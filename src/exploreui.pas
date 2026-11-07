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
{ Walk the party to (dx,dy) on destMap, following a cross-map route. Fails
  quietly (with a message) if no known route reaches it. }
procedure StartAutoTravel(const destMap: string; dx, dy: longint);
procedure CancelAutoTravel;
function AutoTravelActive: boolean;
{ The current route leg's target tile on the current map, for the full-map
  preview. False when no route is active or its current leg is elsewhere. }
function AutoTravelTargetOnMap(out tx, ty: longint): boolean;

implementation

uses
  sysutils, sdl2min, gfx, mapfmt, world, raycast, polyrender, hud, dialog,
  flags, gametime, party, rules, rng, items, encounters, monsters, audio,
  gamestate, worldload, combatui, save, pathfind, maproute, pursuit,
  overworldui, keymap, mappins;

const
  MAX_HUNTERS      = 1;    { at most this many roaming hunters at once }
  HUNTER_SPAWN_ODDS = 40;  { one-in-this chance per step in a dangerous area }
  HUNTER_MIN_DIST  = 6;    { a hunter spawns at least this far off, in tiles }

const
  MOUSE_YAW    = 0.0040;  { radians per mouse unit, free look }
  MOUSE_PITCH  = 0.7;     { pixels per mouse unit, free look }

procedure RestHere; forward;
procedure ChargeWagesDue; forward;

{ ---- party auto-travel ---- }

const
  RECALL_MAP    = 'TOWN';   { the town is the fixed hub every zone links to }
  RECALL_MARKER = 'gate';

var
  atActive: boolean;
  atMap: string;
  atX, atY: longint;                       { final goal, kept for the arrival test }
  atPath: array[0 .. ROUTE_MAX_LEGS - 1] of TRouteLeg;
  atN, atLeg: longint;                     { leg count, and the leg in progress }

function AutoTravelActive: boolean;
begin
  AutoTravelActive := atActive;
end;

{ Make atLeg name the current map's leg, re-materializing the route from here
  if the stored plan no longer covers this map. False means no route from the
  party's current position to the goal. }
function RefreshRoute: boolean;
var
  i: longint;
begin
  RefreshRoute := false;
  { the stored plan still names this map: scan forward to its leg. }
  if atActive then
    for i := atLeg to atN - 1 do
      if atPath[i].map = CurMapName then begin
        atLeg := i;
        RefreshRoute := true;
        exit;
      end;
  { otherwise plan afresh from where the party stands. }
  if RoutePath(CurMapName, TileX, TileY, atMap, atX, atY,
       pmPlayerKnown, atPath, atN) and (atN > 0) then begin
    atLeg := 0;
    RefreshRoute := true;
  end;
end;

{ Always re-materialize from the party's current position, discarding the
  stored plan. Used when the current leg will not path on the live map, so a
  different crossing can be tried. }
function ForcePlan: boolean;
begin
  ForcePlan := RoutePath(CurMapName, TileX, TileY, atMap, atX, atY,
    pmPlayerKnown, atPath, atN) and (atN > 0);
  if ForcePlan then atLeg := 0;
end;

{ The current leg's target tile on this map, for the full-map preview: the
  portal the route leaves through, or the goal when it is on this map. }
function AutoTravelTargetOnMap(out tx, ty: longint): boolean;
begin
  AutoTravelTargetOnMap := false;
  tx := 0; ty := 0;
  if (not atActive) or (atLeg < 0) or (atLeg >= atN) then exit;
  if atPath[atLeg].map <> CurMapName then exit;
  tx := atPath[atLeg].exitX; ty := atPath[atLeg].exitY;
  AutoTravelTargetOnMap := true;
end;

procedure CancelAutoTravel;
begin
  if not atActive then exit;
  atActive := false;
  saveMsg := 'TRAVEL CANCELED';
  saveMsgT := 1.5;
end;

procedure StartAutoTravel(const destMap: string; dx, dy: longint);
begin
  atActive := false;
  if Length(Roster) = 0 then exit;
  if (destMap = CurMapName) and (dx = TileX) and (dy = TileY) then exit;
  { materialize the whole route once; refuse up front if the destination is
    not known-reachable. The walk then follows these legs without re-searching
    every tile. }
  if not RoutePath(CurMapName, TileX, TileY, destMap, dx, dy,
       pmPlayerKnown, atPath, atN) or (atN = 0) then begin
    saveMsg := 'NO KNOWN ROUTE';
    saveMsgT := 2.0;
    exit;
  end;
  atMap := destMap; atX := dx; atY := dy;
  atLeg := 0;
  atActive := true;
  saveMsg := 'TRAVELING';
  saveMsgT := 1.0;
end;

procedure RecallToTown;
{** Auto-travel back to the town gate, a cross-map route through everywhere
  the party has been. }
var
  tm: TMapData;
  isDyn: boolean;
  ver, depth, gx, gy: longint;
  seed: longword;
begin
  if not SourceMap(RECALL_MAP, false, tm, isDyn, ver, seed, depth) then exit;
  if not MarkerPos(tm, RECALL_MARKER, gx, gy) then exit;
  StartAutoTravel(RECALL_MAP, gx, gy);
end;

procedure AutoTravelStep;
{** One tile of the current route: follow the materialized leg for this map,
  path to its target, open a door in the way, and step. A portal on the way
  hands off to the next map in CheckTileEvents; the next call picks up that
  map's leg. The route is only re-searched when the stored plan no longer
  covers the current map or a leg will not path. }
var
  wx, wy, nsteps, nx, ny: longint;
  atGoal: boolean;
  path: array[0 .. 2047] of TPathStep;
begin
  if (CurMapName = atMap) and (TileX = atX) and (TileY = atY) then begin
    atActive := false;
    saveMsg := 'ARRIVED';
    saveMsgT := 2.0;
    exit;
  end;
  if not RefreshRoute then begin
    atActive := false;
    saveMsg := 'ROUTE LOST';
    saveMsgT := 2.0;
    exit;
  end;
  wx := atPath[atLeg].exitX; wy := atPath[atLeg].exitY;
  atGoal := atPath[atLeg].atGoal;
  if not FindPath(CurMap, TileX, TileY, wx, wy, true, path, nsteps) then begin
    { the stored leg will not path on the live map: re-plan once from here. }
    if (not ForcePlan) then begin
      atActive := false;
      saveMsg := 'ROUTE BLOCKED';
      saveMsgT := 2.0;
      exit;
    end;
    wx := atPath[atLeg].exitX; wy := atPath[atLeg].exitY;
    atGoal := atPath[atLeg].atGoal;
    if not FindPath(CurMap, TileX, TileY, wx, wy, true, path, nsteps) then begin
      atActive := false;
      saveMsg := 'ROUTE BLOCKED';
      saveMsgT := 2.0;
      exit;
    end;
  end;
  if nsteps < 2 then begin
    { already on the waypoint: the goal ends the trip, a portal tile should
      have handed off already, so stop here rather than spin. }
    atActive := false;
    if atGoal then begin
      saveMsg := 'ARRIVED';
      saveMsgT := 2.0;
    end;
    exit;
  end;
  nx := path[1].x; ny := path[1].y;
  if (nx >= 0) and (nx < MapW) and (ny >= 0) and (ny < MapH)
     and (TileAt(nx, ny) = TILE_DOOR) and (not DoorOpen[ny][nx]) then begin
    ToggleDoor(nx, ny);
    PlaySfx(SFX_DOOR);
  end;
  StepToward(nx, ny);
end;

function ResolvePursuitCatch(caughtBy: longint): boolean;
{** Turn a pursuer that has caught the party into the fight it was chasing.
  Returns true when a fight started, so the caller stops what it was doing. }
var
  mon: longint;
begin
  ResolvePursuitCatch := false;
  if caughtBy < 0 then exit;
  mon := Pursuers[caughtBy].mon;
  RemovePursuer(caughtBy);
  CancelAutoTravel;
  saveMsg := 'A HUNTER CATCHES YOU!';
  saveMsgT := 2.0;
  if CurDepth > 0 then StartMonsterCombat(mon, CurDepth)
  else StartMonsterCombat(mon, 1);
  ResolvePursuitCatch := true;
end;

procedure StartDialog(const dlgName, npcName: string);
begin
  DialogStart(dlgName);
  if DlgActive then begin
    dlgNpcName := npcName;
    dlgId := dlgName;
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
var
  act: longint;
begin
  { any key but the recall key stops a trip in progress; the first Escape
    only stops it, and does not also quit. }
  if atActive and (scancode <> KeyBind[gaRecall]) then begin
    CancelAutoTravel;
    if scancode = SDL_SCANCODE_ESCAPE then exit;
  end;
  { the rebindable in-world commands come first, by action }
  act := ActionForKey(scancode);
  case act of
    ord(gaRecall): begin RecallToTown; exit; end;
    ord(gaOverworld): begin
      if not EnterOverworld then begin
        saveMsg := 'NO OVERWORLD TRAVEL FROM HERE';
        saveMsgT := 2.0;
      end;
      exit;
    end;
    ord(gaInteract): begin InteractAhead; exit; end;
    ord(gaMap):      begin State := gsFullMap; exit; end;
    ord(gaRest):     begin RestHere; exit; end;
  end;
  { the fixed keys: menus, renderer A/B, quit, and the save slots }
  case scancode of
    SDL_SCANCODE_ESCAPE: QuitRequested := true;
    SDL_SCANCODE_M:      showMap := not showMap;
    SDL_SCANCODE_P:      UsePoly := not UsePoly;   { A/B the renderers }
    SDL_SCANCODE_J:      State := gsMenu;
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

procedure RestEatAndRecover;
{** A rest costs one ration per living member. Fed, the party recovers;
  with too little food they pass the night hungry, recovering nothing and
  losing a little vigor. }
var
  need, i: longint;
begin
  need := 0;
  for i := 0 to High(Roster) do
    if Roster[i].alive then inc(need);
  if PartyConsume('RATION', need) then begin
    RestParty;
    saveMsg := 'THE PARTY RESTS AND RECOVERS';
  end else begin
    for i := 0 to High(Roster) do
      if Roster[i].alive and (not Roster[i].downed) and (Roster[i].hp > 1) then
        dec(Roster[i].hp);
    saveMsg := 'NO FOOD: THE PARTY GOES HUNGRY';
  end;
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
  TimeAdvance(8 * 60);   { a long rest moves the clock by eight hours }
  { eight hours is plenty of time for a hunter on the party's trail to run
    them down; a rest with one loose is no rest at all. }
  if ResolvePursuitCatch(PursuitTick(CurMapName, TileX, TileY)) then exit;
  RestEatAndRecover;
  ChargeWagesDue;        { a rest can carry past a pay day }
  PlaySfx(SFX_SELECT);
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
  and on a failure the party takes damage and the lead is poisoned. A member
  whose worn gear wards against the trap's element takes half. }
var
  dmg, dc, elem, lead, i, hit: longint;
  sprung: string;
begin
  if not TrapAt(TileX, TileY, dmg, dc, elem) then exit;
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
      if (elem <> 0) and ((CharResist(Roster[i]) and elem) <> 0) then
        hit := (hit + 1) div 2;   { warded gear halves it, rounding up }
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

procedure LootCheck;
{** A placed cache on the tile is taken once: its coin goes to the purse and
  any item to the first conscious member. A per-tile flag keeps it from
  refilling on a return visit and rides along in the save. }
var
  gold, qty, m, idx: longint;
  item: string;
  taken: string;
begin
  if not LootAt(TileX, TileY, gold, qty, item) then exit;
  taken := 'LOOT_' + CurMapName + '_' + IntToStr(TileX) + '_' + IntToStr(TileY);
  if FlagHas(taken) then exit;
  FlagSet(taken);
  if gold > 0 then
    PartyGold := PartyGold + gold;
  idx := -1;
  if (item <> '') and (qty > 0) then begin
    m := FirstConscious;
    if m >= 0 then begin
      PackAdd(Roster[m], item, qty);
      idx := ItemIndex(item);
    end;
  end;
  PlaySfx(SFX_PICK);
  if idx >= 0 then begin
    if gold > 0 then
      saveMsg := 'A CACHE: ' + IntToStr(gold) + ' GOLD AND '
        + UpperCase(ItemDefs[idx].name)
    else
      saveMsg := 'YOU FIND ' + UpperCase(ItemDefs[idx].name);
  end else
    saveMsg := 'YOU FIND ' + IntToStr(gold) + ' GOLD';
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

function PickAreaMonster: longint;
{** A monster drawn from the current area's encounter table, or -1 if the
  area is safe or its table names nothing known. }
var
  t, e: longint;
begin
  PickAreaMonster := -1;
  t := CurEncTable;
  if (t < 0) or (t > High(EncTables)) then exit;
  if Length(EncTables[t].entries) = 0 then exit;
  e := Range(0, High(EncTables[t].entries));
  PickAreaMonster := MonIndex(EncTables[t].entries[e].mon);
end;

procedure TrySpawnHunter;
{** Now and then in a dangerous area a monster picks up the party's trail
  and starts hunting from a reachable tile some way off. }
var
  mon, tries, tx, ty: longint;
begin
  if EncTableEmpty(CurEncTable) then exit;        { safe ground, no hunters }
  if ActivePursuerCount >= MAX_HUNTERS then exit;
  if Range(1, HUNTER_SPAWN_ODDS) <> 1 then exit;
  mon := PickAreaMonster;
  if mon < 0 then exit;
  for tries := 1 to 24 do begin
    tx := Range(0, MapW - 1);
    ty := Range(0, MapH - 1);
    if TileAt(tx, ty) <> TILE_EMPTY then continue;
    if Abs(tx - TileX) + Abs(ty - TileY) < HUNTER_MIN_DIST then continue;
    if not PathExists(CurMap, TileX, TileY, tx, ty, true) then continue;
    AddPursuer(mon, CurMapName, tx, ty);
    saveMsg := 'SOMETHING PICKS UP YOUR TRAIL';
    saveMsgT := 2.0;
    exit;
  end;
end;

procedure BurnLight;
{** Underground the torch burns down a little each step. When it runs out
  the party lights a fresh one from the pack, or presses on in the dark; a
  torch found or bought later is lit on the next step. }
begin
  if CurMapSurface then exit;
  if TorchFuel > 0 then begin
    dec(TorchFuel, 3);   { the three minutes a tile takes }
    if TorchFuel > 0 then exit;
    TorchFuel := 0;
    if PartyConsume('TORCH', 1) then begin
      TorchFuel := TORCH_MINUTES;
      saveMsg := 'YOU LIGHT A FRESH TORCH';
    end else
      saveMsg := 'YOUR LIGHT GUTTERS OUT';
    saveMsgT := 2.0;
  end else if PartyConsume('TORCH', 1) then begin
    TorchFuel := TORCH_MINUTES;   { was dark; a spare is now at hand }
    saveMsg := 'YOU LIGHT A FRESH TORCH';
    saveMsgT := 2.0;
  end;
end;

procedure ChargeWagesDue;
{** When a lunar month has turned, pay the hirelings' wages from the purse.
  Any the party cannot cover desert. }
var
  left: longint;
begin
  if HirelingCount = 0 then exit;
  if WagesDueClock = 0 then WagesDueClock := ClockMin + LUNAR_MINUTES;
  while (HirelingCount > 0) and (ClockMin >= WagesDueClock) do begin
    left := ChargeWages;
    if left > 0 then saveMsg := 'A HIRELING LEFT, UNPAID'
    else saveMsg := 'WAGES PAID TO YOUR HIRELINGS';
    saveMsgT := 2.0;
    WagesDueClock := WagesDueClock + LUNAR_MINUTES;
  end;
  if HirelingCount = 0 then WagesDueClock := 0;
end;

procedure AutoPinDiscovered;
{** Drop a marker on each discovered stair, portal and service NPC of the
  resident map, so the full map fills in points of interest as the party
  explores. An auto marker is placed once and never overrides a player pin. }
var
  i, px, py: longint;

  function Discovered(x, y: longint): boolean;
  begin
    Discovered := (x >= 0) and (y >= 0) and (x < MapW) and (y < MapH)
      and (Seen[y][x] <> VIS_UNSEEN);
  end;

begin
  for i := 0 to High(CurMap.portals) do begin
    px := CurMap.portals[i].x; py := CurMap.portals[i].y;
    if Discovered(px, py) then begin
      if (CurMap.portals[i].kind = PK_DOWN) or (CurMap.portals[i].kind = PK_UP)
        or (CurMap.portals[i].kind = PK_LADDER)
        or (CurMap.portals[i].kind = PK_SHAFT) then
        PinSetAuto(CurMapName, px, py, PIN_STAIR)
      else
        PinSetAuto(CurMapName, px, py, PIN_PORTAL);
    end;
  end;
  for i := 0 to High(CurMap.npcs) do begin
    px := CurMap.npcs[i].x; py := CurMap.npcs[i].y;
    if Discovered(px, py) then
      PinSetAuto(CurMapName, px, py, PIN_SHOP);
  end;
end;

procedure CheckTileEvents;
{** On stepping onto a new tile: follow a portal, burn the torch, spring a
  trap, tick poison, advance any hunters, then roll for a wandering monster. }
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
  BurnLight;
  PoisonTick;
  TrapCheck;
  LootCheck;
  LightPuzzleCheck;
  AutoPinDiscovered;
  ChargeWagesDue;
  if not PartyConscious then begin
    State := gsGameOver;
    exit;
  end;
  if Length(Roster) = 0 then exit;

  { roaming hunters close in on the game clock; one that reaches the party
    starts the fight it has been chasing, led by the hunter itself. }
  if ResolvePursuitCatch(PursuitTick(CurMapName, TileX, TileY)) then exit;

  { safe ground shakes off the hunt; dangerous ground may start a new one. }
  if EncTableEmpty(CurEncTable) then
    PursuitClear
  else
    TrySpawnHunter;

  { the older instant wandering-monster roll, elsewhere than safe areas. }
  if (not EncTableEmpty(CurEncTable)) then
    if Range(1, 18) = 1 then begin
      CancelAutoTravel;
      if CurDepth > 0 then StartCombat(CurDepth) else StartCombat(1);
    end;
end;

procedure ExploreUpdate(dt: double);
var
  moveHeld: boolean;
begin
  { the bound movement keys, with the arrows kept as fixed alternates for
    forward, back and turning so the old feel survives a rebind. }
  moveHeld := KeyDown(KeyBind[gaForward]) or KeyDown(SDL_SCANCODE_UP)
    or KeyDown(KeyBind[gaBack]) or KeyDown(SDL_SCANCODE_DOWN)
    or KeyDown(KeyBind[gaStrafeL]) or KeyDown(KeyBind[gaStrafeR])
    or KeyDown(KeyBind[gaTurnL]) or KeyDown(SDL_SCANCODE_LEFT)
    or KeyDown(KeyBind[gaTurnR]) or KeyDown(SDL_SCANCODE_RIGHT);
  { One grid action per idle moment; the tween gates auto-repeat. }
  if not MotionBusy then begin
    if atActive then begin
      { a held movement or turn key takes back manual control. }
      if moveHeld then CancelAutoTravel
      else AutoTravelStep;
    end
    else if KeyDown(KeyBind[gaForward]) or KeyDown(SDL_SCANCODE_UP) then
      RequestStep(1, 0)
    else if KeyDown(KeyBind[gaBack]) or KeyDown(SDL_SCANCODE_DOWN) then
      RequestStep(-1, 0)
    else if KeyDown(KeyBind[gaStrafeL]) then
      RequestStep(0, -1)
    else if KeyDown(KeyBind[gaStrafeR]) then
      RequestStep(0, 1)
    else if KeyDown(KeyBind[gaTurnL]) or KeyDown(SDL_SCANCODE_LEFT) then
      RequestTurn(-1)
    else if KeyDown(KeyBind[gaTurnR]) or KeyDown(SDL_SCANCODE_RIGHT) then
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
  light wells glow by the current sun and moon. Underground the party's
  torch sets the near light, fading as its fuel runs down; in daylight the
  torch does not matter, so it stays full. }
begin
  if CurMapSurface then begin
    AmbientLight := OutdoorAmbient;
    TorchGlow := 256;
  end else begin
    AmbientLight := 48;   { a dim underworld, lifted by fires and glow }
    if TorchFuel >= TORCH_GUTTER then
      TorchGlow := 256
    else if TorchFuel > 0 then
      TorchGlow := TORCH_DARK + (TorchFuel * (256 - TORCH_DARK)) div TORCH_GUTTER
    else
      TorchGlow := TORCH_DARK;
  end;
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
