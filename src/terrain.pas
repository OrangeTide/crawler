unit terrain;

{** Outdoor terrain heightfield, a render-only layer beside the logical grid.

  A surface map's ground is not flat: this unit holds a per-map height grid that
  the polygon renderer draws as relief and that the camera and billboards read to
  sit on the slope. It is decoupled from collision. The logical wall grid stays
  the coarse, target-independent authority, so height never blocks a step or
  changes routing. A flat or indoor map leaves the layer inactive and renders
  exactly as before.

  The height grid is built once per map at load, by sampling a source into a grid
  of (w*TERRAIN_SUBDIV + 1) x (h*TERRAIN_SUBDIV + 1) nodes. TERRAIN_SUBDIV is the
  per-target density knob, the same shape as the 0.26.0 trim-sheet knob: one
  source, a compile-time parameter that bakes a denser or coarser result. The
  desktop build renders dense terrain; a coarse build renders fewer, snapped
  nodes from the same source. Adjacent cells share node columns and rows, so the
  terrain seams with no cracks.

  Phase 1 builds the grid from a baked heightmap asset. Procedural wilderness
  from the world seed is a later phase; its entry point will live here. }

{$mode objfpc}{$H+}

interface

uses
  pak, mapfmt, overworld;

const
  { Sub-quads per cell edge: the per-target terrain density knob. The default
    desktop build is dense; a coarse target build defines TERRAIN_COARSE to drop
    to a low subdivision and quantize node heights for the PlayStation terrace
    look, from the same source. These mirror raster.VSNAP and
    meshfmt.MESH_TRI_BUDGET: compile-time constants a target overrides. }
{$ifdef TERRAIN_COARSE}
  TERRAIN_SUBDIV = 2;
  TERRAIN_ZSTEP  = 0.25;   { world units; snap node heights to this, 0 = off }
{$else}
  TERRAIN_SUBDIV = 4;
  TERRAIN_ZSTEP  = 0.0;
{$endif}

type
  TByteArray = pak.TByteArray;

{ Clear the layer; a map with no height source leaves it like this. }
procedure TerrainReset;

{ Build the height grid for map m from a baked heightmap (sw x sh samples, each
  0..255), mapping sample 0..255 to m.heightZMin..heightZMax (in 1/HZ_UNIT world
  units) across the whole map. Makes the layer active. }
procedure TerrainSetHeightmap(const m: TMapData; const samples: TByteArray;
  sw, sh: longint);

{ Build the height grid for a procedural surface cell (cx,cy) from the world
  seed, sampling overworld.TerrainElevation across the cell. Neighbor cells seam
  because the elevation field is continuous in world space. Makes the layer
  active. }
procedure TerrainSetProcedural(const m: TMapData; cx, cy: longint);

{ True when a height source is resident, so the renderer draws terrain relief and
  the camera and billboards ride it. False on flat and indoor maps. }
function TerrainActive: boolean;

{ The node grid dimensions and one node's height (world units). The renderer
  walks the grid node by node; nx in 0..TerrainCols-1, ny in 0..TerrainRows-1. }
function TerrainCols: longint;
function TerrainRows: longint;
function TerrainNode(nx, ny: longint): double;

{ Terrain height at an arbitrary world position, bilinearly interpolated and
  clamped at the edges. Returns 0 when the layer is inactive. The camera and the
  billboard and prop ground anchor read this. }
function TerrainHeightAt(wx, wy: double): double;

implementation

var
  active: boolean;
  cols, rows: longint;               { node grid dimensions }
  grid: array of single;             { cols*rows, row major, world-unit heights }
  mw, mh: longint;                   { the map's cell dimensions }

procedure TerrainReset;
begin
  active := false;
  grid := nil;
  cols := 0; rows := 0; mw := 0; mh := 0;
end;

function TerrainActive: boolean;
begin
  TerrainActive := active;
end;

function TerrainCols: longint;
begin
  TerrainCols := cols;
end;

function TerrainRows: longint;
begin
  TerrainRows := rows;
end;

function TerrainNode(nx, ny: longint): double;
begin
  if (not active) or (nx < 0) or (ny < 0) or (nx >= cols) or (ny >= rows) then
    TerrainNode := 0
  else
    TerrainNode := grid[ny * cols + nx];
end;

{ Bilinear sample of a sw x sh byte heightmap at normalized (u,v) in [0,1],
  returning 0..255. Clamped at the edges. }
function SampleSrc(const samples: TByteArray; sw, sh: longint;
  u, v: double): double;
var
  fx, fy, tx, ty: double;
  x0, y0, x1, y1: longint;
  s00, s10, s01, s11, a, b: double;
begin
  if (sw <= 0) or (sh <= 0) then begin SampleSrc := 0; exit; end;
  if u < 0 then u := 0 else if u > 1 then u := 1;
  if v < 0 then v := 0 else if v > 1 then v := 1;
  fx := u * (sw - 1);
  fy := v * (sh - 1);
  x0 := Trunc(fx); y0 := Trunc(fy);
  x1 := x0 + 1; y1 := y0 + 1;
  if x1 >= sw then x1 := sw - 1;
  if y1 >= sh then y1 := sh - 1;
  tx := fx - x0; ty := fy - y0;
  s00 := samples[y0 * sw + x0];
  s10 := samples[y0 * sw + x1];
  s01 := samples[y1 * sw + x0];
  s11 := samples[y1 * sw + x1];
  a := s00 + (s10 - s00) * tx;
  b := s01 + (s11 - s01) * tx;
  SampleSrc := a + (b - a) * ty;
end;

{ Optionally snap a height to the coarse-target terrace step. The branch is
  chosen at compile time by the target's TERRAIN_ZSTEP, so no dead code is
  emitted and a zero step never divides. }
function SnapZ(z: double): double;
begin
{$if TERRAIN_ZSTEP > 0}
  SnapZ := Round(z / TERRAIN_ZSTEP) * TERRAIN_ZSTEP;
{$else}
  SnapZ := z;
{$endif}
end;

procedure TerrainSetHeightmap(const m: TMapData; const samples: TByteArray;
  sw, sh: longint);
var
  nx, ny: longint;
  u, v, s, zmin, zmax, z: double;
begin
  TerrainReset;
  if (m.w <= 0) or (m.h <= 0) or (sw <= 0) or (sh <= 0)
    or (Length(samples) < sw * sh) then exit;
  mw := m.w; mh := m.h;
  cols := mw * TERRAIN_SUBDIV + 1;
  rows := mh * TERRAIN_SUBDIV + 1;
  SetLength(grid, cols * rows);
  zmin := m.heightZMin / HZ_UNIT;
  zmax := m.heightZMax / HZ_UNIT;
  for ny := 0 to rows - 1 do
    for nx := 0 to cols - 1 do begin
      { node world position, normalized across the whole map }
      u := (nx / TERRAIN_SUBDIV) / mw;
      v := (ny / TERRAIN_SUBDIV) / mh;
      s := SampleSrc(samples, sw, sh, u, v) / 255.0;
      z := zmin + (zmax - zmin) * s;
      grid[ny * cols + nx] := SnapZ(z);
    end;
  active := true;
end;

procedure TerrainSetProcedural(const m: TMapData; cx, cy: longint);
var
  nx, ny: longint;
  lx, ly: double;
begin
  TerrainReset;
  if (m.w <= 0) or (m.h <= 0) then exit;
  mw := m.w; mh := m.h;
  cols := mw * TERRAIN_SUBDIV + 1;
  rows := mh * TERRAIN_SUBDIV + 1;
  SetLength(grid, cols * rows);
  for ny := 0 to rows - 1 do
    for nx := 0 to cols - 1 do begin
      { node position, normalized 0..1 across the cell }
      lx := (nx / TERRAIN_SUBDIV) / mw;
      ly := (ny / TERRAIN_SUBDIV) / mh;
      grid[ny * cols + nx] := SnapZ(TerrainElevation(cx, cy, lx, ly));
    end;
  active := true;
end;

function TerrainHeightAt(wx, wy: double): double;
var
  fx, fy, tx, ty: double;
  x0, y0, x1, y1: longint;
  h00, h10, h01, h11, a, b: double;
begin
  if not active then begin TerrainHeightAt := 0; exit; end;
  fx := wx * TERRAIN_SUBDIV;
  fy := wy * TERRAIN_SUBDIV;
  if fx < 0 then fx := 0 else if fx > cols - 1 then fx := cols - 1;
  if fy < 0 then fy := 0 else if fy > rows - 1 then fy := rows - 1;
  x0 := Trunc(fx); y0 := Trunc(fy);
  x1 := x0 + 1; y1 := y0 + 1;
  if x1 >= cols then x1 := cols - 1;
  if y1 >= rows then y1 := rows - 1;
  tx := fx - x0; ty := fy - y0;
  h00 := grid[y0 * cols + x0];
  h10 := grid[y0 * cols + x1];
  h01 := grid[y1 * cols + x0];
  h11 := grid[y1 * cols + x1];
  a := h00 + (h10 - h00) * tx;
  b := h01 + (h11 - h01) * tx;
  TerrainHeightAt := a + (b - a) * ty;
end;

initialization
  TerrainReset;
end.
