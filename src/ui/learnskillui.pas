unit learnskillui;

{** The learn-a-skill screen: a member spends banked proficiency slots on
  skills its class may train, raising a known skill's rank or learning a new
  one. Opened with T from the character sheet; closes back to it. }

{$mode objfpc}{$H+}

interface

procedure LearnSkillRender;
procedure LearnSkillKeyDown(scancode: longint);

implementation

uses
  sysutils, sdl2min, gfx, uihelp, audio, gamestate, party, chardata, rules,
  skilldb, skillbook, skillicon;

procedure LearnSkillRender;
const ROWS = 9;
var
  total, firstRow, r, si2, skIdx, y, rank: longint;
  tag: string;
begin
  ClearFB(RGB(10, 10, 16));
  if (skillActor < 0) or (skillActor > High(Roster)) then begin
    State := gsCharSheet; exit;
  end;
  DrawText(12, 10, 'TRAIN A SKILL  (slots '
    + IntToStr(Roster[skillActor].skillSlots) + ')', RGB(230, 210, 130));
  DrawText(12, 22, Roster[skillActor].name + ' the '
    + ClassDefs[Roster[skillActor].klass].name, RGB(150, 170, 190));
  total := LearnableCount(Roster[skillActor]);
  if skillTrainSel >= total then skillTrainSel := total - 1;
  if skillTrainSel < 0 then skillTrainSel := 0;
  if total = 0 then begin
    DrawText(16, 44, 'No skills left to train.', RGB(150, 150, 130));
    DrawText(16, 160, 'ESC DONE', RGB(130, 140, 110));
    exit;
  end;
  firstRow := (skillTrainSel div ROWS) * ROWS;
  y := 40;
  for r := 0 to ROWS - 1 do begin
    si2 := firstRow + r;
    if si2 >= total then break;
    skIdx := LearnableNth(Roster[skillActor], si2);
    if skIdx < 0 then break;
    rank := SkillRank(Roster[skillActor], skIdx);
    if rank < 0 then tag := '  new' else tag := '  R' + IntToStr(rank) + '->'
      + IntToStr(rank + 1);
    if si2 = skillTrainSel then
      FillRectBlend(12, y - 1, 184, 11, RGB(44, 44, 66), 230);
    DrawSkillIcon(14, y, 9, 9, SkillDefs[skIdx].icon);
    if si2 = skillTrainSel then
      DrawText(26, y + 1, SkillDefs[skIdx].name + tag, RGB(244, 230, 150))
    else
      DrawText(26, y + 1, SkillDefs[skIdx].name + tag, RGB(190, 195, 180));
    inc(y, 11);
  end;
  DrawText(16, 150, IntToStr(skillTrainSel + 1) + ' of ' + IntToStr(total),
    RGB(120, 130, 110));
  DrawText(16, 160, 'UP/DN CHOOSE   ENTER TRAIN   ESC DONE', RGB(130, 140, 110));

  skIdx := LearnableNth(Roster[skillActor], skillTrainSel);
  if skIdx >= 0 then begin
    FrameRect(8, 172, FBW - 16, FBH - 172 - 4, RGB(90, 84, 70));
    DrawText(16, 178, SkillDefs[skIdx].name + '   ('
      + ArenaName(SkillDefs[skIdx].arena) + ', '
      + ABIL_NAME[TAbility(SkillDefs[skIdx].ability)] + ')', RGB(230, 210, 140));
    DrawWrapped(16, 190, 48, SkillDefs[skIdx].effectText, RGB(200, 200, 185));
  end;
end;

procedure LearnSkillKeyDown(scancode: longint);
var total, skIdx: longint;
begin
  if (skillActor < 0) or (skillActor > High(Roster)) then begin
    State := gsCharSheet; exit;
  end;
  total := LearnableCount(Roster[skillActor]);
  case scancode of
    SDL_SCANCODE_UP:
      if skillTrainSel > 0 then dec(skillTrainSel);
    SDL_SCANCODE_DOWN:
      if skillTrainSel < total - 1 then inc(skillTrainSel);
    SDL_SCANCODE_RETURN, SDL_SCANCODE_SPACE:
      begin
        skIdx := LearnableNth(Roster[skillActor], skillTrainSel);
        if skIdx >= 0 then begin
          if LearnSkill(Roster[skillActor], skIdx) then PlaySfx(SFX_SELECT)
          else PlaySfx(SFX_MISS);
        end;
        if Roster[skillActor].skillSlots = 0 then State := gsCharSheet;
      end;
    SDL_SCANCODE_T, SDL_SCANCODE_ESCAPE: State := gsCharSheet;
  end;
end;

end.
