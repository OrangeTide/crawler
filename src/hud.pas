unit hud;

{** Heads-up overlay and the maps.

  The in-world HUD is deliberately light: a carved border, a compass, a
  crosshair, a small translucent minimap that shows only the explored
  ground around the party, and a party status strip. The fog of war in
  world decides what the maps reveal. A separate fullscreen map replaces
  the 3D view and shows the whole explored level. }

{$mode objfpc}{$H+}

interface

uses
  gfx;

procedure DrawHud(showMap: boolean; fps: longint);
procedure DrawFullMap;
function FullMapTileAt(sx, sy: longint; out tx, ty: longint): boolean;
procedure FullMapMark(tx, ty: longint; col: TColor);

implementation

uses
  math, sysutils, world, party, gametime, mapfmt;

function NormAngle(a: double): double;
begin
  while a > Pi do a := a - 2 * Pi;
  while a <= -Pi do a := a + 2 * Pi;
  NormAngle := a;
end;

procedure DrawBorder;
var
  lit, dark, mid: TColor;
begin
  lit := RGB(120, 112, 96);
  dark := RGB(28, 26, 22);
  mid := RGB(74, 70, 58);
  FrameRect(0, 0, FBW, FBH, dark);
  FillRect(1, 1, FBW - 2, 3, lit);
  FillRect(1, 1, 3, FBH - 2, lit);
  FillRect(1, FBH - 4, FBW - 2, 3, dark);
  FillRect(FBW - 4, 1, 3, FBH - 2, dark);
  FrameRect(4, 4, FBW - 8, FBH - 8, mid);
end;

procedure DrawCompass;
var
  i, sx: longint;
  ang, a: double;
  mark: char;
  cx: longint;
begin
  FillRect(FBW div 2 - 60, 6, 120, 11, RGB(20, 18, 14));
  FrameRect(FBW div 2 - 60, 6, 120, 11, RGB(90, 84, 70));
  cx := FBW div 2;
  ang := ArcTan2(Cam.dirY, Cam.dirX);
  for i := 0 to 3 do begin
    case i of
      0: begin a := 0;        mark := 'E'; end;
      1: begin a := Pi / 2;   mark := 'S'; end;
      2: begin a := Pi;       mark := 'W'; end;
    else
      begin a := -Pi / 2;     mark := 'N'; end;
    end;
    sx := cx + Round(NormAngle(a - ang) * (76.0 / Pi));
    if (sx > FBW div 2 - 56) and (sx < FBW div 2 + 52) then
      DrawChar(sx - 2, 8, mark, RGB(230, 220, 150));
  end;
end;

procedure DrawCrosshair;
var
  cx, cy: longint;
  c: TColor;
begin
  cx := FBW div 2;
  cy := FBH div 2;
  c := RGB(220, 210, 180);
  HLine(cx - 4, cy, 3, c);
  HLine(cx + 2, cy, 3, c);
  VLine(cx, cy - 4, 3, c);
  VLine(cx, cy + 2, 3, c);
end;

function TileColor(tx, ty: longint; out col: TColor): boolean;
{** Pick a minimap colour for a tile from its contents and fog state.
  Returns false if the tile has never been seen. }
var
  vis: byte;
  t: byte;
  dim: boolean;
  pk: longint;
begin
  TileColor := false;
  if (tx < 0) or (tx >= MapW) or (ty < 0) or (ty >= MapH) then exit;
  vis := Seen[ty][tx];
  if vis = VIS_UNSEEN then exit;
  dim := vis = VIS_REMEMBERED;
  t := TileAt(tx, ty);
  pk := PortalKind(tx, ty);
  if pk >= 0 then begin                { exits stand out on the map }
    case pk of
      PK_DOWN, PK_CAVE, PK_SHAFT: col := RGB(240, 180, 80);
      PK_UP: col := RGB(140, 224, 140);
    else col := RGB(80, 200, 255);
    end;
  end
  else if t = TILE_DOOR then begin
    if DoorOpen[ty][tx] then col := RGB(60, 120, 50)
    else col := RGB(175, 125, 45);
  end else if t = 0 then
    col := RGB(60, 60, 72)
  else
    col := RGB(120, 116, 108);
  if dim then
    col := Shade(col, 110);
  TileColor := true;
end;

procedure DrawMiniMap;
const
  WR = 8;              { tiles each side of the party }
  CELL = 3;
var
  span, px, py, dx, dy, tx, ty, fx, fy: longint;
  col: TColor;
begin
  span := (2 * WR + 1) * CELL;
  px := FBW - span - 8;
  py := 8;
  FillRectBlend(px - 2, py - 2, span + 4, span + 4, RGB(10, 10, 14), 170);
  FrameRect(px - 2, py - 2, span + 4, span + 4, RGB(90, 84, 70));

  for dy := -WR to WR do
    for dx := -WR to WR do begin
      tx := TileX + dx;
      ty := TileY + dy;
      if TileColor(tx, ty, col) then
        FillRect(px + (dx + WR) * CELL, py + (dy + WR) * CELL, CELL, CELL, col);
    end;

  { party marker at the centre and a facing tick }
  FillRect(px + WR * CELL, py + WR * CELL, CELL, CELL, RGB(240, 70, 70));
  ForwardDelta(fx, fy);
  PutPixel(px + WR * CELL + 1 + fx * 2, py + WR * CELL + 1 + fy * 2,
    RGB(255, 230, 120));
end;

procedure DrawPartyStrip;
var
  i, n, slotW, x, barW: longint;
  c: TColor;
  nm: string;
begin
  n := Length(Roster);
  if n = 0 then exit;
  slotW := (FBW - 16) div 4;
  FillRectBlend(8, FBH - 26, FBW - 16, 18, RGB(12, 10, 10), 160);
  for i := 0 to n - 1 do begin
    x := 8 + i * slotW + 2;
    if not Roster[i].alive then c := RGB(150, 70, 70)
    else if Roster[i].downed then c := RGB(170, 130, 80)
    else if Roster[i].disease > 0 then c := RGB(150, 190, 110)  { sickly green }
    else c := RGB(200, 205, 180);
    nm := Copy(Roster[i].name, 1, 6);
    DrawText(x, FBH - 24, nm, c);
    { HP bar }
    barW := slotW - 8;
    FillRect(x, FBH - 14, barW, 3, RGB(50, 20, 20));
    if Roster[i].hpMax > 0 then
      FillRect(x, FBH - 14,
        (barW * Roster[i].hp) div Roster[i].hpMax, 3, RGB(70, 170, 70));
  end;
end;

procedure DrawHud(showMap: boolean; fps: longint);
var
  s: string;
  mc: TColor;
begin
  DrawBorder;
  DrawCompass;
  DrawCrosshair;
  if showMap then
    DrawMiniMap;
  DrawPartyStrip;
  { clock and moon readout, top left }
  DrawText(10, 9, 'D' + IntToStr(DayNumber) + ' ' + TimeString, RGB(175, 185, 150));
  if IsFullMoon then mc := RGB(245, 240, 205) else mc := RGB(130, 140, 160);
  DrawText(10, 19, MoonPhaseName, mc);
  Str(fps, s);
  DrawText(12, FBH - 34, 'FPS ' + s, RGB(120, 150, 120));
end;

procedure FullMapLayout(out cell, ox, oy: longint);
{** The cell size and top-left origin the full map is drawn at, shared by
  the renderer and the click-to-tile mapping so they cannot drift apart. }
begin
  cell := (FBW - 24) div MapW;
  if (FBH - 40) div MapH < cell then cell := (FBH - 40) div MapH;
  if cell < 2 then cell := 2;
  if cell > 12 then cell := 12;
  ox := (FBW - MapW * cell) div 2;
  oy := (FBH - MapH * cell) div 2 + 6;
end;

function FullMapTileAt(sx, sy: longint; out tx, ty: longint): boolean;
{** The map tile under a screen point on the full map, or false if the point
  is off the grid. The inverse of the layout FullMapLayout fixes. }
var
  cell, ox, oy: longint;
begin
  FullMapTileAt := false;
  tx := 0; ty := 0;
  FullMapLayout(cell, ox, oy);
  if (sx < ox) or (sy < oy) then exit;
  tx := (sx - ox) div cell;
  ty := (sy - oy) div cell;
  if (tx < 0) or (tx >= MapW) or (ty < 0) or (ty >= MapH) then exit;
  FullMapTileAt := true;
end;

procedure FullMapMark(tx, ty: longint; col: TColor);
{** Fill the cell of one tile on the full map, for an overlay such as a
  hunter marker. Uses the shared layout, so it lines up with the terrain. }
var
  cell, ox, oy: longint;
begin
  if (tx < 0) or (tx >= MapW) or (ty < 0) or (ty >= MapH) then exit;
  FullMapLayout(cell, ox, oy);
  FillRect(ox + tx * cell, oy + ty * cell, cell, cell, col);
end;

procedure DrawFullMap;
var
  cell, ox, oy, x, y: longint;
  col: TColor;
  fx, fy: longint;
begin
  ClearFB(RGB(8, 8, 12));
  FullMapLayout(cell, ox, oy);

  DrawText(12, 8, 'MAP', RGB(220, 200, 120));
  DrawText(FBW - 120, 8, 'TAB OR ESC TO CLOSE', RGB(120, 120, 100));

  for y := 0 to MapH - 1 do
    for x := 0 to MapW - 1 do
      if TileColor(x, y, col) then
        FillRect(ox + x * cell, oy + y * cell, cell, cell, col);

  { player marker }
  FillRect(ox + TileX * cell, oy + TileY * cell, cell, cell, RGB(240, 70, 70));
  ForwardDelta(fx, fy);
  FillRect(ox + (TileX + fx) * cell + cell div 2,
           oy + (TileY + fy) * cell + cell div 2, 2, 2, RGB(255, 230, 120));
end;

end.
