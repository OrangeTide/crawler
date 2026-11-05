unit worldfmt;

{** Manifest of dynamic (generated) maps.

  A dynamic map has no pak lump; it is built by mapgen from a seed. The
  manifest names each one, its generator, size, difficulty depth and the
  map and marker its exit returns to. Authored as text, compiled into a
  WRLD lump. }

{$mode objfpc}{$H+}

interface

uses
  pak;

const
  WRLD_MAGIC = $444C5257;  { 'WRLD' }

  GEN_ROOMS = 0;
  GEN_CAVE  = 1;
  GEN_MAZE  = 2;

type
  TDynMap = record
    name: string[12];
    gen: byte;
    w, h: byte;
    depth: byte;
    area: byte;           { encounter area, 0 = safe }
    retMap: string[12];
    retMarker: string[12];
  end;

var
  DynMaps: array of TDynMap;

function EncodeWorld(const d: array of TDynMap): TByteArray;
function LoadWorld(const p: TPak): boolean;
function DynIndex(const name: string): longint;

implementation

procedure PutB(var a: TByteArray; var n: longint; v: byte);
begin
  if n >= Length(a) then SetLength(a, (n + 1) * 2);
  a[n] := v; inc(n);
end;

procedure PutName(var a: TByteArray; var n: longint; const s: string);
var i: longint;
begin
  for i := 1 to 12 do
    if i <= Length(s) then PutB(a, n, ord(s[i])) else PutB(a, n, 0);
end;

function EncodeWorld(const d: array of TDynMap): TByteArray;
var a: TByteArray; n, i: longint;
begin
  SetLength(a, 0); n := 0;
  PutB(a, n, WRLD_MAGIC and $FF); PutB(a, n, (WRLD_MAGIC shr 8) and $FF);
  PutB(a, n, (WRLD_MAGIC shr 16) and $FF); PutB(a, n, (WRLD_MAGIC shr 24) and $FF);
  PutB(a, n, Length(d) and $FF); PutB(a, n, (Length(d) shr 8) and $FF);
  for i := 0 to High(d) do begin
    PutName(a, n, d[i].name);
    PutB(a, n, d[i].gen);
    PutB(a, n, d[i].w);
    PutB(a, n, d[i].h);
    PutB(a, n, d[i].depth);
    PutB(a, n, d[i].area);
    PutName(a, n, d[i].retMap);
    PutName(a, n, d[i].retMarker);
  end;
  SetLength(a, n);
  EncodeWorld := a;
end;

function RName(const a: TByteArray; var p: longint): string;
var i: longint; s: string;
begin
  s := '';
  for i := 1 to 12 do begin if a[p] <> 0 then s := s + chr(a[p]); inc(p); end;
  RName := s;
end;

function LoadWorld(const p: TPak): boolean;
var blob: TByteArray; pos, count, i: longint; magic: longword;
begin
  LoadWorld := false;
  DynMaps := nil;
  if not PakGet(p, 'WRLD', blob) then exit;
  if Length(blob) < 6 then exit;
  magic := blob[0] or (blob[1] shl 8) or (blob[2] shl 16) or (longword(blob[3]) shl 24);
  if magic <> WRLD_MAGIC then exit;
  count := blob[4] or (blob[5] shl 8);
  pos := 6;
  SetLength(DynMaps, count);
  for i := 0 to count - 1 do begin
    DynMaps[i].name := RName(blob, pos);
    DynMaps[i].gen := blob[pos]; inc(pos);
    DynMaps[i].w := blob[pos]; inc(pos);
    DynMaps[i].h := blob[pos]; inc(pos);
    DynMaps[i].depth := blob[pos]; inc(pos);
    DynMaps[i].area := blob[pos]; inc(pos);
    DynMaps[i].retMap := RName(blob, pos);
    DynMaps[i].retMarker := RName(blob, pos);
  end;
  LoadWorld := true;
end;

function DynIndex(const name: string): longint;
var i: longint;
begin
  for i := 0 to High(DynMaps) do
    if DynMaps[i].name = name then begin DynIndex := i; exit; end;
  DynIndex := -1;
end;

end.
