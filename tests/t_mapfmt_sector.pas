program t_mapfmt_sector;

{** The map codec's sector layer. A map carries a sector table (floor and
  ceiling heights) and one sector id per cell over the wall grid. Confirm the
  layer round-trips through EncodeMap/DecodeMap, that the wall grid is
  untouched, and that EnsureSectors gives a sector-less map the flat default
  (one room, every open cell assigned, solid cells left out). }

{$mode objfpc}{$H+}

uses
  pak, mapfmt, testing;

{ A 3x2 map: a solid border on row 0, open floor on row 1 with a door. }
procedure MakeMap(out m: TMapData);
begin
  m.w := 3; m.h := 2;
  m.tileset := 1; m.music := 0; m.flags := 0; m.area := 0;
  SetLength(m.walls, 6);
  m.walls[0] := 2; m.walls[1] := 2; m.walls[2] := 2;    { row 0: stone wall }
  m.walls[3] := TILE_EMPTY; m.walls[4] := TILE_DOOR; m.walls[5] := TILE_EMPTY;
  m.sectors := nil; m.cellSector := nil;
  m.markers := nil; m.portals := nil; m.doors := nil; m.npcs := nil;
  m.traps := nil; m.lights := nil; m.props := nil; m.loot := nil;
end;

var
  m, back: TMapData;
  blob: TByteArray;
  i: longint;
  wallsSame: boolean;
begin
  { --- two authored sectors round-trip --- }
  MakeMap(m);
  SetLength(m.sectors, 2);
  m.sectors[0].floorZ := 0;  m.sectors[0].ceilZ := 16;
  m.sectors[0].tileset := 0; m.sectors[0].light := 0;
  m.sectors[1].floorZ := -8; m.sectors[1].ceilZ := 24;   { a sunken, taller room }
  m.sectors[1].tileset := 3; m.sectors[1].light := 2;
  SetLength(m.cellSector, 6);
  for i := 0 to 5 do
    if CellHasSector(m.walls[i]) then m.cellSector[i] := 1 else m.cellSector[i] := SECTOR_NONE;

  blob := EncodeMap(m);
  Check(DecodeMap(blob, back), 'a sector map decodes');
  CheckEqI(Length(back.sectors), 2, 'the sector count survives');
  CheckEqI(back.sectors[1].floorZ, -8, 'a signed floor height survives');
  CheckEqI(back.sectors[1].ceilZ, 24, 'the ceiling height survives');
  CheckEqI(back.sectors[1].tileset, 3, 'the sector tileset survives');
  CheckEqI(back.sectors[1].light, 2, 'the sector light survives');
  CheckEqI(Length(back.cellSector), 6, 'cellSector is one id per cell');
  CheckEqI(back.cellSector[0], SECTOR_NONE, 'a solid cell has no sector');
  CheckEqI(back.cellSector[3], 1, 'an open cell keeps its sector');
  CheckEqI(back.cellSector[4], 1, 'a door cell keeps its sector');

  wallsSame := Length(back.walls) = 6;
  if wallsSame then
    for i := 0 to 5 do if back.walls[i] <> m.walls[i] then wallsSame := false;
  Check(wallsSame, 'the wall grid is unchanged by the sector layer');

  { --- EnsureSectors fills a flat default for a sector-less map --- }
  MakeMap(m);
  EnsureSectors(m);
  CheckEqI(Length(m.sectors), 1, 'EnsureSectors adds one default sector');
  CheckEqI(m.sectors[0].floorZ, 0, 'the default floor is 0');
  CheckEqI(m.sectors[0].ceilZ, HZ_UNIT, 'the default ceiling is one unit');
  CheckEqI(Length(m.cellSector), 6, 'EnsureSectors sizes cellSector');
  CheckEqI(m.cellSector[0], SECTOR_NONE, 'a solid cell is left out');
  CheckEqI(m.cellSector[3], 0, 'an open cell joins the default sector');
  CheckEqI(m.cellSector[4], 0, 'a door cell joins the default sector');

  TestSummary('mapfmt_sector');
  halt(TestExit);
end.
