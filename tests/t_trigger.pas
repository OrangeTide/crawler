program t_trigger;

{** Polygon trigger areas: the codec round-trips a trigger, the point-in-polygon
  lookup finds the cells inside it, and the map compiler parses a trigger
  directive. }

{$mode objfpc}{$H+}

uses
  sysutils, classes, pak, mapfmt, maptext, world, testing;

const
  TMP = 'build/tests/_trigger.pak';
  FN  = 'build/tests/_trigger.map';

{ An 8x8 open room with one square encounter trigger over cells 2..5. }
procedure BuildMap(out m: TMapData);
var x, y: longint;
begin
  m.w := 8; m.h := 8;
  m.tileset := 0; m.music := 0; m.flags := 0; m.area := 0;
  m.markers := nil; m.portals := nil; m.doors := nil; m.npcs := nil;
  m.traps := nil; m.lights := nil; m.props := nil; m.loot := nil;
  m.sectors := nil; m.cellSector := nil; m.triggers := nil;
  SetLength(m.walls, m.w * m.h);
  for y := 0 to m.h - 1 do
    for x := 0 to m.w - 1 do
      if (x = 0) or (y = 0) or (x = m.w - 1) or (y = m.h - 1) then
        m.walls[y * m.w + x] := 2
      else
        m.walls[y * m.w + x] := TILE_EMPTY;
  EnsureSectors(m);

  SetLength(m.triggers, 1);
  m.triggers[0].kind := TRIG_ENCOUNTER;
  m.triggers[0].param := 5;
  m.triggers[0].tag := 'crypt';
  SetLength(m.triggers[0].verts, 4);
  m.triggers[0].verts[0].x := 2 * TRIG_UNIT; m.triggers[0].verts[0].y := 2 * TRIG_UNIT;
  m.triggers[0].verts[1].x := 6 * TRIG_UNIT; m.triggers[0].verts[1].y := 2 * TRIG_UNIT;
  m.triggers[0].verts[2].x := 6 * TRIG_UNIT; m.triggers[0].verts[2].y := 6 * TRIG_UNIT;
  m.triggers[0].verts[3].x := 2 * TRIG_UNIT; m.triggers[0].verts[3].y := 6 * TRIG_UNIT;
end;

procedure WriteMapText;
var s: TStringList;
begin
  s := TStringList.Create;
  s.Add('map TRIGTEST');
  s.Add('size 8 8');
  s.Add('trigger encounter 3 lair 2 2 6 2 6 6 2 6');
  s.Add('walls');
  s.Add('22222222');
  s.Add('20000002');
  s.Add('20000002');
  s.Add('20000002');
  s.Add('20000002');
  s.Add('20000002');
  s.Add('20000002');
  s.Add('22222222');
  s.Add('end');
  s.SaveToFile(FN);
  s.Free;
end;

var
  m, dm: TMapData;
  w: TPakWriter;
  p: TPak;
  blob: TByteArray;
  name, err: string;
begin
  BuildMap(m);

  { codec round-trip }
  PakWInit(w);
  PakWAdd(w, 'MAP0', EncodeMap(m));
  Check(PakWFlush(w, TMP), 'write a temp pak with the map');
  Check(PakLoad(TMP, p), 'reload the pak');
  Check(PakGet(p, 'MAP0', blob), 'read the map lump');
  Check(DecodeMap(blob, dm), 'decode the map');
  CheckEqI(Length(dm.triggers), 1, 'the trigger round-trips');
  CheckEqI(dm.triggers[0].kind, TRIG_ENCOUNTER, 'the kind round-trips');
  CheckEqI(dm.triggers[0].param, 5, 'the parameter round-trips');
  Check(dm.triggers[0].tag = 'crypt', 'the tag round-trips');
  CheckEqI(Length(dm.triggers[0].verts), 4, 'the polygon round-trips');
  CheckEqI(dm.triggers[0].verts[1].x, 6 * TRIG_UNIT, 'a vertex coord round-trips');

  { point-in-polygon through the live lookup }
  Check(LoadMapData(dm), 'load the decoded map');
  CheckEqI(TriggerAt(3, 3), 0, 'a cell inside the polygon hits the trigger');
  CheckEqI(TriggerAt(5, 5), 0, 'the far inside corner still hits');
  CheckEqI(TriggerAt(0, 0), -1, 'a cell outside misses');
  CheckEqI(TriggerAt(6, 6), -1, 'a cell past the edge misses');

  { the map compiler parses the directive }
  WriteMapText;
  Check(ParseMapText(FN, m, name, err), 'the trigger directive parses');
  CheckEqI(Length(m.triggers), 1, 'the compiler built the trigger');
  CheckEqI(m.triggers[0].kind, TRIG_ENCOUNTER, 'the compiled kind is right');
  CheckEqI(m.triggers[0].param, 3, 'the compiled parameter is right');
  CheckEqI(Length(m.triggers[0].verts), 4, 'the compiled polygon has four verts');

  TestSummary('trigger');
  halt(TestExit);
end.
