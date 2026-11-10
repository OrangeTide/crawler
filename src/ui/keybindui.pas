unit keybindui;

{** The key-binding sub-screen: rebind each game action, with the menu
  navigation keys held reserved. Reached from the options screen. }

{$mode objfpc}{$H+}

interface

procedure KeybindRender;
procedure KeybindKeyDown(scancode: longint);

implementation

uses
  sdl2min, gfx, uihelp, audio, gamestate, settings, keymap;

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

end.
