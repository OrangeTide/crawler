program t_mapstate;

{** The snapshot store's LRU bound and resident-memory instrumentation. The
  store is poked directly here, so the checks need no live world or pak. }

{$mode objfpc}{$H+}

uses
  mapstate, testing;

{ Append a snapshot of a given total byte size (split over its fog and door
  arrays) and LRU touch, named for the checks to find it. }
procedure MakeSnap(const name: string; bytes: longint; touch: longword);
var
  i, half: longint;
begin
  i := Length(Snapshots);
  SetLength(Snapshots, i + 1);
  Snapshots[i].name := name;
  half := bytes div 2;
  SetLength(Snapshots[i].seen, half);
  SetLength(Snapshots[i].doors, bytes - half);
  Snapshots[i].touch := touch;
end;

const
  HALF_MB = 512 * 1024;

begin
  { byte accounting: three half-megabyte snapshots. }
  MapStateReset;
  MakeSnap('A', HALF_MB, 1);
  MakeSnap('B', HALF_MB, 2);
  MakeSnap('C', HALF_MB, 3);
  CheckEqI(MapStateBytes, 3 * HALF_MB, 'bytes sum the fog and door arrays');
  CheckEqI(MapStateResidentBytes, 3 * HALF_MB + RESIDENT_BASE_BYTES,
    'resident adds the baseline');
  Check(not MapStateOverBudget, 'three snapshots sit under the warn line');

  { a fourth pushes the estimate past the warn line. }
  MakeSnap('D', HALF_MB, 4);
  Check(MapStateOverBudget, 'four snapshots cross the warn line');

  { LRU: five half-MB snapshots overflow the cap; trimming keeps the newest
    and drops the least-recently-visited, never the kept (resident) map. }
  MapStateReset;
  MakeSnap('A', HALF_MB, 1);
  MakeSnap('B', HALF_MB, 2);
  MakeSnap('C', HALF_MB, 3);
  MakeSnap('D', HALF_MB, 4);
  MakeSnap('E', HALF_MB, 5);
  MapStateTrim('E');
  Check(MapStateBytes <= SNAPSHOT_CAP_BYTES, 'trim brings the store to the cap');
  Check(SnapshotIndex('A') < 0, 'the oldest map was evicted');
  Check(SnapshotIndex('B') < 0, 'the next oldest was evicted');
  Check(SnapshotIndex('C') >= 0, 'a newer map stays resident');
  Check(SnapshotIndex('E') >= 0, 'the kept map stays resident');

  { the kept map is protected even when it is the least recently visited. }
  MapStateReset;
  MakeSnap('A', HALF_MB, 1);
  MakeSnap('B', HALF_MB, 2);
  MakeSnap('C', HALF_MB, 3);
  MakeSnap('D', HALF_MB, 4);
  MakeSnap('E', HALF_MB, 5);
  MapStateTrim('A');
  Check(SnapshotIndex('A') >= 0, 'trim never evicts the kept map');
  Check(MapStateBytes <= SNAPSHOT_CAP_BYTES, 'trim still reaches the cap');

  { reindex gives a fresh ascending LRU order after a load. }
  MapStateReset;
  MakeSnap('A', 16, 99);
  MakeSnap('B', 16, 7);
  MapStateReindexTouch;
  CheckEqI(longint(Snapshots[0].touch), 1, 'reindex orders the first snapshot');
  CheckEqI(longint(Snapshots[1].touch), 2, 'reindex orders the second');

  TestSummary('mapstate');
  halt(TestExit);
end.
