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
    area     u8
    walls    w*h bytes
    markerCount u16, markers [ name 12, x u16, y u16, dir u8, pad u8 ]
    portalCount u16, portals [ x u16, y u16, target 12, marker 12 ]
    doorCount   u16, doors   [ x u16, y u16, locked u8, pad u8, key 12 ] }

{$mode objfpc}{$H+}

interface

uses
  pak, beings;

const
  MAP_MAGIC   = $50414D43;  { 'CMAP' little-endian }
  MAP_VERSION = 12;         { 12 adds the event-trigger message string }

  MAP_SURFACE = 1;          { flags bit: an outdoor map, sees the sky }

  { Trigger-area kinds. A trigger is a polygon over the logical grid, decoupled
    from the geometry, that acts on the party while it stands inside. New kinds
    add here; the codec carries a byte kind and a word parameter either way. }
  TRIG_NONE      = 0;
  TRIG_ENCOUNTER = 1;       { param = the encounter table to roll inside }
  TRIG_AMBIENT   = 2;       { param = ambient light level (0..256) while inside }
  TRIG_EVENT     = 3;       { fire-on-enter once: set the flag `tag`, show `msg` }

  { Trigger polygon vertices are stored in 1/16 cell units, so an edge can fall
    between cells. One cell is TRIG_UNIT steps. }
  TRIG_UNIT   = 16;

  { Sector heights are stored in 1/16 world unit, so one world unit (the old
    flat floor-to-ceiling height) is HZ_UNIT steps. The default room is floor
    at 0 and ceiling at HZ_UNIT, which renders exactly like the old flat grid. }
  HZ_UNIT     = 16;         { one world unit, in height steps }
  SECTOR_NONE = 255;        { a solid wall cell belongs to no sector }

  { Tile semantics in the walls grid: 0 is open floor, a door tile holds
    the door texture value, any other value is a solid wall. These live
    here with the map format so non-render code (pathfinding, tools) can
    read a grid without the texture or runtime units. }
  TILE_EMPTY = 0;
  TILE_DOOR  = 4;

  { The dedicated modular-kit tileset, past the biome tilesets 0..9. A map or
    sector that points here clads from a kit; it is tied to no biome, so
    nothing clads by accident. Lives with the map format so the generators
    can select it without pulling in the texture unit. }
  TILESET_MODULAR = 10;
  TILESET_CATHEDRAL = 11;
  TILESET_TEMPLE = 12;

  { Celestial light wells: their strength tracks the sky (section 22). }
  LIGHT_SKYLIGHT = 0;       { admits sunlight by day }
  LIGHT_MOONWELL = 1;       { admits moonlight, strongest at the full moon }

  { Emissive sources: always on, and they cast a pool of light nearby.
    LIGHT_EMISSIVE is the first emissive kind, so kinds at or above it are
    the always-on lights and kinds below it are the celestial wells. }
  LIGHT_EMISSIVE = 2;
  LIGHT_BIOLUME  = 2;       { bioluminescent growth, natural cavern glow }
  LIGHT_GASVENT  = 3;       { a small vent, a faint flame }
  LIGHT_BRAZIER  = 4;       { a tended brazier at a camp or tomb }
  LIGHT_TORCH    = 5;       { a wall torch }
  LIGHT_BONFIRE  = 6;       { a large fire at a settlement }

  { Portal transition kinds, for the right icon and glow. }
  PK_FLAT   = 0;            { a level transition, a gate or a cell edge }
  PK_DOWN   = 1;            { stairs down }
  PK_UP     = 2;            { stairs up }
  PK_CAVE   = 3;            { a cave mouth, surface down to a dungeon }
  PK_LADDER = 4;
  PK_SHAFT  = 5;            { a drop down a shaft }
  PK_DOOR   = 6;            { a door into an interior }

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
    kind: byte;           { PK_* transition kind }
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
    sprite: string[12];   { sprite lump name, empty for the default NPC art }
    gender: TGender;      { how the NPC identifies; default unspecified }
  end;

  TTrap = record
    x, y: word;
    dmg: byte;      { damage die sides on a failed save }
    dc: byte;       { Dodge save target }
    element: byte;  { EL_* the trap deals, 0 physical (a spike or dart) }
  end;

  TLightTile = record
    x, y: word;
    kind: byte;     { LIGHT_SKYLIGHT or LIGHT_MOONWELL }
  end;

  TProp = record
    x, y: word;
    name: string[12];   { model lump name, e.g. BARREL }
    yaw: byte;          { heading, 0..255 maps to a full turn }
  end;

  TLoot = record
    x, y: word;
    gold: word;         { coin in the cache }
    item: string[12];   { item kind lump name, empty for none }
    qty: byte;          { how many of the item }
  end;

  { A sector is a region of open cells sharing a floor and a ceiling height.
    Walls are the segments between sectors, or between a sector and a solid
    cell; the renderer derives them from cell adjacency. Movement stays on the
    wall grid, laid over the sectors and decoupled from this geometry. }
  TSector = packed record
    floorZ, ceilZ: smallint;   { height in 1/16 world unit }
    tileset: byte;             { 0 = the map's own tileset }
    light: byte;               { reserved; 0 = the per-cell light as today }
  end;

  { A polygon point in 1/16 cell units (TRIG_UNIT per cell). }
  TTrigPt = packed record
    x, y: smallint;
  end;

  { A trigger area: a polygon over the logical grid that acts on the party
    while it stands inside, decoupled from the geometry. }
  TTrigger = record
    kind: byte;           { TRIG_* }
    param: word;          { kind-specific, e.g. an encounter table number }
    tag: string[12];      { optional label or target, empty for none }
    msg: string[80];      { fire-on-enter event message, empty for none }
    verts: array of TTrigPt;
  end;

  TMapData = record
    w, h: longint;
    tileset, music, flags, area: byte;
    walls: array of byte;                 { w*h, row major }
    sectors: array of TSector;            { at least one; 0 is the default room }
    cellSector: array of byte;            { w*h; SECTOR_NONE for solid cells }
    markers: array of TMarker;
    portals: array of TPortal;
    doors: array of TDoorMeta;
    npcs: array of TNpc;
    traps: array of TTrap;
    lights: array of TLightTile;
    props: array of TProp;
    loot: array of TLoot;
    triggers: array of TTrigger;          { polygon trigger areas, may be empty }
  end;

function EncodeMap(const m: TMapData): TByteArray;
function DecodeMap(const blob: TByteArray; out m: TMapData): boolean;

{ Whether a cell value takes part in a sector (floor or door), as opposed to a
  permanently solid wall. }
function CellHasSector(v: byte): boolean;

{ Give a map a default flat sector layer when it has none: one sector (floor 0,
  ceiling one unit) with every open cell assigned to it and solid cells left
  out. A generator or the map compiler calls this after laying the wall grid to
  get the old flat look for free. It also resizes cellSector if it is missing. }
procedure EnsureSectors(var m: TMapData);

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
  i, j: longint;
begin
  BInit(b);
  BU32(b, MAP_MAGIC);
  BU16(b, MAP_VERSION);
  BU16(b, m.w);
  BU16(b, m.h);
  BByte(b, m.tileset);
  BByte(b, m.music);
  BByte(b, m.flags);
  BByte(b, m.area);
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
    BByte(b, m.portals[i].kind);
    BByte(b, 0);
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
    BName(b, m.npcs[i].sprite, 12);
    BByte(b, GenderToByte(m.npcs[i].gender));
  end;

  BU16(b, Length(m.lights));
  for i := 0 to High(m.lights) do begin
    BU16(b, m.lights[i].x);
    BU16(b, m.lights[i].y);
    BByte(b, m.lights[i].kind);
    BByte(b, 0);
  end;

  BU16(b, Length(m.traps));
  for i := 0 to High(m.traps) do begin
    BU16(b, m.traps[i].x);
    BU16(b, m.traps[i].y);
    BByte(b, m.traps[i].dmg);
    BByte(b, m.traps[i].dc);
    BByte(b, m.traps[i].element);
    BByte(b, 0);
  end;

  BU16(b, Length(m.props));
  for i := 0 to High(m.props) do begin
    BU16(b, m.props[i].x);
    BU16(b, m.props[i].y);
    BName(b, m.props[i].name, 12);
    BByte(b, m.props[i].yaw);
    BByte(b, 0);
  end;

  BU16(b, Length(m.loot));
  for i := 0 to High(m.loot) do begin
    BU16(b, m.loot[i].x);
    BU16(b, m.loot[i].y);
    BU16(b, m.loot[i].gold);
    BName(b, m.loot[i].item, 12);
    BByte(b, m.loot[i].qty);
    BByte(b, 0);
  end;

  { sector layer: the sector table then one sector id per cell }
  BU16(b, Length(m.sectors));
  for i := 0 to High(m.sectors) do begin
    BU16(b, word(m.sectors[i].floorZ));
    BU16(b, word(m.sectors[i].ceilZ));
    BByte(b, m.sectors[i].tileset);
    BByte(b, m.sectors[i].light);
  end;
  for i := 0 to m.w * m.h - 1 do
    if i < Length(m.cellSector) then
      BByte(b, m.cellSector[i])
    else
      BByte(b, SECTOR_NONE);

  { trigger layer: each a kind, a parameter, a tag, then its polygon }
  BU16(b, Length(m.triggers));
  for i := 0 to High(m.triggers) do begin
    BByte(b, m.triggers[i].kind);
    BU16(b, m.triggers[i].param);
    BName(b, m.triggers[i].tag, 12);
    BName(b, m.triggers[i].msg, 80);
    BU16(b, Length(m.triggers[i].verts));
    for j := 0 to High(m.triggers[i].verts) do begin
      BU16(b, word(m.triggers[i].verts[j].x));
      BU16(b, word(m.triggers[i].verts[j].y));
    end;
  end;

  BFinish(b);
  EncodeMap := b.data;
end;

function CellHasSector(v: byte): boolean;
begin
  CellHasSector := (v = TILE_EMPTY) or (v = TILE_DOOR);
end;

procedure EnsureSectors(var m: TMapData);
var
  i: longint;
begin
  if Length(m.cellSector) <> m.w * m.h then begin
    SetLength(m.cellSector, m.w * m.h);
    for i := 0 to m.w * m.h - 1 do
      if CellHasSector(m.walls[i]) then m.cellSector[i] := 0
      else m.cellSector[i] := SECTOR_NONE;
  end;
  if Length(m.sectors) = 0 then begin
    SetLength(m.sectors, 1);
    m.sectors[0].floorZ := 0;
    m.sectors[0].ceilZ := HZ_UNIT;
    m.sectors[0].tileset := 0;
    m.sectors[0].light := 0;
  end;
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
  i, j, count, vcount: longint;
begin
  DecodeMap := false;
  m.w := 0; m.h := 0;
  m.walls := nil; m.markers := nil; m.portals := nil; m.doors := nil;
  m.npcs := nil; m.traps := nil; m.lights := nil; m.props := nil;
  m.loot := nil; m.sectors := nil; m.cellSector := nil; m.triggers := nil;
  RInit(r, blob);
  if RU32(r) <> MAP_MAGIC then exit;
  if RU16(r) <> MAP_VERSION then exit;
  m.w := RU16(r);
  m.h := RU16(r);
  m.tileset := RByte(r);
  m.music := RByte(r);
  m.flags := RByte(r);
  m.area := RByte(r);
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
    m.portals[i].kind := RByte(r);
    RByte(r);
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
    m.npcs[i].sprite := RName(r, 12);
    m.npcs[i].gender := GenderFromByte(RByte(r));
  end;

  count := RU16(r);
  SetLength(m.lights, count);
  for i := 0 to count - 1 do begin
    m.lights[i].x := RU16(r);
    m.lights[i].y := RU16(r);
    m.lights[i].kind := RByte(r);
    RByte(r);
  end;

  count := RU16(r);
  SetLength(m.traps, count);
  for i := 0 to count - 1 do begin
    m.traps[i].x := RU16(r);
    m.traps[i].y := RU16(r);
    m.traps[i].dmg := RByte(r);
    m.traps[i].dc := RByte(r);
    m.traps[i].element := RByte(r);
    RByte(r);
  end;

  count := RU16(r);
  SetLength(m.props, count);
  for i := 0 to count - 1 do begin
    m.props[i].x := RU16(r);
    m.props[i].y := RU16(r);
    m.props[i].name := RName(r, 12);
    m.props[i].yaw := RByte(r);
    RByte(r);
  end;

  count := RU16(r);
  SetLength(m.loot, count);
  for i := 0 to count - 1 do begin
    m.loot[i].x := RU16(r);
    m.loot[i].y := RU16(r);
    m.loot[i].gold := RU16(r);
    m.loot[i].item := RName(r, 12);
    m.loot[i].qty := RByte(r);
    RByte(r);
  end;

  count := RU16(r);
  SetLength(m.sectors, count);
  for i := 0 to count - 1 do begin
    m.sectors[i].floorZ := smallint(RU16(r));
    m.sectors[i].ceilZ := smallint(RU16(r));
    m.sectors[i].tileset := RByte(r);
    m.sectors[i].light := RByte(r);
  end;
  SetLength(m.cellSector, m.w * m.h);
  for i := 0 to m.w * m.h - 1 do
    m.cellSector[i] := RByte(r);

  count := RU16(r);
  SetLength(m.triggers, count);
  for i := 0 to count - 1 do begin
    m.triggers[i].kind := RByte(r);
    m.triggers[i].param := RU16(r);
    m.triggers[i].tag := RName(r, 12);
    m.triggers[i].msg := RName(r, 80);
    vcount := RU16(r);
    SetLength(m.triggers[i].verts, vcount);
    for j := 0 to vcount - 1 do begin
      m.triggers[i].verts[j].x := smallint(RU16(r));
      m.triggers[i].verts[j].y := smallint(RU16(r));
    end;
  end;

  { belt and braces: a map that somehow lacks a sector table gets the flat
    default so the renderer always has heights to read. Clearing cellSector
    first forces a rebuild from the wall grid in that case. }
  if r.ok then begin
    if Length(m.sectors) = 0 then m.cellSector := nil;
    EnsureSectors(m);
  end;

  DecodeMap := r.ok;
end;

end.
