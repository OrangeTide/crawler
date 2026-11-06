unit keymap;

{** Rebindable key bindings for the core exploration actions.

  Movement, turning, interaction and the handful of in-world commands read
  their scancodes from one table, so the player can rebind them. Menu
  navigation (arrows, enter, escape) is fixed and not routed through here.
  The table is a plain leaf: it depends only on the scancode names, and the
  settings unit persists it. }

{$mode objfpc}{$H+}

interface

uses
  sdl2min;

type
  TGameAction = (gaForward, gaBack, gaTurnL, gaTurnR, gaStrafeL, gaStrafeR,
                 gaInteract, gaRest, gaMap, gaRecall, gaOverworld);

var
  KeyBind: array[TGameAction] of longint;   { the scancode bound to each action }

procedure KeyBindDefaults;
{ Bind scancode to action a. If another action already holds it, that action
  takes a's old key, so the swap never leaves an action without one. }
procedure RebindKey(a: TGameAction; scancode: longint);
{ The ord of the action bound to scancode, or -1 if none is. }
function ActionForKey(scancode: longint): longint;
function ActionName(a: TGameAction): string;   { for the rebinding screen }
function ActionId(a: TGameAction): string;      { stable id for the config file }
function ActionById(const id: string): longint;  { ord of the action, or -1 }
function KeyName(scancode: longint): string;     { a short label for a scancode }

implementation

uses
  sysutils;

procedure KeyBindDefaults;
begin
  KeyBind[gaForward]   := SDL_SCANCODE_W;
  KeyBind[gaBack]      := SDL_SCANCODE_S;
  KeyBind[gaTurnL]     := SDL_SCANCODE_Q;
  KeyBind[gaTurnR]     := SDL_SCANCODE_E;
  KeyBind[gaStrafeL]   := SDL_SCANCODE_A;
  KeyBind[gaStrafeR]   := SDL_SCANCODE_D;
  KeyBind[gaInteract]  := SDL_SCANCODE_SPACE;
  KeyBind[gaRest]      := SDL_SCANCODE_R;
  KeyBind[gaMap]       := SDL_SCANCODE_TAB;
  KeyBind[gaRecall]    := SDL_SCANCODE_G;
  KeyBind[gaOverworld] := SDL_SCANCODE_O;
end;

procedure RebindKey(a: TGameAction; scancode: longint);
var
  other: TGameAction;
  old: longint;
begin
  old := KeyBind[a];
  for other := Low(TGameAction) to High(TGameAction) do
    if (other <> a) and (KeyBind[other] = scancode) then
      KeyBind[other] := old;
  KeyBind[a] := scancode;
end;

function ActionForKey(scancode: longint): longint;
var a: TGameAction;
begin
  ActionForKey := -1;
  for a := Low(TGameAction) to High(TGameAction) do
    if KeyBind[a] = scancode then begin
      ActionForKey := ord(a);
      exit;
    end;
end;

function ActionName(a: TGameAction): string;
begin
  case a of
    gaForward:   ActionName := 'MOVE FORWARD';
    gaBack:      ActionName := 'MOVE BACK';
    gaTurnL:     ActionName := 'TURN LEFT';
    gaTurnR:     ActionName := 'TURN RIGHT';
    gaStrafeL:   ActionName := 'STRAFE LEFT';
    gaStrafeR:   ActionName := 'STRAFE RIGHT';
    gaInteract:  ActionName := 'INTERACT';
    gaRest:      ActionName := 'REST';
    gaMap:       ActionName := 'MAP';
    gaRecall:    ActionName := 'RECALL TOWN';
    gaOverworld: ActionName := 'OVERWORLD';
  else ActionName := '';
  end;
end;

function ActionId(a: TGameAction): string;
begin
  case a of
    gaForward:   ActionId := 'fwd';
    gaBack:      ActionId := 'back';
    gaTurnL:     ActionId := 'turnl';
    gaTurnR:     ActionId := 'turnr';
    gaStrafeL:   ActionId := 'strafel';
    gaStrafeR:   ActionId := 'strafer';
    gaInteract:  ActionId := 'interact';
    gaRest:      ActionId := 'rest';
    gaMap:       ActionId := 'map';
    gaRecall:    ActionId := 'recall';
    gaOverworld: ActionId := 'overworld';
  else ActionId := '';
  end;
end;

function ActionById(const id: string): longint;
var a: TGameAction;
begin
  ActionById := -1;
  for a := Low(TGameAction) to High(TGameAction) do
    if ActionId(a) = id then begin
      ActionById := ord(a);
      exit;
    end;
end;

function KeyName(scancode: longint): string;
begin
  { letters and digits map contiguously in the SDL scancode table }
  if (scancode >= SDL_SCANCODE_A) and (scancode <= 29) then
    KeyName := chr(ord('A') + scancode - SDL_SCANCODE_A)
  else if (scancode >= 30) and (scancode <= 38) then
    KeyName := chr(ord('1') + scancode - 30)
  else begin
    case scancode of
      39: KeyName := '0';
      SDL_SCANCODE_RETURN: KeyName := 'ENTER';
      SDL_SCANCODE_ESCAPE: KeyName := 'ESC';
      SDL_SCANCODE_TAB:    KeyName := 'TAB';
      SDL_SCANCODE_SPACE:  KeyName := 'SPACE';
      79: KeyName := 'RIGHT';
      80: KeyName := 'LEFT';
      81: KeyName := 'DOWN';
      82: KeyName := 'UP';
    else KeyName := 'KEY' + IntToStr(scancode);
    end;
  end;
end;

initialization
  KeyBindDefaults;

end.
