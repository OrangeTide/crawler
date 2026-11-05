program t_combat;

{** Combat terminates. Run many scripted encounters at a range of depths
  and confirm each one ends without hanging. }

{$mode objfpc}{$H+}

uses
  sysutils, pak, rng, rules, items, chardata, monsters, party, combat, testing;

var
  p: TPak;
  ab: TAbilityScores;
  i, enc, rounds, maxRounds, wins, losses: longint;
  allTerminate: boolean;
begin
  if not PakLoad('build/game.pak', p) then begin
    writeln('  FAIL could not load build/game.pak (run make first)');
    halt(2);
  end;
  Check(LoadItems(p), 'load items');
  Check(LoadCharData(p), 'load class data');
  Check(LoadMonsters(p), 'load monsters');

  allTerminate := true;
  maxRounds := 0; wins := 0; losses := 0;
  for enc := 0 to 199 do begin
    RngSeed(GameRng, 1000 + enc);
    SetLength(Roster, 4);
    for i := 0 to 3 do begin
      RollAbilities(ab);
      MakeCharacter(Roster[i], 'H' + IntToStr(i), 0, i mod Length(ClassDefs), -1, ab);
    end;
    PartyGold := 50;

    StartRandomEncounter(1 + enc mod 8);
    rounds := 0;
    while (not CombatOver) and (rounds < 4000) do begin
      if CurActor < 0 then break;      { would be a stall, caught below }
      ActAttack;
      inc(rounds);
    end;
    if rounds > maxRounds then maxRounds := rounds;
    if not CombatOver then allTerminate := false
    else if Victory then inc(wins) else inc(losses);
  end;

  writeln('  (', wins, ' won, ', losses, ' lost, longest ', maxRounds, ' actions)');
  Check(allTerminate, '200 encounters all terminate');
  Check(maxRounds < 4000, 'none hit the action cap');
  Check(wins > 0, 'the party wins some fights');

  TestSummary('combat');
  halt(TestExit);
end.
