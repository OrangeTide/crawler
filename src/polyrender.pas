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

procedure RenderViewPoly;

implementation

uses
  math, gfx, textures, world, mapfmt, raster, models, meshfmt,
  sprites, worldspr;

const
  VIEW_R = 14;          { tiles drawn around the camera }
  FOCAL  = (FBW / 2) / 0.66;
  NS_DARK = 0.72;       { north/south faces darker, as the raycaster does }

var
  GridTex: array[0 .. TEX_COUNT - 1] of array of byte;   { palette indices }
  gtReady: boolean = false;

procedure BuildGridTex;
var t, i: longint;
begin
  for t := 0 to TEX_COUNT - 1 do begin
    SetLength(GridTex[t], TEXSIZE);
    for i := 0 to TEXSIZE - 1 do GridTex[t][i] := Quantize(Tex[t][i]);
  end;
  gtReady := true;
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
  cx, cy, dist, fwd, light, fcx, fcy, fd: double;
  cyaw, syaw: double;
  ftex: longint;
  shor, syy, sxx: longint;
  sb: byte;
begin
  if not gtReady then BuildGridTex;
  RasterCX := FBW / 2; RasterCY := FBH / 2;
  RasterBeginFrame;
  if CurMapSurface then begin
    { open sky above the horizon; the dark ground below is covered by the
      floor quads, matching the raycaster's surface view }
    shor := round(FBH / 2 + Cam.pitch);
    for syy := 0 to FBH - 1 do begin
      if syy < shor then sb := Quantize(SkyColorAt(syy, shor))
      else sb := Quantize(RGB(6, 6, 10));
      for sxx := 0 to FBW - 1 do FB[syy * FBW + sxx] := sb;
    end;
  end else
    ClearFB(RGB(6, 6, 10));

  ex := Cam.posX; ey := Cam.posY;
  mc.x := ex; mc.y := ey; mc.z := 0.5;
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
        { a face toward each open neighbor, lit from that neighbor tile }
        if not IsWallTile(tx - 1, ty) then begin   { west face, x = tx }
          fcx := tx; fcy := cy; fd := sqrt(sqr(fcx - ex) + sqr(fcy - ey));
          light := TileLight(tx - 1, ty, fd);
          DrawTexQuad(mc, tx, ty, 0,  tx, ty + 1, 0,  tx, ty + 1, 1,  tx, ty, 1,
            0, 0, 1, 0, 1, 1, 0, 1, @GridTex[ftex][0], TEXW, TEXH, light);
        end;
        if not IsWallTile(tx + 1, ty) then begin   { east face, x = tx+1 }
          fcx := tx + 1; fcy := cy; fd := sqrt(sqr(fcx - ex) + sqr(fcy - ey));
          light := TileLight(tx + 1, ty, fd);
          DrawTexQuad(mc, tx + 1, ty + 1, 0,  tx + 1, ty, 0,  tx + 1, ty, 1,  tx + 1, ty + 1, 1,
            0, 0, 1, 0, 1, 1, 0, 1, @GridTex[ftex][0], TEXW, TEXH, light);
        end;
        if not IsWallTile(tx, ty - 1) then begin   { south face, y = ty }
          fcx := cx; fcy := ty; fd := sqrt(sqr(fcx - ex) + sqr(fcy - ey));
          light := TileLight(tx, ty - 1, fd) * NS_DARK;
          DrawTexQuad(mc, tx + 1, ty, 0,  tx, ty, 0,  tx, ty, 1,  tx + 1, ty, 1,
            0, 0, 1, 0, 1, 1, 0, 1, @GridTex[ftex][0], TEXW, TEXH, light);
        end;
        if not IsWallTile(tx, ty + 1) then begin   { north face, y = ty+1 }
          fcx := cx; fcy := ty + 1; fd := sqrt(sqr(fcx - ex) + sqr(fcy - ey));
          light := TileLight(tx, ty + 1, fd) * NS_DARK;
          DrawTexQuad(mc, tx, ty + 1, 0,  tx + 1, ty + 1, 0,  tx + 1, ty + 1, 1,  tx, ty + 1, 1,
            0, 0, 1, 0, 1, 1, 0, 1, @GridTex[ftex][0], TEXW, TEXH, light);
        end;
      end else begin
        light := TileLight(tx, ty, dist);
        { floor }
        DrawTexQuad(mc, tx, ty, 0,  tx + 1, ty, 0,  tx + 1, ty + 1, 0,  tx, ty + 1, 0,
          0, 0, 1, 0, 1, 1, 0, 1, @GridTex[TEX_FLOOR][0], TEXW, TEXH, light);
        { ceiling, unless this is an open-air surface map }
        if not CurMapSurface then
          DrawTexQuad(mc, tx, ty + 1, 1,  tx + 1, ty + 1, 1,  tx + 1, ty, 1,  tx, ty, 1,
            0, 0, 1, 0, 1, 1, 0, 1, @GridTex[TEX_CEILING][0], TEXW, TEXH, light);
      end;
    end;

  DrawProps(mc, ex, ey, cyaw, syaw);
  DrawEntities(mc, ex, ey, cyaw, syaw);
end;

end.
