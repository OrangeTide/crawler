unit shoptext;

{** Parser for the shop stock format, used by the asset tool.

    shop GENERAL DAGGER SWORD MACE ...
    shop APOTHECARY POTION HOLLY HOLYSYM

  A line names a shop id and the item ids it stocks, in order. A shop may
  be continued over several lines by repeating its id; the items append.
  Blank lines and '#' comments are ignored. }

{$mode objfpc}{$H+}

interface

uses
  shops;

function ParseShops(const fn: string; out cs: array of TShopDef;
  out count: longint; out err: string): boolean;

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

function FindShop(const cs: array of TShopDef; count: longint;
  const id: string): longint;
var i: longint;
begin
  FindShop := -1;
  for i := 0 to count - 1 do
    if cs[i].id = id then begin FindShop := i; exit; end;
end;

function ParseShops(const fn: string; out cs: array of TShopDef;
  out count: longint; out err: string): boolean;
var
  lines: TStringList;
  li, n, si, k: longint;
  tok: array[0 .. 31] of string;
  line: string;
begin
  ParseShops := false; err := ''; count := 0;
  lines := TStringList.Create;
  try
    lines.LoadFromFile(fn);
    for li := 0 to lines.Count - 1 do begin
      line := Trim(lines[li]);
      if (line = '') or (line[1] = '#') then continue;
      Split(line, tok, n);
      if n = 0 then continue;
      if tok[0] <> 'shop' then begin
        err := 'line ' + IntToStr(li + 1) + ': expected shop'; exit;
      end;
      if n < 2 then begin
        err := 'line ' + IntToStr(li + 1) + ': shop needs an id'; exit;
      end;
      si := FindShop(cs, count, tok[1]);
      if si < 0 then begin
        if count > High(cs) then begin err := 'too many shops'; exit; end;
        si := count; inc(count);
        cs[si].id := tok[1];
        cs[si].items := nil;
      end;
      for k := 2 to n - 1 do begin
        SetLength(cs[si].items, Length(cs[si].items) + 1);
        cs[si].items[High(cs[si].items)] := tok[k];
      end;
    end;
  finally
    lines.Free;
  end;
  ParseShops := true;
end;

end.
