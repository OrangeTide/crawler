program t_known;

{** Known spells: a caster learns a growing list, chosen at level-up. The
  target grows with level, AutoLearn fills it favouring castable spells, and
  the combat menu draws only the learned, reachable spells. }

{$mode objfpc}{$H+}

uses
  sysutils, pak, rng, rules, items, chardata, monsters, party, spelldb,
  spellbook, combatstate, combatcore, testing;

var
  p: TPak;
  ab: TAbilityScores;
  a: TAbility;
  i, dom, nonCaster: longint;

{ The catalog index of a spell id, or -1. }
function CatOf(const id: string): longint;
var k: longint;
begin
  CatOf := -1;
  for k := 0 to SpellDefCount - 1 do
    if SpellDefs[k].id = id then begin CatOf := k; exit; end;
end;

begin
  if not PakLoad('build/game.pak', p) then begin
    writeln('  FAIL could not load build/game.pak (run make first)');
    halt(2);
  end;
  Check(LoadItems(p), 'load items');
  Check(LoadCharData(p), 'load class data');
  Check(LoadMonsters(p), 'load monsters');
  Check(LoadSpells(p), 'load spells');

  for a := abSTR to abCHA do ab[a] := 12;

  SetLength(Roster, 2);
  MakeCharacter(Roster[0], 'Wren', SpeciesIndex('HUMAN'), ClassIndex('WIZARD'), -1, ab);
  MakeCharacter(Roster[1], 'Bron', SpeciesIndex('HUMAN'), ClassIndex('FIGHTER'), -1, ab);

  { a fresh caster knows nothing and owes picks; a fighter owes none }
  Check(CharIsCaster(Roster[0]), 'the Wizard is a caster');
  Check(not CharIsCaster(Roster[1]), 'the Fighter is not a caster');
  Check(Length(Roster[0].known) = 0, 'a new caster starts knowing no spells');
  Check(PendingLearns(Roster[1]) = 0, 'a non-caster owes no picks');

  { the known target is one at creation plus one per level gained }
  Roster[0].level := 1;
  Check(SpellsKnownTarget(Roster[0]) = 2, 'a level-1 caster is meant to know two');
  Check(PendingLearns(Roster[0]) = 2, 'and owes both at first');
  Roster[0].level := 3;
  Check(SpellsKnownTarget(Roster[0]) = 4, 'the target grows with level');

  { learning one spell reduces the debt and is remembered }
  Roster[0].level := 1;
  i := CatOf('M_MAGICMISSILE');
  Check(i >= 0, 'Magic Missile is in the catalog');
  CharLearn(Roster[0], i);
  Check(CharKnows(Roster[0], i), 'the Wizard now knows Magic Missile');
  Check(PendingLearns(Roster[0]) = 1, 'one pick still owed');
  CharLearn(Roster[0], i);
  Check(Length(Roster[0].known) = 1, 'learning a known spell again is a no-op');

  { learnable spells are domain-gated and exclude what is already known }
  dom := ClassDomain(Roster[0].klass);
  for i := 0 to LearnableCount(Roster[0]) - 1 do
    Check(SpellDefs[LearnableNth(Roster[0], i)].domain = dom,
      'every learnable spell is in the caster domain');
  Check(not CharKnows(Roster[0], CatOf('C_BLESS')),
    'the Wizard cannot know a Cleric spell');

  { AutoLearn fills a caster to its target and favours castable spells }
  Roster[0].known := nil;
  Roster[0].level := 2;
  AutoLearn(Roster[0]);
  Check(Length(Roster[0].known) = SpellsKnownTarget(Roster[0]),
    'AutoLearn fills the caster to its target');
  Check(PendingLearns(Roster[0]) = 0, 'and leaves nothing owed');
  nonCaster := 0;
  for i := 0 to High(Roster[0].known) do
    if not SpellDefs[CatOf(Roster[0].known[i])].castable then inc(nonCaster);
  Check(nonCaster = 0, 'AutoLearn takes castable spells where it can');

  { the combat menu lists only known, castable, reachable spells }
  Roster[0].known := nil;
  Roster[0].level := 1;
  Active^.CurActor := 0; ResetSpellList;
  Check(SpellCount = 0, 'a caster who knows nothing lists nothing to cast');
  CharLearn(Roster[0], CatOf('M_MAGICMISSILE'));
  ResetSpellList;
  Check(SpellCount = 1, 'learning one combat spell puts it on the menu');
  Check(SpellInfo(0).id = 'M_MAGICMISSILE', 'and it is the learned spell');

  { a learned spell above the caster's level stays off the menu }
  CharLearn(Roster[0], CatOf('M_FIREBALL'));   { level 3 }
  ResetSpellList;
  Check(SpellCount = 1, 'a learned spell beyond reach is still gated out');
  Roster[0].level := 5; ResetSpellList;
  Check(SpellCount = 2, 'once the level reaches it, it joins the menu');

  TestSummary('known');
  halt(TestExit);
end.
