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

const
  { VRAM a model costs when resident, in bytes. Every model texture is
    quantized to the one shared game palette, so on the PSX they share a
    single CLUT and the per-model cost is just the texture, one byte per
    texel in an 8-bit texture page. Geometry lives in main RAM and is
    tracked apart from this. }
  MODEL_GEOM_VERT_BYTES = 8;   { a PSX textured vertex: SVECTOR plus UV }

  { The VRAM left for model textures loaded at once, after the double
    framebuffer and the UI and world pages are reserved out of the 1MB.
    Lower this to force smaller per-area model sets. }
  MODEL_VRAM_BUDGET = 256 * 1024;

type
  TModel = record
    name: string[12];
    mesh: TMesh;
    scale: double;      { world units per model unit }
    loaded: boolean;
    vramCost: longint;  { texture bytes resident in VRAM }
    ramCost: longint;   { geometry bytes resident in main RAM }
  end;

{ Load every known model from the pak. Missing ones are skipped, not fatal. }
function LoadModels(const p: TPak): boolean;

{ Load only the named models, freeing any others: the per-area cache gate.
  A name not in the set is left unloaded, so FindModel returns -1 and the
  caller falls back to a glyph. Returns true if any model loaded. }
function LoadModelSet(const p: TPak; const names: array of string): boolean;

{ Index of a model by name, or -1. }
function FindModel(const name: string): longint;

{ The VRAM cost of one model by name, or 0 if it is not loaded. }
function ModelVramCost(const name: string): longint;

{ The VRAM a set of models would occupy loaded together. A name repeated
  in the set is counted once, since the cache holds each mesh a single
  time however many monsters share it. }
function ModelSetVramCost(const names: array of string): longint;

{ Whether a set of models fits the simultaneous VRAM budget. }
function ModelSetFitsVram(const names: array of string): boolean;

var
  ModelReg: array of TModel;

implementation

type
  TModelDef = record
    name: string[12];
    targetHeight: double;   { how tall the model should stand, in tiles }
  end;

const
  ModelDefs: array[0 .. 16] of TModelDef = (
    (name: 'BARREL';  targetHeight: 0.7),
    (name: 'DOORWAY'; targetHeight: 1.7),
    (name: 'CREA1';  targetHeight: 1.2),
    (name: 'CREA2';  targetHeight: 1.2),
    (name: 'CREA3';  targetHeight: 1.2),
    (name: 'CREA4';  targetHeight: 1.2),
    (name: 'CREA5';  targetHeight: 1.2),
    (name: 'CREA6';  targetHeight: 1.2),
    (name: 'CREA7';  targetHeight: 1.2),
    (name: 'CREA8';  targetHeight: 1.2),
    (name: 'CREA9';  targetHeight: 1.2),
    (name: 'CREA10'; targetHeight: 1.2),
    (name: 'CREA11'; targetHeight: 1.2),
    (name: 'CREA12'; targetHeight: 1.2),
    (name: 'CREA13'; targetHeight: 1.2),
    (name: 'FLESH1'; targetHeight: 1.0),
    (name: 'FLESH2'; targetHeight: 1.0)
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

function InNameSet(const name: string; const names: array of string): boolean;
var i: longint;
begin
  InNameSet := false;
  for i := 0 to High(names) do
    if names[i] = name then begin InNameSet := true; exit; end;
end;

function LoadModelSet(const p: TPak; const names: array of string): boolean;
var
  i, n: longint;
  blob: TByteArray;
  m: TMesh;
begin
  if Length(ModelReg) <> Length(ModelDefs) then
    SetLength(ModelReg, Length(ModelDefs));
  n := 0;
  for i := 0 to High(ModelDefs) do begin
    ModelReg[i].name := ModelDefs[i].name;
    if InNameSet(ModelDefs[i].name, names)
      and PakGet(p, ModelDefs[i].name, blob) and DecodeMesh(blob, m) then begin
      ModelReg[i].mesh := m;
      ModelReg[i].scale := ModelDefs[i].targetHeight / MeshHeight(m);
      ModelReg[i].vramCost := m.texW * m.texH;
      ModelReg[i].ramCost := Length(m.verts) * MODEL_GEOM_VERT_BYTES;
      ModelReg[i].loaded := true;
      inc(n);
    end else begin
      ModelReg[i].loaded := false;
      ModelReg[i].scale := 1;
      ModelReg[i].vramCost := 0;
      ModelReg[i].ramCost := 0;
      ModelReg[i].mesh.verts := nil;
      ModelReg[i].mesh.tex := nil;
    end;
  end;
  LoadModelSet := n > 0;
end;

function LoadModels(const p: TPak): boolean;
var
  names: array of string;
  i: longint;
begin
  SetLength(names, Length(ModelDefs));
  for i := 0 to High(ModelDefs) do names[i] := ModelDefs[i].name;
  LoadModels := LoadModelSet(p, names);
end;

function ModelVramCost(const name: string): longint;
var i: longint;
begin
  i := FindModel(name);
  if i >= 0 then ModelVramCost := ModelReg[i].vramCost else ModelVramCost := 0;
end;

function ModelSetVramCost(const names: array of string): longint;
var
  i, j, total: longint;
  seen: boolean;
begin
  total := 0;
  for i := 0 to High(names) do begin
    seen := false;
    for j := 0 to i - 1 do
      if names[j] = names[i] then begin seen := true; break; end;
    if not seen then total := total + ModelVramCost(names[i]);
  end;
  ModelSetVramCost := total;
end;

function ModelSetFitsVram(const names: array of string): boolean;
begin
  ModelSetFitsVram := ModelSetVramCost(names) <= MODEL_VRAM_BUDGET;
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
