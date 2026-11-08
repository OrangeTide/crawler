unit fieldcast;

{** Casting outside combat.

  A caster can work a spell's out-of-combat effect from the SPELLS tab while
  exploring: heal and raise the hurt, lift poison, disease and curses, refuel
  the party light, read magic on carried loot, and sense the ground around the
  party. The castable set and the per-spell effect come from spelldb
  (SpellFieldEffect); this unit spends the spell points and applies the result.

  A field cast costs the spell's level in spell points, which matches what the
  healing spells already charge in combat. Spell points are a persistent pool
  now (combat no longer tops them off), refilled by rest. }

{$mode objfpc}{$H+}

interface

{ The out-of-combat effect kind (spelldb FE_*) a catalog spell works. }
function FieldCastKind(catIdx: longint): byte;
{ The spell-point cost of casting catIdx in the field (its level). }
function FieldCost(catIdx: longint): longint;
{ Whether Roster[casterIdx] can field-cast catIdx now: a real field effect,
  the caster alive and conscious, and spell points enough for the cost. }
function CanFieldCast(casterIdx, catIdx: longint): boolean;
{ Work the field effect of catIdx cast by Roster[casterIdx] on Roster[target]
  (target is ignored for party-wide effects). Spends the spell points and
  returns a short result line, or '' when the cast cannot be made. }
function DoFieldCast(casterIdx, catIdx, target: longint): string;

implementation

uses
  sysutils, party, chardata, rules, spelldb, rng, gamestate, world;

function FieldCastKind(catIdx: longint): byte;
begin
  if (catIdx < 0) or (catIdx >= SpellDefCount) then
    FieldCastKind := FE_NONE
  else
    FieldCastKind := SpellFieldEffect(SpellDefs[catIdx]);
end;

function FieldCost(catIdx: longint): longint;
begin
  if (catIdx < 0) or (catIdx >= SpellDefCount) then
    FieldCost := 0
  else
    FieldCost := SpellDefs[catIdx].level;
end;

function CanFieldCast(casterIdx, catIdx: longint): boolean;
begin
  CanFieldCast := false;
  if (casterIdx < 0) or (casterIdx > High(Roster)) then exit;
  if FieldCastKind(catIdx) = FE_NONE then exit;
  if (not Roster[casterIdx].alive) or Roster[casterIdx].downed then exit;
  CanFieldCast := Roster[casterIdx].sp >= FieldCost(catIdx);
end;

{ The caster's prime-ability modifier, the same bonus a heal gets in combat. }
function CasterBonus(casterIdx: longint): longint;
begin
  CasterBonus := AbilMod(Roster[casterIdx].abil[
    TAbility(ClassDefs[Roster[casterIdx].klass].prime)]);
end;

function DoFieldCast(casterIdx, catIdx, target: longint): string;
var
  kind: byte;
  cost, amt, loads, fuel, n, r, x, y, x0, x1, y0, y1: longint;
begin
  DoFieldCast := '';
  if not CanFieldCast(casterIdx, catIdx) then exit;
  kind := FieldCastKind(catIdx);
  cost := FieldCost(catIdx);

  { targeted effects need a living member to land on }
  if FieldTargeted(kind) then begin
    if (target < 0) or (target > High(Roster)) or (not Roster[target].alive) then
      exit;
  end;

  dec(Roster[casterIdx].sp, cost);

  case kind of
    FE_HEAL: begin
      amt := RngRoll(GameRng, SpellDefs[catIdx].castDice,
        SpellDefs[catIdx].castSides) + CasterBonus(casterIdx);
      if amt < 1 then amt := 1;
      if Roster[target].downed then Roster[target].downed := false;
      Roster[target].hp := Roster[target].hp + amt;
      if Roster[target].hp > Roster[target].hpMax then
        Roster[target].hp := Roster[target].hpMax;
      DoFieldCast := Roster[casterIdx].name + ' mends '
        + Roster[target].name + ' (+' + IntToStr(amt) + ').';
    end;
    FE_CUREPOISON: begin
      Roster[target].poison := 0;
      DoFieldCast := Roster[target].name + ' is cleansed of poison.';
    end;
    FE_CUREDISEASE: begin
      Roster[target].disease := 0;
      DoFieldCast := Roster[target].name + '''s sickness lifts.';
    end;
    FE_REMOVECURSE: begin
      Roster[target].lycan := false;
      Roster[target].wereform := false;
      DoFieldCast := 'The curse lifts from ' + Roster[target].name + '.';
    end;
    FE_LIGHT: begin
      loads := SpellDefs[catIdx].fieldArg;
      if loads < 1 then loads := 1;
      fuel := loads * TORCH_MINUTES;
      if TorchFuel < fuel then TorchFuel := fuel;
      DoFieldCast := 'A clean light fills the way.';
    end;
    FE_IDENTIFY: begin
      n := IdentifyPartyFree;
      if n = 0 then DoFieldCast := 'Nothing carried reads as a mystery.'
      else if n = 1 then DoFieldCast := 'One item kind reads clear.'
      else DoFieldCast := IntToStr(n) + ' item kinds read clear.';
    end;
    FE_REVEAL: begin
      r := SpellDefs[catIdx].fieldArg;
      if r < 1 then r := 4;
      x0 := TileX - r; if x0 < 0 then x0 := 0;
      y0 := TileY - r; if y0 < 0 then y0 := 0;
      x1 := TileX + r; if x1 > MapW - 1 then x1 := MapW - 1;
      y1 := TileY + r; if y1 > MapH - 1 then y1 := MapH - 1;
      for y := y0 to y1 do
        for x := x0 to x1 do
          if Seen[y][x] < VIS_REMEMBERED then Seen[y][x] := VIS_REMEMBERED;
      DoFieldCast := 'You sense the ground around you.';
    end;
  else
    DoFieldCast := '';
  end;
end;

end.
