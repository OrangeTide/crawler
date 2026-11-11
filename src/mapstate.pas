unit mapstate;

{** Per-map persistent state: fog of war and door positions.

  One map is resident at a time. When the party leaves a map its fog and
  door states are captured into a snapshot keyed by map name, and
  restored on return, so visited areas stay explored. The save system
  serialises these snapshots. Dynamic maps also store their seed here
  later, so a regenerated level keeps its changes.

  The snapshot store is the main growth risk against the PS1 2 MB main-RAM
  budget (design section 23): the seeded world is vast, so an unbounded
  store would accumulate a fog and door snapshot per visited map without
  limit. An LRU keeps it under SNAPSHOT_CAP_BYTES by dropping the
  least-recently-visited maps, and a resident estimate lets the loader warn
  when the main-RAM set approaches the budget. A dropped map simply loses
  its remembered fog and open doors; its terrain regenerates from the seed
  on return, so the bound costs memory of far-off places, not consistency. }

{$mode objfpc}{$H+}

interface

uses
  world;

const
  { The whole main-RAM target on the tightest shipping platform. }
  MAIN_RAM_BUDGET     = 2 * 1024 * 1024;
  { A rough resident baseline the design puts well under 100 KB (code, the
    loaded tables, game state, audio), rounded up, added to the snapshot
    store to estimate the resident set. }
  RESIDENT_BASE_BYTES = 128 * 1024;
  { Bound on the snapshot store, set so the estimated resident set stays
    under the budget even when the store is full. }
  SNAPSHOT_CAP_BYTES  = MAIN_RAM_BUDGET - RESIDENT_BASE_BYTES;
  { Warn once the estimated resident set passes seven eighths of the budget,
    before the LRU has to start dropping maps. }
  BUDGET_WARN_BYTES   = MAIN_RAM_BUDGET - MAIN_RAM_BUDGET div 8;

type
  TMapSnapshot = record
    name: string[12];
    w, h: longint;
    seen: array of byte;      { w*h visibility states }
    doors: array of byte;     { w*h, 1 = open }
    isDynamic: boolean;       { generated from a seed, not a pak lump }
    version: longint;         { generator version it was made with }
    seed: longword;           { the seed to regenerate it }
    touch: longword;          { access tick, for LRU eviction }
  end;

var
  Snapshots: array of TMapSnapshot;

procedure MapStateReset;
procedure MapStateCapture(const name: string);
function MapStateRestore(const name: string): boolean;
function SnapshotIndex(const name: string): longint;
function MapStateEnsure(const name: string): longint;
function MapStateGetSeed(const name: string; out version: longint;
  out seed: longword): boolean;
procedure MapStateSetDynamic(const name: string; version: longint; seed: longword);
{ Resident-memory instrumentation and the LRU bound on the store. }
function MapStateBytes: longint;          { fog and door bytes held resident }
function MapStateResidentBytes: longint;  { the whole estimated resident set }
function MapStateOverBudget: boolean;     { resident estimate near the cap }
procedure MapStateTrim(const keep: string);  { LRU-evict to the byte cap }
procedure MapStateReindexTouch;           { reseed LRU order after a load }

implementation

var
  gTouch: longword;   { monotonic access clock driving the LRU }

function NextTouch: longword;
begin
  inc(gTouch);
  NextTouch := gTouch;
end;

procedure MapStateReset;
begin
  Snapshots := nil;
  gTouch := 0;
end;

function SnapshotIndex(const name: string): longint;
var
  i: longint;
begin
  for i := 0 to High(Snapshots) do
    if Snapshots[i].name = name then begin SnapshotIndex := i; exit; end;
  SnapshotIndex := -1;
end;

function MapStateEnsure(const name: string): longint;
{** Return the snapshot index for name, creating an empty one if needed. }
begin
  MapStateEnsure := SnapshotIndex(name);
  if MapStateEnsure < 0 then begin
    SetLength(Snapshots, Length(Snapshots) + 1);
    MapStateEnsure := High(Snapshots);
    Snapshots[MapStateEnsure].name := name;
    Snapshots[MapStateEnsure].w := 0;
    Snapshots[MapStateEnsure].h := 0;
    Snapshots[MapStateEnsure].seen := nil;
    Snapshots[MapStateEnsure].doors := nil;
    Snapshots[MapStateEnsure].isDynamic := false;
    Snapshots[MapStateEnsure].version := 0;
    Snapshots[MapStateEnsure].seed := 0;
  end;
  Snapshots[MapStateEnsure].touch := NextTouch;   { most recently visited }
end;

function MapStateGetSeed(const name: string; out version: longint;
  out seed: longword): boolean;
var
  idx: longint;
begin
  MapStateGetSeed := false;
  version := 0; seed := 0;
  idx := SnapshotIndex(name);
  if idx < 0 then exit;
  if not Snapshots[idx].isDynamic then exit;
  version := Snapshots[idx].version;
  seed := Snapshots[idx].seed;
  Snapshots[idx].touch := NextTouch;
  MapStateGetSeed := true;
end;

procedure MapStateSetDynamic(const name: string; version: longint; seed: longword);
var
  idx: longint;
begin
  idx := MapStateEnsure(name);
  Snapshots[idx].isDynamic := true;
  Snapshots[idx].version := version;
  Snapshots[idx].seed := seed;
end;

procedure MapStateCapture(const name: string);
var
  idx, x, y: longint;
begin
  if name = '' then exit;
  idx := MapStateEnsure(name);
  Snapshots[idx].w := MapW;
  Snapshots[idx].h := MapH;
  SetLength(Snapshots[idx].seen, MapW * MapH);
  SetLength(Snapshots[idx].doors, MapW * MapH);
  for y := 0 to MapH - 1 do
    for x := 0 to MapW - 1 do begin
      Snapshots[idx].seen[y * MapW + x] := Seen[y][x];
      if DoorOpen[y][x] then
        Snapshots[idx].doors[y * MapW + x] := 1
      else
        Snapshots[idx].doors[y * MapW + x] := 0;
    end;
end;

function MapStateRestore(const name: string): boolean;
var
  idx, x, y: longint;
begin
  MapStateRestore := false;
  idx := SnapshotIndex(name);
  if idx < 0 then exit;
  if (Snapshots[idx].w <> MapW) or (Snapshots[idx].h <> MapH) then exit;
  for y := 0 to MapH - 1 do
    for x := 0 to MapW - 1 do begin
      Seen[y][x] := Snapshots[idx].seen[y * MapW + x];
      DoorOpen[y][x] := Snapshots[idx].doors[y * MapW + x] <> 0;
    end;
  Snapshots[idx].touch := NextTouch;
  MapStateRestore := true;
end;

{ ---- resident-memory instrumentation and the LRU bound ---- }

function SnapBytes(const s: TMapSnapshot): longint;
begin
  SnapBytes := Length(s.seen) + Length(s.doors);
end;

function MapStateBytes: longint;
var
  i: longint;
begin
  MapStateBytes := 0;
  for i := 0 to High(Snapshots) do
    MapStateBytes := MapStateBytes + SnapBytes(Snapshots[i]);
end;

function MapStateResidentBytes: longint;
begin
  MapStateResidentBytes := RESIDENT_BASE_BYTES + MapStateBytes;
end;

function MapStateOverBudget: boolean;
begin
  MapStateOverBudget := MapStateResidentBytes >= BUDGET_WARN_BYTES;
end;

procedure DropSnapshot(idx: longint);
{** Remove one snapshot, filling the gap with the last so the array stays
  packed. Order does not matter: lookups are by name and the LRU reads touch. }
begin
  if (idx < 0) or (idx > High(Snapshots)) then exit;
  Snapshots[idx] := Snapshots[High(Snapshots)];
  SetLength(Snapshots, Length(Snapshots) - 1);
end;

procedure MapStateTrim(const keep: string);
{** Drop least-recently-visited snapshots until the store fits the byte cap,
  never evicting the named map (the one resident now). }
var
  total, victim, i: longint;
  lowTouch: longword;
begin
  total := MapStateBytes;
  while total > SNAPSHOT_CAP_BYTES do begin
    victim := -1;
    lowTouch := High(longword);
    for i := 0 to High(Snapshots) do
      if (Snapshots[i].name <> keep) and (Snapshots[i].touch <= lowTouch) then
      begin
        lowTouch := Snapshots[i].touch;
        victim := i;
      end;
    if victim < 0 then break;   { only the kept map remains; cannot shrink }
    total := total - SnapBytes(Snapshots[victim]);
    DropSnapshot(victim);
  end;
end;

procedure MapStateReindexTouch;
{** After a load the snapshots carry no access order (touch is not saved), so
  reseed it in array order and leave the clock past the last one. }
var
  i: longint;
begin
  for i := 0 to High(Snapshots) do
    Snapshots[i].touch := longword(i + 1);
  gTouch := Length(Snapshots);
end;

end.
