unit dialogui;

{** The dialog state: render an NPC conversation over the frozen view,
  take a numbered choice, turn new quest flags into journal lines, and
  route on to a shop, victory or back to exploration. }

{$mode objfpc}{$H+}

interface

procedure DialogRender;
procedure DialogKeyDown(scancode: longint);

implementation

uses
  sysutils, sdl2min, gfx, raycast, polyrender, dialog, flags, uihelp,
  gamestate, party, settings, combatui, monsters;

procedure DialogRender;
var
  i, py, n: longint;
begin
  if UsePoly then RenderViewPoly else RenderView;
  FillRectBlend(0, 0, FBW, FBH, RGB(0, 0, 0), 120);
  py := 118;
  FillRectBlend(8, py, FBW - 16, FBH - py - 8, RGB(14, 12, 20), 230);
  FrameRect(8, py, FBW - 16, FBH - py - 8, RGB(120, 110, 90));
  DrawText(16, py + 6, dlgNpcName, RGB(230, 210, 140));
  if DlgActive then begin
    DrawWrapped(16, py + 20, 48, Convs[DlgConv].nodes[DlgNode].text,
      RGB(205, 205, 190));
    n := DialogRespCount;
    for i := 0 to n - 1 do
      DrawText(20, py + 56 + i * 11,
        IntToStr(i + 1) + ') ' + DialogRespText(i), RGB(170, 200, 170));
  end;
  { a service result lingers a moment at the foot of the box }
  if saveMsgT > 0 then
    DrawText(16, FBH - 16, saveMsg, RGB(230, 210, 140));
end;

procedure SyncJournal;
{** Turn freshly set quest flags into journal lines, once each, and derive the
  assembled-relic flag once all three shards are in hand. }
begin
  if FlagHas('QUEST_MAIN') and (not FlagHas('J_MAIN')) then begin
    JournalAdd('Gather the three relic shards: crypt, cave, and the infernal deep.');
    FlagSet('J_MAIN');
  end;
  if FlagHas('QUEST_CRYPT') and (not FlagHas('J_CRYPT')) then begin
    JournalAdd('Clear the crypt beneath the town for the reeve.');
    FlagSet('J_CRYPT');
  end;
  if FlagHas('SHARD_CRYPT') and (not FlagHas('J_SHARD_CRYPT')) then begin
    JournalAdd('Took the crypt shard from its shrine.');
    FlagSet('J_SHARD_CRYPT');
  end;
  if FlagHas('SHARD_CAVE') and (not FlagHas('J_SHARD_CAVE')) then begin
    JournalAdd('Took the cave shard from the grotto.');
    FlagSet('J_SHARD_CAVE');
  end;
  if FlagHas('SHARD_INFER') and (not FlagHas('J_SHARD_INFER')) then begin
    JournalAdd('Tore the last shard from the demon lord.');
    FlagSet('J_SHARD_INFER');
  end;
  { all three shards assembled: the relic is whole }
  if FlagHas('SHARD_CRYPT') and FlagHas('SHARD_CAVE') and FlagHas('SHARD_INFER')
    and (not FlagHas('QUEST_RELIC')) then begin
    FlagSet('QUEST_RELIC');
    JournalAdd('The relic is whole. Return it to the elder.');
  end;
end;

procedure DialogAfterChoice;
var
  raised: longint;
begin
  SyncJournal;
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
