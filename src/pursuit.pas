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

type
  TPursuer = record
    mon: longint;      { the monster, an index into MonDefs }
    map: string;       { the map it is on }
    x, y: longint;     { its tile }
    active: boolean;
  end;

var
  Pursuers: array of TPursuer;

procedure PursuitReset;
{ Add a hunter and return its index. }
function AddPursuer(monIdx: longint; const map: string; x, y: longint): longint;
procedure RemovePursuer(idx: longint);
{ Drop every hunter, for example on reaching a safe hub. }
procedure PursuitClear;
function ActivePursuerCount: longint;
{ Whether any active hunter stands on the given map. }
function HunterOnMap(const map: string): boolean;

{ The movement core, testable with an injected map provider. Advance every
  active pursuer one tile toward (partyX,partyY) on partyMap. Returns the
  index of the first pursuer that has caught the party (left active for the
  caller to resolve), or -1 if none caught them this step. }
function AdvanceOver(const partyMap: string; partyX, partyY: longint;
  provider: TRouteMapProvider; maxStates: longint): longint;

{ The runtime advance: AdvanceOver wired to the live omniscient provider
  (maps sourced in full from the pak and generators, no fog). }
function PursuitAdvance(const partyMap: string; partyX, partyY: longint): longint;

implementation

uses
  pathfind, worldload;

procedure PursuitReset;
begin
  Pursuers := nil;
end;

function AddPursuer(monIdx: longint; const map: string; x, y: longint): longint;
begin
  SetLength(Pursuers, Length(Pursuers) + 1);
  AddPursuer := High(Pursuers);
  Pursuers[AddPursuer].mon := monIdx;
  Pursuers[AddPursuer].map := map;
  Pursuers[AddPursuer].x := x;
  Pursuers[AddPursuer].y := y;
  Pursuers[AddPursuer].active := true;
end;

procedure RemovePursuer(idx: longint);
begin
  if (idx >= 0) and (idx <= High(Pursuers)) then
    Pursuers[idx].active := false;
end;

procedure PursuitClear;
var
  i: longint;
begin
  for i := 0 to High(Pursuers) do
    Pursuers[i].active := false;
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

function AdvanceOne(var p: TPursuer; const partyMap: string;
  partyX, partyY: longint; provider: TRouteMapProvider;
  maxStates: longint): boolean;
{** Move one pursuer a single tile toward the party. Returns true if it has
  caught them (before or after the move). }
var
  m: TMapData;
  wx, wy, nsteps: longint;
  atGoal: boolean;
  path: array[0 .. 2047] of TPathStep;
begin
  AdvanceOne := false;
  if not p.active then exit;
  if not provider(p.map, m) then exit;   { its map is gone; hold position }

  if p.map = partyMap then begin
    if Caught(p, partyX, partyY) then begin AdvanceOne := true; exit; end;
    { chase on the shared map: one step along the shortest path. }
    if FindPath(m, p.x, p.y, partyX, partyY, true, path, nsteps)
       and (nsteps >= 2) then begin
      p.x := path[1].x;
      p.y := path[1].y;
    end;
    AdvanceOne := Caught(p, partyX, partyY);
    exit;
  end;

  { the party is on another map: head for the portal that begins the
    shortest route to them, and cross it on arrival. }
  if not NextHopOver(m, p.map, p.x, p.y, partyMap, partyX, partyY,
       provider, maxStates, wx, wy, atGoal) then exit;   { no route; hold }
  if (p.x <> wx) or (p.y <> wy) then
    if FindPath(m, p.x, p.y, wx, wy, true, path, nsteps) and (nsteps >= 2) then
    begin
      p.x := path[1].x;
      p.y := path[1].y;
    end;
  CrossIfOnPortal(p, m, provider);
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

end.
