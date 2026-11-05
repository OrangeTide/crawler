unit fixedpt;

{** Signed 16.16 fixed-point math for the raycaster hot path.

  Neither the MS-DOS nor the PlayStation 1 target has a dependable FPU,
  so the per-pixel and per-column raycaster math runs in fixed point.
  The camera is converted from the engine's doubles to fixed once per
  frame at the boundary, which is the only floating point left on the
  render path and is a handful of operations, not millions. }

{$mode objfpc}{$H+}

interface

const
  FBITS = 16;
  FONE  = longint(1) shl FBITS;    { 1.0 }
  FHALF = FONE div 2;

type
  TFix = longint;

function FixI(i: longint): TFix; inline;        { integer to fixed }
function FixF(d: double): TFix; inline;         { float to fixed, boundary only }
function FMul(a, b: TFix): TFix; inline;
function FDiv(a, b: TFix): TFix; inline;
function FFloor(f: TFix): longint; inline;      { floor to integer }
function FFrac(f: TFix): TFix; inline;          { fractional part in [0,1) }
function FAbs(f: TFix): TFix; inline;

implementation

function FixI(i: longint): TFix;
begin
  FixI := i shl FBITS;
end;

function FixF(d: double): TFix;
begin
  FixF := Round(d * FONE);
end;

function FMul(a, b: TFix): TFix;
begin
  FMul := TFix((int64(a) * int64(b)) div FONE);
end;

function FDiv(a, b: TFix): TFix;
begin
  if b = 0 then
    FDiv := $7FFFFFFF
  else
    FDiv := TFix((int64(a) shl FBITS) div b);
end;

function FFloor(f: TFix): longint;
begin
  if f >= 0 then
    FFloor := f shr FBITS
  else
    FFloor := -(((-f) + (FONE - 1)) shr FBITS);
end;

function FFrac(f: TFix): TFix;
begin
  FFrac := f - (FFloor(f) shl FBITS);
end;

function FAbs(f: TFix): TFix;
begin
  if f < 0 then FAbs := -f else FAbs := f;
end;

end.
