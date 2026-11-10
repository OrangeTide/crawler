program t_prop_face;

{** A prop authored with `auto` for its yaw takes its facing from the walls:
  a door backs the wall behind it and faces into the open. Confirm each backing
  direction yields the matching facing, and a freestanding prop defaults south.
  Yaw bytes: 0 south (+Y), 64 west, 128 north, 192 east. }

{$mode objfpc}{$H+}

uses
  classes, mapfmt, maptext, testing;

const
  FN = 'build/tests/_prop_face.map';

procedure WriteMap;
var
  s: TStringList;
begin
  s := TStringList.Create;
  s.Add('map FACES');
  s.Add('size 7 7');
  s.Add('walls');
  s.Add('2222222');
  s.Add('2000002');
  s.Add('2000002');
  s.Add('2000002');
  s.Add('2000002');
  s.Add('2000002');
  s.Add('2222222');
  s.Add('end');
  s.Add('prop 3 1 DOORWAY auto');   { wall north, should face south }
  s.Add('prop 3 5 DOORWAY auto');   { wall south, should face north }
  s.Add('prop 1 3 DOORWAY auto');   { wall west,  should face east }
  s.Add('prop 5 3 DOORWAY auto');   { wall east,  should face west }
  s.Add('prop 3 3 DOORWAY auto');   { freestanding, defaults south }
  s.Add('prop 2 2 BARREL 45');      { an explicit yaw is untouched }
  s.SaveToFile(FN);
  s.Free;
end;

{ The yaw of the prop on cell (x,y), or -1 if none. }
function PropYaw(const m: TMapData; x, y: longint): longint;
var i: longint;
begin
  PropYaw := -1;
  for i := 0 to High(m.props) do
    if (m.props[i].x = x) and (m.props[i].y = y) then begin
      PropYaw := m.props[i].yaw; exit;
    end;
end;

var
  m: TMapData;
  name, err: string;
begin
  WriteMap;
  Check(ParseMapText(FN, m, name, err), 'the map with auto props parses');
  CheckEqI(PropYaw(m, 3, 1), 0,   'a door backing the north wall faces south');
  CheckEqI(PropYaw(m, 3, 5), 128, 'a door backing the south wall faces north');
  CheckEqI(PropYaw(m, 1, 3), 192, 'a door backing the west wall faces east');
  CheckEqI(PropYaw(m, 5, 3), 64,  'a door backing the east wall faces west');
  CheckEqI(PropYaw(m, 3, 3), 0,   'a freestanding door defaults south');
  CheckEqI(PropYaw(m, 2, 2), (45 * 256 div 360) and $FF,
    'an explicit yaw is left untouched');

  TestSummary('prop_face');
  halt(TestExit);
end.
