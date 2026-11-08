program t_skills;

{** The skill catalog, proficiency-slot acquisition, and the skill check. }

{$mode objfpc}{$H+}

uses
  sysutils, pak, rng, rules, items, chardata, monsters, party, skilldb,
  skillbook, combatstate, combatcore, testing;

var
  p: TPak;
  ab: TAbilityScores;
  a: TAbility;
  thief, fighter, wizard: TCharacter;
  lock, power, mend, before, i, who, dis, mPow, mDis: longint;

{ The current actor's combat-menu index for the first skill of an effect. }
function MenuIdxOf(effect: byte): longint;
var k: longint;
begin
  MenuIdxOf := -1;
  for k := 0 to CombatSkillCount - 1 do
    if CombatSkillInfo(k).effect = effect then begin MenuIdxOf := k; exit; end;
end;

function Idx(const id: string): longint;
begin
  Idx := SkillByID(id);
end;

begin
  RngSeed(GameRng, 99);
  if not PakLoad('build/game.pak', p) then begin
    writeln('  FAIL could not load build/game.pak (run make first)');
    halt(2);
  end;
  Check(LoadItems(p), 'load items');
  Check(LoadCharData(p), 'load class data');
  Check(LoadSkills(p), 'load skills');

  { ---- the catalog round-trips ---- }
  Check(SkillDefCount = 9, 'the catalog holds nine skills');
  lock := Idx('SK_PICKLOCK');
  power := Idx('SK_POWERATTACK');
  mend := Idx('SK_MEND');
  Check(lock >= 0, 'Pick Locks is in the catalog');
  Check(SkillDefs[lock].arena = SKA_EXPLORE, 'Pick Locks is an exploration skill');
  Check(SkillDefs[lock].effect = SKE_PICKLOCK, 'Pick Locks keys the pick-lock effect');
  Check(SkillDefs[lock].gate = SKG_THIEF, 'Pick Locks is thief-gated');
  Check(SkillDefs[lock].icon = 60, 'Pick Locks keeps its icon');
  Check(SkillDefs[power].arena = SKA_COMBAT, 'Power Attack is a combat skill');
  Check(SkillDefs[Idx('SK_DISARM')].maxUses = 2, 'Disarm is twice per fight');
  Check(SkillDefs[power].maxUses = 0, 'Power Attack is at-will');
  Check(SkillDefs[mend].dice = 1, 'First Aid rolls a die of healing');

  { ---- slot grants ---- }
  for a := abSTR to abCHA do ab[a] := 12;
  MakeCharacter(thief, 'Fingers', SpeciesIndex('HUMAN'), ClassIndex('THIEF'), -1, ab);
  MakeCharacter(fighter, 'Bran', SpeciesIndex('HUMAN'), ClassIndex('FIGHTER'), -1, ab);
  MakeCharacter(wizard, 'Wren', SpeciesIndex('HUMAN'), ClassIndex('WIZARD'), -1, ab);
  Check(thief.skillSlots = 3, 'a level-1 thief banks three slots');
  Check(fighter.skillSlots = 1, 'a level-1 fighter banks one slot');
  Check(CharSkillSlots(thief, 5) = 7, 'the thief has seven slots by level 5');
  Check(CharSkillSlots(fighter, 7) = 3, 'the fighter has three by level 7');

  { ---- gates ---- }
  Check(SkillLearnable(thief, lock), 'a thief may train Pick Locks');
  Check(not SkillLearnable(fighter, lock), 'a fighter may not train Pick Locks');
  Check(SkillLearnable(fighter, power), 'a fighter may train Power Attack');
  Check(not SkillLearnable(wizard, power), 'a wizard may not train Power Attack');
  Check(SkillLearnable(thief, mend), 'anyone may train First Aid');
  Check(SkillLearnable(wizard, mend), 'a wizard may train First Aid too');

  { ---- learning and ranking up ---- }
  before := thief.skillSlots;
  Check(LearnSkill(thief, lock), 'the thief learns Pick Locks');
  Check(thief.skillSlots = before - 1, 'learning spends a slot');
  Check(SkillRank(thief, lock) = 0, 'a freshly learned skill is rank 0');
  Check(LearnSkill(thief, lock), 'training again ranks it up');
  Check(SkillRank(thief, lock) = 1, 'the rank is now 1');
  Check(KnownSkillCount(thief) = 1, 'ranking up does not add a second entry');

  { a wizard with no slots cannot learn }
  wizard.skillSlots := 0;
  Check(not LearnSkill(wizard, mend), 'no slot, no training');

  { the rank cap stops training }
  fighter.skillSlots := 20;
  for i := 0 to SKILL_MAXRANK do LearnSkill(fighter, power);
  Check(SkillRank(fighter, power) = SKILL_MAXRANK, 'rank stops at the cap');
  Check(not SkillLearnable(fighter, power), 'a capped skill is no longer learnable');

  { ---- the check modifier rises with level and rank ---- }
  Check(SkillCheckMods(thief, lock) > SkillCheckMods(wizard, lock),
    'a trained thief checks better than an untrained wizard');
  before := SkillCheckMods(thief, lock);
  thief.level := 6;
  Check(SkillCheckMods(thief, lock) > before, 'level raises the check');

  { ---- party-wide resolution ---- }
  for a := abSTR to abCHA do ab[a] := 12;
  ab[abDEX] := 18;
  SetLength(Roster, 2);
  MakeCharacter(Roster[0], 'Sly', SpeciesIndex('HUMAN'), ClassIndex('THIEF'), -1, ab);
  MakeCharacter(Roster[1], 'Ox', SpeciesIndex('HUMAN'), ClassIndex('FIGHTER'), -1, ab);
  Roster[0].level := 10;
  Roster[0].skillSlots := 10;
  LearnSkill(Roster[0], lock);
  LearnSkill(Roster[0], lock);
  LearnSkill(Roster[0], lock);   { a high-DEX, high-level, ranked lockpick }

  Check(BestSkillHolder(SKE_PICKLOCK, i, before) and (i = 0),
    'the thief is the party lockpick');
  Check(not BestSkillHolder(SKE_FINDTRAPS, i, before),
    'no one in the party finds traps');
  Check(PartySkillRoll(SKE_PICKLOCK, who) and (who = 0),
    'the ranked lockpick never fails this easy lock');
  Check((not PartySkillRoll(SKE_FINDTRAPS, who)) and (who = -1),
    'a skill no one knows cannot be rolled');

  { ---- combat maneuvers: the menu and per-fight use limits ---- }
  power := Idx('SK_POWERATTACK');
  dis := Idx('SK_DISARM');
  Roster[1].skillSlots := 10;
  LearnSkill(Roster[1], power);   { at-will }
  LearnSkill(Roster[1], dis);     { twice per fight }

  CurActor := 1;
  ResetSkillMenu;
  SetLength(SkillUse, Length(Roster));
  for i := 0 to High(SkillUse) do SetLength(SkillUse[i], SkillDefCount);

  Check(CombatSkillCount = 2, 'the fighter has two combat maneuvers');
  mPow := MenuIdxOf(SKE_POWERATTACK);
  mDis := MenuIdxOf(SKE_DISARM);
  Check((mPow >= 0) and (mDis >= 0), 'both maneuvers are on the menu');
  Check(CombatSkillUsesLeft(1, mPow) = -1, 'power attack is at will');
  Check(CombatSkillUsesLeft(1, mDis) = 2, 'disarm starts with two uses');
  Check(ActorCanManeuver(1, mDis), 'disarm is ready at the start of a fight');

  SpendManeuver(1, mDis);
  Check(CombatSkillUsesLeft(1, mDis) = 1, 'a use spends one of disarm');
  SpendManeuver(1, mDis);
  Check(CombatSkillUsesLeft(1, mDis) = 0, 'disarm is spent after two uses');
  Check(not ActorCanManeuver(1, mDis), 'a spent maneuver is refused');
  Check(ActorCanManeuver(1, mPow), 'the at-will maneuver is never spent');

  TestSummary('skills');
  halt(TestExit);
end.
