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
  TKindred = (kHuman, kDwarf, kElf, kHalfling, kHalfOrc);
  TCharClass = (ccFighter, ccBarbarian, ccRanger, ccCleric, ccThief, ccMagicUser);
  TTrack = (trWarrior, trPriest, trSpecialist, trMage);
  TSaveKind = (svBody, svDodge, svWill);

  TAbilityScores = array[TAbility] of byte;

const
  ABIL_NAME: array[TAbility] of string[3] =
    ('STR', 'DEX', 'CON', 'INT', 'WIS', 'CHA');

  KINDRED_NAME: array[TKindred] of string[9] =
    ('HUMAN', 'DWARF', 'ELF', 'HALFLING', 'HALF-ORC');

  CLASS_NAME: array[TCharClass] of string[10] =
    ('FIGHTER', 'BARBARIAN', 'RANGER', 'CLERIC', 'THIEF', 'MAGIC-USER');

  CLASS_TRACK: array[TCharClass] of TTrack =
    (trWarrior, trWarrior, trWarrior, trPriest, trSpecialist, trMage);

  CLASS_HITDIE: array[TCharClass] of byte =
    (8, 10, 8, 6, 6, 4);

function AbilMod(score: longint): longint;
function AttackBonus(track: TTrack; level: longint): longint;
function MaxHP(cls: TCharClass; conScore, level: longint): longint;

function Check(var r: TRng; abilMods, target: longint): boolean;
function SaveThrow(var r: TRng; abilMods, level, target: longint): boolean;
function RollAbility(var r: TRng): longint;

implementation

function AbilMod(score: longint): longint;
begin
  if score <= 3 then AbilMod := -3
  else if score <= 5 then AbilMod := -2
  else if score <= 8 then AbilMod := -1
  else if score <= 12 then AbilMod := 0
  else if score <= 15 then AbilMod := 1
  else if score <= 17 then AbilMod := 2
  else AbilMod := 3;
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

function MaxHP(cls: TCharClass; conScore, level: longint): longint;
var
  hp, conM, i: longint;
begin
  conM := AbilMod(conScore);
  { Level 1 is the max of one hit die plus CON. }
  hp := CLASS_HITDIE[cls] + conM;
  if hp < 1 then hp := 1;
  { Later levels add a rolled die plus CON; for creation we approximate
    with the average so a fresh party is not swingy. }
  for i := 2 to level do
    hp := hp + (CLASS_HITDIE[cls] div 2 + 1) + conM;
  if hp < level then hp := level;
  MaxHP := hp;
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
