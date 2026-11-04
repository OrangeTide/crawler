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
  sysutils, gfx, pic, pak, texgen, mapfmt, maptext, items, itemtext;

var
  w: TPakWriter;
  img: TImage;
  outPath: string;

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

var
  i: longint;
begin
  if ParamCount < 1 then begin
    writeln(StdErr, 'usage: mkassets <output.pak> [map FILE] [items FILE] ...');
    halt(1);
  end;
  outPath := ParamStr(1);

  PakWInit(w);
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
    end else begin
      writeln(StdErr, 'mkassets: unknown input keyword ', ParamStr(i));
      halt(1);
    end;
  end;

  if not PakWFlush(w, outPath) then begin
    writeln(StdErr, 'mkassets: could not write ', outPath);
    halt(1);
  end;
  writeln('mkassets: wrote ', outPath);
end.
