unit testing;

{** A tiny assertion helper for the engine test programs.

  Each test program makes Check or CheckEqI calls, then ends with
  TestSummary and halt(TestExit). A failed check sets a nonzero exit
  code, which the make test target turns into a build failure. }

{$mode objfpc}{$H+}

interface

procedure Check(cond: boolean; const name: string);
procedure CheckEqI(got, want: longint; const name: string);
procedure TestSummary(const suite: string);
function TestExit: longint;

implementation

var
  passed: longint = 0;
  failed: longint = 0;

procedure Check(cond: boolean; const name: string);
begin
  if cond then begin
    inc(passed);
    writeln('  ok   ', name);
  end else begin
    inc(failed);
    writeln('  FAIL ', name);
  end;
end;

procedure CheckEqI(got, want: longint; const name: string);
begin
  if got = want then begin
    inc(passed);
    writeln('  ok   ', name, ' (= ', got, ')');
  end else begin
    inc(failed);
    writeln('  FAIL ', name, ' got ', got, ' want ', want);
  end;
end;

procedure TestSummary(const suite: string);
begin
  writeln(suite, ': ', passed, ' passed, ', failed, ' failed');
end;

function TestExit: longint;
begin
  if failed > 0 then TestExit := 1 else TestExit := 0;
end;

end.
