program t_pursuit;

{** Monster pursuit: a hunter steps toward the party each tick, across maps
  through portals, and catches them on contact. Driven by a test provider
  over hand-built maps, so no pak or live world is needed. }

{$mode objfpc}{$H+}

uses
  mapfmt, pathfind, maproute, pursuit, testing;

procedure BuildMap(out m: TMapData; const rows: array of string);
var
  y, x: longint;
begin
  m.w := Length(rows[0]);
  m.h := Length(rows);
  m.tileset := 0; m.music := 0; m.flags := 0; m.area := 0;
  m.markers := nil; m.portals := nil; m.doors := nil;
  m.npcs := nil; m.traps := nil; m.lights := nil; m.props := nil;
  SetLength(m.walls, m.w * m.h);
  for y := 0 to m.h - 1 do
    for x := 0 to m.w - 1 do
      if rows[y][x + 1] = '#' then
        m.walls[y * m.w + x] := 1
      else
        m.walls[y * m.w + x] := TILE_EMPTY;
end;

procedure AddPortal(var m: TMapData; x, y: longint; const target, marker: string);
var i: longint;
begin
  i := Length(m.portals);
  SetLength(m.portals, i + 1);
  m.portals[i].x := x; m.portals[i].y := y;
  m.portals[i].target := target; m.portals[i].marker := marker;
  m.portals[i].kind := 0;
end;

procedure AddMarker(var m: TMapData; const name: string; x, y: longint);
var i: longint;
begin
  i := Length(m.markers);
  SetLength(m.markers, i + 1);
  m.markers[i].name := name;
  m.markers[i].x := x; m.markers[i].y := y; m.markers[i].dir := 0;
end;

type
  TEntry = record name: string; m: TMapData; end;
var
  Maps: array of TEntry;

procedure Register(const name: string; const m: TMapData);
var i: longint;
begin
  i := Length(Maps);
  SetLength(Maps, i + 1);
  Maps[i].name := name; Maps[i].m := m;
end;

function TableProvider(const name: string; out m: TMapData): boolean;
var i: longint;
begin
  TableProvider := false;
  for i := 0 to High(Maps) do
    if Maps[i].name = name then begin m := Maps[i].m; TableProvider := true; exit; end;
end;

{ Advance pursuers until one catches the party or the step budget runs out.
  Returns the catching pursuer index, or -1. }
function RunChase(const partyMap: string; px, py, limit: longint): longint;
var n, r: longint;
begin
  RunChase := -1;
  for n := 1 to limit do begin
    r := AdvanceOver(partyMap, px, py, @TableProvider, ROUTE_MAX_STATES);
    if r >= 0 then begin RunChase := r; exit; end;
  end;
end;

var
  a, b, c: TMapData;
  idx: longint;
begin
  { bookkeeping. }
  PursuitReset;
  CheckEqI(ActivePursuerCount, 0, 'starts with no hunters');
  AddPursuer(7, 'A', 0, 0);
  AddPursuer(3, 'A', 1, 0);
  CheckEqI(ActivePursuerCount, 2, 'two hunters added');
  Check(HunterOnMap('A'), 'a hunter is on map A');
  Check(not HunterOnMap('Z'), 'no hunter on an empty map');
  RemovePursuer(0);
  CheckEqI(ActivePursuerCount, 1, 'removing drops the count');
  PursuitClear;
  CheckEqI(ActivePursuerCount, 0, 'clear drops them all');

  { same-map chase: a hunter closes along an open corridor. }
  BuildMap(a, ['.....']);
  Register('A', a);
  PursuitReset;
  AddPursuer(0, 'A', 0, 0);
  CheckEqI(AdvanceOver('A', 4, 0, @TableProvider, ROUTE_MAX_STATES), -1,
    'not caught yet at distance four');
  Check((Pursuers[0].x = 1) and (Pursuers[0].y = 0), 'hunter stepped closer');
  idx := RunChase('A', 4, 0, 10);
  CheckEqI(idx, 0, 'the hunter catches the party on the same map');

  { already adjacent: caught before moving. }
  PursuitReset;
  AddPursuer(0, 'A', 3, 0);
  CheckEqI(AdvanceOver('A', 4, 0, @TableProvider, ROUTE_MAX_STATES), 0,
    'an adjacent hunter has already caught them');

  { cross-map pursuit: the hunter is on A, the party on B through a portal. }
  Maps := nil;
  BuildMap(a, ['.....']);
  AddPortal(a, 4, 0, 'B', 'in');
  BuildMap(b, ['.....']);
  AddMarker(b, 'in', 0, 0);
  Register('A', a); Register('B', b);
  PursuitReset;
  AddPursuer(0, 'A', 0, 0);
  idx := RunChase('B', 4, 0, 30);
  CheckEqI(idx, 0, 'the hunter follows through the portal and catches them');
  Check(Pursuers[0].map = 'B', 'the hunter crossed onto the party map');

  { walled off: no path, so the hunter never catches them and holds still. }
  Maps := nil;
  BuildMap(c, ['..#..']);
  Register('C', c);
  PursuitReset;
  AddPursuer(0, 'C', 0, 0);
  CheckEqI(RunChase('C', 4, 0, 20), -1, 'a walled-off hunter never catches up');
  Check((Pursuers[0].x = 0) and (Pursuers[0].y = 0), 'the blocked hunter holds');

  TestSummary('pursuit');
  halt(TestExit);
end.
