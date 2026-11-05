unit worldtext;

{** Parser for the dynamic-map manifest, used by the asset tool.

    dynmap NAME GEN W H DEPTH RETMAP RETMARKER
  GEN is rooms, cave or maze. Blank lines and '#' comments ignored. }

{$mode objfpc}{$H+}

interface

uses
  worldfmt;

function ParseWorld(const fn: string; out d: array of TDynMap;
  out count: longint; out err: string): boolean;

implementation

uses
  classes, sysutils;

function GenCode(const s: string): longint;
begin
  if s = 'rooms' then GenCode := GEN_ROOMS
  else if s = 'cave' then GenCode := GEN_CAVE
  else if s = 'maze' then GenCode := GEN_MAZE
  else GenCode := -1;
end;

function ParseWorld(const fn: string; out d: array of TDynMap;
  out count: longint; out err: string): boolean;
var
  lines, parts: TStringList;
  li, g: longint;
  line: string;
begin
  ParseWorld := false; err := ''; count := 0;
  lines := TStringList.Create;
  parts := TStringList.Create;
  parts.StrictDelimiter := false; parts.Delimiter := ' ';
  try
    lines.LoadFromFile(fn);
    for li := 0 to lines.Count - 1 do begin
      line := Trim(lines[li]);
      if (line = '') or (line[1] = '#') then continue;
      parts.DelimitedText := line;
      if (parts.Count < 8) or (parts[0] <> 'dynmap') then begin
        err := 'line ' + IntToStr(li + 1) + ': dynmap NAME GEN W H DEPTH RETMAP RETMARKER';
        exit;
      end;
      g := GenCode(parts[2]);
      if g < 0 then begin err := 'line ' + IntToStr(li + 1) + ': bad generator'; exit; end;
      if count > High(d) then begin err := 'too many dynmaps'; exit; end;
      d[count].name := parts[1];
      d[count].gen := g;
      d[count].w := StrToInt(parts[3]);
      d[count].h := StrToInt(parts[4]);
      d[count].depth := StrToInt(parts[5]);
      d[count].retMap := parts[6];
      d[count].retMarker := parts[7];
      inc(count);
    end;
  finally
    parts.Free;
    lines.Free;
  end;
  ParseWorld := true;
end;

end.
