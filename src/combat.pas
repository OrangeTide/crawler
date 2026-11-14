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
  skillbook, encounters, codex, flags, combatstate, combatcore, combatai, sprbank;

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
{ Whether the given party member may fall back to the rear rank: it must be
  in front now, and the front must still carry at least the back's bulk after
  it leaves, so no back-rank ally is left without cover. }
function CanFallBack(idx: longint): boolean;

{ ---- turn pacing ---- }
{ Advance the combat clock; the game calls this each frame while fighting.
  It paces the pause after an action and each foe's turn. Acts on the Active
  fight. }
procedure CombatUpdate(dt: double);

{ Advance every live fight by one tick under the shared clock, each as its own
  turn-based instance (design section 24). Active is repointed at each in turn
  and restored afterward, so the caller keeps whichever fight it was showing.
  Single player has one live fight, so this equals CombatUpdate on it. }
procedure CombatUpdateAll(dt: double);

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
  Active^.TurnContinue := false;
  CheckEnd;
  if Active^.CombatOver then begin Active^.CombatPhase := CP_DONE; exit; end;
  inc(Active^.TurnPos);
  Active^.CombatPhase := CP_BEAT;
  Active^.CombatTimer := BEAT_TIME * CombatBeatScale;
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
  if Active^.CombatOver then begin Active^.TurnContinue := false; Active^.CombatPhase := CP_DONE; exit; end;
  Active^.TurnContinue := true;
  Active^.CombatPhase := CP_BEAT;
  Active^.CombatTimer := BEAT_TIME * CombatBeatScale;
end;

{ A combatant's turn-order speed, higher acting sooner. Party members run
  off Dexterity, foes off their speed stat; slow drags either down. }
function PartySpeed(i: longint): longint;
begin
  PartySpeed := 4 + AbilMod(Active^.Party^[i].abil[abDEX]);
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
  i, n, a, b, sd: longint;
  tmpEnt: TTurnEnt;
  tmpInit: longint;
begin
  if (LivingFoes > 0) and (LivingFoes <= Active^.FoesAtStart div 2) then MoraleCheck;
  CheckEnd;
  if Active^.CombatOver then begin Active^.CombatPhase := CP_DONE; exit; end;

  SetLength(Active^.TurnQueue, 0);
  SetLength(init, 0);
  n := 0;
  { party first (SIDE_PARTY = 1), then foes, so the initiative rolls fall in
    the same order as before }
  for sd := SIDE_PARTY downto SIDE_FOE do
    for i := 0 to CombatantCount(sd) - 1 do
      if CombatantUp(sd, i) then begin
        SetLength(Active^.TurnQueue, n + 1); SetLength(init, n + 1);
        Active^.TurnQueue[n].side := sd; Active^.TurnQueue[n].idx := i;
        if sd = SIDE_PARTY then init[n] := PartySpeed(i) + Range(1, 4)
        else init[n] := FoeSpeed(i) + Range(1, 4);
        inc(n);
      end;

  { insertion sort, descending initiative }
  for a := 1 to n - 1 do begin
    tmpEnt := Active^.TurnQueue[a]; tmpInit := init[a];
    b := a - 1;
    while (b >= 0) and (init[b] < tmpInit) do begin
      Active^.TurnQueue[b + 1] := Active^.TurnQueue[b]; init[b + 1] := init[b];
      dec(b);
    end;
    Active^.TurnQueue[b + 1] := tmpEnt; init[b + 1] := tmpInit;
  end;

  Active^.TurnPos := 0;
  Active^.CurTarget := FirstLivingFoe;
  AdvanceTurn;
end;

function TurnEntAlive(const e: TTurnEnt): boolean;
begin
  TurnEntAlive := CombatantUp(e.side, e.idx);
end;

{ Run the start-of-turn status for a combatant: damage over time, then a
  skipped turn if stunned. Returns true when the turn is spent (the actor
  died or was stunned) so the caller advances past it. }
function StartOfTurnSpent(const e: TTurnEnt): boolean;
var i, side: longint; st: PStatus;
begin
  StartOfTurnSpent := false;
  side := e.side; i := e.idx;
  st := CombatantStatus(side, i);
  { damage over time: poison ticks whether up or not, burn only while up }
  if st^.poison > 0 then begin
    DamageCombatant(side, i, POISON_DMG, EL_PHYS); dec(st^.poison);
  end;
  if CombatantUp(side, i) and (st^.burn > 0) then begin
    DamageCombatant(side, i, BURN_DMG, EL_FIRE); dec(st^.burn);
  end;
  if st^.slow > 0 then dec(st^.slow);
  if st^.offbal > 0 then dec(st^.offbal);
  if st^.fear > 0 then dec(st^.fear);
  if not CombatantUp(side, i) then begin StartOfTurnSpent := true; exit; end;
  { a held or stunned combatant loses its turn }
  if st^.paralyze > 0 then begin
    dec(st^.paralyze);
    CombatLog(CombatantName(side, i) + ' is held fast.');
    PushPop(side, i, POPC_MISS, 'HELD');
    StartOfTurnSpent := true;
  end else if st^.stun > 0 then begin
    dec(st^.stun);
    CombatLog(CombatantName(side, i) + ' is stunned.');
    PushPop(side, i, POPC_MISS, 'STUN');
    StartOfTurnSpent := true;
  end;
end;

procedure ResolveEnemyTurn; forward;

{ Hand the turn to the next living actor: a party member waits for input,
  a foe acts on the clock. Skips the dead and the status-spent. }
procedure AdvanceTurn;
var e: TTurnEnt;
begin
  if Active^.CombatOver then begin Active^.CombatPhase := CP_DONE; exit; end;
  while Active^.TurnPos <= High(Active^.TurnQueue) do begin
    if TurnEntAlive(Active^.TurnQueue[Active^.TurnPos]) then break;
    inc(Active^.TurnPos);
  end;
  if Active^.TurnPos > High(Active^.TurnQueue) then begin NewRound; exit; end;

  e := Active^.TurnQueue[Active^.TurnPos];
  if StartOfTurnSpent(e) then begin EndTurn; exit; end;

  if e.side = SIDE_PARTY then begin
    Active^.CurActor := e.idx;
    Active^.Party^[e.idx].guarding := false;   { the defence held until now }
    Active^.TurnMoved := false;                { a fresh move and action this turn }
    Active^.TurnActed := false;
    Active^.CombatPhase := CP_INPUT;
  end else begin
    Active^.CombatPhase := CP_ENEMY;
    Active^.CombatTimer := ENEMY_STEP * CombatBeatScale;
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
  if Active^.CombatTimer > 0 then begin
    Active^.CombatTimer := Active^.CombatTimer - dt;
    if Active^.CombatTimer > 0 then exit;
    Active^.CombatTimer := 0;
  end;
  case Active^.CombatPhase of
    CP_BEAT:
      if Active^.TurnContinue then begin
        Active^.TurnContinue := false;
        Active^.CombatPhase := CP_INPUT;   { same actor takes its remaining slot }
      end else
        AdvanceTurn;
    CP_ENEMY: begin ResolveEnemyTurn; EndTurn; end;
  end;
end;

procedure CombatUpdateAll(dt: double);
var prev: PCombat; i: longint; c: PCombat;
begin
  prev := Active;
  for i := 0 to MAX_COMBATS - 1 do begin
    c := CombatSlot(i);
    if (c = nil) or (not c^.Live) then continue;
    SetActiveCombat(c);
    CombatUpdate(dt);
  end;
  SetActiveCombat(prev);
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

{ Summed bulk of the party's two ranks, over members that are up (alive and
  not downed), since a fallen body gives no cover. }
procedure PartyBulk(out frontB, backB: longint);
var i: longint;
begin
  frontB := 0; backB := 0;
  for i := 0 to High(Active^.Party^) do
    if Active^.Party^[i].alive and not Active^.Party^[i].downed then
      if Active^.Party^[i].rank = RANK_FRONT then
        frontB := frontB + SizeBulk(Active^.Party^[i].size)
      else
        backB := backB + SizeBulk(Active^.Party^[i].size);
end;

function CanFallBack(idx: longint): boolean;
var frontB, backB, myB: longint;
begin
  CanFallBack := false;
  if (idx < 0) or (idx > High(Active^.Party^)) then exit;
  if Active^.Party^[idx].rank <> RANK_FRONT then exit;
  PartyBulk(frontB, backB);
  myB := SizeBulk(Active^.Party^[idx].size);
  { after the step the member counts toward the back rank instead of the front }
  CanFallBack := (frontB - myB) >= (backB + myB);
end;

{ Promote the largest back-rank foes to the front until the front rank carries
  at least as much bulk as the back, so every back foe has cover. }
procedure EnforceFoeCover;
var i, fB, bB, big, bigBulk, b: longint;
begin
  repeat
    fB := 0; bB := 0;
    for i := 0 to High(Active^.Foes) do
      if Active^.Foes[i].alive then
        if Active^.Foes[i].rank = RANK_FRONT then
          fB := fB + SizeBulk(MonDefs[Active^.Foes[i].def].size)
        else
          bB := bB + SizeBulk(MonDefs[Active^.Foes[i].def].size);
    if fB >= bB then exit;
    big := -1; bigBulk := -1;
    for i := 0 to High(Active^.Foes) do
      if Active^.Foes[i].alive and (Active^.Foes[i].rank = RANK_BACK) then begin
        b := SizeBulk(MonDefs[Active^.Foes[i].def].size);
        if b > bigBulk then begin bigBulk := b; big := i; end;
      end;
    if big < 0 then exit;   { nothing left in back to promote }
    Active^.Foes[big].rank := RANK_FRONT;
  until false;
end;

procedure BuildEncounter(depth, tableNum, leadMon: longint);
{** Build a fight. When leadMon is a valid monster index the first foe is
  that monster (a caught pursuer joins the fight it caused); otherwise all
  foes are drawn from the area table. With leadMon = -1 the draw is
  identical to a plain random encounter. }
var
  pick, count, i, j, npool, e, mi, wrep: longint;
  pool: array of longint;
begin
  Active^.Party := @Roster;    { the party side; MP later keys a joining party }
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
    Active^.Foes[i].spriteIdx := -2;      { resolved on the first draw/update }
    CursorStart(Active^.Foes[i].anim, -1);
    { phase identical foes so a rank of the same creature does not lockstep }
    Active^.Foes[i].anim.clock := i * 0.13;
    { ranged monsters hang back; melee forms the front line. Size then settles
      the ranks: EnforceFoeCover below promotes foes until the front carries at
      least the back's bulk. }
    if (MonDefs[pick].flags and MF_RANGED) <> 0 then
      Active^.Foes[i].rank := RANK_BACK
    else
      Active^.Foes[i].rank := RANK_FRONT;
    { caster and healer foes carry a small pool of spell points }
    if (MonDefs[pick].flags and (MF_MAGE or MF_HEALER)) <> 0 then
      Active^.Foes[i].sp := 4 + depth
    else
      Active^.Foes[i].sp := 0;
  end;
  EnforceFoeCover;   { front bulk >= back bulk, and so someone is reachable }
  Active^.FoesAtStart := count;

  { rebuild the per-caster spell lists in case the party changed or levelled.
    Spell points are a persistent pool now, carried in from exploration and
    refilled by rest, so a fight no longer tops them off. }
  ResetSpellList;

  { clear hit feedback and status for the new fight }
  SetLength(Active^.Pops, 0);
  SetLength(Active^.FoeFlash, Length(Active^.Foes));
  SetLength(Active^.PartyFlash, Length(Active^.Party^));
  SetLength(Active^.FoeStatus, Length(Active^.Foes));
  SetLength(Active^.PartyStatus, Length(Active^.Party^));
  for i := 0 to High(Active^.FoeStatus) do FillChar(Active^.FoeStatus[i], SizeOf(TStatus), 0);
  for i := 0 to High(Active^.PartyStatus) do FillChar(Active^.PartyStatus[i], SizeOf(TStatus), 0);

  { reset the per-fight maneuver tallies and the cached skill menu, so each
    fight starts with every limited maneuver's uses restored }
  ResetSkillMenu;
  SetLength(Active^.SkillUse, Length(Active^.Party^));
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
  fi := Active^.TurnQueue[Active^.TurnPos].idx;
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
  end else if Active^.Foes[fi].rank <> FrontRank(SIDE_FOE) then begin
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
  effAC := CharAC(Active^.Party^[tgt]);
  if Active^.Party^[tgt].guarding then effAC := effAC + 2;   { braced to parry }
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
    if Active^.Party^[tgt].guarding then dmg := dmg div 2;          { defend halves }
    if ranged and (Active^.Party^[tgt].rank = RANK_BACK) then dmg := dmg div 2;
    if dmg < 1 then dmg := 1;
    dmg := ResistedHit(tgt, dmg, MonDefs[Active^.Foes[fi].def].element);
    CombatLog(MonDefs[Active^.Foes[fi].def].name + ' hits ' + Active^.Party^[tgt].name
      + ' for ' + IntToStr(dmg) + '.');
    PushPop(1, tgt, POPC_PARTYDMG, IntToStr(dmg));
    FlashCombatant(SIDE_PARTY, tgt);
    Active^.CombatSfxCue := CUE_HIT;
    HurtMember(tgt, dmg);
    if Active^.Party^[tgt].alive and (not Active^.Party^[tgt].downed) then begin
      if MonDefs[Active^.Foes[fi].def].inflict <> 0 then
        AfflictCombatant(SIDE_PARTY, tgt, MonDefs[Active^.Foes[fi].def].inflict, 3);
      { a lycanthrope's wound can pass on the curse, on a failed save }
      if ((MonDefs[Active^.Foes[fi].def].flags and MF_LYCAN) <> 0)
        and (not Active^.Party^[tgt].lycan)
        and (not SaveThrow(GameRng, AbilMod(Active^.Party^[tgt].abil[abCON]),
                           Active^.Party^[tgt].level, 13)) then
      begin
        Active^.Party^[tgt].lycan := true;
        CombatLog(Active^.Party^[tgt].name + ' is marked by the curse!');
      end;
    end;
  end else begin
    CombatLog(MonDefs[Active^.Foes[fi].def].name + ' misses ' + Active^.Party^[tgt].name + '.');
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
    CombatLog(Active^.Party^[Active^.CurActor].name + ' has no target in reach.');
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
  Active^.Party^[Active^.CurActor].guarding := true;
  CombatLog(Active^.Party^[Active^.CurActor].name + ' braces to defend.');
  FinishSubAction(false);
end;

procedure ActMove;
begin
  if Active^.CombatOver or (Active^.CurActor < 0) or (Active^.CombatPhase <> CP_INPUT) then exit;
  { step between the front line and the back; this spends the move slot }
  if Active^.Party^[Active^.CurActor].rank = RANK_FRONT then begin
    { falling back needs enough bulk left in front to cover the rear }
    if not CanFallBack(Active^.CurActor) then begin
      CombatLog(Active^.Party^[Active^.CurActor].name
        + ' holds the line; the front is too thin to fall back.');
      exit;   { an illegal move spends nothing }
    end;
    Active^.Party^[Active^.CurActor].rank := RANK_BACK;
    CombatLog(Active^.Party^[Active^.CurActor].name + ' falls back.');
  end else begin
    Active^.Party^[Active^.CurActor].rank := RANK_FRONT;
    CombatLog(Active^.Party^[Active^.CurActor].name + ' steps up to the front.');
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
    CombatLog(Active^.Party^[Active^.CurActor].name + ' fails to break away.');
    EndTurn;
  end;
end;

{ Pass: give up any unused move and action and end the turn. }
procedure ActSkip;
begin
  if Active^.CombatOver or (Active^.CurActor < 0) or (Active^.CombatPhase <> CP_INPUT) then exit;
  CombatLog(Active^.Party^[Active^.CurActor].name + ' waits.');
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
  if (slot < 0) or (slot > High(Active^.Party^[Active^.CurActor].pack)) then exit;
  if Active^.Party^[Active^.CurActor].pack[slot].qty <= 0 then exit;
  def := Active^.Party^[Active^.CurActor].pack[slot].def;
  if (def < 0) or (def > High(ItemDefs)) then exit;
  if ItemDefs[def].kind <> IK_POTION then exit;
  if (target < 0) or (target > High(Active^.Party^)) or (not Active^.Party^[target].alive) then exit;
  reviving := (ItemDefs[def].flags and IF_REVIVE) <> 0;
  if reviving and (not Active^.Party^[target].downed) then exit;
  if (not reviving) and Active^.Party^[target].downed then exit;

  dec(Active^.Party^[Active^.CurActor].pack[slot].qty);
  MarkItemKnown(def);   { quaffing an unknown potion reveals what it is }
  heal := RngRoll(GameRng, 1, 8) + 2;
  if reviving then begin
    Active^.Party^[target].downed := false;
    Active^.Party^[target].hp := heal;
  end else
    Active^.Party^[target].hp := Active^.Party^[target].hp + heal;
  if Active^.Party^[target].hp > Active^.Party^[target].hpMax then
    Active^.Party^[target].hp := Active^.Party^[target].hpMax;
  CombatLog(Active^.Party^[Active^.CurActor].name + ' uses ' + ItemDefs[def].name
    + ' on ' + Active^.Party^[target].name + ' (+' + IntToStr(heal) + ').');
  PushPop(1, target, POPC_HEAL, '+' + IntToStr(heal));
  FlashCombatant(SIDE_PARTY, target);
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
    CombatLog(Active^.Party^[Active^.CurActor].name + ' cannot cast that.');
    exit;
  end;
  sp := SpellInfo(spellIdx);
  dec(Active^.Party^[Active^.CurActor].sp, sp.cost);
  m := CasterMod(Active^.CurActor);
  { a specialist casting in its favored school presses the save harder }
  edge := 0;
  if (sp.school <> SCH_NONE)
    and (ClassSchool(Active^.Party^[Active^.CurActor].klass) = sp.school) then edge := 1;

  case sp.mode of
    TGT_ENEMY: begin
      if (target < 0) or (target > High(Active^.Foes)) or (not Active^.Foes[target].alive) then
        target := FirstLivingFoe;
      if target < 0 then begin FinishSubAction(false); exit; end;
      CombatLog(Active^.Party^[Active^.CurActor].name + ' casts ' + sp.name + '.');
      DamageCombatant(SIDE_FOE, target, RngRoll(GameRng, sp.dice, sp.sides) + m, sp.element);
      if Active^.Foes[target].alive and (sp.inflict <> 0) then
        AfflictCombatant(SIDE_FOE, target, sp.inflict, 3, edge);
    end;
    TGT_ENEMY_RANK: begin
      if (target < 0) or (target > High(Active^.Foes)) or (not Active^.Foes[target].alive) then
        target := FirstLivingFoe;
      if target < 0 then begin FinishSubAction(false); exit; end;
      rk := Active^.Foes[target].rank;
      CombatLog(Active^.Party^[Active^.CurActor].name + ' casts ' + sp.name + '.');
      for i := 0 to High(Active^.Foes) do
        if Active^.Foes[i].alive and (Active^.Foes[i].rank = rk) then begin
          DamageCombatant(SIDE_FOE, i, RngRoll(GameRng, sp.dice, sp.sides) + m, sp.element);
          if Active^.Foes[i].alive and (sp.inflict <> 0) then
            AfflictCombatant(SIDE_FOE, i, sp.inflict, 3, edge);
        end;
    end;
    TGT_ALLY: begin
      if (target < 0) or (target > High(Active^.Party^)) or (not Active^.Party^[target].alive) then
        target := Active^.CurActor;
      amt := RngRoll(GameRng, sp.dice, sp.sides) + m;
      if amt < 1 then amt := 1;
      if Active^.Party^[target].downed and Active^.Party^[target].alive then
        Active^.Party^[target].downed := false;    { a mend brings them to their feet }
      Active^.Party^[target].hp := Active^.Party^[target].hp + amt;
      if Active^.Party^[target].hp > Active^.Party^[target].hpMax then
        Active^.Party^[target].hp := Active^.Party^[target].hpMax;
      CombatLog(Active^.Party^[Active^.CurActor].name + ' mends ' + Active^.Party^[target].name
        + ' (+' + IntToStr(amt) + ').');
      PushPop(1, target, POPC_HEAL, '+' + IntToStr(amt));
      FlashCombatant(SIDE_PARTY, target);
    end;
    TGT_PARTY: begin
      Active^.PartyBless := 1;
      CombatLog(Active^.Party^[Active^.CurActor].name + ' blesses the party.');
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
    CombatLog(Active^.Party^[Active^.CurActor].name + ' cannot do that.');
    exit;
  end;
  sk := CombatSkillInfo(skillIdx);
  rk := SkillRank(Active^.Party^[Active^.CurActor], CombatSkillCat(skillIdx));
  if rk < 0 then rk := 0;
  bonus := 0;
  if sk.dice > 0 then bonus := RngRoll(GameRng, sk.dice, sk.sides);
  SpendManeuver(Active^.CurActor, skillIdx);
  CombatLog(Active^.Party^[Active^.CurActor].name + ' uses ' + sk.name + '.');

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
      for i := 0 to High(Active^.Party^) do
        if Active^.Party^[i].alive then Active^.PartyStatus[i].fear := 0;
      Active^.PartyBless := 1;
      CombatLog(Active^.Party^[Active^.CurActor].name + ' rallies the party.');
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
  for i := 0 to High(Active^.Party^) do
    if Active^.Party^[i].alive and (not Active^.Party^[i].downed) then begin wi := i; break; end;
  if wi < 0 then exit;
  PackAdd(Active^.Party^[wi], 'ELIXIR', 1);
  GrantVictoryLoot := true;
end;

end.
