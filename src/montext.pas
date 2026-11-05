unit montext;

{** Parser for the text monster table, used by the asset tool.

  mon ID HD AC ATK DMG MORALE SPEED XP [FLAGS [MODEL [AREAS]]] [tags] "Name"
  FLAGS: 1 = undead, 2 = ranged, 4 = lycanthrope (bitwise). MODEL is an
  optional combat mesh id, drawn from the model registry; omit it for a
  glyph. AREAS is an optional '+'-separated list of the areas the monster
  roams, such as forest+cave; omit it and the monster roams nowhere.

  Any trailing key:value tags tune combat (order free, after the
  positional columns):
    elem:fire          the element this monster's attack deals
    weak:frost,phys    elements it takes extra damage from
    resist:fire        elements it takes reduced damage from
    immune:fire        elements it ignores
    inflict:poison     a status its hit may apply
    statusimm:poison   statuses it cannot suffer
    harry:taunt        a ranged disruption trick (taunt or throw)
  Element names: phys fire frost shock holy. Status names: poison stun
  slow burn. Undead gain holy weakness and poison immunity by default.

  Blank lines and lines starting with '#' are ignored. }

{$mode objfpc}{$H+}

interface

uses
  monsters, worldarea;

function ParseMonsters(const fn: string; out defs: array of TMonsterDef;
  out count: longint; out err: string): boolean;

implementation

uses
  classes, sysutils;

{ Map one element name to its EL_* flag, or 0 if unknown. }
function ElemFlag(const s: string): byte;
var t: string;
begin
  t := LowerCase(Trim(s));
  if t = 'phys' then ElemFlag := EL_PHYS
  else if t = 'fire' then ElemFlag := EL_FIRE
  else if t = 'frost' then ElemFlag := EL_FROST
  else if t = 'shock' then ElemFlag := EL_SHOCK
  else if t = 'holy' then ElemFlag := EL_HOLY
  else ElemFlag := 0;
end;

{ Map one status name to its ST_* flag, or 0 if unknown. }
function StatusFlag(const s: string): byte;
var t: string;
begin
  t := LowerCase(Trim(s));
  if t = 'poison' then StatusFlag := ST_POISON
  else if t = 'stun' then StatusFlag := ST_STUN
  else if t = 'slow' then StatusFlag := ST_SLOW
  else if t = 'burn' then StatusFlag := ST_BURN
  else StatusFlag := 0;
end;

{ OR together the flags for a comma-separated name list, using mapFn. }
function FlagList(const s: string; elem: boolean): byte;
var
  items: TStringList;
  i: longint;
  m: byte;
begin
  m := 0;
  items := TStringList.Create;
  try
    items.StrictDelimiter := true;
    items.Delimiter := ',';
    items.DelimitedText := s;
    for i := 0 to items.Count - 1 do
      if elem then m := m or ElemFlag(items[i])
      else m := m or StatusFlag(items[i]);
  finally
    items.Free;
  end;
  FlagList := m;
end;

function ParseMonsters(const fn: string; out defs: array of TMonsterDef;
  out count: longint; out err: string): boolean;
var
  lines: TStringList;
  parts: TStringList;
  li, qpos, qend, i, posSlot, cpos: longint;
  line, rest, name, tok, key, val: string;
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
      FillChar(d, SizeOf(d), 0);
      d.id := parts[1];
      d.name := name;
      d.hd := StrToInt(parts[2]);
      d.ac := StrToInt(parts[3]);
      d.atkBonus := StrToInt(parts[4]);
      d.dmgSides := StrToInt(parts[5]);
      d.morale := StrToInt(parts[6]);
      d.speed := StrToInt(parts[7]);
      d.xp := StrToInt(parts[8]);

      { tokens past XP are either positional optionals (flags, model,
        areas, in that order) or key:value tags, told apart by the colon }
      posSlot := 0;
      for i := 9 to parts.Count - 1 do begin
        tok := parts[i];
        cpos := Pos(':', tok);
        if cpos > 0 then begin
          key := LowerCase(Copy(tok, 1, cpos - 1));
          val := Copy(tok, cpos + 1, Length(tok));
          if key = 'elem' then d.element := FlagList(val, true)
          else if key = 'weak' then d.weak := FlagList(val, true)
          else if key = 'resist' then d.resist := FlagList(val, true)
          else if key = 'immune' then d.immune := FlagList(val, true)
          else if key = 'inflict' then d.inflict := FlagList(val, false)
          else if key = 'statusimm' then d.statusImm := FlagList(val, false)
          else if key = 'harry' then begin
            if LowerCase(val) = 'taunt' then d.harry := HARRY_TAUNT
            else if LowerCase(val) = 'throw' then d.harry := HARRY_THROW
            else begin
              err := 'line ' + IntToStr(li + 1) + ': bad harry ' + val;
              exit;
            end;
          end
          else begin
            err := 'line ' + IntToStr(li + 1) + ': unknown tag ' + key;
            exit;
          end;
        end else begin
          case posSlot of
            0: d.flags := StrToInt(tok);
            1: d.model := tok;
            2: d.areas := ParseAreaList(tok);
          end;
          inc(posSlot);
        end;
      end;

      { undead are holy-struck and beyond poison unless stated otherwise }
      if (d.flags and MF_UNDEAD) <> 0 then begin
        d.weak := d.weak or EL_HOLY;
        d.statusImm := d.statusImm or ST_POISON;
      end;

      defs[count] := d; inc(count);
    end;
  finally
    parts.Free;
    lines.Free;
  end;
  ParseMonsters := true;
end;

end.
