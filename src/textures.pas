unit textures;

{** Runtime texture cache, loaded from the pak.

  The surface ids and the Tex array are unchanged, so the renderer and
  the map code do not care where the pixels come from. The pixels are no
  longer generated here; LoadTextures reads one PIC lump per surface
  from the archive the asset tool built. }

{$mode objfpc}{$H+}

interface

uses
  gfx, pak, pic;

const
  TEXW = 64;
  TEXH = 64;
  TEXSIZE = TEXW * TEXH;

  { Surface ids used by the renderer. Wall ids match map tile values. }
  TEX_BRICK   = 1;
  TEX_STONE   = 2;
  TEX_MOSS    = 3;
  TEX_DOOR    = 4;
  TEX_FLOOR   = 5;
  TEX_CEILING = 6;
  TEX_COUNT   = 7;

type
  TTexture = array[0 .. TEXSIZE - 1] of TColor;

var
  Tex: array[0 .. TEX_COUNT - 1] of TTexture;

function LoadTextures(const p: TPak): boolean;

implementation

const
  LUMP_NAME: array[1 .. TEX_COUNT - 1] of string[8] = (
    'BRICK', 'STONE', 'MOSS', 'DOOR', 'FLOOR', 'CEIL');

function LoadOne(const p: TPak; id: longint; const name: string): boolean;
var
  blob: TByteArray;
  img: TImage;
  i: longint;
begin
  LoadOne := false;
  if not PakGet(p, name, blob) then
    exit;
  if not PicDecode(blob, img) then
    exit;
  if (img.w <> TEXW) or (img.h <> TEXH) then
    exit;
  for i := 0 to TEXSIZE - 1 do
    Tex[id][i] := img.pix[i];
  LoadOne := true;
end;

function LoadTextures(const p: TPak): boolean;
var
  id: longint;
begin
  LoadTextures := true;
  for id := 1 to TEX_COUNT - 1 do
    if not LoadOne(p, id, LUMP_NAME[id]) then
      LoadTextures := false;
end;

end.
