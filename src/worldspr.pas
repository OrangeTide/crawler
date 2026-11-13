unit worldspr;

{** Gathers the billboard sprites to draw in the world view.

  Both renderers (the raycaster and the polygon renderer) show the same
  set of world entities as front-facing sprites: every NPC placed on the
  current map, every active pursuer standing on it, and the exits (doors,
  stairs, ladders and such) that lead off the map. Each entry names a
  sprite and a world height, so a door stands a full tile tall while a
  stair down sits low on the floor. Random-encounter monsters have no
  world position and are not drawn here. This gather step is shared so the
  two renderers never drift apart. }

{$mode objfpc}{$H+}

interface

uses
  pic;

const
  ENT_H = 1.1;   { default billboard height in tiles, for NPCs and pursuers }

type
  TWorldSprite = record
    x, y: double;    { world position, tile centered }
    wh: double;      { billboard height in tiles }
    img: longint;    { index into sprites.SpriteReg }
    hx, hy: double;  { heading, (0,0) when the entity is not moving }
    phase: double;   { animation phase offset, so like entities desync }
  end;

{ Fill lst with the current map's drawable sprites, up to its length, and
  return how many were written. }
function GatherWorldSprites(var lst: array of TWorldSprite): longint;

{ Advance the shared world animation clock by dt. Call once per explore frame. }
procedure WorldAnimTick(dt: double);

{ The frame of a looping bank sequence at the current clock plus a phase
  offset, so like entities animate out of step. 0 for a plain sprite or a
  single-frame sequence. Exposed for the world view and its test. }
function BankLoopFrame(si, seq: longint; phase: double): longint;

{ The frame to draw for a world entry, with the camera right vector (rx,ry)
  for the facing flip. Returns false for a plain (non-bank) sprite, leaving
  the caller to draw the default image. On true, img is the chosen frame and
  mirror asks for a horizontal flip, the one art facing reused for the other
  side. A moving entity walks (its WALK sequence when present), flipped when
  its heading reads to the screen-left; a still entity idles, unflipped. }
function WorldSpriteFrame(const e: TWorldSprite; rx, ry: double;
  out img: TImage; out mirror: boolean): boolean;

implementation

uses
  mapfmt, world, sprites, pursuit, monsters, gamestate, sprbank;

const
  NPC_SPRITE = 'NPC';   { the default art for an NPC that names no sprite }
  { foliage billboard art: the loafbrr Generic Foliage conifer. One sprite
    serves every kind for now; a later pass can pick per biome from the kit. }
  FOLIAGE_SPRITE = 'FOLIAGE_TREE';
  FOLIAGE_H = 1.6;      { billboard height in tiles }
  FOLIAGE_R = 16;       { only gather foliage within this many tiles of the party }
  PHASE_STEP = 0.37;    { seconds of phase between successive like entities }

var
  animClock: double;    { the shared world animation clock, in seconds }

procedure WorldAnimTick(dt: double);
begin
  animClock := animClock + dt;
end;

function BankLoopFrame(si, seq: longint; phase: double): longint;
var
  fc: longint;
  dur: double;
begin
  BankLoopFrame := 0;
  if (si < 0) or not SpriteReg[si].isBank then exit;
  if (seq < 0) or (seq > High(SpriteReg[si].bank.seqs)) then exit;
  fc := SpriteReg[si].bank.seqs[seq].frameCount;
  if fc <= 1 then exit;
  dur := SpriteReg[si].bank.seqs[seq].ticks / ANIM_FPS;   { seconds per frame }
  if dur <= 0 then exit;
  BankLoopFrame := trunc((animClock + phase) / dur) mod fc;
end;

function WorldSpriteFrame(const e: TWorldSprite; rx, ry: double;
  out img: TImage; out mirror: boolean): boolean;
var
  si, sq, fr: longint;
  moving: boolean;
begin
  WorldSpriteFrame := false;
  mirror := false;
  si := e.img;
  if (si < 0) or not SpriteReg[si].isBank then exit;
  moving := (e.hx <> 0) or (e.hy <> 0);
  sq := -1;
  if moving then sq := SpriteSeqIndex(si, 'WALK');
  if sq < 0 then sq := SpriteSeqIndex(si, 'IDLE');
  if sq < 0 then exit;                 { a bank with neither: use the default }
  { the art faces the camera's right; a heading that reads to the screen-left
    (a negative projection on the camera right vector) flips it to face left }
  if moving then mirror := (e.hx * rx + e.hy * ry) < 0;
  fr := BankLoopFrame(si, sq, e.phase);
  WorldSpriteFrame := SpriteFrame(si, sq, fr, img);
end;

{ The billboard art and height for a portal of this kind. An unknown kind
  draws nothing (name stays empty), leaving only the floor cue. }
procedure ExitLook(kind: longint; out name: string; out h: double);
begin
  name := '';
  h := 1.15;
  case kind of
    { a door or ladder portal draws its prop mesh in the polygon path, not a
      billboard; a flat outdoor edge shows only its floor cue }
    PK_UP:            begin name := 'EXIT_UP';     h := 0.95; end;
    PK_DOWN:          begin name := 'EXIT_DOWN';   h := 0.6;  end;
    PK_CAVE:          name := 'EXIT_CAVE';
    PK_SHAFT:         begin name := 'EXIT_SHAFT';  h := 0.6;  end;
  end;
end;

function GatherWorldSprites(var lst: array of TWorldSprite): longint;
var
  n, i, si: longint;
  spr: string;
  eh: double;
begin
  n := 0;
  { NPCs stand where the map places them, facing the camera; a bank-backed one
    idle-animates in place (no heading, so no flip) }
  for i := 0 to High(CurMap.npcs) do begin
    if n > High(lst) then break;
    spr := CurMap.npcs[i].sprite;
    if spr = '' then spr := NPC_SPRITE;
    si := LoadSprite(GamePak, spr);
    if si < 0 then si := LoadSprite(GamePak, NPC_SPRITE);
    if si < 0 then continue;
    lst[n].x := CurMap.npcs[i].x + 0.5;
    lst[n].y := CurMap.npcs[i].y + 0.5;
    lst[n].wh := ENT_H;
    lst[n].img := si;
    lst[n].hx := 0; lst[n].hy := 0;
    lst[n].phase := i * PHASE_STEP;
    inc(n);
  end;
  { pursuers carry a heading from their last step, so a bank-backed one walks
    and flips to face the way it moves }
  for i := 0 to High(Pursuers) do begin
    if n > High(lst) then break;
    if not Pursuers[i].active then continue;
    if Pursuers[i].map <> CurMapName then continue;
    si := LoadSprite(GamePak, MonDefs[Pursuers[i].mon].model);
    if si < 0 then continue;
    lst[n].x := Pursuers[i].x + 0.5;
    lst[n].y := Pursuers[i].y + 0.5;
    lst[n].wh := ENT_H;
    lst[n].img := si;
    lst[n].hx := Pursuers[i].fx; lst[n].hy := Pursuers[i].fy;
    lst[n].phase := i * PHASE_STEP;
    inc(n);
  end;
  { the map's exits: a door, stair, ladder or cave mouth standing on its
    tile, so the way on reads in 3D rather than as a floor pad alone }
  for i := 0 to High(CurMap.portals) do begin
    if n > High(lst) then break;
    ExitLook(CurMap.portals[i].kind, spr, eh);
    if spr = '' then continue;
    si := LoadSprite(GamePak, spr);
    if si < 0 then continue;
    lst[n].x := CurMap.portals[i].x + 0.5;
    lst[n].y := CurMap.portals[i].y + 0.5;
    lst[n].wh := eh;
    lst[n].img := si;
    lst[n].hx := 0; lst[n].hy := 0; lst[n].phase := 0;
    inc(n);
  end;
  { decorative foliage: trees and rocks the party walks among, billboarded on
    the ground. Only the foliage near the party is gathered, so the near set
    fits the list; each sits on the terrain through the shared ground-Z path. }
  if Length(CurMap.foliage) > 0 then begin
    si := LoadSprite(GamePak, FOLIAGE_SPRITE);
    if si >= 0 then
      for i := 0 to High(CurMap.foliage) do begin
        if n > High(lst) then break;
        if Abs(longint(CurMap.foliage[i].x) - TileX)
          + Abs(longint(CurMap.foliage[i].y) - TileY) > FOLIAGE_R then continue;
        lst[n].x := CurMap.foliage[i].x + 0.5;
        lst[n].y := CurMap.foliage[i].y + 0.5;
        lst[n].wh := FOLIAGE_H;
        lst[n].img := si;
        lst[n].hx := 0; lst[n].hy := 0; lst[n].phase := 0;
        inc(n);
      end;
  end;
  GatherWorldSprites := n;
end;

end.
