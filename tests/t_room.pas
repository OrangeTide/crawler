program t_room;

{** The modular-room text parser. A room lists kit pieces to instance,
  one per line, as "model x y z yawDeg [scale]", with comments and blank
  lines ignored. Confirm the fields parse, yaw converts to radians, the
  scale defaults, names uppercase, and a content-free file is empty. }

{$mode objfpc}{$H+}

uses
  math, roomdb, testing;

var
  r: TRoom;
begin
  Check(ParseRoom(
    '# a chamber'#10 +
    'MOD_WALL  1 2 3  90'#10 +
    ''#10 +
    'mod_floor 0 0 0   0  2.5'#10, r), 'a two-piece room parses');
  CheckEqI(Length(r), 2, 'blank and comment lines are skipped');

  Check(r[0].model = 'MOD_WALL', 'the first piece name survives');
  Check((abs(r[0].x - 1) < 0.001) and (abs(r[0].y - 2) < 0.001)
    and (abs(r[0].z - 3) < 0.001), 'the first piece position parses');
  Check(abs(r[0].yaw - DegToRad(90)) < 0.001, 'yaw converts degrees to radians');
  Check(abs(r[0].scale - 1) < 0.001, 'scale defaults to 1');

  Check(r[1].model = 'MOD_FLOOR', 'a lowercase name is uppercased');
  Check(abs(r[1].scale - 2.5) < 0.001, 'an explicit scale is read');

  Check(not ParseRoom('# nothing here'#10#10, r),
    'a comment-only file yields no pieces');
  Check(not ParseRoom('MOD_WALL 1 2'#10, r),
    'a short line is skipped, leaving the room empty');

  TestSummary('room');
  halt(TestExit);
end.
