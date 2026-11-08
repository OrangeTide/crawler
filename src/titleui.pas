unit titleui;

{** The title menu, the pregen party, and the two quick entry points.
  QuickBattle drops a pregen party straight into a test fight; QuickStart
  dives into the world. Menu choices call down into worldload, combatui
  and charcreateui. }

{$mode objfpc}{$H+}

interface

procedure TitleRender;
procedure TitleKeyDown(scancode: longint);
procedure TitleUsePalette;   { swap in the title's own 256-colour CLUT }
procedure QuickBattle;
procedure QuickBattleDepth(depth: longint);
procedure QuickStart;

implementation

uses
  sdl2min, gfx, pic, sprites, world, party, chardata, rules, audio, uihelp,
  gamestate, worldload, combatui, charcreateui, save, spellbook;

const
  TITLE_ITEMS = 6;

var
  titleTick: longword = 0;   { advances each render, to drift the birds }

{ Blit the baked title background: Jon's mountain photo, already dithered to
  the palette, loaded as a full-screen PIC lump. A missing lump leaves a dark
  field rather than a crash. }
procedure DrawTitleBg;
var
  si, x, y, w, h: longint;
begin
  si := LoadSprite(GamePak, 'TITLE_BG');
  if si < 0 then begin ClearFB(RGB(12, 14, 24)); exit; end;
  w := SpriteReg[si].img.w; h := SpriteReg[si].img.h;
  if (w <> FBW) or (h <> FBH) then begin ClearFB(RGB(12, 14, 24)); exit; end;
  for y := 0 to FBH - 1 do
    for x := 0 to FBW - 1 do
      PutPixel(x, y, SpriteReg[si].img.pix[y * w + x]);
end;

{ A distant bird: a small centre with two wings, flapped between a raised
  and a level pose. }
procedure DrawBird(bx, by: longint; up: boolean; c: TColor);
begin
  PutPixel(bx, by, c);
  PutPixel(bx - 1, by - 1, c); PutPixel(bx + 1, by - 1, c);
  if up then begin
    PutPixel(bx - 2, by - 2, c); PutPixel(bx + 2, by - 2, c);
  end else begin
    PutPixel(bx - 2, by - 1, c); PutPixel(bx + 2, by - 1, c);
  end;
end;

procedure DrawBirds;
const
  N = 6;
  baseX: array[0 .. N - 1] of longint = (40, 120, 190, 250, 85, 215);
  baseY: array[0 .. N - 1] of longint = (58, 46,  66,  50,  74, 62);
var
  i, bx, by: longint;
begin
  for i := 0 to N - 1 do begin
    bx := (baseX[i] - longint(titleTick div 3) + 360) mod 360 - 20;
    by := baseY[i] + round(3 * sin(titleTick * 0.04 + i * 1.7));
    DrawBird(bx, by, ((titleTick div 10 + longword(i)) and 1) = 0,
      RGB(34, 36, 52));
  end;
end;

{ The two-line title logo, each line a scaled string over its own shadow. }
procedure Logo(const s: string; y, sc: longint);
var
  x: longint;
begin
  x := (FBW - TextScaledWidth(s, sc)) div 2;
  DrawTextScaled(x + 2, y + 2, s, RGB(10, 8, 14), sc);
  DrawTextScaled(x, y, s, RGB(236, 214, 130), sc);
end;

{ Load the title's own 256-colour palette (baked as a 256x1 lump) and make it
  the active palette, so the scene renders smoothly in the PlayStation 8-bit
  way. A missing lump leaves the game palette in place. }
procedure TitleUsePalette;
var
  si, i, n: longint;
  cols: array[0 .. 255] of TColor;
begin
  si := LoadSprite(GamePak, 'TITLE_PAL');
  if si < 0 then exit;
  n := SpriteReg[si].img.w * SpriteReg[si].img.h;
  if n > 256 then n := 256;
  for i := 0 to 255 do
    if i < n then cols[i] := SpriteReg[si].img.pix[i] else cols[i] := RGB(0, 0, 0);
  UsePalette(cols);
end;

procedure TitleRender;
const
  LABELS: array[0 .. TITLE_ITEMS - 1] of string = (
    'CONTINUE', 'NEW GAME', 'QUICK START', 'QUICK BATTLE', 'OPTIONS', 'QUIT');
  BOXL = 106; BOXR = 214; BOXT = 150; BOXB = 226;
var
  i, y: longint;
  c: TColor;
begin
  inc(titleTick);
  { CONTINUE is dead without a save, so never rest the cursor on it }
  if (titleSel = 0) and (not SaveExists(SavePath)) then titleSel := 1;

  { the mountain photo, then birds drifting across its sky }
  DrawTitleBg;
  DrawBirds;

  { the title logo and its tagline }
  Logo('CITIES OF THE', 18, 2);
  Logo('SUNLESS DEPTHS', 36, 3);
  DrawCenter(63, 'A DUNGEON CRAWL', RGB(224, 228, 238));   { light underglow }
  DrawCenter(62, 'A DUNGEON CRAWL', RGB(34, 30, 54));       { dark, reads on sky }

  { the menu in a framed box over the foreground }
  FillRectBlend(BOXL, BOXT, BOXR - BOXL, BOXB - BOXT, RGB(14, 12, 24), 215);
  FrameRect(BOXL, BOXT, BOXR - BOXL, BOXB - BOXT, RGB(120, 110, 80));
  FrameRect(BOXL + 2, BOXT + 2, BOXR - BOXL - 4, BOXB - BOXT - 4, RGB(60, 54, 44));
  y := BOXT + 10;
  for i := 0 to TITLE_ITEMS - 1 do begin
    if i = titleSel then begin
      c := RGB(244, 230, 150);
      DrawText(FBW div 2 - Length(LABELS[i]) * 3 - 10, y, '>', c);
    end else
      c := RGB(176, 166, 146);
    if (i = 0) and (not SaveExists(SavePath)) then
      c := RGB(92, 86, 74);
    DrawCenter(y, LABELS[i], c);
    inc(y, 11);
  end;

  DrawCenter(FBH - 8, 'ARROWS SELECT   ENTER CONFIRM', RGB(120, 120, 150));
end;

procedure BuildPregenParty;
{** Roll a ready-to-play party of four: a fighter, thief, friar and wizard. }
var
  i, sp: longint;
  a: TAbilityScores;
  c: TCharacter;
  clsId: array[0 .. 3] of string = ('FIGHTER', 'THIEF', 'FRIAR', 'WIZARD');
begin
  NewParty;
  sp := SpeciesOr0('HUMAN');
  for i := 0 to 3 do begin
    RollAbilities(a);
    MakeCharacter(c, NAME_POOL[i], sp, ClassOr0(clsId[i]), 0, a);
    AutoLearn(c);   { a ready-made caster comes knowing its spells }
    AddPartyMember(c);
  end;
end;

procedure QuickStart;
{** Make a ready-to-play party of four and dive into the world. }
begin
  BuildPregenParty;
  StartGame;
end;

procedure QuickBattleDepth(depth: longint);
{** Skip the world and drop a pregen party into a test encounter at the given
   depth (deeper means more and bigger foes). Set FromQuickBattle so leaving
   the fight returns to the title, since no map is loaded. }
begin
  BuildPregenParty;
  CurMapName := 'QUICKBATTLE';
  CurAreaMask := 0;
  CurEncTable := 0;   { table 0 is empty, so StartRandomEncounter falls back
                        to the whole bestiary for a test fight }
  FromQuickBattle := true;
  StartCombat(depth);
end;

procedure QuickBattle;
{** A quick test fight at a mid depth. }
begin
  QuickBattleDepth(3);
end;

procedure TitleSelect;
begin
  case titleSel of
    0: if SaveExists(SavePath) then ContinueGame;
    1: begin State := gsNewParty; CCStartNewParty; end;
    2: QuickStart;
    3: QuickBattle;
    4: begin optSel := 0; State := gsOptions; end;
    5: QuitRequested := true;
  end;
end;

procedure TitleKeyDown(scancode: longint);
begin
  case scancode of
    SDL_SCANCODE_UP:     titleSel := (titleSel + TITLE_ITEMS - 1) mod TITLE_ITEMS;
    SDL_SCANCODE_DOWN:   titleSel := (titleSel + 1) mod TITLE_ITEMS;
    SDL_SCANCODE_RETURN, SDL_SCANCODE_SPACE: begin PlaySfx(SFX_SELECT); TitleSelect; end;
    SDL_SCANCODE_ESCAPE: QuitRequested := true;
  end;
  { skip the dead CONTINUE row when there is no save to continue }
  if (titleSel = 0) and (not SaveExists(SavePath)) then begin
    if scancode = SDL_SCANCODE_UP then titleSel := TITLE_ITEMS - 1
    else titleSel := 1;
  end;
end;

end.
