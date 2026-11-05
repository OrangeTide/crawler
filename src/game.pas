unit game;

{** Top-level game state machine.

  The game is a set of states (title, exploration, combat, and so on).
  One state is active at a time. This unit owns the active state, routes
  input to it, advances it each frame and renders it. The platform layer
  in crawler.lpr only pumps SDL and uploads the framebuffer.

  For now only the exploration state is implemented, so behaviour matches
  the earlier single-loop build: walk the dungeon, look with the mouse,
  open doors and toggle the automap. The other states are declared so the
  later systems have a place to attach. }

{$mode objfpc}{$H+}

interface

type
  TGameState = (gsTitle, gsNewParty, gsExplore, gsCombat,
                gsDialog, gsShop, gsFullMap, gsInventory, gsMenu,
                gsGameOver, gsVictory, gsOptions);

var
  State: TGameState;
  QuitRequested: boolean;

function GameInit: boolean;
procedure GameHandleEvents;
procedure GameUpdate(dt: double);
procedure GameRender(fps: longint);
{ Jump a pregen party straight into a test encounter (menu / --combat). }
procedure QuickBattle;

implementation

uses
  sysutils, sdl2min, gfx, pak, mapfmt, world, raycast, polyrender, models,
  raster, meshfmt, hud, textures, rng, rules, items, chardata, party, monsters,
  combat, flags, dialog, mapstate, save, worldfmt, mapgen, overworld, gametime,
  audio;

const
  MOUSE_YAW    = 0.0040;  { radians per mouse unit, free look }
  MOUSE_PITCH  = 0.7;     { pixels per mouse unit, free look }

type
  TKeyArray = array[0 .. SDL_NUM_SCANCODES - 1] of UInt8;
  PKeyArray = ^TKeyArray;

var
  keys: PKeyArray;
  showMap: boolean;
  UsePoly: boolean;       { toggle the polygon renderer against the raycaster }
  GamePak: TPak;
  lastTX, lastTY: longint;
  CurDepth: longint;      { 0 surface, else the dungeon depth, for scaling }
  CurAreaMask: byte;      { the encounter area of the loaded map, 0 = safe }
  FromQuickBattle: boolean; { a test fight with no world; exit to the title }
  cursorX, cursorY: longint;
  rmbHeld: boolean;
  dlgNpcName: string;
  shopSel: longint;
  saveMsg: string;
  saveMsgT: double;
  optSel: longint;
  volMaster, volMusic, volSfx: longint;

  { combat command UI: a FF-style command then target flow }
  cbMenu: longint;        { CB_* phase }
  cmdSel: longint;        { highlighted command }
  spellSel: longint;      { highlighted spell }
  allySel: longint;       { highlighted ally, for a heal }
  pendingSpell: longint;  { spell chosen, awaiting a target, -1 none }

  titleSel: longint;
  ccSlot: longint;
  ccSpecies: longint;
  ccClass: longint;
  ccBg: longint;
  ccNameIdx: longint;
  ccAbil: TAbilityScores;
  ccPreview: TCharacter;

const
  NAME_POOL: array[0 .. 11] of string[12] = (
    'THORNE', 'BRYN', 'MAEVE', 'KORRIG', 'ELSPETH', 'DRAVEN',
    'LYRA', 'GARRET', 'ODILE', 'VANCE', 'SERA', 'RHESK');

  { combat command UI phases }
  CB_COMMAND = 0;   { picking a command }
  CB_TARGET  = 1;   { picking an enemy }
  CB_SPELL   = 2;   { picking a spell }
  CB_ALLY    = 3;   { picking an ally, for a heal }

  { commands in the root menu }
  CMD_ATTACK = 0;
  CMD_CAST   = 1;
  CMD_ITEM   = 2;
  CMD_GUARD  = 3;
  CMD_MOVE   = 4;
  CMD_FLEE   = 5;
  CMD_COUNT  = 6;

  CMD_NAME: array[0 .. CMD_COUNT - 1] of string[7] = (
    'ATTACK', 'CAST', 'ITEM', 'DEFEND', 'MOVE', 'FLEE');

function SavePath: string;
begin
  SavePath := ExtractFilePath(ParamStr(0)) + 'save1.sav';
end;

function AreaOf(const name: string): byte;
{** The encounter area of a map, from its name. Pinned zones carry their
  own theme; overworld cells take their surface biome's area, generated
  dungeons their underground theme's. Interiors and the town are safe. }
var
  cx, cy, depth: longint;
begin
  if name = 'TOWN' then AreaOf := 0
  else if name = 'FOREST' then AreaOf := AREA_FOREST
  else if name = 'SEASIDE' then AreaOf := AREA_COAST
  else if name = 'DUNGEON' then AreaOf := AREA_CRYPT
  else if name = 'CAVE' then AreaOf := AREA_CAVE
  else if name = 'INFERNAL' then AreaOf := AREA_INFERNAL
  else if ParseCellName(name, cx, cy) then AreaOf := BiomeArea(BiomeAt(cx, cy))
  else if ParseDungeonName(name, cx, cy, depth) then
    AreaOf := ThemeArea(BiomeTheme(BiomeAt(cx, cy)))
  else if ParseDepthsName(name, cx, cy) then AreaOf := AREA_INFERNAL
  else AreaOf := 0;   { interiors, dynmaps: no wild encounters }
end;

procedure GateAreaModels(areaMask: byte);
{** The per-area model cache gate. Load exactly the models the current
  map's props and this area's monsters need, then check them against the
  VRAM budget so a level never asks for more than the console can hold. }
var
  names: array of string;
  i: longint;

  procedure Add(const nm: string);
  var j: longint;
  begin
    if nm = '' then exit;
    for j := 0 to High(names) do
      if names[j] = nm then exit;
    SetLength(names, Length(names) + 1);
    names[High(names)] := nm;
  end;

begin
  names := nil;
  for i := 0 to High(CurMap.props) do Add(CurMap.props[i].name);
  if areaMask <> 0 then
    for i := 0 to High(MonDefs) do
      if (MonDefs[i].areas and areaMask) <> 0 then Add(MonDefs[i].model);
  LoadModelSet(GamePak, names);
  if not ModelSetFitsVram(names) then begin
    saveMsg := 'MODEL CACHE OVER VRAM: ' + AreaName(areaMask);
    saveMsgT := 2.0;
  end;
end;

function LoadMapLump(const name: string): boolean;
{** Bring a map into the world. A static map is decoded from its pak
  lump; a dynamic map is generated from its stored or a fresh seed. The
  map being left is captured, and the one entered has its fog and doors
  restored. }
var
  blob: TByteArray;
  md: TMapData;
  di, ver, cx, cy, depth, pcx, pcy: longint;
  seed: longword;
  isDyn: boolean;
begin
  LoadMapLump := false;
  ver := 0; seed := 0; isDyn := false;
  CurDepth := 0;
  if PakGet(GamePak, name, blob) then begin
    if not DecodeMap(blob, md) then exit;
  end else if ParseCellName(name, cx, cy) then begin
    { an overworld cell: terrain is fixed by the world seed, so the
      per-cell seed is derived, not stored or random. Fog still persists. }
    isDyn := true;
    ver := GEN_VERSION;
    seed := CellSeed(cx, cy, 0);
    md := GenerateOverworldCell(cx, cy, seed);
  end else if ParseDungeonName(name, cx, cy, depth) then begin
    isDyn := true;
    ver := GEN_VERSION;
    seed := CellSeed(cx, cy, depth);
    md := GenerateDungeonLevel(cx, cy, depth, seed);
    CurDepth := depth;
  end else if ParseDepthsName(name, cx, cy) then begin
    isDyn := true;
    ver := GEN_VERSION;
    seed := CellSeed(cx, cy, SUNLESS_DEPTH + 1);
    md := GenerateDepthsCell(cx, cy, seed);
    CurDepth := SUNLESS_DEPTH;
  end else if ParseInteriorName(name, cx, cy, depth) then begin
    { a building interior standing on cell (cx,cy); depth holds the
      building index. Derived from the cell seed, so it is stable. }
    isDyn := true;
    ver := GEN_VERSION;
    seed := CellSeed(cx, cy, 0);
    md := GenerateInterior(cx, cy, depth, seed);
  end else begin
    di := DynIndex(name);
    if di < 0 then exit;
    isDyn := true;
    if not MapStateGetSeed(name, ver, seed) then begin
      ver := GEN_VERSION;
      seed := RngNext(GameRng);
      if seed = 0 then seed := 1;
    end;
    md := GenerateMap(DynMaps[di], ver, seed);
    CurDepth := DynMaps[di].depth;
  end;
  { a pinned authored zone leaves back to the wilderness that reaches it,
    not only to the town hub. Derived from the map, so it stays stable. }
  if PinnedCellOf(name, pcx, pcy) then
    AddWildernessExit(md, pcx, pcy);
  if CurMapName <> '' then
    MapStateCapture(CurMapName);
  if not LoadMapData(md) then exit;
  CurMapName := name;
  CurAreaMask := AreaOf(name);
  GateAreaModels(CurAreaMask);   { cache only what this area draws }
  if isDyn then
    MapStateSetDynamic(name, ver, seed);
  MapStateRestore(name);     { bring back fog and doors if visited before }
  LoadMapLump := true;
end;

function LoadMapByName(const name, marker: string): boolean;
{** Load a map and place the party at a named marker. }
begin
  LoadMapByName := false;
  if not LoadMapLump(name) then exit;
  PlaceAtMarker(marker);
  lastTX := TileX;
  lastTY := TileY;
  LoadMapByName := true;
end;

function ContinueGame: boolean;
{** Load the save, then reload its map at the saved position. }
begin
  ContinueGame := false;
  if not LoadGame(SavePath) then exit;
  CurMapName := '';          { do not capture a stale resident map }
  if not LoadMapLump(LoadedMapName) then exit;
  PlaceAt(LoadedTX, LoadedTY, LoadedFace);
  lastTX := TileX;
  lastTY := TileY;
  ContinueGame := true;
end;

function KeyDown(scancode: longint): boolean; inline;
begin
  KeyDown := keys^[scancode] <> 0;
end;

{ ---- Exploration state ---- }

procedure StartCombat(depth: longint); forward;
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

procedure StartCombat(depth: longint);
begin
  StartRandomEncounter(depth, CurAreaMask);
  cbMenu := CB_COMMAND;
  cmdSel := CMD_ATTACK;
  spellSel := 0;
  allySel := 0;
  pendingSpell := -1;
  PlaySfx(SFX_FOE);
  State := gsCombat;
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
  { Town is safe; elsewhere a small per-step chance of an encounter,
    scaled by how deep the party has descended. }
  if (CurMapName <> 'TOWN') and (Length(Roster) > 0) then
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

{ ---- Shared UI helpers ---- }

procedure DrawCenter(y: longint; const s: string; c: TColor);
begin
  DrawText((FBW - Length(s) * 6) div 2, y, s, c);
end;

procedure DrawWrapped(x, y, widthChars: longint; const s: string; c: TColor);
{** Draw text word-wrapped to widthChars columns, 10px line pitch. }
var
  words: array[0 .. 63] of string;
  nw, i, start, len, ln: longint;
  line, w: string;
begin
  { split into words }
  nw := 0; start := 1; len := Length(s);
  for i := 1 to len + 1 do
    if (i > len) or (s[i] = ' ') then begin
      if (i > start) and (nw <= High(words)) then begin
        words[nw] := Copy(s, start, i - start);
        inc(nw);
      end;
      start := i + 1;
    end;
  line := ''; ln := 0;
  for i := 0 to nw - 1 do begin
    w := words[i];
    if (line <> '') and (Length(line) + 1 + Length(w) > widthChars) then begin
      DrawText(x, y + ln * 10, line, c);
      inc(ln);
      line := w;
    end else if line = '' then
      line := w
    else
      line := line + ' ' + w;
  end;
  if line <> '' then
    DrawText(x, y + ln * 10, line, c);
end;

function ClassOr0(const id: string): longint;
begin
  ClassOr0 := ClassIndex(id);
  if ClassOr0 < 0 then ClassOr0 := 0;
end;

function SpeciesOr0(const id: string): longint;
begin
  SpeciesOr0 := SpeciesIndex(id);
  if SpeciesOr0 < 0 then SpeciesOr0 := 0;
end;

procedure StartGame;
{** Hand off from the menus to the outskirts: the overworld clearing just
   outside the starter dungeon, a short walk north of town. }
begin
  FlagsReset;
  MapStateReset;
  CurMapName := '';
  if not LoadMapByName('OUTSKIRTS', 'spawn') then begin
    writeln(StdErr, 'game: could not load the starting map');
    QuitRequested := true;
    exit;
  end;
  State := gsExplore;
end;

{ ---- Title state ---- }

const
  TITLE_ITEMS = 6;

procedure TitleRender;
const
  LABELS: array[0 .. TITLE_ITEMS - 1] of string = (
    'CONTINUE', 'NEW GAME', 'QUICK START', 'QUICK BATTLE', 'OPTIONS', 'QUIT');
var
  i, y: longint;
  c: TColor;
begin
  ClearFB(RGB(12, 10, 16));
  FillRect(0, 44, FBW, 2, RGB(90, 70, 40));
  DrawCenter(22, 'SHADOWS OF THE DEEP', RGB(220, 200, 120));
  DrawCenter(32, 'A DUNGEON CRAWL', RGB(120, 110, 90));
  y := 110;
  for i := 0 to TITLE_ITEMS - 1 do begin
    if i = titleSel then begin
      c := RGB(240, 230, 150);
      DrawText(FBW div 2 - Length(LABELS[i]) * 3 - 12, y, '>', c);
    end else
      c := RGB(150, 140, 120);
    if (i = 0) and (not SaveExists(SavePath)) then
      c := RGB(80, 76, 66);
    DrawCenter(y, LABELS[i], c);
    inc(y, 16);
  end;
  DrawCenter(FBH - 20, 'ARROWS SELECT   ENTER CONFIRM', RGB(90, 84, 70));
end;

procedure BuildPregenParty;
{** Roll a ready-to-play party of four: a fighter, thief, friar and wizard. }
var
  i, sp: longint;
  a: TAbilityScores;
  c: TCharacter;
  clsId: array[0 .. 3] of string = ('FIGHTER', 'THIEF', 'FRIAR', 'WIZARD');
begin
  NewParty;
  sp := SpeciesOr0('HUMAN');
  for i := 0 to 3 do begin
    RollAbilities(a);
    MakeCharacter(c, NAME_POOL[i], sp, ClassOr0(clsId[i]), 0, a);
    AddPartyMember(c);
  end;
end;

procedure QuickStart;
{** Make a ready-to-play party of four and dive into the world. }
begin
  BuildPregenParty;
  StartGame;
end;

procedure QuickBattle;
{** Skip the world and drop a pregen party into a test encounter. Set
   FromQuickBattle so leaving the fight returns to the title, since no map
   is loaded. Any area, a mid depth for a meaty mix of foes. }
begin
  BuildPregenParty;
  CurMapName := 'QUICKBATTLE';
  CurAreaMask := 0;
  FromQuickBattle := true;
  StartCombat(3);
end;

procedure CCRebuild; forward;

procedure CCBeginSlot;
begin
  ccSpecies := SpeciesOr0('HUMAN');
  ccClass := ClassOr0('FIGHTER');
  ccBg := 0;
  ccNameIdx := ccSlot;
  RollAbilities(ccAbil);
  CCRebuild;
end;

procedure TitleSelect;
begin
  case titleSel of
    0: if SaveExists(SavePath) then ContinueGame;
    1: begin State := gsNewParty; NewParty; ccSlot := 0; CCBeginSlot; end;
    2: QuickStart;
    3: QuickBattle;
    4: begin optSel := 0; State := gsOptions; end;
    5: QuitRequested := true;
  end;
end;

procedure TitleKeyDown(scancode: longint);
begin
  case scancode of
    SDL_SCANCODE_UP:     titleSel := (titleSel + TITLE_ITEMS - 1) mod TITLE_ITEMS;
    SDL_SCANCODE_DOWN:   titleSel := (titleSel + 1) mod TITLE_ITEMS;
    SDL_SCANCODE_RETURN, SDL_SCANCODE_SPACE: begin PlaySfx(SFX_SELECT); TitleSelect; end;
    SDL_SCANCODE_ESCAPE: QuitRequested := true;
  end;
end;

{ ---- Character creation state ---- }

procedure CCRebuild;
begin
  MakeCharacter(ccPreview, NAME_POOL[ccNameIdx], ccSpecies, ccClass, ccBg, ccAbil);
end;

procedure CCRender;
var
  y: longint;
  a: TAbility;
  s, modStr: string;
  m: longint;
begin
  ClearFB(RGB(14, 12, 18));
  DrawCenter(10, 'CREATE PARTY   MEMBER ' + IntToStr(ccSlot + 1) + ' OF '
    + IntToStr(MAX_PARTY), RGB(220, 200, 120));

  DrawText(30, 30, 'NAME:    ' + NAME_POOL[ccNameIdx], RGB(200, 200, 180));
  DrawText(30, 42, 'SPECIES: ' + SpeciesDefs[ccSpecies].name, RGB(200, 200, 180));
  DrawText(30, 54, 'CLASS:   ' + ClassDefs[ccClass].name, RGB(200, 200, 180));
  DrawText(30, 66, 'PAST:    ' + BackgroundDefs[ccBg].name, RGB(190, 190, 160));

  y := 84;
  for a := abSTR to abCHA do begin
    m := AbilMod(ccPreview.abil[a]);
    if m >= 0 then modStr := '+' + IntToStr(m) else modStr := IntToStr(m);
    Str(ccPreview.abil[a], s);
    DrawText(40, y, ABIL_NAME[a] + ' ' + s + ' (' + modStr + ')',
      RGB(180, 190, 170));
    inc(y, 11);
  end;

  DrawText(150, 80, 'HP ' + IntToStr(ccPreview.hpMax), RGB(200, 160, 160));
  DrawText(150, 91, 'AC ' + IntToStr(CharAC(ccPreview)), RGB(160, 180, 200));
  DrawText(150, 102, 'ATK ' + IntToStr(CharAttack(ccPreview, true)),
    RGB(200, 190, 150));

  DrawText(14, FBH - 40, 'N NAME  K SPECIES  [ ] CLASS  B PAST  R REROLL',
    RGB(140, 130, 110));
  DrawText(14, FBH - 28, 'ENTER ACCEPT   G FINISH   ESC TITLE',
    RGB(140, 130, 110));
end;

procedure CCAccept;
var
  c: TCharacter;
begin
  MakeCharacter(c, NAME_POOL[ccNameIdx], ccSpecies, ccClass, ccBg, ccAbil);
  AddPartyMember(c);
  inc(ccSlot);
  if ccSlot >= MAX_PARTY then
    StartGame
  else
    CCBeginSlot;
end;

procedure CCKeyDown(scancode: longint);
begin
  case scancode of
    SDL_SCANCODE_N:
      ccNameIdx := (ccNameIdx + 1) mod Length(NAME_POOL);
    SDL_SCANCODE_K: begin
      ccSpecies := (ccSpecies + 1) mod Length(SpeciesDefs);
      CCRebuild;
    end;
    SDL_SCANCODE_B: begin
      ccBg := (ccBg + 1) mod Length(BackgroundDefs);
      CCRebuild;
    end;
    SDL_SCANCODE_RIGHTBRACKET, SDL_SCANCODE_E: begin
      ccClass := (ccClass + 1) mod Length(ClassDefs);
      CCRebuild;
    end;
    SDL_SCANCODE_LEFTBRACKET, SDL_SCANCODE_Q: begin
      ccClass := (ccClass + Length(ClassDefs) - 1) mod Length(ClassDefs);
      CCRebuild;
    end;
    SDL_SCANCODE_R: begin
      RollAbilities(ccAbil);
      CCRebuild;
    end;
    SDL_SCANCODE_RETURN, SDL_SCANCODE_SPACE:
      CCAccept;
    SDL_SCANCODE_G:
      if Length(Roster) > 0 then
        StartGame
      else
        CCAccept;
    SDL_SCANCODE_ESCAPE: begin
      NewParty;
      State := gsTitle;
    end;
  end;
end;

{ ---- Combat state ---- }

procedure EndCombat;
begin
  if FromQuickBattle then begin
    FromQuickBattle := false;
    State := gsTitle;
    titleSel := 0;
  end else if Victory or Fled then
    State := gsExplore
  else
    State := gsGameOver;
end;

const
  FOE_PAL: array[0 .. 5] of TColor = (
    TColor($FFB05545), TColor($FF6E9E57), TColor($FF5A86B0),
    TColor($FF9A6FB0), TColor($FF7FA0A0), TColor($FFB0923C));

procedure DrawBar(x, y, w, h, cur, max: longint; fillc, backc: TColor);
var
  fw: longint;
begin
  FillRect(x, y, w, h, backc);
  if max > 0 then begin
    fw := (w * cur) div max;
    if fw < 0 then fw := 0;
    if fw > w then fw := w;
    if (fw = 0) and (cur > 0) then fw := 1;
    FillRect(x, y, fw, h, fillc);
  end;
  FrameRect(x, y, w, h, RGB(0, 0, 0));
end;

procedure DrawFoeGlyph(cx, cy, w, h: longint; body: TColor);
var
  hw, hh: longint;
begin
  hw := w div 2; hh := h div 2;
  { a rounded blob from stacked rectangles }
  FillRect(cx - hw + 2, cy - hh,     w - 4, h,     body);
  FillRect(cx - hw,     cy - hh + 3, w,     h - 6, body);
  FillRect(cx - hw + 3, cy + 2,      w - 6, hh - 3, Shade(body, 150));
  { eyes }
  FillRect(cx - hw + 6, cy - hh + 6, 4, 5, RGB(240, 240, 230));
  FillRect(cx + hw - 10, cy - hh + 6, 4, 5, RGB(240, 240, 230));
  PutPixel(cx - hw + 7, cy - hh + 8, RGB(20, 20, 20));
  PutPixel(cx + hw - 9, cy - hh + 8, RGB(20, 20, 20));
end;

{ Frame a creature mesh into a combat slot centered on (cx,cy). }
procedure DrawFoeModel(const mesh: TMesh; cx, cy: longint; myaw: double;
  halfpx: longint);
const
  FOCALC = (FBW / 2) / 0.66;
var
  i: longint;
  mnx, mny, mnz, mxx, mxy, mxz, h, radius, d: double;
  mc: TMeshCam;
begin
  if Length(mesh.verts) = 0 then exit;
  mnx := mesh.verts[0].x; mxx := mnx;
  mny := mesh.verts[0].y; mxy := mny;
  mnz := mesh.verts[0].z; mxz := mnz;
  for i := 1 to High(mesh.verts) do begin
    if mesh.verts[i].x < mnx then mnx := mesh.verts[i].x;
    if mesh.verts[i].x > mxx then mxx := mesh.verts[i].x;
    if mesh.verts[i].y < mny then mny := mesh.verts[i].y;
    if mesh.verts[i].y > mxy then mxy := mesh.verts[i].y;
    if mesh.verts[i].z < mnz then mnz := mesh.verts[i].z;
    if mesh.verts[i].z > mxz then mxz := mesh.verts[i].z;
  end;
  h := mxz - mnz;
  radius := mxx - mnx;
  if mxy - mny > radius then radius := mxy - mny;
  if h > radius then radius := h;
  radius := radius * 0.5;
  if radius < 0.001 then radius := 1;

  if halfpx < 1 then halfpx := 1;
  d := radius * FOCALC / halfpx;
  mc.x := -d; mc.y := 0; mc.z := h / 2; mc.yaw := 0; mc.pitch := 0;
  RasterCX := cx; RasterCY := cy;
  RenderMeshAt(mesh, mc, 0, 0, 0, 1.0, myaw, 236);
end;

const
  CMDBOX_X = 6;
  CMDBOX_W = 104;
  CMDBOX_Y = 140;      { top of the bottom window band }

{ The FF-style command window at the lower left, one list per phase. The
  cursor moves vertically; target and ally picks drive a chevron out on
  the battlefield, so this box only names the current pick. }
procedure DrawCombatMenu;
var
  i, y, y0, bh: longint;
  sp: TSpell;
  c: TColor;
begin
  bh := FBH - CMDBOX_Y - 2;
  FillRectBlend(CMDBOX_X, CMDBOX_Y, CMDBOX_W, bh, RGB(6, 8, 14), 235);
  FrameRect(CMDBOX_X, CMDBOX_Y, CMDBOX_W, bh, RGB(150, 140, 90));

  { the window belongs to the acting character, named across its head;
    on a beat or the foe turn it stands by with no list }
  if (CombatPhase = CP_INPUT) and (CurActor >= 0) then
    DrawText(CMDBOX_X + 6, CMDBOX_Y + 5, Copy(Roster[CurActor].name, 1, 12),
      RGB(245, 230, 140))
  else if CombatPhase = CP_ENEMY then
    DrawText(CMDBOX_X + 6, CMDBOX_Y + 5, 'FOE TURN', RGB(210, 150, 140))
  else
    DrawText(CMDBOX_X + 6, CMDBOX_Y + 5, '...', RGB(150, 150, 130));
  FillRect(CMDBOX_X + 4, CMDBOX_Y + 16, CMDBOX_W - 8, 1, RGB(90, 84, 56));
  y0 := CMDBOX_Y + 21;
  if CombatPhase <> CP_INPUT then exit;   { no interactive list while busy }

  case cbMenu of
    CB_COMMAND:
      for i := 0 to CMD_COUNT - 1 do begin
        y := y0 + i * 11;
        if i = cmdSel then begin
          DrawText(CMDBOX_X + 5, y, '>', RGB(245, 230, 140));
          DrawText(CMDBOX_X + 15, y, CMD_NAME[i], RGB(245, 230, 140));
        end else
          DrawText(CMDBOX_X + 15, y, CMD_NAME[i], RGB(170, 165, 140));
      end;
    CB_SPELL:
      for i := 0 to SpellCount - 1 do begin
        y := y0 + i * 11;
        sp := SpellInfo(i);
        if i = spellSel then c := RGB(185, 215, 245)
        else if ActorCanCast(CurActor, i) then c := RGB(150, 160, 185)
        else c := RGB(95, 95, 110);
        if i = spellSel then DrawText(CMDBOX_X + 5, y, '>', c);
        DrawText(CMDBOX_X + 15, y, sp.name, c);
        DrawText(CMDBOX_X + CMDBOX_W - 12, y, IntToStr(sp.cost), c);
      end;
    CB_TARGET: begin
      DrawText(CMDBOX_X + 6, y0, 'TARGET', RGB(240, 220, 130));
      if (CurTarget >= 0) and (CurTarget <= High(Foes)) then
        DrawText(CMDBOX_X + 6, y0 + 12,
          Copy(MonDefs[Foes[CurTarget].def].name, 1, 15), RGB(240, 220, 130));
      DrawText(CMDBOX_X + 6, y0 + 32, 'UP/DN AIM', RGB(150, 150, 130));
      DrawText(CMDBOX_X + 6, y0 + 42, 'ENT  OK', RGB(150, 150, 130));
      DrawText(CMDBOX_X + 6, y0 + 52, 'ESC  BACK', RGB(150, 150, 130));
    end;
    CB_ALLY: begin
      DrawText(CMDBOX_X + 6, y0, 'HEAL', RGB(140, 220, 200));
      DrawText(CMDBOX_X + 6, y0 + 12,
        Copy(Roster[allySel].name, 1, 12), RGB(140, 220, 200));
      DrawText(CMDBOX_X + 6, y0 + 32, 'UP/DN PICK', RGB(150, 150, 130));
      DrawText(CMDBOX_X + 6, y0 + 42, 'ENT  OK', RGB(150, 150, 130));
      DrawText(CMDBOX_X + 6, y0 + 52, 'ESC  BACK', RGB(150, 150, 130));
    end;
  end;
end;

{ A white flash over a struck target, fading with its timer. }
procedure DrawFlash(x, y, w, h: longint; t: double);
begin
  if t <= 0 then exit;
  FillRectBlend(x, y, w, h, RGB(255, 245, 230), round(200 * (t / FLASH_LIFE)));
end;

{ Every active floating number for one target, rising and fading above
  (px, py). side 0 is a foe, 1 a party member. }
procedure DrawPops(side, idx, px, py: longint);
var
  i, yy, lit: longint;
  frac: double;
  base: TColor;
begin
  for i := 0 to High(Pops) do
    if (Pops[i].side = side) and (Pops[i].idx = idx) then begin
      frac := Pops[i].life / POP_LIFE;
      case Pops[i].color of
        POPC_FOEDMG:   base := RGB(250, 240, 180);
        POPC_PARTYDMG: base := RGB(245, 95, 85);
        POPC_HEAL:     base := RGB(120, 230, 130);
        POPC_WEAK:     base := RGB(255, 170, 60);    { struck a weakness }
        POPC_RESIST:   base := RGB(120, 170, 235);   { shrugged off }
      else             base := RGB(180, 180, 180);   { miss or status tag }
      end;
      lit := 110 + round(146 * frac);
      yy := py - round((1.0 - frac) * 12);
      DrawText(px - Length(Pops[i].text) * 3, yy, Pops[i].text, Shade(base, lit));
    end;
end;

{ A compact badge of the active status effects on a combatant. }
function StatusTag(const st: TStatus): string;
begin
  StatusTag := '';
  if st.poison > 0 then StatusTag := StatusTag + 'P';
  if st.burn > 0 then StatusTag := StatusTag + 'B';
  if st.stun > 0 then StatusTag := StatusTag + 'T';
  if st.slow > 0 then StatusTag := StatusTag + 'S';
end;

procedure CombatRender;
const
  FOE_YAW = 0.6;
  { the battlefield is one depth axis: foe ranks recede up and back, the
    party ranks stand forward toward the viewer. Reach then reads off the
    screen, a back-rank member is plainly behind the front line. }
  FOE_BACK_Y  = 34;  FOE_BACK_H  = 11;
  FOE_FRONT_Y = 70;  FOE_FRONT_H = 14;
  PTY_FRONT_Y = 92;
  PTY_BACK_Y  = 116;
  PANEL_Y     = 140;
var
  i, n, living, slot, cx, cy, x, mi, rk, half, col, ny: longint;
  c, body: TColor;
  s: string;
begin
  { backdrop: a dim vault receding behind the foes, a lit floor the party
    stands on, a horizon seam where the two sides meet }
  FillRect(0, 0, FBW, 88, RGB(20, 17, 26));
  FillRect(0, 88, FBW, FBH - 88, RGB(40, 32, 27));
  FillRect(0, 86, FBW, 2, RGB(62, 52, 46));

  { title bar }
  FillRect(0, 0, FBW, 14, RGB(30, 12, 12));
  FrameRect(0, 0, FBW, 14, RGB(90, 40, 30));
  DrawText(8, 3, 'COMBAT', RGB(230, 170, 120));
  if LivingFoes = 1 then s := '1 FOE' else s := IntToStr(LivingFoes) + ' FOES';
  DrawText(FBW - 96, 3, s, RGB(190, 180, 140));

  { --- foes, in depth ranks: back rank up and small, front rank nearer
    the clash and larger. Same rank spreads across columns. --- }
  RasterBeginFrame;     { clear depth before the foe models }
  for rk := RANK_BACK downto RANK_FRONT do begin
    living := 0;
    for i := 0 to High(Foes) do
      if Foes[i].alive and (Foes[i].rank = rk) then inc(living);
    if living < 1 then continue;
    slot := FBW div living;
    if rk = RANK_BACK then begin cy := FOE_BACK_Y; half := FOE_BACK_H; end
    else begin cy := FOE_FRONT_Y; half := FOE_FRONT_H; end;
    col := 0;
    for i := 0 to High(Foes) do begin
      if (not Foes[i].alive) or (Foes[i].rank <> rk) then continue;
      cx := slot * col + slot div 2;
      body := FOE_PAL[Foes[i].def mod 6];
      mi := FindModel(MonDefs[Foes[i].def].model);
      if mi >= 0 then
        DrawFoeModel(ModelReg[mi].mesh, cx, cy, FOE_YAW, half)
      else
        DrawFoeGlyph(cx, cy, 2 * half, 2 * half, body);
      if (i <= High(FoeFlash)) then
        DrawFlash(cx - half, cy - half, 2 * half, 2 * half, FoeFlash[i]);
      s := MonDefs[Foes[i].def].name;
      DrawText(cx - Length(s) * 3, cy - half - 8, s, RGB(215, 185, 175));
      DrawBar(cx - 16, cy + half + 1, 32, 3, Foes[i].hp, Foes[i].hpMax,
        RGB(200, 80, 70), RGB(50, 24, 24));
      if i <= High(FoeStatus) then begin
        s := StatusTag(FoeStatus[i]);
        if s <> '' then DrawText(cx + 20, cy + half - 2, s, RGB(190, 120, 215));
      end;
      DrawPops(0, i, cx, cy - half - 18);
      { the aim chevron sits to the left of the chosen foe }
      if (i = CurTarget) and (CombatPhase = CP_INPUT) and (cbMenu <> CB_ALLY) then
        DrawText(cx - half - 10, cy - 3, '>', RGB(245, 225, 120));
      inc(col);
    end;
    { a dim tag in the left margin names the rank's depth }
    if rk = RANK_BACK then s := 'BACK' else s := 'FRONT';
    DrawText(3, cy - 3, s, RGB(96, 88, 72));
  end;

  { --- party, in depth ranks: front rank forward near the clash, back
    rank to the rear near the viewer. Same rank spreads across columns. --- }
  n := Length(Roster);
  for rk := RANK_FRONT to RANK_BACK do begin
    living := 0;
    for i := 0 to n - 1 do if Roster[i].rank = rk then inc(living);
    if living < 1 then continue;
    if rk = RANK_FRONT then ny := PTY_FRONT_Y else ny := PTY_BACK_Y;
    slot := (FBW - 24) div living;
    if slot > 96 then slot := 96;
    col := 0;
    for i := 0 to n - 1 do begin
      if Roster[i].rank <> rk then continue;
      x := 16 + col * slot;
      if (i = CurActor) and (CombatPhase = CP_INPUT) then
        DrawText(x - 10, ny, '>', RGB(245, 230, 140));
      if (cbMenu = CB_ALLY) and (i = allySel) and (CombatPhase = CP_INPUT) then
        DrawText(x - 10, ny, '>', RGB(120, 220, 200));
      if not Roster[i].alive then c := RGB(160, 80, 80)
      else if Roster[i].downed then c := RGB(175, 135, 85)
      else if (i = CurActor) and (CombatPhase = CP_INPUT) then c := RGB(245, 230, 140)
      else c := RGB(205, 210, 190);
      DrawText(x, ny, Copy(Roster[i].name, 1, 8), c);
      if (i <= High(PartyStatus)) and Roster[i].alive and (not Roster[i].downed) then begin
        s := StatusTag(PartyStatus[i]);
        if s <> '' then DrawText(x + 50, ny, s, RGB(190, 120, 215));
      end;
      if not Roster[i].alive then
        DrawText(x, ny + 9, 'SLAIN', RGB(190, 90, 90))
      else if Roster[i].downed then
        DrawText(x, ny + 9, 'DOWN', RGB(190, 140, 90))
      else begin
        DrawText(x, ny + 9, IntToStr(Roster[i].hp) + '/'
          + IntToStr(Roster[i].hpMax), RGB(170, 175, 160));
        if Roster[i].guarding then DrawText(x + slot - 24, ny, 'GRD', RGB(150, 170, 210));
        if Roster[i].sp > 0 then
          DrawText(x + slot - 28, ny + 9, 'sp' + IntToStr(Roster[i].sp),
            RGB(150, 160, 205));
        DrawBar(x, ny + 18, slot - 16, 3, Roster[i].hp, Roster[i].hpMax,
          RGB(70, 170, 70), RGB(40, 20, 20));
      end;
      if (i <= High(PartyFlash)) then
        DrawFlash(x - 2, ny - 2, slot - 6, 26, PartyFlash[i]);
      DrawPops(1, i, x + 14, ny - 11);
      inc(col);
    end;
    { a dim tag at the right names the rank, when a short rank leaves room }
    if living <= 2 then begin
      if rk = RANK_FRONT then s := 'FRONT' else s := 'BACK';
      DrawText(FBW - 44, ny + 5, s, RGB(96, 92, 76));
    end;
  end;

  { --- bottom windows: the message box on the right, the command box on
    the left (the command box is drawn by DrawCombatMenu) --- }
  FillRectBlend(116, PANEL_Y, FBW - 122, FBH - PANEL_Y - 2, RGB(6, 8, 14), 235);
  FrameRect(116, PANEL_Y, FBW - 122, FBH - PANEL_Y - 2, RGB(110, 110, 140));
  for i := 0 to LOG_LINES - 1 do
    DrawText(122, PANEL_Y + 6 + i * 10, Log[i], RGB(175, 185, 170));

  if CombatOver then begin
    FillRectBlend(6, PANEL_Y, 104, FBH - PANEL_Y - 2, RGB(6, 8, 14), 235);
    FrameRect(6, PANEL_Y, 104, FBH - PANEL_Y - 2, RGB(150, 140, 90));
    if Victory then s := 'VICTORY'
    else if Fled then s := 'ESCAPED'
    else s := 'DEFEAT';
    DrawText(16, PANEL_Y + 14, s, RGB(235, 220, 150));
    DrawText(16, PANEL_Y + 34, 'PRESS', RGB(170, 170, 150));
    DrawText(16, PANEL_Y + 44, 'A KEY', RGB(170, 170, 150));
  end else
    DrawCombatMenu;
end;

{ Whether the actor could target this foe under the pending action: a
  spell reaches any living foe, a melee or ranged attack follows reach. }
function CombatCanTarget(foe: longint): boolean;
begin
  if (foe < 0) or (foe > High(Foes)) or (not Foes[foe].alive) then
    CombatCanTarget := false
  else if pendingSpell >= 0 then
    CombatCanTarget := true
  else
    CombatCanTarget := FoeReachable(CurActor, foe);
end;

{ Step the enemy cursor to the next targetable foe in a direction. }
procedure CombatCycleTarget(dir: longint);
var
  start, i, n: longint;
begin
  n := Length(Foes);
  if n = 0 then exit;
  i := CurTarget;
  if (i < 0) or (i >= n) then i := 0;
  start := i;
  repeat
    i := ((i + dir) mod n + n) mod n;
    if CombatCanTarget(i) then begin CurTarget := i; exit; end;
  until i = start;
end;

{ Step the ally cursor to the next living member. A heal may revive a
  downed ally, so the downed count as valid targets. }
procedure CombatCycleAlly(dir: longint);
var
  start, i, n: longint;
begin
  n := Length(Roster);
  if n = 0 then exit;
  i := allySel;
  if (i < 0) or (i >= n) then i := 0;
  start := i;
  repeat
    i := ((i + dir) mod n + n) mod n;
    if Roster[i].alive then begin allySel := i; exit; end;
  until i = start;
end;

{ Step the spell cursor to the next spell this actor can cast. }
procedure CombatStepSpell(dir: longint);
var
  start, i, n: longint;
begin
  n := SpellCount;
  if n = 0 then exit;
  i := spellSel;
  if (i < 0) or (i >= n) then i := 0;
  start := i;
  repeat
    i := ((i + dir) mod n + n) mod n;
    if ActorCanCast(CurActor, i) then begin spellSel := i; exit; end;
  until i = start;
end;

{ Return to the command menu, clearing any pending choice and picking a
  sane default target. Called at the top of each actor's turn. }
procedure CombatToCommand;
begin
  cbMenu := CB_COMMAND;
  cmdSel := CMD_ATTACK;
  pendingSpell := -1;
  if (CurTarget < 0) or (CurTarget > High(Foes)) or (not Foes[CurTarget].alive) then
    CurTarget := FirstLivingFoe;
end;

procedure CombatConfirmCommand;
var
  i: longint;
begin
  case cmdSel of
    CMD_ATTACK: begin
      pendingSpell := -1;
      CurTarget := FirstReachable(CurActor);
      if CurTarget < 0 then begin
        CombatLog(Roster[CurActor].name + ' has no target in reach.');
        PlaySfx(SFX_DOWN);
      end else begin
        cbMenu := CB_TARGET; PlaySfx(SFX_SELECT);
      end;
    end;
    CMD_CAST: begin
      spellSel := -1;
      for i := 0 to SpellCount - 1 do
        if ActorCanCast(CurActor, i) then begin spellSel := i; break; end;
      if spellSel < 0 then begin
        CombatLog(Roster[CurActor].name + ' has no spell to cast.');
        PlaySfx(SFX_DOWN);
      end else begin
        cbMenu := CB_SPELL; PlaySfx(SFX_SELECT);
      end;
    end;
    CMD_ITEM:  begin ActPotion; PlaySfx(SFX_PICK); CombatToCommand; end;
    CMD_GUARD: begin ActGuard; PlaySfx(SFX_SELECT); CombatToCommand; end;
    CMD_MOVE:  begin ActMove; PlaySfx(SFX_SELECT); CombatToCommand; end;
    CMD_FLEE:  begin ActFlee; PlaySfx(SFX_SELECT); CombatToCommand; end;
  end;
end;

procedure CombatConfirmSpell;
var
  sp: TSpell;
begin
  if not ActorCanCast(CurActor, spellSel) then begin PlaySfx(SFX_DOWN); exit; end;
  sp := SpellInfo(spellSel);
  pendingSpell := spellSel;
  case sp.mode of
    TGT_ENEMY, TGT_ENEMY_RANK: begin
      CurTarget := FirstLivingFoe;
      cbMenu := CB_TARGET; PlaySfx(SFX_SELECT);
    end;
    TGT_ALLY: begin
      allySel := CurActor;
      if not Roster[allySel].alive then CombatCycleAlly(1);
      cbMenu := CB_ALLY; PlaySfx(SFX_SELECT);
    end;
    TGT_PARTY: begin
      ActCast(pendingSpell, -1); PlaySfx(SFX_SELECT); CombatToCommand;
    end;
  end;
end;

procedure CombatBack;
begin
  case cbMenu of
    CB_TARGET:
      if pendingSpell >= 0 then cbMenu := CB_SPELL else cbMenu := CB_COMMAND;
    CB_SPELL: cbMenu := CB_COMMAND;
    CB_ALLY:  cbMenu := CB_SPELL;
  end;
  if cbMenu <> CB_TARGET then pendingSpell := -1;
  PlaySfx(SFX_SELECT);
end;

procedure CombatKeyDown(scancode: longint);
begin
  if CombatOver then begin
    EndCombat;
    exit;
  end;
  if CombatBusy or (CurActor < 0) then exit;   { a beat or the foe turn is running }

  case cbMenu of
    CB_COMMAND:
      case scancode of
        SDL_SCANCODE_UP, SDL_SCANCODE_W:
          cmdSel := (cmdSel + CMD_COUNT - 1) mod CMD_COUNT;
        SDL_SCANCODE_DOWN, SDL_SCANCODE_S:
          cmdSel := (cmdSel + 1) mod CMD_COUNT;
        SDL_SCANCODE_RETURN, SDL_SCANCODE_SPACE:
          CombatConfirmCommand;
      end;
    CB_TARGET:
      case scancode of
        SDL_SCANCODE_UP, SDL_SCANCODE_LEFT, SDL_SCANCODE_TAB:
          CombatCycleTarget(-1);
        SDL_SCANCODE_DOWN, SDL_SCANCODE_RIGHT:
          CombatCycleTarget(1);
        SDL_SCANCODE_RETURN, SDL_SCANCODE_SPACE: begin
          if pendingSpell >= 0 then begin
            ActCast(pendingSpell, CurTarget); PlaySfx(SFX_HIT);
          end else begin
            ActAttack; PlaySfx(SFX_HIT);
          end;
          CombatToCommand;
        end;
        SDL_SCANCODE_ESCAPE: CombatBack;
      end;
    CB_SPELL:
      case scancode of
        SDL_SCANCODE_UP, SDL_SCANCODE_W:   CombatStepSpell(-1);
        SDL_SCANCODE_DOWN, SDL_SCANCODE_S: CombatStepSpell(1);
        SDL_SCANCODE_RETURN, SDL_SCANCODE_SPACE: CombatConfirmSpell;
        SDL_SCANCODE_ESCAPE: CombatBack;
      end;
    CB_ALLY:
      case scancode of
        SDL_SCANCODE_UP, SDL_SCANCODE_LEFT:   CombatCycleAlly(-1);
        SDL_SCANCODE_DOWN, SDL_SCANCODE_RIGHT: CombatCycleAlly(1);
        SDL_SCANCODE_RETURN, SDL_SCANCODE_SPACE: begin
          ActCast(pendingSpell, allySel); PlaySfx(SFX_SELECT);
          CombatToCommand;
        end;
        SDL_SCANCODE_ESCAPE: CombatBack;
      end;
  end;

  if CombatOver and (not Victory) and (not Fled) then PlaySfx(SFX_DOWN);
end;

{ ---- Dialog state ---- }

procedure DialogRender;
var
  i, py, n: longint;
begin
  if UsePoly then RenderViewPoly else RenderView;
  FillRectBlend(0, 0, FBW, FBH, RGB(0, 0, 0), 120);
  py := 118;
  FillRectBlend(8, py, FBW - 16, FBH - py - 8, RGB(14, 12, 20), 230);
  FrameRect(8, py, FBW - 16, FBH - py - 8, RGB(120, 110, 90));
  DrawText(16, py + 6, dlgNpcName, RGB(230, 210, 140));
  if DlgActive then begin
    DrawWrapped(16, py + 20, 48, Convs[DlgConv].nodes[DlgNode].text,
      RGB(205, 205, 190));
    n := DialogRespCount;
    for i := 0 to n - 1 do
      DrawText(20, py + 56 + i * 11,
        IntToStr(i + 1) + ') ' + DialogRespText(i), RGB(170, 200, 170));
  end;
end;

procedure SyncJournal;
{** Turn freshly set quest flags into journal lines, once each. }
begin
  if FlagHas('QUEST_MAIN') and (not FlagHas('J_MAIN')) then begin
    JournalAdd('Aid the town against the things from the deep.');
    FlagSet('J_MAIN');
  end;
  if FlagHas('QUEST_CRYPT') and (not FlagHas('J_CRYPT')) then begin
    JournalAdd('Clear the crypt beneath the town for the reeve.');
    FlagSet('J_CRYPT');
  end;
  if FlagHas('QUEST_RELIC') and (not FlagHas('J_RELIC')) then begin
    JournalAdd('Recovered the relic shard. Return it to the elder.');
    FlagSet('J_RELIC');
  end;
end;

procedure DialogAfterChoice;
begin
  SyncJournal;
  if FlagHas('QUEST_WON') then begin
    State := gsVictory;
    exit;
  end;
  if DlgShopReq then begin
    shopSel := 0;
    State := gsShop;
  end else if not DlgActive then
    State := gsExplore;
end;

procedure DialogKeyDown(scancode: longint);
var
  pick: longint;
begin
  pick := -1;
  case scancode of
    SDL_SCANCODE_1: pick := 0;
    SDL_SCANCODE_2: pick := 1;
    SDL_SCANCODE_3: pick := 2;
    SDL_SCANCODE_4: pick := 3;
    SDL_SCANCODE_5: pick := 4;
    SDL_SCANCODE_ESCAPE: begin DlgActive := false; State := gsExplore; exit; end;
  end;
  if (pick >= 0) and (pick < DialogRespCount) then begin
    DialogChoose(pick);
    DialogAfterChoice;
  end;
end;

{ ---- Shop state ---- }

function BuyableCount: longint;
var i, n: longint;
begin
  n := 0;
  for i := 0 to High(ItemDefs) do
    if (ItemDefs[i].value > 0) and (ItemDefs[i].kind <> IK_TREASURE) then inc(n);
  BuyableCount := n;
end;

function NthBuyable(idx: longint): longint;
var i, n: longint;
begin
  n := 0;
  for i := 0 to High(ItemDefs) do
    if (ItemDefs[i].value > 0) and (ItemDefs[i].kind <> IK_TREASURE) then begin
      if n = idx then begin NthBuyable := i; exit; end;
      inc(n);
    end;
  NthBuyable := -1;
end;

procedure ShopRender;
var
  i, cnt, di, y: longint;
  c: TColor;
begin
  ClearFB(RGB(12, 10, 14));
  DrawText(12, 8, 'TRADER', RGB(220, 200, 120));
  DrawText(FBW - 120, 8, 'GOLD ' + IntToStr(PartyGold), RGB(220, 200, 120));
  cnt := BuyableCount;
  y := 26;
  for i := 0 to cnt - 1 do begin
    di := NthBuyable(i);
    if i = shopSel then begin
      c := RGB(240, 230, 150);
      DrawText(10, y, '>', c);
    end else
      c := RGB(180, 180, 160);
    DrawText(18, y, ItemDefs[di].name, c);
    DrawText(180, y, IntToStr(ItemDefs[di].value) + ' GP', c);
    inc(y, 11);
    if y > FBH - 24 then break;
  end;
  DrawText(12, FBH - 14, 'ARROWS SELECT  ENTER BUY  ESC LEAVE', RGB(140, 150, 120));
end;

procedure ShopKeyDown(scancode: longint);
var
  cnt, di: longint;
begin
  cnt := BuyableCount;
  case scancode of
    SDL_SCANCODE_UP:   if shopSel > 0 then dec(shopSel);
    SDL_SCANCODE_DOWN: if shopSel < cnt - 1 then inc(shopSel);
    SDL_SCANCODE_RETURN, SDL_SCANCODE_SPACE: begin
      di := NthBuyable(shopSel);
      if (di >= 0) and (PartyGold >= ItemDefs[di].value) and (Length(Roster) > 0) then
      begin
        PartyGold := PartyGold - ItemDefs[di].value;
        PackAdd(Roster[0], ItemDefs[di].id, 1);
        PlaySfx(SFX_PICK);
      end;
    end;
    SDL_SCANCODE_ESCAPE: begin
      DlgShopReq := false;
      if DlgActive then State := gsDialog else State := gsExplore;
    end;
  end;
end;

{ ---- Full map state ---- }

procedure FullMapKeyDown(scancode: longint);
begin
  case scancode of
    SDL_SCANCODE_TAB, SDL_SCANCODE_ESCAPE, SDL_SCANCODE_M:
      State := gsExplore;
  end;
end;

{ ---- Journal state ---- }

procedure JournalRender;
var
  i, y: longint;
begin
  ClearFB(RGB(10, 10, 16));
  DrawText(12, 10, 'JOURNAL', RGB(220, 200, 120));
  if Length(Journal) = 0 then
    DrawText(16, 30, 'No quests recorded yet.', RGB(150, 150, 130))
  else begin
    y := 30;
    for i := 0 to High(Journal) do begin
      DrawWrapped(16, y, 48, '- ' + Journal[i], RGB(195, 200, 180));
      inc(y, 22);
    end;
  end;
  DrawText(12, FBH - 14, 'J OR ESC TO CLOSE', RGB(130, 140, 110));
end;

procedure JournalKeyDown(scancode: longint);
begin
  case scancode of
    SDL_SCANCODE_J, SDL_SCANCODE_ESCAPE: State := gsExplore;
  end;
end;

{ ---- Game over state ---- }

procedure GameOverRender;
begin
  ClearFB(RGB(16, 6, 8));
  DrawCenter(90, 'THE PARTY HAS FALLEN', RGB(220, 120, 110));
  DrawCenter(110, 'PRESS A KEY', RGB(150, 130, 120));
end;

procedure GameOverKeyDown(scancode: longint);
begin
  titleSel := 0;
  State := gsTitle;
end;

{ ---- Options state ---- }

procedure OptionsRender;
const
  LABELS: array[0 .. 2] of string = ('MASTER', 'MUSIC', 'SFX');
var
  i, y, v: longint;
  c: TColor;
begin
  ClearFB(RGB(12, 12, 16));
  DrawCenter(20, 'OPTIONS', RGB(220, 200, 120));
  y := 60;
  for i := 0 to 2 do begin
    if i = optSel then c := RGB(240, 230, 150) else c := RGB(160, 160, 140);
    DrawText(60, y, LABELS[i], c);
    case i of
      0: v := volMaster;
      1: v := volMusic;
    else v := volSfx;
    end;
    FillRect(130, y, 102, 7, RGB(40, 40, 46));
    FillRect(131, y + 1, v, 5, RGB(90, 160, 110));
    DrawText(240, y, IntToStr(v), c);
    inc(y, 20);
  end;
  DrawCenter(FBH - 20, 'ARROWS ADJUST   ESC BACK', RGB(130, 140, 110));
end;

procedure OptionsKeyDown(scancode: longint);
var
  delta: longint;
begin
  delta := 0;
  case scancode of
    SDL_SCANCODE_UP:   if optSel > 0 then dec(optSel);
    SDL_SCANCODE_DOWN: if optSel < 2 then inc(optSel);
    SDL_SCANCODE_LEFT:  delta := -10;
    SDL_SCANCODE_RIGHT: delta := 10;
    SDL_SCANCODE_ESCAPE: begin State := gsTitle; exit; end;
  end;
  if delta <> 0 then begin
    case optSel of
      0: volMaster := volMaster + delta;
      1: volMusic := volMusic + delta;
    else volSfx := volSfx + delta;
    end;
    if volMaster < 0 then volMaster := 0; if volMaster > 100 then volMaster := 100;
    if volMusic < 0 then volMusic := 0;   if volMusic > 100 then volMusic := 100;
    if volSfx < 0 then volSfx := 0;        if volSfx > 100 then volSfx := 100;
    SetAudioVolumes(volMaster, volMusic, volSfx);
    PlaySfx(SFX_SELECT);
  end;
end;

{ ---- Victory state ---- }

procedure VictoryRender;
begin
  ClearFB(RGB(8, 14, 10));
  DrawCenter(80, 'THE DEEP IS SEALED', RGB(230, 220, 140));
  DrawCenter(96, 'THE TOWN IS SAVED', RGB(180, 200, 160));
  DrawCenter(120, 'PRESS A KEY', RGB(140, 150, 120));
end;

procedure VictoryKeyDown(scancode: longint);
begin
  titleSel := 0;
  State := gsTitle;
end;

{ ---- State machine entry points ---- }

function FindPak: string;
{** Look for game.pak next to the binary, then in common run dirs. }
var
  base: string;
begin
  base := ExtractFilePath(ParamStr(0));
  if FileExists(base + 'game.pak') then
    FindPak := base + 'game.pak'
  else if FileExists('game.pak') then
    FindPak := 'game.pak'
  else if FileExists('build/game.pak') then
    FindPak := 'build/game.pak'
  else
    FindPak := '';
end;

function GameInit: boolean;
var
  pakPath: string;
begin
  GameInit := false;
  pakPath := FindPak;
  if pakPath = '' then begin
    writeln(StdErr, 'game: could not find game.pak (run make to build it)');
    exit;
  end;
  if not PakLoad(pakPath, GamePak) then begin
    writeln(StdErr, 'game: could not load ', pakPath);
    exit;
  end;
  if not LoadTextures(GamePak) then begin
    writeln(StdErr, 'game: missing or bad textures in ', pakPath);
    exit;
  end;
  if not LoadItems(GamePak) then begin
    writeln(StdErr, 'game: missing or bad item table in ', pakPath);
    exit;
  end;
  if not LoadCharData(GamePak) then begin
    writeln(StdErr, 'game: missing species/class/background tables in ', pakPath);
    exit;
  end;
  if not LoadMonsters(GamePak) then begin
    writeln(StdErr, 'game: missing monster table in ', pakPath);
    exit;
  end;
  LoadDialogs(GamePak);   { optional; dialogs just will not open if absent }
  LoadWorld(GamePak);     { optional; dynamic-map manifest }
  LoadModels(GamePak);    { optional; polygon-renderer props }

  TimeReset;
  MoonOffsetDays := (WorldSeed mod 2953) / 100.0;  { seed the moon phase }

  AudioInit(GamePak);   { silent if the device or libxmp is absent }
  volMaster := 80; volMusic := 55; volSfx := 90;
  SetAudioVolumes(volMaster, volMusic, volSfx);
  keys := PKeyArray(SDL_GetKeyboardState(nil));
  showMap := true;
  QuitRequested := false;
  cursorX := FBW div 2;
  cursorY := FBH div 2;
  rmbHeld := false;
  titleSel := 0;
  State := gsTitle;
  GameInit := true;
end;

procedure GameHandleEvents;
var
  ev: TSDL_Event;
begin
  while SDL_PollEvent(@ev) <> 0 do begin
    case ev.kind of
      SDL_QUITEV:
        QuitRequested := true;
      SDL_KEYDOWN:
        case State of
          gsTitle:    TitleKeyDown(ev.key.keysym.scancode);
          gsNewParty: CCKeyDown(ev.key.keysym.scancode);
          gsExplore:  ExploreKeyDown(ev.key.keysym.scancode);
          gsFullMap:  FullMapKeyDown(ev.key.keysym.scancode);
          gsDialog:   DialogKeyDown(ev.key.keysym.scancode);
          gsShop:     ShopKeyDown(ev.key.keysym.scancode);
          gsMenu:     JournalKeyDown(ev.key.keysym.scancode);
          gsCombat:   CombatKeyDown(ev.key.keysym.scancode);
          gsGameOver: GameOverKeyDown(ev.key.keysym.scancode);
          gsVictory:  VictoryKeyDown(ev.key.keysym.scancode);
          gsOptions:  OptionsKeyDown(ev.key.keysym.scancode);
        end;
      SDL_MOUSEMOTION:
        case State of
          gsExplore: ExploreMouseMotion(ev.motion.xrel, ev.motion.yrel);
        end;
      SDL_MOUSEBUTTONDOWN:
        case State of
          gsExplore: ExploreMouseButton(true, ev.button.button);
        end;
      SDL_MOUSEBUTTONUP:
        case State of
          gsExplore: ExploreMouseButton(false, ev.button.button);
        end;
    end;
  end;
end;

procedure CombatAutoTurn(dt: double);
{** Advance the combat clock, then, if the member now up has lost control
  to the were-beast, take its turn for it. Pacing handles the rest. }
begin
  CombatUpdate(dt);
  if CombatSfxCue = CUE_HIT then PlaySfx(SFX_HIT);
  CombatSfxCue := CUE_NONE;
  if (CombatPhase = CP_INPUT) and (not CombatOver)
    and (CurActor >= 0) and (CurActor <= High(Roster))
    and Roster[CurActor].wereform and Roster[CurActor].alive
    and (not Roster[CurActor].downed) then begin
    ActAttack;
    PlaySfx(SFX_HIT);
    { back-rank with nothing in reach: guard so the turn still passes }
    if (CombatPhase = CP_INPUT) and (not CombatOver) then ActGuard;
  end;
end;

procedure GameUpdate(dt: double);
begin
  UpdateLycanthropy;   { the moon acts in every state }
  case State of
    gsExplore: ExploreUpdate(dt);
    gsCombat:  CombatAutoTurn(dt);
  end;
end;

procedure UpdateMusic;
begin
  case State of
    gsTitle, gsNewParty: PlayMusic(MUS_TITLE);
    gsCombat:            PlayMusic(MUS_COMBAT);
    gsGameOver:          StopMusic;
  else
    if CurMapName = 'TOWN' then PlayMusic(MUS_TOWN)
    else PlayMusic(MUS_DUNGEON);
  end;
end;

procedure GameRender(fps: longint);
begin
  UpdateMusic;
  case State of
    gsTitle:    TitleRender;
    gsNewParty: CCRender;
    gsExplore:  ExploreRender(fps);
    gsFullMap:  DrawFullMap;
    gsDialog:   DialogRender;
    gsShop:     ShopRender;
    gsMenu:     JournalRender;
    gsCombat:   CombatRender;
    gsGameOver: GameOverRender;
    gsVictory:  VictoryRender;
    gsOptions:  OptionsRender;
  end;
end;

end.
