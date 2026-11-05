program t_dice;

{** The dice/expression evaluator: arithmetic, dice ranges, precedence,
  determinism, and rejection of malformed input. }

{$mode objfpc}{$H+}

uses
  rng, dice, testing;

var
  r: TRng;
  v, lo, hi, i: longint;
  ok: boolean;

{ Evaluate with a fresh value; returns the value, ignoring the ok flag. }
function Ev(const s: string): longint;
begin
  if not EvalDice(r, s, Ev) then Ev := -999999;
end;

begin
  RngSeed(r, 12345);

  { plain arithmetic }
  Check(Ev('100') = 100, 'a plain number');
  Check(Ev('2+3') = 5, 'addition');
  Check(Ev('10-4') = 6, 'subtraction');
  Check(Ev('2*3') = 6, 'multiplication');
  Check(Ev('7/2') = 3, 'integer division');
  Check(Ev('(2+3)*4') = 20, 'parentheses group');
  Check(Ev('2+3*4') = 14, 'times binds before plus');

  { dice bind tighter than times: 10*3d6 is 10*(3d6), never (10*3)d6 }
  lo := 1000; hi := -1000;
  for i := 1 to 400 do begin
    v := Ev('10*3d6');
    if v < lo then lo := v;
    if v > hi then hi := v;
  end;
  Check((lo >= 30) and (hi <= 180), '10*3d6 stays in 30..180');
  Check(hi > lo, '10*3d6 actually varies');

  { a bare dM is one die }
  lo := 99; hi := -99;
  for i := 1 to 400 do begin
    v := Ev('d6');
    if v < lo then lo := v;
    if v > hi then hi := v;
  end;
  Check((lo = 1) and (hi = 6), 'd6 rolls 1..6');

  { NdM range and the additive modifier }
  lo := 999; hi := -999;
  for i := 1 to 400 do begin
    v := Ev('2d6+5');
    if v < lo then lo := v;
    if v > hi then hi := v;
  end;
  Check((lo >= 7) and (hi <= 17), '2d6+5 stays in 7..17');

  { determinism: the same seed replays the same rolls }
  RngSeed(r, 777);
  v := Ev('20*4d6');
  RngSeed(r, 777);
  Check(Ev('20*4d6') = v, 'same seed, same roll');

  { malformed expressions are rejected }
  Check(not EvalDice(r, '', v), 'empty is rejected');
  Check(not EvalDice(r, '3d', v), 'dangling d is rejected');
  Check(not EvalDice(r, '2+', v), 'dangling operator is rejected');
  Check(not EvalDice(r, '(2+3', v), 'unbalanced paren is rejected');
  Check(not EvalDice(r, '2d6 x', v), 'trailing junk is rejected');

  TestSummary('dice');
  halt(TestExit);
end.
