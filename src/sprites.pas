unit sprites;

{** Runtime store of billboard sprites: named 2D images loaded from the pak.

  Monsters and NPCs are drawn as front-facing textured billboards, in combat
  and (later) in the world view. Each is a PIC lump decoded to a pic.TImage
  with a transparent colour key. Sprites are loaded on demand and cached by
  name, so only the ones a scene needs sit in memory, which suits the 2 MB
  target. }

{$mode objfpc}{$H+}

interface

uses
  pic, pak, sprbank;

const
  MAX_SPRITES = 64;   { resident billboard images at once }

type
  TSpriteEntry = record
    name: string[12];
    img: TImage;        { a plain sprite, or a bank's current frame }
    used: boolean;
    isBank: boolean;    { img is backed by the bank below }
    bank: TRTBank;
  end;

var
  SpriteReg: array[0 .. MAX_SPRITES - 1] of TSpriteEntry;
  SpriteCount: longint;

{ Drop every loaded sprite. }
procedure SpritesReset;
{ The index of an already-loaded sprite by name, or -1. }
function FindSprite(const name: string): longint;
{ Load a sprite lump from the pak and cache it, returning its index; a cached
  one is returned without reloading. -1 when the lump is missing, unreadable,
  or the store is full. }
function LoadSprite(const p: TPak; const name: string): longint;
{ The sequence index for a named sequence in a bank sprite, or -1 when the
  sprite is not a bank or has no such sequence. }
function SpriteSeqIndex(idx: longint; const seq: string): longint;
{ Decode one frame of a bank sprite's sequence into img. False when the sprite
  is not a bank or the indices are out of range. }
function SpriteFrame(idx, seq, frame: longint; out img: TImage): boolean;

implementation

uses
  sysutils;

procedure SpritesReset;
var i: longint;
begin
  for i := 0 to MAX_SPRITES - 1 do begin
    SpriteReg[i].used := false;
    SpriteReg[i].name := '';
    SpriteReg[i].img.pix := nil;
    SpriteReg[i].img.w := 0;
    SpriteReg[i].img.h := 0;
    SpriteReg[i].isBank := false;
    SpriteReg[i].bank.raw := nil;
    SpriteReg[i].bank.seqs := nil;
  end;
  SpriteCount := 0;
end;

function FindSprite(const name: string): longint;
var i: longint; u: string;
begin
  FindSprite := -1;
  u := UpperCase(name);
  for i := 0 to SpriteCount - 1 do
    if SpriteReg[i].used and (SpriteReg[i].name = u) then begin
      FindSprite := i; exit;
    end;
end;

{ True when the blob begins with the SPBK bank magic rather than a plain PIC. }
function IsBankBlob(const blob: pak.TByteArray): boolean;
begin
  IsBankBlob := (Length(blob) >= 4)
    and (blob[0] = ord('S')) and (blob[1] = ord('P'))
    and (blob[2] = ord('B')) and (blob[3] = ord('K'));
end;

function LoadSprite(const p: TPak; const name: string): longint;
var
  blob: pak.TByteArray;
  img: TImage;
  rb: TRTBank;
  idx: longint;
  u: string;
begin
  LoadSprite := FindSprite(name);
  if LoadSprite >= 0 then exit;
  if SpriteCount >= MAX_SPRITES then exit;
  u := UpperCase(name);
  if not PakGet(p, u, blob) then exit;

  idx := SpriteCount;
  if IsBankBlob(blob) then begin
    { A sprite bank: decode it and show its first sequence's first frame, so
      callers that read .img keep working until they animate. }
    if not DecodeBank(blob, rb) then exit;
    if not BankFrame(rb, 0, 0, img) then exit;
    SpriteReg[idx].isBank := true;
    SpriteReg[idx].bank := rb;
  end else begin
    if not PicDecode(blob, img) then exit;
    SpriteReg[idx].isBank := false;
    SpriteReg[idx].bank.raw := nil;
    SpriteReg[idx].bank.seqs := nil;
  end;
  SpriteReg[idx].name := u;
  SpriteReg[idx].img := img;
  SpriteReg[idx].used := true;
  inc(SpriteCount);
  LoadSprite := idx;
end;

function SpriteSeqIndex(idx: longint; const seq: string): longint;
begin
  SpriteSeqIndex := -1;
  if (idx < 0) or (idx >= SpriteCount) then exit;
  if not SpriteReg[idx].isBank then exit;
  SpriteSeqIndex := BankSeqIndex(SpriteReg[idx].bank, seq);
end;

function SpriteFrame(idx, seq, frame: longint; out img: TImage): boolean;
begin
  SpriteFrame := false;
  if (idx < 0) or (idx >= SpriteCount) then exit;
  if not SpriteReg[idx].isBank then exit;
  SpriteFrame := BankFrame(SpriteReg[idx].bank, seq, frame, img);
end;

initialization
  SpritesReset;
end.
