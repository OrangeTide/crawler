unit tilekit;

{** Modular kit definitions, one per tileset, loaded from a compiled lump.

  A kit is the set of baked mesh pieces that clad a tileset's sectors: a
  floor piece, a ceiling piece, wall pieces, pillars. Each piece names a
  baked tile lump and its footprint in grid units, so the cladding pass
  (theme G) can place pieces at their native scale over the logical grid
  without reading mesh bounds. A piece's footprint is its ground extent in
  grid units (fw by fh) and its height in units (fz, 1 for a flat floor or
  ceiling slab, the wall height for a wall).

  Which tileset carries which pieces is authored in content/tilesets.txt,
  so no cladding policy lives in code. A tileset with no kit entry renders
  with the procedural surface quads as before; a tileset with a kit draws
  its sectors from these pieces instead. }

{$mode objfpc}{$H+}

interface

uses
  pak;

const
  KITS_MAGIC = $5354494B;   { 'KITS' little-endian }

  { Piece roles. A kit may list several pieces of one role at different
    footprints; the cladding pass prefers the largest that fits. }
  KITROLE_FLOOR  = 0;
  KITROLE_CEIL   = 1;
  KITROLE_WALL   = 2;
  KITROLE_PILLAR = 3;
  KITROLE_COUNT  = 4;

type
  TKitPiece = record
    role: byte;             { KITROLE_* }
    lump: string[16];       { the baked tile mesh to instance }
    fw, fh: byte;           { ground footprint in grid units }
    fz: byte;               { height in grid units (1 for a slab) }
    atlas: byte;            { which resident trim sheet this piece samples }
  end;

  TKit = record
    tileset: byte;          { the tileset index this kit clads }
    name: string[16];       { a label for tools and logs }
    pieces: array of TKitPiece;
  end;

var
  Kits: array of TKit;      { every loaded kit, any order }

function EncodeKits(const kits: array of TKit): TByteArray;
function LoadKits(const p: TPak): boolean;

{ The index into Kits for a tileset, or -1 if that tileset has no kit. }
function KitIndexForTileset(ts: longint): longint;
{ Whether a tileset carries a kit (so its sectors clad with meshes). }
function TilesetHasKit(ts: longint): boolean;
{ The first piece of a role in a kit, or -1. }
function KitPieceByRole(kitIdx, role: longint): longint;
{ The piece of a role that best fits a run of `run` grid units: the largest
  footprint not exceeding the run, or the smallest piece if all are larger.
  Lets the cladding pass draw native pieces over full runs and base-unit
  pieces over ragged edges. Returns -1 if the role is absent. }
function KitPieceForRun(kitIdx, role, run: longint): longint;

implementation

procedure PutB(var a: TByteArray; var n: longint; v: byte);
begin
  if n >= Length(a) then SetLength(a, (n + 1) * 2);
  a[n] := v; inc(n);
end;

procedure PutU16(var a: TByteArray; var n: longint; v: word);
begin
  PutB(a, n, v and $FF); PutB(a, n, (v shr 8) and $FF);
end;

procedure PutName(var a: TByteArray; var n: longint; const s: string; len: longint);
var i: longint;
begin
  for i := 1 to len do
    if i <= Length(s) then PutB(a, n, ord(s[i])) else PutB(a, n, 0);
end;

function EncodeKits(const kits: array of TKit): TByteArray;
var
  a: TByteArray;
  n, i, k: longint;
begin
  SetLength(a, 0);
  n := 0;
  PutB(a, n, KITS_MAGIC and $FF);
  PutB(a, n, (KITS_MAGIC shr 8) and $FF);
  PutB(a, n, (KITS_MAGIC shr 16) and $FF);
  PutB(a, n, (KITS_MAGIC shr 24) and $FF);
  PutU16(a, n, Length(kits));
  for i := 0 to High(kits) do begin
    PutB(a, n, kits[i].tileset);
    PutName(a, n, kits[i].name, 16);
    PutU16(a, n, Length(kits[i].pieces));
    for k := 0 to High(kits[i].pieces) do begin
      PutB(a, n, kits[i].pieces[k].role);
      PutName(a, n, kits[i].pieces[k].lump, 16);
      PutB(a, n, kits[i].pieces[k].fw);
      PutB(a, n, kits[i].pieces[k].fh);
      PutB(a, n, kits[i].pieces[k].fz);
      PutB(a, n, kits[i].pieces[k].atlas);
    end;
  end;
  SetLength(a, n);
  EncodeKits := a;
end;

function RName(const a: TByteArray; var p: longint; len: longint): string;
var i: longint; s: string;
begin
  s := '';
  for i := 1 to len do begin
    if (p < Length(a)) and (a[p] <> 0) then s := s + chr(a[p]);
    inc(p);
  end;
  RName := s;
end;

function RU16(const a: TByteArray; var p: longint): word;
begin
  RU16 := 0;
  if p + 1 < Length(a) then RU16 := a[p] or (a[p + 1] shl 8);
  inc(p, 2);
end;

function RB(const a: TByteArray; var p: longint): byte;
begin
  RB := 0;
  if p < Length(a) then RB := a[p];
  inc(p);
end;

function LoadKits(const p: TPak): boolean;
var
  blob: TByteArray;
  pos, kcount, pcount, i, k: longint;
  magic: longword;
begin
  LoadKits := false;
  Kits := nil;
  if not PakGet(p, 'KITS', blob) then exit;
  if Length(blob) < 6 then exit;
  magic := blob[0] or (blob[1] shl 8) or (blob[2] shl 16) or (longword(blob[3]) shl 24);
  if magic <> KITS_MAGIC then exit;
  pos := 4;
  kcount := RU16(blob, pos);
  SetLength(Kits, kcount);
  for i := 0 to kcount - 1 do begin
    Kits[i].tileset := RB(blob, pos);
    Kits[i].name := RName(blob, pos, 16);
    pcount := RU16(blob, pos);
    SetLength(Kits[i].pieces, pcount);
    for k := 0 to pcount - 1 do begin
      Kits[i].pieces[k].role := RB(blob, pos);
      Kits[i].pieces[k].lump := RName(blob, pos, 16);
      Kits[i].pieces[k].fw := RB(blob, pos);
      Kits[i].pieces[k].fh := RB(blob, pos);
      Kits[i].pieces[k].fz := RB(blob, pos);
      Kits[i].pieces[k].atlas := RB(blob, pos);
    end;
  end;
  LoadKits := true;
end;

function KitIndexForTileset(ts: longint): longint;
var i: longint;
begin
  KitIndexForTileset := -1;
  for i := 0 to High(Kits) do
    if Kits[i].tileset = ts then begin KitIndexForTileset := i; exit; end;
end;

function TilesetHasKit(ts: longint): boolean;
begin
  TilesetHasKit := KitIndexForTileset(ts) >= 0;
end;

function KitPieceByRole(kitIdx, role: longint): longint;
var k: longint;
begin
  KitPieceByRole := -1;
  if (kitIdx < 0) or (kitIdx > High(Kits)) then exit;
  for k := 0 to High(Kits[kitIdx].pieces) do
    if Kits[kitIdx].pieces[k].role = role then begin
      KitPieceByRole := k; exit;
    end;
end;

function KitPieceForRun(kitIdx, role, run: longint): longint;
var k, best, small: longint;
begin
  KitPieceForRun := -1;
  if (kitIdx < 0) or (kitIdx > High(Kits)) then exit;
  best := -1; small := -1;
  for k := 0 to High(Kits[kitIdx].pieces) do
    if Kits[kitIdx].pieces[k].role = role then begin
      if (small < 0) or (Kits[kitIdx].pieces[k].fw < Kits[kitIdx].pieces[small].fw) then
        small := k;
      if (Kits[kitIdx].pieces[k].fw <= run)
        and ((best < 0) or (Kits[kitIdx].pieces[k].fw > Kits[kitIdx].pieces[best].fw)) then
        best := k;
    end;
  if best >= 0 then KitPieceForRun := best else KitPieceForRun := small;
end;

end.
