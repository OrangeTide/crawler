unit maproute;

{** Cross-map routing over portal links.

  Pathfinding across more than one map. Maps are joined by portals: a
  portal tile in one map names a target map and the marker to arrive at.
  The route is a search over map entry points, where each intra-map leg
  (an entry to a portal tile, or an entry to the goal) is solved by the
  single-map A* in pathfind.

  Two traversal modes serve the two callers the game needs:

  - pmPlayerKnown is for the party. It keeps to what the party has
    actually seen: only visited maps are entered, and inside a map only
    tiles lifted from fog can be crossed. A player plotting a course to a
    remembered place cannot route through corridors they never walked.
  - pmOmniscient is for monsters and other agents that know the whole
    layout. Every map is sourced in full and all its geometry is open.

  The graph search is split from how maps are sourced so it can be tested
  on hand-built maps with no pak or live world. RouteOver takes a provider
  that hands back a map by name (already fog-masked for the player-known
  case); FindRoute wires the runtime providers for each mode. }

{$mode objfpc}{$H+}

interface

uses
  mapfmt;

type
  { Who is routing, and so how much of the world is traversable. }
  TRouteMode = (pmPlayerKnown, pmOmniscient);

  { Hands back a map's geometry by name. Returns false when the map cannot
    be routed through: it does not exist, or (player-known) was never
    visited. A provider may mask the map it returns, marking tiles the
    caller must not cross as solid, so the search needs no fog logic. }
  TRouteMapProvider = function(const name: string; out m: TMapData): boolean;

  { One map on a materialized route. The party arrives at (entryX,entryY)
    and, on every leg but the last, leaves through the portal tile
    (exitX,exitY) toward the next leg. On the final leg atGoal is true and
    (exitX,exitY) is the goal tile itself. }
  TRouteLeg = packed record
    map: string[12];
    entryX, entryY: smallint;
    exitX, exitY: smallint;
    atGoal: boolean;
  end;

const
  { The most map entry points one query will expand before giving up. The
    overworld is effectively unbounded, so an omniscient search needs a
    ceiling; player-known searches stay far below it. }
  ROUTE_MAX_STATES = 512;

  { A materialized route never needs more map hops than this. }
  ROUTE_MAX_LEGS = 64;

{ The marker's tile in m, by name. Falls back to the first marker, then to
  the map centre, exactly as world.PlaceAtMarker does, so a routed entry
  point lands where an actual transition would. Always succeeds for a map
  with positive size. }
function MarkerPos(const m: TMapData; const marker: string;
  out mx, my: longint): boolean;

{ Whether a route exists from (fromX,fromY) on fromMap to (toX,toY) on
  toMap, crossing portals, with every map supplied by provider. A
  breadth-first search over (map, entry tile) states, each intra-map leg
  solved by pathfind.PathExists. Doors are treated as passable. Gives up
  (returns false) after maxStates entry points, so it always terminates. }
function RouteOver(const fromMap: string; fromX, fromY: longint;
  const toMap: string; toX, toY: longint;
  provider: TRouteMapProvider; maxStates: longint): boolean;

{ The next waypoint on curMap toward the goal, for walking a route one map
  at a time. curMap is the live map the party stands in (its fog and open
  doors are the truth), passed in rather than sourced, so the current map is
  always navigable even before it has a saved snapshot. On success wx,wy is
  the tile to head for on curMap: the goal itself when it is on this map
  (atGoal true), otherwise the portal tile that begins a route onward
  (atGoal false). Downstream maps are supplied by provider, so the route
  past the current map still obeys the provider's fog. }
function NextHopOver(const curMap: TMapData; const curName: string;
  fromX, fromY: longint; const toMap: string; toX, toY: longint;
  provider: TRouteMapProvider; maxStates: longint;
  out wx, wy: longint; out atGoal: boolean): boolean;

{ Whether the party (pmPlayerKnown) or an omniscient agent (pmOmniscient)
  can reach (toX,toY) on toMap from (fromX,fromY) on fromMap. Sources maps
  from the live pak and generators through worldload, and for the
  player-known mode confines the route to visited maps and unfogged tiles
  from mapstate. }
function FindRoute(const fromMap: string; fromX, fromY: longint;
  const toMap: string; toX, toY: longint; mode: TRouteMode): boolean;

{ The runtime next waypoint: NextHopOver wired to the live providers for the
  given mode. The party calls it each step to walk a cross-map route. }
function RouteNextHop(const curMap: TMapData; const curName: string;
  fromX, fromY: longint; const toMap: string; toX, toY: longint;
  mode: TRouteMode; out wx, wy: longint; out atGoal: boolean): boolean;

{ Materialize the whole route as an ordered list of per-map legs in a single
  search. legs[0] is the start map; the last leg has atGoal true. The caller
  owns and sizes legs, as pathfind.FindPath does its buffer. Returns false
  with nlegs=0 when no route is found or legs is too small to hold it. }
function RoutePathOver(const fromMap: string; fromX, fromY: longint;
  const toMap: string; toX, toY: longint;
  provider: TRouteMapProvider; maxStates: longint;
  var legs: array of TRouteLeg; out nlegs: longint;
  canPick: boolean = false): boolean;

{ RoutePathOver wired to the live providers for the given mode. canPick lets
  the route plan through locked doors the party can pick (see pathfind). }
function RoutePath(const fromMap: string; fromX, fromY: longint;
  const toMap: string; toX, toY: longint; mode: TRouteMode;
  var legs: array of TRouteLeg; out nlegs: longint;
  canPick: boolean = false): boolean;

implementation

uses
  sysutils, pathfind, world, worldload, mapstate;

function MarkerPos(const m: TMapData; const marker: string;
  out mx, my: longint): boolean;
var
  i, mi: longint;
begin
  MarkerPos := false;
  if (m.w <= 0) or (m.h <= 0) then exit;
  mi := -1;
  for i := 0 to High(m.markers) do
    if m.markers[i].name = marker then begin
      mi := i;
      break;
    end;
  if (mi < 0) and (Length(m.markers) > 0) then
    mi := 0;
  if mi >= 0 then begin
    mx := m.markers[mi].x;
    my := m.markers[mi].y;
  end else begin
    mx := m.w div 2;
    my := m.h div 2;
  end;
  MarkerPos := true;
end;

type
  TStrArr = array of string;
  TIntArr = array of longint;

{ The breadth-first search both the distance and the materialized route are
  built on. It expands (map, entry tile) states, so the first time the goal
  map is reached is by the shortest chain of maps. Each intra-map leg is an A*
  in pathfind, doors passable; the visited set and budget bound the otherwise
  looping overworld so the search always terminates. The queue arrays are the
  caller's, grown as needed; on a hit the goal state's index is returned and
  the arrays hold the tree to reconstruct from (each state records its parent
  and the portal tile on the parent that reached it), or -1 when no route is
  found within maxStates. }
function RouteSearch(const fromMap: string; fromX, fromY: longint;
  const toMap: string; toX, toY: longint;
  provider: TRouteMapProvider; maxStates: longint;
  var qName: TStrArr;
  var qX, qY, qDepth, qParent, qPortX, qPortY: TIntArr;
  canPick: boolean = false): longint;
var
  visited: array of string;
  head, tail, nvis, explored, i, mx, my, cd, curIdx: longint;
  curName: string;
  cx, cy: longint;
  m, tm: TMapData;

  { Enqueue an entry point the first time it is reached. The visited set is
    the key to termination: the overworld's portals loop back on each
    other, so a state must never be expanded twice. parent is the index of
    the state it was reached from, and (portX,portY) the portal tile on that
    parent's map that led here. }
  procedure Push(const n: string; x, y, depth, parent, portX, portY: longint);
  var
    k: string;
    j: longint;
  begin
    k := n + ':' + IntToStr(x) + ':' + IntToStr(y);
    for j := 0 to nvis - 1 do
      if visited[j] = k then exit;
    if nvis >= Length(visited) then
      SetLength(visited, (nvis + 8) * 2);
    visited[nvis] := k;
    inc(nvis);
    if tail >= Length(qName) then begin
      SetLength(qName, (tail + 8) * 2);
      SetLength(qX, Length(qName));
      SetLength(qY, Length(qName));
      SetLength(qDepth, Length(qName));
      SetLength(qParent, Length(qName));
      SetLength(qPortX, Length(qName));
      SetLength(qPortY, Length(qName));
    end;
    qName[tail] := n; qX[tail] := x; qY[tail] := y; qDepth[tail] := depth;
    qParent[tail] := parent; qPortX[tail] := portX; qPortY[tail] := portY;
    inc(tail);
  end;

begin
  RouteSearch := -1;
  head := 0; tail := 0; nvis := 0; explored := 0;
  Push(fromMap, fromX, fromY, 0, -1, 0, 0);
  while head < tail do begin
    if explored >= maxStates then exit;   { budget spent; route not found }
    inc(explored);
    curIdx := head;
    curName := qName[head]; cx := qX[head]; cy := qY[head]; cd := qDepth[head];
    inc(head);
    if not provider(curName, m) then continue;   { unknown or unreachable map }
    if (curName = toMap) and PathExists(m, cx, cy, toX, toY, true, canPick) then
    begin
      RouteSearch := curIdx;
      exit;
    end;
    for i := 0 to High(m.portals) do
      if PathExists(m, cx, cy, m.portals[i].x, m.portals[i].y, true, canPick) then
        if provider(m.portals[i].target, tm) then
          if MarkerPos(tm, m.portals[i].marker, mx, my) then
            Push(m.portals[i].target, mx, my, cd + 1, curIdx,
              m.portals[i].x, m.portals[i].y);
  end;
end;

{ The fewest map hops from (fromX,fromY) on fromMap to (toX,toY) on toMap:
  0 when the goal is on the start map and reachable there, 1 per portal
  crossing, or -1 when no route is found within maxStates. }
function RouteDist(const fromMap: string; fromX, fromY: longint;
  const toMap: string; toX, toY: longint;
  provider: TRouteMapProvider; maxStates: longint): longint;
var
  qName: TStrArr;
  qX, qY, qDepth, qParent, qPortX, qPortY: TIntArr;
  goal: longint;
begin
  goal := RouteSearch(fromMap, fromX, fromY, toMap, toX, toY,
    provider, maxStates, qName, qX, qY, qDepth, qParent, qPortX, qPortY);
  if goal < 0 then RouteDist := -1
  else RouteDist := qDepth[goal];
end;

function RouteOver(const fromMap: string; fromX, fromY: longint;
  const toMap: string; toX, toY: longint;
  provider: TRouteMapProvider; maxStates: longint): boolean;
begin
  RouteOver := RouteDist(fromMap, fromX, fromY, toMap, toX, toY,
    provider, maxStates) >= 0;
end;

function NextHopOver(const curMap: TMapData; const curName: string;
  fromX, fromY: longint; const toMap: string; toX, toY: longint;
  provider: TRouteMapProvider; maxStates: longint;
  out wx, wy: longint; out atGoal: boolean): boolean;
var
  i, mx, my, d, best: longint;
  tm: TMapData;
begin
  NextHopOver := false;
  wx := fromX; wy := fromY; atGoal := false;
  { the goal is on this map and directly reachable: head straight for it. }
  if (curName = toMap) and PathExists(curMap, fromX, fromY, toX, toY, true) then
  begin
    wx := toX; wy := toY; atGoal := true;
    NextHopOver := true;
    exit;
  end;
  { otherwise take the reachable portal whose onward route reaches the goal
    in the fewest map hops, so the party does not detour through an extra
    zone when a nearer crossing exists. }
  best := High(longint);
  for i := 0 to High(curMap.portals) do
    if PathExists(curMap, fromX, fromY, curMap.portals[i].x,
         curMap.portals[i].y, true) then
      if provider(curMap.portals[i].target, tm) then
        if MarkerPos(tm, curMap.portals[i].marker, mx, my) then begin
          d := RouteDist(curMap.portals[i].target, mx, my, toMap, toX, toY,
                 provider, maxStates);
          if (d >= 0) and (d < best) then begin
            best := d;
            wx := curMap.portals[i].x;
            wy := curMap.portals[i].y;
            atGoal := false;
            NextHopOver := true;
          end;
        end;
end;

{ ---- runtime providers (live pak, generators and fog) ---- }

var
  gMode: TRouteMode;

{ Source a map in full, from the pak or a generator, with no fog. }
function ProvideOmniscient(const name: string; out m: TMapData): boolean;
var
  isDyn: boolean;
  ver, depth: longint;
  seed: longword;
begin
  ProvideOmniscient := SourceMap(name, false, m, isDyn, ver, seed, depth);
end;

{ Source a visited map, with tiles the party has not seen masked solid so
  the route cannot pass through them. A map with no snapshot was never
  entered, so it is not routable. }
function ProvidePlayerKnown(const name: string; out m: TMapData): boolean;
var
  isDyn: boolean;
  ver, depth, idx, i, n: longint;
  seed: longword;
begin
  ProvidePlayerKnown := false;
  idx := SnapshotIndex(name);
  if idx < 0 then exit;                 { never visited }
  if not SourceMap(name, false, m, isDyn, ver, seed, depth) then exit;
  if (Snapshots[idx].w = m.w) and (Snapshots[idx].h = m.h) then begin
    n := m.w * m.h;
    for i := 0 to n - 1 do
      if Snapshots[idx].seen[i] = VIS_UNSEEN then
        m.walls[i] := 1;                { an unseen tile is solid to planning }
  end;
  ProvidePlayerKnown := true;
end;

function RuntimeProvider(const name: string; out m: TMapData): boolean;
begin
  if gMode = pmPlayerKnown then
    RuntimeProvider := ProvidePlayerKnown(name, m)
  else
    RuntimeProvider := ProvideOmniscient(name, m);
end;

function FindRoute(const fromMap: string; fromX, fromY: longint;
  const toMap: string; toX, toY: longint; mode: TRouteMode): boolean;
begin
  gMode := mode;
  FindRoute := RouteOver(fromMap, fromX, fromY, toMap, toX, toY,
    @RuntimeProvider, ROUTE_MAX_STATES);
end;

function RouteNextHop(const curMap: TMapData; const curName: string;
  fromX, fromY: longint; const toMap: string; toX, toY: longint;
  mode: TRouteMode; out wx, wy: longint; out atGoal: boolean): boolean;
begin
  gMode := mode;
  RouteNextHop := NextHopOver(curMap, curName, fromX, fromY, toMap, toX, toY,
    @RuntimeProvider, ROUTE_MAX_STATES, wx, wy, atGoal);
end;

function RoutePathOver(const fromMap: string; fromX, fromY: longint;
  const toMap: string; toX, toY: longint;
  provider: TRouteMapProvider; maxStates: longint;
  var legs: array of TRouteLeg; out nlegs: longint;
  canPick: boolean): boolean;
var
  qName: TStrArr;
  qX, qY, qDepth, qParent, qPortX, qPortY: TIntArr;
  goal, count, idx, prevIdx, pos: longint;
begin
  RoutePathOver := false;
  nlegs := 0;
  goal := RouteSearch(fromMap, fromX, fromY, toMap, toX, toY,
    provider, maxStates, qName, qX, qY, qDepth, qParent, qPortX, qPortY,
    canPick);
  if goal < 0 then exit;
  { count the chain from goal up to the root, then refuse if it will not fit. }
  count := 0; idx := goal;
  while idx >= 0 do begin inc(count); idx := qParent[idx]; end;
  if (count = 0) or (count > Length(legs)) then exit;
  { walk goal -> root, filling legs root-first. A state's exit is the portal
    tile recorded on its child (the state visited just before it here); the
    goal's exit is the goal tile itself. }
  pos := count - 1; idx := goal; prevIdx := -1;
  while idx >= 0 do begin
    legs[pos].map := qName[idx];
    legs[pos].entryX := qX[idx]; legs[pos].entryY := qY[idx];
    if idx = goal then begin
      legs[pos].exitX := toX; legs[pos].exitY := toY;
      legs[pos].atGoal := true;
    end else begin
      legs[pos].exitX := qPortX[prevIdx]; legs[pos].exitY := qPortY[prevIdx];
      legs[pos].atGoal := false;
    end;
    prevIdx := idx;
    idx := qParent[idx];
    dec(pos);
  end;
  nlegs := count;
  RoutePathOver := true;
end;

function RoutePath(const fromMap: string; fromX, fromY: longint;
  const toMap: string; toX, toY: longint; mode: TRouteMode;
  var legs: array of TRouteLeg; out nlegs: longint;
  canPick: boolean): boolean;
begin
  gMode := mode;
  RoutePath := RoutePathOver(fromMap, fromX, fromY, toMap, toX, toY,
    @RuntimeProvider, ROUTE_MAX_STATES, legs, nlegs, canPick);
end;

end.
