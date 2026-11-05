unit dice;

{** A small dice and arithmetic expression evaluator for data files.

  Expressions combine integers, dice and the operators + - * /, so a data
  field can read "10*3d6", "2d6+5" or a plain "100". NdM rolls N dice of M
  sides and sums them; a leading d means one die (d6 = 1d6). Precedence,
  tightest first: d, then * and /, then + and -. Parentheses group.

  EvalDice returns false on a malformed expression (and leaves value 0),
  so callers can treat bad data as zero rather than trusting a partial
  parse. Dice are drawn from the given rng stream. }

{$mode objfpc}{$H+}

interface

uses
  rng;

function EvalDice(var r: TRng; const s: string; out value: longint): boolean;

implementation

uses
  sysutils;

type
  TParser = record
    s: string;
    pos: longint;
    ok: boolean;
  end;

procedure SkipWs(var p: TParser);
begin
  while (p.pos <= Length(p.s)) and (p.s[p.pos] = ' ') do inc(p.pos);
end;

{ The next non-space character without consuming it, or #0 at the end. }
function Peek(var p: TParser): char;
begin
  SkipWs(p);
  if p.pos <= Length(p.s) then Peek := p.s[p.pos] else Peek := #0;
end;

function ParseExpr(var p: TParser; var r: TRng): longint; forward;

function ParseNumber(var p: TParser): longint;
var start: longint;
begin
  SkipWs(p);
  start := p.pos;
  while (p.pos <= Length(p.s)) and (p.s[p.pos] >= '0') and (p.s[p.pos] <= '9') do
    inc(p.pos);
  if p.pos = start then begin p.ok := false; ParseNumber := 0; exit; end;
  ParseNumber := StrToIntDef(Copy(p.s, start, p.pos - start), 0);
end;

function ParseAtom(var p: TParser; var r: TRng): longint;
var v: longint;
begin
  if Peek(p) = '(' then begin
    inc(p.pos);
    v := ParseExpr(p, r);
    if Peek(p) = ')' then inc(p.pos) else p.ok := false;
    ParseAtom := v;
  end else
    ParseAtom := ParseNumber(p);
end;

{ A dice factor: atom, optionally followed by d and a sides atom. }
function ParseDice(var p: TParser; var r: TRng): longint;
var
  left, sides: longint;
  c: char;
begin
  c := Peek(p);
  if (c = 'd') or (c = 'D') then left := 1 else left := ParseAtom(p, r);
  if not p.ok then begin ParseDice := 0; exit; end;
  c := Peek(p);
  if (c = 'd') or (c = 'D') then begin
    inc(p.pos);
    sides := ParseAtom(p, r);
    if (not p.ok) or (sides < 1) then begin p.ok := false; ParseDice := 0; exit; end;
    if left < 0 then left := 0;
    ParseDice := RngRoll(r, left, sides);
  end else
    ParseDice := left;
end;

function ParseTerm(var p: TParser; var r: TRng): longint;
var
  v, rhs: longint;
  c: char;
begin
  v := ParseDice(p, r);
  while p.ok do begin
    c := Peek(p);
    if c = '*' then begin
      inc(p.pos); rhs := ParseDice(p, r); v := v * rhs;
    end else if c = '/' then begin
      inc(p.pos); rhs := ParseDice(p, r);
      if rhs = 0 then p.ok := false else v := v div rhs;
    end else
      break;
  end;
  ParseTerm := v;
end;

function ParseExpr(var p: TParser; var r: TRng): longint;
var
  v, rhs: longint;
  c: char;
begin
  v := ParseTerm(p, r);
  while p.ok do begin
    c := Peek(p);
    if c = '+' then begin
      inc(p.pos); rhs := ParseTerm(p, r); v := v + rhs;
    end else if c = '-' then begin
      inc(p.pos); rhs := ParseTerm(p, r); v := v - rhs;
    end else
      break;
  end;
  ParseExpr := v;
end;

function EvalDice(var r: TRng; const s: string; out value: longint): boolean;
var p: TParser;
begin
  p.s := s; p.pos := 1; p.ok := true;
  value := ParseExpr(p, r);
  SkipWs(p);
  if p.pos <= Length(p.s) then p.ok := false;   { trailing junk: reject }
  if not p.ok then value := 0;
  EvalDice := p.ok;
end;

end.
