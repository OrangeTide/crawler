program t_worldspr;

{** World NPC facing by a sprite flip (design section 27, P5). The source art
  animates one facing, so the world view reuses it flipped for the other side:
  a moving entity walks and faces the way it heads, a still one idles. These
  checks pin the three pure pieces: the looping frame pick off the shared clock
  (BankLoopFrame) and the sequence-and-flip decision (WorldSpriteFrame). The
  BANK_WALK fixture (content/banks/walker.txt) carries a two-frame IDLE and a
  three-frame WALK. }

{$mode objfpc}{$H+}

uses
  sysutils, pak, pic, sprites, worldspr, testing;

var
  p: TPak;
  e: TWorldSprite;
  img: TImage;
  si: longint;
  mir: boolean;

{ a world entry at the origin, sprite si, heading (hx,hy), no phase }
function Ent(si: longint; hx, hy: double): TWorldSprite;
begin
  Ent.x := 0; Ent.y := 0; Ent.wh := 1; Ent.img := si;
  Ent.hx := hx; Ent.hy := hy; Ent.phase := 0;
end;

begin
  if not PakLoad('build/game.pak', p) then begin
    writeln('  FAIL could not load build/game.pak (run make first)');
    halt(2);
  end;

  SpritesReset;
  si := LoadSprite(p, 'BANK_WALK');
  Check(si >= 0, 'the walk bank loads');
  Check(SpriteReg[si].isBank, 'BANK_WALK is a bank');

  { a still entity idles and never flips. The camera right vector here is the
    east axis (1,0). }
  e := Ent(si, 0, 0);
  Check(WorldSpriteFrame(e, 1, 0, img, mir), 'a still bank entity resolves a frame');
  CheckEqI(img.w, 64, 'the idle frame decodes');
  Check(not mir, 'a still entity is not flipped');

  { a mover walks. Heading east, with the camera right along east, reads to the
    screen-right: no flip. }
  e := Ent(si, 1, 0);
  Check(WorldSpriteFrame(e, 1, 0, img, mir), 'a moving entity resolves a frame');
  Check(not mir, 'moving with the camera right is not flipped');

  { heading west against the same camera right reads to the screen-left: flip. }
  e := Ent(si, -1, 0);
  Check(WorldSpriteFrame(e, 1, 0, img, mir), 'the opposite heading resolves');
  Check(mir, 'moving against the camera right flips');

  { the flip follows the camera, not the world: the same west heading seen with
    a flipped camera right (facing the other way) reads to the screen-right. }
  e := Ent(si, -1, 0);
  Check(WorldSpriteFrame(e, -1, 0, img, mir), 'the turned-camera case resolves');
  Check(not mir, 'the same heading under a flipped camera does not flip');

  { the shared clock drives the looping frame. The process starts the clock at
    zero; advance it 0.3 s. WALK runs at ticks=3 (0.25 s a frame), so 0.3 s is
    frame 1; IDLE at ticks=6 (0.5 s a frame) is still frame 0. }
  WorldAnimTick(0.3);
  CheckEqI(BankLoopFrame(si, SpriteSeqIndex(si, 'WALK'), 0), 1,
    'the walk cycle is on frame 1 at 0.3 s');
  CheckEqI(BankLoopFrame(si, SpriteSeqIndex(si, 'IDLE'), 0), 0,
    'the idle cycle is still on frame 0 at 0.3 s');
  { a phase offset shifts the same clock onto a later frame }
  CheckEqI(BankLoopFrame(si, SpriteSeqIndex(si, 'WALK'), 0.25), 2,
    'a quarter-second phase advances the walk a frame');

  { a non-looping call with a single-frame sequence never leaves frame 0 }
  si := LoadSprite(p, 'CREA7');          { a one-frame IDLE bank }
  CheckEqI(BankLoopFrame(si, SpriteSeqIndex(si, 'IDLE'), 0), 0,
    'a single-frame sequence holds frame 0');

  { a plain PIC sprite is not a bank: no frame, never flipped }
  si := LoadSprite(p, 'CREA1');
  Check((si >= 0) and not SpriteReg[si].isBank, 'CREA1 is a plain sprite');
  e := Ent(si, 1, 0);
  Check(not WorldSpriteFrame(e, 1, 0, img, mir), 'a plain sprite yields no frame');
  Check(not mir, 'a plain sprite is not flipped');
  CheckEqI(BankLoopFrame(si, 0, 0), 0, 'a plain sprite loop frame is 0');

  TestSummary('worldspr');
  halt(TestExit);
end.
