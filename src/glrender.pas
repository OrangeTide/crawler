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
  raster, meshfmt, pic, gfx;

{ Render one frame of the pipeline-proof scene and swap. A no-op when the GL
  backend is not active. }
procedure GLRenderTestFrame;

{ A GPU scene frame. Begin sets the camera and clears; each kit piece is drawn
  through GLDrawMesh (whose signature matches clad.CladMeshHook); End swaps.
  Call Begin/End around the cladding passes with the hook pointed here. }
procedure GLSceneBegin(const mc: TMeshCam);
{ Fill the scene target with the surface-map sky: a vertical gradient from the
  zenith colour to the horizon colour, split at horizonY (top-down pixel row).
  Drawn after GLSceneBegin and before the geometry, with depth off, so the
  geometry overdraws it. Colours are 0..1. Matches world.SkyColorAt, which is
  linear between the two band ends. }
procedure GLDrawSky(horizonY: longint; zr, zg, zb, hr, hg, hb: double);
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
  tex: PByte; tw, th: longint; light: double;
  direct: PColorArray = nil);
{ Drop the cached GL texture for a source pointer refilled in place, so its next
  draw re-uploads. Called when a tileset swap rebuilds the biome surfaces. }
procedure GLInvalidateAtlas(p: Pointer);
{ One camera-facing sprite billboard, matching raster.DrawSpriteBillboard. The
  ARGB image uploads as an alpha-keyed texture; the scene shader discards the
  transparent texels. A small depth-offset biases it toward the camera so its
  base wins the z-fight with the floor it stands on. }
procedure GLDrawSprite(const cam: TMeshCam; const img: TImage;
  wx, wy, wscale, hscale, light, baseZ: double);
{ A translucent emissive glow decal over floor cell (tx,ty) at height z, the
  colour alpha-blended over the scene at a (0..1). Depth-tested so walls occlude
  it, but it writes no depth. Stands in for raster.DrawFloorGlow on light-well,
  brazier and vent floors, for both kit and non-kit cells. }
procedure GLDrawGlow(tx, ty: longint; z, r, g, b, a: double);
{ Darken the whole window by a translucent black veil (alpha a, 0..1), drawn
  over the already-presented scene in the default framebuffer. Used to dim the
  GPU explore scene behind an overlay such as a dialog, in place of the software
  path's full-screen FillRectBlend. Call after the scene is on screen and before
  the 2D overlay is composited. }
procedure GLDimScene(a: double);
procedure GLSceneEnd;

var
  { When true the GPU binds the kit trim in full direct colour; when false it
    samples through the tileset CLUT for the PlayStation look. The explore
    render path sets this from the player's setting each frame. }
  GLTrueColour: boolean = false;

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
    'uniform sampler2D uEmis;'#10 +
    'uniform sampler2D uClut;'#10 +
    'uniform float uLight;'#10 +
    'uniform float uHasEmis;'#10 +
    'uniform float uClutMode;'#10 +
    'void main() {'#10 +
    '  vec4 s;'#10 +
    '  if (uClutMode > 0.5) {'#10 +   { paletted diffuse: uTex holds CLUT indices }
    '    float idx = floor(texture2D(uTex, vUV).r * 255.0 + 0.5);'#10 +
    '    s = texture2D(uClut, vec2((idx + 0.5) / 256.0, 0.5));'#10 +
    '  } else {'#10 +
    '    s = texture2D(uTex, vUV);'#10 +
    '  }'#10 +
    '  if (s.a < 0.5) discard;'#10 +   { masks a sprite's keyed texels; opaque geometry is alpha 1 }
    '  vec3 c = s.rgb * uLight + texture2D(uEmis, vUV).rgb * uHasEmis;'#10 +   { emission full-bright }
    '  c = clamp(c, 0.0, 1.0);'#10 +
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

  { A flat translucent fill over a fullscreen quad, for the scene-dim veil. }
  DIM_VERT =
    'attribute vec2 aPos;'#10 +
    'void main() { gl_Position = vec4(aPos, 0.0, 1.0); }'#10;
  DIM_FRAG =
    'precision mediump float;'#10 +
    'uniform vec4 uColor;'#10 +
    'void main() { gl_FragColor = uColor; }'#10;

  { The surface-map sky gradient, drawn as a fullscreen quad in the scene
    target. }
  SKY_VERT =
    'attribute vec2 aPos;'#10 +
    'void main() { gl_Position = vec4(aPos, 0.999, 1.0); }'#10;
  SKY_FRAG =
    'precision mediump float;'#10 +
    'uniform vec3 uZenith;'#10 +
    'uniform vec3 uHorizon;'#10 +
    'uniform float uHorizonY;'#10 +
    'uniform float uFBH;'#10 +
    'void main() {'#10 +
    '  float sy = uFBH - gl_FragCoord.y;'#10 +        { top-down row }
    '  float f = clamp(sy / max(uHorizonY, 1.0), 0.0, 1.0);'#10 +
    '  gl_FragColor = vec4(mix(uZenith, uHorizon, f), 1.0);'#10 +
    '}'#10;

  { A flat translucent colour, for the emissive floor glow decal. Reuses the
    scene vertex layout (aPos, aUV) so BindVertexAttribs applies; uv is unused. }
  GLOW_VERT =
    'uniform mat4 uMVP;'#10 +
    'attribute vec3 aPos;'#10 +
    'attribute vec2 aUV;'#10 +
    'void main() { gl_Position = uMVP * vec4(aPos, 1.0); }'#10;
  GLOW_FRAG =
    'precision mediump float;'#10 +
    'uniform vec4 uColor;'#10 +
    'void main() { gl_FragColor = uColor; }'#10;

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
  uResLoc, uBayerLoc, uEmisLoc, uHasEmisLoc: GLint;
  uClutLoc, uClutModeLoc: GLint;
  bayerTex: GLuint = 0;
  quadVBO: GLuint = 0;        { reused for the per-frame world quads }
  matVBO: GLuint = 0;         { reused for a multi-material mesh's per-material runs }
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
  skyReady: boolean = false;
  skyProg: GLuint = 0;
  skyVBO: GLuint = 0;
  skyPos, skyZenithLoc, skyHorizonLoc, skyHorizonYLoc, skyFBHLoc: GLint;
  glowReady: boolean = false;
  glowProg: GLuint = 0;
  glowPos, glowUVLoc, glowColorLoc, glowMVPLoc: GLint;
  dimReady: boolean = false;
  dimProg: GLuint = 0;
  dimPos, dimColorLoc: GLint;

  { per-mesh vertex buffers and per-atlas textures, cached by source pointer.
    Meshes are resident for the session (clad's cache), so their keys are
    stable; atlas keys change when a tileset reloads (a later increment adds
    invalidation). }
  meshKey: array of pointer;
  meshBuf: array of GLuint;
  meshCnt: array of longint;
  atlasKey: array of PByte;
  atlasTex: array of GLuint;
  spriteKey: array of pointer;    { ARGB sprite textures, cached by pix pointer }
  spriteTexs: array of GLuint;

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
  uEmisLoc := glGetUniformLocation(prog, 'uEmis');
  uHasEmisLoc := glGetUniformLocation(prog, 'uHasEmis');
  uClutLoc := glGetUniformLocation(prog, 'uClut');
  uClutModeLoc := glGetUniformLocation(prog, 'uClutMode');
  posLoc := glGetAttribLocation(prog, 'aPos');
  uvLoc := glGetAttribLocation(prog, 'aUV');
  glUniform1i(uTexLoc, 0);
  glUniform1i(uBayerLoc, 1);
  glUniform1i(uEmisLoc, 2);
  glUniform1i(uClutLoc, 3);
  glUniform1f(uClutModeLoc, 0.0);
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

{ Drop the cached GL texture for a source pointer, so the next upload for it is
  rebuilt. Used when a resident texture is refilled in place (the biome surfaces
  in Tex and GridTex, rebuilt on a tileset swap), whose fixed address would
  otherwise keep serving the previous tileset's texture. }
procedure GLInvalidateAtlas(p: Pointer);
var i, n: longint;
begin
  n := Length(atlasKey);
  for i := 0 to n - 1 do
    if atlasKey[i] = PByte(p) then begin
      if VideoIsGL and (atlasTex[i] <> 0) then glDeleteTextures(1, @atlasTex[i]);
      atlasKey[i] := atlasKey[n - 1]; atlasTex[i] := atlasTex[n - 1];
      SetLength(atlasKey, n - 1); SetLength(atlasTex, n - 1);
      exit;
    end;
end;

{ A GL texture for a trim atlas already in direct colour (ARGB), uploaded
  without the shared-palette expansion so the tileset keeps its own colour.
  Cached in the same pointer-keyed table as the indexed atlases; a trim
  sheet's indexed and direct arrays are distinct allocations, so their
  pointers never collide. }
function AtlasTextureRGBA(src: PColorArray; w, h: longint): GLuint;
var
  i, n, b: longint;
  t: GLuint;
  rgba: array of byte;
  c: TColor;
begin
  AtlasTextureRGBA := 0;
  if (src = nil) or (w <= 0) or (h <= 0) then exit;
  for i := 0 to High(atlasKey) do
    if atlasKey[i] = PByte(src) then begin
      AtlasTextureRGBA := atlasTex[i];
      exit;
    end;
  n := w * h;
  SetLength(rgba, n * 4);
  for i := 0 to n - 1 do begin
    c := (src + i)^;
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
  atlasKey[b] := PByte(src); atlasTex[b] := t;
  AtlasTextureRGBA := t;
end;

{ A GL texture holding a trim atlas as raw CLUT indices (one 8-bit channel),
  for the paletted diffuse path. The fragment shader reads the index and looks
  it up in the bound CLUT, as the PS1 samples an indexed texture against a CLUT.
  Cached in the same pointer-keyed table; the cidx array is its own allocation. }
function AtlasIndexTexture(idx: PByte; w, h: longint): GLuint;
var
  i, b: longint;
  t: GLuint;
begin
  AtlasIndexTexture := 0;
  if (idx = nil) or (w <= 0) or (h <= 0) then exit;
  for i := 0 to High(atlasKey) do
    if atlasKey[i] = idx then begin
      AtlasIndexTexture := atlasTex[i];
      exit;
    end;
  glGenTextures(1, @t);
  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, t);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_LUMINANCE, w, h, 0,
    GL_LUMINANCE, GL_UNSIGNED_BYTE, idx);
  glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
  b := Length(atlasKey);
  SetLength(atlasKey, b + 1); SetLength(atlasTex, b + 1);
  atlasKey[b] := idx; atlasTex[b] := t;
  AtlasIndexTexture := t;
end;

{ A 256x1 RGBA GL texture for a tileset CLUT, cached by its pointer. The
  paletted diffuse path binds it to unit 3 and looks up each index against it. }
function ClutTexture(clut: PColorArray): GLuint;
var
  i, b: longint;
  t: GLuint;
  rgba: array[0 .. 256 * 4 - 1] of byte;
  c: TColor;
begin
  ClutTexture := 0;
  if clut = nil then exit;
  for i := 0 to High(atlasKey) do
    if atlasKey[i] = PByte(clut) then begin
      ClutTexture := atlasTex[i];
      exit;
    end;
  for i := 0 to 255 do begin
    c := (clut + i)^;
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
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 256, 1, 0,
    GL_RGBA, GL_UNSIGNED_BYTE, @rgba[0]);
  b := Length(atlasKey);
  SetLength(atlasKey, b + 1); SetLength(atlasTex, b + 1);
  atlasKey[b] := PByte(clut); atlasTex[b] := t;
  ClutTexture := t;
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

function EnsureSky: boolean;
begin
  if skyReady then begin EnsureSky := true; exit; end;
  EnsureSky := false;
  skyProg := BuildProgram(SKY_VERT, SKY_FRAG);
  if skyProg = 0 then exit;
  skyPos := glGetAttribLocation(skyProg, 'aPos');
  skyZenithLoc := glGetUniformLocation(skyProg, 'uZenith');
  skyHorizonLoc := glGetUniformLocation(skyProg, 'uHorizon');
  skyHorizonYLoc := glGetUniformLocation(skyProg, 'uHorizonY');
  skyFBHLoc := glGetUniformLocation(skyProg, 'uFBH');
  glGenBuffers(1, @skyVBO);
  glBindBuffer(GL_ARRAY_BUFFER, skyVBO);
  glBufferData(GL_ARRAY_BUFFER, SizeOf(PQUAD), @PQUAD[0], GL_STATIC_DRAW);
  skyReady := true;
  EnsureSky := true;
end;

procedure GLDrawSky(horizonY: longint; zr, zg, zb, hr, hg, hb: double);
begin
  if not VideoIsGL then exit;
  if not EnsureSky then exit;
  { no depth test, so the quad neither reads nor writes depth and the geometry
    drawn after overdraws it wherever it stands }
  glDisable(GL_DEPTH_TEST);
  glUseProgram(skyProg);
  glUniform3f(skyZenithLoc, zr, zg, zb);
  glUniform3f(skyHorizonLoc, hr, hg, hb);
  glUniform1f(skyHorizonYLoc, horizonY);
  glUniform1f(skyFBHLoc, FBH);
  glBindBuffer(GL_ARRAY_BUFFER, skyVBO);
  glEnableVertexAttribArray(GLuint(skyPos));
  glVertexAttribPointer(GLuint(skyPos), 2, GL_FLOAT, GL_FALSE,
    4 * SizeOf(GLfloat), Pointer(0));
  glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
  glEnable(GL_DEPTH_TEST);
end;

{ Bind a material's emission atlas to texture unit 2 and set uHasEmis, or clear
  uHasEmis when the material has none. Leaves the active unit at 0, but may have
  dirtied unit 0's binding (AtlasTexture binds there on a miss), so the caller
  rebinds the diffuse to unit 0 after this. }
procedure BindEmis(const mat: TMeshMat);
var e: GLuint;
begin
  e := 0;
  if (mat.emisRGBA <> nil) and (mat.ew > 0) and (mat.eh > 0) then
    e := AtlasTextureRGBA(mat.emisRGBA, mat.ew, mat.eh)
  else if (mat.emis <> nil) and (mat.ew > 0) and (mat.eh > 0) then
    e := AtlasTexture(mat.emis, mat.ew, mat.eh);
  if e <> 0 then begin
    glActiveTexture(GL_TEXTURE2);
    glBindTexture(GL_TEXTURE_2D, e);
    glUniform1f(uHasEmisLoc, 1.0);
  end else
    glUniform1f(uHasEmisLoc, 0.0);
  glActiveTexture(GL_TEXTURE0);
end;

{ Bind a material's diffuse and emission for one draw, choosing the paletted
  CLUT path when the material carries a CLUT (unit 0 holds the indices, unit 3
  the CLUT, uClutMode on) and the shared-palette indexed path otherwise. Also
  binds emission to unit 2. Returns false when the diffuse texture is missing,
  so the caller skips the draw. Leaves the active unit at 0. }
function BindDiffuse(const mat: TMeshMat): boolean;
var
  it, ct: GLuint;
  mode: GLfloat;
begin
  BindDiffuse := false;
  mode := 0.0; it := 0; ct := 0;
  if GLTrueColour and (mat.texRGBA <> nil) then
    { full direct colour, no CLUT quantize }
    it := AtlasTextureRGBA(mat.texRGBA, mat.tw, mat.th)
  else if (mat.clut <> nil) and (mat.texClutIdx <> nil) then begin
    it := AtlasIndexTexture(mat.texClutIdx, mat.tw, mat.th);
    ct := ClutTexture(mat.clut);
    if (it <> 0) and (ct <> 0) then mode := 1.0 else it := 0;
  end;
  if (mode < 0.5) and (it = 0) then
    it := AtlasTexture(mat.tex, mat.tw, mat.th);
  if it = 0 then exit;
  BindEmis(mat);
  glUniform1f(uClutModeLoc, mode);
  if mode > 0.5 then begin
    glActiveTexture(GL_TEXTURE3);
    glBindTexture(GL_TEXTURE_2D, ct);
  end;
  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, it);
  BindDiffuse := true;
end;

procedure GLDrawMesh(const m: TMesh; const mc: TMeshCam;
  mx, my, mz, sx, sy, sz, yaw, light: double; const mats: array of TMeshMat);
var
  model, mv, mvp: TMat4;
  buf, t: GLuint;
  count, matCount, mi, tri, nTris, j, k, outN: longint;
  lf: GLfloat;
  data: array of GLfloat;
begin
  if not progReady then exit;
  if Length(m.verts) = 0 then exit;

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

  { an embedded mesh (a prop) carries its own texture, no emission }
  if (m.texKind = TEXKIND_EMBED) and (Length(m.tex) > 0) then begin
    t := AtlasTexture(@m.tex[0], m.texW, m.texH);
    if t = 0 then exit;
    glUniform1f(uHasEmisLoc, 0.0);
    glUniform1f(uClutModeLoc, 0.0);
    glBindTexture(GL_TEXTURE_2D, t);
    buf := MeshBuffer(m, count);
    glBindBuffer(GL_ARRAY_BUFFER, buf);
    BindVertexAttribs;
    glDrawArrays(GL_TRIANGLES, 0, count);
    exit;
  end;

  if Length(mats) = 0 then exit;
  matCount := MeshMatCount(m);

  { a single-material shared mesh samples mats[0] in one draw of its whole
    cached buffer, plus its emission atlas if it has one }
  if (matCount <= 1) or (Length(m.mat) = 0) or (Length(mats) = 1) then begin
    if not BindDiffuse(mats[0]) then exit;
    buf := MeshBuffer(m, count);
    glBindBuffer(GL_ARRAY_BUFFER, buf);
    BindVertexAttribs;
    glDrawArrays(GL_TRIANGLES, 0, count);
    exit;
  end;

  { a multi-material piece (for example a window's stone frame and its glass):
    one draw per material, each binding that material's atlas and gathering only
    its triangles. Built dynamically since the triangles are not grouped. }
  nTris := Length(m.verts) div 3;
  SetLength(data, Length(m.verts) * 5);
  for mi := 0 to matCount - 1 do begin
    j := mi;
    if j > High(mats) then j := High(mats);
    outN := 0;
    for tri := 0 to nTris - 1 do begin
      if m.mat[tri] <> mi then continue;
      for k := 0 to 2 do begin
        data[outN * 5 + 0] := m.verts[tri * 3 + k].x;
        data[outN * 5 + 1] := m.verts[tri * 3 + k].y;
        data[outN * 5 + 2] := m.verts[tri * 3 + k].z;
        data[outN * 5 + 3] := m.verts[tri * 3 + k].u;
        data[outN * 5 + 4] := m.verts[tri * 3 + k].v;
        inc(outN);
      end;
    end;
    if outN = 0 then continue;
    if not BindDiffuse(mats[j]) then continue;
    if matVBO = 0 then glGenBuffers(1, @matVBO);
    glBindBuffer(GL_ARRAY_BUFFER, matVBO);
    glBufferData(GL_ARRAY_BUFFER, outN * 5 * SizeOf(GLfloat), @data[0], GL_DYNAMIC_DRAW);
    BindVertexAttribs;
    glDrawArrays(GL_TRIANGLES, 0, outN);
  end;
end;

procedure GLDrawWorldQuad(
  x0, y0, z0, x1, y1, z1, x2, y2, z2, x3, y3, z3: double;
  u0, v0, u1, v1, u2, v2, u3, v3: double;
  tex: PByte; tw, th: longint; light: double;
  direct: PColorArray = nil);
var
  v: array[0 .. 29] of GLfloat;   { 6 vertices (two tris), 5 floats each }
  mvp: TMat4;
  t: GLuint;
  lf: GLfloat;
begin
  if not progReady then exit;
  { direct colour (the biome surface's own RGBA) when given, else the
    shared-palette indexed form }
  if direct <> nil then
    t := AtlasTextureRGBA(direct, tw, th)
  else
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
  glUniform1f(uHasEmisLoc, 0.0);     { a grid quad has no emission }
  glUniform1f(uClutModeLoc, 0.0);    { grid and terrain are direct, not paletted }
  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, t);

  glBindBuffer(GL_ARRAY_BUFFER, quadVBO);
  glBufferData(GL_ARRAY_BUFFER, SizeOf(v), @v[0], GL_DYNAMIC_DRAW);
  BindVertexAttribs;
  glDrawArrays(GL_TRIANGLES, 0, 6);
end;

{ A GL texture for an ARGB sprite image, cached by its pixel pointer. The bytes
  are reordered to RGBA; the alpha channel carries the sprite's transparency. }
function SpriteTexture(const img: TImage): GLuint;
var
  i, n, b: longint;
  t: GLuint;
  rgba: array of byte;
  c: TColor;
begin
  SpriteTexture := 0;
  if (Length(img.pix) = 0) or (img.w <= 0) or (img.h <= 0) then exit;
  for i := 0 to High(spriteKey) do
    if spriteKey[i] = @img.pix[0] then begin
      SpriteTexture := spriteTexs[i];
      exit;
    end;
  n := img.w * img.h;
  SetLength(rgba, n * 4);
  for i := 0 to n - 1 do begin
    c := img.pix[i];
    rgba[i * 4 + 0] := (c shr 16) and $FF;
    rgba[i * 4 + 1] := (c shr 8) and $FF;
    rgba[i * 4 + 2] := c and $FF;
    rgba[i * 4 + 3] := (c shr 24) and $FF;
  end;
  glGenTextures(1, @t);
  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, t);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
  glPixelStorei(GL_UNPACK_ALIGNMENT, 4);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, img.w, img.h, 0,
    GL_RGBA, GL_UNSIGNED_BYTE, @rgba[0]);
  b := Length(spriteKey);
  SetLength(spriteKey, b + 1); SetLength(spriteTexs, b + 1);
  spriteKey[b] := @img.pix[0]; spriteTexs[b] := t;
  SpriteTexture := t;
end;

procedure GLDrawSprite(const cam: TMeshCam; const img: TImage;
  wx, wy, wscale, hscale, light, baseZ: double);
var
  rx, ry, hw: double;
  v: array[0 .. 29] of GLfloat;
  mvp: TMat4;
  t: GLuint;
  lf: GLfloat;
begin
  if not progReady then exit;
  if Length(img.pix) = 0 then exit;
  t := SpriteTexture(img);
  if t = 0 then exit;

  { camera right vector in the world XY plane, so the quad faces the eye;
    v mirrors raster.DrawSpriteBillboard's corners, with the image's top row at
    the top (u left..right, v 0 at the top as GL uploads it) }
  rx := sin(cam.yaw); ry := -cos(cam.yaw);
  hw := wscale * 0.5;
  { triangle BL, BR, TR }
  v[0] := wx - rx * hw; v[1] := wy - ry * hw; v[2] := baseZ;           v[3] := 0; v[4] := 1;
  v[5] := wx + rx * hw; v[6] := wy + ry * hw; v[7] := baseZ;           v[8] := 1; v[9] := 1;
  v[10] := wx + rx * hw; v[11] := wy + ry * hw; v[12] := baseZ + hscale; v[13] := 1; v[14] := 0;
  { triangle BL, TR, TL }
  v[15] := wx - rx * hw; v[16] := wy - ry * hw; v[17] := baseZ;           v[18] := 0; v[19] := 1;
  v[20] := wx + rx * hw; v[21] := wy + ry * hw; v[22] := baseZ + hscale; v[23] := 1; v[24] := 0;
  v[25] := wx - rx * hw; v[26] := wy - ry * hw; v[27] := baseZ + hscale; v[28] := 0; v[29] := 0;

  if quadVBO = 0 then glGenBuffers(1, @quadVBO);
  mvp := MatMul(sceneProj, sceneView);
  glUseProgram(prog);
  glUniformMatrix4fv(uMVPLoc, 1, GL_FALSE, @mvp[0]);
  lf := light / 256.0;
  if lf > 2.0 then lf := 2.0;
  glUniform1f(uLightLoc, lf);
  glUniform1f(uHasEmisLoc, 0.0);     { a sprite has no emission atlas }
  glUniform1f(uClutModeLoc, 0.0);    { sprites keep their own direct colour }
  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, t);

  { bias depth toward the camera so the base beats the floor's z, matching the
    software billboard's depth nudge, without moving the sprite on screen }
  glEnable(GL_POLYGON_OFFSET_FILL);
  glPolygonOffset(-1.0, -4.0);
  glBindBuffer(GL_ARRAY_BUFFER, quadVBO);
  glBufferData(GL_ARRAY_BUFFER, SizeOf(v), @v[0], GL_DYNAMIC_DRAW);
  BindVertexAttribs;
  glDrawArrays(GL_TRIANGLES, 0, 6);
  glDisable(GL_POLYGON_OFFSET_FILL);
end;

function EnsureGlow: boolean;
begin
  if glowReady then begin EnsureGlow := true; exit; end;
  EnsureGlow := false;
  glowProg := BuildProgram(GLOW_VERT, GLOW_FRAG);
  if glowProg = 0 then exit;
  glowPos := glGetAttribLocation(glowProg, 'aPos');
  glowUVLoc := glGetAttribLocation(glowProg, 'aUV');
  glowColorLoc := glGetUniformLocation(glowProg, 'uColor');
  glowMVPLoc := glGetUniformLocation(glowProg, 'uMVP');
  glowReady := true;
  EnsureGlow := true;
end;

procedure GLDrawGlow(tx, ty: longint; z, r, g, b, a: double);
const
  GLOW_LIFT = 0.05;   { lift the decal above the floor, as raster.DrawFloorGlow }
var
  v: array[0 .. 29] of GLfloat;
  mvp: TMat4;
  zz: GLfloat;
begin
  if not progReady then exit;
  if not EnsureGlow then exit;
  zz := z + GLOW_LIFT;
  { two triangles over the cell: (tx,ty)(tx+1,ty)(tx+1,ty+1) and back to (tx,ty+1) }
  v[0] := tx;     v[1] := ty;     v[2] := zz; v[3] := 0; v[4] := 0;
  v[5] := tx + 1; v[6] := ty;     v[7] := zz; v[8] := 0; v[9] := 0;
  v[10] := tx + 1; v[11] := ty + 1; v[12] := zz; v[13] := 0; v[14] := 0;
  v[15] := tx;     v[16] := ty;     v[17] := zz; v[18] := 0; v[19] := 0;
  v[20] := tx + 1; v[21] := ty + 1; v[22] := zz; v[23] := 0; v[24] := 0;
  v[25] := tx;     v[26] := ty + 1; v[27] := zz; v[28] := 0; v[29] := 0;

  if quadVBO = 0 then glGenBuffers(1, @quadVBO);
  mvp := MatMul(sceneProj, sceneView);
  glUseProgram(glowProg);
  glUniformMatrix4fv(glowMVPLoc, 1, GL_FALSE, @mvp[0]);
  glUniform4f(glowColorLoc, r, g, b, a);

  { blend over the scene, depth-tested but not depth-writing, so walls occlude
    the glow yet it never occludes anything itself }
  glEnable(GL_BLEND);
  glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
  glDepthMask(0);
  glBindBuffer(GL_ARRAY_BUFFER, quadVBO);
  glBufferData(GL_ARRAY_BUFFER, SizeOf(v), @v[0], GL_DYNAMIC_DRAW);
  glEnableVertexAttribArray(GLuint(glowPos));
  glVertexAttribPointer(GLuint(glowPos), 3, GL_FLOAT, GL_FALSE,
    5 * SizeOf(GLfloat), Pointer(0));
  glEnableVertexAttribArray(GLuint(glowUVLoc));
  glVertexAttribPointer(GLuint(glowUVLoc), 2, GL_FLOAT, GL_FALSE,
    5 * SizeOf(GLfloat), Pointer(3 * SizeOf(GLfloat)));
  glDrawArrays(GL_TRIANGLES, 0, 6);
  glDepthMask(1);
  glDisable(GL_BLEND);
end;

function EnsureDim: boolean;
begin
  if dimReady then begin EnsureDim := true; exit; end;
  EnsureDim := false;
  if not EnsurePresent then exit;   { reuses the present fullscreen quad buffer }
  dimProg := BuildProgram(DIM_VERT, DIM_FRAG);
  if dimProg = 0 then exit;
  dimPos := glGetAttribLocation(dimProg, 'aPos');
  dimColorLoc := glGetUniformLocation(dimProg, 'uColor');
  dimReady := true;
  EnsureDim := true;
end;

procedure GLDimScene(a: double);
begin
  if not VideoIsGL then exit;
  if not EnsureDim then exit;
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  glViewport(0, 0, VideoWidth, VideoHeight);
  glDisable(GL_DEPTH_TEST);
  glEnable(GL_BLEND);
  glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
  glUseProgram(dimProg);
  glUniform4f(dimColorLoc, 0.0, 0.0, 0.0, a);
  glBindBuffer(GL_ARRAY_BUFFER, presentVBO);
  glEnableVertexAttribArray(GLuint(dimPos));
  glVertexAttribPointer(GLuint(dimPos), 2, GL_FLOAT, GL_FALSE,
    4 * SizeOf(GLfloat), Pointer(0));
  glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
  glDisable(GL_BLEND);
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
