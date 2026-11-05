unit raycast;

{** Textured raycasting renderer.

  Renders the world from the player camera into the gfx framebuffer.
  Walls use a DDA grid cast (Lode Vandevenne's method). Floor and
  ceiling are drawn by horizontal span casting. A vertical pitch offset
  shifts the horizon so the camera can look up and down, and distance
  fog darkens surfaces toward black for the dungeon mood. }

{$mode objfpc}{$H+}

interface

procedure RenderView;

implementation

uses
  gfx, textures, world, mapfmt;

const
  { Fog: surfaces fully lit up to NEAR, fading to black at FAR tiles. }
  FOG_NEAR = 1.5;
  FOG_FAR  = 9.0;
  PORTAL_GLOW = $FF50C8FF;   { cyan pad: a flat transition or gate }
  DOWN_GLOW   = $FFFFB450;   { amber pad: stairs or a cave mouth down }
  UP_GLOW     = $FF8CE08C;   { green pad: stairs up }
  SKY_GLOW    = $FFFFF5D2;   { warm shaft on a skylight tile }
  MOON_GLOW   = $FF96BEFF;   { pale beam on a moonwell tile }

function FogFactor(dist: double): longint;
{** Maps a distance to a 0..256 brightness scale for Shade. }
var
  f: double;
begin
  if dist <= FOG_NEAR then
    FogFactor := 256
  else if dist >= FOG_FAR then
    FogFactor := 32          { never fully black, keep a hint of shape }
  else begin
    f := 1.0 - (dist - FOG_NEAR) / (FOG_FAR - FOG_NEAR);
    FogFactor := 32 + trunc(f * 224.0);
  end;
  { outdoor day-night and the like scale the whole view }
  FogFactor := FogFactor * AmbientLight shr 8;
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

procedure DrawFloorCeiling;
{** Horizontal span cast for both floor and ceiling in one pass. For
  each scanline we find the world distance of that row, then walk the
  texture coordinate across the screen. }
var
  y, x: longint;
  rayDirX0, rayDirY0, rayDirX1, rayDirY1: double;
  posZ, rowDistance: double;
  floorX, floorY, stepX, stepY: double;
  horizon, p: longint;
  isFloor: boolean;
  tx, ty: longint;
  texId: longint;
  fog: longint;
  cF, cC: TColor;
  cxi, cyi, lk, pk: longint;
  gc: TColor;
begin
  rayDirX0 := Cam.dirX - Cam.planeX;
  rayDirY0 := Cam.dirY - Cam.planeY;
  rayDirX1 := Cam.dirX + Cam.planeX;
  rayDirY1 := Cam.dirY + Cam.planeY;
  posZ := 0.5 * FBH;
  horizon := FBH div 2 + trunc(Cam.pitch);

  for y := 0 to FBH - 1 do begin
    isFloor := y > horizon;
    if isFloor then
      p := y - horizon
    else
      p := horizon - y;
    if p <= 0 then
      continue;

    rowDistance := posZ / p;

    stepX := rowDistance * (rayDirX1 - rayDirX0) / FBW;
    stepY := rowDistance * (rayDirY1 - rayDirY0) / FBW;
    floorX := Cam.posX + rowDistance * rayDirX0;
    floorY := Cam.posY + rowDistance * rayDirY0;

    fog := FogFactor(rowDistance);
    if isFloor then
      texId := TEX_FLOOR
    else
      texId := TEX_CEILING;

    for x := 0 to FBW - 1 do begin
      tx := trunc(floorX * TEXW) and (TEXW - 1);
      ty := trunc(floorY * TEXH) and (TEXH - 1);
      if isFloor then begin
        cF := Shade(Tex[texId][ty * TEXW + tx], fog);
        cxi := trunc(floorX); cyi := trunc(floorY);
        { a glowing pad marks a portal; a shaft marks a sky or moon well }
        if IsPortalTile(cxi, cyi) then begin
          pk := PortalKind(cxi, cyi);
          case pk of
            PK_DOWN, PK_CAVE, PK_SHAFT: gc := DOWN_GLOW;
            PK_UP: gc := UP_GLOW;
          else gc := PORTAL_GLOW;
          end;
          cF := MixColor(cF, Shade(gc, fog), 150);
        end
        else begin
          lk := LightTileKind(cxi, cyi);
          if lk = LIGHT_SKYLIGHT then
            cF := MixColor(cF, Shade(SKY_GLOW, fog), 40 + (SkyLightLevel shr 1))
          else if lk = LIGHT_MOONWELL then
            cF := MixColor(cF, Shade(MOON_GLOW, fog), 40 + (MoonLightLevel shr 1));
        end;
        FB[y * FBW + x] := cF;
      end else begin
        cC := Shade(Tex[texId][ty * TEXW + tx], fog);
        FB[y * FBW + x] := cC;
      end;
      floorX := floorX + stepX;
      floorY := floorY + stepY;
    end;
  end;
end;

procedure DrawWalls;
var
  x: longint;
  cameraX: double;
  rayDirX, rayDirY: double;
  mapX, mapY: longint;
  sideDistX, sideDistY: double;
  deltaDistX, deltaDistY: double;
  perpWallDist: double;
  stepX, stepY: longint;
  hit, side: longint;
  tile: byte;
  lineHeight, drawStart, drawEnd, horizon: longint;
  wallX: double;
  texId, texX, texY, y: longint;
  texStep, texPos: double;
  fog: longint;
  c: TColor;
begin
  horizon := FBH div 2 + trunc(Cam.pitch);

  for x := 0 to FBW - 1 do begin
    cameraX := 2.0 * x / FBW - 1.0;
    rayDirX := Cam.dirX + Cam.planeX * cameraX;
    rayDirY := Cam.dirY + Cam.planeY * cameraX;

    mapX := trunc(Cam.posX);
    mapY := trunc(Cam.posY);

    if rayDirX = 0 then deltaDistX := 1e30
    else deltaDistX := abs(1.0 / rayDirX);
    if rayDirY = 0 then deltaDistY := 1e30
    else deltaDistY := abs(1.0 / rayDirY);

    if rayDirX < 0 then begin
      stepX := -1;
      sideDistX := (Cam.posX - mapX) * deltaDistX;
    end else begin
      stepX := 1;
      sideDistX := (mapX + 1.0 - Cam.posX) * deltaDistX;
    end;
    if rayDirY < 0 then begin
      stepY := -1;
      sideDistY := (Cam.posY - mapY) * deltaDistY;
    end else begin
      stepY := 1;
      sideDistY := (mapY + 1.0 - Cam.posY) * deltaDistY;
    end;

    { DDA: step through grid cells until a blocking tile is hit. }
    hit := 0;
    side := 0;
    tile := 0;
    while hit = 0 do begin
      if sideDistX < sideDistY then begin
        sideDistX := sideDistX + deltaDistX;
        mapX := mapX + stepX;
        side := 0;
      end else begin
        sideDistY := sideDistY + deltaDistY;
        mapY := mapY + stepY;
        side := 1;
      end;
      if IsBlocking(mapX, mapY) then begin
        tile := TileAt(mapX, mapY);
        hit := 1;
      end;
    end;

    if side = 0 then
      perpWallDist := sideDistX - deltaDistX
    else
      perpWallDist := sideDistY - deltaDistY;
    if perpWallDist < 0.0001 then
      perpWallDist := 0.0001;

    lineHeight := trunc(FBH / perpWallDist);
    drawStart := -lineHeight div 2 + horizon;
    drawEnd := lineHeight div 2 + horizon;

    { Where along the tile face the ray landed, for the texture column. }
    if side = 0 then
      wallX := Cam.posY + perpWallDist * rayDirY
    else
      wallX := Cam.posX + perpWallDist * rayDirX;
    wallX := wallX - trunc(wallX);

    texId := WallTexId(tile);
    texX := trunc(wallX * TEXW);
    if (side = 0) and (rayDirX > 0) then texX := TEXW - texX - 1;
    if (side = 1) and (rayDirY < 0) then texX := TEXW - texX - 1;
    if texX < 0 then texX := 0;
    if texX > TEXW - 1 then texX := TEXW - 1;

    fog := FogFactor(perpWallDist);
    { North/south faces a touch darker to read the grid in the gloom. }
    if side = 1 then
      fog := fog * 72 div 100;

    texStep := TEXH / lineHeight;
    texPos := (drawStart - horizon + lineHeight / 2) * texStep;

    if drawStart < 0 then begin
      texPos := texPos + texStep * (-drawStart);
      drawStart := 0;
    end;
    if drawEnd > FBH - 1 then
      drawEnd := FBH - 1;

    for y := drawStart to drawEnd do begin
      texY := trunc(texPos) and (TEXH - 1);
      texPos := texPos + texStep;
      c := Shade(Tex[texId][texY * TEXW + texX], fog);
      FB[y * FBW + x] := c;
    end;
  end;
end;

procedure RenderView;
begin
  DrawFloorCeiling;
  DrawWalls;
end;

end.
