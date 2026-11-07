program t_sprite;

{** Billboard sprite image round-trip: a TImage with transparent key pixels
  survives PicEncodeDirect/PicDecode with its alpha intact, which is what the
  sprite pipeline relies on. Also smoke-checks the runtime sprite store. }

{$mode objfpc}{$H+}

uses
  pic, gfx, pak, sprites, testing;

var
  img, back: TImage;
  blob: TByteArray;
  i: longint;
begin
  ImgNew(img, 4, 3);
  img.hasAlpha := true;
  for i := 0 to 4 * 3 - 1 do
    img.pix[i] := RGB(10 + i, 20, 30);
  img.pix[0] := 0;          { two transparent key texels }
  img.pix[11] := 0;

  blob := PicEncodeDirect(img);
  Check(PicDecode(blob, back), 'sprite decodes');
  CheckEqI(4, back.w, 'width preserved');
  CheckEqI(3, back.h, 'height preserved');
  Check(back.hasAlpha, 'alpha flag preserved');
  Check((back.pix[0] shr 24) = 0, 'keyed texel decodes transparent');
  Check((back.pix[11] shr 24) = 0, 'second keyed texel transparent');
  Check((back.pix[1] shr 24) = $FF, 'opaque texel keeps full alpha');
  CheckEqI(longint(img.pix[1] and $FFFFFF),
    longint(back.pix[1] and $FFFFFF), 'opaque rgb preserved');

  { the store starts empty and reports a miss for an unknown name }
  SpritesReset;
  CheckEqI(0, SpriteCount, 'store starts empty');
  Check(FindSprite('NOPE') < 0, 'unknown sprite is a miss');

  TestSummary('sprite');
  halt(TestExit);
end.
