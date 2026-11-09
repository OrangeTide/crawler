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

  { The modular-tile tileset. Its surfaces fall back to tileset 0, but it
    carries the trim-sheet atlas the modular kit pieces sample. Kept out
    of the authored maps' tileset range so the atlas is resident only when
    a modular area is entered. }

type
  TTexture = array[0 .. TEXSIZE - 1] of TColor;

  { One resident trim-sheet atlas, as palette indices. }
  TTrimSheet = record
    data: array of byte;
    w, h: longint;
  end;

var
  Tex: array[0 .. TEX_COUNT - 1] of TTexture;
  CurTileset: longint = -1;

  { The resident trim-sheet atlases for the current tileset, as palette
    indices (the shared textures the modular tiles sample). Most kits use one
    (atlas 0); a multi-material kit lists several, and each piece names the one
    it samples. Empty when the tileset defines no modular pieces. The set is
    resident only while its tileset is, the same flat-memory rule the surfaces
    follow. }
  TrimSheets: array of TTrimSheet;

  { Atlas 0, kept as its own fields for the single-atlas callers (the authored
    .room render path and the headless tool). }
  TrimTex: array of byte;
  TrimW, TrimH: longint;

{ The atlas at `index` as a pointer and dimensions, falling back to atlas 0
  for an out-of-range or empty index. Returns nil when no atlas is resident. }
function TrimPtr(index: longint; out w, h: longint): PByte;

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

{ The lump name for atlas `a` of a tileset: TRIM<t> for atlas 0, and
  TRIM<t>_<a> for the rest, so a single-atlas kit is unchanged. }
function TrimLumpName(tileset, a: longint): string;
var s: string;
begin
  Str(tileset, s);
  TrimLumpName := 'TRIM' + s;
  if a > 0 then begin
    Str(a, s);
    TrimLumpName := TrimLumpName + '_' + s;
  end;
end;

{ Load the trim atlases of a tileset: TRIM<t>, then TRIM<t>_1, _2, ... until
  one is missing. A tileset with no TRIM<t> lump stays empty, which simply
  means it has no modular pieces. Returns true when at least one loaded. }
function LoadTrims(const p: TPak; tileset: longint): boolean;
var
  blob: TByteArray;
  img: TImage;
  i, n, a: longint;
begin
  TrimSheets := nil;
  TrimTex := nil; TrimW := 0; TrimH := 0;
  a := 0;
  while PakGet(p, TrimLumpName(tileset, a), blob) do begin
    if not PicDecode(blob, img) then break;
    SetLength(TrimSheets, a + 1);
    n := img.w * img.h;
    SetLength(TrimSheets[a].data, n);
    for i := 0 to n - 1 do
      TrimSheets[a].data[i] := Quantize(img.pix[i]);
    TrimSheets[a].w := img.w; TrimSheets[a].h := img.h;
    inc(a);
  end;
  if Length(TrimSheets) > 0 then begin
    TrimTex := TrimSheets[0].data;   { atlas 0 for the single-atlas callers }
    TrimW := TrimSheets[0].w; TrimH := TrimSheets[0].h;
  end;
  LoadTrims := Length(TrimSheets) > 0;
end;

function TrimPtr(index: longint; out w, h: longint): PByte;
begin
  if (index < 0) or (index >= Length(TrimSheets))
    or (Length(TrimSheets[index].data) = 0) then
    index := 0;
  if (Length(TrimSheets) = 0) or (Length(TrimSheets[index].data) = 0) then begin
    TrimPtr := nil; w := 0; h := 0;
    exit;
  end;
  w := TrimSheets[index].w; h := TrimSheets[index].h;
  TrimPtr := @TrimSheets[index].data[0];
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
  { the trim atlases are optional; their absence is not a failure }
  LoadTrims(p, tileset);
  CurTileset := tileset;
end;

function LoadTextures(const p: TPak): boolean;
begin
  CurTileset := -1;
  LoadTextures := SetTileset(p, 0);
end;

end.
