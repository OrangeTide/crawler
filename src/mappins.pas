unit mappins;

{** Pins the player drops on the full map, plus auto-markers the game places
  on discovered stairs, portals and service NPCs. Each tile holds at most one
  pin. Manual pins cycle through a few preset kinds; auto pins are read-only
  and are left in place by the manual cycle. Saved with the game. }

{$mode objfpc}{$H+}

interface

const
  PIN_NONE   = 0;
  { manual kinds, cycled by a right click }
  PIN_BANG   = 1;   { ! a point of interest }
  PIN_QUERY  = 2;   { ? a thing to look into }
  PIN_STAR   = 3;   { * a prize or goal }
  { auto kinds, dropped on discovery }
  PIN_STAIR  = 4;
  PIN_PORTAL = 5;
  PIN_SHOP   = 6;

type
  TPin = record
    map: string[31];
    x, y: smallint;
    kind: byte;
  end;

var
  Pins: array of TPin;

procedure PinsReset;
function PinCount: longint;
function PinKindAt(const map: string; x, y: longint): byte;
{ Right-click cycle on a tile: none -> ! -> ? -> * -> none. A tile holding an
  auto marker is left untouched. }
procedure PinCycleManual(const map: string; x, y: longint);
{ Drop an auto marker on a tile, only if it holds no pin yet. }
procedure PinSetAuto(const map: string; x, y, kind: longint);

implementation

function PinIndex(const map: string; x, y: longint): longint;
var i: longint;
begin
  PinIndex := -1;
  for i := 0 to High(Pins) do
    if (Pins[i].x = x) and (Pins[i].y = y) and (Pins[i].map = map) then begin
      PinIndex := i;
      exit;
    end;
end;

procedure PinsReset;
begin
  Pins := nil;
end;

function PinCount: longint;
begin
  PinCount := Length(Pins);
end;

function PinKindAt(const map: string; x, y: longint): byte;
var i: longint;
begin
  i := PinIndex(map, x, y);
  if i < 0 then PinKindAt := PIN_NONE else PinKindAt := Pins[i].kind;
end;

procedure RemoveAt(i: longint);
var j: longint;
begin
  for j := i to High(Pins) - 1 do Pins[j] := Pins[j + 1];
  SetLength(Pins, Length(Pins) - 1);
end;

procedure AddPin(const map: string; x, y, kind: longint);
begin
  SetLength(Pins, Length(Pins) + 1);
  Pins[High(Pins)].map := map;
  Pins[High(Pins)].x := x;
  Pins[High(Pins)].y := y;
  Pins[High(Pins)].kind := kind;
end;

procedure PinCycleManual(const map: string; x, y: longint);
var i: longint;
begin
  i := PinIndex(map, x, y);
  if i < 0 then begin
    AddPin(map, x, y, PIN_BANG);
    exit;
  end;
  case Pins[i].kind of
    PIN_BANG:  Pins[i].kind := PIN_QUERY;
    PIN_QUERY: Pins[i].kind := PIN_STAR;
    PIN_STAR:  RemoveAt(i);
    { an auto marker is read-only: leave it as it is }
  end;
end;

procedure PinSetAuto(const map: string; x, y, kind: longint);
begin
  if PinIndex(map, x, y) < 0 then AddPin(map, x, y, kind);
end;

end.
