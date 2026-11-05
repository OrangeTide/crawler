unit worldload;

{** Map and session loading.

  Bring a map into the world, whether a static pak lump or a map generated
  from a seed, capturing the one left and restoring the one entered. Also
  the session entry points that sit on top of it: start a new game, resume
  a saved one, and the save-file path. This unit sits below the UI units;
  they call down into it and it never calls back up, so the game-state
  dependency graph stays acyclic. }

{$mode objfpc}{$H+}

interface

function SavePath: string;
function LoadMapLump(const name: string): boolean;
function LoadMapByName(const name, marker: string): boolean;
function ContinueGame: boolean;
procedure StartGame;

implementation

uses
  sysutils, pak, mapfmt, world, models, rng, monsters, encounters,
  mapgen, mapstate, overworld, worldname, worldarea, worldfmt, save, flags,
  gamestate;

function SavePath: string;
begin
  SavePath := ExtractFilePath(ParamStr(0)) + 'save1.sav';
end;

procedure GateAreaModels(tableNum: longint);
{** The per-area model cache gate. Load exactly the models the current
  map's props and this area's encounter monsters need, then check them
  against the VRAM budget so a level never asks for more than it can hold. }
var
  names: array of string;
  i, mi: longint;

  procedure Add(const nm: string);
  var j: longint;
  begin
    if nm = '' then exit;
    for j := 0 to High(names) do
      if names[j] = nm then exit;
    SetLength(names, Length(names) + 1);
    names[High(names)] := nm;
  end;

begin
  names := nil;
  for i := 0 to High(CurMap.props) do Add(CurMap.props[i].name);
  if (tableNum >= 0) and (tableNum <= High(EncTables)) then
    for i := 0 to High(EncTables[tableNum].entries) do begin
      mi := MonIndex(EncTables[tableNum].entries[i].mon);
      if mi >= 0 then Add(MonDefs[mi].model);
    end;
  LoadModelSet(GamePak, names);
  if not ModelSetFitsVram(names) then begin
    saveMsg := 'MODEL CACHE OVER VRAM: ' + AreaName(CurAreaMask);
    saveMsgT := 2.0;
  end;
end;

function LoadMapLump(const name: string): boolean;
{** Bring a map into the world. A static map is decoded from its pak
  lump; a dynamic map is generated from its stored or a fresh seed. The
  map being left is captured, and the one entered has its fog and doors
  restored. }
var
  blob: TByteArray;
  md: TMapData;
  di, ver, cx, cy, depth, pcx, pcy: longint;
  seed: longword;
  isDyn: boolean;
begin
  LoadMapLump := false;
  ver := 0; seed := 0; isDyn := false;
  CurDepth := 0;
  if PakGet(GamePak, name, blob) then begin
    if not DecodeMap(blob, md) then exit;
  end else if ParseCellName(name, cx, cy) then begin
    { an overworld cell: terrain is fixed by the world seed, so the
      per-cell seed is derived, not stored or random. Fog still persists. }
    isDyn := true;
    ver := GEN_VERSION;
    seed := CellSeed(cx, cy, 0);
    md := GenerateOverworldCell(cx, cy, seed);
    md.area := BiomeArea(BiomeAt(cx, cy));
  end else if ParseDungeonName(name, cx, cy, depth) then begin
    isDyn := true;
    ver := GEN_VERSION;
    seed := CellSeed(cx, cy, depth);
    md := GenerateDungeonLevel(cx, cy, depth, seed);
    md.area := ThemeArea(BiomeTheme(BiomeAt(cx, cy)));
    CurDepth := depth;
  end else if ParseDepthsName(name, cx, cy) then begin
    isDyn := true;
    ver := GEN_VERSION;
    seed := CellSeed(cx, cy, SUNLESS_DEPTH + 1);
    md := GenerateDepthsCell(cx, cy, seed);
    md.area := AREA_INFERNAL;
    CurDepth := SUNLESS_DEPTH;
  end else if ParseInteriorName(name, cx, cy, depth) then begin
    { a building interior standing on cell (cx,cy); depth holds the
      building index. Derived from the cell seed, so it is stable. }
    isDyn := true;
    ver := GEN_VERSION;
    seed := CellSeed(cx, cy, 0);
    md := GenerateInterior(cx, cy, depth, seed);
    md.area := 0;   { interiors are safe }
  end else begin
    di := DynIndex(name);
    if di < 0 then exit;
    isDyn := true;
    if not MapStateGetSeed(name, ver, seed) then begin
      ver := GEN_VERSION;
      seed := RngNext(GameRng);
      if seed = 0 then seed := 1;
    end;
    md := GenerateMap(DynMaps[di], ver, seed);
    md.area := DynMaps[di].area;   { the manifest declares its area }
    CurDepth := DynMaps[di].depth;
  end;
  { a pinned authored zone leaves back to the wilderness that reaches it,
    not only to the town hub. Derived from the map, so it stays stable. }
  if PinnedCellOf(name, pcx, pcy) then
    AddWildernessExit(md, pcx, pcy);
  if CurMapName <> '' then
    MapStateCapture(CurMapName);
  if not LoadMapData(md) then exit;
  CurMapName := name;
  CurAreaMask := md.area;   { authored maps carry it in the lump, generated
                             maps get it set above: no name list in code }
  CurEncTable := EncTableOf(CurAreaMask);
  GateAreaModels(CurEncTable);   { cache only what this area draws }
  if isDyn then
    MapStateSetDynamic(name, ver, seed);
  MapStateRestore(name);     { bring back fog and doors if visited before }
  LoadMapLump := true;
end;

function LoadMapByName(const name, marker: string): boolean;
{** Load a map and place the party at a named marker. }
begin
  LoadMapByName := false;
  if not LoadMapLump(name) then exit;
  PlaceAtMarker(marker);
  lastTX := TileX;
  lastTY := TileY;
  LoadMapByName := true;
end;

function ContinueGame: boolean;
{** Load the save, then reload its map at the saved position. }
begin
  ContinueGame := false;
  if not LoadGame(SavePath) then exit;
  CurMapName := '';          { do not capture a stale resident map }
  if not LoadMapLump(LoadedMapName) then exit;
  PlaceAt(LoadedTX, LoadedTY, LoadedFace);
  lastTX := TileX;
  lastTY := TileY;
  ContinueGame := true;
end;

procedure StartGame;
{** Hand off from the menus to the outskirts: the overworld clearing just
   outside the starter dungeon, a short walk north of town. }
begin
  FlagsReset;
  MapStateReset;
  CurMapName := '';
  if not LoadMapByName('OUTSKIRTS', 'spawn') then begin
    writeln(StdErr, 'game: could not load the starting map');
    QuitRequested := true;
    exit;
  end;
  State := gsExplore;
end;

end.
