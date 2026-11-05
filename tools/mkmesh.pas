program mkmesh;

{** Offline mesh baker.

  Usage: mkmesh <out.cmsh> <model.obj> <texture.ppm>

  Reads a Wavefront OBJ (triangulated, with UVs) and a binary PPM
  texture, quantizes the texture to the game palette, and writes a
  'CMSH' lump. Convert source models with assimp and textures with
  ImageMagick first, for example:

    assimp export Barrel_1.glb barrel.obj -tri
    convert Barrel_1_Base_color.png -resize 64x64\! -depth 8 barrel.ppm
    mkmesh barrel.cmsh barrel.obj barrel.ppm }

{$mode objfpc}{$H+}

uses
  sysutils, classes, pak, gfx, meshfmt;

var
  m: TMesh;
  blob: TByteArray;
  fs: TFileStream;
begin
  if ParamCount < 3 then begin
    writeln(StdErr, 'usage: mkmesh <out.cmsh> <model.obj> <texture.ppm>');
    halt(2);
  end;

  InitGfx;   { the palette the texture is quantized against }

  if not LoadMeshObjPpm(ParamStr(2), ParamStr(3), m) then begin
    writeln(StdErr, 'mkmesh: failed to load ', ParamStr(2), ' / ', ParamStr(3));
    halt(1);
  end;

  blob := EncodeMesh(m);
  fs := TFileStream.Create(ParamStr(1), fmCreate);
  try
    if Length(blob) > 0 then fs.WriteBuffer(blob[0], Length(blob));
  finally
    fs.Free;
  end;

  writeln('  mesh ', ParamStr(1), ': ', Length(m.verts) div 3, ' tris, ',
    m.texW, 'x', m.texH, ' tex, ', Length(blob), ' bytes');
end.
