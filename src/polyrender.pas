unit polyrender;

{** Draws the tile grid as textured polygons through the rasterizer.

  This is the polygon-renderer counterpart to raycast.RenderView. The
  world is the same tile grid; only the drawing changes. Each floor tile
  becomes a floor quad and a ceiling quad, and each wall tile contributes
  a vertical face toward every open neighbor. Props and monsters are
  instanced on top later. The existing wall, floor and ceiling textures
  are reused, quantized once to palette indices the rasterizer samples. }

{$mode objfpc}{$H+}

interface

uses
  pak, roomdb;

procedure RenderViewPoly;

{ Draw a hand-placed modular room (the theme G pre-format proof): clear
  to a dark interior, then instance every piece from the resident trim
  atlas through the shared-texture mesh path. Meshes are pulled from the
  pak by piece name. The camera is the global world.Cam, with the eye
  raised to room height. }
procedure RenderRoom(const p: TPak; const room: TRoom);

implementation

uses
  math, gfx, textures, world, mapfmt, raster, models, meshfmt,
  sprites, worldspr, tilekit, clad;

const
  VIEW_R = 14;          { tiles drawn around the camera }
  FOCAL  = (FBW / 2) / 0.66;
  NS_DARK = 0.72;       { north/south faces darker, as the raycaster does }

var
  GridTex: array[0 .. TEX_COUNT - 1] of array of byte;   { palette indices }
  gtTileset: longint = -1;   { which tileset GridTex holds, -1 none }

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

{ One vertical wall quad on cell (tx,ty)'s edge, facing the open neighbor on
  side 0..3 (west, east, south, north), spanning z in [zLo,zHi]. The winding
  matches the old full-height faces, so a flat zLo=0,zHi=1 draws identically. }
procedure WallQuad(const mc: TMeshCam; side, tx, ty: longint;
  zLo, zHi: double; texId: longint; light: double);
begin
  case side of
    0: DrawTexQuad(mc, tx, ty, zLo,  tx, ty + 1, zLo,  tx, ty + 1, zHi,  tx, ty, zHi,
         0, 0, 1, 0, 1, 1, 0, 1, @GridTex[texId][0], TEXW, TEXH, light);
    1: DrawTexQuad(mc, tx + 1, ty + 1, zLo,  tx + 1, ty, zLo,  tx + 1, ty, zHi,  tx + 1, ty + 1, zHi,
         0, 0, 1, 0, 1, 1, 0, 1, @GridTex[texId][0], TEXW, TEXH, light);
    2: DrawTexQuad(mc, tx + 1, ty, zLo,  tx, ty, zLo,  tx, ty, zHi,  tx + 1, ty, zHi,
         0, 0, 1, 0, 1, 1, 0, 1, @GridTex[texId][0], TEXW, TEXH, light);
    3: DrawTexQuad(mc, tx, ty + 1, zLo,  tx + 1, ty + 1, zLo,  tx + 1, ty + 1, zHi,  tx, ty + 1, zHi,
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
begin
  for side := 0 to 3 do begin
    nbx := tx + SDX[side]; nby := ty + SDY[side];
    if IsWallTile(nbx, nby) then continue;     { a solid neighbor is a full wall }
    nfz := FloorZAt(nbx, nby); ncz := CeilZAt(nbx, nby);
    if (fz <= nfz + EPS) and (cz <= ncz + EPS) then continue;
    nd := sqrt(sqr(nbx + 0.5 - ex) + sqr(nby + 0.5 - ey));
    if side >= 2 then nsscale := NS_DARK else nsscale := 1.0;
    lightN := TileLight(nbx, nby, nd) * nsscale;
    if fz > nfz + EPS then
      WallQuad(mc, side, tx, ty, nfz, fz, TEX_STONE, lightN);    { floor riser }
    if cz > ncz + EPS then
      WallQuad(mc, side, tx, ty, ncz, cz, TEX_STONE, lightN);    { ceiling lintel }
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
    RenderMeshAt(ModelReg[mi].mesh, mc, px, py, 0, ModelReg[mi].scale, yaw, light);
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
      ents[i].wh, light);
  end;
end;

procedure RenderViewPoly;
var
  mc: TMeshCam;
  ex, ey: double;
  tx, ty, x0, y0, x1, y1: longint;
  cx, cy, dist, fwd, light, fcx, fcy, fd, fz, cz: double;
  cyaw, syaw: double;
  ftex, gk, gw: longint;
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
    for tx := x0 to x1 do begin
      cx := tx + 0.5; cy := ty + 0.5;
      fwd := (cx - ex) * cyaw + (cy - ey) * syaw;
      if fwd < -1.3 then continue;            { behind the camera }
      dist := sqrt(sqr(cx - ex) + sqr(cy - ey));

      if IsWallTile(tx, ty) then begin
        ftex := WallTexId(TileAt(tx, ty));
        { a face toward each open neighbor, spanning that neighbor's sector
          floor to ceiling, lit from that neighbor tile }
        if not IsWallTile(tx - 1, ty) then begin   { west face, x = tx }
          fcx := tx; fcy := cy; fd := sqrt(sqr(fcx - ex) + sqr(fcy - ey));
          light := TileLight(tx - 1, ty, fd);
          WallQuad(mc, 0, tx, ty, FloorZAt(tx - 1, ty), CeilZAt(tx - 1, ty), ftex, light);
        end;
        if not IsWallTile(tx + 1, ty) then begin   { east face, x = tx+1 }
          fcx := tx + 1; fcy := cy; fd := sqrt(sqr(fcx - ex) + sqr(fcy - ey));
          light := TileLight(tx + 1, ty, fd);
          WallQuad(mc, 1, tx, ty, FloorZAt(tx + 1, ty), CeilZAt(tx + 1, ty), ftex, light);
        end;
        if not IsWallTile(tx, ty - 1) then begin   { south face, y = ty }
          fcx := cx; fcy := ty; fd := sqrt(sqr(fcx - ex) + sqr(fcy - ey));
          light := TileLight(tx, ty - 1, fd) * NS_DARK;
          WallQuad(mc, 2, tx, ty, FloorZAt(tx, ty - 1), CeilZAt(tx, ty - 1), ftex, light);
        end;
        if not IsWallTile(tx, ty + 1) then begin   { north face, y = ty+1 }
          fcx := cx; fcy := ty + 1; fd := sqrt(sqr(fcx - ex) + sqr(fcy - ey));
          light := TileLight(tx, ty + 1, fd) * NS_DARK;
          WallQuad(mc, 3, tx, ty, FloorZAt(tx, ty + 1), CeilZAt(tx, ty + 1), ftex, light);
        end;
      end else begin
        light := TileLight(tx, ty, dist);
        fz := FloorZAt(tx, ty); cz := CeilZAt(tx, ty);
        { a kit tileset's floors and ceilings are drawn by the CladView pass
          after this loop, at the kit's native scale; only a non-kit cell
          draws the procedural surface quads here }
        if KitIndexForTileset(CellTileset(tx, ty)) < 0 then
        begin
          { floor at this cell's sector height, with an emissive tile's glow tint
            mixed in, as the raycaster does for a light well, brazier or vent }
          gw := 0; gcol := 0;
          gk := LightTileKind(tx, ty);
          if gk >= 0 then LightGlow(gk, gcol, gw);
          DrawTexQuad(mc, tx, ty, fz,  tx + 1, ty, fz,  tx + 1, ty + 1, fz,  tx, ty + 1, fz,
            0, 0, 1, 0, 1, 1, 0, 1, @GridTex[TEX_FLOOR][0], TEXW, TEXH, light, gcol, gw);
          { ceiling at this cell's sector height, unless an open-air surface map }
          if not CurMapSurface then
            DrawTexQuad(mc, tx, ty + 1, cz,  tx + 1, ty + 1, cz,  tx + 1, ty, cz,  tx, ty, cz,
              0, 0, 1, 0, 1, 1, 0, 1, @GridTex[TEX_CEILING][0], TEXW, TEXH, light);
        end;
        { risers and lintels where open neighbors differ in height }
        StepFaces(mc, tx, ty, fz, cz, ex, ey);
      end;
    end;

  { clad the kit tilesets' floors and ceilings at native scale, merging
    aligned cells into whole kit pieces }
  CladView(mc, x0, y0, x1, y1, ex, ey, not CurMapSurface, @TileLight);

  DrawProps(mc, ex, ey, cyaw, syaw);
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
