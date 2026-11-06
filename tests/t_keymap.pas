program t_keymap;

{** Key bindings: defaults, action/key lookup, name helpers, and that a
  rebind swaps a clashing action rather than leaving it unbound. }

{$mode objfpc}{$H+}

uses
  sysutils, sdl2min, keymap, testing;

begin
  KeyBindDefaults;
  CheckEqI(KeyBind[gaForward], SDL_SCANCODE_W, 'forward defaults to W');
  CheckEqI(KeyBind[gaStrafeR], SDL_SCANCODE_D, 'strafe right defaults to D');

  { lookup both ways }
  CheckEqI(ActionForKey(SDL_SCANCODE_W), ord(gaForward), 'W maps to forward');
  CheckEqI(ActionForKey(SDL_SCANCODE_SPACE), ord(gaInteract),
    'space maps to interact');
  CheckEqI(ActionForKey(SDL_SCANCODE_F5), -1, 'an unbound key maps to nothing');
  CheckEqI(ActionById('turnl'), ord(gaTurnL), 'id turnl resolves');
  CheckEqI(ActionById('nope'), -1, 'an unknown id resolves to nothing');

  { key names for display }
  Check(KeyName(SDL_SCANCODE_W) = 'W', 'W names itself');
  Check(KeyName(SDL_SCANCODE_SPACE) = 'SPACE', 'space is named');
  Check(KeyName(SDL_SCANCODE_TAB) = 'TAB', 'tab is named');

  { rebind to a free key: just moves }
  KeyBindDefaults;
  RebindKey(gaInteract, SDL_SCANCODE_F);
  CheckEqI(KeyBind[gaInteract], SDL_SCANCODE_F, 'interact rebinds to a free key');
  CheckEqI(ActionForKey(SDL_SCANCODE_SPACE), -1, 'its old key is now free');

  { rebind onto a key another action holds: the two swap }
  KeyBindDefaults;
  RebindKey(gaForward, SDL_SCANCODE_S);   { S currently belongs to back }
  CheckEqI(KeyBind[gaForward], SDL_SCANCODE_S, 'forward takes the S key');
  CheckEqI(KeyBind[gaBack], SDL_SCANCODE_W, 'back takes forward''s old W key');
  CheckEqI(ActionForKey(SDL_SCANCODE_W), ord(gaBack), 'no key is left doubled');

  TestSummary('keymap');
  halt(TestExit);
end.
