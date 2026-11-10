unit gameoverui;

{** The game-over screen: shown when the party falls, a key returns to the
  title. }

{$mode objfpc}{$H+}

interface

procedure GameOverRender;
procedure GameOverKeyDown(scancode: longint);

implementation

uses
  gfx, uihelp, gamestate;

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

end.
