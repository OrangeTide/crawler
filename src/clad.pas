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

  Kit piece meshes are decoded once into a resident cache keyed by lump. Each
  piece samples one of the tileset's resident trim atlases (textures.TrimPtr by
  the piece's atlas index), so the map's tileset must be the resident one. A
  single-atlas kit leaves every piece on atlas 0. The merged block is
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

{ Clad the walls of every open kit cell in the window: a wall piece stands on
  each edge where the cell meets a solid cell, runs merged along the edge and
  aligned to the kit grid, scaled to the sector height. The caller suppresses
  its own wall quads toward kit cells so the two do not overlap. }
procedure CladWalls(const mc: TMeshCam; x0, y0, x1, y1: longint;
  ex, ey: double; lightFn: TCladLightFn);

{ Clad one step face on edge dir of the kit cell (tx,ty): a single wall piece
  spanning world height z0..z1, for a riser or lintel between two open cells of
  different height. Uses the single-cell (base) wall piece, which is double
  sided, so the step reads from the lower neighbour's side. The caller draws
  each step once from the taller cell, as its stone-quad path does. }
procedure CladStep(const mc: TMeshCam; dir, tx, ty: longint;
  z0, z1, light: double);

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
  mi, fw, aw, ah, ew, eh: longint;
  sc: double;
  atlas, emis: PByte;
begin
  if pieceIdx < 0 then exit;
  mi := MeshIdx(Kits[kitIdx].pieces[pieceIdx].lump);
  if (mi < 0) or (not cacheOk[mi]) then exit;
  fw := Kits[kitIdx].pieces[pieceIdx].fw;
  if fw < 1 then fw := 1;
  sc := s / fw;
  atlas := TrimPtr(Kits[kitIdx].tileset, Kits[kitIdx].pieces[pieceIdx].atlas, aw, ah);
  emis := EmisPtr(Kits[kitIdx].tileset, Kits[kitIdx].pieces[pieceIdx].emis, ew, eh);
  RenderMeshAt(cacheMesh[mi], mc, cxw, cyw, mz, sc, 0, light,
    atlas, aw, ah, emis, ew, eh);
end;

{ Draw the floor (and ceiling) of an s-by-s block anchored at cell (ax,ay). }
procedure DrawBlock(const mc: TMeshCam; kitIdx, ax, ay, s: longint;
  fz, cz, ex, ey: double; drawCeil: boolean; lightFn: TCladLightFn);
var
  fp: longint;
  cxw, cyw, dist, light: double;
begin
  fp := KitPieceForRun(kitIdx, KITROLE_FLOOR, s);
  if fp < 0 then exit;
  cxw := ax + s / 2; cyw := ay + s / 2;
  dist := sqrt(sqr(cxw - ex) + sqr(cyw - ey));
  light := lightFn(ax + s div 2, ay + s div 2, dist);
  DrawPiece(mc, kitIdx, fp, cxw, cyw, fz, s, light);
  if drawCeil then
    DrawPiece(mc, kitIdx, KitPieceForRun(kitIdx, KITROLE_CEIL, s),
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

{ The four edge directions a wall can stand on: the solid-neighbour offset,
  whether the run extends along x (else along y), the piece yaw, and the
  anchor offset onto the boundary line between the cell and its neighbour. }
const
  WDX: array[0 .. 3] of longint = (-1,  1,  0,  0);   { W E S N }
  WDY: array[0 .. 3] of longint = ( 0,  0, -1,  1);
  WRunX: array[0 .. 3] of boolean = (false, false, true, true);
  WMOX: array[0 .. 3] of longint = (0, 1, 0, 0);
  WMOY: array[0 .. 3] of longint = (0, 0, 0, 1);

{ Is a wall wanted on edge dir of cell (cx,cy): an open kit cell of sector s0
  whose neighbour across dir is solid, not already drawn? }
function WallCell(cx, cy, dir, s0, kitIdx: longint): boolean;
begin
  WallCell := false;
  if (cx < 0) or (cy < 0) or (cx >= MapW) or (cy >= MapH) then exit;
  if covered[cy][cx] then exit;
  if IsWallTile(cx, cy) then exit;
  if SectorAt(cx, cy) <> s0 then exit;
  if KitIndexForTileset(CellTileset(cx, cy)) <> kitIdx then exit;
  WallCell := IsWallTile(cx + WDX[dir], cy + WDY[dir]);
end;

{ Does the whole kit-grid-aligned run of wfw cells from (ax,ay) along the
  direction's run axis want this wall? }
function WallRunFull(dir, ax, ay, wfw, s0, kitIdx: longint): boolean;
var i: longint;
begin
  WallRunFull := false;
  for i := 0 to wfw - 1 do
    if WRunX[dir] then begin
      if not WallCell(ax + i, ay, dir, s0, kitIdx) then exit;
    end else
      if not WallCell(ax, ay + i, dir, s0, kitIdx) then exit;
  WallRunFull := true;
end;

procedure CladWalls(const mc: TMeshCam; x0, y0, x1, y1: longint;
  ex, ey: double; lightFn: TCladLightFn);
var
  dir, tx, ty, ax, ay, i, run, rsx, rsy, kitIdx: longint;
  wp, wpN, wfw, pfw, wh, s0, mi, aw, ah, ew, eh: longint;
  fz, cz, sxl, szl, yaw, mxw, myw, cxr, cyr, dist, light: double;
  atlas, emis: PByte;
begin
  for dir := 0 to 3 do begin
    for ty := 0 to MapH - 1 do
      for tx := 0 to MapW - 1 do
        covered[ty][tx] := false;

    for ty := y0 to y1 do
      for tx := x0 to x1 do begin
        if (tx < 0) or (ty < 0) or (tx >= MapW) or (ty >= MapH) then continue;
        kitIdx := KitIndexForTileset(CellTileset(tx, ty));
        if kitIdx < 0 then continue;
        s0 := SectorAt(tx, ty);
        if not WallCell(tx, ty, dir, s0, kitIdx) then continue;
        { align runs to the native (largest) wall piece's footprint }
        wpN := KitPieceForRun(kitIdx, KITROLE_WALL, MapW + MapH);
        if wpN < 0 then continue;
        wfw := Kits[kitIdx].pieces[wpN].fw; if wfw < 1 then wfw := 1;

        { a full kit-grid-aligned run draws as one native piece; an edge that
          does not fill the run drops to one base piece per cell. Aligning to
          the world grid keeps the run stable as the camera moves }
        if WRunX[dir] then ax := (tx div wfw) * wfw else ax := tx;
        if WRunX[dir] then ay := ty else ay := (ty div wfw) * wfw;
        if WallRunFull(dir, ax, ay, wfw, s0, kitIdx) then begin
          run := wfw; rsx := ax; rsy := ay;
        end else begin
          run := 1; rsx := tx; rsy := ty;
        end;

        { native piece over a full run, base piece over a single filler }
        wp := KitPieceForRun(kitIdx, KITROLE_WALL, run);
        mi := MeshIdx(Kits[kitIdx].pieces[wp].lump);
        if (mi < 0) or (not cacheOk[mi]) then continue;
        pfw := Kits[kitIdx].pieces[wp].fw; if pfw < 1 then pfw := 1;
        wh := Kits[kitIdx].pieces[wp].fz; if wh < 1 then wh := 1;

        for i := 0 to run - 1 do
          if WRunX[dir] then covered[rsy][rsx + i] := true
          else covered[rsy + i][rsx] := true;

        fz := FloorZAt(tx, ty); cz := CeilZAt(tx, ty);
        sxl := run / pfw;              { run cells along the piece length }
        szl := (cz - fz) / wh;         { fit the piece height to the sector }
        if WRunX[dir] then yaw := 0 else yaw := pi / 2;
        mxw := rsx + WMOX[dir];
        myw := rsy + WMOY[dir];
        if WRunX[dir] then begin
          cxr := rsx + run / 2; cyr := rsy + 0.5;
        end else begin
          cxr := rsx + 0.5; cyr := rsy + run / 2;
        end;
        dist := sqrt(sqr(cxr - ex) + sqr(cyr - ey));
        light := lightFn(tx, ty, dist);
        atlas := TrimPtr(Kits[kitIdx].tileset, Kits[kitIdx].pieces[wp].atlas, aw, ah);
        emis := EmisPtr(Kits[kitIdx].tileset, Kits[kitIdx].pieces[wp].emis, ew, eh);
        RenderMeshAt3(cacheMesh[mi], mc, mxw, myw, fz, sxl, 1, szl, yaw,
          light, atlas, aw, ah, emis, ew, eh);
      end;
  end;
end;

procedure CladStep(const mc: TMeshCam; dir, tx, ty: longint;
  z0, z1, light: double);
var
  kitIdx, wp, pfw, wh, mi, aw, ah: longint;
  sxl, szl, yaw, mxw, myw: double;
  atlas: PByte;
begin
  if z1 <= z0 then exit;
  kitIdx := KitIndexForTileset(CellTileset(tx, ty));
  if kitIdx < 0 then exit;
  wp := KitPieceForRun(kitIdx, KITROLE_WALL, 1);   { the single-cell wall }
  if wp < 0 then exit;
  mi := MeshIdx(Kits[kitIdx].pieces[wp].lump);
  if (mi < 0) or (not cacheOk[mi]) then exit;
  pfw := Kits[kitIdx].pieces[wp].fw; if pfw < 1 then pfw := 1;
  wh := Kits[kitIdx].pieces[wp].fz; if wh < 1 then wh := 1;
  sxl := 1 / pfw;                { one cell wide }
  szl := (z1 - z0) / wh;         { fit the piece height to the step }
  if WRunX[dir] then yaw := 0 else yaw := pi / 2;
  mxw := tx + WMOX[dir];
  myw := ty + WMOY[dir];
  atlas := TrimPtr(Kits[kitIdx].tileset, Kits[kitIdx].pieces[wp].atlas, aw, ah);
  RenderMeshAt3(cacheMesh[mi], mc, mxw, myw, z0, sxl, 1, szl, yaw,
    light, atlas, aw, ah);
end;

end.
