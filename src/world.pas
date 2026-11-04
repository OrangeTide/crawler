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
  TURN_DUR = 0.12;   { seconds per 90 degree turn and view align }
  LOOK_PITCH_MAX = 120;  { framebuffer pixels }
  LIGHT_RADIUS = 5;      { tiles the party can see }

  VIS_UNSEEN     = 0;
  VIS_REMEMBERED = 1;
  VIS_VISIBLE    = 2;

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
  Seen: array[0 .. MAXMAP - 1, 0 .. MAXMAP - 1] of byte;
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
procedure FreeLook(dyaw, dpitch: double);

procedure ToggleDoor(tx, ty: longint);
procedure OpenDoorAhead;
function PickTile(camX, maxDist: double; out tx, ty: longint): boolean;
function PortalAt(mx, my: longint; out target, marker: string): boolean;
procedure ForwardDelta(out dx, dy: longint);
procedure ComputeVisibility;

implementation

var
  curX, curY: double;                 { animated position }
  viewAng, viewPitch: double;         { free continuous view }
  moving, aligning: boolean;
  fromX, fromY, toX, toY: double;
  fromAng, toAng: double;
  moveT, alignT: double;

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

function AngNorm(a: double): double;
{** Wrap an angle to (-Pi, Pi]. }
begin
  while a > Pi do a := a - 2 * Pi;
  while a <= -Pi do a := a + 2 * Pi;
  AngNorm := a;
end;

function NearestCardinal(a: double): longint;
{** The DIR_* whose angle is closest to a. }
var
  k: longint;
begin
  k := Round(a / (Pi / 2)) mod 4;
  if k < 0 then k := k + 4;
  case k of
    0: NearestCardinal := DIR_E;
    1: NearestCardinal := DIR_S;
    2: NearestCardinal := DIR_W;
  else
    NearestCardinal := DIR_N;
  end;
end;

procedure StartAlign(targetDir: longint);
{** Tween the view to a cardinal by the shortest path. }
begin
  fromAng := viewAng;
  toAng := viewAng + AngNorm(DirAngle(targetDir) - viewAng);
  aligning := true;
  alignT := 0;
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
{** Recompute the rendered camera from the free view angle. }
begin
  Cam.dirX := cos(viewAng);
  Cam.dirY := sin(viewAng);
  Cam.planeX := -sin(viewAng) * 0.66;
  Cam.planeY := cos(viewAng) * 0.66;
  Cam.posX := curX;
  Cam.posY := curY;
  Cam.pitch := viewPitch;
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
      Seen[y][x] := VIS_UNSEEN;
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
  viewAng := DirAngle(FaceDir);
  viewPitch := 0;
  moving := false;
  aligning := false;
  moveT := 0;
  alignT := 0;
  ComputeVisibility;
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
  MotionBusy := moving or aligning;
end;

procedure RequestStep(fwd, strafe: longint);
{** Stepping first aligns the facing to the nearest cardinal of the
  current view, then moves one tile along it. }
var
  fx, fy, rx, ry, dx, dy, nx, ny: longint;
begin
  if MotionBusy then exit;
  FaceDir := NearestCardinal(viewAng);
  StartAlign(FaceDir);
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
  moveT := 0;
end;

procedure RequestTurn(dir: longint);
{** Turn 90 degrees from the current facing and align the view to it,
  taking the shortest path from wherever free look left the view. }
begin
  if MotionBusy then exit;
  FaceDir := (FaceDir + dir + 4) mod 4;
  StartAlign(FaceDir);
end;

procedure UpdateMotion(dt: double);
var
  e: double;
begin
  if moving then begin
    moveT := moveT + dt / STEP_DUR;
    if moveT > 1 then moveT := 1;
    e := 1 - (1 - moveT) * (1 - moveT);   { ease out }
    curX := fromX + (toX - fromX) * e;
    curY := fromY + (toY - fromY) * e;
    if moveT >= 1 then begin
      curX := toX; curY := toY; moving := false;
      ComputeVisibility;
    end;
  end;
  if aligning then begin
    alignT := alignT + dt / TURN_DUR;
    if alignT > 1 then alignT := 1;
    e := 1 - (1 - alignT) * (1 - alignT);
    viewAng := fromAng + (toAng - fromAng) * e;
    if alignT >= 1 then begin
      viewAng := AngNorm(toAng);
      aligning := false;
    end;
  end;
  ApplyCamera;
end;

procedure FreeLook(dyaw, dpitch: double);
{** Mouse free look: rotate the view continuously, cancel any pending
  alignment so the look wins, and never recentre on its own. }
begin
  aligning := false;
  viewAng := viewAng + dyaw;
  viewPitch := viewPitch + dpitch;
  if viewPitch > LOOK_PITCH_MAX then viewPitch := LOOK_PITCH_MAX;
  if viewPitch < -LOOK_PITCH_MAX then viewPitch := -LOOK_PITCH_MAX;
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

function SightClear(x0, y0, x1, y1: longint): boolean;
{** True if no solid tile stands strictly between the two tile centres.
  The endpoints are not treated as blockers, so a wall you look at is
  itself revealed. }
var
  fx, fy, dx, dy, tx, ty: double;
  steps, i: longint;
begin
  SightClear := true;
  fx := x0 + 0.5; fy := y0 + 0.5;
  dx := (x1 - x0); dy := (y1 - y0);
  steps := Round(sqrt(dx * dx + dy * dy) * 4) + 1;
  for i := 1 to steps - 1 do begin
    tx := fx + dx * i / steps;
    ty := fy + dy * i / steps;
    if (trunc(tx) = x1) and (trunc(ty) = y1) then continue;
    if (trunc(tx) = x0) and (trunc(ty) = y0) then continue;
    if IsBlocking(trunc(tx), trunc(ty)) then begin
      SightClear := false;
      exit;
    end;
  end;
end;

procedure ComputeVisibility;
var
  x, y, dx, dy: longint;
begin
  { demote what was visible to remembered }
  for y := 0 to MapH - 1 do
    for x := 0 to MapW - 1 do
      if Seen[y][x] = VIS_VISIBLE then
        Seen[y][x] := VIS_REMEMBERED;
  { mark tiles in sight within the light radius }
  for dy := -LIGHT_RADIUS to LIGHT_RADIUS do
    for dx := -LIGHT_RADIUS to LIGHT_RADIUS do begin
      x := TileX + dx;
      y := TileY + dy;
      if (x < 0) or (x >= MapW) or (y < 0) or (y >= MapH) then continue;
      if dx * dx + dy * dy > LIGHT_RADIUS * LIGHT_RADIUS then continue;
      if SightClear(TileX, TileY, x, y) then
        Seen[y][x] := VIS_VISIBLE;
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
