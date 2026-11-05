program t_lighting;

{** Underground lighting: emissive sources are placed and the light map
  casts a falling-off pool around them. }

{$mode objfpc}{$H+}

uses
  overworld, worldname, mapfmt, mapgen, world, testing;

{ Count lights of a kind and remember one position. }
function CountKind(const m: TMapData; kind: longint; out lx, ly: longint): longint;
var i, n: longint;
begin
  n := 0; lx := -1; ly := -1;
  for i := 0 to High(m.lights) do
    if m.lights[i].kind = kind then begin
      inc(n); lx := m.lights[i].x; ly := m.lights[i].y;
    end;
  CountKind := n;
end;

const
  CX = 511; CY = 511;   { ARBOREAL above, so the theme is CRYPT }
var
  m: TMapData;
  lx, ly, atSrc, atFar: longint;
begin
  m := GenerateDungeonLevel(CX, CY, 3, CellSeed(CX, CY, 3));
  Check((m.flags and MAP_SURFACE) = 0, 'dungeon level is underground');
  Check(Length(m.lights) > 0, 'dungeon has light sources');
  Check(CountKind(m, LIGHT_TORCH, lx, ly) >= 1, 'a torch lights the stairs');

  LoadMapData(m);
  { the torch tile is brightly lit, a tile far away much less }
  if lx >= 0 then begin
    atSrc := TileLightAt(lx, ly);
    atFar := TileLightAt(lx + 9, ly);
    Check(atSrc > 60, 'light is strong at the source');
    Check(atSrc > atFar, 'light falls off with distance');
  end else
    Check(false, 'found a torch to sample');

  { the Depths settlement has a bonfire }
  m := GenerateDepthsCell(CX, CY, CellSeed(CX, CY, SUNLESS_DEPTH + 1));
  Check(CountKind(m, LIGHT_BONFIRE, lx, ly) >= 1, 'the Depths has a bonfire');
  LoadMapData(m);
  if lx >= 0 then
    Check(TileLightAt(lx, ly) > 150, 'the bonfire is very bright');

  TestSummary('lighting');
  halt(TestExit);
end.
