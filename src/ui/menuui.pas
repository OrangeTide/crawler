unit menuui;

{** The meta menu (the J screen): three tabs, the journal of quests, the
  bestiary of foes faced, and the spells tab that browses a caster's known
  spells and field-casts the utility ones. }

{$mode objfpc}{$H+}

interface

procedure JournalRender;
procedure JournalKeyDown(scancode: longint);

implementation

uses
  sysutils, sdl2min, gfx, flags, uihelp, audio, gamestate, party, chardata,
  codex, monsters, spelldb, spellbook, spellicon, fieldcast;

var
  spellCaster: longint = 0;   { which party caster the spells tab shows }
  spellSel: longint = 0;      { highlighted spell within that caster's domain }
  castTargeting: boolean = false;  { picking a member for a targeted field cast }
  castTarget: longint = 0;    { the member the target picker sits on }
  castMsg: string = '';       { the last field-cast result, shown on the tab }

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

function FieldDesc(kind: byte): string;
begin
  case kind of
    FE_HEAL:        FieldDesc := 'heal a member';
    FE_CUREPOISON:  FieldDesc := 'cure poison';
    FE_CUREDISEASE: FieldDesc := 'cure disease';
    FE_REMOVECURSE: FieldDesc := 'lift a curse';
    FE_LIGHT:       FieldDesc := 'light the way';
    FE_IDENTIFY:    FieldDesc := 'read magic';
    FE_REVEAL:      FieldDesc := 'sense the area';
  else
    FieldDesc := '';
  end;
end;

procedure SpellsBody;
const
  ROWS = 10;
var
  casters: array[0 .. 15] of longint;
  nc, cm, dom, total, firstRow, r, si, y, spIdx, tx, ty: longint;
  kind: byte;
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
    + IntToStr(Roster[cm].sp) + '/' + IntToStr(CharSpellPoints(Roster[cm])),
    RGB(150, 170, 190));
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
    if si = spellSel then
      FillRectBlend(12, y - 1, 184, 11, RGB(44, 44, 66), 230);
    DrawSpellIcon(14, y, 9, 9, SpellDefs[spIdx].icon);
    if si = spellSel then
      DrawText(26, y + 1, 'L' + IntToStr(SpellDefs[spIdx].level) + ' '
        + SpellDefs[spIdx].name, RGB(244, 230, 150))
    else if CanFieldCast(cm, spIdx) then
      DrawText(26, y + 1, 'L' + IntToStr(SpellDefs[spIdx].level) + ' '
        + SpellDefs[spIdx].name, RGB(170, 220, 160))
    else
      DrawText(26, y + 1, 'L' + IntToStr(SpellDefs[spIdx].level) + ' '
        + SpellDefs[spIdx].name, RGB(160, 165, 150));
    inc(y, 11);
  end;
  DrawText(16, 160, IntToStr(spellSel + 1) + ' of ' + IntToStr(total),
    RGB(120, 130, 110));

  spIdx := KnownNth(Roster[cm], spellSel);
  kind := FE_NONE;
  if spIdx >= 0 then kind := FieldCastKind(spIdx);

  { the foot box: either the member picker for a targeted cast, or the
    highlighted spell in full with its field-cast line }
  FrameRect(8, 172, FBW - 16, FBH - 172 - 4, RGB(90, 84, 70));
  if castTargeting and (spIdx >= 0) then begin
    DrawText(16, 178, 'CAST ' + SpellDefs[spIdx].name + ' ON', RGB(230, 210, 140));
    tx := 16;
    for r := 0 to High(Roster) do begin
      ty := 190 + (r div 2) * 11;
      if (r and 1) = 0 then tx := 16 else tx := 168;
      if r = castTarget then
        FillRectBlend(tx - 2, ty - 1, 148, 10, RGB(44, 60, 48), 230);
      if not Roster[r].alive then
        DrawText(tx, ty, Copy(Roster[r].name, 1, 10) + ' SLAIN',
          RGB(150, 110, 110))
      else
        DrawText(tx, ty, Copy(Roster[r].name, 1, 10) + '  '
          + IntToStr(Roster[r].hp) + '/' + IntToStr(Roster[r].hpMax),
          RGB(200, 205, 185));
    end;
    DrawText(16, FBH - 12, 'UP/DN PICK  ENTER CAST  ESC BACK',
      RGB(130, 140, 110));
  end else if spIdx >= 0 then begin
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
    if castMsg <> '' then
      DrawText(16, FBH - 22, castMsg, RGB(170, 220, 160))
    else if kind <> FE_NONE then begin
      if CanFieldCast(cm, spIdx) then
        DrawText(16, FBH - 22, 'FIELD: ' + FieldDesc(kind) + '   COST '
          + IntToStr(FieldCost(spIdx)) + '   ENTER CAST', RGB(170, 220, 160))
      else
        DrawText(16, FBH - 22, 'FIELD: ' + FieldDesc(kind) + '   COST '
          + IntToStr(FieldCost(spIdx)) + '   (need SP)', RGB(150, 130, 110));
    end;
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

{ The caster the SPELLS tab sits on and its highlighted known spell, as roster
  and catalog indices. False when the party has no caster or no known spell. }
function CurCasterSpell(out cm, spIdx: longint): boolean;
var casters: array[0 .. 15] of longint; nc: longint;
begin
  CurCasterSpell := false;
  nc := CasterList(casters);
  if nc = 0 then exit;
  if spellCaster >= nc then spellCaster := nc - 1;
  if spellCaster < 0 then spellCaster := 0;
  cm := casters[spellCaster];
  spIdx := KnownNth(Roster[cm], spellSel);
  CurCasterSpell := spIdx >= 0;
end;

{ ENTER on the SPELLS tab: begin or complete a field cast of the selected
  spell. Party-wide effects fire at once; targeted ones open the member pick. }
procedure SpellsCast;
var cm, spIdx: longint;
begin
  if castTargeting then exit;
  if not CurCasterSpell(cm, spIdx) then exit;
  if not CanFieldCast(cm, spIdx) then begin PlaySfx(SFX_MISS); exit; end;
  if FieldTargeted(FieldCastKind(spIdx)) then begin
    castTargeting := true;
    castTarget := cm;   { default to the caster; the pick can move it }
    castMsg := '';
    PlaySfx(SFX_SELECT);
  end else begin
    castMsg := DoFieldCast(cm, spIdx, -1);
    PlaySfx(SFX_SELECT);
  end;
end;

{ ENTER in the member picker: land the targeted cast on the chosen member. }
procedure SpellsCastConfirm;
var cm, spIdx: longint;
begin
  if not CurCasterSpell(cm, spIdx) then begin castTargeting := false; exit; end;
  if (castTarget < 0) or (castTarget > High(Roster))
    or (not Roster[castTarget].alive) then begin
    PlaySfx(SFX_MISS); exit;
  end;
  castMsg := DoFieldCast(cm, spIdx, castTarget);
  castTargeting := false;
  PlaySfx(SFX_SELECT);
end;

procedure JournalKeyDown(scancode: longint);
begin
  { the member picker captures the keys while a targeted cast is pending }
  if (menuTab = 2) and castTargeting then begin
    case scancode of
      SDL_SCANCODE_UP:
        if castTarget > 0 then dec(castTarget);
      SDL_SCANCODE_DOWN:
        if castTarget < High(Roster) then inc(castTarget);
      SDL_SCANCODE_LEFT:
        if castTarget > 0 then dec(castTarget);
      SDL_SCANCODE_RIGHT:
        if castTarget < High(Roster) then inc(castTarget);
      SDL_SCANCODE_RETURN:
        SpellsCastConfirm;
      SDL_SCANCODE_ESCAPE:
        castTargeting := false;
    end;
    exit;
  end;

  case scancode of
    SDL_SCANCODE_TAB: begin
      menuTab := (menuTab + 1) mod 3;
      castMsg := '';
    end;
    SDL_SCANCODE_LEFT:
      if menuTab = 2 then begin
        if spellCaster > 0 then dec(spellCaster);
        spellSel := 0; castMsg := '';
      end else
        menuTab := (menuTab + 2) mod 3;
    SDL_SCANCODE_RIGHT:
      if menuTab = 2 then begin
        inc(spellCaster);   { clamped on render }
        spellSel := 0; castMsg := '';
      end else
        menuTab := (menuTab + 1) mod 3;
    SDL_SCANCODE_UP:
      if (menuTab = 2) and (spellSel > 0) then begin dec(spellSel); castMsg := ''; end;
    SDL_SCANCODE_DOWN:
      if menuTab = 2 then begin inc(spellSel); castMsg := ''; end;   { clamped on render }
    SDL_SCANCODE_RETURN:
      if menuTab = 2 then SpellsCast;
    SDL_SCANCODE_J, SDL_SCANCODE_ESCAPE: begin
      castMsg := ''; castTargeting := false; State := gsExplore;
    end;
  end;
end;

end.
