unit maptext;

{** Parser for the human-authored text map format.

  Turns a .map text file into a TMapData record, which mapfmt then
  encodes to a lump. Used by the offline map compiler. The format is
  line based:

    map NAME
    size W H
    tileset N          (optional)
    music N            (optional)
    walls
    <H rows of W tile chars, '0' floor, '1'..'4' walls and doors>
    end
    marker NAME X Y DIR     (DIR is N E S W)
    portal X Y TARGET MARKER
    door X Y LOCKED KEY     (LOCKED is 0 or 1)

  Blank lines and lines starting with '#' are ignored. }

{$mode objfpc}{$H+}

interface

uses
  mapfmt;

function ParseMapText(const fn: string; out m: TMapData;
  out name: string; out errmsg: string): boolean;

implementation

uses
  classes, sysutils, worldarea, monsters, beings;

{ Map an element name to its EL_* flag, 0 if unknown or omitted. }
function ElemFlag(const t: string): byte;
begin
  if t = 'fire' then ElemFlag := EL_FIRE
  else if t = 'frost' then ElemFlag := EL_FROST
  else if t = 'shock' then ElemFlag := EL_SHOCK
  else if t = 'holy' then ElemFlag := EL_HOLY
  else if t = 'phys' then ElemFlag := EL_PHYS
  else ElemFlag := 0;
end;

function DirCode(const s: string): byte;
begin
  if (s = 'N') or (s = 'n') then DirCode := DIR_N
  else if (s = 'E') or (s = 'e') then DirCode := DIR_E
  else if (s = 'S') or (s = 's') then DirCode := DIR_S
  else DirCode := DIR_W;
end;

procedure Split(const line: string; out tok: array of string; out ntok: longint);
var
  i, start, len: longint;
begin
  ntok := 0;
  len := Length(line);
  i := 1;
  while i <= len do begin
    while (i <= len) and (line[i] = ' ') do inc(i);
    if i > len then break;
    start := i;
    while (i <= len) and (line[i] <> ' ') do inc(i);
    if ntok <= High(tok) then begin
      tok[ntok] := Copy(line, start, i - start);
      inc(ntok);
    end;
  end;
end;

function ParseMapText(const fn: string; out m: TMapData;
  out name: string; out errmsg: string): boolean;
var
  lines: TStringList;
  li, ntok, row, x: longint;
  tok: array[0 .. 15] of string;
  line: string;
  inWalls: boolean;
  mk: TMarker;
  po: TPortal;
  dr: TDoorMeta;
  np: TNpc;
  tr: TTrap;
  lt: TLightTile;
  pr: TProp;
  lo: TLoot;
begin
  ParseMapText := false;
  errmsg := '';
  name := '';
  m.w := 0; m.h := 0; m.tileset := 0; m.music := 0; m.flags := 0; m.area := 0;
  m.walls := nil; m.markers := nil; m.portals := nil; m.doors := nil;
  m.npcs := nil; m.traps := nil; m.lights := nil; m.props := nil;
  m.loot := nil;
  inWalls := false;
  row := 0;

  lines := TStringList.Create;
  try
    lines.LoadFromFile(fn);
    for li := 0 to lines.Count - 1 do begin
      line := TrimRight(lines[li]);
      if inWalls then begin
        if (line = 'end') then begin
          inWalls := false;
          if row <> m.h then begin
            errmsg := 'wall row count does not match height';
            exit;
          end;
          continue;
        end;
        if row >= m.h then begin
          errmsg := 'too many wall rows';
          exit;
        end;
        if Length(line) < m.w then begin
          errmsg := 'wall row ' + IntToStr(row) + ' too short';
          exit;
        end;
        for x := 0 to m.w - 1 do
          m.walls[row * m.w + x] := byte(ord(line[x + 1]) - ord('0'));
        inc(row);
        continue;
      end;

      if (line = '') or (line[1] = '#') then
        continue;
      Split(line, tok, ntok);
      if ntok = 0 then
        continue;

      if tok[0] = 'map' then begin
        if ntok >= 2 then name := UpperCase(tok[1]);
      end else if tok[0] = 'size' then begin
        if ntok < 3 then begin errmsg := 'size needs W H'; exit; end;
        m.w := StrToInt(tok[1]);
        m.h := StrToInt(tok[2]);
        SetLength(m.walls, m.w * m.h);
      end else if tok[0] = 'tileset' then
        m.tileset := StrToInt(tok[1])
      else if tok[0] = 'music' then
        m.music := StrToInt(tok[1])
      else if tok[0] = 'walls' then begin
        if m.w = 0 then begin errmsg := 'walls before size'; exit; end;
        inWalls := true;
        row := 0;
      end else if tok[0] = 'marker' then begin
        if ntok < 5 then begin errmsg := 'marker needs NAME X Y DIR'; exit; end;
        mk.name := tok[1];
        mk.x := StrToInt(tok[2]);
        mk.y := StrToInt(tok[3]);
        mk.dir := DirCode(tok[4]);
        SetLength(m.markers, Length(m.markers) + 1);
        m.markers[High(m.markers)] := mk;
      end else if tok[0] = 'portal' then begin
        if ntok < 5 then begin errmsg := 'portal needs X Y TARGET MARKER'; exit; end;
        po.x := StrToInt(tok[1]);
        po.y := StrToInt(tok[2]);
        po.target := tok[3];
        po.marker := tok[4];
        po.kind := PK_FLAT;
        if ntok >= 6 then begin
          if tok[5] = 'down' then po.kind := PK_DOWN
          else if tok[5] = 'up' then po.kind := PK_UP
          else if tok[5] = 'cave' then po.kind := PK_CAVE
          else if tok[5] = 'ladder' then po.kind := PK_LADDER
          else if tok[5] = 'shaft' then po.kind := PK_SHAFT
          else if tok[5] = 'door' then po.kind := PK_DOOR;
        end;
        SetLength(m.portals, Length(m.portals) + 1);
        m.portals[High(m.portals)] := po;
      end else if tok[0] = 'door' then begin
        if ntok < 4 then begin errmsg := 'door needs X Y LOCKED [KEY]'; exit; end;
        dr.x := StrToInt(tok[1]);
        dr.y := StrToInt(tok[2]);
        dr.locked := StrToInt(tok[3]);
        if ntok >= 5 then dr.key := tok[4] else dr.key := '';
        SetLength(m.doors, Length(m.doors) + 1);
        m.doors[High(m.doors)] := dr;
      end else if tok[0] = 'npc' then begin
        if ntok < 5 then begin errmsg := 'npc needs X Y DIALOG NAME [SPRITE] [GENDER]'; exit; end;
        np.x := StrToInt(tok[1]);
        np.y := StrToInt(tok[2]);
        np.dialog := tok[3];
        np.name := tok[4];
        if ntok >= 6 then np.sprite := tok[5] else np.sprite := '';
        if ntok >= 7 then np.gender := GenderFromStr(tok[6]) else np.gender := GenderUnspecified;
        SetLength(m.npcs, Length(m.npcs) + 1);
        m.npcs[High(m.npcs)] := np;
      end else if tok[0] = 'trap' then begin
        if ntok < 5 then begin errmsg := 'trap needs X Y DMG DC [ELEM]'; exit; end;
        tr.x := StrToInt(tok[1]);
        tr.y := StrToInt(tok[2]);
        tr.dmg := StrToInt(tok[3]);
        tr.dc := StrToInt(tok[4]);
        if ntok >= 6 then tr.element := ElemFlag(tok[5]) else tr.element := 0;
        SetLength(m.traps, Length(m.traps) + 1);
        m.traps[High(m.traps)] := tr;
      end else if tok[0] = 'surface' then
        m.flags := m.flags or MAP_SURFACE
      else if tok[0] = 'area' then begin
        if ntok < 2 then begin errmsg := 'area needs a name'; exit; end;
        m.area := AreaMaskByName(tok[1]);
        if m.area = 0 then begin
          errmsg := 'unknown area: ' + tok[1]; exit;
        end;
      end
      else if (tok[0] = 'skylight') or (tok[0] = 'moonwell')
        or (tok[0] = 'biolume') or (tok[0] = 'gasvent') or (tok[0] = 'brazier')
        or (tok[0] = 'torch') or (tok[0] = 'bonfire') then begin
        if ntok < 3 then begin errmsg := tok[0] + ' needs X Y'; exit; end;
        lt.x := StrToInt(tok[1]);
        lt.y := StrToInt(tok[2]);
        if tok[0] = 'moonwell' then lt.kind := LIGHT_MOONWELL
        else if tok[0] = 'biolume' then lt.kind := LIGHT_BIOLUME
        else if tok[0] = 'gasvent' then lt.kind := LIGHT_GASVENT
        else if tok[0] = 'brazier' then lt.kind := LIGHT_BRAZIER
        else if tok[0] = 'torch' then lt.kind := LIGHT_TORCH
        else if tok[0] = 'bonfire' then lt.kind := LIGHT_BONFIRE
        else lt.kind := LIGHT_SKYLIGHT;
        SetLength(m.lights, Length(m.lights) + 1);
        m.lights[High(m.lights)] := lt;
      end else if tok[0] = 'loot' then begin
        if ntok < 4 then begin errmsg := 'loot needs X Y GOLD [ITEM QTY]'; exit; end;
        lo.x := StrToInt(tok[1]);
        lo.y := StrToInt(tok[2]);
        lo.gold := StrToInt(tok[3]);
        if ntok >= 6 then begin
          lo.item := UpperCase(tok[4]);
          lo.qty := StrToInt(tok[5]);
        end else begin
          lo.item := '';
          lo.qty := 0;
        end;
        SetLength(m.loot, Length(m.loot) + 1);
        m.loot[High(m.loot)] := lo;
      end else if tok[0] = 'prop' then begin
        if ntok < 4 then begin errmsg := 'prop needs X Y NAME [yawDeg]'; exit; end;
        pr.x := StrToInt(tok[1]);
        pr.y := StrToInt(tok[2]);
        pr.name := UpperCase(tok[3]);
        if ntok >= 5 then
          pr.yaw := (StrToInt(tok[4]) * 256 div 360) and $FF
        else
          pr.yaw := 0;
        SetLength(m.props, Length(m.props) + 1);
        m.props[High(m.props)] := pr;
      end else begin
        errmsg := 'unknown directive: ' + tok[0];
        exit;
      end;
    end;
  finally
    lines.Free;
  end;

  if m.w = 0 then begin errmsg := 'no size'; exit; end;
  if inWalls then begin errmsg := 'walls not terminated by end'; exit; end;
  ParseMapText := true;
end;

end.
