unit combat;

{** Tactical turn-based combat on AX&X rules, party versus a monster group.

  Combat uses two ranks a side (front, back) rather than a battle grid,
  which suits the first-person view. Turn order is per actor: each round a
  queue is built from every living combatant, ordered by speed, and each
  acts in turn. Party members act under player control; foes resolve on a
  short clock with a small amount of role-aware AI.

  Tactics layered on the base rules:
  - Damage carries an element (physical, fire, frost, shock, holy); foes
    are weak to, resist, or ignore elements, so spell and weapon choice
    matters.
  - Status effects (poison, stun, slow, burn) tick at the start of a
    victim's turn and are resisted by a save.
  - Defend halves incoming damage for a turn; the back rank is shielded
    from melee entirely and takes half from ranged foes.

  The game drives this: it reads Active^.CurActor / Active^.CombatPhase to know whose
  input is wanted, calls an action procedure, and checks Active^.CombatOver. }

{$mode objfpc}{$H+}

interface

uses
  sysutils, rng, rules, items, monsters, party, chardata, spelldb, skilldb,
  skillbook, encounters, codex, flags, combatstate, combatcore, combatai;

{ Start a fight at a dungeon depth. tableNum selects the weighted encounter
  table to draw foes from; an empty or unknown table draws from every
  monster, so forced fights (quick battle, tests) still find foes. }
procedure StartRandomEncounter(depth: longint; tableNum: longint);
{ Start a fight led by a specific monster, the rest drawn as usual. Used
  when a roaming monster catches the party, so the hunter is in the fight. }
procedure StartMonsterEncounter(leadMon, depth, tableNum: longint);
procedure ActAttack;
procedure ActGuard;
procedure ActMove;
procedure ActFlee;
procedure ActSkip;
procedure ActUseItem(slot, target: longint);
procedure NextTarget;

{ ---- turn pacing ---- }
{ Advance the combat clock; the game calls this each frame while fighting.
  It paces the pause after an action and each foe's turn. }
procedure CombatUpdate(dt: double);

{ True while combat resolves on its own (a beat or a foe turn), so the
  game ignores input until the next party member is ready. }
function CombatBusy: boolean;

{ For headless tests: run the clock until a member is ready or the fight
  ends, instead of ticking real frames. }
procedure CombatSettle;

{ Cast spellIdx from the current actor. target is a foe index for enemy
  modes, an ally index for TGT_ALLY, and ignored for TGT_PARTY. }
procedure ActCast(spellIdx, target: longint);

{ Use the i-th combat maneuver from the current actor's skill menu. target is
  the foe for the attacking maneuvers, ignored for the party-wide rally. }
procedure ActSkill(skillIdx, target: longint);

{ ---- post-fight spoils ---- }

{ The story flag a scripted boss fight raises on a win, empty for an ordinary
  fight. Set it before the fight; the game awards it when the fight ends. }
var
  BossRewardFlag: string;

{ Raise and clear the boss story flag when the party has won. Harmless on a
  loss or when no flag was carried. }
procedure AwardBossFlag;

{ Sometimes grant an unidentified potion to a standing member after a win.
  Returns true when a drop was made, so the caller can announce it. The roll
  uses the global RNG stream, not the combat core's GameRng, so it never
  shifts the deterministic combat rolls. }
function GrantVictoryLoot: boolean;

implementation

type
  TTurnEnt = record
    side: byte;        { 0 a foe, 1 a party member }
    idx: longint;      { index into Active^.Foes or Roster }
  end;

var
  TurnQueue: array of TTurnEnt;  { this round's actors, fastest first }
  TurnPos: longint;              { cursor into TurnQueue }
  TurnContinue: boolean;         { the actor keeps its turn for the other slot }
  CombatTimer: double;           { seconds left in the current beat }
  FoesAtStart: longint;          { for the morale threshold }

const
  BEAT_TIME  = 0.45;   { pause after an action before the next step }
  ENEMY_STEP = 0.55;   { how long a foe's own turn is held on screen }

  POISON_DMG = 2;
  BURN_DMG   = 3;
  FEAR_ATK   = 3;      { to-hit penalty while afraid }
  FOE_CAST_SP = 2;     { spell points a foe spends per spell }

{ ---- end of fight ---- }

procedure CheckEnd;
begin
  if LivingFoes = 0 then begin
    Active^.CombatOver := true;
    Active^.Victory := true;
    Active^.GoldGained := Range(0, 10) * Length(Active^.Foes) + Range(0, 20);
    PartyGold := PartyGold + Active^.GoldGained;
    CombatLog('Victory. ' + IntToStr(Active^.XPGained) + ' XP, '
      + IntToStr(Active^.GoldGained) + ' gold.');
    exit;
  end;
  if not PartyConscious then begin
    Active^.CombatOver := true;
    Active^.Victory := false;
    CombatLog('The party falls.');
  end;
end;

procedure MoraleCheck;
var i, best: longint;
begin
  best := 0;
  for i := 0 to High(Active^.Foes) do
    if Active^.Foes[i].alive and (MonDefs[Active^.Foes[i].def].morale > best) then
      best := MonDefs[Active^.Foes[i].def].morale;
  if D(6) > best then begin
    CombatLog('The enemy breaks and flees!');
    for i := 0 to High(Active^.Foes) do Active^.Foes[i].alive := false;
  end;
end;

{ ---- turn order ---- }

procedure NewRound; forward;
procedure AdvanceTurn; forward;

{ Finish whoever just acted: end the fight, or hold a beat and move on. }
procedure EndTurn;
begin
  TurnContinue := false;
  CheckEnd;
  if Active^.CombatOver then begin Active^.CombatPhase := CP_DONE; exit; end;
  inc(TurnPos);
  Active^.CombatPhase := CP_BEAT;
  CombatTimer := BEAT_TIME * CombatBeatScale;
end;

{ A party member gets one move and one other action per turn, in either
  order. A sub-action marks its slot; the turn ends once both slots are
  spent (or on a SKIP or FLEE, which end it outright through EndTurn).
  Until then the same actor is handed back the command menu after a beat. }
procedure FinishSubAction(isMove: boolean);
begin
  if isMove then Active^.TurnMoved := true else Active^.TurnActed := true;
  if Active^.TurnMoved and Active^.TurnActed then begin
    EndTurn;
    exit;
  end;
  CheckEnd;
  if Active^.CombatOver then begin TurnContinue := false; Active^.CombatPhase := CP_DONE; exit; end;
  TurnContinue := true;
  Active^.CombatPhase := CP_BEAT;
  CombatTimer := BEAT_TIME * CombatBeatScale;
end;

{ A combatant's turn-order speed, higher acting sooner. Party members run
  off Dexterity, foes off their speed stat; slow drags either down. }
function PartySpeed(i: longint): longint;
begin
  PartySpeed := 4 + AbilMod(Roster[i].abil[abDEX]);
  if Active^.PartyStatus[i].slow > 0 then PartySpeed := PartySpeed - 4;
end;

function FoeSpeed(i: longint): longint;
begin
  FoeSpeed := MonDefs[Active^.Foes[i].def].speed;
  if Active^.FoeStatus[i].slow > 0 then FoeSpeed := FoeSpeed - 4;
end;

{ Build this round's turn order from every living combatant, fastest
  first, with a small random tiebreak. }
procedure NewRound;
var
  init: array of longint;
  i, n, a, b: longint;
  tmpEnt: TTurnEnt;
  tmpInit: longint;
begin
  if (LivingFoes > 0) and (LivingFoes <= FoesAtStart div 2) then MoraleCheck;
  CheckEnd;
  if Active^.CombatOver then begin Active^.CombatPhase := CP_DONE; exit; end;

  SetLength(TurnQueue, 0);
  SetLength(init, 0);
  n := 0;
  for i := 0 to High(Roster) do
    if Roster[i].alive and (not Roster[i].downed) then begin
      SetLength(TurnQueue, n + 1); SetLength(init, n + 1);
      TurnQueue[n].side := 1; TurnQueue[n].idx := i;
      init[n] := PartySpeed(i) + Range(1, 4);
      inc(n);
    end;
  for i := 0 to High(Active^.Foes) do
    if Active^.Foes[i].alive then begin
      SetLength(TurnQueue, n + 1); SetLength(init, n + 1);
      TurnQueue[n].side := 0; TurnQueue[n].idx := i;
      init[n] := FoeSpeed(i) + Range(1, 4);
      inc(n);
    end;

  { insertion sort, descending initiative }
  for a := 1 to n - 1 do begin
    tmpEnt := TurnQueue[a]; tmpInit := init[a];
    b := a - 1;
    while (b >= 0) and (init[b] < tmpInit) do begin
      TurnQueue[b + 1] := TurnQueue[b]; init[b + 1] := init[b];
      dec(b);
    end;
    TurnQueue[b + 1] := tmpEnt; init[b + 1] := tmpInit;
  end;

  TurnPos := 0;
  Active^.CurTarget := FirstLivingFoe;
  AdvanceTurn;
end;

function TurnEntAlive(const e: TTurnEnt): boolean;
begin
  if e.side = 1 then
    TurnEntAlive := (e.idx <= High(Roster)) and Roster[e.idx].alive
      and (not Roster[e.idx].downed)
  else
    TurnEntAlive := (e.idx <= High(Active^.Foes)) and Active^.Foes[e.idx].alive;
end;

{ Run the start-of-turn status for a combatant: damage over time, then a
  skipped turn if stunned. Returns true when the turn is spent (the actor
  died or was stunned) so the caller advances past it. }
function StartOfTurnSpent(const e: TTurnEnt): boolean;
var i, bd: longint;
begin
  StartOfTurnSpent := false;
  if e.side = 0 then begin
    i := e.idx;
    if Active^.FoeStatus[i].poison > 0 then begin
      DamageFoe(i, POISON_DMG, EL_PHYS); dec(Active^.FoeStatus[i].poison);
    end;
    if Active^.Foes[i].alive and (Active^.FoeStatus[i].burn > 0) then begin
      DamageFoe(i, BURN_DMG, EL_FIRE); dec(Active^.FoeStatus[i].burn);
    end;
    if Active^.FoeStatus[i].slow > 0 then dec(Active^.FoeStatus[i].slow);
    if Active^.FoeStatus[i].offbal > 0 then dec(Active^.FoeStatus[i].offbal);
    if Active^.FoeStatus[i].fear > 0 then dec(Active^.FoeStatus[i].fear);
    if not Active^.Foes[i].alive then begin StartOfTurnSpent := true; exit; end;
    if Active^.FoeStatus[i].paralyze > 0 then begin
      dec(Active^.FoeStatus[i].paralyze);
      CombatLog(MonDefs[Active^.Foes[i].def].name + ' is held fast.');
      PushPop(0, i, POPC_MISS, 'HELD');
      StartOfTurnSpent := true;
    end else if Active^.FoeStatus[i].stun > 0 then begin
      dec(Active^.FoeStatus[i].stun);
      CombatLog(MonDefs[Active^.Foes[i].def].name + ' is stunned.');
      PushPop(0, i, POPC_MISS, 'STUN');
      StartOfTurnSpent := true;
    end;
  end else begin
    i := e.idx;
    if Active^.PartyStatus[i].poison > 0 then begin
      PushPop(1, i, POPC_PARTYDMG, IntToStr(POISON_DMG)); FlashAlly(i);
      HurtMember(i, POISON_DMG); dec(Active^.PartyStatus[i].poison);
    end;
    if Roster[i].alive and (not Roster[i].downed) and (Active^.PartyStatus[i].burn > 0) then begin
      bd := ResistedHit(i, BURN_DMG, EL_FIRE);
      PushPop(1, i, POPC_PARTYDMG, IntToStr(bd)); FlashAlly(i);
      HurtMember(i, bd); dec(Active^.PartyStatus[i].burn);
    end;
    if Active^.PartyStatus[i].slow > 0 then dec(Active^.PartyStatus[i].slow);
    if Active^.PartyStatus[i].offbal > 0 then dec(Active^.PartyStatus[i].offbal);
    if Active^.PartyStatus[i].fear > 0 then dec(Active^.PartyStatus[i].fear);
    if (not Roster[i].alive) or Roster[i].downed then begin
      StartOfTurnSpent := true; exit;
    end;
    if Active^.PartyStatus[i].paralyze > 0 then begin
      dec(Active^.PartyStatus[i].paralyze);
      CombatLog(Roster[i].name + ' is held fast.');
      PushPop(1, i, POPC_MISS, 'HELD');
      StartOfTurnSpent := true;
    end else if Active^.PartyStatus[i].stun > 0 then begin
      dec(Active^.PartyStatus[i].stun);
      CombatLog(Roster[i].name + ' is stunned.');
      PushPop(1, i, POPC_MISS, 'STUN');
      StartOfTurnSpent := true;
    end;
  end;
end;

procedure ResolveEnemyTurn; forward;

{ Hand the turn to the next living actor: a party member waits for input,
  a foe acts on the clock. Skips the dead and the status-spent. }
procedure AdvanceTurn;
var e: TTurnEnt;
begin
  if Active^.CombatOver then begin Active^.CombatPhase := CP_DONE; exit; end;
  while TurnPos <= High(TurnQueue) do begin
    if TurnEntAlive(TurnQueue[TurnPos]) then break;
    inc(TurnPos);
  end;
  if TurnPos > High(TurnQueue) then begin NewRound; exit; end;

  e := TurnQueue[TurnPos];
  if StartOfTurnSpent(e) then begin EndTurn; exit; end;

  if e.side = 1 then begin
    Active^.CurActor := e.idx;
    Roster[e.idx].guarding := false;   { the defence held until now }
    Active^.TurnMoved := false;                { a fresh move and action this turn }
    Active^.TurnActed := false;
    Active^.CombatPhase := CP_INPUT;
  end else begin
    Active^.CombatPhase := CP_ENEMY;
    CombatTimer := ENEMY_STEP * CombatBeatScale;
  end;
end;

function CombatBusy: boolean;
begin
  CombatBusy := (not Active^.CombatOver) and (Active^.CombatPhase <> CP_INPUT);
end;

procedure CombatUpdate(dt: double);
begin
  DecayFeedback(dt);   { flashes and numbers fade in every phase }
  if Active^.CombatOver then begin Active^.CombatPhase := CP_DONE; exit; end;
  if CombatTimer > 0 then begin
    CombatTimer := CombatTimer - dt;
    if CombatTimer > 0 then exit;
    CombatTimer := 0;
  end;
  case Active^.CombatPhase of
    CP_BEAT:
      if TurnContinue then begin
        TurnContinue := false;
        Active^.CombatPhase := CP_INPUT;   { same actor takes its remaining slot }
      end else
        AdvanceTurn;
    CP_ENEMY: begin ResolveEnemyTurn; EndTurn; end;
  end;
end;

procedure CombatSettle;
var guard: longint;
begin
  guard := 0;
  while CombatBusy and (guard < 100000) do begin
    CombatUpdate(1.0);
    inc(guard);
  end;
end;

{ ---- setup ---- }

procedure BuildEncounter(depth, tableNum, leadMon: longint);
{** Build a fight. When leadMon is a valid monster index the first foe is
  that monster (a caught pursuer joins the fight it caused); otherwise all
  foes are drawn from the area table. With leadMon = -1 the draw is
  identical to a plain random encounter. }
var
  pick, count, i, j, front, npool, e, mi, wrep: longint;
  pool: array of longint;
begin
  SetLength(Active^.Foes, 0);
  Active^.CombatOver := false;
  Active^.Victory := false;
  Active^.Fled := false;
  Active^.PartyBless := 0;
  Active^.PartyDark := 0;      { well lit by default; combatui dims it from the torch }
  Active^.XPGained := 0;
  Active^.GoldGained := 0;
  for i := 0 to LOG_LINES - 1 do Active^.Log[i] := '';

  if Length(MonDefs) = 0 then begin
    Active^.CombatOver := true; Active^.Victory := true; exit;
  end;

  { draw the pool from the area's encounter table, each monster repeated by
    its weight. An empty or unknown table falls back to the whole bestiary,
    so forced fights (quick battle, tests) still find foes. }
  SetLength(pool, 0);
  npool := 0;
  if (tableNum >= 0) and (tableNum <= High(EncTables)) then
    for e := 0 to High(EncTables[tableNum].entries) do begin
      mi := MonIndex(EncTables[tableNum].entries[e].mon);
      if mi >= 0 then
        for wrep := 1 to EncTables[tableNum].entries[e].weight do begin
          SetLength(pool, npool + 1);
          pool[npool] := mi; inc(npool);
        end;
    end;
  if npool = 0 then begin
    SetLength(pool, Length(MonDefs));
    for i := 0 to High(MonDefs) do pool[i] := i;
    npool := Length(MonDefs);
  end;

  count := 1 + Range(0, 2) + (depth div 3);
  if count > MAX_FOES then count := MAX_FOES;
  SetLength(Active^.Foes, count);
  front := 0;
  for i := 0 to count - 1 do begin
    pick := pool[Range(0, npool - 1)];
    { the lead foe is the pursuer when one is named; the draw above still
      runs so a plain encounter (leadMon = -1) is bit-for-bit unchanged. }
    if (i = 0) and (leadMon >= 0) and (leadMon <= High(MonDefs)) then
      pick := leadMon;
    Active^.Foes[i].def := pick;
    Active^.Foes[i].hp := RngRoll(GameRng, MonDefs[pick].hd, 8);
    if Active^.Foes[i].hp < 1 then Active^.Foes[i].hp := 1;
    Active^.Foes[i].hpMax := Active^.Foes[i].hp;
    Active^.Foes[i].alive := true;
    { ranged monsters hang back; melee forms a front line, up to three }
    if ((MonDefs[pick].flags and MF_RANGED) <> 0) or (front >= 3) then
      Active^.Foes[i].rank := RANK_BACK
    else begin
      Active^.Foes[i].rank := RANK_FRONT; inc(front);
    end;
    { caster and healer foes carry a small pool of spell points }
    if (MonDefs[pick].flags and (MF_MAGE or MF_HEALER)) <> 0 then
      Active^.Foes[i].sp := 4 + depth
    else
      Active^.Foes[i].sp := 0;
  end;
  if front = 0 then Active^.Foes[0].rank := RANK_FRONT;   { someone must be reachable }
  FoesAtStart := count;

  { rebuild the per-caster spell lists in case the party changed or levelled.
    Spell points are a persistent pool now, carried in from exploration and
    refilled by rest, so a fight no longer tops them off. }
  ResetSpellList;

  { clear hit feedback and status for the new fight }
  SetLength(Active^.Pops, 0);
  SetLength(Active^.FoeFlash, Length(Active^.Foes));
  SetLength(Active^.PartyFlash, Length(Roster));
  SetLength(Active^.FoeStatus, Length(Active^.Foes));
  SetLength(Active^.PartyStatus, Length(Roster));
  for i := 0 to High(Active^.FoeStatus) do FillChar(Active^.FoeStatus[i], SizeOf(TStatus), 0);
  for i := 0 to High(Active^.PartyStatus) do FillChar(Active^.PartyStatus[i], SizeOf(TStatus), 0);

  { reset the per-fight maneuver tallies and the cached skill menu, so each
    fight starts with every limited maneuver's uses restored }
  ResetSkillMenu;
  SetLength(Active^.SkillUse, Length(Roster));
  for i := 0 to High(Active^.SkillUse) do begin
    SetLength(Active^.SkillUse[i], SkillDefCount);
    for j := 0 to High(Active^.SkillUse[i]) do Active^.SkillUse[i][j] := 0;
  end;
  Active^.CombatSfxCue := CUE_NONE;

  { the party now meets these foes: record them in the bestiary }
  for i := 0 to High(Active^.Foes) do MarkMonSeen(Active^.Foes[i].def);

  CombatLog('Foes close in: ' + IntToStr(count) + ' of them.');
  NewRound;
end;

procedure StartRandomEncounter(depth: longint; tableNum: longint);
begin
  BuildEncounter(depth, tableNum, -1);
end;

procedure StartMonsterEncounter(leadMon, depth, tableNum: longint);
begin
  BuildEncounter(depth, tableNum, leadMon);
end;

{ ---- the foe side's AI ---- }

{ Resolve the foe at the turn cursor: choose a target by role and swing,
  carrying the monster's element and any status its hit inflicts. }
procedure ResolveEnemyTurn;
var
  fi, tgt, roll, dmg, effAC, atkB: longint;
  ranged, hasHarry, isMage, isHealer, hit: boolean;
begin
  fi := TurnQueue[TurnPos].idx;
  if (fi > High(Active^.Foes)) or (not Active^.Foes[fi].alive) then exit;
  if FirstConscious < 0 then exit;
  ranged := (MonDefs[Active^.Foes[fi].def].flags and MF_RANGED) <> 0;
  hasHarry := MonDefs[Active^.Foes[fi].def].harry <> HARRY_NONE;
  isMage := (MonDefs[Active^.Foes[fi].def].flags and MF_MAGE) <> 0;
  isHealer := (MonDefs[Active^.Foes[fi].def].flags and MF_HEALER) <> 0;

  { a healer raises a fallen ally first, then tends a wounded one }
  if isHealer and EnemyCastRevive(fi) then exit;
  if isHealer and EnemyCastHeal(fi) then exit;
  { a mage usually conjures a bolt rather than closing or swinging }
  if isMage and (Active^.Foes[fi].sp >= FOE_CAST_SP) and (D(100) <= 70)
     and EnemyCastBolt(fi) then exit;

  if ranged then begin
    { a caster slips back behind cover when it can }
    if EnemyMaybeMove(fi, true) then exit;
  end else if Active^.Foes[fi].rank <> FrontFoeRank then begin
    { out of melee reach: harass from range, surge up, or hold the line }
    if hasHarry and (D(100) <= 45) and EnemyHarry(fi) then exit;
    if EnemyMaybeMove(fi, false) then exit;
    exit;   { penned and did neither: holds }
  end else begin
    { on the line: an occasional jeer or throw instead of a swing }
    if hasHarry and (D(100) <= 25) and EnemyHarry(fi) then exit;
  end;

  tgt := EnemyPickTarget(fi, ranged);
  if tgt < 0 then exit;

  roll := D(20);
  effAC := CharAC(Roster[tgt]);
  if Roster[tgt].guarding then effAC := effAC + 2;   { braced to parry }
  atkB := MonDefs[Active^.Foes[fi].def].atkBonus;
  if Active^.FoeStatus[fi].fear > 0 then dec(atkB, FEAR_ATK);   { afraid: swings wide }
  if OptCriticals then
    hit := (roll <> 1) and ((roll = 20) or (roll + atkB >= effAC))
  else
    hit := roll + atkB >= effAC;   { plain roll, no natural 20/1 }
  if hit then
  begin
    dmg := D(MonDefs[Active^.Foes[fi].def].dmgSides);
    if dmg < 1 then dmg := 1;
    if Roster[tgt].guarding then dmg := dmg div 2;          { defend halves }
    if ranged and (Roster[tgt].rank = RANK_BACK) then dmg := dmg div 2;
    if dmg < 1 then dmg := 1;
    dmg := ResistedHit(tgt, dmg, MonDefs[Active^.Foes[fi].def].element);
    CombatLog(MonDefs[Active^.Foes[fi].def].name + ' hits ' + Roster[tgt].name
      + ' for ' + IntToStr(dmg) + '.');
    PushPop(1, tgt, POPC_PARTYDMG, IntToStr(dmg));
    FlashAlly(tgt);
    Active^.CombatSfxCue := CUE_HIT;
    HurtMember(tgt, dmg);
    if Roster[tgt].alive and (not Roster[tgt].downed) then begin
      if MonDefs[Active^.Foes[fi].def].inflict <> 0 then
        AfflictMember(tgt, MonDefs[Active^.Foes[fi].def].inflict, 3);
      { a lycanthrope's wound can pass on the curse, on a failed save }
      if ((MonDefs[Active^.Foes[fi].def].flags and MF_LYCAN) <> 0)
        and (not Roster[tgt].lycan)
        and (not SaveThrow(GameRng, AbilMod(Roster[tgt].abil[abCON]),
                           Roster[tgt].level, 13)) then
      begin
        Roster[tgt].lycan := true;
        CombatLog(Roster[tgt].name + ' is marked by the curse!');
      end;
    end;
  end else begin
    CombatLog(MonDefs[Active^.Foes[fi].def].name + ' misses ' + Roster[tgt].name + '.');
    PushPop(1, tgt, POPC_MISS, 'MISS');
  end;
end;

{ ---- player actions ---- }

procedure ActAttack;
begin
  if Active^.CombatOver or (Active^.CurActor < 0) or (Active^.CombatPhase <> CP_INPUT) then exit;
  if not FoeReachable(Active^.CurActor, Active^.CurTarget) then
    Active^.CurTarget := FirstReachable(Active^.CurActor);
  if Active^.CurTarget < 0 then begin
    CombatLog(Roster[Active^.CurActor].name + ' has no target in reach.');
    exit;   { the turn is not spent; pick another action or retarget }
  end;
  ResolvePartyAttack(Active^.CurActor, Active^.CurTarget);
  if (Active^.CurTarget > High(Active^.Foes)) or (not Active^.Foes[Active^.CurTarget].alive) then
    Active^.CurTarget := FirstLivingFoe;
  FinishSubAction(false);
end;

procedure ActGuard;
begin
  if Active^.CombatOver or (Active^.CurActor < 0) or (Active^.CombatPhase <> CP_INPUT) then exit;
  Roster[Active^.CurActor].guarding := true;
  CombatLog(Roster[Active^.CurActor].name + ' braces to defend.');
  FinishSubAction(false);
end;

procedure ActMove;
begin
  if Active^.CombatOver or (Active^.CurActor < 0) or (Active^.CombatPhase <> CP_INPUT) then exit;
  { step between the front line and the back; this spends the move slot }
  if Roster[Active^.CurActor].rank = RANK_FRONT then begin
    Roster[Active^.CurActor].rank := RANK_BACK;
    CombatLog(Roster[Active^.CurActor].name + ' falls back.');
  end else begin
    Roster[Active^.CurActor].rank := RANK_FRONT;
    CombatLog(Roster[Active^.CurActor].name + ' steps up to the front.');
  end;
  FinishSubAction(true);
end;

procedure ActFlee;
begin
  if Active^.CombatOver or (Active^.CurActor < 0) or (Active^.CombatPhase <> CP_INPUT) then exit;
  { a scramble to break off: succeeds on better than a coin toss, else the
    turn is lost }
  if D(6) >= 3 then begin
    Active^.CombatOver := true;
    Active^.Victory := false;
    Active^.Fled := true;
    Active^.CombatPhase := CP_DONE;
    CombatLog('The party breaks off and flees.');
  end else begin
    CombatLog(Roster[Active^.CurActor].name + ' fails to break away.');
    EndTurn;
  end;
end;

{ Pass: give up any unused move and action and end the turn. }
procedure ActSkip;
begin
  if Active^.CombatOver or (Active^.CurActor < 0) or (Active^.CombatPhase <> CP_INPUT) then exit;
  CombatLog(Roster[Active^.CurActor].name + ' waits.');
  EndTurn;
end;

{ Use a chosen consumable (pack slot) on a chosen ally. A revive item raises
  a gravely wounded ally; any other potion restores a conscious one. The UI
  gates the target, so an out-of-range or wrong-state pick is just ignored. }
procedure ActUseItem(slot, target: longint);
var
  def, heal: longint;
  reviving: boolean;
begin
  if Active^.CombatOver or (Active^.CurActor < 0) or (Active^.CombatPhase <> CP_INPUT) then exit;
  if (slot < 0) or (slot > High(Roster[Active^.CurActor].pack)) then exit;
  if Roster[Active^.CurActor].pack[slot].qty <= 0 then exit;
  def := Roster[Active^.CurActor].pack[slot].def;
  if (def < 0) or (def > High(ItemDefs)) then exit;
  if ItemDefs[def].kind <> IK_POTION then exit;
  if (target < 0) or (target > High(Roster)) or (not Roster[target].alive) then exit;
  reviving := (ItemDefs[def].flags and IF_REVIVE) <> 0;
  if reviving and (not Roster[target].downed) then exit;
  if (not reviving) and Roster[target].downed then exit;

  dec(Roster[Active^.CurActor].pack[slot].qty);
  MarkItemKnown(def);   { quaffing an unknown potion reveals what it is }
  heal := RngRoll(GameRng, 1, 8) + 2;
  if reviving then begin
    Roster[target].downed := false;
    Roster[target].hp := heal;
  end else
    Roster[target].hp := Roster[target].hp + heal;
  if Roster[target].hp > Roster[target].hpMax then
    Roster[target].hp := Roster[target].hpMax;
  CombatLog(Roster[Active^.CurActor].name + ' uses ' + ItemDefs[def].name
    + ' on ' + Roster[target].name + ' (+' + IntToStr(heal) + ').');
  PushPop(1, target, POPC_HEAL, '+' + IntToStr(heal));
  FlashAlly(target);
  FinishSubAction(false);
end;

procedure NextTarget;
var start, i: longint;
begin
  if (LivingFoes = 0) or (Active^.CurActor < 0) then exit;
  start := Active^.CurTarget;
  if start < 0 then start := 0;
  i := start;
  repeat
    i := (i + 1) mod Length(Active^.Foes);
    if FoeReachable(Active^.CurActor, i) then begin Active^.CurTarget := i; exit; end;
  until i = start;
end;

{ ---- abilities ---- }

procedure ActCast(spellIdx, target: longint);
var
  sp: TSpell;
  amt, m, i, rk, edge: longint;
begin
  if Active^.CombatOver or (Active^.CurActor < 0) or (Active^.CombatPhase <> CP_INPUT) then exit;
  if not ActorCanCast(Active^.CurActor, spellIdx) then begin
    CombatLog(Roster[Active^.CurActor].name + ' cannot cast that.');
    exit;
  end;
  sp := SpellInfo(spellIdx);
  dec(Roster[Active^.CurActor].sp, sp.cost);
  m := CasterMod(Active^.CurActor);
  { a specialist casting in its favored school presses the save harder }
  edge := 0;
  if (sp.school <> SCH_NONE)
    and (ClassSchool(Roster[Active^.CurActor].klass) = sp.school) then edge := 1;

  case sp.mode of
    TGT_ENEMY: begin
      if (target < 0) or (target > High(Active^.Foes)) or (not Active^.Foes[target].alive) then
        target := FirstLivingFoe;
      if target < 0 then begin FinishSubAction(false); exit; end;
      CombatLog(Roster[Active^.CurActor].name + ' casts ' + sp.name + '.');
      DamageFoe(target, RngRoll(GameRng, sp.dice, sp.sides) + m, sp.element);
      if Active^.Foes[target].alive and (sp.inflict <> 0) then
        AfflictFoe(target, sp.inflict, 3, edge);
    end;
    TGT_ENEMY_RANK: begin
      if (target < 0) or (target > High(Active^.Foes)) or (not Active^.Foes[target].alive) then
        target := FirstLivingFoe;
      if target < 0 then begin FinishSubAction(false); exit; end;
      rk := Active^.Foes[target].rank;
      CombatLog(Roster[Active^.CurActor].name + ' casts ' + sp.name + '.');
      for i := 0 to High(Active^.Foes) do
        if Active^.Foes[i].alive and (Active^.Foes[i].rank = rk) then begin
          DamageFoe(i, RngRoll(GameRng, sp.dice, sp.sides) + m, sp.element);
          if Active^.Foes[i].alive and (sp.inflict <> 0) then
            AfflictFoe(i, sp.inflict, 3, edge);
        end;
    end;
    TGT_ALLY: begin
      if (target < 0) or (target > High(Roster)) or (not Roster[target].alive) then
        target := Active^.CurActor;
      amt := RngRoll(GameRng, sp.dice, sp.sides) + m;
      if amt < 1 then amt := 1;
      if Roster[target].downed and Roster[target].alive then
        Roster[target].downed := false;    { a mend brings them to their feet }
      Roster[target].hp := Roster[target].hp + amt;
      if Roster[target].hp > Roster[target].hpMax then
        Roster[target].hp := Roster[target].hpMax;
      CombatLog(Roster[Active^.CurActor].name + ' mends ' + Roster[target].name
        + ' (+' + IntToStr(amt) + ').');
      PushPop(1, target, POPC_HEAL, '+' + IntToStr(amt));
      FlashAlly(target);
    end;
    TGT_PARTY: begin
      Active^.PartyBless := 1;
      CombatLog(Roster[Active^.CurActor].name + ' blesses the party.');
    end;
  end;

  FinishSubAction(false);
end;

procedure ActSkill(skillIdx, target: longint);
var
  sk: TSkillDef;
  rk, bonus, i: longint;
begin
  if Active^.CombatOver or (Active^.CurActor < 0) or (Active^.CombatPhase <> CP_INPUT) then exit;
  if not ActorCanManeuver(Active^.CurActor, skillIdx) then begin
    CombatLog(Roster[Active^.CurActor].name + ' cannot do that.');
    exit;
  end;
  sk := CombatSkillInfo(skillIdx);
  rk := SkillRank(Roster[Active^.CurActor], CombatSkillCat(skillIdx));
  if rk < 0 then rk := 0;
  bonus := 0;
  if sk.dice > 0 then bonus := RngRoll(GameRng, sk.dice, sk.sides);
  SpendManeuver(Active^.CurActor, skillIdx);
  CombatLog(Roster[Active^.CurActor].name + ' uses ' + sk.name + '.');

  case sk.effect of
    SKE_POWERATTACK:
      { a heavy swing: harder to land, heavier when it does }
      ResolvePartyAttack(Active^.CurActor, target, -2, bonus + rk);
    SKE_DISARM:
      { a precise strike that throws the foe off balance }
      ResolvePartyAttack(Active^.CurActor, target, -1, 0, ST_OFFBAL);
    SKE_BASH:
      { a shield slam that can stun }
      ResolvePartyAttack(Active^.CurActor, target, -1, 0, ST_STUN);
    SKE_AIMEDSHOT:
      { a careful shot: surer, and keener with training }
      ResolvePartyAttack(Active^.CurActor, target, 2 + rk, bonus);
    SKE_RALLY: begin
      { steady the party: fear lifts and a short blessing takes hold }
      for i := 0 to High(Roster) do
        if Roster[i].alive then Active^.PartyStatus[i].fear := 0;
      Active^.PartyBless := 1;
      CombatLog(Roster[Active^.CurActor].name + ' rallies the party.');
    end;
  end;

  { the struck foe may have fallen; aim the cursor at a living one }
  if (Active^.CurTarget > High(Active^.Foes)) or (Active^.CurTarget < 0)
     or (not Active^.Foes[Active^.CurTarget].alive) then
    Active^.CurTarget := FirstLivingFoe;

  FinishSubAction(false);
end;

{ ---- post-fight spoils ---- }

const
  LOOT_CHANCE = 12;   { percent chance a won fight yields an unknown find }

procedure AwardBossFlag;
begin
  if Active^.Victory and (BossRewardFlag <> '') then FlagSet(BossRewardFlag);
  BossRewardFlag := '';
end;

function GrantVictoryLoot: boolean;
var i, wi: longint;
begin
  GrantVictoryLoot := false;
  if not Active^.Victory then exit;
  if ItemIndex('ELIXIR') < 0 then exit;
  if Range(1, 100) > LOOT_CHANCE then exit;
  wi := -1;
  for i := 0 to High(Roster) do
    if Roster[i].alive and (not Roster[i].downed) then begin wi := i; break; end;
  if wi < 0 then exit;
  PackAdd(Roster[wi], 'ELIXIR', 1);
  GrantVictoryLoot := true;
end;

end.
