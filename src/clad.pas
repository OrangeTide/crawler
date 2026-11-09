unit clad;

{** The cladding pass: draw a tileset's sectors from its modular kit meshes
  instead of the procedural surface quads.

  Floors and ceilings are drawn at the kit's native scale. The pass merges
  cells into blocks aligned to a fixed world grid of the piece's footprint:
  a full footprint-sized block of open, same-sector cells draws as one
  native-scale piece, and a ragged edge that does not fill a block drops to
  one piece per cell (scaled down to a single grid unit). Aligning the merge
  to the world grid rather than the view keeps the tiling stable as the
  camera moves, so pieces do not resize or shimmer frame to frame.

  Kit piece meshes are decoded once into a resident cache keyed by lump. The
  cladding draws from the resident trim atlas (textures.TrimTex), so the
  map's tileset must be the one whose atlas is resident. The merged block is
  lit as a whole through a caller-supplied light function, so the lighting
  matches the renderer's own per-cell shading at the block's centre. }

{$mode objfpc}{$H+}

interface

uses
  raster, meshfmt, pak, tilekit, world;

type
  { The renderer's surface-light function: brightness (0..256) on the cell at
    (tx,ty) seen from dist tiles away. }
  TCladLightFn = function(tx, ty: longint; dist: double): double;

{ Decode every kit piece mesh into the resident cache. Call after LoadKits. }
procedure CladInit(const p: TPak);

{ Clad the floors (and, when drawCeil, the ceilings) of every open kit cell in
  the window [x0..x1] x [y0..y1], with the camera at (ex,ey) and light from
  lightFn. Non-kit cells are left for the caller's quad path. }
procedure CladView(const mc: TMeshCam; x0, y0, x1, y1: longint;
  ex, ey: double; drawCeil: boolean; lightFn: TCladLightFn);

implementation

uses
  textures;

var
  cacheName: array of string;
  cacheMesh: array of TMesh;
  cacheOk: array of boolean;
  covered: array[0 .. MAXMAP - 1, 0 .. MAXMAP - 1] of boolean;

function MeshIdx(const nm: string): longint;
var k: longint;
begin
  MeshIdx := -1;
  for k := 0 to High(cacheName) do
    if cacheName[k] = nm then begin MeshIdx := k; exit; end;
end;

procedure CladInit(const p: TPak);
var
  i, k, mi: longint;
  blob: TByteArray;
  m: TMesh;
  nm: string;
begin
  cacheName := nil; cacheMesh := nil; cacheOk := nil;
  for i := 0 to High(Kits) do
    for k := 0 to High(Kits[i].pieces) do begin
      nm := Kits[i].pieces[k].lump;
      if MeshIdx(nm) >= 0 then continue;   { shared pieces decode once }
      mi := Length(cacheName);
      SetLength(cacheName, mi + 1);
      SetLength(cacheMesh, mi + 1);
      SetLength(cacheOk, mi + 1);
      cacheName[mi] := nm;
      cacheOk[mi] := PakGet(p, nm, blob) and DecodeMesh(blob, m);
      if cacheOk[mi] then cacheMesh[mi] := m;
    end;
end;

{ Draw one kit piece centred on a world point at height mz. The piece's grid
  footprint (fw units) is scaled to span s grid units. }
procedure DrawPiece(const mc: TMeshCam; kitIdx, pieceIdx: longint;
  cxw, cyw, mz, s, light: double);
var
  mi, fw: longint;
  sc: double;
  atlas: PByte;
begin
  if pieceIdx < 0 then exit;
  mi := MeshIdx(Kits[kitIdx].pieces[pieceIdx].lump);
  if (mi < 0) or (not cacheOk[mi]) then exit;
  fw := Kits[kitIdx].pieces[pieceIdx].fw;
  if fw < 1 then fw := 1;
  sc := s / fw;
  atlas := nil;
  if Length(TrimTex) > 0 then atlas := @TrimTex[0];
  RenderMeshAt(cacheMesh[mi], mc, cxw, cyw, mz, sc, 0, light,
    atlas, TrimW, TrimH);
end;

{ Draw the floor (and ceiling) of an s-by-s block anchored at cell (ax,ay). }
procedure DrawBlock(const mc: TMeshCam; kitIdx, ax, ay, s: longint;
  fz, cz, ex, ey: double; drawCeil: boolean; lightFn: TCladLightFn);
var
  fp: longint;
  cxw, cyw, dist, light: double;
begin
  fp := KitPieceByRole(kitIdx, KITROLE_FLOOR);
  if fp < 0 then exit;
  cxw := ax + s / 2; cyw := ay + s / 2;
  dist := sqrt(sqr(cxw - ex) + sqr(cyw - ey));
  light := lightFn(ax + s div 2, ay + s div 2, dist);
  DrawPiece(mc, kitIdx, fp, cxw, cyw, fz, s, light);
  if drawCeil then
    DrawPiece(mc, kitIdx, KitPieceByRole(kitIdx, KITROLE_CEIL),
      cxw, cyw, cz, s, light);
end;

{ Is every cell of the s-by-s block at (ax,ay) an open, uncovered cell in the
  same sector and kit as the anchor? }
function BlockUniform(ax, ay, s, s0, kitIdx: longint): boolean;
var rx, ry: longint;
begin
  BlockUniform := false;
  for ry := ay to ay + s - 1 do
    for rx := ax to ax + s - 1 do begin
      if (rx < 0) or (ry < 0) or (rx >= MapW) or (ry >= MapH) then exit;
      if IsWallTile(rx, ry) then exit;
      if SectorAt(rx, ry) <> s0 then exit;
      if KitIndexForTileset(CellTileset(rx, ry)) <> kitIdx then exit;
      if covered[ry][rx] then exit;
    end;
  BlockUniform := true;
end;

procedure CladView(const mc: TMeshCam; x0, y0, x1, y1: longint;
  ex, ey: double; drawCeil: boolean; lightFn: TCladLightFn);
var
  tx, ty, ax, ay, rx, ry, kitIdx, fp, fw, s0: longint;
  fz, cz: double;
begin
  for ty := 0 to MapH - 1 do
    for tx := 0 to MapW - 1 do
      covered[ty][tx] := false;

  for ty := y0 to y1 do
    for tx := x0 to x1 do begin
      if (tx < 0) or (ty < 0) or (tx >= MapW) or (ty >= MapH) then continue;
      if covered[ty][tx] or IsWallTile(tx, ty) then continue;
      kitIdx := KitIndexForTileset(CellTileset(tx, ty));
      if kitIdx < 0 then continue;
      fp := KitPieceByRole(kitIdx, KITROLE_FLOOR);
      if fp < 0 then continue;
      fw := Kits[kitIdx].pieces[fp].fw;
      if fw < 1 then fw := 1;
      s0 := SectorAt(tx, ty);
      fz := FloorZAt(tx, ty); cz := CeilZAt(tx, ty);

      { try the full footprint-sized block aligned to the world grid }
      ax := (tx div fw) * fw; ay := (ty div fw) * fw;
      if BlockUniform(ax, ay, fw, s0, kitIdx) then begin
        DrawBlock(mc, kitIdx, ax, ay, fw, fz, cz, ex, ey, drawCeil, lightFn);
        for ry := ay to ay + fw - 1 do
          for rx := ax to ax + fw - 1 do
            covered[ry][rx] := true;
      end else begin
        { ragged edge: one piece scaled to this single cell }
        DrawBlock(mc, kitIdx, tx, ty, 1, fz, cz, ex, ey, drawCeil, lightFn);
        covered[ty][tx] := true;
      end;
    end;
end;

end.
