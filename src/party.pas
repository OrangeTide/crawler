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
  BASE_CARRY = 16;   { bulk a character bears unburdened, before strength }
  PER_STR    = 2;    { extra bulk borne per point of strength modifier }
  REVIVE_BASE = 50;      { temple price to raise a level-1 soul }
  REVIVE_PER_LEVEL = 50; { added to the price for each level beyond the first }
  IDENTIFY_COST = 40;    { temple price to name one unknown item kind }
  HIRE_BASE = 120;       { base price to take on a hireling }
  LUNAR_MINUTES = 42524; { a synodic month in game minutes (29.53 days) }

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
    disease: byte;       { rests of lingering illness; caps recovery while set }
    lycan: boolean;      { cursed with lycanthropy }
    wereform: boolean;   { transformed now, set by the full moon }
    rank: byte;          { 0 front line, 1 back line, for combat reach }
    sp: smallint;        { spell points available this fight }
    hireling: boolean;   { a temporary hire, owed wages each lunar month }
    wage: smallint;      { their recruitment cost, also the monthly upkeep }
  end;

var
  Roster: array of TCharacter;
  PartyGold: longint;
  WagesDueClock: longword;   { clock minute the next month's wages fall due }

function EmptyInst: TItemInst;
procedure PackAdd(var c: TCharacter; const id: string; qty: longint);
{ The total quantity of an item id carried across the whole party. }
function PartyItemCount(const id: string): longint;
{ Remove qty of an item id from the party packs, drawing from each member in
  turn, and dropping emptied stacks. Returns false and changes nothing if
  the party holds fewer than qty. }
function PartyConsume(const id: string; qty: longint): boolean;
procedure SetEquip(var c: TCharacter; slot: TEquipSlot; const id: string);

function CharAC(const c: TCharacter): longint;
{ The EL_* mask the character's worn gear wards against, the OR of the resist
  mask of every equipped item. }
function CharResist(const c: TCharacter): byte;
function CharAttack(const c: TCharacter; melee: boolean): longint;
{ Carried bulk, carrying capacity, and whether the load exceeds it. Bulk is
  the item slots field summed over equipped and packed items. }
function CharLoad(const c: TCharacter): longint;
function CharCapacity(const c: TCharacter): longint;
function CharEncumbered(const c: TCharacter): boolean;
function CharTrack(const c: TCharacter): longint;
function CharSpellPoints(const c: TCharacter): longint;
function CharWeaponDie(const c: TCharacter): longint;

procedure RollAbilities(out a: TAbilityScores);
procedure MakeCharacter(var c: TCharacter; const nm: string;
  speciesIdx, classIdx, bgIdx: longint; const a: TAbilityScores);
procedure GiveClassKit(var c: TCharacter);

procedure TryLevelUp(var c: TCharacter);
procedure RestParty;
{ The gold the temple asks to raise one slain member, by level. }
function ReviveCost(const c: TCharacter): longint;
{ Raise every slain member the purse can afford, cheapest first, spending
  the gold. A raised member returns at half health. Returns the count raised. }
function TempleRevive: longint;
{ Name every unknown item kind the party carries that the purse can afford,
  spending the gold. Returns how many kinds were identified. }
function IdentifyParty: longint;
function HirelingCount: longint;
{ The price to take on a hireling, eased a little by the leader's charisma. }
function HireCost: longint;
{ Take on a random hireling under the given name, at the party's level, for
  the hire cost. Fails if the party is full or the purse is short. }
function RecruitHireling(const nm: string): boolean;
{ Pay every hireling this month's wage. A hireling the purse cannot cover
  deserts and is dropped from the roster. Returns how many left. }
function ChargeWages: longint;
procedure NewParty;
procedure AddPartyMember(const c: TCharacter);
function PartyAlive: boolean;
function PartyConscious: boolean;
function FirstConscious: longint;

implementation

uses
  codex;

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

function PartyItemCount(const id: string): longint;
var
  di, i, j, n: longint;
begin
  PartyItemCount := 0;
  di := ItemIndex(id);
  if di < 0 then exit;
  n := 0;
  for i := 0 to High(Roster) do
    for j := 0 to High(Roster[i].pack) do
      if Roster[i].pack[j].def = di then inc(n, Roster[i].pack[j].qty);
  PartyItemCount := n;
end;

procedure PackCompact(var c: TCharacter);
{ Drop emptied stacks (qty 0) from a pack. }
var
  i, n: longint;
  keep: array of TItemInst;
begin
  n := 0;
  SetLength(keep, Length(c.pack));
  for i := 0 to High(c.pack) do
    if c.pack[i].qty > 0 then begin
      keep[n] := c.pack[i];
      inc(n);
    end;
  SetLength(keep, n);
  c.pack := keep;
end;

function PartyConsume(const id: string; qty: longint): boolean;
var
  di, i, j, take: longint;
begin
  PartyConsume := false;
  if qty <= 0 then begin PartyConsume := true; exit; end;
  if PartyItemCount(id) < qty then exit;   { not enough; change nothing }
  di := ItemIndex(id);
  for i := 0 to High(Roster) do begin
    for j := 0 to High(Roster[i].pack) do begin
      if qty <= 0 then break;
      if Roster[i].pack[j].def = di then begin
        take := Roster[i].pack[j].qty;
        if take > qty then take := qty;
        Roster[i].pack[j].qty := Roster[i].pack[j].qty - take;
        qty := qty - take;
      end;
    end;
    PackCompact(Roster[i]);
  end;
  PartyConsume := true;
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

function CharResist(const c: TCharacter): byte;
var
  mask: byte;
  sl: TEquipSlot;
begin
  mask := 0;
  for sl := eqMain to eqLight do
    if c.equip[sl].def >= 0 then
      mask := mask or ItemDefs[c.equip[sl].def].resist;
  CharResist := mask;
end;

function CharLoad(const c: TCharacter): longint;
var
  total, i: longint;
  sl: TEquipSlot;
begin
  total := 0;
  for sl := eqMain to eqLight do
    if c.equip[sl].def >= 0 then
      total := total + ItemDefs[c.equip[sl].def].slots;
  for i := 0 to High(c.pack) do
    if c.pack[i].def >= 0 then
      total := total + ItemDefs[c.pack[i].def].slots * c.pack[i].qty;
  CharLoad := total;
end;

function CharCapacity(const c: TCharacter): longint;
begin
  CharCapacity := BASE_CARRY + AbilMod(c.abil[abSTR]) * PER_STR;
end;

function CharEncumbered(const c: TCharacter): boolean;
begin
  CharEncumbered := CharLoad(c) > CharCapacity(c);
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
  c.disease := 0;
  c.lycan := false;
  c.wereform := false;
  c.hireling := false;
  c.wage := 0;
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
  PackAdd(c, 'RATION', 4);   { trail food, spent resting }
  PackAdd(c, 'TORCH', 3);    { spare torches, lit as the light burns out }
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
      Roster[i].downed := false;
      Roster[i].guarding := false;
      Roster[i].poison := 0;   { acute poison passes with the night }
      if Roster[i].disease > 0 then begin
        { the fever runs its course over several rests, and caps recovery
          at half strength until it breaks. No level-up catch-up while sick. }
        dec(Roster[i].disease);
        if Roster[i].hp < Roster[i].hpMax div 2 then
          Roster[i].hp := Roster[i].hpMax div 2;
      end else begin
        TryLevelUp(Roster[i]);
        Roster[i].hp := Roster[i].hpMax;
        Roster[i].brushes := 0;
      end;
    end;
end;

function ReviveCost(const c: TCharacter): longint;
begin
  ReviveCost := REVIVE_BASE + (c.level - 1) * REVIVE_PER_LEVEL;
end;

function TempleRevive: longint;
var
  i, best, cost, bestCost: longint;
begin
  TempleRevive := 0;
  repeat
    { pick the cheapest slain member the purse can still afford }
    best := -1;
    bestCost := 0;
    for i := 0 to High(Roster) do
      if not Roster[i].alive then begin
        cost := ReviveCost(Roster[i]);
        if (cost <= PartyGold) and ((best < 0) or (cost < bestCost)) then begin
          best := i;
          bestCost := cost;
        end;
      end;
    if best < 0 then break;
    PartyGold := PartyGold - bestCost;
    Roster[best].alive := true;
    Roster[best].downed := false;
    Roster[best].guarding := false;
    Roster[best].brushes := 0;
    Roster[best].poison := 0;
    Roster[best].disease := 0;
    Roster[best].hp := Roster[best].hpMax div 2;   { raised, but weakened }
    if Roster[best].hp < 1 then Roster[best].hp := 1;
    inc(TempleRevive);
  until false;
end;

function IdentifyParty: longint;
var
  i, j, def, cnt: longint;
begin
  cnt := 0;
  for i := 0 to High(Roster) do
    for j := 0 to High(Roster[i].pack) do begin
      def := Roster[i].pack[j].def;
      if (def >= 0) and (Roster[i].pack[j].qty > 0) and (not ItemIsKnown(def)) then
      begin
        if PartyGold < IDENTIFY_COST then begin IdentifyParty := cnt; exit; end;
        PartyGold := PartyGold - IDENTIFY_COST;
        MarkItemKnown(def);   { later copies of the same kind read as known }
        inc(cnt);
      end;
    end;
  IdentifyParty := cnt;
end;

function HirelingCount: longint;
var i, n: longint;
begin
  n := 0;
  for i := 0 to High(Roster) do
    if Roster[i].hireling then inc(n);
  HirelingCount := n;
end;

function HireCost: longint;
var lead, chaMod: longint;
begin
  { the first standing member leads the bargaining; higher charisma, lower fee }
  chaMod := 0;
  for lead := 0 to High(Roster) do
    if Roster[lead].alive and (not Roster[lead].hireling) then begin
      chaMod := AbilMod(Roster[lead].abil[abCHA]);
      break;
    end;
  HireCost := HIRE_BASE - chaMod * 15;
  if HireCost < 40 then HireCost := 40;
end;

function RecruitHireling(const nm: string): boolean;
var
  c: TCharacter;
  a: TAbilityScores;
  cost, lvl, i: longint;
begin
  RecruitHireling := false;
  if Length(Roster) >= MAX_PARTY then exit;
  cost := HireCost;
  if PartyGold < cost then exit;
  { a hire comes in at the party's level so it can pull its weight }
  lvl := 1;
  for i := 0 to High(Roster) do
    if (not Roster[i].hireling) and (Roster[i].level > lvl) then lvl := Roster[i].level;
  RollAbilities(a);
  MakeCharacter(c, nm, Range(0, High(SpeciesDefs)), Range(0, High(ClassDefs)),
    -1, a);
  if lvl > 1 then begin
    c.level := lvl;
    c.hpMax := MaxHPDie(ClassDefs[c.klass].hitDie, c.abil[abCON], lvl);
    c.hp := c.hpMax;
  end;
  c.hireling := true;
  c.wage := cost;
  PartyGold := PartyGold - cost;
  AddPartyMember(c);
  RecruitHireling := true;
end;

function ChargeWages: longint;
var i, j, left: longint;
begin
  left := 0;
  i := 0;
  while i <= High(Roster) do begin
    if Roster[i].hireling then begin
      if PartyGold >= Roster[i].wage then begin
        PartyGold := PartyGold - Roster[i].wage;
        inc(i);
      end else begin
        { unpaid: the hireling walks off }
        for j := i to High(Roster) - 1 do Roster[j] := Roster[j + 1];
        SetLength(Roster, Length(Roster) - 1);
        inc(left);
      end;
    end else
      inc(i);
  end;
  ChargeWages := left;
end;

procedure NewParty;
begin
  Roster := nil;
  PartyGold := 0;
  WagesDueClock := 0;
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
