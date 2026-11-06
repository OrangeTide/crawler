unit itemtext;

{** Parser for the text item table, used by the asset tool.

  One item per line:
    item ID KIND DMG AC SLOTS VALUE FLAGS "Name"
  KIND is weapon, armor, shield, potion, light, key, treasure or misc.
  Blank lines and lines starting with '#' are ignored. }

{$mode objfpc}{$H+}

interface

uses
  items;

function ParseItems(const fn: string; out defs: array of TItemDef;
  out count: longint; out errmsg: string): boolean;

implementation

uses
  classes, sysutils, monsters;

{ Map one element name to its EL_* flag, or 0 if unknown. }
function ElemFlag(const t: string): byte;
begin
  if t = 'phys' then ElemFlag := EL_PHYS
  else if t = 'fire' then ElemFlag := EL_FIRE
  else if t = 'frost' then ElemFlag := EL_FROST
  else if t = 'shock' then ElemFlag := EL_SHOCK
  else if t = 'holy' then ElemFlag := EL_HOLY
  else ElemFlag := 0;
end;

{ A 'resist:fire,frost' tag's value to an EL_* mask. }
function ElemMask(const list: string): byte;
var
  mask, start, i: longint;
  tok: string;
begin
  mask := 0;
  start := 1;
  for i := 1 to Length(list) + 1 do
    if (i > Length(list)) or (list[i] = ',') or (list[i] = '+') then begin
      tok := Trim(Copy(list, start, i - start));
      if tok <> '' then mask := mask or ElemFlag(tok);
      start := i + 1;
    end;
  ElemMask := mask;
end;

function KindCode(const s: string): longint;
begin
  if s = 'weapon' then KindCode := IK_WEAPON
  else if s = 'armor' then KindCode := IK_ARMOR
  else if s = 'shield' then KindCode := IK_SHIELD
  else if s = 'potion' then KindCode := IK_POTION
  else if s = 'light' then KindCode := IK_LIGHT
  else if s = 'key' then KindCode := IK_KEY
  else if s = 'treasure' then KindCode := IK_TREASURE
  else if s = 'misc' then KindCode := IK_MISC
  else KindCode := -1;
end;

function ParseItems(const fn: string; out defs: array of TItemDef;
  out count: longint; out errmsg: string): boolean;
var
  lines: TStringList;
  li, qpos, qend, kc, pi: longint;
  line, rest, name: string;
  parts: TStringList;
  d: TItemDef;
begin
  ParseItems := false;
  errmsg := '';
  count := 0;
  lines := TStringList.Create;
  parts := TStringList.Create;
  parts.Delimiter := ' ';
  parts.StrictDelimiter := false;
  try
    lines.LoadFromFile(fn);
    for li := 0 to lines.Count - 1 do begin
      line := Trim(lines[li]);
      if (line = '') or (line[1] = '#') then continue;

      { pull the quoted name out first }
      name := '';
      qpos := Pos('"', line);
      if qpos > 0 then begin
        qend := Pos('"', Copy(line, qpos + 1, Length(line)));
        if qend > 0 then
          name := Copy(line, qpos + 1, qend - 1);
        rest := Trim(Copy(line, 1, qpos - 1));
      end else
        rest := line;

      parts.DelimitedText := rest;
      if parts.Count < 8 then begin
        errmsg := 'line ' + IntToStr(li + 1) + ': needs 8 fields and a name';
        exit;
      end;
      if parts[0] <> 'item' then begin
        errmsg := 'line ' + IntToStr(li + 1) + ': expected item';
        exit;
      end;
      kc := KindCode(parts[2]);
      if kc < 0 then begin
        errmsg := 'line ' + IntToStr(li + 1) + ': bad kind ' + parts[2];
        exit;
      end;
      if count > High(defs) then begin
        errmsg := 'too many items';
        exit;
      end;
      d.id := parts[1];
      d.name := name;
      d.kind := kc;
      d.dmgSides := StrToInt(parts[3]);
      d.acVal := StrToInt(parts[4]);
      d.slots := StrToInt(parts[5]);
      d.value := StrToInt(parts[6]);
      d.flags := StrToInt(parts[7]);
      d.sprite := 0;
      { optional tags after the eight fields, before the name }
      d.resist := 0;
      for pi := 8 to parts.Count - 1 do
        if Copy(parts[pi], 1, 7) = 'resist:' then
          d.resist := d.resist or ElemMask(Copy(parts[pi], 8, Length(parts[pi])));
      defs[count] := d;
      inc(count);
    end;
  finally
    parts.Free;
    lines.Free;
  end;
  ParseItems := true;
end;

end.
