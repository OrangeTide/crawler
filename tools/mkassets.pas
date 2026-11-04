program mkassets;

{** Offline asset builder.

  Generates the procedural textures and writes them as PIC lumps into a
  pak archive. This is the piece that turns code into the data files the
  runtime loads, so the game ships with assets on disk rather than
  building them at startup.

  Usage: mkassets <output.pak> }

{$mode objfpc}{$H+}

uses
  sysutils, gfx, pic, pak, texgen;

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

begin
  if ParamCount < 1 then begin
    writeln(StdErr, 'usage: mkassets <output.pak>');
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

  if not PakWFlush(w, outPath) then begin
    writeln(StdErr, 'mkassets: could not write ', outPath);
    halt(1);
  end;
  writeln('mkassets: wrote ', outPath);
end.
