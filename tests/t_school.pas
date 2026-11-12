program t_school;

{** Arcane schools as Magic-User sub-domains. A specialist mage is barred from
  its opposition schools (Lesser Divination excepted), knows one extra spell,
  and presses the save harder on its favored school. }

{$mode objfpc}{$H+}

uses
  sysutils, pak, rng, rules, items, chardata, monsters, party, spelldb,
  spellbook, combatstate, combatcore, testing;

var
  p: TPak;
  ab: TAbilityScores;
  a: TAbility;
  i, saves13, saves14: longint;
  r: TRng;

{ Whether a caster could ever learn the named spell (domain, school, level gate
  ignored except as SpellAllowed applies). }
function Allows(const c: TCharacter; const id: string): boolean;
begin
  Allows := SpellAllowed(c, SpellByID(id));
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

  { the new specialist classes exist and name their schools }
  Check(ClassSchool(ClassIndex('WIZARD')) = SCH_NONE, 'the Wizard is a generalist');
  Check(ClassSchool(ClassIndex('ILLUSION')) = SCH_ILLUS, 'the Illusionist favors illusion');
  Check(ClassSchool(ClassIndex('NECRONIM')) = SCH_NECRO, 'Necronimus favors necromancy');
  Check(ClassSchool(ClassIndex('ABJURER')) = SCH_ABJUR, 'the Abjurer favors abjuration');
  Check(ClassSchool(ClassIndex('CONJURER')) = SCH_CONJ, 'the Conjurer favors conjuration');
  Check(ClassSchool(ClassIndex('DIVINER')) = SCH_DIVIN, 'the Diviner favors divination');
  Check(ClassSchool(ClassIndex('ENCHANTER')) = SCH_ENCHANT, 'the Enchanter favors enchantment');
  Check(ClassSchool(ClassIndex('INVOKER')) = SCH_EVOKE, 'the Invoker favors evocation');
  Check(ClassSchool(ClassIndex('TRANSMUTER')) = SCH_TRANS, 'the Transmuter favors transmutation');

  for a := abSTR to abCHA do ab[a] := 12;
  SetLength(Roster, 4);
  MakeCharacter(Roster[0], 'Gen', SpeciesIndex('HUMAN'), ClassIndex('WIZARD'), -1, ab);
  MakeCharacter(Roster[1], 'Illy', SpeciesIndex('HUMAN'), ClassIndex('ILLUSION'), -1, ab);
  MakeCharacter(Roster[2], 'Cora', SpeciesIndex('HUMAN'), ClassIndex('CONJURER'), -1, ab);
  MakeCharacter(Roster[3], 'Vox', SpeciesIndex('HUMAN'), ClassIndex('INVOKER'), -1, ab);

  { a generalist draws from every school }
  Check(Allows(Roster[0], 'M_FIREBALL'), 'the Wizard may learn an evocation');
  Check(Allows(Roster[0], 'M_INVISIBILITY'), 'the Wizard may learn an illusion');
  Check(Allows(Roster[0], 'M_VAMPIRICTOUCH'), 'the Wizard may learn a necromancy');
  Check(Allows(Roster[0], 'M_FLY'), 'the Wizard may learn a transmutation');

  { the Illusionist keeps its school but is barred from its opposition
    (abjuration, transmutation, necromancy) }
  Check(Allows(Roster[1], 'M_INVISIBILITY'), 'the Illusionist may learn illusion');
  Check(Allows(Roster[1], 'M_FIREBALL'), 'illusion does not oppose evocation');
  Check(not Allows(Roster[1], 'M_SHIELD'), 'the Illusionist is barred from abjuration');
  Check(not Allows(Roster[1], 'M_FLY'), 'the Illusionist is barred from transmutation');
  Check(not Allows(Roster[1], 'M_VAMPIRICTOUCH'), 'the Illusionist is barred from necromancy');

  { Lesser Divination stays open even to a school that opposes divination }
  Check(SchoolOpposes(SCH_CONJ, SCH_DIVIN), 'conjuration opposes divination');
  Check(Allows(Roster[2], 'M_DETECTMAGIC'), 'the Conjurer keeps Lesser Divination (L1)');
  Check(Allows(Roster[2], 'M_CLAIRVOYANCE'), 'the Conjurer keeps Lesser Divination (L3)');
  Check(not Allows(Roster[2], 'M_FIREBALL'), 'the Conjurer is barred from evocation');
  Check(Allows(Roster[2], 'M_ACIDARROW'), 'the Conjurer keeps its own conjuration');

  { a specialist knows one more spell than a generalist of the same level }
  Roster[0].level := 5; Roster[1].level := 5;
  Check(SpellsKnownTarget(Roster[1]) = SpellsKnownTarget(Roster[0]) + 1,
    'a specialist knows one extra spell for its focus');

  { the combat menu drops an opposition spell even if it is somehow known }
  Roster[1].level := 11;      { high enough to reach every level }
  SetLength(Roster[1].known, 2);
  Roster[1].known[0] := 'M_COLORSPRAY';   { illusion, favored, castable }
  Roster[1].known[1] := 'M_SCARE';        { necromancy, opposition, castable }
  Active^.CurActor := 1; ResetSpellList;
  i := -1;
  Check(SpellCount >= 1, 'the Illusionist has a combat spell');
  for i := 0 to SpellCount - 1 do
    Check(SpellInfo(i).id <> 'M_SCARE', 'no opposition spell reaches the menu');
  { and the favored one is there }
  saves13 := 0;
  for i := 0 to SpellCount - 1 do
    if SpellInfo(i).id = 'M_COLORSPRAY' then inc(saves13);
  Check(saves13 = 1, 'the favored-school spell is on the menu');

  { the specialist save edge: casting in the favored school matches, so ActCast
    would add +1 to the DC; a generalist adds nothing }
  Check(SpellDefs[SpellByID('M_MAGICMISSILE')].school = ClassSchool(ClassIndex('INVOKER')),
    'an Invoker fires Magic Missile in its own school (edge applies)');
  Check(SpellDefs[SpellByID('M_MAGICMISSILE')].school <> ClassSchool(ClassIndex('WIZARD')),
    'a generalist gets no school edge');

  { and +1 to the DC genuinely makes a foe save less often (same dice) }
  RngSeed(r, 12345); saves13 := 0;
  for i := 1 to 500 do if SaveThrow(r, 0, 4, 13) then inc(saves13);
  RngSeed(r, 12345); saves14 := 0;
  for i := 1 to 500 do if SaveThrow(r, 0, 4, 14) then inc(saves14);
  Check(saves14 < saves13, 'a +1 save DC lets the foe shrug it off less often');

  TestSummary('school');
  halt(TestExit);
end.
