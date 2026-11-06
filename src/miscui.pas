unit miscui;

{** The small UI states: the full-map overlay toggle, the journal, the
  game-over and victory screens, and the audio options. Each is a render
  and a key handler with little state of its own. }

{$mode objfpc}{$H+}

interface

procedure FullMapRender;
procedure FullMapKeyDown(scancode: longint);
procedure FullMapMouseMotion(xrel, yrel: longint);
procedure FullMapMouseButton(button: longint);
procedure JournalRender;
procedure JournalKeyDown(scancode: longint);
procedure GameOverRender;
procedure GameOverKeyDown(scancode: longint);
procedure OptionsRender;
procedure OptionsKeyDown(scancode: longint);
procedure KeybindRender;
procedure KeybindKeyDown(scancode: longint);
procedure VictoryRender;
procedure VictoryKeyDown(scancode: longint);

implementation

uses
  sysutils, sdl2min, gfx, flags, audio, uihelp, gamestate, world, hud,
  exploreui, pursuit, settings, keymap;

procedure FullMapRender;
{** The full map with any hunters on this map marked over it, so the player
  can see a pursuer closing in. }
var
  i: longint;
begin
  DrawFullMap;
  for i := 0 to High(Pursuers) do
    if Pursuers[i].active and (Pursuers[i].map = CurMapName) then
      FullMapMark(Pursuers[i].x, Pursuers[i].y, RGB(230, 40, 160));
end;

procedure FullMapKeyDown(scancode: longint);
begin
  case scancode of
    SDL_SCANCODE_TAB, SDL_SCANCODE_ESCAPE, SDL_SCANCODE_M:
      State := gsExplore;
  end;
end;

procedure FullMapMouseMotion(xrel, yrel: longint);
{** Drift the shared cursor over the map, clamped to the screen. }
begin
  cursorX := cursorX + xrel;
  cursorY := cursorY + yrel;
  if cursorX < 0 then cursorX := 0;
  if cursorX > FBW - 1 then cursorX := FBW - 1;
  if cursorY < 0 then cursorY := 0;
  if cursorY > FBH - 1 then cursorY := FBH - 1;
end;

procedure FullMapMouseButton(button: longint);
{** Left click a tile to auto-travel there on the current map, then drop
  back to the first-person view to walk it. }
var
  tx, ty: longint;
begin
  if button <> SDL_BUTTON_LEFT then exit;
  if FullMapTileAt(cursorX, cursorY, tx, ty) then begin
    StartAutoTravel(CurMapName, tx, ty);
    State := gsExplore;
  end;
end;

procedure JournalRender;
var
  i, y: longint;
begin
  ClearFB(RGB(10, 10, 16));
  DrawText(12, 10, 'JOURNAL', RGB(220, 200, 120));
  if Length(Journal) = 0 then
    DrawText(16, 30, 'No quests recorded yet.', RGB(150, 150, 130))
  else begin
    y := 30;
    for i := 0 to High(Journal) do begin
      DrawWrapped(16, y, 48, '- ' + Journal[i], RGB(195, 200, 180));
      inc(y, 22);
    end;
  end;
  DrawText(12, FBH - 14, 'J OR ESC TO CLOSE', RGB(130, 140, 110));
end;

procedure JournalKeyDown(scancode: longint);
begin
  case scancode of
    SDL_SCANCODE_J, SDL_SCANCODE_ESCAPE: State := gsExplore;
  end;
end;

procedure GameOverRender;
begin
  ClearFB(RGB(16, 6, 8));
  DrawCenter(90, 'THE PARTY HAS FALLEN', RGB(220, 120, 110));
  DrawCenter(110, 'PRESS A KEY', RGB(150, 130, 120));
end;

procedure GameOverKeyDown(scancode: longint);
begin
  titleSel := 0;
  State := gsTitle;
end;

const
  { the options rows, in order down the screen }
  OPT_MASTER = 0;
  OPT_MUSIC  = 1;
  OPT_SFX    = 2;
  OPT_DEATH  = 3;
  OPT_CRIT   = 4;
  OPT_SPEED  = 5;
  OPT_KEYS   = 6;
  OPT_LAST   = 6;

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
    ('MASTER', 'MUSIC', 'SFX', 'PERMADEATH', 'CRITICALS', 'COMBAT SPEED',
     'KEY BINDINGS');
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
      OPT_SPEED: DrawText(170, y, SpeedName(SetCombatSpeed), c);
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

procedure KeybindRender;
var
  a: TGameAction;
  y: longint;
  c: TColor;
begin
  ClearFB(RGB(12, 12, 16));
  DrawCenter(16, 'KEY BINDINGS', RGB(220, 200, 120));
  y := 44;
  for a := Low(TGameAction) to High(TGameAction) do begin
    if ord(a) = kbSel then c := RGB(240, 230, 150) else c := RGB(160, 160, 140);
    DrawText(50, y, ActionName(a), c);
    if (ord(a) = kbSel) and kbCapturing then
      DrawText(210, y, 'PRESS A KEY', RGB(230, 180, 90))
    else
      DrawText(210, y, KeyName(KeyBind[a]), c);
    inc(y, 16);
  end;
  if kbCapturing then
    DrawCenter(FBH - 20, 'PRESS A KEY   ESC CANCEL', RGB(130, 140, 110))
  else
    DrawCenter(FBH - 20, 'ENTER REBIND   ESC BACK', RGB(130, 140, 110));
end;

{ A key reserved for menu navigation, which must stay unbindable. }
function ReservedKey(scancode: longint): boolean;
begin
  ReservedKey := (scancode = SDL_SCANCODE_RETURN)
    or (scancode = SDL_SCANCODE_UP) or (scancode = SDL_SCANCODE_DOWN)
    or (scancode = SDL_SCANCODE_LEFT) or (scancode = SDL_SCANCODE_RIGHT);
end;

procedure KeybindKeyDown(scancode: longint);
begin
  if kbCapturing then begin
    if scancode = SDL_SCANCODE_ESCAPE then begin kbCapturing := false; exit; end;
    if ReservedKey(scancode) then exit;   { keep the menu keys free }
    RebindKey(TGameAction(kbSel), scancode);
    kbCapturing := false;
    SettingsSave;
    PlaySfx(SFX_SELECT);
    exit;
  end;
  case scancode of
    SDL_SCANCODE_UP:     if kbSel > 0 then dec(kbSel);
    SDL_SCANCODE_DOWN:   if kbSel < ord(High(TGameAction)) then inc(kbSel);
    SDL_SCANCODE_RETURN: kbCapturing := true;
    SDL_SCANCODE_ESCAPE: begin SettingsSave; State := gsOptions; end;
  end;
end;

procedure VictoryRender;
begin
  ClearFB(RGB(8, 14, 10));
  DrawCenter(80, 'THE DEEP IS SEALED', RGB(230, 220, 140));
  DrawCenter(96, 'THE TOWN IS SAVED', RGB(180, 200, 160));
  DrawCenter(120, 'PRESS A KEY', RGB(140, 150, 120));
end;

procedure VictoryKeyDown(scancode: longint);
begin
  titleSel := 0;
  State := gsTitle;
end;

end.
