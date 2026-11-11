program t_tilekit;

{** Modular kit definitions: the codec round-trips (including the per-piece
  trim atlas index), TrimPtr selects among resident atlases, and the baked
  mausoleum kit loads from the pak with its floor, ceiling, wall and pillar
  pieces, their footprints and their atlas assignments. }

{$mode objfpc}{$H+}

uses
  sysutils, pak, mapfmt, tilekit, textures, testing;

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

{ The trim atlas index of the first piece of a role in a kit, or -1. }
function RoleAtlas(ki, role: longint): longint;
var pi: longint;
begin
  RoleAtlas := -1;
  pi := KitPieceByRole(ki, role);
  if pi >= 0 then RoleAtlas := Kits[ki].pieces[pi].atlas;
end;

var
  w: TPakWriter;
  p: TPak;
  src: array[0 .. 0] of TKit;
  ki, aw, ah, aI, eI: longint;
begin
  { codec round-trip on synthetic data through a temp pak }
  src[0].tileset := 7;
  src[0].name := 'test';
  SetLength(src[0].pieces, 3);
  src[0].pieces[0].role := KITROLE_FLOOR;
  src[0].pieces[0].lump := 'T_FLOOR'; src[0].pieces[0].fw := 2;
  src[0].pieces[0].fh := 2; src[0].pieces[0].fz := 1;
  src[0].pieces[0].atlas := 0;
  src[0].pieces[0].emis := 255;
  src[0].pieces[1].role := KITROLE_WALL;
  src[0].pieces[1].lump := 'T_WALL'; src[0].pieces[1].fw := 3;
  src[0].pieces[1].fh := 1; src[0].pieces[1].fz := 4;
  src[0].pieces[1].atlas := 2;
  src[0].pieces[1].emis := 3;
  { a multi-material piece: slot 0 is the frame, slot 1 the glowing glass }
  src[0].pieces[2].role := KITROLE_WALL;
  src[0].pieces[2].lump := 'T_WINDOW'; src[0].pieces[2].fw := 3;
  src[0].pieces[2].fh := 1; src[0].pieces[2].fz := 4;
  src[0].pieces[2].atlas := 0;
  src[0].pieces[2].emis := 255;
  SetLength(src[0].pieces[2].xatlas, 1); src[0].pieces[2].xatlas[0] := 1;
  SetLength(src[0].pieces[2].xemis, 1); src[0].pieces[2].xemis[0] := 2;

  PakWInit(w);
  PakWAdd(w, 'KITS', EncodeKits(src));
  Check(PakWFlush(w, TMP), 'write a temp pak with a KITS lump');
  Check(PakLoad(TMP, p), 'reload the temp pak');
  Check(LoadKits(p), 'decode the kits lump');

  ki := KitIndexForTileset(7);
  Check(ki >= 0, 'the synthetic kit is found by tileset');
  CheckEqI(Length(Kits[ki].pieces), 3, 'all three pieces round-trip');
  CheckEqI(RoleFW(ki, KITROLE_FLOOR), 2, 'the floor footprint round-trips');
  CheckEqI(RoleFW(ki, KITROLE_WALL), 3, 'the wall span round-trips');
  Check(RoleLump(ki, KITROLE_WALL) = 'T_WALL', 'the wall lump round-trips');
  CheckEqI(RoleAtlas(ki, KITROLE_FLOOR), 0, 'the floor atlas round-trips');
  CheckEqI(RoleAtlas(ki, KITROLE_WALL), 2, 'the wall atlas round-trips');
  CheckEqI(Kits[ki].pieces[KitPieceByRole(ki, KITROLE_FLOOR)].emis, 255,
    'a non-emissive piece round-trips as none');
  CheckEqI(Kits[ki].pieces[KitPieceByRole(ki, KITROLE_WALL)].emis, 3,
    'the emission atlas round-trips');

  { the multi-material window piece: its extra slot round-trips, and the
    material accessors resolve each slot's atlas and emission }
  CheckEqI(KitPieceMatCount(Kits[ki].pieces[1]), 1, 'a plain piece has one material');
  CheckEqI(KitPieceMatCount(Kits[ki].pieces[2]), 2, 'the window piece has two materials');
  KitPieceMaterial(Kits[ki].pieces[2], 0, aI, eI);
  Check((aI = 0) and (eI = 255), 'slot 0 is the frame, non-emissive');
  KitPieceMaterial(Kits[ki].pieces[2], 1, aI, eI);
  Check((aI = 1) and (eI = 2), 'slot 1 is the glass, with its emission atlas');
  KitPieceMaterial(Kits[ki].pieces[2], 5, aI, eI);
  Check((aI = 0) and (eI = 255), 'an out-of-range slot falls back to slot 0');

  Check(not TilesetHasKit(3), 'a tileset with no kit reports none');

  { TrimPtr selects a tileset's resident atlas by index, falls back to atlas 0,
    and EmisPtr does not; a second tileset keeps its own atlases }
  SetLength(TrimSets[7], 2);
  SetLength(TrimSets[7][0].data, 4);
  TrimSets[7][0].w := 2; TrimSets[7][0].h := 2;
  SetLength(TrimSets[7][1].data, 16);
  TrimSets[7][1].w := 4; TrimSets[7][1].h := 4;
  SetLength(TrimSets[8], 1);
  SetLength(TrimSets[8][0].data, 64);
  TrimSets[8][0].w := 8; TrimSets[8][0].h := 8;
  Check(TrimPtr(7, 0, aw, ah) <> nil, 'atlas 0 resolves to a sheet');
  CheckEqI(aw, 2, 'atlas 0 reports its width');
  Check(TrimPtr(7, 1, aw, ah) <> nil, 'atlas 1 resolves to a sheet');
  CheckEqI(aw, 4, 'atlas 1 reports its width');
  Check(TrimPtr(7, 5, aw, ah) <> nil, 'an out-of-range atlas falls back');
  CheckEqI(aw, 2, 'the fallback uses atlas 0');
  Check(TrimPtr(8, 0, aw, ah) <> nil, 'another tileset keeps its own atlas');
  CheckEqI(aw, 8, 'that tileset reports its own width');
  Check(EmisPtr(7, 1, aw, ah) <> nil, 'EmisPtr resolves a resident atlas');
  Check(EmisPtr(7, 5, aw, ah) = nil, 'EmisPtr does not fall back to atlas 0');
  TrimSets[7] := nil; TrimSets[8] := nil;
  Check(TrimPtr(7, 0, aw, ah) = nil, 'no resident sheets yields nil');

  { the baked mausoleum kit from content/tilesets.txt }
  Check(PakLoad('build/game.pak', p), 'load build/game.pak (run make first)');
  Check(LoadKits(p), 'load the baked kits');
  ki := KitIndexForTileset(TILESET_MODULAR);
  Check(ki >= 0, 'the modular tileset carries a kit');
  Check(KitPieceByRole(ki, KITROLE_FLOOR) >= 0, 'the mausoleum kit has a floor');
  Check(KitPieceByRole(ki, KITROLE_CEIL) >= 0, 'the mausoleum kit has a ceiling');
  Check(KitPieceByRole(ki, KITROLE_WALL) >= 0, 'the mausoleum kit has a wall');
  Check(KitPieceByRole(ki, KITROLE_PILLAR) >= 0, 'the mausoleum kit has a pillar');
  Check(RoleLump(ki, KITROLE_FLOOR) = 'MAUS_FLOOR', 'the floor names MAUS_FLOOR');
  CheckEqI(RoleFW(ki, KITROLE_FLOOR), 3, 'the mausoleum floor is 3 units wide');
  CheckEqI(RoleAtlas(ki, KITROLE_CEIL), 2, 'the ceiling samples its own atlas');

  { the baked clerestory kit (tileset 14) carries the two-material window }
  ki := KitIndexForTileset(14);
  Check(ki >= 0, 'the clerestory tileset carries a kit');
  Check(RoleLump(ki, KITROLE_WALL) = 'CATH_WINDOW', 'its wall is the window piece');
  CheckEqI(KitPieceMatCount(Kits[ki].pieces[KitPieceByRole(ki, KITROLE_WALL)]), 2,
    'the window wall is two-material: stone frame and glass');

  TestSummary('tilekit');
  halt(TestExit);
end.
