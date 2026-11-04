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
  sysutils, sdl2min, pak, world, raycast, hud, textures;

const
  MOVE_SPEED   = 3.2;     { tiles per second }
  TURN_SPEED   = 2.6;     { radians per second }
  MOUSE_YAW    = 0.0022;  { radians per mouse unit }
  MOUSE_PITCH  = 0.8;     { pixels per mouse unit }

type
  TKeyArray = array[0 .. SDL_NUM_SCANCODES - 1] of UInt8;
  PKeyArray = ^TKeyArray;

var
  keys: PKeyArray;
  showMap: boolean;
  GamePak: TPak;

function KeyDown(scancode: longint): boolean; inline;
begin
  KeyDown := keys^[scancode] <> 0;
end;

{ ---- Exploration state ---- }

procedure ExploreKeyDown(scancode: longint);
begin
  case scancode of
    SDL_SCANCODE_ESCAPE: QuitRequested := true;
    SDL_SCANCODE_SPACE:  ToggleDoorAhead;
    SDL_SCANCODE_M:      showMap := not showMap;
  end;
end;

procedure ExploreMouseMotion(xrel, yrel: longint);
begin
  RotatePlayer(xrel * MOUSE_YAW);
  AddPitch(-yrel * MOUSE_PITCH);
end;

procedure ExploreUpdate(dt: double);
var
  fwd, strafe: double;
begin
  fwd := 0;
  strafe := 0;
  if KeyDown(SDL_SCANCODE_W) then fwd := fwd + 1;
  if KeyDown(SDL_SCANCODE_S) then fwd := fwd - 1;
  if KeyDown(SDL_SCANCODE_Q) then strafe := strafe - 1;
  if KeyDown(SDL_SCANCODE_E) then strafe := strafe + 1;
  { A/D strafe as well, a common crawler layout }
  if KeyDown(SDL_SCANCODE_A) then strafe := strafe - 1;
  if KeyDown(SDL_SCANCODE_D) then strafe := strafe + 1;

  if (fwd <> 0) or (strafe <> 0) then
    MovePlayer(fwd * MOVE_SPEED * dt, strafe * MOVE_SPEED * dt);

  { Arrow keys: up/down move, left/right turn, as in the DOS crawlers. }
  if KeyDown(SDL_SCANCODE_UP) then
    MovePlayer(MOVE_SPEED * dt, 0);
  if KeyDown(SDL_SCANCODE_DOWN) then
    MovePlayer(-MOVE_SPEED * dt, 0);
  if KeyDown(SDL_SCANCODE_LEFT) then
    RotatePlayer(-TURN_SPEED * dt);
  if KeyDown(SDL_SCANCODE_RIGHT) then
    RotatePlayer(TURN_SPEED * dt);
end;

procedure ExploreRender(fps: longint);
begin
  RenderView;
  DrawHud(showMap, fps);
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

  InitWorld;
  keys := PKeyArray(SDL_GetKeyboardState(nil));
  showMap := true;
  QuitRequested := false;
  State := gsExplore;
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
          gsExplore: ExploreKeyDown(ev.key.keysym.scancode);
        end;
      SDL_MOUSEMOTION:
        case State of
          gsExplore: ExploreMouseMotion(ev.motion.xrel, ev.motion.yrel);
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
    gsExplore: ExploreRender(fps);
  end;
end;

end.
