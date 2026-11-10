unit learnspellui;

{** The learn-a-spell screen: a caster picks which spell it learns when it
  gains a slot, at creation and on each level that owes it one. The update loop
  opens this state while any caster has a pending pick; it closes once none do. }

{$mode objfpc}{$H+}

interface

procedure LearnRender;
procedure LearnKeyDown(scancode: longint);

implementation

uses
  sysutils, sdl2min, gfx, uihelp, gamestate, party, chardata, spelldb,
  spellbook, spellicon;

var
  learnSel: longint = 0;      { highlighted spell in the learn-a-spell screen }

procedure LearnRender;
const ROWS = 9;
var actor, total, pend, firstRow, r, si, y, spIdx: longint; tag: string;
begin
  ClearFB(RGB(10, 10, 16));
  actor := NextLearner;
  if actor < 0 then exit;   { nothing left to pick; the update loop will leave }
  pend := PendingLearns(Roster[actor]);
  DrawText(12, 10, 'LEARN A SPELL  (pick ' + IntToStr(pend) + ')',
    RGB(230, 210, 130));
  DrawText(12, 22, Roster[actor].name + ' the '
    + ClassDefs[Roster[actor].klass].name, RGB(150, 170, 190));
  total := LearnableCount(Roster[actor]);
  if learnSel >= total then learnSel := total - 1;
  if learnSel < 0 then learnSel := 0;
  if total = 0 then begin
    DrawText(16, 44, 'No new spells within reach.', RGB(150, 150, 130));
    exit;
  end;
  firstRow := (learnSel div ROWS) * ROWS;
  y := 40;
  for r := 0 to ROWS - 1 do begin
    si := firstRow + r;
    if si >= total then break;
    spIdx := LearnableNth(Roster[actor], si);
    if spIdx < 0 then break;
    tag := '';
    if not SpellDefs[spIdx].castable then tag := '  (util)';
    if si = learnSel then
      FillRectBlend(12, y - 1, 184, 11, RGB(44, 44, 66), 230);
    DrawSpellIcon(14, y, 9, 9, SpellDefs[spIdx].icon);
    if si = learnSel then
      DrawText(26, y + 1, 'L' + IntToStr(SpellDefs[spIdx].level) + ' '
        + SpellDefs[spIdx].name + tag, RGB(244, 230, 150))
    else
      DrawText(26, y + 1, 'L' + IntToStr(SpellDefs[spIdx].level) + ' '
        + SpellDefs[spIdx].name + tag, RGB(190, 195, 180));
    inc(y, 11);
  end;
  DrawText(16, 150, IntToStr(learnSel + 1) + ' of ' + IntToStr(total),
    RGB(120, 130, 110));
  DrawText(16, 160, 'UP/DN CHOOSE   ENTER LEARN', RGB(130, 140, 110));

  { the highlighted spell in full: its prose is what it does }
  spIdx := LearnableNth(Roster[actor], learnSel);
  if spIdx >= 0 then begin
    FrameRect(8, 172, FBW - 16, FBH - 172 - 4, RGB(90, 84, 70));
    if SpellDefs[spIdx].school <> SCH_NONE then
      DrawText(16, 178, SpellDefs[spIdx].name + '  ('
        + SchoolName(SpellDefs[spIdx].school) + ')', RGB(230, 210, 140))
    else
      DrawText(16, 178, SpellDefs[spIdx].name, RGB(230, 210, 140));
    DrawWrapped(16, 190, 48, SpellDefs[spIdx].effect, RGB(200, 200, 185));
  end;
end;

procedure LearnKeyDown(scancode: longint);
var actor, total, spIdx: longint;
begin
  actor := NextLearner;
  if actor < 0 then begin State := gsExplore; exit; end;
  total := LearnableCount(Roster[actor]);
  case scancode of
    SDL_SCANCODE_UP:
      if learnSel > 0 then dec(learnSel);
    SDL_SCANCODE_DOWN:
      if learnSel < total - 1 then inc(learnSel);
    SDL_SCANCODE_RETURN, SDL_SCANCODE_SPACE:
      begin
        spIdx := LearnableNth(Roster[actor], learnSel);
        if spIdx >= 0 then CharLearn(Roster[actor], spIdx);
        learnSel := 0;
        if NextLearner < 0 then State := gsExplore;
      end;
  end;
end;

end.
