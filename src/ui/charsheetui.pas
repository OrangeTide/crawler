unit charsheetui;

{** The character sheet: one party member at a time, the full stat block beside
  the portrait, with the left and right keys paging between members, a spell
  browser or skill list, first aid, and a door to skill training. }

{$mode objfpc}{$H+}

interface

procedure CharSheetRender;
procedure CharSheetKeyDown(scancode: longint);

implementation

uses
  sysutils, sdl2min, gfx, audio, gamestate, party, chardata, rules, items,
  spelldb, spellbook, skilldb, skillbook, pcportrait, spellicon, skillicon, rng;

function SheetGearName(def: longint): string;
begin
  if def >= 0 then SheetGearName := ItemDefs[def].name
  else SheetGearName := '-';
end;

function SheetSign(v: longint): string;
begin
  if v >= 0 then SheetSign := '+' + IntToStr(v) else SheetSign := IntToStr(v);
end;

{ Fill known[] with the catalog indices of the member's known spells, sorted
  by level then name, and return how many. Caps at the array size. }
function SheetKnownList(const c: TCharacter; out known: array of longint): longint;
var i, j, cat, kn: longint; tmp: longint;
begin
  kn := 0;
  for i := 0 to High(c.known) do begin
    cat := SpellByID(c.known[i]);
    if (cat >= 0) and (kn <= High(known)) then begin
      known[kn] := cat; inc(kn);
    end;
  end;
  { insertion sort by (level, name) }
  for i := 1 to kn - 1 do begin
    tmp := known[i]; j := i - 1;
    while (j >= 0) and
      ((SpellDefs[known[j]].level > SpellDefs[tmp].level) or
       ((SpellDefs[known[j]].level = SpellDefs[tmp].level) and
        (SpellDefs[known[j]].name > SpellDefs[tmp].name))) do begin
      known[j + 1] := known[j]; dec(j);
    end;
    known[j + 1] := tmp;
  end;
  SheetKnownList := kn;
end;

procedure CharSheetRender;
const
  VIS = 7;           { spell rows shown before the list scrolls }
  COLX = 158;        { the spell browser's left edge }
var
  n, si, y, m, i, kn, first, idx, cat, ry: longint;
  a: TAbility;
  modStr, st, nm: string;
  known: array[0 .. 63] of longint;
begin
  ClearFB(RGB(10, 10, 16));
  n := Length(Roster);
  if n = 0 then begin State := gsExplore; exit; end;
  if sheetSel < 0 then sheetSel := 0;
  if sheetSel > n - 1 then sheetSel := n - 1;
  si := sheetSel;

  DrawText(12, 10, 'CHARACTER', RGB(230, 210, 130));
  DrawText(FBW - 120, 10, 'MEMBER ' + IntToStr(si + 1) + ' OF ' + IntToStr(n),
    RGB(140, 150, 120));

  { the portrait, framed }
  FillRect(12, 24, 64, 64, RGB(0, 0, 0));
  DrawPCPortrait(12, 24, Roster[si].portrait);
  FrameRect(12, 24, 64, 64, RGB(120, 110, 90));

  { identity block beside the face }
  DrawText(86, 26, Roster[si].name, RGB(230, 210, 140));
  DrawText(86, 40, SpeciesDefs[Roster[si].species].name + '  '
    + ClassDefs[Roster[si].klass].name, RGB(200, 200, 180));
  if Roster[si].background >= 0 then
    DrawText(86, 52, BackgroundDefs[Roster[si].background].name,
      RGB(170, 175, 150));
  DrawText(86, 64, 'LEVEL ' + IntToStr(Roster[si].level) + '    XP '
    + IntToStr(Roster[si].xp), RGB(190, 190, 160));
  DrawText(86, 76, 'HP ' + IntToStr(Roster[si].hp) + '/'
    + IntToStr(Roster[si].hpMax) + '   AC ' + IntToStr(CharAC(Roster[si]))
    + '   ATK ' + SheetSign(CharAttack(Roster[si], true)), RGB(200, 185, 150));

  { a status line only when something is amiss }
  st := '';
  if not Roster[si].alive then st := 'SLAIN'
  else begin
    if Roster[si].downed then st := st + 'DOWNED ';
    if Roster[si].poison > 0 then st := st + 'POISONED ';
    if Roster[si].disease > 0 then st := st + 'ILL ';
    if Roster[si].wereform then st := st + 'WERE '
    else if Roster[si].lycan then st := st + 'CURSED ';
    if Roster[si].hireling then st := st + 'HIRED ';
  end;
  if st <> '' then DrawText(86, 88, st, RGB(205, 160, 140));

  { ability scores, left column }
  y := 102;
  for a := abSTR to abCHA do begin
    m := AbilMod(Roster[si].abil[a]);
    if m >= 0 then modStr := '+' + IntToStr(m) else modStr := IntToStr(m);
    DrawText(16, y, ABIL_NAME[a] + ' ' + IntToStr(Roster[si].abil[a])
      + '  (' + modStr + ')', RGB(185, 190, 170));
    inc(y, 11);
  end;

  { gear, left column below the abilities }
  DrawText(16, 172, 'GEAR', RGB(200, 190, 130));
  DrawText(16, 183, 'MN ' + SheetGearName(Roster[si].equip[eqMain].def),
    RGB(180, 185, 170));
  DrawText(16, 194, 'OF ' + SheetGearName(Roster[si].equip[eqOff].def),
    RGB(180, 185, 170));
  DrawText(16, 205, 'AR ' + SheetGearName(Roster[si].equip[eqArmor].def),
    RGB(180, 185, 170));
  DrawText(16, 216, 'LT ' + SheetGearName(Roster[si].equip[eqLight].def),
    RGB(180, 185, 170));

  { unspent proficiency slots, offered for training from here }
  if Roster[si].skillSlots > 0 then
    DrawText(COLX, 90, 'SLOTS ' + IntToStr(Roster[si].skillSlots)
      + '   T TRAIN', RGB(210, 190, 120));

  if CharIsCaster(Roster[si]) then begin
    { the spell browser, right column, for a caster }
    kn := SheetKnownList(Roster[si], known);
    if sheetSpellSel < 0 then sheetSpellSel := 0;
    if sheetSpellSel > kn - 1 then sheetSpellSel := kn - 1;
    if sheetSpellSel < 0 then sheetSpellSel := 0;

    st := 'SPELLS (' + IntToStr(kn) + ')';
    if ClassSchool(Roster[si].klass) <> SCH_NONE then
      st := st + '  ' + SchoolName(ClassSchool(Roster[si].klass));
    DrawText(COLX, 100, st, RGB(200, 190, 130));

    first := 0;
    if sheetSpellSel >= VIS then first := sheetSpellSel - VIS + 1;
    for i := 0 to VIS - 1 do begin
      idx := first + i;
      if idx >= kn then break;
      cat := known[idx];
      ry := 114 + i * 15;
      if idx = sheetSpellSel then
        FillRect(COLX, ry - 1, FBW - 8 - COLX, 14, RGB(44, 40, 60));
      FrameRect(COLX, ry, 14, 14, RGB(60, 56, 44));
      DrawSpellIcon(COLX, ry, 14, 14, SpellDefs[cat].icon);
      nm := SpellDefs[cat].name;
      if Length(nm) > 20 then nm := Copy(nm, 1, 20);
      if SpellDefs[cat].castable then DrawText(COLX + 18, ry + 3, nm, RGB(210, 210, 190))
      else DrawText(COLX + 18, ry + 3, nm, RGB(150, 150, 135));
    end;

    { the selected spell's level and school on the foot line }
    if kn > 0 then begin
      cat := known[sheetSpellSel];
      st := 'LVL ' + IntToStr(SpellDefs[cat].level);
      if SpellDefs[cat].school <> SCH_NONE then
        st := st + '   ' + SchoolName(SpellDefs[cat].school);
      if not SpellDefs[cat].castable then st := st + '   UTILITY';
      DrawText(COLX, FBH - 24, st, RGB(150, 160, 190));
    end;
  end else begin
    { the skills list, right column, for a non-caster }
    kn := KnownSkillCount(Roster[si]);
    if sheetSpellSel < 0 then sheetSpellSel := 0;
    if sheetSpellSel > kn - 1 then sheetSpellSel := kn - 1;
    if sheetSpellSel < 0 then sheetSpellSel := 0;

    DrawText(COLX, 100, 'SKILLS (' + IntToStr(kn) + ')', RGB(200, 190, 130));
    first := 0;
    if sheetSpellSel >= VIS then first := sheetSpellSel - VIS + 1;
    for i := 0 to VIS - 1 do begin
      idx := first + i;
      if idx >= kn then break;
      cat := KnownSkillNth(Roster[si], idx);
      if cat < 0 then break;
      ry := 114 + i * 15;
      if idx = sheetSpellSel then
        FillRect(COLX, ry - 1, FBW - 8 - COLX, 14, RGB(44, 40, 60));
      FrameRect(COLX, ry, 14, 14, RGB(60, 56, 44));
      DrawSkillIcon(COLX, ry, 14, 14, SkillDefs[cat].icon);
      nm := SkillDefs[cat].name;
      if Length(nm) > 16 then nm := Copy(nm, 1, 16);
      DrawText(COLX + 18, ry + 3, nm, RGB(210, 210, 190));
      DrawText(FBW - 26, ry + 3, 'R' + IntToStr(SkillRank(Roster[si], cat)),
        RGB(160, 180, 150));
    end;

    { the selected skill's arena, ability and rank on the foot line }
    if kn > 0 then begin
      cat := KnownSkillNth(Roster[si], sheetSpellSel);
      if cat >= 0 then
        DrawText(COLX, FBH - 24, UpperCase(ArenaName(SkillDefs[cat].arena)) + '  '
          + ABIL_NAME[TAbility(SkillDefs[cat].ability)] + '  R'
          + IntToStr(SkillRank(Roster[si], cat)), RGB(150, 160, 190));
    end else
      DrawText(COLX, 116, 'No skills trained.', RGB(150, 150, 130));
  end;

  if Roster[si].skillSlots > 0 then
    DrawText(12, FBH - 11, 'L/R MEM  P FACE  A AID  T TRAIN  ESC',
      RGB(130, 140, 110))
  else
    DrawText(12, FBH - 11, 'U/D LIST  L/R MEM  P FACE  A AID  I/ESC',
      RGB(130, 140, 110));
end;

{ First Aid from the sheet: the party's best medic tends the viewed member. A
  binding attempt, pass or fail, spent until the next rest, so the check bites. }
procedure SheetFirstAid;
var tgt, who, mendCat, amt, rank: longint;
begin
  tgt := sheetSel;
  if (tgt < 0) or (tgt > High(Roster)) then exit;
  if (not Roster[tgt].alive) or Roster[tgt].mended then begin
    PlaySfx(SFX_MISS); exit;
  end;
  if (Roster[tgt].hp >= Roster[tgt].hpMax) and (not Roster[tgt].downed) then begin
    PlaySfx(SFX_MISS); exit;   { nothing to tend }
  end;
  if not BestSkillHolder(SKE_MEND, who, mendCat) then begin
    PlaySfx(SFX_MISS); exit;   { no one knows first aid }
  end;
  Roster[tgt].mended := true;
  if not Check(GameRng, SkillCheckMods(Roster[who], mendCat),
    SkillDefs[mendCat].target) then begin
    PlaySfx(SFX_MISS); exit;   { the attempt fails }
  end;
  rank := SkillRank(Roster[who], mendCat);
  if rank < 0 then rank := 0;
  amt := RngRoll(GameRng, SkillDefs[mendCat].dice, SkillDefs[mendCat].sides)
    + AbilMod(Roster[who].abil[abWIS]) + rank;
  if amt < 1 then amt := 1;
  if Roster[tgt].downed then Roster[tgt].downed := false;
  Roster[tgt].hp := Roster[tgt].hp + amt;
  if Roster[tgt].hp > Roster[tgt].hpMax then Roster[tgt].hp := Roster[tgt].hpMax;
  PlaySfx(SFX_SELECT);
end;

procedure CharSheetKeyDown(scancode: longint);
var n, p: longint;
begin
  n := Length(Roster);
  case scancode of
    SDL_SCANCODE_LEFT:
      if (n > 0) and (sheetSel > 0) then begin dec(sheetSel); sheetSpellSel := 0; end;
    SDL_SCANCODE_RIGHT:
      if (n > 0) and (sheetSel < n - 1) then begin inc(sheetSel); sheetSpellSel := 0; end;
    SDL_SCANCODE_UP:
      if sheetSpellSel > 0 then dec(sheetSpellSel);
    SDL_SCANCODE_DOWN:
      inc(sheetSpellSel);   { clamped on render }
    SDL_SCANCODE_P:
      if (n > 0) and (PCPortraitCount > 0) then begin
        p := Roster[sheetSel].portrait + 1;
        if p >= PCPortraitCount then p := 0;
        Roster[sheetSel].portrait := p;
      end;
    SDL_SCANCODE_T:
      if (n > 0) and (Roster[sheetSel].skillSlots > 0) then begin
        skillActor := sheetSel; skillTrainSel := 0; State := gsLearnSkill;
      end;
    SDL_SCANCODE_A:
      if n > 0 then SheetFirstAid;
    SDL_SCANCODE_I, SDL_SCANCODE_ESCAPE: State := gsExplore;
  end;
end;

end.
