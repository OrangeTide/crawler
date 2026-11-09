program t_maptext_sector;

{** The map compiler's height directives. `sector N F C [T]` defines a sector's
  floor and ceiling heights, and `fill N X0 Y0 X1 Y1` paints a cell rectangle
  into it. Confirm both parse and that unfilled open cells fall into the
  default sector while solid cells stay out. }

{$mode objfpc}{$H+}

uses
  classes, mapfmt, maptext, testing;

const
  FN = 'build/tests/_maptext_sector.map';

procedure WriteMap;
var
  s: TStringList;
begin
  s := TStringList.Create;
  s.Add('map HOLLOW');
  s.Add('size 5 4');
  s.Add('sector 1 -16 24');
  s.Add('walls');
  s.Add('22222');
  s.Add('20002');
  s.Add('20002');
  s.Add('22222');
  s.Add('end');
  s.Add('fill 1 1 1 3 1');   { paint the first open row into sector 1 }
  s.SaveToFile(FN);
  s.Free;
end;

var
  m: TMapData;
  name, err: string;
begin
  WriteMap;
  Check(ParseMapText(FN, m, name, err), 'the map with height directives parses');
  Check(name = 'HOLLOW', 'the map name is read');

  Check(Length(m.sectors) >= 2, 'the named sector exists');
  CheckEqI(m.sectors[1].floorZ, -16, 'the sector floor height is read');
  CheckEqI(m.sectors[1].ceilZ, 24, 'the sector ceiling height is read');

  { row y=1 (x 1..3) was filled into sector 1 }
  CheckEqI(m.cellSector[1 * 5 + 1], 1, 'a filled cell takes the sector');
  CheckEqI(m.cellSector[1 * 5 + 3], 1, 'the fill spans its rectangle');
  { row y=2 is open but unfilled, so the default sector 0 }
  CheckEqI(m.cellSector[2 * 5 + 1], 0, 'an unfilled open cell is the default');
  { the border is solid, so no sector }
  CheckEqI(m.cellSector[0], SECTOR_NONE, 'a solid border cell has no sector');

  TestSummary('maptext_sector');
  halt(TestExit);
end.
