unit combatstate;

{** The shared state of a fight: the data every combat unit reads and writes.

  This is the leaf of the combat units. It holds the party-versus-foe model,
  the turn-pacing and hit-feedback records, and the fight-long option and
  modifier globals, with no logic. combatcore (resolution and tactics),
  combatai (the foe side), and combat (the driver) all build on it. }

{$mode objfpc}{$H+}

interface

uses
  sprbank;

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

  { ---- turn pacing ---- }
  CP_INPUT = 0;   { a party member awaits the player's command }
  CP_BEAT  = 1;   { a short pause after an action resolves }
  CP_ENEMY = 2;   { a foe is acting on its own }
  CP_DONE  = 3;   { combat has ended }

  { ---- hit feedback ---- }
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

  DARK_ATK   = 3;      { to-hit penalty when the party fights in the dark }
  DARK_GLOW  = 128;    { torch strength below which a fight is "in the dark" }

type
  TSpell = record
    id: string[16];
    name: string[20];
    track: byte;        { unused: the domain now gates casting }
    cost: byte;         { spell points }
    mode: byte;         { TGT_* }
    effect: byte;       { EF_* }
    dice, sides: byte;  { for damage or healing }
    element: byte;      { EL_* of the damage it deals }
    inflict: byte;      { ST_* a damaging hit may apply, 0 = none }
    school: byte;       { spelldb SCH_*, for the specialist save edge }
    icon: byte;         { spelldb icon number, for the cast menu }
  end;

  TFoe = record
    def: longint;
    hp: smallint;
    hpMax: smallint;
    alive: boolean;
    rank: byte;              { 0 front, 1 back }
    sp: smallint;            { spell points, for caster and healer foes }
    spriteIdx: longint;      { cached sprite-store index; -2 unresolved }
    anim: TBankCursor;       { idle animation play head when the sprite is a bank }
  end;

  { status timers for one combatant, in turns remaining }
  TStatus = record
    poison, stun, slow, burn, offbal, fear, paralyze: smallint;
  end;

  TPop = record
    side: byte;        { 0 a foe, 1 a party member }
    idx: longint;      { index into Foes or Roster }
    text: string[7];
    color: byte;       { POPC_* }
    life: double;      { seconds remaining, counts down from POP_LIFE }
  end;

  TTurnEnt = record
    side: byte;        { 0 a foe, 1 a party member }
    idx: longint;      { index into Foes or Roster }
  end;

  { The whole state of one fight. Today a single instance is resident, reached
    through Active^; the design (section 24) grows this into many concurrent,
    map-located battles, so every site reads the fight through the pointer. }
  TCombat = record
    Live: boolean;             { this slot holds a fight in progress }
    Map: string[16];           { the map cell this fight is located at }
    CellX, CellY: longint;
    Foes: array of TFoe;
    CombatOver: boolean;
    Victory: boolean;
    Fled: boolean;
    CurActor: longint;         { party member awaiting input, or -1 }
    CurTarget: longint;        { selected foe index }
    Log: array[0 .. LOG_LINES - 1] of string;
    XPGained: longint;
    GoldGained: longint;

    CombatPhase: longint;

    TurnQueue: array of TTurnEnt;  { this round's actors, fastest first }
    TurnPos: longint;              { cursor into TurnQueue }
    TurnContinue: boolean;         { the actor keeps its turn for the other slot }
    CombatTimer: double;           { seconds left in the current beat }
    FoesAtStart: longint;          { for the morale threshold }

    TurnMoved: boolean;   { the current actor has spent its move this turn }
    TurnActed: boolean;   { the current actor has spent its action this turn }

    Pops: array of TPop;       { active floating numbers }
    FoeFlash: array of double; { per-foe flash timer }
    PartyFlash: array of double;
    CombatSfxCue: longint;     { a sound the game should play this frame }
    FoeStatus: array of TStatus;   { status timers, per foe }
    PartyStatus: array of TStatus; { status timers, per party member }

    PartyBless: longint;      { a fight-long +hit from a blessing, 0 normally }
    PartyDark: longint;       { a fight-long to-hit penalty for fighting in the
                               dark, set from the torch when the fight begins }
    SkillUse: array of array of longint;  { combat-maneuver uses spent this
                               fight, indexed [party member][skill index] }
  end;
  PCombat = ^TCombat;

const
  MAX_COMBATS = 8;          { concurrent fights; single-player uses slot 0 }

var
  { The fight table, addressed by map cell. A fixed array keeps every slot's
    address stable, so Active (a pointer into it) never dangles across a claim
    and there is no heap churn. Single-player keeps one Live slot at a time. }
  gCombats: array[0 .. MAX_COMBATS - 1] of TCombat;
  Active: PCombat = @gCombats[0];   { every site reaches fight state through Active^ }

  OptCriticals: boolean;    { natural 20 auto-hits for max damage, 1 fumbles }
  OptPrepared: boolean;     { casters must ready a per-level subset of known spells }
  CombatBeatScale: double;  { scales the pause between beats, from the options }

{ The fight slot at table index i (0 .. MAX_COMBATS-1), or nil out of range.
  For iterating the table, e.g. a driver that ticks every live fight. }
function CombatSlot(i: longint): PCombat;

{ The live fight located at a map cell, or nil when none. One fight per cell. }
function CombatAt(const map: string; x, y: longint): PCombat;

{ Claim (or reuse) the fight slot for a cell and make it Active. One-per-cell:
  an existing fight at the cell is returned as-is; otherwise a free slot is
  taken and keyed. The caller fills the fight next (BuildEncounter). }
function BeginCombatAt(const map: string; x, y: longint): PCombat;

{ Repoint Active at a fight instance (the later scheduler's per-cell switch). }
procedure SetActiveCombat(c: PCombat);

{ Free a fight's slot once its post-combat reads are done, and return Active to
  the resident default so between-fights reads stay valid. }
procedure EndCombatInstance(c: PCombat);

implementation

function CombatSlot(i: longint): PCombat;
begin
  if (i >= 0) and (i < MAX_COMBATS) then CombatSlot := @gCombats[i]
  else CombatSlot := nil;
end;

function CombatAt(const map: string; x, y: longint): PCombat;
var i: longint;
begin
  CombatAt := nil;
  for i := 0 to MAX_COMBATS - 1 do
    if gCombats[i].Live and (gCombats[i].CellX = x) and (gCombats[i].CellY = y)
      and (gCombats[i].Map = map) then begin
      CombatAt := @gCombats[i];
      exit;
    end;
end;

function BeginCombatAt(const map: string; x, y: longint): PCombat;
var i: longint;
begin
  BeginCombatAt := CombatAt(map, x, y);
  if BeginCombatAt <> nil then begin
    Active := BeginCombatAt;
    exit;
  end;
  { claim the first free slot; a full table cannot happen in single-player, so
    fall back to slot 0 rather than fail a fight }
  BeginCombatAt := @gCombats[0];
  for i := 0 to MAX_COMBATS - 1 do
    if not gCombats[i].Live then begin
      BeginCombatAt := @gCombats[i];
      break;
    end;
  BeginCombatAt^.Live := true;
  BeginCombatAt^.Map := map;
  BeginCombatAt^.CellX := x;
  BeginCombatAt^.CellY := y;
  Active := BeginCombatAt;
end;

procedure SetActiveCombat(c: PCombat);
begin
  if c <> nil then Active := c;
end;

procedure EndCombatInstance(c: PCombat);
begin
  if c <> nil then c^.Live := false;
  Active := @gCombats[0];
end;

initialization
  OptCriticals := true;
  OptPrepared := false;
  CombatBeatScale := 1.0;
end.
