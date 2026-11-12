unit chartext;

{** Parsers for the species, class, background and gear text tables.

  species ID "Name" STR DEX CON INT WIS CHA FLAGS XP
  class   ID "Name" TRACK HITDIE PRIME KIT
  bg      ID "Name" "skill or situation"
  common       LIGHT [item:count ...]
  kit ARCHETYPE MAIN OFF ARMOR [item:count ...]

  TRACK is warrior/priest/specialist/mage, PRIME is an ability name,
  KIT and ARCHETYPE are soldier/heavy/archer/priest/thief/mage. In a gear
  row, '-' leaves an equip slot bare. Blank lines and lines starting with
  '#' are ignored. }

{$mode objfpc}{$H+}

interface

uses
  chardata;

function ParseSpecies(const fn: string; out defs: array of TSpeciesDef;
  out count: longint; out err: string): boolean;
function ParseClasses(const fn: string; out defs: array of TClassDef;
  out count: longint; out err: string): boolean;
function ParseBackgrounds(const fn: string; out defs: array of TBackgroundDef;
  out count: longint; out err: string): boolean;
function ParseGear(const fn: string; out defs: array of TGearDef;
  out count: longint; out err: string): boolean;
function ParseNewGame(const fn: string; out d: TNewGameData;
  out err: string): boolean;

implementation

uses
  classes, sysutils, spelldb;

procedure QTokenize(const line: string; out tok: array of string; out n: longint);
var
  i, len, start: longint;
begin
  n := 0;
  len := Length(line);
  i := 1;
  while i <= len do begin
    while (i <= len) and (line[i] = ' ') do inc(i);
    if i > len then break;
    if line[i] = '"' then begin
      inc(i);
      start := i;
      while (i <= len) and (line[i] <> '"') do inc(i);
      if n <= High(tok) then tok[n] := Copy(line, start, i - start);
      inc(n);
      if i <= len then inc(i);   { skip closing quote }
    end else begin
      start := i;
      while (i <= len) and (line[i] <> ' ') do inc(i);
      if n <= High(tok) then tok[n] := Copy(line, start, i - start);
      inc(n);
    end;
  end;
end;

function TrackCode(const s: string): longint;
begin
  if s = 'warrior' then TrackCode := TRK_WARRIOR
  else if s = 'priest' then TrackCode := TRK_PRIEST
  else if s = 'specialist' then TrackCode := TRK_SPECIALIST
  else if s = 'mage' then TrackCode := TRK_MAGE
  else TrackCode := -1;
end;

function DomainCode(const s: string): longint;
begin
  if s = 'none' then DomainCode := SPD_NONE
  else if s = 'cleric' then DomainCode := SPD_CLERIC
  else if s = 'druid' then DomainCode := SPD_DRUID
  else if s = 'magicuser' then DomainCode := SPD_MAGE
  else DomainCode := -1;
end;

function SchoolCode(const s: string): longint;
begin
  if s = 'none' then SchoolCode := SCH_NONE
  else if s = 'abjuration' then SchoolCode := SCH_ABJUR
  else if s = 'conjuration' then SchoolCode := SCH_CONJ
  else if s = 'divination' then SchoolCode := SCH_DIVIN
  else if s = 'enchantment' then SchoolCode := SCH_ENCHANT
  else if s = 'evocation' then SchoolCode := SCH_EVOKE
  else if s = 'illusion' then SchoolCode := SCH_ILLUS
  else if s = 'necromancy' then SchoolCode := SCH_NECRO
  else if s = 'transmutation' then SchoolCode := SCH_TRANS
  else SchoolCode := -1;
end;

function KitCode(const s: string): longint;
begin
  if s = 'soldier' then KitCode := KIT_SOLDIER
  else if s = 'heavy' then KitCode := KIT_HEAVY
  else if s = 'archer' then KitCode := KIT_ARCHER
  else if s = 'priest' then KitCode := KIT_PRIEST
  else if s = 'thief' then KitCode := KIT_THIEF
  else if s = 'mage' then KitCode := KIT_MAGE
  else KitCode := -1;
end;

function AbilCode(const s: string): longint;
begin
  if s = 'STR' then AbilCode := 0
  else if s = 'DEX' then AbilCode := 1
  else if s = 'CON' then AbilCode := 2
  else if s = 'INT' then AbilCode := 3
  else if s = 'WIS' then AbilCode := 4
  else if s = 'CHA' then AbilCode := 5
  else AbilCode := -1;
end;

function OpenLines(const fn: string): TStringList;
begin
  OpenLines := TStringList.Create;
  OpenLines.LoadFromFile(fn);
end;

function ParseSpecies(const fn: string; out defs: array of TSpeciesDef;
  out count: longint; out err: string): boolean;
var
  lines: TStringList;
  li, n, k: longint;
  tok: array[0 .. 15] of string;
  line: string;
  d: TSpeciesDef;
begin
  ParseSpecies := false; err := ''; count := 0;
  lines := OpenLines(fn);
  try
    for li := 0 to lines.Count - 1 do begin
      line := Trim(lines[li]);
      if (line = '') or (line[1] = '#') then continue;
      QTokenize(line, tok, n);
      if (n < 11) or (tok[0] <> 'species') then begin
        err := 'line ' + IntToStr(li + 1) + ': bad species row'; exit;
      end;
      d.id := tok[1];
      d.name := tok[2];
      for k := 0 to 5 do d.abilBonus[k] := StrToInt(tok[3 + k]);
      d.flags := StrToInt(tok[9]);
      d.xpBonus := StrToInt(tok[10]);
      if count > High(defs) then begin err := 'too many species'; exit; end;
      defs[count] := d; inc(count);
    end;
  finally
    lines.Free;
  end;
  ParseSpecies := true;
end;

function ParseClasses(const fn: string; out defs: array of TClassDef;
  out count: longint; out err: string): boolean;
var
  lines: TStringList;
  li, n, tc, pc, kc, dc, sc: longint;
  tok: array[0 .. 15] of string;
  line: string;
  d: TClassDef;
begin
  ParseClasses := false; err := ''; count := 0;
  lines := OpenLines(fn);
  try
    for li := 0 to lines.Count - 1 do begin
      line := Trim(lines[li]);
      if (line = '') or (line[1] = '#') then continue;
      QTokenize(line, tok, n);
      if (n < 7) or (tok[0] <> 'class') then begin
        err := 'line ' + IntToStr(li + 1) + ': bad class row'; exit;
      end;
      tc := TrackCode(tok[3]);
      pc := AbilCode(tok[5]);
      kc := KitCode(tok[6]);
      if (tc < 0) or (pc < 0) or (kc < 0) then begin
        err := 'line ' + IntToStr(li + 1) + ': bad track/prime/kit'; exit;
      end;
      { domain is optional: a seventh column, defaulting to none }
      if n >= 8 then dc := DomainCode(tok[7]) else dc := SPD_NONE;
      if dc < 0 then begin
        err := 'line ' + IntToStr(li + 1) + ': bad domain ' + tok[7]; exit;
      end;
      { school is optional: an eighth column, defaulting to none }
      if n >= 9 then sc := SchoolCode(tok[8]) else sc := SCH_NONE;
      if sc < 0 then begin
        err := 'line ' + IntToStr(li + 1) + ': bad school ' + tok[8]; exit;
      end;
      d.id := tok[1];
      d.name := tok[2];
      d.track := tc;
      d.hitDie := StrToInt(tok[4]);
      d.prime := pc;
      d.kit := kc;
      d.domain := dc;
      d.school := sc;
      if count > High(defs) then begin err := 'too many classes'; exit; end;
      defs[count] := d; inc(count);
    end;
  finally
    lines.Free;
  end;
  ParseClasses := true;
end;

function ParseBackgrounds(const fn: string; out defs: array of TBackgroundDef;
  out count: longint; out err: string): boolean;
var
  lines: TStringList;
  li, n: longint;
  tok: array[0 .. 15] of string;
  line: string;
  d: TBackgroundDef;
begin
  ParseBackgrounds := false; err := ''; count := 0;
  lines := OpenLines(fn);
  try
    for li := 0 to lines.Count - 1 do begin
      line := Trim(lines[li]);
      if (line = '') or (line[1] = '#') then continue;
      QTokenize(line, tok, n);
      if (n < 4) or (tok[0] <> 'bg') then begin
        err := 'line ' + IntToStr(li + 1) + ': bad background row'; exit;
      end;
      d.id := tok[1];
      d.name := tok[2];
      d.skill := tok[3];
      if n >= 5 then d.gold := tok[4] else d.gold := '';
      if count > High(defs) then begin err := 'too many backgrounds'; exit; end;
      defs[count] := d; inc(count);
    end;
  finally
    lines.Free;
  end;
  ParseBackgrounds := true;
end;

{ A dash marks an empty equip slot; map it to the empty string. }
function Deq(const s: string): string;
begin
  if s = '-' then Deq := '' else Deq := s;
end;

function ParseGear(const fn: string; out defs: array of TGearDef;
  out count: longint; out err: string): boolean;
var
  lines: TStringList;
  li, n, ti, kc, cp: longint;
  tok: array[0 .. 15] of string;
  line: string;
  d: TGearDef;
  firstPack: longint;
begin
  ParseGear := false; err := ''; count := 0;
  lines := OpenLines(fn);
  try
    for li := 0 to lines.Count - 1 do begin
      line := Trim(lines[li]);
      if (line = '') or (line[1] = '#') then continue;
      QTokenize(line, tok, n);
      d.kit := GEAR_COMMON;
      d.main := ''; d.off := ''; d.armor := ''; d.light := ''; d.packN := 0;
      if tok[0] = 'common' then begin
        if n < 2 then begin
          err := 'line ' + IntToStr(li + 1) + ': bad common row'; exit;
        end;
        d.light := Deq(tok[1]);
        firstPack := 2;
      end else if tok[0] = 'kit' then begin
        if n < 5 then begin
          err := 'line ' + IntToStr(li + 1) + ': bad gear row'; exit;
        end;
        kc := KitCode(tok[1]);
        if kc < 0 then begin
          err := 'line ' + IntToStr(li + 1) + ': bad kit ' + tok[1]; exit;
        end;
        d.kit := kc;
        d.main := Deq(tok[2]); d.off := Deq(tok[3]); d.armor := Deq(tok[4]);
        firstPack := 5;
      end else begin
        err := 'line ' + IntToStr(li + 1) + ': bad gear row'; exit;
      end;
      for ti := firstPack to n - 1 do begin
        if d.packN > High(d.pack) then begin
          err := 'line ' + IntToStr(li + 1) + ': too many pack items'; exit;
        end;
        cp := Pos(':', tok[ti]);
        if cp <= 0 then begin
          err := 'line ' + IntToStr(li + 1) + ': bad pack item ' + tok[ti]; exit;
        end;
        d.pack[d.packN].id := Copy(tok[ti], 1, cp - 1);
        d.pack[d.packN].qty := StrToInt(Copy(tok[ti], cp + 1, Length(tok[ti]) - cp));
        inc(d.packN);
      end;
      if count > High(defs) then begin err := 'too many gear rows'; exit; end;
      defs[count] := d; inc(count);
    end;
  finally
    lines.Free;
  end;
  ParseGear := true;
end;

function ParseNewGame(const fn: string; out d: TNewGameData;
  out err: string): boolean;
var
  lines: TStringList;
  li, n, nameN, pregN: longint;
  tok: array[0 .. 15] of string;
  line: string;
begin
  ParseNewGame := false; err := '';
  SetLength(d.names, 0); SetLength(d.pregen, 0);
  d.defSpecies := ''; d.defClass := '';
  nameN := 0; pregN := 0;
  lines := OpenLines(fn);
  try
    for li := 0 to lines.Count - 1 do begin
      line := Trim(lines[li]);
      if (line = '') or (line[1] = '#') then continue;
      QTokenize(line, tok, n);
      if (tok[0] = 'name') and (n >= 2) then begin
        SetLength(d.names, nameN + 1);
        d.names[nameN] := tok[1]; inc(nameN);
      end else if (tok[0] = 'pregen') and (n >= 3) then begin
        SetLength(d.pregen, pregN + 1);
        d.pregen[pregN].species := tok[1];
        d.pregen[pregN].klass := tok[2]; inc(pregN);
      end else if (tok[0] = 'default') and (n >= 3) then begin
        d.defSpecies := tok[1];
        d.defClass := tok[2];
      end else begin
        err := 'line ' + IntToStr(li + 1) + ': bad newgame row'; exit;
      end;
    end;
  finally
    lines.Free;
  end;
  ParseNewGame := true;
end;

end.
