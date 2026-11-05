unit mapfmt;

{** Compiled map format, shared by the runtime and the map compiler.

  A map is a grid of wall tiles plus typed metadata: markers (named
  entry points), portals (tiles that move the party to another map) and
  door data. The offline mapc tool encodes a text map to this binary
  lump; the runtime decodes it. Keeping encode and decode in one unit
  means the layout is defined once.

  Binary layout:
    magic    'CMAP'   u32
    version  u16
    w, h     u16 each
    tileset  u8
    music    u8
    flags    u8
    reserved u8
    walls    w*h bytes
    markerCount u16, markers [ name 12, x u16, y u16, dir u8, pad u8 ]
    portalCount u16, portals [ x u16, y u16, target 12, marker 12 ]
    doorCount   u16, doors   [ x u16, y u16, locked u8, pad u8, key 12 ] }

{$mode objfpc}{$H+}

interface

uses
  pak;

const
  MAP_MAGIC   = $50414D43;  { 'CMAP' little-endian }
  MAP_VERSION = 1;

  DIR_N = 0;
  DIR_E = 1;
  DIR_S = 2;
  DIR_W = 3;

type
  TMarker = record
    name: string[12];
    x, y: word;
    dir: byte;
  end;

  TPortal = record
    x, y: word;
    target: string[12];   { target map lump name }
    marker: string[12];   { entry marker in the target }
  end;

  TDoorMeta = record
    x, y: word;
    locked: byte;
    key: string[12];
  end;

  TNpc = record
    x, y: word;
    dialog: string[12];
    name: string[12];
  end;

  TTrap = record
    x, y: word;
    dmg: byte;      { damage die sides on a failed save }
    dc: byte;       { Dodge save target }
  end;

  TMapData = record
    w, h: longint;
    tileset, music, flags: byte;
    walls: array of byte;                 { w*h, row major }
    markers: array of TMarker;
    portals: array of TPortal;
    doors: array of TDoorMeta;
    npcs: array of TNpc;
    traps: array of TTrap;
  end;

function EncodeMap(const m: TMapData): TByteArray;
function DecodeMap(const blob: TByteArray; out m: TMapData): boolean;

implementation

{ ---- little-endian writers over a growable array ---- }

type
  TBuf = record
    data: TByteArray;
    n: longint;
  end;

procedure BInit(out b: TBuf);
begin
  b.data := nil;
  b.n := 0;
end;

procedure BByte(var b: TBuf; v: byte);
begin
  if b.n >= Length(b.data) then
    SetLength(b.data, (b.n + 1) * 2);
  b.data[b.n] := v;
  inc(b.n);
end;

procedure BU16(var b: TBuf; v: word);
begin
  BByte(b, v and $FF);
  BByte(b, (v shr 8) and $FF);
end;

procedure BU32(var b: TBuf; v: longword);
begin
  BByte(b, v and $FF);
  BByte(b, (v shr 8) and $FF);
  BByte(b, (v shr 16) and $FF);
  BByte(b, (v shr 24) and $FF);
end;

procedure BName(var b: TBuf; const s: string; len: longint);
var
  i: longint;
begin
  for i := 1 to len do
    if i <= Length(s) then
      BByte(b, ord(s[i]))
    else
      BByte(b, 0);
end;

procedure BFinish(var b: TBuf);
begin
  SetLength(b.data, b.n);
end;

function EncodeMap(const m: TMapData): TByteArray;
var
  b: TBuf;
  i: longint;
begin
  BInit(b);
  BU32(b, MAP_MAGIC);
  BU16(b, MAP_VERSION);
  BU16(b, m.w);
  BU16(b, m.h);
  BByte(b, m.tileset);
  BByte(b, m.music);
  BByte(b, m.flags);
  BByte(b, 0);
  for i := 0 to m.w * m.h - 1 do
    BByte(b, m.walls[i]);

  BU16(b, Length(m.markers));
  for i := 0 to High(m.markers) do begin
    BName(b, m.markers[i].name, 12);
    BU16(b, m.markers[i].x);
    BU16(b, m.markers[i].y);
    BByte(b, m.markers[i].dir);
    BByte(b, 0);
  end;

  BU16(b, Length(m.portals));
  for i := 0 to High(m.portals) do begin
    BU16(b, m.portals[i].x);
    BU16(b, m.portals[i].y);
    BName(b, m.portals[i].target, 12);
    BName(b, m.portals[i].marker, 12);
  end;

  BU16(b, Length(m.doors));
  for i := 0 to High(m.doors) do begin
    BU16(b, m.doors[i].x);
    BU16(b, m.doors[i].y);
    BByte(b, m.doors[i].locked);
    BByte(b, 0);
    BName(b, m.doors[i].key, 12);
  end;

  BU16(b, Length(m.npcs));
  for i := 0 to High(m.npcs) do begin
    BU16(b, m.npcs[i].x);
    BU16(b, m.npcs[i].y);
    BName(b, m.npcs[i].dialog, 12);
    BName(b, m.npcs[i].name, 12);
  end;

  BU16(b, Length(m.traps));
  for i := 0 to High(m.traps) do begin
    BU16(b, m.traps[i].x);
    BU16(b, m.traps[i].y);
    BByte(b, m.traps[i].dmg);
    BByte(b, m.traps[i].dc);
  end;

  BFinish(b);
  EncodeMap := b.data;
end;

{ ---- readers ---- }

type
  TRdr = record
    data: TByteArray;
    p: longint;
    ok: boolean;
  end;

procedure RInit(out r: TRdr; const d: TByteArray);
begin
  r.data := d;
  r.p := 0;
  r.ok := true;
end;

function RByte(var r: TRdr): byte;
begin
  if r.p >= Length(r.data) then begin
    r.ok := false;
    RByte := 0;
  end else begin
    RByte := r.data[r.p];
    inc(r.p);
  end;
end;

function RU16(var r: TRdr): word;
var
  lo, hi: byte;
begin
  lo := RByte(r);
  hi := RByte(r);
  RU16 := lo or (hi shl 8);
end;

function RU32(var r: TRdr): longword;
var
  a, b, c, d: byte;
begin
  a := RByte(r); b := RByte(r); c := RByte(r); d := RByte(r);
  RU32 := a or (b shl 8) or (c shl 16) or (longword(d) shl 24);
end;

function RName(var r: TRdr; len: longint): string;
var
  i: longint;
  ch: byte;
  s: string;
begin
  s := '';
  for i := 1 to len do begin
    ch := RByte(r);
    if ch <> 0 then
      s := s + chr(ch);
  end;
  RName := s;
end;

function DecodeMap(const blob: TByteArray; out m: TMapData): boolean;
var
  r: TRdr;
  i, count: longint;
begin
  DecodeMap := false;
  m.w := 0; m.h := 0;
  m.walls := nil; m.markers := nil; m.portals := nil; m.doors := nil;
  m.npcs := nil; m.traps := nil;
  RInit(r, blob);
  if RU32(r) <> MAP_MAGIC then exit;
  if RU16(r) <> MAP_VERSION then exit;
  m.w := RU16(r);
  m.h := RU16(r);
  m.tileset := RByte(r);
  m.music := RByte(r);
  m.flags := RByte(r);
  RByte(r);  { reserved }
  if (m.w <= 0) or (m.h <= 0) then exit;

  SetLength(m.walls, m.w * m.h);
  for i := 0 to m.w * m.h - 1 do
    m.walls[i] := RByte(r);

  count := RU16(r);
  SetLength(m.markers, count);
  for i := 0 to count - 1 do begin
    m.markers[i].name := RName(r, 12);
    m.markers[i].x := RU16(r);
    m.markers[i].y := RU16(r);
    m.markers[i].dir := RByte(r);
    RByte(r);
  end;

  count := RU16(r);
  SetLength(m.portals, count);
  for i := 0 to count - 1 do begin
    m.portals[i].x := RU16(r);
    m.portals[i].y := RU16(r);
    m.portals[i].target := RName(r, 12);
    m.portals[i].marker := RName(r, 12);
  end;

  count := RU16(r);
  SetLength(m.doors, count);
  for i := 0 to count - 1 do begin
    m.doors[i].x := RU16(r);
    m.doors[i].y := RU16(r);
    m.doors[i].locked := RByte(r);
    RByte(r);
    m.doors[i].key := RName(r, 12);
  end;

  count := RU16(r);
  SetLength(m.npcs, count);
  for i := 0 to count - 1 do begin
    m.npcs[i].x := RU16(r);
    m.npcs[i].y := RU16(r);
    m.npcs[i].dialog := RName(r, 12);
    m.npcs[i].name := RName(r, 12);
  end;

  count := RU16(r);
  SetLength(m.traps, count);
  for i := 0 to count - 1 do begin
    m.traps[i].x := RU16(r);
    m.traps[i].y := RU16(r);
    m.traps[i].dmg := RByte(r);
    m.traps[i].dc := RByte(r);
  end;

  DecodeMap := r.ok;
end;

end.
