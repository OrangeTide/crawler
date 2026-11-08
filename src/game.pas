unit game;

{** Top-level game state machine.

  The game is a set of states (title, exploration, combat, and so on).
  One state is active at a time, held in gamestate. This unit is the thin
  top level: it loads the pak and tables at startup, then each frame routes
  input, update and render to the unit that owns the active state (titleui,
  exploreui, combatui, dialogui, shopui, charcreateui, miscui). The
  platform layer in crawler.lpr only pumps SDL and uploads the framebuffer. }

{$mode objfpc}{$H+}

interface

function GameInit: boolean;
procedure GameHandleEvents;
procedure GameUpdate(dt: double);
procedure GameRender(fps: longint);
{ Jump a pregen party straight into a test encounter (menu / --combat). }
procedure QuickBattle;

implementation

uses
  sysutils, sdl2min, gfx, pak, world, models, hud, textures, items, chardata,
  monsters, dialog, spelldb, shops, encounters, worldfmt, overworld, gamestate,
  worldload, combatui, exploreui, charcreateui, titleui, dialogui, shopui,
  miscui, overworldui, gametime, audio, settings, codex, apppaths;

var
  palIsTitle: boolean = false;   { the title's CLUT is active }

procedure QuickBattle;
{** Delegate to titleui so crawler.lpr's bare QuickBattle still resolves. }
begin
  titleui.QuickBattle;
end;

{ ---- State machine entry points ---- }

function FindPak: string;
{** Look for game.pak through the relocatable asset search. }
begin
  FindPak := AssetPath('game.pak');
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
  LoadSpells(GamePak);    { optional; the imported spell catalog }
  LoadShops(GamePak);     { optional; shop stock lists }
  LoadEncounters(GamePak); { optional; per-area encounter tables }
  LoadWorld(GamePak);     { optional; dynamic-map manifest }
  LoadModels(GamePak);    { optional; polygon-renderer props }
  CodexReset;             { size the bestiary and item knowledge to the tables }

  TimeReset;
  MoonOffsetDays := (WorldSeed mod 2953) / 100.0;  { seed the moon phase }

  AudioInit(GamePak);   { silent if the device or libxmp is absent }
  SettingsLoad;         { volumes, difficulty and key bindings, then applied }
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
          gsKeybind:  KeybindKeyDown(ev.key.keysym.scancode);
          gsOverworld: OverworldKeyDown(ev.key.keysym.scancode);
        end;
      SDL_MOUSEMOTION:
        case State of
          gsExplore: ExploreMouseMotion(ev.motion.xrel, ev.motion.yrel);
          gsFullMap: FullMapMouseMotion(ev.motion.xrel, ev.motion.yrel);
        end;
      SDL_MOUSEBUTTONDOWN:
        case State of
          gsExplore: ExploreMouseButton(true, ev.button.button);
          gsFullMap: FullMapMouseButton(ev.button.button);
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
  { the title carries its own 256-colour palette; swap it in while on the
    title and restore the game palette on the way out }
  if State = gsTitle then begin
    if not palIsTitle then begin TitleUsePalette; palIsTitle := true; end;
  end else if palIsTitle then begin
    UseGamePalette; palIsTitle := false;
  end;
  case State of
    gsTitle:    TitleRender;
    gsNewParty: CCRender;
    gsExplore:  ExploreRender(fps);
    gsFullMap:  FullMapRender;
    gsDialog:   DialogRender;
    gsShop:     ShopRender;
    gsMenu:     JournalRender;
    gsCombat:   CombatRender;
    gsGameOver: GameOverRender;
    gsVictory:  VictoryRender;
    gsOptions:  OptionsRender;
    gsKeybind:  KeybindRender;
    gsOverworld: OverworldRender;
  end;
end;

end.
