unit textures;

{** Runtime texture cache, loaded from the pak.

  The surface ids and the Tex array are unchanged, so the renderer and
  the map code do not care where the pixels come from. The pixels are no
  longer generated here; the asset tool writes one PIC lump per surface
  and tileset into the archive.

  Only one tileset is resident at a time. Tex holds the surfaces of the
  map the party stands in; entering a map with a different tileset
  reloads them. This keeps resident texture memory flat whatever the
  zone, which the 2 MB target needs. The door is one shared lump across
  every tileset. }

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
  CurTileset: longint = -1;

{ Load the surfaces of tileset 0, the default. Call once at startup. }
function LoadTextures(const p: TPak): boolean;

{ Make the given tileset resident, reloading Tex from its lumps. A no-op
  when that tileset is already loaded. A surface the tileset does not
  define falls back to tileset 0. Returns false if even the fallback is
  missing. }
function SetTileset(const p: TPak; tileset: longint): boolean;

implementation

const
  { Surface base names, indexed by the TEX_* ids above. }
  LUMP_BASE: array[1 .. TEX_COUNT - 1] of string[8] = (
    'BRICK', 'STONE', 'MOSS', 'DOOR', 'FLOOR', 'CEIL');

function LumpName(id, tileset: longint): string;
begin
  { the door is one shared plank texture, stored once as DOOR0 }
  if id = TEX_DOOR then
    LumpName := 'DOOR0'
  else begin
    Str(tileset, LumpName);
    LumpName := LUMP_BASE[id] + LumpName;
  end;
end;

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

function SetTileset(const p: TPak; tileset: longint): boolean;
var
  id: longint;
begin
  if tileset = CurTileset then begin
    SetTileset := true;
    exit;
  end;
  SetTileset := true;
  for id := 1 to TEX_COUNT - 1 do
    if not LoadOne(p, id, LumpName(id, tileset)) then
      { this tileset lacks the surface: use tileset 0's }
      if not LoadOne(p, id, LumpName(id, 0)) then
        SetTileset := false;
  CurTileset := tileset;
end;

function LoadTextures(const p: TPak): boolean;
begin
  CurTileset := -1;
  LoadTextures := SetTileset(p, 0);
end;

end.
