program t_sprbank;

{** The sprite-bank format (design section 27). The smoke bank in
  content/banks/smoke.txt bakes to the BANK_SMOKE lump: two sequences with
  different frame counts, loop modes, anchor and the mirror hint. These checks
  pin the baked directory and decode a frame back to an image. }

{$mode objfpc}{$H+}

uses
  sysutils, pak, pic, sprbank, sprites, testing;

var
  p: TPak;
  rb: TRTBank;
  img: TImage;
  idle, walk, si: longint;

begin
  if not PakLoad('build/game.pak', p) then begin
    writeln('  FAIL could not load build/game.pak (run make first)');
    halt(2);
  end;
  Check(LoadBank(p, 'BANK_SMOKE', rb), 'load the smoke bank');
  CheckEqI(Length(rb.seqs), 2, 'two sequences');

  idle := BankSeqIndex(rb, 'IDLE');
  walk := BankSeqIndex(rb, 'WALK');
  Check(idle >= 0, 'IDLE present');
  Check(walk >= 0, 'WALK present');
  Check(BankSeqIndex(rb, 'MISSING') < 0, 'unknown sequence is -1');

  { IDLE: one frame, loop, anchor oy=4, ticks 6, no mirror }
  CheckEqI(rb.seqs[idle].frameCount, 1, 'IDLE has one frame');
  CheckEqI(rb.seqs[idle].sflags and $03, LOOP_LOOP, 'IDLE loops');
  Check((rb.seqs[idle].sflags and SEQ_MIRROR) = 0, 'IDLE is not mirrored');
  CheckEqI(rb.seqs[idle].oy, 4, 'IDLE anchor oy is 4');
  CheckEqI(rb.seqs[idle].ticks, 6, 'IDLE ticks is 6');
  CheckEqI(rb.seqs[idle].w, 64, 'IDLE frame width');
  CheckEqI(rb.seqs[idle].h, 64, 'IDLE frame height');

  { WALK: three frames, play once, mirror hint, anchor ox=-2, ticks 3 }
  CheckEqI(rb.seqs[walk].frameCount, 3, 'WALK has three frames');
  CheckEqI(rb.seqs[walk].sflags and $03, LOOP_ONCE, 'WALK plays once');
  Check((rb.seqs[walk].sflags and SEQ_MIRROR) <> 0, 'WALK carries the mirror hint');
  CheckEqI(rb.seqs[walk].ox, -2, 'WALK anchor ox is -2');
  CheckEqI(rb.seqs[walk].ticks, 3, 'WALK ticks is 3');

  { every frame decodes to a 64x64 image }
  Check(BankFrame(rb, idle, 0, img), 'decode IDLE frame 0');
  CheckEqI(img.w, 64, 'decoded frame width');
  CheckEqI(img.h, 64, 'decoded frame height');
  Check(Length(img.pix) = 64 * 64, 'decoded pixel buffer size');
  Check(BankFrame(rb, walk, 2, img), 'decode WALK frame 2');
  CheckEqI(img.w, 64, 'last WALK frame width');

  { out-of-range frame and sequence are refused }
  Check(not BankFrame(rb, idle, 1, img), 'frame past the end is refused');
  Check(not BankFrame(rb, 99, 0, img), 'bad sequence index is refused');

  { the sprite store sniffs the magic and holds the bank }
  SpritesReset;
  si := LoadSprite(p, 'BANK_SMOKE');
  Check(si >= 0, 'store loads the bank by id');
  Check(SpriteReg[si].isBank, 'the entry is flagged a bank');
  { the default .img is the first sequence's first frame, so legacy draw works }
  CheckEqI(SpriteReg[si].img.w, 64, 'default frame width for legacy callers');
  CheckEqI(SpriteReg[si].img.h, 64, 'default frame height for legacy callers');
  Check(LoadSprite(p, 'BANK_SMOKE') = si, 'a cached bank returns the same slot');

  { the store accessors reach the sequences and frames }
  Check(SpriteSeqIndex(si, 'WALK') >= 0, 'store finds the WALK sequence');
  Check(SpriteSeqIndex(si, 'NOPE') < 0, 'store rejects an unknown sequence');
  Check(SpriteFrame(si, SpriteSeqIndex(si, 'WALK'), 1, img),
    'store decodes a bank frame');
  CheckEqI(img.w, 64, 'store frame width');

  { the migrated monster billboards are single-sequence IDLE banks }
  si := LoadSprite(p, 'CREA7');
  Check((si >= 0) and SpriteReg[si].isBank, 'CREA7 skeleton is a bank');
  Check(SpriteSeqIndex(si, 'IDLE') >= 0, 'CREA7 has an IDLE sequence');
  si := LoadSprite(p, 'CREA15');
  Check((si >= 0) and SpriteReg[si].isBank, 'CREA15 acolyte is a bank');

  { a plain PIC sprite is not a bank and has no sequences }
  si := LoadSprite(p, 'CREA1');
  Check(si >= 0, 'store loads a plain sprite');
  Check(not SpriteReg[si].isBank, 'a plain sprite is not a bank');
  Check(SpriteSeqIndex(si, 'IDLE') < 0, 'a plain sprite has no sequence');
  Check(not SpriteFrame(si, 0, 0, img), 'a plain sprite yields no bank frame');

  TestSummary('sprbank');
  halt(TestExit);
end.
