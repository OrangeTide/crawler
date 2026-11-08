unit spelltext;

{** Parser for the spell catalog text format, used by the asset tool.

    spell ID "Name" DOMAIN LEVEL SAVE DTYPE
      "the effect prose"
      comp "material components"

  DOMAIN is cleric, druid or magicuser; SAVE is none, body, dodge or will;
  DTYPE is none, acid, cold, fire, force, lightning or poison. The effect is a
  bare quoted line; the comp line is optional. Blank lines and '#' comments are
  ignored. }

{$mode objfpc}{$H+}

interface

uses
  spelldb;

function ParseSpells(const fn: string; out ss: array of TSpellDef;
  out count: longint; out err: string): boolean;

implementation

uses
  classes, sysutils;

procedure QTok(const line: string; out tok: array of string; out n: longint);
var
  i, len, start: longint;
begin
  n := 0; len := Length(line); i := 1;
  while i <= len do begin
    while (i <= len) and (line[i] = ' ') do inc(i);
    if i > len then break;
    if line[i] = '"' then begin
      inc(i); start := i;
      while (i <= len) and (line[i] <> '"') do inc(i);
      if n <= High(tok) then tok[n] := Copy(line, start, i - start);
      inc(n);
      if i <= len then inc(i);
    end else begin
      start := i;
      while (i <= len) and (line[i] <> ' ') do inc(i);
      if n <= High(tok) then tok[n] := Copy(line, start, i - start);
      inc(n);
    end;
  end;
end;

function DomainOf(const s: string; out d: byte): boolean;
begin
  DomainOf := true;
  if s = 'cleric' then d := SPD_CLERIC
  else if s = 'druid' then d := SPD_DRUID
  else if s = 'magicuser' then d := SPD_MAGE
  else DomainOf := false;
end;

function SaveOf(const s: string; out v: byte): boolean;
begin
  SaveOf := true;
  if s = 'none' then v := SSV_NONE
  else if s = 'body' then v := SSV_BODY
  else if s = 'dodge' then v := SSV_DODGE
  else if s = 'will' then v := SSV_WILL
  else SaveOf := false;
end;

function DTypeOf(const s: string; out v: byte): boolean;
begin
  DTypeOf := true;
  if s = 'none' then v := SDT_NONE
  else if s = 'acid' then v := SDT_ACID
  else if s = 'cold' then v := SDT_COLD
  else if s = 'fire' then v := SDT_FIRE
  else if s = 'force' then v := SDT_FORCE
  else if s = 'lightning' then v := SDT_LIGHTNING
  else if s = 'poison' then v := SDT_POISON
  else DTypeOf := false;
end;

function ParseSpells(const fn: string; out ss: array of TSpellDef;
  out count: longint; out err: string): boolean;
var
  lines: TStringList;
  li, n, cur: longint;
  tok: array[0 .. 7] of string;
  line: string;
begin
  ParseSpells := false; err := ''; count := 0; cur := -1;
  lines := TStringList.Create;
  try
    lines.LoadFromFile(fn);
    for li := 0 to lines.Count - 1 do begin
      line := Trim(lines[li]);
      if (line = '') or (line[1] = '#') then continue;
      QTok(line, tok, n);
      if n = 0 then continue;

      if tok[0] = 'spell' then begin
        if count > High(ss) then begin err := 'too many spells'; exit; end;
        if n < 7 then begin
          err := 'line ' + IntToStr(li + 1) + ': spell needs ID name domain level save dtype';
          exit;
        end;
        inc(count); cur := count - 1;
        ss[cur].id := tok[1];
        ss[cur].name := tok[2];
        ss[cur].level := StrToIntDef(tok[4], 1);
        ss[cur].effect := '';
        ss[cur].components := '';
        if not DomainOf(tok[3], ss[cur].domain) then begin
          err := 'line ' + IntToStr(li + 1) + ': bad domain ' + tok[3]; exit;
        end;
        if not SaveOf(tok[5], ss[cur].save) then begin
          err := 'line ' + IntToStr(li + 1) + ': bad save ' + tok[5]; exit;
        end;
        if not DTypeOf(tok[6], ss[cur].dtype) then begin
          err := 'line ' + IntToStr(li + 1) + ': bad damage type ' + tok[6]; exit;
        end;
      end else if tok[0] = 'comp' then begin
        if cur < 0 then begin err := 'comp before spell'; exit; end;
        ss[cur].components := tok[1];
      end else if line[1] = '"' then begin
        if cur < 0 then begin err := 'effect before spell'; exit; end;
        ss[cur].effect := tok[0];
      end else begin
        err := 'line ' + IntToStr(li + 1) + ': unknown keyword ' + tok[0];
        exit;
      end;
    end;
  finally
    lines.Free;
  end;
  ParseSpells := true;
end;

end.
