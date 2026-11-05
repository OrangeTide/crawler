unit dialog;

{** Conversation data and runtime, Ultima Underworld style.

  A conversation is a graph of nodes. Each node has a line of NPC text
  and a list of player responses; a response moves to another node, ends
  the talk, opens a shop or sets a story flag. Conversations are authored
  as text, compiled into a DLGS lump and decoded here. The record types
  and the decoder live together so the tool and runtime agree.

  DLGS layout:
    magic 'DLGS' u32, convCount u16
    conv: name[12], nodeCount u16, nodes...
    node: textLen u16, text, respCount u8, responses...
    resp: textLen u16, text, action u8, gotoNode i16, arg[12] }

{$mode objfpc}{$H+}

interface

uses
  pak;

const
  DLGS_MAGIC = $53474C44;  { 'DLGS' }

  DA_GOTO    = 0;
  DA_END     = 1;
  DA_SHOP    = 2;
  DA_SETFLAG = 3;

type
  TResponse = record
    text: string;
    action: byte;
    gotoNode: longint;
    arg: string[12];
    condFlag: string[12];   { shown only if this flag is set, or empty }
  end;

  TNode = record
    text: string;
    resp: array of TResponse;
  end;

  TConversation = record
    name: string[12];
    nodes: array of TNode;
  end;

var
  Convs: array of TConversation;

  { active conversation runtime }
  DlgActive: boolean;
  DlgConv: longint;
  DlgNode: longint;
  DlgShopReq: boolean;    { set when a response opened a shop }

function EncodeDialogs(const cs: array of TConversation): TByteArray;
function LoadDialogs(const p: TPak): boolean;
function ConvIndex(const name: string): boolean;
procedure DialogStart(const name: string);
function DialogRespCount: longint;
function DialogRespText(i: longint): string;
procedure DialogChoose(i: longint);   { may set DlgShopReq or end }

implementation

uses
  flags;

{ ---- encode (used by the tool) ---- }

procedure PutB(var a: TByteArray; var n: longint; v: byte);
begin
  if n >= Length(a) then SetLength(a, (n + 1) * 2);
  a[n] := v; inc(n);
end;

procedure PutU16(var a: TByteArray; var n: longint; v: word);
begin
  PutB(a, n, v and $FF); PutB(a, n, (v shr 8) and $FF);
end;

procedure PutStr(var a: TByteArray; var n: longint; const s: string);
var i: longint;
begin
  PutU16(a, n, Length(s));
  for i := 1 to Length(s) do PutB(a, n, ord(s[i]));
end;

procedure PutFixed(var a: TByteArray; var n: longint; const s: string; len: longint);
var i: longint;
begin
  for i := 1 to len do
    if i <= Length(s) then PutB(a, n, ord(s[i])) else PutB(a, n, 0);
end;

function EncodeDialogs(const cs: array of TConversation): TByteArray;
var
  a: TByteArray;
  n, ci, ni, ri: longint;
begin
  SetLength(a, 0); n := 0;
  PutU16(a, n, DLGS_MAGIC and $FFFF);
  PutU16(a, n, (DLGS_MAGIC shr 16) and $FFFF);
  PutU16(a, n, Length(cs));
  for ci := 0 to High(cs) do begin
    PutFixed(a, n, cs[ci].name, 12);
    PutU16(a, n, Length(cs[ci].nodes));
    for ni := 0 to High(cs[ci].nodes) do begin
      PutStr(a, n, cs[ci].nodes[ni].text);
      PutB(a, n, Length(cs[ci].nodes[ni].resp));
      for ri := 0 to High(cs[ci].nodes[ni].resp) do begin
        PutStr(a, n, cs[ci].nodes[ni].resp[ri].text);
        PutB(a, n, cs[ci].nodes[ni].resp[ri].action);
        PutU16(a, n, word(cs[ci].nodes[ni].resp[ri].gotoNode));
        PutFixed(a, n, cs[ci].nodes[ni].resp[ri].arg, 12);
        PutFixed(a, n, cs[ci].nodes[ni].resp[ri].condFlag, 12);
      end;
    end;
  end;
  SetLength(a, n);
  EncodeDialogs := a;
end;

{ ---- decode ---- }

var
  rp: longint;
  rd: TByteArray;

function RB: byte;
begin
  if rp < Length(rd) then begin RB := rd[rp]; inc(rp); end else RB := 0;
end;

function RU16: word;
var lo, hi: byte;
begin lo := RB; hi := RB; RU16 := lo or (hi shl 8); end;

function RStr: string;
var len, i: longint; s: string;
begin
  len := RU16; s := '';
  for i := 1 to len do s := s + chr(RB);
  RStr := s;
end;

function RFixed(len: longint): string;
var i: longint; s: string; b: byte;
begin
  s := '';
  for i := 1 to len do begin b := RB; if b <> 0 then s := s + chr(b); end;
  RFixed := s;
end;

function LoadDialogs(const p: TPak): boolean;
var
  convCount, ci, ni, ri, nodeCount, respCount: longint;
  magicLo, magicHi: word;
begin
  LoadDialogs := false;
  Convs := nil;
  DlgActive := false;
  if not PakGet(p, 'DLGS', rd) then exit;
  rp := 0;
  magicLo := RU16; magicHi := RU16;
  if (magicLo or (magicHi shl 16)) <> DLGS_MAGIC then exit;
  convCount := RU16;
  SetLength(Convs, convCount);
  for ci := 0 to convCount - 1 do begin
    Convs[ci].name := RFixed(12);
    nodeCount := RU16;
    SetLength(Convs[ci].nodes, nodeCount);
    for ni := 0 to nodeCount - 1 do begin
      Convs[ci].nodes[ni].text := RStr;
      respCount := RB;
      SetLength(Convs[ci].nodes[ni].resp, respCount);
      for ri := 0 to respCount - 1 do begin
        Convs[ci].nodes[ni].resp[ri].text := RStr;
        Convs[ci].nodes[ni].resp[ri].action := RB;
        Convs[ci].nodes[ni].resp[ri].gotoNode := smallint(RU16);
        Convs[ci].nodes[ni].resp[ri].arg := RFixed(12);
        Convs[ci].nodes[ni].resp[ri].condFlag := RFixed(12);
      end;
    end;
  end;
  LoadDialogs := true;
end;

var
  foundIdx: longint;
  DlgVisible: array of longint;   { indices of responses shown at DlgNode }

procedure RecomputeVisible;
var
  i: longint;
begin
  SetLength(DlgVisible, 0);
  if not DlgActive then exit;
  for i := 0 to High(Convs[DlgConv].nodes[DlgNode].resp) do
    with Convs[DlgConv].nodes[DlgNode].resp[i] do
      if (condFlag = '') or FlagHas(condFlag) then begin
        SetLength(DlgVisible, Length(DlgVisible) + 1);
        DlgVisible[High(DlgVisible)] := i;
      end;
end;

function ConvIndex(const name: string): boolean;
var i: longint;
begin
  foundIdx := -1;
  for i := 0 to High(Convs) do
    if Convs[i].name = name then begin foundIdx := i; ConvIndex := true; exit; end;
  ConvIndex := false;
end;

procedure DialogStart(const name: string);
begin
  DlgShopReq := false;
  if not ConvIndex(name) then begin
    DlgActive := false;
    exit;
  end;
  DlgConv := foundIdx;
  DlgNode := 0;
  DlgActive := true;
  RecomputeVisible;
end;

function DialogRespCount: longint;
begin
  DialogRespCount := Length(DlgVisible);
end;

function DialogRespText(i: longint): string;
begin
  DialogRespText := Convs[DlgConv].nodes[DlgNode].resp[DlgVisible[i]].text;
end;

procedure DialogChoose(i: longint);
var
  r: TResponse;
begin
  if (not DlgActive) or (i < 0) or (i >= DialogRespCount) then exit;
  r := Convs[DlgConv].nodes[DlgNode].resp[DlgVisible[i]];
  case r.action of
    DA_SETFLAG: FlagSet(r.arg);
    DA_SHOP:    DlgShopReq := true;
    DA_END: begin DlgActive := false; exit; end;
  end;
  if r.action = DA_END then
    DlgActive := false
  else if (r.gotoNode >= 0) and (r.gotoNode < Length(Convs[DlgConv].nodes)) then begin
    DlgNode := r.gotoNode;
    RecomputeVisible;
  end else
    DlgActive := false;
end;

end.
