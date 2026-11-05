unit gridgen;

{** Grid toolkit for map generation.

  A plain byte grid (0 floor, nonzero wall) plus the carving algorithms
  that fill it: rooms-and-corridors, a cellular-automata cave and a maze,
  with small helpers for borders, flood reach and neighbor lookups. This
  layer knows nothing of the map format; mapgen turns a carved grid into
  a TMapData. The current grid dimensions live in gw/gh, set by the caller
  before carving, matching the existing module-global idiom. }

{$mode objfpc}{$H+}

interface

uses
  rng;

type
  TGrid = array of byte;   { 0 floor, nonzero wall, w*h row major }

var
  gw, gh: longint;         { current grid dimensions }

function At(const g: TGrid; x, y: longint): byte; inline;
procedure SetAt(var g: TGrid; x, y: longint; v: byte); inline;
function Min(a, b: longint): longint;
function Max(a, b: longint): longint;
procedure Borders(var g: TGrid);
function FirstFloor(const g: TGrid; out fx, fy: longint): boolean;
function FloorNeighbor(const g: TGrid; x, y: longint; out nx, ny: longint): boolean;
procedure CarveLine(var g: TGrid; x0, y0, x1, y1: longint);
procedure FloodFarthest(const g: TGrid; sx, sy: longint;
  out ex, ey, reach: longint);
procedure GenRooms(var g: TGrid; var r: TRng; depth: longint);
procedure GenCave(var g: TGrid; var r: TRng);
procedure GenMaze(var g: TGrid; var r: TRng);

implementation

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

function FloorNeighbor(const g: TGrid; x, y: longint; out nx, ny: longint): boolean;
begin
  FloorNeighbor := true;
  if (x + 1 < gw) and (At(g, x + 1, y) = 0) then begin nx := x + 1; ny := y; exit; end;
  if (x - 1 >= 0) and (At(g, x - 1, y) = 0) then begin nx := x - 1; ny := y; exit; end;
  if (y + 1 < gh) and (At(g, x, y + 1) = 0) then begin nx := x; ny := y + 1; exit; end;
  if (y - 1 >= 0) and (At(g, x, y - 1) = 0) then begin nx := x; ny := y - 1; exit; end;
  nx := x; ny := y; FloorNeighbor := false;
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

end.
