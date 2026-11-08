unit miscui;

{** The small UI states: the full-map overlay toggle, the journal, the
  game-over and victory screens, and the audio options. Each is a render
  and a key handler with little state of its own. }

{$mode objfpc}{$H+}

interface

procedure FullMapRender;
procedure FullMapKeyDown(scancode: longint);
procedure FullMapMouseMotion(xrel, yrel: longint);
procedure FullMapMouseButton(button: longint);
procedure JournalRender;
procedure JournalKeyDown(scancode: longint);
procedure GameOverRender;
procedure GameOverKeyDown(scancode: longint);
procedure OptionsRender;
procedure OptionsKeyDown(scancode: longint);
procedure KeybindRender;
procedure KeybindKeyDown(scancode: longint);
procedure VictoryRender;
procedure VictoryKeyDown(scancode: longint);
procedure LearnRender;
procedure LearnKeyDown(scancode: longint);
procedure CharSheetRender;
procedure CharSheetKeyDown(scancode: longint);

implementation

uses
  sysutils, sdl2min, gfx, flags, audio, uihelp, gamestate, world, hud,
  exploreui, pursuit, settings, keymap, codex, monsters, mappins, pathfind,
  party, chardata, spelldb, spellbook, rules, items, pcportrait, spellicon;

var
  spellCaster: longint = 0;   { which party caster the spells tab shows }
  spellSel: longint = 0;      { highlighted spell within that caster's domain }
  learnSel: longint = 0;      { highlighted spell in the learn-a-spell screen }

function PinColor(kind: byte): TColor;
begin
  case kind of
    PIN_BANG:   PinColor := RGB(240, 220, 80);
    PIN_QUERY:  PinColor := RGB(90, 200, 230);
    PIN_STAR:   PinColor := RGB(220, 120, 220);
    PIN_STAIR:  PinColor := RGB(235, 235, 235);
    PIN_PORTAL: PinColor := RGB(90, 120, 240);
    PIN_SHOP:   PinColor := RGB(120, 220, 120);
  else PinColor := RGB(200, 200, 200);
  end;
end;

procedure FullMapRender;
{** The full map with the route preview, the player's pins, the auto-markers,
  and any hunters on this map drawn over it. }
var
  i, n, tx, ty: longint;
  path: array[0 .. 2047] of TPathStep;
begin
  DrawFullMap;
  { preview the trail a left click would walk to the tile under the cursor }
  if FullMapTileAt(cursorX, cursorY, tx, ty) then
    if FindPath(CurMap, TileX, TileY, tx, ty, true, path, n) then
      for i := 1 to n - 2 do
        FullMapMark(path[i].x, path[i].y, RGB(70, 90, 150));
  { the active route's leg on this map, drawn brighter over the hover trail }
  if AutoTravelActive and AutoTravelTargetOnMap(tx, ty) then
    if FindPath(CurMap, TileX, TileY, tx, ty, true, path, n) then
      for i := 1 to n - 2 do
        FullMapMark(path[i].x, path[i].y, RGB(90, 200, 220));
  for i := 0 to High(Pins) do
    if Pins[i].map = CurMapName then
      FullMapMark(Pins[i].x, Pins[i].y, PinColor(Pins[i].kind));
  for i := 0 to High(Pursuers) do
    if Pursuers[i].active and (Pursuers[i].map = CurMapName) then
      FullMapMark(Pursuers[i].x, Pursuers[i].y, RGB(230, 40, 160));
  { legend across the foot: the manual marks, then the auto markers }
  DrawText(6, FBH - 9, 'RMB PIN', RGB(150, 150, 140));
  DrawText(74, FBH - 9, '!', PinColor(PIN_BANG));
  DrawText(84, FBH - 9, '?', PinColor(PIN_QUERY));
  DrawText(94, FBH - 9, '*', PinColor(PIN_STAR));
  DrawText(120, FBH - 9, 'STAIR', PinColor(PIN_STAIR));
  DrawText(162, FBH - 9, 'PORT', PinColor(PIN_PORTAL));
  DrawText(196, FBH - 9, 'NPC', PinColor(PIN_SHOP));
end;

procedure FullMapKeyDown(scancode: longint);
begin
  case scancode of
    SDL_SCANCODE_TAB, SDL_SCANCODE_ESCAPE, SDL_SCANCODE_M:
      State := gsExplore;
  end;
end;

procedure FullMapMouseMotion(xrel, yrel: longint);
{** Drift the shared cursor over the map, clamped to the screen. }
begin
  cursorX := cursorX + xrel;
  cursorY := cursorY + yrel;
  if cursorX < 0 then cursorX := 0;
  if cursorX > FBW - 1 then cursorX := FBW - 1;
  if cursorY < 0 then cursorY := 0;
  if cursorY > FBH - 1 then cursorY := FBH - 1;
end;

procedure FullMapMouseButton(button: longint);
{** Left click a tile to auto-travel there on the current map, then drop
  back to the first-person view to walk it. }
var
  tx, ty: longint;
begin
  if button = SDL_BUTTON_LEFT then begin
    if FullMapTileAt(cursorX, cursorY, tx, ty) then begin
      StartAutoTravel(CurMapName, tx, ty);
      State := gsExplore;
    end;
  end else if button = SDL_BUTTON_RIGHT then begin
    { right click drops or cycles a pin, without leaving the map }
    if FullMapTileAt(cursorX, cursorY, tx, ty) then
      PinCycleManual(CurMapName, tx, ty);
  end;
end;

{ Short element names for a weakness or resistance mask. }
function ElemTags(mask: byte): string;
  procedure Add(bit: byte; const nm: string);
  begin
    if (mask and bit) <> 0 then begin
      if ElemTags <> '' then ElemTags := ElemTags + '/';
      ElemTags := ElemTags + nm;
    end;
  end;
begin
  ElemTags := '';
  Add(EL_FIRE, 'FIRE'); Add(EL_FROST, 'FROST'); Add(EL_SHOCK, 'SHOCK');
  Add(EL_HOLY, 'HOLY'); Add(EL_PHYS, 'PHYS');
end;

procedure JournalBody;
var i, y: longint;
begin
  if Length(Journal) = 0 then
    DrawText(16, 36, 'No quests recorded yet.', RGB(150, 150, 130))
  else begin
    y := 36;
    for i := 0 to High(Journal) do begin
      DrawWrapped(16, y, 48, '- ' + Journal[i], RGB(195, 200, 180));
      inc(y, 22);
    end;
  end;
end;

procedure BestiaryBody;
var
  i, y: longint;
  weak: string;
begin
  DrawText(16, 28, 'FACED ' + IntToStr(MonSeenCount) + ' OF '
    + IntToStr(Length(MonDefs)), RGB(150, 160, 140));
  y := 40;
  for i := 0 to High(MonDefs) do begin
    if MonIsSeen(i) then begin
      DrawText(16, y, MonDefs[i].name, RGB(205, 205, 185));
      DrawText(150, y, 'HD' + IntToStr(MonDefs[i].hd)
        + ' AC' + IntToStr(MonDefs[i].ac), RGB(150, 160, 170));
      weak := ElemTags(MonDefs[i].weak);
      if weak <> '' then
        DrawText(220, y, 'WEAK ' + weak, RGB(150, 200, 150));
    end else
      DrawText(16, y, '???', RGB(120, 120, 135));
    inc(y, 10);
  end;
end;

{ Fill idx with the roster slots that draw from a spell domain; the count. }
function CasterList(out idx: array of longint): longint;
var i, n: longint;
begin
  n := 0;
  for i := 0 to High(Roster) do
    if (ClassDomain(Roster[i].klass) <> SPD_NONE) and (n <= High(idx)) then begin
      idx[n] := i; inc(n);
    end;
  CasterList := n;
end;

procedure SpellsBody;
const
  ROWS = 10;
var
  casters: array[0 .. 15] of longint;
  nc, cm, dom, total, firstRow, r, si, y, spIdx: longint;
  meta: string;
begin
  nc := CasterList(casters);
  if nc = 0 then begin
    DrawText(16, 40, 'No one in the party weaves spells.', RGB(150, 150, 130));
    exit;
  end;
  { clamp the selection, writing back so the keys cannot run off the ends }
  if spellCaster >= nc then spellCaster := nc - 1;
  if spellCaster < 0 then spellCaster := 0;
  cm := casters[spellCaster];
  dom := ClassDomain(Roster[cm].klass);
  total := KnownCount(Roster[cm]);
  if spellSel >= total then spellSel := total - 1;
  if spellSel < 0 then spellSel := 0;

  { header: the caster, their class, their domain and spell-point pool }
  DrawText(16, 24, Roster[cm].name + ' the ' + ClassDefs[Roster[cm].klass].name,
    RGB(230, 210, 140));
  DrawText(16, 34, DomainName(dom) + ' spells   SP '
    + IntToStr(CharSpellPoints(Roster[cm])), RGB(150, 170, 190));
  if ClassSchool(Roster[cm].klass) <> SCH_NONE then
    DrawText(210, 44, SchoolName(ClassSchool(Roster[cm].klass)),
      RGB(170, 150, 190));
  if nc > 1 then DrawText(210, 24, 'L/R MEMBER', RGB(130, 140, 110));
  DrawText(210, 34, 'UP/DN SPELL', RGB(130, 140, 110));

  if total = 0 then begin
    DrawText(16, 54, 'Knows no spells yet.', RGB(150, 150, 130));
    exit;
  end;

  { the spells this caster has learned, one page at a time, in level order }
  firstRow := (spellSel div ROWS) * ROWS;
  y := 50;
  for r := 0 to ROWS - 1 do begin
    si := firstRow + r;
    if si >= total then break;
    spIdx := KnownNth(Roster[cm], si);
    if spIdx < 0 then break;
    if si = spellSel then begin
      FillRectBlend(12, y - 1, 184, 10, RGB(44, 44, 66), 230);
      DrawText(16, y, 'L' + IntToStr(SpellDefs[spIdx].level) + ' '
        + SpellDefs[spIdx].name, RGB(244, 230, 150));
    end else
      DrawText(16, y, 'L' + IntToStr(SpellDefs[spIdx].level) + ' '
        + SpellDefs[spIdx].name, RGB(190, 195, 180));
    inc(y, 10);
  end;
  DrawText(16, 160, IntToStr(spellSel + 1) + ' of ' + IntToStr(total),
    RGB(120, 130, 110));

  { the highlighted spell in full: its prose is the real behaviour }
  spIdx := KnownNth(Roster[cm], spellSel);
  if spIdx >= 0 then begin
    FrameRect(8, 172, FBW - 16, FBH - 172 - 4, RGB(90, 84, 70));
    DrawText(16, 178, SpellDefs[spIdx].name, RGB(230, 210, 140));
    meta := 'level ' + IntToStr(SpellDefs[spIdx].level);
    if SpellDefs[spIdx].save <> SSV_NONE then
      meta := meta + '    save ' + SaveName(SpellDefs[spIdx].save);
    if SpellDefs[spIdx].dtype <> SDT_NONE then
      meta := meta + '    ' + DTypeName(SpellDefs[spIdx].dtype);
    if SpellDefs[spIdx].school <> SCH_NONE then
      meta := meta + '    ' + SchoolName(SpellDefs[spIdx].school);
    DrawText(16, 188, meta, RGB(150, 170, 190));
    DrawWrapped(16, 200, 48, SpellDefs[spIdx].effect, RGB(200, 200, 185));
  end;
end;

procedure JournalRender;
begin
  ClearFB(RGB(10, 10, 16));
  { the three tabs, the open one lit }
  if menuTab = 0 then DrawText(12, 10, 'JOURNAL', RGB(230, 210, 130))
  else DrawText(12, 10, 'JOURNAL', RGB(120, 120, 110));
  if menuTab = 1 then DrawText(100, 10, 'BESTIARY', RGB(230, 210, 130))
  else DrawText(100, 10, 'BESTIARY', RGB(120, 120, 110));
  if menuTab = 2 then DrawText(196, 10, 'SPELLS', RGB(230, 210, 130))
  else DrawText(196, 10, 'SPELLS', RGB(120, 120, 110));
  case menuTab of
    1: BestiaryBody;
    2: SpellsBody;
  else
    JournalBody;
  end;
  { the spells tab fills the foot with its detail box, so hide the hint there }
  if menuTab <> 2 then
    DrawText(12, FBH - 14, 'TAB SWITCH   J/ESC CLOSE', RGB(130, 140, 110));
end;

procedure JournalKeyDown(scancode: longint);
begin
  case scancode of
    SDL_SCANCODE_TAB:
      menuTab := (menuTab + 1) mod 3;
    SDL_SCANCODE_LEFT:
      if menuTab = 2 then begin
        if spellCaster > 0 then dec(spellCaster);
        spellSel := 0;
      end else
        menuTab := (menuTab + 2) mod 3;
    SDL_SCANCODE_RIGHT:
      if menuTab = 2 then begin
        inc(spellCaster);   { clamped on render }
        spellSel := 0;
      end else
        menuTab := (menuTab + 1) mod 3;
    SDL_SCANCODE_UP:
      if (menuTab = 2) and (spellSel > 0) then dec(spellSel);
    SDL_SCANCODE_DOWN:
      if menuTab = 2 then inc(spellSel);   { clamped on render }
    SDL_SCANCODE_J, SDL_SCANCODE_ESCAPE: State := gsExplore;
  end;
end;

{ The learn-a-spell screen: a caster picks which spell it learns when it gains
  a slot, at creation and on each level that owes it one. The update loop opens
  this state while any caster has a pending pick; it closes once none do. }
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
    if si = learnSel then begin
      FillRectBlend(12, y - 1, 184, 10, RGB(44, 44, 66), 230);
      DrawText(16, y, 'L' + IntToStr(SpellDefs[spIdx].level) + ' '
        + SpellDefs[spIdx].name + tag, RGB(244, 230, 150));
    end else
      DrawText(16, y, 'L' + IntToStr(SpellDefs[spIdx].level) + ' '
        + SpellDefs[spIdx].name + tag, RGB(190, 195, 180));
    inc(y, 10);
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

{ The character sheet: one party member at a time, the full stat block beside
  the portrait, with the left and right keys paging between members. Opened
  with I from the world, it reuses the former inventory state. }

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

  { the spell browser, right column, for a caster }
  if CharIsCaster(Roster[si]) then begin
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
  end;

  DrawText(12, FBH - 11, 'UP/DN SPELL  L/R MEMBER  I/ESC CLOSE',
    RGB(130, 140, 110));
end;

procedure CharSheetKeyDown(scancode: longint);
var n: longint;
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
    SDL_SCANCODE_I, SDL_SCANCODE_ESCAPE: State := gsExplore;
  end;
end;

procedure GameOverRender;
begin
  ClearFB(RGB(16, 6, 8));
  DrawCenter(90, 'THE PARTY HAS FALLEN', RGB(220, 120, 110));
  DrawCenter(110, 'PRESS A KEY', RGB(150, 130, 120));
end;

procedure GameOverKeyDown(scancode: longint);
begin
  titleSel := 0;
  State := gsTitle;
end;

const
  { the options rows, in order down the screen }
  OPT_MASTER = 0;
  OPT_MUSIC  = 1;
  OPT_SFX    = 2;
  OPT_DEATH  = 3;
  OPT_CRIT   = 4;
  OPT_SPEED  = 5;
  OPT_KEYS   = 6;
  OPT_LAST   = 6;

function SpeedName(cs: longint): string;
begin
  case cs of
    CS_SLOW: SpeedName := 'SLOW';
    CS_FAST: SpeedName := 'FAST';
  else SpeedName := 'NORMAL';
  end;
end;

procedure OptionsRender;
const
  LABELS: array[OPT_MASTER .. OPT_LAST] of string =
    ('MASTER', 'MUSIC', 'SFX', 'PERMADEATH', 'CRITICALS', 'COMBAT SPEED',
     'KEY BINDINGS');
var
  i, y, v: longint;
  c: TColor;

  procedure OnOff(flag: boolean);
  begin
    if flag then DrawText(170, y, 'ON', c) else DrawText(170, y, 'OFF', c);
  end;

begin
  ClearFB(RGB(12, 12, 16));
  DrawCenter(20, 'OPTIONS', RGB(220, 200, 120));
  y := 56;
  for i := OPT_MASTER to OPT_LAST do begin
    if i = optSel then c := RGB(240, 230, 150) else c := RGB(160, 160, 140);
    DrawText(50, y, LABELS[i], c);
    case i of
      OPT_MASTER, OPT_MUSIC, OPT_SFX: begin
        case i of
          OPT_MASTER: v := volMaster;
          OPT_MUSIC:  v := volMusic;
        else v := volSfx;
        end;
        FillRect(170, y, 102, 7, RGB(40, 40, 46));
        FillRect(171, y + 1, v, 5, RGB(90, 160, 110));
        DrawText(280, y, IntToStr(v), c);
      end;
      OPT_DEATH: OnOff(SetPermadeath);
      OPT_CRIT:  OnOff(SetCriticals);
      OPT_SPEED: DrawText(170, y, SpeedName(SetCombatSpeed), c);
      OPT_KEYS:  DrawText(170, y, 'EDIT >', c);
    end;
    inc(y, 18);
  end;
  DrawCenter(FBH - 20, 'ARROWS ADJUST   ESC BACK', RGB(130, 140, 110));
end;

{ Nudge a volume by delta and clamp it to 0..100. }
function ClampVol(v: longint): longint;
begin
  if v < 0 then v := 0;
  if v > 100 then v := 100;
  ClampVol := v;
end;

procedure OptionsKeyDown(scancode: longint);
var
  dir: longint;
begin
  dir := 0;
  case scancode of
    SDL_SCANCODE_UP:   begin if optSel > 0 then dec(optSel); exit; end;
    SDL_SCANCODE_DOWN: begin if optSel < OPT_LAST then inc(optSel); exit; end;
    SDL_SCANCODE_LEFT:  dir := -1;
    SDL_SCANCODE_RIGHT: dir := 1;
    SDL_SCANCODE_RETURN: dir := 1;   { enter opens the key-binding sub-screen }
    SDL_SCANCODE_ESCAPE: begin SettingsSave; State := gsTitle; exit; end;
  end;
  if dir = 0 then exit;
  { the key-bindings row is a door, not a value }
  if optSel = OPT_KEYS then begin
    if dir > 0 then begin
      kbSel := 0; kbCapturing := false; State := gsKeybind;
    end;
    exit;
  end;
  case optSel of
    OPT_MASTER: volMaster := ClampVol(volMaster + dir * 10);
    OPT_MUSIC:  volMusic  := ClampVol(volMusic + dir * 10);
    OPT_SFX:    volSfx    := ClampVol(volSfx + dir * 10);
    OPT_DEATH:  SetPermadeath := not SetPermadeath;
    OPT_CRIT:   SetCriticals := not SetCriticals;
    OPT_SPEED: begin
      SetCombatSpeed := SetCombatSpeed + dir;
      if SetCombatSpeed < CS_SLOW then SetCombatSpeed := CS_SLOW;
      if SetCombatSpeed > CS_FAST then SetCombatSpeed := CS_FAST;
    end;
  end;
  SettingsApply;        { push volumes and the combat rules live }
  SettingsSave;         { persist the change at once }
  PlaySfx(SFX_SELECT);
end;

procedure KeybindRender;
var
  a: TGameAction;
  y: longint;
  c: TColor;
begin
  ClearFB(RGB(12, 12, 16));
  DrawCenter(16, 'KEY BINDINGS', RGB(220, 200, 120));
  y := 44;
  for a := Low(TGameAction) to High(TGameAction) do begin
    if ord(a) = kbSel then c := RGB(240, 230, 150) else c := RGB(160, 160, 140);
    DrawText(50, y, ActionName(a), c);
    if (ord(a) = kbSel) and kbCapturing then
      DrawText(210, y, 'PRESS A KEY', RGB(230, 180, 90))
    else
      DrawText(210, y, KeyName(KeyBind[a]), c);
    inc(y, 16);
  end;
  if kbCapturing then
    DrawCenter(FBH - 20, 'PRESS A KEY   ESC CANCEL', RGB(130, 140, 110))
  else
    DrawCenter(FBH - 20, 'ENTER REBIND   ESC BACK', RGB(130, 140, 110));
end;

{ A key reserved for menu navigation, which must stay unbindable. }
function ReservedKey(scancode: longint): boolean;
begin
  ReservedKey := (scancode = SDL_SCANCODE_RETURN)
    or (scancode = SDL_SCANCODE_UP) or (scancode = SDL_SCANCODE_DOWN)
    or (scancode = SDL_SCANCODE_LEFT) or (scancode = SDL_SCANCODE_RIGHT);
end;

procedure KeybindKeyDown(scancode: longint);
begin
  if kbCapturing then begin
    if scancode = SDL_SCANCODE_ESCAPE then begin kbCapturing := false; exit; end;
    if ReservedKey(scancode) then exit;   { keep the menu keys free }
    RebindKey(TGameAction(kbSel), scancode);
    kbCapturing := false;
    SettingsSave;
    PlaySfx(SFX_SELECT);
    exit;
  end;
  case scancode of
    SDL_SCANCODE_UP:     if kbSel > 0 then dec(kbSel);
    SDL_SCANCODE_DOWN:   if kbSel < ord(High(TGameAction)) then inc(kbSel);
    SDL_SCANCODE_RETURN: kbCapturing := true;
    SDL_SCANCODE_ESCAPE: begin SettingsSave; State := gsOptions; end;
  end;
end;

procedure VictoryRender;
begin
  ClearFB(RGB(8, 10, 16));
  DrawCenter(72, 'THE GATE STANDS OPEN', RGB(230, 220, 140));
  DrawCenter(88, 'THE LOST CITIES ARE FOUND', RGB(180, 190, 200));
  DrawCenter(104, 'THE SUNLESS DEPTHS AWAIT', RGB(150, 170, 190));
  DrawCenter(128, 'PRESS A KEY', RGB(130, 140, 150));
end;

procedure VictoryKeyDown(scancode: longint);
begin
  titleSel := 0;
  State := gsTitle;
end;

end.
