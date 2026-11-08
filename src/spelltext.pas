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
  classes, sysutils, monsters;

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

function SchoolOf(const s: string; out v: byte): boolean;
begin
  SchoolOf := true;
  if s = 'abjuration' then v := SCH_ABJUR
  else if s = 'conjuration' then v := SCH_CONJ
  else if s = 'divination' then v := SCH_DIVIN
  else if s = 'enchantment' then v := SCH_ENCHANT
  else if s = 'evocation' then v := SCH_EVOKE
  else if s = 'illusion' then v := SCH_ILLUS
  else if s = 'necromancy' then v := SCH_NECRO
  else if s = 'transmutation' then v := SCH_TRANS
  else if s = 'none' then v := SCH_NONE
  else SchoolOf := false;
end;

function ModeOf(const s: string; out v: byte): boolean;
begin
  ModeOf := true;
  if s = 'enemy' then v := SCM_ENEMY
  else if s = 'rank' then v := SCM_RANK
  else if s = 'ally' then v := SCM_ALLY
  else if s = 'party' then v := SCM_PARTY
  else ModeOf := false;
end;

function EffectOf(const s: string; out v: byte): boolean;
begin
  EffectOf := true;
  if s = 'damage' then v := SCE_DAMAGE
  else if s = 'heal' then v := SCE_HEAL
  else if s = 'bless' then v := SCE_BLESS
  else EffectOf := false;
end;

function FieldKindOf(const s: string; out v: byte): boolean;
begin
  FieldKindOf := true;
  if s = 'heal' then v := FE_HEAL
  else if s = 'curepoison' then v := FE_CUREPOISON
  else if s = 'curedisease' then v := FE_CUREDISEASE
  else if s = 'removecurse' then v := FE_REMOVECURSE
  else if s = 'light' then v := FE_LIGHT
  else if s = 'identify' then v := FE_IDENTIFY
  else if s = 'reveal' then v := FE_REVEAL
  else FieldKindOf := false;
end;

function StatusOf(const s: string; out v: byte): boolean;
begin
  StatusOf := true;
  if s = 'poison' then v := ST_POISON
  else if s = 'stun' then v := ST_STUN
  else if s = 'slow' then v := ST_SLOW
  else if s = 'burn' then v := ST_BURN
  else if s = 'offbal' then v := ST_OFFBAL
  else if s = 'fear' then v := ST_FEAR
  else if s = 'paral' then v := ST_PARAL
  else if s = 'disease' then v := ST_DISEASE
  else StatusOf := false;
end;

{ Parse an "XdY" dice expression; "0d0" is allowed for a diceless effect. }
function DiceOf(const s: string; out dice, sides: byte): boolean;
var p, dv, sv: longint;
begin
  DiceOf := false;
  p := Pos('d', s);
  if p < 2 then exit;
  dv := StrToIntDef(Copy(s, 1, p - 1), -1);
  sv := StrToIntDef(Copy(s, p + 1, Length(s)), -1);
  if (dv < 0) or (sv < 0) then exit;
  dice := dv; sides := sv; DiceOf := true;
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
        ss[cur].castable := false;
        ss[cur].castCost := 0;
        ss[cur].castMode := 0;
        ss[cur].castEffect := 0;
        ss[cur].castDice := 0;
        ss[cur].castSides := 0;
        ss[cur].castInflict := 0;
        ss[cur].school := SCH_NONE;
        ss[cur].icon := 0;
        ss[cur].fieldEffect := FE_NONE;
        ss[cur].fieldArg := 0;
        if not DomainOf(tok[3], ss[cur].domain) then begin
          err := 'line ' + IntToStr(li + 1) + ': bad domain ' + tok[3]; exit;
        end;
        if not SaveOf(tok[5], ss[cur].save) then begin
          err := 'line ' + IntToStr(li + 1) + ': bad save ' + tok[5]; exit;
        end;
        if not DTypeOf(tok[6], ss[cur].dtype) then begin
          err := 'line ' + IntToStr(li + 1) + ': bad damage type ' + tok[6]; exit;
        end;
        { optional seventh column: the arcane school, Magic-User only }
        if n >= 8 then
          if not SchoolOf(tok[7], ss[cur].school) then begin
            err := 'line ' + IntToStr(li + 1) + ': bad school ' + tok[7]; exit;
          end;
      end else if tok[0] = 'comp' then begin
        if cur < 0 then begin err := 'comp before spell'; exit; end;
        ss[cur].components := tok[1];
      end else if tok[0] = 'cast' then begin
        { cast COST MODE EFFECT XdY [inflict STATUS] }
        if cur < 0 then begin err := 'cast before spell'; exit; end;
        if n < 5 then begin
          err := 'line ' + IntToStr(li + 1) + ': cast needs cost mode effect dice';
          exit;
        end;
        ss[cur].castable := true;
        ss[cur].castCost := StrToIntDef(tok[1], 1);
        if not ModeOf(tok[2], ss[cur].castMode) then begin
          err := 'line ' + IntToStr(li + 1) + ': bad cast mode ' + tok[2]; exit;
        end;
        if not EffectOf(tok[3], ss[cur].castEffect) then begin
          err := 'line ' + IntToStr(li + 1) + ': bad cast effect ' + tok[3]; exit;
        end;
        if not DiceOf(tok[4], ss[cur].castDice, ss[cur].castSides) then begin
          err := 'line ' + IntToStr(li + 1) + ': bad cast dice ' + tok[4]; exit;
        end;
        if (n >= 7) and (tok[5] = 'inflict') then
          if not StatusOf(tok[6], ss[cur].castInflict) then begin
            err := 'line ' + IntToStr(li + 1) + ': bad inflict ' + tok[6]; exit;
          end;
      end else if tok[0] = 'icon' then begin
        if cur < 0 then begin err := 'icon before spell'; exit; end;
        ss[cur].icon := StrToIntDef(tok[1], 0);
      end else if tok[0] = 'field' then begin
        { field KIND [arg]: the out-of-combat effect and its optional number }
        if cur < 0 then begin err := 'field before spell'; exit; end;
        if not FieldKindOf(tok[1], ss[cur].fieldEffect) then begin
          err := 'line ' + IntToStr(li + 1) + ': bad field ' + tok[1]; exit;
        end;
        if n >= 3 then ss[cur].fieldArg := StrToIntDef(tok[2], 0);
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
