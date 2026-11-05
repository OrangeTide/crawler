unit shops;

{** Shop stock tables, loaded from a compiled lump.

  Each shop is a named list of item ids it offers for sale. Which vendor
  sells what is entirely data: a dialogue shop response names a shop id,
  and the stock, order and contents come from content/shops.txt. Prices
  are the item values from the item table, so nothing about a shop is
  decided in code. The record and codec live here so the asset tool and
  the runtime share one layout. }

{$mode objfpc}{$H+}

interface

uses
  pak;

const
  SHOPS_MAGIC = $504F4853;  { 'SHOP' little-endian }

type
  TShopDef = record
    id: string[12];
    items: array of string[12];
  end;

var
  ShopDefs: array of TShopDef;

function EncodeShops(const defs: array of TShopDef): TByteArray;
function LoadShops(const p: TPak): boolean;
function ShopIndex(const id: string): longint;

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

function EncodeShops(const defs: array of TShopDef): TByteArray;
var
  a: TByteArray;
  n, i, k: longint;
begin
  SetLength(a, 0);
  n := 0;
  PutB(a, n, SHOPS_MAGIC and $FF);
  PutB(a, n, (SHOPS_MAGIC shr 8) and $FF);
  PutB(a, n, (SHOPS_MAGIC shr 16) and $FF);
  PutB(a, n, (SHOPS_MAGIC shr 24) and $FF);
  PutU16(a, n, Length(defs));
  for i := 0 to High(defs) do begin
    PutName(a, n, defs[i].id, 12);
    PutU16(a, n, Length(defs[i].items));
    for k := 0 to High(defs[i].items) do
      PutName(a, n, defs[i].items[k], 12);
  end;
  SetLength(a, n);
  EncodeShops := a;
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

function LoadShops(const p: TPak): boolean;
var
  blob: TByteArray;
  pos, count, items, i, k: longint;
  magic: longword;
begin
  LoadShops := false;
  ShopDefs := nil;
  if not PakGet(p, 'SHOP', blob) then exit;
  if Length(blob) < 6 then exit;
  magic := blob[0] or (blob[1] shl 8) or (blob[2] shl 16) or (longword(blob[3]) shl 24);
  if magic <> SHOPS_MAGIC then exit;
  count := blob[4] or (blob[5] shl 8);
  pos := 6;
  SetLength(ShopDefs, count);
  for i := 0 to count - 1 do begin
    ShopDefs[i].id := RName(blob, pos, 12);
    items := blob[pos] or (blob[pos + 1] shl 8); inc(pos, 2);
    SetLength(ShopDefs[i].items, items);
    for k := 0 to items - 1 do
      ShopDefs[i].items[k] := RName(blob, pos, 12);
  end;
  LoadShops := true;
end;

function ShopIndex(const id: string): longint;
var i: longint;
begin
  for i := 0 to High(ShopDefs) do
    if ShopDefs[i].id = id then begin ShopIndex := i; exit; end;
  ShopIndex := -1;
end;

end.
