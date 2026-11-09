program mkassets;

{** Offline asset builder.

  Generates the procedural textures and compiles the text maps, writing
  everything as lumps into a pak archive. This is the piece that turns
  source into the data files the runtime loads, so the game ships with
  assets on disk rather than building them at startup.

  Usage: mkassets <output.pak> [map FILE] [items FILE] ...
  Each input is named by a keyword so its type is explicit. }

{$mode objfpc}{$H+}

uses
  classes, sysutils, gfx, pic, pak, texgen, mapfmt, maptext, items, itemtext,
  monsters, montext, chardata, chartext, dialog, dialogtext, shops, shoptext,
  encounters, enctext, worldfmt, worldtext, meshfmt, models, spelldb, spelltext,
  skilldb, skilltext;

var
  w: TPakWriter;
  img: TImage;
  outPath: string;
  modelVram, modelRam: longint;   { running VRAM and RAM totals across models }

procedure AddTexLump(const base: string; t, kind: longint);
begin
  case kind of
    0: GenBrick(img, TileSchemes[t]);
    1: GenStone(img, TileSchemes[t]);
    2: GenMoss(img, TileSchemes[t]);
    4: GenFloor(img, TileSchemes[t]);
    5: GenCeiling(img, TileSchemes[t]);
  end;
  PakWAdd(w, base + IntToStr(t), PicEncodeDirect(img));
end;

procedure AddDoor;
begin
  GenDoor(img);
  PakWAdd(w, 'DOOR0', PicEncodeDirect(img));
end;

procedure AddTilesets;
var
  t: longint;
begin
  { Tileset 0 keeps the original BRICK, STONE, MOSS, DOOR, FLOOR, CEIL
    generation order so its noise stream, and therefore its pixels, are
    unchanged. The door is one shared plank texture for every tileset. }
  for t := 0 to NUM_TILESETS - 1 do begin
    AddTexLump('BRICK', t, 0);
    AddTexLump('STONE', t, 1);
    AddTexLump('MOSS',  t, 2);
    if t = 0 then AddDoor;
    AddTexLump('FLOOR', t, 4);
    AddTexLump('CEIL',  t, 5);
  end;
end;

procedure AddMap(const fn: string);
var
  md: TMapData;
  name, err: string;
begin
  if not ParseMapText(fn, md, name, err) then begin
    writeln(StdErr, 'mkassets: ', fn, ': ', err);
    halt(1);
  end;
  if name = '' then begin
    writeln(StdErr, 'mkassets: ', fn, ': map has no name');
    halt(1);
  end;
  PakWAdd(w, name, EncodeMap(md));
  writeln('  map ', name, ' (', md.w, 'x', md.h, ') from ', fn);
end;

procedure AddItems(const fn: string);
var
  defs: array[0 .. 255] of TItemDef;
  dyn: array of TItemDef;
  n, k: longint;
  err: string;
begin
  if not ParseItems(fn, defs, n, err) then begin
    writeln(StdErr, 'mkassets: ', fn, ': ', err);
    halt(1);
  end;
  SetLength(dyn, n);
  for k := 0 to n - 1 do
    dyn[k] := defs[k];
  PakWAdd(w, 'ITEMS', EncodeItems(dyn));
  writeln('  items (', n, ') from ', fn);
end;

procedure AddMonsters(const fn: string);
var
  defs: array[0 .. 255] of TMonsterDef;
  dyn: array of TMonsterDef;
  n, k: longint;
  err: string;
begin
  if not ParseMonsters(fn, defs, n, err) then begin
    writeln(StdErr, 'mkassets: ', fn, ': ', err); halt(1);
  end;
  SetLength(dyn, n);
  for k := 0 to n - 1 do dyn[k] := defs[k];
  PakWAdd(w, 'MONS', EncodeMonsters(dyn));
  writeln('  monsters (', n, ') from ', fn);
end;

procedure AddSpecies(const fn: string);
var
  defs: array[0 .. 63] of TSpeciesDef;
  dyn: array of TSpeciesDef;
  n, k: longint;
  err: string;
begin
  if not ParseSpecies(fn, defs, n, err) then begin
    writeln(StdErr, 'mkassets: ', fn, ': ', err); halt(1);
  end;
  SetLength(dyn, n);
  for k := 0 to n - 1 do dyn[k] := defs[k];
  PakWAdd(w, 'SPEC', EncodeSpecies(dyn));
  writeln('  species (', n, ') from ', fn);
end;

procedure AddClasses(const fn: string);
var
  defs: array[0 .. 63] of TClassDef;
  dyn: array of TClassDef;
  n, k: longint;
  err: string;
begin
  if not ParseClasses(fn, defs, n, err) then begin
    writeln(StdErr, 'mkassets: ', fn, ': ', err); halt(1);
  end;
  SetLength(dyn, n);
  for k := 0 to n - 1 do dyn[k] := defs[k];
  PakWAdd(w, 'CLAS', EncodeClasses(dyn));
  writeln('  classes (', n, ') from ', fn);
end;

procedure AddBackgrounds(const fn: string);
var
  defs: array[0 .. 63] of TBackgroundDef;
  dyn: array of TBackgroundDef;
  n, k: longint;
  err: string;
begin
  if not ParseBackgrounds(fn, defs, n, err) then begin
    writeln(StdErr, 'mkassets: ', fn, ': ', err); halt(1);
  end;
  SetLength(dyn, n);
  for k := 0 to n - 1 do dyn[k] := defs[k];
  PakWAdd(w, 'BKGD', EncodeBackgrounds(dyn));
  writeln('  backgrounds (', n, ') from ', fn);
end;

procedure AddDialogs(const fn: string);
var
  cs: array[0 .. 127] of TConversation;
  dyn: array of TConversation;
  n, k: longint;
  err: string;
begin
  if not ParseDialogs(fn, cs, n, err) then begin
    writeln(StdErr, 'mkassets: ', fn, ': ', err); halt(1);
  end;
  SetLength(dyn, n);
  for k := 0 to n - 1 do dyn[k] := cs[k];
  PakWAdd(w, 'DLGS', EncodeDialogs(dyn));
  writeln('  dialogs (', n, ') from ', fn);
end;

procedure AddSpells(const fn: string);
var
  cs: array[0 .. 255] of TSpellDef;
  dyn: array of TSpellDef;
  n, k: longint;
  err: string;
begin
  if not ParseSpells(fn, cs, n, err) then begin
    writeln(StdErr, 'mkassets: ', fn, ': ', err); halt(1);
  end;
  SetLength(dyn, n);
  for k := 0 to n - 1 do dyn[k] := cs[k];
  PakWAdd(w, 'SPEL', EncodeSpells(dyn));
  writeln('  spells (', n, ') from ', fn);
end;

procedure AddSkills(const fn: string);
var
  cs: array[0 .. 255] of TSkillDef;
  dyn: array of TSkillDef;
  n, k: longint;
  err: string;
begin
  if not ParseSkills(fn, cs, n, err) then begin
    writeln(StdErr, 'mkassets: ', fn, ': ', err); halt(1);
  end;
  SetLength(dyn, n);
  for k := 0 to n - 1 do dyn[k] := cs[k];
  PakWAdd(w, 'SKIL', EncodeSkills(dyn));
  writeln('  skills (', n, ') from ', fn);
end;

procedure AddShops(const fn: string);
var
  cs: array[0 .. 31] of TShopDef;
  dyn: array of TShopDef;
  n, k: longint;
  err: string;
begin
  if not ParseShops(fn, cs, n, err) then begin
    writeln(StdErr, 'mkassets: ', fn, ': ', err); halt(1);
  end;
  SetLength(dyn, n);
  for k := 0 to n - 1 do dyn[k] := cs[k];
  PakWAdd(w, 'SHOP', EncodeShops(dyn));
  writeln('  shops (', n, ') from ', fn);
end;

procedure AddEncounters(const fn: string);
var
  tables: array[0 .. 63] of TEncTable;
  dyn: array of TEncTable;
  areaMap: array[0 .. 255] of byte;
  n, k: longint;
  err: string;
begin
  if not ParseEncounters(fn, tables, n, areaMap, err) then begin
    writeln(StdErr, 'mkassets: ', fn, ': ', err); halt(1);
  end;
  SetLength(dyn, n);
  for k := 0 to n - 1 do dyn[k] := tables[k];
  PakWAdd(w, 'ENCT', EncodeEncounters(dyn, areaMap));
  writeln('  encounters (', n, ' tables) from ', fn);
end;

procedure AddModel(const name, objFn, ppmFn: string);
var
  mesh: TMesh;
  before, after, vram, ram: longint;
begin
  if not LoadMeshObjPpm(objFn, ppmFn, mesh) then begin
    writeln(StdErr, 'mkassets: model ', name, ': cannot bake ', objFn, ' / ', ppmFn);
    halt(1);
  end;
  before := Length(mesh.verts) div 3;
  after := DecimateMesh(mesh, MESH_TRI_BUDGET);
  PakWAdd(w, UpperCase(name), EncodeMesh(mesh));
  vram := mesh.texW * mesh.texH;
  ram := Length(mesh.verts) * MODEL_GEOM_VERT_BYTES;
  modelVram := modelVram + vram;
  modelRam := modelRam + ram;
  if after < before then
    writeln('  model ', UpperCase(name), ' (', after, ' tris, cut from ',
      before, ', ', vram, ' B vram, ', ram, ' B ram) from ', objFn)
  else
    writeln('  model ', UpperCase(name), ' (', after, ' tris, ',
      vram, ' B vram, ', ram, ' B ram) from ', objFn);
end;

procedure AddTile(const name, objFn: string; budget: longint);
{ Bake a modular kit piece as a shared-texture tile: geometry only, its
  UVs indexing the tileset trim atlas, decimated to the per-tile budget.
  The authored origin is kept (recenter off) so pieces tile together. }
var
  mesh: TMesh;
  before, after, ram: longint;
begin
  if not LoadMeshObj(objFn, mesh) then begin
    writeln(StdErr, 'mkassets: tile ', name, ': cannot bake ', objFn);
    halt(1);
  end;
  before := Length(mesh.verts) div 3;
  after := DecimateMesh(mesh, budget, false);
  PakWAdd(w, UpperCase(name), EncodeMesh(mesh));
  ram := Length(mesh.verts) * MODEL_GEOM_VERT_BYTES;
  modelRam := modelRam + ram;   { no VRAM: every tile shares the one atlas }
  if after < before then
    writeln('  tile ', UpperCase(name), ' (', after, ' tris, cut from ',
      before, ', shared tex, ', ram, ' B ram) from ', objFn)
  else
    writeln('  tile ', UpperCase(name), ' (', after, ' tris, shared tex, ',
      ram, ' B ram) from ', objFn);
end;

procedure AddTrimSheet(tileset: longint; const ppmFn: string);
{ Bake a tileset's trim-sheet atlas from a binary PPM into a TRIM<n> PIC,
  the one shared texture its modular tiles draw from. }
var
  sw, sh, i: longint;
  pixbuf: TByteArray;
  atlas: TImage;
begin
  if not ReadPpm(ppmFn, sw, sh, pixbuf) then begin
    writeln(StdErr, 'mkassets: trim ', tileset, ': cannot read ', ppmFn);
    halt(1);
  end;
  ImgNew(atlas, sw, sh);
  for i := 0 to sw * sh - 1 do
    atlas.pix[i] := RGB(pixbuf[i * 3], pixbuf[i * 3 + 1], pixbuf[i * 3 + 2]);
  PakWAdd(w, 'TRIM' + IntToStr(tileset), PicEncodeDirect(atlas));
  writeln('  trim TRIM', tileset, ' (', sw, 'x', sh, ') from ', ppmFn);
end;

procedure AddSprite(const name, ppmFn: string);
{ Ingest a billboard sprite from a binary PPM. Magenta (255,0,255) pixels
  become the transparent key; the rest keep their colour. Shipped as a
  format-0 ARGB PIC with the alpha flag, which PicDecode reads back. }
var
  sw, sh, i: longint;
  pixbuf: TByteArray;
  spr: TImage;
  r, g, b: byte;
begin
  if not ReadPpm(ppmFn, sw, sh, pixbuf) then begin
    writeln(StdErr, 'mkassets: sprite ', name, ': cannot read ', ppmFn);
    halt(1);
  end;
  ImgNew(spr, sw, sh);
  spr.hasAlpha := true;
  for i := 0 to sw * sh - 1 do begin
    r := pixbuf[i * 3]; g := pixbuf[i * 3 + 1]; b := pixbuf[i * 3 + 2];
    if (r = 255) and (g = 0) and (b = 255) then
      spr.pix[i] := 0                      { magenta key -> transparent }
    else
      spr.pix[i] := RGB(r, g, b);
  end;
  PakWAdd(w, UpperCase(name), PicEncodeDirect(spr));
  writeln('  sprite ', UpperCase(name), ' (', sw, 'x', sh, ') from ', ppmFn);
end;

procedure AddMusic(const lump, fn: string);
{ Bundle a tracker module file verbatim as a lump. The module format is
  not parsed here; libxmp identifies it at load time, so any of .xm, .it,
  .s3m or .mod works. A missing file is not an error: that track just
  stays silent until a module is dropped in. }
var
  fs: TFileStream;
  blob: TByteArray;
begin
  if not FileExists(fn) then begin
    writeln('  music ', lump, ' skipped (no ', fn, ')');
    exit;
  end;
  fs := TFileStream.Create(fn, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(blob, fs.Size);
    if fs.Size > 0 then
      fs.ReadBuffer(blob[0], fs.Size);
  finally
    fs.Free;
  end;
  PakWAdd(w, lump, blob);
  writeln('  music ', lump, ' (', Length(blob), ' B) from ', fn);
end;

procedure AddWorld(const fn: string);
var
  d: array[0 .. 63] of TDynMap;
  dyn: array of TDynMap;
  n, k: longint;
  err: string;
begin
  if not ParseWorld(fn, d, n, err) then begin
    writeln(StdErr, 'mkassets: ', fn, ': ', err); halt(1);
  end;
  SetLength(dyn, n);
  for k := 0 to n - 1 do dyn[k] := d[k];
  PakWAdd(w, 'WRLD', EncodeWorld(dyn));
  writeln('  world (', n, ' dynamic maps) from ', fn);
end;

var
  i: longint;
begin
  if ParamCount < 1 then begin
    writeln(StdErr, 'usage: mkassets <output.pak> [map FILE] [items FILE] ...');
    halt(1);
  end;
  outPath := ParamStr(1);

  PakWInit(w);
  InitGfx;   { the palette the model baker quantizes textures against }
  modelVram := 0; modelRam := 0;
  AddTilesets;

  i := 2;
  while i <= ParamCount do begin
    if ParamStr(i) = 'map' then begin
      AddMap(ParamStr(i + 1)); inc(i, 2);
    end else if ParamStr(i) = 'items' then begin
      AddItems(ParamStr(i + 1)); inc(i, 2);
    end else if ParamStr(i) = 'monsters' then begin
      AddMonsters(ParamStr(i + 1)); inc(i, 2);
    end else if ParamStr(i) = 'species' then begin
      AddSpecies(ParamStr(i + 1)); inc(i, 2);
    end else if ParamStr(i) = 'classes' then begin
      AddClasses(ParamStr(i + 1)); inc(i, 2);
    end else if ParamStr(i) = 'backgrounds' then begin
      AddBackgrounds(ParamStr(i + 1)); inc(i, 2);
    end else if ParamStr(i) = 'dialogs' then begin
      AddDialogs(ParamStr(i + 1)); inc(i, 2);
    end else if ParamStr(i) = 'spells' then begin
      AddSpells(ParamStr(i + 1)); inc(i, 2);
    end else if ParamStr(i) = 'skills' then begin
      AddSkills(ParamStr(i + 1)); inc(i, 2);
    end else if ParamStr(i) = 'shops' then begin
      AddShops(ParamStr(i + 1)); inc(i, 2);
    end else if ParamStr(i) = 'encounters' then begin
      AddEncounters(ParamStr(i + 1)); inc(i, 2);
    end else if ParamStr(i) = 'world' then begin
      AddWorld(ParamStr(i + 1)); inc(i, 2);
    end else if ParamStr(i) = 'music' then begin
      AddMusic(ParamStr(i + 1), ParamStr(i + 2)); inc(i, 3);
    end else if ParamStr(i) = 'model' then begin
      AddModel(ParamStr(i + 1), ParamStr(i + 2), ParamStr(i + 3)); inc(i, 4);
    end else if ParamStr(i) = 'tile' then begin
      AddTile(ParamStr(i + 1), ParamStr(i + 2),
        StrToIntDef(ParamStr(i + 3), 128)); inc(i, 4);
    end else if ParamStr(i) = 'trim' then begin
      AddTrimSheet(StrToIntDef(ParamStr(i + 1), 0), ParamStr(i + 2)); inc(i, 3);
    end else if ParamStr(i) = 'sprite' then begin
      AddSprite(ParamStr(i + 1), ParamStr(i + 2)); inc(i, 3);
    end else begin
      writeln(StdErr, 'mkassets: unknown input keyword ', ParamStr(i));
      halt(1);
    end;
  end;

  if not PakWFlush(w, outPath) then begin
    writeln(StdErr, 'mkassets: could not write ', outPath);
    halt(1);
  end;
  if modelVram > 0 then
    writeln('  models total: ', modelVram, ' B vram (all at once would need ',
      (modelVram * 100) div MODEL_VRAM_BUDGET, '% of the ', MODEL_VRAM_BUDGET,
      ' B budget), ', modelRam, ' B ram');
  writeln('mkassets: wrote ', outPath);
end.
