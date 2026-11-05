program t_tactics;

{** Combat tactics: elemental multipliers, elemental damage, status
  application and immunity, and that a fresh fight clears status. }

{$mode objfpc}{$H+}

uses
  sysutils, pak, rng, rules, items, chardata, monsters, party, combat, testing;

var
  p: TPak;
  ab: TAbilityScores;
  i, skel, imp, rat, tries: longint;
  gotPoison, gotStun: boolean;

{ Stand up a single foe of the given definition at full health. }
procedure OneFoe(def: longint);
begin
  SetLength(Foes, 1);
  Foes[0].def := def;
  Foes[0].hp := 100; Foes[0].hpMax := 100;
  Foes[0].alive := true; Foes[0].rank := RANK_FRONT;
  SetLength(FoeStatus, 1);
  FillChar(FoeStatus[0], SizeOf(FoeStatus[0]), 0);
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
  Check(Foes[0].hp = 85, 'holy hit on skeleton deals x1.5 (10 -> 15)');
  DamageFoe(0, 10, EL_PHYS);
  Check(Foes[0].hp = 80, 'physical hit on skeleton deals x0.5 (10 -> 5)');

  OneFoe(imp);
  DamageFoe(0, 10, EL_FIRE);
  Check(Foes[0].hp = 100, 'fire hit on imp is nullified (no damage)');
  DamageFoe(0, 10, EL_FROST);
  Check(Foes[0].hp = 85, 'frost hit on imp deals x1.5 (10 -> 15)');

  OneFoe(rat);
  DamageFoe(0, 100, EL_PHYS);
  Check(not Foes[0].alive, 'lethal damage kills the foe');

  { ---- status: immunity blocks, otherwise it can land ---- }
  RngSeed(GameRng, 4242);
  OneFoe(skel);
  for i := 1 to 80 do AfflictFoe(0, ST_POISON, 3);
  Check(FoeStatus[0].poison = 0, 'undead is immune to poison');

  gotStun := false;
  OneFoe(skel);
  for i := 1 to 80 do begin
    AfflictFoe(0, ST_STUN, 1);
    if FoeStatus[0].stun > 0 then gotStun := true;
    FoeStatus[0].stun := 0;   { clear and retry to exercise the save }
  end;
  Check(gotStun, 'a non-immune foe can be stunned');

  gotPoison := false;
  OneFoe(rat);
  tries := 0;
  while (not gotPoison) and (tries < 200) do begin
    AfflictFoe(0, ST_POISON, 3);
    if FoeStatus[0].poison > 0 then gotPoison := true;
    FoeStatus[0].poison := 0;
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
  for i := 0 to High(FoeStatus) do
    if (FoeStatus[i].poison <> 0) or (FoeStatus[i].stun <> 0)
      or (FoeStatus[i].slow <> 0) or (FoeStatus[i].burn <> 0) then gotPoison := true;
  for i := 0 to High(PartyStatus) do
    if (PartyStatus[i].poison <> 0) or (PartyStatus[i].stun <> 0)
      or (PartyStatus[i].slow <> 0) or (PartyStatus[i].burn <> 0) then gotPoison := true;
  Check(not gotPoison, 'a new encounter starts with no status');

  TestSummary('tactics');
  halt(TestExit);
end.
