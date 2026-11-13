unit sprbank;

{** Sprite animation banks (design section 27).

  A bank is one lump holding many named sequences (IDLE, WALKN, HURT). Each
  sequence has its own bounding box but shares an anchor, so sequences swap
  without the sprite jumping. Direction is encoded in the sequence name, not
  the format, so the engine owns any naming or mirror policy. Frames stay in
  the CPIC format the plain sprite path already bakes, concatenated per
  sequence behind a frame-offset table. Nothing here decodes a run stream: the
  GPU backends decode a frame to a CLUT texture regardless, so a frame is just
  a CPIC blob the loader slices and hands to PicDecode.

  Layout:

    header (8 bytes):
      magic 'SPBK' (4) · flags u8 · seqCount u8 · reserved u16
    seqDir[seqCount], 24 bytes each:
      name[8] · w u8 · h u8 · frames u8 · sflags u8 · ox s8 · oy s8
      · ticks u8 · pad u8 · dirOff u16
    per sequence at bank+dirOff:
      frameOff u16 [frames+1]  (offsets into the frame region after this table,
                                last entry = total frame-region size)
      the frames' CPIC blobs, concatenated

  sflags: bits 0-1 loop mode (0 loop, 1 once, 2 pingpong); bit 7 mirror hint. }

{$mode objfpc}{$H+}

interface

uses
  pic, pak;

const
  SPBK_MAGIC = $4B425053;   { 'SPBK' little-endian }

  LOOP_LOOP     = 0;
  LOOP_ONCE     = 1;
  LOOP_PINGPONG = 2;
  SEQ_MIRROR    = $80;

type
  { Author-side sequence: its metadata and the already-encoded CPIC frames. }
  TBankSeq = record
    name: string[8];
    w, h: byte;
    sflags: byte;
    ox, oy: shortint;
    ticks: byte;
    frames: array of pak.TByteArray;   { one CPIC blob per frame }
  end;

  TSpriteBank = record
    flags: byte;
    seqs: array of TBankSeq;
  end;

  { Runtime sequence: its metadata and the frame extents within the raw blob. }
  TRTSeq = record
    name: string[8];
    w, h, frameCount, sflags: byte;
    ox, oy: shortint;
    ticks: byte;
    off, len: array of longint;    { absolute frame extents into raw }
  end;

  TRTBank = record
    raw: pak.TByteArray;
    flags: byte;
    seqs: array of TRTSeq;
  end;

{ Encode an author-side bank into the SPBK lump bytes. }
function EncodeBank(const b: TSpriteBank): pak.TByteArray;
{ Decode the SPBK lump bytes into a runtime bank. }
function DecodeBank(const blob: pak.TByteArray; out rb: TRTBank): boolean;
{ Load a named SPBK lump from the pak into a runtime bank. }
function LoadBank(const p: TPak; const name: string; out rb: TRTBank): boolean;
{ Index of a sequence by name (case-insensitive), or -1. }
function BankSeqIndex(const rb: TRTBank; const name: string): longint;
{ Decode one frame of a sequence to an image. }
function BankFrame(const rb: TRTBank; seq, frame: longint; out img: TImage): boolean;

implementation

uses
  sysutils;

{ ---- little-endian writers over a growing byte array ---- }

procedure PutB(var a: pak.TByteArray; var n: longint; v: byte);
begin
  if n >= Length(a) then SetLength(a, (n + 1) * 2);
  a[n] := v; inc(n);
end;

procedure PutU16(var a: pak.TByteArray; var n: longint; v: longint);
begin
  PutB(a, n, v and $FF); PutB(a, n, (v shr 8) and $FF);
end;

procedure PutName(var a: pak.TByteArray; var n: longint; const s: string; len: longint);
var i: longint;
begin
  for i := 1 to len do
    if i <= Length(s) then PutB(a, n, ord(s[i])) else PutB(a, n, 0);
end;

procedure PutBytes(var a: pak.TByteArray; var n: longint; const src: pak.TByteArray);
var i: longint;
begin
  for i := 0 to High(src) do PutB(a, n, src[i]);
end;

function RU16(const a: pak.TByteArray; p: longint): longint;
begin
  RU16 := a[p] or (a[p + 1] shl 8);
end;

function RName(const a: pak.TByteArray; p, len: longint): string;
var i: longint; s: string;
begin
  s := '';
  for i := 0 to len - 1 do
    if a[p + i] <> 0 then s := s + chr(a[p + i]);
  RName := s;
end;

{ The byte size of a sequence block: its frame-offset table plus all frames. }
function SeqBlockSize(const s: TBankSeq): longint;
var i, sz: longint;
begin
  sz := (Length(s.frames) + 1) * 2;
  for i := 0 to High(s.frames) do sz := sz + Length(s.frames[i]);
  SeqBlockSize := sz;
end;

function EncodeBank(const b: TSpriteBank): pak.TByteArray;
var
  a: pak.TByteArray;
  n, i, j, dirOff, foff: longint;
begin
  SetLength(a, 0); n := 0;
  { header }
  PutB(a, n, SPBK_MAGIC and $FF);
  PutB(a, n, (SPBK_MAGIC shr 8) and $FF);
  PutB(a, n, (SPBK_MAGIC shr 16) and $FF);
  PutB(a, n, (SPBK_MAGIC shr 24) and $FF);
  PutB(a, n, b.flags);
  PutB(a, n, Length(b.seqs));
  PutU16(a, n, 0);                 { reserved }

  { sequence directory; each dirOff points past the header and the whole dir }
  dirOff := 8 + Length(b.seqs) * 24;
  for i := 0 to High(b.seqs) do begin
    PutName(a, n, b.seqs[i].name, 8);
    PutB(a, n, b.seqs[i].w);
    PutB(a, n, b.seqs[i].h);
    PutB(a, n, Length(b.seqs[i].frames));
    PutB(a, n, b.seqs[i].sflags);
    PutB(a, n, byte(b.seqs[i].ox));
    PutB(a, n, byte(b.seqs[i].oy));
    PutB(a, n, b.seqs[i].ticks);
    PutB(a, n, 0);                 { pad }
    PutU16(a, n, dirOff);
    PutU16(a, n, 0); PutU16(a, n, 0); PutU16(a, n, 0);  { pad entry to 24 }
    dirOff := dirOff + SeqBlockSize(b.seqs[i]);
  end;

  { sequence blocks: the frame-offset table, then the concatenated frames }
  for i := 0 to High(b.seqs) do begin
    foff := 0;
    for j := 0 to High(b.seqs[i].frames) do begin
      PutU16(a, n, foff);
      foff := foff + Length(b.seqs[i].frames[j]);
    end;
    PutU16(a, n, foff);            { tail: total frame-region size }
    for j := 0 to High(b.seqs[i].frames) do
      PutBytes(a, n, b.seqs[i].frames[j]);
  end;

  SetLength(a, n);
  EncodeBank := a;
end;

function DecodeBank(const blob: pak.TByteArray; out rb: TRTBank): boolean;
var
  i, j, p, seqCount, dirOff, tableBase, frOff, nextOff: longint;
  m: longword;
begin
  DecodeBank := false;
  rb.raw := nil; rb.seqs := nil; rb.flags := 0;
  if Length(blob) < 8 then exit;
  m := blob[0] or (blob[1] shl 8) or (blob[2] shl 16) or (longword(blob[3]) shl 24);
  if m <> SPBK_MAGIC then exit;
  rb.raw := blob;
  rb.flags := blob[4];
  seqCount := blob[5];
  SetLength(rb.seqs, seqCount);
  for i := 0 to seqCount - 1 do begin
    p := 8 + i * 24;
    rb.seqs[i].name := RName(blob, p, 8);
    rb.seqs[i].w := blob[p + 8];
    rb.seqs[i].h := blob[p + 9];
    rb.seqs[i].frameCount := blob[p + 10];
    rb.seqs[i].sflags := blob[p + 11];
    rb.seqs[i].ox := shortint(blob[p + 12]);
    rb.seqs[i].oy := shortint(blob[p + 13]);
    rb.seqs[i].ticks := blob[p + 14];
    dirOff := RU16(blob, p + 16);
    { the frame region starts past the (frameCount+1)-entry offset table }
    tableBase := dirOff;
    SetLength(rb.seqs[i].off, rb.seqs[i].frameCount);
    SetLength(rb.seqs[i].len, rb.seqs[i].frameCount);
    for j := 0 to rb.seqs[i].frameCount - 1 do begin
      frOff := RU16(blob, tableBase + j * 2);
      nextOff := RU16(blob, tableBase + (j + 1) * 2);
      rb.seqs[i].off[j] := tableBase + (rb.seqs[i].frameCount + 1) * 2 + frOff;
      rb.seqs[i].len[j] := nextOff - frOff;
    end;
  end;
  DecodeBank := true;
end;

function LoadBank(const p: TPak; const name: string; out rb: TRTBank): boolean;
var blob: pak.TByteArray;
begin
  LoadBank := false;
  if not PakGet(p, name, blob) then exit;
  LoadBank := DecodeBank(blob, rb);
end;

function BankSeqIndex(const rb: TRTBank; const name: string): longint;
var i: longint; u: string;
begin
  u := UpperCase(name);
  for i := 0 to High(rb.seqs) do
    if UpperCase(rb.seqs[i].name) = u then begin BankSeqIndex := i; exit; end;
  BankSeqIndex := -1;
end;

function BankFrame(const rb: TRTBank; seq, frame: longint; out img: TImage): boolean;
var sub: pak.TByteArray; i, off, len: longint;
begin
  BankFrame := false;
  img.w := 0; img.h := 0; img.pix := nil;
  if (seq < 0) or (seq > High(rb.seqs)) then exit;
  if (frame < 0) or (frame >= rb.seqs[seq].frameCount) then exit;
  off := rb.seqs[seq].off[frame];
  len := rb.seqs[seq].len[frame];
  if (len <= 0) or (off + len > Length(rb.raw)) then exit;
  SetLength(sub, len);
  for i := 0 to len - 1 do sub[i] := rb.raw[off + i];
  BankFrame := PicDecode(sub, img);
end;

end.
