program crawler;

{** A first person dungeon crawler with a textured polygon renderer.

  Renders at 320x240 into a software framebuffer, then upscales with
  nearest-neighbour filtering to a larger window for the retro look.
  This file is the platform layer: it loads SDL2, opens the window and
  renderer, runs the frame loop and uploads the framebuffer. All game
  logic lives in the game unit's state machine. }

{$mode objfpc}{$H+}

uses
  math, sdl2min, video, gfx, audio, gamestate, game;

const
  SCALE   = 4;
  WINW    = FBW * SCALE;
  WINH    = FBH * SCALE;
  TITLE   = 'Cities of the Sunless Depths';
  {$I version.inc}                      { defines BUILD_VERSION, generated }
  CAPTION = TITLE + '  v' + BUILD_VERSION;

var
  prevTicks, nowTicks, lastFpsTick: UInt32;
  dt: double;
  fps, frameCount: longint;
  argi: longint;

procedure Shutdown;
begin
  AudioShutdown;
  VideoShutdown;
  SDL_Quit;
  UnloadSDL2;
end;

begin
  BuildVersion := BUILD_VERSION;   { let the title screen show the build }

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

  { Open the window and the present backend. Prefers OpenGL ES, falls back to
    SDL's 2D renderer; see the video unit. }
  if not VideoInit(CAPTION, WINW, WINH) then begin
    writeln(StdErr, 'Video init failed: ', SDL_GetError());
    Shutdown; halt(1);
  end;

  SDL_SetRelativeMouseMode(1);
  SDL_ShowCursor(0);

  InitGfx;   { build the palette and the inverse lookup before any drawing }

  if not GameInit then begin
    Shutdown; halt(1);
  end;

  { --combat / --battle: skip the title and open a test encounter }
  for argi := 1 to ParamCount do
    if (ParamStr(argi) = '--combat') or (ParamStr(argi) = '--battle') then begin
      QuickBattle;
      break;
    end;

  prevTicks := SDL_GetTicks();
  lastFpsTick := prevTicks;
  fps := 0; frameCount := 0;

  while not QuitRequested do begin
    nowTicks := SDL_GetTicks();
    dt := (nowTicks - prevTicks) / 1000.0;
    prevTicks := nowTicks;
    if dt > 0.05 then dt := 0.05;   { clamp after a stall }

    GameHandleEvents;
    GameUpdate(dt);
    GameRender(fps);

    VideoPresent;

    inc(frameCount);
    if nowTicks - lastFpsTick >= 1000 then begin
      fps := frameCount;
      frameCount := 0;
      lastFpsTick := nowTicks;
    end;
  end;

  Shutdown;
end.
