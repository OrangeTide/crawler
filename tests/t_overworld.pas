program t_overworld;

{** The seeded overworld: names, biome determinism and spread, and the
  generated cell structure (reachable edge portals). }

{$mode objfpc}{$H+}

uses
  overworld, worldname, mapfmt, mapgen, testing;

{ Flood from (sx,sy) over floor tiles; true if (tx,ty) is reached. }
function Reaches(const m: TMapData; sx, sy, tx, ty: longint): boolean;
var
  seen: array of boolean;
  st: array of longint;
  sp, idx, x, y, i: longint;

  function Fl(ix, iy: longint): boolean;
  begin
    Fl := (ix >= 0) and (ix < m.w) and (iy >= 0) and (iy < m.h)
      and (m.walls[iy * m.w + ix] = 0);
  end;

  procedure Push(ix, iy: longint);
  begin
    if Fl(ix, iy) and (not seen[iy * m.w + ix]) then begin
      seen[iy * m.w + ix] := true;
      st[sp] := iy * m.w + ix;
      inc(sp);
    end;
  end;

begin
  SetLength(seen, m.w * m.h);
  SetLength(st, m.w * m.h);
  for i := 0 to m.w * m.h - 1 do seen[i] := false;
  sp := 0;
  Push(sx, sy);
  while sp > 0 do begin
    dec(sp);
    idx := st[sp];
    x := idx mod m.w; y := idx div m.w;
    Push(x + 1, y); Push(x - 1, y); Push(x, y + 1); Push(x, y - 1);
  end;
  Reaches := Fl(tx, ty) and seen[ty * m.w + tx];
end;

var
  cx, cy, i, startX, startY, allReach, distinct, idx: longint;
  m: TMapData;
  seenBiome: array[0 .. BIOME_COUNT - 1] of boolean;
  x, y, bx, by, doors, entryX, entryY: longint;
  nm, arr: string;
  found: boolean;
begin
  { name round trip and rejection }
  Check(CellName(300, 712) = 'W300_712', 'CellName format');
  Check(ParseCellName('W300_712', cx, cy) and (cx = 300) and (cy = 712),
    'ParseCellName round trip');
  Check(not ParseCellName('TOWN', cx, cy), 'reject non-cell name');
  Check(not ParseCellName('W1_2_3', cx, cy), 'reject extra field');
  Check(not ParseCellName('W9999_0', cx, cy), 'reject out of range');

  { biomes are deterministic and spread across the world }
  CheckEqI(BiomeAt(600, 600), BiomeAt(600, 600), 'biome deterministic');
  for i := 0 to BIOME_COUNT - 1 do seenBiome[i] := false;
  y := 0;
  while y < OW_SIZE do begin
    x := 0;
    while x < OW_SIZE do begin
      seenBiome[BiomeAt(x, y)] := true;
      inc(x, 16);
    end;
    inc(y, 16);
  end;
  distinct := 0;
  for i := 0 to BIOME_COUNT - 1 do if seenBiome[i] then inc(distinct);
  Check(distinct >= 8, 'at least 8 biomes occur across the world');

  { a generated cell: every edge portal reachable from the start marker }
  m := GenerateOverworldCell(700, 300, CellSeed(700, 300, 0));
  startX := m.w div 2; startY := m.h div 2;
  for i := 0 to High(m.markers) do
    if m.markers[i].name = 'start' then begin
      startX := m.markers[i].x; startY := m.markers[i].y;
    end;
  Check(Length(m.portals) >= 1, 'cell has edge portals');
  allReach := 0;
  for i := 0 to High(m.portals) do
    if Reaches(m, startX, startY, m.portals[i].x, m.portals[i].y) then
      inc(allReach);
  CheckEqI(allReach, Length(m.portals), 'all cell portals reachable');

  { the authored zones are pinned around the town, each with its marker }
  Check(PinnedAt(512, 512, nm, arr) and (nm = 'TOWN') and (arr = 'spawn'),
    'TOWN pinned at the world centre');
  Check(PinnedAt(511, 512, nm, arr) and (nm = 'FOREST'), 'FOREST pinned west');
  Check(PinnedAt(513, 512, nm, arr) and (nm = 'SEASIDE'), 'SEASIDE pinned east');
  Check(PinnedAt(512, 513, nm, arr) and (nm = 'DUNGEON'), 'DUNGEON pinned south');
  Check(PinnedAt(511, 513, nm, arr) and (nm = 'CAVE'), 'CAVE pinned southwest');
  Check(PinnedAt(513, 513, nm, arr) and (nm = 'INFERNAL'), 'INFERNAL pinned');
  Check(not PinnedAt(700, 300, nm, arr), 'wilderness is not pinned');

  { interior name round trip }
  Check(InteriorName(40, 50, 2) = 'I40_50_2', 'InteriorName format');
  Check(ParseInteriorName('I40_50_2', cx, cy, idx)
    and (cx = 40) and (cy = 50) and (idx = 2), 'ParseInteriorName round trip');
  Check(not ParseInteriorName('W1_2_3', cx, cy, idx), 'reject non-interior name');

  { find a cell with a building and check its door leads to an interior }
  found := false; bx := 0; by := 0;
  y := 400;
  while (y < 460) and (not found) do begin
    x := 400;
    while (x < 460) and (not found) do begin
      if HasBuilding(x, y) then begin bx := x; by := y; found := true; end;
      inc(x);
    end;
    inc(y);
  end;
  Check(found, 'some cell has a building');

  if found then begin
    m := GenerateOverworldCell(bx, by, CellSeed(bx, by, 0));
    startX := m.w div 2; startY := m.h div 2;
    doors := 0;
    for i := 0 to High(m.portals) do
      if m.portals[i].kind = PK_DOOR then begin
        inc(doors);
        Check(m.portals[i].target = InteriorName(bx, by, 0),
          'cell door targets its interior');
        Check(Reaches(m, startX, startY, m.portals[i].x, m.portals[i].y),
          'cell door is reachable from the centre');
      end;
    Check(doors >= 1, 'building cell has a door-portal');

    { the interior itself: a door back to the cell, reachable from entry }
    m := GenerateInterior(bx, by, 0, CellSeed(bx, by, 0));
    Check((m.flags and MAP_SURFACE) = 0, 'interior is indoors, not surface');
    entryX := -1; entryY := -1;
    for i := 0 to High(m.markers) do
      if m.markers[i].name = 'entry' then begin
        entryX := m.markers[i].x; entryY := m.markers[i].y;
      end;
    Check(entryX >= 0, 'interior has an entry marker');
    doors := 0;
    for i := 0 to High(m.portals) do
      if m.portals[i].kind = PK_DOOR then begin
        inc(doors);
        Check(m.portals[i].target = CellName(bx, by),
          'interior door returns to the cell');
        if entryX >= 0 then
          Check(Reaches(m, entryX, entryY, m.portals[i].x, m.portals[i].y),
            'interior door reachable from entry');
      end;
    Check(doors >= 1, 'interior has a door back out');
  end;

  { the wilderness back door: a pinned zone that leaves only to the town
    gains a reachable exit into a neighbor cell, and that cell links back }
  m.w := 10; m.h := 8;
  SetLength(m.walls, m.w * m.h);
  for i := 0 to m.w * m.h - 1 do m.walls[i] := 0;
  for x := 0 to m.w - 1 do begin m.walls[x] := 1; m.walls[(m.h - 1) * m.w + x] := 1; end;
  for y := 0 to m.h - 1 do begin m.walls[y * m.w] := 1; m.walls[y * m.w + m.w - 1] := 1; end;
  m.flags := 0;   { underground zone, like DUNGEON }
  SetLength(m.markers, 1);
  m.markers[0].name := 'start'; m.markers[0].x := 2; m.markers[0].y := 2;
  m.markers[0].dir := DIR_E;
  SetLength(m.portals, 1);
  m.portals[0].x := 7; m.portals[0].y := 5;
  m.portals[0].target := 'TOWN'; m.portals[0].marker := 'gate';
  m.portals[0].kind := PK_UP;

  { DUNGEON is pinned at 512,513; its open neighbor is the cell to the south }
  Check(AddWildernessExit(m, 512, 513), 'pinned zone gains a wilderness exit');
  entryX := -1; entryY := -1;   { reuse: the wilderness-exit portal tile }
  nm := '';
  for i := 0 to High(m.portals) do
    if ParseCellName(m.portals[i].target, bx, by) then begin
      nm := m.portals[i].target; entryX := m.portals[i].x; entryY := m.portals[i].y;
      cx := bx; cy := by;
    end;
  Check(nm = CellName(512, 514), 'exit targets the south neighbor cell');
  Check(Reaches(m, 2, 2, entryX, entryY), 'wilderness exit reachable from start');
  Check(m.portals[0].target = 'TOWN', 'the town gate is still there');

  { the neighbor cell links back into the zone at the matching edge }
  m := GenerateOverworldCell(cx, cy, CellSeed(cx, cy, 0));
  found := false; entryX := -1;
  for i := 0 to High(m.portals) do
    if m.portals[i].target = 'DUNGEON' then found := true;
  for i := 0 to High(m.markers) do
    if m.markers[i].name = 'edgeN' then entryX := m.markers[i].x;
  Check(found, 'neighbor cell has a gap portal back to the zone');
  Check(entryX >= 0, 'neighbor cell has the arrival marker');

  TestSummary('overworld');
  halt(TestExit);
end.
