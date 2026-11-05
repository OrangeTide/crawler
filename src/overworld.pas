unit overworld;

{** The seeded overworld.

  The world is a 1024x1024 grid of cells, one square kilometer each, one
  biome per cell. Nothing is stored. Every cell is derived on demand from
  the world seed and its coordinates, so the whole world costs only the
  seed in the save. A cell is addressed by the synthesized map name
  'W<cx>_<cy>', which the map loader recognizes and routes here.

  A few authored zones are pinned to fixed cells. When the party would
  enter a pinned cell, the loader uses the authored map instead of a
  generated one, and neighbor cells link back to it by name. }

{$mode objfpc}{$H+}

interface

const
  OW_SIZE = 1024;          { cells per side }
  SUNLESS_DEPTH = 30;      { a dungeon this deep breaks into the Depths }

  { Surface biome ids. BiomeAt returns one of these for every cell. }
  BIOME_OCEAN    = 0;   { sea travel, coastlines, sea cliffs }
  BIOME_COAST    = 1;   { beaches and cliffs at the ocean edge }
  BIOME_ARBOREAL = 2;   { rivers, forest and grassland, temperate }
  BIOME_SWAMP    = 3;
  BIOME_HILLS    = 4;
  BIOME_MOUNT    = 5;
  BIOME_DESERT   = 6;   { sand, oases, ruins }
  BIOME_ARCTIC   = 7;   { arctic wasteland }
  BIOME_BASALT   = 8;   { basalt wastes around the volcanic highlands }
  BIOME_VOLCAN   = 9;
  BIOME_COUNT    = 10;

  { Underground themes, used to flavor the dungeon levels beneath a
    surface cell (vertical space, build-order step 16). BiomeAt never
    returns these; BiomeTheme maps a surface biome to one. }
  THEME_CAVE       = 0;
  THEME_CRYPT      = 1;
  THEME_DESERTTOMB = 2;   { dusty tomb beneath the desert }
  THEME_UNDERWATER = 3;   { ocean floor and shipwrecks beneath the sea }
  THEME_BASALT     = 4;   { lava tubes beneath basalt and volcanic cells }

var
  WorldSeed: longword = $1A2B3C4D;   { later loaded from the save }

{ Names and parsing of overworld cell map names. }
function CellName(cx, cy: longint): string;
function ParseCellName(const s: string; out cx, cy: longint): boolean;

{ Deterministic per-cell seed for terrain generation. }
function CellSeed(cx, cy, depth: longint): longword;

{ The biome that covers a cell. }
function BiomeAt(cx, cy: longint): byte;
function BiomeName(b: byte): string;
function BiomeWallTile(b: byte): byte;    { 1 brick, 2 stone, 3 moss }
function BiomeDensity(b: byte): longint;  { obstacle clusters per cell }
function BiomeTheme(b: byte): byte;       { underground theme under a cell }

{ Names of the generated layers beneath a cell. }
function DungeonName(cx, cy, depth: longint): string;
function ParseDungeonName(const s: string; out cx, cy, depth: longint): boolean;
function DepthsName(cx, cy: longint): string;
function ParseDepthsName(const s: string; out cx, cy: longint): boolean;

{ Names of the building interiors reached from a surface cell. }
function InteriorName(cx, cy, idx: longint): string;
function ParseInteriorName(const s: string; out cx, cy, idx: longint): boolean;

{ Whether a surface cell has a dungeon entrance, derived from the seed. }
function HasDungeon(cx, cy: longint): boolean;

{ Whether a surface cell has a building to enter, derived from the seed. }
function HasBuilding(cx, cy: longint): boolean;

{ Pinned authored cells. }
function PinnedAt(cx, cy: longint; out name, arrive: string): boolean;

implementation

uses
  sysutils, math;

type
  TPinned = record
    cx, cy: longint;
    name: string[12];
    arrive: string[12];
  end;

const
  { TOWN is the hub. The other authored zones cluster around it so the
    wilderness that borders the cluster links straight into them. Each
    name is an authored map (CAVE is a generated dynmap); each arrive
    marker exists on that map. }
  Pinned: array[0 .. 5] of TPinned = (
    (cx: 512; cy: 512; name: 'TOWN';     arrive: 'spawn'),
    (cx: 511; cy: 512; name: 'FOREST';   arrive: 'start'),
    (cx: 513; cy: 512; name: 'SEASIDE';  arrive: 'start'),
    (cx: 512; cy: 513; name: 'DUNGEON';  arrive: 'start'),
    (cx: 511; cy: 513; name: 'CAVE';     arrive: 'start'),
    (cx: 513; cy: 513; name: 'INFERNAL'; arrive: 'start')
  );

{ --- integer hashing and value noise --- }

function Hash32(a: longword): longword; inline;
begin
  a := a xor (a shr 16);
  a := a * longword($7feb352d);
  a := a xor (a shr 15);
  a := a * longword($846ca68b);
  a := a xor (a shr 16);
  Hash32 := a;
end;

function Hash2(x, y, salt: longint): longword; inline;
begin
  Hash2 := Hash32(longword(x) * longword($9e3779b1)
    xor longword(y) * longword($85ebca6b)
    xor longword(salt) * longword($c2b2ae35)
    xor WorldSeed);
end;

function NodeVal(ix, iy, salt: longint): double; inline;
begin
  NodeVal := Hash2(ix, iy, salt) / 4294967296.0;
end;

function Smooth(t: double): double; inline;
begin
  Smooth := t * t * (3.0 - 2.0 * t);
end;

{ Bilinear value noise at a point, grid-node values hashed from the seed. }
function ValNoise(fx, fy: double; salt: longint): double;
var
  ix, iy: longint;
  tx, ty, v00, v10, v01, v11, a, b: double;
begin
  ix := longint(Floor(fx));
  iy := longint(Floor(fy));
  tx := Smooth(fx - ix);
  ty := Smooth(fy - iy);
  v00 := NodeVal(ix, iy, salt);
  v10 := NodeVal(ix + 1, iy, salt);
  v01 := NodeVal(ix, iy + 1, salt);
  v11 := NodeVal(ix + 1, iy + 1, salt);
  a := v00 + (v10 - v00) * tx;
  b := v01 + (v11 - v01) * tx;
  ValNoise := a + (b - a) * ty;
end;

function CellName(cx, cy: longint): string;
begin
  CellName := 'W' + IntToStr(cx) + '_' + IntToStr(cy);
end;

function ParseCellName(const s: string; out cx, cy: longint): boolean;
var
  i, us: longint;
  a, b: string;
begin
  ParseCellName := false;
  cx := 0; cy := 0;
  if (Length(s) < 4) or (s[1] <> 'W') then exit;
  us := 0;
  for i := 2 to Length(s) do begin
    if s[i] = '_' then begin
      if us <> 0 then exit;   { more than one underscore }
      us := i;
    end else if (s[i] < '0') or (s[i] > '9') then
      exit;                   { non-digit }
  end;
  if (us < 3) or (us = Length(s)) then exit;
  a := Copy(s, 2, us - 2);
  b := Copy(s, us + 1, Length(s) - us);
  cx := StrToInt(a);
  cy := StrToInt(b);
  ParseCellName := (cx >= 0) and (cx < OW_SIZE) and (cy >= 0) and (cy < OW_SIZE);
end;

function CellSeed(cx, cy, depth: longint): longword;
begin
  CellSeed := Hash32(longword(cx) * longword($9e3779b1)
    xor longword(cy) * longword($85ebca6b)
    xor longword(depth + 1) * longword($27d4eb2f)
    xor WorldSeed);
  if CellSeed = 0 then CellSeed := 1;
end;

function BiomeAt(cx, cy: longint): byte;
var
  e, m, t: double;
begin
  e := 0.55 * ValNoise(cx / 80.0, cy / 80.0, 1)
     + 0.30 * ValNoise(cx / 32.0, cy / 32.0, 2)
     + 0.15 * ValNoise(cx / 12.0, cy / 12.0, 3);
  m := ValNoise(cx / 60.0 + 100.0, cy / 60.0 + 100.0, 4);
  t := 0.5 * ValNoise(cx / 90.0, cy / 90.0, 5)
     + 0.5 * (1.0 - Abs(cy - 512) / 512.0);

  if e < 0.34 then
    BiomeAt := BIOME_OCEAN
  else if e < 0.39 then
    BiomeAt := BIOME_COAST
  else if e >= 0.66 then begin
    { highlands: a hot spike is a volcano, the hot dry skirt is basalt
      waste, otherwise bare mountains }
    if (t > 0.58) and (ValNoise(cx / 20.0, cy / 20.0, 9) > 0.68) then
      BiomeAt := BIOME_VOLCAN
    else if (t > 0.54) and (m < 0.34) then
      BiomeAt := BIOME_BASALT
    else
      BiomeAt := BIOME_MOUNT;
  end
  else if e >= 0.56 then
    BiomeAt := BIOME_HILLS
  else begin
    if t < 0.28 then
      BiomeAt := BIOME_ARCTIC
    else if (m < 0.30) and (t > 0.56) then
      BiomeAt := BIOME_DESERT
    else if m > 0.60 then
      BiomeAt := BIOME_SWAMP
    else
      BiomeAt := BIOME_ARBOREAL;
  end;
end;

function BiomeName(b: byte): string;
begin
  case b of
    BIOME_OCEAN:    BiomeName := 'OCEAN';
    BIOME_COAST:    BiomeName := 'COAST';
    BIOME_ARBOREAL: BiomeName := 'ARBOREAL';
    BIOME_SWAMP:    BiomeName := 'SWAMP';
    BIOME_HILLS:    BiomeName := 'HILLS';
    BIOME_MOUNT:    BiomeName := 'MOUNTAINS';
    BIOME_DESERT:   BiomeName := 'DESERT';
    BIOME_ARCTIC:   BiomeName := 'ARCTIC WASTE';
    BIOME_BASALT:   BiomeName := 'BASALT WASTE';
    BIOME_VOLCAN:   BiomeName := 'VOLCANIC';
  else
    BiomeName := 'WILDERNESS';
  end;
end;

function BiomeWallTile(b: byte): byte;
begin
  case b of
    BIOME_ARBOREAL, BIOME_SWAMP: BiomeWallTile := 3;   { moss, stands for trees }
    BIOME_DESERT, BIOME_VOLCAN: BiomeWallTile := 1;    { sandstone and lava rock }
  else
    BiomeWallTile := 2;                                { stone for rocky ground }
  end;
end;

function BiomeDensity(b: byte): longint;
begin
  case b of
    BIOME_OCEAN, BIOME_COAST, BIOME_DESERT, BIOME_ARCTIC: BiomeDensity := 3;
    BIOME_ARBOREAL: BiomeDensity := 7;
    BIOME_HILLS, BIOME_SWAMP, BIOME_BASALT, BIOME_VOLCAN: BiomeDensity := 8;
    BIOME_MOUNT: BiomeDensity := 12;
  else
    BiomeDensity := 6;
  end;
end;

function BiomeTheme(b: byte): byte;
begin
  case b of
    BIOME_OCEAN, BIOME_COAST: BiomeTheme := THEME_UNDERWATER;
    BIOME_DESERT:             BiomeTheme := THEME_DESERTTOMB;
    BIOME_VOLCAN, BIOME_BASALT: BiomeTheme := THEME_BASALT;
    BIOME_ARBOREAL, BIOME_SWAMP: BiomeTheme := THEME_CRYPT;
  else
    BiomeTheme := THEME_CAVE;
  end;
end;

{ Parse up to three underscore-separated non-negative integers from s. }
function ParseNums(const s: string; out n0, n1, n2: longint; out count: longint): boolean;
var
  i, cur: longint;
  started: boolean;
  nums: array[0 .. 2] of longint;
begin
  ParseNums := false;
  n0 := 0; n1 := 0; n2 := 0; count := 0;
  cur := 0; started := false;
  for i := 1 to Length(s) do begin
    if s[i] = '_' then begin
      if not started then exit;      { empty field }
      if count >= 3 then exit;
      nums[count] := cur; inc(count);
      cur := 0; started := false;
    end else if (s[i] >= '0') and (s[i] <= '9') then begin
      cur := cur * 10 + (ord(s[i]) - ord('0'));
      started := true;
    end else
      exit;                          { non-digit }
  end;
  if not started then exit;
  if count >= 3 then exit;
  nums[count] := cur; inc(count);
  n0 := nums[0];
  if count >= 2 then n1 := nums[1];
  if count >= 3 then n2 := nums[2];
  ParseNums := true;
end;

function DungeonName(cx, cy, depth: longint): string;
begin
  DungeonName := 'D' + IntToStr(cx) + '_' + IntToStr(cy) + '_' + IntToStr(depth);
end;

function ParseDungeonName(const s: string; out cx, cy, depth: longint): boolean;
var
  count: longint;
begin
  ParseDungeonName := false;
  cx := 0; cy := 0; depth := 0;
  if (Length(s) < 6) or (s[1] <> 'D') then exit;
  if not ParseNums(Copy(s, 2, Length(s) - 1), cx, cy, depth, count) then exit;
  if count <> 3 then exit;
  ParseDungeonName := (cx >= 0) and (cx < OW_SIZE) and (cy >= 0)
    and (cy < OW_SIZE) and (depth >= 1);
end;

function DepthsName(cx, cy: longint): string;
begin
  DepthsName := 'S' + IntToStr(cx) + '_' + IntToStr(cy);
end;

function ParseDepthsName(const s: string; out cx, cy: longint): boolean;
var
  dummy, count: longint;
begin
  ParseDepthsName := false;
  cx := 0; cy := 0;
  if (Length(s) < 4) or (s[1] <> 'S') then exit;
  if not ParseNums(Copy(s, 2, Length(s) - 1), cx, cy, dummy, count) then exit;
  if count <> 2 then exit;
  ParseDepthsName := (cx >= 0) and (cx < OW_SIZE) and (cy >= 0) and (cy < OW_SIZE);
end;

function InteriorName(cx, cy, idx: longint): string;
begin
  InteriorName := 'I' + IntToStr(cx) + '_' + IntToStr(cy) + '_' + IntToStr(idx);
end;

function ParseInteriorName(const s: string; out cx, cy, idx: longint): boolean;
var
  count: longint;
begin
  ParseInteriorName := false;
  cx := 0; cy := 0; idx := 0;
  if (Length(s) < 6) or (s[1] <> 'I') then exit;
  if not ParseNums(Copy(s, 2, Length(s) - 1), cx, cy, idx, count) then exit;
  if count <> 3 then exit;
  ParseInteriorName := (cx >= 0) and (cx < OW_SIZE) and (cy >= 0)
    and (cy < OW_SIZE) and (idx >= 0);
end;

function HasDungeon(cx, cy: longint): boolean;
var
  salt: longint;
begin
  { about one surface cell in three has a way down, pinned cells aside }
  salt := $D0;
  HasDungeon := (Hash2(cx, cy, salt) mod 3) = 0;
end;

function HasBuilding(cx, cy: longint): boolean;
var
  salt: longint;
begin
  { about one surface cell in four has a building you can enter }
  salt := $B1;
  HasBuilding := (Hash2(cx, cy, salt) mod 4) = 1;
end;

function PinnedAt(cx, cy: longint; out name, arrive: string): boolean;
var
  i: longint;
begin
  PinnedAt := false;
  name := ''; arrive := '';
  for i := 0 to High(Pinned) do
    if (Pinned[i].cx = cx) and (Pinned[i].cy = cy) then begin
      name := Pinned[i].name;
      arrive := Pinned[i].arrive;
      PinnedAt := true;
      exit;
    end;
end;

end.
