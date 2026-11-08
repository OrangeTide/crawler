unit skilltext;

{** Parser for the skill catalog text format, used by the asset tool.

    skill ID "Name" ARENA EFFECT ABILITY TARGET GATE
      uses N            (combat uses per encounter; default 0 = at-will)
      dice XdY          (effect magnitude; default 0d0)
      icon N            (skill icon number; default 0)
      "the effect prose"

  ARENA is explore or combat; EFFECT names the engine behaviour (picklock,
  findtraps, movesilent, mend, powerattack, disarm, bash, aimedshot, rally);
  ABILITY is str, dex, con, int, wis or cha; TARGET is the base d20 difficulty;
  GATE is any, thief or martial. The effect prose is a bare quoted line. Blank
  lines and '#' comments are ignored. }

{$mode objfpc}{$H+}

interface

uses
  skilldb;

function ParseSkills(const fn: string; out ss: array of TSkillDef;
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

function ArenaOf(const s: string; out v: byte): boolean;
begin
  ArenaOf := true;
  if s = 'explore' then v := SKA_EXPLORE
  else if s = 'combat' then v := SKA_COMBAT
  else ArenaOf := false;
end;

function EffectOf(const s: string; out v: byte): boolean;
begin
  EffectOf := true;
  if s = 'picklock' then v := SKE_PICKLOCK
  else if s = 'findtraps' then v := SKE_FINDTRAPS
  else if s = 'movesilent' then v := SKE_MOVESILENT
  else if s = 'mend' then v := SKE_MEND
  else if s = 'powerattack' then v := SKE_POWERATTACK
  else if s = 'disarm' then v := SKE_DISARM
  else if s = 'bash' then v := SKE_BASH
  else if s = 'aimedshot' then v := SKE_AIMEDSHOT
  else if s = 'rally' then v := SKE_RALLY
  else EffectOf := false;
end;

function AbilityOf(const s: string; out v: byte): boolean;
begin
  AbilityOf := true;
  if s = 'str' then v := 0
  else if s = 'dex' then v := 1
  else if s = 'con' then v := 2
  else if s = 'int' then v := 3
  else if s = 'wis' then v := 4
  else if s = 'cha' then v := 5
  else AbilityOf := false;
end;

function GateOf(const s: string; out v: byte): boolean;
begin
  GateOf := true;
  if s = 'any' then v := SKG_ANY
  else if s = 'thief' then v := SKG_THIEF
  else if s = 'martial' then v := SKG_MARTIAL
  else GateOf := false;
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

function ParseSkills(const fn: string; out ss: array of TSkillDef;
  out count: longint; out err: string): boolean;
var
  lines: TStringList;
  li, n, cur: longint;
  tok: array[0 .. 7] of string;
  line: string;
begin
  ParseSkills := false; err := ''; count := 0; cur := -1;
  lines := TStringList.Create;
  try
    lines.LoadFromFile(fn);
    for li := 0 to lines.Count - 1 do begin
      line := Trim(lines[li]);
      if (line = '') or (line[1] = '#') then continue;
      QTok(line, tok, n);
      if n = 0 then continue;

      if tok[0] = 'skill' then begin
        if count > High(ss) then begin err := 'too many skills'; exit; end;
        if n < 8 then begin
          err := 'line ' + IntToStr(li + 1)
            + ': skill needs ID name arena effect ability target gate';
          exit;
        end;
        inc(count); cur := count - 1;
        ss[cur].id := tok[1];
        ss[cur].name := tok[2];
        ss[cur].target := StrToIntDef(tok[6], 12);
        ss[cur].maxUses := 0;
        ss[cur].dice := 0;
        ss[cur].sides := 0;
        ss[cur].icon := 0;
        ss[cur].effectText := '';
        if not ArenaOf(tok[3], ss[cur].arena) then begin
          err := 'line ' + IntToStr(li + 1) + ': bad arena ' + tok[3]; exit;
        end;
        if not EffectOf(tok[4], ss[cur].effect) then begin
          err := 'line ' + IntToStr(li + 1) + ': bad effect ' + tok[4]; exit;
        end;
        if not AbilityOf(tok[5], ss[cur].ability) then begin
          err := 'line ' + IntToStr(li + 1) + ': bad ability ' + tok[5]; exit;
        end;
        if not GateOf(tok[7], ss[cur].gate) then begin
          err := 'line ' + IntToStr(li + 1) + ': bad gate ' + tok[7]; exit;
        end;
      end else if tok[0] = 'uses' then begin
        if cur < 0 then begin err := 'uses before skill'; exit; end;
        ss[cur].maxUses := StrToIntDef(tok[1], 0);
      end else if tok[0] = 'dice' then begin
        if cur < 0 then begin err := 'dice before skill'; exit; end;
        if not DiceOf(tok[1], ss[cur].dice, ss[cur].sides) then begin
          err := 'line ' + IntToStr(li + 1) + ': bad dice ' + tok[1]; exit;
        end;
      end else if tok[0] = 'icon' then begin
        if cur < 0 then begin err := 'icon before skill'; exit; end;
        ss[cur].icon := StrToIntDef(tok[1], 0);
      end else if line[1] = '"' then begin
        if cur < 0 then begin err := 'effect before skill'; exit; end;
        ss[cur].effectText := tok[0];
      end else begin
        err := 'line ' + IntToStr(li + 1) + ': unknown keyword ' + tok[0];
        exit;
      end;
    end;
  finally
    lines.Free;
  end;
  ParseSkills := true;
end;

end.
