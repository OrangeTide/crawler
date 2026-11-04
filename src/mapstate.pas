unit mapstate;

{** Per-map persistent state: fog of war and door positions.

  One map is resident at a time. When the party leaves a map its fog and
  door states are captured into a snapshot keyed by map name, and
  restored on return, so visited areas stay explored. The save system
  serialises these snapshots. Dynamic maps also store their seed here
  later, so a regenerated level keeps its changes. }

{$mode objfpc}{$H+}

interface

uses
  world;

type
  TMapSnapshot = record
    name: string[12];
    w, h: longint;
    seen: array of byte;      { w*h visibility states }
    doors: array of byte;     { w*h, 1 = open }
  end;

var
  Snapshots: array of TMapSnapshot;

procedure MapStateReset;
procedure MapStateCapture(const name: string);
function MapStateRestore(const name: string): boolean;
function SnapshotIndex(const name: string): longint;

implementation

procedure MapStateReset;
begin
  Snapshots := nil;
end;

function SnapshotIndex(const name: string): longint;
var
  i: longint;
begin
  for i := 0 to High(Snapshots) do
    if Snapshots[i].name = name then begin SnapshotIndex := i; exit; end;
  SnapshotIndex := -1;
end;

procedure MapStateCapture(const name: string);
var
  idx, x, y: longint;
begin
  if name = '' then exit;
  idx := SnapshotIndex(name);
  if idx < 0 then begin
    SetLength(Snapshots, Length(Snapshots) + 1);
    idx := High(Snapshots);
    Snapshots[idx].name := name;
  end;
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
  MapStateRestore := true;
end;

end.
