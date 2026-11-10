unit overworldui;

{** Coarse overworld travel.

  The world is a 1024x1024 grid of biome cells, far too large to cross tile
  by tile. This is the map-scale travel mode: a top-down view of the biome
  grid around the party, where one key press moves one cell. The party picks
  a destination across the grid and descends into that cell's local map,
  having spent the travel time. It is reached from the open surface, where
  the party's world cell is known, and it leaves the resident map untouched
  until the journey is committed, so cancelling costs nothing.

  Only land is crossed on foot: open ocean needs a boat, which does not
  exist yet, so ocean cells block. Descending clears any local hunters,
  since the party has outrun them at the scale of the map. }

{$mode objfpc}{$H+}

interface

{ Enter overworld travel if the party stands on the known surface. Returns
  false (and changes nothing) underground or where the cell is unknown. }
function EnterOverworld: boolean;
procedure OverworldRender;
procedure OverworldKeyDown(scancode: longint);

implementation

uses
  sysutils, sdl2min, gfx, world, overworld, worldname, worldload, gametime,
  audio, pursuit, gamestate;

const
  OW_RX = 10;              { cells shown each side of the party, across }
  OW_RY = 7;               { and down }
  OW_CS = 12;              { pixels per cell }
  OVERWORLD_STEP_MIN = 180; { game minutes to cross one cell on foot }

function BiomeColor(b: byte): TColor;
begin
  case b of
    BIOME_OCEAN:    BiomeColor := RGB(40, 70, 130);
    BIOME_COAST:    BiomeColor := RGB(205, 195, 140);
    BIOME_ARBOREAL: BiomeColor := RGB(70, 130, 70);
    BIOME_SWAMP:    BiomeColor := RGB(80, 100, 70);
    BIOME_HILLS:    BiomeColor := RGB(130, 150, 90);
    BIOME_MOUNT:    BiomeColor := RGB(140, 140, 150);
    BIOME_DESERT:   BiomeColor := RGB(210, 185, 120);
    BIOME_ARCTIC:   BiomeColor := RGB(220, 230, 240);
    BIOME_BASALT:   BiomeColor := RGB(70, 66, 72);
  else
    BiomeColor := RGB(150, 60, 45);   { volcanic }
  end;
end;

function PartyCell(out cx, cy: longint): boolean;
{** The world cell the party stands on: a generated wilderness cell by its
  name, or a pinned surface zone by the pin table. }
begin
  PartyCell := ParseCellName(CurMapName, cx, cy)
            or PinnedCellOf(CurMapName, cx, cy);
end;

function CellPassable(cx, cy: longint): boolean;
{** In the world and not open ocean. }
begin
  CellPassable := (cx >= 0) and (cx < OW_SIZE) and (cy >= 0) and (cy < OW_SIZE)
    and (BiomeAt(cx, cy) <> BIOME_OCEAN);
end;

function EnterOverworld: boolean;
var
  cx, cy: longint;
begin
  EnterOverworld := false;
  if not CurMapSurface then exit;      { only from the open surface }
  if not PartyCell(cx, cy) then exit;  { and only where the cell is known }
  owCx := cx; owCy := cy; owSteps := 0;
  State := gsOverworld;
  EnterOverworld := true;
end;

procedure OverworldRender;
var
  col, row, wx, wy, ox, oy, cols, rows, px, py: longint;
  pin, arr: string;
begin
  ClearFB(RGB(6, 8, 12));
  cols := 2 * OW_RX + 1;
  rows := 2 * OW_RY + 1;
  ox := (FBW - cols * OW_CS) div 2;
  oy := (FBH - rows * OW_CS) div 2 + 4;

  for row := 0 to rows - 1 do
    for col := 0 to cols - 1 do begin
      wx := owCx + (col - OW_RX);
      wy := owCy + (row - OW_RY);
      if (wx < 0) or (wx >= OW_SIZE) or (wy < 0) or (wy >= OW_SIZE) then
        continue;
      px := ox + col * OW_CS;
      py := oy + row * OW_CS;
      FillRect(px, py, OW_CS - 1, OW_CS - 1, BiomeColor(BiomeAt(wx, wy)));
      if PinnedAt(wx, wy, pin, arr) then
        FillRect(px + 3, py + 3, OW_CS - 7, OW_CS - 7, RGB(240, 225, 120))
      else if HasDungeon(wx, wy) then
        FillRect(px + 4, py + 4, 3, 3, RGB(150, 60, 50));
    end;

  { the party marker on the centre cell }
  FrameRect(ox + OW_RX * OW_CS - 1, oy + OW_RY * OW_CS - 1,
    OW_CS + 1, OW_CS + 1, RGB(250, 250, 250));

  { header: a title and the cell coordinate, then the place the cursor is
    over, named if it is a known zone. }
  DrawText(8, 5, 'OVERWORLD TRAVEL', RGB(170, 180, 150));
  DrawText(FBW - 8 - Length(IntToStr(owCx) + ',' + IntToStr(owCy)) * 6, 5,
    IntToStr(owCx) + ',' + IntToStr(owCy), RGB(170, 180, 150));
  if PinnedAt(owCx, owCy, pin, arr) then
    DrawText(8, 17, UpperCase(pin) + ' - ' + BiomeName(BiomeAt(owCx, owCy)),
      RGB(240, 225, 120))
  else
    DrawText(8, 17, BiomeName(BiomeAt(owCx, owCy)), RGB(220, 210, 140));

  { footer: the travel cost so far, then the controls. }
  if owSteps > 0 then
    DrawText(8, FBH - 24, IntToStr(owSteps) + ' CELLS   '
      + IntToStr((owSteps * OVERWORLD_STEP_MIN) div 60) + 'H', RGB(170, 180, 150));
  DrawText(8, FBH - 12, 'ARROWS TRAVEL   ENTER DESCEND   ESC BACK',
    RGB(140, 150, 120));
end;

procedure TryMove(dx, dy: longint);
var
  nx, ny: longint;
begin
  nx := owCx + dx;
  ny := owCy + dy;
  if not CellPassable(nx, ny) then exit;   { a wall of ocean or the world edge }
  owCx := nx; owCy := ny;
  inc(owSteps);
  PlaySfx(SFX_SELECT);
end;

procedure Descend;
{** Commit the journey: spend the travel time, shake off local hunters, and
  drop into the destination cell's local map. }
var
  pin, arr: string;
begin
  if owSteps = 0 then begin State := gsExplore; exit; end;  { went nowhere }
  PursuitClear;                 { outrun at map scale }
  TimeAdvance(owSteps * OVERWORLD_STEP_MIN);
  if PinnedAt(owCx, owCy, pin, arr) then
    LoadMapByName(pin, arr)
  else
    LoadMapByName(CellName(owCx, owCy), 'start');
  saveMsg := 'TRAVELED TO ' + BiomeName(BiomeAt(owCx, owCy));
  saveMsgT := 2.0;
  State := gsExplore;
end;

procedure OverworldKeyDown(scancode: longint);
begin
  case scancode of
    SDL_SCANCODE_UP, SDL_SCANCODE_W:    TryMove(0, -1);
    SDL_SCANCODE_DOWN, SDL_SCANCODE_S:  TryMove(0, 1);
    SDL_SCANCODE_LEFT, SDL_SCANCODE_A:  TryMove(-1, 0);
    SDL_SCANCODE_RIGHT, SDL_SCANCODE_D: TryMove(1, 0);
    SDL_SCANCODE_RETURN, SDL_SCANCODE_SPACE: Descend;
    SDL_SCANCODE_ESCAPE, SDL_SCANCODE_O: State := gsExplore;
  end;
end;

end.
