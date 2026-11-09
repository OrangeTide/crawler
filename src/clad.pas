unit clad;

{** The cladding pass: draw a tileset's sectors from its modular kit meshes
  instead of the procedural surface quads.

  This foundation step places one kit floor piece and one ceiling piece per
  open cell, centred on the cell and scaled to fill one grid unit, at the
  sector floor and ceiling height. A later step merges aligned cells into
  native-scale pieces and clads the walls; the per-cell form proves the
  wiring from the kit table through to the resident trim atlas in the live
  view.

  Kit piece meshes are decoded once into a resident cache keyed by lump,
  sized by every loaded kit. The cladding draws from the resident trim atlas
  (textures.TrimTex), so the map's tileset must be the one whose atlas is
  resident. }

{$mode objfpc}{$H+}

interface

uses
  raster, meshfmt, pak, tilekit;

{ Decode every kit piece mesh into the resident cache. Call after LoadKits. }
procedure CladInit(const p: TPak);

{ Draw the floor (and, when drawCeil, the ceiling) of one open cell from its
  kit, at the sector floor fz and ceiling cz in world units, lit by light
  (0..256). Returns true if the floor was drawn, so the caller can skip the
  procedural quad; false falls back to the quad path. }
function CladFloorCeil(const mc: TMeshCam; kitIdx, tx, ty: longint;
  fz, cz, light: double; drawCeil: boolean): boolean;

implementation

uses
  textures;

var
  cacheName: array of string;
  cacheMesh: array of TMesh;
  cacheOk: array of boolean;

function MeshIdx(const nm: string): longint;
var k: longint;
begin
  MeshIdx := -1;
  for k := 0 to High(cacheName) do
    if cacheName[k] = nm then begin MeshIdx := k; exit; end;
end;

procedure CladInit(const p: TPak);
var
  i, k, mi: longint;
  blob: TByteArray;
  m: TMesh;
  nm: string;
begin
  cacheName := nil; cacheMesh := nil; cacheOk := nil;
  for i := 0 to High(Kits) do
    for k := 0 to High(Kits[i].pieces) do begin
      nm := Kits[i].pieces[k].lump;
      if MeshIdx(nm) >= 0 then continue;   { shared pieces decode once }
      mi := Length(cacheName);
      SetLength(cacheName, mi + 1);
      SetLength(cacheMesh, mi + 1);
      SetLength(cacheOk, mi + 1);
      cacheName[mi] := nm;
      cacheOk[mi] := PakGet(p, nm, blob) and DecodeMesh(blob, m);
      if cacheOk[mi] then cacheMesh[mi] := m;
    end;
end;

{ Draw one kit piece centred on the cell at height mz, scaled so its grid
  footprint (fw units wide) fills one cell. Returns true if drawn. }
function DrawPiece(const mc: TMeshCam; kitIdx, pieceIdx, tx, ty: longint;
  mz, light: double): boolean;
var
  mi: longint;
  sc: double;
  atlas: PByte;
begin
  DrawPiece := false;
  if pieceIdx < 0 then exit;
  mi := MeshIdx(Kits[kitIdx].pieces[pieceIdx].lump);
  if (mi < 0) or (not cacheOk[mi]) then exit;
  if Kits[kitIdx].pieces[pieceIdx].fw > 0 then
    sc := 1.0 / Kits[kitIdx].pieces[pieceIdx].fw
  else
    sc := 1.0;
  atlas := nil;
  if Length(TrimTex) > 0 then atlas := @TrimTex[0];
  RenderMeshAt(cacheMesh[mi], mc, tx + 0.5, ty + 0.5, mz, sc, 0, light,
    atlas, TrimW, TrimH);
  DrawPiece := true;
end;

function CladFloorCeil(const mc: TMeshCam; kitIdx, tx, ty: longint;
  fz, cz, light: double; drawCeil: boolean): boolean;
begin
  CladFloorCeil := false;
  if (kitIdx < 0) or (kitIdx > High(Kits)) then exit;
  CladFloorCeil := DrawPiece(mc, kitIdx,
    KitPieceByRole(kitIdx, KITROLE_FLOOR), tx, ty, fz, light);
  if drawCeil then
    DrawPiece(mc, kitIdx,
      KitPieceByRole(kitIdx, KITROLE_CEIL), tx, ty, cz, light);
end;

end.
