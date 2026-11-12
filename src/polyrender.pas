unit polyrender;

{** Draws the tile grid as textured polygons through the rasterizer.

  This is the engine's renderer. The world is a tile grid walked by the
  party; the view draws it as polygons rather than casting it. Each floor tile
  becomes a floor quad and a ceiling quad, and each wall tile contributes
  a vertical face toward every open neighbor. Props and monsters are
  instanced on top later. The existing wall, floor and ceiling textures
  are reused, quantized once to palette indices the rasterizer samples. }

{$mode objfpc}{$H+}

interface

uses
  pak, roomdb;

procedure RenderViewPoly;

{ Stage 2 increment 2: render the kit-clad explore scene on the GPU. Builds the
  camera from the world Cam and runs the cladding passes with clad's mesh hook
  pointed at the GL backend. Only the kit floors, ceilings, walls and pillars so
  far: the non-kit grid, props, terrain, sky, steps and HUD stay on the stage-2
  roadmap. Requires the GL backend (video.VideoIsGL). }
procedure RenderViewGL;

{ Draw a hand-placed modular room (the theme G pre-format proof): clear
  to a dark interior, then instance every piece from the resident trim
  atlas through the shared-texture mesh path. Meshes are pulled from the
  pak by piece name. The camera is the global world.Cam, with the eye
  raised to room height. }
procedure RenderRoom(const p: TPak; const room: TRoom);

implementation

uses
  math, gfx, textures, world, mapfmt, raster, models, meshfmt,
  sprites, worldspr, tilekit, clad, terrain, glrender, video;

const
  VIEW_R = 14;          { tiles drawn around the camera }
  FOCAL  = (FBW / 2) / 0.66;
  NS_DARK = 0.72;       { north/south faces darker }

  { Sub-quads per cell edge for the grid's floor, ceiling and wall faces. The
    polygon path maps textures affinely, so one big cell quad warps a straight
    course into a kink at a grazing angle; subdividing shrinks each affine patch
    and keeps the lines straight, the way the PlayStation tessellated surfaces
    for the same reason. A per-target knob like raster.VSNAP and
    terrain.TERRAIN_SUBDIV: dense on the desktop, coarse on the FPU-less
    targets. 1 is off (a single quad). }
{$ifdef GRID_COARSE}
  GRID_SUBDIV = 2;
{$else}
  GRID_SUBDIV = 4;
{$endif}

var
  GridTex: array[0 .. TEX_COUNT - 1] of array of byte;   { palette indices }
  gtTileset: longint = -1;   { which tileset GridTex holds, -1 none }
  { When set, the procedural grid quads go to the GPU (GLDrawWorldQuad) instead
    of the software rasterizer. RenderViewGL raises it around its cell loop. }
  gEmitGL: boolean = false;

procedure BuildGridTex;
var t, i: longint;
begin
  for t := 0 to TEX_COUNT - 1 do begin
    SetLength(GridTex[t], TEXSIZE);
    for i := 0 to TEXSIZE - 1 do GridTex[t][i] := Quantize(Tex[t][i]);
  end;
  gtTileset := CurTileset;   { Tex holds only one tileset; rebuild when it swaps }
end;

function WallTexId(tile: byte): longint;
begin
  case tile of
    1: WallTexId := TEX_BRICK;
    2: WallTexId := TEX_STONE;
    3: WallTexId := TEX_MOSS;
    4: WallTexId := TEX_DOOR;
  else
    WallTexId := TEX_STONE;
  end;
end;

{ An open neighbour that the procedural wall quad should face: a kit cell is
  clad by its own wall mesh, so the quad is suppressed toward it. }
function OpenNonKit(nx, ny: longint): boolean;
begin
  OpenNonKit := (not IsWallTile(nx, ny))
    and (KitIndexForTileset(CellTileset(nx, ny)) < 0);
end;

{ Emit one textured grid quad, to the GPU or the software rasterizer per
  gEmitGL. The software path subdivides for affine correctness and can carry an
  emissive glow; the GPU path is perspective-correct and skips both. }
procedure EmitQuad(const mc: TMeshCam;
  x0, y0, z0, x1, y1, z1, x2, y2, z2, x3, y3, z3: double;
  u0, v0, u1, v1, u2, v2, u3, v3: double;
  tex: PByte; tw, th: longint; light: double;
  glow: TColor = 0; glowW: longint = 0);
begin
  if gEmitGL then
    GLDrawWorldQuad(x0, y0, z0, x1, y1, z1, x2, y2, z2, x3, y3, z3,
      u0, v0, u1, v1, u2, v2, u3, v3, tex, tw, th, light)
  else
    DrawTexQuadSub(mc, x0, y0, z0, x1, y1, z1, x2, y2, z2, x3, y3, z3,
      u0, v0, u1, v1, u2, v2, u3, v3, tex, tw, th, light, glow, glowW, GRID_SUBDIV);
end;

{ One vertical wall quad on cell (tx,ty)'s edge, facing the open neighbor on
  side 0..3 (west, east, south, north), spanning z in [zLo,zHi]. The winding
  matches the old full-height faces, so a flat zLo=0,zHi=1 draws identically. }
procedure WallQuad(const mc: TMeshCam; side, tx, ty: longint;
  zLo, zHi: double; texId: longint; light: double);
begin
  case side of
    0: EmitQuad(mc, tx, ty, zLo,  tx, ty + 1, zLo,  tx, ty + 1, zHi,  tx, ty, zHi,
         0, 0, 1, 0, 1, 1, 0, 1, @GridTex[texId][0], TEXW, TEXH, light);
    1: EmitQuad(mc, tx + 1, ty + 1, zLo,  tx + 1, ty, zLo,  tx + 1, ty, zHi,  tx + 1, ty + 1, zHi,
         0, 0, 1, 0, 1, 1, 0, 1, @GridTex[texId][0], TEXW, TEXH, light);
    2: EmitQuad(mc, tx + 1, ty, zLo,  tx, ty, zLo,  tx, ty, zHi,  tx + 1, ty, zHi,
         0, 0, 1, 0, 1, 1, 0, 1, @GridTex[texId][0], TEXW, TEXH, light);
    3: EmitQuad(mc, tx, ty + 1, zLo,  tx + 1, ty + 1, zLo,  tx + 1, ty + 1, zHi,  tx, ty + 1, zHi,
         0, 0, 1, 0, 1, 1, 0, 1, @GridTex[texId][0], TEXW, TEXH, light);
  end;
end;

{ The raycaster's fog curve: full to 1.5, fading to a floor of 32 by 9.0. }
function FogAt(dist: double): double;
begin
  if dist <= 1.5 then FogAt := 256
  else if dist >= 9.0 then FogAt := 32
  else FogAt := 32 + (9.0 - dist) / 7.5 * 224;
end;

{ Brightness on a tile surface: the brighter of torch fog and scene light. }
function TileLight(tx, ty: longint; dist: double): double;
var scene: longint;
begin
  scene := AmbientLight + TileLightAt(tx, ty);
  if scene > 256 then scene := 256;
  TileLight := FogAt(dist) * TorchGlow / 256;   { party light dims as it burns }
  if scene > TileLight then TileLight := scene;
end;

{ The step walls of an open cell: a lower riser where an open neighbor's floor
  sits below this cell's, and an upper lintel where its ceiling sits below.
  Each step is drawn once, from the cell with the higher floor or ceiling, so
  flat maps (no height difference) draw nothing here. }
procedure StepFaces(const mc: TMeshCam; tx, ty: longint; fz, cz, ex, ey: double);
const
  SDX: array[0 .. 3] of longint = (-1, 1, 0, 0);
  SDY: array[0 .. 3] of longint = (0, 0, -1, 1);
  EPS = 0.001;
var
  side, nbx, nby: longint;
  nfz, ncz, nd, lightN, nsscale: double;
  kitHere: boolean;
begin
  kitHere := KitIndexForTileset(CellTileset(tx, ty)) >= 0;
  for side := 0 to 3 do begin
    nbx := tx + SDX[side]; nby := ty + SDY[side];
    if IsWallTile(nbx, nby) then continue;     { a solid neighbor is a full wall }
    nfz := FloorZAt(nbx, nby); ncz := CeilZAt(nbx, nby);
    if (fz <= nfz + EPS) and (cz <= ncz + EPS) then continue;
    nd := sqrt(sqr(nbx + 0.5 - ex) + sqr(nby + 0.5 - ey));
    if side >= 2 then nsscale := NS_DARK else nsscale := 1.0;
    lightN := TileLight(nbx, nby, nd) * nsscale;
    if fz > nfz + EPS then begin                                 { floor riser }
      if kitHere then CladStep(mc, side, tx, ty, nfz, fz, lightN)
      else WallQuad(mc, side, tx, ty, nfz, fz, TEX_STONE, lightN);
    end;
    if cz > ncz + EPS then begin                                 { ceiling lintel }
      if kitHere then CladStep(mc, side, tx, ty, ncz, cz, lightN)
      else WallQuad(mc, side, tx, ty, ncz, cz, TEX_STONE, lightN);
    end;
  end;
end;

{ Instance every placed prop near the camera as a model. }
procedure DrawProps(const mc: TMeshCam; ex, ey, cyaw, syaw: double);
var
  i, mi, ptx, pty: longint;
  px, py, dist, fwd, yaw, light: double;
begin
  for i := 0 to High(CurMap.props) do begin
    ptx := CurMap.props[i].x; pty := CurMap.props[i].y;
    px := ptx + 0.5; py := pty + 0.5;
    fwd := (px - ex) * cyaw + (py - ey) * syaw;
    if fwd < -1.0 then continue;                 { behind the camera }
    dist := sqrt(sqr(px - ex) + sqr(py - ey));
    if dist > VIEW_R + 1 then continue;
    mi := FindModel(CurMap.props[i].name);
    if mi < 0 then continue;
    yaw := CurMap.props[i].yaw / 256.0 * 2 * Pi;
    light := TileLight(ptx, pty, dist);
    RenderMeshAt(ModelReg[mi].mesh, mc, px, py, GroundZAt(px, py),
      ModelReg[mi].scale, yaw, light);
  end;
end;

{ Place a door in its cell: face it away from the single wall backing the
  cell, into the open (as carve.FaceFromWalls orients an `auto` prop), and
  push it almost half a tile toward that wall so it sits in the wall plane
  instead of floating centered on the walkable tile. Freestanding cells face
  south and are not shifted. }
procedure DoorPlacement(tx, ty: longint; out yaw, ox, oy: double);
const
  SET_IN = 0.45;   { toward the wall, short of the face so it never z-fights it }
var
  wN, wS, wE, wW: boolean;
  yb: longint;
begin
  wN := IsWallTile(tx, ty - 1); wS := IsWallTile(tx, ty + 1);
  wE := IsWallTile(tx + 1, ty); wW := IsWallTile(tx - 1, ty);
  ox := 0; oy := 0;
  if wN and (not wS) then begin yb := 0;   oy := -SET_IN; end
  else if wS and (not wN) then begin yb := 128; oy := SET_IN; end
  else if wE and (not wW) then begin yb := 64;  ox := SET_IN; end
  else if wW and (not wE) then begin yb := 192; ox := -SET_IN; end
  else yb := 0;
  yaw := yb / 256.0 * 2 * Pi;
end;

{ Draw the prop mesh that stands in a portal, so an exit reads as real
  geometry rather than a flat billboard: the doorway mesh in a door portal,
  the ladder mesh in a ladder portal. Covers authored and generated maps
  alike, since it walks the live portal list. A door is set into the wall
  backing its cell and faces the open side the wall gives it. A ladder stands
  centred in its cell (the generator puts it in an open chamber, where there
  is no wall to face away from) and turns its flat climbable face toward the
  camera, the way the old billboard always did, so it never shows only its
  thin edge. The model's face sits along +Y at yaw 0, so the camera-facing
  yaw is atan2(px - ex, ey - py). }
procedure DrawPortalMeshes(const mc: TMeshCam; ex, ey, cyaw, syaw: double);
var
  i, mdDoor, mdLad, mi, ptx, pty: longint;
  px, py, dist, fwd, light, yaw, ox, oy: double;
  isDoor: boolean;
begin
  mdDoor := FindModel('DOORWAY');
  mdLad := FindModel('LADDER');
  for i := 0 to High(CurMap.portals) do begin
    isDoor := CurMap.portals[i].kind = PK_DOOR;
    if isDoor then mi := mdDoor
    else if CurMap.portals[i].kind = PK_LADDER then mi := mdLad
    else continue;
    if mi < 0 then continue;
    ptx := CurMap.portals[i].x; pty := CurMap.portals[i].y;
    DoorPlacement(ptx, pty, yaw, ox, oy);
    if not isDoor then begin ox := 0; oy := 0; end;   { a ladder stands centred }
    px := ptx + 0.5 + ox; py := pty + 0.5 + oy;   { a door is set into the wall }
    if not isDoor then yaw := ArcTan2(px - ex, ey - py);   { ladder faces camera }
    fwd := (px - ex) * cyaw + (py - ey) * syaw;
    if fwd < -1.0 then continue;                 { behind the camera }
    dist := sqrt(sqr(px - ex) + sqr(py - ey));
    if dist > VIEW_R + 1 then continue;
    light := TileLight(ptx, pty, dist);
    { height from the walkable tile centre, not the shifted point, so the door
      never samples ground inside the wall it backs against }
    RenderMeshAt(ModelReg[mi].mesh, mc, px, py, GroundZAt(ptx + 0.5, pty + 0.5),
      ModelReg[mi].scale, yaw, light);
  end;
end;

{ Draw the outdoor terrain heightfield: for each visible open, non-kit cell on a
  surface map that carries terrain, emit TERRAIN_SUBDIV^2 textured sub-quads whose
  corner heights come from the resident height grid. This replaces the flat floor
  quad. UVs are world positions, so the ground texture tiles once per cell exactly
  as the flat floor did; adjacent cells share corner heights, so the terrain
  seams with no cracks. Reuses the floor texture, projection, z-buffer and
  lighting, so it adds no new per-pixel math. }
procedure DrawTerrain(const mc: TMeshCam; x0, y0, x1, y1: longint; ex, ey: double);
var
  tx, ty, sxi, syi: longint;
  dist, light, step, wx0, wy0, wx1, wy1, z00, z10, z11, z01: double;
begin
  step := 1.0 / TERRAIN_SUBDIV;
  for ty := y0 to y1 do
    for tx := x0 to x1 do begin
      if IsWallTile(tx, ty) then continue;                  { no ground under a wall }
      if KitIndexForTileset(CellTileset(tx, ty)) >= 0 then continue;  { clad separately }
      dist := sqrt(sqr(tx + 0.5 - ex) + sqr(ty + 0.5 - ey));
      light := TileLight(tx, ty, dist);
      for syi := 0 to TERRAIN_SUBDIV - 1 do
        for sxi := 0 to TERRAIN_SUBDIV - 1 do begin
          wx0 := tx + sxi * step; wx1 := wx0 + step;
          wy0 := ty + syi * step; wy1 := wy0 + step;
          z00 := TerrainHeightAt(wx0, wy0);
          z10 := TerrainHeightAt(wx1, wy0);
          z11 := TerrainHeightAt(wx1, wy1);
          z01 := TerrainHeightAt(wx0, wy1);
          DrawTexQuad(mc,
            wx0, wy0, z00,  wx1, wy0, z10,  wx1, wy1, z11,  wx0, wy1, z01,
            wx0, wy0, wx1, wy0, wx1, wy1, wx0, wy1,
            @GridTex[TEX_FLOOR][0], TEXW, TEXH, light);
        end;
    end;
end;

{ Billboard every NPC and active pursuer on the current map. }
procedure DrawEntities(const mc: TMeshCam; ex, ey, cyaw, syaw: double);
var
  ents: array[0 .. 63] of TWorldSprite;
  n, i, ptx, pty: longint;
  px, py, dist, fwd, light, wscale: double;
begin
  n := GatherWorldSprites(ents);
  for i := 0 to n - 1 do begin
    px := ents[i].x; py := ents[i].y;
    fwd := (px - ex) * cyaw + (py - ey) * syaw;
    if fwd < -1.0 then continue;                 { behind the camera }
    dist := sqrt(sqr(px - ex) + sqr(py - ey));
    if dist > VIEW_R + 1 then continue;
    ptx := trunc(px); pty := trunc(py);
    light := TileLight(ptx, pty, dist);
    with SpriteReg[ents[i].img].img do
      if h > 0 then wscale := ents[i].wh * w / h else wscale := ents[i].wh;
    DrawSpriteBillboard(mc, SpriteReg[ents[i].img].img, px, py, wscale,
      ents[i].wh, light, GroundZAt(px, py));
  end;
end;

{ The procedural grid geometry of one cell: wall faces toward open non-kit
  neighbours, or, for an open non-kit cell, its floor, ceiling and step risers.
  Kit cells are left to the cladding passes. Emits through EmitQuad, so it draws
  on the GPU or the software rasterizer per gEmitGL, and is shared by both the
  software view and the GPU view. cyaw/syaw are the camera facing, for the
  behind-camera cull. }
procedure DrawGridCell(const mc: TMeshCam; tx, ty: longint;
  ex, ey, cyaw, syaw: double);
var
  cx, cy, dist, fwd, light, fd, fz, cz: double;
  ftex, gk, gw: longint;
  gcol: TColor;
begin
  cx := tx + 0.5; cy := ty + 0.5;
  fwd := (cx - ex) * cyaw + (cy - ey) * syaw;
  if fwd < -1.3 then exit;                 { behind the camera }
  dist := sqrt(sqr(cx - ex) + sqr(cy - ey));

  if IsWallTile(tx, ty) then begin
    ftex := WallTexId(TileAt(tx, ty));
    { a face toward each open neighbor, spanning that neighbor's sector
      floor to ceiling, lit from that neighbor tile }
    if OpenNonKit(tx - 1, ty) then begin   { west face, x = tx }
      fd := sqrt(sqr(tx - ex) + sqr(cy - ey));
      light := TileLight(tx - 1, ty, fd);
      WallQuad(mc, 0, tx, ty, FloorZAt(tx - 1, ty), CeilZAt(tx - 1, ty), ftex, light);
    end;
    if OpenNonKit(tx + 1, ty) then begin   { east face, x = tx+1 }
      fd := sqrt(sqr(tx + 1 - ex) + sqr(cy - ey));
      light := TileLight(tx + 1, ty, fd);
      WallQuad(mc, 1, tx, ty, FloorZAt(tx + 1, ty), CeilZAt(tx + 1, ty), ftex, light);
    end;
    if OpenNonKit(tx, ty - 1) then begin   { south face, y = ty }
      fd := sqrt(sqr(cx - ex) + sqr(ty - ey));
      light := TileLight(tx, ty - 1, fd) * NS_DARK;
      WallQuad(mc, 2, tx, ty, FloorZAt(tx, ty - 1), CeilZAt(tx, ty - 1), ftex, light);
    end;
    if OpenNonKit(tx, ty + 1) then begin   { north face, y = ty+1 }
      fd := sqrt(sqr(cx - ex) + sqr(ty + 1 - ey));
      light := TileLight(tx, ty + 1, fd) * NS_DARK;
      WallQuad(mc, 3, tx, ty, FloorZAt(tx, ty + 1), CeilZAt(tx, ty + 1), ftex, light);
    end;
  end else begin
    light := TileLight(tx, ty, dist);
    fz := FloorZAt(tx, ty); cz := CeilZAt(tx, ty);
    { a kit tileset's floors and ceilings are drawn by the CladView pass; only a
      non-kit cell draws the procedural surface quads here }
    if KitIndexForTileset(CellTileset(tx, ty)) < 0 then
    begin
      { floor at this cell's sector height, with an emissive tile's glow tint
        mixed in (software path only). On a surface map with terrain relief,
        DrawTerrain draws the ground instead. }
      if not (CurMapSurface and TerrainActive) then
      begin
        gw := 0; gcol := 0;
        gk := LightTileKind(tx, ty);
        if gk >= 0 then LightGlow(gk, gcol, gw);
        EmitQuad(mc, tx, ty, fz,  tx + 1, ty, fz,  tx + 1, ty + 1, fz,  tx, ty + 1, fz,
          0, 0, 1, 0, 1, 1, 0, 1, @GridTex[TEX_FLOOR][0], TEXW, TEXH, light, gcol, gw);
      end;
      { ceiling at this cell's sector height, unless an open-air surface map }
      if not CurMapSurface then
        EmitQuad(mc, tx, ty + 1, cz,  tx + 1, ty + 1, cz,  tx + 1, ty, cz,  tx, ty, cz,
          0, 0, 1, 0, 1, 1, 0, 1, @GridTex[TEX_CEILING][0], TEXW, TEXH, light);
    end;
    { risers and lintels where open neighbors differ in height }
    StepFaces(mc, tx, ty, fz, cz, ex, ey);
  end;
end;

procedure RenderViewGL;
var
  mc: TMeshCam;
  ex, ey, cyaw, syaw: double;
  tx, ty, x0, y0, x1, y1: longint;
begin
  if not VideoIsGL then exit;
  ex := Cam.posX; ey := Cam.posY;
  mc.x := ex; mc.y := ey; mc.z := Cam.posZ;
  mc.yaw := arctan2(Cam.dirY, Cam.dirX);
  mc.pitch := Cam.pitch / FOCAL;
  cyaw := cos(mc.yaw); syaw := sin(mc.yaw);
  x0 := max(0, trunc(ex) - VIEW_R); x1 := min(MapW - 1, trunc(ex) + VIEW_R);
  y0 := max(0, trunc(ey) - VIEW_R); y1 := min(MapH - 1, trunc(ey) + VIEW_R);

  GLSceneBegin(mc);
  CladMeshHook := @GLDrawMesh;
  { the procedural non-kit grid, emitted to the GPU }
  gEmitGL := true;
  for ty := y0 to y1 do
    for tx := x0 to x1 do
      DrawGridCell(mc, tx, ty, ex, ey, cyaw, syaw);
  gEmitGL := false;
  { the kit-clad floors, ceilings, walls and pillars at native scale }
  CladView(mc, x0, y0, x1, y1, ex, ey, not CurMapSurface, @TileLight);
  CladWalls(mc, x0, y0, x1, y1, ex, ey, @TileLight);
  CladPillars(mc, x0, y0, x1, y1, ex, ey, @TileLight);
  CladMeshHook := nil;
  GLSceneEnd;
end;

procedure RenderViewPoly;
var
  mc: TMeshCam;
  ex, ey: double;
  tx, ty, x0, y0, x1, y1: longint;
  cyaw, syaw, cx, cy, fwd, dist: double;
  gk, gw: longint;
  gcol: TColor;
  shor, syy, sxx: longint;
  sb: byte;
begin
  if gtTileset <> CurTileset then BuildGridTex;
  RasterCX := FBW / 2; RasterCY := FBH / 2;
  RasterBeginFrame;
  if CurMapSurface then begin
    { open sky above the horizon; the dark ground below is covered by the
      floor quads, matching the raycaster's surface view }
    shor := round(FBH / 2 + Cam.pitch);
    for syy := 0 to FBH - 1 do begin
      if syy < shor then
        for sxx := 0 to FBW - 1 do
          FB[syy * FBW + sxx] := DitherQuant(SkyColorAt(syy, shor), sxx, syy)
      else begin
        sb := Quantize(RGB(6, 6, 10));
        for sxx := 0 to FBW - 1 do FB[syy * FBW + sxx] := sb;
      end;
    end;
  end else
    ClearFB(RGB(6, 6, 10));

  ex := Cam.posX; ey := Cam.posY;
  mc.x := ex; mc.y := ey; mc.z := Cam.posZ;
  mc.yaw := arctan2(Cam.dirY, Cam.dirX);
  mc.pitch := Cam.pitch / FOCAL;   { pixel horizon shift to an angle }
  cyaw := cos(mc.yaw); syaw := sin(mc.yaw);

  x0 := max(0, trunc(ex) - VIEW_R); x1 := min(MapW - 1, trunc(ex) + VIEW_R);
  y0 := max(0, trunc(ey) - VIEW_R); y1 := min(MapH - 1, trunc(ey) + VIEW_R);

  for ty := y0 to y1 do
    for tx := x0 to x1 do
      DrawGridCell(mc, tx, ty, ex, ey, cyaw, syaw);

  { clad the kit tilesets' floors and ceilings at native scale, merging
    aligned cells into whole kit pieces, then the walls on their edges }
  CladView(mc, x0, y0, x1, y1, ex, ey, not CurMapSurface, @TileLight);
  CladWalls(mc, x0, y0, x1, y1, ex, ey, @TileLight);
  CladPillars(mc, x0, y0, x1, y1, ex, ey, @TileLight);

  { a light tile on a kit-clad floor cannot glow through its merged native
    floor piece, so tint those cells with a per-cell decal here, the way the
    non-kit floor quad above mixes the glow in directly }
  for ty := y0 to y1 do
    for tx := x0 to x1 do
      if (not IsWallTile(tx, ty))
         and (KitIndexForTileset(CellTileset(tx, ty)) >= 0) then begin
        gk := LightTileKind(tx, ty);
        if gk < 0 then continue;
        gw := 0; gcol := 0;
        if not LightGlow(gk, gcol, gw) then continue;
        cx := tx + 0.5; cy := ty + 0.5;
        fwd := (cx - ex) * cyaw + (cy - ey) * syaw;
        if fwd < -1.3 then continue;         { behind the camera }
        dist := sqrt(sqr(cx - ex) + sqr(cy - ey));
        DrawFloorGlow(mc, tx, ty, FloorZAt(tx, ty), gcol, gw, TileLight(tx, ty, dist));
      end;

  { the outdoor ground, drawn as relief where a surface map carries terrain }
  if CurMapSurface and TerrainActive then
    DrawTerrain(mc, x0, y0, x1, y1, ex, ey);

  DrawProps(mc, ex, ey, cyaw, syaw);
  DrawPortalMeshes(mc, ex, ey, cyaw, syaw);
  DrawEntities(mc, ex, ey, cyaw, syaw);
end;

procedure RenderRoom(const p: TPak; const room: TRoom);
var
  mc: TMeshCam;
  i, ci: longint;
  dist, light: double;
  blob: TByteArray;
  atlas: PByte;
  cacheName: array of string;
  cacheMesh: array of TMesh;

  { Decode a piece mesh from the pak once, caching by name for this frame. }
  function MeshFor(const nm: string): longint;
  var k: longint; m: TMesh;
  begin
    MeshFor := -1;
    for k := 0 to High(cacheName) do
      if cacheName[k] = nm then begin MeshFor := k; exit; end;
    if not (PakGet(p, nm, blob) and DecodeMesh(blob, m)) then exit;
    k := Length(cacheName);
    SetLength(cacheName, k + 1); SetLength(cacheMesh, k + 1);
    cacheName[k] := nm; cacheMesh[k] := m;
    MeshFor := k;
  end;

begin
  RasterCX := FBW / 2; RasterCY := FBH / 2;
  ClearFB(RGB(10, 9, 12));
  RasterBeginFrame;

  atlas := nil;
  if Length(TrimTex) > 0 then atlas := @TrimTex[0];

  mc.x := Cam.posX; mc.y := Cam.posY; mc.z := 1.5;
  mc.yaw := arctan2(Cam.dirY, Cam.dirX);
  mc.pitch := Cam.pitch / FOCAL;

  for i := 0 to High(room) do begin
    ci := MeshFor(room[i].model);
    if ci < 0 then continue;
    dist := sqrt(sqr(room[i].x - Cam.posX) + sqr(room[i].y - Cam.posY));
    light := 230 - dist * 6;
    if light < 70 then light := 70;
    RenderMeshAt(cacheMesh[ci], mc, room[i].x, room[i].y, room[i].z,
      room[i].scale, room[i].yaw, light, atlas, TrimW, TrimH);
  end;
end;

end.
