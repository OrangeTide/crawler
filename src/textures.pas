unit textures;

{** Procedurally generated 64x64 wall, floor and ceiling textures.

  Everything is built at startup from simple noise and pattern code so
  the game ships without any asset files. Each surface id maps to one
  texture in the Tex array. }

{$mode objfpc}{$H+}

interface

uses
  gfx;

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

type
  TTexture = array[0 .. TEXSIZE - 1] of TColor;

var
  Tex: array[0 .. TEX_COUNT - 1] of TTexture;

procedure BuildTextures;

implementation

var
  seed: UInt32 = $1234ABCD;

function Rnd: UInt32;
{** Small xorshift PRNG so textures are deterministic across runs. }
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

procedure SetTx(var t: TTexture; x, y: longint; c: TColor); inline;
begin
  t[y * TEXW + x] := c;
end;

procedure BuildBrick(var t: TTexture);
var
  x, y, n: longint;
  mortar, c: TColor;
  base: longint;
begin
  mortar := RGB(60, 55, 50);
  for y := 0 to TEXH - 1 do
    for x := 0 to TEXW - 1 do begin
      { Two offset courses of bricks with mortar lines. }
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
          c := RGB(
            byte(150 + n), byte(70 + (n div 2)), byte(55 + (n div 2)));
          { subtle top highlight }
          if (y mod 16) = 2 then
            c := Shade(c, 320);
        end;
      end;
      SetTx(t, x, y, c);
    end;
end;

procedure BuildStone(var t: TTexture);
var
  x, y, n: longint;
  c: TColor;
begin
  for y := 0 to TEXH - 1 do
    for x := 0 to TEXW - 1 do begin
      n := RndRange(-20, 20);
      c := RGB(byte(120 + n), byte(120 + n), byte(128 + n));
      { blocky joints every 32 px }
      if ((x mod 32) = 0) or ((y mod 32) = 0) then
        c := RGB(70, 70, 76);
      SetTx(t, x, y, c);
    end;
end;

procedure BuildMoss(var t: TTexture);
var
  x, y, n: longint;
  c: TColor;
begin
  for y := 0 to TEXH - 1 do
    for x := 0 to TEXW - 1 do begin
      n := RndRange(-18, 18);
      c := RGB(byte(95 + n), byte(95 + n), byte(100 + n));
      if ((y mod 16) < 2) or ((x mod 16) < 2) then
        c := RGB(55, 55, 60);
      { green moss patches in the lower half }
      if (y > 28) and (RndRange(0, 100) < 35) then
        c := RGB(byte(40 + (n div 2)), byte(90 + n), byte(45));
      SetTx(t, x, y, c);
    end;
end;

procedure BuildDoor(var t: TTexture);
var
  x, y: longint;
  c: TColor;
  plank: longint;
begin
  for y := 0 to TEXH - 1 do
    for x := 0 to TEXW - 1 do begin
      c := RGB(95, 60, 30);
      plank := x mod 16;
      if plank < 1 then
        c := RGB(50, 32, 16)              { vertical plank seam }
      else if (plank > 1) and (plank < 15) then
        c := RGB(byte(95 + RndRange(-10, 10)),
                 byte(60 + RndRange(-8, 8)), byte(30 + RndRange(-6, 6)));
      { iron bands across the top and bottom }
      if (y < 6) or (y > TEXH - 8) or ((y > 28) and (y < 34)) then
        c := RGB(70, 70, 78);
      { a round handle }
      if (sqr(x - 48) + sqr(y - 36)) < 10 then
        c := RGB(200, 180, 60);
      SetTx(t, x, y, c);
    end;
end;

procedure BuildFloor(var t: TTexture);
var
  x, y, n: longint;
  c: TColor;
begin
  for y := 0 to TEXH - 1 do
    for x := 0 to TEXW - 1 do begin
      n := RndRange(-14, 14);
      c := RGB(byte(70 + n), byte(66 + n), byte(60 + n));
      { cobble grid }
      if (((x + 8 * ((y div 16) and 1)) mod 16) < 2) or ((y mod 16) < 2) then
        c := RGB(40, 38, 34);
      SetTx(t, x, y, c);
    end;
end;

procedure BuildCeiling(var t: TTexture);
var
  x, y, n: longint;
  c: TColor;
begin
  for y := 0 to TEXH - 1 do
    for x := 0 to TEXW - 1 do begin
      n := RndRange(-10, 10);
      c := RGB(byte(46 + n), byte(46 + n), byte(54 + n));
      if ((x mod 32) < 2) or ((y mod 32) < 2) then
        c := RGB(30, 30, 36);
      SetTx(t, x, y, c);
    end;
end;

procedure BuildTextures;
begin
  BuildBrick(Tex[TEX_BRICK]);
  BuildStone(Tex[TEX_STONE]);
  BuildMoss(Tex[TEX_MOSS]);
  BuildDoor(Tex[TEX_DOOR]);
  BuildFloor(Tex[TEX_FLOOR]);
  BuildCeiling(Tex[TEX_CEILING]);
end;

end.
