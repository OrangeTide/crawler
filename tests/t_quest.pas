program t_quest;

{** The relic spine at the dialogue layer: the shard shrines set their flags,
  the demon altar raises a boss-fight request, the elder reveals the whole
  relic as a key and charges the descent, and the Depths gate turns that key
  into the win. }

{$mode objfpc}{$H+}

uses
  sysutils, pak, flags, dialog, testing;

var
  p: TPak;

{ Pick the visible response whose text starts with a prefix, or -1. }
function RespStarting(const prefix: string): longint;
var i: longint;
begin
  RespStarting := -1;
  for i := 0 to DialogRespCount - 1 do
    if Copy(DialogRespText(i), 1, Length(prefix)) = prefix then begin
      RespStarting := i;
      exit;
    end;
end;

begin
  if not PakLoad('build/game.pak', p) then begin
    writeln('  FAIL could not load build/game.pak (run make first)');
    halt(2);
  end;
  Check(LoadDialogs(p), 'load dialogs');
  FlagsReset;

  { the crypt shrine grants its shard }
  DialogStart('SHRINE');
  Check(RespStarting('Take the crypt') >= 0, 'the crypt shrine offers its shard');
  DialogChoose(RespStarting('Take the crypt'));
  Check(FlagHas('SHARD_CRYPT'), 'the crypt shard flag is set');

  { the grotto shrine grants the cave shard }
  DialogStart('GROTTO');
  DialogChoose(RespStarting('Prise the cave'));
  Check(FlagHas('SHARD_CAVE'), 'the cave shard flag is set');

  { the demon altar raises a boss fight, carrying the win flag }
  DialogStart('DEMONLORD');
  DialogChoose(RespStarting('Face the demon'));
  Check(DlgFightReq, 'the altar requests a fight');
  Check(DlgFightMon = 'DEMON', 'the fight is against the demon');
  Check(DlgFightFlag = 'SHARD_INFER', 'winning will grant the infernal shard');

  { the elder hides the relic turn-in until the relic is whole }
  DialogStart('ELDER');
  Check(RespStarting('I bear the relic') < 0,
    'the elder will not take a relic you do not hold');
  FlagSet('QUEST_RELIC');
  DialogStart('ELDER');
  Check(RespStarting('I bear the relic') >= 0,
    'with the relic whole, the elder will take it');
  { the relic is revealed as a key: the elder charges the descent, no win yet }
  DialogChoose(RespStarting('I bear the relic'));   { the reveal node }
  DialogChoose(RespStarting('The road to where')); { the charge node }
  DialogChoose(RespStarting('I will go down'));
  Check(FlagHas('QUEST_DEPTHS'), 'the elder charges the descent to the Depths');
  Check(not FlagHas('QUEST_WON'), 'handing back the relic does not end the game');

  { the Depths gate stays sealed without the charge, then grants the win }
  FlagsReset;
  DialogStart('DEPTHS');
  Check(RespStarting('Set the relic-key') < 0,
    'the gate will not open without the charge to descend');
  FlagSet('QUEST_DEPTHS');
  DialogStart('DEPTHS');
  Check(RespStarting('Set the relic-key') >= 0,
    'with the charge, the key turns in the gate');
  DialogChoose(RespStarting('Set the relic-key'));  { the gate grinds open }
  DialogChoose(RespStarting('Walk into the ruins'));
  Check(FlagHas('QUEST_WON'), 'entering the first lost city wins the game');

  TestSummary('quest');
  halt(TestExit);
end.
