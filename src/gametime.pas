unit gametime;

{** The game clock, day-night cycle and the moon.

  Time is a single count of minutes since an epoch. A day is 1440
  minutes. Outdoor light follows the hour, and the moon follows a
  29.53 day synodic cycle. The moon is tracked from the clock alone,
  so its phase is known everywhere, including underground, which is
  what the lycanthropy curse needs. The clock is saved as one field. }

{$mode objfpc}{$H+}

interface

const
  MINS_PER_DAY = 1440;
  SYNODIC_DAYS = 29.53059;

var
  ClockMin: longword;       { minutes since the epoch }
  MoonOffsetDays: double;   { phase offset, seeded from the world at new game }

procedure TimeReset;
procedure TimeAdvance(mins: longint);

function DayNumber: longint;
function HourOfDay: longint;
function MinuteOfHour: longint;
function TimeString: string;

function DaylightFactor: longint;   { 0..256 direct sun, 0 at night }
function MoonlightFactor: longint;  { 0..256 by illuminated fraction }
function OutdoorAmbient: longint;   { 0..256 light on a surface map }

function MoonAgeDays: double;       { 0 .. SYNODIC_DAYS }
function MoonPhase: longint;        { 0 new .. 4 full .. 7 }
function MoonPhaseName: string;
function IsFullMoon: boolean;
function IsNight: boolean;

implementation

uses
  sysutils, math;

procedure TimeReset;
begin
  ClockMin := 6 * 60;   { day 0, 06:00, a morning start }
end;

procedure TimeAdvance(mins: longint);
begin
  if mins > 0 then
    ClockMin := ClockMin + longword(mins);
end;

function DayNumber: longint;
begin
  DayNumber := ClockMin div MINS_PER_DAY;
end;

function HourOfDay: longint;
begin
  HourOfDay := (ClockMin mod MINS_PER_DAY) div 60;
end;

function MinuteOfHour: longint;
begin
  MinuteOfHour := ClockMin mod 60;
end;

function Pad2(v: longint): string;
begin
  if v < 10 then Pad2 := '0' + IntToStr(v) else Pad2 := IntToStr(v);
end;

function TimeString: string;
begin
  TimeString := Pad2(HourOfDay) + ':' + Pad2(MinuteOfHour);
end;

function DaylightFactor: longint;
var
  h, d: double;
begin
  h := HourOfDay + MinuteOfHour / 60.0;
  if (h < 5.0) or (h >= 19.0) then d := 0.0
  else if h < 7.0 then d := (h - 5.0) / 2.0     { dawn ramp }
  else if h < 17.0 then d := 1.0                { full day }
  else d := (19.0 - h) / 2.0;                   { dusk ramp }
  DaylightFactor := Round(d * 256.0);
end;

function MoonAgeDays: double;
var
  totalDays, p: double;
begin
  totalDays := ClockMin / MINS_PER_DAY + MoonOffsetDays;
  p := totalDays / SYNODIC_DAYS;
  p := p - Floor(p);               { fractional cycle, 0..1 }
  MoonAgeDays := p * SYNODIC_DAYS;
end;

function MoonlightFactor: longint;
var
  p, illum: double;
begin
  p := MoonAgeDays / SYNODIC_DAYS;
  illum := (1.0 - Cos(2.0 * Pi * p)) / 2.0;   { 0 at new, 1 at full }
  MoonlightFactor := Round(illum * 256.0);
end;

function OutdoorAmbient: longint;
var
  a, moon: longint;
begin
  a := DaylightFactor;
  moon := MoonlightFactor div 3;    { the moon lifts the night floor }
  if 40 + moon > a then a := 40 + moon;
  if a > 256 then a := 256;
  OutdoorAmbient := a;
end;

function MoonPhase: longint;
var
  p: double;
begin
  p := MoonAgeDays / SYNODIC_DAYS;
  MoonPhase := Round(p * 8.0);
  if MoonPhase >= 8 then MoonPhase := 0;
end;

function MoonPhaseName: string;
begin
  case MoonPhase of
    0: MoonPhaseName := 'NEW';
    1: MoonPhaseName := 'WAX CRES';
    2: MoonPhaseName := 'FIRST QTR';
    3: MoonPhaseName := 'WAX GIBB';
    4: MoonPhaseName := 'FULL';
    5: MoonPhaseName := 'WANE GIBB';
    6: MoonPhaseName := 'LAST QTR';
  else
    MoonPhaseName := 'WANE CRES';
  end;
end;

function IsFullMoon: boolean;
begin
  IsFullMoon := Abs(MoonAgeDays - SYNODIC_DAYS / 2.0) < 1.0;   { within a day }
end;

function IsNight: boolean;
begin
  IsNight := DaylightFactor = 0;
end;

end.
