unit combatui;

{** The combat screen and its input.

  Renders the fight (foe ranks, party ranks, the message and command
  windows, flashes and floating numbers) and drives the FF-style command
  then target flow. The combat rules and state live in the combat engine;
  this unit is the player's view of and interface to them. It returns to
  exploration by setting State, so it never depends on the explore unit. }

{$mode objfpc}{$H+}

interface

procedure StartCombat(depth: longint);
procedure StartMonsterCombat(leadMon, depth: longint);
procedure StartBossCombat(leadMon, depth: longint; const winFlag: string);
procedure EndCombat;
procedure CombatRender;
procedure CombatKeyDown(scancode: longint);
procedure CombatAutoTurn(dt: double);

implementation

uses
  sysutils, sdl2min, gfx, pic, sprites, sprbank, party, chardata, items,
  monsters, combat, combatstate, combatcore, audio, gamestate, world, codex,
  pcportrait, spellicon, skilldb, skillicon;

const
  { combat command UI phases }
  CB_COMMAND = 0;   { picking a command }
  CB_TARGET  = 1;   { picking an enemy }
  CB_SPELL   = 2;   { picking a spell }
  CB_ALLY    = 3;   { picking an ally, for a heal or an item }
  CB_ITEM    = 4;   { picking an item to use }
  CB_SKILL   = 5;   { picking a combat maneuver }

  { commands in the root menu }
  CMD_ATTACK = 0;
  CMD_CAST   = 1;
  CMD_SKILL  = 2;
  CMD_ITEM   = 3;
  CMD_GUARD  = 4;
  CMD_MOVE   = 5;
  CMD_SKIP   = 6;
  CMD_FLEE   = 7;
  CMD_COUNT  = 8;

  CMD_NAME: array[0 .. CMD_COUNT - 1] of string[7] = (
    'ATTACK', 'CAST', 'SKILL', 'ITEM', 'DEFEND', 'MOVE', 'SKIP', 'FLEE');

var
  { combat command UI: a FF-style command then target flow }
  cbMenu: longint;        { CB_* phase }
  cmdSel: longint;        { highlighted command }
  spellSel: longint;      { highlighted spell }
  skillSel: longint;      { highlighted combat maneuver }
  pendingSkill: longint;  { maneuver chosen, awaiting a target, -1 none }
  allySel: longint;       { highlighted ally, for a heal }
  pendingSpell: longint;  { spell chosen, awaiting a target, -1 none }
  itemSel: longint;       { highlighted item, a pack slot }
  pendingItem: longint;   { item chosen, awaiting a target, -1 none }

procedure EndCombat;
begin
  { the fight's spoils resolve in combat; the UI only announces the find. A
    quick test battle has no world to carry loot into, so it is skipped. }
  if (not FromQuickBattle) and GrantVictoryLoot then begin
    saveMsg := 'AN UNKNOWN POTION AMONG THE SPOILS';
    saveMsgT := 2.5;
  end;
  AwardBossFlag;
  if FromQuickBattle then begin
    FromQuickBattle := false;
    State := gsTitle;
    titleSel := 0;
  end else if Active^.Victory or Active^.Fled then
    State := gsExplore
  else
    State := gsGameOver;
end;

const
  FOE_PAL: array[0 .. 5] of TColor = (
    TColor($FFB05545), TColor($FF6E9E57), TColor($FF5A86B0),
    TColor($FF9A6FB0), TColor($FF7FA0A0), TColor($FFB0923C));

procedure DrawBar(x, y, w, h, cur, max: longint; fillc, backc: TColor);
var
  fw: longint;
begin
  FillRect(x, y, w, h, backc);
  if max > 0 then begin
    fw := (w * cur) div max;
    if fw < 0 then fw := 0;
    if fw > w then fw := w;
    if (fw = 0) and (cur > 0) then fw := 1;
    FillRect(x, y, fw, h, fillc);
  end;
  FrameRect(x, y, w, h, RGB(0, 0, 0));
end;

procedure DrawFoeGlyph(cx, cy, w, h: longint; body: TColor);
var
  hw, hh: longint;
begin
  hw := w div 2; hh := h div 2;
  { a rounded blob from stacked rectangles }
  FillRect(cx - hw + 2, cy - hh,     w - 4, h,     body);
  FillRect(cx - hw,     cy - hh + 3, w,     h - 6, body);
  FillRect(cx - hw + 3, cy + 2,      w - 6, hh - 3, Shade(body, 150));
  { eyes }
  FillRect(cx - hw + 6, cy - hh + 6, 4, 5, RGB(240, 240, 230));
  FillRect(cx + hw - 10, cy - hh + 6, 4, 5, RGB(240, 240, 230));
  PutPixel(cx - hw + 7, cy - hh + 8, RGB(20, 20, 20));
  PutPixel(cx + hw - 9, cy - hh + 8, RGB(20, 20, 20));
end;

{ Draw a billboard sprite into a combat slot, scaled to fit a box of height
  boxH centered on (cx,cy), feet-down, with its colour key left transparent. }
procedure DrawFoeSprite(const img: TImage; cx, cy, boxH: longint);
var
  dx, dy, dw, dh, x0, y0, srcx, srcy: longint;
  c: TColor;
begin
  if (img.w <= 0) or (img.h <= 0) or (boxH < 1) then exit;
  dh := boxH;
  dw := round(img.w * (boxH / img.h));
  if dw < 1 then dw := 1;
  x0 := cx - dw div 2;
  y0 := cy - dh div 2;
  for dy := 0 to dh - 1 do begin
    srcy := (dy * img.h) div dh;
    for dx := 0 to dw - 1 do begin
      srcx := (dx * img.w) div dw;
      c := img.pix[srcy * img.w + srcx];
      if (c shr 24) < 128 then continue;      { transparent key }
      PutPixel(x0 + dx, y0 + dy, c);
    end;
  end;
end;

const
  CMDBOX_X = 6;
  CMDBOX_W = 104;
  CMDBOX_Y = 140;      { top of the bottom window band }
  SPELL_VIS = 6;       { spell rows the command box shows before it scrolls }

{ The FF-style command window at the lower left, one list per phase. The
  cursor moves vertically; target and ally picks drive a chevron out on
  the battlefield, so this box only names the current pick. }
{ Whether pack slot of the acting character is a consumable it can use. The
  item rule lives in items; this adds the actor, slot and quantity guards. }
function CombatItemUsable(slot: longint): boolean;
begin
  CombatItemUsable := false;
  if Active^.CurActor < 0 then exit;
  if (slot < 0) or (slot > High(Roster[Active^.CurActor].pack)) then exit;
  if Roster[Active^.CurActor].pack[slot].qty <= 0 then exit;
  CombatItemUsable := ItemUsableInCombat(Roster[Active^.CurActor].pack[slot].def);
end;

{ Whether the item in that pack slot raises a fallen ally (vs heals). }
function CombatSlotRevives(slot: longint): boolean;
begin
  CombatSlotRevives := false;
  if Active^.CurActor < 0 then exit;
  if (slot < 0) or (slot > High(Roster[Active^.CurActor].pack)) then exit;
  CombatSlotRevives := ItemRevives(Roster[Active^.CurActor].pack[slot].def);
end;

{ A command whose slot the current actor has already spent this turn is
  shown greyed and refused: MOVE once the move is used, and the action
  commands once the action is used. SKIP and FLEE are always available. }
function CmdSpent(cmd: longint): boolean;
begin
  case cmd of
    CMD_MOVE: CmdSpent := Active^.TurnMoved;
    CMD_ATTACK, CMD_CAST, CMD_SKILL, CMD_ITEM, CMD_GUARD: CmdSpent := Active^.TurnActed;
  else
    CmdSpent := false;
  end;
end;

procedure DrawCombatMenu;
var
  i, y, y0, bh, row, n, first: longint;
  sp: TSpell;
  sk: TSkillDef;
  c: TColor;
  any: boolean;
begin
  bh := FBH - CMDBOX_Y - 2;
  FillRectBlend(CMDBOX_X, CMDBOX_Y, CMDBOX_W, bh, RGB(6, 8, 14), 235);
  FrameRect(CMDBOX_X, CMDBOX_Y, CMDBOX_W, bh, RGB(150, 140, 90));

  { the window belongs to the acting character, named across its head;
    on a beat or the foe turn it stands by with no list }
  if (Active^.CombatPhase = CP_INPUT) and (Active^.CurActor >= 0) then
    DrawText(CMDBOX_X + 6, CMDBOX_Y + 5, Copy(Roster[Active^.CurActor].name, 1, 12),
      RGB(245, 230, 140))
  else if Active^.CombatPhase = CP_ENEMY then
    DrawText(CMDBOX_X + 6, CMDBOX_Y + 5, 'FOE TURN', RGB(210, 150, 140))
  else
    DrawText(CMDBOX_X + 6, CMDBOX_Y + 5, '...', RGB(150, 150, 130));
  FillRect(CMDBOX_X + 4, CMDBOX_Y + 16, CMDBOX_W - 8, 1, RGB(90, 84, 56));
  y0 := CMDBOX_Y + 21;
  if Active^.CombatPhase <> CP_INPUT then exit;   { no interactive list while busy }

  case cbMenu of
    CB_COMMAND:
      { the root menu now holds eight commands, so pack the rows a touch
        tighter than the scrolling sublists to keep FLEE inside the box }
      for i := 0 to CMD_COUNT - 1 do begin
        y := (y0 - 2) + i * 10;
        if CmdSpent(i) then begin
          if i = cmdSel then DrawText(CMDBOX_X + 5, y, '>', RGB(96, 90, 72));
          DrawText(CMDBOX_X + 15, y, CMD_NAME[i], RGB(96, 90, 72));
        end else if i = cmdSel then begin
          DrawText(CMDBOX_X + 5, y, '>', RGB(245, 230, 140));
          DrawText(CMDBOX_X + 15, y, CMD_NAME[i], RGB(245, 230, 140));
        end else
          DrawText(CMDBOX_X + 15, y, CMD_NAME[i], RGB(170, 165, 140));
      end;
    CB_SPELL: begin
      { the list can outrun the box, so show a window of SPELL_VIS around the
        selection and mark that more lie above or below }
      n := SpellCount;
      first := 0;
      if n > SPELL_VIS then begin
        if spellSel >= SPELL_VIS then first := spellSel - SPELL_VIS + 1;
        if first > n - SPELL_VIS then first := n - SPELL_VIS;
      end;
      for row := 0 to SPELL_VIS - 1 do begin
        i := first + row;
        if i >= n then break;
        y := y0 + row * 11;
        sp := SpellInfo(i);
        if i = spellSel then c := RGB(185, 215, 245)
        else if ActorCanCast(Active^.CurActor, i) then c := RGB(150, 160, 185)
        else c := RGB(95, 95, 110);
        if i = spellSel then
          FillRectBlend(CMDBOX_X + 2, y - 1, CMDBOX_W - 4, 10,
            RGB(40, 44, 66), 200);
        DrawSpellIcon(CMDBOX_X + 3, y, 9, 9, sp.icon);
        DrawText(CMDBOX_X + 14, y, Copy(sp.name, 1, 11), c);
        DrawText(CMDBOX_X + CMDBOX_W - 12, y, IntToStr(sp.cost), c);
      end;
      { a count footer when the list is longer than the window }
      if n > SPELL_VIS then
        DrawText(CMDBOX_X + 15, y0 + SPELL_VIS * 11,
          IntToStr(spellSel + 1) + '/' + IntToStr(n), RGB(120, 130, 150));
    end;
    CB_SKILL: begin
      n := CombatSkillCount;
      if n = 0 then
        DrawText(CMDBOX_X + 6, y0, 'NO SKILLS', RGB(150, 150, 130))
      else begin
        first := 0;
        if n > SPELL_VIS then begin
          if skillSel >= SPELL_VIS then first := skillSel - SPELL_VIS + 1;
          if first > n - SPELL_VIS then first := n - SPELL_VIS;
        end;
        for row := 0 to SPELL_VIS - 1 do begin
          i := first + row;
          if i >= n then break;
          y := y0 + row * 11;
          sk := CombatSkillInfo(i);
          if i = skillSel then c := RGB(185, 215, 245)
          else if ActorCanManeuver(Active^.CurActor, i) then c := RGB(150, 160, 185)
          else c := RGB(95, 95, 110);
          if i = skillSel then
            FillRectBlend(CMDBOX_X + 2, y - 1, CMDBOX_W - 4, 10,
              RGB(40, 44, 66), 200);
          DrawSkillIcon(CMDBOX_X + 3, y, 9, 9, sk.icon);
          DrawText(CMDBOX_X + 14, y, Copy(sk.name, 1, 12), c);
          { at-will shows a dot, limited shows the uses left this fight }
          if sk.maxUses = 0 then
            DrawText(CMDBOX_X + CMDBOX_W - 12, y, '-', c)
          else
            DrawText(CMDBOX_X + CMDBOX_W - 12, y,
              IntToStr(CombatSkillUsesLeft(Active^.CurActor, i)), c);
        end;
        if n > SPELL_VIS then
          DrawText(CMDBOX_X + 15, y0 + SPELL_VIS * 11,
            IntToStr(skillSel + 1) + '/' + IntToStr(n), RGB(120, 130, 150));
      end;
    end;
    CB_TARGET: begin
      DrawText(CMDBOX_X + 6, y0, 'TARGET', RGB(240, 220, 130));
      if (Active^.CurTarget >= 0) and (Active^.CurTarget <= High(Active^.Foes)) then
        DrawText(CMDBOX_X + 6, y0 + 12,
          Copy(MonDefs[Active^.Foes[Active^.CurTarget].def].name, 1, 15), RGB(240, 220, 130));
      DrawText(CMDBOX_X + 6, y0 + 32, 'UP/DN AIM', RGB(150, 150, 130));
      DrawText(CMDBOX_X + 6, y0 + 42, 'ENT  OK', RGB(150, 150, 130));
      DrawText(CMDBOX_X + 6, y0 + 52, 'ESC  BACK', RGB(150, 150, 130));
    end;
    CB_ITEM: begin
      any := false;
      row := 0;
      for i := 0 to High(Roster[Active^.CurActor].pack) do
        if CombatItemUsable(i) then begin
          y := y0 + row * 11;
          if i = itemSel then c := RGB(185, 215, 245)
          else c := RGB(150, 160, 185);
          if i = itemSel then DrawText(CMDBOX_X + 5, y, '>', c);
          if Roster[Active^.CurActor].pack[i].qty > 1 then begin
            DrawText(CMDBOX_X + 15, y,
              Copy(ItemLabel(Roster[Active^.CurActor].pack[i].def), 1, 10), c);
            DrawText(CMDBOX_X + CMDBOX_W - 16, y,
              'x' + IntToStr(Roster[Active^.CurActor].pack[i].qty), c);
          end else
            DrawText(CMDBOX_X + 15, y,
              Copy(ItemLabel(Roster[Active^.CurActor].pack[i].def), 1, 14), c);
          inc(row);
          any := true;
        end;
      if not any then DrawText(CMDBOX_X + 6, y0, 'NO ITEMS', RGB(150, 150, 130));
    end;
    CB_ALLY: begin
      if pendingItem >= 0 then DrawText(CMDBOX_X + 6, y0, 'USE', RGB(140, 220, 200))
      else DrawText(CMDBOX_X + 6, y0, 'HEAL', RGB(140, 220, 200));
      DrawText(CMDBOX_X + 6, y0 + 12,
        Copy(Roster[allySel].name, 1, 12), RGB(140, 220, 200));
      DrawText(CMDBOX_X + 6, y0 + 32, 'UP/DN PICK', RGB(150, 150, 130));
      DrawText(CMDBOX_X + 6, y0 + 42, 'ENT  OK', RGB(150, 150, 130));
      DrawText(CMDBOX_X + 6, y0 + 52, 'ESC  BACK', RGB(150, 150, 130));
    end;
  end;
end;

{ A white flash over a struck target, fading with its timer. }
procedure DrawFlash(x, y, w, h: longint; t: double);
begin
  if t <= 0 then exit;
  FillRectBlend(x, y, w, h, RGB(255, 245, 230), round(200 * (t / FLASH_LIFE)));
end;

{ Every active floating number for one target, rising and fading above
  (px, py). side 0 is a foe, 1 a party member. }
procedure DrawPops(side, idx, px, py: longint);
var
  i, yy, lit: longint;
  frac: double;
  base: TColor;
begin
  for i := 0 to High(Active^.Pops) do
    if (Active^.Pops[i].side = side) and (Active^.Pops[i].idx = idx) then begin
      frac := Active^.Pops[i].life / POP_LIFE;
      case Active^.Pops[i].color of
        POPC_FOEDMG:   base := RGB(250, 240, 180);
        POPC_PARTYDMG: base := RGB(245, 95, 85);
        POPC_HEAL:     base := RGB(120, 230, 130);
        POPC_WEAK:     base := RGB(255, 170, 60);    { struck a weakness }
        POPC_RESIST:   base := RGB(120, 170, 235);   { shrugged off }
      else             base := RGB(180, 180, 180);   { miss or status tag }
      end;
      lit := 110 + round(146 * frac);
      yy := py - round((1.0 - frac) * 12);
      DrawText(px - Length(Active^.Pops[i].text) * 3, yy, Active^.Pops[i].text, Shade(base, lit));
    end;
end;

{ A compact badge of the active status effects on a combatant. }
function StatusTag(const st: TStatus): string;
begin
  StatusTag := '';
  if st.poison > 0 then StatusTag := StatusTag + 'P';
  if st.burn > 0 then StatusTag := StatusTag + 'B';
  if st.stun > 0 then StatusTag := StatusTag + 'T';
  if st.slow > 0 then StatusTag := StatusTag + 'S';
  if st.offbal > 0 then StatusTag := StatusTag + 'D';
end;

procedure CombatRender;
const
  { the battlefield is one depth axis: foe ranks recede up and back, the
    party ranks stand forward toward the viewer. Reach then reads off the
    screen, a back-rank member is plainly behind the front line. }
  FOE_BACK_Y  = 34;  FOE_BACK_H  = 11;
  FOE_FRONT_Y = 70;  FOE_FRONT_H = 14;
  PTY_FRONT_Y = 92;
  PTY_BACK_Y  = 116;
  PANEL_Y     = 140;
var
  i, n, living, slot, cx, cy, x, tx, mi, rk, half, col, ny: longint;
  c, body: TColor;
  s: string;
  frameImg: TImage;
begin
  { backdrop: a dim vault receding behind the foes, a lit floor the party
    stands on, a horizon seam where the two sides meet }
  FillRect(0, 0, FBW, 88, RGB(20, 17, 26));
  FillRect(0, 88, FBW, FBH - 88, RGB(40, 32, 27));
  FillRect(0, 86, FBW, 2, RGB(62, 52, 46));

  { title bar }
  FillRect(0, 0, FBW, 14, RGB(30, 12, 12));
  FrameRect(0, 0, FBW, 14, RGB(90, 40, 30));
  DrawText(8, 3, 'COMBAT', RGB(230, 170, 120));
  if LivingFoes = 1 then s := '1 FOE' else s := IntToStr(LivingFoes) + ' FOES';
  DrawText(FBW - 96, 3, s, RGB(190, 180, 140));

  { --- foes, in depth ranks: back rank up and small, front rank nearer
    the clash and larger. Same rank spreads across columns. --- }
  for rk := RANK_BACK downto RANK_FRONT do begin
    living := 0;
    for i := 0 to High(Active^.Foes) do
      if Active^.Foes[i].alive and (Active^.Foes[i].rank = rk) then inc(living);
    if living < 1 then continue;
    slot := FBW div living;
    if rk = RANK_BACK then begin cy := FOE_BACK_Y; half := FOE_BACK_H; end
    else begin cy := FOE_FRONT_Y; half := FOE_FRONT_H; end;
    col := 0;
    for i := 0 to High(Active^.Foes) do begin
      if (not Active^.Foes[i].alive) or (Active^.Foes[i].rank <> rk) then continue;
      cx := slot * col + slot div 2;
      body := FOE_PAL[Active^.Foes[i].def mod 6];
      mi := Active^.Foes[i].spriteIdx;
      if mi = -2 then mi := LoadSprite(GamePak, MonDefs[Active^.Foes[i].def].model);
      if (mi >= 0) and SpriteReg[mi].isBank
        and SpriteFrame(mi, Active^.Foes[i].anim.seq, Active^.Foes[i].anim.frame, frameImg) then
        DrawFoeSprite(frameImg, cx, cy, 2 * half)
      else if mi >= 0 then
        DrawFoeSprite(SpriteReg[mi].img, cx, cy, 2 * half)
      else
        DrawFoeGlyph(cx, cy, 2 * half, 2 * half, body);
      if (i <= High(Active^.FoeFlash)) then
        DrawFlash(cx - half, cy - half, 2 * half, 2 * half, Active^.FoeFlash[i]);
      s := MonDefs[Active^.Foes[i].def].name;
      DrawText(cx - Length(s) * 3, cy - half - 8, s, RGB(215, 185, 175));
      DrawBar(cx - 16, cy + half + 1, 32, 3, Active^.Foes[i].hp, Active^.Foes[i].hpMax,
        RGB(200, 80, 70), RGB(50, 24, 24));
      if i <= High(Active^.FoeStatus) then begin
        s := StatusTag(Active^.FoeStatus[i]);
        if s <> '' then DrawText(cx + 20, cy + half - 2, s, RGB(190, 120, 215));
      end;
      DrawPops(0, i, cx, cy - half - 18);
      { the aim chevron sits to the left of the chosen foe }
      if (i = Active^.CurTarget) and (Active^.CombatPhase = CP_INPUT) and (cbMenu <> CB_ALLY) then
        DrawText(cx - half - 10, cy - 3, '>', RGB(245, 225, 120));
      inc(col);
    end;
    { a dim tag in the left margin names the rank's depth }
    if rk = RANK_BACK then s := 'BACK' else s := 'FRONT';
    DrawText(3, cy - 3, s, RGB(96, 88, 72));
  end;

  { --- party, in depth ranks: front rank forward near the clash, back
    rank to the rear near the viewer. Same rank spreads across columns. --- }
  n := Length(Roster);
  for rk := RANK_FRONT to RANK_BACK do begin
    living := 0;
    for i := 0 to n - 1 do if Roster[i].rank = rk then inc(living);
    if living < 1 then continue;
    if rk = RANK_FRONT then ny := PTY_FRONT_Y else ny := PTY_BACK_Y;
    slot := (FBW - 24) div living;
    if slot > 96 then slot := 96;
    col := 0;
    for i := 0 to n - 1 do begin
      if Roster[i].rank <> rk then continue;
      x := 16 + col * slot;
      tx := x + 18;   { text clears the portrait thumbnail on the left }
      if (i = Active^.CurActor) and (Active^.CombatPhase = CP_INPUT) then
        DrawText(x - 10, ny, '>', RGB(245, 230, 140));
      if (cbMenu = CB_ALLY) and (i = allySel) and (Active^.CombatPhase = CP_INPUT) then
        DrawText(x - 10, ny, '>', RGB(120, 220, 200));
      if not Roster[i].alive then c := RGB(160, 80, 80)
      else if Roster[i].downed then c := RGB(175, 135, 85)
      else if (i = Active^.CurActor) and (Active^.CombatPhase = CP_INPUT) then c := RGB(245, 230, 140)
      else c := RGB(205, 210, 190);
      FrameRect(x, ny, 16, 16, RGB(50, 46, 38));
      DrawPCPortraitScaled(x, ny, 16, 16, Roster[i].portrait);
      DrawText(tx, ny, Copy(Roster[i].name, 1, 8), c);
      if (i <= High(Active^.PartyStatus)) and Roster[i].alive and (not Roster[i].downed) then begin
        s := StatusTag(Active^.PartyStatus[i]);
        if s <> '' then DrawText(tx + 50, ny, s, RGB(190, 120, 215));
      end;
      if not Roster[i].alive then
        DrawText(tx, ny + 9, 'SLAIN', RGB(190, 90, 90))
      else if Roster[i].downed then
        DrawText(tx, ny + 9, 'DOWN', RGB(190, 140, 90))
      else begin
        DrawText(tx, ny + 9, IntToStr(Roster[i].hp) + '/'
          + IntToStr(Roster[i].hpMax), RGB(170, 175, 160));
        if Roster[i].guarding then DrawText(x + slot - 24, ny, 'GRD', RGB(150, 170, 210));
        if Roster[i].sp > 0 then
          DrawText(x + slot - 28, ny + 9, 'sp' + IntToStr(Roster[i].sp),
            RGB(150, 160, 205));
        DrawBar(x, ny + 18, slot - 16, 3, Roster[i].hp, Roster[i].hpMax,
          RGB(70, 170, 70), RGB(40, 20, 20));
      end;
      if (i <= High(Active^.PartyFlash)) then
        DrawFlash(x - 2, ny - 2, slot - 6, 26, Active^.PartyFlash[i]);
      DrawPops(1, i, x + 14, ny - 11);
      inc(col);
    end;
    { a dim tag at the right names the rank, when a short rank leaves room }
    if living <= 2 then begin
      if rk = RANK_FRONT then s := 'FRONT' else s := 'BACK';
      DrawText(FBW - 44, ny + 5, s, RGB(96, 92, 76));
    end;
  end;

  { --- bottom windows: the message box on the right, the command box on
    the left (the command box is drawn by DrawCombatMenu) --- }
  FillRectBlend(116, PANEL_Y, FBW - 122, FBH - PANEL_Y - 2, RGB(6, 8, 14), 235);
  FrameRect(116, PANEL_Y, FBW - 122, FBH - PANEL_Y - 2, RGB(110, 110, 140));
  for i := 0 to LOG_LINES - 1 do
    DrawText(122, PANEL_Y + 6 + i * 10, Active^.Log[i], RGB(175, 185, 170));

  { context help: what the acting member may still do this turn. One move
    and one action in either order, then the turn ends; SKIP ends it early. }
  if (not Active^.CombatOver) and (Active^.CombatPhase = CP_INPUT) and (Active^.CurActor >= 0) then begin
    FillRect(122, FBH - 27, FBW - 134, 1, RGB(70, 74, 92));
    if Active^.TurnMoved and (not Active^.TurnActed) then begin
      DrawText(122, FBH - 22, 'Move spent.', RGB(150, 205, 175));
      DrawText(122, FBH - 12, 'Take an ACTION, or SKIP.', RGB(175, 185, 205));
    end else if Active^.TurnActed and (not Active^.TurnMoved) then begin
      DrawText(122, FBH - 22, 'Action spent.', RGB(150, 205, 175));
      DrawText(122, FBH - 12, 'MOVE, or SKIP to end turn.', RGB(175, 185, 205));
    end else begin
      DrawText(122, FBH - 22, 'One MOVE and one ACTION,', RGB(175, 185, 205));
      DrawText(122, FBH - 12, 'any order. SKIP ends turn.', RGB(175, 185, 205));
    end;
  end;

  if Active^.CombatOver then begin
    FillRectBlend(6, PANEL_Y, 104, FBH - PANEL_Y - 2, RGB(6, 8, 14), 235);
    FrameRect(6, PANEL_Y, 104, FBH - PANEL_Y - 2, RGB(150, 140, 90));
    if Active^.Victory then s := 'VICTORY'
    else if Active^.Fled then s := 'ESCAPED'
    else s := 'DEFEAT';
    DrawText(16, PANEL_Y + 14, s, RGB(235, 220, 150));
    DrawText(16, PANEL_Y + 34, 'PRESS', RGB(170, 170, 150));
    DrawText(16, PANEL_Y + 44, 'A KEY', RGB(170, 170, 150));
  end else
    DrawCombatMenu;
end;

{ Whether the actor could target this foe under the pending action: a
  spell reaches any living foe, a melee or ranged attack follows reach. }
function CombatCanTarget(foe: longint): boolean;
begin
  if (foe < 0) or (foe > High(Active^.Foes)) or (not Active^.Foes[foe].alive) then
    CombatCanTarget := false
  else if pendingSpell >= 0 then
    CombatCanTarget := true
  else
    CombatCanTarget := FoeReachable(Active^.CurActor, foe);
end;

{ Step the enemy cursor to the next targetable foe in a direction. }
procedure CombatCycleTarget(dir: longint);
var
  start, i, n: longint;
begin
  n := Length(Active^.Foes);
  if n = 0 then exit;
  i := Active^.CurTarget;
  if (i < 0) or (i >= n) then i := 0;
  start := i;
  repeat
    i := ((i + dir) mod n + n) mod n;
    if CombatCanTarget(i) then begin Active^.CurTarget := i; exit; end;
  until i = start;
end;

{ Whether member i is a valid ally target for the pending action. A spell
  heal may revive the downed, so they count. A pending revive item wants a
  gravely wounded ally; any other item wants a conscious one. }
function CombatAllyTargetable(i: longint): boolean;
begin
  CombatAllyTargetable := false;
  if (i < 0) or (i > High(Roster)) then exit;
  if not Roster[i].alive then exit;
  if pendingItem >= 0 then begin
    if CombatSlotRevives(pendingItem) then
      CombatAllyTargetable := Roster[i].downed
    else
      CombatAllyTargetable := not Roster[i].downed;
  end else
    CombatAllyTargetable := true;
end;

{ Step the ally cursor to the next valid target for the pending action. }
procedure CombatCycleAlly(dir: longint);
var
  start, i, n: longint;
begin
  n := Length(Roster);
  if n = 0 then exit;
  i := allySel;
  if (i < 0) or (i >= n) then i := 0;
  start := i;
  repeat
    i := ((i + dir) mod n + n) mod n;
    if CombatAllyTargetable(i) then begin allySel := i; exit; end;
  until i = start;
end;

{ Step the item cursor to the next usable consumable in the pack. }
procedure CombatStepItem(dir: longint);
var
  start, i, n: longint;
begin
  if Active^.CurActor < 0 then exit;
  n := Length(Roster[Active^.CurActor].pack);
  if n = 0 then exit;
  i := itemSel;
  if (i < 0) or (i >= n) then i := 0;
  start := i;
  repeat
    i := ((i + dir) mod n + n) mod n;
    if CombatItemUsable(i) then begin itemSel := i; exit; end;
  until i = start;
end;

{ Step the spell cursor to the next spell this actor can cast. }
procedure CombatStepSpell(dir: longint);
var
  start, i, n: longint;
begin
  n := SpellCount;
  if n = 0 then exit;
  i := spellSel;
  if (i < 0) or (i >= n) then i := 0;
  start := i;
  repeat
    i := ((i + dir) mod n + n) mod n;
    if ActorCanCast(Active^.CurActor, i) then begin spellSel := i; exit; end;
  until i = start;
end;

procedure CombatStepSkill(dir: longint);
var
  start, i, n: longint;
begin
  n := CombatSkillCount;
  if n = 0 then exit;
  i := skillSel;
  if (i < 0) or (i >= n) then i := 0;
  start := i;
  repeat
    i := ((i + dir) mod n + n) mod n;
    if ActorCanManeuver(Active^.CurActor, i) then begin skillSel := i; exit; end;
  until i = start;
end;

{ Return to the command menu, clearing any pending choice and picking a
  sane default target. Called at the top of each actor's turn. }
procedure CombatToCommand;
var
  i: longint;
begin
  cbMenu := CB_COMMAND;
  cmdSel := CMD_ATTACK;
  for i := 0 to CMD_COUNT - 1 do        { land on the first command still open }
    if not CmdSpent(i) then begin cmdSel := i; break; end;
  pendingSpell := -1;
  pendingSkill := -1;
  pendingItem := -1;
  if (Active^.CurTarget < 0) or (Active^.CurTarget > High(Active^.Foes)) or (not Active^.Foes[Active^.CurTarget].alive) then
    Active^.CurTarget := FirstLivingFoe;
end;

procedure CombatConfirmCommand;
var
  i: longint;
begin
  if CmdSpent(cmdSel) then begin PlaySfx(SFX_DOWN); exit; end;
  case cmdSel of
    CMD_ATTACK: begin
      pendingSpell := -1;
      Active^.CurTarget := FirstReachable(Active^.CurActor);
      if Active^.CurTarget < 0 then begin
        CombatLog(Roster[Active^.CurActor].name + ' has no target in reach.');
        PlaySfx(SFX_DOWN);
      end else begin
        cbMenu := CB_TARGET; PlaySfx(SFX_SELECT);
      end;
    end;
    CMD_CAST: begin
      spellSel := -1;
      for i := 0 to SpellCount - 1 do
        if ActorCanCast(Active^.CurActor, i) then begin spellSel := i; break; end;
      if spellSel < 0 then begin
        CombatLog(Roster[Active^.CurActor].name + ' has no spell to cast.');
        PlaySfx(SFX_DOWN);
      end else begin
        cbMenu := CB_SPELL; PlaySfx(SFX_SELECT);
      end;
    end;
    CMD_SKILL: begin
      skillSel := -1;
      for i := 0 to CombatSkillCount - 1 do
        if ActorCanManeuver(Active^.CurActor, i) then begin skillSel := i; break; end;
      if skillSel < 0 then begin
        CombatLog(Roster[Active^.CurActor].name + ' has no maneuver ready.');
        PlaySfx(SFX_DOWN);
      end else begin
        cbMenu := CB_SKILL; PlaySfx(SFX_SELECT);
      end;
    end;
    CMD_ITEM: begin
      itemSel := -1;
      for i := 0 to High(Roster[Active^.CurActor].pack) do
        if CombatItemUsable(i) then begin itemSel := i; break; end;
      if itemSel < 0 then begin
        CombatLog(Roster[Active^.CurActor].name + ' has no item to use.');
        PlaySfx(SFX_DOWN);
      end else begin
        cbMenu := CB_ITEM; PlaySfx(SFX_SELECT);
      end;
    end;
    CMD_GUARD: begin ActGuard; PlaySfx(SFX_SELECT); CombatToCommand; end;
    CMD_MOVE:  begin ActMove; PlaySfx(SFX_SELECT); CombatToCommand; end;
    CMD_SKIP:  begin ActSkip; PlaySfx(SFX_SELECT); CombatToCommand; end;
    CMD_FLEE:  begin ActFlee; PlaySfx(SFX_SELECT); CombatToCommand; end;
  end;
end;

procedure CombatConfirmSpell;
var
  sp: TSpell;
begin
  if not ActorCanCast(Active^.CurActor, spellSel) then begin PlaySfx(SFX_DOWN); exit; end;
  sp := SpellInfo(spellSel);
  pendingSpell := spellSel;
  case sp.mode of
    TGT_ENEMY, TGT_ENEMY_RANK: begin
      Active^.CurTarget := FirstLivingFoe;
      cbMenu := CB_TARGET; PlaySfx(SFX_SELECT);
    end;
    TGT_ALLY: begin
      allySel := Active^.CurActor;
      if not Roster[allySel].alive then CombatCycleAlly(1);
      cbMenu := CB_ALLY; PlaySfx(SFX_SELECT);
    end;
    TGT_PARTY: begin
      ActCast(pendingSpell, -1); PlaySfx(SFX_SELECT); CombatToCommand;
    end;
  end;
end;

procedure CombatConfirmSkill;
var
  sk: TSkillDef;
begin
  if not ActorCanManeuver(Active^.CurActor, skillSel) then begin PlaySfx(SFX_DOWN); exit; end;
  sk := CombatSkillInfo(skillSel);
  if sk.effect = SKE_RALLY then begin
    { the rally hits the whole party, so it needs no target }
    ActSkill(skillSel, -1); PlaySfx(SFX_SELECT); CombatToCommand;
    exit;
  end;
  pendingSkill := skillSel;
  Active^.CurTarget := FirstLivingFoe;
  cbMenu := CB_TARGET; PlaySfx(SFX_SELECT);
end;

procedure CombatConfirmItem;
begin
  if not CombatItemUsable(itemSel) then begin PlaySfx(SFX_DOWN); exit; end;
  pendingItem := itemSel;
  { start the ally cursor on a valid target under this item's filter }
  allySel := Active^.CurActor;
  if not CombatAllyTargetable(allySel) then CombatCycleAlly(1);
  if not CombatAllyTargetable(allySel) then begin
    { nothing this item can act on, e.g. a revive with no one down }
    if CombatSlotRevives(itemSel) then
      CombatLog('No fallen ally to revive.')
    else
      CombatLog('No one to use that on.');
    pendingItem := -1; PlaySfx(SFX_DOWN); exit;
  end;
  cbMenu := CB_ALLY; PlaySfx(SFX_SELECT);
end;

procedure CombatBack;
begin
  case cbMenu of
    CB_TARGET:
      if pendingSkill >= 0 then cbMenu := CB_SKILL
      else if pendingSpell >= 0 then cbMenu := CB_SPELL
      else cbMenu := CB_COMMAND;
    CB_SPELL: cbMenu := CB_COMMAND;
    CB_SKILL: cbMenu := CB_COMMAND;
    CB_ITEM:  cbMenu := CB_COMMAND;
    CB_ALLY:
      if pendingItem >= 0 then cbMenu := CB_ITEM else cbMenu := CB_SPELL;
  end;
  if cbMenu <> CB_TARGET then pendingSpell := -1;
  if (cbMenu <> CB_TARGET) and (cbMenu <> CB_SKILL) then pendingSkill := -1;
  if cbMenu <> CB_ALLY then pendingItem := -1;
  PlaySfx(SFX_SELECT);
end;

procedure CombatKeyDown(scancode: longint);
begin
  if Active^.CombatOver then begin
    EndCombat;
    exit;
  end;
  if CombatBusy or (Active^.CurActor < 0) then exit;   { a beat or the foe turn is running }

  case cbMenu of
    CB_COMMAND:
      case scancode of
        SDL_SCANCODE_UP, SDL_SCANCODE_W:
          cmdSel := (cmdSel + CMD_COUNT - 1) mod CMD_COUNT;
        SDL_SCANCODE_DOWN, SDL_SCANCODE_S:
          cmdSel := (cmdSel + 1) mod CMD_COUNT;
        SDL_SCANCODE_RETURN, SDL_SCANCODE_SPACE:
          CombatConfirmCommand;
        { the command menu is the root, so Escape has nothing to back out to;
          move the cursor to FLEE, so Escape reads as leaving the battle and the
          player still confirms with Enter rather than fleeing on a stray press }
        SDL_SCANCODE_ESCAPE:
          cmdSel := CMD_FLEE;
      end;
    CB_TARGET:
      case scancode of
        SDL_SCANCODE_UP, SDL_SCANCODE_LEFT, SDL_SCANCODE_TAB:
          CombatCycleTarget(-1);
        SDL_SCANCODE_DOWN, SDL_SCANCODE_RIGHT:
          CombatCycleTarget(1);
        SDL_SCANCODE_RETURN, SDL_SCANCODE_SPACE: begin
          if pendingSkill >= 0 then begin
            ActSkill(pendingSkill, Active^.CurTarget); PlaySfx(SFX_HIT);
          end else if pendingSpell >= 0 then begin
            ActCast(pendingSpell, Active^.CurTarget); PlaySfx(SFX_HIT);
          end else begin
            ActAttack; PlaySfx(SFX_HIT);
          end;
          CombatToCommand;
        end;
        SDL_SCANCODE_ESCAPE: CombatBack;
      end;
    CB_SKILL:
      case scancode of
        SDL_SCANCODE_UP, SDL_SCANCODE_W:   CombatStepSkill(-1);
        SDL_SCANCODE_DOWN, SDL_SCANCODE_S: CombatStepSkill(1);
        SDL_SCANCODE_RETURN, SDL_SCANCODE_SPACE: CombatConfirmSkill;
        SDL_SCANCODE_ESCAPE: CombatBack;
      end;
    CB_SPELL:
      case scancode of
        SDL_SCANCODE_UP, SDL_SCANCODE_W:   CombatStepSpell(-1);
        SDL_SCANCODE_DOWN, SDL_SCANCODE_S: CombatStepSpell(1);
        SDL_SCANCODE_RETURN, SDL_SCANCODE_SPACE: CombatConfirmSpell;
        SDL_SCANCODE_ESCAPE: CombatBack;
      end;
    CB_ITEM:
      case scancode of
        SDL_SCANCODE_UP, SDL_SCANCODE_W:   CombatStepItem(-1);
        SDL_SCANCODE_DOWN, SDL_SCANCODE_S: CombatStepItem(1);
        SDL_SCANCODE_RETURN, SDL_SCANCODE_SPACE: CombatConfirmItem;
        SDL_SCANCODE_ESCAPE: CombatBack;
      end;
    CB_ALLY:
      case scancode of
        SDL_SCANCODE_UP, SDL_SCANCODE_LEFT:   CombatCycleAlly(-1);
        SDL_SCANCODE_DOWN, SDL_SCANCODE_RIGHT: CombatCycleAlly(1);
        SDL_SCANCODE_RETURN, SDL_SCANCODE_SPACE: begin
          if pendingItem >= 0 then
            ActUseItem(pendingItem, allySel)
          else
            ActCast(pendingSpell, allySel);
          PlaySfx(SFX_SELECT);
          CombatToCommand;
        end;
        SDL_SCANCODE_ESCAPE: CombatBack;
      end;
  end;

  if Active^.CombatOver and (not Active^.Victory) and (not Active^.Fled) then PlaySfx(SFX_DOWN);
end;

procedure EnterCombat;
{** Reset the combat menu and hand control to the fight. }
begin
  cbMenu := CB_COMMAND;
  cmdSel := CMD_ATTACK;
  spellSel := 0;
  skillSel := 0;
  pendingSkill := -1;
  allySel := 0;
  pendingSpell := -1;
  itemSel := 0;
  pendingItem := -1;
  { fighting in the dark: a fight-long to-hit penalty when the torch is low }
  if TorchGlow < DARK_GLOW then Active^.PartyDark := DARK_ATK else Active^.PartyDark := 0;
  PlaySfx(SFX_FOE);
  State := gsCombat;
end;

procedure StartCombat(depth: longint);
begin
  BossRewardFlag := '';
  StartRandomEncounter(depth, CurEncTable);
  EnterCombat;
end;

procedure StartMonsterCombat(leadMon, depth: longint);
{** Begin a fight led by a specific monster, for a roaming pursuer that has
  caught the party. }
begin
  BossRewardFlag := '';
  StartMonsterEncounter(leadMon, depth, CurEncTable);
  EnterCombat;
end;

procedure StartBossCombat(leadMon, depth: longint; const winFlag: string);
{** Begin a scripted boss fight led by a named monster. Winning raises
  winFlag, which the quest reads to grant a reward. }
begin
  BossRewardFlag := winFlag;
  StartMonsterEncounter(leadMon, depth, CurEncTable);
  EnterCombat;
end;

procedure FoeAnimTick(dt: double);
{** Resolve each living foe's sprite once, then advance its idle animation.
  A foe on a plain (non-bank) sprite, or a single-frame bank, does not move. }
var i, mi, sq: longint;
begin
  for i := 0 to High(Active^.Foes) do begin
    if not Active^.Foes[i].alive then continue;
    if Active^.Foes[i].spriteIdx = -2 then begin
      mi := LoadSprite(GamePak, MonDefs[Active^.Foes[i].def].model);
      Active^.Foes[i].spriteIdx := mi;
      if (mi >= 0) and SpriteReg[mi].isBank then begin
        sq := SpriteSeqIndex(mi, 'IDLE');
        if sq < 0 then sq := 0;
        CursorStart(Active^.Foes[i].anim, sq);
        Active^.Foes[i].anim.clock := i * 0.13;   { desync identical foes }
      end;
    end;
    mi := Active^.Foes[i].spriteIdx;
    if (mi >= 0) and SpriteReg[mi].isBank then
      CursorTick(SpriteReg[mi].bank, Active^.Foes[i].anim, dt);
  end;
end;

procedure CombatAutoTurn(dt: double);
{** Advance the combat clock, then, if the member now up has lost control
  to the were-beast, take its turn for it. Pacing handles the rest. }
begin
  CombatUpdate(dt);
  FoeAnimTick(dt);
  if Active^.CombatSfxCue = CUE_HIT then PlaySfx(SFX_HIT);
  Active^.CombatSfxCue := CUE_NONE;
  if (Active^.CombatPhase = CP_INPUT) and (not Active^.CombatOver)
    and (Active^.CurActor >= 0) and (Active^.CurActor <= High(Roster))
    and Roster[Active^.CurActor].wereform and Roster[Active^.CurActor].alive
    and (not Roster[Active^.CurActor].downed) then begin
    ActAttack;
    PlaySfx(SFX_HIT);
    { back-rank with nothing in reach: guard so the turn still passes }
    if (Active^.CombatPhase = CP_INPUT) and (not Active^.CombatOver) then ActGuard;
  end;
end;

end.
