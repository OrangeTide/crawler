program t_clut;

{** Per-tileset CLUT lumps. Each kit tileset carries a baked 256-colour palette
  (CLUT<tileset>) median-cut from its own trim atlases, and it decodes to 256
  colours with real content. The biome tilesets, which use procedural textures,
  carry none. Asset-side only: the indexed renderer does not bind these yet. }

{$mode objfpc}{$H+}

uses
  sysutils, pak, textures, testing;

{ How many of a CLUT's 256 entries carry colour, a cheap non-degeneracy check. }
function NonBlack(const cols: TClut): longint;
var i, n: longint;
begin
  n := 0;
  for i := 0 to 255 do
    if (cols[i] and $00FFFFFF) <> 0 then inc(n);
  NonBlack := n;
end;

var
  p: TPak;
  cols: TClut;
  t: longint;
begin
  Check(PakLoad('build/game.pak', p), 'load build/game.pak (run make first)');

  { every kit tileset with trim atlases carries a CLUT that decodes to colour }
  for t := 10 to 16 do begin
    Check(LoadTilesetClut(p, t, cols),
      'kit tileset ' + IntToStr(t) + ' has a baked CLUT');
    Check(NonBlack(cols) >= 16,
      'tileset ' + IntToStr(t) + ' CLUT holds real colours, not all black');
  end;

  { a biome tileset uses procedural textures and carries no CLUT }
  Check(not LoadTilesetClut(p, 0, cols), 'a biome tileset has no CLUT');
  CheckEqI(NonBlack(cols), 0, 'a missing CLUT comes back all black');

  TestSummary('clut');
  halt(TestExit);
end.
