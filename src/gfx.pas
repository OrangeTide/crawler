unit gfx;

{** Software framebuffer for the 320x240 retro target.

  All rendering writes 32-bit ARGB pixels into a flat buffer that is
  later uploaded to an SDL streaming texture and upscaled. This unit
  owns the buffer plus a handful of primitives and a compact 5x7
  bitmap font used by the HUD. }

{$mode objfpc}{$H+}

interface

const
  FBW = 320;
  FBH = 240;

type
  TColor = UInt32;  { 0xAARRGGBB }
  TFrameBuffer = array[0 .. FBW * FBH - 1] of TColor;

var
  FB: TFrameBuffer;

function RGB(r, g, b: byte): TColor; inline;
function Shade(c: TColor; f: longint): TColor; inline;
function MixColor(a, b: TColor; t: longint): TColor; inline;
procedure ClearFB(c: TColor);
procedure PutPixel(x, y: longint; c: TColor); inline;
procedure FillRect(x, y, w, h: longint; c: TColor);
procedure FrameRect(x, y, w, h: longint; c: TColor);
procedure BlendPixel(x, y: longint; c: TColor; alpha: byte);
procedure FillRectBlend(x, y, w, h: longint; c: TColor; alpha: byte);
procedure HLine(x, y, len: longint; c: TColor);
procedure VLine(x, y, len: longint; c: TColor);
procedure DrawChar(x, y: longint; ch: char; c: TColor);
procedure DrawText(x, y: longint; const s: string; c: TColor);

implementation

function RGB(r, g, b: byte): TColor;
begin
  RGB := TColor($FF000000) or (TColor(r) shl 16) or (TColor(g) shl 8) or TColor(b);
end;

function Shade(c: TColor; f: longint): TColor;
{** Scale the RGB channels by f/256 for distance fog. f is clamped. }
var
  r, g, b: longint;
begin
  if f < 0 then f := 0;
  if f > 256 then f := 256;
  r := ((c shr 16) and $FF) * f shr 8;
  g := ((c shr 8) and $FF) * f shr 8;
  b := (c and $FF) * f shr 8;
  Shade := TColor($FF000000) or (TColor(r) shl 16) or (TColor(g) shl 8) or TColor(b);
end;

function MixColor(a, b: TColor; t: longint): TColor;
{** Blend b into a by t/256, opaque result. t is clamped to 0..256. }
var
  ar, ag, ab, br, bg, bb: longint;
begin
  if t < 0 then t := 0;
  if t > 256 then t := 256;
  ar := (a shr 16) and $FF; ag := (a shr 8) and $FF; ab := a and $FF;
  br := (b shr 16) and $FF; bg := (b shr 8) and $FF; bb := b and $FF;
  MixColor := TColor($FF000000)
    or (TColor(ar + ((br - ar) * t shr 8)) shl 16)
    or (TColor(ag + ((bg - ag) * t shr 8)) shl 8)
    or TColor(ab + ((bb - ab) * t shr 8));
end;

procedure ClearFB(c: TColor);
var
  i: longint;
begin
  for i := 0 to FBW * FBH - 1 do
    FB[i] := c;
end;

procedure PutPixel(x, y: longint; c: TColor);
begin
  if (x >= 0) and (x < FBW) and (y >= 0) and (y < FBH) then
    FB[y * FBW + x] := c;
end;

procedure HLine(x, y, len: longint; c: TColor);
var
  i: longint;
begin
  for i := 0 to len - 1 do
    PutPixel(x + i, y, c);
end;

procedure VLine(x, y, len: longint; c: TColor);
var
  i: longint;
begin
  for i := 0 to len - 1 do
    PutPixel(x, y + i, c);
end;

procedure FillRect(x, y, w, h: longint; c: TColor);
var
  j: longint;
begin
  for j := 0 to h - 1 do
    HLine(x, y + j, w, c);
end;

procedure FrameRect(x, y, w, h: longint; c: TColor);
begin
  HLine(x, y, w, c);
  HLine(x, y + h - 1, w, c);
  VLine(x, y, h, c);
  VLine(x + w - 1, y, h, c);
end;

procedure BlendPixel(x, y: longint; c: TColor; alpha: byte);
{** Alpha-blend c over the existing pixel. alpha 0 keeps the dst, 255
  replaces it. Used for translucent HUD overlays. }
var
  d: TColor;
  sr, sg, sb, dr, dg, db, ia: longint;
begin
  if (x < 0) or (x >= FBW) or (y < 0) or (y >= FBH) then exit;
  if alpha = 0 then exit;
  if alpha = 255 then begin
    FB[y * FBW + x] := c;
    exit;
  end;
  d := FB[y * FBW + x];
  ia := 255 - alpha;
  sr := (c shr 16) and $FF; sg := (c shr 8) and $FF; sb := c and $FF;
  dr := (d shr 16) and $FF; dg := (d shr 8) and $FF; db := d and $FF;
  dr := (sr * alpha + dr * ia) div 255;
  dg := (sg * alpha + dg * ia) div 255;
  db := (sb * alpha + db * ia) div 255;
  FB[y * FBW + x] := TColor($FF000000) or (TColor(dr) shl 16) or
    (TColor(dg) shl 8) or TColor(db);
end;

procedure FillRectBlend(x, y, w, h: longint; c: TColor; alpha: byte);
var
  i, j: longint;
begin
  for j := 0 to h - 1 do
    for i := 0 to w - 1 do
      BlendPixel(x + i, y + j, c, alpha);
end;

{ ---- Bitmap font: 5 wide x 7 tall, low 5 bits of each row byte ----
  Each row of the table is: character code, then 7 pattern rows.
  Only the glyphs the HUD needs are defined; others draw blank. }

const
  FONT_COUNT = 44;
  FONT: array[0 .. FONT_COUNT - 1, 0 .. 7] of byte = (
    (ord('0'), $0E, $11, $13, $15, $19, $11, $0E),
    (ord('1'), $04, $0C, $04, $04, $04, $04, $0E),
    (ord('2'), $0E, $11, $01, $02, $04, $08, $1F),
    (ord('3'), $1F, $02, $04, $02, $01, $11, $0E),
    (ord('4'), $02, $06, $0A, $12, $1F, $02, $02),
    (ord('5'), $1F, $10, $1E, $01, $01, $11, $0E),
    (ord('6'), $06, $08, $10, $1E, $11, $11, $0E),
    (ord('7'), $1F, $01, $02, $04, $08, $08, $08),
    (ord('8'), $0E, $11, $11, $0E, $11, $11, $0E),
    (ord('9'), $0E, $11, $11, $0F, $01, $02, $0C),
    (ord('A'), $0E, $11, $11, $1F, $11, $11, $11),
    (ord('B'), $1E, $11, $11, $1E, $11, $11, $1E),
    (ord('C'), $0E, $11, $10, $10, $10, $11, $0E),
    (ord('D'), $1C, $12, $11, $11, $11, $12, $1C),
    (ord('E'), $1F, $10, $10, $1E, $10, $10, $1F),
    (ord('F'), $1F, $10, $10, $1E, $10, $10, $10),
    (ord('G'), $0E, $11, $10, $17, $11, $11, $0F),
    (ord('H'), $11, $11, $11, $1F, $11, $11, $11),
    (ord('I'), $0E, $04, $04, $04, $04, $04, $0E),
    (ord('J'), $07, $02, $02, $02, $02, $12, $0C),
    (ord('K'), $11, $12, $14, $18, $14, $12, $11),
    (ord('L'), $10, $10, $10, $10, $10, $10, $1F),
    (ord('M'), $11, $1B, $15, $15, $11, $11, $11),
    (ord('N'), $11, $19, $15, $13, $11, $11, $11),
    (ord('O'), $0E, $11, $11, $11, $11, $11, $0E),
    (ord('P'), $1E, $11, $11, $1E, $10, $10, $10),
    (ord('Q'), $0E, $11, $11, $11, $15, $12, $0D),
    (ord('R'), $1E, $11, $11, $1E, $14, $12, $11),
    (ord('S'), $0F, $10, $10, $0E, $01, $01, $1E),
    (ord('T'), $1F, $04, $04, $04, $04, $04, $04),
    (ord('U'), $11, $11, $11, $11, $11, $11, $0E),
    (ord('V'), $11, $11, $11, $11, $11, $0A, $04),
    (ord('W'), $11, $11, $11, $15, $15, $1B, $11),
    (ord('X'), $11, $11, $0A, $04, $0A, $11, $11),
    (ord('Y'), $11, $11, $0A, $04, $04, $04, $04),
    (ord('Z'), $1F, $01, $02, $04, $08, $10, $1F),
    (ord('.'), $00, $00, $00, $00, $00, $0C, $0C),
    (ord(','), $00, $00, $00, $00, $0C, $0C, $08),
    (ord(':'), $00, $0C, $0C, $00, $0C, $0C, $00),
    (ord('-'), $00, $00, $00, $1F, $00, $00, $00),
    (ord('+'), $00, $04, $04, $1F, $04, $04, $00),
    (ord('/'), $01, $02, $02, $04, $08, $08, $10),
    (ord('('), $02, $04, $08, $08, $08, $04, $02),
    (ord(')'), $08, $04, $02, $02, $02, $04, $08));

procedure DrawChar(x, y: longint; ch: char; c: TColor);
var
  row, col, i, idx: longint;
  bits: byte;
begin
  if (ch >= 'a') and (ch <= 'z') then
    ch := char(ord(ch) - 32);
  idx := -1;
  for i := 0 to FONT_COUNT - 1 do
    if FONT[i][0] = ord(ch) then begin
      idx := i;
      break;
    end;
  if idx < 0 then
    exit;  { space or unknown: leave blank }
  for row := 0 to 6 do begin
    bits := FONT[idx][row + 1];
    for col := 0 to 4 do
      if (bits and (1 shl (4 - col))) <> 0 then
        PutPixel(x + col, y + row, c);
  end;
end;

procedure DrawText(x, y: longint; const s: string; c: TColor);
var
  i: longint;
begin
  for i := 1 to length(s) do
    DrawChar(x + (i - 1) * 6, y, s[i], c);
end;

end.
