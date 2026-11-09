program shot;

{** Headless screenshot tool.

  Drives the real game offscreen and writes its framebuffer to a PPM.
  SDL runs on the "dummy" video driver, so no window, display or GPU is
  needed and it works in a headless or sandboxed environment. The tool
  reuses the game's own init and render paths, so a shot shows exactly
  what the app would draw for that state.

  Usage:
    shot <out.ppm> title
    shot <out.ppm> combat [DEPTH]
    shot <out.ppm> world
    shot <out.ppm> menu [TAB]   (0 journal, 1 bestiary, 2 spells)
    shot <out.ppm> castmenu     (a quick battle with the Wizard's spell list open)
    shot <out.ppm> skillmenu    (a quick battle with a fighter's maneuver list open)
    shot <out.ppm> learn        (the level-up learn-a-spell screen for a caster)
    shot <out.ppm> dialog <ID>  (an NPC dialog, to frame its portrait)
    shot <out.ppm> create       (the character-creation screen)
    shot <out.ppm> sheet [N]    (the character sheet for party member N)
    shot <out.ppm> fieldcast [cast]   (the SPELLS tab field-casting; cast opens the picker)
    shot <out.ppm> map <MAP> <X> <Y> <N|E|S|W>
    shot <out.ppm> foe <MAP> <X> <Y> <N|E|S|W> <MON> <MX> <MY>

  'map' starts a pregen party, switches to the named map lump, and
  stands the party on tile X,Y facing the given cardinal, which is how
  the per-map NPC and entity sprites are framed for inspection. 'foe'
  does the same and places a monster MON on tile MX,MY so it appears as
  a billboard down the corridor. 'combat' takes an optional depth, deeper
  being more and bigger foes. }

{$mode objfpc}{$H+}

uses
  sysutils, classes, sdl2min, gfx, gamestate, game, world, worldload,
  mapfmt, monsters, pursuit, titleui, combat, combatui, combatstate, party, chardata,
  dialog, charcreateui, spellbook, miscui, spelldb, fieldcast,
  skilldb, skillbook, rules, textures, roomdb, polyrender, math;

procedure DumpPPM(const fn: string);
var
  fs: TFileStream;
  hdr: string;
  row: array of byte;
  i: longint;
  c: TColor;
begin
  SetLength(row, FBW * FBH * 3);
  for i := 0 to FBW * FBH - 1 do begin
    c := Palette[FB[i]];
    row[i * 3]     := (c shr 16) and $FF;
    row[i * 3 + 1] := (c shr 8) and $FF;
    row[i * 3 + 2] := c and $FF;
  end;
  hdr := Format('P6'#10'%d %d'#10'255'#10, [FBW, FBH]);
  fs := TFileStream.Create(fn, fmCreate);
  try
    fs.WriteBuffer(hdr[1], Length(hdr));
    fs.WriteBuffer(row[0], Length(row));
  finally
    fs.Free;
  end;
end;

function DirCode(const s: string): longint;
begin
  case UpCase(s[1]) of
    'N': DirCode := DIR_N;
    'E': DirCode := DIR_E;
    'S': DirCode := DIR_S;
    'W': DirCode := DIR_W;
  else
    DirCode := DIR_E;
  end;
end;

{ Build a hand-made two-sector map to prove the renderer draws height: a
  flat room with a sunken square pit and a raised dais, so the polygon path
  shows floor risers, ceiling lintels and the eye riding the sector floor. }
procedure BuildSectorDemo(out m: TMapData);
var
  x, y, i: longint;
begin
  m.w := 14; m.h := 14;
  m.tileset := 4; m.music := 0; m.flags := 0; m.area := 0;
  SetLength(m.walls, m.w * m.h);
  SetLength(m.cellSector, m.w * m.h);
  m.markers := nil; m.portals := nil; m.doors := nil; m.npcs := nil;
  m.traps := nil; m.lights := nil; m.props := nil; m.loot := nil;

  SetLength(m.sectors, 3);
  m.sectors[0].floorZ := 0;  m.sectors[0].ceilZ := 16;  { the main room }
  m.sectors[0].tileset := 0; m.sectors[0].light := 0;
  m.sectors[1].floorZ := -12; m.sectors[1].ceilZ := 16;  { a sunken pit }
  m.sectors[1].tileset := 0; m.sectors[1].light := 0;
  m.sectors[2].floorZ := 6;  m.sectors[2].ceilZ := 16;  { a raised dais }
  m.sectors[2].tileset := 0; m.sectors[2].light := 0;

  for y := 0 to m.h - 1 do
    for x := 0 to m.w - 1 do begin
      i := y * m.w + x;
      if (x = 0) or (y = 0) or (x = m.w - 1) or (y = m.h - 1) then begin
        m.walls[i] := 2;                 { stone border wall }
        m.cellSector[i] := SECTOR_NONE;
      end else begin
        m.walls[i] := TILE_EMPTY;
        m.cellSector[i] := 0;            { the main room by default }
      end;
    end;
  for y := 3 to 6 do for x := 3 to 6 do m.cellSector[y * m.w + x] := 1;   { pit }
  for y := 8 to 10 do for x := 8 to 10 do m.cellSector[y * m.w + x] := 2;  { dais }
end;

var
  outPath, scene: string;
  mi, ci, nd: longint;
  doGameRender: boolean;
  room: TRoom;
  roomFn: string;
  rls: TStringList;
  camA: double;
  secMap: TMapData;
begin
  doGameRender := true;
  if ParamCount < 2 then begin
    writeln(StdErr, 'usage: shot <out.ppm> title|combat|world|map ...');
    halt(2);
  end;
  outPath := ParamStr(1);
  scene := LowerCase(ParamStr(2));

  if not LoadSDL2 then begin
    writeln(StdErr, 'shot: could not load SDL2'); halt(1);
  end;
  { Force the dummy video driver: SDL then needs no display or GPU. }
  SDL_SetHint('SDL_VIDEODRIVER', 'dummy');
  if SDL_Init(SDL_INIT_VIDEO) <> 0 then begin
    writeln(StdErr, 'shot: SDL_Init failed: ', SDL_GetError()); halt(1);
  end;

  InitGfx;
  if not GameInit then begin
    writeln(StdErr, 'shot: GameInit failed (is build/game.pak present?)');
    halt(1);
  end;

  if scene = 'title' then
    { GameInit already leaves the state at the title }
  else if scene = 'combat' then begin
    if ParamCount >= 3 then QuickBattleDepth(StrToInt(ParamStr(3)))
    else QuickBattle;
  end
  else if scene = 'world' then
    QuickStart
  else if scene = 'create' then begin
    { the character-creation screen, to frame the portrait picker. An optional
      count presses P that many times to cycle the face forward. }
    CCStartNewParty;
    State := gsNewParty;
    if ParamCount >= 3 then
      for mi := 1 to StrToInt(ParamStr(3)) do CCKeyDown(SDL_SCANCODE_P);
  end
  else if scene = 'sheet' then begin
    { the character sheet for a party member (default the first). An optional
      level raises that member and relearns, to fill the spell browser. }
    QuickStart;
    if ParamCount >= 3 then sheetSel := StrToInt(ParamStr(3)) else sheetSel := 0;
    if (ParamCount >= 4) and (sheetSel <= High(Roster)) then begin
      Roster[sheetSel].level := StrToInt(ParamStr(4));
      SetLength(Roster[sheetSel].known, 0);
      AutoLearn(Roster[sheetSel]);
    end;
    sheetSpellSel := 0;
    State := gsCharSheet;
  end
  else if scene = 'menu' then begin
    QuickStart;             { a party, so the spells tab has casters }
    State := gsMenu;
    if ParamCount >= 3 then menuTab := StrToInt(ParamStr(3)) else menuTab := 0;
  end
  else if scene = 'fieldcast' then begin
    { the SPELLS tab set up to field-cast: the first caster is raised and
      relearns so it knows cures, a member is wounded to mend, and the cursor
      is driven to the first field-castable spell. A 'cast' argument then opens
      the member picker. }
    QuickStart;
    ci := -1;
    for mi := 0 to High(Roster) do
      if (ci < 0) and CharIsCaster(Roster[mi]) then ci := mi;
    if ci >= 0 then begin
      Roster[ci].level := 6;
      SetLength(Roster[ci].known, 0);
      AutoLearn(Roster[ci]);
      Roster[ci].sp := CharSpellPoints(Roster[ci]);
    end;
    if High(Roster) >= 1 then Roster[1].hp := Roster[1].hpMax div 2;
    State := gsMenu;
    menuTab := 2;
    { step the cursor down to the first spell with a field effect }
    if ci >= 0 then begin
      nd := -1;
      for mi := 0 to KnownCount(Roster[ci]) - 1 do
        if (nd < 0) and (FieldCastKind(KnownNth(Roster[ci], mi)) <> FE_NONE) then
          nd := mi;
      if nd > 0 then
        for mi := 1 to nd do JournalKeyDown(SDL_SCANCODE_DOWN);
    end;
    if (ParamCount >= 3) and (LowerCase(ParamStr(3)) = 'cast') then
      JournalKeyDown(SDL_SCANCODE_RETURN);   { open the member picker }
  end
  else if scene = 'skills' then begin
    { a thief with trained skills and slots to spare, on the character sheet. A
      'train' argument opens the learn-a-skill screen instead. }
    QuickStart;
    ci := 0;
    Roster[ci].klass := ClassIndex('THIEF');
    Roster[ci].level := 5;
    Roster[ci].skillSlots := 10;
    LearnSkill(Roster[ci], SkillByID('SK_PICKLOCK'));
    LearnSkill(Roster[ci], SkillByID('SK_PICKLOCK'));   { rank it up }
    LearnSkill(Roster[ci], SkillByID('SK_FINDTRAPS'));
    LearnSkill(Roster[ci], SkillByID('SK_MOVESILENT'));
    LearnSkill(Roster[ci], SkillByID('SK_MEND'));
    LearnSkill(Roster[ci], SkillByID('SK_MEND'));   { rank it so aid lands }
    LearnSkill(Roster[ci], SkillByID('SK_MEND'));
    Roster[ci].abil[abWIS] := 18;
    Roster[ci].hp := 3;   { wounded, so First Aid has something to mend }
    sheetSel := ci; sheetSpellSel := 0;
    State := gsCharSheet;
    if (ParamCount >= 3) and (LowerCase(ParamStr(3)) = 'train') then begin
      skillActor := ci; skillTrainSel := 0; State := gsLearnSkill;
    end else if (ParamCount >= 3) and (LowerCase(ParamStr(3)) = 'aid') then
      CharSheetKeyDown(SDL_SCANCODE_A);   { tend the wounded member }
  end
  else if scene = 'skillmenu' then begin
    { a quick battle, then reclass the first member to a fighter, train it in a
      few maneuvers, and open the SKILL submenu to frame the maneuver list }
    QuickBattle;
    if High(Roster) >= 0 then begin
      ci := 0;
      Roster[ci].klass := ClassIndex('FIGHTER');
      Roster[ci].level := 5;
      Roster[ci].skillSlots := 10;
      LearnSkill(Roster[ci], SkillByID('SK_POWERATTACK'));
      LearnSkill(Roster[ci], SkillByID('SK_DISARM'));
      LearnSkill(Roster[ci], SkillByID('SK_RALLY'));
      CurActor := ci;
    end;
    CombatKeyDown(SDL_SCANCODE_DOWN);     { ATTACK -> CAST }
    CombatKeyDown(SDL_SCANCODE_DOWN);     { CAST -> SKILL }
    CombatKeyDown(SDL_SCANCODE_RETURN);   { open the maneuver list }
    if (ParamCount >= 3) and (LowerCase(ParamStr(3)) = 'go') then begin
      CombatKeyDown(SDL_SCANCODE_RETURN); { pick Power Attack, go to target }
      CombatKeyDown(SDL_SCANCODE_RETURN); { confirm the target: swing lands }
      CombatSettle;                       { run the beat out so the log fills }
    end;
  end
  else if scene = 'castmenu' then begin
    { a quick battle, then drive the Wizard into the cast submenu; an optional
      level argument raises the Wizard so more spell levels open up }
    QuickBattle;
    if High(Roster) >= 3 then begin
      CurActor := 3;          { the pregen Wizard }
      if ParamCount >= 3 then Roster[3].level := StrToInt(ParamStr(3));
      Roster[3].sp := 20;
    end;
    CombatKeyDown(SDL_SCANCODE_DOWN);     { ATTACK -> CAST }
    CombatKeyDown(SDL_SCANCODE_RETURN);   { open the spell list }
  end
  else if scene = 'learn' then begin
    { a party, then wipe the Wizard's learned spells so it owes picks and the
      level-up learn screen opens for it. An optional CLASS reclasses that
      member (e.g. ILLUSION) to show a specialist's filtered learn list. }
    QuickStart;
    if High(Roster) >= 3 then begin
      if ParamCount >= 3 then begin
        mi := ClassIndex(UpperCase(ParamStr(3)));
        if mi >= 0 then Roster[3].klass := mi;
        Roster[3].level := 11;   { reach every spell level }
      end;
      SetLength(Roster[3].known, 0);
    end;
    State := gsLearnSpell;
  end
  else if scene = 'dialog' then begin
    { a party and a started world, then open the named NPC conversation so its
      PORT_<ID> portrait is framed in the dialog box. }
    if ParamCount < 3 then begin
      writeln(StdErr, 'usage: shot <out.ppm> dialog <ID>'); halt(2);
    end;
    QuickStart;
    DialogStart(UpperCase(ParamStr(3)));
    dlgId := UpperCase(ParamStr(3));
    dlgNpcName := UpperCase(ParamStr(3));
    State := gsDialog;
  end
  else if (scene = 'map') or (scene = 'foe') then begin
    if ParamCount < 6 then begin
      writeln(StdErr, 'usage: shot <out.ppm> map <MAP> <X> <Y> <N|E|S|W>');
      halt(2);
    end;
    QuickStart;   { a party for the HUD, and a started world }
    if not LoadMapLump(UpperCase(ParamStr(3))) then begin
      writeln(StdErr, 'shot: no map lump ', ParamStr(3)); halt(1);
    end;
    PlaceAt(StrToInt(ParamStr(4)), StrToInt(ParamStr(5)), DirCode(ParamStr(6)));
    if scene = 'foe' then begin
      if ParamCount < 9 then begin
        writeln(StdErr,
          'usage: shot <out.ppm> foe <MAP> <X> <Y> <DIR> <MON> <MX> <MY>');
        halt(2);
      end;
      mi := MonIndex(UpperCase(ParamStr(7)));
      if mi < 0 then begin
        writeln(StdErr, 'shot: no monster ', ParamStr(7)); halt(1);
      end;
      AddPursuer(mi, UpperCase(ParamStr(3)),
        StrToInt(ParamStr(8)), StrToInt(ParamStr(9)));
    end;
  end else if scene = 'sector' then begin
    { the theme G height proof: a hand-built two-sector map with a pit and a
      dais, rendered through the normal explore view. Optional args:
      <camX> <camY> <N|E|S|W> }
    QuickStart;
    BuildSectorDemo(secMap);
    if not LoadMapData(secMap) then begin
      writeln(StdErr, 'shot: could not load the sector demo'); halt(1);
    end;
    CurMapName := 'SECTORDEMO';
    if ParamCount >= 5 then
      PlaceAt(StrToInt(ParamStr(3)), StrToInt(ParamStr(4)), DirCode(ParamStr(5)))
    else
      PlaceAt(7, 12, DIR_N);
  end else if scene = 'room' then begin
    { the theme G modular-room proof: load a hand-placed set of kit pieces
      and draw them from the resident trim atlas through the polygon path.
      Optional args: <room-file> <camX> <camY> <camYawDeg> }
    roomFn := 'content/rooms/chamber.room';
    if ParamCount >= 3 then roomFn := ParamStr(3);
    if not FileExists(roomFn) then begin
      writeln(StdErr, 'shot: no room file ', roomFn); halt(1);
    end;
    rls := TStringList.Create;
    rls.LoadFromFile(roomFn);
    if not ParseRoom(rls.Text, room) then begin
      writeln(StdErr, 'shot: empty or malformed room ', roomFn); halt(1);
    end;
    rls.Free;
    if not SetTileset(GamePak, TILESET_MODULAR) then
      writeln(StdErr, 'shot: warning, modular tileset incomplete');
    if Length(TrimTex) = 0 then
      writeln(StdErr, 'shot: warning, no trim atlas resident (TRIM',
        TILESET_MODULAR, ' missing)');
    Cam.posX := -3.0; Cam.posY := 0.0; camA := 0.0;
    if ParamCount >= 6 then begin
      Cam.posX := StrToFloatDef(ParamStr(4), -3.0);
      Cam.posY := StrToFloatDef(ParamStr(5), 0.0);
      camA := DegToRad(StrToFloatDef(ParamStr(6), 0.0));
    end;
    Cam.dirX := cos(camA); Cam.dirY := sin(camA);
    Cam.planeX := -sin(camA) * 0.66; Cam.planeY := cos(camA) * 0.66;
    Cam.pitch := 0;
    RenderRoom(GamePak, room);
    doGameRender := false;
  end else begin
    writeln(StdErr, 'shot: unknown scene ', scene); halt(2);
  end;

  { any 'poly' argument draws the world view through the polygon renderer
    instead of the raycaster, to frame the PSX-style rasterizer headlessly }
  for mi := 2 to ParamCount do
    if LowerCase(ParamStr(mi)) = 'poly' then UsePoly := true;

  if doGameRender then GameRender(60);
  DumpPPM(outPath);
  writeln('wrote ', outPath, ' (', scene, ')');

  SDL_Quit;
end.
