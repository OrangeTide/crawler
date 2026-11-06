program t_survival;

{** Party consumable resources: counting and spending stacked items across
  the whole party, the mechanic that rations-at-rest is built on. }

{$mode objfpc}{$H+}

uses
  sysutils, pak, rng, rules, items, chardata, party, codex, testing;

var
  p: TPak;
  ab: TAbilityScores;
  sl: TEquipSlot;
  c: TCharacter;
begin
  if not PakLoad('build/game.pak', p) then begin
    writeln('  FAIL could not load build/game.pak (run make first)');
    halt(2);
  end;
  LoadItems(p);
  LoadCharData(p);
  Check(ItemIndex('RATION') >= 0, 'the RATION item exists in the table');

  RngSeed(GameRng, 1);
  SetLength(Roster, 2);
  RollAbilities(ab); MakeCharacter(Roster[0], 'A', 0, 0, -1, ab);
  RollAbilities(ab); MakeCharacter(Roster[1], 'B', 0, 1, -1, ab);
  { clear any kit-granted stacks so the counts below are exact }
  SetLength(Roster[0].pack, 0);
  SetLength(Roster[1].pack, 0);

  { rations spread across both members' packs }
  PackAdd(Roster[0], 'RATION', 3);
  PackAdd(Roster[1], 'RATION', 2);
  CheckEqI(PartyItemCount('RATION'), 5, 'counts rations across the party');

  { spend four, drawing from both members }
  Check(PartyConsume('RATION', 4), 'spends four rations');
  CheckEqI(PartyItemCount('RATION'), 1, 'one ration left after spending four');

  { cannot overspend; the attempt changes nothing }
  Check(not PartyConsume('RATION', 2), 'cannot spend more than is carried');
  CheckEqI(PartyItemCount('RATION'), 1, 'a failed spend leaves the count');

  { spend the last one; emptied stacks are dropped }
  Check(PartyConsume('RATION', 1), 'spends the last ration');
  CheckEqI(PartyItemCount('RATION'), 0, 'none left');
  CheckEqI(Length(Roster[0].pack) + Length(Roster[1].pack), 0,
    'emptied ration stacks are removed');

  { spending zero is a no-op success }
  Check(PartyConsume('RATION', 0), 'spending zero succeeds');

  { ---- disease caps rest recovery until it breaks ---- }
  Roster[0].hpMax := 20; Roster[0].hp := 2;
  Roster[0].downed := true;
  Roster[0].disease := 2;
  Roster[1].hpMax := 20; Roster[1].hp := 5;   { a healthy member for contrast }

  RestParty;
  CheckEqI(Roster[0].disease, 1, 'a rest wears the illness down by one');
  CheckEqI(Roster[0].hp, 10, 'a sick member recovers only to half');
  Check(not Roster[0].downed, 'the rest still brings the sick member round');
  CheckEqI(Roster[1].hp, 20, 'a healthy member recovers in full');

  RestParty;
  CheckEqI(Roster[0].disease, 0, 'a second rest breaks the fever');
  CheckEqI(Roster[0].hp, 10, 'still capped the rest the fever broke on');

  RestParty;
  CheckEqI(Roster[0].hp, 20, 'cured, the next rest heals in full');

  { ---- encumbrance from carried bulk ---- }
  RngSeed(GameRng, 3);
  SetLength(Roster, 1);
  RollAbilities(ab); MakeCharacter(Roster[0], 'C', 0, 0, -1, ab);
  { strip the kit to a known, empty load }
  for sl := eqMain to eqLight do Roster[0].equip[sl].def := -1;
  SetLength(Roster[0].pack, 0);
  CheckEqI(CharLoad(Roster[0]), 0, 'an empty character carries no bulk');

  { plate (3 slots) + dagger (1) + four rations (1 each) + a potion (1) }
  SetEquip(Roster[0], eqArmor, 'HARMOR');
  SetEquip(Roster[0], eqMain, 'DAGGER');
  PackAdd(Roster[0], 'RATION', 4);
  PackAdd(Roster[0], 'POTION', 1);
  CheckEqI(CharLoad(Roster[0]), 9, 'bulk sums over equipment and pack');

  { capacity scales with strength }
  Roster[0].abil[abSTR] := 10;   { +0 }
  CheckEqI(CharCapacity(Roster[0]), 16, 'average strength bears the base load');
  Check(not CharEncumbered(Roster[0]), 'a modest load is no burden');
  Roster[0].abil[abSTR] := 16;   { +2 }
  CheckEqI(CharCapacity(Roster[0]), 20, 'strength widens the capacity');

  { pile on three suits of plate: now the load tips over capacity }
  Roster[0].abil[abSTR] := 10;
  PackAdd(Roster[0], 'HARMOR', 3);
  Check(CharEncumbered(Roster[0]), 'too much carried gear is a burden');

  { ---- temple revival ---- }
  RngSeed(GameRng, 5);
  SetLength(Roster, 3);
  RollAbilities(ab); MakeCharacter(Roster[0], 'D', 0, 0, -1, ab);
  RollAbilities(ab); MakeCharacter(Roster[1], 'E', 0, 0, -1, ab);
  RollAbilities(ab); MakeCharacter(Roster[2], 'F', 0, 0, -1, ab);
  Roster[0].level := 1; Roster[1].level := 1; Roster[2].level := 3;
  Roster[0].alive := false; Roster[0].downed := true;
  Roster[1].alive := false; Roster[1].downed := true;
  Roster[2].alive := true;   { a living member is never charged }

  CheckEqI(ReviveCost(Roster[0]), REVIVE_BASE, 'a level-1 soul costs the base');
  CheckEqI(ReviveCost(Roster[2]), REVIVE_BASE + 2 * REVIVE_PER_LEVEL,
    'the price climbs with level');

  PartyGold := REVIVE_BASE;   { enough for exactly one }
  CheckEqI(TempleRevive, 1, 'raises as many as the purse affords');
  CheckEqI(PartyGold, 0, 'the revival spends the gold');
  Check(Roster[0].alive and (not Roster[1].alive),
    'the cheapest-first fallen is the one raised');
  Check(Roster[0].hp = Roster[0].hpMax div 2, 'the raised return weakened');

  PartyGold := 1000;
  CheckEqI(TempleRevive, 1, 'the last rises once there is coin');
  Check(Roster[1].alive, 'now the whole party stands');
  CheckEqI(TempleRevive, 0, 'nothing to raise when all are alive');

  { ---- temple identification ---- }
  CodexReset;
  SetLength(Roster, 1);
  RollAbilities(ab); MakeCharacter(Roster[0], 'G', 0, 0, -1, ab);
  SetLength(Roster[0].pack, 0);
  PackAdd(Roster[0], 'ELIXIR', 2);   { two of one unknown kind }

  PartyGold := IDENTIFY_COST - 1;
  CheckEqI(IdentifyParty, 0, 'too little coin names nothing');
  Check(not ItemIsKnown(ItemIndex('ELIXIR')), 'the kind stays unknown');

  PartyGold := 100;
  CheckEqI(IdentifyParty, 1, 'names each unknown kind once, not per item');
  CheckEqI(PartyGold, 100 - IDENTIFY_COST, 'identification spends per kind');
  Check(ItemIsKnown(ItemIndex('ELIXIR')), 'the kind is known afterward');
  CheckEqI(IdentifyParty, 0, 'nothing unknown left to name');

  { ---- hirelings ---- }
  RngSeed(GameRng, 11);
  SetLength(Roster, 1);
  RollAbilities(ab); MakeCharacter(Roster[0], 'LEAD', 0, 0, -1, ab);
  Roster[0].abil[abCHA] := 10;   { +0 charisma: the base fee }
  PartyGold := 1000;
  CheckEqI(HireCost, HIRE_BASE, 'average charisma pays the base hire fee');
  Check(RecruitHireling('HIRE'), 'a hire joins with room and coin');
  CheckEqI(HirelingCount, 1, 'the hire is on the roster');
  CheckEqI(PartyGold, 1000 - HIRE_BASE, 'recruiting spends the fee');
  Check((Length(Roster) >= 2) and Roster[1].hireling, 'the recruit is a hireling');
  CheckEqI(Roster[1].wage, HIRE_BASE, 'the wage equals the hire fee');

  { a covered wage is paid and the hire stays }
  PartyGold := 500;
  CheckEqI(ChargeWages, 0, 'a covered wage keeps the hire');
  CheckEqI(PartyGold, 500 - HIRE_BASE, 'the monthly wage is deducted');
  CheckEqI(HirelingCount, 1, 'the hire stays on');

  { an unpaid wage sends the hire packing }
  PartyGold := 0;
  CheckEqI(ChargeWages, 1, 'an unpaid hire deserts');
  CheckEqI(HirelingCount, 0, 'the deserter is gone');
  CheckEqI(Length(Roster), 1, 'only the leader remains');

  { a full party cannot take on more }
  while Length(Roster) < MAX_PARTY do begin
    RollAbilities(ab); MakeCharacter(c, 'X', 0, 0, -1, ab);
    AddPartyMember(c);
  end;
  PartyGold := 1000;
  Check(not RecruitHireling('NOPE'), 'a full party turns a hire away');

  TestSummary('survival');
  halt(TestExit);
end.
