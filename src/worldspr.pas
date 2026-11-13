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
    anim: longint;   { slot in the NPC animation table, or -1 when static }
  end;

{ Fill lst with the current map's drawable sprites, up to its length, and
  return how many were written. }
function GatherWorldSprites(var lst: array of TWorldSprite): longint;

{ Advance every resident NPC animation cursor by dt. Call once per explore
  frame; a plain-sprite or single-frame NPC costs nothing. }
procedure WorldAnimTick(dt: double);

{ Which of an NPC's four sides faces an observer: the DIR_* the observer at
  (ox,oy) stands in, as seen from the NPC at (nx,ny). }
function WorldViewDir(nx, ny, ox, oy: double): longint;

{ The idle sequence of bank sprite si to show for view direction dir: the
  directional IDLE<dir>, the east art flipped for the west view (mirror set),
  or a plain IDLE for a non-directional bank. Returns -1 and mirror false when
  si is not a bank or carries no idle. }
function BankIdleForDir(si, dir: longint; out mirror: boolean): longint;

{ The frame to draw for an animated entry, given the camera position so the
  view picks which side of the NPC it sees. Returns false for a static entry
  or a plain (non-bank) sprite, leaving the caller to draw the default image.
  On true, img is the chosen frame and mirror asks for a horizontal flip, the
  east art reused for the west view. }
function WorldSpriteFrame(anim: longint; camx, camy: double;
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
  DIRLET: array[0 .. 3] of char = ('N', 'E', 'S', 'W');   { indexed by DIR_* }

type
  TNpcAnim = record
    si: longint;        { sprite reg slot, -1 when unresolved this map }
    nx, ny: double;     { the NPC's world centre, for the view bearing }
    cur: TBankCursor;
    seqIdx: longint;    { the sequence the cursor plays, -1 before the first }
  end;

var
  npcAnim: array of TNpcAnim;
  animMap: string;      { the map name npcAnim belongs to }

{ (Re)size the per-NPC animation table for the current map, resetting its
  cursors when the resident map or the NPC count changed. }
procedure EnsureNpcAnim;
var
  i, cnt: longint;
begin
  cnt := Length(CurMap.npcs);
  if (animMap = CurMapName) and (Length(npcAnim) = cnt) then exit;
  SetLength(npcAnim, cnt);
  for i := 0 to cnt - 1 do begin
    npcAnim[i].si := -1;
    npcAnim[i].seqIdx := -1;
    CursorStart(npcAnim[i].cur, -1);
  end;
  animMap := CurMapName;
end;

{ The axes match the world's DIR_* (east is +x, south is +y); the 45 degree
  quadrant split is the same partition atan2 rounding would give. }
function WorldViewDir(nx, ny, ox, oy: double): longint;
var
  dx, dy: double;
begin
  dx := ox - nx; dy := oy - ny;
  if Abs(dx) >= Abs(dy) then begin
    if dx >= 0 then WorldViewDir := DIR_E else WorldViewDir := DIR_W;
  end else begin
    if dy >= 0 then WorldViewDir := DIR_S else WorldViewDir := DIR_N;
  end;
end;

function BankIdleForDir(si, dir: longint; out mirror: boolean): longint;
var
  sq: longint;
begin
  mirror := false;
  BankIdleForDir := -1;
  if (si < 0) or not SpriteReg[si].isBank then exit;
  if (dir < 0) or (dir > 3) then exit;
  { a directional IDLE<dir>, else the east art flipped for the west view, else
    a single plain IDLE for a non-directional bank }
  sq := SpriteSeqIndex(si, 'IDLE' + DIRLET[dir]);
  if (sq < 0) and (dir = DIR_W) then begin
    sq := SpriteSeqIndex(si, 'IDLEE');
    if sq >= 0 then mirror := true;
  end;
  if sq < 0 then sq := SpriteSeqIndex(si, 'IDLE');
  BankIdleForDir := sq;
end;

procedure WorldAnimTick(dt: double);
var
  i, si: longint;
begin
  for i := 0 to High(npcAnim) do begin
    si := npcAnim[i].si;
    if (si < 0) or not SpriteReg[si].isBank then continue;
    if npcAnim[i].seqIdx < 0 then continue;   { no frame chosen yet }
    CursorTick(SpriteReg[si].bank, npcAnim[i].cur, dt);
  end;
end;

function WorldSpriteFrame(anim: longint; camx, camy: double;
  out img: TImage; out mirror: boolean): boolean;
var
  si, dir, sq: longint;
begin
  WorldSpriteFrame := false;
  mirror := false;
  if (anim < 0) or (anim > High(npcAnim)) then exit;
  si := npcAnim[anim].si;
  if (si < 0) or not SpriteReg[si].isBank then exit;
  dir := WorldViewDir(npcAnim[anim].nx, npcAnim[anim].ny, camx, camy);
  sq := BankIdleForDir(si, dir, mirror);
  if sq < 0 then exit;                 { a bank with no idle: use the default }
  if sq <> npcAnim[anim].seqIdx then begin
    CursorStart(npcAnim[anim].cur, sq);
    npcAnim[anim].seqIdx := sq;
  end;
  WorldSpriteFrame := SpriteFrame(si, sq, npcAnim[anim].cur.frame, img);
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
  EnsureNpcAnim;
  for i := 0 to High(CurMap.npcs) do begin
    if n > High(lst) then break;
    spr := CurMap.npcs[i].sprite;
    if spr = '' then spr := NPC_SPRITE;
    si := LoadSprite(GamePak, spr);
    if si < 0 then si := LoadSprite(GamePak, NPC_SPRITE);
    if si < 0 then continue;
    npcAnim[i].si := si;
    npcAnim[i].nx := CurMap.npcs[i].x + 0.5;
    npcAnim[i].ny := CurMap.npcs[i].y + 0.5;
    lst[n].x := npcAnim[i].nx;
    lst[n].y := npcAnim[i].ny;
    lst[n].wh := ENT_H;
    lst[n].img := si;
    lst[n].anim := i;
    inc(n);
  end;
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
    lst[n].anim := -1;
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
    lst[n].anim := -1;
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
        lst[n].anim := -1;
        inc(n);
      end;
  end;
  GatherWorldSprites := n;
end;

end.
