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

const
  { The most map entry points one query will expand before giving up. The
    overworld is effectively unbounded, so an omniscient search needs a
    ceiling; player-known searches stay far below it. }
  ROUTE_MAX_STATES = 512;

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

{ Whether the party (pmPlayerKnown) or an omniscient agent (pmOmniscient)
  can reach (toX,toY) on toMap from (fromX,fromY) on fromMap. Sources maps
  from the live pak and generators through worldload, and for the
  player-known mode confines the route to visited maps and unfogged tiles
  from mapstate. }
function FindRoute(const fromMap: string; fromX, fromY: longint;
  const toMap: string; toX, toY: longint; mode: TRouteMode): boolean;

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

function RouteOver(const fromMap: string; fromX, fromY: longint;
  const toMap: string; toX, toY: longint;
  provider: TRouteMapProvider; maxStates: longint): boolean;
var
  qName: array of string;
  qX, qY: array of longint;
  visited: array of string;
  head, tail, nvis, explored, i, mx, my: longint;
  curName: string;
  cx, cy: longint;
  m, tm: TMapData;

  function StateKey(const n: string; x, y: longint): string;
  begin
    StateKey := n + ':' + IntToStr(x) + ':' + IntToStr(y);
  end;

  { Enqueue an entry point the first time it is reached. The visited set is
    the key to termination: the overworld's portals loop back on each
    other, so a state must never be expanded twice. }
  procedure Push(const n: string; x, y: longint);
  var
    k: string;
    j: longint;
  begin
    k := StateKey(n, x, y);
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
    end;
    qName[tail] := n; qX[tail] := x; qY[tail] := y;
    inc(tail);
  end;

begin
  RouteOver := false;
  head := 0; tail := 0; nvis := 0; explored := 0;
  Push(fromMap, fromX, fromY);
  while head < tail do begin
    if explored >= maxStates then exit;   { budget spent; route not found }
    inc(explored);
    curName := qName[head]; cx := qX[head]; cy := qY[head];
    inc(head);
    if not provider(curName, m) then continue;   { unknown or unreachable map }
    if (curName = toMap) and PathExists(m, cx, cy, toX, toY, true) then begin
      RouteOver := true;
      exit;
    end;
    for i := 0 to High(m.portals) do
      if PathExists(m, cx, cy, m.portals[i].x, m.portals[i].y, true) then
        if provider(m.portals[i].target, tm) then
          if MarkerPos(tm, m.portals[i].marker, mx, my) then
            Push(m.portals[i].target, mx, my);
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

end.
