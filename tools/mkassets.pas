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
  monsters, montext, chardata, chartext, dialog, dialogtext,
  worldfmt, worldtext, meshfmt, models;

var
  w: TPakWriter;
  img: TImage;
  outPath: string;
  modelVram, modelRam: longint;   { running VRAM and RAM totals across models }

procedure AddTex(const name: string; genProc: longint);
begin
  case genProc of
    0: GenBrick(img);
    1: GenStone(img);
    2: GenMoss(img);
    3: GenDoor(img);
    4: GenFloor(img);
    5: GenCeiling(img);
  end;
  PakWAdd(w, name, PicEncodeDirect(img));
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
  AddTex('BRICK', 0);
  AddTex('STONE', 1);
  AddTex('MOSS',  2);
  AddTex('DOOR',  3);
  AddTex('FLOOR', 4);
  AddTex('CEIL',  5);

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
    end else if ParamStr(i) = 'world' then begin
      AddWorld(ParamStr(i + 1)); inc(i, 2);
    end else if ParamStr(i) = 'music' then begin
      AddMusic(ParamStr(i + 1), ParamStr(i + 2)); inc(i, 3);
    end else if ParamStr(i) = 'model' then begin
      AddModel(ParamStr(i + 1), ParamStr(i + 2), ParamStr(i + 3)); inc(i, 4);
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
