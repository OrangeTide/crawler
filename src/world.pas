unit world;

{** Active map, player camera and movement.

  The map is no longer hardcoded. A compiled map lump is decoded into the
  working grid, and the party is placed at a named marker. Portals move
  the party to another map. The camera is the Lode-style raycasting
  camera: position, direction vector, view plane and a vertical pitch. }

{$mode objfpc}{$H+}

interface

uses
  textures, mapfmt;

const
  MAXMAP = 64;

  TILE_EMPTY = 0;
  TILE_DOOR  = TEX_DOOR;

type
  TCamera = record
    posX, posY: double;
    dirX, dirY: double;
    planeX, planeY: double;
    pitch: double;
  end;

var
  Cam: TCamera;
  Map: array[0 .. MAXMAP - 1, 0 .. MAXMAP - 1] of byte;
  DoorOpen: array[0 .. MAXMAP - 1, 0 .. MAXMAP - 1] of boolean;
  MapW, MapH: longint;
  CurMap: TMapData;

function LoadMapData(const m: TMapData): boolean;
procedure PlaceAtMarker(const name: string);
function TileAt(mx, my: longint): byte;
function IsBlocking(mx, my: longint): boolean;
procedure MovePlayer(forward, strafe: double);
procedure RotatePlayer(angle: double);
procedure AddPitch(delta: double);
procedure ToggleDoorAhead;
function PortalAt(mx, my: longint; out target, marker: string): boolean;

implementation

function LoadMapData(const m: TMapData): boolean;
var
  x, y: longint;
begin
  LoadMapData := false;
  if (m.w <= 0) or (m.h <= 0) or (m.w > MAXMAP) or (m.h > MAXMAP) then
    exit;
  CurMap := m;
  MapW := m.w;
  MapH := m.h;
  for y := 0 to MAXMAP - 1 do
    for x := 0 to MAXMAP - 1 do begin
      Map[y][x] := 1;            { out of extent reads as wall }
      DoorOpen[y][x] := false;
    end;
  for y := 0 to MapH - 1 do
    for x := 0 to MapW - 1 do
      Map[y][x] := m.walls[y * MapW + x];
  LoadMapData := true;
end;

procedure SetFacing(dir: byte);
{** Point the camera along a cardinal direction, plane square to it. }
begin
  case dir of
    DIR_N: begin Cam.dirX := 0; Cam.dirY := -1; Cam.planeX := 0.66; Cam.planeY := 0; end;
    DIR_E: begin Cam.dirX := 1; Cam.dirY := 0; Cam.planeX := 0; Cam.planeY := 0.66; end;
    DIR_S: begin Cam.dirX := 0; Cam.dirY := 1; Cam.planeX := -0.66; Cam.planeY := 0; end;
  else
    begin Cam.dirX := -1; Cam.dirY := 0; Cam.planeX := 0; Cam.planeY := -0.66; end;
  end;
end;

procedure PlaceAtMarker(const name: string);
var
  i: longint;
begin
  Cam.pitch := 0;
  for i := 0 to High(CurMap.markers) do
    if CurMap.markers[i].name = name then begin
      Cam.posX := CurMap.markers[i].x + 0.5;
      Cam.posY := CurMap.markers[i].y + 0.5;
      SetFacing(CurMap.markers[i].dir);
      exit;
    end;
  { fall back to the first marker, else the centre }
  if Length(CurMap.markers) > 0 then begin
    Cam.posX := CurMap.markers[0].x + 0.5;
    Cam.posY := CurMap.markers[0].y + 0.5;
    SetFacing(CurMap.markers[0].dir);
  end else begin
    Cam.posX := MapW / 2;
    Cam.posY := MapH / 2;
    SetFacing(DIR_E);
  end;
end;

function TileAt(mx, my: longint): byte;
begin
  if (mx < 0) or (mx >= MapW) or (my < 0) or (my >= MapH) then
    TileAt := 1
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
    if (mx < 0) or (mx >= MapW) or (my < 0) or (my >= MapH) then
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
const
  R = 0.18;
var
  nx, ny: double;
  stepX, stepY: double;
begin
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

function DoorIsLocked(mx, my: longint): boolean;
var
  i: longint;
begin
  DoorIsLocked := false;
  for i := 0 to High(CurMap.doors) do
    if (CurMap.doors[i].x = mx) and (CurMap.doors[i].y = my) then begin
      DoorIsLocked := CurMap.doors[i].locked <> 0;
      exit;
    end;
end;

procedure ToggleDoorAhead;
var
  tx, ty: longint;
begin
  tx := trunc(Cam.posX + Cam.dirX * 0.6);
  ty := trunc(Cam.posY + Cam.dirY * 0.6);
  if (tx < 0) or (tx >= MapW) or (ty < 0) or (ty >= MapH) then
    exit;
  if TileAt(tx, ty) = TILE_DOOR then begin
    { A locked door with no key stays shut. Keys arrive with inventory. }
    if (not DoorOpen[ty][tx]) and DoorIsLocked(tx, ty) then
      exit;
    DoorOpen[ty][tx] := not DoorOpen[ty][tx];
  end;
end;

function PortalAt(mx, my: longint; out target, marker: string): boolean;
var
  i: longint;
begin
  PortalAt := false;
  target := '';
  marker := '';
  for i := 0 to High(CurMap.portals) do
    if (CurMap.portals[i].x = mx) and (CurMap.portals[i].y = my) then begin
      target := CurMap.portals[i].target;
      marker := CurMap.portals[i].marker;
      PortalAt := true;
      exit;
    end;
end;

end.
