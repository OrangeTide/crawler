unit flags;

{** Global story flags and a simple quest journal.

  A flag is a named boolean the dialog and world systems set and test:
  quest state, doors unlocked by a password, NPCs already met. Journal
  entries are short lines the game adds as quests progress. Both are
  part of the save. }

{$mode objfpc}{$H+}

interface

var
  FlagNames: array of string;
  Journal: array of string;

procedure FlagsReset;
procedure FlagSet(const name: string);
procedure FlagClear(const name: string);
function FlagHas(const name: string): boolean;
procedure JournalAdd(const line: string);
{ Add a line only if it is not already in the journal, so a repeated sync does
  not duplicate it across saves and reloads. }
procedure JournalAddOnce(const line: string);

implementation

procedure FlagsReset;
begin
  FlagNames := nil;
  Journal := nil;
end;

function FlagIndex(const name: string): longint;
var
  i: longint;
begin
  for i := 0 to High(FlagNames) do
    if FlagNames[i] = name then begin FlagIndex := i; exit; end;
  FlagIndex := -1;
end;

procedure FlagSet(const name: string);
begin
  if FlagIndex(name) >= 0 then exit;
  SetLength(FlagNames, Length(FlagNames) + 1);
  FlagNames[High(FlagNames)] := name;
end;

procedure FlagClear(const name: string);
var
  i, idx: longint;
begin
  idx := FlagIndex(name);
  if idx < 0 then exit;
  for i := idx to High(FlagNames) - 1 do
    FlagNames[i] := FlagNames[i + 1];
  SetLength(FlagNames, Length(FlagNames) - 1);
end;

function FlagHas(const name: string): boolean;
begin
  FlagHas := FlagIndex(name) >= 0;
end;

procedure JournalAdd(const line: string);
begin
  SetLength(Journal, Length(Journal) + 1);
  Journal[High(Journal)] := line;
end;

procedure JournalAddOnce(const line: string);
var i: longint;
begin
  for i := 0 to High(Journal) do
    if Journal[i] = line then exit;
  JournalAdd(line);
end;

end.
