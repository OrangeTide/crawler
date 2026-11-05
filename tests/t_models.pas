program t_models;

{** Model cost accounting. Confirm each model reports a VRAM weight, that
  a model set sums its weights with duplicates counted once, and that the
  budget check flags a set that overflows PSX VRAM. }

{$mode objfpc}{$H+}

uses
  sysutils, pak, gfx, meshfmt, models, monsters, testing;

var
  p: TPak;
  i, one, two, full: longint;
  names: array of string;
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

  TestSummary('models');
  halt(TestExit);
end.
