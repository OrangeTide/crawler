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
                gsDialog, gsFullMap, gsInventory, gsMenu, gsGameOver);

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
  rng, rules, items, chardata, party;

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

function LoadMapByName(const name, marker: string): boolean;
{** Pull a map lump from the pak, decode it and place the party. }
var
  blob: TByteArray;
  md: TMapData;
begin
  LoadMapByName := false;
  if not PakGet(GamePak, name, blob) then
    exit;
  if not DecodeMap(blob, md) then
    exit;
  if not LoadMapData(md) then
    exit;
  PlaceAtMarker(marker);
  lastTX := TileX;
  lastTY := TileY;
  LoadMapByName := true;
end;

function KeyDown(scancode: longint): boolean; inline;
begin
  KeyDown := keys^[scancode] <> 0;
end;

{ ---- Exploration state ---- }

procedure ExploreInteract;
{** Left click: act on whatever tile the cursor points at. For now that
  means opening or closing a door within reach. }
var
  camX: double;
  tx, ty: longint;
begin
  camX := 2.0 * cursorX / FBW - 1.0;
  if PickTile(camX, 1.8, tx, ty) then
    if TileAt(tx, ty) = TILE_DOOR then
      ToggleDoor(tx, ty);
end;

procedure ExploreKeyDown(scancode: longint);
begin
  case scancode of
    SDL_SCANCODE_ESCAPE: QuitRequested := true;
    SDL_SCANCODE_SPACE:  OpenDoorAhead;
    SDL_SCANCODE_M:      showMap := not showMap;
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

procedure CheckPortal;
{** On stepping onto a new tile, follow a portal if one is there. }
var
  target, marker: string;
begin
  if (TileX = lastTX) and (TileY = lastTY) then
    exit;
  lastTX := TileX;
  lastTY := TileY;
  if PortalAt(TileX, TileY, target, marker) then
    LoadMapByName(target, marker);
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
  CheckPortal;
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
  DrawCursor;
end;

{ ---- Shared UI helpers ---- }

procedure DrawCenter(y: longint; const s: string; c: TColor);
begin
  DrawText((FBW - Length(s) * 6) div 2, y, s, c);
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
{** Hand off from the menus to the dungeon. }
begin
  if not LoadMapByName('DUNGEON', 'start') then begin
    writeln(StdErr, 'game: could not load the starting map');
    QuitRequested := true;
    exit;
  end;
  State := gsExplore;
end;

{ ---- Title state ---- }

const
  TITLE_ITEMS = 3;

procedure TitleRender;
const
  LABELS: array[0 .. TITLE_ITEMS - 1] of string = (
    'NEW GAME', 'QUICK START', 'QUIT');
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
    0: begin State := gsNewParty; NewParty; ccSlot := 0; CCBeginSlot; end;
    1: QuickStart;
    2: QuitRequested := true;
  end;
end;

procedure TitleKeyDown(scancode: longint);
begin
  case scancode of
    SDL_SCANCODE_UP:     titleSel := (titleSel + TITLE_ITEMS - 1) mod TITLE_ITEMS;
    SDL_SCANCODE_DOWN:   titleSel := (titleSel + 1) mod TITLE_ITEMS;
    SDL_SCANCODE_RETURN, SDL_SCANCODE_SPACE: TitleSelect;
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

procedure GameRender(fps: longint);
begin
  case State of
    gsTitle:    TitleRender;
    gsNewParty: CCRender;
    gsExplore:  ExploreRender(fps);
  end;
end;

end.
