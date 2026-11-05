program t_shops;

{** Shop stock: the data file loads, and vendors have distinct stock. }

{$mode objfpc}{$H+}

uses
  sysutils, pak, shops, testing;

{ Whether shop s stocks item id. }
function Stocks(s: longint; const id: string): boolean;
var k: longint;
begin
  Stocks := false;
  if s < 0 then exit;
  for k := 0 to High(ShopDefs[s].items) do
    if ShopDefs[s].items[k] = id then begin Stocks := true; exit; end;
end;

var
  p: TPak;
  gen, apo: longint;
begin
  if not PakLoad('build/game.pak', p) then begin
    writeln('  FAIL could not load build/game.pak (run make first)');
    halt(2);
  end;
  Check(LoadShops(p), 'load shops');

  gen := ShopIndex('GENERAL');
  apo := ShopIndex('APOTHECARY');
  Check(gen >= 0, 'general store present');
  Check(apo >= 0, 'apothecary present');
  Check(ShopIndex('NOSUCH') < 0, 'unknown shop id is not found');

  { the apothecary sells remedies and sacred gear }
  Check(Stocks(apo, 'POTION'), 'apothecary stocks a healing potion');
  Check(Stocks(apo, 'HOLLY'), 'apothecary stocks a sprig of holly');
  Check(Stocks(apo, 'HOLYSYM'), 'apothecary stocks a holy symbol');
  Check(not Stocks(apo, 'SWORD'), 'apothecary does not sell weapons');

  { the general store sells arms and goods, not the apothecary remedies }
  Check(Stocks(gen, 'DAGGER'), 'general store stocks a dagger');
  Check(not Stocks(gen, 'HOLLY'), 'the holly is apothecary-only');
  Check(not Stocks(gen, 'POTION'), 'potions are apothecary-only');

  TestSummary('shops');
  halt(TestExit);
end.
