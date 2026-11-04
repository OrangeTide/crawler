unit world;

{** Active map, grid movement and the raycasting camera.

  Movement is turn based on the tile grid: the party faces one of four
  cardinal directions and steps one tile at a time, and a 90 degree turn
  rotates the facing. Each step and turn is tweened so the motion reads
  smoothly rather than snapping. Free look is a yaw and pitch offset laid
  on top of the facing; it swings the view without changing the grid
  facing and eases back to centre when released.

  The rendered camera (Cam) is recomputed from the animated base each
  frame, so the raycaster and HUD are unchanged. }

{$mode objfpc}{$H+}

interface

uses
  textures, mapfmt;

const
  MAXMAP = 64;

  TILE_EMPTY = 0;
  TILE_DOOR  = TEX_DOOR;

  STEP_DUR = 0.12;   { seconds per tile step }
  TURN_DUR = 0.12;   { seconds per 90 degree turn }
  LOOK_YAW_MAX = 0.9;    { radians, about 50 degrees }
  LOOK_PITCH_MAX = 120;  { framebuffer pixels }

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

  TileX, TileY: longint;   { logical tile the party stands on }
  FaceDir: longint;        { DIR_N / DIR_E / DIR_S / DIR_W }

function LoadMapData(const m: TMapData): boolean;
procedure PlaceAtMarker(const name: string);
function TileAt(mx, my: longint): byte;
function IsBlocking(mx, my: longint): boolean;

procedure RequestStep(fwd, strafe: longint);
procedure RequestTurn(dir: longint);
function MotionBusy: boolean;
procedure UpdateMotion(dt: double);
procedure AddLook(dyaw, dpitch: double);
procedure EaseLook(dt: double);

procedure ToggleDoor(tx, ty: longint);
procedure OpenDoorAhead;
function PickTile(camX, maxDist: double; out tx, ty: longint): boolean;
function PortalAt(mx, my: longint; out target, marker: string): boolean;
procedure ForwardDelta(out dx, dy: longint);

implementation

var
  curX, curY, curAng: double;         { animated camera base }
  moving, turning: boolean;
  fromX, fromY, toX, toY: double;
  fromAng, toAng: double;
  tweenT: double;
  lookYaw, lookPitch: double;

function DirAngle(d: longint): double;
begin
  case d of
    DIR_N: DirAngle := -Pi / 2;
    DIR_E: DirAngle := 0;
    DIR_S: DirAngle := Pi / 2;
  else
    DirAngle := Pi;
  end;
end;

procedure ForwardDelta(out dx, dy: longint);
begin
  case FaceDir of
    DIR_N: begin dx := 0; dy := -1; end;
    DIR_E: begin dx := 1; dy := 0; end;
    DIR_S: begin dx := 0; dy := 1; end;
  else
    begin dx := -1; dy := 0; end;
  end;
end;

procedure ApplyCamera;
{** Recompute the rendered camera from the animated base and look. }
var
  a: double;
begin
  a := curAng + lookYaw;
  Cam.dirX := cos(a);
  Cam.dirY := sin(a);
  Cam.planeX := -sin(a) * 0.66;
  Cam.planeY := cos(a) * 0.66;
  Cam.posX := curX;
  Cam.posY := curY;
  Cam.pitch := lookPitch;
end;

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
      Map[y][x] := 1;
      DoorOpen[y][x] := false;
    end;
  for y := 0 to MapH - 1 do
    for x := 0 to MapW - 1 do
      Map[y][x] := m.walls[y * MapW + x];
  LoadMapData := true;
end;

procedure PlaceAtMarker(const name: string);
var
  i, mi: longint;
begin
  mi := -1;
  for i := 0 to High(CurMap.markers) do
    if CurMap.markers[i].name = name then begin
      mi := i;
      break;
    end;
  if (mi < 0) and (Length(CurMap.markers) > 0) then
    mi := 0;

  if mi >= 0 then begin
    TileX := CurMap.markers[mi].x;
    TileY := CurMap.markers[mi].y;
    FaceDir := CurMap.markers[mi].dir;
  end else begin
    TileX := MapW div 2;
    TileY := MapH div 2;
    FaceDir := DIR_E;
  end;

  curX := TileX + 0.5;
  curY := TileY + 0.5;
  curAng := DirAngle(FaceDir);
  lookYaw := 0;
  lookPitch := 0;
  moving := false;
  turning := false;
  tweenT := 0;
  ApplyCamera;
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

function MotionBusy: boolean;
begin
  MotionBusy := moving or turning;
end;

procedure RequestStep(fwd, strafe: longint);
var
  fx, fy, rx, ry, dx, dy, nx, ny: longint;
begin
  if MotionBusy then exit;
  ForwardDelta(fx, fy);
  rx := -fy;   { right vector is the forward vector turned 90 degrees }
  ry := fx;
  dx := fwd * fx + strafe * rx;
  dy := fwd * fy + strafe * ry;
  if (dx = 0) and (dy = 0) then exit;
  nx := TileX + dx;
  ny := TileY + dy;
  if IsBlocking(nx, ny) then exit;
  fromX := curX; fromY := curY;
  toX := nx + 0.5; toY := ny + 0.5;
  TileX := nx; TileY := ny;
  moving := true;
  tweenT := 0;
end;

procedure RequestTurn(dir: longint);
begin
  if MotionBusy then exit;
  FaceDir := (FaceDir + dir + 4) mod 4;
  fromAng := curAng;
  toAng := curAng + dir * (Pi / 2);
  turning := true;
  tweenT := 0;
end;

procedure UpdateMotion(dt: double);
var
  e: double;
begin
  if moving or turning then begin
    if moving then
      tweenT := tweenT + dt / STEP_DUR
    else
      tweenT := tweenT + dt / TURN_DUR;
    if tweenT > 1 then tweenT := 1;
    e := 1 - (1 - tweenT) * (1 - tweenT);   { ease out }
    if moving then begin
      curX := fromX + (toX - fromX) * e;
      curY := fromY + (toY - fromY) * e;
    end;
    if turning then
      curAng := fromAng + (toAng - fromAng) * e;
    if tweenT >= 1 then begin
      if moving then begin curX := toX; curY := toY; moving := false; end;
      if turning then begin curAng := toAng; turning := false; end;
    end;
  end;
  ApplyCamera;
end;

procedure AddLook(dyaw, dpitch: double);
begin
  lookYaw := lookYaw + dyaw;
  if lookYaw > LOOK_YAW_MAX then lookYaw := LOOK_YAW_MAX;
  if lookYaw < -LOOK_YAW_MAX then lookYaw := -LOOK_YAW_MAX;
  lookPitch := lookPitch + dpitch;
  if lookPitch > LOOK_PITCH_MAX then lookPitch := LOOK_PITCH_MAX;
  if lookPitch < -LOOK_PITCH_MAX then lookPitch := -LOOK_PITCH_MAX;
end;

procedure EaseLook(dt: double);
var
  k: double;
begin
  k := 1 - dt * 10;        { exponential-ish decay toward centre }
  if k < 0 then k := 0;
  lookYaw := lookYaw * k;
  lookPitch := lookPitch * k;
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

procedure ToggleDoor(tx, ty: longint);
begin
  if (tx < 0) or (tx >= MapW) or (ty < 0) or (ty >= MapH) then exit;
  if TileAt(tx, ty) <> TILE_DOOR then exit;
  if (not DoorOpen[ty][tx]) and DoorIsLocked(tx, ty) then exit;
  DoorOpen[ty][tx] := not DoorOpen[ty][tx];
end;

procedure OpenDoorAhead;
var
  dx, dy: longint;
begin
  ForwardDelta(dx, dy);
  ToggleDoor(TileX + dx, TileY + dy);
end;

function PickTile(camX, maxDist: double; out tx, ty: longint): boolean;
{** March a ray from the cursor's screen column until it meets a solid
  tile or runs past maxDist. Returns the tile the ray struck. }
var
  rdx, rdy, t, px, py: double;
begin
  PickTile := false;
  tx := 0; ty := 0;
  rdx := Cam.dirX + Cam.planeX * camX;
  rdy := Cam.dirY + Cam.planeY * camX;
  t := 0.1;
  while t <= maxDist do begin
    px := Cam.posX + rdx * t;
    py := Cam.posY + rdy * t;
    if IsBlocking(trunc(px), trunc(py)) then begin
      tx := trunc(px);
      ty := trunc(py);
      PickTile := true;
      exit;
    end;
    t := t + 0.05;
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
