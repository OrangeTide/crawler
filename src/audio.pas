unit audio;

{** Software audio mixer with sound-effect and music channels.

  One SDL audio callback mixes several sound-effect channels and a music
  channel into 16-bit stereo. Sound effects are short PCM buffers built
  procedurally at startup, so no audio files ship. Music is a tiny
  square-wave synth playing built-in note sequences, one track at a
  time. This keeps the download small while still giving layered sound.

  If the audio device will not open the game runs silently; every call
  here is then a harmless no-op. }

{$mode objfpc}{$H+}

interface

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

function AudioInit: boolean;
procedure AudioShutdown;
procedure PlaySfx(id: longint);
procedure PlayMusic(track: longint);
procedure StopMusic;
procedure SetAudioVolumes(master, music, sfx: longint);

implementation

uses
  sdl2min;

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

  { music synth }
  musTrack: longint = MUS_NONE;
  musSeq: array of shortint;        { semitone offsets from A4; -128 = rest }
  musPos: longint;
  musSampInNote: longint;
  musPhase: double;
  noteSamples: longint;

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

{ ---- music sequences ---- }

const
  R = -128;   { rest }

  SEQ_TITLE: array[0 .. 7] of shortint = (0, 4, 7, 12, 7, 4, 0, R);
  SEQ_TOWN: array[0 .. 7] of shortint = (0, 2, 4, 5, 4, 2, 0, R);
  SEQ_DUNGEON: array[0 .. 7] of shortint = (-5, -5, -2, -5, -7, -5, R, R);
  SEQ_COMBAT: array[0 .. 7] of shortint = (0, 0, 3, 0, 5, 3, 0, R);

procedure SetSeq(const s: array of shortint);
var i: longint;
begin
  SetLength(musSeq, Length(s));
  for i := 0 to High(s) do musSeq[i] := s[i];
  musPos := 0;
  musSampInNote := 0;
  musPhase := 0;
end;

function NoteFreq(semi: shortint): double;
begin
  NoteFreq := 220.0 * Exp(semi * 0.69314718 / 12.0);  { 2^(semi/12) from A3 }
end;

{ ---- the mixer callback ---- }

procedure AudioCallback(userdata: Pointer; stream: PUInt8; len: Int32); cdecl;
var
  frames, i, c, acc, mv, sv, mix: longint;
  semi: shortint;
  out16: PUInt8;
  musv: longint;
  freq: double;
begin
  out16 := stream;
  frames := len div 4;   { S16 stereo }
  for i := 0 to frames - 1 do begin
    acc := 0;
    { sound effects }
    for c := 0 to NSFXCHAN - 1 do
      if sfxCh[c].active then begin
        if sfxCh[c].pos < Length(sfxBuf[sfxCh[c].id]) then begin
          acc := acc + sfxBuf[sfxCh[c].id][sfxCh[c].pos];
          inc(sfxCh[c].pos);
        end else
          sfxCh[c].active := false;
      end;
    sv := (acc * sfxV) div 100;

    { music }
    musv := 0;
    if (musTrack <> MUS_NONE) and (Length(musSeq) > 0) then begin
      semi := musSeq[musPos];
      if semi <> R then begin
        freq := NoteFreq(semi);
        musPhase := musPhase + freq / SR;
        if (musPhase - trunc(musPhase)) < 0.5 then musv := 2600 else musv := -2600;
      end;
      inc(musSampInNote);
      if musSampInNote >= noteSamples then begin
        musSampInNote := 0;
        musPos := (musPos + 1) mod Length(musSeq);
      end;
    end;
    mv := (musv * musicV) div 100;

    mix := ((sv + mv) * masterV) div 100;
    if mix > 32767 then mix := 32767;
    if mix < -32768 then mix := -32768;

    out16[i * 4]     := mix and $FF;
    out16[i * 4 + 1] := (mix shr 8) and $FF;
    out16[i * 4 + 2] := mix and $FF;
    out16[i * 4 + 3] := (mix shr 8) and $FF;
  end;
end;

{ ---- public ---- }

function AudioInit: boolean;
var
  want, got: TSDL_AudioSpec;
  i: longint;
begin
  AudioInit := false;
  masterV := 80; musicV := 55; sfxV := 90;
  noteSamples := (SR * 18) div 100;   { ~0.18s per note }
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
  SDL_PauseAudioDevice(devId, 0);   { start playing }
  AudioInit := true;
end;

procedure AudioShutdown;
begin
  if haveAudio then begin
    SDL_PauseAudioDevice(devId, 1);
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

procedure PlayMusic(track: longint);
begin
  if not haveAudio then exit;
  if track = musTrack then exit;
  SDL_LockAudioDevice(devId);
  musTrack := track;
  case track of
    MUS_TITLE:   SetSeq(SEQ_TITLE);
    MUS_TOWN:    SetSeq(SEQ_TOWN);
    MUS_DUNGEON: SetSeq(SEQ_DUNGEON);
    MUS_COMBAT:  SetSeq(SEQ_COMBAT);
  else
    musTrack := MUS_NONE;
  end;
  SDL_UnlockAudioDevice(devId);
end;

procedure StopMusic;
begin
  if not haveAudio then exit;
  SDL_LockAudioDevice(devId);
  musTrack := MUS_NONE;
  SDL_UnlockAudioDevice(devId);
end;

procedure SetAudioVolumes(master, music, sfx: longint);
begin
  masterV := master; musicV := music; sfxV := sfx;
end;

end.
