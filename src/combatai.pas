unit combatai;

{** The foe side's AI: how a monster chooses to move, harry, cast, or hold.

  Each routine acts for one foe, identified by its index, and reports whether
  it spent the turn. The driver's ResolveEnemyTurn picks among them by the
  monster's role. These build on combatcore (resolution, tactics, feedback)
  and never touch the turn order, so the layering stays acyclic. }

{$mode objfpc}{$H+}

interface

uses
  sysutils, rng, party, monsters, combatstate, combatcore;

{ Pick a target for foe fi by role: ranged foes reach the soft back rank,
  melee foes the party front, pressing the most wounded in reach. -1 if none. }
function EnemyPickTarget(fi: longint; ranged: boolean): longint;
{ The foe AI's reposition choice: may flip foe fi's rank (melee closes to the
  front, a ranged caster with cover falls back) and report the turn as spent. }
function EnemyMaybeMove(fi: longint; ranged: boolean): boolean;
{ The foe AI's ranged disruption: a taunt or a thrown weapon. Spends the turn. }
function EnemyHarry(fi: longint): boolean;
{ Foe spellcasting: a mage's bolt at the party, a healer's mend on an ally. }
function EnemyCastBolt(fi: longint): boolean;
function EnemyCastHeal(fi: longint): boolean;
function EnemyCastRevive(fi: longint): boolean;

implementation

const
  FOE_CAST_SP = 2;     { spell points a foe spends per spell }
  FOE_REVIVE_SP = 3;   { spell points to raise a fallen ally }

{ The most wounded member of a pool of party indices, random among ties. }
function MostWounded(const pool: array of longint; n: longint): longint;
var i, best: longint;
begin
  best := -1;
  for i := 0 to n - 1 do
    if (best < 0) or (Active^.Party^[pool[i]].hp < Active^.Party^[best].hp) then
      best := pool[i];
  MostWounded := best;
end;

{ Pick a target for foe fi. Ranged foes reach past the front line and go
  for the soft back rank; melee foes are held to the party front rank.
  Within the allowed set they press the most wounded. }
function EnemyPickTarget(fi: longint; ranged: boolean): longint;
var
  pool: array[0 .. 31] of longint;
  n, i, fr: longint;
begin
  EnemyPickTarget := -1;
  n := 0;
  if ranged then begin
    { prefer the back rank; fall back to anyone conscious }
    for i := 0 to High(Active^.Party^) do
      if Active^.Party^[i].alive and (not Active^.Party^[i].downed)
        and (Active^.Party^[i].rank = RANK_BACK) and (n <= High(pool)) then begin
        pool[n] := i; inc(n);
      end;
    if n = 0 then
      for i := 0 to High(Active^.Party^) do
        if Active^.Party^[i].alive and (not Active^.Party^[i].downed) and (n <= High(pool)) then begin
          pool[n] := i; inc(n);
        end;
  end else begin
    fr := FrontPartyRank;
    for i := 0 to High(Active^.Party^) do
      if Active^.Party^[i].alive and (not Active^.Party^[i].downed)
        and (Active^.Party^[i].rank = fr) and (n <= High(pool)) then begin
        pool[n] := i; inc(n);
      end;
  end;
  if n > 0 then EnemyPickTarget := MostWounded(pool, n);
end;

{ Is another living foe holding the front rank, so this one has cover? }
function FoeHasCover(exclude: longint): boolean;
var
  i: longint;
begin
  FoeHasCover := false;
  for i := 0 to High(Active^.Foes) do
    if (i <> exclude) and Active^.Foes[i].alive and (Active^.Foes[i].rank = RANK_FRONT) then
    begin
      FoeHasCover := true; exit;
    end;
end;

{ A foe may spend its turn repositioning. Melee brutes penned in the back
  surge forward to close the distance; ranged casters caught in the front
  line slip back behind the brutes when there is a front line to hide them.
  Returns true if the turn was spent moving. }
function EnemyMaybeMove(fi: longint; ranged: boolean): boolean;
begin
  EnemyMaybeMove := false;
  if ranged then begin
    if (Active^.Foes[fi].rank = RANK_FRONT) and FoeHasCover(fi) and (D(100) <= 70) then
    begin
      Active^.Foes[fi].rank := RANK_BACK;
      CombatLog(MonDefs[Active^.Foes[fi].def].name + ' slips to the back.');
      EnemyMaybeMove := true;
    end;
  end else begin
    if (Active^.Foes[fi].rank <> FrontFoeRank) and (D(100) <= 75) then
    begin
      Active^.Foes[fi].rank := RANK_FRONT;
      CombatLog(MonDefs[Active^.Foes[fi].def].name + ' surges to the front.');
      EnemyMaybeMove := true;
    end;
  end;
end;

{ A brute's ranged disruption: a taunt that throws a front-liner off
  balance, or a lobbed weapon that chips the back line and rattles it.
  Secondary to its melee, and the only reach it has while penned. }
function EnemyHarry(fi: longint): boolean;
var
  tgt, dmg: longint;
begin
  EnemyHarry := false;
  case MonDefs[Active^.Foes[fi].def].harry of
    HARRY_TAUNT:
      begin
        tgt := EnemyPickTarget(fi, false);     { a front-line attacker }
        if tgt < 0 then tgt := FirstConscious;
        if tgt < 0 then exit;
        CombatLog(MonDefs[Active^.Foes[fi].def].name + ' taunts ' + Active^.Party^[tgt].name + '.');
        AfflictMember(tgt, ST_OFFBAL, 2);
        EnemyHarry := true;
      end;
    HARRY_THROW:
      begin
        tgt := EnemyPickTarget(fi, true);      { lob at the soft back line }
        if tgt < 0 then exit;
        dmg := D(MonDefs[Active^.Foes[fi].def].dmgSides) div 2;
        if dmg < 1 then dmg := 1;
        dmg := ResistedHit(tgt, dmg, MonDefs[Active^.Foes[fi].def].element);
        CombatLog(MonDefs[Active^.Foes[fi].def].name + ' hurls a weapon at '
          + Active^.Party^[tgt].name + ' for ' + IntToStr(dmg) + '.');
        PushPop(1, tgt, POPC_PARTYDMG, IntToStr(dmg));
        FlashAlly(tgt);
        Active^.CombatSfxCue := CUE_HIT;
        HurtMember(tgt, dmg);
        if Active^.Party^[tgt].alive and (not Active^.Party^[tgt].downed) then
          AfflictMember(tgt, ST_OFFBAL, 2);    { a solid throw rattles them }
        EnemyHarry := true;
      end;
  end;
end;

{ A mage foe conjures a bolt at the party, reaching past the front line for
  the soft back row, and may leave the status its element implies. Spends SP. }
function EnemyCastBolt(fi: longint): boolean;
var
  tgt, dmg: longint;
begin
  EnemyCastBolt := false;
  if Active^.Foes[fi].sp < FOE_CAST_SP then exit;
  tgt := EnemyPickTarget(fi, true);       { ranged reach, prefers the back }
  if tgt < 0 then exit;
  dec(Active^.Foes[fi].sp, FOE_CAST_SP);
  dmg := RngRoll(GameRng, 1, 6) + MonDefs[Active^.Foes[fi].def].hd;
  if dmg < 1 then dmg := 1;
  dmg := ResistedHit(tgt, dmg, MonDefs[Active^.Foes[fi].def].element);
  CombatLog(MonDefs[Active^.Foes[fi].def].name + ' conjures a bolt at '
    + Active^.Party^[tgt].name + ' for ' + IntToStr(dmg) + '.');
  PushPop(1, tgt, POPC_PARTYDMG, IntToStr(dmg));
  FlashAlly(tgt);
  Active^.CombatSfxCue := CUE_HIT;
  HurtMember(tgt, dmg);
  if Active^.Party^[tgt].alive and (not Active^.Party^[tgt].downed)
     and (MonDefs[Active^.Foes[fi].def].inflict <> 0) then
    AfflictMember(tgt, MonDefs[Active^.Foes[fi].def].inflict, 3);
  EnemyCastBolt := true;
end;

{ A healer foe mends its most wounded living ally. Returns false (so the foe
  acts some other way) when no ally is hurt. Spends SP. }
function EnemyCastHeal(fi: longint): boolean;
var
  i, best, amt: longint;
begin
  EnemyCastHeal := false;
  if Active^.Foes[fi].sp < FOE_CAST_SP then exit;
  best := -1;
  for i := 0 to High(Active^.Foes) do
    if Active^.Foes[i].alive and (Active^.Foes[i].hp < Active^.Foes[i].hpMax) then
      if (best < 0) or (Active^.Foes[i].hp < Active^.Foes[best].hp) then best := i;
  if best < 0 then exit;                  { nobody needs it }
  dec(Active^.Foes[fi].sp, FOE_CAST_SP);
  amt := RngRoll(GameRng, 1, 8) + MonDefs[Active^.Foes[fi].def].hd;
  if amt < 1 then amt := 1;
  Active^.Foes[best].hp := Active^.Foes[best].hp + amt;
  if Active^.Foes[best].hp > Active^.Foes[best].hpMax then Active^.Foes[best].hp := Active^.Foes[best].hpMax;
  CombatLog(MonDefs[Active^.Foes[fi].def].name + ' mends '
    + MonDefs[Active^.Foes[best].def].name + ' (+' + IntToStr(amt) + ').');
  PushPop(0, best, POPC_HEAL, '+' + IntToStr(amt));
  FlashFoe(best);
  EnemyCastHeal := true;
end;

{ A healer foe raises a fallen ally, back on its feet at half health. The
  experience its fall granted is taken back, so a fresh kill still counts.
  Returns false when no ally lies dead. Spends SP. }
function EnemyCastRevive(fi: longint): boolean;
var
  i, best, amt: longint;
begin
  EnemyCastRevive := false;
  if Active^.Foes[fi].sp < FOE_REVIVE_SP then exit;
  best := -1;
  for i := 0 to High(Active^.Foes) do
    if not Active^.Foes[i].alive then begin best := i; break; end;
  if best < 0 then exit;                  { no one to raise }
  dec(Active^.Foes[fi].sp, FOE_REVIVE_SP);
  Active^.Foes[best].alive := true;
  amt := Active^.Foes[best].hpMax div 2;
  if amt < 1 then amt := 1;
  Active^.Foes[best].hp := amt;
  Active^.XPGained := Active^.XPGained - MonDefs[Active^.Foes[best].def].xp;
  if Active^.XPGained < 0 then Active^.XPGained := 0;
  FillChar(Active^.FoeStatus[best], SizeOf(TStatus), 0);
  CombatLog(MonDefs[Active^.Foes[fi].def].name + ' raises '
    + MonDefs[Active^.Foes[best].def].name + '.');
  PushPop(0, best, POPC_HEAL, 'RAISE');
  FlashFoe(best);
  EnemyCastRevive := true;
end;

end.
