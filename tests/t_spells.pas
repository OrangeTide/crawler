program t_spells;

{** The imported spell catalog: the SPEL lump loads, every spell is well formed,
  the three domains carry their expected counts, and the thematic damage-type to
  element mapping holds. }

{$mode objfpc}{$H+}

uses
  sysutils, pak, monsters, spelldb, chardata, testing;

var
  p: TPak;
  i, j, cleric, druid, mage, withComp, badLevel, emptyId, emptyEff, dupId: longint;
  schooled, nonMageSchool: longint;

begin
  if not PakLoad('build/game.pak', p) then begin
    writeln('  FAIL could not load build/game.pak (run make first)');
    halt(2);
  end;
  Check(LoadSpells(p), 'the SPEL lump loads');
  Check(SpellDefCount = 170, 'the catalog holds all 170 spells');

  { tally the domains and check each spell is well formed }
  cleric := 0; druid := 0; mage := 0; withComp := 0;
  badLevel := 0; emptyId := 0; emptyEff := 0;
  for i := 0 to SpellDefCount - 1 do begin
    case SpellDefs[i].domain of
      SPD_CLERIC: inc(cleric);
      SPD_DRUID:  inc(druid);
      SPD_MAGE:   inc(mage);
    end;
    if (SpellDefs[i].level < 1) or (SpellDefs[i].level > 6) then inc(badLevel);
    if SpellDefs[i].id = '' then inc(emptyId);
    if SpellDefs[i].effect = '' then inc(emptyEff);
    if SpellDefs[i].components <> '' then inc(withComp);
  end;
  Check(cleric = 47, 'the Cleric domain carries its 47 spells');
  Check(druid = 51, 'the Druid domain carries its 51 spells');
  Check(mage = 72, 'the Magic-User domain carries its 72 spells');
  Check(cleric + druid + mage = 170, 'every spell lands in a domain');
  Check(badLevel = 0, 'every spell sits at a level from 1 to 6');
  Check(emptyId = 0, 'every spell has an id');
  Check(emptyEff = 0, 'every spell keeps its effect prose');
  Check(withComp = 19, 'nineteen spells name material components');

  { ids are unique }
  dupId := 0;
  for i := 0 to SpellDefCount - 1 do
    for j := i + 1 to SpellDefCount - 1 do
      if SpellDefs[i].id = SpellDefs[j].id then inc(dupId);
  Check(dupId = 0, 'no two spells share an id');

  { a known spell round-trips with its fields intact }
  i := SpellByID('C_BLESS');
  Check(i >= 0, 'Bless is found by id');
  Check(SpellDefs[i].domain = SPD_CLERIC, 'Bless is a Cleric spell');
  Check(SpellDefs[i].level = 1, 'Bless is a level 1 spell');
  Check(SpellDefs[i].save = SSV_NONE, 'Bless allows no save');
  Check(SpellDefs[i].dtype = SDT_NONE, 'Bless deals no typed damage');
  Check(Copy(SpellDefs[i].effect, 1, 2) = '+1', 'Bless keeps its effect text');
  Check(SpellByID('NO_SUCH_SPELL') = -1, 'an unknown id is not found');

  { every Magic-User spell carries an arcane school, and no other does }
  schooled := 0; nonMageSchool := 0;
  for i := 0 to SpellDefCount - 1 do
    if SpellDefs[i].domain = SPD_MAGE then begin
      if SpellDefs[i].school <> SCH_NONE then inc(schooled);
    end else
      if SpellDefs[i].school <> SCH_NONE then inc(nonMageSchool);
  Check(schooled = 72, 'every Magic-User spell is tagged with a school');
  Check(nonMageSchool = 0, 'cleric and druid spells carry no school');
  Check(SpellDefs[SpellByID('M_FIREBALL')].school = SCH_EVOKE,
    'Fireball is an evocation');
  Check(SpellDefs[SpellByID('M_INVISIBILITY')].school = SCH_ILLUS,
    'Invisibility is an illusion');
  Check(SpellDefs[SpellByID('M_SLEEP')].school = SCH_ENCHANT,
    'Sleep is an enchantment');

  { the opposition matrix is symmetric-free of self-opposition and matches AD&D }
  Check(not SchoolOpposes(SCH_EVOKE, SCH_EVOKE), 'a school never opposes itself');
  Check(SchoolOpposes(SCH_ILLUS, SCH_NECRO), 'illusion opposes necromancy');
  Check(SchoolOpposes(SCH_NECRO, SCH_ILLUS), 'necromancy opposes illusion');
  Check(not SchoolOpposes(SCH_NONE, SCH_EVOKE), 'a generalist opposes nothing');

  { the damage type maps onto an engine element, thematically }
  Check(SpellElement(SDT_FIRE) = EL_FIRE, 'fire maps to the fire element');
  Check(SpellElement(SDT_COLD) = EL_FROST, 'cold maps to the frost element');
  Check(SpellElement(SDT_LIGHTNING) = EL_SHOCK, 'lightning maps to shock');
  Check(SpellElement(SDT_ACID) = EL_PHYS, 'acid falls back to physical');
  Check(SpellElement(SDT_FORCE) = EL_PHYS, 'force falls back to physical');
  Check(SpellElement(SDT_POISON) = EL_PHYS, 'poison falls back to physical');
  Check(SpellElement(SDT_NONE) = 0, 'an untyped spell has no element');

  { every spell carries a spell icon, and a few resolve to the expected one }
  j := 0;
  for i := 0 to SpellDefCount - 1 do if SpellDefs[i].icon > 0 then inc(j);
  Check(j = SpellDefCount, 'every spell names an icon');
  Check(SpellDefs[SpellByID('M_FIREBALL')].icon = 238, 'Fireball keeps its icon');
  Check(SpellDefs[SpellByID('M_MAGICMISSILE')].icon = 52, 'Magic Missile keeps its icon');
  Check(SpellDefs[SpellByID('C_BLESS')].icon = 34, 'Bless keeps its icon');

  { the domain count helper agrees with the per-domain tallies }
  Check(DomainSpellCount(SPD_CLERIC) = 47, 'the Cleric domain counts 47');
  Check(DomainSpellCount(SPD_DRUID) = 51, 'the Druid domain counts 51');
  Check(DomainSpellCount(SPD_MAGE) = 72, 'the Magic-User domain counts 72');

  { NextInDomain walks a domain in order and terminates }
  i := NextInDomain(SPD_CLERIC, -1);
  Check(i >= 0, 'the first Cleric spell is reachable');
  Check(SpellDefs[i].domain = SPD_CLERIC, 'the walk stays in the domain');
  j := 0;
  while i >= 0 do begin inc(j); i := NextInDomain(SPD_CLERIC, i); end;
  Check(j = 47, 'the walk visits every Cleric spell once');

  { the caster classes draw from their domains, non-casters from none }
  Check(LoadCharData(p), 'the class tables load');
  Check(ClassDomain(ClassIndex('WIZARD')) = SPD_MAGE, 'the Wizard is a Magic-User');
  Check(ClassDomain(ClassIndex('FRIAR')) = SPD_CLERIC, 'the Friar is a Cleric');
  Check(ClassDomain(ClassIndex('FORESTAL')) = SPD_DRUID, 'the Forestal is a Druid');
  Check(ClassDomain(ClassIndex('FIGHTER')) = SPD_NONE, 'the Fighter casts nothing');
  Check(ClassDomain(-1) = SPD_NONE, 'an unknown class has no domain');

  TestSummary('spells');
  halt(TestExit);
end.
