unit combat;

{** Turn-based combat on AX&X rules, party versus a monster group.

  Combat uses range bands (engaged, near, far) rather than a battle
  grid, which suits the first-person view. Side initiative is 1d6 per
  side each round. A round runs the party side then the foe side (or the
  reverse when the foes win initiative). The party acts one member at a
  time under player control; the foe side is resolved automatically.

  The game drives this: it reads ActorReady to know whose input is
  wanted, calls an action procedure, and checks CombatOver. }

{$mode objfpc}{$H+}

interface

uses
  sysutils, rng, rules, items, monsters, party, chardata;

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
  end;

type
  TFoe = record
    def: longint;
    hp: smallint;
    hpMax: smallint;
    alive: boolean;
    rank: byte;              { 0 front, 1 back }
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

{ Start a fight at a dungeon depth. areaMask limits the roster to the
  monsters that roam that area; 0 draws from every monster. }
procedure StartRandomEncounter(depth: longint; areaMask: byte);
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
procedure ActFlee;
procedure ActPotion;
procedure NextTarget;

{ ---- turn pacing ---- }
const
  CP_INPUT = 0;   { a party member awaits the player's command }
  CP_BEAT  = 1;   { a short pause after an action resolves }
  CP_ENEMY = 2;   { the foe side is acting, one at a time }
  CP_DONE  = 3;   { combat has ended }

var
  CombatPhase: longint;

{ Advance the combat clock; the game calls this each frame while fighting.
  It paces the pause after an action and the foe side's turn. }
procedure CombatUpdate(dt: double);

{ True while combat resolves on its own (a beat or the foe turn), so the
  game ignores input until the next party member is ready. }
function CombatBusy: boolean;

{ For headless tests: run the clock until a member is ready or the fight
  ends, instead of ticking real frames. }
procedure CombatSettle;

{ ---- abilities ---- }
function SpellCount: longint;
function SpellInfo(i: longint): TSpell;
function ActorCanCast(actor, spellIdx: longint): boolean;
{ Cast spellIdx from the current actor. target is a foe index for enemy
  modes, an ally index for TGT_ALLY, and ignored for TGT_PARTY. }
procedure ActCast(spellIdx, target: longint);

var
  PartyBless: longint;      { a fight-long +hit from a blessing, 0 normally }

implementation

var
  enemyActed: boolean;     { has the foe side swung this round }
  enemyThenParty: boolean; { foes won initiative, so the party follows them }
  enemyIdx: longint;       { scan cursor through the foes this phase }
  CombatTimer: double;     { seconds left in the current beat }

{ ---- logging ---- }

procedure CombatLog(const s: string);
var
  i: longint;
begin
  for i := 0 to LOG_LINES - 2 do
    Log[i] := Log[i + 1];
  Log[LOG_LINES - 1] := s;
end;

{ ---- helpers ---- }

function LivingFoes: longint;
var
  i, n: longint;
begin
  n := 0;
  for i := 0 to High(Foes) do
    if Foes[i].alive then inc(n);
  LivingFoes := n;
end;

function FirstLivingFoe: longint;
var
  i: longint;
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

function WeaponRanged(const c: TCharacter): boolean; forward;

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

function NextLivingActor(from: longint): longint;
var
  i: longint;
begin
  NextLivingActor := -1;
  for i := from to High(Roster) do
    if Roster[i].alive and (not Roster[i].downed) then begin
      NextLivingActor := i;
      exit;
    end;
end;

const
  BEAT_TIME  = 0.45;   { pause after an action before the next step }
  ENEMY_STEP = 0.55;   { pause between one foe's swing and the next }

procedure CheckEnd; forward;
procedure NewRound; forward;
procedure StartPartyTurn; forward;
procedure BeginEnemyPhase(thenParty: boolean); forward;
function StepEnemyPhase: boolean; forward;
procedure MoraleCheck; forward;

{ End the acting member's turn: resolve any ending, then hold a beat so
  the result reads before the next step. }
procedure EndPartyAction;
begin
  CheckEnd;
  if CombatOver then begin CombatPhase := CP_DONE; exit; end;
  CombatPhase := CP_BEAT;
  CombatTimer := BEAT_TIME;
end;

{ After the beat: move to the next conscious member, or hand to the foe
  side (or open the next round if the foes already swung this round). }
procedure AdvanceAfterPartyAction;
var
  nxt: longint;
begin
  nxt := NextLivingActor(CurActor + 1);
  if nxt >= 0 then begin
    CurActor := nxt;
    Roster[CurActor].guarding := false;
    CombatPhase := CP_INPUT;
    exit;
  end;
  if enemyActed then NewRound        { foes already swung this round }
  else BeginEnemyPhase(false);       { party went first, foes now }
end;

procedure StartPartyTurn;
begin
  CurActor := FirstConscious;
  if CurActor >= 0 then begin
    Roster[CurActor].guarding := false;
    CombatPhase := CP_INPUT;
  end else begin
    CheckEnd;
    if not CombatOver then NewRound else CombatPhase := CP_DONE;
  end;
end;

procedure BeginEnemyPhase(thenParty: boolean);
begin
  enemyThenParty := thenParty;
  enemyIdx := 0;
  CombatPhase := CP_ENEMY;
  CombatTimer := BEAT_TIME;
end;

{ Called once the foe side is spent: morale, end check, then control back
  to the party or on to the next round. }
procedure EndEnemyPhase;
begin
  if (LivingFoes > 0) and (LivingFoes <= Length(Foes) div 2) then MoraleCheck;
  enemyActed := true;
  CheckEnd;
  if CombatOver then begin CombatPhase := CP_DONE; exit; end;
  if enemyThenParty then StartPartyTurn   { foes went first; party acts now }
  else NewRound;                          { foes went last; round over }
end;

function CombatBusy: boolean;
begin
  CombatBusy := (not CombatOver) and (CombatPhase <> CP_INPUT);
end;

procedure CombatUpdate(dt: double);
begin
  if CombatOver then begin CombatPhase := CP_DONE; exit; end;
  if CombatTimer > 0 then begin
    CombatTimer := CombatTimer - dt;
    if CombatTimer > 0 then exit;
    CombatTimer := 0;
  end;
  case CombatPhase of
    CP_BEAT: AdvanceAfterPartyAction;
    CP_ENEMY:
      if StepEnemyPhase then CombatTimer := ENEMY_STEP
      else EndEnemyPhase;
  end;
end;

procedure CombatSettle;
var
  guard: longint;
begin
  guard := 0;
  while CombatBusy and (guard < 100000) do begin
    CombatUpdate(1.0);
    inc(guard);
  end;
end;

{ ---- setup ---- }

procedure StartRandomEncounter(depth: longint; areaMask: byte);
var
  pick, count, i, front, npool: longint;
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

  { the encounter table for this area: monsters whose range covers it.
    An unset mask, or an area no monster covers, falls back to the lot. }
  SetLength(pool, Length(MonDefs));
  npool := 0;
  if areaMask <> 0 then
    for i := 0 to High(MonDefs) do
      if (MonDefs[i].areas and areaMask) <> 0 then begin
        pool[npool] := i; inc(npool);
      end;
  if npool = 0 then begin
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
  end;
  if front = 0 then Foes[0].rank := RANK_FRONT;   { someone must be reachable }

  { give casters a small pool of spell points for the fight }
  for i := 0 to High(Roster) do
    Roster[i].sp := CharSpellPoints(Roster[i]);

  CombatLog('Foes close in: ' + IntToStr(count) + ' of them.');
  NewRound;
end;

procedure NewRound;
var
  pInit, fInit: longint;
begin
  enemyActed := false;
  pInit := D(6);
  fInit := D(6);
  CurTarget := FirstLivingFoe;
  if fInit > pInit then BeginEnemyPhase(true)   { foes win initiative }
  else StartPartyTurn;
end;

{ ---- resolution ---- }

procedure HurtMember(mi, dmg: longint);
var
  roll: longint;
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

procedure KillFoe(fi: longint);
begin
  Foes[fi].alive := false;
  XPGained := XPGained + MonDefs[Foes[fi].def].xp;
  CombatLog(MonDefs[Foes[fi].def].name + ' is destroyed.');
end;

function WeaponRanged(const c: TCharacter): boolean;
begin
  WeaponRanged := (c.equip[eqMain].def >= 0) and
    ((ItemDefs[c.equip[eqMain].def].flags and IF_RANGED) <> 0);
end;

procedure ResolvePartyAttack(actor, foe: longint);
var
  melee: boolean;
  roll, atk, dmg, die: longint;
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
  atk := CharAttack(Roster[actor], melee) + PartyBless;
  if (roll <> 1) and ((roll = 20) or (roll + atk >= MonDefs[Foes[foe].def].ac)) then
  begin
    if roll = 20 then
      dmg := die
    else
      dmg := D(die);
    if melee then dmg := dmg + AbilMod(Roster[actor].abil[abSTR]);
    if dmg < 1 then dmg := 1;
    Foes[foe].hp := Foes[foe].hp - dmg;
    CombatLog(Roster[actor].name + ' hits ' + MonDefs[Foes[foe].def].name
      + ' for ' + IntToStr(dmg) + '.');
    if Foes[foe].hp <= 0 then
      KillFoe(foe);
  end else
    CombatLog(Roster[actor].name + ' misses.');
end;

procedure MoraleCheck;
var
  i, best: longint;
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

{ A random conscious member the enemy may strike: melee foes are held to
  the party front rank, ranged foes may hit anyone. }
function PickPartyTarget(anyRank: boolean): longint;
var
  pool: array[0 .. 31] of longint;
  n, i, fr: longint;
begin
  PickPartyTarget := -1;
  n := 0; fr := FrontPartyRank;
  for i := 0 to High(Roster) do
    if Roster[i].alive and (not Roster[i].downed) and (Roster[i].hp > 0)
      and (anyRank or (Roster[i].rank = fr)) and (n <= High(pool)) then begin
      pool[n] := i; inc(n);
    end;
  if n > 0 then PickPartyTarget := pool[Range(0, n - 1)];
end;

{ Resolve the next foe that can act, advancing the scan cursor. Returns
  true when one acted (so the caller paces a beat), false when the foe
  side is spent. A back-rank melee foe is skipped without burning a beat. }
function StepEnemyPhase: boolean;
var
  i, tgt, roll, dmg, effAC: longint;
  ranged: boolean;
begin
  StepEnemyPhase := false;
  while enemyIdx <= High(Foes) do begin
    i := enemyIdx;
    inc(enemyIdx);
    if not Foes[i].alive then continue;
    if FirstConscious < 0 then exit;      { nobody left to strike }
    ranged := (MonDefs[Foes[i].def].flags and MF_RANGED) <> 0;
    { a back-rank melee foe cannot reach until the front rank falls }
    if (not ranged) and (Foes[i].rank <> FrontFoeRank) then continue;
    tgt := PickPartyTarget(ranged);
    if tgt < 0 then exit;
    roll := D(20);
    effAC := CharAC(Roster[tgt]);
    if Roster[tgt].guarding then effAC := effAC + 2;   { parry }
    if (roll <> 1) and ((roll = 20) or
       (roll + MonDefs[Foes[i].def].atkBonus >= effAC)) then
    begin
      dmg := D(MonDefs[Foes[i].def].dmgSides);
      if dmg < 1 then dmg := 1;
      CombatLog(MonDefs[Foes[i].def].name + ' hits ' + Roster[tgt].name
        + ' for ' + IntToStr(dmg) + '.');
      HurtMember(tgt, dmg);
      { a lycanthrope's wound can pass on the curse, on a failed save }
      if ((MonDefs[Foes[i].def].flags and MF_LYCAN) <> 0)
        and Roster[tgt].alive and (not Roster[tgt].lycan)
        and (not SaveThrow(GameRng, AbilMod(Roster[tgt].abil[abCON]),
                           Roster[tgt].level, 13)) then
      begin
        Roster[tgt].lycan := true;
        CombatLog(Roster[tgt].name + ' is marked by the curse!');
      end;
    end else
      CombatLog(MonDefs[Foes[i].def].name + ' misses ' + Roster[tgt].name + '.');
    StepEnemyPhase := true;
    exit;
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

{ ---- player actions ---- }

{ First foe the actor can actually strike, or -1. }
function FirstReachable(actor: longint): longint;
var i: longint;
begin
  FirstReachable := -1;
  for i := 0 to High(Foes) do
    if FoeReachable(actor, i) then begin FirstReachable := i; exit; end;
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
  EndPartyAction;
end;

procedure ActGuard;
begin
  if CombatOver or (CurActor < 0) or (CombatPhase <> CP_INPUT) then exit;
  Roster[CurActor].guarding := true;
  CombatLog(Roster[CurActor].name + ' takes a guarded stance.');
  EndPartyAction;
end;

procedure ActFlee;
begin
  if CombatOver or (CurActor < 0) or (CombatPhase <> CP_INPUT) then exit;
  { a scramble to break off: succeeds on better than a coin toss, else the
    turn is lost and the enemy gets their swing }
  if D(6) >= 3 then begin
    CombatOver := true;
    Victory := false;
    Fled := true;
    CombatPhase := CP_DONE;
    CombatLog('The party breaks off and flees.');
  end else begin
    CombatLog(Roster[CurActor].name + ' fails to break away.');
    EndPartyAction;
  end;
end;

procedure ActPotion;
var
  i, heal: longint;
  pidx: longint;
begin
  if CombatOver or (CurActor < 0) or (CombatPhase <> CP_INPUT) then exit;
  pidx := ItemIndex('POTION');
  for i := 0 to High(Roster[CurActor].pack) do
    if (Roster[CurActor].pack[i].def = pidx) and (Roster[CurActor].pack[i].qty > 0) then
    begin
      dec(Roster[CurActor].pack[i].qty);
      heal := RngRoll(GameRng, 1, 8) + 2;
      Roster[CurActor].hp := Roster[CurActor].hp + heal;
      if Roster[CurActor].hp > Roster[CurActor].hpMax then
        Roster[CurActor].hp := Roster[CurActor].hpMax;
      CombatLog(Roster[CurActor].name + ' drinks a potion (+'
        + IntToStr(heal) + ').');
      EndPartyAction;
      exit;
    end;
  CombatLog('No potion to drink.');
end;

{ ---- abilities ---- }

const
  SpellTable: array[0 .. 3] of TSpell = (
    (id: 'BOLT';  name: 'Arc Bolt'; track: TRK_MAGE;   cost: 1;
     mode: TGT_ENEMY;      effect: EF_DAMAGE; dice: 2; sides: 6),
    (id: 'BLAST'; name: 'Blast';    track: TRK_MAGE;   cost: 2;
     mode: TGT_ENEMY_RANK; effect: EF_DAMAGE; dice: 2; sides: 6),
    (id: 'MEND';  name: 'Mend';     track: TRK_PRIEST; cost: 1;
     mode: TGT_ALLY;       effect: EF_HEAL;   dice: 2; sides: 8),
    (id: 'BLESS'; name: 'Bless';    track: TRK_PRIEST; cost: 2;
     mode: TGT_PARTY;      effect: EF_BLESS;  dice: 0; sides: 0)
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

procedure DamageFoe(fi, amount: longint);
begin
  if amount < 1 then amount := 1;
  Foes[fi].hp := Foes[fi].hp - amount;
  CombatLog(MonDefs[Foes[fi].def].name + ' takes ' + IntToStr(amount) + '.');
  if Foes[fi].hp <= 0 then KillFoe(fi);
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
      if target < 0 then begin EndPartyAction; exit; end;
      CombatLog(Roster[CurActor].name + ' casts ' + sp.name + '.');
      DamageFoe(target, RngRoll(GameRng, sp.dice, sp.sides) + m);
    end;
    TGT_ENEMY_RANK: begin
      if (target < 0) or (target > High(Foes)) or (not Foes[target].alive) then
        target := FirstLivingFoe;
      if target < 0 then begin EndPartyAction; exit; end;
      rk := Foes[target].rank;
      CombatLog(Roster[CurActor].name + ' casts ' + sp.name + '.');
      for i := 0 to High(Foes) do
        if Foes[i].alive and (Foes[i].rank = rk) then
          DamageFoe(i, RngRoll(GameRng, sp.dice, sp.sides) + m);
    end;
    TGT_ALLY: begin
      if (target < 0) or (target > High(Roster)) or (not Roster[target].alive) then
        target := CurActor;
      amt := RngRoll(GameRng, sp.dice, sp.sides) + m;
      if amt < 1 then amt := 1;
      if Roster[target].downed and Roster[target].alive then
        Roster[target].downed := false;    { a mend brings them back to their feet }
      Roster[target].hp := Roster[target].hp + amt;
      if Roster[target].hp > Roster[target].hpMax then
        Roster[target].hp := Roster[target].hpMax;
      CombatLog(Roster[CurActor].name + ' mends ' + Roster[target].name
        + ' (+' + IntToStr(amt) + ').');
    end;
    TGT_PARTY: begin
      PartyBless := 1;
      CombatLog(Roster[CurActor].name + ' blesses the party.');
    end;
  end;

  EndPartyAction;
end;

procedure NextTarget;
var
  start, i: longint;
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

end.
