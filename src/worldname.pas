unit worldname;

{** Names of the synthesized overworld maps.

  The world's cells and the layers beneath them have no stored maps; each
  is addressed by a synthesized name that the map loader recognizes and
  routes to the generator. This unit builds and parses those names, and
  holds the two world extents they range over. It is pure string work with
  no dependency on the noise or biome machinery, so the data parsers can
  share it without pulling in the terrain generator. }

{$mode objfpc}{$H+}

interface

const
  OW_SIZE = 1024;          { cells per side }
  SUNLESS_DEPTH = 30;      { a dungeon this deep breaks into the Depths }

{ Overworld surface cells: 'W<cx>_<cy>'. }
function CellName(cx, cy: longint): string;
function ParseCellName(const s: string; out cx, cy: longint): boolean;

{ Dungeon levels beneath a cell: 'D<cx>_<cy>_<depth>'. }
function DungeonName(cx, cy, depth: longint): string;
function ParseDungeonName(const s: string; out cx, cy, depth: longint): boolean;

{ The Sunless Depths cavern beneath a cell: 'S<cx>_<cy>'. }
function DepthsName(cx, cy: longint): string;
function ParseDepthsName(const s: string; out cx, cy: longint): boolean;

{ Building interiors reached from a surface cell: 'I<cx>_<cy>_<idx>'. }
function InteriorName(cx, cy, idx: longint): string;
function ParseInteriorName(const s: string; out cx, cy, idx: longint): boolean;

implementation

uses
  sysutils;

function CellName(cx, cy: longint): string;
begin
  CellName := 'W' + IntToStr(cx) + '_' + IntToStr(cy);
end;

function ParseCellName(const s: string; out cx, cy: longint): boolean;
var
  i, us: longint;
  a, b: string;
begin
  ParseCellName := false;
  cx := 0; cy := 0;
  if (Length(s) < 4) or (s[1] <> 'W') then exit;
  us := 0;
  for i := 2 to Length(s) do begin
    if s[i] = '_' then begin
      if us <> 0 then exit;   { more than one underscore }
      us := i;
    end else if (s[i] < '0') or (s[i] > '9') then
      exit;                   { non-digit }
  end;
  if (us < 3) or (us = Length(s)) then exit;
  a := Copy(s, 2, us - 2);
  b := Copy(s, us + 1, Length(s) - us);
  cx := StrToInt(a);
  cy := StrToInt(b);
  ParseCellName := (cx >= 0) and (cx < OW_SIZE) and (cy >= 0) and (cy < OW_SIZE);
end;

{ Parse up to three underscore-separated non-negative integers from s. }
function ParseNums(const s: string; out n0, n1, n2: longint; out count: longint): boolean;
var
  i, cur: longint;
  started: boolean;
  nums: array[0 .. 2] of longint;
begin
  ParseNums := false;
  n0 := 0; n1 := 0; n2 := 0; count := 0;
  cur := 0; started := false;
  for i := 1 to Length(s) do begin
    if s[i] = '_' then begin
      if not started then exit;      { empty field }
      if count >= 3 then exit;
      nums[count] := cur; inc(count);
      cur := 0; started := false;
    end else if (s[i] >= '0') and (s[i] <= '9') then begin
      cur := cur * 10 + (ord(s[i]) - ord('0'));
      started := true;
    end else
      exit;                          { non-digit }
  end;
  if not started then exit;
  if count >= 3 then exit;
  nums[count] := cur; inc(count);
  n0 := nums[0];
  if count >= 2 then n1 := nums[1];
  if count >= 3 then n2 := nums[2];
  ParseNums := true;
end;

function DungeonName(cx, cy, depth: longint): string;
begin
  DungeonName := 'D' + IntToStr(cx) + '_' + IntToStr(cy) + '_' + IntToStr(depth);
end;

function ParseDungeonName(const s: string; out cx, cy, depth: longint): boolean;
var
  count: longint;
begin
  ParseDungeonName := false;
  cx := 0; cy := 0; depth := 0;
  if (Length(s) < 6) or (s[1] <> 'D') then exit;
  if not ParseNums(Copy(s, 2, Length(s) - 1), cx, cy, depth, count) then exit;
  if count <> 3 then exit;
  ParseDungeonName := (cx >= 0) and (cx < OW_SIZE) and (cy >= 0)
    and (cy < OW_SIZE) and (depth >= 1);
end;

function DepthsName(cx, cy: longint): string;
begin
  DepthsName := 'S' + IntToStr(cx) + '_' + IntToStr(cy);
end;

function ParseDepthsName(const s: string; out cx, cy: longint): boolean;
var
  dummy, count: longint;
begin
  ParseDepthsName := false;
  cx := 0; cy := 0;
  if (Length(s) < 4) or (s[1] <> 'S') then exit;
  if not ParseNums(Copy(s, 2, Length(s) - 1), cx, cy, dummy, count) then exit;
  if count <> 2 then exit;
  ParseDepthsName := (cx >= 0) and (cx < OW_SIZE) and (cy >= 0) and (cy < OW_SIZE);
end;

function InteriorName(cx, cy, idx: longint): string;
begin
  InteriorName := 'I' + IntToStr(cx) + '_' + IntToStr(cy) + '_' + IntToStr(idx);
end;

function ParseInteriorName(const s: string; out cx, cy, idx: longint): boolean;
var
  count: longint;
begin
  ParseInteriorName := false;
  cx := 0; cy := 0; idx := 0;
  if (Length(s) < 6) or (s[1] <> 'I') then exit;
  if not ParseNums(Copy(s, 2, Length(s) - 1), cx, cy, idx, count) then exit;
  if count <> 3 then exit;
  ParseInteriorName := (cx >= 0) and (cx < OW_SIZE) and (cy >= 0)
    and (cy < OW_SIZE) and (idx >= 0);
end;

end.
