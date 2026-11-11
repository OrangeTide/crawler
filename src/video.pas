unit video;

{** The platform video backend: owns the window and the present path.

  It prefers an OpenGL ES 2.0 context, the portable GPU seam that ports to
  desktop GL 3.x or ANGLE and begins the staged move of rendering onto the
  GPU. If a GL context or its shaders are unavailable it falls back to SDL's
  2D renderer, so the game still runs. Either backend presents the 320x240
  software framebuffer (gfx.FB) upscaled to the window.

  This is stage 1 of the backend seam: the software rasterizer still produces
  the frame, and the GL path only blits it. Later stages render the 3D scene
  natively per backend, which need not look identical across PS1 and desktop.
  Set CRAWLER_GL=0 in the environment to force the SDL fallback. }

{$mode objfpc}{$H+}

interface

function VideoInit(const caption: string; winW, winH: longint): boolean;
procedure VideoPresent;
procedure VideoShutdown;
function VideoIsGL: boolean;      { true when the GLES backend is active }

implementation

uses
  sysutils, sdl2min, gles2, gfx;

var
  win: Pointer = nil;
  gCaption: string = '';
  gW: longint = 0;
  gH: longint = 0;
  usingGL: boolean = false;
  argb: array[0 .. FBW * FBH - 1] of TColor;   { index -> ARGB scratch }

  { GL backend state }
  glCtx: Pointer = nil;
  prog: GLuint = 0;
  vbo: GLuint = 0;
  fbTex: GLuint = 0;

  { SDL 2D fallback state }
  ren: Pointer = nil;
  tex: Pointer = nil;

const
  VERT_SRC =
    'attribute vec2 aPos;'#10 +
    'attribute vec2 aUV;'#10 +
    'varying vec2 vUV;'#10 +
    'void main() { vUV = aUV; gl_Position = vec4(aPos, 0.0, 1.0); }'#10;

  { gfx stores 0xAARRGGBB, which on a little-endian host is the bytes B,G,R,A.
    Uploaded as GL_RGBA those land in the texel as (B,G,R,A), so swizzle .bgra
    to put the colour back to (R,G,B,A) for the screen. }
  FRAG_SRC =
    'precision mediump float;'#10 +
    'varying vec2 vUV;'#10 +
    'uniform sampler2D uTex;'#10 +
    'void main() { gl_FragColor = texture2D(uTex, vUV).bgra; }'#10;

  { A fullscreen quad as a triangle strip: x, y, u, v per vertex. The V runs
    top-to-bottom so the framebuffer's first row maps to the top of the
    window. }
  QUAD: array[0 .. 15] of GLfloat = (
    -1.0, -1.0,  0.0, 1.0,
     1.0, -1.0,  1.0, 1.0,
    -1.0,  1.0,  0.0, 0.0,
     1.0,  1.0,  1.0, 0.0);

function WantGL: boolean;
begin
  WantGL := GetEnvironmentVariable('CRAWLER_GL') <> '0';
end;

function MakeShader(shaderType: GLenum; const src: string): GLuint;
var
  sh: GLuint;
  s: PGLchar;
  status, ln: GLint;
  log: array[0 .. 511] of char;
begin
  MakeShader := 0;
  sh := glCreateShader(shaderType);
  if sh = 0 then exit;
  s := PGLchar(src);
  glShaderSource(sh, 1, @s, nil);
  glCompileShader(sh);
  status := 0;
  glGetShaderiv(sh, GL_COMPILE_STATUS, @status);
  if status = 0 then begin
    ln := 0;
    glGetShaderInfoLog(sh, SizeOf(log), @ln, @log[0]);
    writeln(StdErr, 'video: shader compile failed: ', PChar(@log[0]));
    exit;
  end;
  MakeShader := sh;
end;

{ Compile and link the present program, returning 0 on failure. }
function MakeProgram: GLuint;
var
  vs, fs, pr: GLuint;
  status, ln: GLint;
  log: array[0 .. 511] of char;
begin
  MakeProgram := 0;
  vs := MakeShader(GL_VERTEX_SHADER, VERT_SRC);
  fs := MakeShader(GL_FRAGMENT_SHADER, FRAG_SRC);
  if (vs = 0) or (fs = 0) then exit;
  pr := glCreateProgram();
  if pr = 0 then exit;
  glAttachShader(pr, vs);
  glAttachShader(pr, fs);
  glLinkProgram(pr);
  status := 0;
  glGetProgramiv(pr, GL_LINK_STATUS, @status);
  if status = 0 then begin
    ln := 0;
    glGetProgramInfoLog(pr, SizeOf(log), @ln, @log[0]);
    writeln(StdErr, 'video: program link failed: ', PChar(@log[0]));
    exit;
  end;
  MakeProgram := pr;
end;

function InitGL: boolean;
var
  posLoc, uvLoc, texLoc: GLint;
begin
  InitGL := false;
  SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_ES);
  SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 2);
  SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 0);
  SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
  SDL_GL_SetAttribute(SDL_GL_RED_SIZE, 8);
  SDL_GL_SetAttribute(SDL_GL_GREEN_SIZE, 8);
  SDL_GL_SetAttribute(SDL_GL_BLUE_SIZE, 8);

  win := SDL_CreateWindow(PChar(gCaption),
    SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, gW, gH,
    SDL_WINDOW_OPENGL or SDL_WINDOW_SHOWN);
  if win = nil then exit;

  glCtx := SDL_GL_CreateContext(win);
  if glCtx = nil then begin
    SDL_DestroyWindow(win); win := nil; exit;
  end;
  if not LoadGLES2 then begin
    SDL_GL_DeleteContext(glCtx); glCtx := nil;
    SDL_DestroyWindow(win); win := nil; exit;
  end;
  SDL_GL_SetSwapInterval(1);

  prog := MakeProgram;
  if prog = 0 then begin
    SDL_GL_DeleteContext(glCtx); glCtx := nil;
    SDL_DestroyWindow(win); win := nil; exit;
  end;

  glGenBuffers(1, @vbo);
  glBindBuffer(GL_ARRAY_BUFFER, vbo);
  glBufferData(GL_ARRAY_BUFFER, SizeOf(QUAD), @QUAD[0], GL_STATIC_DRAW);

  glGenTextures(1, @fbTex);
  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, fbTex);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, FBW, FBH, 0,
    GL_RGBA, GL_UNSIGNED_BYTE, nil);

  { The vertex attribute and sampler wiring is constant, so set it once. }
  glUseProgram(prog);
  texLoc := glGetUniformLocation(prog, 'uTex');
  glUniform1i(texLoc, 0);
  posLoc := glGetAttribLocation(prog, 'aPos');
  uvLoc := glGetAttribLocation(prog, 'aUV');
  glBindBuffer(GL_ARRAY_BUFFER, vbo);
  glEnableVertexAttribArray(GLuint(posLoc));
  glVertexAttribPointer(GLuint(posLoc), 2, GL_FLOAT, GL_FALSE,
    4 * SizeOf(GLfloat), Pointer(0));
  glEnableVertexAttribArray(GLuint(uvLoc));
  glVertexAttribPointer(GLuint(uvLoc), 2, GL_FLOAT, GL_FALSE,
    4 * SizeOf(GLfloat), Pointer(2 * SizeOf(GLfloat)));

  glViewport(0, 0, gW, gH);
  glClearColor(0, 0, 0, 1);

  usingGL := true;
  InitGL := true;
end;

function InitSDL: boolean;
begin
  InitSDL := false;
  SDL_SetHint('SDL_RENDER_SCALE_QUALITY', '0');   { nearest neighbour }
  win := SDL_CreateWindow(PChar(gCaption),
    SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, gW, gH, SDL_WINDOW_SHOWN);
  if win = nil then exit;
  ren := SDL_CreateRenderer(win, -1,
    SDL_RENDERER_ACCELERATED or SDL_RENDERER_PRESENTVSYNC);
  if ren = nil then
    ren := SDL_CreateRenderer(win, -1, 0);   { software fallback }
  if ren = nil then begin
    SDL_DestroyWindow(win); win := nil; exit;
  end;
  tex := SDL_CreateTexture(ren, SDL_PIXELFORMAT_ARGB8888,
    SDL_TEXTUREACCESS_STREAMING, FBW, FBH);
  if tex = nil then begin
    SDL_DestroyRenderer(ren); ren := nil;
    SDL_DestroyWindow(win); win := nil; exit;
  end;
  usingGL := false;
  InitSDL := true;
end;

function VideoInit(const caption: string; winW, winH: longint): boolean;
begin
  gCaption := caption; gW := winW; gH := winH;
  if WantGL and InitGL then begin
    writeln(StdErr, 'video: OpenGL ES 2.0 backend'); Flush(StdErr);
    VideoInit := true; exit;
  end;
  VideoInit := InitSDL;
  if VideoInit then begin
    writeln(StdErr, 'video: SDL 2D renderer backend'); Flush(StdErr);
  end;
end;

procedure VideoPresent;
begin
  PalExpand(@argb[0]);
  if usingGL then begin
    glBindTexture(GL_TEXTURE_2D, fbTex);
    glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0, FBW, FBH,
      GL_RGBA, GL_UNSIGNED_BYTE, @argb[0]);
    glClear(GL_COLOR_BUFFER_BIT);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    SDL_GL_SwapWindow(win);
  end else begin
    SDL_UpdateTexture(tex, nil, @argb[0], FBW * 4);
    SDL_RenderClear(ren);
    SDL_RenderCopy(ren, tex, nil, nil);
    SDL_RenderPresent(ren);
  end;
end;

procedure VideoShutdown;
begin
  if usingGL then begin
    if fbTex <> 0 then glDeleteTextures(1, @fbTex);
    if glCtx <> nil then SDL_GL_DeleteContext(glCtx);
    glCtx := nil;
  end else begin
    if tex <> nil then SDL_DestroyTexture(tex);
    if ren <> nil then SDL_DestroyRenderer(ren);
    tex := nil; ren := nil;
  end;
  if win <> nil then SDL_DestroyWindow(win);
  win := nil;
end;

function VideoIsGL: boolean;
begin
  VideoIsGL := usingGL;
end;

end.
