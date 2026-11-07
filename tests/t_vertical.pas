program t_vertical;

{** Vertical space: dungeon names, stair stacking to depth 30, the
  Sunless Depths connection, and stair reachability. }

{$mode objfpc}{$H+}

uses
  sysutils, overworld, worldname, mapfmt, mapgen, testing;

const
  CX = 511; CY = 511;

function Reaches(const m: TMapData; sx, sy, tx, ty: longint): boolean;
var
  seen: array of boolean;
  st: array of longint;
  sp, idx, x, y, i: longint;
  function Fl(ix, iy: longint): boolean;
  begin
    Fl := (ix >= 0) and (ix < m.w) and (iy >= 0) and (iy < m.h)
      and (m.walls[iy * m.w + ix] = 0);
  end;
  procedure Push(ix, iy: longint);
  begin
    if Fl(ix, iy) and (not seen[iy * m.w + ix]) then begin
      seen[iy * m.w + ix] := true; st[sp] := iy * m.w + ix; inc(sp);
    end;
  end;
begin
  SetLength(seen, m.w * m.h); SetLength(st, m.w * m.h);
  for i := 0 to m.w * m.h - 1 do seen[i] := false;
  sp := 0; Push(sx, sy);
  while sp > 0 do begin
    dec(sp); idx := st[sp]; x := idx mod m.w; y := idx div m.w;
    Push(x + 1, y); Push(x - 1, y); Push(x, y + 1); Push(x, y - 1);
  end;
  Reaches := Fl(tx, ty) and seen[ty * m.w + tx];
end;

{ Find the first portal of a kind. }
function FindPortal(const m: TMapData; kind: longint;
  out px, py: longint; out tgt: string): boolean;
var i: longint;
begin
  FindPortal := false;
  for i := 0 to High(m.portals) do
    if m.portals[i].kind = kind then begin
      px := m.portals[i].x; py := m.portals[i].y; tgt := m.portals[i].target;
      FindPortal := true; exit;
    end;
end;

{ Find the vertical exit leading deeper (wantDown) or shallower, by its
  target rather than its kind: a staircase and a ladder are both valid
  connectors, and only the target records which way the exit leads. }
function FindVertical(const m: TMapData; depth: longint; wantDown: boolean;
  out px, py: longint; out tgt: string): boolean;
var
  i, tcx, tcy, tdep: longint;
  isDown: boolean;
begin
  FindVertical := false;
  for i := 0 to High(m.portals) do begin
    isDown := ((depth >= SUNLESS_DEPTH)
        and (m.portals[i].target = DepthsName(CX, CY)))
      or (ParseDungeonName(m.portals[i].target, tcx, tcy, tdep)
        and (tdep = depth + 1));
    if isDown = wantDown then begin
      px := m.portals[i].x; py := m.portals[i].y;
      tgt := m.portals[i].target;
      FindVertical := true; exit;
    end;
  end;
end;

var
  cx2, cy2, dep, depth, ux, uy, dx, dy, edges, i: longint;
  m: TMapData;
  tgt: string;
  allVert: boolean;
begin
  allVert := true;
  { names }
  Check(DungeonName(CX, CY, 7) = 'D511_511_7', 'DungeonName format');
  Check(ParseDungeonName('D511_511_30', cx2, cy2, dep)
    and (cx2 = CX) and (cy2 = CY) and (dep = 30), 'ParseDungeonName round trip');
  Check(not ParseDungeonName('W1_2', cx2, cy2, dep), 'reject cell name as dungeon');
  Check(ParseDepthsName('S511_511', cx2, cy2), 'ParseDepthsName');

  { the overworld cell we test has a dungeon entrance }
  Check(HasDungeon(CX, CY), 'test cell has a dungeon');

  { every level 1..30 has a way up and a way down, both reachable. The
    exits may be stairs or ladders, so they are found by target not kind. }
  for depth := 1 to 30 do begin
    m := GenerateDungeonLevel(CX, CY, depth, CellSeed(CX, CY, depth));
    if not (FindVertical(m, depth, false, ux, uy, tgt)
        and FindVertical(m, depth, true, dx, dy, tgt)) then begin
      Check(false, 'depth ' + IntToStr(depth) + ' has both exits');
      continue;
    end;
    if not Reaches(m, ux, uy, dx, dy) then
      Check(false, 'depth ' + IntToStr(depth) + ' exits connected');
    for i := 0 to High(m.portals) do
      if not (m.portals[i].kind in [PK_UP, PK_DOWN, PK_LADDER]) then
        allVert := false;
  end;
  Check(true, 'all 30 levels have connected exits');
  Check(allVert, 'every exit is a staircase or a ladder');

  { depth 30 descends into the Sunless Depths }
  m := GenerateDungeonLevel(CX, CY, 30, CellSeed(CX, CY, 30));
  FindVertical(m, 30, true, dx, dy, tgt);
  Check(tgt = DepthsName(CX, CY), 'depth 30 opens into the Depths');

  { the Depths cell links back up and edge-links to neighbors }
  m := GenerateDepthsCell(CX, CY, CellSeed(CX, CY, SUNLESS_DEPTH + 1));
  Check(FindPortal(m, PK_UP, ux, uy, tgt), 'Depths has a stair up');
  Check(tgt = DungeonName(CX, CY, SUNLESS_DEPTH), 'Depths up returns to depth 30');
  Check((m.flags and MAP_SURFACE) = 0, 'Depths is underground');
  edges := 0;
  for i := 0 to High(m.portals) do
    if m.portals[i].kind = PK_FLAT then inc(edges);
  Check(edges = 4, 'Depths cell has four world-spanning edges');

  TestSummary('vertical');
  halt(TestExit);
end.
