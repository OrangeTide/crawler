unit pak;

{** Read-only pack archive, plus an in-memory writer for the tools.

  A pak is a flat bundle of named lumps, the whole game's data in one
  file. The runtime loads the archive into memory once and fetches a
  lump by name. The offline tools use TPakWriter to build an archive.

  Layout:
    magic    'CPAK'      4 bytes
    version  u16
    count    u16         number of lumps
    dirOfs   u32         byte offset of the directory
    data     ...         the lump bytes, back to back
    dir      count * [ name 16 bytes, ofs u32, size u32 ]

  Lump names are at most 16 bytes, null padded, case sensitive. }

{$mode objfpc}{$H+}

interface

type
  TByteArray = array of byte;

  TPakEntry = record
    name: string[16];
    ofs, size: longint;
  end;

  TPak = record
    data: TByteArray;              { whole file in memory }
    dir: array of TPakEntry;
  end;

  TPakWriter = record
    names: array of string[16];
    blobs: array of TByteArray;
  end;

const
  PAK_MAGIC   = $4B415043;  { 'CPAK' little-endian }
  PAK_VERSION = 1;

{ Runtime: open an archive file and look up lumps. }
function PakLoad(const fn: string; out p: TPak): boolean;
function PakHas(const p: TPak; const name: string): boolean;
function PakGet(const p: TPak; const name: string; out blob: TByteArray): boolean;

{ Tools: accumulate named lumps then flush to a file. }
procedure PakWInit(out w: TPakWriter);
procedure PakWAdd(var w: TPakWriter; const name: string; const blob: TByteArray);
function PakWFlush(const w: TPakWriter; const fn: string): boolean;

implementation

uses
  classes, sysutils;

function PakLoad(const fn: string; out p: TPak): boolean;
var
  fs: TFileStream;
  count, dirOfs, i, j: longint;
  magic, ver: longword;
  nm: array[0 .. 15] of char;
begin
  PakLoad := false;
  p.data := nil;
  p.dir := nil;
  if not FileExists(fn) then
    exit;
  fs := TFileStream.Create(fn, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(p.data, fs.Size);
    if fs.Size > 0 then
      fs.ReadBuffer(p.data[0], fs.Size);
  finally
    fs.Free;
  end;
  if Length(p.data) < 12 then
    exit;

  Move(p.data[0], magic, 4);
  if magic <> PAK_MAGIC then
    exit;
  ver := p.data[4] or (p.data[5] shl 8);
  if ver <> PAK_VERSION then
    exit;
  count := p.data[6] or (p.data[7] shl 8);
  Move(p.data[8], dirOfs, 4);

  SetLength(p.dir, count);
  for i := 0 to count - 1 do begin
    Move(p.data[dirOfs + i * 24], nm[0], 16);
    p.dir[i].name := '';
    for j := 0 to 15 do begin
      if nm[j] = #0 then
        break;
      p.dir[i].name := p.dir[i].name + nm[j];
    end;
    Move(p.data[dirOfs + i * 24 + 16], p.dir[i].ofs, 4);
    Move(p.data[dirOfs + i * 24 + 20], p.dir[i].size, 4);
  end;
  PakLoad := true;
end;

function FindEntry(const p: TPak; const name: string): longint;
var
  i: longint;
begin
  for i := 0 to High(p.dir) do
    if p.dir[i].name = name then begin
      FindEntry := i;
      exit;
    end;
  FindEntry := -1;
end;

function PakHas(const p: TPak; const name: string): boolean;
begin
  PakHas := FindEntry(p, name) >= 0;
end;

function PakGet(const p: TPak; const name: string; out blob: TByteArray): boolean;
var
  i: longint;
begin
  blob := nil;
  i := FindEntry(p, name);
  if i < 0 then begin
    PakGet := false;
    exit;
  end;
  SetLength(blob, p.dir[i].size);
  if p.dir[i].size > 0 then
    Move(p.data[p.dir[i].ofs], blob[0], p.dir[i].size);
  PakGet := true;
end;

procedure PakWInit(out w: TPakWriter);
begin
  w.names := nil;
  w.blobs := nil;
end;

procedure PakWAdd(var w: TPakWriter; const name: string; const blob: TByteArray);
var
  n: longint;
begin
  n := Length(w.names);
  SetLength(w.names, n + 1);
  SetLength(w.blobs, n + 1);
  w.names[n] := name;
  w.blobs[n] := blob;
end;

procedure PutU16(fs: TStream; v: word);
begin
  fs.WriteByte(v and $FF);
  fs.WriteByte((v shr 8) and $FF);
end;

procedure PutU32(fs: TStream; v: longword);
begin
  fs.WriteByte(v and $FF);
  fs.WriteByte((v shr 8) and $FF);
  fs.WriteByte((v shr 16) and $FF);
  fs.WriteByte((v shr 24) and $FF);
end;

function PakWFlush(const w: TPakWriter; const fn: string): boolean;
var
  fs: TFileStream;
  i, j, dirOfs, count: longint;
  ofs: array of longint;
  nm: array[0 .. 15] of char;
  s: string[16];
begin
  PakWFlush := false;
  count := Length(w.names);
  fs := TFileStream.Create(fn, fmCreate);
  try
    PutU32(fs, PAK_MAGIC);
    PutU16(fs, PAK_VERSION);
    PutU16(fs, count);
    PutU32(fs, 0);   { dirOfs patched below }

    SetLength(ofs, count);
    for i := 0 to count - 1 do begin
      ofs[i] := fs.Position;
      if Length(w.blobs[i]) > 0 then
        fs.WriteBuffer(w.blobs[i][0], Length(w.blobs[i]));
    end;

    dirOfs := fs.Position;
    for i := 0 to count - 1 do begin
      FillChar(nm, 16, 0);
      s := w.names[i];
      for j := 1 to Length(s) do
        if j <= 16 then
          nm[j - 1] := s[j];
      fs.WriteBuffer(nm[0], 16);
      PutU32(fs, ofs[i]);
      PutU32(fs, Length(w.blobs[i]));
    end;

    fs.Position := 8;
    PutU32(fs, dirOfs);
  finally
    fs.Free;
  end;
  PakWFlush := true;
end;

end.
