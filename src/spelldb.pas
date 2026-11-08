unit spelldb;

{** Spell catalog, imported from the axx-rpg lists.

  A spell carries its domain, level, saving throw, source damage type, the
  effect prose that is the real behaviour, and optional material components.
  Spells are authored as text, compiled into a SPEL lump and decoded here.
  The record type, the encoder (used by the asset tool) and the decoder live
  together so the tool and the runtime agree.

  The damage type is kept faithful to the source; SpellElement maps it onto the
  engine's five elements thematically (acid, force and poison fall back to
  physical) for any combat that later wires a spell up.

  SPEL layout:
    magic 'SPEL' u32, spellCount u16
    spell: id[16], name(str), domain u8, level u8, save u8, dtype u8,
           effect(str), components(str) }

{$mode objfpc}{$H+}

interface

uses
  pak, monsters;

const
  SPEL_MAGIC = $4C455053;  { 'SPEL' }

  { domains }
  SPD_CLERIC = 0;
  SPD_DRUID  = 1;
  SPD_MAGE   = 2;
  SPD_NONE   = 255;  { a class that draws from no domain }

  { saving throws }
  SSV_NONE  = 0;
  SSV_BODY  = 1;
  SSV_DODGE = 2;
  SSV_WILL  = 3;

  { arcane schools: only Magic-User spells carry one, the rest stay SCH_NONE.
    The order is fixed; the codec and the parser depend on it. }
  SCH_ABJUR   = 0;   { abjuration: protection and warding }
  SCH_CONJ    = 1;   { conjuration and summoning }
  SCH_DIVIN   = 2;   { divination: knowledge and foresight }
  SCH_ENCHANT = 3;   { enchantment and charm: minds }
  SCH_EVOKE   = 4;   { evocation and invocation: raw energy }
  SCH_ILLUS   = 5;   { illusion and phantasm: deception }
  SCH_NECRO   = 6;   { necromancy: life force and undeath }
  SCH_TRANS   = 7;   { transmutation (AD&D Alteration): change }
  SCH_NONE    = 255; { not an arcane school spell }

  { source damage types (faithful to axx-rpg) }
  SDT_NONE      = 0;
  SDT_ACID      = 1;
  SDT_COLD      = 2;
  SDT_FIRE      = 3;
  SDT_FORCE     = 4;
  SDT_LIGHTNING = 5;
  SDT_POISON    = 6;

  { combat target modes, kept equal to combatstate TGT_* }
  SCM_ENEMY = 0;
  SCM_RANK  = 1;
  SCM_ALLY  = 2;
  SCM_PARTY = 3;

  { combat effects, kept equal to combatstate EF_* }
  SCE_DAMAGE = 0;
  SCE_HEAL   = 1;
  SCE_BLESS  = 2;

  { out-of-combat (field) effects. FE_HEAL is derived from an ally heal combat
    line, not stored; the rest are declared by a "field" line in content. }
  FE_NONE        = 0;
  FE_HEAL        = 1;   { restore HP to one member (from the cast dice) }
  FE_CUREPOISON  = 2;   { clear poison on one member }
  FE_CUREDISEASE = 3;   { clear disease on one member }
  FE_REMOVECURSE = 4;   { lift lycanthropy on one member }
  FE_LIGHT       = 5;   { refuel the party light, fieldArg torch-loads }
  FE_IDENTIFY    = 6;   { identify the party's carried unknown item kinds }
  FE_REVEAL      = 7;   { lift fog within fieldArg tiles of the party }

type
  TSpellDef = record
    id: string[16];
    name: string;
    domain: byte;       { SPD_* }
    level: byte;        { 1 .. 6 }
    save: byte;         { SSV_* }
    dtype: byte;        { SDT_* }
    effect: string;     { the prose that defines what the spell does }
    components: string; { material components, or empty }
    { an optional thematic combat approximation; castable is false for the
      utility and reference spells that no fight can use }
    castable: boolean;
    castCost: byte;     { spell points spent }
    castMode: byte;     { SCM_* }
    castEffect: byte;   { SCE_* }
    castDice: byte;
    castSides: byte;
    castInflict: byte;  { a monsters ST_* a damaging hit may lay, 0 = none }
    school: byte;       { SCH_*, SCH_NONE for cleric, druid and untagged }
    icon: byte;         { PORT_SI<NN> spell icon, 0 = none }
    fieldEffect: byte;  { FE_*, the out-of-combat effect; FE_NONE if none }
    fieldArg: byte;     { FE_LIGHT torch-loads, FE_REVEAL radius, else 0 }
  end;

var
  SpellDefs: array of TSpellDef;

function EncodeSpells(const ss: array of TSpellDef): TByteArray;
function LoadSpells(const p: TPak): boolean;

function SpellDefCount: longint;
function SpellByID(const id: string): longint;   { index, or -1 }
function DomainSpellCount(domain: longint): longint;
{ Walk the spells of one domain in level order: pass -1 to start, then the
  last index returned, to get each in turn; returns -1 at the end. }
function NextInDomain(domain, after: longint): longint;
{ The engine element this damage type maps to, thematically. }
function SpellElement(dtype: byte): byte;
function DomainName(d: byte): string;
function SaveName(s: byte): string;
function DTypeName(d: byte): string;
function SchoolName(s: byte): string;
{ Whether a specialist of the favored school is barred from the other school
  (its AD&D opposition). A school never opposes itself. }
function SchoolOpposes(favored, other: byte): boolean;
{ The out-of-combat effect a spell works, FE_NONE for none. A spell with an
  explicit field effect uses it; otherwise an ally heal combat line stands in
  as FE_HEAL, so the cure-wounds line needs no separate tag. }
function SpellFieldEffect(const d: TSpellDef): byte;
{ Whether a field effect picks one party member (heals and cures), as opposed
  to working on the whole party (light, identify, reveal). }
function FieldTargeted(kind: byte): boolean;

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

function EncodeSpells(const ss: array of TSpellDef): TByteArray;
var
  a: TByteArray;
  n, si: longint;
begin
  SetLength(a, 0); n := 0;
  PutU16(a, n, SPEL_MAGIC and $FFFF);
  PutU16(a, n, (SPEL_MAGIC shr 16) and $FFFF);
  PutU16(a, n, Length(ss));
  for si := 0 to High(ss) do begin
    PutFixed(a, n, ss[si].id, 16);
    PutStr(a, n, ss[si].name);
    PutB(a, n, ss[si].domain);
    PutB(a, n, ss[si].level);
    PutB(a, n, ss[si].save);
    PutB(a, n, ss[si].dtype);
    PutStr(a, n, ss[si].effect);
    PutStr(a, n, ss[si].components);
    if ss[si].castable then PutB(a, n, 1) else PutB(a, n, 0);
    PutB(a, n, ss[si].castCost);
    PutB(a, n, ss[si].castMode);
    PutB(a, n, ss[si].castEffect);
    PutB(a, n, ss[si].castDice);
    PutB(a, n, ss[si].castSides);
    PutB(a, n, ss[si].castInflict);
    PutB(a, n, ss[si].school);
    PutB(a, n, ss[si].icon);
    PutB(a, n, ss[si].fieldEffect);
    PutB(a, n, ss[si].fieldArg);
  end;
  SetLength(a, n);
  EncodeSpells := a;
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

function LoadSpells(const p: TPak): boolean;
var
  count, si: longint;
  magicLo, magicHi: word;
begin
  LoadSpells := false;
  SpellDefs := nil;
  if not PakGet(p, 'SPEL', rd) then exit;
  rp := 0;
  magicLo := RU16; magicHi := RU16;
  if (magicLo or (magicHi shl 16)) <> SPEL_MAGIC then exit;
  count := RU16;
  SetLength(SpellDefs, count);
  for si := 0 to count - 1 do begin
    SpellDefs[si].id := RFixed(16);
    SpellDefs[si].name := RStr;
    SpellDefs[si].domain := RB;
    SpellDefs[si].level := RB;
    SpellDefs[si].save := RB;
    SpellDefs[si].dtype := RB;
    SpellDefs[si].effect := RStr;
    SpellDefs[si].components := RStr;
    SpellDefs[si].castable := RB <> 0;
    SpellDefs[si].castCost := RB;
    SpellDefs[si].castMode := RB;
    SpellDefs[si].castEffect := RB;
    SpellDefs[si].castDice := RB;
    SpellDefs[si].castSides := RB;
    SpellDefs[si].castInflict := RB;
    SpellDefs[si].school := RB;
    SpellDefs[si].icon := RB;
    SpellDefs[si].fieldEffect := RB;
    SpellDefs[si].fieldArg := RB;
  end;
  LoadSpells := true;
end;

{ ---- queries ---- }

function SpellDefCount: longint;
begin
  SpellDefCount := Length(SpellDefs);
end;

function SpellByID(const id: string): longint;
var i: longint;
begin
  for i := 0 to High(SpellDefs) do
    if SpellDefs[i].id = id then begin SpellByID := i; exit; end;
  SpellByID := -1;
end;

function DomainSpellCount(domain: longint): longint;
var i, c: longint;
begin
  c := 0;
  for i := 0 to High(SpellDefs) do
    if SpellDefs[i].domain = domain then inc(c);
  DomainSpellCount := c;
end;

function NextInDomain(domain, after: longint): longint;
var i: longint;
begin
  for i := after + 1 to High(SpellDefs) do
    if SpellDefs[i].domain = domain then begin NextInDomain := i; exit; end;
  NextInDomain := -1;
end;

function SpellElement(dtype: byte): byte;
begin
  case dtype of
    SDT_FIRE:      SpellElement := EL_FIRE;
    SDT_COLD:      SpellElement := EL_FROST;
    SDT_LIGHTNING: SpellElement := EL_SHOCK;
    { acid, force and poison have no element of their own: physical is the
      closest thematic fit, and the prose still carries the real flavour }
    SDT_ACID, SDT_FORCE, SDT_POISON: SpellElement := EL_PHYS;
  else
    SpellElement := 0;
  end;
end;

function DomainName(d: byte): string;
begin
  case d of
    SPD_CLERIC: DomainName := 'Cleric';
    SPD_DRUID:  DomainName := 'Druid';
    SPD_MAGE:   DomainName := 'Magic-User';
  else
    DomainName := '?';
  end;
end;

function SaveName(s: byte): string;
begin
  case s of
    SSV_BODY:  SaveName := 'Body';
    SSV_DODGE: SaveName := 'Dodge';
    SSV_WILL:  SaveName := 'Will';
  else
    SaveName := 'none';
  end;
end;

function DTypeName(d: byte): string;
begin
  case d of
    SDT_ACID:      DTypeName := 'acid';
    SDT_COLD:      DTypeName := 'cold';
    SDT_FIRE:      DTypeName := 'fire';
    SDT_FORCE:     DTypeName := 'force';
    SDT_LIGHTNING: DTypeName := 'lightning';
    SDT_POISON:    DTypeName := 'poison';
  else
    DTypeName := 'none';
  end;
end;

function SchoolName(s: byte): string;
begin
  case s of
    SCH_ABJUR:   SchoolName := 'abjuration';
    SCH_CONJ:    SchoolName := 'conjuration';
    SCH_DIVIN:   SchoolName := 'divination';
    SCH_ENCHANT: SchoolName := 'enchantment';
    SCH_EVOKE:   SchoolName := 'evocation';
    SCH_ILLUS:   SchoolName := 'illusion';
    SCH_NECRO:   SchoolName := 'necromancy';
    SCH_TRANS:   SchoolName := 'transmutation';
  else
    SchoolName := 'none';
  end;
end;

{ The AD&D 2e opposition matrix, simplified to our single Divination school.
  A specialist cannot learn or cast spells of a school that opposes its own.
  The Lesser Divination exemption (always-available low divination) is applied
  by the caller, not here. }
function SchoolOpposes(favored, other: byte): boolean;
const
  OPP: array[SCH_ABJUR .. SCH_TRANS] of set of byte = (
    { abjur     } [SCH_TRANS, SCH_ILLUS],
    { conj      } [SCH_DIVIN, SCH_EVOKE],
    { divin     } [SCH_CONJ],
    { enchant   } [SCH_ILLUS, SCH_EVOKE],
    { evoke     } [SCH_ENCHANT, SCH_CONJ],
    { illus     } [SCH_ABJUR, SCH_TRANS, SCH_NECRO],
    { necro     } [SCH_ILLUS, SCH_ENCHANT],
    { trans     } [SCH_ABJUR, SCH_NECRO]);
begin
  SchoolOpposes := false;
  if favored > SCH_TRANS then exit;        { generalist or invalid favors none }
  if other > SCH_TRANS then exit;
  SchoolOpposes := other in OPP[favored];
end;

function SpellFieldEffect(const d: TSpellDef): byte;
begin
  if d.fieldEffect <> FE_NONE then
    SpellFieldEffect := d.fieldEffect
  else if d.castable and (d.castEffect = SCE_HEAL)
    and (d.castMode = SCM_ALLY) then
    SpellFieldEffect := FE_HEAL
  else
    SpellFieldEffect := FE_NONE;
end;

function FieldTargeted(kind: byte): boolean;
begin
  FieldTargeted := (kind = FE_HEAL) or (kind = FE_CUREPOISON)
    or (kind = FE_CUREDISEASE) or (kind = FE_REMOVECURSE);
end;

end.
