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
{ Whether a caster may learn or cast a catalog spell. A specialist mage is
  barred from its school's opposition schools, except Lesser Divination (any
  divination spell of level 4 or lower), which every mage keeps. Generalists
  and non-arcane casters allow everything in their domain. }
function SpellAllowed(const c: TCharacter; cat: longint): boolean;
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

{ ---- prepared spells (the optional memorization layer) ---- }
{ How many spells of a given spell level a caster may ready at once: one slot
  when the level first opens, and one more every six character levels past
  that, mirroring an AD&D slots-by-level table. Zero for an unreachable level. }
function PreparedSlotsAt(const c: TCharacter; spellLevel: longint): longint;
{ Whether a known spell is currently readied, by id or catalog index. }
function CharPreparedID(const c: TCharacter; const id: string): boolean;
function CharPrepared(const c: TCharacter; cat: longint): boolean;
{ How many spells of a given spell level the caster has readied. }
function PreparedCountAt(const c: TCharacter; spellLevel: longint): longint;
{ Ready or un-ready a known spell. Readying fails (returns the unchanged state)
  when that spell level's slots are full; un-readying always works. Returns the
  resulting readied state. }
function TogglePrepared(var c: TCharacter; cat: longint): boolean;
{ Drop readied ids the caster no longer knows, and any that overflow their
  level's slots. Called when the known list or level changes. }
procedure PrunePrepared(var c: TCharacter);

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

function SpellAllowed(const c: TCharacter; cat: longint): boolean;
var fav: byte;
begin
  SpellAllowed := false;
  if (cat < 0) or (cat >= SpellDefCount) then exit;
  SpellAllowed := true;
  if SpellDefs[cat].domain <> SPD_MAGE then exit;   { schools gate arcane only }
  fav := ClassSchool(c.klass);
  if fav = SCH_NONE then exit;                       { a generalist draws all }
  { Lesser Divination stays open to every mage }
  if (SpellDefs[cat].school = SCH_DIVIN) and (SpellDefs[cat].level <= 4) then exit;
  if SchoolOpposes(fav, SpellDefs[cat].school) then SpellAllowed := false;
end;

function SpellsKnownTarget(const c: TCharacter): longint;
begin
  { one spell at creation plus one for each level gained }
  SpellsKnownTarget := c.level + 1;
  { a specialist mage knows one extra for its focus }
  if ClassSchool(c.klass) <> SCH_NONE then inc(SpellsKnownTarget);
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

{ ---- prepared spells ---- }

function CatOfId(const id: string): longint;
var i: longint;
begin
  CatOfId := -1;
  for i := 0 to SpellDefCount - 1 do
    if SpellDefs[i].id = id then begin CatOfId := i; exit; end;
end;

function PreparedSlotsAt(const c: TCharacter; spellLevel: longint): longint;
var unlock: longint;
begin
  PreparedSlotsAt := 0;
  if (spellLevel < 1) or (spellLevel > MaxSpellLevel(c)) then exit;
  unlock := 2 * spellLevel - 1;   { L1 opens at level 1, L2 at 3, L3 at 5, ... }
  if c.level < unlock then exit;
  PreparedSlotsAt := 1 + (c.level - unlock) div 6;
end;

function CharPreparedID(const c: TCharacter; const id: string): boolean;
var i: longint;
begin
  CharPreparedID := true;
  for i := 0 to High(c.prepared) do
    if c.prepared[i] = id then exit;
  CharPreparedID := false;
end;

function CharPrepared(const c: TCharacter; cat: longint): boolean;
begin
  CharPrepared := (cat >= 0) and (cat < SpellDefCount)
    and CharPreparedID(c, SpellDefs[cat].id);
end;

function PreparedCountAt(const c: TCharacter; spellLevel: longint): longint;
var i, cat, cnt: longint;
begin
  cnt := 0;
  for i := 0 to High(c.prepared) do begin
    cat := CatOfId(c.prepared[i]);
    if (cat >= 0) and (SpellDefs[cat].level = spellLevel) then inc(cnt);
  end;
  PreparedCountAt := cnt;
end;

procedure RemovePreparedID(var c: TCharacter; const id: string);
var i, j: longint;
begin
  j := 0;
  for i := 0 to High(c.prepared) do
    if c.prepared[i] <> id then begin c.prepared[j] := c.prepared[i]; inc(j); end;
  SetLength(c.prepared, j);
end;

function TogglePrepared(var c: TCharacter; cat: longint): boolean;
var lvl: longint;
begin
  TogglePrepared := false;
  if (cat < 0) or (cat >= SpellDefCount) then exit;
  if not CharKnowsID(c, SpellDefs[cat].id) then exit;
  if CharPreparedID(c, SpellDefs[cat].id) then begin
    RemovePreparedID(c, SpellDefs[cat].id);   { un-ready always works }
    exit;
  end;
  lvl := SpellDefs[cat].level;
  if PreparedCountAt(c, lvl) >= PreparedSlotsAt(c, lvl) then exit;  { slots full }
  SetLength(c.prepared, Length(c.prepared) + 1);
  c.prepared[High(c.prepared)] := SpellDefs[cat].id;
  TogglePrepared := true;
end;

procedure PrunePrepared(var c: TCharacter);
var
  i, cat, lvl: longint;
  kept: array of string[16];
  usedAt: array[0 .. 15] of longint;
begin
  for i := 0 to 15 do usedAt[i] := 0;
  SetLength(kept, 0);
  for i := 0 to High(c.prepared) do begin
    cat := CatOfId(c.prepared[i]);
    if cat < 0 then continue;                           { unknown catalog id }
    if not CharKnowsID(c, c.prepared[i]) then continue; { no longer known }
    lvl := SpellDefs[cat].level;
    if (lvl < 1) or (lvl > 15) then continue;
    if usedAt[lvl] >= PreparedSlotsAt(c, lvl) then continue;  { over its slots }
    SetLength(kept, Length(kept) + 1);
    kept[High(kept)] := c.prepared[i];
    inc(usedAt[lvl]);
  end;
  c.prepared := kept;
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
      and SpellAllowed(c, i) and not CharKnows(c, i) then begin
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
