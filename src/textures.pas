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

  { One resident trim-sheet atlas in three forms. data is the indexed form the
    software renderer samples (quantized to the shared game palette). rgba keeps
    the atlas in its own direct colour, used for the emission channel, which is
    additive and not part of the tileset CLUT. cidx is the atlas remapped to its
    tileset's CLUT, the paletted diffuse form the direct-colour backends bind
    and look up through the CLUT, as the PlayStation does. cidx is empty when
    the tileset carries no CLUT. }
  TTrimSheet = record
    data: array of byte;
    rgba: array of TColor;
    cidx: array of byte;
    w, h: longint;
  end;

  { A baked per-tileset colour lookup table: 256 direct colours, median-cut
    from the tileset's own trim atlases at bake time. The direct-colour
    backends (desktop OpenGL and the PS1 GPU) bind one CLUT per tileset and
    sample the diffuse trim as indices into it. }
  TClut = array[0 .. 255] of TColor;
  PClut = ^TClut;

var
  Tex: array[0 .. TEX_COUNT - 1] of TTexture;
  CurTileset: longint = -1;

const
  MAX_TILESET = 31;       { tileset indices 0..31; kits live past the biomes }

var
  { The resident trim-sheet atlases, one set per tileset, as palette indices
    (the shared textures the modular tiles sample). Most kits use one (atlas 0);
    a multi-material kit lists several, and each piece names the one it samples.
    Keyed by tileset so a map that mixes sectors of different tilesets (a lava
    lake in a rock cavern) can reach each sector's own atlases. Empty when the
    tileset defines no modular pieces. }
  TrimSets: array[0 .. MAX_TILESET] of array of TTrimSheet;
  TrimLoaded: array[0 .. MAX_TILESET] of boolean;

  { The resident per-tileset CLUT, loaded alongside the trim atlases. ClutHas
    is false for a tileset with no baked CLUT lump (the biome tilesets), where
    the GPU falls back to the shared-palette indexed form. }
  TrimClut: array[0 .. MAX_TILESET] of TClut;
  ClutHas: array[0 .. MAX_TILESET] of boolean;

  { Atlas 0 of the current tileset, kept as its own fields for the single-atlas
    callers (the authored .room render path and the headless tool). }
  TrimTex: array of byte;
  TrimW, TrimH: longint;

{ A tileset's atlas at `index` as a pointer and dimensions, falling back to
  that tileset's atlas 0 for an out-of-range or empty index. Returns nil when
  the tileset has no atlas resident. }
function TrimPtr(tileset, index: longint; out w, h: longint): PByte;
{ A tileset's emission atlas at `index`, or nil for index 255 (none) or a
  non-resident index. Never falls back to atlas 0. }
function EmisPtr(tileset, index: longint; out w, h: longint): PByte;

{ A tileset's diffuse atlas at `index` remapped to its CLUT, the paletted form
  the direct-colour backends sample and look up through the tileset CLUT. nil
  when the tileset has no CLUT. Same fallback rules as TrimPtr. }
function TrimClutIdxPtr(tileset, index: longint; out w, h: longint): PByte;
{ A tileset's resident CLUT (256 colours), or nil when it has none. }
function TilesetClut(tileset: longint): PClut;
{ A tileset's emission atlas at `index` in its own direct colour (ARGB), the
  additive emission channel which is not part of the CLUT. nil for index 255 or
  a non-resident index. }
function EmisRGBAPtr(tileset, index: longint; out w, h: longint): PColorArray;

{ The baked CLUT lump name for a tileset, CLUT<tileset>. }
function ClutLumpName(tileset: longint): string;
{ Decode a tileset's baked CLUT from the pak into cols (256 colours), or false
  when the tileset carries no CLUT lump (the biome tilesets, and any kit with
  no baked palette). Slots past the baked colour count come back black. Not
  used by the indexed renderer yet; it is the palette the direct-colour
  backends will bind per tileset. }
function LoadTilesetClut(const p: TPak; tileset: longint; out cols: TClut): boolean;

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

function ClutLumpName(tileset: longint): string;
var s: string;
begin
  Str(tileset, s);
  ClutLumpName := 'CLUT' + s;
end;

function LoadTilesetClut(const p: TPak; tileset: longint; out cols: TClut): boolean;
var
  blob: TByteArray;
  img: TImage;
  i, n: longint;
begin
  LoadTilesetClut := false;
  for i := 0 to 255 do cols[i] := 0;
  if not PakGet(p, ClutLumpName(tileset), blob) then exit;
  if not PicDecode(blob, img) then exit;
  n := img.w * img.h;
  if n > 256 then n := 256;
  for i := 0 to n - 1 do cols[i] := img.pix[i];
  LoadTilesetClut := true;
end;

{ The CLUT entry nearest a colour, by squared RGB distance. The scan stops on
  an exact hit, which is common since the CLUT is median-cut from these atlases. }
function NearestClut(const clut: TClut; c: TColor): byte;
var
  i, best, bestd, d, dr, dg, db, r, g, b: longint;
begin
  r := (c shr 16) and $FF; g := (c shr 8) and $FF; b := c and $FF;
  best := 0; bestd := MaxLongint;
  for i := 0 to 255 do begin
    dr := r - longint((clut[i] shr 16) and $FF);
    dg := g - longint((clut[i] shr 8) and $FF);
    db := b - longint(clut[i] and $FF);
    d := dr * dr + dg * dg + db * db;
    if d < bestd then begin
      bestd := d; best := i;
      if d = 0 then break;
    end;
  end;
  NearestClut := best;
end;

{ Remap a tileset's resident trim atlases to its CLUT, filling each sheet's
  cidx. A 15-bit (5 bits per channel) cache bounds the nearest-colour scans so
  the whole tileset costs a few thousand searches, not one per texel. }
procedure BuildClutIndices(tileset: longint);
var
  a, i, n, key: longint;
  c: TColor;
  cache: array[0 .. 32767] of smallint;
begin
  for i := 0 to 32767 do cache[i] := -1;
  for a := 0 to High(TrimSets[tileset]) do begin
    n := Length(TrimSets[tileset][a].rgba);
    SetLength(TrimSets[tileset][a].cidx, n);
    for i := 0 to n - 1 do begin
      c := TrimSets[tileset][a].rgba[i];
      key := (((c shr 19) and 31) shl 10)
          or (((c shr 11) and 31) shl 5)
          or ((c shr 3) and 31);
      if cache[key] < 0 then
        cache[key] := NearestClut(TrimClut[tileset], c);
      TrimSets[tileset][a].cidx[i] := byte(cache[key]);
    end;
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
  if (tileset < 0) or (tileset > MAX_TILESET) then begin
    LoadTrims := false; exit;
  end;
  if TrimLoaded[tileset] then begin
    LoadTrims := Length(TrimSets[tileset]) > 0; exit;
  end;
  TrimLoaded[tileset] := true;
  TrimSets[tileset] := nil;
  a := 0;
  while PakGet(p, TrimLumpName(tileset, a), blob) do begin
    if not PicDecode(blob, img) then break;
    SetLength(TrimSets[tileset], a + 1);
    n := img.w * img.h;
    SetLength(TrimSets[tileset][a].data, n);
    SetLength(TrimSets[tileset][a].rgba, n);
    for i := 0 to n - 1 do begin
      TrimSets[tileset][a].data[i] := Quantize(img.pix[i]);
      TrimSets[tileset][a].rgba[i] := img.pix[i];
    end;
    TrimSets[tileset][a].w := img.w; TrimSets[tileset][a].h := img.h;
    inc(a);
  end;
  { Load the tileset CLUT and build the paletted diffuse form, so the GPU can
    sample the trim through the tileset's own palette as the PS1 does. }
  ClutHas[tileset] := LoadTilesetClut(p, tileset, TrimClut[tileset]);
  if ClutHas[tileset] and (Length(TrimSets[tileset]) > 0) then
    BuildClutIndices(tileset);
  LoadTrims := Length(TrimSets[tileset]) > 0;
end;

function TrimPtr(tileset, index: longint; out w, h: longint): PByte;
var sheets: longint;
begin
  TrimPtr := nil; w := 0; h := 0;
  if (tileset < 0) or (tileset > MAX_TILESET) then exit;
  sheets := Length(TrimSets[tileset]);
  if sheets = 0 then exit;
  if (index < 0) or (index >= sheets)
    or (Length(TrimSets[tileset][index].data) = 0) then
    index := 0;
  if Length(TrimSets[tileset][index].data) = 0 then exit;
  w := TrimSets[tileset][index].w; h := TrimSets[tileset][index].h;
  TrimPtr := @TrimSets[tileset][index].data[0];
end;

function EmisPtr(tileset, index: longint; out w, h: longint): PByte;
{** The emission atlas for a piece, or nil when the piece names none (255) or
  the index is not a resident sheet. Unlike TrimPtr it never falls back to
  atlas 0, so a non-emissive piece adds no glow. }
begin
  EmisPtr := nil; w := 0; h := 0;
  if (tileset < 0) or (tileset > MAX_TILESET) then exit;
  if (index < 0) or (index >= Length(TrimSets[tileset])) then exit;
  if Length(TrimSets[tileset][index].data) = 0 then exit;
  w := TrimSets[tileset][index].w; h := TrimSets[tileset][index].h;
  EmisPtr := @TrimSets[tileset][index].data[0];
end;

function TrimClutIdxPtr(tileset, index: longint; out w, h: longint): PByte;
var sheets: longint;
begin
  TrimClutIdxPtr := nil; w := 0; h := 0;
  if (tileset < 0) or (tileset > MAX_TILESET) then exit;
  sheets := Length(TrimSets[tileset]);
  if sheets = 0 then exit;
  if (index < 0) or (index >= sheets)
    or (Length(TrimSets[tileset][index].cidx) = 0) then
    index := 0;
  if Length(TrimSets[tileset][index].cidx) = 0 then exit;
  w := TrimSets[tileset][index].w; h := TrimSets[tileset][index].h;
  TrimClutIdxPtr := @TrimSets[tileset][index].cidx[0];
end;

function TilesetClut(tileset: longint): PClut;
begin
  TilesetClut := nil;
  if (tileset < 0) or (tileset > MAX_TILESET) then exit;
  if not ClutHas[tileset] then exit;
  TilesetClut := @TrimClut[tileset];
end;

function EmisRGBAPtr(tileset, index: longint; out w, h: longint): PColorArray;
begin
  EmisRGBAPtr := nil; w := 0; h := 0;
  if (tileset < 0) or (tileset > MAX_TILESET) then exit;
  if (index < 0) or (index >= Length(TrimSets[tileset])) then exit;
  if Length(TrimSets[tileset][index].rgba) = 0 then exit;
  w := TrimSets[tileset][index].w; h := TrimSets[tileset][index].h;
  EmisRGBAPtr := @TrimSets[tileset][index].rgba[0];
end;

function SetTileset(const p: TPak; tileset: longint): boolean;
var
  id, ts: longint;
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
  { Load every tileset's trim atlases, not just this one, so a map whose sectors
    point at other tilesets (a lava lake in a rock cavern) can reach their
    atlases while cladding. Each set loads once and is cached. The atlases are
    optional; their absence is not a failure. }
  for ts := 0 to MAX_TILESET do LoadTrims(p, ts);
  { atlas 0 of the base tileset, for the single-atlas .room and polygon paths }
  TrimTex := nil; TrimW := 0; TrimH := 0;
  if (Length(TrimSets[tileset]) > 0)
    and (Length(TrimSets[tileset][0].data) > 0) then begin
    TrimTex := TrimSets[tileset][0].data;
    TrimW := TrimSets[tileset][0].w; TrimH := TrimSets[tileset][0].h;
  end;
  CurTileset := tileset;
end;

function LoadTextures(const p: TPak): boolean;
begin
  CurTileset := -1;
  LoadTextures := SetTileset(p, 0);
end;

end.
