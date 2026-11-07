unit titleui;

{** The title menu, the pregen party, and the two quick entry points.
  QuickBattle drops a pregen party straight into a test fight; QuickStart
  dives into the world. Menu choices call down into worldload, combatui
  and charcreateui. }

{$mode objfpc}{$H+}

interface

procedure TitleRender;
procedure TitleKeyDown(scancode: longint);
procedure QuickBattle;
procedure QuickStart;

implementation

uses
  sdl2min, gfx, world, party, chardata, rules, audio, uihelp, gamestate,
  worldload, combatui, charcreateui, save;

const
  TITLE_ITEMS = 6;

var
  titleTick: longword = 0;   { advances each render, to drift the birds }

{ One channel of a linear blend between two stops. }
function Lerp1(a, b: longint; t: double): longint;
begin
  Lerp1 := round(a + (b - a) * t);
end;

{ The dusk sky colour at a vertical fraction 0 (zenith) to 1 (horizon):
  deep indigo overhead through blue and mauve to a warm rose and pale gold
  band at the ridgeline. The channels are the ideal, pre-dither values. }
function SkyColor(frac: double): TColor;
const
  NST = 5;
  sy: array[0 .. NST - 1] of double  = (0.0, 0.45, 0.72, 0.88, 1.0);
  sr: array[0 .. NST - 1] of longint = (32,  70,  138, 236, 250);
  sg: array[0 .. NST - 1] of longint = (34,  82,  130, 170, 206);
  sb: array[0 .. NST - 1] of longint = (78,  150, 182, 150, 150);
var
  seg: longint;
  lt: double;
begin
  if frac < 0 then frac := 0;
  if frac > 1 then frac := 1;
  seg := 0;
  while (seg < NST - 2) and (frac > sy[seg + 1]) do inc(seg);
  lt := (frac - sy[seg]) / (sy[seg + 1] - sy[seg]);
  SkyColor := RGB(Lerp1(sr[seg], sr[seg + 1], lt),
                  Lerp1(sg[seg], sg[seg + 1], lt),
                  Lerp1(sb[seg], sb[seg + 1], lt));
end;

{ One channel ordered-dithered between the two bracketing palette cube
  levels (the cube steps by 51), so a smooth gradient reads without the
  hard banding the 6x6x6 palette would otherwise show. }
function DitherCh(v, bx, by: longint): longint;
const
  bayer: array[0 .. 3, 0 .. 3] of longint =
    ((0, 8, 2, 10), (12, 4, 14, 6), (3, 11, 1, 9), (15, 7, 13, 5));
var
  lo: longint;
begin
  if v < 0 then v := 0;
  if v > 255 then v := 255;
  lo := (v div 51) * 51;
  if (v - lo) * 16 > (bayer[by and 3][bx and 3] * 51 + 25) then
    lo := lo + 51;
  if lo > 255 then lo := 255;
  DitherCh := lo;
end;

{ Fill the sky with the dithered gradient. }
procedure DrawSky;
var
  x, y, rr, gg, bb: longint;
  col: TColor;
begin
  for y := 0 to FBH - 1 do begin
    col := SkyColor(y / 132);
    rr := (col shr 16) and $FF; gg := (col shr 8) and $FF; bb := col and $FF;
    for x := 0 to FBW - 1 do
      PutPixel(x, y, RGB(DitherCh(rr, x, y), DitherCh(gg, x, y),
        DitherCh(bb, x, y)));
  end;
end;

{ A mountain ridge: a wandering crest from two sines, filled solid to the
  foot of the screen. A near ridge drawn over a far one reads as depth. }
procedure DrawRidge(baseY, a1, a2: longint; f1, p1, f2, p2: double;
  col, rim: TColor; doRim: boolean);
var
  x, top: longint;
begin
  for x := 0 to FBW - 1 do begin
    top := baseY - round(a1 * sin(x * f1 + p1)) - round(a2 * sin(x * f2 + p2));
    if top < 0 then top := 0;
    VLine(x, top, FBH - top, col);
    if doRim then PutPixel(x, top, rim);   { a dawn rim picks out the crest }
  end;
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
  baseY: array[0 .. N - 1] of longint = (74, 60,  82,  66,  96, 92);
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

  { the sky: a dithered gradient packed into the space above the ridgeline }
  DrawSky;

  { far then near mountains, the near one rimmed by the last light }
  DrawRidge(116, 9, 15, 0.050, 0.6, 0.015, 2.0, RGB(56, 60, 96),
    RGB(0, 0, 0), false);
  DrawRidge(150, 8, 13, 0.038, 3.1, 0.090, 0.4, RGB(24, 22, 40),
    RGB(78, 72, 108), true);

  DrawBirds;

  { the title logo and its tagline }
  Logo('SHADOWS', 16, 3);
  Logo('OF THE DEEP', 42, 2);
  DrawCenter(62, 'A DUNGEON CRAWL', RGB(150, 150, 180));

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
    AddPartyMember(c);
  end;
end;

procedure QuickStart;
{** Make a ready-to-play party of four and dive into the world. }
begin
  BuildPregenParty;
  StartGame;
end;

procedure QuickBattle;
{** Skip the world and drop a pregen party into a test encounter. Set
   FromQuickBattle so leaving the fight returns to the title, since no map
   is loaded. Any area, a mid depth for a meaty mix of foes. }
begin
  BuildPregenParty;
  CurMapName := 'QUICKBATTLE';
  CurAreaMask := 0;
  CurEncTable := 0;   { table 0 is empty, so StartRandomEncounter falls back
                        to the whole bestiary for a test fight }
  FromQuickBattle := true;
  StartCombat(3);
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
end;

end.
