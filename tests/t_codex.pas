program t_codex;

{** The reference codex: the bestiary of met monsters and the identified item
  kinds, sized to the loaded tables. }

{$mode objfpc}{$H+}

uses
  sysutils, pak, items, monsters, codex, testing;

var
  p: TPak;
  si: longint;
begin
  if not PakLoad('build/game.pak', p) then begin
    writeln('  FAIL could not load build/game.pak (run make first)');
    halt(2);
  end;
  LoadItems(p);
  LoadMonsters(p);

  CodexReset;
  CheckEqI(MonSeenCount, 0, 'a fresh codex has met nobody');

  si := MonIndex('SKELETON');
  Check(not MonIsSeen(si), 'the skeleton is unknown at first');
  MarkMonSeen(si);
  Check(MonIsSeen(si), 'the skeleton is known once met');
  CheckEqI(MonSeenCount, 1, 'one monster met');
  MarkMonSeen(si);
  CheckEqI(MonSeenCount, 1, 'meeting the same monster twice counts once');

  MarkMonSeen(-1);
  MarkMonSeen(99999);
  CheckEqI(MonSeenCount, 1, 'out-of-range marks are ignored');

  { plain gear is always known and shows its real name }
  Check(ItemIsKnown(ItemIndex('SWORD')), 'plain gear is known');
  Check(ItemIsKnown(-1), 'an out-of-range item reads as known');
  Check(ItemLabel(ItemIndex('SWORD')) = 'Short Sword', 'known gear shows its name');

  { a mystery item hides its name until identified }
  Check(ItemIndex('ELIXIR') >= 0, 'the mystery elixir exists');
  Check(not ItemIsKnown(ItemIndex('ELIXIR')), 'a mystery item starts unknown');
  Check(ItemLabel(ItemIndex('ELIXIR')) = 'UNKNOWN POTION',
    'an unknown potion shows a generic label');
  MarkItemKnown(ItemIndex('ELIXIR'));
  Check(ItemIsKnown(ItemIndex('ELIXIR')), 'it is known once identified');
  Check(ItemLabel(ItemIndex('ELIXIR')) = 'Elixir of Vigor',
    'a known item shows its true name');

  { CodexReset wipes the bestiary back to empty }
  CodexReset;
  CheckEqI(MonSeenCount, 0, 'a reset clears the bestiary');

  TestSummary('codex');
  halt(TestExit);
end.
