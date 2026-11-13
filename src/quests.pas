unit quests;

{** Data-driven quest log.

  A quest is a title with flag-gated stages and a completion flag, authored in
  content/quests.txt and compiled into the QUST lump. Quest state is read from
  the story flags, so nothing new goes in the save. QuestsUpdate derives
  composite flags (the relic from its shards) and appends the once-only journal
  lines, replacing what the old hardcoded SyncJournal did. The meta journal tab
  reads the quests here to show active and completed quests. }

{$mode objfpc}{$H+}

interface

uses pak;

const
  QUST_MAGIC = $54535551;  { 'QUST' }

type
  TQuestStage = record
    flag: string[24];
    text: string[120];
  end;

  TQuest = record
    id: string[16];
    title: string[32];
    stages: array of TQuestStage;
    doneFlag: string[24];
    doneText: string[120];
  end;

  TDerive = record
    target: string[24];
    sources: array of string[24];
  end;

  TQLog = record
    flag: string[24];
    text: string[120];
  end;

var
  QuestDefs: array of TQuest;
  QDerives: array of TDerive;
  QLogs: array of TQLog;

{ Parse content/quests.txt into the globals (used by the asset baker). }
function ParseQuests(const fn: string; out err: string): boolean;
{ Encode the globals into the QUST lump bytes. }
function EncodeQuests: pak.TByteArray;
{ Load the QUST lump into the globals at runtime. }
function LoadQuests(const p: TPak): boolean;

{ Apply derive rules, then append each set stage, done and log line once. Call
  after a dialog choice and on game load. }
procedure QuestsUpdate;

{ A quest is active once any stage flag or its done flag is set. }
function QuestActive(const q: TQuest): boolean;
{ A quest is complete once its done flag is set. }
function QuestComplete(const q: TQuest): boolean;
{ The current objective: the text of the last stage whose flag is set. }
function QuestObjective(const q: TQuest): string;

implementation

uses classes, sysutils, flags;

{ ---- byte helpers ---- }

procedure PutB(var a: pak.TByteArray; var n: longint; v: byte);
begin
  if n >= Length(a) then SetLength(a, (n + 1) * 2);
  a[n] := v; inc(n);
end;

procedure PutName(var a: pak.TByteArray; var n: longint; const s: string; len: longint);
var i: longint;
begin
  for i := 1 to len do
    if i <= Length(s) then PutB(a, n, ord(s[i])) else PutB(a, n, 0);
end;

function RName(const a: pak.TByteArray; var p: longint; len: longint): string;
var i: longint; s: string;
begin
  s := '';
  for i := 1 to len do begin
    if (p < Length(a)) and (a[p] <> 0) then s := s + chr(a[p]);
    inc(p);
  end;
  RName := s;
end;

function EncodeQuests: pak.TByteArray;
var a: pak.TByteArray; n, i, j: longint;
begin
  SetLength(a, 0); n := 0;
  PutB(a, n, QUST_MAGIC and $FF);
  PutB(a, n, (QUST_MAGIC shr 8) and $FF);
  PutB(a, n, (QUST_MAGIC shr 16) and $FF);
  PutB(a, n, (QUST_MAGIC shr 24) and $FF);
  PutB(a, n, Length(QuestDefs));
  for i := 0 to High(QuestDefs) do begin
    PutName(a, n, QuestDefs[i].id, 16);
    PutName(a, n, QuestDefs[i].title, 32);
    PutName(a, n, QuestDefs[i].doneFlag, 24);
    PutName(a, n, QuestDefs[i].doneText, 120);
    PutB(a, n, Length(QuestDefs[i].stages));
    for j := 0 to High(QuestDefs[i].stages) do begin
      PutName(a, n, QuestDefs[i].stages[j].flag, 24);
      PutName(a, n, QuestDefs[i].stages[j].text, 120);
    end;
  end;
  PutB(a, n, Length(QDerives));
  for i := 0 to High(QDerives) do begin
    PutName(a, n, QDerives[i].target, 24);
    PutB(a, n, Length(QDerives[i].sources));
    for j := 0 to High(QDerives[i].sources) do
      PutName(a, n, QDerives[i].sources[j], 24);
  end;
  PutB(a, n, Length(QLogs));
  for i := 0 to High(QLogs) do begin
    PutName(a, n, QLogs[i].flag, 24);
    PutName(a, n, QLogs[i].text, 120);
  end;
  SetLength(a, n);
  EncodeQuests := a;
end;

function LoadQuests(const p: TPak): boolean;
var blob: pak.TByteArray; pos, i, j, qn, sn, dn, srcn, ln: longint; m: longword;
begin
  LoadQuests := false;
  QuestDefs := nil; QDerives := nil; QLogs := nil;
  if not PakGet(p, 'QUST', blob) then exit;
  if Length(blob) < 5 then exit;
  m := blob[0] or (blob[1] shl 8) or (blob[2] shl 16) or (longword(blob[3]) shl 24);
  if m <> QUST_MAGIC then exit;
  pos := 4;
  qn := blob[pos]; inc(pos);
  SetLength(QuestDefs, qn);
  for i := 0 to qn - 1 do begin
    QuestDefs[i].id := RName(blob, pos, 16);
    QuestDefs[i].title := RName(blob, pos, 32);
    QuestDefs[i].doneFlag := RName(blob, pos, 24);
    QuestDefs[i].doneText := RName(blob, pos, 120);
    sn := blob[pos]; inc(pos);
    SetLength(QuestDefs[i].stages, sn);
    for j := 0 to sn - 1 do begin
      QuestDefs[i].stages[j].flag := RName(blob, pos, 24);
      QuestDefs[i].stages[j].text := RName(blob, pos, 120);
    end;
  end;
  dn := blob[pos]; inc(pos);
  SetLength(QDerives, dn);
  for i := 0 to dn - 1 do begin
    QDerives[i].target := RName(blob, pos, 24);
    srcn := blob[pos]; inc(pos);
    SetLength(QDerives[i].sources, srcn);
    for j := 0 to srcn - 1 do QDerives[i].sources[j] := RName(blob, pos, 24);
  end;
  ln := blob[pos]; inc(pos);
  SetLength(QLogs, ln);
  for i := 0 to ln - 1 do begin
    QLogs[i].flag := RName(blob, pos, 24);
    QLogs[i].text := RName(blob, pos, 120);
  end;
  LoadQuests := true;
end;

{ ---- runtime logic ---- }

procedure LogOnce(const flag, text: string);
begin
  if (flag <> '') and (text <> '') and FlagHas(flag) then
    JournalAddOnce(text);
end;

procedure QuestsUpdate;
var i, j: longint; all: boolean;
begin
  { Apply the derive rules: set a composite flag once all its sources are set.
    The quest stages and completion render straight from the flags, so they do
    not go in the flat journal; only the freeform log events do. }
  for i := 0 to High(QDerives) do begin
    if FlagHas(QDerives[i].target) then continue;
    all := Length(QDerives[i].sources) > 0;
    for j := 0 to High(QDerives[i].sources) do
      if not FlagHas(QDerives[i].sources[j]) then all := false;
    if all then FlagSet(QDerives[i].target);
  end;
  for i := 0 to High(QLogs) do
    LogOnce(QLogs[i].flag, QLogs[i].text);
end;

function QuestComplete(const q: TQuest): boolean;
begin
  QuestComplete := (q.doneFlag <> '') and FlagHas(q.doneFlag);
end;

function QuestActive(const q: TQuest): boolean;
var i: longint;
begin
  QuestActive := true;
  if QuestComplete(q) then exit;
  for i := 0 to High(q.stages) do
    if FlagHas(q.stages[i].flag) then exit;
  QuestActive := false;
end;

function QuestObjective(const q: TQuest): string;
var i: longint;
begin
  QuestObjective := '';
  for i := 0 to High(q.stages) do
    if FlagHas(q.stages[i].flag) then QuestObjective := q.stages[i].text;
end;

{ ---- parser ---- }

{ Split a line into its leading space-separated tokens and a trailing quoted
  string. tok[0..n-1] are the words before the first quote; quoted is the text
  inside the quotes, or empty. }
procedure SplitLine(const line: string; out tok: array of string; out n: longint;
  out quoted: string);
var qpos, qend, i, start, len: longint; head: string;
begin
  n := 0; quoted := '';
  qpos := Pos('"', line);
  if qpos > 0 then begin
    head := Trim(Copy(line, 1, qpos - 1));
    qend := Pos('"', Copy(line, qpos + 1, Length(line)));
    if qend > 0 then quoted := Copy(line, qpos + 1, qend - 1);
  end else
    head := line;
  len := Length(head);
  i := 1;
  while i <= len do begin
    while (i <= len) and (head[i] = ' ') do inc(i);
    if i > len then break;
    start := i;
    while (i <= len) and (head[i] <> ' ') do inc(i);
    if n <= High(tok) then tok[n] := Copy(head, start, i - start);
    inc(n);
  end;
end;

function ParseQuests(const fn: string; out err: string): boolean;
var
  lines: TStringList;
  li, n, j, cur: longint;
  tok: array[0 .. 31] of string;
  line, quoted: string;
begin
  ParseQuests := false; err := '';
  QuestDefs := nil; QDerives := nil; QLogs := nil;
  cur := -1;
  lines := TStringList.Create;
  try
    lines.LoadFromFile(fn);
    for li := 0 to lines.Count - 1 do begin
      line := Trim(lines[li]);
      if (line = '') or (line[1] = '#') then continue;
      SplitLine(line, tok, n, quoted);
      if tok[0] = 'quest' then begin
        if n < 2 then begin err := 'line ' + IntToStr(li + 1) + ': quest needs an id'; exit; end;
        SetLength(QuestDefs, Length(QuestDefs) + 1);
        cur := High(QuestDefs);
        QuestDefs[cur].id := tok[1];
        QuestDefs[cur].title := quoted;
        QuestDefs[cur].doneFlag := '';
        QuestDefs[cur].doneText := '';
        SetLength(QuestDefs[cur].stages, 0);
      end else if tok[0] = 'stage' then begin
        if cur < 0 then begin err := 'line ' + IntToStr(li + 1) + ': stage before quest'; exit; end;
        if n < 2 then begin err := 'line ' + IntToStr(li + 1) + ': stage needs a flag'; exit; end;
        j := Length(QuestDefs[cur].stages);
        SetLength(QuestDefs[cur].stages, j + 1);
        QuestDefs[cur].stages[j].flag := tok[1];
        QuestDefs[cur].stages[j].text := quoted;
      end else if tok[0] = 'done' then begin
        if cur < 0 then begin err := 'line ' + IntToStr(li + 1) + ': done before quest'; exit; end;
        if n < 2 then begin err := 'line ' + IntToStr(li + 1) + ': done needs a flag'; exit; end;
        QuestDefs[cur].doneFlag := tok[1];
        QuestDefs[cur].doneText := quoted;
      end else if tok[0] = 'derive' then begin
        if n < 3 then begin err := 'line ' + IntToStr(li + 1) + ': derive needs a target and sources'; exit; end;
        SetLength(QDerives, Length(QDerives) + 1);
        QDerives[High(QDerives)].target := tok[1];
        SetLength(QDerives[High(QDerives)].sources, n - 2);
        for j := 2 to n - 1 do
          QDerives[High(QDerives)].sources[j - 2] := tok[j];
      end else if tok[0] = 'log' then begin
        if n < 2 then begin err := 'line ' + IntToStr(li + 1) + ': log needs a flag'; exit; end;
        SetLength(QLogs, Length(QLogs) + 1);
        QLogs[High(QLogs)].flag := tok[1];
        QLogs[High(QLogs)].text := quoted;
      end else begin
        err := 'line ' + IntToStr(li + 1) + ': unknown quest directive ' + tok[0]; exit;
      end;
    end;
  finally
    lines.Free;
  end;
  ParseQuests := true;
end;

end.
