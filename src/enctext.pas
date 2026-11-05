unit enctext;

{** Parser for the encounter-table format, used by the asset tool.

    area forest 1      assign an area to a table number
    area cave 1
    table 1            begin filling table 1
    mon RAT 4          a monster id and its weight in the current table
    mon WOLF 2

  Areas: forest coast desert frozen volcanic crypt cave infernal. Tables
  are numbered from 0; table 0 is left empty for safe areas. Blank lines
  and '#' comments are ignored. }

{$mode objfpc}{$H+}

interface

uses
  encounters;

function ParseEncounters(const fn: string; out tables: array of TEncTable;
  out tableCount: longint; out areaMap: array of byte; out err: string): boolean;

implementation

uses
  classes, sysutils, worldarea;

procedure Split(const line: string; out tok: array of string; out n: longint);
var
  i, len, start: longint;
begin
  n := 0; len := Length(line); i := 1;
  while i <= len do begin
    while (i <= len) and (line[i] = ' ') do inc(i);
    if i > len then break;
    start := i;
    while (i <= len) and (line[i] <> ' ') do inc(i);
    if n <= High(tok) then tok[n] := Copy(line, start, i - start);
    inc(n);
  end;
end;

function ParseEncounters(const fn: string; out tables: array of TEncTable;
  out tableCount: longint; out areaMap: array of byte; out err: string): boolean;
var
  lines: TStringList;
  li, n, cur, t, i, w: longint;
  tok: array[0 .. 7] of string;
  line: string;
  ab: byte;
begin
  ParseEncounters := false; err := ''; tableCount := 0; cur := -1;
  for i := 0 to High(areaMap) do areaMap[i] := 0;
  for i := 0 to High(tables) do tables[i].entries := nil;

  lines := TStringList.Create;
  try
    lines.LoadFromFile(fn);
    for li := 0 to lines.Count - 1 do begin
      line := Trim(lines[li]);
      if (line = '') or (line[1] = '#') then continue;
      Split(line, tok, n);
      if n = 0 then continue;

      if tok[0] = 'area' then begin
        if n < 3 then begin
          err := 'line ' + IntToStr(li + 1) + ': area needs a name and table';
          exit;
        end;
        ab := AreaMaskByName(tok[1]);
        if ab = 0 then begin
          err := 'line ' + IntToStr(li + 1) + ': unknown area ' + tok[1]; exit;
        end;
        t := StrToIntDef(tok[2], -1);
        if (t < 0) or (t > High(areaMap)) then begin
          err := 'line ' + IntToStr(li + 1) + ': bad table number'; exit;
        end;
        areaMap[ab] := t;
        if t + 1 > tableCount then tableCount := t + 1;
      end else if tok[0] = 'table' then begin
        if n < 2 then begin
          err := 'line ' + IntToStr(li + 1) + ': table needs a number'; exit;
        end;
        cur := StrToIntDef(tok[1], -1);
        if (cur < 0) or (cur > High(tables)) then begin
          err := 'line ' + IntToStr(li + 1) + ': bad table number'; exit;
        end;
        if cur + 1 > tableCount then tableCount := cur + 1;
      end else if tok[0] = 'mon' then begin
        if cur < 0 then begin
          err := 'line ' + IntToStr(li + 1) + ': mon before table'; exit;
        end;
        if n < 3 then begin
          err := 'line ' + IntToStr(li + 1) + ': mon needs an id and weight';
          exit;
        end;
        w := StrToIntDef(tok[2], 0);
        if w < 1 then begin
          err := 'line ' + IntToStr(li + 1) + ': weight must be positive'; exit;
        end;
        with tables[cur] do begin
          SetLength(entries, Length(entries) + 1);
          entries[High(entries)].mon := tok[1];
          entries[High(entries)].weight := w;
        end;
      end else begin
        err := 'line ' + IntToStr(li + 1) + ': unknown keyword ' + tok[0];
        exit;
      end;
    end;
  finally
    lines.Free;
  end;
  ParseEncounters := true;
end;

end.
