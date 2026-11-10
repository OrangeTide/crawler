program t_carve;

{** Carve-and-clad generation: KitModule reads the baked kit footprints,
  CarveLevel produces a connected level whose every open cell sits in a whole
  module block of one sector (so the cladding draws native pieces with no
  fillers) and is deterministic from its seed, and RepairToModule conforms a
  ragged, partly disconnected grid to the module while keeping it connected and
  relocating a stranded marker. }

{$mode objfpc}{$H+}

uses
  sysutils, pak, mapfmt, tilekit, rng, gridgen, carve, testing;

{ Count the open cells of a map. }
function OpenCount(const m: TMapData): longint;
var i, n: longint;
begin
  n := 0;
  for i := 0 to m.w * m.h - 1 do
    if m.walls[i] = 0 then inc(n);
  OpenCount := n;
end;

{ The first open cell, scanning row major. }
function FirstOpen(const m: TMapData; out sx, sy: longint): boolean;
var x, y: longint;
begin
  FirstOpen := false;
  for y := 0 to m.h - 1 do
    for x := 0 to m.w - 1 do
      if m.walls[y * m.w + x] = 0 then begin
        sx := x; sy := y; FirstOpen := true; exit;
      end;
end;

{ How many open cells are reachable from (sx,sy), via the grid flood. }
function FloodReach(const m: TMapData; sx, sy: longint): longint;
var
  g: TGrid;
  i, ex, ey, reach: longint;
begin
  gw := m.w; gh := m.h;
  SetLength(g, gw * gh);
  for i := 0 to gw * gh - 1 do
    if m.walls[i] = 0 then g[i] := 0 else g[i] := 1;
  FloodFarthest(g, sx, sy, ex, ey, reach);
  FloodReach := reach;
end;

{ Whether every open cell sits in a fully open, single-sector N-block anchored
  to the world grid: exactly the cladding's native-piece condition. }
function Claddable(const m: TMapData; modN: longint): boolean;
var
  tx, ty, ax, ay, rx, ry, j: longint;
  s0: byte;
begin
  Claddable := false;
  for ty := 0 to m.h - 1 do
    for tx := 0 to m.w - 1 do begin
      if m.walls[ty * m.w + tx] <> 0 then continue;
      s0 := m.cellSector[ty * m.w + tx];
      ax := (tx div modN) * modN;
      ay := (ty div modN) * modN;
      for ry := ay to ay + modN - 1 do
        for rx := ax to ax + modN - 1 do begin
          if (rx >= m.w) or (ry >= m.h) then exit;   { block falls off the map }
          j := ry * m.w + rx;
          if m.walls[j] <> 0 then exit;              { block not fully open }
          if m.cellSector[j] <> s0 then exit;        { block not one sector }
        end;
    end;
  Claddable := true;
end;

{ Whether two maps have identical wall and sector grids. }
function SameGrid(const a, b: TMapData): boolean;
var i: longint;
begin
  SameGrid := false;
  if (a.w <> b.w) or (a.h <> b.h) then exit;
  for i := 0 to a.w * a.h - 1 do begin
    if a.walls[i] <> b.walls[i] then exit;
    if a.cellSector[i] <> b.cellSector[i] then exit;
  end;
  SameGrid := true;
end;

{ A deliberately ragged map for the repair pass: one large off-grid room, a
  one-cell corridor, and a separate blob disconnected from the room. 20x20, a
  multiple of 4, so the conform does not shrink it. }
procedure BuildRagged(out m: TMapData);
var x, y, i: longint;
begin
  m.w := 20; m.h := 20;
  m.tileset := TILESET_GROTTO; m.music := 0; m.flags := 0; m.area := 0;
  m.heightLump := ''; m.heightZMin := 0; m.heightZMax := 0;
  SetLength(m.walls, m.w * m.h);
  SetLength(m.cellSector, m.w * m.h);
  for i := 0 to m.w * m.h - 1 do begin
    m.walls[i] := 1; m.cellSector[i] := SECTOR_NONE;
  end;
  SetLength(m.sectors, 1);
  m.sectors[0].floorZ := 0; m.sectors[0].ceilZ := HZ_UNIT;
  m.sectors[0].tileset := 0; m.sectors[0].light := 0;

  m.markers := nil; m.portals := nil; m.doors := nil; m.npcs := nil;
  m.traps := nil; m.lights := nil; m.props := nil; m.loot := nil;
  m.triggers := nil; m.pillars := nil; m.foliage := nil;

  { the room, off the 4-grid at origin 2 }
  for y := 2 to 13 do
    for x := 2 to 13 do begin
      m.walls[y * m.w + x] := 0; m.cellSector[y * m.w + x] := 0;
    end;
  { a one-cell corridor east of the room, a sub-module notch to be dropped }
  for x := 14 to 17 do begin
    m.walls[8 * m.w + x] := 0; m.cellSector[8 * m.w + x] := 0;
  end;
  { a blob in the far corner, disconnected from the room }
  for y := 16 to 18 do
    for x := 16 to 18 do begin
      m.walls[y * m.w + x] := 0; m.cellSector[y * m.w + x] := 0;
    end;

  { a marker on the corridor cell, which the conform solidifies }
  SetLength(m.markers, 1);
  m.markers[0].name := 'start';
  m.markers[0].x := 16; m.markers[0].y := 8; m.markers[0].dir := DIR_E;
end;

var
  p: TPak;
  m, m2, rag: TMapData;
  modN, sx, sy: longint;
begin
  Check(PakLoad('build/game.pak', p), 'load build/game.pak (run make first)');
  Check(LoadKits(p), 'load the baked kits');

  { KitModule reads the baked footprints }
  CheckEqI(KitModule(TILESET_MODULAR), 3, 'the mausoleum module is 3');
  CheckEqI(KitModule(TILESET_GROTTO), 4, 'the grotto module is 4');
  CheckEqI(KitModule(0), 1, 'a tileset with no kit has module 1');

  { CarveStyleFor picks a fitting style per kit }
  CheckEqI(CarveStyleFor(TILESET_MODULAR), CARVE_ROOMS, 'the crypt carves rooms');
  CheckEqI(CarveStyleFor(TILESET_GROTTO), CARVE_CAVE, 'the grotto carves a cave');
  CheckEqI(CarveStyleFor(TILESET_CATHEDRAL), CARVE_CATHEDRAL,
    'the cathedral carves bays');

  { CarveLevel on the mausoleum kit (N=3), rooms }
  m := CarveLevel($1234, TILESET_MODULAR, 3, CARVE_ROOMS);
  modN := 3;
  Check((m.w mod modN = 0) and (m.h mod modN = 0),
    'the carved mausoleum spans whole modules');
  Check(OpenCount(m) > 0, 'the carved mausoleum has open floor');
  Check(FirstOpen(m, sx, sy), 'it has a first open cell');
  CheckEqI(FloodReach(m, sx, sy), OpenCount(m),
    'the carved mausoleum is one connected space');
  Check(Claddable(m, modN), 'every mausoleum cell clads from a native block');

  { deterministic from the seed }
  m2 := CarveLevel($1234, TILESET_MODULAR, 3, CARVE_ROOMS);
  Check(SameGrid(m, m2), 'the same seed carves the same mausoleum');
  m2 := CarveLevel($9999, TILESET_MODULAR, 3, CARVE_ROOMS);
  Check(not SameGrid(m, m2), 'a different seed carves a different mausoleum');

  { CarveLevel on the grotto kit (N=4), an organic cave }
  m := CarveLevel($ABCD, TILESET_GROTTO, 4, CARVE_CAVE);
  modN := 4;
  Check((m.w mod modN = 0) and (m.h mod modN = 0),
    'the carved grotto spans whole modules');
  Check(OpenCount(m) > 0, 'the carved grotto has open floor');
  Check(FirstOpen(m, sx, sy), 'the grotto has a first open cell');
  CheckEqI(FloodReach(m, sx, sy), OpenCount(m),
    'the carved grotto cave is one connected space');
  Check(Claddable(m, modN), 'every grotto cell clads from a native block');

  { CarveLevel on the cathedral kit (N=8), cruciform bays }
  m := CarveLevel($CA7, TILESET_CATHEDRAL, 3, CARVE_CATHEDRAL);
  modN := 8;
  Check((m.w mod modN = 0) and (m.h mod modN = 0),
    'the carved cathedral spans whole modules');
  Check(OpenCount(m) > 0, 'the carved cathedral has open floor');
  Check(FirstOpen(m, sx, sy), 'the cathedral has a first open cell');
  CheckEqI(FloodReach(m, sx, sy), OpenCount(m),
    'the carved cathedral is one connected space');
  Check(Claddable(m, modN), 'every cathedral cell clads from a native block');

  { RepairToModule conforms a ragged, partly disconnected grid }
  BuildRagged(rag);
  Check(RepairToModule(rag, 4), 'the repair pass runs on the ragged map');
  Check(Claddable(rag, 4), 'the repaired grid clads from native blocks');
  Check(FirstOpen(rag, sx, sy), 'the repaired grid still has open floor');
  CheckEqI(FloodReach(rag, sx, sy), OpenCount(rag),
    'the repair reconnects the stranded blob');
  Check(rag.walls[rag.markers[0].y * rag.w + rag.markers[0].x] = 0,
    'the stranded marker is relocated onto open floor');

  TestSummary('carve');
  halt(TestExit);
end.
