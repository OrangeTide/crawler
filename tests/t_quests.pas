program t_quests;

{** The quest log is data-driven. Quest titles, flag-gated stages, completion
  flags, composite derive rules, and freeform log events come from
  content/quests.txt, baked into the QUST lump. These checks pin the baked
  table and exercise the flag-driven queries and the derive and log pass. }

{$mode objfpc}{$H+}

uses
  sysutils, pak, flags, quests, testing;

var
  p: TPak;
  i, relic, crypt: longint;

begin
  if not PakLoad('build/game.pak', p) then begin
    writeln('  FAIL could not load build/game.pak (run make first)');
    halt(2);
  end;
  Check(LoadQuests(p), 'load quest table');

  { the baked table }
  CheckEqI(Length(QuestDefs), 2, 'two quests loaded');
  relic := -1; crypt := -1;
  for i := 0 to High(QuestDefs) do begin
    if QuestDefs[i].id = 'Q_RELIC' then relic := i;
    if QuestDefs[i].id = 'Q_CRYPT' then crypt := i;
  end;
  Check(relic >= 0, 'Q_RELIC present');
  Check(crypt >= 0, 'Q_CRYPT present');
  Check(QuestDefs[relic].title = 'The Broken Relic', 'relic title');
  CheckEqI(Length(QuestDefs[relic].stages), 3, 'relic has three stages');
  Check(QuestDefs[relic].stages[0].flag = 'QUEST_MAIN', 'first stage flag');
  Check(QuestDefs[relic].doneFlag = 'QUEST_WON', 'relic done flag');
  Check(QuestDefs[crypt].doneFlag = 'SHARD_CRYPT', 'crypt done flag');

  { one derive rule assembles the relic from three shards }
  CheckEqI(Length(QDerives), 1, 'one derive rule');
  Check(QDerives[0].target = 'QUEST_RELIC', 'derive target is QUEST_RELIC');
  CheckEqI(Length(QDerives[0].sources), 3, 'derive has three sources');

  { two freeform log events }
  CheckEqI(Length(QLogs), 2, 'two log events');

  { nothing set yet: no quest active, empty journal }
  FlagsReset;
  QuestsUpdate;
  Check(not QuestActive(QuestDefs[relic]), 'relic inactive before any flag');
  CheckEqI(Length(Journal), 0, 'journal empty before any flag');

  { set the main quest: it becomes active with its first objective }
  FlagSet('QUEST_MAIN');
  QuestsUpdate;
  Check(QuestActive(QuestDefs[relic]), 'relic active once QUEST_MAIN set');
  Check(not QuestComplete(QuestDefs[relic]), 'relic not complete yet');
  Check(QuestObjective(QuestDefs[relic]) = QuestDefs[relic].stages[0].text,
    'objective is the first stage text');

  { a log event fires once its flag is set, and only once }
  FlagSet('SHARD_CAVE');
  QuestsUpdate;
  CheckEqI(Length(Journal), 1, 'cave log event recorded once');
  QuestsUpdate;
  CheckEqI(Length(Journal), 1, 'repeat update does not duplicate the event');

  { the derive sets QUEST_RELIC only when all three shards are in hand }
  FlagSet('SHARD_CRYPT');
  QuestsUpdate;
  Check(not FlagHas('QUEST_RELIC'), 'relic not derived with two shards');
  FlagSet('SHARD_INFER');
  QuestsUpdate;
  Check(FlagHas('QUEST_RELIC'), 'relic derived once all three shards are set');
  Check(QuestObjective(QuestDefs[relic]) = QuestDefs[relic].stages[1].text,
    'objective advances to the whole-relic stage');

  { the done flag completes the quest }
  FlagSet('QUEST_WON');
  QuestsUpdate;
  Check(QuestComplete(QuestDefs[relic]), 'relic complete once QUEST_WON set');

  { the crypt quest shares SHARD_CRYPT as its done flag, set above }
  Check(QuestComplete(QuestDefs[crypt]), 'crypt complete via SHARD_CRYPT');

  { a fresh reset clears quest state back to inactive }
  FlagsReset;
  Check(not QuestActive(QuestDefs[crypt]), 'crypt inactive after reset');
  Check(not QuestComplete(QuestDefs[relic]), 'relic not complete after reset');

  TestSummary('quests');
  halt(TestExit);
end.
