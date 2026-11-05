unit xmpmin;

{** Minimal libxmp binding, loaded at runtime.

  libxmp is a module replayer: it reads a tracker module (a bank of
  sampled instruments plus a pattern sequence, as in .xm, .it, .s3m or
  .mod) and renders it to PCM. That is the same sampled-sequence model
  the PlayStation SPU used for music, so one authoring format serves the
  software-mixed targets here and a VAB/SEQ bake on hardware.

  Like sdl2min this dlopens the shared library and binds only the few
  entry points the mixer needs. If the library is absent LoadXmp returns
  false and the caller runs without music. }

{$mode objfpc}{$H+}

interface

const
  { xmp_start_player format flags. 0 is the default: 16-bit signed,
    stereo, interleaved, which is what the mixer wants. }
  XMP_FORMAT_8BIT     = 1 shl 0;
  XMP_FORMAT_UNSIGNED = 1 shl 1;
  XMP_FORMAT_MONO     = 1 shl 2;

type
  Txmp_context = Pointer;

  Txmp_create_context_fn = function: Txmp_context; cdecl;
  Txmp_free_context_fn   = procedure(c: Txmp_context); cdecl;
  Txmp_load_module_from_memory_fn =
    function(c: Txmp_context; mem: Pointer; size: longint): longint; cdecl;
  Txmp_release_module_fn = procedure(c: Txmp_context); cdecl;
  Txmp_start_player_fn   = function(c: Txmp_context; rate, format: longint): longint; cdecl;
  Txmp_end_player_fn     = procedure(c: Txmp_context); cdecl;
  Txmp_play_buffer_fn    =
    function(c: Txmp_context; buffer: Pointer; size, loop: longint): longint; cdecl;

var
  xmp_create_context: Txmp_create_context_fn;
  xmp_free_context: Txmp_free_context_fn;
  xmp_load_module_from_memory: Txmp_load_module_from_memory_fn;
  xmp_release_module: Txmp_release_module_fn;
  xmp_start_player: Txmp_start_player_fn;
  xmp_end_player: Txmp_end_player_fn;
  xmp_play_buffer: Txmp_play_buffer_fn;

{ Load the library and bind the entry points. false if it is not present
  or a symbol is missing, in which case the bound pointers stay nil. }
function LoadXmp: boolean;
procedure UnloadXmp;

implementation

uses
  dynlibs;

const
  XMP_SONAMES: array[0 .. 3] of string = (
    'libxmp.so.4', 'libxmp.so', 'libxmp-4.dll', 'libxmp.dll');

var
  libHandle: TLibHandle = NilHandle;

function LoadXmp: boolean;
var
  i: longint;

  function Bind(const name: string): Pointer;
  begin
    Bind := GetProcedureAddress(libHandle, name);
    if Bind = nil then begin
      writeln(StdErr, 'xmpmin: missing symbol ', name);
      UnloadLibrary(libHandle);
      libHandle := NilHandle;
    end;
  end;

begin
  LoadXmp := false;
  for i := 0 to High(XMP_SONAMES) do begin
    libHandle := LoadLibrary(XMP_SONAMES[i]);
    if libHandle <> NilHandle then
      break;
  end;
  if libHandle = NilHandle then
    exit;

  xmp_create_context := Txmp_create_context_fn(Bind('xmp_create_context'));
  xmp_free_context := Txmp_free_context_fn(Bind('xmp_free_context'));
  xmp_load_module_from_memory :=
    Txmp_load_module_from_memory_fn(Bind('xmp_load_module_from_memory'));
  xmp_release_module := Txmp_release_module_fn(Bind('xmp_release_module'));
  xmp_start_player := Txmp_start_player_fn(Bind('xmp_start_player'));
  xmp_end_player := Txmp_end_player_fn(Bind('xmp_end_player'));
  xmp_play_buffer := Txmp_play_buffer_fn(Bind('xmp_play_buffer'));

  { Bind clears the handle on the first missing symbol. }
  LoadXmp := libHandle <> NilHandle;
end;

procedure UnloadXmp;
begin
  if libHandle <> NilHandle then begin
    UnloadLibrary(libHandle);
    libHandle := NilHandle;
  end;
end;

end.
