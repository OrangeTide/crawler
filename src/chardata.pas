unit chardata;

{** Data-driven species, classes and backgrounds.

  These replace the hardcoded kindred and class enums. Each table is
  authored as text, compiled into a lump and loaded here. Classes map to
  the four AX&X tracks, so the mechanics in rules stay small while the
  roster is open ended. }

{$mode objfpc}{$H+}

interface

uses
  pak;

const
  { track values match TTrack ordinals in rules }
  TRK_WARRIOR    = 0;
  TRK_PRIEST     = 1;
  TRK_SPECIALIST = 2;
  TRK_MAGE       = 3;

  { starting-kit archetypes }
  KIT_SOLDIER = 0;
  KIT_HEAVY   = 1;
  KIT_ARCHER  = 2;
  KIT_PRIEST  = 3;
  KIT_THIEF   = 4;
  KIT_MAGE    = 5;

  SPF_DARKVISION = 1;
  SPF_PRIMEBONUS = 2;   { human-style +1 to the class prime ability }

  SPEC_MAGIC = $43455053;  { 'SPEC' }
  CLAS_MAGIC = $53414C43;  { 'CLAS' }
  BKGD_MAGIC = $44474B42;  { 'BKGD' }

type
  TSpeciesDef = record
    id: string[12];
    name: string[16];
    abilBonus: array[0 .. 5] of shortint;
    flags: byte;
    xpBonus: byte;        { percent }
  end;

  TClassDef = record
    id: string[12];
    name: string[16];
    track: byte;
    hitDie: byte;
    prime: byte;          { ability ordinal 0..5 }
    kit: byte;
    domain: byte;         { spell domain: spelldb SPD_*, 255 (SPD_NONE) if none }
    school: byte;         { favored arcane school: spelldb SCH_*, 255 none }
  end;

  TBackgroundDef = record
    id: string[12];
    name: string[20];
    skill: string[16];
    gold: string[16];    { starting-coin dice expression, e.g. 10*3d6 }
  end;

var
  SpeciesDefs: array of TSpeciesDef;
  ClassDefs: array of TClassDef;
  BackgroundDefs: array of TBackgroundDef;

function EncodeSpecies(const defs: array of TSpeciesDef): TByteArray;
function EncodeClasses(const defs: array of TClassDef): TByteArray;
function EncodeBackgrounds(const defs: array of TBackgroundDef): TByteArray;
function LoadCharData(const p: TPak): boolean;
function ClassIndex(const id: string): longint;
function SpeciesIndex(const id: string): longint;
{ The spell domain a class draws from (spelldb SPD_*), or 255 (SPD_NONE). }
function ClassDomain(idx: longint): byte;
{ The favored arcane school of a class (spelldb SCH_*), or 255 for none. }
function ClassSchool(idx: longint): byte;

implementation

{ ---- shared byte writers ---- }

procedure PutB(var a: TByteArray; var n: longint; v: byte);
begin
  if n >= Length(a) then SetLength(a, (n + 1) * 2);
  a[n] := v; inc(n);
end;

procedure PutHdr(var a: TByteArray; var n: longint; magic: longword; count: longint);
begin
  PutB(a, n, magic and $FF);
  PutB(a, n, (magic shr 8) and $FF);
  PutB(a, n, (magic shr 16) and $FF);
  PutB(a, n, (magic shr 24) and $FF);
  PutB(a, n, count and $FF);
  PutB(a, n, (count shr 8) and $FF);
end;

procedure PutName(var a: TByteArray; var n: longint; const s: string; len: longint);
var i: longint;
begin
  for i := 1 to len do
    if i <= Length(s) then PutB(a, n, ord(s[i])) else PutB(a, n, 0);
end;

function EncodeSpecies(const defs: array of TSpeciesDef): TByteArray;
var a: TByteArray; n, i, k: longint;
begin
  SetLength(a, 0); n := 0;
  PutHdr(a, n, SPEC_MAGIC, Length(defs));
  for i := 0 to High(defs) do begin
    PutName(a, n, defs[i].id, 12);
    PutName(a, n, defs[i].name, 16);
    for k := 0 to 5 do PutB(a, n, byte(defs[i].abilBonus[k]));
    PutB(a, n, defs[i].flags);
    PutB(a, n, defs[i].xpBonus);
  end;
  SetLength(a, n);
  EncodeSpecies := a;
end;

function EncodeClasses(const defs: array of TClassDef): TByteArray;
var a: TByteArray; n, i: longint;
begin
  SetLength(a, 0); n := 0;
  PutHdr(a, n, CLAS_MAGIC, Length(defs));
  for i := 0 to High(defs) do begin
    PutName(a, n, defs[i].id, 12);
    PutName(a, n, defs[i].name, 16);
    PutB(a, n, defs[i].track);
    PutB(a, n, defs[i].hitDie);
    PutB(a, n, defs[i].prime);
    PutB(a, n, defs[i].kit);
    PutB(a, n, defs[i].domain);
    PutB(a, n, defs[i].school);
  end;
  SetLength(a, n);
  EncodeClasses := a;
end;

function EncodeBackgrounds(const defs: array of TBackgroundDef): TByteArray;
var a: TByteArray; n, i: longint;
begin
  SetLength(a, 0); n := 0;
  PutHdr(a, n, BKGD_MAGIC, Length(defs));
  for i := 0 to High(defs) do begin
    PutName(a, n, defs[i].id, 12);
    PutName(a, n, defs[i].name, 20);
    PutName(a, n, defs[i].skill, 16);
    PutName(a, n, defs[i].gold, 16);
  end;
  SetLength(a, n);
  EncodeBackgrounds := a;
end;

{ ---- readers ---- }

function RName(const a: TByteArray; var p: longint; len: longint): string;
var i: longint; s: string;
begin
  s := '';
  for i := 1 to len do begin
    if a[p] <> 0 then s := s + chr(a[p]);
    inc(p);
  end;
  RName := s;
end;

function ChkHdr(const blob: TByteArray; magic: longword; out count, pos: longint): boolean;
var m: longword;
begin
  ChkHdr := false;
  if Length(blob) < 6 then exit;
  m := blob[0] or (blob[1] shl 8) or (blob[2] shl 16) or (longword(blob[3]) shl 24);
  if m <> magic then exit;
  count := blob[4] or (blob[5] shl 8);
  pos := 6;
  ChkHdr := true;
end;

function LoadSpecies(const p: TPak): boolean;
var blob: TByteArray; count, pos, i, k: longint;
begin
  LoadSpecies := false;
  if not PakGet(p, 'SPEC', blob) then exit;
  if not ChkHdr(blob, SPEC_MAGIC, count, pos) then exit;
  SetLength(SpeciesDefs, count);
  for i := 0 to count - 1 do begin
    SpeciesDefs[i].id := RName(blob, pos, 12);
    SpeciesDefs[i].name := RName(blob, pos, 16);
    for k := 0 to 5 do begin SpeciesDefs[i].abilBonus[k] := shortint(blob[pos]); inc(pos); end;
    SpeciesDefs[i].flags := blob[pos]; inc(pos);
    SpeciesDefs[i].xpBonus := blob[pos]; inc(pos);
  end;
  LoadSpecies := true;
end;

function LoadClasses(const p: TPak): boolean;
var blob: TByteArray; count, pos, i: longint;
begin
  LoadClasses := false;
  if not PakGet(p, 'CLAS', blob) then exit;
  if not ChkHdr(blob, CLAS_MAGIC, count, pos) then exit;
  SetLength(ClassDefs, count);
  for i := 0 to count - 1 do begin
    ClassDefs[i].id := RName(blob, pos, 12);
    ClassDefs[i].name := RName(blob, pos, 16);
    ClassDefs[i].track := blob[pos]; inc(pos);
    ClassDefs[i].hitDie := blob[pos]; inc(pos);
    ClassDefs[i].prime := blob[pos]; inc(pos);
    ClassDefs[i].kit := blob[pos]; inc(pos);
    ClassDefs[i].domain := blob[pos]; inc(pos);
    ClassDefs[i].school := blob[pos]; inc(pos);
  end;
  LoadClasses := true;
end;

function LoadBackgrounds(const p: TPak): boolean;
var blob: TByteArray; count, pos, i: longint;
begin
  LoadBackgrounds := false;
  if not PakGet(p, 'BKGD', blob) then exit;
  if not ChkHdr(blob, BKGD_MAGIC, count, pos) then exit;
  SetLength(BackgroundDefs, count);
  for i := 0 to count - 1 do begin
    BackgroundDefs[i].id := RName(blob, pos, 12);
    BackgroundDefs[i].name := RName(blob, pos, 20);
    BackgroundDefs[i].skill := RName(blob, pos, 16);
    BackgroundDefs[i].gold := RName(blob, pos, 16);
  end;
  LoadBackgrounds := true;
end;

function LoadCharData(const p: TPak): boolean;
begin
  LoadCharData := LoadSpecies(p) and LoadClasses(p) and LoadBackgrounds(p);
end;

function ClassIndex(const id: string): longint;
var i: longint;
begin
  for i := 0 to High(ClassDefs) do
    if ClassDefs[i].id = id then begin ClassIndex := i; exit; end;
  ClassIndex := -1;
end;

function SpeciesIndex(const id: string): longint;
var i: longint;
begin
  for i := 0 to High(SpeciesDefs) do
    if SpeciesDefs[i].id = id then begin SpeciesIndex := i; exit; end;
  SpeciesIndex := -1;
end;

function ClassDomain(idx: longint): byte;
begin
  if (idx < 0) or (idx > High(ClassDefs)) then ClassDomain := 255
  else ClassDomain := ClassDefs[idx].domain;
end;

function ClassSchool(idx: longint): byte;
begin
  if (idx < 0) or (idx > High(ClassDefs)) then ClassSchool := 255
  else ClassSchool := ClassDefs[idx].school;
end;

end.
