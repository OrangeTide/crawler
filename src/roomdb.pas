unit roomdb;

{** A modular room: a hand-placed list of kit pieces.

  This is the pre-format proof for theme G. A room is a flat list of
  placements, each naming a baked tile mesh and giving its position, a
  yaw about Z, and a uniform scale. The polygon renderer instances the
  pieces over the world through the same mesh path props use, drawing
  every piece from the one resident trim atlas.

  The authored source is a plain text file, one piece per line:

    model  x y z  yaw  [scale]

  with '#' comments and blank lines ignored. yaw is in degrees, scale
  defaults to 1. The sector map format (0.27.0) will supersede this with
  real sector geometry; for now it proves the look and the budget. }

{$mode objfpc}{$H+}

interface

type
  TRoomPiece = record
    model: string[16];        { the baked tile lump to instance }
    x, y, z: single;          { world position, Z up }
    yaw: single;              { heading in radians }
    scale: single;            { uniform scale, world units per model unit }
  end;

  TRoom = array of TRoomPiece;

{ Parse room text (the whole file as one string) into a placement list.
  Returns true if at least one piece parsed. Malformed lines are skipped. }
function ParseRoom(const text: string; out room: TRoom): boolean;

implementation

uses
  sysutils, classes, math;

{ Split a line into whitespace-separated tokens. }
procedure SplitWS(const s: string; out tok: array of string; out ntok: longint);
var i, start: longint; inWord: boolean;
begin
  ntok := 0; start := 1; inWord := false;
  for i := 1 to Length(s) do begin
    if (s[i] = ' ') or (s[i] = #9) or (s[i] = #13) then begin
      if inWord then begin
        if ntok <= High(tok) then begin tok[ntok] := Copy(s, start, i - start); inc(ntok); end;
        inWord := false;
      end;
    end else if not inWord then begin start := i; inWord := true; end;
  end;
  if inWord and (ntok <= High(tok)) then begin
    tok[ntok] := Copy(s, start, Length(s) - start + 1); inc(ntok);
  end;
end;

function ParseRoom(const text: string; out room: TRoom): boolean;
var
  lines: TStringList;
  li, ntok, n: longint;
  tok: array[0 .. 15] of string;
  p: TRoomPiece;
  line: string;
begin
  room := nil;
  n := 0;
  lines := TStringList.Create;
  try
    lines.Text := text;
    for li := 0 to lines.Count - 1 do begin
      line := lines[li];
      SplitWS(line, tok, ntok);
      if ntok = 0 then continue;
      if tok[0][1] = '#' then continue;
      { model x y z yaw [scale] }
      if ntok < 5 then continue;
      p.model := UpperCase(tok[0]);
      p.x := StrToFloatDef(tok[1], 0);
      p.y := StrToFloatDef(tok[2], 0);
      p.z := StrToFloatDef(tok[3], 0);
      p.yaw := DegToRad(StrToFloatDef(tok[4], 0));
      if ntok >= 6 then p.scale := StrToFloatDef(tok[5], 1) else p.scale := 1;
      SetLength(room, n + 1);
      room[n] := p;
      inc(n);
    end;
  finally
    lines.Free;
  end;
  ParseRoom := n > 0;
end;

end.
