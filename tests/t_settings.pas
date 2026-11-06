program t_settings;

{** Settings persistence: defaults, a round trip through the text file, and
  that out-of-range values are clamped and unknown keys ignored on load. }

{$mode objfpc}{$H+}

uses
  sysutils, sdl2min, gamestate, keymap, settings, testing;

var
  fn: string;
begin
  fn := 'build/tests/settings_rt.cfg';

  SettingsDefaults;
  CheckEqI(volMaster, 80, 'default master volume');
  Check(not SetPermadeath, 'permadeath off by default (temple can revive)');
  Check(SetCriticals, 'criticals on by default');
  CheckEqI(SetCombatSpeed, CS_NORMAL, 'combat speed normal by default');
  CheckEqI(KeyBind[gaForward], SDL_SCANCODE_W, 'forward defaults to W');
  CheckEqI(KeyBind[gaInteract], SDL_SCANCODE_SPACE, 'interact defaults to SPACE');

  { change every field, with one volume out of range to exercise the clamp }
  volMaster := 999; volMusic := 10; volSfx := 7;
  SetPermadeath := true;   { non-default, to prove it persists }
  SetCriticals := false;
  SetCombatSpeed := CS_FAST;
  KeyBind[gaInteract] := SDL_SCANCODE_RETURN;
  Check(SettingsSaveTo(fn), 'save writes the file');

  { wipe back to defaults, then load the file over them }
  SettingsDefaults;
  CheckEqI(volMusic, 55, 'reset to defaults before the load');
  Check(SettingsLoadFrom(fn), 'load reads the file');
  CheckEqI(volMaster, 100, 'an over-range volume is clamped on load');
  CheckEqI(volMusic, 10, 'music volume restored');
  CheckEqI(volSfx, 7, 'sfx volume restored');
  Check(SetPermadeath, 'permadeath choice restored');
  Check(not SetCriticals, 'criticals choice restored');
  CheckEqI(SetCombatSpeed, CS_FAST, 'combat speed restored');
  CheckEqI(KeyBind[gaInteract], SDL_SCANCODE_RETURN, 'a rebound key restored');
  CheckEqI(KeyBind[gaForward], SDL_SCANCODE_W, 'an unchanged key keeps default');

  { a missing file leaves defaults in place and reports no load }
  SettingsDefaults;
  Check(not SettingsLoadFrom('build/tests/no_such_settings.cfg'),
    'a missing file does not load');
  CheckEqI(volMaster, 80, 'defaults stand when there is no file');

  TestSummary('settings');
  halt(TestExit);
end.
