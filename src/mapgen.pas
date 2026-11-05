unit mapgen;

{** Roguelike map generation for dynamic maps.

  A dynamic map is built from a seed, so it regenerates identically from
  the (version, seed) pair stored in the save. Three generators are
  provided: rooms-and-corridors, a cellular-automata cave and a maze.
  Each result has a start marker, a matching back marker and an exit
  portal to the map that linked here, placed so it is always reachable
  from the start (verified by a flood fill). }

{$mode objfpc}{$H+}

interface

uses
  rng, mapfmt, worldfmt;

const
  GEN_VERSION = 1;   { bump when a generator changes to invalidate old seeds }

function GenerateMap(const d: TDynMap; version: longint; seed: longword): TMapData;
function GenerateOverworldCell(cx, cy: longint; seed: longword): TMapData;
function GenerateDungeonLevel(cx, cy, depth: longint; seed: longword): TMapData;
function GenerateDepthsCell(cx, cy: longint; seed: longword): TMapData;

implementation

uses
  overworld;

type
  TGrid = array of byte;   { 0 floor, 1 wall, w*h }

var
  gw, gh: longint;

function At(const g: TGrid; x, y: longint): byte; inline;
begin
  At := g[y * gw + x];
end;

procedure SetAt(var g: TGrid; x, y: longint; v: byte); inline;
begin
  g[y * gw + x] := v;
end;

function Min(a, b: longint): longint; begin if a < b then Min := a else Min := b; end;
function Max(a, b: longint): longint; begin if a > b then Max := a else Max := b; end;

procedure Borders(var g: TGrid);
var x, y: longint;
begin
  for x := 0 to gw - 1 do begin SetAt(g, x, 0, 1); SetAt(g, x, gh - 1, 1); end;
  for y := 0 to gh - 1 do begin SetAt(g, 0, y, 1); SetAt(g, gw - 1, y, 1); end;
end;

procedure GenRooms(var g: TGrid; var r: TRng; depth: longint);
var
  i, n, rw, rh, rx, ry, x, y, cx, cy, px, py: longint;
begin
  for i := 0 to gw * gh - 1 do g[i] := 1;
  n := 6 + depth * 2;
  if n > 16 then n := 16;
  px := -1; py := -1;
  for i := 1 to n do begin
    rw := RngRange(r, 3, 7);
    rh := RngRange(r, 3, 6);
    rx := RngRange(r, 1, gw - rw - 2);
    ry := RngRange(r, 1, gh - rh - 2);
    for y := ry to ry + rh - 1 do
      for x := rx to rx + rw - 1 do
        SetAt(g, x, y, 0);
    cx := rx + rw div 2; cy := ry + rh div 2;
    if px >= 0 then begin
      { L-shaped corridor from the previous room centre }
      for x := Min(px, cx) to Max(px, cx) do SetAt(g, x, py, 0);
      for y := Min(py, cy) to Max(py, cy) do SetAt(g, cx, y, 0);
    end;
    px := cx; py := cy;
  end;
  Borders(g);
end;

procedure GenCave(var g: TGrid; var r: TRng);
var
  i, x, y, step, walls: longint;
  ng: TGrid;
begin
  for i := 0 to gw * gh - 1 do
    if RngRange(r, 0, 99) < 45 then g[i] := 1 else g[i] := 0;
  Borders(g);
  SetLength(ng, gw * gh);
  for step := 1 to 4 do begin
    for y := 1 to gh - 2 do
      for x := 1 to gw - 2 do begin
        walls := 0;
        for i := 0 to 8 do
          if (i <> 4) then
            walls := walls + At(g, x + (i mod 3) - 1, y + (i div 3) - 1);
        if walls >= 5 then ng[y * gw + x] := 1 else ng[y * gw + x] := 0;
      end;
    for y := 1 to gh - 2 do
      for x := 1 to gw - 2 do
        SetAt(g, x, y, ng[y * gw + x]);
    Borders(g);
  end;
end;

procedure GenMaze(var g: TGrid; var r: TRng);
var
  i, x, y, cx, cy, dir, nx, ny: longint;
  stackX, stackY: array of longint;
  sp: longint;
  tried: array[0 .. 3] of boolean;
  ntr: longint;
begin
  for i := 0 to gw * gh - 1 do g[i] := 1;
  SetLength(stackX, gw * gh);
  SetLength(stackY, gw * gh);
  cx := 1; cy := 1;
  SetAt(g, cx, cy, 0);
  sp := 0; stackX[0] := cx; stackY[0] := cy;
  while sp >= 0 do begin
    cx := stackX[sp]; cy := stackY[sp];
    tried[0] := false; tried[1] := false; tried[2] := false; tried[3] := false;
    ntr := 0;
    nx := -1; ny := -1;
    while ntr < 4 do begin
      dir := RngRange(r, 0, 3);
      if tried[dir] then begin inc(ntr); continue; end;
      tried[dir] := true; inc(ntr);
      case dir of
        0: begin nx := cx; ny := cy - 2; end;
        1: begin nx := cx + 2; ny := cy; end;
        2: begin nx := cx; ny := cy + 2; end;
      else begin nx := cx - 2; ny := cy; end;
      end;
      if (nx > 0) and (nx < gw - 1) and (ny > 0) and (ny < gh - 1)
         and (At(g, nx, ny) = 1) then begin
        SetAt(g, (cx + nx) div 2, (cy + ny) div 2, 0);
        SetAt(g, nx, ny, 0);
        inc(sp); stackX[sp] := nx; stackY[sp] := ny;
        nx := -2;   { signal advanced }
        break;
      end;
    end;
    if nx <> -2 then
      dec(sp);   { dead end, backtrack }
  end;
  Borders(g);
end;

procedure FloodFarthest(const g: TGrid; sx, sy: longint;
  out ex, ey, reach: longint);
var
  dist: array of longint;
  qx, qy: array of longint;
  head, tail, x, y, i, best: longint;
  nx, ny: longint;
  dx: array[0 .. 3] of longint = (0, 1, 0, -1);
  dy: array[0 .. 3] of longint = (-1, 0, 1, 0);
begin
  SetLength(dist, gw * gh);
  for i := 0 to gw * gh - 1 do dist[i] := -1;
  SetLength(qx, gw * gh);
  SetLength(qy, gw * gh);
  head := 0; tail := 0;
  dist[sy * gw + sx] := 0;
  qx[tail] := sx; qy[tail] := sy; inc(tail);
  ex := sx; ey := sy; best := 0; reach := 1;
  while head < tail do begin
    x := qx[head]; y := qy[head]; inc(head);
    for i := 0 to 3 do begin
      nx := x + dx[i]; ny := y + dy[i];
      if (nx < 0) or (nx >= gw) or (ny < 0) or (ny >= gh) then continue;
      if At(g, nx, ny) <> 0 then continue;
      if dist[ny * gw + nx] >= 0 then continue;
      dist[ny * gw + nx] := dist[y * gw + x] + 1;
      qx[tail] := nx; qy[tail] := ny; inc(tail);
      inc(reach);
      if dist[ny * gw + nx] > best then begin
        best := dist[ny * gw + nx];
        ex := nx; ey := ny;
      end;
    end;
  end;
end;

function FirstFloor(const g: TGrid; out fx, fy: longint): boolean;
var x, y: longint;
begin
  FirstFloor := false;
  for y := 1 to gh - 2 do
    for x := 1 to gw - 2 do
      if At(g, x, y) = 0 then begin fx := x; fy := y; FirstFloor := true; exit; end;
end;

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
  GenerateMap := m;
end;

{ Carve a straight floor corridor between two points (inclusive), L-shaped. }
procedure CarveLine(var g: TGrid; x0, y0, x1, y1: longint);
var x, y: longint;
begin
  x := x0; y := y0;
  while x <> x1 do begin SetAt(g, x, y, 0); if x < x1 then inc(x) else dec(x); end;
  while y <> y1 do begin SetAt(g, x, y, 0); if y < y1 then inc(y) else dec(y); end;
  SetAt(g, x1, y1, 0);
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
  m.doors := nil; m.npcs := nil; m.traps := nil; m.lights := nil;

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

  SetLength(m.walls, gw * gh);
  for i := 0 to gw * gh - 1 do m.walls[i] := g[i];

  GenerateOverworldCell := m;
end;

function FloorNeighbor(const g: TGrid; x, y: longint; out nx, ny: longint): boolean;
begin
  FloorNeighbor := true;
  if (x + 1 < gw) and (At(g, x + 1, y) = 0) then begin nx := x + 1; ny := y; exit; end;
  if (x - 1 >= 0) and (At(g, x - 1, y) = 0) then begin nx := x - 1; ny := y; exit; end;
  if (y + 1 < gh) and (At(g, x, y + 1) = 0) then begin nx := x; ny := y + 1; exit; end;
  if (y - 1 >= 0) and (At(g, x, y - 1) = 0) then begin nx := x; ny := y - 1; exit; end;
  nx := x; ny := y; FloorNeighbor := false;
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

function GenerateDungeonLevel(cx, cy, depth: longint; seed: longword): TMapData;
const
  W = 28; H = 28;
var
  r: TRng;
  g: TGrid;
  m: TMapData;
  i, theme, wallTile, usx, usy, dsx, dsy, reach, nx, ny: longint;
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
  m.doors := nil; m.npcs := nil; m.traps := nil; m.lights := nil;

  { the way up: to the level above, or to the surface at depth 1 }
  if depth <= 1 then begin
    if PinnedAt(cx, cy, pin, arr) then begin upTarget := pin; upMarker := arr; end
    else begin upTarget := CellName(cx, cy); upMarker := 'start'; end;
  end else begin
    upTarget := DungeonName(cx, cy, depth - 1);
    upMarker := 'downarr';
  end;
  AddStair(m, g, usx, usy, PK_UP, upTarget, upMarker, 'uparr');

  { the way down: deeper, or into the Sunless Depths at the threshold }
  if depth >= SUNLESS_DEPTH then
    downTarget := DepthsName(cx, cy)
  else
    downTarget := DungeonName(cx, cy, depth + 1);
  AddStair(m, g, dsx, dsy, PK_DOWN, downTarget, 'uparr', 'downarr');

  { natural underground light: bioluminescence and small gas vents }
  ScatterLights(m, g, r, 3 + RngRange(r, 0, 3), LIGHT_BIOLUME);
  ScatterLights(m, g, r, 1 + RngRange(r, 0, 2), LIGHT_GASVENT);
  { a torch-lit landing at the stairs up, a brazier if this is a tomb }
  if FloorNeighbor(g, usx, usy, nx, ny) then AddLight(m, nx, ny, LIGHT_TORCH);
  if (theme = THEME_CRYPT) or (theme = THEME_DESERTTOMB) then
    if FloorNeighbor(g, dsx, dsy, nx, ny) then AddLight(m, nx, ny, LIGHT_BRAZIER);

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
  i, mx, my, nx, ny: longint;
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
  m.doors := nil; m.npcs := nil; m.traps := nil; m.lights := nil;

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

  SetLength(m.walls, gw * gh);
  for i := 0 to gw * gh - 1 do
    if g[i] = 0 then m.walls[i] := 0 else m.walls[i] := 2;

  GenerateDepthsCell := m;
end;

end.
