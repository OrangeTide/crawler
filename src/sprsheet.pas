unit sprsheet;

{** Slice a grid sprite sheet into sprite banks (offline, tool side).

  Many character packs ship one PNG laid out as a uniform grid of cells: a
  column per character and a row per animation frame, or a row per named
  action. This parses a sheet manifest that names the grid and carves it into
  one or more banks, so a whole multi-character sheet bakes from a single file.

  The sheet is a binary PPM (converted from the pack PNG and flattened onto the
  magenta key, as the sprite pipeline does), read once. Each cell is keyed on
  magenta (255,0,255) for transparency and encoded to a CPIC blob, the same
  frame format the plain bank baker produces.

  Manifest grammar (blank lines and '#' comments ignored):

    sheet  <ppm path, relative to the manifest>
    cell   <w> <h>
    bank   <LUMP>
    seq    NAME [loop|once|pingpong] [mirror] [ticks=N] [ox=N] [oy=N] : <run>
    ...

  A 'bank' line opens a new bank; the 'seq' lines after it are its sequences,
  until the next 'bank' or end of file. A sequence's <run> lists the cells that
  make up its frames, in order, as one of:

    col C rows A-B     a column run, rows A through B going down
    row R cols A-B     a row run, columns A through B going right
    C,R C,R ...        explicit cell coordinates (column,row), for odd layouts

  Rows and columns are zero based. All frames in a sequence share the cell
  size, so a sequence's width and height are the cell size. }

{$mode objfpc}{$H+}

interface

uses
  sprbank;

type
  TSheetBankRef = record
    name: string;
    bank: TSpriteBank;
  end;
  TSheetBankArray = array of TSheetBankRef;

{ Parse the sheet manifest at fn into banks. False with err set on any error. }
function ParseSheet(const fn: string; out banks: TSheetBankArray;
  out err: string): boolean;

implementation

uses
  classes, sysutils, gfx, pic, pak, meshfmt;

{ Encode one grid cell (col,row) of the sheet to a CPIC blob, keying magenta to
  transparent. The sheet pixels are RGB triples, w by h. }
function CellBlob(const pix: TByteArray; sw, sh, cellW, cellH, col, row: longint;
  out blob: TByteArray; out err: string): boolean;
var
  img: TImage;
  cx, cy, ox, oy, si, di: longint;
  r, g, b: byte;
begin
  CellBlob := false; err := '';
  ox := col * cellW; oy := row * cellH;
  if (ox + cellW > sw) or (oy + cellH > sh) then begin
    err := 'cell ' + IntToStr(col) + ',' + IntToStr(row) + ' is off the sheet';
    exit;
  end;
  ImgNew(img, cellW, cellH);
  img.hasAlpha := true;
  for cy := 0 to cellH - 1 do
    for cx := 0 to cellW - 1 do begin
      si := ((oy + cy) * sw + (ox + cx)) * 3;
      di := cy * cellW + cx;
      r := pix[si]; g := pix[si + 1]; b := pix[si + 2];
      if (r = 255) and (g = 0) and (b = 255) then
        img.pix[di] := 0
      else
        img.pix[di] := RGB(r, g, b);
    end;
  blob := PicEncodeDirect(img);
  CellBlob := true;
end;

{ Split s on the first ':' into head and tail; tail empty if no colon. }
procedure SplitColon(const s: string; out head, tail: string);
var c: longint;
begin
  c := Pos(':', s);
  if c > 0 then begin
    head := Trim(Copy(s, 1, c - 1));
    tail := Trim(Copy(s, c + 1, Length(s)));
  end else begin
    head := Trim(s); tail := '';
  end;
end;

{ Split on spaces into tok[0..n-1]. }
procedure Tokenize(const s: string; out tok: array of string; out n: longint);
var i, len, start: longint;
begin
  n := 0; len := Length(s); i := 1;
  while i <= len do begin
    while (i <= len) and (s[i] = ' ') do inc(i);
    if i > len then break;
    start := i;
    while (i <= len) and (s[i] <> ' ') do inc(i);
    if n <= High(tok) then tok[n] := Copy(s, start, i - start);
    inc(n);
  end;
end;

{ Expand a cell run into parallel (cols,rows) lists. Returns the frame count,
  or -1 with err set. }
function ExpandRun(const tail: string; out cols, rows: array of longint;
  out err: string): longint;
var
  tok: array[0 .. 63] of string;
  n, i, a, b, fixed, cp, nf: longint;
begin
  ExpandRun := -1; err := '';
  Tokenize(tail, tok, n);
  if n = 0 then begin err := 'empty frame run'; exit; end;
  nf := 0;
  if (tok[0] = 'col') or (tok[0] = 'row') then begin
    { col C rows A-B  |  row R cols A-B }
    if n < 4 then begin err := 'run needs: ' + tok[0] + ' N rows/cols A-B'; exit; end;
    fixed := StrToIntDef(tok[1], -1);
    cp := Pos('-', tok[3]);
    if (fixed < 0) or (cp < 1) then begin err := 'bad run range'; exit; end;
    a := StrToIntDef(Copy(tok[3], 1, cp - 1), -1);
    b := StrToIntDef(Copy(tok[3], cp + 1, 9), -1);
    if (a < 0) or (b < a) then begin err := 'bad run range ' + tok[3]; exit; end;
    for i := a to b do begin
      if nf > High(cols) then begin err := 'run too long'; exit; end;
      if tok[0] = 'col' then begin cols[nf] := fixed; rows[nf] := i; end
      else begin cols[nf] := i; rows[nf] := fixed; end;
      inc(nf);
    end;
  end else begin
    { explicit C,R tokens }
    for i := 0 to n - 1 do begin
      cp := Pos(',', tok[i]);
      if cp < 1 then begin err := 'cell wants C,R, got ' + tok[i]; exit; end;
      if nf > High(cols) then begin err := 'run too long'; exit; end;
      cols[nf] := StrToIntDef(Copy(tok[i], 1, cp - 1), -1);
      rows[nf] := StrToIntDef(Copy(tok[i], cp + 1, 9), -1);
      if (cols[nf] < 0) or (rows[nf] < 0) then begin
        err := 'bad cell ' + tok[i]; exit;
      end;
      inc(nf);
    end;
  end;
  ExpandRun := nf;
end;

function ParseSheet(const fn: string; out banks: TSheetBankArray;
  out err: string): boolean;
var
  lines: TStringList;
  pix: TByteArray;
  sw, sh, cellW, cellH, li, n, bi, si, fi, nf, i: longint;
  head, left, tail, opt, base, blobErr: string;
  tok: array[0 .. 31] of string;
  cols, rows: array[0 .. 255] of longint;
  blob: TByteArray;
  haveSheet: boolean;
begin
  ParseSheet := false; err := '';
  banks := nil;
  cellW := 0; cellH := 0; sw := 0; sh := 0;
  haveSheet := false;
  base := ExtractFilePath(fn);
  lines := TStringList.Create;
  try
    lines.LoadFromFile(fn);
    for li := 0 to lines.Count - 1 do begin
      head := Trim(lines[li]);
      if (head = '') or (head[1] = '#') then continue;
      SplitColon(head, left, tail);
      Tokenize(left, tok, n);

      if tok[0] = 'sheet' then begin
        if n < 2 then begin err := 'line ' + IntToStr(li + 1) + ': sheet needs a path'; exit; end;
        if not ReadPpm(base + tok[1], sw, sh, pix) then begin
          err := 'line ' + IntToStr(li + 1) + ': cannot read sheet ' + tok[1]; exit;
        end;
        haveSheet := true;
      end else if tok[0] = 'cell' then begin
        if n < 3 then begin err := 'line ' + IntToStr(li + 1) + ': cell needs w h'; exit; end;
        cellW := StrToIntDef(tok[1], 0); cellH := StrToIntDef(tok[2], 0);
        if (cellW <= 0) or (cellH <= 0) or (cellW > 255) or (cellH > 255) then begin
          err := 'line ' + IntToStr(li + 1) + ': cell size out of range'; exit;
        end;
      end else if tok[0] = 'bank' then begin
        if n < 2 then begin err := 'line ' + IntToStr(li + 1) + ': bank needs a name'; exit; end;
        bi := Length(banks);
        SetLength(banks, bi + 1);
        banks[bi].name := UpperCase(tok[1]);
        banks[bi].bank.flags := 0;
        banks[bi].bank.seqs := nil;
      end else if tok[0] = 'seq' then begin
        if not haveSheet then begin err := 'line ' + IntToStr(li + 1) + ': seq before sheet'; exit; end;
        if (cellW = 0) or (cellH = 0) then begin err := 'line ' + IntToStr(li + 1) + ': seq before cell'; exit; end;
        if Length(banks) = 0 then begin err := 'line ' + IntToStr(li + 1) + ': seq before bank'; exit; end;
        if n < 2 then begin err := 'line ' + IntToStr(li + 1) + ': seq needs a name'; exit; end;
        bi := High(banks);
        si := Length(banks[bi].bank.seqs);
        SetLength(banks[bi].bank.seqs, si + 1);
        banks[bi].bank.seqs[si].name := UpperCase(tok[1]);
        banks[bi].bank.seqs[si].sflags := LOOP_LOOP;
        banks[bi].bank.seqs[si].ox := 0; banks[bi].bank.seqs[si].oy := 0;
        banks[bi].bank.seqs[si].ticks := 4;
        for fi := 2 to n - 1 do begin
          opt := tok[fi];
          if opt = 'loop' then banks[bi].bank.seqs[si].sflags :=
            (banks[bi].bank.seqs[si].sflags and SEQ_MIRROR) or LOOP_LOOP
          else if opt = 'once' then banks[bi].bank.seqs[si].sflags :=
            (banks[bi].bank.seqs[si].sflags and SEQ_MIRROR) or LOOP_ONCE
          else if opt = 'pingpong' then banks[bi].bank.seqs[si].sflags :=
            (banks[bi].bank.seqs[si].sflags and SEQ_MIRROR) or LOOP_PINGPONG
          else if opt = 'mirror' then banks[bi].bank.seqs[si].sflags :=
            banks[bi].bank.seqs[si].sflags or SEQ_MIRROR
          else if Copy(opt, 1, 6) = 'ticks=' then
            banks[bi].bank.seqs[si].ticks := StrToIntDef(Copy(opt, 7, 9), 4)
          else if Copy(opt, 1, 3) = 'ox=' then
            banks[bi].bank.seqs[si].ox := StrToIntDef(Copy(opt, 4, 9), 0)
          else if Copy(opt, 1, 3) = 'oy=' then
            banks[bi].bank.seqs[si].oy := StrToIntDef(Copy(opt, 4, 9), 0)
          else begin
            err := 'line ' + IntToStr(li + 1) + ': unknown option ' + opt; exit;
          end;
        end;
        nf := ExpandRun(tail, cols, rows, blobErr);
        if nf < 0 then begin err := 'line ' + IntToStr(li + 1) + ': ' + blobErr; exit; end;
        if nf = 0 then begin err := 'line ' + IntToStr(li + 1) + ': seq has no frames'; exit; end;
        SetLength(banks[bi].bank.seqs[si].frames, nf);
        for i := 0 to nf - 1 do begin
          if not CellBlob(pix, sw, sh, cellW, cellH, cols[i], rows[i], blob, blobErr) then begin
            err := 'line ' + IntToStr(li + 1) + ': ' + blobErr; exit;
          end;
          banks[bi].bank.seqs[si].frames[i] := blob;
        end;
        banks[bi].bank.seqs[si].w := cellW;
        banks[bi].bank.seqs[si].h := cellH;
      end else begin
        err := 'line ' + IntToStr(li + 1) + ': unknown directive ' + tok[0]; exit;
      end;
    end;
  finally
    lines.Free;
  end;
  if Length(banks) = 0 then begin err := 'no banks in ' + fn; exit; end;
  ParseSheet := true;
end;

end.
