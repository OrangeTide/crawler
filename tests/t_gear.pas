program t_gear;

{** Starting gear is data-driven. A new character's equipment and pack come
  from content/gear.txt (the common row plus the class kit archetype), not a
  hardcoded case. These checks pin the baked loadouts for the archetypes the
  pregen party uses. }

{$mode objfpc}{$H+}

uses
  sysutils, pak, rng, rules, items, chardata, party, testing;

var
  p: TPak;
  ab: TAbilityScores;
  a: TAbility;
  sp: longint;

{ The item index bound to an equip slot, or -1 if the slot is bare. }
function EquipDef(const c: TCharacter; slot: TEquipSlot): longint;
begin
  EquipDef := c.equip[slot].def;
end;

{ The total count of an item id across a character's pack, 0 if absent. }
function PackQty(const c: TCharacter; const id: string): longint;
var i, idx, total: longint;
begin
  idx := ItemIndex(id);
  total := 0;
  for i := 0 to High(c.pack) do
    if c.pack[i].def = idx then total := total + c.pack[i].qty;
  PackQty := total;
end;

{ Roll a fresh level-1 character of the named class. }
function Fresh(const classId: string): TCharacter;
var c: TCharacter;
begin
  MakeCharacter(c, 'Test', sp, ClassIndex(classId), 0, ab);
  Fresh := c;
end;

var
  c: TCharacter;

begin
  if not PakLoad('build/game.pak', p) then begin
    writeln('  FAIL could not load build/game.pak (run make first)');
    halt(2);
  end;
  Check(LoadItems(p), 'load items');
  Check(LoadCharData(p), 'load class and gear data');

  Check(Length(GearDefs) > 0, 'the gear table loaded rows');

  for a := abSTR to abCHA do ab[a] := 12;
  sp := SpeciesIndex('HUMAN');
  Check(sp >= 0, 'HUMAN species present');

  { the common loadout reaches everyone }
  c := Fresh('WIZARD');
  CheckEqI(EquipDef(c, eqLight), ItemIndex('TORCH'), 'everyone starts lit');
  CheckEqI(PackQty(c, 'RATION'), 4, 'everyone carries four rations');
  CheckEqI(PackQty(c, 'TORCH'), 3, 'everyone carries three spare torches');
  CheckEqI(PackQty(c, 'POTION'), 1, 'everyone carries one potion');

  { the soldier kit (a Fighter) }
  c := Fresh('FIGHTER');
  CheckEqI(EquipDef(c, eqMain), ItemIndex('SWORD'), 'a fighter draws a sword');
  CheckEqI(EquipDef(c, eqOff), ItemIndex('SHIELD'), 'a fighter raises a shield');
  CheckEqI(EquipDef(c, eqArmor), ItemIndex('MARMOR'), 'a fighter wears mail');

  { the mage kit (a Wizard): staff and a spellbook, no armor }
  c := Fresh('WIZARD');
  CheckEqI(EquipDef(c, eqMain), ItemIndex('STAFF'), 'a wizard holds a staff');
  CheckEqI(EquipDef(c, eqArmor), -1, 'a wizard wears no armor');
  CheckEqI(PackQty(c, 'SPELLBK'), 1, 'a wizard packs a spellbook');

  { the priest kit (a Friar) }
  c := Fresh('FRIAR');
  CheckEqI(EquipDef(c, eqMain), ItemIndex('SILVER'), 'a friar bears a silver mace');
  CheckEqI(PackQty(c, 'HOLYSYM'), 1, 'a friar packs a holy symbol');

  { the thief kit (a Thief) }
  c := Fresh('THIEF');
  CheckEqI(EquipDef(c, eqMain), ItemIndex('DAGGER'), 'a thief carries a dagger');
  CheckEqI(PackQty(c, 'THVTOOLS'), 1, 'a thief packs tools');

  TestSummary('gear');
  halt(TestExit);
end.
