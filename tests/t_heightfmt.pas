program t_heightfmt;

{** Baked terrain heightmap codec: the CHGT lump round-trips its dimensions and
  every sample, and a malformed blob is rejected. }

{$mode objfpc}{$H+}

uses
  sysutils, pak, heightfmt, testing;

var
  samples, got, blob, bad: TByteArray;
  w, h, i: longint;
  ok: boolean;
begin
  { a 3x2 ramp of distinct sample values }
  SetLength(samples, 6);
  for i := 0 to 5 do samples[i] := i * 40;

  blob := EncodeHeight(3, 2, samples);
  Check(DecodeHeight(blob, w, h, got), 'the heightmap decodes');
  CheckEqI(w, 3, 'the width round-trips');
  CheckEqI(h, 2, 'the height round-trips');
  CheckEqI(Length(got), 6, 'the sample count round-trips');
  ok := true;
  for i := 0 to 5 do if got[i] <> samples[i] then ok := false;
  Check(ok, 'every sample round-trips');

  { a truncated blob is rejected, not read past the end }
  SetLength(bad, 4);
  for i := 0 to 3 do bad[i] := blob[i];
  Check(not DecodeHeight(bad, w, h, got), 'a truncated blob is rejected');

  TestSummary('heightfmt');
  halt(TestExit);
end.
