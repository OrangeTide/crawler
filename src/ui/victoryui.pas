unit victoryui;

{** The victory screen: shown when the gate to the lost cities opens, a key
  returns to the title. }

{$mode objfpc}{$H+}

interface

procedure VictoryRender;
procedure VictoryKeyDown(scancode: longint);

implementation

uses
  gfx, uihelp, gamestate, runtimer;

procedure VictoryRender;
begin
  ClearFB(RGB(8, 10, 16));
  DrawCenter(72, 'THE GATE STANDS OPEN', RGB(230, 220, 140));
  DrawCenter(88, 'THE LOST CITIES ARE FOUND', RGB(180, 190, 200));
  DrawCenter(104, 'THE SUNLESS DEPTHS AWAIT', RGB(150, 170, 190));
  DrawCenter(128, 'RUN TIME ' + RunTimeString, RGB(200, 200, 160));
  DrawCenter(152, 'PRESS A KEY', RGB(130, 140, 150));
end;

procedure VictoryKeyDown(scancode: longint);
begin
  titleSel := 0;
  State := gsTitle;
end;

end.
