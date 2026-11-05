program t_format;

{** The compiled pak: textures load, and maps carry their new fields
  (surface flag, light tiles, portal kinds) through encode and decode. }

{$mode objfpc}{$H+}

uses
  pak, pic, textures, mapfmt, testing;

var
  p: TPak;
  blob: TByteArray;
  m: TMapData;
  i, moonwells: longint;
begin
  if not PakLoad('build/game.pak', p) then begin
    writeln('  FAIL could not load build/game.pak (run make first)');
    halt(2);
  end;
  Check(LoadTextures(p), 'textures load from pak');

  Check(PakGet(p, 'TOWN', blob) and DecodeMap(blob, m), 'decode TOWN');
  Check((m.flags and MAP_SURFACE) <> 0, 'TOWN is a surface map');
  Check(Length(m.portals) >= 5, 'TOWN has its gates');

  Check(PakGet(p, 'DUNGEON', blob) and DecodeMap(blob, m), 'decode DUNGEON');
  Check((m.flags and MAP_SURFACE) = 0, 'DUNGEON is underground');
  Check(Length(m.traps) >= 2, 'DUNGEON keeps its traps');
  moonwells := 0;
  for i := 0 to High(m.lights) do
    if m.lights[i].kind = LIGHT_MOONWELL then inc(moonwells);
  Check(moonwells >= 1, 'DUNGEON has the moonwell');
  Check(Length(m.portals) >= 1, 'DUNGEON has portals');

  TestSummary('format');
  halt(TestExit);
end.
