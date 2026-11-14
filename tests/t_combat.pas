program t_combat;

{** Combat terminates. Run many scripted encounters at a range of depths
  and confirm each one ends without hanging. }

{$mode objfpc}{$H+}

uses
  sysutils, pak, rng, rules, items, chardata, monsters, party, combat,
  combatstate, testing;

var
  p: TPak;
  ab: TAbilityScores;
  i, enc, rounds, maxRounds, wins, losses: longint;
  allTerminate: boolean;
  c1, c2: PCombat;
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

    { rotate through the eight area masks so every per-area roster fights }
    StartRandomEncounter(1 + enc mod 8, 1 shl (enc mod 8));
    rounds := 0;
    CombatSettle;   { the foe side may win initiative and open the fight }
    while (not Active^.CombatOver) and (rounds < 4000) do begin
      if CombatBusy then begin CombatSettle; continue; end;
      if Active^.CurActor < 0 then break;      { would be a stall, caught below }
      ActAttack;
      { a back-rank melee actor has no reach and ActAttack does not spend
        the turn; guard instead so the round advances }
      if (Active^.CombatPhase = CP_INPUT) and (not Active^.CombatOver) then ActGuard;
      CombatSettle;   { run the beat and any foe turn to the next input }
      inc(rounds);
    end;
    if rounds > maxRounds then maxRounds := rounds;
    if not Active^.CombatOver then allTerminate := false
    else if Active^.Victory then inc(wins) else inc(losses);
  end;

  writeln('  (', wins, ' won, ', losses, ' lost, longest ', maxRounds, ' actions)');
  Check(allTerminate, '200 encounters all terminate');
  Check(maxRounds < 4000, 'none hit the action cap');
  Check(wins > 0, 'the party wins some fights');

  { the fight reaches the party through its own pointer, and shares the live
    party rather than copying it }
  Check(Active^.Party = @Roster, 'a built fight points at the resident party');
  Active^.Party^[0].hp := 7;
  Check(Roster[0].hp = 7, 'a write through the fight is seen in the party');

  { the cell-keyed fight table: a fight is addressed by its map cell, one per
    cell, and its slot frees when the fight ends }
  Check(CombatAt('CAVE', 3, 4) = nil, 'no fight at a cell before it begins');
  c1 := BeginCombatAt('CAVE', 3, 4);
  Check(c1 <> nil, 'beginning a fight claims a slot');
  Check(c1^.Live, 'the claimed slot is live');
  Check(Active = c1, 'beginning a fight makes it active');
  Check(CombatAt('CAVE', 3, 4) = c1, 'the fight is found at its cell');
  Check(BeginCombatAt('CAVE', 3, 4) = c1, 'one fight per cell: the cell reuses its slot');
  c2 := BeginCombatAt('CAVE', 5, 4);
  Check(c2 <> c1, 'a different cell takes a different slot');
  Check(CombatAt('CAVE', 3, 4) = c1, 'the first cell keeps its own fight');
  { the multi-instance driver advances every live fight, not just Active. Both
    cells hold a live fight; a tick decrements both beat timers even though only
    one is Active. }
  c1^.CombatOver := false; c1^.CombatTimer := 5.0;
  c2^.CombatOver := false; c2^.CombatTimer := 5.0;
  SetActiveCombat(c1);
  CombatUpdateAll(1.0);
  Check(Active = c1, 'the driver restores the shown fight as Active');
  Check(Abs(c1^.CombatTimer - 4.0) < 0.001, 'the active fight advanced');
  Check(Abs(c2^.CombatTimer - 4.0) < 0.001, 'the non-active fight advanced too');

  EndCombatInstance(c1);
  Check(CombatAt('CAVE', 3, 4) = nil, 'ending a fight frees its cell');
  Check(not c1^.Live, 'the freed slot is no longer live');
  { a freed fight is skipped by the driver }
  c2^.CombatTimer := 5.0;
  CombatUpdateAll(1.0);
  Check(Abs(c1^.CombatTimer - 4.0) < 0.001, 'the freed fight is not advanced');
  EndCombatInstance(c2);
  Check(CombatAt('CAVE', 5, 4) = nil, 'ending the second fight frees its cell too');

  TestSummary('combat');
  halt(TestExit);
end.
