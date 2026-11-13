unit pursuit;

{** Roaming monsters that hunt the party across maps.

  A pursuer is a monster loose in the world with a position and the map it
  stands on. Each party step every pursuer takes one step toward the party,
  routing with the omniscient cross-map pathfinder: it knows the whole
  layout, so it follows the party through portals from one map to the next.
  When a pursuer reaches the party it has caught them, and the caller turns
  that into a fight.

  The movement core is split from how maps are sourced behind a provider, so
  it is tested on hand-built maps with no pak or live world (as maproute is).
  PursuitAdvance wires the live omniscient provider. }

{$mode objfpc}{$H+}

interface

uses
  mapfmt, maproute;

const
  { A pursuer's behaviour. The router carries all three. }
  PM_HUNT     = 0;   { aware: routes to the party, across maps, and catches it }
  PM_PATROL   = 1;   { roams waypoints on its own map until it spots the party }
  PM_CONVERGE = 2;   { heads for a raised alarm, to join a hunt already begun }

  { A patroller spots the party within this many tiles on its own map. }
  PURSUIT_DETECT = 5;

type
  TPursuer = record
    mon: longint;      { the monster, an index into MonDefs }
    map: string;       { the map it is on }
    x, y: longint;     { its tile }
    active: boolean;
    mode: byte;        { PM_*, how it moves this tick }
    gx, gy: longint;   { its goal tile on its own map (patrol or converge) }
    fx, fy: longint;   { last step delta, the heading the world view faces }
  end;

var
  Pursuers: array of TPursuer;

procedure PursuitReset;
{ Add a hunter already aware of the party: it heads straight for it. }
function AddPursuer(monIdx: longint; const map: string; x, y: longint): longint;
{ Add a patroller: it roams its map until it spots the party, then hunts. }
function AddPatroller(monIdx: longint; const map: string; x, y: longint): longint;
procedure RemovePursuer(idx: longint);
{ Move a hunter to a new map and tile and keep it active, for a setback after
  the party breaks off a fight rather than finishing the hunter. }
procedure RepositionPursuer(idx: longint; const map: string; x, y: longint);
{ Raise an alarm at a tile: every patroller on that map turns to converge on
  it, so one creature that finds the party pulls the others in. }
procedure RaiseAlarm(const map: string; x, y: longint);
{ Whether an alarm is currently up. }
function AlarmActive: boolean;
{ Drop every hunter, for example on reaching a safe hub. }
procedure PursuitClear;
function ActivePursuerCount: longint;
{ Whether any active hunter stands on the given map. }
function HunterOnMap(const map: string): boolean;

{ The movement core, testable with an injected map provider. Advance every
  active pursuer one tile by its mode: a hunter toward the party, a patroller
  along its waypoints, a converging one toward the alarm. A patroller that
  spots the party turns to hunt and rallies the rest. Returns the index of the
  first hunter that has caught the party (left active for the caller to
  resolve), or -1 if none caught them this step. }
function AdvanceOver(const partyMap: string; partyX, partyY: longint;
  provider: TRouteMapProvider; maxStates: longint): longint;

{ The runtime advance: AdvanceOver wired to the live omniscient provider
  (maps sourced in full from the pak and generators, no fog). }
function PursuitAdvance(const partyMap: string; partyX, partyY: longint): longint;

{ Advance hunters by the game time that has passed since the last tick, one
  tile per MINUTES_PER_STEP minutes. Because it reads the clock rather than
  counting party steps, time that passes without a step (resting, waiting)
  still closes the distance. Returns the first pursuer to catch the party,
  or -1. Call it wherever game time advances in exploration. }
function PursuitTick(const partyMap: string; partyX, partyY: longint): longint;

implementation

uses
  pathfind, worldload, gametime, rng;

const
  MINUTES_PER_STEP = 3;     { a hunter covers one tile in this much game time,
                              matching the three minutes a party tile takes }
  MAX_TICK_STEPS   = 256;   { cap the catch-up from a long rest so one tick
                              never loops without bound }

var
  gLastClock: longword;     { the clock at the last pursuit tick }
  gAlarmOn: boolean;        { an alarm is up, pulling patrollers in }
  gAlarmMap: string;        { and where it was raised }
  gAlarmX, gAlarmY: longint;

procedure ClearAlarm;
begin
  gAlarmOn := false;
  gAlarmMap := '';
  gAlarmX := 0; gAlarmY := 0;
end;

procedure PursuitReset;
begin
  Pursuers := nil;
  gLastClock := ClockMin;   { start level with the clock; no backlog owed }
  ClearAlarm;
end;

function AddHunterRec(monIdx: longint; const map: string; x, y: longint;
  mode: byte): longint;
begin
  SetLength(Pursuers, Length(Pursuers) + 1);
  AddHunterRec := High(Pursuers);
  Pursuers[AddHunterRec].mon := monIdx;
  Pursuers[AddHunterRec].map := map;
  Pursuers[AddHunterRec].x := x;
  Pursuers[AddHunterRec].y := y;
  Pursuers[AddHunterRec].active := true;
  Pursuers[AddHunterRec].mode := mode;
  Pursuers[AddHunterRec].gx := x;   { patrol picks a real goal on its first tick }
  Pursuers[AddHunterRec].gy := y;
end;

function AddPursuer(monIdx: longint; const map: string; x, y: longint): longint;
begin
  AddPursuer := AddHunterRec(monIdx, map, x, y, PM_HUNT);
end;

function AddPatroller(monIdx: longint; const map: string; x, y: longint): longint;
begin
  AddPatroller := AddHunterRec(monIdx, map, x, y, PM_PATROL);
end;

procedure RaiseAlarm(const map: string; x, y: longint);
var
  i: longint;
begin
  gAlarmOn := true;
  gAlarmMap := map;
  gAlarmX := x; gAlarmY := y;
  for i := 0 to High(Pursuers) do
    if Pursuers[i].active and (Pursuers[i].mode = PM_PATROL)
       and (Pursuers[i].map = map) then begin
      Pursuers[i].mode := PM_CONVERGE;
      Pursuers[i].gx := x;
      Pursuers[i].gy := y;
    end;
end;

function AlarmActive: boolean;
begin
  AlarmActive := gAlarmOn;
end;

procedure RemovePursuer(idx: longint);
begin
  if (idx >= 0) and (idx <= High(Pursuers)) then
    Pursuers[idx].active := false;
end;

procedure RepositionPursuer(idx: longint; const map: string; x, y: longint);
begin
  if (idx < 0) or (idx > High(Pursuers)) then exit;
  Pursuers[idx].map := map;
  Pursuers[idx].x := x;
  Pursuers[idx].y := y;
  Pursuers[idx].active := true;
end;

procedure PursuitClear;
var
  i: longint;
begin
  for i := 0 to High(Pursuers) do
    Pursuers[i].active := false;
  ClearAlarm;
end;

function ActivePursuerCount: longint;
var
  i: longint;
begin
  ActivePursuerCount := 0;
  for i := 0 to High(Pursuers) do
    if Pursuers[i].active then inc(ActivePursuerCount);
end;

function HunterOnMap(const map: string): boolean;
var
  i: longint;
begin
  HunterOnMap := false;
  for i := 0 to High(Pursuers) do
    if Pursuers[i].active and (Pursuers[i].map = map) then begin
      HunterOnMap := true;
      exit;
    end;
end;

function Caught(const p: TPursuer; partyX, partyY: longint): boolean;
{** A hunter has the party when it stands on their tile or right beside it. }
begin
  Caught := (Abs(p.x - partyX) + Abs(p.y - partyY)) <= 1;
end;

procedure CrossIfOnPortal(var p: TPursuer; const m: TMapData;
  provider: TRouteMapProvider);
{** If the pursuer now stands on a portal tile, take it to the target map's
  marker, the same transition the party makes stepping onto a portal. }
var
  i, mx, my: longint;
  tm: TMapData;
begin
  for i := 0 to High(m.portals) do
    if (m.portals[i].x = p.x) and (m.portals[i].y = p.y) then begin
      if provider(m.portals[i].target, tm) then
        if MarkerPos(tm, m.portals[i].marker, mx, my) then begin
          p.map := m.portals[i].target;
          p.x := mx;
          p.y := my;
        end;
      exit;
    end;
end;

function Detects(const p: TPursuer; const partyMap: string;
  partyX, partyY: longint): boolean;
{** A patroller spots the party on its own map within the detect radius. }
begin
  Detects := (p.map = partyMap)
    and (Abs(p.x - partyX) + Abs(p.y - partyY) <= PURSUIT_DETECT);
end;

procedure ChaseTile(var p: TPursuer; const m: TMapData; const tMap: string;
  tX, tY: longint; provider: TRouteMapProvider; maxStates: longint);
{** Step one tile toward (tMap,tX,tY), crossing a portal on arrival if the
  target is on another map. It does not test a catch; the caller does. }
var
  wx, wy, nsteps: longint;
  atGoal: boolean;
  path: array[0 .. 2047] of TPathStep;
begin
  if p.map = tMap then begin
    if (p.x <> tX) or (p.y <> tY) then
      if FindPath(m, p.x, p.y, tX, tY, true, path, nsteps) and (nsteps >= 2) then
      begin
        p.fx := path[1].x - p.x;
        p.fy := path[1].y - p.y;
        p.x := path[1].x;
        p.y := path[1].y;
      end;
    exit;
  end;
  { the target is on another map: head for the portal that begins the
    shortest route to it, and cross it on arrival. }
  if not NextHopOver(m, p.map, p.x, p.y, tMap, tX, tY,
       provider, maxStates, wx, wy, atGoal) then exit;   { no route; hold }
  if (p.x <> wx) or (p.y <> wy) then
    if FindPath(m, p.x, p.y, wx, wy, true, path, nsteps) and (nsteps >= 2) then
    begin
      p.fx := path[1].x - p.x;
      p.fy := path[1].y - p.y;
      p.x := path[1].x;
      p.y := path[1].y;
    end;
  CrossIfOnPortal(p, m, provider);
end;

procedure PickPatrolGoal(var p: TPursuer; const m: TMapData);
{** Choose a fresh reachable open tile on the pursuer's own map to roam to.
  Stays put if a few tries turn up nothing reachable. }
var
  tries, tx, ty: longint;
begin
  for tries := 1 to 16 do begin
    tx := Range(0, m.w - 1);
    ty := Range(0, m.h - 1);
    if m.walls[ty * m.w + tx] <> TILE_EMPTY then continue;
    if (tx = p.x) and (ty = p.y) then continue;
    if not PathExists(m, p.x, p.y, tx, ty, true) then continue;
    p.gx := tx; p.gy := ty;
    exit;
  end;
  p.gx := p.x; p.gy := p.y;
end;

function AdvanceOne(var p: TPursuer; const partyMap: string;
  partyX, partyY: longint; provider: TRouteMapProvider;
  maxStates: longint): boolean;
{** Move one pursuer a single tile by its mode. A patroller or a converging
  hunter that spots the party takes up the chase and rallies the others.
  Returns true only when a hunting pursuer has caught the party. }
var
  m: TMapData;
begin
  AdvanceOne := false;
  if not p.active then exit;
  if not provider(p.map, m) then exit;   { its map is gone; hold position }

  { seeing the party turns any mode into a hunt and raises the alarm. }
  if (p.mode <> PM_HUNT) and Detects(p, partyMap, partyX, partyY) then begin
    p.mode := PM_HUNT;
    RaiseAlarm(partyMap, partyX, partyY);
  end;

  case p.mode of
    PM_PATROL: begin
      if (p.x = p.gx) and (p.y = p.gy) then PickPatrolGoal(p, m);
      ChaseTile(p, m, p.map, p.gx, p.gy, provider, maxStates);
    end;
    PM_CONVERGE: begin
      if gAlarmOn then ChaseTile(p, m, gAlarmMap, gAlarmX, gAlarmY,
        provider, maxStates);
      { reached the alarm with no party in sight: fall back to patrolling. }
      if (not gAlarmOn) or ((p.map = gAlarmMap) and (p.x = gAlarmX)
         and (p.y = gAlarmY)) then begin
        p.mode := PM_PATROL;
        PickPatrolGoal(p, m);
      end;
    end;
  else begin   { PM_HUNT }
    if (p.map = partyMap) and Caught(p, partyX, partyY) then begin
      AdvanceOne := true; exit;
    end;
    ChaseTile(p, m, partyMap, partyX, partyY, provider, maxStates);
    AdvanceOne := (p.map = partyMap) and Caught(p, partyX, partyY);
  end;
  end;
end;

function AdvanceOver(const partyMap: string; partyX, partyY: longint;
  provider: TRouteMapProvider; maxStates: longint): longint;
var
  i: longint;
begin
  AdvanceOver := -1;
  for i := 0 to High(Pursuers) do
    if Pursuers[i].active then
      if AdvanceOne(Pursuers[i], partyMap, partyX, partyY, provider,
           maxStates) then begin
        AdvanceOver := i;   { the caller resolves this catch into a fight }
        exit;
      end;
end;

function PursuitProvider(const name: string; out m: TMapData): boolean;
var
  isDyn: boolean;
  ver, depth: longint;
  seed: longword;
begin
  PursuitProvider := SourceMap(name, false, m, isDyn, ver, seed, depth);
end;

function PursuitAdvance(const partyMap: string; partyX, partyY: longint): longint;
begin
  PursuitAdvance := AdvanceOver(partyMap, partyX, partyY, @PursuitProvider,
    ROUTE_MAX_STATES);
end;

function PursuitTick(const partyMap: string; partyX, partyY: longint): longint;
var
  due, i, caught: longint;
begin
  PursuitTick := -1;
  { with no hunters, just keep the clock mark current so a hunter spawned
    later does not inherit a backlog of moves. }
  if ActivePursuerCount = 0 then begin
    gLastClock := ClockMin;
    exit;
  end;
  if ClockMin <= gLastClock then exit;   { no time has passed (or a reset) }
  due := longint((ClockMin - gLastClock) div MINUTES_PER_STEP);
  gLastClock := ClockMin;                { consume all elapsed time }
  if due <= 0 then exit;
  if due > MAX_TICK_STEPS then due := MAX_TICK_STEPS;
  for i := 1 to due do begin
    caught := AdvanceOver(partyMap, partyX, partyY, @PursuitProvider,
      ROUTE_MAX_STATES);
    if caught >= 0 then begin
      PursuitTick := caught;
      exit;
    end;
  end;
end;

end.
