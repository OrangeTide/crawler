unit optionsui;

{** The options screen: master, music and SFX volumes, the permadeath and
  critical-hit toggles, the combat speed, and a door to the key-binding
  sub-screen. Changes apply and persist at once. }

{$mode objfpc}{$H+}

interface

procedure OptionsRender;
procedure OptionsKeyDown(scancode: longint);

implementation

uses
  sysutils, sdl2min, gfx, uihelp, audio, gamestate, settings;

const
  { the options rows, in order down the screen }
  OPT_MASTER = 0;
  OPT_MUSIC  = 1;
  OPT_SFX    = 2;
  OPT_DEATH  = 3;
  OPT_CRIT   = 4;
  OPT_PREPARED = 5;
  OPT_SPEED  = 6;
  OPT_COLOR  = 7;
  OPT_KEYS   = 8;
  OPT_LAST   = 8;

function SpeedName(cs: longint): string;
begin
  case cs of
    CS_SLOW: SpeedName := 'SLOW';
    CS_FAST: SpeedName := 'FAST';
  else SpeedName := 'NORMAL';
  end;
end;

procedure OptionsRender;
const
  LABELS: array[OPT_MASTER .. OPT_LAST] of string =
    ('MASTER', 'MUSIC', 'SFX', 'PERMADEATH', 'CRITICALS', 'PREPARE SPELLS',
     'COMBAT SPEED', 'TEXTURE COLOR', 'KEY BINDINGS');
var
  i, y, v: longint;
  c: TColor;

  procedure OnOff(flag: boolean);
  begin
    if flag then DrawText(170, y, 'ON', c) else DrawText(170, y, 'OFF', c);
  end;

begin
  ClearFB(RGB(12, 12, 16));
  DrawCenter(20, 'OPTIONS', RGB(220, 200, 120));
  y := 56;
  for i := OPT_MASTER to OPT_LAST do begin
    if i = optSel then c := RGB(240, 230, 150) else c := RGB(160, 160, 140);
    DrawText(50, y, LABELS[i], c);
    case i of
      OPT_MASTER, OPT_MUSIC, OPT_SFX: begin
        case i of
          OPT_MASTER: v := volMaster;
          OPT_MUSIC:  v := volMusic;
        else v := volSfx;
        end;
        FillRect(170, y, 102, 7, RGB(40, 40, 46));
        FillRect(171, y + 1, v, 5, RGB(90, 160, 110));
        DrawText(280, y, IntToStr(v), c);
      end;
      OPT_DEATH: OnOff(SetPermadeath);
      OPT_CRIT:  OnOff(SetCriticals);
      OPT_PREPARED: OnOff(SetPrepared);
      OPT_SPEED: DrawText(170, y, SpeedName(SetCombatSpeed), c);
      OPT_COLOR: if SetGLTrueColour then DrawText(170, y, 'DIRECT', c)
                 else DrawText(170, y, 'CLUT (PS1)', c);
      OPT_KEYS:  DrawText(170, y, 'EDIT >', c);
    end;
    inc(y, 18);
  end;
  DrawCenter(FBH - 20, 'ARROWS ADJUST   ESC BACK', RGB(130, 140, 110));
end;

{ Nudge a volume by delta and clamp it to 0..100. }
function ClampVol(v: longint): longint;
begin
  if v < 0 then v := 0;
  if v > 100 then v := 100;
  ClampVol := v;
end;

procedure OptionsKeyDown(scancode: longint);
var
  dir: longint;
begin
  dir := 0;
  case scancode of
    SDL_SCANCODE_UP:   begin if optSel > 0 then dec(optSel); exit; end;
    SDL_SCANCODE_DOWN: begin if optSel < OPT_LAST then inc(optSel); exit; end;
    SDL_SCANCODE_LEFT:  dir := -1;
    SDL_SCANCODE_RIGHT: dir := 1;
    SDL_SCANCODE_RETURN: dir := 1;   { enter opens the key-binding sub-screen }
    SDL_SCANCODE_ESCAPE: begin SettingsSave; State := gsTitle; exit; end;
  end;
  if dir = 0 then exit;
  { the key-bindings row is a door, not a value }
  if optSel = OPT_KEYS then begin
    if dir > 0 then begin
      kbSel := 0; kbCapturing := false; State := gsKeybind;
    end;
    exit;
  end;
  case optSel of
    OPT_MASTER: volMaster := ClampVol(volMaster + dir * 10);
    OPT_MUSIC:  volMusic  := ClampVol(volMusic + dir * 10);
    OPT_SFX:    volSfx    := ClampVol(volSfx + dir * 10);
    OPT_DEATH:  SetPermadeath := not SetPermadeath;
    OPT_CRIT:   SetCriticals := not SetCriticals;
    OPT_PREPARED: SetPrepared := not SetPrepared;
    OPT_COLOR:  SetGLTrueColour := not SetGLTrueColour;
    OPT_SPEED: begin
      SetCombatSpeed := SetCombatSpeed + dir;
      if SetCombatSpeed < CS_SLOW then SetCombatSpeed := CS_SLOW;
      if SetCombatSpeed > CS_FAST then SetCombatSpeed := CS_FAST;
    end;
  end;
  SettingsApply;        { push volumes and the combat rules live }
  SettingsSave;         { persist the change at once }
  PlaySfx(SFX_SELECT);
end;

end.
