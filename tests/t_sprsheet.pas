program t_sprsheet;

{** Grid character sheets sliced into banks (design section 27). The male and
  female character sheets bake one bank per column through the `sheet` manifest
  (content/banks/sheets/*.sheet). These checks load a few of the baked lumps and
  confirm the slice: each is a bank carrying a 13-frame IDLE cycle of 64x64
  frames that the store animates like any other bank. }

{$mode objfpc}{$H+}

uses
  sysutils, pak, pic, sprbank, sprites, worldspr, testing;

var
  p: TPak;
  si, sq: longint;
  img: TImage;

procedure CheckChar(const lump: string);
var idx, seq: longint;
begin
  idx := LoadSprite(p, lump);
  Check(idx >= 0, lump + ' loads from the pak');
  Check(SpriteReg[idx].isBank, lump + ' is a bank');
  seq := SpriteSeqIndex(idx, 'IDLE');
  Check(seq >= 0, lump + ' has an IDLE sequence');
  CheckEqI(SpriteReg[idx].bank.seqs[seq].frameCount, 13, lump + ' IDLE has 13 frames');
  CheckEqI(SpriteReg[idx].bank.seqs[seq].w, 64, lump + ' frame width is 64');
  CheckEqI(SpriteReg[idx].bank.seqs[seq].h, 64, lump + ' frame height is 64');
end;

begin
  if not PakLoad('build/game.pak', p) then begin
    writeln('  FAIL could not load build/game.pak (run make first)');
    halt(2);
  end;

  SpritesReset;
  CheckChar('MALE_KING');
  CheckChar('MALE_GUARD');
  CheckChar('MALE_KNIGHT');
  CheckChar('FEMALE_QUEEN');
  CheckChar('FEMALE_SUCCUBUS');

  { a sliced frame decodes, and the whole column reads back in range }
  si := LoadSprite(p, 'MALE_KING');
  sq := SpriteSeqIndex(si, 'IDLE');
  Check(SpriteFrame(si, sq, 0, img), 'the first king frame decodes');
  CheckEqI(img.w, 64, 'decoded frame width');
  Check(Length(img.pix) = 64 * 64, 'decoded pixel buffer size');
  Check(SpriteFrame(si, sq, 12, img), 'the last king frame decodes');
  Check(not SpriteFrame(si, sq, 13, img), 'a frame past the cycle is refused');

  { the shared clock loops the full 13-frame cycle }
  WorldAnimTick(1.0);
  Check(BankLoopFrame(si, sq, 0) < 13, 'the king loop frame stays in range');

  TestSummary('sprsheet');
  halt(TestExit);
end.
