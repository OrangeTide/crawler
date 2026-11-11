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

const
  ENT_H = 1.1;   { default billboard height in tiles, for NPCs and pursuers }

type
  TWorldSprite = record
    x, y: double;    { world position, tile centered }
    wh: double;      { billboard height in tiles }
    img: longint;    { index into sprites.SpriteReg }
  end;

{ Fill lst with the current map's drawable sprites, up to its length, and
  return how many were written. }
function GatherWorldSprites(var lst: array of TWorldSprite): longint;

implementation

uses
  mapfmt, world, sprites, pursuit, monsters, gamestate;

const
  NPC_SPRITE = 'NPC';   { the default art for an NPC that names no sprite }
  { foliage billboard art: the loafbrr Generic Foliage conifer. One sprite
    serves every kind for now; a later pass can pick per biome from the kit. }
  FOLIAGE_SPRITE = 'FOLIAGE_TREE';
  FOLIAGE_H = 1.6;      { billboard height in tiles }
  FOLIAGE_R = 16;       { only gather foliage within this many tiles of the party }

{ The billboard art and height for a portal of this kind. An unknown kind
  draws nothing (name stays empty), leaving only the floor cue. }
procedure ExitLook(kind: longint; out name: string; out h: double);
begin
  name := '';
  h := 1.15;
  case kind of
    { a door portal draws the doorway mesh in the polygon path, not a
      billboard; a flat outdoor edge shows only its floor cue }
    PK_UP:            begin name := 'EXIT_UP';     h := 0.95; end;
    PK_DOWN:          begin name := 'EXIT_DOWN';   h := 0.6;  end;
    PK_CAVE:          name := 'EXIT_CAVE';
    PK_LADDER:        name := 'EXIT_LADDER';
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
        inc(n);
      end;
  end;
  GatherWorldSprites := n;
end;

end.
