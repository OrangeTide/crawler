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
  rng, rules, items, chardata, dice;

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
    species: longint;     { index into SpeciesDefs }
    klass: longint;       { index into ClassDefs }
    background: longint;  { index into BackgroundDefs, -1 none }
    level: byte;
    xp: longint;
    abil: TAbilityScores;
    hpMax, hp: smallint;
    equip: array[TEquipSlot] of TItemInst;
    pack: array of TItemInst;
    alive: boolean;      { false only when slain }
    downed: boolean;     { at 0 HP but not slain: unconscious }
    guarding: boolean;   { parrying this round for +2 AC }
    brushes: byte;       { brushes with death so far today }
    poison: byte;        { remaining poison ticks }
    lycan: boolean;      { cursed with lycanthropy }
    wereform: boolean;   { transformed now, set by the full moon }
    rank: byte;          { 0 front line, 1 back line, for combat reach }
    sp: smallint;        { spell points available this fight }
  end;

var
  Roster: array of TCharacter;
  PartyGold: longint;

function EmptyInst: TItemInst;
procedure PackAdd(var c: TCharacter; const id: string; qty: longint);
procedure SetEquip(var c: TCharacter; slot: TEquipSlot; const id: string);

function CharAC(const c: TCharacter): longint;
function CharAttack(const c: TCharacter; melee: boolean): longint;
function CharTrack(const c: TCharacter): longint;
function CharSpellPoints(const c: TCharacter): longint;
function CharWeaponDie(const c: TCharacter): longint;

procedure RollAbilities(out a: TAbilityScores);
procedure MakeCharacter(var c: TCharacter; const nm: string;
  speciesIdx, classIdx, bgIdx: longint; const a: TAbilityScores);
procedure GiveClassKit(var c: TCharacter);

procedure TryLevelUp(var c: TCharacter);
procedure RestParty;
procedure NewParty;
procedure AddPartyMember(const c: TCharacter);
function PartyAlive: boolean;
function PartyConscious: boolean;
function FirstConscious: longint;

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
var
  d: longint;
begin
  if (c.equip[eqMain].def >= 0) and
     (ItemDefs[c.equip[eqMain].def].dmgSides > 0) then
    d := ItemDefs[c.equip[eqMain].def].dmgSides
  else
    d := 2;   { unarmed: 1d2 }
  if c.wereform and (d < 8) then d := 8;   { savage claws, 1d8 }
  CharWeaponDie := d;
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
  ab := AttackBonus(TTrack(ClassDefs[c.klass].track), c.level);
  if melee then
    ab := ab + AbilMod(c.abil[abSTR])
  else
    ab := ab + AbilMod(c.abil[abDEX]);
  if c.wereform then ab := ab + 2;   { the were-beast strikes hard }
  CharAttack := ab;
end;

function CharTrack(const c: TCharacter): longint;
begin
  CharTrack := ClassDefs[c.klass].track;
end;

function CharSpellPoints(const c: TCharacter): longint;
var
  t, m: longint;
begin
  t := ClassDefs[c.klass].track;
  if (t = TRK_MAGE) or (t = TRK_PRIEST) then begin
    m := AbilMod(c.abil[TAbility(ClassDefs[c.klass].prime)]);
    if m < 0 then m := 0;
    CharSpellPoints := 2 + c.level + m;
  end else
    CharSpellPoints := 0;
end;

procedure RollAbilities(out a: TAbilityScores);
var
  ab: TAbility;
begin
  for ab := abSTR to abCHA do
    a[ab] := RollAbility(GameRng);
end;

procedure MakeCharacter(var c: TCharacter; const nm: string;
  speciesIdx, classIdx, bgIdx: longint; const a: TAbilityScores);
var
  ab: TAbility;
  prime, newv: longint;
  s: TEquipSlot;
begin
  c.name := nm;
  c.species := speciesIdx;
  c.klass := classIdx;
  c.background := bgIdx;
  c.level := 1;
  c.xp := 0;
  for ab := abSTR to abCHA do begin
    newv := a[ab] + SpeciesDefs[speciesIdx].abilBonus[ord(ab)];
    if newv < 3 then newv := 3;
    if newv > 18 then newv := 18;
    c.abil[ab] := newv;
  end;
  { Human-style species give +1 to the class prime ability. }
  if (SpeciesDefs[speciesIdx].flags and SPF_PRIMEBONUS) <> 0 then begin
    prime := ClassDefs[classIdx].prime;
    if c.abil[TAbility(prime)] < 18 then
      c.abil[TAbility(prime)] := c.abil[TAbility(prime)] + 1;
  end;
  c.hpMax := MaxHPDie(ClassDefs[classIdx].hitDie, c.abil[abCON], 1);
  c.hp := c.hpMax;
  c.alive := true;
  c.downed := false;
  c.guarding := false;
  c.brushes := 0;
  c.poison := 0;
  c.lycan := false;
  c.wereform := false;
  { casters hang back by default, melee classes take the front line }
  if (ClassDefs[classIdx].track = TRK_MAGE)
    or (ClassDefs[classIdx].track = TRK_PRIEST) then
    c.rank := 1
  else
    c.rank := 0;
  c.sp := 0;
  for s := eqMain to eqLight do
    c.equip[s] := EmptyInst;
  c.pack := nil;
  GiveClassKit(c);
end;

procedure GiveClassKit(var c: TCharacter);
begin
  { Everyone carries a torch. The kit archetype on the class drives the
    rest, so a new class needs only a table row, not code. }
  SetEquip(c, eqLight, 'TORCH');
  case ClassDefs[c.klass].kit of
    KIT_SOLDIER: begin
      SetEquip(c, eqMain, 'SWORD');
      SetEquip(c, eqOff, 'SHIELD');
      SetEquip(c, eqArmor, 'MARMOR');
    end;
    KIT_HEAVY: begin
      SetEquip(c, eqMain, 'GREATAXE');
      SetEquip(c, eqArmor, 'HIDE');
      PackAdd(c, 'TROPHY', 1);
    end;
    KIT_ARCHER: begin
      SetEquip(c, eqMain, 'BOW');
      SetEquip(c, eqArmor, 'LARMOR');
      PackAdd(c, 'SWORD', 1);
      PackAdd(c, 'WOODCRFT', 1);
    end;
    KIT_PRIEST: begin
      SetEquip(c, eqMain, 'SILVER');
      SetEquip(c, eqOff, 'SHIELD');
      SetEquip(c, eqArmor, 'MARMOR');
      PackAdd(c, 'HOLYSYM', 1);
      PackAdd(c, 'HOLLY', 1);
    end;
    KIT_THIEF: begin
      SetEquip(c, eqMain, 'DAGGER');
      SetEquip(c, eqArmor, 'LARMOR');
      PackAdd(c, 'THVTOOLS', 1);
    end;
    KIT_MAGE: begin
      SetEquip(c, eqMain, 'STAFF');
      PackAdd(c, 'SPELLBK', 1);
    end;
  end;
  PackAdd(c, 'POTION', 1);
end;

procedure TryLevelUp(var c: TCharacter);
var
  track: TTrack;
begin
  if not c.alive then exit;
  track := TTrack(ClassDefs[c.klass].track);
  while c.xp >= XPForNext(track, c.level) do begin
    inc(c.level);
    c.hpMax := MaxHPDie(ClassDefs[c.klass].hitDie, c.abil[abCON], c.level);
  end;
end;

procedure RestParty;
var
  i: longint;
begin
  for i := 0 to High(Roster) do
    if Roster[i].alive then begin
      TryLevelUp(Roster[i]);
      Roster[i].hp := Roster[i].hpMax;
      Roster[i].downed := false;
      Roster[i].guarding := false;
      Roster[i].brushes := 0;
      Roster[i].poison := 0;
    end;
end;

procedure NewParty;
begin
  Roster := nil;
  PartyGold := 0;
end;

procedure AddPartyMember(const c: TCharacter);
var g: longint;
begin
  if Length(Roster) >= MAX_PARTY then exit;
  SetLength(Roster, Length(Roster) + 1);
  Roster[High(Roster)] := c;
  { the member brings the purse their background rolls up }
  if (c.background >= 0) and (c.background <= High(BackgroundDefs)) then
    if EvalDice(GameRng, BackgroundDefs[c.background].gold, g) then
      PartyGold := PartyGold + g;
end;

function PartyAlive: boolean;
var
  i: longint;
begin
  PartyAlive := false;
  for i := 0 to High(Roster) do
    if Roster[i].alive then begin
      PartyAlive := true;
      exit;
    end;
end;

function PartyConscious: boolean;
begin
  PartyConscious := FirstConscious >= 0;
end;

function FirstConscious: longint;
var
  i: longint;
begin
  FirstConscious := -1;
  for i := 0 to High(Roster) do
    if Roster[i].alive and (not Roster[i].downed) and (Roster[i].hp > 0) then begin
      FirstConscious := i;
      exit;
    end;
end;

end.
