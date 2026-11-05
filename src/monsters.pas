unit monsters;

{** Monster database, loaded from a compiled table lump.

  Like the item table, monsters are authored as text, compiled by the
  asset tool and loaded here. Combat reads these definitions to run a
  fight. The record and the codec live together so the tool and the
  runtime agree on the layout. }

{$mode objfpc}{$H+}

interface

uses
  pak;

const
  MONS_MAGIC = $534E4F4D;  { 'MONS' little-endian }

  MF_UNDEAD = 1;
  MF_RANGED = 2;
  MF_LYCAN  = 4;   { a hit can pass on the lycanthropy curse }

type
  TMonsterDef = record
    id: string[12];
    name: string[16];
    hd: byte;         { hit dice }
    ac: byte;
    atkBonus: byte;   { to-hit bonus; AX&X monsters attack at +HD }
    dmgSides: byte;   { damage die sides }
    morale: byte;     { hold on a 1d6 of this or less; higher is braver }
    speed: byte;      { range bands closed per move }
    xp: word;
    flags: byte;
    model: string[12]; { combat mesh id in the model registry, '' for none }
  end;

var
  MonDefs: array of TMonsterDef;

function EncodeMonsters(const defs: array of TMonsterDef): TByteArray;
function LoadMonsters(const p: TPak): boolean;
function MonIndex(const id: string): longint;

implementation

procedure PutB(var a: TByteArray; var n: longint; v: byte);
begin
  if n >= Length(a) then SetLength(a, (n + 1) * 2);
  a[n] := v; inc(n);
end;

procedure PutName(var a: TByteArray; var n: longint; const s: string; len: longint);
var i: longint;
begin
  for i := 1 to len do
    if i <= Length(s) then PutB(a, n, ord(s[i])) else PutB(a, n, 0);
end;

function EncodeMonsters(const defs: array of TMonsterDef): TByteArray;
var
  a: TByteArray;
  n, i: longint;
begin
  SetLength(a, 0);
  n := 0;
  PutB(a, n, MONS_MAGIC and $FF);
  PutB(a, n, (MONS_MAGIC shr 8) and $FF);
  PutB(a, n, (MONS_MAGIC shr 16) and $FF);
  PutB(a, n, (MONS_MAGIC shr 24) and $FF);
  PutB(a, n, Length(defs) and $FF);
  PutB(a, n, (Length(defs) shr 8) and $FF);
  for i := 0 to High(defs) do begin
    PutName(a, n, defs[i].id, 12);
    PutName(a, n, defs[i].name, 16);
    PutB(a, n, defs[i].hd);
    PutB(a, n, defs[i].ac);
    PutB(a, n, defs[i].atkBonus);
    PutB(a, n, defs[i].dmgSides);
    PutB(a, n, defs[i].morale);
    PutB(a, n, defs[i].speed);
    PutB(a, n, defs[i].xp and $FF);
    PutB(a, n, (defs[i].xp shr 8) and $FF);
    PutB(a, n, defs[i].flags);
    PutName(a, n, defs[i].model, 12);
  end;
  SetLength(a, n);
  EncodeMonsters := a;
end;

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

function LoadMonsters(const p: TPak): boolean;
var
  blob: TByteArray;
  pos, count, i: longint;
  magic: longword;
begin
  LoadMonsters := false;
  MonDefs := nil;
  if not PakGet(p, 'MONS', blob) then exit;
  if Length(blob) < 6 then exit;
  magic := blob[0] or (blob[1] shl 8) or (blob[2] shl 16) or (longword(blob[3]) shl 24);
  if magic <> MONS_MAGIC then exit;
  count := blob[4] or (blob[5] shl 8);
  pos := 6;
  SetLength(MonDefs, count);
  for i := 0 to count - 1 do begin
    MonDefs[i].id := RName(blob, pos, 12);
    MonDefs[i].name := RName(blob, pos, 16);
    MonDefs[i].hd := blob[pos]; inc(pos);
    MonDefs[i].ac := blob[pos]; inc(pos);
    MonDefs[i].atkBonus := blob[pos]; inc(pos);
    MonDefs[i].dmgSides := blob[pos]; inc(pos);
    MonDefs[i].morale := blob[pos]; inc(pos);
    MonDefs[i].speed := blob[pos]; inc(pos);
    MonDefs[i].xp := blob[pos] or (blob[pos + 1] shl 8); inc(pos, 2);
    MonDefs[i].flags := blob[pos]; inc(pos);
    MonDefs[i].model := RName(blob, pos, 12);
  end;
  LoadMonsters := true;
end;

function MonIndex(const id: string): longint;
var i: longint;
begin
  for i := 0 to High(MonDefs) do
    if MonDefs[i].id = id then begin MonIndex := i; exit; end;
  MonIndex := -1;
end;

end.
