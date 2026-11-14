unit combatcore;

{** The leaf logic of a fight: resolution, tactics, status, and spell data.

  Everything here reads and writes combatstate but drives nothing: it does not
  advance turns or run the foe AI. The turn-order driver (combat) and the foe
  AI (combatai) both build on these primitives. The routines the tests pin
  (ElementMult, DamageFoe, ResistedHit, AfflictFoe, ResolvePartyAttack, the
  spell queries) live here. }

{$mode objfpc}{$H+}

interface

uses
  sysutils, rng, rules, items, monsters, party, chardata, spelldb, spellbook,
  skilldb, skillbook, combatstate;

{ The party casts from the spell catalog (spelldb): a caster draws the castable
  spells of its class domain that its level reaches. SpellCount, SpellInfo and
  ActorCanCast work over that per-actor list, which is rebuilt on demand. }

procedure CombatLog(const s: string);

{ Hit feedback: floating numbers and target flashes. }
procedure PushPop(side, idx, color: longint; const txt: string);
procedure FlashFoe(idx: longint);
procedure FlashAlly(idx: longint);
procedure DecayFeedback(dt: double);

{ Tactics and queries. }
function LivingFoes: longint;
function FirstLivingFoe: longint;
{ First foe the actor can actually strike, or -1. }
function FirstReachable(actor: longint): longint;
{ The frontmost living rank on each side; melee can only reach it. }
function FrontFoeRank: longint;
function FrontPartyRank: longint;
{ Whether the actor could strike this foe with its current weapon. }
function FoeReachable(actor, foe: longint): boolean;

{ The damage multiplier an element deals to a foe: 0 immune, 0.5 resisted,
  1.5 against a weakness, 1 otherwise. }
function ElementMult(element, fi: longint): double;
{ Deal elemental damage to a foe, applying its weakness or resistance. }
procedure DamageFoe(fi, baseAmount, element: longint);
{ The damage a party member takes after worn-gear resistance: halved (min 1)
  when the member's gear wards the hit's element, unchanged otherwise. }
function ResistedHit(mi, dmg, element: longint): longint;
{ Apply damage to a party member, resolving a brush with death on a drop. }
procedure HurtMember(mi, dmg: longint);
{ Try to lay a status on a foe; immunity blocks it, a save resists it. The
  optional dcBonus raises the save difficulty (a specialist's school edge). }
procedure AfflictFoe(fi, st, turns: longint; dcBonus: longint = 0);
{ Try to lay a status on a party member; a save shrugs it. }
procedure AfflictMember(mi, st, turns: longint);

{ ---- the uniform combatant seam: address a combatant as (side, idx) ----
  Each call dispatches to the foe path (SIDE_FOE, over TFoe/MonDefs) or the
  party path (SIDE_PARTY, over TCharacter), so a caller need not branch on the
  side. The typed procedures above are the dispatch targets. }
function CombatantCount(side: longint): longint;
function CombatantUp(side, idx: longint): boolean;      { foe alive; member up }
function CombatantName(side, idx: longint): string;
function CombatantStatus(side, idx: longint): PStatus;  { the status timers }
function FrontRank(side: longint): longint;             { frontmost living rank }
procedure FlashCombatant(side, idx: longint);
procedure AfflictCombatant(side, idx, st, turns: longint; dcBonus: longint = 0);
procedure DamageCombatant(side, idx, amount, element: longint);
{ Resolve one party melee or ranged attack; off balance rolls at disadvantage.
  hitMod and dmgMod bend a maneuver's swing (power attack trades hit for
  damage, an aimed shot buys hit); inflict lays a status on the foe when the
  blow lands (a disarm knocks it off balance, a bash stuns). }
procedure ResolvePartyAttack(actor, foe: longint;
  hitMod: longint = 0; dmgMod: longint = 0; inflict: longint = 0);

{ Drop the cached per-actor spell list so it rebuilds; call at fight start. }
procedure ResetSpellList;
function SpellCount: longint;
function SpellInfo(i: longint): TSpell;
function ActorCanCast(actor, spellIdx: longint): boolean;
{ The spell ability modifier: the caster's class prime ability. }
function CasterMod(actor: longint): longint;

{ Combat maneuvers (skilldb, arena SKA_COMBAT): Active^.CurActor's known combat skills,
  rebuilt on demand, with per-fight use limits tracked in Active^.SkillUse. The queries
  mirror the spell list above. }
procedure ResetSkillMenu;
function CombatSkillCount: longint;
{ The catalog index of the i-th combat skill in the current actor's menu, -1
  when out of range. }
function CombatSkillCat(i: longint): longint;
function CombatSkillInfo(i: longint): TSkillDef;
{ Uses left this fight for the i-th skill: -1 means at will (no limit). }
function CombatSkillUsesLeft(actor, i: longint): longint;
{ Whether the actor may use the i-th maneuver now: alive, its gear requirement
  met, and a use left this fight. }
function ActorCanManeuver(actor, i: longint): boolean;
{ Count one use of the i-th maneuver against its per-fight limit. }
procedure SpendManeuver(actor, i: longint);

implementation

const
  STATUS_DC  = 13;     { save target to shrug off an inflicted status }
  FEAR_ATK   = 3;      { to-hit penalty while afraid }
  ENCUMBER_ATK = 2;    { to-hit penalty while carrying too much }
  DISEASE_DAYS = 2;    { rests a caught illness lingers before it breaks }

{ ---- logging ---- }

procedure CombatLog(const s: string);
var
  i: longint;
begin
  for i := 0 to LOG_LINES - 2 do
    Active^.Log[i] := Active^.Log[i + 1];
  Active^.Log[LOG_LINES - 1] := s;
end;

{ ---- hit feedback ---- }

procedure PushPop(side, idx, color: longint; const txt: string);
var k: longint;
begin
  k := Length(Active^.Pops);
  SetLength(Active^.Pops, k + 1);
  Active^.Pops[k].side := side;
  Active^.Pops[k].idx := idx;
  Active^.Pops[k].text := Copy(txt, 1, 7);
  Active^.Pops[k].color := color;
  Active^.Pops[k].life := POP_LIFE;
end;

procedure FlashFoe(idx: longint);
begin
  if (idx >= 0) and (idx <= High(Active^.FoeFlash)) then Active^.FoeFlash[idx] := FLASH_LIFE;
end;

procedure FlashAlly(idx: longint);
begin
  if (idx >= 0) and (idx <= High(Active^.PartyFlash)) then Active^.PartyFlash[idx] := FLASH_LIFE;
end;

{ Age the flashes and floating numbers; drop the ones that expired. }
procedure DecayFeedback(dt: double);
var i, w: longint;
begin
  for i := 0 to High(Active^.FoeFlash) do
    if Active^.FoeFlash[i] > 0 then begin
      Active^.FoeFlash[i] := Active^.FoeFlash[i] - dt;
      if Active^.FoeFlash[i] < 0 then Active^.FoeFlash[i] := 0;
    end;
  for i := 0 to High(Active^.PartyFlash) do
    if Active^.PartyFlash[i] > 0 then begin
      Active^.PartyFlash[i] := Active^.PartyFlash[i] - dt;
      if Active^.PartyFlash[i] < 0 then Active^.PartyFlash[i] := 0;
    end;
  w := 0;
  for i := 0 to High(Active^.Pops) do begin
    Active^.Pops[i].life := Active^.Pops[i].life - dt;
    if Active^.Pops[i].life > 0 then begin
      if w <> i then Active^.Pops[w] := Active^.Pops[i];
      inc(w);
    end;
  end;
  SetLength(Active^.Pops, w);
end;

{ ---- helpers ---- }

function LivingFoes: longint;
var i, n: longint;
begin
  n := 0;
  for i := 0 to High(Active^.Foes) do
    if Active^.Foes[i].alive then inc(n);
  LivingFoes := n;
end;

function FirstLivingFoe: longint;
var i: longint;
begin
  FirstLivingFoe := -1;
  for i := 0 to High(Active^.Foes) do
    if Active^.Foes[i].alive then begin FirstLivingFoe := i; exit; end;
end;

{ The frontmost living foe rank: 0 if any front foe lives, else 1. }
function FrontFoeRank: longint;
var i: longint;
begin
  for i := 0 to High(Active^.Foes) do
    if Active^.Foes[i].alive and (Active^.Foes[i].rank = RANK_FRONT) then begin
      FrontFoeRank := RANK_FRONT; exit;
    end;
  FrontFoeRank := RANK_BACK;
end;

{ The frontmost conscious party rank. }
function FrontPartyRank: longint;
var i: longint;
begin
  for i := 0 to High(Active^.Party^) do
    if Active^.Party^[i].alive and (not Active^.Party^[i].downed) and (Active^.Party^[i].rank = RANK_FRONT) then begin
      FrontPartyRank := RANK_FRONT; exit;
    end;
  FrontPartyRank := RANK_BACK;
end;

{ ---- the uniform combatant seam ---- }

function CombatantCount(side: longint): longint;
begin
  if side = SIDE_FOE then CombatantCount := Length(Active^.Foes)
  else CombatantCount := Length(Active^.Party^);
end;

function CombatantUp(side, idx: longint): boolean;
begin
  if side = SIDE_FOE then
    CombatantUp := (idx >= 0) and (idx <= High(Active^.Foes))
      and Active^.Foes[idx].alive
  else
    CombatantUp := (idx >= 0) and (idx <= High(Active^.Party^))
      and Active^.Party^[idx].alive and (not Active^.Party^[idx].downed);
end;

function CombatantName(side, idx: longint): string;
begin
  if side = SIDE_FOE then CombatantName := MonDefs[Active^.Foes[idx].def].name
  else CombatantName := Active^.Party^[idx].name;
end;

function CombatantStatus(side, idx: longint): PStatus;
begin
  if side = SIDE_FOE then CombatantStatus := @Active^.FoeStatus[idx]
  else CombatantStatus := @Active^.PartyStatus[idx];
end;

function FrontRank(side: longint): longint;
begin
  if side = SIDE_FOE then FrontRank := FrontFoeRank
  else FrontRank := FrontPartyRank;
end;

procedure FlashCombatant(side, idx: longint);
begin
  if side = SIDE_FOE then FlashFoe(idx) else FlashAlly(idx);
end;

procedure AfflictCombatant(side, idx, st, turns: longint; dcBonus: longint = 0);
begin
  if side = SIDE_FOE then AfflictFoe(idx, st, turns, dcBonus)
  else AfflictMember(idx, st, turns);
end;

{ Damage a combatant on either side. The foe path bundles the element
  multiplier, pop, flash and kill; the party path applies worn-gear resistance,
  then the floating number, flash and the brush-with-death drop. }
procedure DamageCombatant(side, idx, amount, element: longint);
var dmg: longint;
begin
  if side = SIDE_FOE then
    DamageFoe(idx, amount, element)
  else begin
    dmg := ResistedHit(idx, amount, element);
    PushPop(SIDE_PARTY, idx, POPC_PARTYDMG, IntToStr(dmg));
    FlashAlly(idx);
    HurtMember(idx, dmg);
  end;
end;

function WeaponRanged(const c: TCharacter): boolean;
begin
  WeaponRanged := (c.equip[eqMain].def >= 0) and
    ((ItemDefs[c.equip[eqMain].def].flags and IF_RANGED) <> 0);
end;

{ A character's weapon element: silvered/blessed weapons strike as holy,
  everything else as plain physical. }
function WeaponElement(const c: TCharacter): byte;
begin
  if (c.equip[eqMain].def >= 0) and
     ((ItemDefs[c.equip[eqMain].def].flags and IF_SILVER) <> 0) then
    WeaponElement := EL_HOLY
  else
    WeaponElement := EL_PHYS;
end;

{ Whether actor can strike foe: ranged weapons reach any rank, melee only
  the frontmost living enemy rank, and only from the party front line. }
function FoeReachable(actor, foe: longint): boolean;
begin
  FoeReachable := false;
  if (foe < 0) or (foe > High(Active^.Foes)) or (not Active^.Foes[foe].alive) then exit;
  if WeaponRanged(Active^.Party^[actor]) then begin
    FoeReachable := true;           { arrows and bolts reach the back rank }
    exit;
  end;
  if Active^.Party^[actor].rank <> RANK_FRONT then exit;   { no melee from the back }
  FoeReachable := Active^.Foes[foe].rank = FrontFoeRank;
end;

{ First foe the actor can actually strike, or -1. }
function FirstReachable(actor: longint): longint;
var i: longint;
begin
  FirstReachable := -1;
  for i := 0 to High(Active^.Foes) do
    if FoeReachable(actor, i) then begin FirstReachable := i; exit; end;
end;

{ ---- elements and status ---- }

function ElementMult(element, fi: longint): double;
var e: byte;
begin
  e := element;
  if e = 0 then e := EL_PHYS;
  if (MonDefs[Active^.Foes[fi].def].immune and e) <> 0 then ElementMult := 0.0
  else if (MonDefs[Active^.Foes[fi].def].weak and e) <> 0 then ElementMult := 1.5
  else if (MonDefs[Active^.Foes[fi].def].resist and e) <> 0 then ElementMult := 0.5
  else ElementMult := 1.0;
end;

function StatusName(st: longint): string;
begin
  case st of
    ST_POISON: StatusName := 'POISON';
    ST_STUN:   StatusName := 'STUN';
    ST_SLOW:   StatusName := 'SLOW';
    ST_BURN:   StatusName := 'BURN';
    ST_OFFBAL: StatusName := 'DAZED';
    ST_FEAR:   StatusName := 'AFRAID';
    ST_PARAL:  StatusName := 'HELD';
    ST_DISEASE: StatusName := 'SICK';
  else StatusName := '';
  end;
end;

procedure SetStatus(var s: TStatus; st, turns: longint);
begin
  case st of
    ST_POISON: if turns > s.poison then s.poison := turns;
    ST_STUN:   if turns > s.stun then s.stun := turns;
    ST_SLOW:   if turns > s.slow then s.slow := turns;
    ST_BURN:   if turns > s.burn then s.burn := turns;
    ST_OFFBAL: if turns > s.offbal then s.offbal := turns;
    ST_FEAR:   if turns > s.fear then s.fear := turns;
    ST_PARAL:  if turns > s.paralyze then s.paralyze := turns;
  end;
end;

{ Try to lay a status on a foe: blocked by immunity, resisted by a save. }
procedure AfflictFoe(fi, st, turns: longint; dcBonus: longint = 0);
begin
  if st = 0 then exit;
  if st = ST_DISEASE then exit;   { illness is a party burden, not a foe's }
  if (MonDefs[Active^.Foes[fi].def].statusImm and st) <> 0 then exit;
  if SaveThrow(GameRng, 0, MonDefs[Active^.Foes[fi].def].hd, STATUS_DC + dcBonus) then exit;
  SetStatus(Active^.FoeStatus[fi], st, turns);
  CombatLog(MonDefs[Active^.Foes[fi].def].name + ' is ' + StatusName(st) + '.');
  PushPop(0, fi, POPC_MISS, StatusName(st));
end;

{ Try to lay a status on a party member; a save shrugs it. Fear is a Will
  save (WIS), the rest resist with Body (CON). }
procedure AfflictMember(mi, st, turns: longint);
var
  save: longint;
begin
  if st = 0 then exit;
  if st = ST_FEAR then
    save := AbilMod(Active^.Party^[mi].abil[abWIS])
  else
    save := AbilMod(Active^.Party^[mi].abil[abCON]);
  if SaveThrow(GameRng, save, Active^.Party^[mi].level, STATUS_DC) then exit;
  { disease is not an in-fight timer: it rides out on the character and is
    shaken off only by resting it out. }
  if st = ST_DISEASE then begin
    if Active^.Party^[mi].disease < DISEASE_DAYS then Active^.Party^[mi].disease := DISEASE_DAYS;
    CombatLog(Active^.Party^[mi].name + ' is ' + StatusName(st) + '.');
    PushPop(1, mi, POPC_MISS, StatusName(st));
    exit;
  end;
  SetStatus(Active^.PartyStatus[mi], st, turns);
  CombatLog(Active^.Party^[mi].name + ' is ' + StatusName(st) + '.');
  PushPop(1, mi, POPC_MISS, StatusName(st));
end;

{ ---- resolution primitives ---- }

procedure KillFoe(fi: longint);
begin
  Active^.Foes[fi].alive := false;
  Active^.XPGained := Active^.XPGained + MonDefs[Active^.Foes[fi].def].xp;
  CombatLog(MonDefs[Active^.Foes[fi].def].name + ' is destroyed.');
end;

{ Deal elemental damage to a foe, applying its weakness or resistance and
  colouring the floating number to match. }
procedure DamageFoe(fi, baseAmount, element: longint);
var
  mult: double;
  amount, color: longint;
begin
  if not Active^.Foes[fi].alive then exit;
  mult := ElementMult(element, fi);
  if mult <= 0 then begin
    CombatLog(MonDefs[Active^.Foes[fi].def].name + ' is unharmed.');
    PushPop(0, fi, POPC_MISS, 'NULL');
    FlashFoe(fi);
    exit;
  end;
  amount := round(baseAmount * mult);
  if amount < 1 then amount := 1;
  if mult > 1 then color := POPC_WEAK
  else if mult < 1 then color := POPC_RESIST
  else color := POPC_FOEDMG;
  Active^.Foes[fi].hp := Active^.Foes[fi].hp - amount;
  CombatLog(MonDefs[Active^.Foes[fi].def].name + ' takes ' + IntToStr(amount) + '.');
  PushPop(0, fi, color, IntToStr(amount));
  FlashFoe(fi);
  if Active^.Foes[fi].hp <= 0 then KillFoe(fi);
end;

procedure HurtMember(mi, dmg: longint);
var roll: longint;
begin
  Active^.Party^[mi].hp := Active^.Party^[mi].hp - dmg;
  if Active^.Party^[mi].hp <= 0 then begin
    Active^.Party^[mi].hp := 0;
    { Brush with Death: 1d6 + prior brushes; 7+ is slain. }
    inc(Active^.Party^[mi].brushes);
    roll := D(6) + (Active^.Party^[mi].brushes - 1);
    if roll >= 7 then begin
      Active^.Party^[mi].alive := false;
      Active^.Party^[mi].downed := true;
      CombatLog(Active^.Party^[mi].name + ' is slain!');
    end else begin
      Active^.Party^[mi].downed := true;
      CombatLog(Active^.Party^[mi].name + ' falls, gravely wounded.');
    end;
  end;
end;

function ElementName(element: longint): string;
begin
  case element of
    EL_FIRE:  ElementName := 'the flames';
    EL_FROST: ElementName := 'the cold';
    EL_SHOCK: ElementName := 'the shock';
    EL_HOLY:  ElementName := 'the holy fire';
  else
    ElementName := 'the blow';
  end;
end;

function ResistedHit(mi, dmg, element: longint): longint;
{** Halve incoming elemental damage when the member's worn gear wards against
  that element, and note it in the log. Physical and untyped hits pass through
  since no gear resists them. }
begin
  ResistedHit := dmg;
  if (element <> 0) and ((CharResist(Active^.Party^[mi]) and element) <> 0) then begin
    ResistedHit := dmg div 2;
    if ResistedHit < 1 then ResistedHit := 1;
    CombatLog(Active^.Party^[mi].name + ' shrugs off ' + ElementName(element) + '.');
  end;
end;

{ ---- spell data: the caster's domain spells, rebuilt on demand ---- }

var
  gListActor: longint = -1;   { whose list gList currently holds }
  gList: array of longint;    { catalog indices this caster may cast }

procedure BuildList(actor: longint);
var dom, i, j, tmp: longint;
begin
  gListActor := actor;
  SetLength(gList, 0);
  if (actor < 0) or (actor > High(Active^.Party^)) then exit;
  dom := ClassDomain(Active^.Party^[actor].klass);
  if dom = SPD_NONE then exit;
  { the castable spells of the domain the caster has learned and its level
    reaches, so the combat menu holds only known, reachable spells }
  for i := 0 to SpellDefCount - 1 do
    if SpellDefs[i].castable and (SpellDefs[i].domain = dom)
      and (SpellDefs[i].level <= MaxSpellLevel(Active^.Party^[actor]))
      and SpellAllowed(Active^.Party^[actor], i)
      and CharKnows(Active^.Party^[actor], i)
      and ((not OptPrepared) or CharPrepared(Active^.Party^[actor], i)) then begin
      SetLength(gList, Length(gList) + 1);
      gList[High(gList)] := i;
    end;
  { order the menu by spell level; the catalog keeps some spells out of order }
  for i := 1 to High(gList) do begin
    tmp := gList[i]; j := i - 1;
    while (j >= 0) and (SpellDefs[gList[j]].level > SpellDefs[tmp].level) do begin
      gList[j + 1] := gList[j]; dec(j);
    end;
    gList[j + 1] := tmp;
  end;
end;

procedure EnsureList(actor: longint);
begin
  if gListActor <> actor then BuildList(actor);
end;

procedure ResetSpellList;
begin
  gListActor := -1;
end;

{ Build a combat spell from a catalog entry: the prose is the intent, these
  fields its thematic combat shape. The source damage type sets the element. }
function SpellFromCatalog(cat: longint): TSpell;
var d: TSpellDef;
begin
  d := SpellDefs[cat];
  SpellFromCatalog.id := d.id;
  SpellFromCatalog.name := d.name;
  SpellFromCatalog.track := 0;
  SpellFromCatalog.cost := d.castCost;
  case d.castMode of
    SCM_RANK:  SpellFromCatalog.mode := TGT_ENEMY_RANK;
    SCM_ALLY:  SpellFromCatalog.mode := TGT_ALLY;
    SCM_PARTY: SpellFromCatalog.mode := TGT_PARTY;
  else
    SpellFromCatalog.mode := TGT_ENEMY;
  end;
  case d.castEffect of
    SCE_HEAL:  SpellFromCatalog.effect := EF_HEAL;
    SCE_BLESS: SpellFromCatalog.effect := EF_BLESS;
  else
    SpellFromCatalog.effect := EF_DAMAGE;
  end;
  SpellFromCatalog.dice := d.castDice;
  SpellFromCatalog.sides := d.castSides;
  SpellFromCatalog.element := SpellElement(d.dtype);
  SpellFromCatalog.inflict := d.castInflict;
  SpellFromCatalog.school := d.school;
  SpellFromCatalog.icon := d.icon;
end;

function SpellCount: longint;
begin
  EnsureList(Active^.CurActor);
  SpellCount := Length(gList);
end;

function SpellInfo(i: longint): TSpell;
begin
  EnsureList(Active^.CurActor);
  if (i < 0) or (i >= Length(gList)) then begin
    FillChar(SpellInfo, SizeOf(SpellInfo), 0);
    exit;
  end;
  SpellInfo := SpellFromCatalog(gList[i]);
end;

function ActorCanCast(actor, spellIdx: longint): boolean;
begin
  ActorCanCast := false;
  if (actor < 0) or (actor > High(Active^.Party^)) then exit;
  EnsureList(actor);
  if (spellIdx < 0) or (spellIdx >= Length(gList)) then exit;
  if not (Active^.Party^[actor].alive and (not Active^.Party^[actor].downed)) then exit;
  ActorCanCast := Active^.Party^[actor].sp >= SpellDefs[gList[spellIdx]].castCost;
end;

{ The spell ability modifier: the caster's class prime ability. }
function CasterMod(actor: longint): longint;
begin
  CasterMod := AbilMod(Active^.Party^[actor].abil[
    TAbility(ClassDefs[Active^.Party^[actor].klass].prime)]);
end;

{ ---- party attack resolution ---- }

procedure ResolvePartyAttack(actor, foe: longint;
  hitMod: longint = 0; dmgMod: longint = 0; inflict: longint = 0);
var
  melee, hit: boolean;
  roll, roll2, atk, dmg, die: longint;
begin
  melee := not WeaponRanged(Active^.Party^[actor]);
  if melee and (Active^.Party^[actor].rank <> RANK_FRONT) then begin
    CombatLog(Active^.Party^[actor].name + ' has no reach from the back rank.');
    exit;
  end;
  if melee and (Active^.Foes[foe].rank <> FrontFoeRank) then begin
    CombatLog(Active^.Party^[actor].name + ' cannot reach the back rank.');
    exit;
  end;
  die := CharWeaponDie(Active^.Party^[actor]);
  roll := D(20);
  if Active^.PartyStatus[actor].offbal > 0 then begin
    roll2 := D(20);                       { off balance: roll at disadvantage }
    if roll2 < roll then roll := roll2;
  end;
  atk := CharAttack(Active^.Party^[actor], melee) + Active^.PartyBless - Active^.PartyDark + hitMod;
  if Active^.PartyStatus[actor].fear > 0 then dec(atk, FEAR_ATK);   { afraid: shaky aim }
  if CharEncumbered(Active^.Party^[actor]) then dec(atk, ENCUMBER_ATK);  { overladen }
  if OptCriticals then
    hit := (roll <> 1) and ((roll = 20) or (roll + atk >= MonDefs[Active^.Foes[foe].def].ac))
  else
    hit := roll + atk >= MonDefs[Active^.Foes[foe].def].ac;   { plain roll, no 20/1 }
  if hit then
  begin
    if OptCriticals and (roll = 20) then dmg := die   { a crit for max damage }
    else dmg := D(die);
    if melee then dmg := dmg + AbilMod(Active^.Party^[actor].abil[abSTR]);
    dmg := dmg + dmgMod;
    if dmg < 1 then dmg := 1;
    CombatLog(Active^.Party^[actor].name + ' hits ' + MonDefs[Active^.Foes[foe].def].name + '.');
    DamageFoe(foe, dmg, WeaponElement(Active^.Party^[actor]));
    if Active^.Foes[foe].alive and (inflict <> 0) then AfflictFoe(foe, inflict, 3);
  end else begin
    CombatLog(Active^.Party^[actor].name + ' misses.');
    PushPop(0, foe, POPC_MISS, 'MISS');
  end;
end;

{ ---- combat maneuvers: the actor's combat-arena skills, rebuilt on demand ---- }

var
  gKActor: longint = -1;    { whose menu gKList currently holds }
  gKList: array of longint; { catalog indices of that actor's combat skills }

function CharHasShield(const c: TCharacter): boolean;
begin
  CharHasShield := (c.equip[eqOff].def >= 0)
    and (ItemDefs[c.equip[eqOff].def].kind = IK_SHIELD);
end;

procedure BuildSkillMenu(actor: longint);
var i, cat: longint;
begin
  gKActor := actor;
  SetLength(gKList, 0);
  if (actor < 0) or (actor > High(Active^.Party^)) then exit;
  for i := 0 to KnownSkillCount(Active^.Party^[actor]) - 1 do begin
    cat := KnownSkillNth(Active^.Party^[actor], i);
    if (cat >= 0) and (SkillDefs[cat].arena = SKA_COMBAT) then begin
      SetLength(gKList, Length(gKList) + 1);
      gKList[High(gKList)] := cat;
    end;
  end;
end;

procedure EnsureSkillMenu(actor: longint);
begin
  if gKActor <> actor then BuildSkillMenu(actor);
end;

procedure ResetSkillMenu;
begin
  gKActor := -1;
end;

function CombatSkillCount: longint;
begin
  EnsureSkillMenu(Active^.CurActor);
  CombatSkillCount := Length(gKList);
end;

function CombatSkillCat(i: longint): longint;
begin
  EnsureSkillMenu(Active^.CurActor);
  if (i < 0) or (i >= Length(gKList)) then CombatSkillCat := -1
  else CombatSkillCat := gKList[i];
end;

function CombatSkillInfo(i: longint): TSkillDef;
var cat: longint;
begin
  cat := CombatSkillCat(i);
  { the UI never asks out of range; fall back to the first entry if it does }
  if cat < 0 then cat := 0;
  if SkillDefCount > 0 then CombatSkillInfo := SkillDefs[cat];
end;

function CombatSkillUsesLeft(actor, i: longint): longint;
var cat: longint;
begin
  CombatSkillUsesLeft := -1;
  cat := CombatSkillCat(i);
  if cat < 0 then exit;
  if SkillDefs[cat].maxUses = 0 then exit;   { at will }
  CombatSkillUsesLeft := SkillDefs[cat].maxUses;
  if (actor >= 0) and (actor <= High(Active^.SkillUse))
     and (cat <= High(Active^.SkillUse[actor])) then
    CombatSkillUsesLeft := SkillDefs[cat].maxUses - Active^.SkillUse[actor][cat];
  if CombatSkillUsesLeft < 0 then CombatSkillUsesLeft := 0;
end;

function ActorCanManeuver(actor, i: longint): boolean;
var cat: longint;
begin
  ActorCanManeuver := false;
  if (actor < 0) or (actor > High(Active^.Party^)) then exit;
  if not (Active^.Party^[actor].alive and (not Active^.Party^[actor].downed)) then exit;
  cat := CombatSkillCat(i);
  if cat < 0 then exit;
  { a maneuver may demand gear: a shield to bash, a ranged weapon to aim }
  case SkillDefs[cat].effect of
    SKE_BASH:      if not CharHasShield(Active^.Party^[actor]) then exit;
    SKE_AIMEDSHOT: if not WeaponRanged(Active^.Party^[actor]) then exit;
  end;
  if (SkillDefs[cat].maxUses > 0) and (CombatSkillUsesLeft(actor, i) <= 0) then exit;
  ActorCanManeuver := true;
end;

procedure SpendManeuver(actor, i: longint);
var cat: longint;
begin
  cat := CombatSkillCat(i);
  if cat < 0 then exit;
  if SkillDefs[cat].maxUses = 0 then exit;   { at will, nothing to track }
  if (actor >= 0) and (actor <= High(Active^.SkillUse))
     and (cat <= High(Active^.SkillUse[actor])) then
    inc(Active^.SkillUse[actor][cat]);
end;

end.
