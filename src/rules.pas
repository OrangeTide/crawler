unit rules;

{** AX&X rules math: abilities, classes, and the core dice resolution.

  The numbers follow the AX&X v0.3 core rules, which are public domain
  (CC0). This unit is pure: it knows nothing about the party record or
  the world, so combat, creation and the UI can all share it. }

{$mode objfpc}{$H+}

interface

uses
  rng;

type
  TAbility = (abSTR, abDEX, abCON, abINT, abWIS, abCHA);
  TTrack = (trWarrior, trPriest, trSpecialist, trMage);
  TSaveKind = (svBody, svDodge, svWill);

  TAbilityScores = array[TAbility] of byte;

const
  ABIL_NAME: array[TAbility] of string[3] =
    ('STR', 'DEX', 'CON', 'INT', 'WIS', 'CHA');

function AbilMod(score: longint): longint;
function AttackBonus(track: TTrack; level: longint): longint;
function MaxHPDie(hitDie, conScore, level: longint): longint;
function XPForNext(track: TTrack; curLevel: longint): longint;

function Check(var r: TRng; abilMods, target: longint): boolean;
function SaveThrow(var r: TRng; abilMods, level, target: longint): boolean;
function RollAbility(var r: TRng): longint;

implementation

function AbilMod(score: longint): longint;
begin
  case score of
    0 .. 3:   AbilMod := -3;
    4 .. 5:   AbilMod := -2;
    6 .. 8:   AbilMod := -1;
    9 .. 12:  AbilMod := 0;
    13 .. 15: AbilMod := 1;
    16 .. 17: AbilMod := 2;
  else
    AbilMod := 3;
  end;
end;

function AttackBonus(track: TTrack; level: longint): longint;
begin
  case track of
    trWarrior:    AttackBonus := level;
    trPriest:     AttackBonus := (level + 1) div 2;   { ceil(level/2) }
    trSpecialist: AttackBonus := (level + 1) div 2;
  else
    AttackBonus := level div 2;                        { mage: floor(level/2) }
  end;
end;

function MaxHPDie(hitDie, conScore, level: longint): longint;
var
  hp, conM, i: longint;
begin
  conM := AbilMod(conScore);
  { Level 1 is the max of one hit die plus CON. }
  hp := hitDie + conM;
  if hp < 1 then hp := 1;
  { Later levels add a rolled die plus CON; for creation we approximate
    with the average so a fresh party is not swingy. }
  for i := 2 to level do
    hp := hp + (hitDie div 2 + 1) + conM;
  if hp < level then hp := level;
  MaxHPDie := hp;
end;

function XPForNext(track: TTrack; curLevel: longint): longint;
{** Total XP needed to reach curLevel+1. Level 2 costs the track base;
  each later level doubles the previous requirement (AX&X). }
var
  base, xp, i: longint;
begin
  case track of
    trSpecialist: base := 1500;
    trWarrior, trPriest: base := 2000;
  else
    base := 2500;
  end;
  xp := base;
  for i := 2 to curLevel do
    xp := xp * 2;
  XPForNext := xp;
end;

function Check(var r: TRng; abilMods, target: longint): boolean;
begin
  Check := (RngRange(r, 1, 20) + abilMods) >= target;
end;

function SaveThrow(var r: TRng; abilMods, level, target: longint): boolean;
begin
  SaveThrow := (RngRange(r, 1, 20) + (level div 2) + abilMods) >= target;
end;

function RollAbility(var r: TRng): longint;
begin
  RollAbility := RngRoll(r, 3, 6);   { 3d6 in order }
end;

end.
