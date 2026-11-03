program crawler;

{** A first person dungeon crawler with a textured raycasting engine.

  Renders at 320x240 into a software framebuffer, then upscales with
  nearest-neighbour filtering to a larger window for the retro look.
  Movement is continuous through a tile-grid dungeon: walk with WASD,
  turn and look up/down with the arrow keys or the mouse, open doors
  with Space. The camera motion mirrors the step-and-turn feel of the
  old Realms of Arkania dungeons while keeping smooth free movement. }

{$mode objfpc}{$H+}

uses
  math, sdl2min, gfx, textures, world, raycast, hud;

const
  SCALE   = 4;
  WINW    = FBW * SCALE;
  WINH    = FBH * SCALE;
  TITLE   = 'Crawler - Shadows of the Deep';

  MOVE_SPEED   = 3.2;     { tiles per second }
  TURN_SPEED   = 2.6;     { radians per second }
  MOUSE_YAW    = 0.0022;  { radians per mouse unit }
  MOUSE_PITCH  = 0.8;     { pixels per mouse unit }

type
  TKeyArray = array[0 .. SDL_NUM_SCANCODES - 1] of UInt8;
  PKeyArray = ^TKeyArray;

var
  win, ren, tex: Pointer;
  keys: PKeyArray;
  ev: TSDL_Event;
  running: boolean;
  showMap: boolean;
  prevTicks, nowTicks, lastFpsTick: UInt32;
  dt: double;
  fps, frameCount: longint;

function KeyDown(scancode: longint): boolean; inline;
begin
  KeyDown := keys^[scancode] <> 0;
end;

procedure HandleEvents;
begin
  while SDL_PollEvent(@ev) <> 0 do begin
    case ev.kind of
      SDL_QUITEV:
        running := false;
      SDL_KEYDOWN:
        case ev.key.keysym.scancode of
          SDL_SCANCODE_ESCAPE: running := false;
          SDL_SCANCODE_SPACE:  ToggleDoorAhead;
          SDL_SCANCODE_M:      showMap := not showMap;
        end;
      SDL_MOUSEMOTION: begin
        RotatePlayer(ev.motion.xrel * MOUSE_YAW);
        AddPitch(-ev.motion.yrel * MOUSE_PITCH);
      end;
    end;
  end;
end;

procedure HandleHeldKeys;
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

procedure Shutdown;
begin
  if tex <> nil then SDL_DestroyTexture(tex);
  if ren <> nil then SDL_DestroyRenderer(ren);
  if win <> nil then SDL_DestroyWindow(win);
  SDL_Quit;
  UnloadSDL2;
end;

begin
  { SDL and the GL/Mesa stack perform operations that raise the x87/SSE
    invalid and divide-by-zero flags. FPC leaves those unmasked, which
    turns them into runtime errors, so mask them before any SDL call. }
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide,
    exOverflow, exUnderflow, exPrecision]);

  if not LoadSDL2 then begin
    writeln(StdErr, 'Could not load the SDL2 shared library (libSDL2-2.0.so.0).');
    writeln(StdErr, 'Install it, for example: sudo apt install libsdl2-2.0-0');
    halt(1);
  end;

  if SDL_Init(SDL_INIT_VIDEO or SDL_INIT_EVENTS) <> 0 then begin
    writeln(StdErr, 'SDL_Init failed: ', SDL_GetError());
    halt(1);
  end;

  SDL_SetHint('SDL_RENDER_SCALE_QUALITY', '0');  { nearest neighbour }

  win := SDL_CreateWindow(TITLE, SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
    WINW, WINH, SDL_WINDOW_SHOWN);
  if win = nil then begin
    writeln(StdErr, 'CreateWindow failed: ', SDL_GetError());
    Shutdown; halt(1);
  end;

  ren := SDL_CreateRenderer(win, -1,
    SDL_RENDERER_ACCELERATED or SDL_RENDERER_PRESENTVSYNC);
  if ren = nil then
    ren := SDL_CreateRenderer(win, -1, 0);  { fall back to software }
  if ren = nil then begin
    writeln(StdErr, 'CreateRenderer failed: ', SDL_GetError());
    Shutdown; halt(1);
  end;

  tex := SDL_CreateTexture(ren, SDL_PIXELFORMAT_ARGB8888,
    SDL_TEXTUREACCESS_STREAMING, FBW, FBH);
  if tex = nil then begin
    writeln(StdErr, 'CreateTexture failed: ', SDL_GetError());
    Shutdown; halt(1);
  end;

  BuildTextures;
  InitWorld;
  SDL_SetRelativeMouseMode(1);
  SDL_ShowCursor(0);

  keys := PKeyArray(SDL_GetKeyboardState(nil));
  running := true;
  showMap := true;
  prevTicks := SDL_GetTicks();
  lastFpsTick := prevTicks;
  fps := 0; frameCount := 0;

  while running do begin
    nowTicks := SDL_GetTicks();
    dt := (nowTicks - prevTicks) / 1000.0;
    prevTicks := nowTicks;
    if dt > 0.05 then dt := 0.05;   { clamp after a stall }

    HandleEvents;
    HandleHeldKeys;

    RenderView;
    DrawHud(showMap, fps);

    SDL_UpdateTexture(tex, nil, @FB[0], FBW * 4);
    SDL_RenderClear(ren);
    SDL_RenderCopy(ren, tex, nil, nil);
    SDL_RenderPresent(ren);

    inc(frameCount);
    if nowTicks - lastFpsTick >= 1000 then begin
      fps := frameCount;
      frameCount := 0;
      lastFpsTick := nowTicks;
    end;
  end;

  Shutdown;
end.
