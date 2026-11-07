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

procedure TitleRender;
const
  LABELS: array[0 .. TITLE_ITEMS - 1] of string = (
    'CONTINUE', 'NEW GAME', 'QUICK START', 'QUICK BATTLE', 'OPTIONS', 'QUIT');
var
  i, y: longint;
  c: TColor;
begin
  ClearFB(RGB(12, 10, 16));
  FillRect(0, 44, FBW, 2, RGB(90, 70, 40));
  DrawCenter(22, 'SHADOWS OF THE DEEP', RGB(220, 200, 120));
  DrawCenter(32, 'A DUNGEON CRAWL', RGB(120, 110, 90));
  y := 110;
  for i := 0 to TITLE_ITEMS - 1 do begin
    if i = titleSel then begin
      c := RGB(240, 230, 150);
      DrawText(FBW div 2 - Length(LABELS[i]) * 3 - 12, y, '>', c);
    end else
      c := RGB(150, 140, 120);
    if (i = 0) and (not SaveExists(SavePath)) then
      c := RGB(80, 76, 66);
    DrawCenter(y, LABELS[i], c);
    inc(y, 16);
  end;
  DrawCenter(FBH - 20, 'ARROWS SELECT   ENTER CONFIRM', RGB(90, 84, 70));
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
