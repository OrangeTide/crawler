program t_survival;

{** Party consumable resources: counting and spending stacked items across
  the whole party, the mechanic that rations-at-rest is built on. }

{$mode objfpc}{$H+}

uses
  sysutils, pak, rng, rules, items, chardata, party, testing;

var
  p: TPak;
  ab: TAbilityScores;
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

  TestSummary('survival');
  halt(TestExit);
end.
