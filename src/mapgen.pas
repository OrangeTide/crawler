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

{ One edge of an overworld cell: fill in its gap, arrival marker and the
  portal that leaves toward the neighbor, unless that neighbor is off the
  world. Pinned neighbors are entered by their authored name and marker. }
procedure EdgeLink(var m: TMapData; var g: TGrid;
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
  if PinnedAt(ncx, ncy, pin, arr) then begin
    m.portals[np].target := pin;
    m.portals[np].marker := arr;
  end else begin
    m.portals[np].target := CellName(ncx, ncy);
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
  i, j, n, bx, by, mx, my, biome, wallTile: longint;
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
  m.tileset := 0; m.music := 0; m.flags := 0;
  m.markers := nil; m.portals := nil;
  m.doors := nil; m.npcs := nil; m.traps := nil;

  { centre spawn, used on first entry from a pinned zone's gate }
  SetLength(m.markers, 1);
  m.markers[0].name := 'start';
  m.markers[0].x := mx; m.markers[0].y := my; m.markers[0].dir := DIR_E;

  EdgeLink(m, g, cx,     cy - 1, mx, 0,      mx, 1,      'edgeN', DIR_S);
  EdgeLink(m, g, cx,     cy + 1, mx, gh - 1, mx, gh - 2, 'edgeS', DIR_N);
  EdgeLink(m, g, cx - 1, cy,     0,  my,     1,  my,     'edgeW', DIR_E);
  EdgeLink(m, g, cx + 1, cy,     gw - 1, my, gw - 2, my, 'edgeE', DIR_W);

  SetLength(m.walls, gw * gh);
  for i := 0 to gw * gh - 1 do m.walls[i] := g[i];

  GenerateOverworldCell := m;
end;

end.
