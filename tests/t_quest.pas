program t_quest;

{** The relic spine at the dialogue layer: the shard shrines set their flags,
  the demon altar raises a boss-fight request, and the elder's victory line is
  gated behind the assembled relic. }

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

  { the elder hides the victory line until the relic is whole }
  DialogStart('ELDER');
  Check(RespStarting('I bear the relic') < 0,
    'the elder will not take a relic you do not hold');
  FlagSet('QUEST_RELIC');
  DialogStart('ELDER');
  Check(RespStarting('I bear the relic') >= 0,
    'with the relic whole, the elder will take it');
  DialogChoose(RespStarting('I bear the relic'));   { goto the closing node }
  DialogChoose(RespStarting('It was my honour'));
  Check(FlagHas('QUEST_WON'), 'returning the relic wins the game');

  TestSummary('quest');
  halt(TestExit);
end.
