unit pic;

{** Custom image format for textures, sprites and portraits.

  An image decodes straight into the 32-bit ARGB layout the framebuffer
  uses. Two storage formats share one header:

    format 0: direct 32-bit ARGB, PackBits compressed over the bytes.
    format 1: 8-bit palette indices, PackBits compressed, index 0 is the
              transparent key when the alpha flag is set; a 256-entry RGB
              palette precedes the data.

  The procedural art the tool generates is noisy, so it ships as format
  0, which stays correct without a colour quantiser. Authored sprites can
  use format 1 later for a smaller size. Header:

    magic   'CPIC'   4 bytes
    width   u16
    height  u16
    format  u8       0 direct, 1 indexed
    flags   u8       bit 0: has transparency }

{$mode objfpc}{$H+}

interface

uses
  gfx, pak;

const
  PIC_MAGIC = $43495043;  { 'CPIC' little-endian }

  PIC_DIRECT  = 0;
  PIC_INDEXED = 1;

  PIC_FLAG_ALPHA = 1;

type
  TImage = record
    w, h: longint;
    hasAlpha: boolean;
    pix: array of TColor;    { ARGB, row major }
  end;

procedure ImgNew(out img: TImage; w, h: longint);
function ImgAt(const img: TImage; x, y: longint): TColor; inline;
procedure ImgSet(var img: TImage; x, y: longint; c: TColor); inline;

{ Encode an image to a direct-colour PIC blob, and decode either format. }
function PicEncodeDirect(const img: TImage): TByteArray;
function PicDecode(const blob: TByteArray; out img: TImage): boolean;

implementation

procedure ImgNew(out img: TImage; w, h: longint);
begin
  img.w := w;
  img.h := h;
  img.hasAlpha := false;
  SetLength(img.pix, w * h);
end;

function ImgAt(const img: TImage; x, y: longint): TColor;
begin
  ImgAt := img.pix[y * img.w + x];
end;

procedure ImgSet(var img: TImage; x, y: longint; c: TColor);
begin
  img.pix[y * img.w + x] := c;
end;

{ ---- PackBits over a byte buffer ---- }

procedure PackBits(const src: TByteArray; out dst: TByteArray);
var
  n, i, runLen, litStart, dn: longint;

  procedure Emit(b: byte);
  begin
    if dn >= Length(dst) then
      SetLength(dst, (dn + 1) * 2);
    dst[dn] := b;
    inc(dn);
  end;

  procedure FlushLiteral(start, count: longint);
  var
    k: longint;
  begin
    while count > 0 do begin
      runLen := count;
      if runLen > 128 then runLen := 128;
      Emit(runLen - 1);               { 0..127 => copy n+1 literals }
      for k := 0 to runLen - 1 do
        Emit(src[start + k]);
      start := start + runLen;
      count := count - runLen;
    end;
  end;

begin
  n := Length(src);
  SetLength(dst, 0);
  dn := 0;
  i := 0;
  litStart := 0;
  while i < n do begin
    { Measure a run of equal bytes at i. }
    runLen := 1;
    while (i + runLen < n) and (src[i + runLen] = src[i]) and (runLen < 128) do
      inc(runLen);
    if runLen >= 2 then begin
      if i > litStart then
        FlushLiteral(litStart, i - litStart);
      Emit(257 - runLen);             { 129..255 => repeat next byte }
      Emit(src[i]);
      i := i + runLen;
      litStart := i;
    end else
      inc(i);
  end;
  if i > litStart then
    FlushLiteral(litStart, i - litStart);
  SetLength(dst, dn);
end;

function UnpackBits(const src: TByteArray; ofs, len, expected: longint;
  out dst: TByteArray): boolean;
var
  i, dn, k, count: longint;
  hdr: shortint;
  b: byte;
begin
  UnpackBits := false;
  SetLength(dst, expected);
  i := ofs;
  dn := 0;
  while (i < ofs + len) and (dn < expected) do begin
    hdr := shortint(src[i]);
    inc(i);
    if hdr >= 0 then begin
      count := hdr + 1;
      for k := 0 to count - 1 do begin
        if (i >= ofs + len) or (dn >= expected) then exit;
        dst[dn] := src[i];
        inc(i); inc(dn);
      end;
    end else if hdr <> -128 then begin
      count := 257 - (256 + hdr);     { -1 => 2, ... -127 => 128 }
      if i >= ofs + len then exit;
      b := src[i];
      inc(i);
      for k := 0 to count - 1 do begin
        if dn >= expected then exit;
        dst[dn] := b;
        inc(dn);
      end;
    end;
  end;
  UnpackBits := dn = expected;
end;

{ ---- Little-endian helpers over a growable byte array ---- }

procedure PutB(var a: TByteArray; var n: longint; v: byte);
begin
  if n >= Length(a) then
    SetLength(a, (n + 1) * 2);
  a[n] := v;
  inc(n);
end;

function PicEncodeDirect(const img: TImage): TByteArray;
var
  raw, comp, outp: TByteArray;
  i, n, flags: longint;
  c: TColor;
begin
  { Flatten pixels to a BGRA byte stream. }
  SetLength(raw, img.w * img.h * 4);
  for i := 0 to img.w * img.h - 1 do begin
    c := img.pix[i];
    raw[i * 4]     := c and $FF;
    raw[i * 4 + 1] := (c shr 8) and $FF;
    raw[i * 4 + 2] := (c shr 16) and $FF;
    raw[i * 4 + 3] := (c shr 24) and $FF;
  end;
  PackBits(raw, comp);

  flags := 0;
  if img.hasAlpha then flags := flags or PIC_FLAG_ALPHA;

  SetLength(outp, 0);
  n := 0;
  PutB(outp, n, PIC_MAGIC and $FF);
  PutB(outp, n, (PIC_MAGIC shr 8) and $FF);
  PutB(outp, n, (PIC_MAGIC shr 16) and $FF);
  PutB(outp, n, (PIC_MAGIC shr 24) and $FF);
  PutB(outp, n, img.w and $FF);
  PutB(outp, n, (img.w shr 8) and $FF);
  PutB(outp, n, img.h and $FF);
  PutB(outp, n, (img.h shr 8) and $FF);
  PutB(outp, n, PIC_DIRECT);
  PutB(outp, n, flags);
  for i := 0 to Length(comp) - 1 do
    PutB(outp, n, comp[i]);
  SetLength(outp, n);
  PicEncodeDirect := outp;
end;

function PicDecode(const blob: TByteArray; out img: TImage): boolean;
var
  magic: longword;
  w, h, format, flags, i, px: longint;
  raw, pal: TByteArray;
  idx: longint;
  r, g, b: byte;
begin
  PicDecode := false;
  img.w := 0; img.h := 0; img.pix := nil; img.hasAlpha := false;
  if Length(blob) < 10 then
    exit;
  magic := blob[0] or (blob[1] shl 8) or (blob[2] shl 16) or (longword(blob[3]) shl 24);
  if magic <> PIC_MAGIC then
    exit;
  w := blob[4] or (blob[5] shl 8);
  h := blob[6] or (blob[7] shl 8);
  format := blob[8];
  flags := blob[9];
  px := w * h;
  ImgNew(img, w, h);
  img.hasAlpha := (flags and PIC_FLAG_ALPHA) <> 0;

  if format = PIC_DIRECT then begin
    if not UnpackBits(blob, 10, Length(blob) - 10, px * 4, raw) then
      exit;
    for i := 0 to px - 1 do
      img.pix[i] := TColor(raw[i * 4]) or (TColor(raw[i * 4 + 1]) shl 8) or
        (TColor(raw[i * 4 + 2]) shl 16) or (TColor(raw[i * 4 + 3]) shl 24);
    PicDecode := true;
  end else if format = PIC_INDEXED then begin
    if Length(blob) < 10 + 768 then
      exit;
    SetLength(pal, 768);
    for i := 0 to 767 do
      pal[i] := blob[10 + i];
    if not UnpackBits(blob, 10 + 768, Length(blob) - 10 - 768, px, raw) then
      exit;
    for i := 0 to px - 1 do begin
      idx := raw[i];
      r := pal[idx * 3];
      g := pal[idx * 3 + 1];
      b := pal[idx * 3 + 2];
      if img.hasAlpha and (idx = 0) then
        img.pix[i] := 0                     { transparent key }
      else
        img.pix[i] := RGB(r, g, b);
    end;
    PicDecode := true;
  end;
end;

end.
