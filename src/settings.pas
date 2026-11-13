unit settings;

{** Player settings, stored in a small text file next to the save.

  Holds the volumes, the difficulty and accessibility choices, and the
  rebindable key table. The file is a plain list of "key value" lines, so
  an unknown or missing key simply keeps its default and the format can
  grow without breaking old files. Loading fills defaults first, then
  overlays whatever the file carries; applying pushes the live values into
  the audio mixer and the combat rules. }

{$mode objfpc}{$H+}

interface

const
  SETTINGS_VERSION = 1;

  { combat speed choices: the pause between beats is scaled by these }
  CS_SLOW   = 0;
  CS_NORMAL = 1;
  CS_FAST   = 2;

var
  SetPermadeath: boolean;   { a slain member stays dead; no temple revival }
  SetCriticals: boolean;    { the AX&X natural 20/1 and max-damage crit rules }
  SetPrepared: boolean;     { casters ready a per-level subset of spells per rest }
  SetCombatSpeed: longint;  { CS_* }
  SetGLTrueColour: boolean; { GPU kit trim in full direct colour, not the CLUT }

procedure SettingsDefaults;
procedure SettingsApply;             { push the live values into the engine }
function SettingsPath: string;
function SettingsLoad: boolean;      { load from the standard path, then apply }
function SettingsSave: boolean;      { save to the standard path }
function SettingsLoadFrom(const fn: string): boolean;  { no apply, for tests }
function SettingsSaveTo(const fn: string): boolean;
function CombatSpeedScale(cs: longint): double;

implementation

uses
  sysutils, classes, gamestate, audio, combatstate, keymap, apppaths;

procedure SettingsDefaults;
begin
  volMaster := 80;
  volMusic := 55;
  volSfx := 90;
  SetPermadeath := false;   { the temple can raise the dead unless turned on }
  SetCriticals := true;
  SetPrepared := false;     { off by default: cast any known spell at will }
  SetCombatSpeed := CS_NORMAL;
  SetGLTrueColour := false;   { default to the per-tileset CLUT (PS1) look }
  KeyBindDefaults;
end;

function CombatSpeedScale(cs: longint): double;
begin
  case cs of
    CS_SLOW: CombatSpeedScale := 1.6;
    CS_FAST: CombatSpeedScale := 0.5;
  else CombatSpeedScale := 1.0;
  end;
end;

procedure SettingsApply;
begin
  SetAudioVolumes(volMaster, volMusic, volSfx);
  OptCriticals := SetCriticals;
  OptPrepared := SetPrepared;
  CombatBeatScale := CombatSpeedScale(SetCombatSpeed);
  { permadeath is read straight from SetPermadeath by the temple service }
end;

function SettingsPath: string;
begin
  SettingsPath := UserFilePath('settings.cfg');
end;

function ClampVol(v: longint): longint;
begin
  if v < 0 then v := 0;
  if v > 100 then v := 100;
  ClampVol := v;
end;

function SettingsSaveTo(const fn: string): boolean;
var
  lines: TStringList;
  a: TGameAction;
begin
  SettingsSaveTo := false;
  lines := TStringList.Create;
  try
    lines.Add('version ' + IntToStr(SETTINGS_VERSION));
    lines.Add('volmaster ' + IntToStr(volMaster));
    lines.Add('volmusic ' + IntToStr(volMusic));
    lines.Add('volsfx ' + IntToStr(volSfx));
    lines.Add('permadeath ' + IntToStr(ord(SetPermadeath)));
    lines.Add('criticals ' + IntToStr(ord(SetCriticals)));
    lines.Add('prepared ' + IntToStr(ord(SetPrepared)));
    lines.Add('combatspeed ' + IntToStr(SetCombatSpeed));
    lines.Add('gltruecolour ' + IntToStr(ord(SetGLTrueColour)));
    for a := Low(TGameAction) to High(TGameAction) do
      lines.Add('key.' + ActionId(a) + ' ' + IntToStr(KeyBind[a]));
    try
      lines.SaveToFile(fn);
      SettingsSaveTo := true;
    except
    end;
  finally
    lines.Free;
  end;
end;

function SettingsSave: boolean;
begin
  SettingsSave := SettingsSaveTo(SettingsPath);
end;

{ Split a line into its key and integer value. Returns false on a blank or
  malformed line. }
function ParseLine(const s: string; out key: string; out num: longint): boolean;
var
  sp, code: longint;
  t: string;
begin
  ParseLine := false;
  t := Trim(s);
  if (t = '') or (t[1] = '#') then exit;
  sp := Pos(' ', t);
  if sp <= 0 then exit;
  key := LowerCase(Copy(t, 1, sp - 1));
  Val(Trim(Copy(t, sp + 1, Length(t))), num, code);
  if code <> 0 then exit;
  ParseLine := true;
end;

function SettingsLoadFrom(const fn: string): boolean;
var
  lines: TStringList;
  i, v, ai: longint;
  key: string;
begin
  SettingsLoadFrom := false;
  SettingsDefaults;   { missing keys keep their defaults }
  if not FileExists(fn) then exit;
  lines := TStringList.Create;
  try
    try
      lines.LoadFromFile(fn);
    except
      exit;
    end;
    for i := 0 to lines.Count - 1 do begin
      if not ParseLine(lines[i], key, v) then continue;
      if key = 'volmaster' then volMaster := ClampVol(v)
      else if key = 'volmusic' then volMusic := ClampVol(v)
      else if key = 'volsfx' then volSfx := ClampVol(v)
      else if key = 'permadeath' then SetPermadeath := v <> 0
      else if key = 'criticals' then SetCriticals := v <> 0
      else if key = 'prepared' then SetPrepared := v <> 0
      else if key = 'combatspeed' then begin
        if (v >= CS_SLOW) and (v <= CS_FAST) then SetCombatSpeed := v;
      end
      else if key = 'gltruecolour' then SetGLTrueColour := v <> 0
      else if Copy(key, 1, 4) = 'key.' then begin
        ai := ActionById(Copy(key, 5, Length(key)));
        if ai >= 0 then KeyBind[TGameAction(ai)] := v;
      end;
    end;
    SettingsLoadFrom := true;
  finally
    lines.Free;
  end;
end;

function SettingsLoad: boolean;
begin
  SettingsLoad := SettingsLoadFrom(SettingsPath);
  SettingsApply;
end;

initialization
  SettingsDefaults;

end.
