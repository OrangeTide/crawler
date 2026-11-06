program t_mappins;

{** Map pins: the manual right-click cycle, auto markers that never override a
  player pin, and per-map keying. }

{$mode objfpc}{$H+}

uses
  sysutils, mappins, testing;

begin
  PinsReset;
  CheckEqI(PinCount, 0, 'a fresh map has no pins');

  { the manual cycle: none -> ! -> ? -> * -> gone }
  PinCycleManual('TOWN', 3, 4);
  CheckEqI(PinKindAt('TOWN', 3, 4), PIN_BANG, 'first click drops a bang');
  PinCycleManual('TOWN', 3, 4);
  CheckEqI(PinKindAt('TOWN', 3, 4), PIN_QUERY, 'next click is a query');
  PinCycleManual('TOWN', 3, 4);
  CheckEqI(PinKindAt('TOWN', 3, 4), PIN_STAR, 'next click is a star');
  PinCycleManual('TOWN', 3, 4);
  CheckEqI(PinKindAt('TOWN', 3, 4), PIN_NONE, 'a fourth click clears it');
  CheckEqI(PinCount, 0, 'the cleared pin is gone');

  { pins are keyed per map and tile }
  PinCycleManual('TOWN', 3, 4);
  PinCycleManual('DUNGEON', 3, 4);
  CheckEqI(PinKindAt('TOWN', 3, 4), PIN_BANG, 'the town pin stands');
  CheckEqI(PinKindAt('DUNGEON', 3, 4), PIN_BANG, 'a different map is separate');
  CheckEqI(PinKindAt('TOWN', 9, 9), PIN_NONE, 'an unpinned tile is empty');

  { an auto marker drops only on an empty tile and is left by the cycle }
  PinsReset;
  PinSetAuto('DUNGEON', 5, 5, PIN_STAIR);
  CheckEqI(PinKindAt('DUNGEON', 5, 5), PIN_STAIR, 'an auto stair marker lands');
  PinSetAuto('DUNGEON', 5, 5, PIN_PORTAL);
  CheckEqI(PinKindAt('DUNGEON', 5, 5), PIN_STAIR,
    'auto does not overwrite an existing pin');
  PinCycleManual('DUNGEON', 5, 5);
  CheckEqI(PinKindAt('DUNGEON', 5, 5), PIN_STAIR,
    'the manual cycle leaves an auto marker alone');

  TestSummary('mappins');
  halt(TestExit);
end.
