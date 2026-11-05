unit game;

{** Top-level game state machine.

  The game is a set of states (title, exploration, combat, and so on).
  One state is active at a time. This unit owns the active state, routes
  input to it, advances it each frame and renders it. The platform layer
  in crawler.lpr only pumps SDL and uploads the framebuffer.

  For now only the exploration state is implemented, so behaviour matches
  the earlier single-loop build: walk the dungeon, look with the mouse,
  open doors and toggle the automap. The other states are declared so the
  later systems have a place to attach. }

{$mode objfpc}{$H+}

interface

function GameInit: boolean;
procedure GameHandleEvents;
procedure GameUpdate(dt: double);
procedure GameRender(fps: longint);
{ Jump a pregen party straight into a test encounter (menu / --combat). }
procedure QuickBattle;

implementation

uses
  sysutils, sdl2min, gfx, pak, mapfmt, world, raycast, polyrender, models,
  raster, meshfmt, hud, textures, rng, rules, items, chardata, party, monsters,
  combat, flags, dialog, shops, encounters, mapstate, save, worldfmt, mapgen,
  overworld, worldname, worldarea, gamestate, uihelp, worldload, combatui,
  exploreui, charcreateui, titleui, gametime, audio;

procedure QuickBattle;
{** Delegate to titleui so crawler.lpr's bare QuickBattle still resolves. }
begin
  titleui.QuickBattle;
end;

{ ---- Dialog state ---- }

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
end;

procedure SyncJournal;
{** Turn freshly set quest flags into journal lines, once each. }
begin
  if FlagHas('QUEST_MAIN') and (not FlagHas('J_MAIN')) then begin
    JournalAdd('Aid the town against the things from the deep.');
    FlagSet('J_MAIN');
  end;
  if FlagHas('QUEST_CRYPT') and (not FlagHas('J_CRYPT')) then begin
    JournalAdd('Clear the crypt beneath the town for the reeve.');
    FlagSet('J_CRYPT');
  end;
  if FlagHas('QUEST_RELIC') and (not FlagHas('J_RELIC')) then begin
    JournalAdd('Recovered the relic shard. Return it to the elder.');
    FlagSet('J_RELIC');
  end;
end;

procedure DialogAfterChoice;
begin
  SyncJournal;
  if FlagHas('QUEST_WON') then begin
    State := gsVictory;
    exit;
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

{ ---- Shop state ---- }

{ The number of items the open shop stocks, from its data list. }
function BuyableCount: longint;
var s: longint;
begin
  BuyableCount := 0;
  s := ShopIndex(shopStock);
  if s < 0 then exit;
  BuyableCount := Length(ShopDefs[s].items);
end;

{ The ItemDefs index of the idx-th item in the open shop's stock, or -1. }
function NthBuyable(idx: longint): longint;
var s: longint;
begin
  NthBuyable := -1;
  s := ShopIndex(shopStock);
  if s < 0 then exit;
  if (idx < 0) or (idx >= Length(ShopDefs[s].items)) then exit;
  NthBuyable := ItemIndex(ShopDefs[s].items[idx]);
end;

procedure ShopRender;
var
  i, cnt, di, y: longint;
  c: TColor;
begin
  ClearFB(RGB(12, 10, 14));
  if dlgNpcName <> '' then DrawText(12, 8, UpperCase(dlgNpcName), RGB(220, 200, 120))
  else DrawText(12, 8, 'SHOP', RGB(220, 200, 120));
  DrawText(FBW - 120, 8, 'GOLD ' + IntToStr(PartyGold), RGB(220, 200, 120));
  cnt := BuyableCount;
  y := 26;
  for i := 0 to cnt - 1 do begin
    di := NthBuyable(i);
    if di < 0 then continue;      { an item id the table does not know }
    if i = shopSel then begin
      c := RGB(240, 230, 150);
      DrawText(10, y, '>', c);
    end else
      c := RGB(180, 180, 160);
    DrawText(18, y, ItemDefs[di].name, c);
    DrawText(180, y, IntToStr(ItemDefs[di].value) + ' GP', c);
    inc(y, 11);
    if y > FBH - 24 then break;
  end;
  DrawText(12, FBH - 14, 'ARROWS SELECT  ENTER BUY  ESC LEAVE', RGB(140, 150, 120));
end;

procedure ShopKeyDown(scancode: longint);
var
  cnt, di: longint;
begin
  cnt := BuyableCount;
  case scancode of
    SDL_SCANCODE_UP:   if shopSel > 0 then dec(shopSel);
    SDL_SCANCODE_DOWN: if shopSel < cnt - 1 then inc(shopSel);
    SDL_SCANCODE_RETURN, SDL_SCANCODE_SPACE: begin
      di := NthBuyable(shopSel);
      if (di >= 0) and (PartyGold >= ItemDefs[di].value) and (Length(Roster) > 0) then
      begin
        PartyGold := PartyGold - ItemDefs[di].value;
        PackAdd(Roster[0], ItemDefs[di].id, 1);
        PlaySfx(SFX_PICK);
      end;
    end;
    SDL_SCANCODE_ESCAPE: begin
      DlgShopReq := false;
      if DlgActive then State := gsDialog else State := gsExplore;
    end;
  end;
end;

{ ---- Full map state ---- }

procedure FullMapKeyDown(scancode: longint);
begin
  case scancode of
    SDL_SCANCODE_TAB, SDL_SCANCODE_ESCAPE, SDL_SCANCODE_M:
      State := gsExplore;
  end;
end;

{ ---- Journal state ---- }

procedure JournalRender;
var
  i, y: longint;
begin
  ClearFB(RGB(10, 10, 16));
  DrawText(12, 10, 'JOURNAL', RGB(220, 200, 120));
  if Length(Journal) = 0 then
    DrawText(16, 30, 'No quests recorded yet.', RGB(150, 150, 130))
  else begin
    y := 30;
    for i := 0 to High(Journal) do begin
      DrawWrapped(16, y, 48, '- ' + Journal[i], RGB(195, 200, 180));
      inc(y, 22);
    end;
  end;
  DrawText(12, FBH - 14, 'J OR ESC TO CLOSE', RGB(130, 140, 110));
end;

procedure JournalKeyDown(scancode: longint);
begin
  case scancode of
    SDL_SCANCODE_J, SDL_SCANCODE_ESCAPE: State := gsExplore;
  end;
end;

{ ---- Game over state ---- }

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

{ ---- Options state ---- }

procedure OptionsRender;
const
  LABELS: array[0 .. 2] of string = ('MASTER', 'MUSIC', 'SFX');
var
  i, y, v: longint;
  c: TColor;
begin
  ClearFB(RGB(12, 12, 16));
  DrawCenter(20, 'OPTIONS', RGB(220, 200, 120));
  y := 60;
  for i := 0 to 2 do begin
    if i = optSel then c := RGB(240, 230, 150) else c := RGB(160, 160, 140);
    DrawText(60, y, LABELS[i], c);
    case i of
      0: v := volMaster;
      1: v := volMusic;
    else v := volSfx;
    end;
    FillRect(130, y, 102, 7, RGB(40, 40, 46));
    FillRect(131, y + 1, v, 5, RGB(90, 160, 110));
    DrawText(240, y, IntToStr(v), c);
    inc(y, 20);
  end;
  DrawCenter(FBH - 20, 'ARROWS ADJUST   ESC BACK', RGB(130, 140, 110));
end;

procedure OptionsKeyDown(scancode: longint);
var
  delta: longint;
begin
  delta := 0;
  case scancode of
    SDL_SCANCODE_UP:   if optSel > 0 then dec(optSel);
    SDL_SCANCODE_DOWN: if optSel < 2 then inc(optSel);
    SDL_SCANCODE_LEFT:  delta := -10;
    SDL_SCANCODE_RIGHT: delta := 10;
    SDL_SCANCODE_ESCAPE: begin State := gsTitle; exit; end;
  end;
  if delta <> 0 then begin
    case optSel of
      0: volMaster := volMaster + delta;
      1: volMusic := volMusic + delta;
    else volSfx := volSfx + delta;
    end;
    if volMaster < 0 then volMaster := 0; if volMaster > 100 then volMaster := 100;
    if volMusic < 0 then volMusic := 0;   if volMusic > 100 then volMusic := 100;
    if volSfx < 0 then volSfx := 0;        if volSfx > 100 then volSfx := 100;
    SetAudioVolumes(volMaster, volMusic, volSfx);
    PlaySfx(SFX_SELECT);
  end;
end;

{ ---- Victory state ---- }

procedure VictoryRender;
begin
  ClearFB(RGB(8, 14, 10));
  DrawCenter(80, 'THE DEEP IS SEALED', RGB(230, 220, 140));
  DrawCenter(96, 'THE TOWN IS SAVED', RGB(180, 200, 160));
  DrawCenter(120, 'PRESS A KEY', RGB(140, 150, 120));
end;

procedure VictoryKeyDown(scancode: longint);
begin
  titleSel := 0;
  State := gsTitle;
end;

{ ---- State machine entry points ---- }

function FindPak: string;
{** Look for game.pak next to the binary, then in common run dirs. }
var
  base: string;
begin
  base := ExtractFilePath(ParamStr(0));
  if FileExists(base + 'game.pak') then
    FindPak := base + 'game.pak'
  else if FileExists('game.pak') then
    FindPak := 'game.pak'
  else if FileExists('build/game.pak') then
    FindPak := 'build/game.pak'
  else
    FindPak := '';
end;

function GameInit: boolean;
var
  pakPath: string;
begin
  GameInit := false;
  pakPath := FindPak;
  if pakPath = '' then begin
    writeln(StdErr, 'game: could not find game.pak (run make to build it)');
    exit;
  end;
  if not PakLoad(pakPath, GamePak) then begin
    writeln(StdErr, 'game: could not load ', pakPath);
    exit;
  end;
  if not LoadTextures(GamePak) then begin
    writeln(StdErr, 'game: missing or bad textures in ', pakPath);
    exit;
  end;
  if not LoadItems(GamePak) then begin
    writeln(StdErr, 'game: missing or bad item table in ', pakPath);
    exit;
  end;
  if not LoadCharData(GamePak) then begin
    writeln(StdErr, 'game: missing species/class/background tables in ', pakPath);
    exit;
  end;
  if not LoadMonsters(GamePak) then begin
    writeln(StdErr, 'game: missing monster table in ', pakPath);
    exit;
  end;
  LoadDialogs(GamePak);   { optional; dialogs just will not open if absent }
  LoadShops(GamePak);     { optional; shop stock lists }
  LoadEncounters(GamePak); { optional; per-area encounter tables }
  LoadWorld(GamePak);     { optional; dynamic-map manifest }
  LoadModels(GamePak);    { optional; polygon-renderer props }

  TimeReset;
  MoonOffsetDays := (WorldSeed mod 2953) / 100.0;  { seed the moon phase }

  AudioInit(GamePak);   { silent if the device or libxmp is absent }
  volMaster := 80; volMusic := 55; volSfx := 90;
  SetAudioVolumes(volMaster, volMusic, volSfx);
  keys := PKeyArray(SDL_GetKeyboardState(nil));
  showMap := true;
  QuitRequested := false;
  cursorX := FBW div 2;
  cursorY := FBH div 2;
  rmbHeld := false;
  titleSel := 0;
  State := gsTitle;
  GameInit := true;
end;

procedure GameHandleEvents;
var
  ev: TSDL_Event;
begin
  while SDL_PollEvent(@ev) <> 0 do begin
    case ev.kind of
      SDL_QUITEV:
        QuitRequested := true;
      SDL_KEYDOWN:
        case State of
          gsTitle:    TitleKeyDown(ev.key.keysym.scancode);
          gsNewParty: CCKeyDown(ev.key.keysym.scancode);
          gsExplore:  ExploreKeyDown(ev.key.keysym.scancode);
          gsFullMap:  FullMapKeyDown(ev.key.keysym.scancode);
          gsDialog:   DialogKeyDown(ev.key.keysym.scancode);
          gsShop:     ShopKeyDown(ev.key.keysym.scancode);
          gsMenu:     JournalKeyDown(ev.key.keysym.scancode);
          gsCombat:   CombatKeyDown(ev.key.keysym.scancode);
          gsGameOver: GameOverKeyDown(ev.key.keysym.scancode);
          gsVictory:  VictoryKeyDown(ev.key.keysym.scancode);
          gsOptions:  OptionsKeyDown(ev.key.keysym.scancode);
        end;
      SDL_MOUSEMOTION:
        case State of
          gsExplore: ExploreMouseMotion(ev.motion.xrel, ev.motion.yrel);
        end;
      SDL_MOUSEBUTTONDOWN:
        case State of
          gsExplore: ExploreMouseButton(true, ev.button.button);
        end;
      SDL_MOUSEBUTTONUP:
        case State of
          gsExplore: ExploreMouseButton(false, ev.button.button);
        end;
    end;
  end;
end;

procedure GameUpdate(dt: double);
begin
  UpdateLycanthropy;   { the moon acts in every state }
  case State of
    gsExplore: ExploreUpdate(dt);
    gsCombat:  CombatAutoTurn(dt);
  end;
end;

procedure UpdateMusic;
begin
  case State of
    gsTitle, gsNewParty: PlayMusic(MUS_TITLE);
    gsCombat:            PlayMusic(MUS_COMBAT);
    gsGameOver:          StopMusic;
  else
    if CurMapName = 'TOWN' then PlayMusic(MUS_TOWN)
    else PlayMusic(MUS_DUNGEON);
  end;
end;

procedure GameRender(fps: longint);
begin
  UpdateMusic;
  case State of
    gsTitle:    TitleRender;
    gsNewParty: CCRender;
    gsExplore:  ExploreRender(fps);
    gsFullMap:  DrawFullMap;
    gsDialog:   DialogRender;
    gsShop:     ShopRender;
    gsMenu:     JournalRender;
    gsCombat:   CombatRender;
    gsGameOver: GameOverRender;
    gsVictory:  VictoryRender;
    gsOptions:  OptionsRender;
  end;
end;

end.
