unit save;

{** Save and load the whole game to a file.

  The save captures the party, gold, story flags, journal, the current
  map and party position, and a snapshot of every visited map (fog and
  doors). It is the only format written at runtime, so it carries a
  version for migration. The map is reloaded by the caller from the
  stored name after a load returns. }

{$mode objfpc}{$H+}

interface

uses
  world, party, flags, mapstate;

const
  SAVE_MAGIC   = $56415343;  { 'CSAV' }
  SAVE_VERSION = 14;

var
  LoadedMapName: string;
  LoadedTX, LoadedTY, LoadedFace: longint;

function SaveGame(const fn: string): boolean;
function LoadGame(const fn: string): boolean;
function SaveExists(const fn: string): boolean;

implementation

uses
  classes, sysutils, rules, chardata, gametime, pursuit, gamestate, codex,
  mappins, beings;

{ ---- stream helpers ---- }

procedure WU32(s: TStream; v: longword);
begin
  s.WriteByte(v and $FF); s.WriteByte((v shr 8) and $FF);
  s.WriteByte((v shr 16) and $FF); s.WriteByte((v shr 24) and $FF);
end;

procedure WI32(s: TStream; v: longint);
begin
  WU32(s, longword(v));
end;

function RU32(s: TStream): longword;
var a, b, c, d: byte;
begin
  a := s.ReadByte; b := s.ReadByte; c := s.ReadByte; d := s.ReadByte;
  RU32 := a or (b shl 8) or (c shl 16) or (longword(d) shl 24);
end;

function RI32(s: TStream): longint;
begin
  RI32 := longint(RU32(s));
end;

procedure WStr(s: TStream; const v: string);
var i: longint;
begin
  WU32(s, Length(v));
  for i := 1 to Length(v) do s.WriteByte(ord(v[i]));
end;

function RStr(s: TStream): string;
var n, i: longint; r: string;
begin
  n := RI32(s); r := '';
  for i := 1 to n do r := r + chr(s.ReadByte);
  RStr := r;
end;

{ ---- character ---- }

procedure WItem(s: TStream; const it: TItemInst);
begin
  WI32(s, it.def);
  WI32(s, it.qty);
  s.WriteByte(ord(it.identified));
end;

function RItem(s: TStream): TItemInst;
begin
  RItem.def := RI32(s);
  RItem.qty := RI32(s);
  RItem.identified := s.ReadByte <> 0;
end;

procedure WChar(s: TStream; const c: TCharacter);
var a: TAbility; sl: TEquipSlot; i: longint;
begin
  WStr(s, c.name);
  s.WriteByte(GenderToByte(c.gender));
  WI32(s, c.species); WI32(s, c.klass); WI32(s, c.background);
  WI32(s, c.level); WI32(s, c.xp);
  for a := abSTR to abCHA do s.WriteByte(c.abil[a]);
  WI32(s, c.hpMax); WI32(s, c.hp);
  for sl := eqMain to eqLight do WItem(s, c.equip[sl]);
  WI32(s, Length(c.pack));
  for i := 0 to High(c.pack) do WItem(s, c.pack[i]);
  s.WriteByte(ord(c.alive));
  s.WriteByte(ord(c.downed));
  s.WriteByte(ord(c.guarding));
  s.WriteByte(c.brushes);
  s.WriteByte(c.poison);
  s.WriteByte(c.disease);
  s.WriteByte(ord(c.lycan));
  s.WriteByte(ord(c.hireling));
  WI32(s, c.wage);
  WI32(s, Length(c.known));
  for i := 0 to High(c.known) do WStr(s, c.known[i]);
  s.WriteByte(c.portrait);
  WI32(s, Length(c.skills));
  for i := 0 to High(c.skills) do begin
    WStr(s, c.skills[i].id);
    s.WriteByte(c.skills[i].rank);
  end;
  s.WriteByte(c.skillSlots);
  s.WriteByte(ord(c.mended));
end;

function RChar(s: TStream): TCharacter;
var a: TAbility; sl: TEquipSlot; i, n: longint;
begin
  RChar.name := RStr(s);
  RChar.gender := GenderFromByte(s.ReadByte);
  RChar.species := RI32(s); RChar.klass := RI32(s); RChar.background := RI32(s);
  RChar.level := RI32(s); RChar.xp := RI32(s);
  for a := abSTR to abCHA do RChar.abil[a] := s.ReadByte;
  RChar.hpMax := RI32(s); RChar.hp := RI32(s);
  for sl := eqMain to eqLight do RChar.equip[sl] := RItem(s);
  n := RI32(s);
  SetLength(RChar.pack, n);
  for i := 0 to n - 1 do RChar.pack[i] := RItem(s);
  RChar.alive := s.ReadByte <> 0;
  RChar.downed := s.ReadByte <> 0;
  RChar.guarding := s.ReadByte <> 0;
  RChar.brushes := s.ReadByte;
  RChar.poison := s.ReadByte;
  RChar.disease := s.ReadByte;
  RChar.lycan := s.ReadByte <> 0;
  RChar.hireling := s.ReadByte <> 0;
  RChar.wage := RI32(s);
  n := RI32(s);
  SetLength(RChar.known, n);
  for i := 0 to n - 1 do RChar.known[i] := RStr(s);
  RChar.portrait := s.ReadByte;
  n := RI32(s);
  SetLength(RChar.skills, n);
  for i := 0 to n - 1 do begin
    RChar.skills[i].id := RStr(s);
    RChar.skills[i].rank := s.ReadByte;
  end;
  RChar.skillSlots := s.ReadByte;
  RChar.mended := s.ReadByte <> 0;
  RChar.wereform := false;   { recomputed from the moon on the next frame }
  RChar.size := SZ_MEDIUM;   { PCs are medium; a combat attribute, not saved }
end;

function SaveGame(const fn: string): boolean;
var
  fs: TFileStream;
  i, j: longint;
begin
  SaveGame := false;
  { capture the resident map so its fog is stored too }
  MapStateCapture(CurMapName);
  try
    fs := TFileStream.Create(fn, fmCreate);
  except
    exit;
  end;
  try
    WU32(fs, SAVE_MAGIC);
    WU32(fs, SAVE_VERSION);

    { party }
    WI32(fs, Length(Roster));
    for i := 0 to High(Roster) do WChar(fs, Roster[i]);
    WI32(fs, PartyGold);

    { flags and journal }
    WI32(fs, Length(FlagNames));
    for i := 0 to High(FlagNames) do WStr(fs, FlagNames[i]);
    WI32(fs, Length(Journal));
    for i := 0 to High(Journal) do WStr(fs, Journal[i]);

    { location }
    WStr(fs, CurMapName);
    WI32(fs, TileX); WI32(fs, TileY); WI32(fs, FaceDir);

    { clock and moon, then the party light }
    WU32(fs, ClockMin);
    WI32(fs, Round(MoonOffsetDays * 1000.0));
    WI32(fs, TorchFuel);
    WU32(fs, WagesDueClock);

    { visited-map snapshots }
    WI32(fs, Length(Snapshots));
    for i := 0 to High(Snapshots) do begin
      WStr(fs, Snapshots[i].name);
      WI32(fs, Snapshots[i].w); WI32(fs, Snapshots[i].h);
      fs.WriteByte(ord(Snapshots[i].isDynamic));
      WI32(fs, Snapshots[i].version);
      WU32(fs, Snapshots[i].seed);
      for j := 0 to Snapshots[i].w * Snapshots[i].h - 1 do
        fs.WriteByte(Snapshots[i].seen[j]);
      for j := 0 to Snapshots[i].w * Snapshots[i].h - 1 do
        fs.WriteByte(Snapshots[i].doors[j]);
    end;

    { roaming hunters, so a chase survives a save (active ones only) }
    j := 0;
    for i := 0 to High(Pursuers) do if Pursuers[i].active then inc(j);
    WI32(fs, j);
    for i := 0 to High(Pursuers) do
      if Pursuers[i].active then begin
        WI32(fs, Pursuers[i].mon);
        WStr(fs, Pursuers[i].map);
        WI32(fs, Pursuers[i].x);
        WI32(fs, Pursuers[i].y);
      end;

    { codex: the bestiary and the identified item kinds }
    WI32(fs, Length(MonSeen));
    for i := 0 to High(MonSeen) do fs.WriteByte(ord(MonSeen[i]));
    WI32(fs, Length(ItemIdent));
    for i := 0 to High(ItemIdent) do fs.WriteByte(ord(ItemIdent[i]));

    { map pins and auto-markers }
    WI32(fs, Length(Pins));
    for i := 0 to High(Pins) do begin
      WStr(fs, Pins[i].map);
      WI32(fs, Pins[i].x);
      WI32(fs, Pins[i].y);
      fs.WriteByte(Pins[i].kind);
    end;
  finally
    fs.Free;
  end;
  SaveGame := true;
end;

function LoadGame(const fn: string): boolean;
var
  fs: TFileStream;
  i, j, n, cells, pmon, px, py: longint;
  pmap: string;
begin
  LoadGame := false;
  if not FileExists(fn) then exit;
  fs := TFileStream.Create(fn, fmOpenRead or fmShareDenyWrite);
  try
    if RU32(fs) <> SAVE_MAGIC then exit;
    if RU32(fs) <> SAVE_VERSION then exit;

    n := RI32(fs);
    SetLength(Roster, n);
    for i := 0 to n - 1 do Roster[i] := RChar(fs);
    PartyGold := RI32(fs);

    FlagsReset;
    n := RI32(fs);
    for i := 0 to n - 1 do FlagSet(RStr(fs));
    n := RI32(fs);
    for i := 0 to n - 1 do JournalAdd(RStr(fs));

    LoadedMapName := RStr(fs);
    LoadedTX := RI32(fs); LoadedTY := RI32(fs); LoadedFace := RI32(fs);

    ClockMin := RU32(fs);
    MoonOffsetDays := RI32(fs) / 1000.0;
    TorchFuel := RI32(fs);
    WagesDueClock := RU32(fs);

    MapStateReset;
    n := RI32(fs);
    SetLength(Snapshots, n);
    for i := 0 to n - 1 do begin
      Snapshots[i].name := RStr(fs);
      Snapshots[i].w := RI32(fs); Snapshots[i].h := RI32(fs);
      Snapshots[i].isDynamic := fs.ReadByte <> 0;
      Snapshots[i].version := RI32(fs);
      Snapshots[i].seed := RU32(fs);
      cells := Snapshots[i].w * Snapshots[i].h;
      SetLength(Snapshots[i].seen, cells);
      SetLength(Snapshots[i].doors, cells);
      for j := 0 to cells - 1 do Snapshots[i].seen[j] := fs.ReadByte;
      for j := 0 to cells - 1 do Snapshots[i].doors[j] := fs.ReadByte;
    end;
    MapStateReindexTouch;   { restore an LRU order; touch is not serialised }

    { roaming hunters: clear any live ones, then restore the saved chase.
      read the fields in order into locals; argument evaluation order is
      not defined, so they cannot be read inline in the call. }
    PursuitReset;
    n := RI32(fs);
    for i := 0 to n - 1 do begin
      pmon := RI32(fs);
      pmap := RStr(fs);
      px := RI32(fs);
      py := RI32(fs);
      AddPursuer(pmon, pmap, px, py);
    end;

    { codex: size to the current tables, then overlay the saved bits }
    CodexReset;
    n := RI32(fs);
    for i := 0 to n - 1 do begin
      cells := fs.ReadByte;   { reuse cells as a scratch byte }
      if i <= High(MonSeen) then MonSeen[i] := cells <> 0;
    end;
    n := RI32(fs);
    for i := 0 to n - 1 do begin
      cells := fs.ReadByte;
      if i <= High(ItemIdent) then ItemIdent[i] := cells <> 0;
    end;

    { map pins. Read each field in order into the record; argument evaluation
      order is undefined, so the reads cannot be inlined into one call. }
    PinsReset;
    n := RI32(fs);
    SetLength(Pins, n);
    for i := 0 to n - 1 do begin
      Pins[i].map := RStr(fs);
      Pins[i].x := RI32(fs);
      Pins[i].y := RI32(fs);
      Pins[i].kind := fs.ReadByte;
    end;
  finally
    fs.Free;
  end;
  LoadGame := true;
end;

function SaveExists(const fn: string): boolean;
begin
  SaveExists := FileExists(fn);
end;

end.
