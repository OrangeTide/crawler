program t_format;

{** The compiled pak: textures load, and maps carry their new fields
  (surface flag, light tiles, portal kinds) through encode and decode. }

{$mode objfpc}{$H+}

uses
  pak, pic, textures, mapfmt, overworld, testing;

var
  p: TPak;
  blob: TByteArray;
  m: TMapData;
  i, moonwells, doors, props: longint;
begin
  if not PakLoad('build/game.pak', p) then begin
    writeln('  FAIL could not load build/game.pak (run make first)');
    halt(2);
  end;
  Check(LoadTextures(p), 'textures load from pak');

  Check(PakGet(p, 'TOWN', blob) and DecodeMap(blob, m), 'decode TOWN');
  Check((m.flags and MAP_SURFACE) <> 0, 'TOWN is a surface map');
  Check(m.area = 0, 'TOWN is a safe area');
  Check(Length(m.portals) >= 5, 'TOWN has its gates');
  doors := 0;
  for i := 0 to High(m.portals) do
    if m.portals[i].kind = PK_DOOR then inc(doors);
  Check(doors >= 1, 'TOWN has the tavern door');

  { props survive encode and decode }
  props := 0;
  for i := 0 to High(m.props) do
    if m.props[i].name = 'BARREL' then inc(props);
  Check(Length(m.props) >= 1, 'TOWN carries props');
  Check(props >= 1, 'TOWN has a barrel prop');

  Check(PakGet(p, 'TAVERN', blob) and DecodeMap(blob, m), 'decode TAVERN');
  Check((m.flags and MAP_SURFACE) = 0, 'TAVERN is an indoor map');
  doors := 0;
  for i := 0 to High(m.portals) do
    if (m.portals[i].kind = PK_DOOR) and (m.portals[i].target = 'TOWN') then
      inc(doors);
  Check(doors >= 1, 'TAVERN has a door back to TOWN');

  Check(PakGet(p, 'DUNGEON', blob) and DecodeMap(blob, m), 'decode DUNGEON');
  Check((m.flags and MAP_SURFACE) = 0, 'DUNGEON is underground');
  Check(m.area = AREA_CRYPT, 'DUNGEON carries its crypt area from the lump');
  Check(Length(m.traps) >= 2, 'DUNGEON keeps its traps');
  moonwells := 0;
  for i := 0 to High(m.lights) do
    if m.lights[i].kind = LIGHT_MOONWELL then inc(moonwells);
  Check(moonwells >= 1, 'DUNGEON has the moonwell');
  Check(Length(m.portals) >= 1, 'DUNGEON has portals');

  Check(PakGet(p, 'FOREST', blob) and DecodeMap(blob, m), 'decode FOREST');
  Check(m.area = AREA_FOREST, 'FOREST carries its forest area from the lump');

  TestSummary('format');
  halt(TestExit);
end.
