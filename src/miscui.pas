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
procedure VictoryRender;
procedure VictoryKeyDown(scancode: longint);

implementation

uses
  sysutils, sdl2min, gfx, flags, audio, uihelp, gamestate, world, hud,
  exploreui, pursuit;

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

procedure OptionsRender;
const
  LABELS: array[0 .. 2] of string = ('MASTER', 'MUSIC', 'SFX');
var
  i, y, v: longint;
  c: TColor;
begin
  ClearFB(RGB(12, 12, 16));
  DrawCenter(20, 'OPTIONS', RGB(220, 200, 120));
  y := 60;
  for i := 0 to 2 do begin
    if i = optSel then c := RGB(240, 230, 150) else c := RGB(160, 160, 140);
    DrawText(60, y, LABELS[i], c);
    case i of
      0: v := volMaster;
      1: v := volMusic;
    else v := volSfx;
    end;
    FillRect(130, y, 102, 7, RGB(40, 40, 46));
    FillRect(131, y + 1, v, 5, RGB(90, 160, 110));
    DrawText(240, y, IntToStr(v), c);
    inc(y, 20);
  end;
  DrawCenter(FBH - 20, 'ARROWS ADJUST   ESC BACK', RGB(130, 140, 110));
end;

procedure OptionsKeyDown(scancode: longint);
var
  delta: longint;
begin
  delta := 0;
  case scancode of
    SDL_SCANCODE_UP:   if optSel > 0 then dec(optSel);
    SDL_SCANCODE_DOWN: if optSel < 2 then inc(optSel);
    SDL_SCANCODE_LEFT:  delta := -10;
    SDL_SCANCODE_RIGHT: delta := 10;
    SDL_SCANCODE_ESCAPE: begin State := gsTitle; exit; end;
  end;
  if delta <> 0 then begin
    case optSel of
      0: volMaster := volMaster + delta;
      1: volMusic := volMusic + delta;
    else volSfx := volSfx + delta;
    end;
    if volMaster < 0 then volMaster := 0; if volMaster > 100 then volMaster := 100;
    if volMusic < 0 then volMusic := 0;   if volMusic > 100 then volMusic := 100;
    if volSfx < 0 then volSfx := 0;        if volSfx > 100 then volSfx := 100;
    SetAudioVolumes(volMaster, volMusic, volSfx);
    PlaySfx(SFX_SELECT);
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
