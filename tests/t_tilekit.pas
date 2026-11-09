program t_tilekit;

{** Modular kit definitions: the codec round-trips, and the baked mossy kit
  (tileset 9) loads from the pak with its floor, ceiling, wall and pillar
  pieces and their footprints. }

{$mode objfpc}{$H+}

uses
  sysutils, pak, tilekit, textures, testing;

const
  TMP = 'build/tests/_tilekit.pak';

{ The footprint width of the first piece of a role in a kit, or 0. }
function RoleFW(ki, role: longint): longint;
var pi: longint;
begin
  RoleFW := 0;
  pi := KitPieceByRole(ki, role);
  if pi >= 0 then RoleFW := Kits[ki].pieces[pi].fw;
end;

{ The lump of the first piece of a role in a kit, or ''. }
function RoleLump(ki, role: longint): string;
var pi: longint;
begin
  RoleLump := '';
  pi := KitPieceByRole(ki, role);
  if pi >= 0 then RoleLump := Kits[ki].pieces[pi].lump;
end;

var
  w: TPakWriter;
  p: TPak;
  src: array[0 .. 0] of TKit;
  ki: longint;
begin
  { codec round-trip on synthetic data through a temp pak }
  src[0].tileset := 7;
  src[0].name := 'test';
  SetLength(src[0].pieces, 2);
  src[0].pieces[0].role := KITROLE_FLOOR;
  src[0].pieces[0].lump := 'T_FLOOR'; src[0].pieces[0].fw := 2;
  src[0].pieces[0].fh := 2; src[0].pieces[0].fz := 1;
  src[0].pieces[1].role := KITROLE_WALL;
  src[0].pieces[1].lump := 'T_WALL'; src[0].pieces[1].fw := 3;
  src[0].pieces[1].fh := 1; src[0].pieces[1].fz := 4;

  PakWInit(w);
  PakWAdd(w, 'KITS', EncodeKits(src));
  Check(PakWFlush(w, TMP), 'write a temp pak with a KITS lump');
  Check(PakLoad(TMP, p), 'reload the temp pak');
  Check(LoadKits(p), 'decode the kits lump');

  ki := KitIndexForTileset(7);
  Check(ki >= 0, 'the synthetic kit is found by tileset');
  CheckEqI(Length(Kits[ki].pieces), 2, 'both pieces round-trip');
  CheckEqI(RoleFW(ki, KITROLE_FLOOR), 2, 'the floor footprint round-trips');
  CheckEqI(RoleFW(ki, KITROLE_WALL), 3, 'the wall span round-trips');
  Check(RoleLump(ki, KITROLE_WALL) = 'T_WALL', 'the wall lump round-trips');
  Check(not TilesetHasKit(3), 'a tileset with no kit reports none');

  { the baked mossy kit from content/tilesets.txt }
  Check(PakLoad('build/game.pak', p), 'load build/game.pak (run make first)');
  Check(LoadKits(p), 'load the baked kits');
  ki := KitIndexForTileset(TILESET_MODULAR);
  Check(ki >= 0, 'the modular tileset carries a kit');
  Check(KitPieceByRole(ki, KITROLE_FLOOR) >= 0, 'the mossy kit has a floor');
  Check(KitPieceByRole(ki, KITROLE_CEIL) >= 0, 'the mossy kit has a ceiling');
  Check(KitPieceByRole(ki, KITROLE_WALL) >= 0, 'the mossy kit has a wall');
  Check(KitPieceByRole(ki, KITROLE_PILLAR) >= 0, 'the mossy kit has a pillar');
  Check(RoleLump(ki, KITROLE_FLOOR) = 'MOD_FLOOR', 'the floor names MOD_FLOOR');
  CheckEqI(RoleFW(ki, KITROLE_FLOOR), 4, 'the mossy floor is 4 units wide');

  TestSummary('tilekit');
  halt(TestExit);
end.
