program crawler;

{** A first person dungeon crawler with a textured raycasting engine.

  Renders at 320x240 into a software framebuffer, then upscales with
  nearest-neighbour filtering to a larger window for the retro look.
  This file is the platform layer: it loads SDL2, opens the window and
  renderer, runs the frame loop and uploads the framebuffer. All game
  logic lives in the game unit's state machine. }

{$mode objfpc}{$H+}

uses
  math, sdl2min, gfx, audio, gamestate, game;

const
  SCALE   = 4;
  WINW    = FBW * SCALE;
  WINH    = FBH * SCALE;
  TITLE   = 'Cities of the Sunless Depths';
  {$I version.inc}                      { defines BUILD_VERSION, generated }
  CAPTION = TITLE + '  v' + BUILD_VERSION;

var
  win, ren, tex: Pointer;
  prevTicks, nowTicks, lastFpsTick: UInt32;
  dt: double;
  fps, frameCount: longint;
  argi: longint;
  argb: array[0 .. FBW * FBH - 1] of TColor;   { index->ARGB scratch for SDL }

procedure Shutdown;
begin
  AudioShutdown;
  if tex <> nil then SDL_DestroyTexture(tex);
  if ren <> nil then SDL_DestroyRenderer(ren);
  if win <> nil then SDL_DestroyWindow(win);
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

  SDL_SetHint('SDL_RENDER_SCALE_QUALITY', '0');  { nearest neighbour }

  win := SDL_CreateWindow(CAPTION, SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
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

    PalExpand(@argb[0]);
    SDL_UpdateTexture(tex, nil, @argb[0], FBW * 4);
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
