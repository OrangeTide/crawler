program t_fieldcast;

{** Casting outside combat: the field effects a caster can work from the
  SPELLS tab while exploring, and the spell-point pool they draw from. }

{$mode objfpc}{$H+}

uses
  sysutils, pak, rng, rules, items, chardata, monsters, party, spelldb,
  spellbook, gamestate, world, codex, fieldcast, testing;

var
  p: TPak;
  ab: TAbilityScores;
  a: TAbility;
  hpWas, spWas, elixir: longint;

function Cat(const id: string): longint;
begin
  Cat := SpellByID(id);
end;

begin
  RngSeed(GameRng, 1234);
  if not PakLoad('build/game.pak', p) then begin
    writeln('  FAIL could not load build/game.pak (run make first)');
    halt(2);
  end;
  Check(LoadItems(p), 'load items');
  Check(LoadCharData(p), 'load class data');
  Check(LoadMonsters(p), 'load monsters');
  Check(LoadSpells(p), 'load spells');
  CodexReset;

  { ---- classification ---- }
  Check(SpellFieldEffect(SpellDefs[Cat('C_CURELIGHTWOUND')]) = FE_HEAL,
    'an ally heal reads as a field heal');
  Check(SpellFieldEffect(SpellDefs[Cat('C_CUREDISEASE')]) = FE_CUREDISEASE,
    'Cure Disease is a field cure');
  Check(SpellFieldEffect(SpellDefs[Cat('C_NEUTRALIZEPOIS')]) = FE_CUREPOISON,
    'Neutralize Poison clears poison');
  Check(SpellFieldEffect(SpellDefs[Cat('C_LIGHT')]) = FE_LIGHT,
    'Light is a field light');
  Check(SpellFieldEffect(SpellDefs[Cat('C_DETECTMAGIC')]) = FE_IDENTIFY,
    'Detect Magic identifies');
  Check(SpellFieldEffect(SpellDefs[Cat('C_DETECTEVIL')]) = FE_REVEAL,
    'Detect Evil reveals the area');
  Check(FieldCastKind(Cat('M_FIREBALL')) = FE_NONE,
    'a damage spell has no field effect');
  Check(FieldTargeted(FE_HEAL) and FieldTargeted(FE_CUREPOISON),
    'heals and cures pick a member');
  Check(not FieldTargeted(FE_LIGHT), 'light works on the whole party');

  { cost is the spell level }
  Check(FieldCost(Cat('C_CURELIGHTWOUND')) = 1, 'a level-1 cast costs 1 SP');
  Check(FieldCost(Cat('C_HEAL')) = 6, 'a level-6 cast costs 6 SP');

  { ---- a caster to cast, a target to mend ---- }
  for a := abSTR to abCHA do ab[a] := 12;
  ab[abWIS] := 16;
  SetLength(Roster, 2);
  MakeCharacter(Roster[0], 'Maeve', SpeciesIndex('HUMAN'), ClassIndex('FRIAR'), -1, ab);
  MakeCharacter(Roster[1], 'Bran', SpeciesIndex('HUMAN'), ClassIndex('FIGHTER'), -1, ab);
  { a new caster starts with a full spell pool }
  Check(Roster[0].sp = CharSpellPoints(Roster[0]), 'a new Friar starts with a pool');
  Check(Roster[1].sp = 0, 'a new Fighter has no pool');
  Roster[0].level := 6;
  Roster[0].sp := CharSpellPoints(Roster[0]);

  { gating: enough points casts, none does not }
  Check(CanFieldCast(0, Cat('C_CURELIGHTWOUND')), 'with points, the Friar can mend');
  spWas := Roster[0].sp;
  Roster[0].sp := 0;
  Check(not CanFieldCast(0, Cat('C_CURELIGHTWOUND')), 'with no points, it cannot');
  Check(DoFieldCast(0, Cat('C_CURELIGHTWOUND'), 1) = '',
    'a cast with no points does nothing');
  Roster[0].sp := spWas;

  { heal raises HP and spends the cost }
  Roster[1].hp := Roster[1].hpMax - 6;
  hpWas := Roster[1].hp; spWas := Roster[0].sp;
  Check(DoFieldCast(0, Cat('C_CURELIGHTWOUND'), 1) <> '', 'the mend resolves');
  Check(Roster[1].hp > hpWas, 'the target gains HP');
  Check(Roster[1].hp <= Roster[1].hpMax, 'HP does not exceed the maximum');
  Check(Roster[0].sp = spWas - 1, 'the mend spends one spell point');

  { a full pool, so the later effects are not gated by exhaustion }
  Roster[0].sp := 20;

  { cures clear the persistent conditions }
  Roster[1].poison := 5;
  DoFieldCast(0, Cat('C_NEUTRALIZEPOIS'), 1);
  Check(Roster[1].poison = 0, 'Neutralize Poison clears poison');
  Roster[1].disease := 3;
  DoFieldCast(0, Cat('C_CUREDISEASE'), 1);
  Check(Roster[1].disease = 0, 'Cure Disease clears disease');
  Roster[1].lycan := true; Roster[1].wereform := true;
  DoFieldCast(0, Cat('C_REMOVECURSE'), 1);
  Check(not Roster[1].lycan, 'Remove Curse lifts lycanthropy');
  Check(not Roster[1].wereform, 'and reverts the were-form');

  { light refuels the party torch to the spell's torch-loads }
  TorchFuel := 0;
  DoFieldCast(0, Cat('C_CONTINUALLIGHT'), -1);
  Check(TorchFuel = 4 * TORCH_MINUTES, 'Continual Light sets four torch-loads');

  { identify names a carried mystery item without gold }
  elixir := ItemIndex('ELIXIR');
  Check(elixir >= 0, 'the mystery elixir exists');
  CodexReset;
  Check(not ItemIsKnown(elixir), 'the elixir starts a mystery');
  SetLength(Roster[0].pack, 1);
  Roster[0].pack[0].def := elixir;
  Roster[0].pack[0].qty := 1;
  Roster[0].pack[0].identified := false;
  DoFieldCast(0, Cat('C_DETECTMAGIC'), -1);
  Check(ItemIsKnown(elixir), 'Detect Magic names the elixir');

  { reveal lifts the fog within the spell's radius of the party }
  MapW := 24; MapH := 24; TileX := 12; TileY := 12;
  Seen[12][12] := VIS_UNSEEN;
  Seen[12][18] := VIS_UNSEEN;   { six tiles east, within Detect Evil's reach }
  Seen[12][19] := VIS_UNSEEN;   { seven tiles east, out of reach }
  DoFieldCast(0, Cat('C_DETECTEVIL'), -1);
  Check(Seen[12][12] >= VIS_REMEMBERED, 'the party tile is revealed');
  Check(Seen[12][18] >= VIS_REMEMBERED, 'a tile within reach is revealed');
  Check(Seen[12][19] = VIS_UNSEEN, 'a tile past the reach stays dark');

  { ---- the spell-point pool is persistent and rest-restored ---- }
  Roster[0].sp := 1;   { stand in for a pool spent down over a delve }
  RestParty;
  Check(Roster[0].sp = CharSpellPoints(Roster[0]),
    'rest refills the spell pool');
  Check(CharSpellPoints(Roster[1]) = 0, 'a fighter has no pool to refill');

  TestSummary('fieldcast');
  halt(TestExit);
end.
