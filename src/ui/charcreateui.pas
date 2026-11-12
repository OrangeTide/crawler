unit charcreateui;

{** Character creation: roll and accept the party, one member at a time.
  Also the two small id-to-index helpers shared with the title screen.
  CCAccept finishes into the world through worldload.StartGame. }

{$mode objfpc}{$H+}

interface

function ClassOr0(const id: string): longint;
function SpeciesOr0(const id: string): longint;
procedure CCStartNewParty;
procedure CCRender;
procedure CCKeyDown(scancode: longint);

implementation

uses
  sysutils, sdl2min, gfx, chardata, party, rules, uihelp, gamestate, worldload,
  pcportrait;

var
  ccSlot: longint;
  ccSpecies: longint;
  ccClass: longint;
  ccBg: longint;
  ccNameIdx: longint;
  ccPortrait: longint;
  ccAbil: TAbilityScores;
  ccPreview: TCharacter;

function ClassOr0(const id: string): longint;
begin
  ClassOr0 := ClassIndex(id);
  if ClassOr0 < 0 then ClassOr0 := 0;
end;

function SpeciesOr0(const id: string): longint;
begin
  SpeciesOr0 := SpeciesIndex(id);
  if SpeciesOr0 < 0 then SpeciesOr0 := 0;
end;

procedure CCRebuild;
begin
  MakeCharacter(ccPreview, NamePool[ccNameIdx], ccSpecies, ccClass, ccBg, ccAbil);
  ccPreview.portrait := ccPortrait;
end;

procedure CCBeginSlot;
begin
  ccSpecies := SpeciesOr0(DefaultSpecies);
  ccClass := ClassOr0(DefaultClass);
  ccBg := 0;
  ccNameIdx := ccSlot;
  ccPortrait := PCPortraitClamp(ccSlot);
  RollAbilities(ccAbil);
  CCRebuild;
end;

{ Start a fresh party at the first slot. The title screen calls this to
  enter character creation. }
procedure CCStartNewParty;
begin
  NewParty;
  ccSlot := 0;
  CCBeginSlot;
end;

procedure CCRender;
var
  y: longint;
  a: TAbility;
  s, modStr: string;
  m: longint;
begin
  ClearFB(RGB(14, 12, 18));
  DrawCenter(10, 'CREATE PARTY   MEMBER ' + IntToStr(ccSlot + 1) + ' OF '
    + IntToStr(MAX_PARTY), RGB(220, 200, 120));

  DrawText(30, 30, 'NAME:    ' + NamePool[ccNameIdx], RGB(200, 200, 180));
  DrawText(30, 42, 'SPECIES: ' + SpeciesDefs[ccSpecies].name, RGB(200, 200, 180));
  DrawText(30, 54, 'CLASS:   ' + ClassDefs[ccClass].name, RGB(200, 200, 180));
  DrawText(30, 66, 'PAST:    ' + BackgroundDefs[ccBg].name, RGB(190, 190, 160));

  y := 84;
  for a := abSTR to abCHA do begin
    m := AbilMod(ccPreview.abil[a]);
    if m >= 0 then modStr := '+' + IntToStr(m) else modStr := IntToStr(m);
    Str(ccPreview.abil[a], s);
    DrawText(40, y, ABIL_NAME[a] + ' ' + s + ' (' + modStr + ')',
      RGB(180, 190, 170));
    inc(y, 11);
  end;

  DrawText(150, 80, 'HP ' + IntToStr(ccPreview.hpMax), RGB(200, 160, 160));
  DrawText(150, 91, 'AC ' + IntToStr(CharAC(ccPreview)), RGB(160, 180, 200));
  DrawText(150, 102, 'ATK ' + IntToStr(CharAttack(ccPreview, true)),
    RGB(200, 190, 150));

  { the chosen face, framed, top right }
  FillRect(240, 28, 64, 64, RGB(0, 0, 0));
  DrawPCPortrait(240, 28, ccPortrait);
  FrameRect(240, 28, 64, 64, RGB(120, 110, 90));

  DrawText(14, FBH - 40, 'N NAME  K SPECIES  [ ] CLASS  B PAST  R REROLL',
    RGB(140, 130, 110));
  DrawText(14, FBH - 28, 'P FACE   ENTER ACCEPT   G FINISH   ESC TITLE',
    RGB(140, 130, 110));
end;

procedure CCAccept;
var
  c: TCharacter;
begin
  MakeCharacter(c, NamePool[ccNameIdx], ccSpecies, ccClass, ccBg, ccAbil);
  c.portrait := ccPortrait;
  AddPartyMember(c);
  inc(ccSlot);
  if ccSlot >= MAX_PARTY then
    StartGame
  else
    CCBeginSlot;
end;

procedure CCKeyDown(scancode: longint);
begin
  case scancode of
    SDL_SCANCODE_N:
      ccNameIdx := (ccNameIdx + 1) mod Length(NamePool);
    SDL_SCANCODE_K: begin
      ccSpecies := (ccSpecies + 1) mod Length(SpeciesDefs);
      CCRebuild;
    end;
    SDL_SCANCODE_B: begin
      ccBg := (ccBg + 1) mod Length(BackgroundDefs);
      CCRebuild;
    end;
    SDL_SCANCODE_RIGHTBRACKET, SDL_SCANCODE_E: begin
      ccClass := (ccClass + 1) mod Length(ClassDefs);
      CCRebuild;
    end;
    SDL_SCANCODE_LEFTBRACKET, SDL_SCANCODE_Q: begin
      ccClass := (ccClass + Length(ClassDefs) - 1) mod Length(ClassDefs);
      CCRebuild;
    end;
    SDL_SCANCODE_P: begin
      ccPortrait := PCPortraitClamp(ccPortrait + 1);
      ccPreview.portrait := ccPortrait;
    end;
    SDL_SCANCODE_R: begin
      RollAbilities(ccAbil);
      CCRebuild;
    end;
    SDL_SCANCODE_RETURN, SDL_SCANCODE_SPACE:
      CCAccept;
    SDL_SCANCODE_G:
      if Length(Roster) > 0 then
        StartGame
      else
        CCAccept;
    SDL_SCANCODE_ESCAPE: begin
      NewParty;
      State := gsTitle;
    end;
  end;
end;

end.
