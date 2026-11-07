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
  pic, pak;

const
  MAX_SPRITES = 64;   { resident billboard images at once }

type
  TSpriteEntry = record
    name: string[12];
    img: TImage;
    used: boolean;
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

function LoadSprite(const p: TPak; const name: string): longint;
var
  blob: pak.TByteArray;
  img: TImage;
  idx: longint;
  u: string;
begin
  LoadSprite := FindSprite(name);
  if LoadSprite >= 0 then exit;
  if SpriteCount >= MAX_SPRITES then exit;
  u := UpperCase(name);
  if not PakGet(p, u, blob) then exit;
  if not PicDecode(blob, img) then exit;
  idx := SpriteCount;
  SpriteReg[idx].name := u;
  SpriteReg[idx].img := img;
  SpriteReg[idx].used := true;
  inc(SpriteCount);
  LoadSprite := idx;
end;

initialization
  SpritesReset;
end.
