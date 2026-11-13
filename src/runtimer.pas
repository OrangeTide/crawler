unit runtimer;

{** The run timer: real play time accumulated across a single playthrough.

  It counts wall-clock seconds while the run is in progress, so it is a
  speedrun-style clock rather than the in-world day-night clock in gametime.
  It does not advance on the title, during party creation, or once the run has
  ended at the game-over or victory screen. The whole-second total is part of
  the save, so a loaded run resumes its clock. }

{$mode objfpc}{$H+}

interface

var
  RunSeconds: double;   { accumulated real play time of this run }

procedure RunTimerReset;
procedure RunTimerTick(dt: double);   { add dt seconds while the run is active }
function RunTimeString: string;       { H:MM:SS }

implementation

uses sysutils;

procedure RunTimerReset;
begin
  RunSeconds := 0;
end;

procedure RunTimerTick(dt: double);
begin
  if dt > 0 then RunSeconds := RunSeconds + dt;
end;

function RunTimeString: string;
var t, h, m, s: longint;
begin
  t := Trunc(RunSeconds);
  h := t div 3600;
  m := (t div 60) mod 60;
  s := t mod 60;
  RunTimeString := Format('%d:%.2d:%.2d', [h, m, s]);
end;

initialization
  RunSeconds := 0;
end.
