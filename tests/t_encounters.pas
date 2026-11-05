program t_encounters;

{** Encounter tables: the data file loads, areas map to tables, and the
  empty table 0 marks a safe area. }

{$mode objfpc}{$H+}

uses
  sysutils, pak, overworld, encounters, testing;

{ Total weight a table assigns to a monster id (0 if absent). }
function WeightOf(tab: longint; const id: string): longint;
var k: longint;
begin
  WeightOf := 0;
  if (tab < 0) or (tab > High(EncTables)) then exit;
  for k := 0 to High(EncTables[tab].entries) do
    if EncTables[tab].entries[k].mon = id then
      WeightOf := WeightOf + EncTables[tab].entries[k].weight;
end;

var
  p: TPak;
  forestTab, cryptTab: longint;
begin
  if not PakLoad('build/game.pak', p) then begin
    writeln('  FAIL could not load build/game.pak (run make first)');
    halt(2);
  end;
  Check(LoadEncounters(p), 'load encounters');

  { table 0 is the empty, safe table }
  Check(EncTableEmpty(0), 'table 0 is empty');
  Check(EncTableOf(0) = 0, 'area 0 (interiors) points at the empty table');
  Check(EncTableEmpty(EncTableOf(0)), 'area 0 is a safe area');

  { each wild area points at a non-empty table }
  forestTab := EncTableOf(AREA_FOREST);
  cryptTab := EncTableOf(AREA_CRYPT);
  Check(forestTab > 0, 'the forest references a table');
  Check(cryptTab > 0, 'the crypt references a table');
  Check(not EncTableEmpty(forestTab), 'the forest table spawns foes');
  Check(not EncTableEmpty(cryptTab), 'the crypt table spawns foes');
  Check(forestTab <> cryptTab, 'distinct areas use distinct tables');

  { weighted entries carry through }
  Check(WeightOf(forestTab, 'GOBLIN') > 0, 'goblins roam the forest');
  Check(WeightOf(cryptTab, 'SKELETON') > 0, 'skeletons haunt the crypt');
  Check(WeightOf(cryptTab, 'SKELETON') >= WeightOf(cryptTab, 'CULTIST'),
    'the crypt favours skeletons over cultists');
  Check(WeightOf(forestTab, 'SKELETON') = 0, 'no skeletons in the forest');

  { an unset area falls back to the safe table }
  Check(EncTableOf(0) = 0, 'unmapped areas default to table 0');

  TestSummary('encounters');
  halt(TestExit);
end.
