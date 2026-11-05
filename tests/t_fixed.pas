program t_fixed;

{** Fixed-point math: exact integer expectations for the 16.16 ops. }

{$mode objfpc}{$H+}

uses
  fixedpt, testing;

begin
  CheckEqI(FMul(FixI(3), FixI(4)), FixI(12), 'FMul 3*4 = 12');
  CheckEqI(FMul(FixI(-2) - FHALF, FixI(4)), -(FixI(10)), 'FMul -2.5*4 = -10');
  CheckEqI(FDiv(FixI(1), FixI(4)), FONE div 4, 'FDiv 1/4 = 0.25');
  CheckEqI(FDiv(FixI(7), FHALF), FixI(14), 'FDiv 7/0.5 = 14');
  CheckEqI(FFloor(FixI(5) + FHALF), 5, 'FFloor 5.5 = 5');
  CheckEqI(FFloor(-FHALF), -1, 'FFloor -0.5 = -1');
  CheckEqI(FFloor(FixI(-1)), -1, 'FFloor -1.0 = -1');
  CheckEqI(FFrac(FixI(5) + FHALF), FHALF, 'FFrac 5.5 = 0.5');
  CheckEqI(FAbs(-(FixI(3))), FixI(3), 'FAbs -3 = 3');
  CheckEqI(FAbs(FixI(3)), FixI(3), 'FAbs 3 = 3');

  TestSummary('fixed');
  halt(TestExit);
end.
