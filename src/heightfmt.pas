unit heightfmt;

{** Baked terrain heightmap, the source a surface map samples for its relief.

  A heightmap is a small grid of one-byte samples, 0..255, that the terrain
  layer upsamples into the per-map height grid at load time. It is a render-only
  asset beside the logical grid: the samples carry elevation, not collision, and
  the map's heightZMin/heightZMax fields map sample 0 and 255 to a world height.

  The on-disk lump is 'CHGT': a header then one byte per sample, row major. The
  offline baker reads a grayscale PPM (the red channel) and produces this. Keep
  the source modest; the per-target subdivision knob, not the source, sets how
  dense the rendered terrain is. }

{$mode objfpc}{$H+}

interface

uses
  pak;

const
  HEIGHT_MAGIC   = $54474843;   { 'CHGT' little-endian }
  HEIGHT_VERSION = 1;

type
  { pin this to pak's dynamic byte array, as meshfmt does, so sysutils'
    static TByteArray does not shadow it }
  TByteArray = pak.TByteArray;

function EncodeHeight(w, h: longint; const samples: TByteArray): TByteArray;
function DecodeHeight(const blob: TByteArray; out w, h: longint;
  out samples: TByteArray): boolean;

implementation

procedure PutU32(var b: TByteArray; var n: longint; v: longword);
begin
  b[n] := v and $FF; b[n + 1] := (v shr 8) and $FF;
  b[n + 2] := (v shr 16) and $FF; b[n + 3] := (v shr 24) and $FF;
  inc(n, 4);
end;

function GetU32(const b: TByteArray; var n: longint): longword;
begin
  GetU32 := longword(b[n]) or (longword(b[n + 1]) shl 8)
    or (longword(b[n + 2]) shl 16) or (longword(b[n + 3]) shl 24);
  inc(n, 4);
end;

function EncodeHeight(w, h: longint; const samples: TByteArray): TByteArray;
var
  b: TByteArray;
  n, i, ns: longint;
begin
  ns := w * h;
  SetLength(b, 4 + 4 + 4 + 4 + ns);
  n := 0;
  PutU32(b, n, HEIGHT_MAGIC);
  PutU32(b, n, HEIGHT_VERSION);
  PutU32(b, n, w);
  PutU32(b, n, h);
  for i := 0 to ns - 1 do
    if i < Length(samples) then b[n + i] := samples[i]
    else b[n + i] := 0;
  inc(n, ns);
  EncodeHeight := b;
end;

function DecodeHeight(const blob: TByteArray; out w, h: longint;
  out samples: TByteArray): boolean;
var
  n, i, ns: longint;
begin
  DecodeHeight := false;
  w := 0; h := 0; samples := nil;
  if Length(blob) < 16 then exit;
  n := 0;
  if GetU32(blob, n) <> HEIGHT_MAGIC then exit;
  if GetU32(blob, n) <> HEIGHT_VERSION then exit;
  w := GetU32(blob, n);
  h := GetU32(blob, n);
  if (w <= 0) or (h <= 0) then exit;
  ns := w * h;
  if Length(blob) < n + ns then exit;
  SetLength(samples, ns);
  for i := 0 to ns - 1 do samples[i] := blob[n + i];
  DecodeHeight := true;
end;

end.
