unit mapgen;

{** Roguelike map generation for dynamic maps.

  A dynamic map is built from a seed, so it regenerates identically from
  the (version, seed) pair stored in the save. Three generators are
  provided: rooms-and-corridors, a cellular-automata cave and a maze.
  Each result has a start marker, a matching back marker and an exit
  portal to the map that linked here, placed so it is always reachable
  from the start (verified by a flood fill). The grid carvers live in
  gridgen; this unit assembles a carved grid into a TMapData. }

{$mode objfpc}{$H+}

interface

uses
  rng, mapfmt, worldfmt;

const
  GEN_VERSION = 4;   { bump when a generator changes to invalidate old seeds }

function GenerateMap(const d: TDynMap; version: longint; seed: longword): TMapData;
function GenerateOverworldCell(cx, cy: longint; seed: longword): TMapData;
function GenerateInterior(cx, cy, idx: longint; seed: longword): TMapData;
function AddWildernessExit(var m: TMapData; cx, cy: longint): boolean;
function GenerateDungeonLevel(cx, cy, depth: longint; seed: longword): TMapData;
function GenerateDepthsCell(cx, cy: longint; seed: longword): TMapData;

implementation

uses
  gridgen, overworld, worldname;

const
  LADDER_SNAP = 3;   { how far an exit may shift to reach open floor for a ladder }
  STAIR_SNAP  = 3;   { how far an exit may shift to reach a wall for stairs }

function GenerateMap(const d: TDynMap; version: longint; seed: longword): TMapData;
var
  r: TRng;
  g: TGrid;
  i, sx, sy, ex, ey, reach, wallTile: longint;
  m: TMapData;
begin
  gw := d.w; gh := d.h;
  if gw < 8 then gw := 8;
  if gh < 8 then gh := 8;
  if gw > 60 then gw := 60;
  if gh > 60 then gh := 60;
  SetLength(g, gw * gh);
  RngSeed(r, seed);

  case d.gen of
    GEN_CAVE: begin GenCave(g, r); wallTile := 3; end;
    GEN_MAZE: begin GenMaze(g, r); wallTile := 2; end;
  else
    begin GenRooms(g, r, d.depth); wallTile := 1; end;
  end;

  if not FirstFloor(g, sx, sy) then begin
    { degenerate: carve a small room in the middle }
    sx := gw div 2; sy := gh div 2;
    SetAt(g, sx, sy, 0);
    SetAt(g, sx + 1, sy, 0);
  end;
  FloodFarthest(g, sx, sy, ex, ey, reach);

  m.w := gw; m.h := gh;
  m.tileset := 0; m.music := 0; m.flags := 0;
  SetLength(m.walls, gw * gh);
  for i := 0 to gw * gh - 1 do
    if g[i] = 0 then m.walls[i] := 0 else m.walls[i] := wallTile;

  SetLength(m.markers, 2);
  m.markers[0].name := 'start'; m.markers[0].x := sx; m.markers[0].y := sy;
  m.markers[0].dir := DIR_E;
  m.markers[1].name := 'back'; m.markers[1].x := sx; m.markers[1].y := sy;
  m.markers[1].dir := DIR_E;

  SetLength(m.portals, 1);
  m.portals[0].x := ex; m.portals[0].y := ey;
  m.portals[0].target := d.retMap;
  m.portals[0].marker := d.retMarker;
  m.portals[0].kind := PK_UP;

  m.doors := nil;
  m.npcs := nil;
  m.traps := nil; m.lights := nil; m.props := nil;
  GenerateMap := m;
end;

{ One edge of a cell on the given layer ('W' surface, 'S' the Depths):
  fill in its gap, the arrival marker and the portal leaving toward the
  neighbor, unless that neighbor is off the world. On the surface a pinned
  neighbor is entered by its authored name and marker. }
procedure EdgeLink(var m: TMapData; var g: TGrid; layer: char;
  ncx, ncy, gapX, gapY, edgeX, edgeY: longint;
  const arriveName: string; arriveDir: byte);
var
  pin, arr: string;
  np: longint;
begin
  if (ncx < 0) or (ncx >= OW_SIZE) or (ncy < 0) or (ncy >= OW_SIZE) then
    exit;   { world border: leave the wall solid, no exit }

  SetAt(g, gapX, gapY, 0);
  SetAt(g, edgeX, edgeY, 0);

  { arrival marker, one tile inside the gap }
  SetLength(m.markers, Length(m.markers) + 1);
  m.markers[High(m.markers)].name := arriveName;
  m.markers[High(m.markers)].x := edgeX;
  m.markers[High(m.markers)].y := edgeY;
  m.markers[High(m.markers)].dir := arriveDir;

  { portal on the border gap tile, leaving to the neighbor }
  np := Length(m.portals);
  SetLength(m.portals, np + 1);
  m.portals[np].x := gapX;
  m.portals[np].y := gapY;
  m.portals[np].kind := PK_FLAT;
  if (layer = 'W') and PinnedAt(ncx, ncy, pin, arr) then begin
    m.portals[np].target := pin;
    m.portals[np].marker := arr;
  end else begin
    if layer = 'S' then m.portals[np].target := DepthsName(ncx, ncy)
    else m.portals[np].target := CellName(ncx, ncy);
    case arriveName of   { leave by one edge, arrive at the opposite one }
      'edgeN': m.portals[np].marker := 'edgeS';
      'edgeS': m.portals[np].marker := 'edgeN';
      'edgeW': m.portals[np].marker := 'edgeE';
    else       m.portals[np].marker := 'edgeW';
    end;
  end;
end;

function GenerateOverworldCell(cx, cy: longint; seed: longword): TMapData;
const
  W = 24; H = 24;
var
  r: TRng;
  g: TGrid;
  i, j, n, bx, by, mx, my, biome, wallTile, np: longint;
  m: TMapData;
begin
  gw := W; gh := H;
  mx := W div 2; my := H div 2;
  SetLength(g, gw * gh);
  RngSeed(r, seed);
  biome := BiomeAt(cx, cy);
  wallTile := BiomeWallTile(biome);

  for i := 0 to gw * gh - 1 do g[i] := 0;   { open ground }
  Borders(g);

  { scattered obstacle clusters, density by biome }
  n := BiomeDensity(biome);
  for i := 1 to n do begin
    bx := 2 + RngRange(r, 0, gw - 5);
    by := 2 + RngRange(r, 0, gh - 5);
    for j := 0 to RngRange(r, 1, 4) do
      SetAt(g, Min(gw - 2, bx + RngRange(r, 0, 2)),
               Min(gh - 2, by + RngRange(r, 0, 2)), wallTile);
  end;

  { keep the center and routes to every edge clear }
  SetAt(g, mx, my, 0);
  CarveLine(g, mx, my, mx, 1);
  CarveLine(g, mx, my, mx, gh - 2);
  CarveLine(g, mx, my, 1, my);
  CarveLine(g, mx, my, gw - 2, my);

  m.w := gw; m.h := gh;
  m.tileset := 0; m.music := 0; m.flags := MAP_SURFACE;
  m.markers := nil; m.portals := nil;
  m.doors := nil; m.npcs := nil; m.traps := nil; m.lights := nil; m.props := nil;

  { centre spawn, used on first entry from a pinned zone's gate }
  SetLength(m.markers, 1);
  m.markers[0].name := 'start';
  m.markers[0].x := mx; m.markers[0].y := my; m.markers[0].dir := DIR_E;

  EdgeLink(m, g, 'W', cx,     cy - 1, mx, 0,      mx, 1,      'edgeN', DIR_S);
  EdgeLink(m, g, 'W', cx,     cy + 1, mx, gh - 1, mx, gh - 2, 'edgeS', DIR_N);
  EdgeLink(m, g, 'W', cx - 1, cy,     0,  my,     1,  my,     'edgeW', DIR_E);
  EdgeLink(m, g, 'W', cx + 1, cy,     gw - 1, my, gw - 2, my, 'edgeE', DIR_W);

  { a cave mouth down into the dungeon beneath this cell, on some cells }
  if HasDungeon(cx, cy) then begin
    bx := mx + 4; by := my + 3;
    if bx > gw - 2 then bx := gw - 2;
    if by > gh - 2 then by := gh - 2;
    CarveLine(g, mx, my, bx, by);
    np := Length(m.portals);
    SetLength(m.portals, np + 1);
    m.portals[np].x := bx; m.portals[np].y := by;
    m.portals[np].target := DungeonName(cx, cy, 1);
    m.portals[np].marker := 'uparr';
    m.portals[np].kind := PK_CAVE;
  end;

  { a building to enter, on some cells: a door-portal into its interior,
    with a return marker beside it so stepping out does not re-enter }
  if HasBuilding(cx, cy) then begin
    bx := mx - 4; by := my + 3;
    if bx < 1 then bx := 1;
    if by > gh - 2 then by := gh - 2;
    CarveLine(g, mx, my, bx, by);
    np := Length(m.portals);
    SetLength(m.portals, np + 1);
    m.portals[np].x := bx; m.portals[np].y := by;
    m.portals[np].target := InteriorName(cx, cy, 0);
    m.portals[np].marker := 'entry';
    m.portals[np].kind := PK_DOOR;
    SetLength(m.markers, Length(m.markers) + 1);
    m.markers[High(m.markers)].name := 'door0';
    m.markers[High(m.markers)].x := bx;
    m.markers[High(m.markers)].y := by - 1;
    m.markers[High(m.markers)].dir := DIR_S;
  end;

  SetLength(m.walls, gw * gh);
  for i := 0 to gw * gh - 1 do m.walls[i] := g[i];

  GenerateOverworldCell := m;
end;

function ThemeWall(theme: longint): longint;
begin
  case theme of
    THEME_CRYPT, THEME_DESERTTOMB: ThemeWall := 1;   { brick and sandstone }
    THEME_CAVE: ThemeWall := 3;                      { mossy cavern }
  else
    ThemeWall := 2;                                  { stone, basalt, flooded }
  end;
end;

{ Place a stair: a portal at (sx,sy) and an arrival marker just beside it
  so arriving does not instantly trigger the return trip. }
procedure AddStair(var m: TMapData; const g: TGrid; sx, sy, kind: longint;
  const target, marker, arriveName: string);
var
  nx, ny, np: longint;
begin
  if not FloorNeighbor(g, sx, sy, nx, ny) then begin nx := sx; ny := sy; end;
  SetLength(m.markers, Length(m.markers) + 1);
  m.markers[High(m.markers)].name := arriveName;
  m.markers[High(m.markers)].x := nx;
  m.markers[High(m.markers)].y := ny;
  m.markers[High(m.markers)].dir := DIR_E;
  np := Length(m.portals);
  SetLength(m.portals, np + 1);
  m.portals[np].x := sx; m.portals[np].y := sy;
  m.portals[np].target := target;
  m.portals[np].marker := marker;
  m.portals[np].kind := kind;
end;

procedure AddLight(var m: TMapData; x, y, kind: longint);
begin
  SetLength(m.lights, Length(m.lights) + 1);
  m.lights[High(m.lights)].x := x;
  m.lights[High(m.lights)].y := y;
  m.lights[High(m.lights)].kind := kind;
end;

{ Place an NPC at a tile. The remaining TNpc fields (sprite, gender) stay at
  their zeroed defaults: the default NPC art and an unspecified gender. }
procedure AddNpc(var m: TMapData; x, y: longint; const dialog, name: string);
begin
  SetLength(m.npcs, Length(m.npcs) + 1);
  m.npcs[High(m.npcs)].x := x;
  m.npcs[High(m.npcs)].y := y;
  m.npcs[High(m.npcs)].dialog := dialog;
  m.npcs[High(m.npcs)].name := name;
  m.npcs[High(m.npcs)].sprite := '';
end;

{ Scatter n lights of a kind on random floor tiles of the grid. }
procedure ScatterLights(var m: TMapData; const g: TGrid; var r: TRng;
  n, kind: longint);
var
  i, x, y: longint;
begin
  for i := 1 to n do begin
    x := RngRange(r, 1, gw - 2);
    y := RngRange(r, 1, gh - 2);
    if At(g, x, y) = 0 then AddLight(m, x, y, kind);
  end;
end;

{ True when the floor tile (x,y) sits at the foot of a straight wall run at
  least three tiles wide: the tile on one side is wall, and so are the two
  that flank it. A stair leans against such a flat back; an open tile with no
  such wall takes a ladder instead. The tile is interior, so x+-1 and y+-1
  stay in range. }
function BacksWideWall(const g: TGrid; x, y: longint): boolean;
begin
  BacksWideWall := false;
  if At(g, x, y) <> 0 then exit;
  if (At(g, x, y - 1) <> 0) and (At(g, x - 1, y - 1) <> 0)
    and (At(g, x + 1, y - 1) <> 0) then begin BacksWideWall := true; exit; end;
  if (At(g, x, y + 1) <> 0) and (At(g, x - 1, y + 1) <> 0)
    and (At(g, x + 1, y + 1) <> 0) then begin BacksWideWall := true; exit; end;
  if (At(g, x - 1, y) <> 0) and (At(g, x - 1, y - 1) <> 0)
    and (At(g, x - 1, y + 1) <> 0) then begin BacksWideWall := true; exit; end;
  if (At(g, x + 1, y) <> 0) and (At(g, x + 1, y - 1) <> 0)
    and (At(g, x + 1, y + 1) <> 0) then begin BacksWideWall := true; exit; end;
end;

{ True when the floor tile stands clear of walls: it and all eight neighbors
  are open, so it sits in the middle of a room or cavern where a ladder fits.
  The tile is interior, so the neighbor reads stay in range. }
function OpenMiddle(const g: TGrid; x, y: longint): boolean;
begin
  OpenMiddle :=
    (At(g, x, y) = 0)
    and (At(g, x - 1, y) = 0) and (At(g, x + 1, y) = 0)
    and (At(g, x, y - 1) = 0) and (At(g, x, y + 1) = 0)
    and (At(g, x - 1, y - 1) = 0) and (At(g, x + 1, y - 1) = 0)
    and (At(g, x - 1, y + 1) = 0) and (At(g, x + 1, y + 1) = 0);
end;

{ Breadth-first from the anchor over connected floor, out to `radius` steps,
  for the nearest tile matching the wanted shape: an open middle (for a
  ladder) or the foot of a wide wall (for stairs). Staying on connected floor
  keeps the relocated exit linked to the anchor. False when none is near. }
function SnapNearest(const g: TGrid; ax, ay, radius: longint; wantOpen: boolean;
  out sx, sy: longint): boolean;
const
  dx4: array[0 .. 3] of longint = (1, -1, 0, 0);
  dy4: array[0 .. 3] of longint = (0, 0, 1, -1);
var
  qx, qy, qd: array of longint;
  seen: array of boolean;
  head, tail, cx, cy, cd, k, nxx, nyy: longint;
  hit: boolean;
begin
  SnapNearest := false;
  SetLength(seen, gw * gh);
  SetLength(qx, gw * gh); SetLength(qy, gw * gh); SetLength(qd, gw * gh);
  head := 0; tail := 0;
  qx[tail] := ax; qy[tail] := ay; qd[tail] := 0; inc(tail);
  seen[ay * gw + ax] := true;
  while head < tail do begin
    cx := qx[head]; cy := qy[head]; cd := qd[head]; inc(head);
    if wantOpen then hit := OpenMiddle(g, cx, cy)
    else hit := BacksWideWall(g, cx, cy);
    if hit then begin
      sx := cx; sy := cy; SnapNearest := true; exit;
    end;
    if cd >= radius then continue;
    for k := 0 to 3 do begin
      nxx := cx + dx4[k]; nyy := cy + dy4[k];
      if (nxx < 0) or (nyy < 0) or (nxx >= gw) or (nyy >= gh) then continue;
      if seen[nyy * gw + nxx] then continue;
      if At(g, nxx, nyy) <> 0 then continue;
      seen[nyy * gw + nxx] := true;
      qx[tail] := nxx; qy[tail] := nyy; qd[tail] := cd + 1; inc(tail);
    end;
  end;
end;

{ Place a vertical exit near its anchor, choosing its form from the ground it
  can reach. When preferLadder is set the exit looks first for an open room or
  cavern interior and stands there as a ladder; otherwise it looks first for
  the foot of a wide wall and reads as stairs. Each falls back to the other
  shape, then to the anchor as stairs. The way up favors a staircase on the
  entrance wall; the way down favors a ladder in an open chamber. The final
  tile is returned so its landing can be lit. }
procedure PlaceVerticalExit(var m: TMapData; const g: TGrid;
  ax, ay, stairKind: longint; preferLadder: boolean;
  const target, marker, arrive: string; out fx, fy: longint);
var
  kind: longint;
begin
  kind := stairKind; fx := ax; fy := ay;
  if preferLadder then begin
    if SnapNearest(g, ax, ay, LADDER_SNAP, true, fx, fy) then
      kind := PK_LADDER
    else if SnapNearest(g, ax, ay, STAIR_SNAP, false, fx, fy) then
      kind := stairKind;
  end else begin
    if SnapNearest(g, ax, ay, STAIR_SNAP, false, fx, fy) then
      kind := stairKind
    else if SnapNearest(g, ax, ay, LADDER_SNAP, true, fx, fy) then
      kind := PK_LADDER;
  end;
  AddStair(m, g, fx, fy, kind, target, marker, arrive);
end;

function GenerateDungeonLevel(cx, cy, depth: longint; seed: longword): TMapData;
const
  W = 28; H = 28;
var
  r: TRng;
  g: TGrid;
  m: TMapData;
  i, theme, wallTile, usx, usy, dsx, dsy, reach, nx, ny: longint;
  upx, upy, dnx, dny: longint;
  pin, arr, upTarget, upMarker, downTarget: string;
begin
  gw := W; gh := H;
  SetLength(g, gw * gh);
  RngSeed(r, seed);
  theme := BiomeTheme(BiomeAt(cx, cy));
  wallTile := ThemeWall(theme);

  case theme of
    THEME_CAVE, THEME_UNDERWATER: GenCave(g, r);
  else
    GenRooms(g, r, depth);
  end;

  if not FirstFloor(g, usx, usy) then begin
    usx := gw div 2; usy := gh div 2;
    SetAt(g, usx, usy, 0); SetAt(g, usx + 1, usy, 0);
  end;
  FloodFarthest(g, usx, usy, dsx, dsy, reach);

  m.w := gw; m.h := gh;
  m.tileset := 0; m.music := 0; m.flags := 0;
  m.markers := nil; m.portals := nil;
  m.doors := nil; m.npcs := nil; m.traps := nil; m.lights := nil; m.props := nil;

  { the way up: to the level above, or to the surface at depth 1 }
  if depth <= 1 then begin
    if PinnedAt(cx, cy, pin, arr) then begin upTarget := pin; upMarker := arr; end
    else begin upTarget := CellName(cx, cy); upMarker := 'start'; end;
  end else begin
    upTarget := DungeonName(cx, cy, depth - 1);
    upMarker := 'downarr';
  end;
  PlaceVerticalExit(m, g, usx, usy, PK_UP, false, upTarget, upMarker, 'uparr',
    upx, upy);

  { the way down: deeper, or into the Sunless Depths at the threshold }
  if depth >= SUNLESS_DEPTH then
    downTarget := DepthsName(cx, cy)
  else
    downTarget := DungeonName(cx, cy, depth + 1);
  PlaceVerticalExit(m, g, dsx, dsy, PK_DOWN, true, downTarget, 'uparr',
    'downarr', dnx, dny);

  { natural underground light: bioluminescence and small gas vents }
  ScatterLights(m, g, r, 3 + RngRange(r, 0, 3), LIGHT_BIOLUME);
  ScatterLights(m, g, r, 1 + RngRange(r, 0, 2), LIGHT_GASVENT);
  { a torch-lit landing at the way up, a brazier if this is a tomb }
  if FloorNeighbor(g, upx, upy, nx, ny) then AddLight(m, nx, ny, LIGHT_TORCH);
  if (theme = THEME_CRYPT) or (theme = THEME_DESERTTOMB) then
    if FloorNeighbor(g, dnx, dny, nx, ny) then AddLight(m, nx, ny, LIGHT_BRAZIER);

  SetLength(m.walls, gw * gh);
  for i := 0 to gw * gh - 1 do
    if g[i] = 0 then m.walls[i] := 0 else m.walls[i] := wallTile;

  GenerateDungeonLevel := m;
end;

function GenerateDepthsCell(cx, cy: longint; seed: longword): TMapData;
const
  W = 28; H = 28;
var
  r: TRng;
  g: TGrid;
  m: TMapData;
  i, mx, my, nx, ny, gy: longint;
begin
  gw := W; gh := H;
  mx := gw div 2; my := gh div 2;
  SetLength(g, gw * gh);
  RngSeed(r, seed);
  GenCave(g, r);
  Borders(g);
  SetAt(g, mx, my, 0);

  m.w := gw; m.h := gh;
  m.tileset := 0; m.music := 0; m.flags := 0;
  m.markers := nil; m.portals := nil;
  m.doors := nil; m.npcs := nil; m.traps := nil; m.lights := nil; m.props := nil;

  { the way back up to the dungeon that opened into the Depths }
  AddStair(m, g, mx, my, PK_UP, DungeonName(cx, cy, SUNLESS_DEPTH),
    'downarr', 'uparr');

  { the Depths span the world: each edge opens into the neighbor cavern }
  CarveLine(g, mx, my, mx, 1);
  CarveLine(g, mx, my, mx, gh - 2);
  CarveLine(g, mx, my, 1, my);
  CarveLine(g, mx, my, gw - 2, my);
  EdgeLink(m, g, 'S', cx,     cy - 1, mx, 0,      mx, 1,      'edgeN', DIR_S);
  EdgeLink(m, g, 'S', cx,     cy + 1, mx, gh - 1, mx, gh - 2, 'edgeS', DIR_N);
  EdgeLink(m, g, 'S', cx - 1, cy,     0,  my,     1,  my,     'edgeW', DIR_E);
  EdgeLink(m, g, 'S', cx + 1, cy,     gw - 1, my, gw - 2, my, 'edgeE', DIR_W);

  { a Depths settlement by the stair up: a bonfire with biolume beyond }
  if FloorNeighbor(g, mx, my, nx, ny) then AddLight(m, nx, ny, LIGHT_BONFIRE);
  ScatterLights(m, g, r, 6, LIGHT_BIOLUME);
  ScatterLights(m, g, r, 3, LIGHT_GASVENT);

  { the capstone: the sealed gate to the lost cities, set ahead of the
    landing along the north corridor the carvers always open }
  gy := my - 2;
  if (gy >= 1) and (At(g, mx, gy) = 0) then
    AddNpc(m, mx, gy, 'DEPTHS', 'City Gate');

  SetLength(m.walls, gw * gh);
  for i := 0 to gw * gh - 1 do
    if g[i] = 0 then m.walls[i] := 0 else m.walls[i] := 2;

  GenerateDepthsCell := m;
end;

function GenerateInterior(cx, cy, idx: longint; seed: longword): TMapData;
var
  r: TRng;
  g: TGrid;
  m: TMapData;
  i, mx: longint;
begin
  { idx distinguishes several buildings on one cell, so each gets a
    different interior from the same cell seed }
  RngSeed(r, seed xor (longword(idx + 1) * longword($9e3779b1)));
  gw := 9 + RngRange(r, 0, 4) * 2;    { odd widths 9..17 }
  gh := 7 + RngRange(r, 0, 2) * 2;    { odd heights 7..11 }
  mx := gw div 2;
  SetLength(g, gw * gh);

  for i := 0 to gw * gh - 1 do g[i] := 0;   { one open room }
  Borders(g);

  m.w := gw; m.h := gh;
  m.tileset := 0; m.music := 0; m.flags := 0;   { indoors, lamp-lit, no sky }
  m.markers := nil; m.portals := nil;
  m.doors := nil; m.npcs := nil; m.traps := nil; m.lights := nil; m.props := nil;

  { the door back out to the surface cell this building stands on }
  AddStair(m, g, mx, gh - 2, PK_DOOR, CellName(cx, cy), 'door0', 'entry');

  { a hearth so the room is not pitch dark }
  AddLight(m, 1, 1, LIGHT_TORCH);
  if gw >= 11 then AddLight(m, gw - 2, 1, LIGHT_TORCH);

  SetLength(m.walls, gw * gh);
  for i := 0 to gw * gh - 1 do
    if g[i] = 0 then m.walls[i] := 0 else m.walls[i] := 1;   { brick }

  GenerateInterior := m;
end;

{ True if some portal already sits on tile (x,y). }
function PortalOnTile(const m: TMapData; x, y: longint): boolean;
var i: longint;
begin
  PortalOnTile := false;
  for i := 0 to High(m.portals) do
    if (m.portals[i].x = x) and (m.portals[i].y = y) then begin
      PortalOnTile := true; exit;
    end;
end;

function AddWildernessExit(var m: TMapData; cx, cy: longint): boolean;
{** Give a pinned zone a back door into the wilderness. The zone is
  entered from the wilderness at its start marker (the neighbor cells
  already link inward), but without this it can only be left toward the
  town hub. This adds one portal, on a floor tile reachable from the
  start, that leaves into the first open neighbor cell. Placement is
  derived from the map, so it is the same every load and survives a
  save. A zone that already leaves to a cell is left alone. }
const
  dx: array[0 .. 3] of longint = (0, 1, 0, -1);
  dy: array[0 .. 3] of longint = (-1, 0, 1, 0);
var
  i, nx, ny, np, sx, sy, x, y, bx, by, best, head, tail, d, px, py: longint;
  arriveMarker, pin, arr: string;
  dumX, dumY, kind: longint;
  haveNeighbor: boolean;
  dist, qx, qy: array of longint;
begin
  AddWildernessExit := false;

  { already two-way if any portal leaves to a generated cell }
  for i := 0 to High(m.portals) do
    if ParseCellName(m.portals[i].target, dumX, dumY) then exit;

  { first in-world, non-pinned neighbor: south, east, west, then north }
  haveNeighbor := false; nx := cx; ny := cy; arriveMarker := 'edgeN';
  if (cy + 1 < OW_SIZE) and not PinnedAt(cx, cy + 1, pin, arr) then begin
    nx := cx; ny := cy + 1; arriveMarker := 'edgeN'; haveNeighbor := true;
  end else if (cx + 1 < OW_SIZE) and not PinnedAt(cx + 1, cy, pin, arr) then begin
    nx := cx + 1; ny := cy; arriveMarker := 'edgeW'; haveNeighbor := true;
  end else if (cx - 1 >= 0) and not PinnedAt(cx - 1, cy, pin, arr) then begin
    nx := cx - 1; ny := cy; arriveMarker := 'edgeE'; haveNeighbor := true;
  end else if (cy - 1 >= 0) and not PinnedAt(cx, cy - 1, pin, arr) then begin
    nx := cx; ny := cy - 1; arriveMarker := 'edgeS'; haveNeighbor := true;
  end;
  if not haveNeighbor then exit;

  { the tile the party enters on: the start or spawn marker }
  sx := -1; sy := -1;
  for i := 0 to High(m.markers) do
    if (m.markers[i].name = 'start') or (m.markers[i].name = 'spawn') then begin
      sx := m.markers[i].x; sy := m.markers[i].y; break;
    end;
  if sx < 0 then
    for y := 0 to m.h - 1 do
      for x := 0 to m.w - 1 do
        if (sx < 0) and (m.walls[y * m.w + x] = 0) then begin sx := x; sy := y; end;
  if sx < 0 then exit;

  { flood the floor from the start; host the exit on the farthest reachable
    tile that is open and does not already carry a portal }
  SetLength(dist, m.w * m.h);
  for i := 0 to m.w * m.h - 1 do dist[i] := -1;
  SetLength(qx, m.w * m.h); SetLength(qy, m.w * m.h);
  head := 0; tail := 0;
  dist[sy * m.w + sx] := 0; qx[0] := sx; qy[0] := sy; inc(tail);
  bx := -1; by := -1; best := -1;
  while head < tail do begin
    x := qx[head]; y := qy[head]; inc(head);
    d := dist[y * m.w + x];
    if (d > best) and not ((x = sx) and (y = sy)) and not PortalOnTile(m, x, y) then begin
      best := d; bx := x; by := y;
    end;
    for i := 0 to 3 do begin
      px := x + dx[i]; py := y + dy[i];
      if (px < 0) or (px >= m.w) or (py < 0) or (py >= m.h) then continue;
      if m.walls[py * m.w + px] <> 0 then continue;
      if dist[py * m.w + px] >= 0 then continue;
      dist[py * m.w + px] := d + 1;
      qx[tail] := px; qy[tail] := py; inc(tail);
    end;
  end;
  if bx < 0 then exit;

  { an outdoor zone steps out flat; an underground one climbs to the surface }
  if (m.flags and MAP_SURFACE) <> 0 then kind := PK_FLAT else kind := PK_UP;

  np := Length(m.portals);
  SetLength(m.portals, np + 1);
  m.portals[np].x := bx; m.portals[np].y := by;
  m.portals[np].target := CellName(nx, ny);
  m.portals[np].marker := arriveMarker;
  m.portals[np].kind := kind;
  AddWildernessExit := true;
end;

end.
