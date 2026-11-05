unit gamestate;

{** Shared state for the game's UI units.

  The game is a set of states (title, exploration, combat, and so on), one
  active at a time. The handlers for those states live in their own units;
  this unit holds the state they share: the active state itself, the input
  snapshot, the loaded pak, and the cross-state scratch each handler reads
  or writes. It has no logic beyond the key test, so every UI unit can
  depend on it without pulling in another. }

{$mode objfpc}{$H+}

interface

uses
  sdl2min, pak;

type
  TGameState = (gsTitle, gsNewParty, gsExplore, gsCombat,
                gsDialog, gsShop, gsFullMap, gsInventory, gsMenu,
                gsGameOver, gsVictory, gsOptions);

  TKeyArray = array[0 .. SDL_NUM_SCANCODES - 1] of UInt8;
  PKeyArray = ^TKeyArray;

const
  NAME_POOL: array[0 .. 11] of string[12] = (
    'THORNE', 'BRYN', 'MAEVE', 'KORRIG', 'ELSPETH', 'DRAVEN',
    'LYRA', 'GARRET', 'ODILE', 'VANCE', 'SERA', 'RHESK');

var
  State: TGameState;
  QuitRequested: boolean;

  keys: PKeyArray;        { the SDL key-state snapshot for this frame }
  showMap: boolean;
  UsePoly: boolean;       { toggle the polygon renderer against the raycaster }
  GamePak: TPak;

  lastTX, lastTY: longint;
  CurDepth: longint;      { 0 surface, else the dungeon depth, for scaling }
  CurAreaMask: byte;      { the encounter area of the loaded map, 0 = safe }
  CurEncTable: longint;   { the encounter table that area points at, 0 = none }
  FromQuickBattle: boolean; { a test fight with no world; exit to the title }

  cursorX, cursorY: longint;
  rmbHeld: boolean;
  dlgNpcName: string;
  shopSel: longint;
  shopStock: string;      { id of the shop currently open }
  saveMsg: string;
  saveMsgT: double;
  optSel: longint;
  volMaster, volMusic, volSfx: longint;
  titleSel: longint;

function KeyDown(scancode: longint): boolean; inline;

implementation

function KeyDown(scancode: longint): boolean; inline;
begin
  KeyDown := (keys <> nil) and (keys^[scancode] <> 0);
end;

end.
