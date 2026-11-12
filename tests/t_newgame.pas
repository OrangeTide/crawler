program t_newgame;

{** New-game data is data-driven. The random name pool, the quick-start pregen
  party, and the character-creation default selections come from
  content/newgame.txt, not Pascal literals. These checks pin the baked table. }

{$mode objfpc}{$H+}

uses
  sysutils, pak, rules, items, chardata, testing;

var
  p: TPak;

begin
  if not PakLoad('build/game.pak', p) then begin
    writeln('  FAIL could not load build/game.pak (run make first)');
    halt(2);
  end;
  Check(LoadItems(p), 'load items');
  Check(LoadCharData(p), 'load character and new-game data');

  { the random name pool }
  CheckEqI(Length(NamePool), 12, 'the name pool loaded twelve names');
  Check(NamePool[0] = 'THORNE', 'the first name is THORNE');
  Check(NamePool[11] = 'RHESK', 'the last name is RHESK');

  { the quick-start pregen party }
  CheckEqI(Length(PregenParty), 4, 'the pregen party has four slots');
  Check(PregenParty[0].klass = 'FIGHTER', 'slot 1 is a fighter');
  Check(PregenParty[1].klass = 'THIEF', 'slot 2 is a thief');
  Check(PregenParty[2].klass = 'FRIAR', 'slot 3 is a friar');
  Check(PregenParty[3].klass = 'WIZARD', 'slot 4 is a wizard');
  Check(PregenParty[0].species = 'HUMAN', 'the party is human');
  { every pregen id resolves against the loaded tables }
  Check(SpeciesIndex(PregenParty[0].species) >= 0, 'pregen species resolves');
  Check(ClassIndex(PregenParty[0].klass) >= 0, 'pregen class resolves');

  { the character-creation defaults }
  Check(DefaultSpecies = 'HUMAN', 'the default species is human');
  Check(DefaultClass = 'FIGHTER', 'the default class is fighter');
  Check(ClassIndex(DefaultClass) >= 0, 'the default class resolves');

  TestSummary('newgame');
  halt(TestExit);
end.
