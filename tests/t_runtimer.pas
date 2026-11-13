program t_runtimer;

{** The run timer accumulates real play seconds and formats as H:MM:SS. }

{$mode objfpc}{$H+}

uses
  sysutils, runtimer, testing;

begin
  RunTimerReset;
  Check(RunTimeString = '0:00:00', 'reset reads zero');

  RunTimerTick(1.5);
  RunTimerTick(2.0);
  Check(RunTimeString = '0:00:03', 'fractional ticks sum and truncate');

  { negative or zero deltas never move the clock backwards }
  RunTimerTick(-10.0);
  RunTimerTick(0.0);
  Check(RunTimeString = '0:00:03', 'non-positive ticks are ignored');

  RunTimerReset;
  RunTimerTick(3661.0);   { 1h 01m 01s }
  Check(RunTimeString = '1:01:01', 'hours, minutes and seconds carry');

  RunTimerReset;
  RunTimerTick(59.0);
  Check(RunTimeString = '0:00:59', 'seconds below a minute');
  RunTimerTick(1.0);
  Check(RunTimeString = '0:01:00', 'rolls into a minute');

  TestSummary('runtimer');
  halt(TestExit);
end.
