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

implementation

uses
  sysutils, sdl2min, gfx, pak, mapfmt, world, raycast, hud, textures,
  rng, rules, items, chardata, party, monsters, combat, flags, dialog,
  mapstate, save, worldfmt, mapgen, audio;

const
  MOUSE_YAW    = 0.0040;  { radians per mouse unit, free look }
  MOUSE_PITCH  = 0.7;     { pixels per mouse unit, free look }

type
  TKeyArray = array[0 .. SDL_NUM_SCANCODES - 1] of UInt8;
  PKeyArray = ^TKeyArray;

var
  keys: PKeyArray;
  showMap: boolean;
  GamePak: TPak;
  lastTX, lastTY: longint;
  cursorX, cursorY: longint;
  rmbHeld: boolean;
  dlgNpcName: string;
  shopSel: longint;
  saveMsg: string;
  saveMsgT: double;
  optSel: longint;
  volMaster, volMusic, volSfx: longint;

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

function SavePath: string;
begin
  SavePath := ExtractFilePath(ParamStr(0)) + 'save1.sav';
end;

function LoadMapLump(const name: string): boolean;
{** Bring a map into the world. A static map is decoded from its pak
  lump; a dynamic map is generated from its stored or a fresh seed. The
  map being left is captured, and the one entered has its fog and doors
  restored. }
var
  blob: TByteArray;
  md: TMapData;
  di, ver: longint;
  seed: longword;
  isDyn: boolean;
begin
  LoadMapLump := false;
  ver := 0; seed := 0; isDyn := false;
  if PakGet(GamePak, name, blob) then begin
    if not DecodeMap(blob, md) then exit;
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
  end;
  if CurMapName <> '' then
    MapStateCapture(CurMapName);
  if not LoadMapData(md) then exit;
  CurMapName := name;
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
  StartRandomEncounter(depth);
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
  if PortalAt(TileX, TileY, target, marker) then begin
    LoadMapByName(target, marker);
    exit;
  end;
  PoisonTick;
  TrapCheck;
  if not PartyConscious then begin
    State := gsGameOver;
    exit;
  end;
  { Town is safe; elsewhere a small per-step chance of an encounter. }
  if (CurMapName <> 'TOWN') and (Length(Roster) > 0) then
    if Range(1, 18) = 1 then
      StartCombat(1);
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

procedure ExploreRender(fps: longint);
begin
  RenderView;
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
{** Hand off from the menus to the starting town. }
begin
  FlagsReset;
  MapStateReset;
  CurMapName := '';
  if not LoadMapByName('TOWN', 'spawn') then begin
    writeln(StdErr, 'game: could not load the starting map');
    QuitRequested := true;
    exit;
  end;
  State := gsExplore;
end;

{ ---- Title state ---- }

const
  TITLE_ITEMS = 5;

procedure TitleRender;
const
  LABELS: array[0 .. TITLE_ITEMS - 1] of string = (
    'CONTINUE', 'NEW GAME', 'QUICK START', 'OPTIONS', 'QUIT');
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

procedure QuickStart;
{** Make a ready-to-play party of four and dive in. }
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
  StartGame;
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
    3: begin optSel := 0; State := gsOptions; end;
    4: QuitRequested := true;
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
  if Victory or Fled then
    State := gsExplore
  else
    State := gsGameOver;
end;

const
  BAND_LABEL: array[0 .. 2] of string = ('ENGAGED', 'NEAR', 'FAR');

procedure CombatRender;
var
  i, y: longint;
  c: TColor;
  s: string;
begin
  ClearFB(RGB(10, 8, 12));
  DrawText(12, 8, 'COMBAT', RGB(220, 160, 120));
  DrawText(FBW - 120, 8, 'RANGE: ' + BAND_LABEL[Band], RGB(180, 180, 140));

  { party }
  y := 26;
  for i := 0 to High(Roster) do begin
    if (i = CurActor) and (not CombatOver) then
      DrawText(8, y, '>', RGB(240, 230, 150));
    if not Roster[i].alive then c := RGB(110, 60, 60)
    else if Roster[i].downed then c := RGB(150, 110, 70)
    else c := RGB(200, 210, 190);
    s := Roster[i].name + ' ' + IntToStr(Roster[i].hp) + '/'
      + IntToStr(Roster[i].hpMax);
    if not Roster[i].alive then s := s + ' SLAIN'
    else if Roster[i].downed then s := s + ' DOWN'
    else if Roster[i].guarding then s := s + ' GUARD';
    DrawText(16, y, s, c);
    inc(y, 11);
  end;

  { foes }
  y := 26;
  for i := 0 to High(Foes) do begin
    if not Foes[i].alive then continue;
    if i = CurTarget then
      DrawText(FBW - 128, y, '*', RGB(240, 120, 120));
    DrawText(FBW - 120, y, MonDefs[Foes[i].def].name + ' '
      + IntToStr(Foes[i].hp), RGB(210, 170, 160));
    inc(y, 11);
  end;

  { log }
  for i := 0 to LOG_LINES - 1 do
    DrawText(12, FBH - 70 + i * 10, Log[i], RGB(160, 170, 150));

  if CombatOver then
    DrawCenter(FBH - 12, 'PRESS A KEY', RGB(230, 220, 150))
  else
    DrawText(12, FBH - 12,
      'A ATTACK  G GUARD  F ADVANCE  R WITHDRAW  P POTION  TAB TARGET',
      RGB(140, 150, 120));
end;

procedure CombatKeyDown(scancode: longint);
begin
  if CombatOver then begin
    EndCombat;
    exit;
  end;
  case scancode of
    SDL_SCANCODE_A, SDL_SCANCODE_SPACE, SDL_SCANCODE_RETURN: begin
      ActAttack; PlaySfx(SFX_HIT);
    end;
    SDL_SCANCODE_G: begin ActGuard; PlaySfx(SFX_SELECT); end;
    SDL_SCANCODE_F: begin ActAdvance; PlaySfx(SFX_SELECT); end;
    SDL_SCANCODE_R: begin ActWithdraw; PlaySfx(SFX_SELECT); end;
    SDL_SCANCODE_P: begin ActPotion; PlaySfx(SFX_PICK); end;
    SDL_SCANCODE_TAB: NextTarget;
  end;
  if CombatOver and (not Victory) and (not Fled) then PlaySfx(SFX_DOWN);
end;

{ ---- Dialog state ---- }

procedure DialogRender;
var
  i, py, n: longint;
begin
  RenderView;
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

  AudioInit;   { silent if it fails }
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

procedure GameUpdate(dt: double);
begin
  case State of
    gsExplore: ExploreUpdate(dt);
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
