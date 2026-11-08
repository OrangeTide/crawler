unit pcportrait;

{** Player-character portrait pool.

  A party member carries a portrait index into the baked PORT_PC<NN> lumps.
  The player cycles through the pool at character creation, and the chosen
  face shows in the party strip.

  These are UI images, not world billboards, so they are decoded into a
  small cache of their own rather than the shared sprite registry (which has
  a fixed slot budget the world billboards need). The cache fills lazily:
  only the faces actually drawn are decoded, and each only once. }

{$mode objfpc}{$H+}

interface

uses pic, gfx;

const
  PC_PORTRAIT_MAX = 32;   { the most PORT_PC lumps this will look for }

{ How many PORT_PC lumps the pak holds, counted once. At least one is
  assumed; a pool of zero would leave callers with nothing to show. }
function PCPortraitCount: longint;

{ Keep an index inside the pool, wrapping, so a stale save or an empty pool
  never selects a face that is not there. }
function PCPortraitClamp(idx: longint): longint;

{ Blit portrait idx at its native 64x64 size, skipping the keyed background,
  the way the NPC dialog portrait draws. }
procedure DrawPCPortrait(px, py, idx: longint);

{ Blit portrait idx scaled into a dw by dh box by nearest sampling, skipping
  keyed pixels. For the small party-strip thumbnail. }
procedure DrawPCPortraitScaled(px, py, dw, dh, idx: longint);

implementation

uses sysutils, pak, gamestate;

type
  PImage = ^TImage;
  TEntry = record
    tried: boolean;    { have we attempted to load this index yet }
    ok: boolean;       { did it decode }
    img: TImage;
  end;

var
  cache: array[0 .. PC_PORTRAIT_MAX - 1] of TEntry;
  countCached: longint = -1;

function LumpName(idx: longint): string;
begin
  LumpName := 'PORT_PC' + Format('%.2d', [idx]);
end;

function PCPortraitCount: longint;
var
  blob: pak.TByteArray;
begin
  if countCached < 0 then begin
    countCached := 0;
    while (countCached < PC_PORTRAIT_MAX)
      and PakGet(GamePak, LumpName(countCached), blob) do
      inc(countCached);
  end;
  PCPortraitCount := countCached;
end;

function PCPortraitClamp(idx: longint): longint;
var n: longint;
begin
  n := PCPortraitCount;
  if n <= 0 then begin PCPortraitClamp := 0; exit; end;
  idx := idx mod n;
  if idx < 0 then inc(idx, n);
  PCPortraitClamp := idx;
end;

{ The decoded image for idx, or nil if it is out of range or will not load. }
function Get(idx: longint): PImage;
var blob: pak.TByteArray;
begin
  Get := nil;
  if (idx < 0) or (idx >= PC_PORTRAIT_MAX) then exit;
  if not cache[idx].tried then begin
    cache[idx].tried := true;
    cache[idx].ok := PakGet(GamePak, LumpName(idx), blob)
                     and PicDecode(blob, cache[idx].img);
  end;
  if cache[idx].ok then Get := @cache[idx].img;
end;

procedure DrawPCPortrait(px, py, idx: longint);
var
  img: PImage;
  x, y: longint;
  c: TColor;
begin
  img := Get(idx);
  if img = nil then exit;
  for y := 0 to img^.h - 1 do
    for x := 0 to img^.w - 1 do begin
      c := img^.pix[y * img^.w + x];
      if (c shr 24) < 128 then continue;
      PutPixel(px + x, py + y, c);
    end;
end;

procedure DrawPCPortraitScaled(px, py, dw, dh, idx: longint);
var
  img: PImage;
  dx, dy, sx, sy: longint;
  c: TColor;
begin
  if (dw <= 0) or (dh <= 0) then exit;
  img := Get(idx);
  if img = nil then exit;
  for dy := 0 to dh - 1 do begin
    sy := dy * img^.h div dh;
    for dx := 0 to dw - 1 do begin
      sx := dx * img^.w div dw;
      c := img^.pix[sy * img^.w + sx];
      if (c shr 24) < 128 then continue;
      PutPixel(px + dx, py + dy, c);
    end;
  end;
end;

end.
