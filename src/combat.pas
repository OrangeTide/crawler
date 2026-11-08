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

  The game drives this: it reads CurActor / CombatPhase to know whose
  input is wanted, calls an action procedure, and checks CombatOver. }

{$mode objfpc}{$H+}

interface

uses
  sysutils, rng, rules, items, monsters, party, chardata, spelldb, encounters,
  codex, combatstate, combatcore, combatai;

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

implementation

type
  TTurnEnt = record
    side: byte;        { 0 a foe, 1 a party member }
    idx: longint;      { index into Foes or Roster }
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
    CombatOver := true;
    Victory := true;
    GoldGained := Range(0, 10) * Length(Foes) + Range(0, 20);
    PartyGold := PartyGold + GoldGained;
    CombatLog('Victory. ' + IntToStr(XPGained) + ' XP, '
      + IntToStr(GoldGained) + ' gold.');
    exit;
  end;
  if not PartyConscious then begin
    CombatOver := true;
    Victory := false;
    CombatLog('The party falls.');
  end;
end;

procedure MoraleCheck;
var i, best: longint;
begin
  best := 0;
  for i := 0 to High(Foes) do
    if Foes[i].alive and (MonDefs[Foes[i].def].morale > best) then
      best := MonDefs[Foes[i].def].morale;
  if D(6) > best then begin
    CombatLog('The enemy breaks and flees!');
    for i := 0 to High(Foes) do Foes[i].alive := false;
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
  if CombatOver then begin CombatPhase := CP_DONE; exit; end;
  inc(TurnPos);
  CombatPhase := CP_BEAT;
  CombatTimer := BEAT_TIME * CombatBeatScale;
end;

{ A party member gets one move and one other action per turn, in either
  order. A sub-action marks its slot; the turn ends once both slots are
  spent (or on a SKIP or FLEE, which end it outright through EndTurn).
  Until then the same actor is handed back the command menu after a beat. }
procedure FinishSubAction(isMove: boolean);
begin
  if isMove then TurnMoved := true else TurnActed := true;
  if TurnMoved and TurnActed then begin
    EndTurn;
    exit;
  end;
  CheckEnd;
  if CombatOver then begin TurnContinue := false; CombatPhase := CP_DONE; exit; end;
  TurnContinue := true;
  CombatPhase := CP_BEAT;
  CombatTimer := BEAT_TIME * CombatBeatScale;
end;

{ A combatant's turn-order speed, higher acting sooner. Party members run
  off Dexterity, foes off their speed stat; slow drags either down. }
function PartySpeed(i: longint): longint;
begin
  PartySpeed := 4 + AbilMod(Roster[i].abil[abDEX]);
  if PartyStatus[i].slow > 0 then PartySpeed := PartySpeed - 4;
end;

function FoeSpeed(i: longint): longint;
begin
  FoeSpeed := MonDefs[Foes[i].def].speed;
  if FoeStatus[i].slow > 0 then FoeSpeed := FoeSpeed - 4;
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
  if CombatOver then begin CombatPhase := CP_DONE; exit; end;

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
  for i := 0 to High(Foes) do
    if Foes[i].alive then begin
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
  CurTarget := FirstLivingFoe;
  AdvanceTurn;
end;

function TurnEntAlive(const e: TTurnEnt): boolean;
begin
  if e.side = 1 then
    TurnEntAlive := (e.idx <= High(Roster)) and Roster[e.idx].alive
      and (not Roster[e.idx].downed)
  else
    TurnEntAlive := (e.idx <= High(Foes)) and Foes[e.idx].alive;
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
    if FoeStatus[i].poison > 0 then begin
      DamageFoe(i, POISON_DMG, EL_PHYS); dec(FoeStatus[i].poison);
    end;
    if Foes[i].alive and (FoeStatus[i].burn > 0) then begin
      DamageFoe(i, BURN_DMG, EL_FIRE); dec(FoeStatus[i].burn);
    end;
    if FoeStatus[i].slow > 0 then dec(FoeStatus[i].slow);
    if FoeStatus[i].offbal > 0 then dec(FoeStatus[i].offbal);
    if FoeStatus[i].fear > 0 then dec(FoeStatus[i].fear);
    if not Foes[i].alive then begin StartOfTurnSpent := true; exit; end;
    if FoeStatus[i].paralyze > 0 then begin
      dec(FoeStatus[i].paralyze);
      CombatLog(MonDefs[Foes[i].def].name + ' is held fast.');
      PushPop(0, i, POPC_MISS, 'HELD');
      StartOfTurnSpent := true;
    end else if FoeStatus[i].stun > 0 then begin
      dec(FoeStatus[i].stun);
      CombatLog(MonDefs[Foes[i].def].name + ' is stunned.');
      PushPop(0, i, POPC_MISS, 'STUN');
      StartOfTurnSpent := true;
    end;
  end else begin
    i := e.idx;
    if PartyStatus[i].poison > 0 then begin
      PushPop(1, i, POPC_PARTYDMG, IntToStr(POISON_DMG)); FlashAlly(i);
      HurtMember(i, POISON_DMG); dec(PartyStatus[i].poison);
    end;
    if Roster[i].alive and (not Roster[i].downed) and (PartyStatus[i].burn > 0) then begin
      bd := ResistedHit(i, BURN_DMG, EL_FIRE);
      PushPop(1, i, POPC_PARTYDMG, IntToStr(bd)); FlashAlly(i);
      HurtMember(i, bd); dec(PartyStatus[i].burn);
    end;
    if PartyStatus[i].slow > 0 then dec(PartyStatus[i].slow);
    if PartyStatus[i].offbal > 0 then dec(PartyStatus[i].offbal);
    if PartyStatus[i].fear > 0 then dec(PartyStatus[i].fear);
    if (not Roster[i].alive) or Roster[i].downed then begin
      StartOfTurnSpent := true; exit;
    end;
    if PartyStatus[i].paralyze > 0 then begin
      dec(PartyStatus[i].paralyze);
      CombatLog(Roster[i].name + ' is held fast.');
      PushPop(1, i, POPC_MISS, 'HELD');
      StartOfTurnSpent := true;
    end else if PartyStatus[i].stun > 0 then begin
      dec(PartyStatus[i].stun);
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
  if CombatOver then begin CombatPhase := CP_DONE; exit; end;
  while TurnPos <= High(TurnQueue) do begin
    if TurnEntAlive(TurnQueue[TurnPos]) then break;
    inc(TurnPos);
  end;
  if TurnPos > High(TurnQueue) then begin NewRound; exit; end;

  e := TurnQueue[TurnPos];
  if StartOfTurnSpent(e) then begin EndTurn; exit; end;

  if e.side = 1 then begin
    CurActor := e.idx;
    Roster[e.idx].guarding := false;   { the defence held until now }
    TurnMoved := false;                { a fresh move and action this turn }
    TurnActed := false;
    CombatPhase := CP_INPUT;
  end else begin
    CombatPhase := CP_ENEMY;
    CombatTimer := ENEMY_STEP * CombatBeatScale;
  end;
end;

function CombatBusy: boolean;
begin
  CombatBusy := (not CombatOver) and (CombatPhase <> CP_INPUT);
end;

procedure CombatUpdate(dt: double);
begin
  DecayFeedback(dt);   { flashes and numbers fade in every phase }
  if CombatOver then begin CombatPhase := CP_DONE; exit; end;
  if CombatTimer > 0 then begin
    CombatTimer := CombatTimer - dt;
    if CombatTimer > 0 then exit;
    CombatTimer := 0;
  end;
  case CombatPhase of
    CP_BEAT:
      if TurnContinue then begin
        TurnContinue := false;
        CombatPhase := CP_INPUT;   { same actor takes its remaining slot }
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
  pick, count, i, front, npool, e, mi, wrep: longint;
  pool: array of longint;
begin
  SetLength(Foes, 0);
  CombatOver := false;
  Victory := false;
  Fled := false;
  PartyBless := 0;
  PartyDark := 0;      { well lit by default; combatui dims it from the torch }
  XPGained := 0;
  GoldGained := 0;
  for i := 0 to LOG_LINES - 1 do Log[i] := '';

  if Length(MonDefs) = 0 then begin
    CombatOver := true; Victory := true; exit;
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
  SetLength(Foes, count);
  front := 0;
  for i := 0 to count - 1 do begin
    pick := pool[Range(0, npool - 1)];
    { the lead foe is the pursuer when one is named; the draw above still
      runs so a plain encounter (leadMon = -1) is bit-for-bit unchanged. }
    if (i = 0) and (leadMon >= 0) and (leadMon <= High(MonDefs)) then
      pick := leadMon;
    Foes[i].def := pick;
    Foes[i].hp := RngRoll(GameRng, MonDefs[pick].hd, 8);
    if Foes[i].hp < 1 then Foes[i].hp := 1;
    Foes[i].hpMax := Foes[i].hp;
    Foes[i].alive := true;
    { ranged monsters hang back; melee forms a front line, up to three }
    if ((MonDefs[pick].flags and MF_RANGED) <> 0) or (front >= 3) then
      Foes[i].rank := RANK_BACK
    else begin
      Foes[i].rank := RANK_FRONT; inc(front);
    end;
    { caster and healer foes carry a small pool of spell points }
    if (MonDefs[pick].flags and (MF_MAGE or MF_HEALER)) <> 0 then
      Foes[i].sp := 4 + depth
    else
      Foes[i].sp := 0;
  end;
  if front = 0 then Foes[0].rank := RANK_FRONT;   { someone must be reachable }
  FoesAtStart := count;

  { give casters a small pool of spell points for the fight, and rebuild the
    per-caster spell lists in case the party changed or levelled }
  ResetSpellList;
  for i := 0 to High(Roster) do
    Roster[i].sp := CharSpellPoints(Roster[i]);

  { clear hit feedback and status for the new fight }
  SetLength(Pops, 0);
  SetLength(FoeFlash, Length(Foes));
  SetLength(PartyFlash, Length(Roster));
  SetLength(FoeStatus, Length(Foes));
  SetLength(PartyStatus, Length(Roster));
  for i := 0 to High(FoeStatus) do FillChar(FoeStatus[i], SizeOf(TStatus), 0);
  for i := 0 to High(PartyStatus) do FillChar(PartyStatus[i], SizeOf(TStatus), 0);
  CombatSfxCue := CUE_NONE;

  { the party now meets these foes: record them in the bestiary }
  for i := 0 to High(Foes) do MarkMonSeen(Foes[i].def);

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
  if (fi > High(Foes)) or (not Foes[fi].alive) then exit;
  if FirstConscious < 0 then exit;
  ranged := (MonDefs[Foes[fi].def].flags and MF_RANGED) <> 0;
  hasHarry := MonDefs[Foes[fi].def].harry <> HARRY_NONE;
  isMage := (MonDefs[Foes[fi].def].flags and MF_MAGE) <> 0;
  isHealer := (MonDefs[Foes[fi].def].flags and MF_HEALER) <> 0;

  { a healer raises a fallen ally first, then tends a wounded one }
  if isHealer and EnemyCastRevive(fi) then exit;
  if isHealer and EnemyCastHeal(fi) then exit;
  { a mage usually conjures a bolt rather than closing or swinging }
  if isMage and (Foes[fi].sp >= FOE_CAST_SP) and (D(100) <= 70)
     and EnemyCastBolt(fi) then exit;

  if ranged then begin
    { a caster slips back behind cover when it can }
    if EnemyMaybeMove(fi, true) then exit;
  end else if Foes[fi].rank <> FrontFoeRank then begin
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
  atkB := MonDefs[Foes[fi].def].atkBonus;
  if FoeStatus[fi].fear > 0 then dec(atkB, FEAR_ATK);   { afraid: swings wide }
  if OptCriticals then
    hit := (roll <> 1) and ((roll = 20) or (roll + atkB >= effAC))
  else
    hit := roll + atkB >= effAC;   { plain roll, no natural 20/1 }
  if hit then
  begin
    dmg := D(MonDefs[Foes[fi].def].dmgSides);
    if dmg < 1 then dmg := 1;
    if Roster[tgt].guarding then dmg := dmg div 2;          { defend halves }
    if ranged and (Roster[tgt].rank = RANK_BACK) then dmg := dmg div 2;
    if dmg < 1 then dmg := 1;
    dmg := ResistedHit(tgt, dmg, MonDefs[Foes[fi].def].element);
    CombatLog(MonDefs[Foes[fi].def].name + ' hits ' + Roster[tgt].name
      + ' for ' + IntToStr(dmg) + '.');
    PushPop(1, tgt, POPC_PARTYDMG, IntToStr(dmg));
    FlashAlly(tgt);
    CombatSfxCue := CUE_HIT;
    HurtMember(tgt, dmg);
    if Roster[tgt].alive and (not Roster[tgt].downed) then begin
      if MonDefs[Foes[fi].def].inflict <> 0 then
        AfflictMember(tgt, MonDefs[Foes[fi].def].inflict, 3);
      { a lycanthrope's wound can pass on the curse, on a failed save }
      if ((MonDefs[Foes[fi].def].flags and MF_LYCAN) <> 0)
        and (not Roster[tgt].lycan)
        and (not SaveThrow(GameRng, AbilMod(Roster[tgt].abil[abCON]),
                           Roster[tgt].level, 13)) then
      begin
        Roster[tgt].lycan := true;
        CombatLog(Roster[tgt].name + ' is marked by the curse!');
      end;
    end;
  end else begin
    CombatLog(MonDefs[Foes[fi].def].name + ' misses ' + Roster[tgt].name + '.');
    PushPop(1, tgt, POPC_MISS, 'MISS');
  end;
end;

{ ---- player actions ---- }

procedure ActAttack;
begin
  if CombatOver or (CurActor < 0) or (CombatPhase <> CP_INPUT) then exit;
  if not FoeReachable(CurActor, CurTarget) then
    CurTarget := FirstReachable(CurActor);
  if CurTarget < 0 then begin
    CombatLog(Roster[CurActor].name + ' has no target in reach.');
    exit;   { the turn is not spent; pick another action or retarget }
  end;
  ResolvePartyAttack(CurActor, CurTarget);
  if (CurTarget > High(Foes)) or (not Foes[CurTarget].alive) then
    CurTarget := FirstLivingFoe;
  FinishSubAction(false);
end;

procedure ActGuard;
begin
  if CombatOver or (CurActor < 0) or (CombatPhase <> CP_INPUT) then exit;
  Roster[CurActor].guarding := true;
  CombatLog(Roster[CurActor].name + ' braces to defend.');
  FinishSubAction(false);
end;

procedure ActMove;
begin
  if CombatOver or (CurActor < 0) or (CombatPhase <> CP_INPUT) then exit;
  { step between the front line and the back; this spends the move slot }
  if Roster[CurActor].rank = RANK_FRONT then begin
    Roster[CurActor].rank := RANK_BACK;
    CombatLog(Roster[CurActor].name + ' falls back.');
  end else begin
    Roster[CurActor].rank := RANK_FRONT;
    CombatLog(Roster[CurActor].name + ' steps up to the front.');
  end;
  FinishSubAction(true);
end;

procedure ActFlee;
begin
  if CombatOver or (CurActor < 0) or (CombatPhase <> CP_INPUT) then exit;
  { a scramble to break off: succeeds on better than a coin toss, else the
    turn is lost }
  if D(6) >= 3 then begin
    CombatOver := true;
    Victory := false;
    Fled := true;
    CombatPhase := CP_DONE;
    CombatLog('The party breaks off and flees.');
  end else begin
    CombatLog(Roster[CurActor].name + ' fails to break away.');
    EndTurn;
  end;
end;

{ Pass: give up any unused move and action and end the turn. }
procedure ActSkip;
begin
  if CombatOver or (CurActor < 0) or (CombatPhase <> CP_INPUT) then exit;
  CombatLog(Roster[CurActor].name + ' waits.');
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
  if CombatOver or (CurActor < 0) or (CombatPhase <> CP_INPUT) then exit;
  if (slot < 0) or (slot > High(Roster[CurActor].pack)) then exit;
  if Roster[CurActor].pack[slot].qty <= 0 then exit;
  def := Roster[CurActor].pack[slot].def;
  if (def < 0) or (def > High(ItemDefs)) then exit;
  if ItemDefs[def].kind <> IK_POTION then exit;
  if (target < 0) or (target > High(Roster)) or (not Roster[target].alive) then exit;
  reviving := (ItemDefs[def].flags and IF_REVIVE) <> 0;
  if reviving and (not Roster[target].downed) then exit;
  if (not reviving) and Roster[target].downed then exit;

  dec(Roster[CurActor].pack[slot].qty);
  MarkItemKnown(def);   { quaffing an unknown potion reveals what it is }
  heal := RngRoll(GameRng, 1, 8) + 2;
  if reviving then begin
    Roster[target].downed := false;
    Roster[target].hp := heal;
  end else
    Roster[target].hp := Roster[target].hp + heal;
  if Roster[target].hp > Roster[target].hpMax then
    Roster[target].hp := Roster[target].hpMax;
  CombatLog(Roster[CurActor].name + ' uses ' + ItemDefs[def].name
    + ' on ' + Roster[target].name + ' (+' + IntToStr(heal) + ').');
  PushPop(1, target, POPC_HEAL, '+' + IntToStr(heal));
  FlashAlly(target);
  FinishSubAction(false);
end;

procedure NextTarget;
var start, i: longint;
begin
  if (LivingFoes = 0) or (CurActor < 0) then exit;
  start := CurTarget;
  if start < 0 then start := 0;
  i := start;
  repeat
    i := (i + 1) mod Length(Foes);
    if FoeReachable(CurActor, i) then begin CurTarget := i; exit; end;
  until i = start;
end;

{ ---- abilities ---- }

procedure ActCast(spellIdx, target: longint);
var
  sp: TSpell;
  amt, m, i, rk, edge: longint;
begin
  if CombatOver or (CurActor < 0) or (CombatPhase <> CP_INPUT) then exit;
  if not ActorCanCast(CurActor, spellIdx) then begin
    CombatLog(Roster[CurActor].name + ' cannot cast that.');
    exit;
  end;
  sp := SpellInfo(spellIdx);
  dec(Roster[CurActor].sp, sp.cost);
  m := CasterMod(CurActor);
  { a specialist casting in its favored school presses the save harder }
  edge := 0;
  if (sp.school <> SCH_NONE)
    and (ClassSchool(Roster[CurActor].klass) = sp.school) then edge := 1;

  case sp.mode of
    TGT_ENEMY: begin
      if (target < 0) or (target > High(Foes)) or (not Foes[target].alive) then
        target := FirstLivingFoe;
      if target < 0 then begin FinishSubAction(false); exit; end;
      CombatLog(Roster[CurActor].name + ' casts ' + sp.name + '.');
      DamageFoe(target, RngRoll(GameRng, sp.dice, sp.sides) + m, sp.element);
      if Foes[target].alive and (sp.inflict <> 0) then
        AfflictFoe(target, sp.inflict, 3, edge);
    end;
    TGT_ENEMY_RANK: begin
      if (target < 0) or (target > High(Foes)) or (not Foes[target].alive) then
        target := FirstLivingFoe;
      if target < 0 then begin FinishSubAction(false); exit; end;
      rk := Foes[target].rank;
      CombatLog(Roster[CurActor].name + ' casts ' + sp.name + '.');
      for i := 0 to High(Foes) do
        if Foes[i].alive and (Foes[i].rank = rk) then begin
          DamageFoe(i, RngRoll(GameRng, sp.dice, sp.sides) + m, sp.element);
          if Foes[i].alive and (sp.inflict <> 0) then
            AfflictFoe(i, sp.inflict, 3, edge);
        end;
    end;
    TGT_ALLY: begin
      if (target < 0) or (target > High(Roster)) or (not Roster[target].alive) then
        target := CurActor;
      amt := RngRoll(GameRng, sp.dice, sp.sides) + m;
      if amt < 1 then amt := 1;
      if Roster[target].downed and Roster[target].alive then
        Roster[target].downed := false;    { a mend brings them to their feet }
      Roster[target].hp := Roster[target].hp + amt;
      if Roster[target].hp > Roster[target].hpMax then
        Roster[target].hp := Roster[target].hpMax;
      CombatLog(Roster[CurActor].name + ' mends ' + Roster[target].name
        + ' (+' + IntToStr(amt) + ').');
      PushPop(1, target, POPC_HEAL, '+' + IntToStr(amt));
      FlashAlly(target);
    end;
    TGT_PARTY: begin
      PartyBless := 1;
      CombatLog(Roster[CurActor].name + ' blesses the party.');
    end;
  end;

  FinishSubAction(false);
end;

end.
