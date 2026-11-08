unit skillicon;

{** Skill icon pool.

  A skill may name an icon number that content/skills.txt carries and the baker
  writes to a WI<N> lump. Like the spell icons and player portraits, these are
  decoded into a cache of their own rather than the world-billboard registry,
  since they are UI art drawn on demand. The learn screen, the character sheet
  and the combat skill menu draw them small beside each skill. }

{$mode objfpc}{$H+}

interface

uses pic, gfx;

{ True when icon n is a real, loadable icon. }
function HasSkillIcon(n: longint): boolean;

{ Draw icon n scaled into a dw by dh box by nearest sampling, skipping keyed
  pixels. Does nothing when n names no icon. }
procedure DrawSkillIcon(px, py, dw, dh, n: longint);

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
    cache[n].ok := PakGet(GamePak, 'WI' + IntToStr(n), blob)
                   and PicDecode(blob, cache[n].img);
  end;
  if cache[n].ok then Get := @cache[n].img;
end;

function HasSkillIcon(n: longint): boolean;
begin
  HasSkillIcon := Get(n) <> nil;
end;

procedure DrawSkillIcon(px, py, dw, dh, n: longint);
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
