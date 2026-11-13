# Crawler: Expanded Edition Design

This document is the design for turning the current raycasting tech demo into a
complete dungeon crawler RPG. It covers the systems requested plus the pieces a
finished game needs around them. It is a plan, not an implementation. Code is
written in Free Pascal (OBJFPC mode) to match the existing engine, and the
offline tools share the engine's file-format units so there is no second
language to maintain.

The combat and character rules follow AX&X (https://orangetide.github.io/axx-rpg/),
which is released under CC0. We can embed and adapt its tables freely.

## 1. Goals and constraints

- Keep the 320x240 software framebuffer and the raycasting renderer. Everything
  new draws into the same buffer or the same tile world.
- Fit a complete game into a 10 MB zip. This is the hard budget that drives
  every asset decision (see section 15).
- All game content lives in files, loaded at runtime. Nothing that a designer
  would want to change stays hardcoded.
- Custom binary formats where they keep the runtime simple. Human-authored
  source is plain text or a trivial format (PPM), and offline tools compile it
  to the runtime formats.
- Deterministic where it matters. Dynamic maps are reproducible from a seed so a
  save only needs to store the seed plus the player's changes.
- Linux and SDL2 are the prototype. The shipping targets are MS-DOS on 32-bit
  i386 protected mode and the PlayStation 1, both without a usable FPU and the
  PS1 with only 2 MB of main RAM. The design holds to those limits as it grows,
  which means fixed-point math and a capped resident memory set (see section 23).

## 2. From demo to game: module layout

The current build has six units. The expanded edition keeps them and adds
focused units so no single file carries unrelated concerns. Proposed layout:

| Unit | Role | State |
|------|------|-------|
| `sdl2min` | SDL2 runtime binding | keep, add audio imports |
| `gfx` | framebuffer, primitives, font | keep, add blits and alpha |
| `pak` | read-only archive reader | new |
| `pic` | indexed-RLE image codec (textures and sprites) | new |
| `texcache` | replaces `textures`, loads from `pic` lumps | new |
| `rng` | deterministic xorshift PRNG, named streams | new |
| `mapfmt` | map record types and binary load | new |
| `mapgen` | roguelike generation from seed | new |
| `world` | active map grid, camera, collision, movement | keep, extend |
| `raycast` | textured wall/floor/ceiling cast | keep, add sprite cast |
| `entities` | monsters, NPCs, items on the ground, doors | new |
| `rules` | AX&X dice, checks, saves, attack, damage | new |
| `party` | characters, attributes, classes, HP, XP | new |
| `items` | item database and item instances | new |
| `inventory` | per-character and party inventory, equip | new |
| `combat` | turn and round state machine | new |
| `dialog` | text conversation runtime | new |
| `automap` | fog of war, HUD minimap, fullscreen map | new |
| `audio` | software mixer, SFX, module music | new |
| `ui` | menus, title screen, character creation | new |
| `save` | save and load of the whole game state | new |
| `hud` | in-world overlay (reduced, see section 8) | keep, shrink |
| `game` | top-level state machine, main loop glue | new |

`game` owns a small state enum and routes input and rendering:

```
TGameState = (gsTitle, gsNewParty, gsExplore, gsCombat,
              gsDialog, gsFullMap, gsInventory, gsMenu, gsGameOver);
```

Each state has `Update(dt)`, `Render`, and `HandleKey`. The explore state is the
existing free-walk loop; the others are new. `crawler.lpr` shrinks to window
setup plus `GameRun`.

## 3. Turn-based grid movement with free look

The request is to move on the grid in discrete turns while still allowing free
look. We split facing from view.

- **Facing** is one of four cardinal directions. Movement is tile-stepped:
  forward, back, strafe left, strafe right move exactly one tile; turn left and
  turn right rotate facing 90 degrees. A step is rejected if the target tile
  blocks.
- **Animation** tweens the camera between the old and new tile over about 120 ms
  (ease-out), and tweens a 90 degree turn similarly, so the grid motion still
  reads as smooth rather than teleporting. Input is ignored while a step tweens,
  which gives the deliberate step-and-turn cadence of the DOS crawlers.
- **Free look** is a view offset layered on top of facing. The mouse adds a yaw
  offset (clamped to about +/- 50 degrees so you cannot see behind your own
  facing) and a pitch offset (the existing pitch, clamped). Releasing look
  (or pressing a recenter key) eases the offset back to zero. So the player
  stands on a tile facing north and can still glance around the room.
- **Turn economy in combat.** Outside combat, steps are free and only gated by
  the tween. Inside combat (section 5) a step or an action consumes the
  character's turn, so the same movement code is reused with a per-turn budget.

`TCamera` gains `faceDir: 0..3`, `tweenT: double`, and `yawOffset: double`.
The renderer builds the effective direction and plane each frame from
`faceDir` plus the tween and the yaw offset, so `raycast` does not change.

### Mouse interaction (point and click)

The DOS crawlers were point-and-click: you moved a cursor over the scene and
clicked objects to look at them, use them, pick them up or attack. The engine
keeps a virtual cursor driven by relative mouse motion, drawn over the view.

- **Left click** interacts with whatever is under the cursor. A ray is cast
  from the cursor's screen column into the world; the first thing it meets
  decides the verb: a door opens or closes, an item is picked up, a container
  opens, an NPC starts a conversation, and in combat an enemy is attacked. Out
  of reach, the click just examines (prints a line of description text).
- **Right button held** is free look: mouse motion swings the view (yaw and
  pitch) instead of moving the cursor, and the view eases back to the facing
  when released. So the cursor is for clicking and the right button is for
  glancing around, and neither changes which way the party faces on the grid.
- **The HUD is clickable** too: the minimap, the party portraits and, later,
  inventory and spell slots respond to the same cursor.

Keyboard still drives grid movement and the common actions, so the game is
fully playable without the mouse. The cursor and click verbs are an addition,
not a replacement.

## 4. Characters, classes, and party

Up to four characters in the party, matching the AX&X worksheet layout. The
party moves as one body in the dungeon (single camera), which is standard for
grid crawlers and keeps the renderer unchanged.

### Attributes

Six scores as in AX&X: STR, DEX, CON, INT, WIS, CHA. Modifier table:

| Score | 3 | 4-5 | 6-8 | 9-12 | 13-15 | 16-17 | 18 |
|-------|---|-----|-----|------|-------|-------|----|
| Mod   | -3| -2  | -1  | 0    | +1    | +2    | +3 |

### Classes (AX&X)

| Class | Track | Hit Die | Save boon | Notes |
|-------|-------|---------|-----------|-------|
| Fighter | Warrior | d8 | +2 Body | any weapon and armor |
| Barbarian | Warrior | d10 | +2 vs magic | no heavy armor, faster on foot |
| Ranger | Warrior | d8 | +2 Body | hard to surprise |
| Cleric | Priest | d6 | +2 Will | blunt weapons, divine spells, turn undead |
| Thief | Specialist | d6 | +2 Dodge | stealth, locks, traps, backstab +4 and double damage |
| Magic-User | Mage | d4 | +2 vs magic | spellbook, no armor |

Attack bonus by track: Warrior +level; Priest and Specialist +ceil(level/2);
Mage +floor(level/2). Second attack at level 6, third at level 11 for Warriors.

### Character record

```
TAbilitySet = array[TAbility] of byte;   { STR..CHA, raw 3..18 }

TCharacter = record
  name:       string[15];
  kindred:    TKindred;      { Human, Dwarf, Elf, Halfling, HalfOrc }
  klass:      TClass;
  level:      byte;
  xp:         longint;
  abil:       TAbilitySet;
  hpMax, hp:  smallint;
  ac:         byte;          { derived, cached }
  slots:      array[TEquipSlot] of TItemRef;  { weapon, shield, armor, ... }
  pack:       TInventory;    { carried items, STR item-slot limit }
  spells:     TSpellSet;     { prepared slots for casters }
  status:     TStatusSet;    { poisoned, afraid, blessed, ... }
  portrait:   byte;          { index into a portrait sprite sheet }
end;
```

### Character creation (gsNewParty)

A guided flow, one character at a time, up to four:

1. Roll 3d6 in order for the six scores, with one re-roll of the whole set
   allowed (classic) and a swap-two option to keep it friendly.
2. Choose kindred (applies the Human +1 and 10% XP, darkvision, halfling reroll).
3. Choose class (validated against the rolled scores only softly; AX&X lets any
   kindred take any class).
4. Name and pick a portrait.
5. Take the class starting kit, or roll 3d6 x 10 GP and buy from the shop list.

Starting HP is max Hit Die + CON, per AX&X. The whole party can also be
auto-generated with a "quick start" button for players who want to dive in.

## 4b. Setting and system: species, classes, backgrounds

The character identity options are broader than the AX&X defaults and are
data-driven, not hardcoded. They live in `content/species.txt`,
`content/classes.txt` and `content/backgrounds.txt`, compiled into the pak and
loaded at startup, so the roster can grow without code changes. The mechanics
still run on the four AX&X tracks (Warrior, Priest, Specialist, Mage), so every
class is immediately playable; unique per-class features are future work layered
on top of the track.

### Species

Dwarf, elf, half-elf, gnome, halfling, half-orc, human, tiefling, dark elf,
Earthling human, tainted human, exotic human, primate (ape-folk), reptilian,
revenant (undead), winged folk, and witchling.

Each species row carries small ability adjustments, a flags byte (darkvision and
the like) and an XP bonus. Human keeps the AX&X +1 to a prime ability and the
10 percent XP bonus. The others get modest, editable traits.

### Classes

Every class maps to a track, a hit die and a prime ability. Grouping:

- **Warrior track:** fighter, berserker, knight, paladin, anti-paladin, ranger,
  templar, folk-champion, wild-brute, rifleman, sky-lord, eldritch-archer,
  warden, clansdwarf. Hit die d8, or d10 for the heavy brawlers (berserker,
  wild-brute, clansdwarf). Prime STR, or DEX for the archers (ranger,
  eldritch-archer, rifleman).
- **Priest track:** friar, mystic, templar-devout, gothi, occultist, savant.
  Hit die d6, prime WIS.
- **Specialist track:** thief, acrobat, assassin, bard, scout, trickster,
  psychic. Hit die d6, prime DEX.
- **Mage track:** wizard, warlock, wise-one, fae-mage, forestal, illusionist,
  necronimus. Hit die d4, prime INT.

Each class also names a starting-kit archetype (soldier, heavy, archer, priest,
thief or mage) so the kit grant stays data-driven.

### Backgrounds

A background is a pre-adventuring life. Each grants a narrow competence (a bonus
to a related check) and carries a complication the referee can lean on. The set:
apprentice smith, failed merchant, village healer's assistant, runaway serf,
disgraced soldier, itinerant peddler, temple acolyte, grave-digger, disowned
noble, hedge wizard's errand-runner, ship's galley hand, former poacher, failed
actor, courtier's servant, bandit's lookout, village reeve's deputy, failed
guild artisan, pilgrim, former smuggler, and discharged camp follower.

Each row names the skill or situation it helps (the benefit) and a short
complication line. Mechanically the benefit is a +2 to checks the referee rules
relevant; the full benefit and complication text lives in the content file.

## 5. Combat (AX&X rules)

Combat is turn-based on the same tile grid. When it starts, the game enters
`gsCombat`, the view stays first person, and enemies render as billboard
sprites (section 14). We implement the AX&X core fight loop plus the useful
parts of Combat & Tactics.

### Round structure

AX&X runs a round on four lines: initiative, an action, an attack roll, damage.

- **Initiative:** side-based, 1d6 per side, higher side acts first, ties act
  together. Store `partyInit`, `foeInit` per round.
- **A turn:** each combatant gets, on their side's step, one move and one
  action, or two moves. Actions: Attack, Cast, Aid (+2 to an ally), Withdraw
  (careful retreat, no free attack), Guard, Parry, or use an item.
- **Movement** uses range bands rather than free positioning, which fits a
  party-vs-group fight without a tactical map: engaged, near, far. A move shifts
  one band. Leaving "engaged" without Withdraw draws a free attack. This keeps
  combat readable in a first-person view where we do not show a battle grid.

### Resolution

- **Attack:** 1d20 + attack mod vs target AC. Attack mod = track bonus + STR
  (melee) or DEX (missile). Monsters attack at +HD.
- **Damage:** weapon die + STR for melee. Resistant halves, vulnerable doubles.
- **Critical (optional, on):** natural 20 deals max damage, doubled against a
  vulnerability.
- **AC:** base 10 or armor value, plus DEX bonus and shield. Shield applies only
  to faced foes and can be splintered to negate one hit.
- **Saves:** 1d20 + floor(level/2) + ability mod, target 12, or 10 + foe HD when
  a creature causes it. Body (CON), Dodge (DEX), Will (WIS).
- **Morale:** when a side is bloodied or its leader falls, 1d6 morale check; on a
  fail the enemy flees or surrenders. This ends fights early and is cheap.
- **Reactions:** 2d6 on first contact decides whether a group is hostile, wary,
  or open to parley, feeding the dialog system (section 9).
- **Brush with Death:** at 0 HP, roll 1d6 + prior brushes that day; 7+ is slain,
  otherwise a brush-with-death result (down but recoverable). Characters are not
  casually killed, which suits a four-person party.

### Tactical options worth including

Charge (+2 to hit, -2 AC), Parry (+2 AC, Fighter can instead cut a foe's
attacks), Gang Up (+2 per extra attacker, +2 and ignore shields from behind),
Set against a charge (spear/polearm strikes first for double), and the ranged
penalties (into melee -4, point blank +1, cover and concealment). These are all
flat modifiers, so they are cheap flags on the attack call.

### Spells and Turn Undead

Clerics and Magic-Users prepare spell slots. A small starting spellbook drawn
from the AX&X Spellbook supplement is enough for launch: Magic Missile, Light,
Sleep, Shield, Cure Light Wounds, Bless, Hold Person, Turn Undead. Spells are
data (section 13), so more can be added without code changes.

## 6. Items and inventory

- **Item database** is a file (section 13): id, name, kind (weapon, armor,
  shield, potion, scroll, key, light, treasure, quest), stats (damage die,
  AC, slots, value), sprite, and an effect script id.
- **Instances** carry only an item id plus state (charges, identified flag,
  quantity for stackables). This keeps save size small.
- **Carry limit** is STR item-slots per AX&X, with a shared party stash in town.
- **Equipment** slots per character: main hand, off hand (shield), armor, light
  source, and two trinket slots. Equipping recomputes AC and attack mods.
- **Ground items** are entities (section 14) you walk onto and pick up, or find
  in containers opened from the world.
- **Light** matters: a lit torch or lantern sets the fog radius and is a consumable
  resource, which ties the item system to exploration tension.

## 7. The world: multiple maps from files

The single hardcoded 24x24 grid is replaced by a world of named maps loaded on
demand.

- A **world manifest** (`world.txt`, compiled to a lump) lists every map, its
  kind (static file or dynamic generator), display name, music track, ambient
  light, texture set, and its edge or portal links to other maps.
- A **portal/transition** is a tile tagged with a target map id and target
  entry marker. Stepping on it (stairs, a town gate, a cave mouth) loads the
  target map and places the party at the named marker. This is how the six
  zones connect.
- Only one map is resident at a time. Loading a map deserializes its grid,
  entities, and triggers, and restores any saved changes and fog for that map
  from the save (section 11).

### Map format

Authored maps are a readable text format compiled by the `mapc` tool to a binary
lump. The text keeps the current grid feel but gains layers:

```
map crypt_entry
size 32 32
tileset crypt
music crypt_theme
light 0.35
layer walls
<32 rows of wall-tile chars, 0 = floor>
layer floor
<32 rows of floor-texture chars>
layer ceil
<32 rows of ceiling-texture chars>
marker start 2 2 east
portal 16 0 -> town_square gate_south
door 9 9 locked crypt_key
spawn skeleton 12 7
spawn skeleton 13 7
item torch 4 4
trigger 20 20 text "A cold draught rises from the pit."
region 0 0 31 15 "Upper Vault"
```

The compiled binary is a small header plus tightly packed layers and typed
record arrays, so the runtime loads it with block reads and no parsing.

## 8. HUD and maps: reduced overlay, fullscreen map, fog of war

Three related pieces.

### Reduced in-world HUD

The current automap fills a corner. Replace it with a small translucent minimap
(about 56x56 px) in a corner, alpha-blended over the 3D view so it does not block
the scene. It shows only the fog-revealed tiles near the party, the party marker,
and known doors and stairs. The compass and a compact party status strip (four
portraits with HP pips) occupy a thin translucent band. `gfx` gains an alpha
blit so overlays blend rather than overwrite.

### Fullscreen map (gsFullMap)

Pressing Tab (or M) replaces the 3D view entirely with a full-screen top-down
map of the current zone. It draws at a larger tile scale, pans and is scrollable
on big maps, labels known regions, and marks portals, locked doors, and notes
the player has picked up. It respects fog of war. Escape or Tab returns to
explore.

### Fog of war

Per map, three visibility states per tile stored in the save:

- **Unseen:** never revealed; drawn black on both maps.
- **Remembered:** seen before but not currently in line of sight; drawn dim, from
  memory. Entities are not shown here (you remember the room, not the monster).
- **Visible:** currently in line of sight and within the light radius; drawn lit,
  entities shown.

Visibility is a cheap LOS check from the party tile out to the current light
radius (reuse the DDA from the raycaster, stop at walls). Revealed tiles are
OR-ed into the map's "seen" bitmask. The bitmask is 1 bit per tile per state, so
a 64x64 map costs a few hundred bytes to store.

## 9. Text dialog, Ultima Underworld style

A keyword and menu conversation runtime, which is the DOS-crawler idiom.

- When you talk to an NPC (or a wary group passes its reaction check), the game
  enters `gsDialog`. The 3D view dims and a framed text panel takes the lower
  portion of the screen, with the NPC portrait at the side.
- **Conversation data** is a node graph in a file (section 13): each node has
  NPC text and a list of player responses. A response can set a flag, check a
  flag or an item or a stat (a CHA parley check, say), give or take an item or
  gold, open a shop, start combat, or jump to another node. This covers
  merchants, quest givers, locked doors that respond to a password, and lore.
- **Barks and prompts** reuse the same panel for one-off world text from map
  triggers ("A cold draught rises from the pit.") and for examine text on items.
- Text uses the existing bitmap font, extended to a full printable ASCII set and
  with word-wrap and a typewriter reveal for flavor.

Conversations reference flags in the save's global flag store, so quests persist.

## 10. Rogue-like generation for dynamic maps

Some zones (cave, parts of the crypt and the infernal zone) are generated rather
than authored, for replay variety.

- The world manifest marks a map as dynamic and gives it a generator kind
  (rooms-and-corridors, cave via cellular automata, or a maze) and a difficulty
  band.
- Generation is fully determined by `(generatorVersion, seed)`. `rng` provides a
  named, seeded stream so generation never touches the global PRNG used for
  combat.
- The first time the party enters a dynamic map, the game draws a fresh seed and
  records `(version, seed)` for that map slot in the save. Re-entering regenerates
  the identical layout from that pair, then overlays the saved changes and fog
  for that slot. So a dynamic level is persistent across visits without storing
  its whole grid: the save holds only version, seed, the fog bitmask, and the
  diff of what the party changed (opened doors, taken items, killed spawns).
- `generatorVersion` guards against engine updates: if the generator changes, old
  saves either keep their stored grid (fallback: store the grid) or regenerate
  with a compatibility note. The simplest safe rule is to bump the version and,
  on mismatch, fall back to storing the generated grid in that save slot.

## 11. Save and load

A single save slot format that captures the whole game, plus a title-screen
slot picker for several saves.

Save contents:

- Header: magic, format version, timestamp, play time, party summary for the
  slot list (names, levels, current zone).
- Party: each character's full record (section 4), prepared spells, status.
- Party stash and gold.
- Global flags (quest and dialog state) and the journal (section 16).
- Current map id and party position and facing.
- Per visited map, a **map-state block**:
  - for static maps: fog bitmask plus a diff of changed tiles, opened or unlocked
    doors, removed ground items, and defeated spawns.
  - for dynamic maps: `(generatorVersion, seed)` plus the same fog and diff, or a
    stored grid if the version no longer matches.

The format is a tagged chunk file (a four-byte tag, a length, then the payload
per block) so the loader can skip unknown blocks and older saves can be migrated
by format version. Visited-area persistence falls directly out of the per-map
fog bitmask being part of every map-state block.

Autosave on zone transition and a manual save from the menu. No save during
combat (standard, avoids mid-round corruption).

## 12. Audio: sound effects and music channels

The engine currently dlopens only SDL2 video. We add SDL2 audio and a small
software mixer so we do not depend on SDL_mixer.

- **Mixer:** one SDL audio callback pulls from a fixed set of channels (say 8
  SFX channels plus the music renderer), mixes to 16-bit stereo at 22050 or
  44100 Hz. Channels have volume and pan. A master, music, and SFX volume live in
  settings.
- **Sound effects** are short PCM clips loaded from lumps. To fit the budget they
  are mono, low rate, and either raw or a trivial ADPCM. Triggered by id from
  combat, doors, pickups, UI, and foot-steps.
- **Music** uses a tracker module player. MOD (and optionally XM) files are tiny
  (tens of KB for a full track) because they store instrument samples plus a
  pattern sequence, which is exactly how DOS-era games hit small sizes. We write
  a compact MOD player that renders into the music channel. One track per zone
  plus a title theme and a combat sting.
- Playback is non-blocking and ducks music under important stings.

If writing a module player is judged too large for a first pass, the fallback is
a very small custom sequence format (note events plus a few synth instruments
rendered in software), which is even smaller but less rich. MOD is the
recommended target.

## 13. Custom file formats

All runtime data ships inside one archive and uses simple binary layouts.

### PAK archive

A Doom-style pack keeps the zip tidy and loads fast:

```
PAK header:  magic 'CPAK', version u16, lumpCount u16, dirOffset u32
Directory:   lumpCount entries of { name[16], offset u32, size u32 }
Data:        the lump bytes
```

The runtime memory-maps or reads the directory once and fetches lumps by name.
Everything below is a lump inside the PAK.

### PIC images (textures, sprites, portraits)

Indexed color with a shared or per-image palette, RLE compressed, which suits
the 64x64 textures and small sprites and decodes straight into the framebuffer:

```
PIC header:  magic 'CPIC', width u16, height u16, flags u8 (0=opaque,1=alpha key),
             paletteId u8
Data:        RLE runs over palette indices; index 0 is the transparent key
```

Sprite sheets are a PIC plus a small frame table (grid cell size and count) so
monster animations and the font come from one lump each.

### Maps

Binary compiled from the text map (section 7): header (size, tileset id, music
id, light, counts), then the wall, floor, and ceiling layers as byte planes,
then packed arrays of markers, portals, doors, spawns, items, triggers, and
regions.

### Items, spells, monsters, tilesets

Small typed-record tables, one lump each, authored as readable text and compiled
to fixed-size record arrays. For example the monster table row carries HD, AC,
attack, damage, saves, morale, speed, sprite id, loot table id, and resistances,
which is all `combat` needs.

### Dialog

A node table: per node an NPC-text string id and an array of responses, each
with a condition, an effect, and a next-node id. Strings live in a string lump
so they are shared and localizable later.

### Save

The tagged-chunk file of section 11. It is the only format written at runtime, so
it does not go in the PAK.

## 14. Sprites and textures from files

- `texcache` loads wall, floor, and ceiling textures from PIC lumps named by the
  tileset. The current procedural generators move into the `picc` tool so the
  same art can ship as files, which also lets an artist replace them.
- `raycast` gains **billboard sprite casting**: after the wall pass, visible
  entities (monsters, NPCs, ground items, decorations) are sorted back to front
  by distance and drawn as camera-facing sprites with the same per-column depth
  buffer the walls fill, so they occlude correctly behind walls and fog them with
  distance.
- Entity sprites, portraits, and UI art are all PIC lumps, so adding a monster is
  adding a sprite and a monster-table row, no code.

## 15. Fitting a 10 MB zip

The budget is comfortable if we keep to the retro constraints, and it is the
reason for the format choices above.

- Textures and sprites are indexed and RLE-compressed at small sizes. A full set
  of tileset textures and a few dozen monster and item sprites is well under
  1 MB.
- Music as MOD modules: six zone themes plus a title and combat track at tens of
  KB each is a few hundred KB.
- Sound effects are short, mono, low rate: another few hundred KB.
- Maps, tables, and dialog are tiny (KB each).
- The FPC binary is a couple of MB, and the SDL2 runtime is not bundled (loaded
  from the system, as today), which keeps the download small on Linux. For
  Windows and Mac the SDL2 DLL does count against the budget, so note the
  per-platform zip differs.

A rough tally: binary ~3 MB, assets ~2 MB, leaving generous headroom inside
10 MB. The PAK plus the binary is the whole game.

## 16. What else a full game needs

Beyond the requested list, these make it feel complete rather than a systems
demo. They are ordered roughly by value.

1. **A quest and journal system.** Global flags already back dialog; add a
   journal screen that logs active and finished quests and key clues. Without it,
   a multi-zone game is easy to get lost in. Small to build on the flag store.
2. **Rest, camp, and recovery.** Resting to recover HP and re-prepare spells,
   with a wandering-monster check (AX&X 1 in 6) and light and food as the cost.
   This paces the dungeon and gives light and rations a purpose.
3. **Shops and economy.** A merchant dialog mode to buy and sell against the item
   database, plus the AX&X "1 GP to town = 1 XP" loop, which is the core reward
   that ties exploration to advancement.
4. **A town hub.** The starting town is also the services hub: shop, temple
   (healing and cure status, raise from a brush with death), tavern (rumors and
   hirelings), and the party stash. It anchors the loop between dungeon runs.
5. **Traps and locks.** Thief class checks to find and disarm traps and pick
   locks, Dodge saves to avoid sprung traps, keys for locked doors. This gives
   the Thief a job and makes the map tactical.
6. **Status effects and conditions.** Poison, disease, fear, paralysis, blindness
   in dim light, encumbrance. Mostly flat modifiers and save hooks, reusing the
   save system already specified.
7. **NPC followers and hirelings.** CHA-driven hirelings from the tavern expand a
   thin party and fit AX&X. They can share the party structure with a flag that
   marks them temporary.
8. **Difficulty and accessibility options.** Toggle for permadeath vs revive at
   the temple, combat speed, text speed, and the optional AX&X rules (natural
   20/1, criticals). Cheap and widens the audience.
9. **Minimap notes and auto-notes.** Let the player drop a pin or note on the
   fullscreen map. Pairs with the journal.
10. **An ending and a critical path.** A main quest that threads the six zones
    (for example: a relic split across the crypt, cave, and infernal zones) with
    a final confrontation, so the game concludes rather than just stopping.
11. **Options and key rebinding.** Stored next to the save. Needed once there are
    this many actions.
12. **A bestiary and item identification.** Discovered monsters and identified
    items fill reference screens, a small reward that encourages exploration.

Lower priority but worth noting: ambient sound beds per zone, simple weather or
light flicker for mood, a day/night tint in the town and outdoor zones, and
achievements or a run timer for replay.

## 17. The six zones

Each zone is a cluster of maps under the world manifest, with its own tileset,
music, monster set, and a reason to be there. Portals connect them through the
town hub and a few direct links.

1. **Starting town (static).** Safe hub. Shop, temple, tavern, stash, the first
   quest giver, and gates to the seaside and forest. Teaches movement, dialog,
   and the map. No combat unless provoked.
2. **Island and seaside (mostly static).** Docks, a wrecked ship, tide caves,
   coastal ruins. Lower-level fights (crabs, smugglers, drowned dead). Introduces
   ranged combat and water footing rules. A boat or ferry links back to town.
3. **Forest (mixed).** Authored landmarks (a shrine, a hunter's camp, a ranger
   ally) with dynamic connecting paths. Wolves, bandits, fey. Introduces the
   wandering-monster and rest loop and the Ranger's strengths.
4. **Crypt and dungeon (static with dynamic sub-levels).** Multi-level, locked
   doors, traps, undead, Turn Undead matters here. The authored upper vault leads
   to dynamic lower catacombs. A relic fragment and a mid-game boss.
5. **Cave (dynamic).** Cellular-automata caverns, dark (light radius is small, so
   torches and the darkvision kindreds matter), oozes, kobolds, a mineral prize.
   The clearest showcase of the roguelike generator and fog of war.
6. **Infernal and volcanic (static spine, dynamic pockets).** Late game. Lava
   hazards (Dodge saves, fire damage, resistant and vulnerable foes), demons, the
   final relic and the end confrontation. Fire resistance gear earned earlier
   pays off here.

## 18. Offline tools

Command-line tools in Free Pascal that link the same `pak`, `pic`, `mapfmt`, and
table units as the engine, so a format is defined once. No Python, nothing to
maintain in a second language. Built by the same Makefile into `build/tools/`.

| Tool | Input | Output | Job |
|------|-------|--------|-----|
| `picc` | PPM (P6) image or the procedural generators | PIC lump | palettize and RLE-compress art |
| `mapc` | `.map` text | map lump | compile a map, validate portals and markers |
| `tablec` | `.tab` text (items, monsters, spells, tilesets) | record lumps | compile data tables |
| `dialogc` | `.dlg` text | dialog and string lumps | compile conversations, resolve node links |
| `modconv` | MOD or WAV | music and SFX lumps | pack audio (resample, trim) |
| `pakc` | all lumps | `game.pak` | build the final archive |

PPM is chosen as the art input because it is trivial to read with no external
library, and most editors export it. The build runs the tools in order and
ends with `pakc`, so `make` produces both the binary and `game.pak`.

## 19. Suggested build order

The systems depend on each other, so a sane sequence is. Each milestone is a
version, starting at 0.1.0, with a minor bump per milestone. A version tags the
milestone, so the build order is the plan rather than the exact order of work.

1. **0.1.0** Refactor to the module layout and the `game` state machine, no behavior change.
2. **0.2.0** PAK, PIC, `texcache`: move the existing procedural textures to files.
3. **0.3.0** Map format and multi-map world with portals, still one hardcoded-then-loaded map.
4. **0.4.0** Turn-based grid movement with free look.
5. **0.5.0** Party, attributes, classes, items, inventory, character creation, title screen.
6. **0.6.0** Combat with the AX&X core loop, then the tactical options.
7. **0.7.0** Fog of war, reduced HUD, fullscreen map.
8. **0.8.0** Dialog, shops, the town hub, quests and journal.
9. **0.9.0** Save and load, including per-map fog and diffs.
10. **0.10.0** Roguelike generation and the dynamic-map save path.
11. **0.11.0** Audio mixer, SFX, module music.
12. **0.12.0** Build out the six zones and the critical path.
13. **0.13.0** Rest, traps, status effects, options, and the remaining section 16 items.
14. **0.14.0** Fixed-point math layer and a renderer backend seam, validated on Linux
    against the existing float path (section 23). De-risks the DOS and PS1
    targets without changing gameplay.
15. **0.15.0** The seeded overworld: the biome grid, per-cell local map generation, edge
    transitions, and the authored zones pinned to fixed cells (section 20).
16. **0.16.0** Vertical space: depth-keyed maps, stair, ladder, shaft and interior
    transitions, and consistent dungeon stacking (section 21).
17. **0.17.0** Time: the clock, outdoor day-night lighting, moon phase, lycanthropy, and
    the skylight and moonwell puzzle tiles (section 22).
18. **0.18.0** Interiors and the full pin table: all six authored zones pinned to
    cells around the town, generated building interiors reached by door-portals, and
    an authored town tavern (section 21).
19. **0.19.0** (in progress) PSX-style polygon renderer: a fixed-function triangle
    rasterizer that draws the existing tile grid as geometry and instances CC0 models
    as props, doors and monsters, replacing the raycaster (section 25).

Each step leaves the game runnable, which keeps the project honest. Milestones
0.1.0 through 0.18.0 are done. 0.14.0 landed before the later features, so
the raycaster runs in fixed point and the framebuffer is 8-bit paletted, which
is what the MS-DOS and PlayStation 1 targets need. The camera still uses a few
floats per frame, and textures stay in true color on the prototype. Those are
the next conversions when a target build starts.

## 20. The overworld: a seeded world of biomes

The six zones are set inside a far larger world that is never stored, only
generated from a seed.

- **The grid.** The world is a 1024x1024 grid of cells. Each cell is one square
  kilometer and holds one biome. The whole grid is 1,048,576 cells, so storing
  even one byte per cell would be a megabyte. Instead every cell is derived on
  demand from `hash(worldSeed, cx, cy)`, and the world seed is the only thing in
  the save.
- **Biome derivation.** The cell hash seeds a small, cheap function that yields
  elevation, moisture, and temperature from a few octaves of value noise over
  the grid. Those three values map to a surface biome, deterministic so the
  same coordinates always give the same biome. The surface biomes are ocean
  (sea travel, coastlines, sea cliffs), coast, arboreal (rivers, forest, and
  grassland), swamp, hills, mountains, desert (sand, oases, ruins), arctic
  waste, basalt waste, and volcanic.
- **Underground themes.** Descending under a cell gives a dungeon whose look
  follows the surface above it, so the theme is a function of the biome rather
  than a separate roll. Desert cells lead to dusty desert tombs, ocean and
  coast cells to a flooded underwater floor with shipwrecks, volcanic and basalt
  cells to lava tubes, forested and swamp cells to crypts, and the rest to
  plain caves. These themes are used when vertical space lands in step 16.
- **Local maps.** A biome cell is not the thing you walk on directly. Entering a
  cell generates its detailed walk-around map from `(worldSeed, cx, cy, biome)`,
  using the existing room, cave, and maze generators plus new open-terrain
  generators for the outdoor biomes. The local map is the same scale the engine
  already handles.
- **Authored cells.** The hand-built zones are pinned to fixed coordinates in a
  small table in the world manifest. When the party enters a pinned cell the
  engine loads the authored map instead of generating one. Town, seaside,
  forest, crypt, cave, and infernal sit at known coordinates, and generated
  wilderness fills the space between them. The neighbor cells link inward to a
  pinned zone's start marker. For the reverse, a zone that otherwise leaves only
  to the town hub is given a back door on load: one portal, placed on a floor
  tile reachable from the start, into the first open neighbor cell. The
  placement is derived from the map, so it is the same every load and needs
  nothing stored. This keeps a zone two-way with the wild without pinning
  coordinates into the authored map files.
- **Edges.** A cell border is a doorway, not a seam. A border tile carries a
  portal into the neighbor cell, and stepping onto it loads the neighbor map and
  places the party at the matching opposite edge, the same transition any other
  doorway makes. This is a retro game, so there is no seamless scrolling across
  the join and nothing from the neighbor is resident until the party crosses.
- **Persistence.** Generated cells are reproducible from the seed, so only
  visited fog and player-made diffs are saved, keyed by `(cx, cy, depth)`. The
  terrain itself is never stored. This is the same mechanism the dynamic maps
  already use.
- **Scale and travel.** A 1024 km world is far too large to cross tile by tile,
  so travel has two modes. A coarse overworld mode moves one cell per step for
  long journeys, and the detailed local mode is normal walking inside a cell.
  The time system (section 22) advances faster in overworld mode.
- **Memory.** One map is resident at a time. Because every transition is a
  doorway that loads a map, there is no neighbor cell cache to keep warm. The
  budget lever is instead the visited-map snapshot store, the fog and diffs of
  places the party has been. The common pattern is a hub with many small maps off
  it, a town of houses or a dungeon of rooms, entered and left in quick
  succession, so that store grows by many small snapshots. A least-recently-used
  bound caps it against the 2 MB budget (section 23): the maps the party keeps
  returning to stay resident, and only long-untouched places are dropped, to
  regenerate from the seed on a later return.

## 21. Vertical space: stairs, ladders, interiors, and depth

Maps gain a depth coordinate so the world has an up and a down, not just a
surface plane.

- **The key.** A map is addressed by `(cx, cy, depth)`. Surface is depth 0,
  going down is positive depth (dungeon and cave levels), and building upper
  floors are handled as interior maps rather than world depth.
- **Transition kinds.** A transition tile carries a kind flag: stairs down,
  stairs up, ladder, shaft or pit (a drop, possibly one way or needing a rope),
  cave mouth (surface to underground), and door (into an interior). The flag
  lets the minimap draw the right icon and lets each transition use its own
  animation and sound.
- **Dungeon stacking.** Each depth under a cell is generated from
  `(worldSeed, cx, cy, depth)`, so descending and climbing back is consistent.
  The generator pairs a stairs-down marker on depth N with a stairs-up marker on
  depth N+1 so the two levels connect at a fixed point.
- **Interiors.** A building footprint on a surface map has a door-portal (kind
  door) into an interior map. The town tavern is authored and holds the barkeep.
  Generic houses are generated: a surface cell with `HasBuilding` set places a
  door to the interior named `I<cx>_<cy>_<idx>`, and that interior is built from
  the cell seed with a door back to the cell at its `door0` marker, so entering
  and leaving are stable round trips. Interior stairs for upper floors are not
  built yet.
- **Surface flag.** Each map is flagged surface or underground. The flag drives
  lighting, torch-only underground, and whether the sky and its day-night light
  are visible (section 22).
- **The Sunless Depths.** Dungeons are scattered across the world, and a few run
  deep. At 30 levels down a dungeon breaks into the Sunless Depths, a world
  spanning cavern and the underground civilization that lives in it, in the
  spirit of the Underdark. Reaching depth 30 under any deep dungeon is a doorway
  into the same connected underworld, so the Depths are a second world layer
  beneath the surface, not a single dungeon.
- **Depth as challenge.** A dungeon level maps to a challenge level that scales
  monster hit dice, numbers, and rewards, so descending is the difficulty dial.
  Level one near the surface is a match for a beginning party, and depth 30 and
  the Depths are endgame. The party is rated against a level by a war-band
  calculation rather than by its highest member. Each member contributes a power
  from its level, the powers sum, and the total converts back to one effective
  level, so four level-3s rate above a lone level-3 and below a lone level-6.
  That effective level is the dungeon depth the party can take at roughly even
  odds, which is what the generator and the wandering tables read.

## 22. Time: day-night cycle and the moon

Time is a single clock that everything else reads.

- **The clock.** A 32-bit count of minutes since an epoch, held in one save
  field. A day is 1440 minutes. Actions advance it: a grid step or turn costs a
  few minutes, resting costs hours, and overworld travel costs more per step.
- **Day and night.** The hour is `(minutes mod 1440) / 60`. A daylight factor
  follows a smooth curve, high at noon, zero at night, with dawn and dusk bands.
  Outdoors it modulates ambient light, fog color, and the sky. Indoors and
  underground ignore it and use torch light. Encounter tables can shift with the
  hour, for example more predators and undead at night.
- **The moon.** The synodic month is 29.53 days. The moon age is
  `(totalDays + offset) mod 29.53`, and the phase buckets are new, waxing
  crescent, first quarter, waxing gibbous, full, and the waning mirror. The full
  moon is a narrow window around an age of about 14.77 days. Nothing extra is
  stored, since the moon is derived from the clock.
- **Lycanthropy.** An afflicted character carries a flag. During the full-moon
  window the affliction triggers a transformation, with changed stats and lost
  control. Because the moon is read from the global clock, this fires everywhere,
  including underground. It is the one time-driven effect that ignores the
  sky-visibility rule, matching the brief that the full moon always matters.
- **Light underground.** Underground maps normally show no sun or moon and get
  no day-night light. The exception is tiles flagged skylight or moonwell. A
  skylight admits sunlight by day. A moonwell admits moonlight whose strength
  follows the moon phase, so a beam can reach a glyph only at full moon and open
  a passage. These are tile flags read together with the clock, which is how the
  light puzzles work.
- **Underground light sources.** Beyond the celestial wells, the underworld has
  its own light. The base ambient underground is dim, so the dark reads and the
  party's torch, the near-field distance light, matters. Natural light comes
  from scattered bioluminescent growth and small gas vents. Artificial light
  gathers where people do: braziers, wall torches and bonfires at settlements,
  camps and the major tombs, which in the generator means lit landings at the
  stairs, braziers in the tomb-themed levels, and a bonfire at the Sunless
  Depths settlement. Each source is an emissive tile that both glows in the view
  and casts a pool of light through a per-tile light map precomputed when the
  map loads, with a radius and intensity by kind. A surface sample takes the
  brighter of the torch and the scene light, so a source lights its surroundings
  without washing out the torch-lit near field.

## 23. Target hardware: fixed-point and the 2 MB budget

Linux and SDL2 are the prototype and reference. The shipping targets are MS-DOS
on 32-bit i386 in protected mode (FPC go32v2) and the PlayStation 1 (Kobold
Pascal). The design is held to their limits as it grows.

- **No FPU.** Neither target has a dependable floating-point unit. The i386 is
  assumed to have no 387, and the PS1 R3000 has no FPU at all. The camera and
  raycaster currently use `double`. The plan is a fixed-point unit, a signed
  16.16 `Fixed` type with multiply, divide, and sine, cosine, and square-root
  tables, and a conversion of the camera vectors, ray stepping, and texture
  coordinate math. A compile switch on Linux keeps the float path so the
  fixed-point output can be validated against it.
- **The framebuffer is a prototype cost.** The 320x240 ARGB software buffer is
  about 300 KB, but it exists only in the Linux build. On DOS, mode 13h is a
  320x200 8-bit paletted buffer in VGA memory, about 64 KB and not in main RAM.
  On PS1 the GPU owns the frame in VRAM and walls are drawn as textured quads,
  not raycast per pixel into main RAM. So the renderer sits behind a thin seam,
  and the Linux software rasterizer is just one backend.
- **One indexed color format across all three.** The canonical framebuffer is
  8-bit paletted, one byte per pixel, which is how DOS and PS1 era games were
  made and what both targets want. A single well-chosen palette with ordered
  ramps lets the shading the renderer already does, fog and the day-night
  ambient, become an index shift along a ramp or a lookup table, with limited
  mixing, instead of per-channel math. One byte per pixel also halves and more
  the framebuffer. On the Linux, Windows and SDL port the indexed buffer is
  expanded to true color for display by a palette lookup, which is a one line
  shader in SDL3 and reachable in SDL2 through a GLES path or a small CPU
  lookup. The current ARGB software path stays usable as a fallback, but the
  indexed format is the one the targets share, so it supersedes treating the
  32-bit buffer as canonical.
- **Textures live in VRAM on target.** A 64x64 ARGB texture is 16 KB in the
  prototype. On DOS and PS1 textures are paletted, 8-bit or 4-bit, and on PS1
  they sit in VRAM. Texture count presses on VRAM, not on the 2 MB main RAM.
- **The 2 MB main RAM budget.** The PS1 has 2 MB of main RAM, the tightest of
  the three, so everything is budgeted to it. DOS in 32-bit protected mode has
  more headroom through DPMI, but holding to the PS1 limit keeps all three
  honest. Main RAM holds code and the runtime, game state (party, inventory,
  flags, journal), the one resident map, the loaded tables (items,
  monsters, species, classes, dialogs), the fog and diff snapshots of visited
  maps, and the audio sequence data. In the current prototype the non-framebuffer
  data is well under 100 KB.
- **What can blow the budget.** With one map resident and every transition a
  doorway, there is no multi-cell cache to grow. The real risk is the
  visited-snapshot store, an unbounded set of fog and diffs spread across a huge
  world, since a hub of many small maps fills it with quick entries and exits.
  Large sprite or NPC banks are a secondary risk. The rules are to bound the
  snapshot store with a least-recently-used cap, with fog as bitfields a later
  option, and to load each table once. The snapshot LRU and a budget warning are
  in: the loader drops long-untouched maps to hold the store under its cap and
  warns when the estimated resident set approaches 2 MB.

## 24. Multiplayer: shared shards (future work)

Not scheduled. Single player stays the primary design and the same game. This
records the decided shape so nothing built now blocks it, and so it compiles out
cleanly for the PlayStation 1.

### Scope and deployment

- **Desktop only, UDP only, compile-time optional.** Networking lives behind a
  build flag and is absent from the PS1 build, which has no standard networking
  path. There is no IPX or DOS transport. A single build guard drops the
  backend, leaving the protocol core and the game untouched.
- **A shard holds 32 to 1024 players, configurable.** The range is the size of
  the transport's static connection table, which the server sets; netchan's
  static memory model is why the count is a fixed configured bound, and a
  default of 32 suits most LAN servers. The typical deployment is one shard that
  a player self-hosts as a local game server, which others join. The engine
  gains a headless server mode that runs the simulation and the shard with no
  window or renderer. The `shot` tool already runs the real init and simulation
  paths with no display, so that seam exists.

### Transport: borrow netchan's reliable datagram

- **Feed and pull seam.** We do not adopt netchan directly; we take its shape.
  The protocol core is a pure state machine. The application does the socket
  recv and send and hands bytes across two calls, one that feeds a received
  datagram in and one that pulls the next datagram to send out, with a service
  call that drives retransmit timers. The core includes no socket header. The
  peer address is an opaque value the core copies and compares but never
  interprets, so one small UDP backend is the only code that knows what a socket
  is. That is what lets the whole system compile out for the PS1 with nothing to
  stub.
- **Reliable and unreliable channels.** Named channels carry either reliable or
  unreliable traffic. Turn-based combat and membership changes use reliable
  channels; real-time explore movement and state snapshots use unreliable ones.
- **Discovery.** A host broadcasts a small LAN beacon, a UDP broadcast carrying
  the shard name, player count and join port, so clients find local shards with
  no typed address. WAN join by typed address is also supported but
  server-configurable: a host may enable or disable it. LAN beacon discovery is
  always available.

### Seed-light world

Because the maps and the whole overworld rebuild from a seed, and one map is
resident per party with borders as portal loads, the network never sends
terrain. On join a client gets the shard seed once over a reliable welcome, then
an unreliable stream of only the dynamic party and entity state. The seed
regenerates the terrain, but a map also carries state that does not follow from
it, opened doors, taken items, revealed fog and defeated bosses, so on join and
on each map entry the server sends that map's current diff set over a reliable
channel. The unreliable snapshots then carry only the moving party and entity
state. Interest management falls out of the resident-map design: the server
scopes a client's
snapshot to its party's current map or sector, and the players spread across
many maps, so no client ever receives the whole shard. The server, unlike the
2 MB single-player client, holds many maps resident at once, every map that has
a party on it.

### Parties

- **Solo start, grow by hire or join.** Multiplayer does not build a party of
  four at creation. A player creates one character and grows the party by hiring
  NPCs and hirelings or by other players joining it. Party size is a shard
  parameter, not a fixed four; four is only single-player's starting size.
- **One grid tile, one leader.** A party is one grid tile, exactly as in single
  player, so collision, path-blocking, fog and combat are unchanged. A party
  leader drives the tile's movement. The other players' characters are not drawn
  as world avatars; a party is identified on the map and in listings by its
  first character's icon, and its members show in the normal party roster.
- **Membership.** A member may leave the party while out of combat, becoming
  their own party. The leader may nominate another member as leader. When a
  player disconnects, their character stays in the party as reclaimable and they
  reclaim it on rejoin. When the leader disconnects the party is stuck, unable to
  move, until leadership auto-promotes to another member after a timeout.

### Combat

- **The existing two sides, generalized.** Combat already has two sides, the
  party against monsters. Multiplayer keeps that model and lets each side hold
  one or more parties and monsters. Each player submits the actions for their own
  characters over a reliable channel; the AI runs the hired NPCs and the monsters.
- **A battle is a located, joinable instance.** A battle is anchored to the
  place on the map where it begins, not the abstract full-screen state single
  player uses. Other parties on that map see it and may approach to choose a
  side, so a side can grow to monsters and parties against other parties. A
  battle involves only its combatants, so the rest of the shard keeps exploring
  while it resolves. This moves the engine from one global combat state
  (`gsCombat` and a single `combatstate`) to many concurrent, map-located
  battles on the server, which is the main combat-layer rework multiplayer
  needs.

### PvP and PvE consent

As a principle, a player is never pulled into a PvP fight against their will.
Consent is a per-session flag: for a session a player is either PvP or PvE-only.

The flag is a party property as well, and a party may not mix the two. A party
carries one PvE or PvP flag, so a player whose flag differs cannot belong to it.
Changing your own flag forces you out of your party, with the same mechanics and
restrictions as the leave-party command. This holds for the leader too: a leader
who changes the flag is ejected exactly as if they had left, and leadership
transfers by the normal rule.

A PvE-only player is in a safe mode: their party cannot damage or be damaged by
another player's party, and cannot gain or lose anything through player conflict.
The exclusions all follow from that principle. PvE removes player conflict, not
risk, so everything cooperative stays open.

Excluded mechanics:

- PvP combat itself. A PvE party cannot initiate or receive attacks from another
  player's party.
- Joining a contested battle. The join-a-side action is limited to monster-only
  battles. Once a battle has a player-versus-player side, a PvE party can neither
  join a side nor be targeted, so monster-plus-party against party battles are
  closed to it.
- The post-battle ground-hold cooldown. That one-step territory claim is a
  PvP-combat artifact and does not apply to a PvE party, since nothing can
  contest its tile.
- PvP spoils. No looting a defeated player party, no bounties or contracts placed
  on or collected from players, and no reward whose source is beating another
  player.
- Force-contested objectives. Where a scarce objective resolves by fighting for
  it (a claimable node, a boss tag decided by combat), a PvE party cannot contest
  and yields instead.

Excluded events are those whose win condition is defeating other players: open
sieges and territory control, arenas, tournaments and duels, faction-war
objectives, and player bounty hunts. PvE players keep all cooperative content:
world and raid bosses that are monster fights, exploration, the critical path to
the cities, the town economy and stash loop, and trade.

Three rules fix the edges of the safe mode. A PvE player killed by monsters takes
the normal death penalty and loot drop, the same as single player, because PvE
removes player conflict and not PvE stakes. PvP and PvE players cannot share a
party, but they can still trade and use a shared market, since trade is not
conflict and only party membership is flag-gated. Credit for a cooperative
objective such as a world boss is shared among all who took part, so a PvE player
is never excluded from PvE bosses; only force-contested objectives fall under the
exclusion above.

In PvP, battle acceptance is automatic outside a short cooldown. After a party
wins or flees a battle it gains a one-step cooldown during which it cannot be
pulled into a new battle. The cooldown clears the moment the party takes a step,
so holding position keeps the ground a party earned in battle while a single step
forfeits that protection. This makes repeated grief battles harder without
blocking real fighting. There is no cooldown during a battle: while one is in
progress any number of parties may join the brawl, under the join-a-side rule
above.

PvE and PvP players may render differently to each other. A candidate is to draw
a PvE-only player as only a silhouette or a translucent sprite in another
player's first-person view. Some items, skills, or magic may also be PvP-only,
usable or meaningful only to a PvP player. None are chosen yet. This is a reserved
balance lever, the classic way to keep PvP and PvE fair on one server, and the
specific content comes later.

### Disconnect and character persistence

A character is decoupled from its connection. The character instance persists on
the shard well after its player disconnects, and stays a live combatant: it can
be attacked and acted on while no one is driving it. An optional safe-disconnect
timeout lets a player step away cleanly, but it only waits for the character
instance to time out on its own, and disconnecting early does not shorten that
timeout. This character-instance timeout is distinct from the leader
auto-promotion timeout, which only governs who may move the party.

A disconnected character still in a battle is run by a default AI until its player
returns or it times out. The tactics will be configurable later. For now the AI
is defensive: it makes simple attacks, does not consume items, and tries to move
to the back row or take a defensive stance.

### Who controls whom

The control line is the player character against everything else. A player
character is controlled by a player, who submits its turn. Hirelings and other
NPCs are not player-controlled: they operate their own AI. So does every monster.
In single player one player controls every player character in the party. In
multiplayer each player controls only their own player characters, while the
party's hirelings and NPCs run their AI as always.

The server holds authority over all of it. It runs the AI for monsters,
hirelings, NPCs, and any disconnected player character, and it validates and
arbitrates the actions a player submits for their own characters. A client cannot
be trusted to run an actor that touches shared state, both to stop it acting on
information its player should not have and to keep one combat code path, the same
AI the single-player engine already runs, now on the host. A disconnected player
character falls to the default defensive AI until its player returns or it times
out; the AI behavior is tunable content for later.

### Persistence

The shard is persistent and checkpoints periodically. A checkpoint is the
server-side extension of the single-player save, the seed plus the accumulated
world diffs, now shard-global (a door one party opens is open for all) and
covering every active party.

Characters are saved on the shard, which is authoritative and keeps a client
from forging one. A connected player may export a copy of their own character to
their machine; that export re-imports into a local single-player game, or an
admin copies it into a server by hand. There is no live character transfer
between shards: joining another host does not carry your shard character to it.

### Server authority and time

The host runs the simulation authoritatively at a low tick. The game clock is
shared and runs in real time for the whole shard, so no party can fast-forward
it; rest and the other time-gated systems (wages, lycanthropy, the moon phase)
advance with the real clock rather than skipping ahead. Battles stay turn based:
a battle is a turn-based instance that resolves on its own while the shared
real-time clock keeps advancing for everyone else.

Grid movement is discrete, so step latency is acceptable and there is no
client-side prediction. A high-latency WAN link is fine to play on, though it
can make that player a poor party leader, so players self-select: a laggy member
need not lead, and anyone can prefer a shard closer to them.

### Single player as a one-player shard

Single player and multiplayer are one code path, not two. Single player is a
one-player shard: the same authoritative simulation, the same combat instances,
the same who-controls-whom and persistence rules, running in process with the
UDP backend compiled out. The whole design above already leans this way. The AI
is the one the single-player engine runs, the checkpoint is the single-player
save extended, and the PS1 build is exactly this, a one-player shard with the
transport absent. Only two things differ between single and multiplayer: how many
players are connected, and whether the datagram backend is built in. The
authority seam stays the same, with a player submitting actions to the host and
the host arbitrating. In single player that host is in process and the channel is
a direct loopback, so there is no socket, no beacon, and no serialization on the
hot path.

The unification is incremental and single-player first, not a rewrite behind a
flag. The server-authority and combat-instance refactors land in the
single-player engine first and keep it working the whole way, checked by the
headless shot tool and the test programs. Multiplayer then adds the datagram
backend and real connections on top. No separate multiplayer combat system is
ever written, which is the point of folding the two together.

## 25. The PSX-style polygon renderer (in progress)

The raycaster was the right prototype on Linux, but the real targets are a
polygon machine (PlayStation 1) and 32-bit DOS, and the art we have is low-poly
PSX models. So the visual layer moves from the raycaster to a small
fixed-function triangle rasterizer, the kind of renderer those machines ran.

The grid stays. This is a change to how the world is drawn, not to what the
world is. The tile grid, collision, portals, fog, the overworld generator,
interiors, time, and the combat rules are all renderer-agnostic and carry over
unchanged. Walls become extruded textured quads, floors and ceilings become
quads, and the CC0 models are instanced onto tiles as props, doors, furniture
and, in combat, monsters. The party still walks the grid.

- **Renderer.** `raster.pas` transforms triangles into view space, projects
  them, and fills them with affine (not perspective correct) texture mapping,
  which is the classic PSX texture warp. There is no depth buffer: whole
  triangles are sorted back to front and painted, the painter's approach the
  PS1 ordering table also used. Backface culling drops the far side. The target
  is the shared 8-bit framebuffer, so a texel is already a palette index. The
  math is double precision for now and converts to fixed point later, the same
  staged way the raycaster did.

- **Mesh format.** `meshfmt.pas` defines a baked mesh: a flat list of triangles,
  three corners each with a position and a texture coordinate, plus one paletted
  texture. Corners are not shared, which keeps the renderer a simple loop and
  suits small models. The on-disk lump is `CMSH`.

- **Asset pipeline.** Source models are FBX and GLB with PNG textures.
  `assimp` converts a model to a triangulated OBJ with UVs; ImageMagick resizes
  the texture to a small PPM, which avoids a PNG decoder in Pascal; and the
  `mkmesh` tool bakes the OBJ and PPM into a `CMSH` lump, quantizing the texture
  to the game palette and centering the model on its base. `meshshot` renders a
  baked mesh to a PPM for inspection. The models are CC0.

- **Budget.** The PS1 has 2 MB main RAM and 1 MB VRAM. Geometry is cheap;
  textures are the constraint. Models and textures are kept to a per-area working
  set with shared small textures, the same cell-cache discipline the overworld
  already uses (section 23).

Status: the renderer, the mesh format, and the bake pipeline exist and are
proven on textured props rendered headless (a barrel, a door, eldritch
creatures). The tile grid now draws through the rasterizer as well:
`polyrender.pas` walks the tiles near the camera and emits a floor and ceiling
quad per open tile and a wall face toward every open neighbor, reusing the wall,
floor and ceiling textures quantized to palette indices. A per-pixel depth
buffer in the rasterizer resolves occlusion, so faces draw in any order. The
game toggles between the raycaster and the polygon renderer with the P key, so
the two can be compared directly; the raycaster is still the default.

Props are instanced on top of the grid. A map carries a list of props, each a
model name, a tile and a heading, added with a `prop X Y NAME [yawDeg]`
directive (map format version 4). Models are baked into the pak from an OBJ and
a PPM under `content/models` by the same mesh baker, so the game build needs
only the Pascal toolchain. `models.pas` loads them once and derives a display
scale from a target height, and `polyrender` draws every prop near the camera
through the mesh path, depth-buffered against the walls and floor. The town
carries a few barrels and a door as the first dressing.

Still to do: props do not block movement yet, and they draw only in the polygon
renderer; put monster models in combat, draw the portal and light glows the
raycaster shows, then dial in vertex snap and dither and port the hot path to
fixed point.

## 26. Side-view tactical combat (future combat mode)

Not scheduled. This records a new combat mode that would replace the
first-person, rank-based fight with a 2D side-scrolling, turn-based tactical
battle, in the spirit of Worms crossed with AD&D initiative. Exploration stays
first person; combat drops into a side view on a large, modifiable terrain. The
mode is desktop-first but PS1-native in its model, since Worms itself ran on the
PS1, DOS and Amiga with no FPU.

### Scope and relationship to the current fight

The whole party, four to six units, deploys at once on a multi-screen
destructible field against a mob of enemies, typically under ten but with no
hard cap beyond the platform. The battle is its own instance, which reuses the
`TCombat` seam the single-player engine already grew, but its presentation,
positioning and physics are new. The first-person combat stays the shipping path
until this reaches parity, so it is built as an alternate mode behind a flag and
only then considered for replacement. The design is expressed in the project's
idioms, records plus fixed-point plus data-driven content, not the class and
float hierarchy a generated draft of this document used.

### The battlefield (PS1 budget settled)

The field is a large horizontal terrain spanning several screens, scrolled by a
pan and zoom camera with a free-look mode. Terrain is destructible as in Worms: a
projectile carves a circle out of the ground.

- **Collision** is a 1-bit mask. A 320 by 200 playfield is exactly 8 KB, and an
  eight-screen field is 64 KB, a rounding error against the 2 MB budget, so the
  mask is per-pixel with no need to coarsen it for memory.
- **The playfield is about 200 rows**, not the full 240. A HUD band holds the
  turn order, movement gauge and aim and power meters, and an indestructible
  bedrock strip sits below. The bedrock is also a design element: carved debris
  and falling units always terminate on it, it blocks the dig-straight-down
  degenerate, and it keeps the field from being severed from its base.
- **The visual surface** is an 8-bit CLUT layer, about 75 KB per screen, held in
  VRAM the way a PlayStation stores backgrounds. A carve mutates the 8 KB mask
  and the VRAM surface inside the dirty circle.

### Simulation model

The simulation is cheap and PS1-native. Only a few point masses are live at a
time, the in-flight projectile plus any units knocked loose, integrated under
constant gravity in 16.16 fixed point at a fixed 20 to 30 Hz tick. Most
collisions are point against a terrain bit or point against an axis-aligned box.
Animation decouples from the sim: sprite frames interpolate at display rate over
the fixed tick. There is no floating point and no per-platform physics drift.

### Turn and action economy

Each unit takes one turn per round in initiative order, rolled as DEX plus a d20
into a global queue. A turn holds two pools:

- **Movement budget**, derived from the AD&D move stat times a pixel multiplier,
  spent walking, jumping and climbing across the terrain.
- **One action**: a melee strike, a ranged shot, a spell, or an item.

Movement and the action interleave freely, move part way, act, move the rest, as
long as no irreversible event has fired. Movement is undoable: pressing undo
restores the unit to its turn-start position and refunds the budget, but only
until the state locks. Taking an action, taking damage during movement (a hazard
or an overwatch trap), or altering the world (a switch, an item, breaking a
platform) locks the turn and forbids undo.

### Terrain traversal

Walking handles small rises on its own. A normal walk steps up terrain no taller
than one unit, where one unit is a knee-high block, the largest rise a unit
clears without a dedicated climb. A rise taller than one unit blocks forward
movement, so the unit must route around it or climb it.

Descending is free and needs no separate rule. A drop of any height is walked
down or fallen into, since stepping down a small ledge and falling off a tall one
are the same downward motion. A unit can walk off a ledge into a pit it then
cannot climb back out of.

Climbing taller terrain is a later character feat. A climb feat raises that
unit's step height, or grants a distinct climb action that spends extra movement,
so terrain that stops a normal walker is passable to a climber. The base rule
ships first and the feats layer onto it without changing it.

Traversal probes the terrain against the 1-bit collision mask, not a per-column
height field. A step-up is a short vertical scan of the ground ahead for the
first standable surface within step height. A height field (one surface per
column) is simpler but cannot represent the overhangs, tunnels and caves the mask
allows, so the mask probe, not a stored column height, is the traversal model.

### Ranged and melee

Ranged fire is the Worms model: the player sets an aim angle relative to facing
and charges a power bar, then releases to launch a projectile that arcs under
gravity, so a high arc clears obstacles, allies and cover. Melee moves a unit
adjacent to a target and strikes, stopping further movement for the turn and
applying damage and knockback. Both lock the turn.

### Determinism and the battle instance

The simulation is fixed-point and fixed-timestep, so a battle is deterministic
and reconstructable from its terrain seed plus the ordered list of committed turn
inputs (each move path, aim angle, power and action). That one property gives the
save an exact in-progress battle, lets a late party join a battle in progress by
replaying to the current state, and makes a server checkpoint exact with no
float drift between machines.

### Multiplayer fit

This mode fits the shard design in section 24, and it supplies the battle pacing
that section left open. Battles are turn based while the shard clock runs in real
time, so each turn carries a countdown, the Worms turn timer: when it expires the
turn auto-ends, locking the state and forfeiting the unused action. The server
runs the deterministic battle and the AI authoritatively; a client submits its
turn intent over the reliable channel and the server simulates and broadcasts the
result, with no client prediction. Undo works before commit within a player's own
turn against the server's authoritative pre-commit state, bounded by the timer. A
disconnected player's unit auto-skips on timeout or is played by the default
defensive AI, as section 24 already states. Because a battle replays from its
committed inputs, the join-a-side feature and server checkpoints both fall out of
the same mechanism.

### Art

The art direction uses the GandalfHardcore itch.io bundle, licensed for personal
and commercial use, so it is usable and open to experiment with now. The bundle
covers the mode broadly: knight, heavy knight, wizard, archer, samurai, angel and
succubus characters; skeleton, zombie, goblin, spider and other enemies; a
projectile-and-effects pack for shots and impacts; a hundred-plus ability and
buff icons; a UI pack; and side-scroller environment tiles. Each sheet ships
seven or eight colour variants, and the character packs layer body and legs
separately, which is the modularity that lets a player customise an avatar's
appearance by swapping parts and recolouring, a good fit for the multiplayer
build-one-character start.

Two caveats. First, attack, hit and death frame coverage varies per pack (the
knight ships run and portrait frames explicitly), so some sheets may carry only
idle and walk. For a turn-based battle that uses the sprite mainly for position,
a simple lunge or recoil plus a projectile or effect overlay can stand in, but the
per-pack coverage must be verified before a pack is relied on. Second, these are
clean, full-colour pixel sprites, a different look from the project's PS1 dither
and CLUT discipline, so the palette story is unsettled. When any of this art is
baked into content, CREDITS gains a GandalfHardcore entry with the bundle's
licence terms.

### Open questions

- **Replacement scope.** Whether this replaces the first-person fight outright or
  stays an alternate mode, and how the explore-to-battle transition loads the
  field and returns results, deaths, loot and experience to the party.
- **Spell and skill mapping.** How the domain-gated spell catalog and the
  proficiency skill system translate into the 2D action economy: area effects,
  arcing over allies, target selection, friendly fire.
- **Terrain source.** Whether a battlefield is generated from the encounter's
  biome or authored, how it relates to the first-person map, and its size bounds.
- **Carve support.** Whether terrain left unsupported by a carve stays floating,
  the Worms model and the cheap default, or collapses and settles onto what holds
  it up. This is separate from debris and falling units, which already terminate
  on bedrock; it is about whether the standing terrain restructures after a dig.
- **Enemy AI.** Pathfinding across destructible terrain and an aiming solver that
  picks an angle and power for an arc.
- **Art coverage and palette.** Per-pack attack, hit and death frames, and
  whether the sprites keep their full colour or are brought into the project's
  palette discipline.

## 27. Animated sprite format (evaluation of the dos-rpg .SPA/.SPC)

Sprites in this engine are static today. A monster or NPC is one `CPIC`
lump decoded to an ARGB image and drawn as a billboard, loaded on demand
and cached by name in a flat 64-slot store (`src/sprites.pas`,
`src/pic.pas`). There is no frame or sequence concept, no anchor, and no
loop metadata. Animated foes and directional NPCs need all of that, so
before authoring animation this section settles which parts of the
dos-rpg sprite work to borrow. That project's formats are specified in
`~/DEVEL/dos-rpg/sprfmt.md`: the single-sequence `.SPC` (2bpp) and `.SPV`
(8bpp) with a 4-byte `struct sprhdr` (w, h, frames, flags), the planned
`.SPA` animation bank of many named sequences, and the `.PRT` portrait
container of fixed cells.

### What the .SPA bank offers

The bank is a good container design. One file holds many named sequences
(`WALKN`, `HURTS`, `IDLE`), each with its own bounding box but a shared
anchor so sequences swap without the sprite jumping. Direction lives in
the sequence name, not a format field, so the format stays policy-free
and the engine owns the naming and any fallback (mirror the east walk for
west, fall back from run to walk). Each sequence carries a loop mode,
default frame duration, anchor offset and a mirror hint, and a frame
offset table for variable-length frames. These concerns are what our
`CPIC` lump lacks, and they are renderer-agnostic: a bank index is just
metadata around whatever the per-frame pixels are.

### Where our targets diverge

The dos-rpg run encoding does not fit our backends. Its frames are run
segments of `skip, count, pixels` that drop the mask plane and encode
transparency as skips, and its blitter consumes those runs directly from
far memory with no decode step. That is a software-rasterizer win on an
80286 with a 400-500 KB budget: it shrinks resident RAM and avoids a
decode-to-buffer pass. Our targets are the PS1 GPU and desktop OpenGL
(see section 23 and the target-backend notes), which draw sprites as
textured quads sampled from VRAM through a per-texture CLUT. A GPU cannot
sample a run stream; the sprite has to be decoded to a rectangular
texture and uploaded regardless. So the run encoding's main payoff is
absent on our GPU path and would cost us a decode step we do not want.
Disk size is better handled where we already handle it, by PackBits in
`CPIC` today and by the planned QOI-based codec (see the QOI backlog
item), both orthogonal to the bank. The DOS 2bpp palette limit is also
moot here: our content is 32 colours or fewer, so animated sprites use
the indexed `CPIC` path (format 1), which is our per-sprite CLUT and
matches the per-tileset palette decision for the target backends.

### Decision

Adopt the bank structure, not the pixel encoding.

- Define an animation bank that wraps our existing per-frame `CPIC`
  payload: a header, then a sequence directory modeled on `seq_dir`
  (name, w, h, frame count, loop mode and mirror hint, signed anchor
  `ox, oy`, default ticks, and an offset to the sequence block), then
  per-sequence a frame offset table and the frames. Keep frames as
  indexed `CPIC` so the decoded form is a texture with a CLUT, which both
  backends can upload. Bake it as a new uppercase pak lump through
  `mkassets`, from a text manifest like `png2spr -b` so authoring is a
  tracked file, not ad-hoc runs.
- Keep direction and fallback in the engine. The bank stores a flat set
  of named sequences; the sprite code requests `WALKN` and decides any
  mirroring or fallback. A single-sequence bank is the animated
  replacement for a plain billboard, so static sprites migrate without a
  separate format.
- Do not port the run-segment frame encoding, the mask plane, or the
  2bpp packing. Transparency stays the `CPIC` alpha key; size stays
  PackBits now and QOI later.

### Deferred

- The reference-counted LRU asset cache (`cache_acquire` /
  `cache_release`, acquire-before-release across a map change) is a sound
  pattern for loading a map's whole asset set on entry without reloading
  shared assets. Our store loads on demand into a fixed registry and
  current scenes are small, so this is premature. Adopt it when sprites
  move to bulk on-entry loading and scenes grow, and size the budget to
  the 2 MB target.
- Portraits (`.PRT`, a container of fixed 32x32 cells) map to a small
  multi-frame bank or a simple atlas. Low priority; the current
  single-image portrait path is adequate until portraits animate.
