unit gles2;

{** Minimal runtime binding to OpenGL ES 2.0.

  The entry points are resolved through SDL_GL_GetProcAddress, so there is
  no link-time dependency on libGLESv2: the GL comes from whatever the SDL
  GL context provides (a native GLES driver on the Raspberry Pi and Linux,
  or desktop GL / ANGLE later). A current GL context must exist before
  LoadGLES2 is called.

  Only the handful of calls the framebuffer-present backend needs are bound:
  one texture, one shader program, one vertex buffer and a draw. The 3D path
  that later moves rendering onto the GPU will add to this. }

{$mode objfpc}{$H+}

interface

type
  GLenum     = UInt32;
  GLbitfield = UInt32;
  GLuint     = UInt32;
  GLint      = Int32;
  GLsizei    = Int32;
  GLfloat    = Single;
  GLchar     = Char;
  GLboolean  = UInt8;
  PGLuint    = ^GLuint;
  PGLint     = ^GLint;
  PGLfloat   = ^GLfloat;
  PGLchar    = ^GLchar;
  PPGLchar   = ^PGLchar;

const
  GL_FALSE              = 0;
  GL_TRUE               = 1;
  GL_TRIANGLE_STRIP     = $0005;
  GL_FLOAT              = $1406;
  GL_UNSIGNED_BYTE      = $1401;
  GL_RGBA               = $1908;
  GL_TEXTURE_2D         = $0DE1;
  GL_TEXTURE0           = $84C0;
  GL_TEXTURE_MAG_FILTER = $2800;
  GL_TEXTURE_MIN_FILTER = $2801;
  GL_TEXTURE_WRAP_S     = $2802;
  GL_TEXTURE_WRAP_T     = $2803;
  GL_NEAREST            = $2600;
  GL_CLAMP_TO_EDGE      = $812F;
  GL_ARRAY_BUFFER       = $8892;
  GL_STATIC_DRAW        = $88E4;
  GL_FRAGMENT_SHADER    = $8B30;
  GL_VERTEX_SHADER      = $8B31;
  GL_COMPILE_STATUS     = $8B81;
  GL_LINK_STATUS        = $8B82;
  GL_COLOR_BUFFER_BIT   = $4000;
  GL_DEPTH_BUFFER_BIT   = $0100;
  GL_UNPACK_ALIGNMENT   = $0CF5;
  GL_TRIANGLES          = $0004;
  GL_DEPTH_TEST         = $0B71;
  GL_LEQUAL             = $0203;
  GL_CULL_FACE          = $0B44;
  GL_BACK               = $0405;
  GL_FRONT              = $0404;
  GL_CCW                = $0901;
  GL_CW                 = $0900;
  GL_LINEAR             = $2601;
  GL_RGB                = $1907;
  GL_BLEND              = $0BE2;
  GL_SRC_ALPHA          = $0302;
  GL_ONE_MINUS_SRC_ALPHA = $0303;

var
  glClearColor: procedure(r, g, b, a: GLfloat); cdecl;
  glClear: procedure(mask: GLbitfield); cdecl;
  glViewport: procedure(x, y: GLint; w, h: GLsizei); cdecl;
  glGenTextures: procedure(n: GLsizei; textures: PGLuint); cdecl;
  glDeleteTextures: procedure(n: GLsizei; textures: PGLuint); cdecl;
  glBindTexture: procedure(target: GLenum; texture: GLuint); cdecl;
  glActiveTexture: procedure(texture: GLenum); cdecl;
  glTexParameteri: procedure(target, pname: GLenum; param: GLint); cdecl;
  glPixelStorei: procedure(pname: GLenum; param: GLint); cdecl;
  glTexImage2D: procedure(target: GLenum; level, internalformat: GLint;
    w, h: GLsizei; border: GLint; format, kind: GLenum; pixels: Pointer); cdecl;
  glTexSubImage2D: procedure(target: GLenum; level, xoff, yoff: GLint;
    w, h: GLsizei; format, kind: GLenum; pixels: Pointer); cdecl;
  glGenBuffers: procedure(n: GLsizei; buffers: PGLuint); cdecl;
  glBindBuffer: procedure(target: GLenum; buffer: GLuint); cdecl;
  glBufferData: procedure(target: GLenum; size: PtrInt; data: Pointer;
    usage: GLenum); cdecl;
  glCreateShader: function(shaderType: GLenum): GLuint; cdecl;
  glShaderSource: procedure(shader: GLuint; count: GLsizei;
    strs: PPGLchar; lengths: PGLint); cdecl;
  glCompileShader: procedure(shader: GLuint); cdecl;
  glGetShaderiv: procedure(shader: GLuint; pname: GLenum; params: PGLint); cdecl;
  glGetShaderInfoLog: procedure(shader: GLuint; bufSize: GLsizei;
    length: PGLint; infoLog: PGLchar); cdecl;
  glCreateProgram: function: GLuint; cdecl;
  glAttachShader: procedure(prog, shader: GLuint); cdecl;
  glLinkProgram: procedure(prog: GLuint); cdecl;
  glGetProgramiv: procedure(prog: GLuint; pname: GLenum; params: PGLint); cdecl;
  glGetProgramInfoLog: procedure(prog: GLuint; bufSize: GLsizei;
    length: PGLint; infoLog: PGLchar); cdecl;
  glUseProgram: procedure(prog: GLuint); cdecl;
  glGetAttribLocation: function(prog: GLuint; name: PGLchar): GLint; cdecl;
  glGetUniformLocation: function(prog: GLuint; name: PGLchar): GLint; cdecl;
  glEnableVertexAttribArray: procedure(index: GLuint); cdecl;
  glVertexAttribPointer: procedure(index: GLuint; size: GLint; kind: GLenum;
    normalized: GLboolean; stride: GLsizei; ptr: Pointer); cdecl;
  glUniform1i: procedure(location, v0: GLint); cdecl;
  glUniform1f: procedure(location: GLint; v0: GLfloat); cdecl;
  glUniform3f: procedure(location: GLint; v0, v1, v2: GLfloat); cdecl;
  glUniformMatrix4fv: procedure(location: GLint; count: GLsizei;
    transpose: GLboolean; value: PGLfloat); cdecl;
  glDrawArrays: procedure(mode: GLenum; first: GLint; count: GLsizei); cdecl;
  glEnable: procedure(cap: GLenum); cdecl;
  glDisable: procedure(cap: GLenum); cdecl;
  glDepthFunc: procedure(func: GLenum); cdecl;
  glCullFace: procedure(mode: GLenum); cdecl;
  glFrontFace: procedure(mode: GLenum); cdecl;
  glBlendFunc: procedure(sfactor, dfactor: GLenum); cdecl;
  glReadPixels: procedure(x, y: GLint; w, h: GLsizei; format, kind: GLenum;
    pixels: Pointer); cdecl;
  glDeleteBuffers: procedure(n: GLsizei; buffers: PGLuint); cdecl;

{ Bind every entry point above through SDL_GL_GetProcAddress. Returns false if
  any is missing, so the caller can fall back to the software present path. }
function LoadGLES2: boolean;

implementation

uses
  sdl2min;

var
  missing: boolean;

function GL(const name: string): Pointer;
begin
  GL := SDL_GL_GetProcAddress(PChar(name));
  if GL = nil then missing := true;
end;

function LoadGLES2: boolean;
begin
  missing := false;
  Pointer(glClearColor) := GL('glClearColor');
  Pointer(glClear) := GL('glClear');
  Pointer(glViewport) := GL('glViewport');
  Pointer(glGenTextures) := GL('glGenTextures');
  Pointer(glDeleteTextures) := GL('glDeleteTextures');
  Pointer(glBindTexture) := GL('glBindTexture');
  Pointer(glActiveTexture) := GL('glActiveTexture');
  Pointer(glTexParameteri) := GL('glTexParameteri');
  Pointer(glPixelStorei) := GL('glPixelStorei');
  Pointer(glTexImage2D) := GL('glTexImage2D');
  Pointer(glTexSubImage2D) := GL('glTexSubImage2D');
  Pointer(glGenBuffers) := GL('glGenBuffers');
  Pointer(glBindBuffer) := GL('glBindBuffer');
  Pointer(glBufferData) := GL('glBufferData');
  Pointer(glCreateShader) := GL('glCreateShader');
  Pointer(glShaderSource) := GL('glShaderSource');
  Pointer(glCompileShader) := GL('glCompileShader');
  Pointer(glGetShaderiv) := GL('glGetShaderiv');
  Pointer(glGetShaderInfoLog) := GL('glGetShaderInfoLog');
  Pointer(glCreateProgram) := GL('glCreateProgram');
  Pointer(glAttachShader) := GL('glAttachShader');
  Pointer(glLinkProgram) := GL('glLinkProgram');
  Pointer(glGetProgramiv) := GL('glGetProgramiv');
  Pointer(glGetProgramInfoLog) := GL('glGetProgramInfoLog');
  Pointer(glUseProgram) := GL('glUseProgram');
  Pointer(glGetAttribLocation) := GL('glGetAttribLocation');
  Pointer(glGetUniformLocation) := GL('glGetUniformLocation');
  Pointer(glEnableVertexAttribArray) := GL('glEnableVertexAttribArray');
  Pointer(glVertexAttribPointer) := GL('glVertexAttribPointer');
  Pointer(glUniform1i) := GL('glUniform1i');
  Pointer(glUniform1f) := GL('glUniform1f');
  Pointer(glUniform3f) := GL('glUniform3f');
  Pointer(glUniformMatrix4fv) := GL('glUniformMatrix4fv');
  Pointer(glDrawArrays) := GL('glDrawArrays');
  Pointer(glEnable) := GL('glEnable');
  Pointer(glDisable) := GL('glDisable');
  Pointer(glDepthFunc) := GL('glDepthFunc');
  Pointer(glCullFace) := GL('glCullFace');
  Pointer(glFrontFace) := GL('glFrontFace');
  Pointer(glBlendFunc) := GL('glBlendFunc');
  Pointer(glReadPixels) := GL('glReadPixels');
  Pointer(glDeleteBuffers) := GL('glDeleteBuffers');
  LoadGLES2 := not missing;
end;

end.
