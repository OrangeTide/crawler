unit items;

{** Item database: definitions loaded from a compiled table lump.

  Item definitions are authored as text, compiled into an ITEMS lump by
  the asset tool and loaded here at startup. Item instances elsewhere
  carry only an index into this database plus per-instance state, which
  keeps saves small. The record type and the encode/decode live here so
  the tool and the runtime share one layout. }

{$mode objfpc}{$H+}

interface

uses
  pak;

const
  IK_WEAPON   = 0;
  IK_ARMOR    = 1;
  IK_SHIELD   = 2;
  IK_POTION   = 3;
  IK_LIGHT    = 4;
  IK_KEY      = 5;
  IK_TREASURE = 6;
  IK_MISC     = 7;

  IF_TWOHAND = 1;
  IF_RANGED  = 2;
  IF_SILVER  = 4;   { a blessed or silvered weapon; strikes as holy }
  IF_REVIVE  = 8;   { a consumable that raises a gravely wounded ally }
  IF_MYSTERY = 16;  { found unidentified; its true name is hidden until known }

  ITEMS_MAGIC = $4D455449;  { 'ITEM' little-endian }

type
  TItemDef = record
    id: string[12];
    name: string[20];
    kind: byte;
    dmgSides: byte;   { weapon damage die; 0 if none }
    acVal: byte;      { armor AC value, or shield AC bonus }
    slots: byte;
    value: word;
    flags: byte;
    sprite: byte;
  end;

var
  ItemDefs: array of TItemDef;

function EncodeItems(const defs: array of TItemDef): TByteArray;
function LoadItems(const p: TPak): boolean;
function ItemIndex(const id: string): longint;
function ItemKindName(kind: byte): string;

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

function EncodeItems(const defs: array of TItemDef): TByteArray;
var
  a: TByteArray;
  n, i: longint;
begin
  SetLength(a, 0);
  n := 0;
  PutB(a, n, ITEMS_MAGIC and $FF);
  PutB(a, n, (ITEMS_MAGIC shr 8) and $FF);
  PutB(a, n, (ITEMS_MAGIC shr 16) and $FF);
  PutB(a, n, (ITEMS_MAGIC shr 24) and $FF);
  PutB(a, n, Length(defs) and $FF);
  PutB(a, n, (Length(defs) shr 8) and $FF);
  for i := 0 to High(defs) do begin
    PutName(a, n, defs[i].id, 12);
    PutName(a, n, defs[i].name, 20);
    PutB(a, n, defs[i].kind);
    PutB(a, n, defs[i].dmgSides);
    PutB(a, n, defs[i].acVal);
    PutB(a, n, defs[i].slots);
    PutB(a, n, defs[i].value and $FF);
    PutB(a, n, (defs[i].value shr 8) and $FF);
    PutB(a, n, defs[i].flags);
    PutB(a, n, defs[i].sprite);
  end;
  SetLength(a, n);
  EncodeItems := a;
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

function LoadItems(const p: TPak): boolean;
var
  blob: TByteArray;
  pos, count, i: longint;
  magic: longword;
begin
  LoadItems := false;
  ItemDefs := nil;
  if not PakGet(p, 'ITEMS', blob) then exit;
  if Length(blob) < 6 then exit;
  magic := blob[0] or (blob[1] shl 8) or (blob[2] shl 16) or (longword(blob[3]) shl 24);
  if magic <> ITEMS_MAGIC then exit;
  count := blob[4] or (blob[5] shl 8);
  pos := 6;
  SetLength(ItemDefs, count);
  for i := 0 to count - 1 do begin
    ItemDefs[i].id := RName(blob, pos, 12);
    ItemDefs[i].name := RName(blob, pos, 20);
    ItemDefs[i].kind := blob[pos]; inc(pos);
    ItemDefs[i].dmgSides := blob[pos]; inc(pos);
    ItemDefs[i].acVal := blob[pos]; inc(pos);
    ItemDefs[i].slots := blob[pos]; inc(pos);
    ItemDefs[i].value := blob[pos] or (blob[pos + 1] shl 8); inc(pos, 2);
    ItemDefs[i].flags := blob[pos]; inc(pos);
    ItemDefs[i].sprite := blob[pos]; inc(pos);
  end;
  LoadItems := true;
end;

function ItemIndex(const id: string): longint;
var i: longint;
begin
  for i := 0 to High(ItemDefs) do
    if ItemDefs[i].id = id then begin ItemIndex := i; exit; end;
  ItemIndex := -1;
end;

function ItemKindName(kind: byte): string;
begin
  case kind of
    IK_WEAPON:   ItemKindName := 'weapon';
    IK_ARMOR:    ItemKindName := 'armor';
    IK_SHIELD:   ItemKindName := 'shield';
    IK_POTION:   ItemKindName := 'potion';
    IK_LIGHT:    ItemKindName := 'light';
    IK_KEY:      ItemKindName := 'key';
    IK_TREASURE: ItemKindName := 'treasure';
  else
    ItemKindName := 'misc';
  end;
end;

end.
