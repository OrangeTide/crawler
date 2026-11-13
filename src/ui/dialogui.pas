unit dialogui;

{** The dialog state: render an NPC conversation over the frozen view,
  take a numbered choice, turn new quest flags into journal lines, and
  route on to a shop, victory or back to exploration. }

{$mode objfpc}{$H+}

interface

procedure DialogRender;
procedure RenderDialogGL;
procedure DialogKeyDown(scancode: longint);

implementation

uses
  sysutils, sdl2min, gfx, polyrender, glrender, video, dialog, flags, uihelp,
  gamestate, party, settings, combatui, monsters, gametime, rng, sprites, pic,
  spellbook, pcportrait, chardata, quests;

{ Blit a portrait image at its native size, skipping the keyed background. }
procedure DrawPortrait(px, py: longint; const img: TImage);
var
  x, y: longint;
  c: TColor;
begin
  for y := 0 to img.h - 1 do
    for x := 0 to img.w - 1 do begin
      c := img.pix[y * img.w + x];
      if (c shr 24) < 128 then continue;
      PutPixel(px + x, py + y, c);
    end;
end;

{ Draw the dialog panel (box, portrait and text) into the framebuffer. solidBg
  fills the box backgrounds opaque, for the GPU path that composites the panel
  over the GL scene by colour key; the software path blends them over the
  software-rendered scene. }
procedure DrawDialogPanel(solidBg: boolean);
var
  i, py, n, pi, tx, tw: longint;

  procedure BoxFill(x, y, w, h: longint; c: TColor; alpha: byte);
  begin
    if solidBg then FillRect(x, y, w, h, c)
    else FillRectBlend(x, y, w, h, c, alpha);
  end;

begin
  py := 118;
  BoxFill(8, py, FBW - 16, FBH - py - 8, RGB(14, 12, 20), 230);
  FrameRect(8, py, FBW - 16, FBH - py - 8, RGB(120, 110, 90));

  { an NPC with a PORT_<dialog-id> portrait lump shows a framed face on the
    left, and the text makes room for it; speakers with none keep the full
    width (a shrine, an altar, and such name no portrait) }
  pi := LoadSprite(GamePak, 'PORT_' + UpperCase(dlgId));
  if pi >= 0 then begin
    BoxFill(14, py + 6, 64, 64, RGB(0, 0, 0), 190);
    FrameRect(14, py + 6, 64, 64, RGB(120, 110, 90));
    DrawPortrait(14, py + 6, SpriteReg[pi].img);
    tx := 86; tw := 36;
  end else begin
    tx := 16; tw := 48;
  end;

  DrawText(tx, py + 6, dlgNpcName, RGB(230, 210, 140));
  if DlgActive then begin
    DrawWrapped(tx, py + 20, tw, Convs[DlgConv].nodes[DlgNode].text,
      RGB(205, 205, 190));
    n := DialogRespCount;
    for i := 0 to n - 1 do
      DrawText(tx + 4, py + 56 + i * 11,
        IntToStr(i + 1) + ') ' + DialogRespText(i), RGB(170, 200, 170));
  end;
  { a service result lingers a moment at the foot of the box }
  if saveMsgT > 0 then
    DrawText(16, FBH - 16, saveMsg, RGB(230, 210, 140));
end;

{ Software path: render the scene, veil it, and blend the panel over it. }
procedure DialogRender;
begin
  RenderViewPoly;
  FillRectBlend(0, 0, FBW, FBH, RGB(0, 0, 0), 120);
  DrawDialogPanel(false);
end;

{ GPU path: render the scene on the GPU, dim it with a GL veil, then composite
  the opaque panel over it through the colour-keyed 2D layer. }
procedure RenderDialogGL;
begin
  GLTrueColour := SetGLTrueColour;
  RenderViewGL;                      { GPU scene into the default framebuffer }
  GLDimScene(120.0 / 255.0);         { the veil, matching the software blend }
  ClearFB(RGB(255, 0, 255));         { the 2D layer; magenta reads transparent }
  DrawDialogPanel(true);
  VideoPresentHud;                   { composite the panel over the dimmed scene }
  VideoSwap;
end;

procedure DialogAfterChoice;
var
  raised, cost: longint;
  wasFirst: boolean;
begin
  QuestsUpdate;   { derive composite flags and append new journal lines }
  if FlagHas('QUEST_WON') then begin
    State := gsVictory;
    exit;
  end;
  if DlgReviveReq then begin
    DlgReviveReq := false;
    if SetPermadeath then
      saveMsg := 'THE FALLEN DO NOT RETURN'
    else begin
      raised := TempleRevive;
      if raised > 0 then saveMsg := 'THE TEMPLE RAISES ' + IntToStr(raised)
      else saveMsg := 'NONE TO RAISE, OR NO COIN';
    end;
    saveMsgT := 2.5;
    exit;   { stay in the talk so the result shows }
  end;
  if DlgIdentifyReq then begin
    DlgIdentifyReq := false;
    raised := IdentifyParty;
    if raised > 0 then saveMsg := 'THE TEMPLE NAMES ' + IntToStr(raised)
    else saveMsg := 'NOTHING UNKNOWN, OR NO COIN';
    saveMsgT := 2.5;
    exit;
  end;
  if DlgRecruitReq then begin
    DlgRecruitReq := false;
    cost := HireCost;
    wasFirst := HirelingCount = 0;
    if RecruitHireling(NamePool[Range(0, High(NamePool))]) then begin
      { a hired caster comes already knowing its spells, and a random face }
      Roster[High(Roster)].portrait := PCPortraitClamp(Range(0, PCPortraitCount - 1));
      AutoLearn(Roster[High(Roster)]);
      if wasFirst then WagesDueClock := ClockMin + LUNAR_MINUTES;
      saveMsg := 'A SWORD-ARM JOINS FOR ' + IntToStr(cost) + ' GOLD';
    end else
      saveMsg := 'NO ROOM, OR NO COIN FOR A HIRE';
    saveMsgT := 2.5;
    exit;
  end;
  if DlgFightReq then begin
    DlgFightReq := false;
    StartBossCombat(MonIndex(DlgFightMon), CurDepth, DlgFightFlag);
    exit;   { StartBossCombat sets the state to gsCombat }
  end;
  if DlgShopReq then begin
    shopSel := 0;
    shopStock := DlgShopId;
    State := gsShop;
  end else if not DlgActive then
    State := gsExplore;
end;

procedure DialogKeyDown(scancode: longint);
var
  pick: longint;
begin
  pick := -1;
  case scancode of
    SDL_SCANCODE_1: pick := 0;
    SDL_SCANCODE_2: pick := 1;
    SDL_SCANCODE_3: pick := 2;
    SDL_SCANCODE_4: pick := 3;
    SDL_SCANCODE_5: pick := 4;
    SDL_SCANCODE_ESCAPE: begin DlgActive := false; State := gsExplore; exit; end;
  end;
  if (pick >= 0) and (pick < DialogRespCount) then begin
    DialogChoose(pick);
    DialogAfterChoice;
  end;
end;

end.
