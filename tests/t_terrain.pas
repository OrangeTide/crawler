program t_terrain;

{** The terrain height layer: a baked heightmap builds a height grid that
  samples as a bilinear ramp, clamps outside the map, seams across cell
  boundaries, and clears back to inactive on reset. }

{$mode objfpc}{$H+}

uses
  sysutils, pak, mapfmt, overworld, terrain, testing;

{ True when a is within 0.01 of b. }
function Near(a, b: double): boolean;
begin
  Near := Abs(a - b) < 0.01;
end;

var
  m: TMapData;
  samples: TByteArray;
  leftOfSeam, rightOfSeam: double;
begin
  { a 2x2 source that ramps 0..255 left to right, flat top to bottom }
  SetLength(samples, 4);
  samples[0] := 0;   samples[1] := 255;
  samples[2] := 0;   samples[3] := 255;

  { a 4x4 map; zmin 0, zmax 16 maps sample 0..255 to 0..1 world unit }
  m.w := 4; m.h := 4;
  m.heightLump := 'HM'; m.heightZMin := 0; m.heightZMax := 16;

  TerrainSetHeightmap(m, samples, 2, 2);
  Check(TerrainActive, 'a heightmap makes the layer active');

  { the ramp: height tracks x/mapW across the map, flat in y }
  Check(Near(TerrainHeightAt(0, 0), 0.0), 'the west edge sits at zmin');
  Check(Near(TerrainHeightAt(4, 0), 1.0), 'the east edge sits at zmax');
  Check(Near(TerrainHeightAt(2, 0), 0.5), 'the middle interpolates halfway');
  Check(Near(TerrainHeightAt(2, 3), 0.5), 'the ramp is flat along y');
  Check(Near(TerrainHeightAt(1, 0), 0.25), 'a quarter across reads a quarter up');

  { outside the map clamps to the edge, never reads out of bounds }
  Check(Near(TerrainHeightAt(-5, -5), 0.0), 'past the west edge clamps to zmin');
  Check(Near(TerrainHeightAt(99, 99), 1.0), 'past the east edge clamps to zmax');

  { the surface seams: the height just left and just right of an interior cell
    boundary agree, so adjacent cells draw no crack }
  leftOfSeam := TerrainHeightAt(2.0 - 0.0001, 1.5);
  rightOfSeam := TerrainHeightAt(2.0 + 0.0001, 1.5);
  Check(Abs(leftOfSeam - rightOfSeam) < 0.001, 'the height is continuous across a cell boundary');

  { procedural elevation seams across a cell edge: the east edge of cell (cx,cy)
    matches the west edge of (cx+1,cy) at the same y, so neighbor wilderness
    terrain has no crack, with nothing stored }
  Check(Abs(TerrainElevation(400, 400, 1.0, 0.3)
          - TerrainElevation(401, 400, 0.0, 0.3)) < 1e-9,
    'procedural terrain seams across the east edge');
  Check(Abs(TerrainElevation(400, 400, 0.6, 1.0)
          - TerrainElevation(400, 401, 0.6, 0.0)) < 1e-9,
    'procedural terrain seams across the south edge');
  { and it stays within its height range, never underground }
  Check((TerrainElevation(400, 400, 0.5, 0.5) >= 0.0)
    and (TerrainElevation(400, 400, 0.5, 0.5) <= 2.5),
    'procedural height stays in range');

  { reset deactivates and reads flat }
  TerrainReset;
  Check(not TerrainActive, 'reset clears the layer');
  Check(Near(TerrainHeightAt(2, 0), 0.0), 'an inactive layer reads flat');

  TestSummary('terrain');
  halt(TestExit);
end.
