program t_maproute;

{** Cross-map routing: a breadth-first search over portal-linked maps, with
  each intra-map leg solved by the single-map A*. The maps here are built in
  memory and handed to RouteOver by a test provider, so the search is
  exercised with no pak and no live world. }

{$mode objfpc}{$H+}

uses
  mapfmt, pathfind, maproute, testing;

{ Build a map from equal-length row strings: '.' open, '#' wall. }
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
var
  i: longint;
begin
  i := Length(m.portals);
  SetLength(m.portals, i + 1);
  m.portals[i].x := x; m.portals[i].y := y;
  m.portals[i].target := target;
  m.portals[i].marker := marker;
  m.portals[i].kind := 0;
end;

procedure AddMarker(var m: TMapData; const name: string; x, y: longint);
var
  i: longint;
begin
  i := Length(m.markers);
  SetLength(m.markers, i + 1);
  m.markers[i].name := name;
  m.markers[i].x := x; m.markers[i].y := y;
  m.markers[i].dir := 0;
end;

{ A fixed table of named maps for the provider to serve. }
type
  TEntry = record
    name: string;
    m: TMapData;
  end;

var
  Maps: array of TEntry;

procedure Register(const name: string; const m: TMapData);
var
  i: longint;
begin
  i := Length(Maps);
  SetLength(Maps, i + 1);
  Maps[i].name := name;
  Maps[i].m := m;
end;

function TableProvider(const name: string; out m: TMapData): boolean;
var
  i: longint;
begin
  TableProvider := false;
  for i := 0 to High(Maps) do
    if Maps[i].name = name then begin
      m := Maps[i].m;
      TableProvider := true;
      exit;
    end;
end;

var
  a, b, c, e, f, g: TMapData;
  mx, my, wx, wy: longint;
  atGoal: boolean;
  legs: array[0 .. 15] of TRouteLeg;
  small: array[0 .. 0] of TRouteLeg;
  nlegs: longint;
begin
  { A -> B -> C, three open rooms in a line joined by portals. }
  BuildMap(a, ['.....', '.....', '.....', '.....', '.....']);
  AddPortal(a, 4, 2, 'B', 'fromA');
  BuildMap(b, ['.....', '.....', '.....', '.....', '.....']);
  AddMarker(b, 'fromA', 0, 2);
  AddPortal(b, 4, 2, 'C', 'fromB');
  BuildMap(c, ['.....', '.....', '.....', '.....', '.....']);
  AddMarker(c, 'fromB', 0, 2);
  Register('A', a); Register('B', b); Register('C', c);

  { Same map: the start and goal share a room. }
  Check(RouteOver('A', 0, 0, 'A', 4, 4, @TableProvider, ROUTE_MAX_STATES),
    'same-map route found');

  { One hop across a portal. }
  Check(RouteOver('A', 0, 0, 'B', 4, 4, @TableProvider, ROUTE_MAX_STATES),
    'one-hop route across a portal');

  { Two hops, A through B to C. }
  Check(RouteOver('A', 0, 0, 'C', 4, 4, @TableProvider, ROUTE_MAX_STATES),
    'two-hop route A to C');

  { A target map the provider does not serve is unreachable. }
  Check(not RouteOver('A', 0, 0, 'Z', 0, 0, @TableProvider, ROUTE_MAX_STATES),
    'route to an unserved map fails');

  { The budget is too small to reach C (needs three map expansions). }
  Check(not RouteOver('A', 0, 0, 'C', 4, 4, @TableProvider, 1),
    'exhausted state budget gives up');
  { A budget that covers the three maps still succeeds. }
  Check(RouteOver('A', 0, 0, 'C', 4, 4, @TableProvider, 8),
    'a sufficient budget reaches C');

  { E has its portal walled off from the entry, so F is unreachable. A full
    column at x=2 splits the 0..1 side (with the entry) from the portal. }
  BuildMap(e, ['..#..', '..#..', '..#..', '..#..', '..#..']);
  AddPortal(e, 4, 2, 'F', 'in');
  BuildMap(f, ['.....', '.....', '.....', '.....', '.....']);
  AddMarker(f, 'in', 0, 2);
  Register('E', e); Register('F', f);
  Check(not RouteOver('E', 0, 0, 'F', 4, 4, @TableProvider, ROUTE_MAX_STATES),
    'portal unreachable from entry blocks the route');
  { From the portal side of E the crossing works. }
  Check(RouteOver('E', 4, 0, 'F', 4, 4, @TableProvider, ROUTE_MAX_STATES),
    'route from the portal side of E reaches F');

  { G: the goal sits in a region cut off from the arrival marker. Arrive at
    (0,2), goal at (4,2), full wall column between them. }
  BuildMap(g, ['..#..', '..#..', '..#..', '..#..', '..#..']);
  AddMarker(g, 'in', 0, 2);
  Register('G', g);
  Check(not RouteOver('G', 0, 2, 'G', 4, 2, @TableProvider, ROUTE_MAX_STATES),
    'goal walled off from arrival is unreachable');

  { MarkerPos: a named marker, the first-marker fallback, the centre. }
  Check(MarkerPos(b, 'fromA', mx, my) and (mx = 0) and (my = 2),
    'named marker resolves to its tile');
  Check(MarkerPos(b, 'nope', mx, my) and (mx = 0) and (my = 2),
    'unknown marker falls back to the first marker');
  Check(MarkerPos(a, 'any', mx, my) and (mx = 2) and (my = 2),
    'no markers falls back to the map centre');

  { NextHopOver: the first leg toward a destination. From A toward C the
    waypoint is A's portal tile (4,2), and it is not the goal. }
  Check(NextHopOver(a, 'A', 0, 0, 'C', 4, 4, @TableProvider, ROUTE_MAX_STATES,
    wx, wy, atGoal), 'next hop toward C exists');
  Check((wx = 4) and (wy = 2), 'next hop aims at the portal to B');
  Check(not atGoal, 'the next hop is a portal, not the goal');

  { When the goal is on this map, the waypoint is the goal itself. }
  Check(NextHopOver(a, 'A', 0, 0, 'A', 4, 4, @TableProvider, ROUTE_MAX_STATES,
    wx, wy, atGoal), 'next hop on the goal map exists');
  Check((wx = 4) and (wy = 4) and atGoal, 'the goal-map hop is the goal');

  { With the portal walled off from the entry, there is no next hop. }
  Check(not NextHopOver(e, 'E', 0, 0, 'F', 4, 4, @TableProvider,
    ROUTE_MAX_STATES, wx, wy, atGoal),
    'no next hop when the only portal is unreachable');

  { From the portal side of E the hop is E's portal tile. }
  Check(NextHopOver(e, 'E', 4, 0, 'F', 4, 4, @TableProvider, ROUTE_MAX_STATES,
    wx, wy, atGoal) and (wx = 4) and (wy = 2) and not atGoal,
    'next hop from the portal side aims at the portal');

  { RoutePathOver: the materialized leg list for A -> B -> C. }
  Check(RoutePathOver('A', 0, 0, 'C', 4, 4, @TableProvider, ROUTE_MAX_STATES,
    legs, nlegs), 'materialized route A to C found');
  CheckEqI(3, nlegs, 'A to C is three legs');
  Check((legs[0].map = 'A') and (legs[0].entryX = 0) and (legs[0].entryY = 0)
    and (legs[0].exitX = 4) and (legs[0].exitY = 2) and (not legs[0].atGoal),
    'leg 0 enters A at the start and exits its portal');
  Check((legs[1].map = 'B') and (legs[1].entryX = 0) and (legs[1].entryY = 2)
    and (legs[1].exitX = 4) and (legs[1].exitY = 2) and (not legs[1].atGoal),
    'leg 1 enters B at the marker and exits its portal');
  Check((legs[2].map = 'C') and (legs[2].entryX = 0) and (legs[2].entryY = 2)
    and (legs[2].exitX = 4) and (legs[2].exitY = 4) and legs[2].atGoal,
    'leg 2 enters C at the marker and ends on the goal');

  { Same map: a single leg that is already the goal. }
  Check(RoutePathOver('A', 0, 0, 'A', 4, 4, @TableProvider, ROUTE_MAX_STATES,
    legs, nlegs), 'materialized same-map route found');
  CheckEqI(1, nlegs, 'a same-map route is one leg');
  Check((legs[0].map = 'A') and (legs[0].entryX = 0) and (legs[0].entryY = 0)
    and (legs[0].exitX = 4) and (legs[0].exitY = 4) and legs[0].atGoal,
    'the one leg runs from the start to the goal');

  { A route the search cannot find materializes nothing. }
  Check(not RoutePathOver('A', 0, 0, 'Z', 0, 0, @TableProvider,
    ROUTE_MAX_STATES, legs, nlegs), 'no route to an unserved map');
  CheckEqI(0, nlegs, 'an unreachable goal yields no legs');
  Check(not RoutePathOver('E', 0, 0, 'F', 4, 4, @TableProvider,
    ROUTE_MAX_STATES, legs, nlegs), 'walled-off portal yields no route');

  { A buffer too small to hold the route is refused, like FindPath. }
  Check(not RoutePathOver('A', 0, 0, 'C', 4, 4, @TableProvider,
    ROUTE_MAX_STATES, small, nlegs), 'a too-small leg buffer is refused');
  CheckEqI(0, nlegs, 'a refused buffer yields no legs');

  { The materialized route agrees with RouteOver on reachability. }
  Check(RoutePathOver('A', 0, 0, 'C', 4, 4, @TableProvider, 8, legs, nlegs)
    = RouteOver('A', 0, 0, 'C', 4, 4, @TableProvider, 8),
    'RoutePathOver agrees with RouteOver');

  TestSummary('maproute');
  halt(TestExit);
end.
