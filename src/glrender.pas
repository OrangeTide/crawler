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

uses
  raster, meshfmt;

{ Render one frame of the pipeline-proof scene and swap. A no-op when the GL
  backend is not active. }
procedure GLRenderTestFrame;

{ A GPU scene frame. Begin sets the camera and clears; each kit piece is drawn
  through GLDrawMesh (whose signature matches clad.CladMeshHook); End swaps.
  Call Begin/End around the cladding passes with the hook pointed here. }
procedure GLSceneBegin(const mc: TMeshCam);
procedure GLDrawMesh(const m: TMesh; const mc: TMeshCam;
  mx, my, mz, sx, sy, sz, yaw, light: double; const mats: array of TMeshMat);
{ One world-space textured quad (two triangles), for the procedural grid walls,
  floors and ceilings a non-kit cell draws. Corners and texture coordinates
  match raster.DrawTexQuad; the texture is a tileset's palette-index bitmap,
  expanded to RGBA. The GPU interpolates perspective-correct, so no subdivision
  is needed here (unlike the affine software path). }
procedure GLDrawWorldQuad(
  x0, y0, z0, x1, y1, z1, x2, y2, z2, x3, y3, z3: double;
  u0, v0, u1, v1, u2, v2, u3, v3: double;
  tex: PByte; tw, th: longint; light: double);
procedure GLSceneEnd;

implementation

uses
  math, gfx, gles2, video;

type
  TMat4 = array[0 .. 15] of GLfloat;   { column-major, as GL expects }

const
  { Horizontal half-angle tangent the software renderer projects with
    (raster.FOCAL = (FBW/2) / 0.66). The vertical tangent follows from the
    4:3 aspect, so the GPU view matches the software view. }
  TAN_HX = 0.66;
  NEARP  = 0.05;
  FARP   = 100.0;

  { The scene vertex shader snaps each projected vertex to the 320x240 pixel
    grid (uRes), so vertices wobble the way the PlayStation's integer GTE output
    did. This matches raster.VSNAP = 1 (whole pixels). The snap is in clip space
    before the perspective divide, so shared world corners still snap alike. }
  VERT_SRC =
    'uniform mat4 uMVP;'#10 +
    'uniform vec2 uRes;'#10 +
    'attribute vec3 aPos;'#10 +
    'attribute vec2 aUV;'#10 +
    'varying vec2 vUV;'#10 +
    'void main() {'#10 +
    '  vUV = aUV;'#10 +
    '  vec4 p = uMVP * vec4(aPos, 1.0);'#10 +
    '  vec2 g = uRes * 0.5;'#10 +
    '  p.xy = floor((p.xy / p.w) * g + 0.5) / g * p.w;'#10 +
    '  gl_Position = p;'#10 +
    '}'#10;

  { The scene fragment shader applies a 4x4 ordered (Bayer) dither keyed on the
    pixel, then quantizes each channel to 5 bits, standing in for the PS1's
    15-bit framebuffer. The Bayer thresholds come from a 4x4 texture (uBayer,
    repeat-wrapped), which avoids the dynamic array indexing GLES 2 drivers need
    not support. This is the direct-colour echo of gfx.DitherQuant. }
  FRAG_SRC =
    'precision mediump float;'#10 +
    'varying vec2 vUV;'#10 +
    'uniform sampler2D uTex;'#10 +
    'uniform sampler2D uBayer;'#10 +
    'uniform float uLight;'#10 +
    'void main() {'#10 +
    '  vec3 c = texture2D(uTex, vUV).rgb * uLight;'#10 +
    '  float b = texture2D(uBayer, gl_FragCoord.xy / 4.0).r;'#10 +
    '  c = clamp(c + (b - 0.5) / 31.0, 0.0, 1.0);'#10 +
    '  c = floor(c * 31.0 + 0.5) / 31.0;'#10 +
    '  gl_FragColor = vec4(c, 1.0);'#10 +
    '}'#10;

  { The upscale-blit of the 320x240 scene target to the window. }
  PVERT_SRC =
    'attribute vec2 aPos;'#10 +
    'attribute vec2 aUV;'#10 +
    'varying vec2 vUV;'#10 +
    'void main() { vUV = aUV; gl_Position = vec4(aPos, 0.0, 1.0); }'#10;
  PFRAG_SRC =
    'precision mediump float;'#10 +
    'varying vec2 vUV;'#10 +
    'uniform sampler2D uTex;'#10 +
    'void main() { gl_FragColor = texture2D(uTex, vUV); }'#10;

  { fullscreen quad (x, y, u, v); uv maps straight to clip, no flip, since the
    scene target and the window share GL's bottom-left origin. }
  PQUAD: array[0 .. 15] of GLfloat = (
    -1.0, -1.0, 0.0, 0.0,
     1.0, -1.0, 1.0, 0.0,
    -1.0,  1.0, 0.0, 1.0,
     1.0,  1.0, 1.0, 1.0);

  { Six cube faces, four corners each (x, y, z, u, v), wound CCW from outside. }
  FACES: array[0 .. 119] of GLfloat = (
    { +X } 0.5,-0.5,-0.5, 0,0,  0.5, 0.5,-0.5, 1,0,  0.5, 0.5, 0.5, 1,1,  0.5,-0.5, 0.5, 0,1,
    { -X }-0.5, 0.5,-0.5, 0,0, -0.5,-0.5,-0.5, 1,0, -0.5,-0.5, 0.5, 1,1, -0.5, 0.5, 0.5, 0,1,
    { +Y } 0.5, 0.5,-0.5, 0,0, -0.5, 0.5,-0.5, 1,0, -0.5, 0.5, 0.5, 1,1,  0.5, 0.5, 0.5, 0,1,
    { -Y }-0.5,-0.5,-0.5, 0,0,  0.5,-0.5,-0.5, 1,0,  0.5,-0.5, 0.5, 1,1, -0.5,-0.5, 0.5, 0,1,
    { +Z }-0.5,-0.5, 0.5, 0,0,  0.5,-0.5, 0.5, 1,0,  0.5, 0.5, 0.5, 1,1, -0.5, 0.5, 0.5, 0,1,
    { -Z }-0.5, 0.5,-0.5, 0,0,  0.5, 0.5,-0.5, 1,0,  0.5,-0.5,-0.5, 1,1, -0.5,-0.5,-0.5, 0,1);

var
  progReady: boolean = false;
  cubeReady: boolean = false;
  prog: GLuint = 0;
  vbo: GLuint = 0;
  tex: GLuint = 0;
  uMVPLoc, uLightLoc, uTexLoc: GLint;
  uResLoc, uBayerLoc: GLint;
  bayerTex: GLuint = 0;
  quadVBO: GLuint = 0;        { reused for the per-frame world quads }
  posLoc, uvLoc: GLint;
  angle: GLfloat = 0;

  { the view and projection for the frame in progress, set by GLSceneBegin }
  sceneProj, sceneView: TMat4;

  { the 320x240 scene render target and its upscale-blit program }
  fboReady: boolean = false;
  fbo: GLuint = 0;
  fboTex: GLuint = 0;
  fboDepth: GLuint = 0;
  presentReady: boolean = false;
  presentProg: GLuint = 0;
  presentVBO: GLuint = 0;
  presentPos, presentUV, presentTexLoc: GLint;

  { per-mesh vertex buffers and per-atlas textures, cached by source pointer.
    Meshes are resident for the session (clad's cache), so their keys are
    stable; atlas keys change when a tileset reloads (a later increment adds
    invalidation). }
  meshKey: array of pointer;
  meshBuf: array of GLuint;
  meshCnt: array of longint;
  atlasKey: array of PByte;
  atlasTex: array of GLuint;

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

function BuildProgram(const vsrc, fsrc: string): GLuint;
var vs, fs, pr: GLuint; status, ln: GLint; log: array[0 .. 511] of char;
begin
  BuildProgram := 0;
  vs := MakeShader(GL_VERTEX_SHADER, vsrc);
  fs := MakeShader(GL_FRAGMENT_SHADER, fsrc);
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
  BuildProgram := pr;
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
  tanHy := TAN_HX * (FBH / FBW);   { the 320x240 render target's aspect }
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

function MatTrans(tx, ty, tz: GLfloat): TMat4;
var m: TMat4; i: longint;
begin
  for i := 0 to 15 do m[i] := 0;
  m[0] := 1; m[5] := 1; m[10] := 1; m[15] := 1;
  m[12] := tx; m[13] := ty; m[14] := tz;
  MatTrans := m;
end;

function MatScale(sx, sy, sz: GLfloat): TMat4;
var m: TMat4; i: longint;
begin
  for i := 0 to 15 do m[i] := 0;
  m[0] := sx; m[5] := sy; m[10] := sz; m[15] := 1;
  MatScale := m;
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

{ Build the 4x4 ordered-dither threshold texture the scene shader samples. Each
  texel is (BAYER4 + 0.5) / 16 scaled to a byte, so the shader reads a threshold
  in (0, 1). The matrix matches gfx.BAYER4. }
procedure BuildBayerTex;
const
  BAYER4: array[0 .. 15] of longint =
    (0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5);
var
  px: array[0 .. 15] of byte;
  i: longint;
begin
  for i := 0 to 15 do
    px[i] := round((BAYER4[i] + 0.5) / 16.0 * 255.0);
  glGenTextures(1, @bayerTex);
  glActiveTexture(GL_TEXTURE1);
  glBindTexture(GL_TEXTURE_2D, bayerTex);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_REPEAT);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_REPEAT);
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_LUMINANCE, 4, 4, 0,
    GL_LUMINANCE, GL_UNSIGNED_BYTE, @px[0]);
  glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
  glActiveTexture(GL_TEXTURE0);
end;

function EnsureProgram: boolean;
begin
  if progReady then begin EnsureProgram := true; exit; end;
  EnsureProgram := false;
  prog := BuildProgram(VERT_SRC, FRAG_SRC);
  if prog = 0 then exit;
  BuildBayerTex;
  glUseProgram(prog);
  uMVPLoc := glGetUniformLocation(prog, 'uMVP');
  uLightLoc := glGetUniformLocation(prog, 'uLight');
  uTexLoc := glGetUniformLocation(prog, 'uTex');
  uResLoc := glGetUniformLocation(prog, 'uRes');
  uBayerLoc := glGetUniformLocation(prog, 'uBayer');
  posLoc := glGetAttribLocation(prog, 'aPos');
  uvLoc := glGetAttribLocation(prog, 'aUV');
  glUniform1i(uTexLoc, 0);
  glUniform1i(uBayerLoc, 1);
  glUniform2f(uResLoc, FBW, FBH);
  progReady := true;
  EnsureProgram := true;
end;

{ Point the pos/uv attributes at the currently bound vertex buffer, whose
  vertices are five floats: x, y, z, u, v. }
procedure BindVertexAttribs;
begin
  glEnableVertexAttribArray(GLuint(posLoc));
  glVertexAttribPointer(GLuint(posLoc), 3, GL_FLOAT, GL_FALSE,
    5 * SizeOf(GLfloat), Pointer(0));
  glEnableVertexAttribArray(GLuint(uvLoc));
  glVertexAttribPointer(GLuint(uvLoc), 2, GL_FLOAT, GL_FALSE,
    5 * SizeOf(GLfloat), Pointer(3 * SizeOf(GLfloat)));
end;

procedure GLRenderTestFrame;
var mvp, proj, view, model: TMat4;
begin
  if not VideoIsGL then exit;
  if not EnsureProgram then exit;
  if not cubeReady then begin
    InitResources;
    glUseProgram(prog); glUniform1i(uTexLoc, 0);
    cubeReady := true;
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
  BindVertexAttribs;
  glDrawArrays(GL_TRIANGLES, 0, 36);
  VideoSwap;
end;

{ ---- GPU scene (stage 2 increment 2) ---- }

{ The vertex buffer for a mesh, uploaded and cached on first use. }
function MeshBuffer(const m: TMesh; out count: longint): GLuint;
var
  i, n, b: longint;
  buf: GLuint;
  data: array of GLfloat;
begin
  n := Length(m.verts);
  count := n;
  for i := 0 to High(meshKey) do
    if meshKey[i] = @m.verts[0] then begin
      count := meshCnt[i];
      MeshBuffer := meshBuf[i];
      exit;
    end;
  SetLength(data, n * 5);
  for i := 0 to n - 1 do begin
    data[i * 5 + 0] := m.verts[i].x;
    data[i * 5 + 1] := m.verts[i].y;
    data[i * 5 + 2] := m.verts[i].z;
    data[i * 5 + 3] := m.verts[i].u;
    data[i * 5 + 4] := m.verts[i].v;
  end;
  glGenBuffers(1, @buf);
  glBindBuffer(GL_ARRAY_BUFFER, buf);
  glBufferData(GL_ARRAY_BUFFER, n * 5 * SizeOf(GLfloat), @data[0], GL_STATIC_DRAW);
  b := Length(meshKey);
  SetLength(meshKey, b + 1); SetLength(meshBuf, b + 1); SetLength(meshCnt, b + 1);
  meshKey[b] := @m.verts[0]; meshBuf[b] := buf; meshCnt[b] := n;
  MeshBuffer := buf;
end;

{ A GL texture for a trim atlas of palette indices, expanded to RGBA through
  the active game palette and cached by the atlas pointer. }
function AtlasTexture(idx: PByte; w, h: longint): GLuint;
var
  i, n, b: longint;
  t: GLuint;
  rgba: array of byte;
  c: TColor;
begin
  AtlasTexture := 0;
  if (idx = nil) or (w <= 0) or (h <= 0) then exit;
  for i := 0 to High(atlasKey) do
    if atlasKey[i] = idx then begin
      AtlasTexture := atlasTex[i];
      exit;
    end;
  n := w * h;
  SetLength(rgba, n * 4);
  for i := 0 to n - 1 do begin
    c := Palette[(idx + i)^];
    rgba[i * 4 + 0] := (c shr 16) and $FF;
    rgba[i * 4 + 1] := (c shr 8) and $FF;
    rgba[i * 4 + 2] := c and $FF;
    rgba[i * 4 + 3] := 255;
  end;
  glGenTextures(1, @t);
  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, t);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0,
    GL_RGBA, GL_UNSIGNED_BYTE, @rgba[0]);
  b := Length(atlasKey);
  SetLength(atlasKey, b + 1); SetLength(atlasTex, b + 1);
  atlasKey[b] := idx; atlasTex[b] := t;
  AtlasTexture := t;
end;

{ The 320x240 scene render target: a colour texture plus a depth buffer. }
function EnsureFBO: boolean;
begin
  if fboReady then begin EnsureFBO := true; exit; end;
  EnsureFBO := false;
  glGenTextures(1, @fboTex);
  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, fboTex);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, FBW, FBH, 0,
    GL_RGBA, GL_UNSIGNED_BYTE, nil);
  glGenRenderbuffers(1, @fboDepth);
  glBindRenderbuffer(GL_RENDERBUFFER, fboDepth);
  glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT16, FBW, FBH);
  glGenFramebuffers(1, @fbo);
  glBindFramebuffer(GL_FRAMEBUFFER, fbo);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
    GL_TEXTURE_2D, fboTex, 0);
  glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT,
    GL_RENDERBUFFER, fboDepth);
  if glCheckFramebufferStatus(GL_FRAMEBUFFER) <> GL_FRAMEBUFFER_COMPLETE then begin
    writeln(StdErr, 'glrender: scene framebuffer incomplete');
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    exit;
  end;
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  fboReady := true;
  EnsureFBO := true;
end;

function EnsurePresent: boolean;
begin
  if presentReady then begin EnsurePresent := true; exit; end;
  EnsurePresent := false;
  presentProg := BuildProgram(PVERT_SRC, PFRAG_SRC);
  if presentProg = 0 then exit;
  presentPos := glGetAttribLocation(presentProg, 'aPos');
  presentUV := glGetAttribLocation(presentProg, 'aUV');
  presentTexLoc := glGetUniformLocation(presentProg, 'uTex');
  glGenBuffers(1, @presentVBO);
  glBindBuffer(GL_ARRAY_BUFFER, presentVBO);
  glBufferData(GL_ARRAY_BUFFER, SizeOf(PQUAD), @PQUAD[0], GL_STATIC_DRAW);
  presentReady := true;
  EnsurePresent := true;
end;

procedure GLSceneBegin(const mc: TMeshCam);
begin
  if not VideoIsGL then exit;
  if not EnsureProgram then exit;
  if not EnsureFBO then exit;
  if not EnsurePresent then exit;
  glBindFramebuffer(GL_FRAMEBUFFER, fbo);
  glViewport(0, 0, FBW, FBH);
  glEnable(GL_DEPTH_TEST);
  glDepthFunc(GL_LEQUAL);
  glDisable(GL_CULL_FACE);
  glClearColor(0.02, 0.02, 0.04, 1.0);
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT);
  sceneProj := MatProj;
  sceneView := MatView(mc.x, mc.y, mc.z, mc.yaw, mc.pitch);
  glUseProgram(prog);
  glUniform1i(uTexLoc, 0);
  glActiveTexture(GL_TEXTURE1);         { the dither matrix stays on unit 1 }
  glBindTexture(GL_TEXTURE_2D, bayerTex);
  glActiveTexture(GL_TEXTURE0);
end;

procedure GLDrawMesh(const m: TMesh; const mc: TMeshCam;
  mx, my, mz, sx, sy, sz, yaw, light: double; const mats: array of TMeshMat);
var
  model, mv, mvp: TMat4;
  buf, t: GLuint;
  count: longint;
  lf: GLfloat;
begin
  if not progReady then exit;
  if Length(m.verts) = 0 then exit;
  { an embedded mesh (a prop) carries its own texture; a shared mesh (a kit
    piece) samples the atlas passed in mats[0] }
  if (m.texKind = TEXKIND_EMBED) and (Length(m.tex) > 0) then
    t := AtlasTexture(@m.tex[0], m.texW, m.texH)
  else if Length(mats) > 0 then
    t := AtlasTexture(mats[0].tex, mats[0].tw, mats[0].th)
  else
    t := 0;
  if t = 0 then exit;

  { model = translate * rotateZ(yaw) * scale, matching the software path }
  model := MatMul(MatTrans(mx, my, mz), MatMul(MatRotZ(yaw), MatScale(sx, sy, sz)));
  mv := MatMul(sceneView, model);
  mvp := MatMul(sceneProj, mv);

  glUseProgram(prog);
  glUniformMatrix4fv(uMVPLoc, 1, GL_FALSE, @mvp[0]);
  lf := light / 256.0;
  if lf > 2.0 then lf := 2.0;
  glUniform1f(uLightLoc, lf);
  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, t);

  buf := MeshBuffer(m, count);
  glBindBuffer(GL_ARRAY_BUFFER, buf);
  BindVertexAttribs;
  glDrawArrays(GL_TRIANGLES, 0, count);
end;

procedure GLDrawWorldQuad(
  x0, y0, z0, x1, y1, z1, x2, y2, z2, x3, y3, z3: double;
  u0, v0, u1, v1, u2, v2, u3, v3: double;
  tex: PByte; tw, th: longint; light: double);
var
  v: array[0 .. 29] of GLfloat;   { 6 vertices (two tris), 5 floats each }
  mvp: TMat4;
  t: GLuint;
  lf: GLfloat;
begin
  if not progReady then exit;
  t := AtlasTexture(tex, tw, th);
  if t = 0 then exit;

  { triangles (0,1,2) and (0,2,3), matching the quad's corner order }
  v[0] := x0; v[1] := y0; v[2] := z0; v[3] := u0; v[4] := v0;
  v[5] := x1; v[6] := y1; v[7] := z1; v[8] := u1; v[9] := v1;
  v[10] := x2; v[11] := y2; v[12] := z2; v[13] := u2; v[14] := v2;
  v[15] := x0; v[16] := y0; v[17] := z0; v[18] := u0; v[19] := v0;
  v[20] := x2; v[21] := y2; v[22] := z2; v[23] := u2; v[24] := v2;
  v[25] := x3; v[26] := y3; v[27] := z3; v[28] := u3; v[29] := v3;

  if quadVBO = 0 then glGenBuffers(1, @quadVBO);

  { model is identity: the corners are already in world space }
  mvp := MatMul(sceneProj, sceneView);
  glUseProgram(prog);
  glUniformMatrix4fv(uMVPLoc, 1, GL_FALSE, @mvp[0]);
  lf := light / 256.0;
  if lf > 2.0 then lf := 2.0;
  glUniform1f(uLightLoc, lf);
  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, t);

  glBindBuffer(GL_ARRAY_BUFFER, quadVBO);
  glBufferData(GL_ARRAY_BUFFER, SizeOf(v), @v[0], GL_DYNAMIC_DRAW);
  BindVertexAttribs;
  glDrawArrays(GL_TRIANGLES, 0, 6);
end;

procedure GLSceneEnd;
begin
  if not fboReady then exit;
  if not presentReady then exit;

  { Blit the 320x240 scene target to the window, upscaled nearest for the retro
    look. The HUD is composited over this by the caller, which then swaps. }
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  glViewport(0, 0, VideoWidth, VideoHeight);
  glDisable(GL_DEPTH_TEST);
  glDisable(GL_BLEND);
  glUseProgram(presentProg);
  glUniform1i(presentTexLoc, 0);
  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, fboTex);

  glBindBuffer(GL_ARRAY_BUFFER, presentVBO);
  glEnableVertexAttribArray(GLuint(presentPos));
  glVertexAttribPointer(GLuint(presentPos), 2, GL_FLOAT, GL_FALSE,
    4 * SizeOf(GLfloat), Pointer(0));
  glEnableVertexAttribArray(GLuint(presentUV));
  glVertexAttribPointer(GLuint(presentUV), 2, GL_FLOAT, GL_FALSE,
    4 * SizeOf(GLfloat), Pointer(2 * SizeOf(GLfloat)));
  glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
end;

end.
