program t_cast;

{** Combat casting from the spell catalog: a caster's menu is the castable
  spells of its class domain, gated by character level and spell points, with
  the ability modifier drawn from the class prime. }

{$mode objfpc}{$H+}

uses
  sysutils, pak, rng, rules, items, chardata, monsters, party, spelldb,
  combat, combatstate, combatcore, testing;

var
  p: TPak;
  ab: TAbilityScores;
  a: TAbility;
  mm: longint;

{ The menu index of a spell by id in the current actor's list, or -1. }
function MenuIndexOf(const id: string): longint;
var i: longint;
begin
  MenuIndexOf := -1;
  for i := 0 to SpellCount - 1 do
    if SpellInfo(i).id = id then begin MenuIndexOf := i; exit; end;
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

  { INT and WIS set well apart, so the caster ability a class uses is visible }
  for a := abSTR to abCHA do ab[a] := 12;
  ab[abINT] := 16; ab[abWIS] := 8;

  SetLength(Roster, 2);
  MakeCharacter(Roster[0], 'Wren', SpeciesIndex('HUMAN'), ClassIndex('WIZARD'), -1, ab);
  MakeCharacter(Roster[1], 'Maeve', SpeciesIndex('HUMAN'), ClassIndex('FRIAR'), -1, ab);

  { a level-1 Wizard: the three L1 Magic-User combat spells, no L2 yet }
  CurActor := 0;
  Roster[0].level := 1; ResetSpellList;
  Roster[0].sp := 5;
  Check(SpellCount = 5, 'a level-1 Wizard lists its five L1 Magic-User spells');
  Check(MenuIndexOf('M_MAGICMISSILE') >= 0, 'Magic Missile is castable');
  Check(MenuIndexOf('M_SLEEP') >= 0, 'Sleep is castable at level 1');
  Check(MenuIndexOf('M_ACIDARROW') < 0, 'Acid Arrow (L2) is gated out at level 1');
  Check(SpellInfo(MenuIndexOf('M_MAGICMISSILE')).mode = TGT_ENEMY,
    'Magic Missile hits one enemy');
  Check(SpellInfo(MenuIndexOf('M_BURNINGHANDS')).mode = TGT_ENEMY_RANK,
    'Burning Hands hits a rank');
  Check(SpellInfo(MenuIndexOf('M_SHOCKINGGRASP')).element = EL_SHOCK,
    'Shocking Grasp carries the shock element');
  Check(SpellInfo(MenuIndexOf('M_SLEEP')).mode = TGT_ENEMY_RANK,
    'Sleep blankets a whole rank');
  Check(SpellInfo(MenuIndexOf('M_SLEEP')).inflict = ST_PARAL,
    'Sleep lays a holding status');
  Check(CasterMod(0) = AbilMod(Roster[0].abil[abINT]),
    'the Wizard casts off Intelligence');
  Check(CasterMod(0) <> AbilMod(Roster[0].abil[abWIS]),
    'the Wizard does not cast off Wisdom');

  { level 3 opens the level-2 spells, level 5 the level-3 spells }
  Roster[0].level := 3; ResetSpellList;
  Check(MenuIndexOf('M_ACIDARROW') >= 0, 'at level 3 Acid Arrow (L2) opens up');
  Check(MenuIndexOf('M_FIREBALL') < 0, 'Fireball (L3) is still out of reach');
  Roster[0].level := 5; ResetSpellList;
  Check(MenuIndexOf('M_FIREBALL') >= 0, 'at level 5 Fireball (L3) opens up');
  Check(SpellInfo(MenuIndexOf('M_FIREBALL')).element = EL_FIRE, 'Fireball burns');
  Check(MenuIndexOf('M_DISINTEGRATE') < 0, 'Disintegrate (L6) is still far off');
  Roster[0].level := 11; ResetSpellList;
  Check(MenuIndexOf('M_DISINTEGRATE') >= 0, 'at high level Disintegrate (L6) opens up');

  { spell points gate the cast }
  mm := MenuIndexOf('M_MAGICMISSILE');
  Roster[0].sp := 1;
  Check(ActorCanCast(0, mm), 'with a point to spend, the Wizard can cast');
  Roster[0].sp := 0;
  Check(not ActorCanCast(0, mm), 'with no points, the Wizard cannot cast');

  { the Friar draws the Cleric domain and casts off Wisdom }
  CurActor := 1;
  Roster[1].level := 1; ResetSpellList;
  Roster[1].sp := 5;
  Check(MenuIndexOf('C_CURELIGHTWOUND') >= 0, 'the Friar can mend wounds');
  Check(MenuIndexOf('C_BLESS') >= 0, 'the Friar can bless the party');
  Check(MenuIndexOf('M_MAGICMISSILE') < 0, 'the Friar draws no arcane spells');
  Check(CasterMod(1) = AbilMod(Roster[1].abil[abWIS]),
    'the Friar casts off Wisdom');
  Check(CasterMod(1) <> AbilMod(Roster[1].abil[abINT]),
    'the Friar does not cast off Intelligence');

  { a non-caster has an empty list }
  SetLength(Roster, 3);
  MakeCharacter(Roster[2], 'Bron', SpeciesIndex('HUMAN'), ClassIndex('FIGHTER'), -1, ab);
  CurActor := 2; ResetSpellList;
  Check(SpellCount = 0, 'a Fighter has no spells to cast');

  TestSummary('cast');
  halt(TestExit);
end.
