unit texgen;

{** Procedural texture generation for the asset tool.

  These are the wall, floor, ceiling and door patterns that the runtime
  used to build at startup. They now live here and are called by the
  offline asset tool, which writes the results as PIC lumps into the
  pak. The runtime no longer generates art; it loads it from files. }

{$mode objfpc}{$H+}

interface

uses
  gfx, pic;

const
  GEN_TEXW = 64;
  GEN_TEXH = 64;

procedure GenBrick(out img: TImage);
procedure GenStone(out img: TImage);
procedure GenMoss(out img: TImage);
procedure GenDoor(out img: TImage);
procedure GenFloor(out img: TImage);
procedure GenCeiling(out img: TImage);

implementation

var
  seed: UInt32 = $1234ABCD;

function Rnd: UInt32;
begin
  seed := seed xor (seed shl 13);
  seed := seed xor (seed shr 17);
  seed := seed xor (seed shl 5);
  Rnd := seed;
end;

function RndRange(lo, hi: longint): longint;
begin
  RndRange := lo + longint(Rnd mod UInt32(hi - lo + 1));
end;

procedure GenBrick(out img: TImage);
var
  x, y, n, base: longint;
  mortar, c: TColor;
begin
  ImgNew(img, GEN_TEXW, GEN_TEXH);
  mortar := RGB(60, 55, 50);
  for y := 0 to GEN_TEXH - 1 do
    for x := 0 to GEN_TEXW - 1 do begin
      if (y mod 16) < 2 then
        c := mortar
      else begin
        base := x;
        if ((y div 16) and 1) = 1 then
          base := x + 16;
        if (base mod 32) < 2 then
          c := mortar
        else begin
          n := RndRange(-18, 18);
          c := RGB(byte(150 + n), byte(70 + (n div 2)), byte(55 + (n div 2)));
          if (y mod 16) = 2 then
            c := Shade(c, 320);
        end;
      end;
      ImgSet(img, x, y, c);
    end;
end;

procedure GenStone(out img: TImage);
var
  x, y, n: longint;
  c: TColor;
begin
  ImgNew(img, GEN_TEXW, GEN_TEXH);
  for y := 0 to GEN_TEXH - 1 do
    for x := 0 to GEN_TEXW - 1 do begin
      n := RndRange(-20, 20);
      c := RGB(byte(120 + n), byte(120 + n), byte(128 + n));
      if ((x mod 32) = 0) or ((y mod 32) = 0) then
        c := RGB(70, 70, 76);
      ImgSet(img, x, y, c);
    end;
end;

procedure GenMoss(out img: TImage);
var
  x, y, n: longint;
  c: TColor;
begin
  ImgNew(img, GEN_TEXW, GEN_TEXH);
  for y := 0 to GEN_TEXH - 1 do
    for x := 0 to GEN_TEXW - 1 do begin
      n := RndRange(-18, 18);
      c := RGB(byte(95 + n), byte(95 + n), byte(100 + n));
      if ((y mod 16) < 2) or ((x mod 16) < 2) then
        c := RGB(55, 55, 60);
      if (y > 28) and (RndRange(0, 100) < 35) then
        c := RGB(byte(40 + (n div 2)), byte(90 + n), byte(45));
      ImgSet(img, x, y, c);
    end;
end;

procedure GenDoor(out img: TImage);
var
  x, y, plank: longint;
  c: TColor;
begin
  ImgNew(img, GEN_TEXW, GEN_TEXH);
  for y := 0 to GEN_TEXH - 1 do
    for x := 0 to GEN_TEXW - 1 do begin
      c := RGB(95, 60, 30);
      plank := x mod 16;
      if plank < 1 then
        c := RGB(50, 32, 16)
      else if (plank > 1) and (plank < 15) then
        c := RGB(byte(95 + RndRange(-10, 10)),
                 byte(60 + RndRange(-8, 8)), byte(30 + RndRange(-6, 6)));
      if (y < 6) or (y > GEN_TEXH - 8) or ((y > 28) and (y < 34)) then
        c := RGB(70, 70, 78);
      if (sqr(x - 48) + sqr(y - 36)) < 10 then
        c := RGB(200, 180, 60);
      ImgSet(img, x, y, c);
    end;
end;

procedure GenFloor(out img: TImage);
var
  x, y, n: longint;
  c: TColor;
begin
  ImgNew(img, GEN_TEXW, GEN_TEXH);
  for y := 0 to GEN_TEXH - 1 do
    for x := 0 to GEN_TEXW - 1 do begin
      n := RndRange(-14, 14);
      c := RGB(byte(70 + n), byte(66 + n), byte(60 + n));
      if (((x + 8 * ((y div 16) and 1)) mod 16) < 2) or ((y mod 16) < 2) then
        c := RGB(40, 38, 34);
      ImgSet(img, x, y, c);
    end;
end;

procedure GenCeiling(out img: TImage);
var
  x, y, n: longint;
  c: TColor;
begin
  ImgNew(img, GEN_TEXW, GEN_TEXH);
  for y := 0 to GEN_TEXH - 1 do
    for x := 0 to GEN_TEXW - 1 do begin
      n := RndRange(-10, 10);
      c := RGB(byte(46 + n), byte(46 + n), byte(54 + n));
      if ((x mod 32) < 2) or ((y mod 32) < 2) then
        c := RGB(30, 30, 36);
      ImgSet(img, x, y, c);
    end;
end;

end.
