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
  sysutils, rng, rules, items, monsters, party, chardata, encounters;

const
  MAX_FOES = 6;
  LOG_LINES = 5;

  RANK_FRONT = 0;
  RANK_BACK  = 1;

  { ability targeting modes }
  TGT_ENEMY      = 0;   { one enemy, any rank }
  TGT_ENEMY_RANK = 1;   { every enemy in the target's rank }
  TGT_ALLY       = 2;   { one ally, oneself included }
  TGT_PARTY      = 3;   { the whole party, no pick }

  { ability effects }
  EF_DAMAGE = 0;
  EF_HEAL   = 1;
  EF_BLESS  = 2;

type
  TSpell = record
    id: string[8];
    name: string[14];
    track: byte;        { TRK_MAGE or TRK_PRIEST }
    cost: byte;         { spell points }
    mode: byte;         { TGT_* }
    effect: byte;       { EF_* }
    dice, sides: byte;  { for damage or healing }
    element: byte;      { EL_* of the damage it deals }
    inflict: byte;      { ST_* a damaging hit may apply, 0 = none }
  end;

  TFoe = record
    def: longint;
    hp: smallint;
    hpMax: smallint;
    alive: boolean;
    rank: byte;              { 0 front, 1 back }
    sp: smallint;            { spell points, for caster and healer foes }
  end;

  { status timers for one combatant, in turns remaining }
  TStatus = record
    poison, stun, slow, burn, offbal: smallint;
  end;

var
  Foes: array of TFoe;
  CombatOver: boolean;
  Victory: boolean;
  Fled: boolean;
  CurActor: longint;         { party member awaiting input, or -1 }
  CurTarget: longint;        { selected foe index }
  Log: array[0 .. LOG_LINES - 1] of string;
  XPGained: longint;
  GoldGained: longint;

{ Start a fight at a dungeon depth. tableNum selects the weighted encounter
  table to draw foes from; an empty or unknown table draws from every
  monster, so forced fights (quick battle, tests) still find foes. }
procedure StartRandomEncounter(depth: longint; tableNum: longint);
procedure CombatLog(const s: string);
function LivingFoes: longint;
function FirstLivingFoe: longint;
{ First foe the actor can actually strike, or -1. }
function FirstReachable(actor: longint): longint;
{ The frontmost living rank on each side; melee can only reach it. }
function FrontFoeRank: longint;
function FrontPartyRank: longint;
{ Whether the actor could strike this foe with its current weapon. }
function FoeReachable(actor, foe: longint): boolean;
procedure ActAttack;
procedure ActGuard;
procedure ActMove;
procedure ActFlee;
procedure ActUseItem(slot, target: longint);
procedure NextTarget;

{ ---- turn pacing ---- }
const
  CP_INPUT = 0;   { a party member awaits the player's command }
  CP_BEAT  = 1;   { a short pause after an action resolves }
  CP_ENEMY = 2;   { a foe is acting on its own }
  CP_DONE  = 3;   { combat has ended }

var
  CombatPhase: longint;

{ Advance the combat clock; the game calls this each frame while fighting.
  It paces the pause after an action and each foe's turn. }
procedure CombatUpdate(dt: double);

{ True while combat resolves on its own (a beat or a foe turn), so the
  game ignores input until the next party member is ready. }
function CombatBusy: boolean;

{ For headless tests: run the clock until a member is ready or the fight
  ends, instead of ticking real frames. }
procedure CombatSettle;

{ ---- hit feedback ---- }
const
  POP_LIFE   = 0.9;    { seconds a floating number lives }
  FLASH_LIFE = 0.22;   { seconds a struck target flashes }

  POPC_FOEDMG   = 0;   { damage dealt to a foe }
  POPC_PARTYDMG = 1;   { damage dealt to a party member }
  POPC_HEAL     = 2;   { healing }
  POPC_MISS     = 3;   { a whiff or a status tag }
  POPC_WEAK     = 4;   { damage against a weakness }
  POPC_RESIST   = 5;   { damage a foe resisted }

  CUE_NONE = 0;
  CUE_HIT  = 1;        { a foe swing landed; the game plays the sound }

type
  TPop = record
    side: byte;        { 0 a foe, 1 a party member }
    idx: longint;      { index into Foes or Roster }
    text: string[7];
    color: byte;       { POPC_* }
    life: double;      { seconds remaining, counts down from POP_LIFE }
  end;

var
  Pops: array of TPop;       { active floating numbers }
  FoeFlash: array of double; { per-foe flash timer }
  PartyFlash: array of double;
  CombatSfxCue: longint;     { a sound the game should play this frame }
  FoeStatus: array of TStatus;   { status timers, per foe }
  PartyStatus: array of TStatus; { status timers, per party member }

{ ---- abilities ---- }
{ ---- tactics (also used by tests) ---- }
{ The damage multiplier an element deals to a foe: 0 immune, 0.5 resisted,
  1.5 against a weakness, 1 otherwise. }
function ElementMult(element, fi: longint): double;
{ Deal elemental damage to a foe, applying its weakness or resistance. }
procedure DamageFoe(fi, baseAmount, element: longint);
{ Try to lay a status on a foe; immunity blocks it, a save resists it. }
procedure AfflictFoe(fi, st, turns: longint);
{ The foe AI's reposition choice: may flip foe fi's rank (melee closes to the
  front, a ranged caster with cover falls back) and report the turn as spent. }
function EnemyMaybeMove(fi: longint; ranged: boolean): boolean;
{ The foe AI's ranged disruption: a taunt or a thrown weapon. Spends the turn. }
function EnemyHarry(fi: longint): boolean;
{ Foe spellcasting: a mage's bolt at the party, a healer's mend on an ally. }
function EnemyCastBolt(fi: longint): boolean;
function EnemyCastHeal(fi: longint): boolean;
function EnemyCastRevive(fi: longint): boolean;
{ Resolve one party melee or ranged attack; off balance rolls at disadvantage. }
procedure ResolvePartyAttack(actor, foe: longint);

function SpellCount: longint;
function SpellInfo(i: longint): TSpell;
function ActorCanCast(actor, spellIdx: longint): boolean;
{ Cast spellIdx from the current actor. target is a foe index for enemy
  modes, an ally index for TGT_ALLY, and ignored for TGT_PARTY. }
procedure ActCast(spellIdx, target: longint);

var
  PartyBless: longint;      { a fight-long +hit from a blessing, 0 normally }

implementation

type
  TTurnEnt = record
    side: byte;        { 0 a foe, 1 a party member }
    idx: longint;      { index into Foes or Roster }
  end;

var
  TurnQueue: array of TTurnEnt;  { this round's actors, fastest first }
  TurnPos: longint;              { cursor into TurnQueue }
  CombatTimer: double;           { seconds left in the current beat }
  FoesAtStart: longint;          { for the morale threshold }

const
  BEAT_TIME  = 0.45;   { pause after an action before the next step }
  ENEMY_STEP = 0.55;   { how long a foe's own turn is held on screen }

  POISON_DMG = 2;
  BURN_DMG   = 3;
  STATUS_DC  = 13;     { save target to shrug off an inflicted status }
  FOE_CAST_SP = 2;     { spell points a foe spends per spell }
  FOE_REVIVE_SP = 3;   { spell points to raise a fallen ally }

{ ---- logging ---- }

procedure CombatLog(const s: string);
var
  i: longint;
begin
  for i := 0 to LOG_LINES - 2 do
    Log[i] := Log[i + 1];
  Log[LOG_LINES - 1] := s;
end;

{ ---- hit feedback ---- }

procedure PushPop(side, idx, color: longint; const txt: string);
var k: longint;
begin
  k := Length(Pops);
  SetLength(Pops, k + 1);
  Pops[k].side := side;
  Pops[k].idx := idx;
  Pops[k].text := Copy(txt, 1, 7);
  Pops[k].color := color;
  Pops[k].life := POP_LIFE;
end;

procedure FlashFoe(idx: longint);
begin
  if (idx >= 0) and (idx <= High(FoeFlash)) then FoeFlash[idx] := FLASH_LIFE;
end;

procedure FlashAlly(idx: longint);
begin
  if (idx >= 0) and (idx <= High(PartyFlash)) then PartyFlash[idx] := FLASH_LIFE;
end;

{ Age the flashes and floating numbers; drop the ones that expired. }
procedure DecayFeedback(dt: double);
var i, w: longint;
begin
  for i := 0 to High(FoeFlash) do
    if FoeFlash[i] > 0 then begin
      FoeFlash[i] := FoeFlash[i] - dt;
      if FoeFlash[i] < 0 then FoeFlash[i] := 0;
    end;
  for i := 0 to High(PartyFlash) do
    if PartyFlash[i] > 0 then begin
      PartyFlash[i] := PartyFlash[i] - dt;
      if PartyFlash[i] < 0 then PartyFlash[i] := 0;
    end;
  w := 0;
  for i := 0 to High(Pops) do begin
    Pops[i].life := Pops[i].life - dt;
    if Pops[i].life > 0 then begin
      if w <> i then Pops[w] := Pops[i];
      inc(w);
    end;
  end;
  SetLength(Pops, w);
end;

{ ---- helpers ---- }

function LivingFoes: longint;
var i, n: longint;
begin
  n := 0;
  for i := 0 to High(Foes) do
    if Foes[i].alive then inc(n);
  LivingFoes := n;
end;

function FirstLivingFoe: longint;
var i: longint;
begin
  FirstLivingFoe := -1;
  for i := 0 to High(Foes) do
    if Foes[i].alive then begin FirstLivingFoe := i; exit; end;
end;

{ The frontmost living foe rank: 0 if any front foe lives, else 1. }
function FrontFoeRank: longint;
var i: longint;
begin
  for i := 0 to High(Foes) do
    if Foes[i].alive and (Foes[i].rank = RANK_FRONT) then begin
      FrontFoeRank := RANK_FRONT; exit;
    end;
  FrontFoeRank := RANK_BACK;
end;

{ The frontmost conscious party rank. }
function FrontPartyRank: longint;
var i: longint;
begin
  for i := 0 to High(Roster) do
    if Roster[i].alive and (not Roster[i].downed) and (Roster[i].rank = RANK_FRONT) then begin
      FrontPartyRank := RANK_FRONT; exit;
    end;
  FrontPartyRank := RANK_BACK;
end;

function WeaponRanged(const c: TCharacter): boolean;
begin
  WeaponRanged := (c.equip[eqMain].def >= 0) and
    ((ItemDefs[c.equip[eqMain].def].flags and IF_RANGED) <> 0);
end;

{ A character's weapon element: silvered/blessed weapons strike as holy,
  everything else as plain physical. }
function WeaponElement(const c: TCharacter): byte;
begin
  if (c.equip[eqMain].def >= 0) and
     ((ItemDefs[c.equip[eqMain].def].flags and IF_SILVER) <> 0) then
    WeaponElement := EL_HOLY
  else
    WeaponElement := EL_PHYS;
end;

{ Whether actor can strike foe: ranged weapons reach any rank, melee only
  the frontmost living enemy rank, and only from the party front line. }
function FoeReachable(actor, foe: longint): boolean;
begin
  FoeReachable := false;
  if (foe < 0) or (foe > High(Foes)) or (not Foes[foe].alive) then exit;
  if WeaponRanged(Roster[actor]) then begin
    FoeReachable := true;           { arrows and bolts reach the back rank }
    exit;
  end;
  if Roster[actor].rank <> RANK_FRONT then exit;   { no melee from the back }
  FoeReachable := Foes[foe].rank = FrontFoeRank;
end;

{ First foe the actor can actually strike, or -1. }
function FirstReachable(actor: longint): longint;
var i: longint;
begin
  FirstReachable := -1;
  for i := 0 to High(Foes) do
    if FoeReachable(actor, i) then begin FirstReachable := i; exit; end;
end;

{ ---- elements and status ---- }

{ The damage multiplier an element deals to a foe: 0 immune, 0.5 resisted,
  1.5 against a weakness, 1 otherwise. }
function ElementMult(element, fi: longint): double;
var e: byte;
begin
  e := element;
  if e = 0 then e := EL_PHYS;
  if (MonDefs[Foes[fi].def].immune and e) <> 0 then ElementMult := 0.0
  else if (MonDefs[Foes[fi].def].weak and e) <> 0 then ElementMult := 1.5
  else if (MonDefs[Foes[fi].def].resist and e) <> 0 then ElementMult := 0.5
  else ElementMult := 1.0;
end;

function StatusName(st: longint): string;
begin
  case st of
    ST_POISON: StatusName := 'POISON';
    ST_STUN:   StatusName := 'STUN';
    ST_SLOW:   StatusName := 'SLOW';
    ST_BURN:   StatusName := 'BURN';
    ST_OFFBAL: StatusName := 'DAZED';
  else StatusName := '';
  end;
end;

procedure SetStatus(var s: TStatus; st, turns: longint);
begin
  case st of
    ST_POISON: if turns > s.poison then s.poison := turns;
    ST_STUN:   if turns > s.stun then s.stun := turns;
    ST_SLOW:   if turns > s.slow then s.slow := turns;
    ST_BURN:   if turns > s.burn then s.burn := turns;
    ST_OFFBAL: if turns > s.offbal then s.offbal := turns;
  end;
end;

{ Try to lay a status on a foe: blocked by immunity, resisted by a save. }
procedure AfflictFoe(fi, st, turns: longint);
begin
  if st = 0 then exit;
  if (MonDefs[Foes[fi].def].statusImm and st) <> 0 then exit;
  if SaveThrow(GameRng, 0, MonDefs[Foes[fi].def].hd, STATUS_DC) then exit;
  SetStatus(FoeStatus[fi], st, turns);
  CombatLog(MonDefs[Foes[fi].def].name + ' is ' + StatusName(st) + '.');
  PushPop(0, fi, POPC_MISS, StatusName(st));
end;

{ Try to lay a status on a party member; a Constitution save shrugs it. }
procedure AfflictMember(mi, st, turns: longint);
begin
  if st = 0 then exit;
  if SaveThrow(GameRng, AbilMod(Roster[mi].abil[abCON]), Roster[mi].level, STATUS_DC) then exit;
  SetStatus(PartyStatus[mi], st, turns);
  CombatLog(Roster[mi].name + ' is ' + StatusName(st) + '.');
  PushPop(1, mi, POPC_MISS, StatusName(st));
end;

{ ---- resolution primitives ---- }

procedure KillFoe(fi: longint);
begin
  Foes[fi].alive := false;
  XPGained := XPGained + MonDefs[Foes[fi].def].xp;
  CombatLog(MonDefs[Foes[fi].def].name + ' is destroyed.');
end;

{ Deal elemental damage to a foe, applying its weakness or resistance and
  colouring the floating number to match. }
procedure DamageFoe(fi, baseAmount, element: longint);
var
  mult: double;
  amount, color: longint;
begin
  if not Foes[fi].alive then exit;
  mult := ElementMult(element, fi);
  if mult <= 0 then begin
    CombatLog(MonDefs[Foes[fi].def].name + ' is unharmed.');
    PushPop(0, fi, POPC_MISS, 'NULL');
    FlashFoe(fi);
    exit;
  end;
  amount := round(baseAmount * mult);
  if amount < 1 then amount := 1;
  if mult > 1 then color := POPC_WEAK
  else if mult < 1 then color := POPC_RESIST
  else color := POPC_FOEDMG;
  Foes[fi].hp := Foes[fi].hp - amount;
  CombatLog(MonDefs[Foes[fi].def].name + ' takes ' + IntToStr(amount) + '.');
  PushPop(0, fi, color, IntToStr(amount));
  FlashFoe(fi);
  if Foes[fi].hp <= 0 then KillFoe(fi);
end;

procedure HurtMember(mi, dmg: longint);
var roll: longint;
begin
  Roster[mi].hp := Roster[mi].hp - dmg;
  if Roster[mi].hp <= 0 then begin
    Roster[mi].hp := 0;
    { Brush with Death: 1d6 + prior brushes; 7+ is slain. }
    inc(Roster[mi].brushes);
    roll := D(6) + (Roster[mi].brushes - 1);
    if roll >= 7 then begin
      Roster[mi].alive := false;
      Roster[mi].downed := true;
      CombatLog(Roster[mi].name + ' is slain!');
    end else begin
      Roster[mi].downed := true;
      CombatLog(Roster[mi].name + ' falls, gravely wounded.');
    end;
  end;
end;

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
  CheckEnd;
  if CombatOver then begin CombatPhase := CP_DONE; exit; end;
  inc(TurnPos);
  CombatPhase := CP_BEAT;
  CombatTimer := BEAT_TIME;
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
var i: longint;
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
    if not Foes[i].alive then begin StartOfTurnSpent := true; exit; end;
    if FoeStatus[i].stun > 0 then begin
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
      PushPop(1, i, POPC_PARTYDMG, IntToStr(BURN_DMG)); FlashAlly(i);
      HurtMember(i, BURN_DMG); dec(PartyStatus[i].burn);
    end;
    if PartyStatus[i].slow > 0 then dec(PartyStatus[i].slow);
    if PartyStatus[i].offbal > 0 then dec(PartyStatus[i].offbal);
    if (not Roster[i].alive) or Roster[i].downed then begin
      StartOfTurnSpent := true; exit;
    end;
    if PartyStatus[i].stun > 0 then begin
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
    CombatPhase := CP_INPUT;
  end else begin
    CombatPhase := CP_ENEMY;
    CombatTimer := ENEMY_STEP;
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
    CP_BEAT:  AdvanceTurn;
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

procedure StartRandomEncounter(depth: longint; tableNum: longint);
var
  pick, count, i, front, npool, e, mi, wrep: longint;
  pool: array of longint;
begin
  SetLength(Foes, 0);
  CombatOver := false;
  Victory := false;
  Fled := false;
  PartyBless := 0;
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

  { give casters a small pool of spell points for the fight }
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

  CombatLog('Foes close in: ' + IntToStr(count) + ' of them.');
  NewRound;
end;

{ ---- the foe side's AI ---- }

{ The most wounded member of a pool of party indices, random among ties. }
function MostWounded(const pool: array of longint; n: longint): longint;
var i, best: longint;
begin
  best := -1;
  for i := 0 to n - 1 do
    if (best < 0) or (Roster[pool[i]].hp < Roster[best].hp) then
      best := pool[i];
  MostWounded := best;
end;

{ Pick a target for foe fi. Ranged foes reach past the front line and go
  for the soft back rank; melee foes are held to the party front rank.
  Within the allowed set they press the most wounded. }
function EnemyPickTarget(fi: longint; ranged: boolean): longint;
var
  pool: array[0 .. 31] of longint;
  n, i, fr: longint;
begin
  EnemyPickTarget := -1;
  n := 0;
  if ranged then begin
    { prefer the back rank; fall back to anyone conscious }
    for i := 0 to High(Roster) do
      if Roster[i].alive and (not Roster[i].downed)
        and (Roster[i].rank = RANK_BACK) and (n <= High(pool)) then begin
        pool[n] := i; inc(n);
      end;
    if n = 0 then
      for i := 0 to High(Roster) do
        if Roster[i].alive and (not Roster[i].downed) and (n <= High(pool)) then begin
          pool[n] := i; inc(n);
        end;
  end else begin
    fr := FrontPartyRank;
    for i := 0 to High(Roster) do
      if Roster[i].alive and (not Roster[i].downed)
        and (Roster[i].rank = fr) and (n <= High(pool)) then begin
        pool[n] := i; inc(n);
      end;
  end;
  if n > 0 then EnemyPickTarget := MostWounded(pool, n);
end;

{ Is another living foe holding the front rank, so this one has cover? }
function FoeHasCover(exclude: longint): boolean;
var
  i: longint;
begin
  FoeHasCover := false;
  for i := 0 to High(Foes) do
    if (i <> exclude) and Foes[i].alive and (Foes[i].rank = RANK_FRONT) then
    begin
      FoeHasCover := true; exit;
    end;
end;

{ A foe may spend its turn repositioning. Melee brutes penned in the back
  surge forward to close the distance; ranged casters caught in the front
  line slip back behind the brutes when there is a front line to hide them.
  Returns true if the turn was spent moving. }
function EnemyMaybeMove(fi: longint; ranged: boolean): boolean;
begin
  EnemyMaybeMove := false;
  if ranged then begin
    if (Foes[fi].rank = RANK_FRONT) and FoeHasCover(fi) and (D(100) <= 70) then
    begin
      Foes[fi].rank := RANK_BACK;
      CombatLog(MonDefs[Foes[fi].def].name + ' slips to the back.');
      EnemyMaybeMove := true;
    end;
  end else begin
    if (Foes[fi].rank <> FrontFoeRank) and (D(100) <= 75) then
    begin
      Foes[fi].rank := RANK_FRONT;
      CombatLog(MonDefs[Foes[fi].def].name + ' surges to the front.');
      EnemyMaybeMove := true;
    end;
  end;
end;

{ A brute's ranged disruption: a taunt that throws a front-liner off
  balance, or a lobbed weapon that chips the back line and rattles it.
  Secondary to its melee, and the only reach it has while penned. }
function EnemyHarry(fi: longint): boolean;
var
  tgt, dmg: longint;
begin
  EnemyHarry := false;
  case MonDefs[Foes[fi].def].harry of
    HARRY_TAUNT:
      begin
        tgt := EnemyPickTarget(fi, false);     { a front-line attacker }
        if tgt < 0 then tgt := FirstConscious;
        if tgt < 0 then exit;
        CombatLog(MonDefs[Foes[fi].def].name + ' taunts ' + Roster[tgt].name + '.');
        AfflictMember(tgt, ST_OFFBAL, 2);
        EnemyHarry := true;
      end;
    HARRY_THROW:
      begin
        tgt := EnemyPickTarget(fi, true);      { lob at the soft back line }
        if tgt < 0 then exit;
        dmg := D(MonDefs[Foes[fi].def].dmgSides) div 2;
        if dmg < 1 then dmg := 1;
        CombatLog(MonDefs[Foes[fi].def].name + ' hurls a weapon at '
          + Roster[tgt].name + ' for ' + IntToStr(dmg) + '.');
        PushPop(1, tgt, POPC_PARTYDMG, IntToStr(dmg));
        FlashAlly(tgt);
        CombatSfxCue := CUE_HIT;
        HurtMember(tgt, dmg);
        if Roster[tgt].alive and (not Roster[tgt].downed) then
          AfflictMember(tgt, ST_OFFBAL, 2);    { a solid throw rattles them }
        EnemyHarry := true;
      end;
  end;
end;

{ A mage foe conjures a bolt at the party, reaching past the front line for
  the soft back row, and may leave the status its element implies. Spends SP. }
function EnemyCastBolt(fi: longint): boolean;
var
  tgt, dmg: longint;
begin
  EnemyCastBolt := false;
  if Foes[fi].sp < FOE_CAST_SP then exit;
  tgt := EnemyPickTarget(fi, true);       { ranged reach, prefers the back }
  if tgt < 0 then exit;
  dec(Foes[fi].sp, FOE_CAST_SP);
  dmg := RngRoll(GameRng, 1, 6) + MonDefs[Foes[fi].def].hd;
  if dmg < 1 then dmg := 1;
  CombatLog(MonDefs[Foes[fi].def].name + ' conjures a bolt at '
    + Roster[tgt].name + ' for ' + IntToStr(dmg) + '.');
  PushPop(1, tgt, POPC_PARTYDMG, IntToStr(dmg));
  FlashAlly(tgt);
  CombatSfxCue := CUE_HIT;
  HurtMember(tgt, dmg);
  if Roster[tgt].alive and (not Roster[tgt].downed)
     and (MonDefs[Foes[fi].def].inflict <> 0) then
    AfflictMember(tgt, MonDefs[Foes[fi].def].inflict, 3);
  EnemyCastBolt := true;
end;

{ A healer foe mends its most wounded living ally. Returns false (so the foe
  acts some other way) when no ally is hurt. Spends SP. }
function EnemyCastHeal(fi: longint): boolean;
var
  i, best, amt: longint;
begin
  EnemyCastHeal := false;
  if Foes[fi].sp < FOE_CAST_SP then exit;
  best := -1;
  for i := 0 to High(Foes) do
    if Foes[i].alive and (Foes[i].hp < Foes[i].hpMax) then
      if (best < 0) or (Foes[i].hp < Foes[best].hp) then best := i;
  if best < 0 then exit;                  { nobody needs it }
  dec(Foes[fi].sp, FOE_CAST_SP);
  amt := RngRoll(GameRng, 1, 8) + MonDefs[Foes[fi].def].hd;
  if amt < 1 then amt := 1;
  Foes[best].hp := Foes[best].hp + amt;
  if Foes[best].hp > Foes[best].hpMax then Foes[best].hp := Foes[best].hpMax;
  CombatLog(MonDefs[Foes[fi].def].name + ' mends '
    + MonDefs[Foes[best].def].name + ' (+' + IntToStr(amt) + ').');
  PushPop(0, best, POPC_HEAL, '+' + IntToStr(amt));
  FlashFoe(best);
  EnemyCastHeal := true;
end;

{ A healer foe raises a fallen ally, back on its feet at half health. The
  experience its fall granted is taken back, so a fresh kill still counts.
  Returns false when no ally lies dead. Spends SP. }
function EnemyCastRevive(fi: longint): boolean;
var
  i, best, amt: longint;
begin
  EnemyCastRevive := false;
  if Foes[fi].sp < FOE_REVIVE_SP then exit;
  best := -1;
  for i := 0 to High(Foes) do
    if not Foes[i].alive then begin best := i; break; end;
  if best < 0 then exit;                  { no one to raise }
  dec(Foes[fi].sp, FOE_REVIVE_SP);
  Foes[best].alive := true;
  amt := Foes[best].hpMax div 2;
  if amt < 1 then amt := 1;
  Foes[best].hp := amt;
  XPGained := XPGained - MonDefs[Foes[best].def].xp;
  if XPGained < 0 then XPGained := 0;
  FillChar(FoeStatus[best], SizeOf(TStatus), 0);
  CombatLog(MonDefs[Foes[fi].def].name + ' raises '
    + MonDefs[Foes[best].def].name + '.');
  PushPop(0, best, POPC_HEAL, 'RAISE');
  FlashFoe(best);
  EnemyCastRevive := true;
end;

{ Resolve the foe at the turn cursor: choose a target by role and swing,
  carrying the monster's element and any status its hit inflicts. }
procedure ResolveEnemyTurn;
var
  fi, tgt, roll, dmg, effAC: longint;
  ranged, hasHarry, isMage, isHealer: boolean;
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
  if (roll <> 1) and ((roll = 20) or
     (roll + MonDefs[Foes[fi].def].atkBonus >= effAC)) then
  begin
    dmg := D(MonDefs[Foes[fi].def].dmgSides);
    if dmg < 1 then dmg := 1;
    if Roster[tgt].guarding then dmg := dmg div 2;          { defend halves }
    if ranged and (Roster[tgt].rank = RANK_BACK) then dmg := dmg div 2;
    if dmg < 1 then dmg := 1;
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

procedure ResolvePartyAttack(actor, foe: longint);
var
  melee: boolean;
  roll, roll2, atk, dmg, die: longint;
begin
  melee := not WeaponRanged(Roster[actor]);
  if melee and (Roster[actor].rank <> RANK_FRONT) then begin
    CombatLog(Roster[actor].name + ' has no reach from the back rank.');
    exit;
  end;
  if melee and (Foes[foe].rank <> FrontFoeRank) then begin
    CombatLog(Roster[actor].name + ' cannot reach the back rank.');
    exit;
  end;
  die := CharWeaponDie(Roster[actor]);
  roll := D(20);
  if PartyStatus[actor].offbal > 0 then begin
    roll2 := D(20);                       { off balance: roll at disadvantage }
    if roll2 < roll then roll := roll2;
  end;
  atk := CharAttack(Roster[actor], melee) + PartyBless;
  if (roll <> 1) and ((roll = 20) or (roll + atk >= MonDefs[Foes[foe].def].ac)) then
  begin
    if roll = 20 then dmg := die
    else dmg := D(die);
    if melee then dmg := dmg + AbilMod(Roster[actor].abil[abSTR]);
    if dmg < 1 then dmg := 1;
    CombatLog(Roster[actor].name + ' hits ' + MonDefs[Foes[foe].def].name + '.');
    DamageFoe(foe, dmg, WeaponElement(Roster[actor]));
  end else begin
    CombatLog(Roster[actor].name + ' misses.');
    PushPop(0, foe, POPC_MISS, 'MISS');
  end;
end;

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
  EndTurn;
end;

procedure ActGuard;
begin
  if CombatOver or (CurActor < 0) or (CombatPhase <> CP_INPUT) then exit;
  Roster[CurActor].guarding := true;
  CombatLog(Roster[CurActor].name + ' braces to defend.');
  EndTurn;
end;

procedure ActMove;
begin
  if CombatOver or (CurActor < 0) or (CombatPhase <> CP_INPUT) then exit;
  { step between the front line and the back; this spends the turn }
  if Roster[CurActor].rank = RANK_FRONT then begin
    Roster[CurActor].rank := RANK_BACK;
    CombatLog(Roster[CurActor].name + ' falls back.');
  end else begin
    Roster[CurActor].rank := RANK_FRONT;
    CombatLog(Roster[CurActor].name + ' steps up to the front.');
  end;
  EndTurn;
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
  EndTurn;
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

const
  SpellTable: array[0 .. 6] of TSpell = (
    (id: 'BOLT';  name: 'Arc Bolt';    track: TRK_MAGE;   cost: 1;
     mode: TGT_ENEMY;      effect: EF_DAMAGE; dice: 2; sides: 6;
     element: EL_SHOCK; inflict: 0),
    (id: 'BLAST'; name: 'Fire Blast';  track: TRK_MAGE;   cost: 2;
     mode: TGT_ENEMY_RANK; effect: EF_DAMAGE; dice: 2; sides: 6;
     element: EL_FIRE; inflict: 0),
    (id: 'FROST'; name: 'Frost Shard';  track: TRK_MAGE;  cost: 1;
     mode: TGT_ENEMY;      effect: EF_DAMAGE; dice: 1; sides: 8;
     element: EL_FROST; inflict: ST_SLOW),
    (id: 'HEX';   name: 'Venom Hex';    track: TRK_MAGE;  cost: 1;
     mode: TGT_ENEMY;      effect: EF_DAMAGE; dice: 1; sides: 4;
     element: EL_PHYS; inflict: ST_POISON),
    (id: 'SMITE'; name: 'Smite';        track: TRK_PRIEST; cost: 2;
     mode: TGT_ENEMY;      effect: EF_DAMAGE; dice: 2; sides: 8;
     element: EL_HOLY; inflict: 0),
    (id: 'MEND';  name: 'Mend';         track: TRK_PRIEST; cost: 1;
     mode: TGT_ALLY;       effect: EF_HEAL;   dice: 2; sides: 8;
     element: 0; inflict: 0),
    (id: 'BLESS'; name: 'Bless';        track: TRK_PRIEST; cost: 2;
     mode: TGT_PARTY;      effect: EF_BLESS;  dice: 0; sides: 0;
     element: 0; inflict: 0)
  );

function SpellCount: longint;
begin
  SpellCount := Length(SpellTable);
end;

function SpellInfo(i: longint): TSpell;
begin
  SpellInfo := SpellTable[i];
end;

function ActorCanCast(actor, spellIdx: longint): boolean;
begin
  ActorCanCast := false;
  if (spellIdx < 0) or (spellIdx >= Length(SpellTable)) then exit;
  if (actor < 0) or (actor > High(Roster)) then exit;
  if not (Roster[actor].alive and (not Roster[actor].downed)) then exit;
  ActorCanCast := (CharTrack(Roster[actor]) = SpellTable[spellIdx].track)
    and (Roster[actor].sp >= SpellTable[spellIdx].cost);
end;

{ The spell ability modifier: wits for mages, wisdom for priests. }
function CasterMod(actor: longint): longint;
begin
  if CharTrack(Roster[actor]) = TRK_MAGE then
    CasterMod := AbilMod(Roster[actor].abil[abINT])
  else
    CasterMod := AbilMod(Roster[actor].abil[abWIS]);
end;

procedure ActCast(spellIdx, target: longint);
var
  sp: TSpell;
  amt, m, i, rk: longint;
begin
  if CombatOver or (CurActor < 0) or (CombatPhase <> CP_INPUT) then exit;
  if not ActorCanCast(CurActor, spellIdx) then begin
    CombatLog(Roster[CurActor].name + ' cannot cast that.');
    exit;
  end;
  sp := SpellTable[spellIdx];
  dec(Roster[CurActor].sp, sp.cost);
  m := CasterMod(CurActor);

  case sp.mode of
    TGT_ENEMY: begin
      if (target < 0) or (target > High(Foes)) or (not Foes[target].alive) then
        target := FirstLivingFoe;
      if target < 0 then begin EndTurn; exit; end;
      CombatLog(Roster[CurActor].name + ' casts ' + sp.name + '.');
      DamageFoe(target, RngRoll(GameRng, sp.dice, sp.sides) + m, sp.element);
      if Foes[target].alive and (sp.inflict <> 0) then
        AfflictFoe(target, sp.inflict, 3);
    end;
    TGT_ENEMY_RANK: begin
      if (target < 0) or (target > High(Foes)) or (not Foes[target].alive) then
        target := FirstLivingFoe;
      if target < 0 then begin EndTurn; exit; end;
      rk := Foes[target].rank;
      CombatLog(Roster[CurActor].name + ' casts ' + sp.name + '.');
      for i := 0 to High(Foes) do
        if Foes[i].alive and (Foes[i].rank = rk) then begin
          DamageFoe(i, RngRoll(GameRng, sp.dice, sp.sides) + m, sp.element);
          if Foes[i].alive and (sp.inflict <> 0) then
            AfflictFoe(i, sp.inflict, 3);
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

  EndTurn;
end;

end.
