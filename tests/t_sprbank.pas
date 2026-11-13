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
  idle, walk, bob, ping, si: longint;
  cur: TBankCursor;

{ A sequence whose frames total more than 64 KB forces the u32 frame-offset
  table; a u16 table would wrap and truncate a frame's length. Two 200x100
  noise frames are ~80 KB each, so frame 1 sits well past the old 64 KB cap. }
procedure BigBankRoundTrip;
var
  b: TSpriteBank;
  big: TImage;
  blob: pak.TByteArray;
  rb2: TRTBank;
  out1: TImage;
  i: longint;
begin
  ImgNew(big, 200, 100);
  for i := 0 to Length(big.pix) - 1 do
    big.pix[i] := UInt32((qword(i) * 2654435761) and $FFFFFFFF);  { noise, RLE-proof }

  b.flags := 0;
  SetLength(b.seqs, 1);
  b.seqs[0].name := 'IDLE';
  b.seqs[0].w := 200; b.seqs[0].h := 100;
  b.seqs[0].sflags := LOOP_LOOP;
  b.seqs[0].ox := 0; b.seqs[0].oy := 0;
  b.seqs[0].ticks := 4;
  SetLength(b.seqs[0].frames, 2);
  b.seqs[0].frames[0] := PicEncodeDirect(big);
  b.seqs[0].frames[1] := PicEncodeDirect(big);
  Check(Length(b.seqs[0].frames[0]) > 65535,
    'a noise frame is over 64 KB, past the old u16 cap');

  blob := EncodeBank(b);
  Check(DecodeBank(blob, rb2), 'a >64 KB bank decodes');
  CheckEqI(rb2.seqs[0].frameCount, 2, 'the big bank keeps both frames');
  Check(BankFrame(rb2, 0, 0, out1), 'the first >64 KB frame decodes');
  CheckEqI(out1.w, 200, 'big frame 0 width');
  Check(BankFrame(rb2, 0, 1, out1), 'the frame past 64 KB decodes');
  CheckEqI(out1.w, 200, 'big frame 1 width');
end;

begin
  if not PakLoad('build/game.pak', p) then begin
    writeln('  FAIL could not load build/game.pak (run make first)');
    halt(2);
  end;
  Check(LoadBank(p, 'BANK_SMOKE', rb), 'load the smoke bank');
  CheckEqI(Length(rb.seqs), 4, 'four sequences');

  idle := BankSeqIndex(rb, 'IDLE');
  walk := BankSeqIndex(rb, 'WALK');
  bob  := BankSeqIndex(rb, 'BOB');
  ping := BankSeqIndex(rb, 'PING');
  Check(idle >= 0, 'IDLE present');
  Check(walk >= 0, 'WALK present');
  Check(bob >= 0, 'BOB present');
  Check(ping >= 0, 'PING present');
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

  { a single-frame IDLE never advances }
  CursorStart(cur, idle);
  Check(not CursorTick(rb, cur, 1.0), 'single-frame IDLE does not animate');
  CheckEqI(cur.frame, 0, 'IDLE stays on frame 0');

  { BOB loops two frames at ticks=1 (1/12 s each): 0 -> 1 -> 0 }
  CursorStart(cur, bob);
  Check(CursorTick(rb, cur, 0.09), 'BOB advances past one frame of time');
  CheckEqI(cur.frame, 1, 'BOB on frame 1');
  Check(CursorTick(rb, cur, 0.09), 'BOB advances again');
  CheckEqI(cur.frame, 0, 'BOB wraps to frame 0');
  Check(not CursorTick(rb, cur, 0.04), 'a short tick holds the frame');
  CheckEqI(cur.frame, 0, 'BOB unchanged within a frame');

  { WALK plays once over three frames, then holds the last }
  CursorStart(cur, walk);
  Check(CursorTick(rb, cur, 0.26), 'WALK to frame 1');
  CheckEqI(cur.frame, 1, 'WALK frame 1');
  Check(CursorTick(rb, cur, 0.26), 'WALK to frame 2');
  CheckEqI(cur.frame, 2, 'WALK frame 2');
  Check(CursorAtEnd(rb, cur), 'WALK reports done at the last frame');
  Check(not CursorTick(rb, cur, 1.0), 'a finished once-sequence holds');
  CheckEqI(cur.frame, 2, 'WALK still on the last frame');

  { PING bounces 0 -> 1 -> 2 -> 1 -> 0 }
  CursorStart(cur, ping);
  CursorTick(rb, cur, 0.09); CheckEqI(cur.frame, 1, 'PING up to 1');
  CursorTick(rb, cur, 0.09); CheckEqI(cur.frame, 2, 'PING up to 2');
  CursorTick(rb, cur, 0.09); CheckEqI(cur.frame, 1, 'PING bounces to 1');
  CursorTick(rb, cur, 0.09); CheckEqI(cur.frame, 0, 'PING back to 0');
  CursorTick(rb, cur, 0.09); CheckEqI(cur.frame, 1, 'PING up again');

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

  BigBankRoundTrip;

  TestSummary('sprbank');
  halt(TestExit);
end.
