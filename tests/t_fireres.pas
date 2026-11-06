program t_fireres;

{** Fire resistance from worn gear. The unit half of the test pins the
  resisted-damage math directly; the combat half fights the demon lord
  twice, once warded and once not, under the same seed, and checks the
  warded run takes strictly less. }

{$mode objfpc}{$H+}

uses
  sysutils, pak, rng, rules, items, chardata, monsters, party, combat, testing;

var
  p: TPak;
  ab: TAbilityScores;
  widx: longint;

{ Fight the demon lord to a fixed length with the lead member guarding, so
  no foe dies and the clock just racks up enemy swings. Returns the damage
  the member soaked. The member carries the dragonscale shield either way;
  warded toggles whether that shield's resist mask is live, so the two runs
  stay in RNG lockstep and differ only by the halving. }
function FightDamage(warded: boolean): longint;
var
  rounds: longint;
begin
  if warded then ItemDefs[widx].resist := EL_FIRE
  else ItemDefs[widx].resist := 0;

  RngSeed(GameRng, 4242);
  SetLength(Roster, 1);
  RollAbilities(ab);
  MakeCharacter(Roster[0], 'TANK', 0, 0, -1, ab);
  Roster[0].hpMax := 30000;    { too tough to fall, so no brush-with-death rolls
                                 diverge the two runs }
  Roster[0].hp := 30000;
  SetEquip(Roster[0], eqOff, 'WARDSHLD');
  PartyGold := 0;

  StartMonsterEncounter(MonIndex('DEMON'), 6, 0);
  CombatSettle;
  rounds := 0;
  while (not CombatOver) and (rounds < 400) do begin
    if CombatBusy then begin CombatSettle; continue; end;
    if CurActor >= 0 then ActGuard;   { pass the turn, never killing a foe }
    CombatSettle;
    inc(rounds);
  end;
  FightDamage := 30000 - Roster[0].hp;
end;

var
  wardedDmg, bareDmg: longint;
begin
  if not PakLoad('build/game.pak', p) then begin
    writeln('  FAIL could not load build/game.pak (run make first)');
    halt(2);
  end;
  Check(LoadItems(p), 'load items');
  Check(LoadCharData(p), 'load class data');
  Check(LoadMonsters(p), 'load monsters');

  widx := ItemIndex('WARDSHLD');
  Check(widx >= 0, 'the dragonscale shield exists');

  { ---- the resisted-damage math, pinned directly ---- }
  SetLength(Roster, 1);
  RngSeed(GameRng, 1);
  RollAbilities(ab);
  MakeCharacter(Roster[0], 'WEARER', 0, 0, -1, ab);
  SetEquip(Roster[0], eqOff, 'WARDSHLD');
  ItemDefs[widx].resist := EL_FIRE;

  CheckEqI(ResistedHit(0, 10, EL_FIRE), 5, 'warded fire is halved');
  CheckEqI(ResistedHit(0, 9, EL_FIRE), 4, 'the halving rounds down');
  CheckEqI(ResistedHit(0, 1, EL_FIRE), 1, 'a warded hit never falls below one');
  CheckEqI(ResistedHit(0, 10, EL_FROST), 10, 'an unwarded element is full');
  CheckEqI(ResistedHit(0, 10, EL_PHYS), 10, 'a physical blow is full');
  CheckEqI(ResistedHit(0, 10, 0), 10, 'an untyped blow is full');

  Roster[0].equip[eqOff].def := -1;    { bare off-hand }
  CheckEqI(ResistedHit(0, 10, EL_FIRE), 10, 'without the gear, fire is full');

  { ---- the same halving, now through a real fight ---- }
  wardedDmg := FightDamage(true);
  bareDmg := FightDamage(false);
  ItemDefs[widx].resist := EL_FIRE;    { leave the table as the game ships it }

  Check(bareDmg > 0, 'the demon lands fire in the unwarded fight');
  Check(wardedDmg > 0, 'the demon still bites through the ward');
  Check(wardedDmg < bareDmg, 'the ward soaks the demon fire in combat');

  writeln('  (warded ', wardedDmg, ' vs bare ', bareDmg, ' damage over the fight)');

  TestSummary('fireres');
  halt(TestExit);
end.
