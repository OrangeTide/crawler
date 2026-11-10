unit shopui;

{** The shop state: list the open vendor's stock from its data table, buy
  an item with party gold, and leave back to the dialog or exploration. }

{$mode objfpc}{$H+}

interface

procedure ShopRender;
procedure ShopKeyDown(scancode: longint);

implementation

uses
  sysutils, sdl2min, gfx, shops, items, party, dialog, audio, gamestate;

{ The number of items the open shop stocks, from its data list. }
function BuyableCount: longint;
var s: longint;
begin
  BuyableCount := 0;
  s := ShopIndex(shopStock);
  if s < 0 then exit;
  BuyableCount := Length(ShopDefs[s].items);
end;

{ The ItemDefs index of the idx-th item in the open shop's stock, or -1. }
function NthBuyable(idx: longint): longint;
var s: longint;
begin
  NthBuyable := -1;
  s := ShopIndex(shopStock);
  if s < 0 then exit;
  if (idx < 0) or (idx >= Length(ShopDefs[s].items)) then exit;
  NthBuyable := ItemIndex(ShopDefs[s].items[idx]);
end;

procedure ShopRender;
var
  i, cnt, di, y: longint;
  c: TColor;
begin
  ClearFB(RGB(12, 10, 14));
  if dlgNpcName <> '' then DrawText(12, 8, UpperCase(dlgNpcName), RGB(220, 200, 120))
  else DrawText(12, 8, 'SHOP', RGB(220, 200, 120));
  DrawText(FBW - 120, 8, 'GOLD ' + IntToStr(PartyGold), RGB(220, 200, 120));
  cnt := BuyableCount;
  y := 26;
  for i := 0 to cnt - 1 do begin
    di := NthBuyable(i);
    if di < 0 then continue;      { an item id the table does not know }
    if i = shopSel then begin
      c := RGB(240, 230, 150);
      DrawText(10, y, '>', c);
    end else
      c := RGB(180, 180, 160);
    DrawText(18, y, ItemDefs[di].name, c);
    DrawText(180, y, IntToStr(ItemDefs[di].value) + ' GP', c);
    inc(y, 11);
    if y > FBH - 24 then break;
  end;
  DrawText(12, FBH - 14, 'ARROWS SELECT  ENTER BUY  ESC LEAVE', RGB(140, 150, 120));
end;

procedure ShopKeyDown(scancode: longint);
var
  cnt, di: longint;
begin
  cnt := BuyableCount;
  case scancode of
    SDL_SCANCODE_UP:   if shopSel > 0 then dec(shopSel);
    SDL_SCANCODE_DOWN: if shopSel < cnt - 1 then inc(shopSel);
    SDL_SCANCODE_RETURN, SDL_SCANCODE_SPACE: begin
      di := NthBuyable(shopSel);
      if (di >= 0) and (PartyGold >= ItemDefs[di].value) and (Length(Roster) > 0) then
      begin
        PartyGold := PartyGold - ItemDefs[di].value;
        PackAdd(Roster[0], ItemDefs[di].id, 1);
        PlaySfx(SFX_PICK);
      end;
    end;
    SDL_SCANCODE_ESCAPE: begin
      DlgShopReq := false;
      if DlgActive then State := gsDialog else State := gsExplore;
    end;
  end;
end;

end.
