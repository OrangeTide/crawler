unit codex;

{** Reference knowledge the party builds up: which monsters they have met in
  battle, and which item kinds they have identified. Both are sized to the
  loaded content tables and saved with the game. A leaf unit: it reads the
  table lengths and nothing calls back into it from below. }

{$mode objfpc}{$H+}

interface

uses
  monsters, items;

var
  MonSeen: array of boolean;    { by MonDefs index: met in a fight }
  ItemIdent: array of boolean;  { by ItemDefs index: the kind is identified }

procedure CodexReset;
{ Mark a monster met. Out-of-range indices are ignored, so the engine can
  call it before the codex has been sized (as the unit tests do). }
procedure MarkMonSeen(mi: longint);
function MonIsSeen(mi: longint): boolean;
function MonSeenCount: longint;
procedure MarkItemKnown(di: longint);
function ItemIsKnown(di: longint): boolean;
{ The name to show for an item: its true name once the kind is known,
  otherwise a generic label by kind. }
function ItemLabel(di: longint): string;

implementation

procedure CodexReset;
var i: longint;
begin
  SetLength(MonSeen, Length(MonDefs));
  for i := 0 to High(MonSeen) do MonSeen[i] := false;
  SetLength(ItemIdent, Length(ItemDefs));
  { everything is known by default; the mystery items turn their bit off }
  for i := 0 to High(ItemIdent) do ItemIdent[i] := true;
  for i := 0 to High(ItemDefs) do
    if (ItemDefs[i].flags and IF_MYSTERY) <> 0 then ItemIdent[i] := false;
end;

procedure MarkMonSeen(mi: longint);
begin
  if (mi >= 0) and (mi <= High(MonSeen)) then MonSeen[mi] := true;
end;

function MonIsSeen(mi: longint): boolean;
begin
  MonIsSeen := (mi >= 0) and (mi <= High(MonSeen)) and MonSeen[mi];
end;

function MonSeenCount: longint;
var i, n: longint;
begin
  n := 0;
  for i := 0 to High(MonSeen) do
    if MonSeen[i] then inc(n);
  MonSeenCount := n;
end;

procedure MarkItemKnown(di: longint);
begin
  if (di >= 0) and (di <= High(ItemIdent)) then ItemIdent[di] := true;
end;

function ItemIsKnown(di: longint): boolean;
begin
  { an unsized or out-of-range entry reads as known, so display never hides a
    name the codex does not track }
  if (di < 0) or (di > High(ItemIdent)) then ItemIsKnown := true
  else ItemIsKnown := ItemIdent[di];
end;

function ItemLabel(di: longint): string;
begin
  if (di < 0) or (di > High(ItemDefs)) then ItemLabel := ''
  else if ItemIsKnown(di) then ItemLabel := ItemDefs[di].name
  else if ItemDefs[di].kind = IK_POTION then ItemLabel := 'UNKNOWN POTION'
  else ItemLabel := 'UNKNOWN ITEM';
end;

end.
