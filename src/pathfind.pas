unit pathfind;

{** Grid pathfinding over a single map.

  A* on the tile grid of one TMapData, 4-connected (the game moves one
  cardinal at a time, no diagonals). The unit depends only on the map
  format, not on the renderer or the SDL runtime, so tools and monster
  AI can route without linking the view.

  This is the intra-map foundation. Cross-map routing over portals, with
  a player-known (fog-limited) mode and an omniscient mode, builds on this
  unit and lives in maproute. }

{$mode objfpc}{$H+}

interface

uses
  mapfmt;

type
  { One tile on a path. Packed and small for the memory-tight targets. }
  TPathStep = packed record
    x, y: smallint;
  end;

{ Whether a tile can be walked for planning, read from the map's static
  data. Open floor is passable. A tile an NPC stands on is blocked, since
  NPCs do not step aside. A door is passable only when doorsPassable is set
  and the door is either unlocked or one the planner may count on opening: a
  locked door is a wall unless canPick is set, which the caller passes when
  the party carries a lockpick (someone with the Pick Locks skill), since
  such a party can work a locked door open and retry until it gives. A
  party with no lockpick, and every non-player planner (monsters do not pick
  locks), leaves canPick false so a locked door stays a wall. Any other wall
  value, and any out-of-bounds coordinate, is solid. This mirrors
  world.IsBlocking over the static grid, without the live open-door state. }
function PathPassable(const m: TMapData; x, y: longint;
  doorsPassable: boolean; canPick: boolean = false): boolean;

{ Shortest 4-connected route from (sx,sy) to (dx,dy) on map m. On success
  the route is written into path (path[0] is the start, path[steps-1] the
  goal) and the result is true. start = goal yields steps = 1. Returns
  false if the goal is unreachable, if either endpoint is not passable, or
  if the route needs more than Length(path) steps. canPick is the lockpick
  allowance passed to PathPassable. }
function FindPath(const m: TMapData; sx, sy, dx, dy: longint;
  doorsPassable: boolean; var path: array of TPathStep;
  out steps: longint; canPick: boolean = false): boolean;

{ Whether a route exists, without reconstructing it. Same search as
  FindPath but it never touches a path buffer, so it cannot fail on size. }
function PathExists(const m: TMapData; sx, sy, dx, dy: longint;
  doorsPassable: boolean; canPick: boolean = false): boolean;

implementation

function DoorLocked(const m: TMapData; x, y: longint): boolean;
{** Whether a door tile carries a locked door record. A door tile with no
  record is an ordinary unlocked door. }
var
  i: longint;
begin
  DoorLocked := false;
  for i := 0 to High(m.doors) do
    if (m.doors[i].x = x) and (m.doors[i].y = y) then begin
      DoorLocked := m.doors[i].locked <> 0;
      exit;
    end;
end;

function NpcTile(const m: TMapData; x, y: longint): boolean;
{** Whether an NPC stands on the tile. }
var
  i: longint;
begin
  NpcTile := false;
  for i := 0 to High(m.npcs) do
    if (m.npcs[i].x = x) and (m.npcs[i].y = y) then begin
      NpcTile := true;
      exit;
    end;
end;

function PathPassable(const m: TMapData; x, y: longint;
  doorsPassable: boolean; canPick: boolean): boolean;
var
  t: byte;
begin
  PathPassable := false;
  if (x < 0) or (y < 0) or (x >= m.w) or (y >= m.h) then exit;
  if NpcTile(m, x, y) then exit;
  t := m.walls[y * m.w + x];
  if t = TILE_EMPTY then
    PathPassable := true
  else if t = TILE_DOOR then
    PathPassable := doorsPassable
      and ((not DoorLocked(m, x, y)) or canPick);
end;

const
  INF = High(longint) div 4;

{ The A* search. Fills cameFrom with each visited tile's parent index
  (-1 at the start, left -1 if never reached) and returns whether the goal
  was reached. Indices are packed as y*w + x. The heap sorts on a composite
  key so ties on f prefer the smaller heuristic, giving straighter paths. }
function RunAStar(const m: TMapData; si, gi: longint;
  doorsPassable, canPick: boolean;
  var cameFrom: array of longint): boolean;
var
  n, i: longint;
  gScore, keyArr, heap: array of longint;
  closed: array of boolean;
  hn, cur, gx, gy, cx, cy, nx, ny, ni, d, tentative, nh: longint;
  dxs: array[0 .. 3] of longint = (0, 1, 0, -1);   { N, E, S, W }
  dys: array[0 .. 3] of longint = (-1, 0, 1, 0);

  function Heur(idx: longint): longint;
  begin
    Heur := Abs((idx mod m.w) - gx) + Abs((idx div m.w) - gy);
  end;

  { Composite key: f in the high part, h in the low part for tie-breaking.
    h is bounded by w + h <= 2*64, so a 256 multiplier keeps them apart. }
  function CompKey(idx, g: longint): longint;
  var hh: longint;
  begin
    hh := Heur(idx);
    CompKey := (g + hh) * 256 + hh;
  end;

  procedure HeapPush(idx: longint);
  var c, p, tmp: longint;
  begin
    heap[hn] := idx;
    c := hn;
    inc(hn);
    while c > 0 do begin
      p := (c - 1) div 2;
      if keyArr[heap[p]] <= keyArr[heap[c]] then break;
      tmp := heap[p]; heap[p] := heap[c]; heap[c] := tmp;
      c := p;
    end;
  end;

  function HeapPop: longint;
  var c, l, r, s, tmp: longint;
  begin
    HeapPop := heap[0];
    dec(hn);
    heap[0] := heap[hn];
    c := 0;
    while true do begin
      l := 2 * c + 1; r := l + 1; s := c;
      if (l < hn) and (keyArr[heap[l]] < keyArr[heap[s]]) then s := l;
      if (r < hn) and (keyArr[heap[r]] < keyArr[heap[s]]) then s := r;
      if s = c then break;
      tmp := heap[s]; heap[s] := heap[c]; heap[c] := tmp;
      c := s;
    end;
  end;

begin
  RunAStar := false;
  n := m.w * m.h;
  SetLength(gScore, n);
  SetLength(keyArr, n);
  SetLength(closed, n);
  SetLength(heap, n + 1);
  for i := 0 to n - 1 do begin
    gScore[i] := INF;
    cameFrom[i] := -1;
    closed[i] := false;
  end;
  gx := gi mod m.w; gy := gi div m.w;

  gScore[si] := 0;
  keyArr[si] := CompKey(si, 0);
  hn := 0;
  HeapPush(si);

  while hn > 0 do begin
    cur := HeapPop;
    if closed[cur] then continue;
    if cur = gi then begin RunAStar := true; exit; end;
    closed[cur] := true;
    cx := cur mod m.w; cy := cur div m.w;
    for d := 0 to 3 do begin
      nx := cx + dxs[d]; ny := cy + dys[d];
      if (nx < 0) or (ny < 0) or (nx >= m.w) or (ny >= m.h) then continue;
      ni := ny * m.w + nx;
      if closed[ni] then continue;
      if not PathPassable(m, nx, ny, doorsPassable, canPick) then continue;
      tentative := gScore[cur] + 1;
      if tentative < gScore[ni] then begin
        cameFrom[ni] := cur;
        gScore[ni] := tentative;
        nh := Abs(nx - gx) + Abs(ny - gy);
        keyArr[ni] := (tentative + nh) * 256 + nh;
        HeapPush(ni);
      end;
    end;
  end;
end;

function FindPath(const m: TMapData; sx, sy, dx, dy: longint;
  doorsPassable: boolean; var path: array of TPathStep;
  out steps: longint; canPick: boolean): boolean;
var
  cameFrom: array of longint;
  si, gi, cur, count, i, w: longint;
  chain: array of longint;
begin
  FindPath := false;
  steps := 0;
  if (m.w <= 0) or (m.h <= 0) then exit;
  if not PathPassable(m, sx, sy, doorsPassable, canPick) then exit;
  if not PathPassable(m, dx, dy, doorsPassable, canPick) then exit;
  w := m.w;
  si := sy * w + sx;
  gi := dy * w + dx;
  if si = gi then begin
    if Length(path) < 1 then exit;
    path[0].x := sx; path[0].y := sy;
    steps := 1;
    FindPath := true;
    exit;
  end;

  SetLength(cameFrom, m.w * m.h);
  if not RunAStar(m, si, gi, doorsPassable, canPick, cameFrom) then exit;

  { Walk parents back from the goal to count the chain. }
  count := 0;
  cur := gi;
  while cur <> -1 do begin
    inc(count);
    if cur = si then break;
    cur := cameFrom[cur];
  end;
  if count > Length(path) then exit;   { route does not fit the buffer }

  { Collect reversed, then emit start-to-goal. }
  SetLength(chain, count);
  cur := gi;
  for i := 0 to count - 1 do begin
    chain[i] := cur;
    cur := cameFrom[cur];
  end;
  for i := 0 to count - 1 do begin
    path[i].x := chain[count - 1 - i] mod w;
    path[i].y := chain[count - 1 - i] div w;
  end;
  steps := count;
  FindPath := true;
end;

function PathExists(const m: TMapData; sx, sy, dx, dy: longint;
  doorsPassable: boolean; canPick: boolean): boolean;
var
  cameFrom: array of longint;
  si, gi, w: longint;
begin
  PathExists := false;
  if (m.w <= 0) or (m.h <= 0) then exit;
  if not PathPassable(m, sx, sy, doorsPassable, canPick) then exit;
  if not PathPassable(m, dx, dy, doorsPassable, canPick) then exit;
  w := m.w;
  si := sy * w + sx;
  gi := dy * w + dx;
  if si = gi then begin PathExists := true; exit; end;
  SetLength(cameFrom, m.w * m.h);
  PathExists := RunAStar(m, si, gi, doorsPassable, canPick, cameFrom);
end;

end.
