program mkmesh;

{** Offline mesh baker.

  Usage: mkmesh <out.cmsh> <model.obj> <texture.ppm> [triBudget]
         mkmesh <out.cmsh> <model.obj> [triBudget]

  The three-argument form reads a Wavefront OBJ (triangulated, with UVs)
  and a binary PPM texture, quantizes the texture to the game palette,
  and writes an embedded-texture 'CMSH' with the mesh centered on its
  footprint. The two-argument form bakes a shared-texture modular tile:
  geometry only, its UVs left to index a trim atlas the renderer supplies,
  and the authored origin kept so pieces tile together. Both reduce the
  mesh to the triangle budget (default MESH_TRI_BUDGET). Convert source
  models with assimp and textures with ImageMagick first, for example:

    assimp export Barrel_1.glb barrel.obj -tri
    convert Barrel_1_Base_color.png -resize 64x64\! -depth 8 barrel.ppm
    mkmesh barrel.cmsh barrel.obj barrel.ppm
    assimp export wall_small_01.glb wall.obj -tri
    mkmesh wall.cmsh wall.obj 128 }

{$mode objfpc}{$H+}

uses
  sysutils, classes, pak, gfx, meshfmt;

var
  m: TMesh;
  blob: TByteArray;
  fs: TFileStream;
  budget, before, after: longint;
  tileForm: boolean;
begin
  if ParamCount < 2 then begin
    writeln(StdErr, 'usage: mkmesh <out.cmsh> <model.obj> <texture.ppm> [triBudget]');
    writeln(StdErr, '       mkmesh <out.cmsh> <model.obj> [triBudget]');
    halt(2);
  end;

  InitGfx;   { the palette the texture is quantized against }

  { a positive-integer third argument (or none) selects the shared-texture
    tile form; otherwise the third argument is a PPM for the embedded form }
  tileForm := (ParamCount < 3) or (StrToIntDef(ParamStr(3), 0) > 0);
  budget := MESH_TRI_BUDGET;

  if tileForm then begin
    if ParamCount >= 3 then budget := StrToIntDef(ParamStr(3), MESH_TRI_BUDGET);
    if not LoadMeshObj(ParamStr(2), m) then begin
      writeln(StdErr, 'mkmesh: failed to load ', ParamStr(2));
      halt(1);
    end;
  end else begin
    if ParamCount >= 4 then budget := StrToIntDef(ParamStr(4), MESH_TRI_BUDGET);
    if not LoadMeshObjPpm(ParamStr(2), ParamStr(3), m) then begin
      writeln(StdErr, 'mkmesh: failed to load ', ParamStr(2), ' / ', ParamStr(3));
      halt(1);
    end;
  end;

  before := Length(m.verts) div 3;
  after := DecimateMesh(m, budget, not tileForm);
  if after < before then
    writeln('  budget ', budget, ': ', before, ' -> ', after, ' tris');

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
