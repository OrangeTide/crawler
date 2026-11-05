unit models;

{** The model registry: baked meshes the polygon renderer instances.

  Each model is loaded from its pak lump into a mesh once. A model also
  carries a display scale, derived at load from a target height, so a
  prop placed on a tile is sized sensibly whatever units the source used.
  Props reference a model by name; the renderer looks it up here. }

{$mode objfpc}{$H+}

interface

uses
  pak, meshfmt;

type
  TModel = record
    name: string[12];
    mesh: TMesh;
    scale: double;      { world units per model unit }
    loaded: boolean;
  end;

{ Load every known model from the pak. Missing ones are skipped, not fatal. }
function LoadModels(const p: TPak): boolean;

{ Index of a model by name, or -1. }
function FindModel(const name: string): longint;

var
  ModelReg: array of TModel;

implementation

type
  TModelDef = record
    name: string[12];
    targetHeight: double;   { how tall the model should stand, in tiles }
  end;

const
  ModelDefs: array[0 .. 1] of TModelDef = (
    (name: 'BARREL'; targetHeight: 0.7),
    (name: 'DOOR';   targetHeight: 1.7)
  );

{ The model's height in its own units, to derive a scale. }
function MeshHeight(const m: TMesh): double;
var
  i: longint;
  minz, maxz: single;
begin
  if Length(m.verts) = 0 then begin MeshHeight := 1; exit; end;
  minz := m.verts[0].z; maxz := minz;
  for i := 1 to High(m.verts) do begin
    if m.verts[i].z < minz then minz := m.verts[i].z;
    if m.verts[i].z > maxz then maxz := m.verts[i].z;
  end;
  if maxz - minz < 0.0001 then MeshHeight := 1 else MeshHeight := maxz - minz;
end;

function LoadModels(const p: TPak): boolean;
var
  i, n: longint;
  blob: TByteArray;
  m: TMesh;
begin
  SetLength(ModelReg, Length(ModelDefs));
  n := 0;
  for i := 0 to High(ModelDefs) do begin
    ModelReg[i].name := ModelDefs[i].name;
    ModelReg[i].loaded := false;
    ModelReg[i].scale := 1;
    if PakGet(p, ModelDefs[i].name, blob) and DecodeMesh(blob, m) then begin
      ModelReg[i].mesh := m;
      ModelReg[i].scale := ModelDefs[i].targetHeight / MeshHeight(m);
      ModelReg[i].loaded := true;
      inc(n);
    end;
  end;
  LoadModels := n > 0;
end;

function FindModel(const name: string): longint;
var i: longint;
begin
  FindModel := -1;
  for i := 0 to High(ModelReg) do
    if ModelReg[i].loaded and (ModelReg[i].name = name) then begin
      FindModel := i; exit;
    end;
end;

end.
