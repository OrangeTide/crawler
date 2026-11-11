unit sdl2min;

{** Minimal runtime binding to the system SDL2 shared library.

  This unit avoids any dependency on the fpc-sdl2 packages or a
  libSDL2.so development symlink. It loads libSDL2-2.0.so.0 with
  dlopen at startup and binds only the handful of entry points the
  crawler needs: video, a streaming texture, event polling, the
  keyboard state array, relative mouse mode and timing. }

{$mode objfpc}{$H+}

interface

const
  { ---- Init flags ---- }
  SDL_INIT_VIDEO  = $00000020;
  SDL_INIT_AUDIO  = $00000010;
  SDL_INIT_EVENTS = $00004000;

  { ---- Audio ---- }
  AUDIO_S16LSB = $8010;

  { ---- Window ---- }
  SDL_WINDOWPOS_CENTERED = $2FFF0000;
  SDL_WINDOW_SHOWN       = $00000004;

  { ---- Renderer ---- }
  SDL_RENDERER_ACCELERATED = $00000002;
  SDL_RENDERER_PRESENTVSYNC = $00000004;

  { ---- Texture ---- }
  SDL_PIXELFORMAT_ARGB8888 = $16362004;
  SDL_TEXTUREACCESS_STREAMING = 1;

  { ---- OpenGL ---- }
  SDL_WINDOW_OPENGL = $00000002;
  { SDL_GLattr selectors for SDL_GL_SetAttribute (enum order from SDL_video.h) }
  SDL_GL_RED_SIZE              = 0;
  SDL_GL_GREEN_SIZE            = 1;
  SDL_GL_BLUE_SIZE            = 2;
  SDL_GL_ALPHA_SIZE           = 3;
  SDL_GL_DOUBLEBUFFER         = 5;
  SDL_GL_DEPTH_SIZE           = 6;
  SDL_GL_CONTEXT_MAJOR_VERSION = 17;
  SDL_GL_CONTEXT_MINOR_VERSION = 18;
  SDL_GL_CONTEXT_PROFILE_MASK  = 21;
  { profile mask values }
  SDL_GL_CONTEXT_PROFILE_CORE          = $0001;
  SDL_GL_CONTEXT_PROFILE_COMPATIBILITY = $0002;
  SDL_GL_CONTEXT_PROFILE_ES            = $0004;

  { ---- Event types ---- }
  SDL_QUITEV          = $100;
  SDL_KEYDOWN         = $300;
  SDL_KEYUP           = $301;
  SDL_MOUSEMOTION     = $400;
  SDL_MOUSEBUTTONDOWN = $401;
  SDL_MOUSEBUTTONUP   = $402;

  { ---- Mouse buttons ---- }
  SDL_BUTTON_LEFT  = 1;
  SDL_BUTTON_RIGHT = 3;

  { ---- Scancodes (USB HID usage ids, as SDL uses them) ---- }
  SDL_SCANCODE_A = 4;      SDL_SCANCODE_D = 7;
  SDL_SCANCODE_E = 8;      SDL_SCANCODE_Q = 20;
  SDL_SCANCODE_S = 22;     SDL_SCANCODE_W = 26;
  SDL_SCANCODE_T = 23;
  SDL_SCANCODE_M = 16;     SDL_SCANCODE_N = 17;
  SDL_SCANCODE_O = 18;
  SDL_SCANCODE_K = 14;     SDL_SCANCODE_R = 21;
  SDL_SCANCODE_G = 10;     SDL_SCANCODE_I = 12;
  SDL_SCANCODE_J = 13;
  SDL_SCANCODE_B = 5;      SDL_SCANCODE_C = 6;
  SDL_SCANCODE_F = 9;      SDL_SCANCODE_P = 19;
  SDL_SCANCODE_V = 25;
  SDL_SCANCODE_1 = 30;     SDL_SCANCODE_2 = 31;
  SDL_SCANCODE_3 = 32;     SDL_SCANCODE_4 = 33;
  SDL_SCANCODE_5 = 34;     SDL_SCANCODE_6 = 35;
  SDL_SCANCODE_F5 = 62;    SDL_SCANCODE_F9 = 66;
  SDL_SCANCODE_LEFTBRACKET  = 47;
  SDL_SCANCODE_RIGHTBRACKET = 48;
  SDL_SCANCODE_RETURN = 40;
  SDL_SCANCODE_TAB    = 43;
  SDL_SCANCODE_SPACE  = 44;
  SDL_SCANCODE_ESCAPE = 41;
  SDL_SCANCODE_RIGHT  = 79;
  SDL_SCANCODE_LEFT   = 80;
  SDL_SCANCODE_DOWN   = 81;
  SDL_SCANCODE_UP     = 82;
  SDL_SCANCODE_LSHIFT = 225;
  SDL_NUM_SCANCODES   = 512;

type
  { ---- Event records (field layout matches SDL 2 ABI) ---- }
  TSDL_Keysym = record
    scancode: Int32;
    sym: Int32;
    modi: UInt16;
    unused: UInt32;
  end;

  TSDL_KeyboardEvent = record
    kind: UInt32;
    timestamp: UInt32;
    windowID: UInt32;
    state: UInt8;
    rep: UInt8;
    padding2: UInt8;
    padding3: UInt8;
    keysym: TSDL_Keysym;
  end;

  TSDL_MouseMotionEvent = record
    kind: UInt32;
    timestamp: UInt32;
    windowID: UInt32;
    which: UInt32;
    state: UInt32;
    x: Int32;
    y: Int32;
    xrel: Int32;
    yrel: Int32;
  end;

  TSDL_MouseButtonEvent = record
    kind: UInt32;
    timestamp: UInt32;
    windowID: UInt32;
    which: UInt32;
    button: UInt8;
    state: UInt8;
    clicks: UInt8;
    padding1: UInt8;
    x: Int32;
    y: Int32;
  end;

  TSDL_Event = record
    case longint of
      0: (kind: UInt32; raw: array[0..59] of byte);
      1: (key: TSDL_KeyboardEvent);
      2: (motion: TSDL_MouseMotionEvent);
      3: (button: TSDL_MouseButtonEvent);
  end;

  PUInt8 = ^UInt8;

  TSDL_AudioSpec = record
    freq: Int32;
    format: UInt16;
    channels: UInt8;
    silence: UInt8;
    samples: UInt16;
    padding: UInt16;
    size: UInt32;
    callback: Pointer;
    userdata: Pointer;
  end;
  PSDL_AudioSpec = ^TSDL_AudioSpec;

  TSDL_AudioCallback = procedure(userdata: Pointer; stream: PUInt8; len: Int32); cdecl;

  { ---- Entry point signatures ---- }
  TSDL_InitFn        = function(flags: UInt32): Int32; cdecl;
  TSDL_InitSubSystemFn = function(flags: UInt32): Int32; cdecl;
  TSDL_QuitFn        = procedure; cdecl;
  TSDL_GetErrorFn    = function: PChar; cdecl;
  TSDL_SetHintFn     = function(name, value: PChar): Int32; cdecl;
  TSDL_CreateWindowFn = function(title: PChar; x, y, w, h: Int32; flags: UInt32): Pointer; cdecl;
  TSDL_CreateRendererFn = function(win: Pointer; index: Int32; flags: UInt32): Pointer; cdecl;
  TSDL_CreateTextureFn = function(ren: Pointer; format: UInt32; access, w, h: Int32): Pointer; cdecl;
  TSDL_UpdateTextureFn = function(tex, rect, pixels: Pointer; pitch: Int32): Int32; cdecl;
  TSDL_RenderClearFn = function(ren: Pointer): Int32; cdecl;
  TSDL_RenderCopyFn  = function(ren, tex, src, dst: Pointer): Int32; cdecl;
  TSDL_RenderPresentFn = procedure(ren: Pointer); cdecl;
  TSDL_DestroyTextureFn = procedure(tex: Pointer); cdecl;
  TSDL_DestroyRendererFn = procedure(ren: Pointer); cdecl;
  TSDL_DestroyWindowFn = procedure(win: Pointer); cdecl;
  TSDL_GL_SetAttributeFn = function(attr, value: Int32): Int32; cdecl;
  TSDL_GL_CreateContextFn = function(win: Pointer): Pointer; cdecl;
  TSDL_GL_DeleteContextFn = procedure(ctx: Pointer); cdecl;
  TSDL_GL_MakeCurrentFn = function(win, ctx: Pointer): Int32; cdecl;
  TSDL_GL_GetProcAddressFn = function(proc: PChar): Pointer; cdecl;
  TSDL_GL_SwapWindowFn = procedure(win: Pointer); cdecl;
  TSDL_GL_SetSwapIntervalFn = function(interval: Int32): Int32; cdecl;
  TSDL_PollEventFn   = function(ev: Pointer): Int32; cdecl;
  TSDL_GetTicksFn    = function: UInt32; cdecl;
  TSDL_DelayFn       = procedure(ms: UInt32); cdecl;
  TSDL_GetKeyboardStateFn = function(numkeys: Pointer): PUInt8; cdecl;
  TSDL_SetRelativeMouseModeFn = function(enabled: Int32): Int32; cdecl;
  TSDL_ShowCursorFn  = function(toggle: Int32): Int32; cdecl;
  TSDL_OpenAudioDeviceFn = function(device: PChar; iscapture: Int32;
    desired, obtained: PSDL_AudioSpec; allowed: Int32): UInt32; cdecl;
  TSDL_PauseAudioDeviceFn = procedure(dev: UInt32; pause_on: Int32); cdecl;
  TSDL_CloseAudioDeviceFn = procedure(dev: UInt32); cdecl;
  TSDL_LockAudioDeviceFn = procedure(dev: UInt32); cdecl;
  TSDL_UnlockAudioDeviceFn = procedure(dev: UInt32); cdecl;

var
  SDL_Init: TSDL_InitFn;
  SDL_InitSubSystem: TSDL_InitSubSystemFn;
  SDL_Quit: TSDL_QuitFn;
  SDL_GetError: TSDL_GetErrorFn;
  SDL_SetHint: TSDL_SetHintFn;
  SDL_CreateWindow: TSDL_CreateWindowFn;
  SDL_CreateRenderer: TSDL_CreateRendererFn;
  SDL_CreateTexture: TSDL_CreateTextureFn;
  SDL_UpdateTexture: TSDL_UpdateTextureFn;
  SDL_RenderClear: TSDL_RenderClearFn;
  SDL_RenderCopy: TSDL_RenderCopyFn;
  SDL_RenderPresent: TSDL_RenderPresentFn;
  SDL_DestroyTexture: TSDL_DestroyTextureFn;
  SDL_DestroyRenderer: TSDL_DestroyRendererFn;
  SDL_DestroyWindow: TSDL_DestroyWindowFn;
  SDL_GL_SetAttribute: TSDL_GL_SetAttributeFn;
  SDL_GL_CreateContext: TSDL_GL_CreateContextFn;
  SDL_GL_DeleteContext: TSDL_GL_DeleteContextFn;
  SDL_GL_MakeCurrent: TSDL_GL_MakeCurrentFn;
  SDL_GL_GetProcAddress: TSDL_GL_GetProcAddressFn;
  SDL_GL_SwapWindow: TSDL_GL_SwapWindowFn;
  SDL_GL_SetSwapInterval: TSDL_GL_SetSwapIntervalFn;
  SDL_PollEvent: TSDL_PollEventFn;
  SDL_GetTicks: TSDL_GetTicksFn;
  SDL_Delay: TSDL_DelayFn;
  SDL_GetKeyboardState: TSDL_GetKeyboardStateFn;
  SDL_SetRelativeMouseMode: TSDL_SetRelativeMouseModeFn;
  SDL_ShowCursor: TSDL_ShowCursorFn;
  SDL_OpenAudioDevice: TSDL_OpenAudioDeviceFn;
  SDL_PauseAudioDevice: TSDL_PauseAudioDeviceFn;
  SDL_CloseAudioDevice: TSDL_CloseAudioDeviceFn;
  SDL_LockAudioDevice: TSDL_LockAudioDeviceFn;
  SDL_UnlockAudioDevice: TSDL_UnlockAudioDeviceFn;

function LoadSDL2: boolean;
procedure UnloadSDL2;

implementation

uses
  dynlibs, sysutils, apppaths;

const
{$IFDEF WINDOWS}
  SDL_SONAMES: array[0..0] of string = ('SDL2.dll');
{$ELSE}
{$IFDEF DARWIN}
  SDL_SONAMES: array[0..2] of string = (
    'libSDL2-2.0.0.dylib', 'libSDL2.dylib', 'SDL2');
{$ELSE}
  SDL_SONAMES: array[0..2] of string = (
    'libSDL2-2.0.so.0', 'libSDL2.so', 'libSDL2-2.0.so');
{$ENDIF}
{$ENDIF}

var
  libHandle: TLibHandle = NilHandle;

function Bind(const name: string): Pointer;
{** Resolve one entry point, halting with a clear message if absent. }
begin
  Bind := GetProcedureAddress(libHandle, name);
  if Bind = nil then begin
    writeln(StdErr, 'sdl2min: missing symbol ', name);
    halt(2);
  end;
end;

function LoadSDL2: boolean;
var
  i: longint;
begin
  libHandle := NilHandle;
{$IFDEF DARWIN}
  { A shipped .app carries its own SDL2 under Contents/Frameworks, because
    macOS has no system-wide SDL2 to find by name. Load that copy first, by
    absolute path; fall back to the search names for a development build. }
  libHandle := LoadLibrary(ExpandFileName(ExeDir + '..' + PathDelim +
    'Frameworks' + PathDelim + 'libSDL2.dylib'));
{$ENDIF}
  if libHandle = NilHandle then
    for i := 0 to High(SDL_SONAMES) do begin
      libHandle := LoadLibrary(SDL_SONAMES[i]);
      if libHandle <> NilHandle then
        break;
    end;
  if libHandle = NilHandle then begin
    LoadSDL2 := false;
    exit;
  end;

  SDL_Init := TSDL_InitFn(Bind('SDL_Init'));
  SDL_InitSubSystem := TSDL_InitSubSystemFn(Bind('SDL_InitSubSystem'));
  SDL_Quit := TSDL_QuitFn(Bind('SDL_Quit'));
  SDL_GetError := TSDL_GetErrorFn(Bind('SDL_GetError'));
  SDL_SetHint := TSDL_SetHintFn(Bind('SDL_SetHint'));
  SDL_CreateWindow := TSDL_CreateWindowFn(Bind('SDL_CreateWindow'));
  SDL_CreateRenderer := TSDL_CreateRendererFn(Bind('SDL_CreateRenderer'));
  SDL_CreateTexture := TSDL_CreateTextureFn(Bind('SDL_CreateTexture'));
  SDL_UpdateTexture := TSDL_UpdateTextureFn(Bind('SDL_UpdateTexture'));
  SDL_RenderClear := TSDL_RenderClearFn(Bind('SDL_RenderClear'));
  SDL_RenderCopy := TSDL_RenderCopyFn(Bind('SDL_RenderCopy'));
  SDL_RenderPresent := TSDL_RenderPresentFn(Bind('SDL_RenderPresent'));
  SDL_DestroyTexture := TSDL_DestroyTextureFn(Bind('SDL_DestroyTexture'));
  SDL_DestroyRenderer := TSDL_DestroyRendererFn(Bind('SDL_DestroyRenderer'));
  SDL_DestroyWindow := TSDL_DestroyWindowFn(Bind('SDL_DestroyWindow'));
  SDL_GL_SetAttribute := TSDL_GL_SetAttributeFn(Bind('SDL_GL_SetAttribute'));
  SDL_GL_CreateContext := TSDL_GL_CreateContextFn(Bind('SDL_GL_CreateContext'));
  SDL_GL_DeleteContext := TSDL_GL_DeleteContextFn(Bind('SDL_GL_DeleteContext'));
  SDL_GL_MakeCurrent := TSDL_GL_MakeCurrentFn(Bind('SDL_GL_MakeCurrent'));
  SDL_GL_GetProcAddress := TSDL_GL_GetProcAddressFn(Bind('SDL_GL_GetProcAddress'));
  SDL_GL_SwapWindow := TSDL_GL_SwapWindowFn(Bind('SDL_GL_SwapWindow'));
  SDL_GL_SetSwapInterval := TSDL_GL_SetSwapIntervalFn(Bind('SDL_GL_SetSwapInterval'));
  SDL_PollEvent := TSDL_PollEventFn(Bind('SDL_PollEvent'));
  SDL_GetTicks := TSDL_GetTicksFn(Bind('SDL_GetTicks'));
  SDL_Delay := TSDL_DelayFn(Bind('SDL_Delay'));
  SDL_GetKeyboardState := TSDL_GetKeyboardStateFn(Bind('SDL_GetKeyboardState'));
  SDL_SetRelativeMouseMode := TSDL_SetRelativeMouseModeFn(Bind('SDL_SetRelativeMouseMode'));
  SDL_ShowCursor := TSDL_ShowCursorFn(Bind('SDL_ShowCursor'));
  SDL_OpenAudioDevice := TSDL_OpenAudioDeviceFn(Bind('SDL_OpenAudioDevice'));
  SDL_PauseAudioDevice := TSDL_PauseAudioDeviceFn(Bind('SDL_PauseAudioDevice'));
  SDL_CloseAudioDevice := TSDL_CloseAudioDeviceFn(Bind('SDL_CloseAudioDevice'));
  SDL_LockAudioDevice := TSDL_LockAudioDeviceFn(Bind('SDL_LockAudioDevice'));
  SDL_UnlockAudioDevice := TSDL_UnlockAudioDeviceFn(Bind('SDL_UnlockAudioDevice'));

  LoadSDL2 := true;
end;

procedure UnloadSDL2;
begin
  if libHandle <> NilHandle then begin
    UnloadLibrary(libHandle);
    libHandle := NilHandle;
  end;
end;

end.
