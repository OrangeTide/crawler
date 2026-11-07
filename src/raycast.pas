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
  gfx, textures, world, mapfmt, fixedpt, pic, sprites, worldspr;

const
  { Fog in fixed point: fully lit to NEAR (1.5), fading to FAR (9.0). }
  FOG_NEAR_F = 1 * FONE + FONE div 2;        { 1.5 }
  FOG_FAR_F  = 9 * FONE;                      { 9.0 }
  FOG_SPAN_F = FOG_FAR_F - FOG_NEAR_F;
  SKY_GLOW    = $FFFFF5D2;   { warm shaft on a skylight tile }
  MOON_GLOW   = $FF96BEFF;   { pale beam on a moonwell tile }
  BIO_GLOW    = $FF50FFB4;   { bioluminescent growth }
  GAS_GLOW    = $FF8CE0FF;   { a gas vent flame }
  FIRE_GLOW   = $FFFFA030;   { brazier, torch or bonfire }

var
  { Perpendicular wall distance per screen column, in world tiles, filled by
    DrawWalls and read by the sprite pass to occlude billboards behind walls. }
  ColDepth: array[0 .. FBW - 1] of double;

function FogFactor(dist: TFix): longint;
{** Maps a fixed-point distance to a 0..256 brightness scale for Shade. }
var
  frac: TFix;
begin
  if dist <= FOG_NEAR_F then
    FogFactor := 256
  else if dist >= FOG_FAR_F then
    FogFactor := 32          { never fully black, keep a hint of shape }
  else begin
    frac := FDiv(FOG_FAR_F - dist, FOG_SPAN_F);   { 0..1 fixed }
    FogFactor := 32 + ((frac * 224) shr FBITS);
  end;
end;

{ Brightness on a surface: the brighter of the party torch (distance fog)
  and the scene light at the tile (base ambient plus any cast light). }
function LitFactor(torch, tileX, tileY: longint): longint;
var
  scene: longint;
begin
  torch := (torch * TorchGlow) shr 8;   { the party light, dim as it burns out }
  scene := AmbientLight + TileLightAt(tileX, tileY);
  if scene > 256 then scene := 256;
  if torch > scene then LitFactor := torch else LitFactor := scene;
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
  cfPosX, cfPosY, cfDirX, cfDirY, cfPlaneX, cfPlaneY: TFix;
  rayDirX0, rayDirY0, dRayX, dRayY: TFix;
  posZF, rowDistance, floorX, floorY, stepX, stepY: TFix;
  horizon, p: longint;
  isFloor: boolean;
  tx, ty: longint;
  texId: longint;
  fog: longint;
  cF, cC: TColor;
  cxi, cyi, lk, shF: longint;
  skyb: byte;
begin
  cfPosX := FixF(Cam.posX); cfPosY := FixF(Cam.posY);
  cfDirX := FixF(Cam.dirX); cfDirY := FixF(Cam.dirY);
  cfPlaneX := FixF(Cam.planeX); cfPlaneY := FixF(Cam.planeY);
  rayDirX0 := cfDirX - cfPlaneX;
  rayDirY0 := cfDirY - cfPlaneY;
  dRayX := cfPlaneX * 2;     { (dir+plane) - (dir-plane) }
  dRayY := cfPlaneY * 2;
  posZF := FixI(FBH) div 2;
  horizon := FBH div 2 + trunc(Cam.pitch);

  for y := 0 to FBH - 1 do begin
    isFloor := y > horizon;
    if isFloor then
      p := y - horizon
    else
      p := horizon - y;
    if p <= 0 then
      continue;

    { on a surface map the ceiling half becomes an open sky }
    if (not isFloor) and CurMapSurface then begin
      skyb := Quantize(SkyColorAt(y, horizon));
      for x := 0 to FBW - 1 do FB[y * FBW + x] := skyb;
      continue;
    end;

    rowDistance := FDiv(posZF, FixI(p));

    stepX := FDiv(FMul(rowDistance, dRayX), FixI(FBW));
    stepY := FDiv(FMul(rowDistance, dRayY), FixI(FBW));
    floorX := cfPosX + FMul(rowDistance, rayDirX0);
    floorY := cfPosY + FMul(rowDistance, rayDirY0);

    fog := FogFactor(rowDistance);
    if isFloor then
      texId := TEX_FLOOR
    else
      texId := TEX_CEILING;

    for x := 0 to FBW - 1 do begin
      tx := FFloor(FMul(floorX, FixI(TEXW))) and (TEXW - 1);
      ty := FFloor(FMul(floorY, FixI(TEXH))) and (TEXH - 1);
      cxi := FFloor(floorX); cyi := FFloor(floorY);
      shF := LitFactor(fog, cxi, cyi);
      if isFloor then begin
        cF := Shade(Tex[texId][ty * TEXW + tx], shF);
        { light wells and emissive sources glow; an exit now stands as a
          billboard, so its tile carries no coloured floor pad }
        lk := LightTileKind(cxi, cyi);
        case lk of
          LIGHT_SKYLIGHT: cF := MixColor(cF, Shade(SKY_GLOW, shF), 40 + (SkyLightLevel shr 1));
          LIGHT_MOONWELL: cF := MixColor(cF, Shade(MOON_GLOW, shF), 40 + (MoonLightLevel shr 1));
          LIGHT_BIOLUME:  cF := MixColor(cF, Shade(BIO_GLOW, shF), 120);
          LIGHT_GASVENT:  cF := MixColor(cF, Shade(GAS_GLOW, shF), 90);
          LIGHT_BRAZIER, LIGHT_TORCH, LIGHT_BONFIRE:
            cF := MixColor(cF, Shade(FIRE_GLOW, shF), 170);
        end;
        FB[y * FBW + x] := Quantize(cF);
      end else begin
        cC := Shade(Tex[texId][ty * TEXW + tx], shF);
        FB[y * FBW + x] := Quantize(cC);
      end;
      floorX := floorX + stepX;
      floorY := floorY + stepY;
    end;
  end;
end;

procedure DrawWalls;
var
  x: longint;
  cfPosX, cfPosY, cfDirX, cfDirY, cfPlaneX, cfPlaneY: TFix;
  cameraX, rayDirX, rayDirY: TFix;
  mapX, mapY: longint;
  sideDistX, sideDistY, deltaDistX, deltaDistY, perpWallDist: TFix;
  stepX, stepY: longint;
  hit, side: longint;
  tile: byte;
  lineHeight, drawStart, drawEnd, horizon, tmp: longint;
  wallX: TFix;
  texId, texX, texY, y: longint;
  texStep, texPos: TFix;
  fog: longint;
  c: TColor;
begin
  cfPosX := FixF(Cam.posX); cfPosY := FixF(Cam.posY);
  cfDirX := FixF(Cam.dirX); cfDirY := FixF(Cam.dirY);
  cfPlaneX := FixF(Cam.planeX); cfPlaneY := FixF(Cam.planeY);
  horizon := FBH div 2 + trunc(Cam.pitch);

  for x := 0 to FBW - 1 do begin
    cameraX := FixI(2 * x) div FBW - FONE;   { 2*x/FBW - 1 }
    rayDirX := cfDirX + FMul(cfPlaneX, cameraX);
    rayDirY := cfDirY + FMul(cfPlaneY, cameraX);

    mapX := FFloor(cfPosX);
    mapY := FFloor(cfPosY);

    if rayDirX = 0 then deltaDistX := $7FFFFFFF
    else deltaDistX := FDiv(FONE, FAbs(rayDirX));
    if rayDirY = 0 then deltaDistY := $7FFFFFFF
    else deltaDistY := FDiv(FONE, FAbs(rayDirY));

    if rayDirX < 0 then begin
      stepX := -1;
      sideDistX := FMul(cfPosX - FixI(mapX), deltaDistX);
    end else begin
      stepX := 1;
      sideDistX := FMul(FixI(mapX) + FONE - cfPosX, deltaDistX);
    end;
    if rayDirY < 0 then begin
      stepY := -1;
      sideDistY := FMul(cfPosY - FixI(mapY), deltaDistY);
    end else begin
      stepY := 1;
      sideDistY := FMul(FixI(mapY) + FONE - cfPosY, deltaDistY);
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
      if IsWallTile(mapX, mapY) then begin
        tile := TileAt(mapX, mapY);
        hit := 1;
      end;
    end;

    if side = 0 then
      perpWallDist := sideDistX - deltaDistX
    else
      perpWallDist := sideDistY - deltaDistY;
    if perpWallDist < 8 then
      perpWallDist := 8;   { ~0.0001, guards the divide }
    ColDepth[x] := perpWallDist / (1.0 * FONE);   { world tiles, for sprites }

    { line height as a plain integer so a near wall cannot overflow fixed }
    lineHeight := longint((int64(FBH) shl FBITS) div perpWallDist);
    if lineHeight <= 0 then continue;
    drawStart := -lineHeight div 2 + horizon;
    drawEnd := lineHeight div 2 + horizon;

    { Where along the tile face the ray landed, for the texture column. }
    if side = 0 then
      wallX := cfPosY + FMul(perpWallDist, rayDirY)
    else
      wallX := cfPosX + FMul(perpWallDist, rayDirX);
    wallX := FFrac(wallX);

    texId := WallTexId(tile);
    texX := FFloor(FMul(wallX, FixI(TEXW)));
    if (side = 0) and (rayDirX > 0) then texX := TEXW - texX - 1;
    if (side = 1) and (rayDirY < 0) then texX := TEXW - texX - 1;
    if texX < 0 then texX := 0;
    if texX > TEXW - 1 then texX := TEXW - 1;

    fog := FogFactor(perpWallDist);
    { North/south faces a touch darker to read the grid in the gloom. }
    if side = 1 then
      fog := fog * 72 div 100;
    fog := LitFactor(fog, mapX, mapY);   { fold in scene and cast light }

    texStep := TFix((int64(TEXH) shl FBITS) div lineHeight);
    tmp := (drawStart - horizon) + (lineHeight div 2);
    texPos := TFix(int64(tmp) * int64(texStep));

    if drawStart < 0 then begin
      texPos := texPos + TFix(int64(-drawStart) * int64(texStep));
      drawStart := 0;
    end;
    if drawEnd > FBH - 1 then
      drawEnd := FBH - 1;

    for y := drawStart to drawEnd do begin
      texY := FFloor(texPos) and (TEXH - 1);
      texPos := texPos + texStep;
      c := Shade(Tex[texId][texY * TEXW + texX], fog);
      FB[y * FBW + x] := Quantize(c);
    end;
  end;
end;

procedure DrawSprites;
{** Classic distance-sorted raycaster sprite pass. Each entity is projected
  to camera space, the list drawn far to near, and every billboard column is
  skipped where the wall at that column stands nearer than the sprite. }
var
  ents: array[0 .. 63] of TWorldSprite;
  order: array[0 .. 63] of longint;
  dist: array[0 .. 63] of double;
  n, i, j, stripe, yy, texX, texY, tmp, horizon: longint;
  posX, posY, dirX, dirY, planeX, planeY, invDet: double;
  spriteX, spriteY, transformX, transformY: double;
  spriteScreenX, unitH, spriteH, spriteW, vTop, vBase: double;
  drawStartX, drawEndX, drawStartY, drawEndY, litI, fog, iw, ih: longint;
  img: ^TImage;
  src: TColor;
begin
  n := GatherWorldSprites(ents);
  if n = 0 then exit;
  posX := Cam.posX; posY := Cam.posY;
  dirX := Cam.dirX; dirY := Cam.dirY;
  planeX := Cam.planeX; planeY := Cam.planeY;
  horizon := FBH div 2 + trunc(Cam.pitch);
  invDet := 1.0 / (planeX * dirY - dirX * planeY);

  for i := 0 to n - 1 do begin
    order[i] := i;
    dist[i] := sqr(posX - ents[i].x) + sqr(posY - ents[i].y);
  end;
  for i := 0 to n - 2 do
    for j := 0 to n - 2 - i do
      if dist[order[j]] < dist[order[j + 1]] then begin
        tmp := order[j]; order[j] := order[j + 1]; order[j + 1] := tmp;
      end;

  for i := 0 to n - 1 do begin
    img := @SpriteReg[ents[order[i]].img].img;
    iw := img^.w; ih := img^.h;
    if (iw <= 0) or (ih <= 0) or (Length(img^.pix) = 0) then continue;
    spriteX := ents[order[i]].x - posX;
    spriteY := ents[order[i]].y - posY;
    transformX := invDet * (dirY * spriteX - dirX * spriteY);
    transformY := invDet * (planeX * spriteY - planeY * spriteX);   { depth }
    if transformY <= 0.05 then continue;                 { behind the camera }

    spriteScreenX := (FBW / 2) * (1 + transformX / transformY);
    unitH := FBH / transformY;              { a one-tile-tall wall in pixels }
    spriteH := unitH * ents[order[i]].wh;
    spriteW := unitH * (ents[order[i]].wh * iw / ih);
    if (spriteW < 0.001) or (spriteH < 0.001) then continue;
    vBase := horizon + unitH / 2;           { the floor line at this depth }
    vTop := vBase - spriteH;

    drawStartX := round(spriteScreenX - spriteW / 2);
    drawEndX   := round(spriteScreenX + spriteW / 2);
    drawStartY := round(vTop);
    drawEndY   := round(vBase);

    fog := FogFactor(FixF(transformY));
    litI := LitFactor(fog, trunc(ents[order[i]].x), trunc(ents[order[i]].y));

    for stripe := drawStartX to drawEndX do begin
      if (stripe < 0) or (stripe > FBW - 1) then continue;
      if transformY >= ColDepth[stripe] then continue;   { occluded by a wall }
      texX := trunc((stripe - (spriteScreenX - spriteW / 2)) / spriteW * iw);
      if texX < 0 then texX := 0 else if texX > iw - 1 then texX := iw - 1;
      for yy := drawStartY to drawEndY do begin
        if (yy < 0) or (yy > FBH - 1) then continue;
        texY := trunc((yy - vTop) / spriteH * ih);
        if texY < 0 then texY := 0 else if texY > ih - 1 then texY := ih - 1;
        src := img^.pix[texY * iw + texX];
        if (src shr 24) < 128 then continue;              { transparent texel }
        if litI >= 256 then
          FB[yy * FBW + stripe] := Quantize(src)
        else
          FB[yy * FBW + stripe] := Quantize(Shade(src, litI));
      end;
    end;
  end;
end;

procedure RenderView;
begin
  DrawFloorCeiling;
  DrawWalls;
  DrawSprites;
end;

end.
