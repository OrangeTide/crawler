program t_overworld;

{** The seeded overworld: names, biome determinism and spread, and the
  generated cell structure (reachable edge portals). }

{$mode objfpc}{$H+}

uses
  overworld, mapfmt, mapgen, testing;

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
  cx, cy, i, startX, startY, allReach, distinct: longint;
  m: TMapData;
  seenBiome: array[0 .. BIOME_COUNT - 1] of boolean;
  x, y: longint;
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

  TestSummary('overworld');
  halt(TestExit);
end.
