program t_time;

{** The clock, day-night curve and the moon cadence. }

{$mode objfpc}{$H+}

uses
  gametime, testing;

var
  day, fullNights: longint;
begin
  TimeReset;
  MoonOffsetDays := 0;

  ClockMin := 0;        CheckEqI(DaylightFactor, 0, 'midnight is dark');
  ClockMin := 12 * 60;  CheckEqI(DaylightFactor, 256, 'noon is full light');
  ClockMin := 6 * 60;   Check(DaylightFactor > 0, 'dawn has some light');
  ClockMin := 0;        CheckEqI(OutdoorAmbient, 40, 'midnight ambient is the floor');
  ClockMin := 12 * 60;  CheckEqI(OutdoorAmbient, 256, 'noon ambient is full');

  { determinism }
  ClockMin := 7 * 60;
  CheckEqI(DaylightFactor, DaylightFactor, 'daylight deterministic');

  { a full moon should fall on a night within a synodic month and recur }
  fullNights := 0;
  for day := 0 to 59 do begin
    ClockMin := longword(day) * MINS_PER_DAY + longword(22 * 60);
    if IsFullMoon and IsNight then inc(fullNights);
  end;
  Check((fullNights >= 3) and (fullNights <= 5),
    '3 to 5 full-moon nights in 60 days');

  TestSummary('time');
  halt(TestExit);
end.
