program t_worldspr;

{** Directional world NPCs (design section 27, P5). The world view picks which
  side of an NPC it sees from the camera bearing, then draws that cardinal's
  idle sequence, reusing the east art flipped for the west view. These checks
  pin the two pure pieces: the bearing-to-cardinal split (WorldViewDir) and the
  sequence pick with its mirror fallback (BankIdleForDir). The BANK_DIR fixture
  (content/banks/dirnpc.txt) carries IDLEN, IDLEE and IDLES but no IDLEW, so the
  west view must fall back to the east art. }

{$mode objfpc}{$H+}

uses
  sysutils, pak, mapfmt, sprites, worldspr, testing;

var
  p: TPak;
  dir, si, smoke, plain: longint;
  mir: boolean;

begin
  if not PakLoad('build/game.pak', p) then begin
    writeln('  FAIL could not load build/game.pak (run make first)');
    halt(2);
  end;

  { the camera bearing resolves to the NPC side it faces. NPC sits at (5,5). }
  CheckEqI(WorldViewDir(5, 5, 7, 5), DIR_E, 'camera to the east sees the E side');
  CheckEqI(WorldViewDir(5, 5, 3, 5), DIR_W, 'camera to the west sees the W side');
  CheckEqI(WorldViewDir(5, 5, 5, 7), DIR_S, 'camera to the south sees the S side');
  CheckEqI(WorldViewDir(5, 5, 5, 3), DIR_N, 'camera to the north sees the N side');
  { the dominant axis wins the 45 degree quadrant split }
  CheckEqI(WorldViewDir(5, 5, 7, 6), DIR_E, 'east dominates a shallow diagonal');
  CheckEqI(WorldViewDir(5, 5, 6, 7), DIR_S, 'south dominates a shallow diagonal');

  { the directional bank: N, E and S resolve to their own sequence unflipped }
  SpritesReset;
  si := LoadSprite(p, 'BANK_DIR');
  Check(si >= 0, 'the directional bank loads');
  Check(SpriteReg[si].isBank, 'BANK_DIR is a bank');
  Check(SpriteSeqIndex(si, 'IDLEW') < 0, 'BANK_DIR has no west sequence');

  dir := BankIdleForDir(si, DIR_N, mir);
  CheckEqI(dir, SpriteSeqIndex(si, 'IDLEN'), 'north picks IDLEN');
  Check(not mir, 'north is not mirrored');
  dir := BankIdleForDir(si, DIR_E, mir);
  CheckEqI(dir, SpriteSeqIndex(si, 'IDLEE'), 'east picks IDLEE');
  Check(not mir, 'east is not mirrored');
  dir := BankIdleForDir(si, DIR_S, mir);
  CheckEqI(dir, SpriteSeqIndex(si, 'IDLES'), 'south picks IDLES');
  Check(not mir, 'south is not mirrored');

  { west has no art, so it reuses the east sequence flipped }
  dir := BankIdleForDir(si, DIR_W, mir);
  CheckEqI(dir, SpriteSeqIndex(si, 'IDLEE'), 'west falls back to IDLEE');
  Check(mir, 'the west fallback is mirrored');

  { a non-directional bank (a plain IDLE) ignores the direction and never flips }
  smoke := LoadSprite(p, 'BANK_SMOKE');
  Check((smoke >= 0) and SpriteReg[smoke].isBank, 'BANK_SMOKE is a bank');
  dir := BankIdleForDir(smoke, DIR_N, mir);
  CheckEqI(dir, SpriteSeqIndex(smoke, 'IDLE'), 'a plain bank picks IDLE for north');
  Check(not mir, 'a plain bank north is not mirrored');
  dir := BankIdleForDir(smoke, DIR_W, mir);
  CheckEqI(dir, SpriteSeqIndex(smoke, 'IDLE'), 'a plain bank picks IDLE for west');
  Check(not mir, 'a plain bank west is not mirrored');

  { a plain PIC sprite is not a bank: no sequence, never mirrored }
  plain := LoadSprite(p, 'CREA1');
  Check((plain >= 0) and not SpriteReg[plain].isBank, 'CREA1 is a plain sprite');
  Check(BankIdleForDir(plain, DIR_E, mir) < 0, 'a plain sprite yields no sequence');
  Check(not mir, 'a plain sprite is not mirrored');

  { an out-of-range direction is refused }
  Check(BankIdleForDir(si, 7, mir) < 0, 'a bad direction is refused');

  TestSummary('worldspr');
  halt(TestExit);
end.
