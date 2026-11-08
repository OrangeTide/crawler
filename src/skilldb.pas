unit skilldb;

{** Skill catalog.

  A skill is an active or passive non-spell ability a character trains by
  spending proficiency slots. Exploration skills (pick locks, find traps, move
  silently, first aid) resolve against the world; combat skills (power attack,
  disarm, shield bash, aimed shot, rally) are maneuvers in a fight. Skills are
  authored as text, compiled into a SKIL lump and decoded here, the same way
  spells are, so the asset tool and the runtime agree on the layout.

  A skill keys a fixed engine effect (SKE_*); the content tunes the numbers (the
  check difficulty, the effect dice, the per-encounter uses). The check itself
  is rolled with rules.Check against ability + level + rank.

  SKIL layout:
    magic 'SKIL' u32, skillCount u16
    skill: id[16], name(str), arena u8, effect u8, ability u8, target u8,
           gate u8, uses u8, dice u8, sides u8, icon u8, effectText(str) }

{$mode objfpc}{$H+}

interface

uses
  pak;

const
  SKIL_MAGIC = $4C494B53;  { 'SKIL' }

  { where a skill acts }
  SKA_EXPLORE = 0;   { resolves in the world, out of combat }
  SKA_COMBAT  = 1;   { a maneuver chosen from the combat menu }

  { the engine behaviour a skill keys. Content maps a skill id to one of these;
    the arena says which menu it appears in. }
  SKE_NONE       = 0;
  SKE_PICKLOCK   = 1;   { explore: open a locked door }
  SKE_FINDTRAPS  = 2;   { explore: detect and disarm a trap before it springs }
  SKE_MOVESILENT = 3;   { explore: passive, slip past a wandering encounter }
  SKE_MEND       = 4;   { explore: non-magical first aid, heals one member }
  SKE_POWERATTACK = 5;  { combat: a heavier swing, more damage, less accuracy }
  SKE_DISARM     = 6;   { combat: an attack that leaves a foe off balance }
  SKE_BASH       = 7;   { combat: a shield slam that stuns (needs a shield) }
  SKE_AIMEDSHOT  = 8;   { combat: a careful ranged shot (needs a bow) }
  SKE_RALLY      = 9;   { combat: steady the party, clearing fear }

  { who may learn a skill }
  SKG_ANY     = 0;   { any class }
  SKG_THIEF   = 1;   { the thief kit only }
  SKG_MARTIAL = 2;   { the warrior and specialist tracks }

  SKILL_MAXRANK = 4;   { a skill cannot be trained past this rank }

type
  TSkillDef = record
    id: string[16];
    name: string[24];
    arena: byte;       { SKA_* }
    effect: byte;      { SKE_* }
    ability: byte;     { ability ordinal 0..5 the check rolls }
    target: byte;      { base d20 difficulty at rank 0 }
    gate: byte;        { SKG_*, who may learn it }
    maxUses: byte;     { combat uses per encounter, 0 = at-will }
    dice, sides: byte; { effect magnitude }
    icon: byte;        { skill icon number, 0 = none }
    effectText: string;{ prose for the learn screen and the sheet }
  end;

var
  SkillDefs: array of TSkillDef;

function EncodeSkills(const ss: array of TSkillDef): TByteArray;
function LoadSkills(const p: TPak): boolean;

function SkillDefCount: longint;
function SkillByID(const id: string): longint;   { index, or -1 }
function ArenaName(a: byte): string;
function GateName(g: byte): string;

implementation

{ ---- encode (used by the tool) ---- }

procedure PutB(var a: TByteArray; var n: longint; v: byte);
begin
  if n >= Length(a) then SetLength(a, (n + 1) * 2);
  a[n] := v; inc(n);
end;

procedure PutU16(var a: TByteArray; var n: longint; v: word);
begin
  PutB(a, n, v and $FF); PutB(a, n, (v shr 8) and $FF);
end;

procedure PutStr(var a: TByteArray; var n: longint; const s: string);
var i: longint;
begin
  PutU16(a, n, Length(s));
  for i := 1 to Length(s) do PutB(a, n, ord(s[i]));
end;

procedure PutFixed(var a: TByteArray; var n: longint; const s: string; len: longint);
var i: longint;
begin
  for i := 1 to len do
    if i <= Length(s) then PutB(a, n, ord(s[i])) else PutB(a, n, 0);
end;

function EncodeSkills(const ss: array of TSkillDef): TByteArray;
var
  a: TByteArray;
  n, si: longint;
begin
  SetLength(a, 0); n := 0;
  PutU16(a, n, SKIL_MAGIC and $FFFF);
  PutU16(a, n, (SKIL_MAGIC shr 16) and $FFFF);
  PutU16(a, n, Length(ss));
  for si := 0 to High(ss) do begin
    PutFixed(a, n, ss[si].id, 16);
    PutStr(a, n, ss[si].name);
    PutB(a, n, ss[si].arena);
    PutB(a, n, ss[si].effect);
    PutB(a, n, ss[si].ability);
    PutB(a, n, ss[si].target);
    PutB(a, n, ss[si].gate);
    PutB(a, n, ss[si].maxUses);
    PutB(a, n, ss[si].dice);
    PutB(a, n, ss[si].sides);
    PutB(a, n, ss[si].icon);
    PutStr(a, n, ss[si].effectText);
  end;
  SetLength(a, n);
  EncodeSkills := a;
end;

{ ---- decode ---- }

var
  rp: longint;
  rd: TByteArray;

function RB: byte;
begin
  if rp < Length(rd) then begin RB := rd[rp]; inc(rp); end else RB := 0;
end;

function RU16: word;
var lo, hi: byte;
begin lo := RB; hi := RB; RU16 := lo or (hi shl 8); end;

function RStr: string;
var len, i: longint; s: string;
begin
  len := RU16; s := '';
  for i := 1 to len do s := s + chr(RB);
  RStr := s;
end;

function RFixed(len: longint): string;
var i: longint; s: string; b: byte;
begin
  s := '';
  for i := 1 to len do begin b := RB; if b <> 0 then s := s + chr(b); end;
  RFixed := s;
end;

function LoadSkills(const p: TPak): boolean;
var
  count, si: longint;
  magicLo, magicHi: word;
begin
  LoadSkills := false;
  SkillDefs := nil;
  if not PakGet(p, 'SKIL', rd) then exit;
  rp := 0;
  magicLo := RU16; magicHi := RU16;
  if (magicLo or (magicHi shl 16)) <> SKIL_MAGIC then exit;
  count := RU16;
  SetLength(SkillDefs, count);
  for si := 0 to count - 1 do begin
    SkillDefs[si].id := RFixed(16);
    SkillDefs[si].name := RStr;
    SkillDefs[si].arena := RB;
    SkillDefs[si].effect := RB;
    SkillDefs[si].ability := RB;
    SkillDefs[si].target := RB;
    SkillDefs[si].gate := RB;
    SkillDefs[si].maxUses := RB;
    SkillDefs[si].dice := RB;
    SkillDefs[si].sides := RB;
    SkillDefs[si].icon := RB;
    SkillDefs[si].effectText := RStr;
  end;
  LoadSkills := true;
end;

{ ---- queries ---- }

function SkillDefCount: longint;
begin
  SkillDefCount := Length(SkillDefs);
end;

function SkillByID(const id: string): longint;
var i: longint;
begin
  SkillByID := -1;
  for i := 0 to High(SkillDefs) do
    if SkillDefs[i].id = id then begin SkillByID := i; exit; end;
end;

function ArenaName(a: byte): string;
begin
  if a = SKA_COMBAT then ArenaName := 'combat' else ArenaName := 'field';
end;

function GateName(g: byte): string;
begin
  case g of
    SKG_THIEF:   GateName := 'thief';
    SKG_MARTIAL: GateName := 'martial';
  else
    GateName := 'any';
  end;
end;

end.
