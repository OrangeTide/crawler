program t_save;

{** Save and load round trip: the party, gold, flags, the clock and the
  lycanthropy curse survive a write and read. }

{$mode objfpc}{$H+}

uses
  sysutils, pak, rng, rules, items, chardata, mapfmt, world, party, flags,
  mapstate, gametime, pursuit, save, testing;

var
  p: TPak;
  ab: TAbilityScores;
  blob: TByteArray;
  m: TMapData;
  fn: string;
begin
  if not PakLoad('build/game.pak', p) then begin
    writeln('  FAIL could not load build/game.pak (run make first)');
    halt(2);
  end;
  LoadItems(p);
  LoadCharData(p);

  { a resident map so its fog is captured on save }
  Check(PakGet(p, 'TOWN', blob) and DecodeMap(blob, m), 'decode TOWN');
  LoadMapData(m);
  CurMapName := 'TOWN';
  TileX := 6; TileY := 5; FaceDir := 2;

  MapStateReset;
  FlagsReset;
  RngSeed(GameRng, 7);
  SetLength(Roster, 2);
  RollAbilities(ab); MakeCharacter(Roster[0], 'Alice', 0, 0, -1, ab);
  RollAbilities(ab); MakeCharacter(Roster[1], 'Bob', 0, 1, -1, ab);
  Roster[0].lycan := true;
  PartyGold := 137;
  FlagSet('QUEST_X');
  JournalAdd('a journal note');
  TimeReset;
  TimeAdvance(5000);     { clock now 6*60 + 5000 }

  { two roaming hunters on the trail }
  PursuitReset;
  AddPursuer(3, 'TOWN', 4, 4);
  AddPursuer(5, 'DUNGEON', 2, 1);

  fn := 'build/tests/save_rt.sav';
  Check(SaveGame(fn), 'save writes');

  { wipe the live state, then load it back }
  SetLength(Roster, 0);
  PartyGold := 0;
  FlagsReset;
  ClockMin := 0;
  PursuitReset;          { drop the hunters so the load must restore them }

  Check(LoadGame(fn), 'load reads');
  CheckEqI(Length(Roster), 2, 'party size restored');
  Check((Length(Roster) >= 1) and (Roster[0].name = 'Alice'), 'name restored');
  Check((Length(Roster) >= 1) and Roster[0].lycan, 'lycanthropy restored');
  CheckEqI(PartyGold, 137, 'gold restored');
  Check(FlagHas('QUEST_X'), 'flag restored');
  CheckEqI(ClockMin, 6 * 60 + 5000, 'clock restored');
  CheckEqI(ActivePursuerCount, 2, 'both hunters restored');
  Check((Length(Pursuers) >= 2) and (Pursuers[0].mon = 3)
    and (Pursuers[0].map = 'TOWN') and (Pursuers[0].x = 4) and (Pursuers[0].y = 4),
    'first hunter restored intact');
  Check((Length(Pursuers) >= 2) and (Pursuers[1].map = 'DUNGEON'),
    'second hunter on its own map');

  TestSummary('save');
  halt(TestExit);
end.
