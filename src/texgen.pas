unit texgen;

{** Procedural texture generation for the asset tool.

  These are the wall, floor, ceiling and door patterns that the runtime
  used to build at startup. They now live here and are called by the
  offline asset tool, which writes the results as PIC lumps into the
  pak. The runtime no longer generates art; it loads it from files.

  Each tileset is one colour scheme over the same patterns, so a zone can
  carry its own look (stone crypt, green wood, sea-stone shore, basalt
  hell) without new art. Scheme 0 reproduces the original dungeon look
  byte for byte, so maps that stay on tileset 0 are unchanged. The door
  is one shared plank texture across every tileset.

  The runtime palette is a 6x6x6 colour cube (levels 0, 51, 102, 153,
  204, 255 per channel), so scheme colours are chosen near those levels
  with the channels well separated. That keeps a hue from drifting when
  the texture is quantised, for example a warm floor turning olive. }

{$mode objfpc}{$H+}

interface

uses
  gfx, pic;

const
  GEN_TEXW = 64;
  GEN_TEXH = 64;
  NUM_TILESETS = 10;

type
  TTexScheme = record
    brickR, brickG, brickB, morR, morG, morB: longint;
    stoneR, stoneG, stoneB, stnSR, stnSG, stnSB: longint;
    mossR, mossG, mossB, msR, msG, msB: longint;
    mossGR, mossGG, mossGB, mossGrowth: longint;
    floorR, floorG, floorB, flrSR, flrSG, flrSB: longint;
    ceilR, ceilG, ceilB, celSR, celSG, celSB: longint;
  end;

const
  { Tileset 0 is the original dungeon palette, its numbers unchanged. The
    rest theme a zone. Each row: brick + mortar, stone + seam, moss + seam,
    moss growth + its chance, floor + seam, ceiling + seam. }
  TileSchemes: array[0 .. NUM_TILESETS - 1] of TTexScheme = (
    { 0 dungeon: stone and red brick, the original look }
    (brickR: 150; brickG: 70; brickB: 55; morR: 60; morG: 55; morB: 50;
     stoneR: 120; stoneG: 120; stoneB: 128; stnSR: 70; stnSG: 70; stnSB: 76;
     mossR: 95; mossG: 95; mossB: 100; msR: 55; msG: 55; msB: 60;
     mossGR: 40; mossGG: 90; mossGB: 45; mossGrowth: 35;
     floorR: 70; floorG: 66; floorB: 60; flrSR: 40; flrSG: 38; flrSB: 34;
     ceilR: 46; ceilG: 46; ceilB: 54; celSR: 30; celSG: 30; celSB: 36),
    { 1 town: warm sandstone, pale plaster, timber floor }
    (brickR: 205; brickG: 155; brickB: 100; morR: 150; morG: 100; morB: 51;
     stoneR: 210; stoneG: 195; stoneB: 150; stnSR: 150; stnSG: 140; stnSB: 100;
     mossR: 200; mossG: 190; mossB: 150; msR: 150; msG: 140; msB: 110;
     mossGR: 150; mossGG: 170; mossGB: 110; mossGrowth: 18;
     floorR: 150; floorG: 100; floorB: 55; flrSR: 100; flrSG: 55; flrSB: 30;
     ceilR: 150; ceilG: 145; ceilB: 115; celSR: 100; celSG: 95; celSB: 80),
    { 2 coast: pale sea-stone, wet sand, overcast }
    (brickR: 100; brickG: 150; brickB: 160; morR: 50; morG: 100; morB: 110;
     stoneR: 150; stoneG: 160; stoneB: 200; stnSR: 100; stnSG: 110; stnSB: 150;
     mossR: 100; mossG: 150; mossB: 150; msR: 50; msG: 100; msB: 100;
     mossGR: 50; mossGG: 150; mossGB: 110; mossGrowth: 30;
     floorR: 200; floorG: 155; floorB: 100; flrSR: 150; flrSG: 100; flrSB: 55;
     ceilR: 150; ceilG: 160; ceilB: 200; celSR: 100; celSG: 110; celSB: 150),
    { 3 forest and wilds: bark, lichen rock, lush green, leaf litter }
    (brickR: 100; brickG: 55; brickB: 10; morR: 50; morG: 40; morB: 10;
     stoneR: 100; stoneG: 150; stoneB: 100; stnSR: 50; stnSG: 100; stnSB: 50;
     mossR: 50; mossG: 150; mossB: 50; msR: 0; msG: 100; msB: 50;
     mossGR: 100; mossGG: 200; mossGB: 50; mossGrowth: 55;
     floorR: 105; floorG: 100; floorB: 50; flrSR: 51; flrSG: 51; flrSB: 10;
     ceilR: 50; ceilG: 100; ceilB: 50; celSR: 10; celSG: 51; celSB: 51),
    { 4 crypt: cold grey-blue block and flagstone }
    (brickR: 100; brickG: 100; brickB: 150; morR: 50; morG: 50; morB: 100;
     stoneR: 100; stoneG: 105; stoneB: 150; stnSR: 50; stnSG: 55; stnSB: 100;
     mossR: 100; mossG: 150; mossB: 150; msR: 50; msG: 100; msB: 100;
     mossGR: 100; mossGG: 150; mossGB: 100; mossGrowth: 25;
     floorR: 100; floorG: 100; floorB: 105; flrSR: 50; flrSG: 50; flrSB: 55;
     ceilR: 50; ceilG: 50; ceilB: 100; celSR: 10; celSG: 10; celSB: 55),
    { 5 cave: ochre and brown rock, damp }
    (brickR: 150; brickG: 100; brickB: 55; morR: 100; morG: 55; morB: 30;
     stoneR: 150; stoneG: 105; stoneB: 55; stnSR: 100; stnSG: 55; stnSB: 30;
     mossR: 105; mossG: 100; mossB: 55; msR: 51; msG: 51; msB: 10;
     mossGR: 100; mossGG: 150; mossGB: 100; mossGrowth: 35;
     floorR: 150; floorG: 100; floorB: 55; flrSR: 100; flrSG: 55; flrSB: 30;
     ceilR: 55; ceilG: 50; ceilB: 40; celSR: 10; celSG: 10; celSB: 10),
    { 6 infernal: basalt and ember red }
    (brickR: 150; brickG: 50; brickB: 50; morR: 50; morG: 10; morB: 10;
     stoneR: 55; stoneG: 50; stoneB: 55; stnSR: 10; stnSG: 10; stnSB: 10;
     mossR: 150; mossG: 60; mossB: 20; msR: 50; msG: 20; msB: 10;
     mossGR: 255; mossGG: 100; mossGB: 0; mossGrowth: 30;
     floorR: 105; floorG: 55; floorB: 50; flrSR: 50; flrSG: 10; flrSB: 10;
     ceilR: 55; ceilG: 50; ceilB: 55; celSR: 10; celSG: 10; celSB: 10),
    { 7 desert: adobe and sand }
    (brickR: 205; brickG: 155; brickB: 105; morR: 150; morG: 105; morB: 55;
     stoneR: 255; stoneG: 205; stoneB: 155; stnSR: 205; stnSG: 155; stnSB: 105;
     mossR: 205; mossG: 205; mossB: 150; msR: 150; msG: 150; msB: 100;
     mossGR: 150; mossGG: 205; mossGB: 100; mossGrowth: 15;
     floorR: 255; floorG: 205; floorB: 150; flrSR: 205; flrSG: 155; flrSB: 105;
     ceilR: 205; ceilG: 205; ceilB: 205; celSR: 150; celSG: 150; celSB: 150),
    { 8 frozen: ice and packed snow }
    (brickR: 155; brickG: 205; brickB: 255; morR: 100; morG: 155; morB: 205;
     stoneR: 155; stoneG: 205; stoneB: 255; stnSR: 100; stnSG: 155; stnSB: 205;
     mossR: 205; mossG: 255; mossB: 255; msR: 155; msG: 205; msB: 205;
     mossGR: 150; mossGG: 205; mossGB: 205; mossGrowth: 15;
     floorR: 205; floorG: 255; floorB: 255; flrSR: 155; flrSG: 205; flrSB: 205;
     ceilR: 155; ceilG: 205; ceilB: 255; celSR: 100; celSG: 155; celSB: 205),
    { 9 volcanic: ash rock and sulfur }
    (brickR: 105; brickG: 100; brickB: 100; morR: 50; morG: 50; morB: 50;
     stoneR: 105; stoneG: 100; stoneB: 100; stnSR: 50; stnSG: 50; stnSB: 50;
     mossR: 205; mossG: 155; mossB: 55; msR: 100; msG: 100; msB: 10;
     mossGR: 255; mossGG: 155; mossGB: 10; mossGrowth: 30;
     floorR: 105; floorG: 100; floorB: 100; flrSR: 50; flrSG: 50; flrSB: 50;
     ceilR: 55; ceilG: 50; ceilB: 50; celSR: 10; celSG: 10; celSB: 10)
  );

procedure GenBrick(out img: TImage; const s: TTexScheme);
procedure GenStone(out img: TImage; const s: TTexScheme);
procedure GenMoss(out img: TImage; const s: TTexScheme);
procedure GenDoor(out img: TImage);
procedure GenFloor(out img: TImage; const s: TTexScheme);
procedure GenCeiling(out img: TImage; const s: TTexScheme);

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

procedure GenBrick(out img: TImage; const s: TTexScheme);
var
  x, y, n, base: longint;
  mortar, c: TColor;
begin
  ImgNew(img, GEN_TEXW, GEN_TEXH);
  mortar := RGB(byte(s.morR), byte(s.morG), byte(s.morB));
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
          c := RGB(byte(s.brickR + n), byte(s.brickG + (n div 2)),
                   byte(s.brickB + (n div 2)));
          if (y mod 16) = 2 then
            c := Shade(c, 320);
        end;
      end;
      ImgSet(img, x, y, c);
    end;
end;

procedure GenStone(out img: TImage; const s: TTexScheme);
var
  x, y, n: longint;
  c, seam: TColor;
begin
  ImgNew(img, GEN_TEXW, GEN_TEXH);
  seam := RGB(byte(s.stnSR), byte(s.stnSG), byte(s.stnSB));
  for y := 0 to GEN_TEXH - 1 do
    for x := 0 to GEN_TEXW - 1 do begin
      n := RndRange(-20, 20);
      c := RGB(byte(s.stoneR + n), byte(s.stoneG + n), byte(s.stoneB + n));
      if ((x mod 32) = 0) or ((y mod 32) = 0) then
        c := seam;
      ImgSet(img, x, y, c);
    end;
end;

procedure GenMoss(out img: TImage; const s: TTexScheme);
var
  x, y, n: longint;
  c, seam: TColor;
begin
  ImgNew(img, GEN_TEXW, GEN_TEXH);
  seam := RGB(byte(s.msR), byte(s.msG), byte(s.msB));
  for y := 0 to GEN_TEXH - 1 do
    for x := 0 to GEN_TEXW - 1 do begin
      n := RndRange(-18, 18);
      c := RGB(byte(s.mossR + n), byte(s.mossG + n), byte(s.mossB + n));
      if ((y mod 16) < 2) or ((x mod 16) < 2) then
        c := seam;
      if (y > 28) and (RndRange(0, 100) < s.mossGrowth) then
        c := RGB(byte(s.mossGR + (n div 2)), byte(s.mossGG + n), byte(s.mossGB));
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

procedure GenFloor(out img: TImage; const s: TTexScheme);
var
  x, y, n: longint;
  c, seam: TColor;
begin
  ImgNew(img, GEN_TEXW, GEN_TEXH);
  seam := RGB(byte(s.flrSR), byte(s.flrSG), byte(s.flrSB));
  for y := 0 to GEN_TEXH - 1 do
    for x := 0 to GEN_TEXW - 1 do begin
      n := RndRange(-14, 14);
      c := RGB(byte(s.floorR + n), byte(s.floorG + n), byte(s.floorB + n));
      if (((x + 8 * ((y div 16) and 1)) mod 16) < 2) or ((y mod 16) < 2) then
        c := seam;
      ImgSet(img, x, y, c);
    end;
end;

procedure GenCeiling(out img: TImage; const s: TTexScheme);
var
  x, y, n: longint;
  c, seam: TColor;
begin
  ImgNew(img, GEN_TEXW, GEN_TEXH);
  seam := RGB(byte(s.celSR), byte(s.celSG), byte(s.celSB));
  for y := 0 to GEN_TEXH - 1 do
    for x := 0 to GEN_TEXW - 1 do begin
      n := RndRange(-10, 10);
      c := RGB(byte(s.ceilR + n), byte(s.ceilG + n), byte(s.ceilB + n));
      if ((x mod 32) < 2) or ((y mod 32) < 2) then
        c := seam;
      ImgSet(img, x, y, c);
    end;
end;

end.
