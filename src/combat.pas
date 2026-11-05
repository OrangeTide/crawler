unit combat;

{** Turn-based combat on AX&X rules, party versus a monster group.

  Combat uses range bands (engaged, near, far) rather than a battle
  grid, which suits the first-person view. Side initiative is 1d6 per
  side each round. A round runs the party side then the foe side (or the
  reverse when the foes win initiative). The party acts one member at a
  time under player control; the foe side is resolved automatically.

  The game drives this: it reads ActorReady to know whose input is
  wanted, calls an action procedure, and checks CombatOver. }

{$mode objfpc}{$H+}

interface

uses
  sysutils, rng, rules, items, monsters, party;

const
  BAND_ENGAGED = 0;
  BAND_NEAR    = 1;
  BAND_FAR     = 2;

  MAX_FOES = 6;
  LOG_LINES = 5;

type
  TFoe = record
    def: longint;
    hp: smallint;
    hpMax: smallint;
    alive: boolean;
  end;

var
  Foes: array of TFoe;
  Band: longint;
  CombatOver: boolean;
  Victory: boolean;
  Fled: boolean;
  CurActor: longint;         { party member awaiting input, or -1 }
  CurTarget: longint;        { selected foe index }
  Log: array[0 .. LOG_LINES - 1] of string;
  XPGained: longint;
  GoldGained: longint;

procedure StartRandomEncounter(depth: longint);
procedure CombatLog(const s: string);
function LivingFoes: longint;
procedure ActAttack;
procedure ActGuard;
procedure ActAdvance;
procedure ActWithdraw;
procedure ActPotion;
procedure NextTarget;

implementation

var
  enemyActed: boolean;
  bandMoved: boolean;        { foe group spent this round closing }

{ ---- logging ---- }

procedure CombatLog(const s: string);
var
  i: longint;
begin
  for i := 0 to LOG_LINES - 2 do
    Log[i] := Log[i + 1];
  Log[LOG_LINES - 1] := s;
end;

{ ---- helpers ---- }

function LivingFoes: longint;
var
  i, n: longint;
begin
  n := 0;
  for i := 0 to High(Foes) do
    if Foes[i].alive then inc(n);
  LivingFoes := n;
end;

function FirstLivingFoe: longint;
var
  i: longint;
begin
  FirstLivingFoe := -1;
  for i := 0 to High(Foes) do
    if Foes[i].alive then begin FirstLivingFoe := i; exit; end;
end;

function NextLivingActor(from: longint): longint;
var
  i: longint;
begin
  NextLivingActor := -1;
  for i := from to High(Roster) do
    if Roster[i].alive and (not Roster[i].downed) then begin
      NextLivingActor := i;
      exit;
    end;
end;

procedure CheckEnd; forward;
procedure ProcessEnemyPhase; forward;
procedure NewRound; forward;

procedure AdvancePartyActor;
{** Move to the next conscious member, or hand off to the foe side. }
var
  nxt: longint;
begin
  if CombatOver then exit;
  nxt := NextLivingActor(CurActor + 1);
  if nxt >= 0 then begin
    CurActor := nxt;
    Roster[CurActor].guarding := false;   { their guard covered the last round }
    exit;
  end;
  { party side finished }
  if not enemyActed then begin
    ProcessEnemyPhase;
    enemyActed := true;
  end;
  CheckEnd;
  if not CombatOver then
    NewRound;
end;

{ ---- setup ---- }

procedure StartRandomEncounter(depth: longint);
var
  pick, count, i: longint;
begin
  SetLength(Foes, 0);
  CombatOver := false;
  Victory := false;
  Fled := false;
  XPGained := 0;
  GoldGained := 0;
  for i := 0 to LOG_LINES - 1 do Log[i] := '';

  if Length(MonDefs) = 0 then begin
    CombatOver := true; Victory := true; exit;
  end;
  count := 1 + Range(0, 2) + (depth div 3);
  if count > MAX_FOES then count := MAX_FOES;
  SetLength(Foes, count);
  for i := 0 to count - 1 do begin
    pick := Range(0, High(MonDefs));
    Foes[i].def := pick;
    Foes[i].hp := RngRoll(GameRng, MonDefs[pick].hd, 8);
    if Foes[i].hp < 1 then Foes[i].hp := 1;
    Foes[i].hpMax := Foes[i].hp;
    Foes[i].alive := true;
  end;
  Band := BAND_NEAR;
  CombatLog('A hostile band closes in.');

  NewRound;
end;

procedure NewRound;
var
  pInit, fInit: longint;
begin
  enemyActed := false;
  bandMoved := false;
  pInit := D(6);
  fInit := D(6);
  CurTarget := FirstLivingFoe;
  if fInit > pInit then begin
    ProcessEnemyPhase;
    enemyActed := true;
    CheckEnd;
    if CombatOver then exit;
  end;
  CurActor := FirstConscious;
  if CurActor >= 0 then
    Roster[CurActor].guarding := false;
end;

{ ---- resolution ---- }

procedure HurtMember(mi, dmg: longint);
var
  roll: longint;
begin
  Roster[mi].hp := Roster[mi].hp - dmg;
  if Roster[mi].hp <= 0 then begin
    Roster[mi].hp := 0;
    { Brush with Death: 1d6 + prior brushes; 7+ is slain. }
    inc(Roster[mi].brushes);
    roll := D(6) + (Roster[mi].brushes - 1);
    if roll >= 7 then begin
      Roster[mi].alive := false;
      Roster[mi].downed := true;
      CombatLog(Roster[mi].name + ' is slain!');
    end else begin
      Roster[mi].downed := true;
      CombatLog(Roster[mi].name + ' falls, gravely wounded.');
    end;
  end;
end;

procedure KillFoe(fi: longint);
begin
  Foes[fi].alive := false;
  XPGained := XPGained + MonDefs[Foes[fi].def].xp;
  CombatLog(MonDefs[Foes[fi].def].name + ' is destroyed.');
end;

function WeaponRanged(const c: TCharacter): boolean;
begin
  WeaponRanged := (c.equip[eqMain].def >= 0) and
    ((ItemDefs[c.equip[eqMain].def].flags and IF_RANGED) <> 0);
end;

procedure ResolvePartyAttack(actor, foe: longint);
var
  melee: boolean;
  roll, atk, dmg, die: longint;
begin
  melee := not WeaponRanged(Roster[actor]);
  if melee and (Band <> BAND_ENGAGED) then begin
    CombatLog(Roster[actor].name + ' has no reach; advance first.');
    exit;
  end;
  die := CharWeaponDie(Roster[actor]);
  roll := D(20);
  atk := CharAttack(Roster[actor], melee);
  if (roll <> 1) and ((roll = 20) or (roll + atk >= MonDefs[Foes[foe].def].ac)) then
  begin
    if roll = 20 then
      dmg := die
    else
      dmg := D(die);
    if melee then dmg := dmg + AbilMod(Roster[actor].abil[abSTR]);
    if dmg < 1 then dmg := 1;
    Foes[foe].hp := Foes[foe].hp - dmg;
    CombatLog(Roster[actor].name + ' hits ' + MonDefs[Foes[foe].def].name
      + ' for ' + IntToStr(dmg) + '.');
    if Foes[foe].hp <= 0 then
      KillFoe(foe);
  end else
    CombatLog(Roster[actor].name + ' misses.');
end;

procedure MoraleCheck;
var
  i, best: longint;
begin
  best := 0;
  for i := 0 to High(Foes) do
    if Foes[i].alive and (MonDefs[Foes[i].def].morale > best) then
      best := MonDefs[Foes[i].def].morale;
  if D(6) > best then begin
    CombatLog('The enemy breaks and flees!');
    for i := 0 to High(Foes) do Foes[i].alive := false;
  end;
end;

procedure ProcessEnemyPhase;
var
  i, tgt, roll, dmg, effAC: longint;
  total: longint;
begin
  if LivingFoes = 0 then exit;

  { If not engaged, the group closes one band instead of attacking. }
  if Band <> BAND_ENGAGED then begin
    dec(Band);
    bandMoved := true;
    CombatLog('The enemy advances.');
    exit;
  end;

  total := Length(Foes);
  for i := 0 to High(Foes) do begin
    if not Foes[i].alive then continue;
    tgt := FirstConscious;
    if tgt < 0 then break;
    { pick a random conscious member }
    repeat
      tgt := Range(0, High(Roster));
    until Roster[tgt].alive and (not Roster[tgt].downed) and (Roster[tgt].hp > 0);
    roll := D(20);
    effAC := CharAC(Roster[tgt]);
    if Roster[tgt].guarding then effAC := effAC + 2;   { parry }
    if (roll <> 1) and ((roll = 20) or
       (roll + MonDefs[Foes[i].def].atkBonus >= effAC)) then
    begin
      dmg := D(MonDefs[Foes[i].def].dmgSides);
      if dmg < 1 then dmg := 1;
      CombatLog(MonDefs[Foes[i].def].name + ' hits ' + Roster[tgt].name
        + ' for ' + IntToStr(dmg) + '.');
      HurtMember(tgt, dmg);
    end else
      CombatLog(MonDefs[Foes[i].def].name + ' misses ' + Roster[tgt].name + '.');
    if FirstConscious < 0 then break;
  end;

  { morale once the group is bloodied }
  if (LivingFoes > 0) and (LivingFoes <= total div 2) then
    MoraleCheck;
end;

procedure CheckEnd;
begin
  if LivingFoes = 0 then begin
    CombatOver := true;
    Victory := true;
    GoldGained := Range(0, 10) * Length(Foes) + Range(0, 20);
    PartyGold := PartyGold + GoldGained;
    CombatLog('Victory. ' + IntToStr(XPGained) + ' XP, '
      + IntToStr(GoldGained) + ' gold.');
    exit;
  end;
  if not PartyConscious then begin
    CombatOver := true;
    Victory := false;
    CombatLog('The party falls.');
  end;
end;

{ ---- player actions ---- }

procedure ActAttack;
begin
  if CombatOver or (CurActor < 0) then exit;
  if (CurTarget < 0) or (CurTarget > High(Foes)) or (not Foes[CurTarget].alive) then
    CurTarget := FirstLivingFoe;
  if CurTarget < 0 then exit;
  ResolvePartyAttack(CurActor, CurTarget);
  if not Foes[CurTarget].alive then CurTarget := FirstLivingFoe;
  CheckEnd;
  AdvancePartyActor;
end;

procedure ActGuard;
begin
  if CombatOver or (CurActor < 0) then exit;
  Roster[CurActor].guarding := true;
  CombatLog(Roster[CurActor].name + ' takes a guarded stance.');
  AdvancePartyActor;
end;

procedure ActAdvance;
begin
  if CombatOver or (CurActor < 0) then exit;
  if Band > BAND_ENGAGED then begin
    dec(Band);
    CombatLog(Roster[CurActor].name + ' leads the advance.');
  end else
    CombatLog('Already engaged.');
  AdvancePartyActor;
end;

procedure ActWithdraw;
begin
  if CombatOver or (CurActor < 0) then exit;
  if Band < BAND_FAR then begin
    inc(Band);
    CombatLog(Roster[CurActor].name + ' pulls the party back.');
    AdvancePartyActor;
  end else begin
    { already far: a full withdraw ends the fight }
    CombatOver := true;
    Victory := false;
    Fled := true;
    CombatLog('The party withdraws from the fight.');
  end;
end;

procedure ActPotion;
var
  i, heal: longint;
  pidx: longint;
begin
  if CombatOver or (CurActor < 0) then exit;
  pidx := ItemIndex('POTION');
  for i := 0 to High(Roster[CurActor].pack) do
    if (Roster[CurActor].pack[i].def = pidx) and (Roster[CurActor].pack[i].qty > 0) then
    begin
      dec(Roster[CurActor].pack[i].qty);
      heal := RngRoll(GameRng, 1, 8) + 2;
      Roster[CurActor].hp := Roster[CurActor].hp + heal;
      if Roster[CurActor].hp > Roster[CurActor].hpMax then
        Roster[CurActor].hp := Roster[CurActor].hpMax;
      CombatLog(Roster[CurActor].name + ' drinks a potion (+'
        + IntToStr(heal) + ').');
      AdvancePartyActor;
      exit;
    end;
  CombatLog('No potion to drink.');
end;

procedure NextTarget;
var
  start, i: longint;
begin
  if LivingFoes = 0 then exit;
  start := CurTarget;
  i := start;
  repeat
    i := (i + 1) mod Length(Foes);
    if Foes[i].alive then begin CurTarget := i; exit; end;
  until i = start;
end;

end.
