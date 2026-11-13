unit sprbanktext;

{** Parse a sprite-bank manifest into an author-side bank (offline, tool side).

  A manifest names sequences and their frame images. Frame paths are relative
  to the manifest's own directory. Each frame is a binary PPM, keyed on magenta
  (255,0,255) for transparency and encoded to a CPIC blob, the same path the
  plain sprite baker uses. One line per sequence:

    seq NAME [loop|once|pingpong] [mirror] [ticks=N] [ox=N] [oy=N] : a.ppm b.ppm

  Lines that are blank or start with '#' are ignored. All frames in a sequence
  must share dimensions; sequences may differ. }

{$mode objfpc}{$H+}

interface

uses
  sprbank;

{ Parse the manifest at fn into bank. Returns false with err set on any error. }
function ParseBank(const fn: string; out bank: TSpriteBank; out err: string): boolean;

implementation

uses
  classes, sysutils, gfx, pic, pak, meshfmt;

{ Encode one PPM frame to a CPIC blob, keying magenta to transparent. Sets w,h. }
function FrameBlob(const path: string; out fw, fh: longint; out blob: TByteArray;
  out err: string): boolean;
var
  pixbuf: TByteArray;
  img: TImage;
  i: longint;
  r, g, b: byte;
begin
  FrameBlob := false; err := '';
  if not ReadPpm(path, fw, fh, pixbuf) then begin
    err := 'cannot read frame ' + path; exit;
  end;
  if (fw > 255) or (fh > 255) then begin
    err := 'frame ' + path + ' exceeds 255x255'; exit;
  end;
  ImgNew(img, fw, fh);
  img.hasAlpha := true;
  for i := 0 to fw * fh - 1 do begin
    r := pixbuf[i * 3]; g := pixbuf[i * 3 + 1]; b := pixbuf[i * 3 + 2];
    if (r = 255) and (g = 0) and (b = 255) then
      img.pix[i] := 0
    else
      img.pix[i] := RGB(r, g, b);
  end;
  blob := PicEncodeDirect(img);
  FrameBlob := true;
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

function ParseBank(const fn: string; out bank: TSpriteBank; out err: string): boolean;
var
  lines, frameList: TStringList;
  li, n, fi, nf, fw, fh, sw, sh, si: longint;
  head, left, tail, opt, blobErr, base: string;
  tok: array[0 .. 31] of string;
  blob: TByteArray;
begin
  ParseBank := false; err := '';
  bank.flags := 0; bank.seqs := nil;
  base := ExtractFilePath(fn);
  lines := TStringList.Create;
  frameList := TStringList.Create;
  try
    lines.LoadFromFile(fn);
    for li := 0 to lines.Count - 1 do begin
      head := Trim(lines[li]);
      if (head = '') or (head[1] = '#') then continue;
      SplitColon(head, left, tail);
      Tokenize(left, tok, n);
      if tok[0] <> 'seq' then begin
        err := 'line ' + IntToStr(li + 1) + ': expected seq, got ' + tok[0]; exit;
      end;
      if n < 2 then begin
        err := 'line ' + IntToStr(li + 1) + ': seq needs a name'; exit;
      end;
      si := Length(bank.seqs);
      SetLength(bank.seqs, si + 1);
      bank.seqs[si].name := UpperCase(tok[1]);
      bank.seqs[si].sflags := LOOP_LOOP;
      bank.seqs[si].ox := 0; bank.seqs[si].oy := 0;
      bank.seqs[si].ticks := 4;
      { options between the name and the colon }
      for fi := 2 to n - 1 do begin
        opt := tok[fi];
        if opt = 'loop' then bank.seqs[si].sflags :=
          (bank.seqs[si].sflags and SEQ_MIRROR) or LOOP_LOOP
        else if opt = 'once' then bank.seqs[si].sflags :=
          (bank.seqs[si].sflags and SEQ_MIRROR) or LOOP_ONCE
        else if opt = 'pingpong' then bank.seqs[si].sflags :=
          (bank.seqs[si].sflags and SEQ_MIRROR) or LOOP_PINGPONG
        else if opt = 'mirror' then bank.seqs[si].sflags :=
          bank.seqs[si].sflags or SEQ_MIRROR
        else if Copy(opt, 1, 6) = 'ticks=' then
          bank.seqs[si].ticks := StrToIntDef(Copy(opt, 7, 9), 4)
        else if Copy(opt, 1, 3) = 'ox=' then
          bank.seqs[si].ox := StrToIntDef(Copy(opt, 4, 9), 0)
        else if Copy(opt, 1, 3) = 'oy=' then
          bank.seqs[si].oy := StrToIntDef(Copy(opt, 4, 9), 0)
        else begin
          err := 'line ' + IntToStr(li + 1) + ': unknown option ' + opt; exit;
        end;
      end;
      { the frame list after the colon }
      frameList.Clear;
      frameList.Delimiter := ' ';
      frameList.StrictDelimiter := true;
      frameList.DelimitedText := tail;
      nf := 0;
      for fi := 0 to frameList.Count - 1 do
        if Trim(frameList[fi]) <> '' then inc(nf);
      if nf = 0 then begin
        err := 'line ' + IntToStr(li + 1) + ': seq ' + tok[1] + ' has no frames'; exit;
      end;
      SetLength(bank.seqs[si].frames, nf);
      sw := 0; sh := 0; nf := 0;
      for fi := 0 to frameList.Count - 1 do begin
        if Trim(frameList[fi]) = '' then continue;
        if not FrameBlob(base + Trim(frameList[fi]), fw, fh, blob, blobErr) then begin
          err := 'line ' + IntToStr(li + 1) + ': ' + blobErr; exit;
        end;
        if nf = 0 then begin sw := fw; sh := fh; end
        else if (fw <> sw) or (fh <> sh) then begin
          err := 'line ' + IntToStr(li + 1) + ': frame ' + frameList[fi]
            + ' size differs from the first frame'; exit;
        end;
        bank.seqs[si].frames[nf] := blob;
        inc(nf);
      end;
      bank.seqs[si].w := sw;
      bank.seqs[si].h := sh;
    end;
  finally
    frameList.Free;
    lines.Free;
  end;
  ParseBank := true;
end;

end.
