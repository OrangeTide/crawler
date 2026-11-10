program t_trigger;

{** Polygon trigger areas: the codec round-trips a trigger, the point-in-polygon
  lookup finds the cells inside it, and the map compiler parses a trigger
  directive. }

{$mode objfpc}{$H+}

uses
  sysutils, classes, pak, mapfmt, maptext, world, encounters, testing;

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
  m.pillars := nil; m.foliage := nil;
  m.heightLump := ''; m.heightZMin := 0; m.heightZMax := 0;
  SetLength(m.walls, m.w * m.h);
  for y := 0 to m.h - 1 do
    for x := 0 to m.w - 1 do
      if (x = 0) or (y = 0) or (x = m.w - 1) or (y = m.h - 1) then
        m.walls[y * m.w + x] := 2
      else
        m.walls[y * m.w + x] := TILE_EMPTY;
  EnsureSectors(m);

  SetLength(m.triggers, 3);
  m.triggers[0].kind := TRIG_ENCOUNTER;
  m.triggers[0].param := 5;
  m.triggers[0].tag := 'crypt';
  m.triggers[0].msg := '';
  SetLength(m.triggers[0].verts, 4);
  m.triggers[0].verts[0].x := 2 * TRIG_UNIT; m.triggers[0].verts[0].y := 2 * TRIG_UNIT;
  m.triggers[0].verts[1].x := 6 * TRIG_UNIT; m.triggers[0].verts[1].y := 2 * TRIG_UNIT;
  m.triggers[0].verts[2].x := 6 * TRIG_UNIT; m.triggers[0].verts[2].y := 6 * TRIG_UNIT;
  m.triggers[0].verts[3].x := 2 * TRIG_UNIT; m.triggers[0].verts[3].y := 6 * TRIG_UNIT;
  { a fire-on-enter event over the same cells, carrying a message }
  m.triggers[1].kind := TRIG_EVENT;
  m.triggers[1].param := 0;
  m.triggers[1].tag := 'seen';
  m.triggers[1].msg := 'A COLD DRAFT STIRS THE DUST.';
  SetLength(m.triggers[1].verts, 4);
  m.triggers[1].verts[0].x := 2 * TRIG_UNIT; m.triggers[1].verts[0].y := 2 * TRIG_UNIT;
  m.triggers[1].verts[1].x := 6 * TRIG_UNIT; m.triggers[1].verts[1].y := 2 * TRIG_UNIT;
  m.triggers[1].verts[2].x := 6 * TRIG_UNIT; m.triggers[1].verts[2].y := 6 * TRIG_UNIT;
  m.triggers[1].verts[3].x := 2 * TRIG_UNIT; m.triggers[1].verts[3].y := 6 * TRIG_UNIT;
  { a fire hazard over the same cells }
  m.triggers[2].kind := TRIG_HAZARD;
  m.triggers[2].param := 4;
  m.triggers[2].tag := 'fire';
  m.triggers[2].msg := '';
  SetLength(m.triggers[2].verts, 4);
  m.triggers[2].verts[0].x := 2 * TRIG_UNIT; m.triggers[2].verts[0].y := 2 * TRIG_UNIT;
  m.triggers[2].verts[1].x := 6 * TRIG_UNIT; m.triggers[2].verts[1].y := 2 * TRIG_UNIT;
  m.triggers[2].verts[2].x := 6 * TRIG_UNIT; m.triggers[2].verts[2].y := 6 * TRIG_UNIT;
  m.triggers[2].verts[3].x := 2 * TRIG_UNIT; m.triggers[2].verts[3].y := 6 * TRIG_UNIT;
end;

procedure WriteMapText;
var s: TStringList;
begin
  s := TStringList.Create;
  s.Add('map TRIGTEST');
  s.Add('size 8 8');
  s.Add('trigger encounter 3 lair 2 2 6 2 6 6 2 6');
  s.Add('trigger event 0 seen 2 2 6 2 6 6 2 6');
  s.Add('eventmsg seen A cold draft stirs the dust.');
  s.Add('trigger hazard 4 fire 2 2 6 2 6 6 2 6');
  s.Add('pillar 4 4');
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
  SetLength(m.pillars, 2);
  m.pillars[0].x := 3; m.pillars[0].y := 4;
  m.pillars[1].x := 5; m.pillars[1].y := 2;

  m.heightLump := 'HM_HILL'; m.heightZMin := -8; m.heightZMax := 48;

  SetLength(m.foliage, 2);
  m.foliage[0].x := 2; m.foliage[0].y := 3; m.foliage[0].kind := 4;
  m.foliage[1].x := 5; m.foliage[1].y := 6; m.foliage[1].kind := 0;

  { codec round-trip }
  PakWInit(w);
  PakWAdd(w, 'MAP0', EncodeMap(m));
  Check(PakWFlush(w, TMP), 'write a temp pak with the map');
  Check(PakLoad(TMP, p), 'reload the pak');
  Check(PakGet(p, 'MAP0', blob), 'read the map lump');
  Check(DecodeMap(blob, dm), 'decode the map');
  CheckEqI(Length(dm.triggers), 3, 'the triggers round-trip');
  CheckEqI(dm.triggers[0].kind, TRIG_ENCOUNTER, 'the kind round-trips');
  CheckEqI(dm.triggers[0].param, 5, 'the parameter round-trips');
  Check(dm.triggers[0].tag = 'crypt', 'the tag round-trips');
  CheckEqI(Length(dm.triggers[0].verts), 4, 'the polygon round-trips');
  CheckEqI(dm.triggers[0].verts[1].x, 6 * TRIG_UNIT, 'a vertex coord round-trips');
  CheckEqI(dm.triggers[1].kind, TRIG_EVENT, 'the event kind round-trips');
  Check(dm.triggers[1].msg = 'A COLD DRAFT STIRS THE DUST.', 'the event message round-trips');
  CheckEqI(Length(dm.pillars), 2, 'the pillars round-trip');
  CheckEqI(dm.pillars[0].x, 3, 'a pillar x round-trips');
  CheckEqI(dm.pillars[1].y, 2, 'a pillar y round-trips');
  Check(dm.heightLump = 'HM_HILL', 'the terrain height lump round-trips');
  CheckEqI(dm.heightZMin, -8, 'the terrain min height round-trips');
  CheckEqI(dm.heightZMax, 48, 'the terrain max height round-trips');
  CheckEqI(Length(dm.foliage), 2, 'the foliage round-trips');
  CheckEqI(dm.foliage[0].kind, 4, 'a foliage kind round-trips');
  CheckEqI(dm.foliage[1].x, 5, 'a foliage x round-trips');

  { point-in-polygon through the live lookup }
  Check(LoadMapData(dm), 'load the decoded map');
  Check(IsPillar(3, 4), 'a pillar cell reports a pillar');
  Check(IsBlocking(3, 4), 'a pillar cell blocks movement');
  Check(not IsPillar(4, 4), 'a bare floor cell has no pillar');
  CheckEqI(TriggerAt(3, 3), 0, 'a cell inside the polygon hits the trigger');
  CheckEqI(TriggerAt(5, 5), 0, 'the far inside corner still hits');
  CheckEqI(TriggerAt(0, 0), -1, 'a cell outside misses');
  CheckEqI(TriggerAt(6, 6), -1, 'a cell past the edge misses');

  { the encounter table in effect: the trigger's inside it, the area's out }
  CheckEqI(EncTableHere(0, 3, 3), 5, 'inside, the trigger table applies');
  CheckEqI(EncTableHere(0, 0, 0), EncTableOf(0), 'outside, the area table applies');

  { the event lookup is kind-filtered and finds the event polygon }
  CheckEqI(EventHere(3, 3), 1, 'inside, the event trigger is found');
  CheckEqI(EventHere(0, 0), -1, 'outside, no event trigger');
  CheckEqI(HazardHere(3, 3), 2, 'inside, the hazard trigger is found');
  CheckEqI(HazardHere(0, 0), -1, 'outside, no hazard trigger');

  { the map compiler parses the directive }
  WriteMapText;
  Check(ParseMapText(FN, m, name, err), 'the trigger directive parses');
  CheckEqI(Length(m.triggers), 3, 'the compiler built the triggers');
  CheckEqI(m.triggers[0].kind, TRIG_ENCOUNTER, 'the compiled kind is right');
  CheckEqI(m.triggers[0].param, 3, 'the compiled parameter is right');
  CheckEqI(Length(m.triggers[0].verts), 4, 'the compiled polygon has four verts');
  CheckEqI(m.triggers[1].kind, TRIG_EVENT, 'the compiled event kind is right');
  Check(m.triggers[1].msg = 'A cold draft stirs the dust.',
    'the eventmsg directive attaches the message');
  CheckEqI(m.triggers[2].kind, TRIG_HAZARD, 'the compiled hazard kind is right');
  CheckEqI(m.triggers[2].param, 4, 'the compiled hazard damage is right');
  Check(m.triggers[2].tag = 'fire', 'the compiled hazard element is right');
  CheckEqI(Length(m.pillars), 1, 'the pillar directive compiles');
  CheckEqI(m.pillars[0].x, 4, 'the compiled pillar x is right');
  CheckEqI(m.pillars[0].y, 4, 'the compiled pillar y is right');

  TestSummary('trigger');
  halt(TestExit);
end.
