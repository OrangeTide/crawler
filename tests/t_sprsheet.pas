program t_sprsheet;

{** Grid character sheets sliced into banks (design section 27). The male and
  female character sheets bake one bank per column through the `sheet` manifest
  (content/banks/sheets/*.sheet). These checks load a few of the baked lumps and
  confirm the slice: each is a bank carrying a 13-frame IDLE cycle of 64x64
  frames that the store animates like any other bank.

  The enemy pack sheets slice by action row instead (idle, walk, attack,
  death), each row a sequence with its own frame count, so a few of those are
  checked by sequence to pin the per-row runs. }

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

procedure CheckSeq(const lump, seq: string; frames: longint);
var idx, s: longint;
begin
  idx := LoadSprite(p, lump);
  Check(idx >= 0, lump + ' loads from the pak');
  Check(SpriteReg[idx].isBank, lump + ' is a bank');
  s := SpriteSeqIndex(idx, seq);
  Check(s >= 0, lump + ' has a ' + seq + ' sequence');
  if s >= 0 then begin
    CheckEqI(SpriteReg[idx].bank.seqs[s].frameCount, frames,
      lump + ' ' + seq + ' frame count');
    CheckEqI(SpriteReg[idx].bank.seqs[s].w, 64, lump + ' ' + seq + ' width 64');
    CheckEqI(SpriteReg[idx].bank.seqs[s].h, 64, lump + ' ' + seq + ' height 64');
  end;
end;

procedure CheckSeqWH(const lump, seq: string; frames, w, h: longint);
var idx, s: longint;
begin
  idx := LoadSprite(p, lump);
  Check(idx >= 0, lump + ' loads from the pak');
  s := SpriteSeqIndex(idx, seq);
  Check(s >= 0, lump + ' has a ' + seq + ' sequence');
  if s >= 0 then begin
    CheckEqI(SpriteReg[idx].bank.seqs[s].frameCount, frames,
      lump + ' ' + seq + ' frame count');
    CheckEqI(SpriteReg[idx].bank.seqs[s].w, w, lump + ' ' + seq + ' width');
    CheckEqI(SpriteReg[idx].bank.seqs[s].h, h, lump + ' ' + seq + ' height');
  end;
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

  { enemy action sheets: per-row sequences with ragged frame counts }
  CheckSeq('ORC', 'IDLE', 5);
  CheckSeq('ORC', 'WALK', 8);
  CheckSeq('ORC', 'ATTACK', 6);
  CheckSeq('ORC', 'DEATH', 7);
  CheckSeq('BAT', 'WALK', 6);
  CheckSeq('BAT', 'DEATH', 6);
  CheckSeq('PUMPKIN', 'IDLE', 10);
  CheckSeq('PUMPKIN', 'ATTACK', 9);
  Check(SpriteSeqIndex(LoadSprite(p, 'PUMPKIN'), 'WALK') < 0,
    'the rooted pumpkin has no WALK sequence');
  CheckSeq('FLYINGWITCH', 'ATTACK', 8);
  CheckSeq('MUSHROOM', 'WALK', 5);

  { single-character action sheets sliced with the linear run (lin A-B), one
    bank per colour variant }
  CheckSeq('ARCHER', 'IDLE', 5);
  CheckSeq('ARCHER', 'WALK', 8);
  CheckSeq('ARCHER', 'ATTACK', 11);
  CheckSeq('ARCHER', 'HURT', 5);
  CheckSeq('ARCHER', 'DEATH', 6);
  CheckSeq('ARCHER_RED', 'IDLE', 5);
  CheckSeq('ARCHER_BLUE', 'WALK', 8);
  { a linear run that wraps past the right edge still decodes a real frame:
    ARCHER WALK is lin 22-29 on an 11-wide sheet, so frame 0 is cell (0,2) }
  si := LoadSprite(p, 'ARCHER');
  sq := SpriteSeqIndex(si, 'WALK');
  Check(SpriteFrame(si, sq, 0, img), 'a wrapped linear walk frame decodes');
  CheckEqI(img.w, 64, 'wrapped frame width is 64');

  { wrap-style enemy strips sliced by linear range }
  CheckSeq('ZOMBIE', 'IDLE', 10);
  CheckSeq('ZOMBIE', 'WALK', 9);
  CheckSeq('ZOMBIE', 'DEATH', 12);
  CheckSeq('ZOMBIE_V4', 'IDLE', 10);
  CheckSeq('SKELETON', 'IDLE', 8);
  CheckSeq('SKELETON', 'WALK', 10);
  CheckSeq('SKELETON', 'ATTACK', 5);
  CheckSeq('SKELETON_GOLD', 'DEATH', 10);

  { non-square cells (goblin 72x80) and large cells (spider 96x96) }
  CheckSeqWH('GOBLIN', 'IDLE', 7, 72, 80);
  CheckSeqWH('GOBLIN', 'WALK', 6, 72, 80);
  CheckSeqWH('GOBLIN_RED', 'DEATH', 7, 72, 80);
  CheckSeqWH('SPIDER', 'IDLE', 12, 96, 96);
  CheckSeqWH('SPIDER', 'WALK', 16, 96, 96);
  CheckSeqWH('SPIDER', 'DEATH', 10, 96, 96);

  { samurai is a wide 96x64 cell; angel a 96x96 cell }
  CheckSeqWH('SAMURAI', 'IDLE', 5, 96, 64);
  CheckSeqWH('SAMURAI', 'WALK', 8, 96, 64);
  CheckSeqWH('SAMURAI', 'DEATH', 9, 96, 64);
  CheckSeqWH('SAMURAI_RED', 'ATTACK', 8, 96, 64);
  CheckSeqWH('ANGEL', 'IDLE', 8, 96, 96);
  CheckSeqWH('ANGEL', 'WALK', 10, 96, 96);

  CheckSeq('WIZARD', 'IDLE', 6);
  CheckSeq('WIZARD', 'CAST', 6);
  CheckSeq('WIZARD_RED', 'DEATH', 5);
  CheckSeq('ALIEN', 'IDLE', 5);
  CheckSeq('ALIEN', 'WALK', 8);
  CheckSeq('ALIEN', 'ATTACK', 5);

  CheckSeqWH('KNIGHT', 'IDLE', 5, 69, 58);
  CheckSeqWH('KNIGHT', 'WALK', 5, 69, 58);
  CheckSeqWH('KNIGHT', 'BLOCK', 5, 69, 58);
  CheckSeqWH('KNIGHT_GREEN', 'DEATH', 6, 69, 58);

  { farm animals on their own cell sizes }
  CheckSeqWH('HORSE', 'IDLE', 6, 128, 90);
  CheckSeqWH('HORSE', 'RUN', 6, 128, 90);
  CheckSeqWH('COW', 'IDLE', 8, 112, 80);
  CheckSeqWH('COW', 'GRAZE', 8, 112, 80);
  CheckSeqWH('PIG', 'WALK', 7, 80, 48);
  CheckSeqWH('CHICKEN', 'IDLE', 6, 32, 32);
  CheckSeqWH('CHICKEN_WHITE', 'PECK', 6, 32, 32);

  CheckSeqWH('RIDER', 'IDLE', 10, 128, 111);
  CheckSeqWH('RIDER', 'GALLOP', 10, 128, 111);
  CheckSeqWH('RIDER_RED', 'DEATH', 6, 128, 111);
  CheckSeq('AGENT', 'IDLE', 5);
  CheckSeq('AGENT', 'WALK', 8);
  CheckSeq('AGENT_GREEN', 'DEATH', 8);

  CheckSeqWH('HKNIGHT', 'IDLE', 5, 91, 64);
  CheckSeqWH('HKNIGHT', 'BLOCK', 5, 91, 64);
  CheckSeqWH('HKNIGHT_RED', 'DEATH', 5, 91, 64);

  CheckSeq('MAID', 'IDLE', 8);
  CheckSeq('MAID', 'WALK', 8);
  CheckSeq('MAID_RED', 'DEATH', 8);

  CheckSeq('MAIDEN', 'IDLE', 5);
  CheckSeq('MAIDEN', 'WALK', 8);
  CheckSeq('MAIDEN', 'HARP', 10);
  CheckSeq('FAGENT', 'IDLE', 5);
  CheckSeq('FAGENT', 'WALK', 8);
  CheckSeq('FAGENT_RED', 'DEATH', 12);

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
