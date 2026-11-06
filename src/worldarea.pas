unit worldarea;

{** Encounter areas.

  A monster lists the areas it roams as a bitmask; a loaded map resolves
  to one area, so only its monsters spawn and only their models sit in the
  cache at once. Eight areas fit a byte. The names are shared by the data
  parsers (maps, monsters, encounters, the world manifest) and by the
  runtime, so they live in their own small unit with no world dependency. }

{$mode objfpc}{$H+}

interface

const
  AREA_FOREST   = $01;
  AREA_COAST    = $02;
  AREA_DESERT   = $04;
  AREA_FROZEN   = $08;
  AREA_VOLCANIC = $10;
  AREA_CRYPT    = $20;
  AREA_CAVE     = $40;
  AREA_INFERNAL = $80;

{ The mask of one area named in a data file. }
function AreaMaskByName(const name: string): byte;
{ A '+' or ',' separated list of area names, such as 'forest+cave'. }
function ParseAreaList(const s: string): byte;
{ A short label for a single-area mask. }
function AreaName(mask: byte): string;
{ The texture tileset a generated map in this area should wear. The
  numbers match the tileset schemes in texgen: 0 default, 2 coast,
  3 wilds, 4 crypt, 5 cave, 6 infernal, 7 desert, 8 frozen, 9 volcanic.
  Authored maps carry their own tileset and do not use this. }
function TilesetForArea(mask: byte): longint;

implementation

uses
  sysutils;

function AreaMaskByName(const name: string): byte;
var s: string;
begin
  s := LowerCase(name);
  if s = 'forest' then AreaMaskByName := AREA_FOREST
  else if s = 'coast' then AreaMaskByName := AREA_COAST
  else if s = 'desert' then AreaMaskByName := AREA_DESERT
  else if s = 'frozen' then AreaMaskByName := AREA_FROZEN
  else if s = 'volcanic' then AreaMaskByName := AREA_VOLCANIC
  else if s = 'crypt' then AreaMaskByName := AREA_CRYPT
  else if s = 'cave' then AreaMaskByName := AREA_CAVE
  else if s = 'infernal' then AreaMaskByName := AREA_INFERNAL
  else AreaMaskByName := 0;
end;

function ParseAreaList(const s: string): byte;
var
  mask: byte;
  i, start: longint;
  tok: string;
begin
  mask := 0;
  start := 1;
  for i := 1 to Length(s) + 1 do
    if (i > Length(s)) or (s[i] = '+') or (s[i] = ',') then begin
      tok := Trim(Copy(s, start, i - start));
      if tok <> '' then mask := mask or AreaMaskByName(tok);
      start := i + 1;
    end;
  ParseAreaList := mask;
end;

function AreaName(mask: byte): string;
begin
  case mask of
    AREA_FOREST:   AreaName := 'wilds';
    AREA_COAST:    AreaName := 'coast';
    AREA_DESERT:   AreaName := 'desert';
    AREA_FROZEN:   AreaName := 'frozen';
    AREA_VOLCANIC: AreaName := 'volcanic';
    AREA_CRYPT:    AreaName := 'crypt';
    AREA_CAVE:     AreaName := 'cave';
    AREA_INFERNAL: AreaName := 'infernal';
  else
    AreaName := 'mixed';
  end;
end;

function TilesetForArea(mask: byte): longint;
begin
  case mask of
    AREA_FOREST:   TilesetForArea := 3;
    AREA_COAST:    TilesetForArea := 2;
    AREA_DESERT:   TilesetForArea := 7;
    AREA_FROZEN:   TilesetForArea := 8;
    AREA_VOLCANIC: TilesetForArea := 9;
    AREA_CRYPT:    TilesetForArea := 4;
    AREA_CAVE:     TilesetForArea := 5;
    AREA_INFERNAL: TilesetForArea := 6;
  else
    TilesetForArea := 0;
  end;
end;

end.
