program t_maptext_conform;

{** The map compiler's `conform N` directive. A hand-authored map whose open
  region sits off the kit's module grid is snapped to it at parse time, so the
  baked map clads from whole native pieces just like a generated one. Confirm
  the directive parses and that every open cell then sits in a fully open,
  single-sector N-block. }

{$mode objfpc}{$H+}

uses
  classes, mapfmt, maptext, testing;

const
  FN = 'build/tests/_maptext_conform.map';

procedure WriteMap;
var
  s: TStringList;
begin
  s := TStringList.Create;
  s.Add('map RAGGED');
  s.Add('size 12 12');
  s.Add('walls');
  s.Add('222222222222');
  s.Add('222222222222');
  s.Add('220000000022');   { an open region at x2..9, y2..7, off the 4-grid }
  s.Add('220000000022');
  s.Add('220000000022');
  s.Add('220000000022');
  s.Add('220000000022');
  s.Add('220000000022');
  s.Add('222222222222');
  s.Add('222222222222');
  s.Add('222222222222');
  s.Add('222222222222');
  s.Add('end');
  s.Add('conform 4');
  s.SaveToFile(FN);
  s.Free;
end;

{ Every open cell sits in a fully open, single-sector 4-block anchored to the
  world grid: the cladding's native-piece condition. }
function Claddable(const m: TMapData; modN: longint): boolean;
var
  tx, ty, ax, ay, rx, ry, j: longint;
  s0: byte;
begin
  Claddable := false;
  for ty := 0 to m.h - 1 do
    for tx := 0 to m.w - 1 do begin
      if m.walls[ty * m.w + tx] <> 0 then continue;
      s0 := m.cellSector[ty * m.w + tx];
      ax := (tx div modN) * modN;
      ay := (ty div modN) * modN;
      for ry := ay to ay + modN - 1 do
        for rx := ax to ax + modN - 1 do begin
          if (rx >= m.w) or (ry >= m.h) then exit;
          j := ry * m.w + rx;
          if m.walls[j] <> 0 then exit;
          if m.cellSector[j] <> s0 then exit;
        end;
    end;
  Claddable := true;
end;

function OpenCount(const m: TMapData): longint;
var i, n: longint;
begin
  n := 0;
  for i := 0 to m.w * m.h - 1 do
    if m.walls[i] = 0 then inc(n);
  OpenCount := n;
end;

var
  m: TMapData;
  name, err: string;
begin
  WriteMap;
  Check(ParseMapText(FN, m, name, err), 'the map with a conform directive parses');
  Check(name = 'RAGGED', 'the map name is read');
  Check(OpenCount(m) > 0, 'the conformed map keeps open floor');
  Check(Claddable(m, 4), 'the conformed map clads from native 4-blocks');

  TestSummary('maptext_conform');
  halt(TestExit);
end.
