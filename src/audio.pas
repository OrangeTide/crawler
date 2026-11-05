unit audio;

{** Software audio mixer with sound-effect and music channels.

  One SDL audio callback mixes several sound-effect channels and a music
  track into 16-bit stereo. Sound effects are short PCM buffers built
  procedurally at startup, so no sound files ship for them. Music is a
  tracker module (a sample bank plus a pattern sequence) rendered by
  libxmp, one track at a time, read from the pak as a lump. This is the
  sampled-sequence model the PlayStation SPU used, so the same module
  files feed a VAB/SEQ bake on that target.

  Both halves are optional and independent. If the audio device will not
  open the game runs silently. If libxmp is absent the sound effects
  still play and only music is a no-op. Every call here is then harmless. }

{$mode objfpc}{$H+}

interface

uses
  pak;

const
  SFX_SELECT = 0;
  SFX_HIT    = 1;
  SFX_MISS   = 2;
  SFX_DOOR   = 3;
  SFX_PICK   = 4;
  SFX_FOE    = 5;
  SFX_DOWN   = 6;
  SFX_COUNT  = 7;

  MUS_NONE    = 0;
  MUS_TITLE   = 1;
  MUS_TOWN    = 2;
  MUS_DUNGEON = 3;
  MUS_COMBAT  = 4;

function AudioInit(const p: TPak): boolean;
procedure AudioShutdown;
procedure PlaySfx(id: longint);
procedure PlayMusic(track: longint);
procedure StopMusic;
procedure SetAudioVolumes(master, music, sfx: longint);

implementation

uses
  sdl2min, xmpmin;

const
  SR = 22050;         { sample rate }
  NSFXCHAN = 6;

type
  TSamples = array of smallint;

var
  devId: UInt32 = 0;
  haveAudio: boolean = false;

  sfxBuf: array[0 .. SFX_COUNT - 1] of TSamples;

  sfxCh: array[0 .. NSFXCHAN - 1] of record
    active: boolean;
    id, pos: longint;
  end;

  masterV, musicV, sfxV: longint;   { 0..100 }

  { music replayer }
  musPak: TPak;                     { lumps the module tracks live in }
  xmpCtx: Txmp_context = nil;
  haveMusic: boolean = false;       { libxmp present and a context is live }
  musLoaded: boolean = false;       { a module is loaded in the context }
  musTrack: longint = MUS_NONE;
  musBuf: array of smallint;        { scratch the callback renders a block into }

{ ---- SFX synthesis ---- }

procedure MakeTone(var buf: TSamples; durMs, freq, amp: longint; decay: boolean);
var
  i, n: longint;
  t, env, ph: double;
begin
  n := (SR * durMs) div 1000;
  SetLength(buf, n);
  ph := 0;
  for i := 0 to n - 1 do begin
    t := i / n;
    if decay then env := 1.0 - t else env := 1.0;
    ph := ph + freq / SR;
    if (ph - trunc(ph)) < 0.5 then          { square wave }
      buf[i] := Round(amp * env)
    else
      buf[i] := -Round(amp * env);
  end;
end;

procedure MakeNoise(var buf: TSamples; durMs, amp: longint);
var
  i, n: longint;
  seed: UInt32;
  v: longint;
begin
  n := (SR * durMs) div 1000;
  SetLength(buf, n);
  seed := $ACE1;
  for i := 0 to n - 1 do begin
    seed := seed * 1103515245 + 12345;
    v := longint((seed shr 16) and $FFFF) - 32768;
    buf[i] := Round((v / 32768.0) * amp * (1.0 - i / n));
  end;
end;

procedure MakeChime(var buf: TSamples);
var
  a, b: TSamples;
  i: longint;
begin
  MakeTone(a, 70, 660, 5000, false);
  MakeTone(b, 110, 990, 5000, true);
  SetLength(buf, Length(a) + Length(b));
  for i := 0 to High(a) do buf[i] := a[i];
  for i := 0 to High(b) do buf[Length(a) + i] := b[i];
end;

procedure BuildSfx;
begin
  MakeTone(sfxBuf[SFX_SELECT], 40, 880, 4000, true);
  MakeNoise(sfxBuf[SFX_HIT], 120, 7000);
  MakeTone(sfxBuf[SFX_MISS], 90, 300, 3500, true);
  MakeTone(sfxBuf[SFX_DOOR], 180, 150, 5000, true);
  MakeChime(sfxBuf[SFX_PICK]);
  MakeNoise(sfxBuf[SFX_FOE], 220, 6000);
  MakeTone(sfxBuf[SFX_DOWN], 260, 200, 5000, true);
end;

{ ---- music tracks ---- }

const
  { each track names its module lump in the pak; '' means no track }
  MusLumps: array[MUS_NONE .. MUS_COMBAT] of string =
    ('', 'MUS_TITLE', 'MUS_TOWN', 'MUS_DUNGEON', 'MUS_COMBAT');

{ ---- the mixer callback ---- }

procedure AudioCallback(userdata: Pointer; stream: PUInt8; len: Int32); cdecl;
var
  frames, i, c, acc, sv, mixL, mixR: longint;
  musL, musR, musHave: longint;
  out16: PUInt8;
begin
  out16 := stream;
  frames := len div 4;   { S16 stereo }

  { Render one block of the module into the scratch buffer. libxmp fills
    it as interleaved S16 stereo and loops the module itself (loop = 0),
    so there is never a gap or a click at the loop point. }
  musHave := 0;
  if (musTrack <> MUS_NONE) and musLoaded and (frames * 2 <= Length(musBuf)) then
    if xmp_play_buffer(xmpCtx, @musBuf[0], frames * 4, 0) = 0 then
      musHave := 1;

  for i := 0 to frames - 1 do begin
    { sound effects mix to one centred value }
    acc := 0;
    for c := 0 to NSFXCHAN - 1 do
      if sfxCh[c].active then begin
        if sfxCh[c].pos < Length(sfxBuf[sfxCh[c].id]) then begin
          acc := acc + sfxBuf[sfxCh[c].id][sfxCh[c].pos];
          inc(sfxCh[c].pos);
        end else
          sfxCh[c].active := false;
      end;
    sv := (acc * sfxV) div 100;

    { music keeps its own stereo image }
    if musHave = 1 then begin
      musL := (musBuf[i * 2]     * musicV) div 100;
      musR := (musBuf[i * 2 + 1] * musicV) div 100;
    end else begin
      musL := 0; musR := 0;
    end;

    mixL := ((sv + musL) * masterV) div 100;
    mixR := ((sv + musR) * masterV) div 100;
    if mixL > 32767 then mixL := 32767 else if mixL < -32768 then mixL := -32768;
    if mixR > 32767 then mixR := 32767 else if mixR < -32768 then mixR := -32768;

    out16[i * 4]     := mixL and $FF;
    out16[i * 4 + 1] := (mixL shr 8) and $FF;
    out16[i * 4 + 2] := mixR and $FF;
    out16[i * 4 + 3] := (mixR shr 8) and $FF;
  end;
end;

{ ---- public ---- }

function AudioInit(const p: TPak): boolean;
var
  want, got: TSDL_AudioSpec;
  i: longint;
begin
  AudioInit := false;
  masterV := 80; musicV := 55; sfxV := 90;
  musPak := p;
  BuildSfx;
  for i := 0 to NSFXCHAN - 1 do sfxCh[i].active := false;

  { Audio is optional: init its subsystem separately so a machine with
    no sound device still runs the game silently. }
  if SDL_InitSubSystem(SDL_INIT_AUDIO) <> 0 then
    exit;

  FillChar(want, SizeOf(want), 0);
  want.freq := SR;
  want.format := AUDIO_S16LSB;
  want.channels := 2;
  want.samples := 1024;
  want.callback := @AudioCallback;
  want.userdata := nil;

  devId := SDL_OpenAudioDevice(nil, 0, @want, @got, 0);
  if devId = 0 then
    exit;
  haveAudio := true;

  { Music is optional on top of that: without libxmp the SFX still play.
    Size the render scratch to the device block, two samples a frame. }
  if LoadXmp then begin
    xmpCtx := xmp_create_context;
    if xmpCtx <> nil then begin
      SetLength(musBuf, (got.samples + 64) * 2);
      haveMusic := true;
    end else
      UnloadXmp;
  end;

  SDL_PauseAudioDevice(devId, 0);   { start playing }
  AudioInit := true;
end;

procedure AudioShutdown;
begin
  if haveAudio then begin
    SDL_PauseAudioDevice(devId, 1);   { stop the callback before teardown }
    if haveMusic then begin
      if musLoaded then begin
        xmp_end_player(xmpCtx);
        xmp_release_module(xmpCtx);
        musLoaded := false;
      end;
      xmp_free_context(xmpCtx);
      xmpCtx := nil;
      haveMusic := false;
      UnloadXmp;
    end;
    SDL_CloseAudioDevice(devId);
    haveAudio := false;
  end;
end;

procedure PlaySfx(id: longint);
var
  c, free: longint;
begin
  if not haveAudio then exit;
  if (id < 0) or (id >= SFX_COUNT) then exit;
  SDL_LockAudioDevice(devId);
  free := -1;
  for c := 0 to NSFXCHAN - 1 do
    if not sfxCh[c].active then begin free := c; break; end;
  if free < 0 then free := 0;   { steal channel 0 }
  sfxCh[free].active := true;
  sfxCh[free].id := id;
  sfxCh[free].pos := 0;
  SDL_UnlockAudioDevice(devId);
end;

{ Swap the module behind the lock, so the callback never renders a
  half-loaded context. Loading itself is not realtime safe, which is why
  it happens here on the caller's thread and never in the callback. }
procedure PlayMusic(track: longint);
var
  blob: TByteArray;
begin
  if not haveMusic then exit;
  if track = musTrack then exit;
  SDL_LockAudioDevice(devId);

  musTrack := MUS_NONE;   { stop mixing while the context changes }
  if musLoaded then begin
    xmp_end_player(xmpCtx);
    xmp_release_module(xmpCtx);
    musLoaded := false;
  end;

  if (track >= Low(MusLumps)) and (track <= High(MusLumps))
     and (MusLumps[track] <> '')
     and PakGet(musPak, MusLumps[track], blob) and (Length(blob) > 0) then
    if xmp_load_module_from_memory(xmpCtx, @blob[0], Length(blob)) = 0 then begin
      { 0 = 16-bit signed stereo at the mixer rate }
      if xmp_start_player(xmpCtx, SR, 0) = 0 then begin
        musLoaded := true;
        musTrack := track;
      end else
        xmp_release_module(xmpCtx);
    end;

  SDL_UnlockAudioDevice(devId);
end;

procedure StopMusic;
begin
  if not haveMusic then exit;
  SDL_LockAudioDevice(devId);
  musTrack := MUS_NONE;
  if musLoaded then begin
    xmp_end_player(xmpCtx);
    xmp_release_module(xmpCtx);
    musLoaded := false;
  end;
  SDL_UnlockAudioDevice(devId);
end;

procedure SetAudioVolumes(master, music, sfx: longint);
begin
  masterV := master; musicV := music; sfxV := sfx;
end;

end.
