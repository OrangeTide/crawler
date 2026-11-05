unit montext;

{** Parser for the text monster table, used by the asset tool.

  mon ID HD AC ATK DMG MORALE SPEED XP FLAGS [MODEL] "Name"
  FLAGS: 1 = undead, 2 = ranged (bitwise). MODEL is an optional combat
  mesh id, drawn from the model registry; omit it for a glyph. Blank
  lines and lines starting with '#' are ignored. }

{$mode objfpc}{$H+}

interface

uses
  monsters;

function ParseMonsters(const fn: string; out defs: array of TMonsterDef;
  out count: longint; out err: string): boolean;

implementation

uses
  classes, sysutils;

function ParseMonsters(const fn: string; out defs: array of TMonsterDef;
  out count: longint; out err: string): boolean;
var
  lines: TStringList;
  parts: TStringList;
  li, qpos, qend: longint;
  line, rest, name: string;
  d: TMonsterDef;
begin
  ParseMonsters := false; err := ''; count := 0;
  lines := TStringList.Create;
  parts := TStringList.Create;
  parts.StrictDelimiter := false;
  parts.Delimiter := ' ';
  try
    lines.LoadFromFile(fn);
    for li := 0 to lines.Count - 1 do begin
      line := Trim(lines[li]);
      if (line = '') or (line[1] = '#') then continue;

      name := '';
      qpos := Pos('"', line);
      if qpos > 0 then begin
        qend := Pos('"', Copy(line, qpos + 1, Length(line)));
        if qend > 0 then name := Copy(line, qpos + 1, qend - 1);
        rest := Trim(Copy(line, 1, qpos - 1));
      end else
        rest := line;

      parts.DelimitedText := rest;
      if (parts.Count < 9) or (parts[0] <> 'mon') then begin
        err := 'line ' + IntToStr(li + 1) + ': needs mon ID HD AC ATK DMG MORALE SPEED XP FLAGS "Name"';
        exit;
      end;
      if count > High(defs) then begin err := 'too many monsters'; exit; end;
      d.id := parts[1];
      d.name := name;
      d.hd := StrToInt(parts[2]);
      d.ac := StrToInt(parts[3]);
      d.atkBonus := StrToInt(parts[4]);
      d.dmgSides := StrToInt(parts[5]);
      d.morale := StrToInt(parts[6]);
      d.speed := StrToInt(parts[7]);
      d.xp := StrToInt(parts[8]);
      if parts.Count >= 10 then d.flags := StrToInt(parts[9]) else d.flags := 0;
      if parts.Count >= 11 then d.model := parts[10] else d.model := '';
      defs[count] := d; inc(count);
    end;
  finally
    parts.Free;
    lines.Free;
  end;
  ParseMonsters := true;
end;

end.
