unit spellbook;

{** Known spells for caster characters.

  A caster does not command its whole domain. It learns a growing list of
  spells, chosen as it levels up, and only those it knows reach its combat
  menu and its spell list. This unit holds the shared rules both combat and
  the meta screen read: the highest spell level a character reaches, how many
  spells it may know, which catalog spells it may still learn, and the
  known-list queries. The known ids live on the character and in the save. }

{$mode objfpc}{$H+}

interface

uses party, chardata, spelldb;

{ The highest spell level a caster of this character level reaches. }
function MaxSpellLevel(const c: TCharacter): longint;
{ True when the character's class draws from a spell domain. }
function CharIsCaster(const c: TCharacter): boolean;
{ How many spells a caster of this level is meant to know. }
function SpellsKnownTarget(const c: TCharacter): longint;
{ Whether the character already knows a spell, by catalog id or index. }
function CharKnowsID(const c: TCharacter; const id: string): boolean;
function CharKnows(const c: TCharacter; cat: longint): boolean;
{ Add a catalog spell to the character's known list, once. }
procedure CharLearn(var c: TCharacter; cat: longint);
{ The spells this caster may still learn now: its domain, up to the level it
  reaches, not already known. Ordered by spell level then catalog order. }
function LearnableCount(const c: TCharacter): longint;
function LearnableNth(const c: TCharacter; n: longint): longint;
{ The spells this caster has learned, by catalog index, in spell-level order. }
function KnownCount(const c: TCharacter): longint;
function KnownNth(const c: TCharacter; n: longint): longint;
{ How many spells this caster is owed and can still pick right now. }
function PendingLearns(const c: TCharacter): longint;
{ The first roster member with a spell to pick, or -1 when none is waiting. }
function NextLearner: longint;
{ Fill a caster's known list up to its target without the pick UI, favouring
  castable spells, for generated parties and hirelings. }
procedure AutoLearn(var c: TCharacter);

implementation

function MaxSpellLevel(const c: TCharacter): longint;
begin
  MaxSpellLevel := (c.level + 1) div 2;
  if MaxSpellLevel < 1 then MaxSpellLevel := 1;
  if MaxSpellLevel > 6 then MaxSpellLevel := 6;
end;

function CharIsCaster(const c: TCharacter): boolean;
begin
  CharIsCaster := ClassDomain(c.klass) <> SPD_NONE;
end;

function SpellsKnownTarget(const c: TCharacter): longint;
begin
  { one spell at creation plus one for each level gained }
  SpellsKnownTarget := c.level + 1;
end;

function CharKnowsID(const c: TCharacter; const id: string): boolean;
var i: longint;
begin
  CharKnowsID := true;
  for i := 0 to High(c.known) do
    if c.known[i] = id then exit;
  CharKnowsID := false;
end;

function CharKnows(const c: TCharacter; cat: longint): boolean;
begin
  CharKnows := (cat >= 0) and (cat < SpellDefCount)
    and CharKnowsID(c, SpellDefs[cat].id);
end;

procedure CharLearn(var c: TCharacter; cat: longint);
begin
  if (cat < 0) or (cat >= SpellDefCount) then exit;
  if CharKnowsID(c, SpellDefs[cat].id) then exit;
  SetLength(c.known, Length(c.known) + 1);
  c.known[High(c.known)] := SpellDefs[cat].id;
end;

{ Gather the catalog indices this caster may still learn, level-ordered. }
procedure BuildLearnable(const c: TCharacter; out arr: array of longint;
  out cnt: longint);
var dom, lvl, i, j, tmp: longint;
begin
  cnt := 0;
  dom := ClassDomain(c.klass);
  if dom = SPD_NONE then exit;
  lvl := MaxSpellLevel(c);
  for i := 0 to SpellDefCount - 1 do
    if (SpellDefs[i].domain = dom) and (SpellDefs[i].level <= lvl)
      and not CharKnows(c, i) then begin
      if cnt > High(arr) then break;
      arr[cnt] := i;
      inc(cnt);
    end;
  for i := 1 to cnt - 1 do begin
    tmp := arr[i]; j := i - 1;
    while (j >= 0) and (SpellDefs[arr[j]].level > SpellDefs[tmp].level) do begin
      arr[j + 1] := arr[j]; dec(j);
    end;
    arr[j + 1] := tmp;
  end;
end;

function LearnableCount(const c: TCharacter): longint;
var arr: array[0..255] of longint; n: longint;
begin
  BuildLearnable(c, arr, n);
  LearnableCount := n;
end;

function LearnableNth(const c: TCharacter; n: longint): longint;
var arr: array[0..255] of longint; cnt: longint;
begin
  LearnableNth := -1;
  BuildLearnable(c, arr, cnt);
  if (n >= 0) and (n < cnt) then LearnableNth := arr[n];
end;

{ Gather the catalog indices this caster has learned, level-ordered. }
procedure BuildKnown(const c: TCharacter; out arr: array of longint;
  out cnt: longint);
var i, j, tmp: longint;
begin
  cnt := 0;
  for i := 0 to SpellDefCount - 1 do
    if CharKnows(c, i) then begin
      if cnt > High(arr) then break;
      arr[cnt] := i;
      inc(cnt);
    end;
  for i := 1 to cnt - 1 do begin
    tmp := arr[i]; j := i - 1;
    while (j >= 0) and (SpellDefs[arr[j]].level > SpellDefs[tmp].level) do begin
      arr[j + 1] := arr[j]; dec(j);
    end;
    arr[j + 1] := tmp;
  end;
end;

function KnownCount(const c: TCharacter): longint;
var arr: array[0..255] of longint; n: longint;
begin
  BuildKnown(c, arr, n);
  KnownCount := n;
end;

function KnownNth(const c: TCharacter; n: longint): longint;
var arr: array[0..255] of longint; cnt: longint;
begin
  KnownNth := -1;
  BuildKnown(c, arr, cnt);
  if (n >= 0) and (n < cnt) then KnownNth := arr[n];
end;

function PendingLearns(const c: TCharacter): longint;
var owed, avail: longint;
begin
  PendingLearns := 0;
  if not CharIsCaster(c) then exit;
  owed := SpellsKnownTarget(c) - Length(c.known);
  if owed <= 0 then exit;
  avail := LearnableCount(c);
  if owed > avail then owed := avail;
  PendingLearns := owed;
end;

function NextLearner: longint;
var i: longint;
begin
  NextLearner := -1;
  for i := 0 to High(Roster) do
    if PendingLearns(Roster[i]) > 0 then begin NextLearner := i; exit; end;
end;

procedure AutoLearn(var c: TCharacter);
var arr: array[0..255] of longint; cnt, i, pick: longint;
begin
  if not CharIsCaster(c) then exit;
  while PendingLearns(c) > 0 do begin
    BuildLearnable(c, arr, cnt);
    if cnt = 0 then break;
    { favour a castable spell so a generated caster can fight }
    pick := arr[0];
    for i := 0 to cnt - 1 do
      if SpellDefs[arr[i]].castable then begin pick := arr[i]; break; end;
    CharLearn(c, pick);
  end;
end;

end.
