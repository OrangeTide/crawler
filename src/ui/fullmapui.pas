unit fullmapui;

{** The full-map overlay: the whole current map with the route preview, the
  player's pins, the auto-markers and any hunters, with the mouse to drop pins
  or pick an auto-travel destination. }

{$mode objfpc}{$H+}

interface

procedure FullMapRender;
procedure FullMapKeyDown(scancode: longint);
procedure FullMapMouseMotion(xrel, yrel: longint);
procedure FullMapMouseButton(button: longint);

implementation

uses
  sdl2min, gfx, gamestate, world, hud, exploreui, pursuit, mappins, pathfind,
  skillbook;

function PinColor(kind: byte): TColor;
begin
  case kind of
    PIN_BANG:   PinColor := RGB(240, 220, 80);
    PIN_QUERY:  PinColor := RGB(90, 200, 230);
    PIN_STAR:   PinColor := RGB(220, 120, 220);
    PIN_STAIR:  PinColor := RGB(235, 235, 235);
    PIN_PORTAL: PinColor := RGB(90, 120, 240);
    PIN_SHOP:   PinColor := RGB(120, 220, 120);
  else PinColor := RGB(200, 200, 200);
  end;
end;

procedure FullMapRender;
{** The full map with the route preview, the player's pins, the auto-markers,
  and any hunters on this map drawn over it. }
var
  i, n, tx, ty: longint;
  path: array[0 .. 2047] of TPathStep;
begin
  DrawFullMap;
  { preview the trail a left click would walk to the tile under the cursor }
  if FullMapTileAt(cursorX, cursorY, tx, ty) then
    if FindPath(CurMap, TileX, TileY, tx, ty, true, path, n,
      PartyCanPickLocks) then
      for i := 1 to n - 2 do
        FullMapMark(path[i].x, path[i].y, RGB(70, 90, 150));
  { the active route's leg on this map, drawn brighter over the hover trail }
  if AutoTravelActive and AutoTravelTargetOnMap(tx, ty) then
    if FindPath(CurMap, TileX, TileY, tx, ty, true, path, n,
      PartyCanPickLocks) then
      for i := 1 to n - 2 do
        FullMapMark(path[i].x, path[i].y, RGB(90, 200, 220));
  for i := 0 to High(Pins) do
    if Pins[i].map = CurMapName then
      FullMapMark(Pins[i].x, Pins[i].y, PinColor(Pins[i].kind));
  for i := 0 to High(Pursuers) do
    if Pursuers[i].active and (Pursuers[i].map = CurMapName) then
      FullMapMark(Pursuers[i].x, Pursuers[i].y, RGB(230, 40, 160));
  { legend across the foot: the manual marks, then the auto markers }
  DrawText(6, FBH - 9, 'RMB PIN', RGB(150, 150, 140));
  DrawText(74, FBH - 9, '!', PinColor(PIN_BANG));
  DrawText(84, FBH - 9, '?', PinColor(PIN_QUERY));
  DrawText(94, FBH - 9, '*', PinColor(PIN_STAR));
  DrawText(120, FBH - 9, 'STAIR', PinColor(PIN_STAIR));
  DrawText(162, FBH - 9, 'PORT', PinColor(PIN_PORTAL));
  DrawText(196, FBH - 9, 'NPC', PinColor(PIN_SHOP));
end;

procedure FullMapKeyDown(scancode: longint);
begin
  case scancode of
    SDL_SCANCODE_TAB, SDL_SCANCODE_ESCAPE, SDL_SCANCODE_M:
      State := gsExplore;
  end;
end;

procedure FullMapMouseMotion(xrel, yrel: longint);
{** Drift the shared cursor over the map, clamped to the screen. }
begin
  cursorX := cursorX + xrel;
  cursorY := cursorY + yrel;
  if cursorX < 0 then cursorX := 0;
  if cursorX > FBW - 1 then cursorX := FBW - 1;
  if cursorY < 0 then cursorY := 0;
  if cursorY > FBH - 1 then cursorY := FBH - 1;
end;

procedure FullMapMouseButton(button: longint);
{** Left click a tile to auto-travel there on the current map, then drop
  back to the first-person view to walk it. }
var
  tx, ty: longint;
begin
  if button = SDL_BUTTON_LEFT then begin
    if FullMapTileAt(cursorX, cursorY, tx, ty) then begin
      StartAutoTravel(CurMapName, tx, ty);
      State := gsExplore;
    end;
  end else if button = SDL_BUTTON_RIGHT then begin
    { right click drops or cycles a pin, without leaving the map }
    if FullMapTileAt(cursorX, cursorY, tx, ty) then
      PinCycleManual(CurMapName, tx, ty);
  end;
end;

end.
