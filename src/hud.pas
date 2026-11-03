unit hud;

{** Heads-up overlay drawn on top of the 3D view.

  A carved stone border frames the viewport, a compass strip shows the
  facing, a crosshair marks the centre and an optional automap gives an
  overhead view of explored ground. }

{$mode objfpc}{$H+}

interface

procedure DrawHud(showMap: boolean; fps: longint);

implementation

uses
  math, gfx, world;

function NormAngle(a: double): double;
{** Wrap an angle to the range (-Pi, Pi]. }
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
  { bevelled 4px frame around the whole screen }
  FrameRect(0, 0, FBW, FBH, dark);
  FillRect(1, 1, FBW - 2, 3, lit);
  FillRect(1, 1, 3, FBH - 2, lit);
  FillRect(1, FBH - 4, FBW - 2, 3, dark);
  FillRect(FBW - 4, 1, 3, FBH - 2, dark);
  FrameRect(4, 4, FBW - 8, FBH - 8, mid);
end;

procedure DrawCompass;
{** A strip at the top with cardinal letters that scroll with facing.
  Screen angle 0 points along +X (east). }
var
  i, sx: longint;
  ang, a: double;
  mark: char;
  cx: longint;
begin
  FillRect(FBW div 2 - 60, 6, 120, 11, RGB(20, 18, 14));
  FrameRect(FBW div 2 - 60, 6, 120, 11, RGB(90, 84, 70));
  cx := FBW div 2;

  { atan2 of the direction gives the heading; +X is east, 0 radians. }
  ang := ArcTan2(Cam.dirY, Cam.dirX);

  for i := 0 to 3 do begin
    case i of
      0: begin a := 0;        mark := 'E'; end;
      1: begin a := Pi / 2;   mark := 'S'; end;  { +Y is south on screen }
      2: begin a := Pi;       mark := 'W'; end;
    else
      begin a := -Pi / 2;     mark := 'N'; end;
    end;
    { horizontal offset of this cardinal from the view centre }
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

procedure DrawMap;
const
  CELL = 5;
var
  ox, oy, x, y: longint;
  t: byte;
  c: TColor;
  px, py: longint;
begin
  ox := FBW - MAPW * CELL - 8;
  oy := 8;
  FillRect(ox - 2, oy - 2, MAPW * CELL + 4, MAPH * CELL + 4, RGB(10, 10, 12));
  FrameRect(ox - 2, oy - 2, MAPW * CELL + 4, MAPH * CELL + 4, RGB(90, 84, 70));

  for y := 0 to MAPH - 1 do
    for x := 0 to MAPW - 1 do begin
      t := TileAt(x, y);
      if t = TILE_DOOR then begin
        if DoorOpen[y][x] then
          c := RGB(60, 90, 40)
        else
          c := RGB(170, 120, 40);
      end else if t = 0 then
        c := RGB(40, 40, 48)
      else
        c := RGB(100, 96, 88);
      FillRect(ox + x * CELL, oy + y * CELL, CELL - 1, CELL - 1, c);
    end;

  { player marker and a line showing facing }
  px := ox + Trunc(Cam.posX * CELL);
  py := oy + Trunc(Cam.posY * CELL);
  FillRect(px - 1, py - 1, 3, 3, RGB(240, 60, 60));
  PutPixel(px + Round(Cam.dirX * 4), py + Round(Cam.dirY * 4), RGB(255, 230, 120));
end;

procedure DrawHud(showMap: boolean; fps: longint);
var
  s: string;
begin
  DrawBorder;
  DrawCompass;
  DrawCrosshair;
  if showMap then
    DrawMap;

  { status line along the bottom }
  FillRect(8, FBH - 20, FBW - 16, 12, RGB(18, 16, 12));
  Str(fps, s);
  DrawText(12, FBH - 18, 'FPS ' + s, RGB(150, 200, 150));
  DrawText(90, FBH - 18, 'WASD MOVE  ARROWS LOOK  SPACE DOOR  M MAP  ESC QUIT',
    RGB(170, 160, 130));
end;

end.
