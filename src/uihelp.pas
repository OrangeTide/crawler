unit uihelp;

{** Shared text-layout helpers for the UI units: centered and word-wrapped
  text, drawn against the framebuffer. }

{$mode objfpc}{$H+}

interface

uses
  gfx;

procedure DrawCenter(y: longint; const s: string; c: TColor);
procedure DrawWrapped(x, y, widthChars: longint; const s: string; c: TColor);

implementation

procedure DrawCenter(y: longint; const s: string; c: TColor);
begin
  DrawText((FBW - Length(s) * 6) div 2, y, s, c);
end;

procedure DrawWrapped(x, y, widthChars: longint; const s: string; c: TColor);
{** Draw text word-wrapped to widthChars columns, 10px line pitch. }
var
  words: array[0 .. 63] of string;
  nw, i, start, len, ln: longint;
  line, w: string;
begin
  { split into words }
  nw := 0; start := 1; len := Length(s);
  for i := 1 to len + 1 do
    if (i > len) or (s[i] = ' ') then begin
      if (i > start) and (nw <= High(words)) then begin
        words[nw] := Copy(s, start, i - start);
        inc(nw);
      end;
      start := i + 1;
    end;
  line := ''; ln := 0;
  for i := 0 to nw - 1 do begin
    w := words[i];
    if (line <> '') and (Length(line) + 1 + Length(w) > widthChars) then begin
      DrawText(x, y + ln * 10, line, c);
      inc(ln);
      line := w;
    end else if line = '' then
      line := w
    else
      line := line + ' ' + w;
  end;
  if line <> '' then
    DrawText(x, y + ln * 10, line, c);
end;

end.
