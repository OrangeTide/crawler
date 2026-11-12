unit glrender;

{** GPU 3D rendering, stage 2 of the renderer backend seam.

  This is the start of moving the mesh-clad 3D scene off the software
  rasterizer onto OpenGL ES. Increment 1 is a self-contained proof of the
  pipeline: a textured, depth-tested cube drawn with the same projection the
  software renderer uses (FOCAL from a 0.66 horizontal half-angle tangent, Z-up
  world, yaw 0 along +X). It validates the shader, vertex buffer, texture,
  camera and depth path on the real GPU before the engine's geometry is fed in.

  Later increments drive this from the explore camera and the cladding scene,
  composite the software 2D HUD on top, and add the 320x240 retro downscale.
  The GL backend must be active (video.VideoIsGL); nothing here touches the
  software framebuffer. }

{$mode objfpc}{$H+}

interface

{ Render one frame of the pipeline-proof scene and swap. A no-op when the GL
  backend is not active. }
procedure GLRenderTestFrame;

implementation

uses
  math, gles2, video;

type
  TMat4 = array[0 .. 15] of GLfloat;   { column-major, as GL expects }

const
  { Horizontal half-angle tangent the software renderer projects with
    (raster.FOCAL = (FBW/2) / 0.66). The vertical tangent follows from the
    4:3 aspect, so the GPU view matches the software view. }
  TAN_HX = 0.66;
  NEARP  = 0.05;
  FARP   = 100.0;

  VERT_SRC =
    'uniform mat4 uMVP;'#10 +
    'attribute vec3 aPos;'#10 +
    'attribute vec2 aUV;'#10 +
    'varying vec2 vUV;'#10 +
    'void main() { vUV = aUV; gl_Position = uMVP * vec4(aPos, 1.0); }'#10;

  FRAG_SRC =
    'precision mediump float;'#10 +
    'varying vec2 vUV;'#10 +
    'uniform sampler2D uTex;'#10 +
    'uniform float uLight;'#10 +
    'void main() { gl_FragColor = vec4(texture2D(uTex, vUV).rgb * uLight, 1.0); }'#10;

  { Six cube faces, four corners each (x, y, z, u, v), wound CCW from outside. }
  FACES: array[0 .. 119] of GLfloat = (
    { +X } 0.5,-0.5,-0.5, 0,0,  0.5, 0.5,-0.5, 1,0,  0.5, 0.5, 0.5, 1,1,  0.5,-0.5, 0.5, 0,1,
    { -X }-0.5, 0.5,-0.5, 0,0, -0.5,-0.5,-0.5, 1,0, -0.5,-0.5, 0.5, 1,1, -0.5, 0.5, 0.5, 0,1,
    { +Y } 0.5, 0.5,-0.5, 0,0, -0.5, 0.5,-0.5, 1,0, -0.5, 0.5, 0.5, 1,1,  0.5, 0.5, 0.5, 0,1,
    { -Y }-0.5,-0.5,-0.5, 0,0,  0.5,-0.5,-0.5, 1,0,  0.5,-0.5, 0.5, 1,1, -0.5,-0.5, 0.5, 0,1,
    { +Z }-0.5,-0.5, 0.5, 0,0,  0.5,-0.5, 0.5, 1,0,  0.5, 0.5, 0.5, 1,1, -0.5, 0.5, 0.5, 0,1,
    { -Z }-0.5, 0.5,-0.5, 0,0,  0.5, 0.5,-0.5, 1,0,  0.5,-0.5,-0.5, 1,1, -0.5,-0.5,-0.5, 0,1);

var
  ready: boolean = false;
  prog: GLuint = 0;
  vbo: GLuint = 0;
  tex: GLuint = 0;
  uMVPLoc, uLightLoc, uTexLoc: GLint;
  posLoc, uvLoc: GLint;
  angle: GLfloat = 0;

function MakeShader(kind: GLenum; const src: string): GLuint;
var sh: GLuint; s: PGLchar; status, ln: GLint; log: array[0 .. 511] of char;
begin
  MakeShader := 0;
  sh := glCreateShader(kind);
  if sh = 0 then exit;
  s := PGLchar(src);
  glShaderSource(sh, 1, @s, nil);
  glCompileShader(sh);
  status := 0; glGetShaderiv(sh, GL_COMPILE_STATUS, @status);
  if status = 0 then begin
    ln := 0; glGetShaderInfoLog(sh, SizeOf(log), @ln, @log[0]);
    writeln(StdErr, 'glrender: shader compile failed: ', PChar(@log[0]));
    exit;
  end;
  MakeShader := sh;
end;

function MakeProgram: GLuint;
var vs, fs, pr: GLuint; status, ln: GLint; log: array[0 .. 511] of char;
begin
  MakeProgram := 0;
  vs := MakeShader(GL_VERTEX_SHADER, VERT_SRC);
  fs := MakeShader(GL_FRAGMENT_SHADER, FRAG_SRC);
  if (vs = 0) or (fs = 0) then exit;
  pr := glCreateProgram();
  if pr = 0 then exit;
  glAttachShader(pr, vs); glAttachShader(pr, fs);
  glLinkProgram(pr);
  status := 0; glGetProgramiv(pr, GL_LINK_STATUS, @status);
  if status = 0 then begin
    ln := 0; glGetProgramInfoLog(pr, SizeOf(log), @ln, @log[0]);
    writeln(StdErr, 'glrender: program link failed: ', PChar(@log[0]));
    exit;
  end;
  MakeProgram := pr;
end;

{ C = A * B, both column-major. }
function MatMul(const a, b: TMat4): TMat4;
var c, r, k: longint; s: GLfloat;
begin
  for c := 0 to 3 do
    for r := 0 to 3 do begin
      s := 0;
      for k := 0 to 3 do s := s + a[k * 4 + r] * b[c * 4 + k];
      MatMul[c * 4 + r] := s;
    end;
end;

{ A perspective projection matching the software FOCAL and the 4:3 aspect. }
function MatProj: TMat4;
var m: TMat4; i: longint; tanHy, a, bb: GLfloat;
begin
  for i := 0 to 15 do m[i] := 0;
  tanHy := TAN_HX * (VideoHeight / VideoWidth);
  m[0] := 1.0 / TAN_HX;
  m[5] := 1.0 / tanHy;
  a := -(FARP + NEARP) / (FARP - NEARP);
  bb := -(2.0 * FARP * NEARP) / (FARP - NEARP);
  m[10] := a; m[11] := -1.0; m[14] := bb;
  MatProj := m;
end;

{ A view matrix for a Z-up camera: eye position, yaw (0 looks +X), pitch (up
  positive). View space is +X right, +Y up, -Z forward, matching the software
  renderer's world-to-view transform. }
function MatView(ex, ey, ez, yaw, pitch: GLfloat): TMat4;
var
  m: TMat4;
  cy, sy, cp, sp: GLfloat;
  r0x, r0y, r0z, r1x, r1y, r1z, r2x, r2y, r2z: GLfloat;
begin
  cy := cos(yaw); sy := sin(yaw); cp := cos(pitch); sp := sin(pitch);
  r0x := -sy;      r0y := cy;       r0z := 0;
  r1x := -sp * cy; r1y := -sp * sy; r1z := cp;
  r2x := -cp * cy; r2y := -cp * sy; r2z := -sp;
  m[0] := r0x; m[1] := r1x; m[2] := r2x; m[3] := 0;
  m[4] := r0y; m[5] := r1y; m[6] := r2y; m[7] := 0;
  m[8] := r0z; m[9] := r1z; m[10] := r2z; m[11] := 0;
  m[12] := -(r0x * ex + r0y * ey + r0z * ez);
  m[13] := -(r1x * ex + r1y * ey + r1z * ez);
  m[14] := -(r2x * ex + r2y * ey + r2z * ez);
  m[15] := 1;
  MatView := m;
end;

{ Rotation about the world Z axis (the mesh/world up). }
function MatRotZ(a: GLfloat): TMat4;
var m: TMat4; i: longint; c, s: GLfloat;
begin
  for i := 0 to 15 do m[i] := 0;
  c := cos(a); s := sin(a);
  m[0] := c; m[1] := s; m[4] := -s; m[5] := c; m[10] := 1; m[15] := 1;
  MatRotZ := m;
end;

{ Build the 36-vertex cube buffer and a procedural checker texture. }
procedure InitResources;
var
  verts: array[0 .. 36 * 5 - 1] of GLfloat;
  f, corner, n, src: longint;
  tri: array[0 .. 5] of longint = (0, 1, 2, 0, 2, 3);
  checker: array[0 .. 63, 0 .. 63, 0 .. 3] of byte;
  xx, yy: longint; on: boolean;
begin
  { expand each face's four corners into two triangles }
  n := 0;
  for f := 0 to 5 do
    for corner := 0 to 5 do begin
      src := (f * 4 + tri[corner]) * 5;
      verts[n + 0] := FACES[src + 0];
      verts[n + 1] := FACES[src + 1];
      verts[n + 2] := FACES[src + 2];
      verts[n + 3] := FACES[src + 3];
      verts[n + 4] := FACES[src + 4];
      n := n + 5;
    end;

  glGenBuffers(1, @vbo);
  glBindBuffer(GL_ARRAY_BUFFER, vbo);
  glBufferData(GL_ARRAY_BUFFER, SizeOf(verts), @verts[0], GL_STATIC_DRAW);

  for yy := 0 to 63 do
    for xx := 0 to 63 do begin
      on := ((xx shr 3) + (yy shr 3)) and 1 = 0;
      if on then begin
        checker[yy, xx, 0] := 210; checker[yy, xx, 1] := 180; checker[yy, xx, 2] := 70;
      end else begin
        checker[yy, xx, 0] := 40; checker[yy, xx, 1] := 50; checker[yy, xx, 2] := 70;
      end;
      checker[yy, xx, 3] := 255;
    end;
  glGenTextures(1, @tex);
  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, tex);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 64, 64, 0,
    GL_RGBA, GL_UNSIGNED_BYTE, @checker[0, 0, 0]);
end;

function InitGL: boolean;
begin
  InitGL := false;
  prog := MakeProgram;
  if prog = 0 then exit;
  glUseProgram(prog);
  uMVPLoc := glGetUniformLocation(prog, 'uMVP');
  uLightLoc := glGetUniformLocation(prog, 'uLight');
  uTexLoc := glGetUniformLocation(prog, 'uTex');
  posLoc := glGetAttribLocation(prog, 'aPos');
  uvLoc := glGetAttribLocation(prog, 'aUV');
  InitResources;
  glUniform1i(uTexLoc, 0);
  InitGL := true;
end;

procedure GLRenderTestFrame;
var mvp, proj, view, model: TMat4;
begin
  if not VideoIsGL then exit;
  if not ready then begin
    if not InitGL then exit;
    ready := true;
  end;

  glViewport(0, 0, VideoWidth, VideoHeight);
  glEnable(GL_DEPTH_TEST);
  glDepthFunc(GL_LEQUAL);
  glClearColor(0.07, 0.07, 0.10, 1.0);
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT);

  proj := MatProj;
  { camera three units back on -X, slightly up, looking at the origin cube }
  view := MatView(-3.0, 0.0, 0.6, 0.0, -0.15);
  model := MatRotZ(angle);
  mvp := MatMul(proj, MatMul(view, model));
  angle := angle + 0.01;

  glUseProgram(prog);
  glUniformMatrix4fv(uMVPLoc, 1, GL_FALSE, @mvp[0]);
  glUniform1f(uLightLoc, 1.0);
  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, tex);

  glBindBuffer(GL_ARRAY_BUFFER, vbo);
  glEnableVertexAttribArray(GLuint(posLoc));
  glVertexAttribPointer(GLuint(posLoc), 3, GL_FLOAT, GL_FALSE,
    5 * SizeOf(GLfloat), Pointer(0));
  glEnableVertexAttribArray(GLuint(uvLoc));
  glVertexAttribPointer(GLuint(uvLoc), 2, GL_FLOAT, GL_FALSE,
    5 * SizeOf(GLfloat), Pointer(3 * SizeOf(GLfloat)));

  glDrawArrays(GL_TRIANGLES, 0, 36);
  VideoSwap;
end;

end.
