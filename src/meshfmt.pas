unit meshfmt;

{** Baked triangle mesh, the unit the polygon renderer draws.

  A mesh is a flat list of triangles, three corners each, every corner
  carrying a position and a texture coordinate. Corners are not shared
  between triangles, which keeps the renderer a simple loop and suits
  the small PSX-scale models this engine uses. One paletted texture
  travels with the mesh, already quantized to the game palette.

  The on-disk lump is 'CMSH': a header, the corners as 32-bit floats,
  then the texture as one byte per texel (a palette index). The offline
  baker reads a Wavefront OBJ (positions and UVs) and a binary PPM
  texture and produces this. Model space is converted to the engine's
  Z-up world on the way in, so the renderer needs no axis juggling. }

{$mode objfpc}{$H+}

interface

uses
  pak;

const
  MESH_MAGIC   = $48534D43;   { 'CMSH' little-endian }
  MESH_VERSION = 1;

  { default triangle ceiling for a baked model, sized for the PSX and
    DOS targets; the baker reduces anything heavier to fit }
  MESH_TRI_BUDGET = 600;

type
  { pin this to pak's dynamic byte array; sysutils exposes a static
    TByteArray that would otherwise shadow it in the implementation }
  TByteArray = pak.TByteArray;

  TTriVert = record
    x, y, z: single;    { position, Z up }
    u, v: single;       { texture coordinate, OBJ convention (V up) }
  end;

  TMesh = record
    verts: array of TTriVert;   { 3 per triangle, length = triCount * 3 }
    texW, texH: longint;
    tex: array of byte;         { texW * texH palette indices, top-left origin }
  end;

function EncodeMesh(const m: TMesh): TByteArray;
function DecodeMesh(const blob: TByteArray; out m: TMesh): boolean;

{ Offline baker: read an OBJ and a binary PPM, quantize the texture to
  the game palette (InitGfx must have run), and build the mesh. }
function LoadMeshObjPpm(const objFn, ppmFn: string; out m: TMesh): boolean;

{ Read a binary PPM (P6) into a flat RGB byte buffer (w*h*3). }
function ReadPpm(const fn: string; out w, h: longint; out pixbuf: TByteArray): boolean;

{ Offline baker: reduce a mesh to at most maxTris triangles by clustering
  vertices onto a spatial grid. A mesh already within budget is left as
  is. Returns the triangle count after the pass. }
function DecimateMesh(var m: TMesh; maxTris: longint): longint;

implementation

uses
  sysutils, classes, gfx;

{ --- little-endian byte stream helpers --- }

procedure PutU32(var b: TByteArray; var n: longint; v: longword);
begin
  b[n] := v and $FF; b[n + 1] := (v shr 8) and $FF;
  b[n + 2] := (v shr 16) and $FF; b[n + 3] := (v shr 24) and $FF;
  inc(n, 4);
end;

function GetU32(const b: TByteArray; var n: longint): longword;
begin
  GetU32 := longword(b[n]) or (longword(b[n + 1]) shl 8)
    or (longword(b[n + 2]) shl 16) or (longword(b[n + 3]) shl 24);
  inc(n, 4);
end;

procedure PutF(var b: TByteArray; var n: longint; f: single);
var p: pbyte; i: longint;
begin
  p := pbyte(@f);
  for i := 0 to 3 do b[n + i] := p[i];
  inc(n, 4);
end;

function GetF(const b: TByteArray; var n: longint): single;
var f: single; p: pbyte; i: longint;
begin
  p := pbyte(@f);
  for i := 0 to 3 do p[i] := b[n + i];
  inc(n, 4);
  GetF := f;
end;

function EncodeMesh(const m: TMesh): TByteArray;
var
  b: TByteArray;
  n, i, nv, nt: longint;
begin
  nv := Length(m.verts);
  nt := m.texW * m.texH;
  SetLength(b, 4 + 4 + 4 + nv * 5 * 4 + 4 + 4 + nt);
  n := 0;
  PutU32(b, n, MESH_MAGIC);
  PutU32(b, n, MESH_VERSION);
  PutU32(b, n, nv);
  for i := 0 to nv - 1 do begin
    PutF(b, n, m.verts[i].x); PutF(b, n, m.verts[i].y); PutF(b, n, m.verts[i].z);
    PutF(b, n, m.verts[i].u); PutF(b, n, m.verts[i].v);
  end;
  PutU32(b, n, m.texW);
  PutU32(b, n, m.texH);
  for i := 0 to nt - 1 do b[n + i] := m.tex[i];
  inc(n, nt);
  EncodeMesh := b;
end;

function DecodeMesh(const blob: TByteArray; out m: TMesh): boolean;
var
  n, i, nv, nt: longint;
begin
  DecodeMesh := false;
  m.verts := nil; m.tex := nil; m.texW := 0; m.texH := 0;
  if Length(blob) < 12 then exit;
  n := 0;
  if GetU32(blob, n) <> MESH_MAGIC then exit;
  if GetU32(blob, n) <> MESH_VERSION then exit;
  nv := GetU32(blob, n);
  if (nv < 0) or (nv mod 3 <> 0) then exit;
  if Length(blob) < n + nv * 5 * 4 + 8 then exit;
  SetLength(m.verts, nv);
  for i := 0 to nv - 1 do begin
    m.verts[i].x := GetF(blob, n); m.verts[i].y := GetF(blob, n);
    m.verts[i].z := GetF(blob, n);
    m.verts[i].u := GetF(blob, n); m.verts[i].v := GetF(blob, n);
  end;
  m.texW := GetU32(blob, n);
  m.texH := GetU32(blob, n);
  nt := m.texW * m.texH;
  if (nt < 0) or (Length(blob) < n + nt) then exit;
  SetLength(m.tex, nt);
  for i := 0 to nt - 1 do m.tex[i] := blob[n + i];
  DecodeMesh := true;
end;

{ --- OBJ and PPM parsing for the baker --- }

type
  TVec3 = record x, y, z: single; end;
  TVec2 = record u, v: single; end;

{ Parse one face corner token 'v', 'v/vt' or 'v/vt/vn' into 1-based
  position and uv indices (uv 0 if absent). }
procedure ParseCorner(const tok: string; out vi, ti: longint);
var
  p, q: longint;
  a, b: string;
begin
  vi := 0; ti := 0;
  p := Pos('/', tok);
  if p = 0 then begin vi := StrToIntDef(tok, 0); exit; end;
  a := Copy(tok, 1, p - 1);
  vi := StrToIntDef(a, 0);
  b := Copy(tok, p + 1, Length(tok) - p);
  q := Pos('/', b);
  if q > 0 then b := Copy(b, 1, q - 1);
  ti := StrToIntDef(b, 0);
end;

{ Split a line on whitespace into tokens. }
procedure SplitWS(const s: string; out tok: array of string; out ntok: longint);
var i, start: longint; inWord: boolean;
begin
  ntok := 0; start := 1; inWord := false;
  for i := 1 to Length(s) do begin
    if (s[i] = ' ') or (s[i] = #9) then begin
      if inWord then begin
        if ntok <= High(tok) then begin tok[ntok] := Copy(s, start, i - start); inc(ntok); end;
        inWord := false;
      end;
    end else begin
      if not inWord then begin start := i; inWord := true; end;
    end;
  end;
  if inWord and (ntok <= High(tok)) then begin
    tok[ntok] := Copy(s, start, Length(s) - start + 1); inc(ntok);
  end;
end;

function ReadPpm(const fn: string; out w, h: longint; out pixbuf: TByteArray): boolean;
var
  fs: TFileStream;
  raw: TByteArray;
  n, len, fld: longint;
  vals: array[0 .. 2] of longint;
  cur: longint; started, inComment: boolean;

  function ByteAt(i: longint): byte; begin ByteAt := raw[i]; end;
begin
  ReadPpm := false;
  w := 0; h := 0; pixbuf := nil;
  if not FileExists(fn) then exit;
  fs := TFileStream.Create(fn, fmOpenRead);
  try
    len := fs.Size;
    SetLength(raw, len);
    if len > 0 then fs.ReadBuffer(raw[0], len);
  finally
    fs.Free;
  end;
  if (len < 2) or (ByteAt(0) <> ord('P')) or (ByteAt(1) <> ord('6')) then exit;

  { read three integers (width, height, maxval), skipping whitespace and
    '#' comments; the pixel data starts right after the byte that ends
    the maxval field }
  n := 2; fld := 0; cur := 0; started := false; inComment := false;
  while (n < len) and (fld < 3) do begin
    if inComment then begin
      if ByteAt(n) = 10 then inComment := false;
      inc(n); continue;
    end;
    if ByteAt(n) = ord('#') then begin inComment := true; inc(n); continue; end;
    if (ByteAt(n) >= ord('0')) and (ByteAt(n) <= ord('9')) then begin
      cur := cur * 10 + (ByteAt(n) - ord('0')); started := true; inc(n);
    end else begin
      if started then begin vals[fld] := cur; inc(fld); cur := 0; started := false; end;
      inc(n);   { this whitespace byte after maxval is the single separator }
    end;
  end;
  if fld < 3 then exit;
  w := vals[0]; h := vals[1];
  if (w <= 0) or (h <= 0) then exit;
  if vals[2] <> 255 then exit;   { only 8-bit channels; 16-bit PPM is rejected }
  if len - n < w * h * 3 then exit;
  SetLength(pixbuf, w * h * 3);
  Move(raw[n], pixbuf[0], w * h * 3);
  ReadPpm := true;
end;

{ Shift a mesh so its footprint is centered on X,Y and its lowest point
  sits at z=0. }
procedure CenterMesh(var m: TMesh);
var
  i: longint;
  minx, miny, minz, maxx, maxy, maxz, cx, cy: single;
begin
  if Length(m.verts) = 0 then exit;
  minx := m.verts[0].x; maxx := minx;
  miny := m.verts[0].y; maxy := miny;
  minz := m.verts[0].z; maxz := minz;
  for i := 1 to High(m.verts) do begin
    if m.verts[i].x < minx then minx := m.verts[i].x;
    if m.verts[i].x > maxx then maxx := m.verts[i].x;
    if m.verts[i].y < miny then miny := m.verts[i].y;
    if m.verts[i].y > maxy then maxy := m.verts[i].y;
    if m.verts[i].z < minz then minz := m.verts[i].z;
    if m.verts[i].z > maxz then maxz := m.verts[i].z;
  end;
  cx := (minx + maxx) / 2; cy := (miny + maxy) / 2;
  for i := 0 to High(m.verts) do begin
    m.verts[i].x := m.verts[i].x - cx;
    m.verts[i].y := m.verts[i].y - cy;
    m.verts[i].z := m.verts[i].z - minz;
  end;
end;

{ Build a clustered copy of src at grid resolution g (cells across the
  longest axis). Vertices in a cell collapse to their average; a triangle
  whose corners land in fewer than three cells is dropped. Returns the
  kept triangle count. }
function ClusterAtRes(const src: TMesh; g: longint; out dst: TMesh): longint;
var
  nv, i, t, htSize, repCount, kept, w, c0, c1, c2: longint;
  minx, miny, minz, maxx, maxy, maxz, ext, cell: single;
  htKey, htRep, vrep: array of longint;
  sx, sy, sz, su, sv: array of double;
  pop: array of longint;

  { The representative index for source vertex i, interning its cell. }
  function CellRep(i: longint): longint;
  var cx, cy, cz, kk, s: longint; h: longword;
  begin
    cx := Trunc((src.verts[i].x - minx) / cell);
    cy := Trunc((src.verts[i].y - miny) / cell);
    cz := Trunc((src.verts[i].z - minz) / cell);
    if cx < 0 then cx := 0 else if cx > g then cx := g;
    if cy < 0 then cy := 0 else if cy > g then cy := g;
    if cz < 0 then cz := 0 else if cz > g then cz := g;
    kk := cx + cy * (g + 2) + cz * (g + 2) * (g + 2);
    h := longword(kk);
    h := h xor (h shr 16); h := h * 2654435761; h := h xor (h shr 13);
    s := longint(h and longword(htSize - 1));
    while (htKey[s] <> -1) and (htKey[s] <> kk) do s := (s + 1) and (htSize - 1);
    if htKey[s] = -1 then begin
      htKey[s] := kk; htRep[s] := repCount;
      sx[repCount] := 0; sy[repCount] := 0; sz[repCount] := 0;
      su[repCount] := 0; sv[repCount] := 0; pop[repCount] := 0;
      inc(repCount);
    end;
    CellRep := htRep[s];
  end;

  procedure PutRep(r: longint);
  begin
    dst.verts[w].x := sx[r] / pop[r];
    dst.verts[w].y := sy[r] / pop[r];
    dst.verts[w].z := sz[r] / pop[r];
    dst.verts[w].u := su[r] / pop[r];
    dst.verts[w].v := sv[r] / pop[r];
    inc(w);
  end;

begin
  nv := Length(src.verts);
  minx := src.verts[0].x; maxx := minx; miny := src.verts[0].y; maxy := miny;
  minz := src.verts[0].z; maxz := minz;
  for i := 1 to nv - 1 do begin
    if src.verts[i].x < minx then minx := src.verts[i].x
    else if src.verts[i].x > maxx then maxx := src.verts[i].x;
    if src.verts[i].y < miny then miny := src.verts[i].y
    else if src.verts[i].y > maxy then maxy := src.verts[i].y;
    if src.verts[i].z < minz then minz := src.verts[i].z
    else if src.verts[i].z > maxz then maxz := src.verts[i].z;
  end;
  ext := maxx - minx;
  if maxy - miny > ext then ext := maxy - miny;
  if maxz - minz > ext then ext := maxz - minz;
  if ext <= 0 then ext := 1;
  cell := ext / g;
  if cell <= 0 then cell := ext;

  htSize := 1;
  while htSize < nv * 2 do htSize := htSize * 2;
  SetLength(htKey, htSize); SetLength(htRep, htSize);
  for i := 0 to htSize - 1 do htKey[i] := -1;
  SetLength(sx, nv); SetLength(sy, nv); SetLength(sz, nv);
  SetLength(su, nv); SetLength(sv, nv); SetLength(pop, nv);
  SetLength(vrep, nv);
  repCount := 0;

  for i := 0 to nv - 1 do begin
    vrep[i] := CellRep(i);
    sx[vrep[i]] := sx[vrep[i]] + src.verts[i].x;
    sy[vrep[i]] := sy[vrep[i]] + src.verts[i].y;
    sz[vrep[i]] := sz[vrep[i]] + src.verts[i].z;
    su[vrep[i]] := su[vrep[i]] + src.verts[i].u;
    sv[vrep[i]] := sv[vrep[i]] + src.verts[i].v;
    inc(pop[vrep[i]]);
  end;

  kept := 0;
  for t := 0 to (nv div 3) - 1 do begin
    c0 := vrep[t * 3]; c1 := vrep[t * 3 + 1]; c2 := vrep[t * 3 + 2];
    if (c0 <> c1) and (c1 <> c2) and (c0 <> c2) then inc(kept);
  end;

  dst.verts := nil;
  SetLength(dst.verts, kept * 3);
  dst.texW := src.texW; dst.texH := src.texH;
  SetLength(dst.tex, Length(src.tex));
  if Length(src.tex) > 0 then Move(src.tex[0], dst.tex[0], Length(src.tex));
  w := 0;
  for t := 0 to (nv div 3) - 1 do begin
    c0 := vrep[t * 3]; c1 := vrep[t * 3 + 1]; c2 := vrep[t * 3 + 2];
    if (c0 <> c1) and (c1 <> c2) and (c0 <> c2) then begin
      PutRep(c0); PutRep(c1); PutRep(c2);
    end;
  end;
  ClusterAtRes := kept;
end;

function DecimateMesh(var m: TMesh; maxTris: longint): longint;
var
  lo, hi, mid, bestG, cnt: longint;
  tmp: TMesh;
begin
  DecimateMesh := Length(m.verts) div 3;
  if maxTris < 1 then exit;
  if (Length(m.verts) < 3) or (Length(m.verts) div 3 <= maxTris) then exit;

  { the finest grid within budget preserves the most shape; the kept
    count rises with resolution, so search for the largest g that fits }
  lo := 2; hi := 128; bestG := 2;
  while lo <= hi do begin
    mid := (lo + hi) div 2;
    cnt := ClusterAtRes(m, mid, tmp);
    if cnt <= maxTris then begin bestG := mid; lo := mid + 1; end
    else hi := mid - 1;
  end;

  ClusterAtRes(m, bestG, tmp);
  m := tmp;
  CenterMesh(m);   { averaging may lift the base; reseat it on z=0 }
  DecimateMesh := Length(m.verts) div 3;
end;

function LoadMeshObjPpm(const objFn, ppmFn: string; out m: TMesh): boolean;
var
  lines: TStringList;
  li, i, ntok, vi0, ti0, vi1, ti1, vi2, ti2: longint;
  tok: array[0 .. 63] of string;
  pos: array of TVec3;
  uvs: array of TVec2;
  np, nu, tw, th: longint;
  pixbuf: TByteArray;
  line: string;

  procedure AddCorner(vi, ti: longint);
  var k: longint; tv: TTriVert;
  begin
    if vi < 0 then vi := np + 1 + vi;   { OBJ relative index }
    if ti < 0 then ti := nu + 1 + ti;
    if (vi < 1) or (vi > np) then exit;
    { model is Y-up; store Z-up world coordinates }
    tv.x := pos[vi - 1].x;
    tv.y := -pos[vi - 1].z;
    tv.z := pos[vi - 1].y;
    if (ti >= 1) and (ti <= nu) then begin tv.u := uvs[ti - 1].u; tv.v := uvs[ti - 1].v; end
    else begin tv.u := 0; tv.v := 0; end;
    k := Length(m.verts); SetLength(m.verts, k + 1); m.verts[k] := tv;
  end;

begin
  LoadMeshObjPpm := false;
  m.verts := nil; m.tex := nil; m.texW := 0; m.texH := 0;
  np := 0; nu := 0;

  if not ReadPpm(ppmFn, tw, th, pixbuf) then exit;
  m.texW := tw; m.texH := th;
  SetLength(m.tex, tw * th);
  for i := 0 to tw * th - 1 do
    m.tex[i] := Quantize(RGB(pixbuf[i * 3], pixbuf[i * 3 + 1], pixbuf[i * 3 + 2]));

  lines := TStringList.Create;
  try
    lines.LoadFromFile(objFn);
    SetLength(pos, 0); SetLength(uvs, 0);
    for li := 0 to lines.Count - 1 do begin
      line := lines[li];
      if line = '' then continue;
      SplitWS(line, tok, ntok);
      if ntok = 0 then continue;
      if tok[0] = 'v' then begin
        if ntok >= 4 then begin
          SetLength(pos, np + 1);
          pos[np].x := StrToFloatDef(tok[1], 0);
          pos[np].y := StrToFloatDef(tok[2], 0);
          pos[np].z := StrToFloatDef(tok[3], 0);
          inc(np);
        end;
      end else if tok[0] = 'vt' then begin
        if ntok >= 3 then begin
          SetLength(uvs, nu + 1);
          uvs[nu].u := StrToFloatDef(tok[1], 0);
          uvs[nu].v := StrToFloatDef(tok[2], 0);
          inc(nu);
        end;
      end else if tok[0] = 'f' then begin
        if ntok >= 4 then begin
          { triangulate a fan; assimp -tri already gives triangles }
          ParseCorner(tok[1], vi0, ti0);
          for i := 3 to ntok - 1 do begin
            ParseCorner(tok[i - 1], vi1, ti1);
            ParseCorner(tok[i], vi2, ti2);
            AddCorner(vi0, ti0); AddCorner(vi1, ti1); AddCorner(vi2, ti2);
          end;
        end;
      end;
    end;
  finally
    lines.Free;
  end;

  { center the model on its footprint and rest its base on z=0, so it
    rotates about its own axis and sits on the floor when placed }
  CenterMesh(m);

  LoadMeshObjPpm := Length(m.verts) >= 3;
end;

end.
