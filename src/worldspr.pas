unit worldspr;

{** Gathers the billboard sprites to draw in the world view.

  Both renderers (the raycaster and the polygon renderer) show the same
  set of world entities as front-facing sprites: every NPC placed on the
  current map, and every active pursuer standing on it. Each entity names
  a sprite, loaded on demand into the sprite store. Random-encounter
  monsters have no world position and are not drawn here. This gather step
  is shared so the two renderers never drift apart. }

{$mode objfpc}{$H+}

interface

type
  TWorldSprite = record
    x, y: double;    { world position, tile centered }
    img: longint;    { index into sprites.SpriteReg }
  end;

{ Fill lst with the current map's drawable sprites, up to its length, and
  return how many were written. }
function GatherWorldSprites(var lst: array of TWorldSprite): longint;

implementation

uses
  world, sprites, pursuit, monsters, gamestate;

const
  NPC_SPRITE = 'NPC';   { the shared placeholder until NPCs name their own }

function GatherWorldSprites(var lst: array of TWorldSprite): longint;
var
  n, i, si: longint;
begin
  n := 0;
  for i := 0 to High(CurMap.npcs) do begin
    if n > High(lst) then break;
    si := LoadSprite(GamePak, NPC_SPRITE);
    if si < 0 then continue;
    lst[n].x := CurMap.npcs[i].x + 0.5;
    lst[n].y := CurMap.npcs[i].y + 0.5;
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
    lst[n].img := si;
    inc(n);
  end;
  GatherWorldSprites := n;
end;

end.
