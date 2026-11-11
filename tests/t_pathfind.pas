program t_pathfind;

{** Intra-map A*: routes over hand-built grids, with doors and limits. }

{$mode objfpc}{$H+}

uses
  mapfmt, pathfind, testing;

{ Build a map from a list of equal-length row strings: '.' open, '#' wall,
  '+' a door tile. }
procedure BuildMap(out m: TMapData; const rows: array of string);
var
  y, x: longint;
  c: char;
begin
  m.w := Length(rows[0]);
  m.h := Length(rows);
  m.tileset := 0; m.music := 0; m.flags := 0; m.area := 0;
  m.markers := nil; m.portals := nil; m.doors := nil;
  m.npcs := nil; m.traps := nil; m.lights := nil; m.props := nil;
  SetLength(m.walls, m.w * m.h);
  for y := 0 to m.h - 1 do
    for x := 0 to m.w - 1 do begin
      c := rows[y][x + 1];
      case c of
        '#': m.walls[y * m.w + x] := 1;
        '+': m.walls[y * m.w + x] := TILE_DOOR;
      else
        m.walls[y * m.w + x] := TILE_EMPTY;
      end;
    end;
end;

var
  m: TMapData;
  path: array[0 .. 255] of TPathStep;
  steps: longint;
  tiny: array[0 .. 2] of TPathStep;
  doorAt: boolean;
  i: longint;
begin
  { 1: straight corridor, 1x5 open. }
  BuildMap(m, ['.....']);
  Check(FindPath(m, 0, 0, 4, 0, true, path, steps), 'corridor reachable');
  CheckEqI(steps, 5, 'corridor is five tiles');
  Check((path[0].x = 0) and (path[0].y = 0), 'corridor starts at the start');
  Check((path[4].x = 4) and (path[4].y = 0), 'corridor ends at the goal');

  { 2: open 5x5 room, Manhattan-length diagonal trip. }
  BuildMap(m, ['.....', '.....', '.....', '.....', '.....']);
  Check(FindPath(m, 0, 0, 4, 4, true, path, steps), 'open room reachable');
  CheckEqI(steps, 9, 'shortest corner-to-corner is nine tiles');

  { 3: a wall column at x=2 for y=0..3, gap at (2,4): must detour. }
  BuildMap(m, ['..#..', '..#..', '..#..', '..#..', '.....']);
  Check(FindPath(m, 0, 0, 4, 0, true, path, steps), 'route around obstacle');
  CheckEqI(steps, 13, 'detour length round the wall');

  { 4: a full wall column splits the map: no route. }
  BuildMap(m, ['..#..', '..#..', '..#..', '..#..', '..#..']);
  Check(not FindPath(m, 0, 0, 4, 0, true, path, steps), 'walled off: no path');
  CheckEqI(steps, 0, 'no path yields zero steps');
  Check(not PathExists(m, 0, 0, 4, 0, true), 'PathExists agrees: walled off');

  { 5 and 6: a door mid-corridor, passable only when doors are allowed. }
  BuildMap(m, ['..+..']);
  Check(FindPath(m, 0, 0, 4, 0, true, path, steps), 'door open to pathing');
  doorAt := false;
  for i := 0 to steps - 1 do
    if (path[i].x = 2) and (path[i].y = 0) then doorAt := true;
  Check(doorAt, 'the route passes through the door tile');
  Check(not FindPath(m, 0, 0, 4, 0, false, path, steps), 'closed door blocks');

  { 7: start equals goal. }
  BuildMap(m, ['.....', '.....', '.....', '.....', '.....']);
  Check(FindPath(m, 2, 2, 2, 2, true, path, steps), 'trivial path exists');
  CheckEqI(steps, 1, 'trivial path is one tile');

  { 8: a goal that sits on a wall is rejected. }
  BuildMap(m, ['..#..', '.....', '.....', '.....', '.....']);
  Check(not FindPath(m, 0, 1, 2, 0, true, path, steps), 'goal on a wall rejected');
  Check(not FindPath(m, 2, 0, 0, 1, true, path, steps), 'start on a wall rejected');

  { 9: PathExists agrees with FindPath on a solvable detour. }
  BuildMap(m, ['..#..', '..#..', '..#..', '..#..', '.....']);
  CheckEqI(ord(PathExists(m, 0, 0, 4, 0, true)),
    ord(FindPath(m, 0, 0, 4, 0, true, path, steps)),
    'PathExists matches FindPath');

  { 10: buffer too small: the 1x5 corridor needs five slots, has three. }
  BuildMap(m, ['.....']);
  Check(not FindPath(m, 0, 0, 4, 0, true, tiny, steps),
    'returns false when the route exceeds the buffer');

  { 11: a locked door is a wall to planning, unless the planner may pick it
    (canPick), or the door is unlocked. }
  BuildMap(m, ['..+..']);
  SetLength(m.doors, 1);
  m.doors[0].x := 2; m.doors[0].y := 0; m.doors[0].locked := 1;
  m.doors[0].key := 'K';
  Check(not FindPath(m, 0, 0, 4, 0, true, path, steps),
    'a locked door blocks a route that cannot pick it');
  Check(FindPath(m, 0, 0, 4, 0, true, path, steps, true),
    'a locked door opens to a route that can pick it');
  m.doors[0].locked := 0;
  Check(FindPath(m, 0, 0, 4, 0, true, path, steps),
    'the same door unlocked lets the route through');

  { 12: an NPC blocks its tile, and a route detours around one. }
  BuildMap(m, ['.....']);
  SetLength(m.npcs, 1);
  m.npcs[0].x := 2; m.npcs[0].y := 0;
  Check(not FindPath(m, 0, 0, 4, 0, true, path, steps),
    'an NPC blocks the only corridor');
  BuildMap(m, ['.....', '.....']);
  SetLength(m.npcs, 1);
  m.npcs[0].x := 2; m.npcs[0].y := 0;
  Check(FindPath(m, 0, 0, 4, 0, true, path, steps),
    'a route detours around an NPC when it can');

  TestSummary('pathfind');
  halt(TestExit);
end.
