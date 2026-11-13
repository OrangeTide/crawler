program t_size;

{** Rank capacity by creature size. A size class carries a bulk weight, and a
  combat rank's cover is its summed bulk: the front rank must hold at least as
  much bulk as the back. These checks cover the weights, the baked monster
  sizes, the encounter layout invariant, and the party fall-back gate. }

{$mode objfpc}{$H+}

uses
  sysutils, pak, rng, rules, items, chardata, monsters, party,
  combatstate, combatcore, combat, testing;

var
  p: TPak;

{ Summed bulk of the foes in a rank of the current encounter. }
function FoeBulk(backRank: boolean): longint;
var i, total: longint;
begin
  total := 0;
  for i := 0 to High(Active^.Foes) do
    if Active^.Foes[i].alive
      and ((Active^.Foes[i].rank = RANK_BACK) = backRank) then
      total := total + SizeBulk(MonDefs[Active^.Foes[i].def].size);
  FoeBulk := total;
end;

{ The size of a monster by id. }
function MonSize(const id: string): longint;
var idx: longint;
begin
  idx := MonIndex(id);
  if idx < 0 then MonSize := -1 else MonSize := MonDefs[idx].size;
end;

var
  i, ab: longint;
  a: TAbility;
  scores: TAbilityScores;
  frontOk: boolean;
  c: TCharacter;

begin
  if not PakLoad('build/game.pak', p) then begin
    writeln('  FAIL could not load build/game.pak (run make first)');
    halt(2);
  end;
  Check(LoadItems(p), 'load items');
  Check(LoadCharData(p), 'load character data');
  Check(LoadMonsters(p), 'load monsters');

  { the bulk weights, in quarter-units of a medium body }
  CheckEqI(SizeBulk(SZ_TINY), 1, 'tiny weighs 1');
  CheckEqI(SizeBulk(SZ_SMALL), 2, 'small weighs 2');
  CheckEqI(SizeBulk(SZ_MEDIUM), 4, 'medium weighs 4');
  CheckEqI(SizeBulk(SZ_LARGE), 8, 'large weighs 8');
  CheckEqI(SizeBulk(SZ_HUGE), 12, 'huge weighs 12');
  CheckEqI(SizeBulk(SZ_COLOSSAL), 16, 'colossal weighs 16');
  { eight tiny shelter behind one large: equal bulk }
  CheckEqI(8 * SizeBulk(SZ_TINY), SizeBulk(SZ_LARGE), 'eight tiny == one large');

  { baked monster sizes from the table and the medium default }
  CheckEqI(MonSize('BAT'), SZ_TINY, 'a cave bat is tiny');
  CheckEqI(MonSize('RAT'), SZ_SMALL, 'a giant rat is small');
  CheckEqI(MonSize('SKELETON'), SZ_MEDIUM, 'a skeleton is medium (default)');
  CheckEqI(MonSize('SPIDER'), SZ_LARGE, 'a giant spider is large');
  CheckEqI(MonSize('DEMON'), SZ_HUGE, 'a demon lord is huge');

  { the encounter builder leaves the front carrying at least the back's bulk }
  RngSeed(GameRng, 12345);
  frontOk := true;
  for i := 0 to 199 do begin
    StartRandomEncounter(1 + (i mod 10), -1);
    if FoeBulk(false) < FoeBulk(true) then frontOk := false;
    if FoeBulk(false) = 0 then frontOk := false;   { someone must be reachable }
  end;
  Check(frontOk, 'every built encounter keeps front bulk >= back bulk');

  { the party fall-back gate. Build four medium members up front. }
  for a := abSTR to abCHA do scores[a] := 12;
  NewParty;
  for i := 0 to 3 do begin
    MakeCharacter(c, 'M' + IntToStr(i), SpeciesIndex('HUMAN'),
      ClassIndex('FIGHTER'), 0, scores);
    c.rank := RANK_FRONT;
    AddPartyMember(c);
  end;

  { all four in front: one may fall back (3 front >= 1 back) }
  Check(CanFallBack(0), 'with four in front, one can fall back');

  { one front, three back: the lone front body cannot fall back }
  Roster[0].rank := RANK_FRONT;
  for i := 1 to 3 do Roster[i].rank := RANK_BACK;
  Check(not CanFallBack(0), 'the last front body cannot leave the rear bare');

  { a back-rank member never "falls back" further }
  Check(not CanFallBack(1), 'a back-rank member cannot fall back');

  { a large body up front is the cover a small one can duck behind }
  Roster[0].rank := RANK_FRONT; Roster[0].size := SZ_LARGE;   { bulk 8 }
  Roster[1].rank := RANK_FRONT; Roster[1].size := SZ_MEDIUM;  { bulk 4 }
  Roster[2].rank := RANK_BACK;  Roster[2].size := SZ_MEDIUM;
  Roster[3].rank := RANK_BACK;  Roster[3].size := SZ_SMALL;
  { front = 12, back = 6. The medium (4) may fall back: 8 >= 10? no }
  Check(not CanFallBack(1), 'the medium cannot fall back past the cover it adds');
  { the large (8) cannot fall back: 4 >= 14? no }
  Check(not CanFallBack(0), 'the large cover body cannot abandon the front');

  TestSummary('size');
  halt(TestExit);
end.
