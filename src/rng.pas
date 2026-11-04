unit rng;

{** Deterministic pseudo-random number generator.

  An explicit state record so the game can keep independent streams: one
  seeded per dynamic map (so a level regenerates identically from its
  seed) and one for gameplay rolls. xorshift32 is small, fast and good
  enough for dice and map generation. }

{$mode objfpc}{$H+}

interface

type
  TRng = record
    state: UInt32;
  end;

var
  GameRng: TRng;   { the default gameplay stream }

procedure RngSeed(var r: TRng; s: UInt32);
function RngNext(var r: TRng): UInt32;
function RngRange(var r: TRng; lo, hi: longint): longint;
function RngRoll(var r: TRng; count, sides: longint): longint;

{ Convenience wrappers over GameRng. }
function Range(lo, hi: longint): longint;
function Roll(count, sides: longint): longint;
function D(sides: longint): longint;

implementation

procedure RngSeed(var r: TRng; s: UInt32);
begin
  if s = 0 then s := $9E3779B9;   { avoid the zero fixed point }
  r.state := s;
end;

function RngNext(var r: TRng): UInt32;
begin
  r.state := r.state xor (r.state shl 13);
  r.state := r.state xor (r.state shr 17);
  r.state := r.state xor (r.state shl 5);
  RngNext := r.state;
end;

function RngRange(var r: TRng; lo, hi: longint): longint;
begin
  if hi <= lo then
    RngRange := lo
  else
    RngRange := lo + longint(RngNext(r) mod UInt32(hi - lo + 1));
end;

function RngRoll(var r: TRng; count, sides: longint): longint;
var
  i, s: longint;
begin
  s := 0;
  for i := 1 to count do
    s := s + RngRange(r, 1, sides);
  RngRoll := s;
end;

function Range(lo, hi: longint): longint;
begin
  Range := RngRange(GameRng, lo, hi);
end;

function Roll(count, sides: longint): longint;
begin
  Roll := RngRoll(GameRng, count, sides);
end;

function D(sides: longint): longint;
begin
  D := RngRange(GameRng, 1, sides);
end;

initialization
  RngSeed(GameRng, $1234ABCD);

end.
