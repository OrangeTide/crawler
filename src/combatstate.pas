unit combatstate;

{** The shared state of a fight: the data every combat unit reads and writes.

  This is the leaf of the combat units. It holds the party-versus-foe model,
  the turn-pacing and hit-feedback records, and the fight-long option and
  modifier globals, with no logic. combatcore (resolution and tactics),
  combatai (the foe side), and combat (the driver) all build on it. }

{$mode objfpc}{$H+}

interface

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

  CombatPhase: longint;

  TurnMoved: boolean;   { the current party actor has spent its move this turn }
  TurnActed: boolean;   { the current party actor has spent its action this turn }

  Pops: array of TPop;       { active floating numbers }
  FoeFlash: array of double; { per-foe flash timer }
  PartyFlash: array of double;
  CombatSfxCue: longint;     { a sound the game should play this frame }
  FoeStatus: array of TStatus;   { status timers, per foe }
  PartyStatus: array of TStatus; { status timers, per party member }

  PartyBless: longint;      { a fight-long +hit from a blessing, 0 normally }
  PartyDark: longint;       { a fight-long to-hit penalty for fighting in the
                             dark, set from the torch when the fight begins }
  OptCriticals: boolean;    { natural 20 auto-hits for max damage, 1 fumbles }
  CombatBeatScale: double;  { scales the pause between beats, from the options }

implementation

initialization
  OptCriticals := true;
  CombatBeatScale := 1.0;
end.
