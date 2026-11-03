unit world;

{** Dungeon map, player camera and movement.

  The map is a grid of tiles. A non-zero tile is a solid wall whose
  value selects a wall texture. Door tiles toggle between solid and
  open. The player camera is a Lode-style raycasting camera: a
  position, a direction vector and a view plane, plus a vertical pitch
  used for looking up and down. }

{$mode objfpc}{$H+}

interface

uses
  textures;

const
  MAPW = 24;
  MAPH = 24;

  TILE_EMPTY = 0;
  { 1..4 reuse the TEX_* wall ids from the textures unit. }
  TILE_DOOR  = TEX_DOOR;

type
  TCamera = record
    posX, posY: double;      { position in tile units }
    dirX, dirY: double;      { facing unit vector }
    planeX, planeY: double;  { camera plane, length sets the FOV }
    pitch: double;           { vertical look, in framebuffer pixels }
  end;

var
  Cam: TCamera;
  Map: array[0 .. MAPH - 1, 0 .. MAPW - 1] of byte;
  DoorOpen: array[0 .. MAPH - 1, 0 .. MAPW - 1] of boolean;

procedure InitWorld;
function TileAt(mx, my: longint): byte;
function IsBlocking(mx, my: longint): boolean;
procedure MovePlayer(forward, strafe: double);
procedure RotatePlayer(angle: double);
procedure AddPitch(delta: double);
procedure ToggleDoorAhead;

implementation

const
  { 24x24 dungeon. 1=brick 2=stone 3=moss 4=door, 0=open floor. }
  LAYOUT: array[0 .. MAPH - 1] of string[MAPW] = (
    '111111111111111111111111',
    '100000000002220000000001',
    '101110111102020111011101',
    '101000100000000000100301',
    '101011101110111011101101',
    '100010001000100010001001',
    '111010111011101110101111',
    '100000000000000000000001',
    '101111011110111101111101',
    '100000010000400000010001',
    '101110010111111010011101',
    '101000000100000010000101',
    '101011110101110110110101',
    '100010000101000000010001',
    '111010111101011111010111',
    '100000100000010000000001',
    '101110101111010101111101',
    '101000101000000100000301',
    '101011101011111101110101',
    '100010001000000001000001',
    '111010111110111011101011',
    '103000000000200000000001',
    '100000111002220111000001',
    '111111111111111111111111');

procedure InitWorld;
var
  x, y: longint;
  c: char;
begin
  for y := 0 to MAPH - 1 do
    for x := 0 to MAPW - 1 do begin
      c := LAYOUT[y][x + 1];
      Map[y][x] := byte(ord(c) - ord('0'));
      DoorOpen[y][x] := false;
    end;

  { Start near the top-left in an open cell, facing east. }
  Cam.posX := 2.5;
  Cam.posY := 1.5;
  Cam.dirX := 1.0;
  Cam.dirY := 0.0;
  Cam.planeX := 0.0;
  Cam.planeY := 0.66;  { ~66 degree field of view }
  Cam.pitch := 0.0;
end;

function TileAt(mx, my: longint): byte;
begin
  if (mx < 0) or (mx >= MAPW) or (my < 0) or (my >= MAPH) then
    TileAt := 1        { out of bounds reads as solid wall }
  else
    TileAt := Map[my][mx];
end;

function IsBlocking(mx, my: longint): boolean;
var
  t: byte;
begin
  t := TileAt(mx, my);
  if t = TILE_EMPTY then
    IsBlocking := false
  else if t = TILE_DOOR then begin
    if (mx < 0) or (mx >= MAPW) or (my < 0) or (my >= MAPH) then
      IsBlocking := true
    else
      IsBlocking := not DoorOpen[my][mx];
  end else
    IsBlocking := true;
end;

function Sgn(v: double): double;
begin
  if v > 0 then Sgn := 1.0
  else if v < 0 then Sgn := -1.0
  else Sgn := 0.0;
end;

procedure MovePlayer(forward, strafe: double);
{** Slide along X and Y independently so the player grazes walls
  instead of sticking. A small radius keeps the camera off surfaces. }
const
  R = 0.18;
var
  nx, ny: double;
  stepX, stepY: double;
begin
  { planeX/planeY is the FOV-scaled right vector; divide out its length
    so strafing speed matches forward speed. }
  stepX := Cam.dirX * forward + Cam.planeX / 0.66 * strafe;
  stepY := Cam.dirY * forward + Cam.planeY / 0.66 * strafe;

  nx := Cam.posX + stepX;
  if not IsBlocking(trunc(nx + R * Sgn(stepX)), trunc(Cam.posY)) then
    Cam.posX := nx;

  ny := Cam.posY + stepY;
  if not IsBlocking(trunc(Cam.posX), trunc(ny + R * Sgn(stepY))) then
    Cam.posY := ny;
end;

procedure RotatePlayer(angle: double);
var
  oldDirX, oldPlaneX: double;
  c, s: double;
begin
  c := cos(angle);
  s := sin(angle);
  oldDirX := Cam.dirX;
  Cam.dirX := Cam.dirX * c - Cam.dirY * s;
  Cam.dirY := oldDirX * s + Cam.dirY * c;
  oldPlaneX := Cam.planeX;
  Cam.planeX := Cam.planeX * c - Cam.planeY * s;
  Cam.planeY := oldPlaneX * s + Cam.planeY * c;
end;

procedure AddPitch(delta: double);
begin
  Cam.pitch := Cam.pitch + delta;
  if Cam.pitch > 120 then Cam.pitch := 120;
  if Cam.pitch < -120 then Cam.pitch := -120;
end;

procedure ToggleDoorAhead;
{** Open or close a door in the tile directly in front of the camera. }
var
  tx, ty: longint;
begin
  tx := trunc(Cam.posX + Cam.dirX * 0.6);
  ty := trunc(Cam.posY + Cam.dirY * 0.6);
  if TileAt(tx, ty) = TILE_DOOR then
    DoorOpen[ty][tx] := not DoorOpen[ty][tx];
end;

end.
