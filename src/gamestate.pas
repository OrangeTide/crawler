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
                gsDialog, gsShop, gsFullMap, gsCharSheet, gsMenu,
                gsGameOver, gsVictory, gsOptions, gsKeybind, gsOverworld,
                gsLearnSpell, gsLearnSkill);

  TKeyArray = array[0 .. SDL_NUM_SCANCODES - 1] of UInt8;
  PKeyArray = ^TKeyArray;

const
  NAME_POOL: array[0 .. 11] of string[12] = (
    'THORNE', 'BRYN', 'MAEVE', 'KORRIG', 'ELSPETH', 'DRAVEN',
    'LYRA', 'GARRET', 'ODILE', 'VANCE', 'SERA', 'RHESK');

  { light-as-a-resource tuning }
  TORCH_MINUTES = 240;   { how long one torch burns, in game minutes }
  TORCH_GUTTER  = 20;    { below this many minutes the flame gutters low }
  TORCH_DARK    = 56;    { torchless underground glow, 0..256 }

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
  dlgId: string;        { the active dialog id, used to pick the NPC portrait }
  shopSel: longint;
  shopStock: string;      { id of the shop currently open }
  saveMsg: string;
  saveMsgT: double;
  optSel: longint;
  volMaster, volMusic, volSfx: longint;
  titleSel: longint;
  kbSel: longint;          { selected row on the key-bindings screen }
  kbCapturing: boolean;    { waiting for the next key to bind it }
  menuTab: longint;        { meta-screen tab: 0 journal, 1 bestiary, 2 spells }
  sheetSel: longint;       { which party member the character sheet shows }
  sheetSpellSel: longint;  { highlighted spell in the sheet's spell browser }
  skillActor: longint;     { the member training on the learn-a-skill screen }
  skillTrainSel: longint;  { highlighted skill on the learn-a-skill screen }

  { coarse overworld travel: the cursor cell and how many cells it has
    moved from where the party stood when travel began }
  owCx, owCy, owSteps: longint;

  { the party light: game minutes left on the burning torch }
  TorchFuel: longint;

function KeyDown(scancode: longint): boolean; inline;

implementation

function KeyDown(scancode: longint): boolean; inline;
begin
  KeyDown := (keys <> nil) and (keys^[scancode] <> 0);
end;

end.
