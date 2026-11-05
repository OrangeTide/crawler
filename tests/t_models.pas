program t_models;

{** Model cost accounting. Confirm each model reports a VRAM weight, that
  a model set sums its weights with duplicates counted once, and that the
  budget check flags a set that overflows PSX VRAM. }

{$mode objfpc}{$H+}

uses
  sysutils, pak, gfx, meshfmt, models, monsters, overworld, testing;

var
  p: TPak;
  i, b, one, two, full, na: longint;
  names: array of string;
  areaFits: boolean;
begin
  if not PakLoad('build/game.pak', p) then begin
    writeln('  FAIL could not load build/game.pak (run make first)');
    halt(2);
  end;
  InitGfx;
  Check(LoadModels(p), 'load models');
  Check(LoadMonsters(p), 'load monsters');

  { a creature texture is 128x128, one byte per texel in an 8-bit page }
  Check(ModelVramCost('CREA1') = 128 * 128, 'CREA1 costs its texture bytes');
  Check(ModelVramCost('NOSUCH') = 0, 'an unknown model costs nothing');

  { a repeated model in a set is counted once }
  one := ModelSetVramCost(['CREA1']);
  two := ModelSetVramCost(['CREA1', 'CREA1']);
  Check(two = one, 'a duplicate model is not double counted');
  Check(ModelSetVramCost(['CREA1', 'CREA2']) = 2 * one,
    'two distinct models sum their cost');

  Check(ModelSetFitsVram(['CREA1', 'CREA2', 'CREA3']), 'a small set fits');

  { the monster roster alone fits VRAM, with little headroom }
  SetLength(names, Length(MonDefs));
  for i := 0 to High(MonDefs) do names[i] := MonDefs[i].model;
  full := ModelSetVramCost(names);
  writeln('  (every monster model at once: ', full, ' of ',
    MODEL_VRAM_BUDGET, ' B)');
  Check(ModelSetFitsVram(names), 'the whole monster roster fits VRAM');

  { adding prop models on top overflows the budget, so an area must
    trim its model set rather than hold everything }
  SetLength(names, Length(MonDefs) + 2);
  names[High(names) - 1] := 'DOORWAY';
  names[High(names)] := 'BARREL';
  Check(not ModelSetFitsVram(names),
    'monsters plus props exceed the budget');

  { the gate's purpose: every single area's roster fits VRAM on its own }
  areaFits := true;
  for b := 0 to 7 do begin
    SetLength(names, 0); na := 0;
    for i := 0 to High(MonDefs) do
      if (MonDefs[i].areas and (1 shl b)) <> 0 then begin
        SetLength(names, na + 1); names[na] := MonDefs[i].model; inc(na);
      end;
    if (na > 0) and (not ModelSetFitsVram(names)) then areaFits := false;
  end;
  Check(areaFits, 'each per-area roster fits the VRAM budget');

  { gating to a small set unloads the rest }
  LoadModelSet(p, ['CREA1', 'CREA2']);
  Check((FindModel('CREA1') >= 0) and (FindModel('CREA2') >= 0),
    'a gated set loads its models');
  Check(FindModel('CREA13') < 0, 'a model outside the gate is not loaded');
  LoadModels(p);   { restore the full registry for anything after }

  TestSummary('models');
  halt(TestExit);
end.
