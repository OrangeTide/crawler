unit spellicon;

{** Spell icon pool.

  A spell may name an icon number (1..250) that content/spells.txt carries and
  the baker writes to an SI<NN> lump. Like the player portraits, the icons are
  decoded into a cache of their own rather than the world-billboard registry,
  since they are UI art drawn on demand. The character sheet's spell browser
  draws them small beside each known spell. }

{$mode objfpc}{$H+}

interface

uses pic, gfx;

{ True when icon n is a real, loadable icon. }
function HasSpellIcon(n: longint): boolean;

{ Draw icon n scaled into a dw by dh box by nearest sampling, skipping keyed
  pixels. Does nothing when n names no icon. }
procedure DrawSpellIcon(px, py, dw, dh, n: longint);

implementation

uses sysutils, pak, gamestate;

const
  MAXICON = 256;

type
  PImage = ^TImage;

var
  cache: array[0 .. MAXICON - 1] of record
    tried, ok: boolean;
    img: TImage;
  end;

function Get(n: longint): PImage;
var blob: pak.TByteArray;
begin
  Get := nil;
  if (n <= 0) or (n >= MAXICON) then exit;
  if not cache[n].tried then begin
    cache[n].tried := true;
    cache[n].ok := PakGet(GamePak, 'SI' + IntToStr(n), blob)
                   and PicDecode(blob, cache[n].img);
  end;
  if cache[n].ok then Get := @cache[n].img;
end;

function HasSpellIcon(n: longint): boolean;
begin
  HasSpellIcon := Get(n) <> nil;
end;

procedure DrawSpellIcon(px, py, dw, dh, n: longint);
var
  img: PImage;
  dx, dy, sx, sy: longint;
  c: TColor;
begin
  if (dw <= 0) or (dh <= 0) then exit;
  img := Get(n);
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
