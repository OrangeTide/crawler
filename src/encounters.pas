unit encounters;

{** Encounter tables, loaded from a compiled lump.

  Each area references an encounter table by number. A table is a weighted
  list of monster ids; the wild-encounter roll draws from the table for the
  party's current area. Table 0 is empty by convention, so a safe area (the
  town, interiors) simply points at it and spawns nothing. Which area uses
  which table, and the tables themselves, are authored in
  content/encounters.txt, so no spawn policy lives in code. }

{$mode objfpc}{$H+}

interface

uses
  pak;

const
  ENCT_MAGIC = $54434E45;  { 'ENCT' little-endian }

type
  TEncEntry = record
    mon: string[12];       { monster id }
    weight: word;          { relative chance within the table }
  end;

  TEncTable = record
    entries: array of TEncEntry;
  end;

var
  EncTables: array of TEncTable;        { indexed by table number }
  AreaTable: array[0 .. 255] of byte;   { area byte -> table number }

function EncodeEncounters(const tables: array of TEncTable;
  const areaMap: array of byte): TByteArray;
function LoadEncounters(const p: TPak): boolean;

{ The table number an area points at (0, the empty table, when unset). }
function EncTableOf(areaMask: byte): longint;
{ Whether a table has no entries (so it spawns nothing). }
function EncTableEmpty(tab: longint): boolean;

implementation

procedure PutB(var a: TByteArray; var n: longint; v: byte);
begin
  if n >= Length(a) then SetLength(a, (n + 1) * 2);
  a[n] := v; inc(n);
end;

procedure PutU16(var a: TByteArray; var n: longint; v: word);
begin
  PutB(a, n, v and $FF); PutB(a, n, (v shr 8) and $FF);
end;

procedure PutName(var a: TByteArray; var n: longint; const s: string; len: longint);
var i: longint;
begin
  for i := 1 to len do
    if i <= Length(s) then PutB(a, n, ord(s[i])) else PutB(a, n, 0);
end;

function EncodeEncounters(const tables: array of TEncTable;
  const areaMap: array of byte): TByteArray;
var
  a: TByteArray;
  n, i, k, areas: longint;
begin
  SetLength(a, 0);
  n := 0;
  PutB(a, n, ENCT_MAGIC and $FF);
  PutB(a, n, (ENCT_MAGIC shr 8) and $FF);
  PutB(a, n, (ENCT_MAGIC shr 16) and $FF);
  PutB(a, n, (ENCT_MAGIC shr 24) and $FF);
  PutU16(a, n, Length(tables));
  for i := 0 to High(tables) do begin
    PutU16(a, n, Length(tables[i].entries));
    for k := 0 to High(tables[i].entries) do begin
      PutName(a, n, tables[i].entries[k].mon, 12);
      PutU16(a, n, tables[i].entries[k].weight);
    end;
  end;
  { the area -> table map, only the non-zero entries }
  areas := 0;
  for i := 0 to High(areaMap) do if areaMap[i] <> 0 then inc(areas);
  PutU16(a, n, areas);
  for i := 0 to High(areaMap) do
    if areaMap[i] <> 0 then begin
      PutB(a, n, i);
      PutB(a, n, areaMap[i]);
    end;
  SetLength(a, n);
  EncodeEncounters := a;
end;

function RName(const a: TByteArray; var p: longint; len: longint): string;
var i: longint; s: string;
begin
  s := '';
  for i := 1 to len do begin
    if (p < Length(a)) and (a[p] <> 0) then s := s + chr(a[p]);
    inc(p);
  end;
  RName := s;
end;

function RU16(const a: TByteArray; var p: longint): word;
begin
  RU16 := 0;
  if p + 1 < Length(a) then RU16 := a[p] or (a[p + 1] shl 8);
  inc(p, 2);
end;

function LoadEncounters(const p: TPak): boolean;
var
  blob: TByteArray;
  pos, tcount, ecount, areas, i, k: longint;
  magic: longword;
  ab, tb: byte;
begin
  LoadEncounters := false;
  EncTables := nil;
  for i := 0 to 255 do AreaTable[i] := 0;
  if not PakGet(p, 'ENCT', blob) then exit;
  if Length(blob) < 6 then exit;
  magic := blob[0] or (blob[1] shl 8) or (blob[2] shl 16) or (longword(blob[3]) shl 24);
  if magic <> ENCT_MAGIC then exit;
  pos := 4;
  tcount := RU16(blob, pos);
  SetLength(EncTables, tcount);
  for i := 0 to tcount - 1 do begin
    ecount := RU16(blob, pos);
    SetLength(EncTables[i].entries, ecount);
    for k := 0 to ecount - 1 do begin
      EncTables[i].entries[k].mon := RName(blob, pos, 12);
      EncTables[i].entries[k].weight := RU16(blob, pos);
    end;
  end;
  areas := RU16(blob, pos);
  for i := 0 to areas - 1 do begin
    if pos + 1 >= Length(blob) then break;
    ab := blob[pos]; inc(pos);
    tb := blob[pos]; inc(pos);
    AreaTable[ab] := tb;
  end;
  LoadEncounters := true;
end;

function EncTableOf(areaMask: byte): longint;
begin
  EncTableOf := AreaTable[areaMask];
end;

function EncTableEmpty(tab: longint): boolean;
begin
  EncTableEmpty := (tab < 0) or (tab > High(EncTables))
    or (Length(EncTables[tab].entries) = 0);
end;

end.
