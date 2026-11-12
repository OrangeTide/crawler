program t_tactics;

{** Combat tactics: elemental multipliers, elemental damage, status
  application and immunity, and that a fresh fight clears status. }

{$mode objfpc}{$H+}

uses
  sysutils, pak, rng, rules, items, chardata, monsters, party, combat,
  combatstate, combatcore, combatai, testing;

var
  p: TPak;
  ab: TAbilityScores;
  i, skel, imp, rat, tries: longint;
  gob, orc, hits0, hits1, cultist, acolyte: longint;
  gotPoison, gotStun, moved: boolean;
  sl: TEquipSlot;

{ Stand up a single foe of the given definition at full health. }
procedure OneFoe(def: longint);
begin
  SetLength(Active^.Foes, 1);
  Active^.Foes[0].def := def;
  Active^.Foes[0].hp := 100; Active^.Foes[0].hpMax := 100;
  Active^.Foes[0].alive := true; Active^.Foes[0].rank := RANK_FRONT;
  SetLength(Active^.FoeStatus, 1);
  FillChar(Active^.FoeStatus[0], SizeOf(Active^.FoeStatus[0]), 0);
end;

begin
  if not PakLoad('build/game.pak', p) then begin
    writeln('  FAIL could not load build/game.pak (run make first)');
    halt(2);
  end;
  Check(LoadItems(p), 'load items');
  Check(LoadCharData(p), 'load class data');
  Check(LoadMonsters(p), 'load monsters');

  skel := MonIndex('SKELETON');   { undead: weak holy, resist phys, poison-immune }
  imp  := MonIndex('IMP');        { immune fire, weak frost }
  rat  := MonIndex('RAT');        { plain physical }
  Check((skel >= 0) and (imp >= 0) and (rat >= 0), 'test monsters present');

  { ---- elemental multipliers ---- }
  OneFoe(skel);
  Check(ElementMult(EL_HOLY, 0) = 1.5, 'skeleton weak to holy (x1.5)');
  Check(ElementMult(EL_PHYS, 0) = 0.5, 'skeleton resists physical (x0.5)');
  Check(ElementMult(EL_FIRE, 0) = 1.0, 'skeleton neutral to fire (x1)');

  OneFoe(imp);
  Check(ElementMult(EL_FIRE, 0) = 0.0, 'imp immune to fire (x0)');
  Check(ElementMult(EL_FROST, 0) = 1.5, 'imp weak to frost (x1.5)');
  Check(ElementMult(EL_PHYS, 0) = 1.0, 'imp neutral to physical (x1)');

  OneFoe(rat);
  Check(ElementMult(EL_HOLY, 0) = 1.0, 'rat neutral to holy (x1)');

  { ---- elemental damage applies the multiplier ---- }
  OneFoe(skel);
  DamageFoe(0, 10, EL_HOLY);
  Check(Active^.Foes[0].hp = 85, 'holy hit on skeleton deals x1.5 (10 -> 15)');
  DamageFoe(0, 10, EL_PHYS);
  Check(Active^.Foes[0].hp = 80, 'physical hit on skeleton deals x0.5 (10 -> 5)');

  OneFoe(imp);
  DamageFoe(0, 10, EL_FIRE);
  Check(Active^.Foes[0].hp = 100, 'fire hit on imp is nullified (no damage)');
  DamageFoe(0, 10, EL_FROST);
  Check(Active^.Foes[0].hp = 85, 'frost hit on imp deals x1.5 (10 -> 15)');

  OneFoe(rat);
  DamageFoe(0, 100, EL_PHYS);
  Check(not Active^.Foes[0].alive, 'lethal damage kills the foe');

  { ---- status: immunity blocks, otherwise it can land ---- }
  RngSeed(GameRng, 4242);
  OneFoe(skel);
  for i := 1 to 80 do AfflictFoe(0, ST_POISON, 3);
  Check(Active^.FoeStatus[0].poison = 0, 'undead is immune to poison');

  gotStun := false;
  OneFoe(skel);
  for i := 1 to 80 do begin
    AfflictFoe(0, ST_STUN, 1);
    if Active^.FoeStatus[0].stun > 0 then gotStun := true;
    Active^.FoeStatus[0].stun := 0;   { clear and retry to exercise the save }
  end;
  Check(gotStun, 'a non-immune foe can be stunned');

  gotPoison := false;
  OneFoe(rat);
  tries := 0;
  while (not gotPoison) and (tries < 200) do begin
    AfflictFoe(0, ST_POISON, 3);
    if Active^.FoeStatus[0].poison > 0 then gotPoison := true;
    Active^.FoeStatus[0].poison := 0;
    inc(tries);
  end;
  Check(gotPoison, 'a non-immune foe can be poisoned');

  { ---- a fresh encounter clears all status ---- }
  SetLength(Roster, 2);
  for i := 0 to 1 do begin
    RollAbilities(ab);
    MakeCharacter(Roster[i], 'H' + IntToStr(i), 0, i mod Length(ClassDefs), -1, ab);
  end;
  PartyGold := 0;
  RngSeed(GameRng, 7);
  StartRandomEncounter(1, 0);
  gotPoison := false;
  for i := 0 to High(Active^.FoeStatus) do
    if (Active^.FoeStatus[i].poison <> 0) or (Active^.FoeStatus[i].stun <> 0)
      or (Active^.FoeStatus[i].slow <> 0) or (Active^.FoeStatus[i].burn <> 0)
      or (Active^.FoeStatus[i].offbal <> 0) then gotPoison := true;
  for i := 0 to High(Active^.PartyStatus) do
    if (Active^.PartyStatus[i].poison <> 0) or (Active^.PartyStatus[i].stun <> 0)
      or (Active^.PartyStatus[i].slow <> 0) or (Active^.PartyStatus[i].burn <> 0)
      or (Active^.PartyStatus[i].offbal <> 0) then gotPoison := true;
  Check(not gotPoison, 'a new encounter starts with no status');

  { ---- foe AI repositioning (MOVE) ---- }
  RngSeed(GameRng, 20260);
  SetLength(Active^.Foes, 2); SetLength(Active^.FoeStatus, 2);
  for i := 0 to 1 do begin
    Active^.Foes[i].def := rat; Active^.Foes[i].hp := 100; Active^.Foes[i].hpMax := 100;
    Active^.Foes[i].alive := true;
    FillChar(Active^.FoeStatus[i], SizeOf(Active^.FoeStatus[i]), 0);
  end;

  { a melee brute penned behind the line surges up to close }
  Active^.Foes[0].rank := RANK_FRONT;
  moved := false;
  for i := 1 to 40 do begin
    Active^.Foes[1].rank := RANK_BACK;
    if EnemyMaybeMove(1, false) then begin
      Check(Active^.Foes[1].rank = RANK_FRONT, 'melee brute surges to the front');
      moved := true; break;
    end;
  end;
  Check(moved, 'a penned melee foe eventually moves up');

  { a melee foe already on the front line stays put }
  Active^.Foes[0].rank := RANK_FRONT; Active^.Foes[1].rank := RANK_FRONT;
  moved := false;
  for i := 1 to 40 do if EnemyMaybeMove(1, false) then moved := true;
  Check(not moved, 'a front-rank melee foe holds its place');

  { a ranged caster caught in front slips back when it has cover }
  Active^.Foes[0].rank := RANK_FRONT;
  moved := false;
  for i := 1 to 40 do begin
    Active^.Foes[1].rank := RANK_FRONT;
    if EnemyMaybeMove(1, true) then begin
      Check(Active^.Foes[1].rank = RANK_BACK, 'exposed caster falls back');
      moved := true; break;
    end;
  end;
  Check(moved, 'a front-line caster with cover eventually retreats');

  { a ranged caster with no cover stands its ground }
  OneFoe(rat); Active^.Foes[0].rank := RANK_FRONT;
  moved := false;
  for i := 1 to 40 do if EnemyMaybeMove(0, true) then moved := true;
  Check(not moved, 'a caster with no cover never retreats');

  { ---- brute ranged tricks (taunt / throw) ---- }
  gob := MonIndex('GOBLIN');
  orc := MonIndex('ORC');
  Check((gob >= 0) and (orc >= 0), 'harry test monsters present');
  Check(MonDefs[gob].harry = HARRY_TAUNT, 'goblin is a taunter');
  Check(MonDefs[orc].harry = HARRY_THROW, 'orc is a thrower');

  { off balance makes a party member attack at disadvantage: fewer hits }
  SetLength(Roster, 1);
  RollAbilities(ab);
  MakeCharacter(Roster[0], 'HIT', 0, 0, -1, ab);
  Roster[0].rank := RANK_FRONT;
  SetLength(Active^.PartyStatus, 1);
  OneFoe(rat); Active^.Foes[0].rank := RANK_FRONT;
  RngSeed(GameRng, 99);
  hits0 := 0;
  for i := 1 to 400 do begin
    Active^.PartyStatus[0].offbal := 0;
    Active^.Foes[0].hp := 100; Active^.Foes[0].hpMax := 100; Active^.Foes[0].alive := true;
    ResolvePartyAttack(0, 0);
    if Active^.Foes[0].hp < 100 then inc(hits0);
  end;
  hits1 := 0;
  for i := 1 to 400 do begin
    Active^.PartyStatus[0].offbal := 1;
    Active^.Foes[0].hp := 100; Active^.Foes[0].hpMax := 100; Active^.Foes[0].alive := true;
    ResolvePartyAttack(0, 0);
    if Active^.Foes[0].hp < 100 then inc(hits1);
  end;
  Check(hits1 < hits0, 'off balance lowers the hit rate');

  { a thrower chips the target and can rattle it }
  SetLength(Roster, 1);
  RollAbilities(ab);
  MakeCharacter(Roster[0], 'TGT', 0, 0, -1, ab);
  Roster[0].rank := RANK_BACK;
  SetLength(Active^.PartyStatus, 1);
  FillChar(Active^.PartyStatus[0], SizeOf(Active^.PartyStatus[0]), 0);
  OneFoe(orc); Active^.Foes[0].rank := RANK_FRONT;
  RngSeed(GameRng, 5);
  moved := EnemyHarry(0);
  Check(moved, 'a thrower takes its harry action');
  Check(Roster[0].hp < Roster[0].hpMax, 'a thrown weapon chips the target');

  { a taunt can leave a front-line target off balance }
  SetLength(Roster, 1);
  RollAbilities(ab);
  MakeCharacter(Roster[0], 'JEE', 0, 0, -1, ab);
  Roster[0].rank := RANK_FRONT;
  SetLength(Active^.PartyStatus, 1);
  OneFoe(gob); Active^.Foes[0].rank := RANK_FRONT;
  RngSeed(GameRng, 12);
  gotStun := false;
  for i := 1 to 80 do begin
    Active^.PartyStatus[0].offbal := 0;
    if EnemyHarry(0) and (Active^.PartyStatus[0].offbal > 0) then gotStun := true;
  end;
  Check(gotStun, 'a taunt can throw a target off balance');

  { ---- foe spellcasting ---- }
  cultist := MonIndex('CULTIST');
  acolyte := MonIndex('ACOLYTE');
  Check((cultist >= 0) and (acolyte >= 0), 'caster monsters present');
  Check((MonDefs[cultist].flags and MF_MAGE) <> 0, 'cultist is a mage');
  Check((MonDefs[cultist].flags and MF_RANGED) <> 0, 'cultist hangs back');
  Check((MonDefs[acolyte].flags and MF_HEALER) <> 0, 'acolyte is a healer');

  { a mage conjures a bolt that wounds the party and spends spell points }
  SetLength(Roster, 1);
  RollAbilities(ab);
  MakeCharacter(Roster[0], 'MAG', 0, 0, -1, ab);
  Roster[0].rank := RANK_BACK;
  SetLength(Active^.PartyStatus, 1);
  FillChar(Active^.PartyStatus[0], SizeOf(Active^.PartyStatus[0]), 0);
  OneFoe(cultist); Active^.Foes[0].rank := RANK_BACK; Active^.Foes[0].sp := 6;
  RngSeed(GameRng, 3);
  moved := EnemyCastBolt(0);
  Check(moved, 'a mage casts its bolt');
  Check(Roster[0].hp < Roster[0].hpMax, 'the bolt wounds the target');
  Check(Active^.Foes[0].sp < 6, 'the bolt spends spell points');
  Active^.Foes[0].sp := 1;
  Check(not EnemyCastBolt(0), 'no bolt without spell points');

  { a healer mends the most wounded living ally }
  SetLength(Active^.Foes, 2); SetLength(Active^.FoeStatus, 2);
  Active^.Foes[0].def := acolyte; Active^.Foes[0].hp := 20; Active^.Foes[0].hpMax := 20;
  Active^.Foes[0].alive := true; Active^.Foes[0].rank := RANK_BACK; Active^.Foes[0].sp := 6;
  Active^.Foes[1].def := rat; Active^.Foes[1].hp := 3; Active^.Foes[1].hpMax := 30;
  Active^.Foes[1].alive := true; Active^.Foes[1].rank := RANK_FRONT; Active^.Foes[1].sp := 0;
  FillChar(Active^.FoeStatus[0], SizeOf(Active^.FoeStatus[0]), 0);
  FillChar(Active^.FoeStatus[1], SizeOf(Active^.FoeStatus[1]), 0);
  RngSeed(GameRng, 8);
  moved := EnemyCastHeal(0);
  Check(moved, 'a healer mends when an ally is hurt');
  Check(Active^.Foes[1].hp > 3, 'the wounded ally recovers');
  Check(Active^.Foes[0].sp < 6, 'the mend spends spell points');
  Active^.Foes[0].hp := Active^.Foes[0].hpMax; Active^.Foes[1].hp := Active^.Foes[1].hpMax;
  Check(not EnemyCastHeal(0), 'no mend when every ally is at full health');

  { a healer raises a fallen ally and takes back the kill XP }
  SetLength(Active^.Foes, 2); SetLength(Active^.FoeStatus, 2); SetLength(Active^.FoeFlash, 2);
  Active^.Foes[0].def := acolyte; Active^.Foes[0].hp := 20; Active^.Foes[0].hpMax := 20;
  Active^.Foes[0].alive := true; Active^.Foes[0].rank := RANK_BACK; Active^.Foes[0].sp := 6;
  Active^.Foes[1].def := rat; Active^.Foes[1].hp := 0; Active^.Foes[1].hpMax := 30;
  Active^.Foes[1].alive := false; Active^.Foes[1].rank := RANK_FRONT; Active^.Foes[1].sp := 0;
  FillChar(Active^.FoeStatus[0], SizeOf(Active^.FoeStatus[0]), 0);
  FillChar(Active^.FoeStatus[1], SizeOf(Active^.FoeStatus[1]), 0);
  Active^.XPGained := 100;
  RngSeed(GameRng, 2);
  moved := EnemyCastRevive(0);
  Check(moved, 'a healer raises a fallen ally');
  Check(Active^.Foes[1].alive, 'the fallen ally is back on its feet');
  Check(Active^.Foes[1].hp = Active^.Foes[1].hpMax div 2, 'it returns at half health');
  Check(Active^.XPGained = 100 - MonDefs[rat].xp, 'reviving takes back the kill XP');
  Check(Active^.Foes[0].sp < 6, 'the revival spends spell points');
  Check(not EnemyCastRevive(0), 'no revival when no ally is dead');

  { ---- fear and the dark lower the party's aim ---- }
  SetLength(Roster, 1);
  RollAbilities(ab);
  MakeCharacter(Roster[0], 'FEA', 0, 0, -1, ab);
  Roster[0].rank := RANK_FRONT;
  SetLength(Active^.PartyStatus, 1);
  OneFoe(rat); Active^.Foes[0].rank := RANK_FRONT;

  { baseline: well lit and unafraid }
  RngSeed(GameRng, 99);
  hits0 := 0;
  for i := 1 to 400 do begin
    FillChar(Active^.PartyStatus[0], SizeOf(Active^.PartyStatus[0]), 0);
    Active^.PartyDark := 0;
    Active^.Foes[0].hp := 100; Active^.Foes[0].hpMax := 100; Active^.Foes[0].alive := true;
    ResolvePartyAttack(0, 0);
    if Active^.Foes[0].hp < 100 then inc(hits0);
  end;

  { afraid: a flat to-hit penalty, so fewer hits }
  RngSeed(GameRng, 99);
  hits1 := 0;
  for i := 1 to 400 do begin
    FillChar(Active^.PartyStatus[0], SizeOf(Active^.PartyStatus[0]), 0);
    Active^.PartyStatus[0].fear := 2;
    Active^.PartyDark := 0;
    Active^.Foes[0].hp := 100; Active^.Foes[0].hpMax := 100; Active^.Foes[0].alive := true;
    ResolvePartyAttack(0, 0);
    if Active^.Foes[0].hp < 100 then inc(hits1);
  end;
  Check(hits1 < hits0, 'fear lowers the hit rate');

  { fighting in the dark: the same kind of flat penalty }
  RngSeed(GameRng, 99);
  hits1 := 0;
  for i := 1 to 400 do begin
    FillChar(Active^.PartyStatus[0], SizeOf(Active^.PartyStatus[0]), 0);
    Active^.PartyDark := DARK_ATK;
    Active^.Foes[0].hp := 100; Active^.Foes[0].hpMax := 100; Active^.Foes[0].alive := true;
    ResolvePartyAttack(0, 0);
    if Active^.Foes[0].hp < 100 then inc(hits1);
  end;
  Check(hits1 < hits0, 'fighting in the dark lowers the hit rate');
  Active^.PartyDark := 0;

  { an overladen fighter swings at a penalty too }
  for sl := eqMain to eqLight do Roster[0].equip[sl].def := -1;
  SetEquip(Roster[0], eqMain, 'DAGGER');
  SetLength(Roster[0].pack, 0);
  Roster[0].abil[abSTR] := 10;
  Check(not CharEncumbered(Roster[0]), 'the test fighter starts unburdened');
  RngSeed(GameRng, 99);
  hits0 := 0;
  for i := 1 to 400 do begin
    FillChar(Active^.PartyStatus[0], SizeOf(Active^.PartyStatus[0]), 0);
    Active^.PartyDark := 0;
    Active^.Foes[0].hp := 100; Active^.Foes[0].hpMax := 100; Active^.Foes[0].alive := true;
    ResolvePartyAttack(0, 0);
    if Active^.Foes[0].hp < 100 then inc(hits0);
  end;
  PackAdd(Roster[0], 'HARMOR', 9);   { bulk well past capacity }
  Check(CharEncumbered(Roster[0]), 'the piled-on gear overloads the fighter');
  RngSeed(GameRng, 99);
  hits1 := 0;
  for i := 1 to 400 do begin
    FillChar(Active^.PartyStatus[0], SizeOf(Active^.PartyStatus[0]), 0);
    Active^.PartyDark := 0;
    Active^.Foes[0].hp := 100; Active^.Foes[0].hpMax := 100; Active^.Foes[0].alive := true;
    ResolvePartyAttack(0, 0);
    if Active^.Foes[0].hp < 100 then inc(hits1);
  end;
  Check(hits1 < hits0, 'an overladen fighter hits less often');

  { fear and paralysis can take hold of a foe, on a failed save }
  OneFoe(rat);
  RngSeed(GameRng, 7);
  gotStun := false;
  for i := 1 to 200 do begin
    Active^.FoeStatus[0].fear := 0;
    AfflictFoe(0, ST_FEAR, 3);
    if Active^.FoeStatus[0].fear > 0 then gotStun := true;
  end;
  Check(gotStun, 'fear can take hold of a foe');
  gotStun := false;
  for i := 1 to 200 do begin
    Active^.FoeStatus[0].paralyze := 0;
    AfflictFoe(0, ST_PARAL, 2);
    if Active^.FoeStatus[0].paralyze > 0 then gotStun := true;
  end;
  Check(gotStun, 'paralysis can take hold of a foe');

  { ---- revive item ---- }
  Check(ItemIndex('HOLLY') >= 0, 'sprig of holly present');
  Check((ItemDefs[ItemIndex('HOLLY')].flags and IF_REVIVE) <> 0,
    'the sprig of holly is a revive item');

  TestSummary('tactics');
  halt(TestExit);
end.
