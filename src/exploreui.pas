unit exploreui;

{** The exploration state: first-person movement and the things that
  happen as the party walks. Input and rendering for the dungeon view,
  interaction with doors and NPCs, tile events (portals, traps, light
  puzzles, wandering monsters), resting, and the lycanthropy check that
  runs in every state. It calls down into worldload for map changes and
  combatui to start a fight; neither calls back up. }

{$mode objfpc}{$H+}

interface

procedure ExploreKeyDown(scancode: longint);
procedure ExploreMouseMotion(xrel, yrel: longint);
procedure ExploreMouseButton(down: boolean; button: longint);
procedure ExploreUpdate(dt: double);
procedure ExploreRender(fps: longint);
procedure UpdateLycanthropy;

implementation

uses
  sysutils, sdl2min, gfx, mapfmt, world, raycast, polyrender, hud, dialog,
  flags, gametime, party, rules, rng, encounters, audio, gamestate, worldload,
  combatui, save;

const
  MOUSE_YAW    = 0.0040;  { radians per mouse unit, free look }
  MOUSE_PITCH  = 0.7;     { pixels per mouse unit, free look }

procedure RestHere; forward;

procedure StartDialog(const dlgName, npcName: string);
begin
  DialogStart(dlgName);
  if DlgActive then begin
    dlgNpcName := npcName;
    State := gsDialog;
  end;
end;

procedure ExploreInteract;
{** Left click: act on whatever tile the cursor points at. A door opens,
  an NPC starts talking. }
var
  camX: double;
  tx, ty: longint;
  dlg, nm: string;
begin
  camX := 2.0 * cursorX / FBW - 1.0;
  if PickTile(camX, 1.8, tx, ty) then begin
    if NpcAt(tx, ty, dlg, nm) then
      StartDialog(dlg, nm)
    else if TileAt(tx, ty) = TILE_DOOR then begin
      ToggleDoor(tx, ty);
      PlaySfx(SFX_DOOR);
    end;
  end;
end;

procedure InteractAhead;
{** Space: talk to an NPC directly ahead, else open a door. }
var
  dx, dy: longint;
  dlg, nm: string;
begin
  ForwardDelta(dx, dy);
  if NpcAt(TileX + dx, TileY + dy, dlg, nm) then
    StartDialog(dlg, nm)
  else begin
    OpenDoorAhead;
    PlaySfx(SFX_DOOR);
  end;
end;

procedure ExploreKeyDown(scancode: longint);
begin
  case scancode of
    SDL_SCANCODE_ESCAPE: QuitRequested := true;
    SDL_SCANCODE_SPACE:  InteractAhead;
    SDL_SCANCODE_M:      showMap := not showMap;
    SDL_SCANCODE_P:      UsePoly := not UsePoly;   { A/B the renderers }
    SDL_SCANCODE_TAB:    State := gsFullMap;
    SDL_SCANCODE_J:      State := gsMenu;
    SDL_SCANCODE_R:      RestHere;
    SDL_SCANCODE_C:      if Length(Roster) > 0 then StartCombat(1);
    SDL_SCANCODE_F5: begin
      if SaveGame(SavePath) then saveMsg := 'GAME SAVED'
      else saveMsg := 'SAVE FAILED';
      saveMsgT := 2.0;
    end;
    SDL_SCANCODE_F9:
      if ContinueGame then begin
        saveMsg := 'GAME LOADED';
        saveMsgT := 2.0;
      end;
  end;
end;

procedure ExploreMouseMotion(xrel, yrel: longint);
begin
  if rmbHeld then
    FreeLook(xrel * MOUSE_YAW, -yrel * MOUSE_PITCH)
  else begin
    cursorX := cursorX + xrel;
    cursorY := cursorY + yrel;
    if cursorX < 6 then cursorX := 6;
    if cursorX > FBW - 6 then cursorX := FBW - 6;
    if cursorY < 6 then cursorY := 6;
    if cursorY > FBH - 6 then cursorY := FBH - 6;
  end;
end;

procedure ExploreMouseButton(down: boolean; button: longint);
begin
  if button = SDL_BUTTON_RIGHT then
    rmbHeld := down
  else if (button = SDL_BUTTON_LEFT) and down then
    ExploreInteract;
end;

procedure RestHere;
{** Camp to recover. Away from town a rest risks a wandering monster. }
begin
  if Length(Roster) = 0 then exit;
  if (CurMapName <> 'TOWN') and (Range(1, 6) = 1) then begin
    saveMsg := 'AMBUSHED WHILE RESTING!';
    saveMsgT := 2.0;
    StartCombat(2);
    exit;
  end;
  RestParty;
  TimeAdvance(8 * 60);   { a long rest moves the clock by eight hours }
  PlaySfx(SFX_SELECT);
  saveMsg := 'THE PARTY RESTS AND RECOVERS';
  saveMsgT := 2.0;
end;

procedure PoisonTick;
{** Each step, poisoned members lose a point until it clears. }
var
  i: longint;
begin
  for i := 0 to High(Roster) do
    if Roster[i].alive and (Roster[i].poison > 0) then begin
      dec(Roster[i].poison);
      if Roster[i].hp > 1 then dec(Roster[i].hp);
    end;
end;

procedure TrapCheck;
{** A trap on the tile springs once; the lead member rolls a Dodge save,
  and on a failure the party takes damage and the lead is poisoned. }
var
  dmg, dc, lead, i, hit: longint;
  sprung: string;
begin
  if not TrapAt(TileX, TileY, dmg, dc) then exit;
  sprung := 'TRAP_' + CurMapName + '_' + IntToStr(TileX) + '_' + IntToStr(TileY);
  if FlagHas(sprung) then exit;
  FlagSet(sprung);
  lead := FirstConscious;
  if lead < 0 then exit;
  if SaveThrow(GameRng, AbilMod(Roster[lead].abil[abDEX]), Roster[lead].level, dc) then begin
    saveMsg := 'YOU SPOT AND AVOID A TRAP';
    saveMsgT := 2.0;
    exit;
  end;
  for i := 0 to High(Roster) do
    if Roster[i].alive and (not Roster[i].downed) then begin
      hit := D(dmg);
      Roster[i].hp := Roster[i].hp - hit;
      if Roster[i].hp <= 0 then begin
        Roster[i].hp := 0;
        Roster[i].downed := true;
      end;
    end;
  Roster[lead].poison := Roster[lead].poison + 3;
  PlaySfx(SFX_HIT);
  saveMsg := 'A TRAP SPRINGS!';
  saveMsgT := 2.0;
end;

procedure OpenAdjacentDoor(tx, ty: longint);
{** Force a closed door tile open, used when a light well is lit. }
begin
  if (TileAt(tx, ty) = TILE_DOOR) and (ty >= 0) and (ty < MapH)
    and (tx >= 0) and (tx < MapW) and (not DoorOpen[ty][tx]) then
    ToggleDoor(tx, ty);
end;

procedure LightPuzzleCheck;
{** A skylight lit by day, or a moonwell at the full moon by night, sets
  a LIT flag for its tile and opens any door beside it. }
var
  lk: longint;
  active: boolean;
begin
  lk := LightTileKind(TileX, TileY);
  if lk < 0 then exit;
  active := ((lk = LIGHT_SKYLIGHT) and (DaylightFactor >= 160))
         or ((lk = LIGHT_MOONWELL) and IsFullMoon and IsNight);
  if not active then exit;
  FlagSet('LIT_' + CurMapName + '_' + IntToStr(TileX) + '_' + IntToStr(TileY));
  OpenAdjacentDoor(TileX + 1, TileY);
  OpenAdjacentDoor(TileX - 1, TileY);
  OpenAdjacentDoor(TileX, TileY + 1);
  OpenAdjacentDoor(TileX, TileY - 1);
  if lk = LIGHT_MOONWELL then saveMsg := 'MOONLIGHT OPENS THE WAY'
  else saveMsg := 'SUNLIGHT OPENS THE WAY';
  saveMsgT := 2.0;
end;

procedure CheckTileEvents;
{** On stepping onto a new tile: follow a portal, spring a trap, tick
  poison, then roll for a wandering monster (thinned out per step). }
var
  target, marker: string;
begin
  if (TileX = lastTX) and (TileY = lastTY) then
    exit;
  lastTX := TileX;
  lastTY := TileY;
  TimeAdvance(3);   { a few minutes pass each tile }
  if PortalAt(TileX, TileY, target, marker) then begin
    LoadMapByName(target, marker);
    exit;
  end;
  PoisonTick;
  TrapCheck;
  LightPuzzleCheck;
  if not PartyConscious then begin
    State := gsGameOver;
    exit;
  end;
  { Safe areas (those whose table is empty, like town and interiors) never
    spawn foes; elsewhere a small per-step chance, scaled by depth. }
  if (not EncTableEmpty(CurEncTable)) and (Length(Roster) > 0) then
    if Range(1, 18) = 1 then begin
      if CurDepth > 0 then StartCombat(CurDepth) else StartCombat(1);
    end;
end;

procedure ExploreUpdate(dt: double);
begin
  { One grid action per idle moment; the tween gates auto-repeat. }
  if not MotionBusy then begin
    if KeyDown(SDL_SCANCODE_W) or KeyDown(SDL_SCANCODE_UP) then
      RequestStep(1, 0)
    else if KeyDown(SDL_SCANCODE_S) or KeyDown(SDL_SCANCODE_DOWN) then
      RequestStep(-1, 0)
    else if KeyDown(SDL_SCANCODE_A) then
      RequestStep(0, -1)
    else if KeyDown(SDL_SCANCODE_D) then
      RequestStep(0, 1)
    else if KeyDown(SDL_SCANCODE_Q) or KeyDown(SDL_SCANCODE_LEFT) then
      RequestTurn(-1)
    else if KeyDown(SDL_SCANCODE_E) or KeyDown(SDL_SCANCODE_RIGHT) then
      RequestTurn(1);
  end;

  UpdateMotion(dt);
  if saveMsgT > 0 then saveMsgT := saveMsgT - dt;
  CheckTileEvents;
end;

procedure DrawCursor;
var
  c: TColor;
begin
  c := RGB(240, 230, 160);
  HLine(cursorX - 4, cursorY, 9, c);
  VLine(cursorX, cursorY - 4, 9, c);
  PutPixel(cursorX, cursorY, RGB(40, 30, 10));
end;

procedure UpdateWorldLight;
{** Feed the clock into the renderer: surface maps darken at night, and
  light wells glow by the current sun and moon. }
begin
  if CurMapSurface then AmbientLight := OutdoorAmbient
  else AmbientLight := 48;   { a dim underworld, lifted by fires and glow }
  SkyLightLevel := DaylightFactor;
  MoonLightLevel := MoonlightFactor;
end;

procedure UpdateLycanthropy;
{** The full moon transforms the cursed wherever they are, even deep
  underground, and the change reverts when it wanes. }
var
  i: longint;
  full, was: boolean;
begin
  full := IsFullMoon;
  for i := 0 to High(Roster) do begin
    if not Roster[i].lycan then begin
      Roster[i].wereform := false;
      continue;
    end;
    was := Roster[i].wereform;
    Roster[i].wereform := full and Roster[i].alive;
    if Roster[i].wereform and (not was) then
      JournalAdd(Roster[i].name + ' transforms under the full moon!')
    else if was and (not Roster[i].wereform) then
      JournalAdd(Roster[i].name + ' returns to their own shape.');
  end;
end;

procedure ExploreRender(fps: longint);
begin
  UpdateWorldLight;
  if UsePoly then RenderViewPoly else RenderView;
  DrawHud(showMap, fps);
  if saveMsgT > 0 then
    DrawText(FBW div 2 - Length(saveMsg) * 3, 22, saveMsg, RGB(230, 220, 150));
  DrawCursor;
end;

end.
