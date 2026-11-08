unit skillbook;

{** Skill rules: who may learn a skill, spending proficiency slots to learn or
  rank it up, and the modifier a trained skill brings to its d20 check.

  A character banks skill slots (generous for the thief kit, lean otherwise,
  see party.CharSkillSlots) and spends them here. A skill is gated by class:
  thief skills need the thief kit, martial maneuvers the warrior or specialist
  tracks, and general skills are open to all. Spending a slot on a skill already
  known raises its rank, up to SKILL_MAXRANK. }

{$mode objfpc}{$H+}

interface

uses
  party, skilldb;

{ The rank of a trained skill by catalog index, or -1 if untrained. }
function SkillRank(const c: TCharacter; skillIdx: longint): longint;
{ Whether the character's class may train this skill at all. }
function SkillGateOK(const c: TCharacter; gate: byte): boolean;
{ Whether a slot spent now would train or improve this skill (gate allows it and
  it is not already at the rank cap). Does not check that a slot is in hand. }
function SkillLearnable(const c: TCharacter; skillIdx: longint): boolean;
{ Spend one slot to learn the skill or raise its rank. False if no slot is in
  hand or the skill is not learnable. }
function LearnSkill(var c: TCharacter; skillIdx: longint): boolean;
{ The modifier added to a d20 skill check: ability + level/2 + 2*rank. }
function SkillCheckMods(const c: TCharacter; skillIdx: longint): longint;

{ Listing for the learn screen: the catalog indices this character may still
  train, in catalog order. }
function LearnableCount(const c: TCharacter): longint;
function LearnableNth(const c: TCharacter; n: longint): longint;
{ Listing for the sheet: the character's trained skills, in catalog order. }
function KnownSkillCount(const c: TCharacter): longint;
function KnownSkillNth(const c: TCharacter; n: longint): longint;

{ The living party member best at a skill of the given effect, with the skill's
  catalog index, or false when no conscious member has one. }
function BestSkillHolder(effect: byte; out who, skillIdx: longint): boolean;
{ Roll the party's best holder of this skill effect against the skill's
  difficulty. memberIdx returns that holder, or -1 when the party has none
  (in which case the result is false). }
function PartySkillRoll(effect: byte; out memberIdx: longint): boolean;

implementation

uses
  rules, chardata, rng;

function SkillRank(const c: TCharacter; skillIdx: longint): longint;
var i: longint; id: string;
begin
  SkillRank := -1;
  if (skillIdx < 0) or (skillIdx >= SkillDefCount) then exit;
  id := SkillDefs[skillIdx].id;
  for i := 0 to High(c.skills) do
    if c.skills[i].id = id then begin SkillRank := c.skills[i].rank; exit; end;
end;

function SkillGateOK(const c: TCharacter; gate: byte): boolean;
var track: longint;
begin
  track := ClassDefs[c.klass].track;
  case gate of
    SKG_THIEF:   SkillGateOK := ClassDefs[c.klass].kit = KIT_THIEF;
    SKG_MARTIAL: SkillGateOK := (track = TRK_WARRIOR) or (track = TRK_SPECIALIST);
  else
    SkillGateOK := true;   { SKG_ANY }
  end;
end;

function SkillLearnable(const c: TCharacter; skillIdx: longint): boolean;
begin
  SkillLearnable := false;
  if (skillIdx < 0) or (skillIdx >= SkillDefCount) then exit;
  if not SkillGateOK(c, SkillDefs[skillIdx].gate) then exit;
  SkillLearnable := SkillRank(c, skillIdx) < SKILL_MAXRANK;
end;

function LearnSkill(var c: TCharacter; skillIdx: longint): boolean;
var i: longint; id: string;
begin
  LearnSkill := false;
  if c.skillSlots < 1 then exit;
  if not SkillLearnable(c, skillIdx) then exit;
  id := SkillDefs[skillIdx].id;
  for i := 0 to High(c.skills) do
    if c.skills[i].id = id then begin
      inc(c.skills[i].rank);
      dec(c.skillSlots);
      LearnSkill := true;
      exit;
    end;
  SetLength(c.skills, Length(c.skills) + 1);
  c.skills[High(c.skills)].id := id;
  c.skills[High(c.skills)].rank := 0;
  dec(c.skillSlots);
  LearnSkill := true;
end;

function SkillCheckMods(const c: TCharacter; skillIdx: longint): longint;
var rank: longint;
begin
  SkillCheckMods := 0;
  if (skillIdx < 0) or (skillIdx >= SkillDefCount) then exit;
  rank := SkillRank(c, skillIdx);
  if rank < 0 then rank := 0;
  SkillCheckMods := AbilMod(c.abil[TAbility(SkillDefs[skillIdx].ability)])
    + c.level div 2 + 2 * rank;
end;

function LearnableCount(const c: TCharacter): longint;
var i, n: longint;
begin
  n := 0;
  for i := 0 to SkillDefCount - 1 do
    if SkillLearnable(c, i) then inc(n);
  LearnableCount := n;
end;

function LearnableNth(const c: TCharacter; n: longint): longint;
var i, k: longint;
begin
  LearnableNth := -1;
  k := 0;
  for i := 0 to SkillDefCount - 1 do
    if SkillLearnable(c, i) then begin
      if k = n then begin LearnableNth := i; exit; end;
      inc(k);
    end;
end;

function KnownSkillCount(const c: TCharacter): longint;
begin
  KnownSkillCount := Length(c.skills);
end;

function KnownSkillNth(const c: TCharacter; n: longint): longint;
begin
  KnownSkillNth := -1;
  if (n < 0) or (n > High(c.skills)) then exit;
  KnownSkillNth := SkillByID(c.skills[n].id);
end;

function BestSkillHolder(effect: byte; out who, skillIdx: longint): boolean;
var i, j, cat, mods, best: longint;
begin
  BestSkillHolder := false;
  best := 0;
  for i := 0 to High(Roster) do
    if Roster[i].alive and (not Roster[i].downed) then
      for j := 0 to High(Roster[i].skills) do begin
        cat := SkillByID(Roster[i].skills[j].id);
        if (cat >= 0) and (SkillDefs[cat].effect = effect) then begin
          mods := SkillCheckMods(Roster[i], cat);
          if (not BestSkillHolder) or (mods > best) then begin
            BestSkillHolder := true; best := mods; who := i; skillIdx := cat;
          end;
        end;
      end;
end;

function PartySkillRoll(effect: byte; out memberIdx: longint): boolean;
var who, sk: longint;
begin
  memberIdx := -1;
  PartySkillRoll := false;
  if not BestSkillHolder(effect, who, sk) then exit;
  memberIdx := who;
  PartySkillRoll := Check(GameRng, SkillCheckMods(Roster[who], sk),
    SkillDefs[sk].target);
end;

end.
