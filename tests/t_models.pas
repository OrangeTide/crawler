program t_models;

{** Prop model cost accounting. Monsters and NPCs are billboard sprites now,
  so the model registry holds only the prop meshes. Confirm each reports a
  VRAM weight, that a set sums weights with duplicates counted once, and that
  the per-area gate loads only the requested models. }

{$mode objfpc}{$H+}

uses
  sysutils, pak, gfx, meshfmt, models, testing;

var
  p: TPak;
  one: longint;
begin
  if not PakLoad('build/game.pak', p) then begin
    writeln('  FAIL could not load build/game.pak (run make first)');
    halt(2);
  end;
  InitGfx;
  Check(LoadModels(p), 'load models');

  { a prop texture weighs its texel bytes in the 8-bit page }
  Check(ModelVramCost('BARREL') > 0, 'BARREL costs its texture bytes');
  Check(ModelVramCost('NOSUCH') = 0, 'an unknown model costs nothing');

  { a repeated model in a set is counted once }
  one := ModelSetVramCost(['BARREL']);
  Check(ModelSetVramCost(['BARREL', 'BARREL']) = one,
    'a duplicate model is not double counted');
  Check(ModelSetVramCost(['BARREL', 'DOORWAY'])
    = ModelVramCost('BARREL') + ModelVramCost('DOORWAY'),
    'two distinct models sum their cost');

  Check(ModelSetFitsVram(['BARREL', 'DOORWAY']), 'the prop set fits VRAM');

  { gating to a subset unloads the rest }
  LoadModelSet(p, ['BARREL']);
  Check(FindModel('BARREL') >= 0, 'a gated set loads its models');
  Check(FindModel('DOORWAY') < 0, 'a model outside the gate is not loaded');
  LoadModels(p);   { restore the full registry for anything after }

  TestSummary('models');
  halt(TestExit);
end.
