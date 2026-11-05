unit dialogtext;

{** Parser for the text conversation format, used by the asset tool.

    dialog NAME
    node 0
    text "NPC line"
    resp "player line" goto 1
    resp "player line" shop
    resp "player line" setflag QUEST_X
    resp "player line" end

  Nodes are numbered in order from 0. A shop or setflag response stays on
  the same node after acting. Blank lines and '#' comments are ignored. }

{$mode objfpc}{$H+}

interface

uses
  dialog;

function ParseDialogs(const fn: string; out cs: array of TConversation;
  out count: longint; out err: string): boolean;

implementation

uses
  classes, sysutils;

procedure QTok(const line: string; out tok: array of string; out n: longint);
var
  i, len, start: longint;
begin
  n := 0; len := Length(line); i := 1;
  while i <= len do begin
    while (i <= len) and (line[i] = ' ') do inc(i);
    if i > len then break;
    if line[i] = '"' then begin
      inc(i); start := i;
      while (i <= len) and (line[i] <> '"') do inc(i);
      if n <= High(tok) then tok[n] := Copy(line, start, i - start);
      inc(n);
      if i <= len then inc(i);
    end else begin
      start := i;
      while (i <= len) and (line[i] <> ' ') do inc(i);
      if n <= High(tok) then tok[n] := Copy(line, start, i - start);
      inc(n);
    end;
  end;
end;

function ParseDialogs(const fn: string; out cs: array of TConversation;
  out count: longint; out err: string): boolean;
var
  lines: TStringList;
  li, n, curNode: longint;
  tok: array[0 .. 7] of string;
  line: string;
  r: TResponse;
begin
  ParseDialogs := false; err := ''; count := 0; curNode := -1;
  lines := TStringList.Create;
  try
    lines.LoadFromFile(fn);
    for li := 0 to lines.Count - 1 do begin
      line := Trim(lines[li]);
      if (line = '') or (line[1] = '#') then continue;
      QTok(line, tok, n);
      if n = 0 then continue;

      if tok[0] = 'dialog' then begin
        if count > High(cs) then begin err := 'too many dialogs'; exit; end;
        inc(count);
        cs[count - 1].name := tok[1];
        cs[count - 1].nodes := nil;
        curNode := -1;
      end else if tok[0] = 'node' then begin
        if count = 0 then begin err := 'node before dialog'; exit; end;
        SetLength(cs[count - 1].nodes, Length(cs[count - 1].nodes) + 1);
        curNode := High(cs[count - 1].nodes);
        cs[count - 1].nodes[curNode].text := '';
        cs[count - 1].nodes[curNode].resp := nil;
      end else if tok[0] = 'text' then begin
        if curNode < 0 then begin err := 'text before node'; exit; end;
        cs[count - 1].nodes[curNode].text := tok[1];
      end else if tok[0] = 'resp' then begin
        if curNode < 0 then begin err := 'resp before node'; exit; end;
        r.text := tok[1];
        r.arg := '';
        r.condFlag := '';
        r.gotoNode := curNode;
        if (n >= 3) and (tok[2] = 'goto') then begin
          r.action := DA_GOTO; r.gotoNode := StrToInt(tok[3]);
        end else if (n >= 3) and (tok[2] = 'end') then
          r.action := DA_END
        else if (n >= 3) and (tok[2] = 'shop') then
          r.action := DA_SHOP
        else if (n >= 4) and (tok[2] = 'setflag') then begin
          r.action := DA_SETFLAG; r.arg := tok[3];
        end else begin
          err := 'line ' + IntToStr(li + 1) + ': bad response action';
          exit;
        end;
        { optional trailing: needflag FLAG }
        if (n >= 2) and (tok[n - 2] = 'needflag') then
          r.condFlag := tok[n - 1];
        with cs[count - 1].nodes[curNode] do begin
          SetLength(resp, Length(resp) + 1);
          resp[High(resp)] := r;
        end;
      end else begin
        err := 'line ' + IntToStr(li + 1) + ': unknown keyword ' + tok[0];
        exit;
      end;
    end;
  finally
    lines.Free;
  end;
  ParseDialogs := true;
end;

end.
