unit carve;

{** Carve-and-clad map generation on the kit's module grid.

  A modular kit clads a sector cleanly only when its open cells fall into
  whole floor-piece blocks aligned to the world grid: the cladding anchors a
  block at (tx div N)*N and draws one native piece when that whole N by N
  block is open and one sector, dropping to scaled single-cell fillers
  otherwise (clad.CladView). This unit lays maps out so that condition always
  holds. It carves on a coarse module grid, one module per N by N floor piece,
  then expands each module to its N by N cells. Every open region is then a
  union of N-aligned single-sector blocks, and the smallest corridor is one
  module (N cells) wide, so a sub-module notch or a one-cell corridor the kit
  cannot tile is impossible by construction.

  CarveLevel generates a fresh level this way. RepairToModule conforms an
  arbitrary grid (carved or hand-authored) to the module, so manual authoring
  can run the same step before a final edit. N is the kit's floor footprint,
  from the kit tables; a tileset with no kit has N = 1 and is left flat. The
  output is an ordinary TMapData that feeds the existing cladding unchanged. }

{$mode objfpc}{$H+}

interface

uses
  rng, mapfmt, tilekit, gridgen;

{ The module size N for a tileset: its kit's floor-piece footprint, or 1 when
  the tileset carries no kit. }
function KitModule(tileset: longint): longint;

{ Carve a fresh level for a kit tileset, born aligned to its module so it clads
  from native pieces with no fillers. depth tunes the room count. The result
  has walls, per-module sectors and a start/back marker; portals and content
  are the caller's to add. }
function CarveLevel(seed: longword; tileset, depth: longint): TMapData;

{ Conform an existing map's grid to module N: snap ragged rooms to the module,
  drop sub-module notches, keep the map connected, and relocate any entity a
  snapped cell would strand. Returns false only on a degenerate map (no room
  for one module). }
function RepairToModule(var m: TMapData; N: longint): boolean;

implementation

{ Per-module height palette, matching the crypt's VaryHeights: floors step by
  at most half a unit so adjacent modules stay within the party's step-up
  limit, ceilings vary freely. }
const
  CEILS: array[0 .. 3] of smallint = (40, 48, 56, 64);   { 2.5 .. 4.0 units }
  FLRS:  array[0 .. 1] of smallint = (0, 8);             { 0 or 0.5 unit }

function KitModule(tileset: longint): longint;
var
  ki, fp: longint;
begin
  KitModule := 1;
  ki := KitIndexForTileset(tileset);
  if ki < 0 then exit;
  fp := KitPieceByRole(ki, KITROLE_FLOOR);
  if fp < 0 then exit;
  KitModule := Kits[ki].pieces[fp].fw;
  if KitModule < 1 then KitModule := 1;
end;

{ Find a sector with this floor and ceiling, or add one. Open cells of the same
  height share a sector, so the cladding merges them into one block. }
function InternSector(var m: TMapData; fz, cz: smallint): longint;
var
  k: longint;
begin
  for k := 0 to High(m.sectors) do
    if (m.sectors[k].floorZ = fz) and (m.sectors[k].ceilZ = cz) then begin
      InternSector := k;
      exit;
    end;
  k := Length(m.sectors);
  SetLength(m.sectors, k + 1);
  m.sectors[k].floorZ := fz;
  m.sectors[k].ceilZ := cz;
  m.sectors[k].tileset := 0;
  m.sectors[k].light := 0;
  InternSector := k;
end;

function CarveLevel(seed: longword; tileset, depth: longint): TMapData;
var
  r: TRng;
  gm: TGrid;
  modCols, modRows, modN, i, mx, my, cx, cy, fwc, fhc: longint;
  smx, smy, emx, emy, reach, sec: longint;
  mFloor, mCeil: array of smallint;
  m: TMapData;
begin
  modN := KitModule(tileset);
  if modN < 1 then modN := 1;
  { a module grid that keeps the fine map within MAXMAP (60 cells here, to
    match the generators' own clamp) and stays big enough to carve rooms in }
  modCols := 60 div modN;
  if modCols > 16 then modCols := 16;
  if modCols < 4 then modCols := 4;
  modRows := modCols;

  RngSeed(r, seed);

  { carve the module grid: rooms-and-corridors where it is large enough, else
    (large-module kits, where the grid is small) a single bordered hall, which
    is already module-clean }
  gw := modCols; gh := modRows;
  SetLength(gm, gw * gh);
  if (modCols >= 10) and (modRows >= 10) then
    GenRooms(gm, r, depth)
  else begin
    for i := 0 to gw * gh - 1 do gm[i] := 1;
    for my := 1 to gh - 2 do
      for mx := 1 to gw - 2 do
        SetAt(gm, mx, my, 0);
  end;

  if not FirstFloor(gm, smx, smy) then begin
    smx := gw div 2; smy := gh div 2;
    SetAt(gm, smx, smy, 0);
  end;
  FloodFarthest(gm, smx, smy, emx, emy, reach);

  { one floor/ceiling height per module, so every N-block stays single-sector }
  SetLength(mFloor, modCols * modRows);
  SetLength(mCeil, modCols * modRows);
  for i := 0 to modCols * modRows - 1 do begin
    mFloor[i] := FLRS[RngRange(r, 0, 1)];
    mCeil[i]  := CEILS[RngRange(r, 0, 3)];
  end;

  { realize: each module expands to its N by N block of cells, born on the
    cladding's (tx div N)*N anchor }
  fwc := modCols * modN; fhc := modRows * modN;
  m.w := fwc; m.h := fhc;
  m.tileset := tileset; m.music := 0; m.flags := 0; m.area := 0;
  m.heightLump := ''; m.heightZMin := 0; m.heightZMax := 0;
  SetLength(m.walls, fwc * fhc);
  SetLength(m.cellSector, fwc * fhc);
  SetLength(m.sectors, 0);
  m.markers := nil; m.portals := nil; m.doors := nil; m.npcs := nil;
  m.traps := nil; m.lights := nil; m.props := nil; m.loot := nil;
  m.triggers := nil; m.pillars := nil; m.foliage := nil;

  for my := 0 to modRows - 1 do
    for mx := 0 to modCols - 1 do begin
      if At(gm, mx, my) = 0 then
        sec := InternSector(m, mFloor[my * modCols + mx], mCeil[my * modCols + mx])
      else
        sec := -1;
      for cy := my * modN to my * modN + modN - 1 do
        for cx := mx * modN to mx * modN + modN - 1 do begin
          i := cy * fwc + cx;
          if sec >= 0 then begin
            m.walls[i] := 0;
            m.cellSector[i] := byte(sec);
          end else begin
            m.walls[i] := 1;             { any nonzero cell is solid to the kit }
            m.cellSector[i] := SECTOR_NONE;
          end;
        end;
    end;
  if Length(m.sectors) = 0 then
    m.cellSector[0] := byte(InternSector(m, 0, HZ_UNIT));

  { the party's entry, at the centre of the start module }
  SetLength(m.markers, 2);
  m.markers[0].name := 'start';
  m.markers[0].x := smx * modN + modN div 2;
  m.markers[0].y := smy * modN + modN div 2;
  m.markers[0].dir := DIR_E;
  m.markers[1] := m.markers[0];
  m.markers[1].name := 'back';

  CarveLevel := m;
end;

{ Breadth-first mark of every open module reachable from (sx,sy) on the module
  grid, using the gridgen globals gw/gh. }
procedure FloodMark(const g: TGrid; sx, sy: longint; var reached: array of boolean);
const
  dx: array[0 .. 3] of longint = (1, -1, 0, 0);
  dy: array[0 .. 3] of longint = (0, 0, 1, -1);
var
  qx, qy: array of longint;
  head, tail, x, y, k, nx, ny: longint;
begin
  for k := 0 to gw * gh - 1 do reached[k] := false;
  SetLength(qx, gw * gh); SetLength(qy, gw * gh);
  head := 0; tail := 0;
  reached[sy * gw + sx] := true;
  qx[tail] := sx; qy[tail] := sy; inc(tail);
  while head < tail do begin
    x := qx[head]; y := qy[head]; inc(head);
    for k := 0 to 3 do begin
      nx := x + dx[k]; ny := y + dy[k];
      if (nx < 0) or (ny < 0) or (nx >= gw) or (ny >= gh) then continue;
      if At(g, nx, ny) <> 0 then continue;
      if reached[ny * gw + nx] then continue;
      reached[ny * gw + nx] := true;
      qx[tail] := nx; qy[tail] := ny; inc(tail);
    end;
  end;
end;

{ Nearest open cell to (x,y) on the map's wall grid, by breadth-first search.
  Used to pull an entity off a cell the conform turned solid. }
function NearestOpen(const m: TMapData; x, y: longint; out ox, oy: longint): boolean;
const
  dx: array[0 .. 3] of longint = (1, -1, 0, 0);
  dy: array[0 .. 3] of longint = (0, 0, 1, -1);
var
  qx, qy: array of longint;
  seen: array of boolean;
  head, tail, cx, cy, k, nx, ny: longint;
begin
  NearestOpen := false;
  if (x < 0) or (y < 0) or (x >= m.w) or (y >= m.h) then exit;
  SetLength(seen, m.w * m.h);
  SetLength(qx, m.w * m.h); SetLength(qy, m.w * m.h);
  head := 0; tail := 0;
  seen[y * m.w + x] := true;
  qx[tail] := x; qy[tail] := y; inc(tail);
  while head < tail do begin
    cx := qx[head]; cy := qy[head]; inc(head);
    if m.walls[cy * m.w + cx] = 0 then begin
      ox := cx; oy := cy; NearestOpen := true; exit;
    end;
    for k := 0 to 3 do begin
      nx := cx + dx[k]; ny := cy + dy[k];
      if (nx < 0) or (ny < 0) or (nx >= m.w) or (ny >= m.h) then continue;
      if seen[ny * m.w + nx] then continue;
      seen[ny * m.w + nx] := true;
      qx[tail] := nx; qy[tail] := ny; inc(tail);
    end;
  end;
end;

{ Move an entity at (ex,ey) onto the nearest open cell, clamping an out-of-range
  coordinate into the map first. Returns false only when the map has no open
  cell at all. }
function RelocOpen(const m: TMapData; var ex, ey: word): boolean;
var
  cx, cy, ox, oy: longint;
begin
  cx := ex; cy := ey;
  if cx >= m.w then cx := m.w - 1;
  if cy >= m.h then cy := m.h - 1;
  if (cx < 0) or (cy < 0) then begin RelocOpen := false; exit; end;
  if m.walls[cy * m.w + cx] = 0 then begin
    ex := cx; ey := cy; RelocOpen := true; exit;
  end;
  RelocOpen := NearestOpen(m, cx, cy, ox, oy);
  if RelocOpen then begin ex := ox; ey := oy; end;
end;

function RepairToModule(var m: TMapData; N: longint): boolean;
var
  mbCols, mbRows, mx, my, cx, cy, i, idx: longint;
  gm: TGrid;
  reached: array of boolean;
  bFloor, bCeil: array of smallint;
  half, openCnt, smx, smy, ux, uy, fwc, fhc, sec: longint;
  minF, maxC, cs: smallint;
  had, anyStranded: boolean;
  newWalls, newCS: array of byte;
  keptProps: array of TProp;
  keptLoot: array of TLoot;
  keptFol: array of TFoliage;
  keptPil: array of TPillar;
begin
  RepairToModule := false;
  if N < 1 then N := 1;
  if N = 1 then begin EnsureSectors(m); RepairToModule := true; exit; end;
  mbCols := m.w div N; mbRows := m.h div N;
  if (mbCols < 1) or (mbRows < 1) then exit;

  { 1. reduce to a module grid: a block is open when most of its cells are open,
       which snaps ragged edges to the module and drops sub-module notches }
  gw := mbCols; gh := mbRows;
  SetLength(gm, mbCols * mbRows);
  SetLength(bFloor, mbCols * mbRows);
  SetLength(bCeil, mbCols * mbRows);
  half := (N * N + 1) div 2;
  for my := 0 to mbRows - 1 do
    for mx := 0 to mbCols - 1 do begin
      openCnt := 0; minF := 32767; maxC := -32768; had := false;
      for cy := my * N to my * N + N - 1 do
        for cx := mx * N to mx * N + N - 1 do begin
          i := cy * m.w + cx;
          if m.walls[i] <> 0 then continue;
          inc(openCnt);
          if (Length(m.cellSector) = m.w * m.h)
            and (m.cellSector[i] <> SECTOR_NONE)
            and (m.cellSector[i] <= High(m.sectors)) then begin
            had := true;
            cs := m.sectors[m.cellSector[i]].floorZ;
            if cs < minF then minF := cs;
            cs := m.sectors[m.cellSector[i]].ceilZ;
            if cs > maxC then maxC := cs;
          end;
        end;
      idx := my * mbCols + mx;
      if openCnt >= half then begin
        SetAt(gm, mx, my, 0);
        if had then begin bFloor[idx] := minF; bCeil[idx] := maxC; end
        else begin bFloor[idx] := 0; bCeil[idx] := HZ_UNIT; end;
      end else begin
        SetAt(gm, mx, my, 1);
        bFloor[idx] := 0; bCeil[idx] := HZ_UNIT;
      end;
    end;

  { 2. keep it connected: reconnect any open module stranded by the snap, by
       carving a corridor from the start module to it }
  SetLength(reached, mbCols * mbRows);
  if FirstFloor(gm, smx, smy) then
    repeat
      FloodMark(gm, smx, smy, reached);
      anyStranded := false;
      ux := -1; uy := -1;
      for my := 0 to mbRows - 1 do
        for mx := 0 to mbCols - 1 do
          if (At(gm, mx, my) = 0) and (not reached[my * mbCols + mx]) then begin
            ux := mx; uy := my; anyStranded := true;
          end;
      if anyStranded then
        CarveLine(gm, smx, smy, ux, uy);   { newly opened modules take defaults }
    until not anyStranded;

  { 3. re-expand the module grid to a fresh fine grid and sector layer }
  fwc := mbCols * N; fhc := mbRows * N;
  SetLength(newWalls, fwc * fhc);
  SetLength(newCS, fwc * fhc);
  SetLength(m.sectors, 0);
  for my := 0 to mbRows - 1 do
    for mx := 0 to mbCols - 1 do begin
      idx := my * mbCols + mx;
      if At(gm, mx, my) = 0 then
        sec := InternSector(m, bFloor[idx], bCeil[idx])
      else
        sec := -1;
      for cy := my * N to my * N + N - 1 do
        for cx := mx * N to mx * N + N - 1 do begin
          i := cy * fwc + cx;
          if sec >= 0 then begin
            newWalls[i] := 0;
            newCS[i] := byte(sec);
          end else begin
            newWalls[i] := 1;
            newCS[i] := SECTOR_NONE;
          end;
        end;
    end;
  m.w := fwc; m.h := fhc;
  m.walls := newWalls;
  m.cellSector := newCS;
  if Length(m.sectors) = 0 then
    m.cellSector[0] := byte(InternSector(m, 0, HZ_UNIT));

  { 4. relocate structural entities a snapped cell would strand; drop decoration
       that fell on a solidified cell }
  for i := 0 to High(m.markers) do
    RelocOpen(m, m.markers[i].x, m.markers[i].y);
  for i := 0 to High(m.portals) do
    RelocOpen(m, m.portals[i].x, m.portals[i].y);
  for i := 0 to High(m.npcs) do
    RelocOpen(m, m.npcs[i].x, m.npcs[i].y);
  for i := 0 to High(m.doors) do
    RelocOpen(m, m.doors[i].x, m.doors[i].y);

  SetLength(keptProps, 0);
  for i := 0 to High(m.props) do
    if (m.props[i].x < m.w) and (m.props[i].y < m.h)
      and (m.walls[m.props[i].y * m.w + m.props[i].x] = 0) then begin
      SetLength(keptProps, Length(keptProps) + 1);
      keptProps[High(keptProps)] := m.props[i];
    end;
  m.props := keptProps;

  SetLength(keptLoot, 0);
  for i := 0 to High(m.loot) do
    if (m.loot[i].x < m.w) and (m.loot[i].y < m.h)
      and (m.walls[m.loot[i].y * m.w + m.loot[i].x] = 0) then begin
      SetLength(keptLoot, Length(keptLoot) + 1);
      keptLoot[High(keptLoot)] := m.loot[i];
    end;
  m.loot := keptLoot;

  SetLength(keptFol, 0);
  for i := 0 to High(m.foliage) do
    if (m.foliage[i].x < m.w) and (m.foliage[i].y < m.h)
      and (m.walls[m.foliage[i].y * m.w + m.foliage[i].x] = 0) then begin
      SetLength(keptFol, Length(keptFol) + 1);
      keptFol[High(keptFol)] := m.foliage[i];
    end;
  m.foliage := keptFol;

  SetLength(keptPil, 0);
  for i := 0 to High(m.pillars) do
    if (m.pillars[i].x < m.w) and (m.pillars[i].y < m.h)
      and (m.walls[m.pillars[i].y * m.w + m.pillars[i].x] = 0) then begin
      SetLength(keptPil, Length(keptPil) + 1);
      keptPil[High(keptPil)] := m.pillars[i];
    end;
  m.pillars := keptPil;

  RepairToModule := true;
end;

end.
