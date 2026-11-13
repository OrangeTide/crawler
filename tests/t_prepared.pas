program t_prepared;

{** Prepared-spell subset (optional). When the option is on, a caster may only
  cast spells it has readied, and readying is bounded by per-spell-level slots
  (1 at a level's unlock, +1 every six character levels). These checks cover the
  slot math, the ready/un-ready gate, the combat-menu filter, and pruning. }

{$mode objfpc}{$H+}

uses
  sysutils, pak, rng, rules, items, chardata, monsters, spelldb, spellbook,
  party, combatstate, combatcore, testing;

var
  p: TPak;
  ab: TAbilityScores;
  a: TAbility;
  mm, sg, acid: longint;

{ catalog index of a spell id, or -1 }
function CatOf(const id: string): longint;
var k: longint;
begin
  CatOf := -1;
  for k := 0 to SpellDefCount - 1 do
    if SpellDefs[k].id = id then begin CatOf := k; exit; end;
end;

{ the combat spell count for Roster[0] as the current actor }
function CastCount: longint;
begin
  Active^.CurActor := 0;
  ResetSpellList;
  CastCount := SpellCount;
end;

begin
  if not PakLoad('build/game.pak', p) then begin
    writeln('  FAIL could not load build/game.pak (run make first)');
    halt(2);
  end;
  Check(LoadItems(p), 'load items');
  Check(LoadCharData(p), 'load character data');
  Check(LoadMonsters(p), 'load monsters');
  Check(LoadSpells(p), 'load spells');

  mm := CatOf('M_MAGICMISSILE'); sg := CatOf('M_SHOCKINGGRASP');
  acid := CatOf('M_ACIDARROW');
  Check((mm >= 0) and (sg >= 0) and (acid >= 0), 'the sample spells exist');

  for a := abSTR to abCHA do ab[a] := 14;
  SetLength(Roster, 1);
  MakeCharacter(Roster[0], 'Mage', SpeciesIndex('HUMAN'),
    ClassIndex('WIZARD'), 0, ab);

  { ---- the slots-by-level table ---- }
  Roster[0].level := 1;
  CheckEqI(PreparedSlotsAt(Roster[0], 1), 1, 'L1 caster has one L1 slot');
  CheckEqI(PreparedSlotsAt(Roster[0], 2), 0, 'L1 caster has no L2 slots');
  Roster[0].level := 5;
  CheckEqI(PreparedSlotsAt(Roster[0], 1), 1, 'L5 caster: one L1 slot');
  CheckEqI(PreparedSlotsAt(Roster[0], 2), 1, 'L5 caster: one L2 slot');
  CheckEqI(PreparedSlotsAt(Roster[0], 3), 1, 'L5 caster: one L3 slot');
  CheckEqI(PreparedSlotsAt(Roster[0], 4), 0, 'L5 caster: no L4 slot yet');
  Roster[0].level := 7;
  CheckEqI(PreparedSlotsAt(Roster[0], 1), 2, 'L7 caster: a second L1 slot opens');

  { ---- the ready gate at level 1 (one L1 slot) ---- }
  Roster[0].level := 1;
  Roster[0].known := nil; Roster[0].prepared := nil;
  CharLearn(Roster[0], mm);
  CharLearn(Roster[0], sg);
  Check(TogglePrepared(Roster[0], mm), 'readying Magic Missile fills the slot');
  Check(CharPrepared(Roster[0], mm), 'Magic Missile reads as readied');
  Check(not TogglePrepared(Roster[0], sg), 'a second L1 spell will not fit');
  Check(not CharPrepared(Roster[0], sg), 'so Shocking Grasp stays un-readied');
  Check(not TogglePrepared(Roster[0], mm), 'toggling again un-readies it');
  Check(not CharPrepared(Roster[0], mm), 'Magic Missile is no longer readied');
  Check(TogglePrepared(Roster[0], sg), 'now Shocking Grasp fits the free slot');

  { ---- the combat menu filters to readied spells when the option is on ---- }
  Roster[0].level := 5;
  Roster[0].known := nil; Roster[0].prepared := nil;
  CharLearn(Roster[0], mm); CharLearn(Roster[0], sg); CharLearn(Roster[0], acid);

  OptPrepared := false;
  CheckEqI(CastCount, 3, 'option off: all three known spells are castable');

  OptPrepared := true;
  CheckEqI(CastCount, 0, 'option on, nothing readied: nothing to cast');
  Check(TogglePrepared(Roster[0], mm), 'ready Magic Missile (L1)');
  Check(TogglePrepared(Roster[0], acid), 'ready Acid Arrow (L2)');
  CheckEqI(CastCount, 2, 'option on: only the two readied spells are castable');

  { ---- pruning drops readied spells whose slots vanish ---- }
  Roster[0].level := 1;   { L2 slots fall to zero }
  PrunePrepared(Roster[0]);
  Check(CharPrepared(Roster[0], mm), 'the L1 spell survives the prune');
  Check(not CharPrepared(Roster[0], acid), 'the now-unreachable L2 spell is pruned');

  OptPrepared := false;   { leave the global as the default }

  TestSummary('prepared');
  halt(TestExit);
end.
