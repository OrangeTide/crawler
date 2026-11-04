unit party;

{** Roster of characters, their derived stats and character creation.

  Up to four characters share one camera in the dungeon. A character
  carries ability scores, class and level, hit points, equipped items
  and a pack. Item instances reference the item database by index so the
  records stay small. Creation follows the AX&X flow: roll 3d6 in order,
  apply the kindred bonus, take the class kit. }

{$mode objfpc}{$H+}

interface

uses
  rng, rules, items;

const
  MAX_PARTY = 4;

type
  TEquipSlot = (eqMain, eqOff, eqArmor, eqLight);

  TItemInst = record
    def: smallint;        { index into ItemDefs, -1 = empty }
    qty: word;
    identified: boolean;
  end;

  TCharacter = record
    name: string[15];
    kindred: TKindred;
    klass: TCharClass;
    level: byte;
    xp: longint;
    abil: TAbilityScores;
    hpMax, hp: smallint;
    equip: array[TEquipSlot] of TItemInst;
    pack: array of TItemInst;
    alive: boolean;
  end;

var
  Roster: array of TCharacter;
  PartyGold: longint;

function EmptyInst: TItemInst;
procedure PackAdd(var c: TCharacter; const id: string; qty: longint);
procedure SetEquip(var c: TCharacter; slot: TEquipSlot; const id: string);

function CharAC(const c: TCharacter): longint;
function CharAttack(const c: TCharacter; melee: boolean): longint;
function CharWeaponDie(const c: TCharacter): longint;
function PrimeAbility(cls: TCharClass): TAbility;

procedure RollAbilities(out a: TAbilityScores);
procedure MakeCharacter(var c: TCharacter; const nm: string;
  kin: TKindred; cls: TCharClass; const a: TAbilityScores);
procedure GiveClassKit(var c: TCharacter);

procedure NewParty;
procedure AddPartyMember(const c: TCharacter);
function PartyAlive: boolean;

implementation

function EmptyInst: TItemInst;
begin
  EmptyInst.def := -1;
  EmptyInst.qty := 0;
  EmptyInst.identified := true;
end;

function MakeInst(const id: string; qty: longint): TItemInst;
begin
  MakeInst.def := ItemIndex(id);
  MakeInst.qty := qty;
  MakeInst.identified := true;
end;

procedure PackAdd(var c: TCharacter; const id: string; qty: longint);
begin
  if ItemIndex(id) < 0 then exit;
  SetLength(c.pack, Length(c.pack) + 1);
  c.pack[High(c.pack)] := MakeInst(id, qty);
end;

procedure SetEquip(var c: TCharacter; slot: TEquipSlot; const id: string);
begin
  c.equip[slot] := MakeInst(id, 1);
end;

function PrimeAbility(cls: TCharClass): TAbility;
begin
  case cls of
    ccFighter, ccBarbarian: PrimeAbility := abSTR;
    ccRanger, ccThief:      PrimeAbility := abDEX;
    ccCleric:               PrimeAbility := abWIS;
  else
    PrimeAbility := abINT;
  end;
end;

function CharAC(const c: TCharacter): longint;
var
  ac: longint;
begin
  ac := 10;
  if (c.equip[eqArmor].def >= 0) and
     (ItemDefs[c.equip[eqArmor].def].kind = IK_ARMOR) then
    ac := ItemDefs[c.equip[eqArmor].def].acVal;
  ac := ac + AbilMod(c.abil[abDEX]);
  if (c.equip[eqOff].def >= 0) and
     (ItemDefs[c.equip[eqOff].def].kind = IK_SHIELD) then
    ac := ac + ItemDefs[c.equip[eqOff].def].acVal;
  CharAC := ac;
end;

function CharWeaponDie(const c: TCharacter): longint;
begin
  if (c.equip[eqMain].def >= 0) and
     (ItemDefs[c.equip[eqMain].def].dmgSides > 0) then
    CharWeaponDie := ItemDefs[c.equip[eqMain].def].dmgSides
  else
    CharWeaponDie := 2;   { unarmed: 1d2 }
end;

function WeaponIsRanged(const c: TCharacter): boolean;
begin
  WeaponIsRanged := (c.equip[eqMain].def >= 0) and
    ((ItemDefs[c.equip[eqMain].def].flags and IF_RANGED) <> 0);
end;

function CharAttack(const c: TCharacter; melee: boolean): longint;
var
  ab: longint;
begin
  ab := AttackBonus(CLASS_TRACK[c.klass], c.level);
  if melee then
    ab := ab + AbilMod(c.abil[abSTR])
  else
    ab := ab + AbilMod(c.abil[abDEX]);
  CharAttack := ab;
end;

procedure RollAbilities(out a: TAbilityScores);
var
  ab: TAbility;
begin
  for ab := abSTR to abCHA do
    a[ab] := RollAbility(GameRng);
end;

procedure MakeCharacter(var c: TCharacter; const nm: string;
  kin: TKindred; cls: TCharClass; const a: TAbilityScores);
var
  ab: TAbility;
  prime: TAbility;
  s: TEquipSlot;
begin
  c.name := nm;
  c.kindred := kin;
  c.klass := cls;
  c.level := 1;
  c.xp := 0;
  for ab := abSTR to abCHA do
    c.abil[ab] := a[ab];
  { Human gets +1 to its prime ability. }
  if kin = kHuman then begin
    prime := PrimeAbility(cls);
    if c.abil[prime] < 18 then
      c.abil[prime] := c.abil[prime] + 1;
  end;
  c.hpMax := MaxHP(cls, c.abil[abCON], 1);
  c.hp := c.hpMax;
  c.alive := true;
  for s := eqMain to eqLight do
    c.equip[s] := EmptyInst;
  c.pack := nil;
  GiveClassKit(c);
end;

procedure GiveClassKit(var c: TCharacter);
begin
  { Everyone carries a torch. }
  SetEquip(c, eqLight, 'TORCH');
  case c.klass of
    ccFighter: begin
      SetEquip(c, eqMain, 'SWORD');
      SetEquip(c, eqOff, 'SHIELD');
      SetEquip(c, eqArmor, 'MARMOR');
    end;
    ccBarbarian: begin
      SetEquip(c, eqMain, 'GREATAXE');
      SetEquip(c, eqArmor, 'HIDE');
      PackAdd(c, 'TROPHY', 1);
    end;
    ccRanger: begin
      SetEquip(c, eqMain, 'BOW');
      SetEquip(c, eqArmor, 'LARMOR');
      PackAdd(c, 'SWORD', 1);
      PackAdd(c, 'WOODCRFT', 1);
    end;
    ccCleric: begin
      SetEquip(c, eqMain, 'MACE');
      SetEquip(c, eqOff, 'SHIELD');
      SetEquip(c, eqArmor, 'MARMOR');
      PackAdd(c, 'HOLYSYM', 1);
    end;
    ccThief: begin
      SetEquip(c, eqMain, 'DAGGER');
      SetEquip(c, eqArmor, 'LARMOR');
      PackAdd(c, 'THVTOOLS', 1);
    end;
    ccMagicUser: begin
      SetEquip(c, eqMain, 'STAFF');
      PackAdd(c, 'SPELLBK', 1);
    end;
  end;
  PackAdd(c, 'POTION', 1);
end;

procedure NewParty;
begin
  Roster := nil;
  PartyGold := 0;
end;

procedure AddPartyMember(const c: TCharacter);
begin
  if Length(Roster) >= MAX_PARTY then exit;
  SetLength(Roster, Length(Roster) + 1);
  Roster[High(Roster)] := c;
end;

function PartyAlive: boolean;
var
  i: longint;
begin
  PartyAlive := false;
  for i := 0 to High(Roster) do
    if Roster[i].alive and (Roster[i].hp > 0) then begin
      PartyAlive := true;
      exit;
    end;
end;

end.
