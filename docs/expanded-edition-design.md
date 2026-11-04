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

The systems depend on each other, so a sane sequence is:

1. Refactor to the module layout and the `game` state machine, no behavior change.
2. PAK, PIC, `texcache`: move the existing procedural textures to files.
3. Map format and multi-map world with portals, still one hardcoded-then-loaded map.
4. Turn-based grid movement with free look.
5. Party, attributes, classes, items, inventory, character creation, title screen.
6. Combat with the AX&X core loop, then the tactical options.
7. Fog of war, reduced HUD, fullscreen map.
8. Dialog, shops, the town hub, quests and journal.
9. Save and load, including per-map fog and diffs.
10. Roguelike generation and the dynamic-map save path.
11. Audio mixer, SFX, module music.
12. Build out the six zones and the critical path.
13. Rest, traps, status effects, options, and the remaining section 16 items.

Each step leaves the game runnable, which keeps the project honest.
