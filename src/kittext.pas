unit kittext;

{** Parser for the modular kit format, used by the asset tool.

    kit 9 mossy          begin a kit for tileset 9, labelled "mossy"
    floor MOD_FLOOR 4 4  a floor piece, 4x4 grid-unit footprint
    ceil  MOD_CEIL  4 4  a ceiling piece
    wall  MOD_WALL  4 1 3  a wall: 4 units of span, 1 deep, 3 units tall
    pillar MOD_PILLAR 1 1  a pillar

  A piece line is "<role> <LUMP> <fw> <fh> [<fz>] [@N ...] [!N ...]": the role,
  the baked tile lump, the ground footprint in grid units, an optional height
  in units (fz, default 1), and "@N"/"!N" tokens naming the trim atlas and the
  emission atlas for each of the piece's material slots. One "@N" (default 0)
  with an optional "!N" (default none) sets a single-material piece. Several
  "@N" tokens map to successive material slots of a multi-material mesh, so one
  piece clads from more than one sheet, for example a window's stone frame (@0)
  and its glass (@1 !2). The k-th "!N" pairs with the k-th "@N"; use "!-" to
  mark a slot that does not glow so the lists stay aligned. Roles are floor,
  ceil, wall, pillar. Lines attach to the current kit opened by the last "kit"
  line. Blank lines and '#' comments are ignored. }

{$mode objfpc}{$H+}

interface

uses
  tilekit;

function ParseKits(const fn: string; out kits: array of TKit;
  out kitCount: longint; out err: string): boolean;

implementation

uses
  classes, sysutils;

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

function RoleOf(const s: string; out role: byte): boolean;
begin
  RoleOf := true;
  if s = 'floor' then role := KITROLE_FLOOR
  else if s = 'ceil' then role := KITROLE_CEIL
  else if s = 'wall' then role := KITROLE_WALL
  else if s = 'pillar' then role := KITROLE_PILLAR
  else RoleOf := false;
end;

function ParseKits(const fn: string; out kits: array of TKit;
  out kitCount: longint; out err: string): boolean;
var
  lines: TStringList;
  li, n, cur, np, ai: longint;
  tok: array[0 .. 23] of string;
  line: string;
  role: byte;
  pc: TKitPiece;
  alist, elist: array of longint;
begin
  ParseKits := false; err := ''; kitCount := 0; cur := -1;
  for li := 0 to High(kits) do begin
    kits[li].pieces := nil;
    kits[li].tileset := 0;
    kits[li].name := '';
  end;

  lines := TStringList.Create;
  try
    lines.LoadFromFile(fn);
    for li := 0 to lines.Count - 1 do begin
      line := Trim(lines[li]);
      if (line = '') or (line[1] = '#') then continue;
      Split(line, tok, n);
      if n = 0 then continue;

      if tok[0] = 'kit' then begin
        if n < 3 then begin
          err := 'line ' + IntToStr(li + 1) + ': kit needs a tileset and a name';
          exit;
        end;
        if kitCount > High(kits) then begin
          err := 'line ' + IntToStr(li + 1) + ': too many kits';
          exit;
        end;
        cur := kitCount;
        kits[cur].tileset := StrToIntDef(tok[1], 0);
        kits[cur].name := tok[2];
        kits[cur].pieces := nil;
        inc(kitCount);
      end else if RoleOf(tok[0], role) then begin
        if cur < 0 then begin
          err := 'line ' + IntToStr(li + 1) + ': piece before any kit';
          exit;
        end;
        if n < 4 then begin
          err := 'line ' + IntToStr(li + 1) + ': piece needs a lump and a footprint';
          exit;
        end;
        pc.role := role;
        pc.lump := UpperCase(tok[1]);
        pc.fw := StrToIntDef(tok[2], 1);
        pc.fh := StrToIntDef(tok[3], 1);
        { fz is the optional 5th field. "@N" and "!N" tokens past the footprint
          name the trim atlas and the emission atlas for one material slot. A
          single pair sets the whole (single-material) piece; several map to
          successive material slots, so a multi-material mesh clads from more
          than one sheet, for example a window's stone frame (@0) and glass
          (@1 !2). "!-" marks a slot that does not glow, so the emission tokens
          stay lined up with the atlas tokens. }
        pc.fz := 1;
        alist := nil; elist := nil;
        for ai := 4 to n - 1 do
          if (Length(tok[ai]) >= 1) and (tok[ai][1] = '@') then begin
            SetLength(alist, Length(alist) + 1);
            alist[High(alist)] := StrToIntDef(Copy(tok[ai], 2, 8), 0);
          end else if (Length(tok[ai]) >= 1) and (tok[ai][1] = '!') then begin
            SetLength(elist, Length(elist) + 1);
            elist[High(elist)] := StrToIntDef(Copy(tok[ai], 2, 8), 255);
          end else if ai = 4 then
            pc.fz := StrToIntDef(tok[ai], 1);
        { slot 0 is the base atlas and emis; each further "@" adds a slot. The
          k-th emission token pairs with the k-th atlas token; a missing one is
          none (255). }
        if Length(alist) >= 1 then pc.atlas := alist[0] else pc.atlas := 0;
        if Length(elist) >= 1 then pc.emis := elist[0] else pc.emis := 255;
        pc.xatlas := nil; pc.xemis := nil;
        for ai := 1 to High(alist) do begin
          SetLength(pc.xatlas, ai); SetLength(pc.xemis, ai);
          pc.xatlas[ai - 1] := alist[ai];
          if ai <= High(elist) then pc.xemis[ai - 1] := elist[ai]
          else pc.xemis[ai - 1] := 255;
        end;
        np := Length(kits[cur].pieces);
        SetLength(kits[cur].pieces, np + 1);
        kits[cur].pieces[np] := pc;
      end else begin
        err := 'line ' + IntToStr(li + 1) + ': unknown directive ' + tok[0];
        exit;
      end;
    end;
  finally
    lines.Free;
  end;
  ParseKits := true;
end;

end.
