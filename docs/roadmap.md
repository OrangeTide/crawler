# Crawler: Roadmap

This roadmap sequences the work that remains to carry the game from where it is
now to a finished, shippable crawler on its three targets. It is grounded in the
design doc (`expanded-edition-design.md`), whose build order (section 19) runs
through milestone 0.19.0, and in the open items that work and the recent
navigation, AI, and systems work have left behind.

Numbering continues the design doc's milestone scheme. The engine is renderer
and content agnostic, so most of this is additive and each milestone leaves the
game runnable. Every open feature below names the milestone it lands in, and the
sequenced roadmap collects them in execution order.

The major new direction is a map-format rework that grows out of the polygon
renderer: the world moves from a uniform-height tile grid to a late-1990s
first-person RPG look, Doom-style sectors built indoors from modular tile meshes
and outdoors from heightfield terrain. Sprite billboards and turn-based grid
movement stay; only the world geometry and its data format change. It is tracked
as theme G and sits late in the sequence because it depends on the polygon
renderer being the default first.

## Where things stand

Milestones 0.1.0 through 0.18.0 are complete: the module layout and state
machine, PAK and PIC assets, the multi-map world with portals, turn based grid
movement with free look, party and classes and items and character creation,
the AX&X combat loop with tactical options, fog of war and the HUD and full map,
dialog and shops and the town hub, save and load, roguelike generation, audio,
the six zones in skeleton, rest, traps, poison, options for volume, the seeded
overworld and biomes, vertical space and the Sunless Depths, and the time,
day-night, and moon systems with lycanthropy and the light-well puzzles.

Milestone 0.19.0 (the PSX-style polygon renderer) is nearly complete: the
rasterizer, mesh format, bake pipeline, grid-through-rasterizer draw, and
instanced props all exist, and the polygon renderer is now the default view,
with the raycaster kept as a P-toggle fallback. It carries the PSX look (vertex
snap and ordered dither), emissive-tile floor glows, and the 3D props the
raycaster cannot draw. Monsters and NPCs are front-facing billboard sprites in
both the combat slots and the world view; map exits draw as floor-anchored
billboards, replacing the old coloured floor pads; and surface maps open onto a
gradient sky instead of a ceiling. The rasterizer's per-pixel hot path now runs
in fixed point too, so 0.19.0 is complete; only the per-vertex camera and edge
math still floats, converting last on the theme E hardware track.

The gameplay milestones 0.21.0 through 0.24.0 landed ahead of the renderer and
navigation work: survival systems (light, food, status breadth), options and
key rebinding with a settings file, the bestiary and item identification with
map pins, and the full world-content milestone, the six themed zones and the
relic quest that closes the critical path.

Past the numbered build order, a large systems-and-presentation pass landed,
captured retrospectively as milestone 0.25.0. The axx-rpg spell catalog now
drives both combat and out-of-combat casting; caster classes carry domains and
specialist schools and learn from a learn screen; the martial counterpart, a
proficiency-slot skills system with exploration checks and no-resource combat
maneuvers, is in; and presentation gained per-spell and per-skill icons,
player-character portraits, and a full character sheet. That leaves 0.19.0 and
0.20.0 as the open low-numbered milestones, and themes E, F, and the new theme G
as the forward work.

Recent work past the build order added cross-map pathfinding (`pathfind`,
`maproute`), player-known party auto-travel, and omniscient monster pursuit on
the game clock (`pursuit`). Auto-travel then grew a materialized route that it
plans once and follows, with a route preview on the full map. These opened a
navigation and AI track that the backlog below carries forward.

The art-asset bottleneck drove a switch from per-monster meshes to billboard
sprites (`sprites`, `worldspr`): combat foes and world entities now draw from a
transparency-keyed PIC store, which retired the creature meshes and freed the
model VRAM budget. Front-facing sprites fit a blobber and unlock the pool of
CC0 2D creature art. That art is now in the build: every monster and NPC draws
a distinct CC0 tile from the public domain Dungeon Crawl set and its
supplemental set. The props remain as meshes, which is the seam the modular-tile
work in theme G builds on.

Presentation and content gained several passes on top of that. Interactible
NPCs show dialog portraits. A painted title screen carries its own per-scene
256-colour palette, the way a PlayStation 8-bit background does, over the
mountain photo the project's DOS forebear uses; `gfx.UsePalette` and
`UseGamePalette` make that scene-palette swap reusable. Combat gives each turn
one move and one action in either order, ended early by a SKIP. Every being
carries a gender. Generated dungeons now choose each vertical exit's form from
the ground around it: a staircase against a wide wall, or a ladder standing in
an open chamber.

On code structure, the largest units are split along their concerns. Combat is
now a thin driver over `combatstate`, `combatcore`, and `combatai`, matching
the earlier `game`, `overworld`, and `mapgen` splits.

## Open backlog by theme

Tags: [gap] not started, [partial] exists but incomplete, [done] complete,
[future] recorded but unscheduled. Each open item names its target milestone.

### A. Polygon renderer and the target path (finish 0.19.0)

- [done] Exits (doors, stairs, ladders, cave mouths, shafts) draw as
  floor-anchored billboards in both renderers, replacing the coloured floor
  pads. The shared gather step keeps the two paths in step.
- [partial] (0.19.0) Draw the remaining light-source glows in the polygon path
  that the raycaster already shows.
- [gap] (0.19.0) Vertex snap and ordered dither for the PSX look.
- [done] Prop collision: props are passable decorations by default, with an
  opt-in solid flag per model (models.ModelDef.solid, checked by
  world.PropSolidAt in IsBlocking). The current props stay passable, which the
  maps rely on: a barrel sits on a tile that also holds loot, so blocking it
  would strand the loot, and a doorway is an arch to walk through. Furniture the
  theme G kit brings (coffins, crates) sets solid to block. Route planning does
  not yet read solid props, the same blind spot as NPCs and locked doors in
  theme B.
- [done] Reached parity with the raycaster and made the polygon renderer the
  default (UsePoly true at startup; P toggles the raycaster, kept as a
  fallback). A parity sweep across the zones fixed a stale texture cache on
  tileset swap and billboards sinking into the floor at range, and confirmed the
  polygon path draws the 3D props the raycaster cannot. This unblocks theme G.
  The raycaster retires once the sector level format lands.
- [done] Ported the rasterizer's per-pixel hot path to 16.16 fixed point: the
  depth buffer is fixed, and each span steps its texture and depth interpolants
  with integer adds and compares. Projection and the scanline edge walk stay in
  float as the boundary, the same split the raycaster uses (see theme E).

### B. Navigation and AI (continues the recent track, 0.20.0)

- [done] Materialized cross-map routes: auto-travel plans the portal route once
  as a list of per-map legs and follows it, re-planning only on divergence,
  rather than re-searching every step. The full map previews the walked path.
- [gap] (0.20.0) Locked-door handling in routing: `pathfind` treats every door
  as passable, so a route can plan through a door the party cannot open. Now
  that the Pick Locks skill exists (theme C), a door-aware router should consult
  the party's best lockpick before treating a locked door as passable.
- [gap] (0.20.0) NPC-aware pathing: auto-travel can stall on an NPC-occupied
  tile, and a pursuer can path through one, because the planners read only the
  static grid.
- [gap] (0.20.0) Persist pursuers in the save so a hunt survives a save and load
  (they are transient today).
- [partial] (0.20.0) Pursuit tuning: spawn cadence and caps, and letting a fled
  fight keep the hunter on the trail instead of consuming it on contact.
- [gap] (0.20.0) Coarse overworld travel mode (design section 20): one cell per
  step for long journeys, built on the same router, with the time system
  advancing faster. The local cross-map auto-travel is the detailed mode only.
- [gap] (0.20.0) Broader omniscient AI uses now that the router exists: patrols,
  fleeing to reinforcements, guards that converge on an alarm.

### C. RPG systems depth (design section 16)

- [done] Status effects breadth: poison, fear, paralysis, fighting blind in
  dim light, lingering disease, and encumbrance from carried bulk are all
  wired, with monsters that inflict them and a party-strip that shows them.
- [done] Light and food as consumable resources tied to rest. A torch burns
  down as a fuel budget, spare torches relight as it gutters, and a rest
  spends one ration per living member or the party goes hungry.
- [done] Difficulty and accessibility options: permadeath versus temple
  revive, combat speed, and the optional natural-20/1 critical rules are all
  options rows. Text speed was dropped: there is no typewriter reveal to tune.
- [done] Key rebinding and settings persistence stored next to the save. A
  config file holds the volumes, the choices, and the core-action key table;
  the explore keys rebind in a dedicated screen.
- [done] Hirelings and followers from the tavern, sharing the party structure.
  A recruit joins at the party's level for a charisma-eased fee and draws the
  same fee as a wage each lunar month, deserting when the purse cannot cover it.
- [done] (0.25.0) The spell system: imported the axx-rpg lists, gave each caster
  class its domain and specialist schools, a learn screen and a saved known
  list, combat casting from the catalog, and out-of-combat casting off a
  persistent, rest-restored spell-point pool. (Full detail in the 0.25.0
  milestone below.)
- [done] (0.25.0) The skills system, the martial counterpart to spells.
  Proficiency-slot acquisition, exploration checks (pick locks, find traps,
  move silently, first aid), and no-resource combat maneuvers (power attack,
  disarm, shield bash, aimed shot, rally) on a SKILL command. Data-driven in
  content/skills.txt, rules in skillbook, saved per character (save version 14).

- [gap] (0.30.0) Rank capacity by creature size. The front rank must hold at
  least as much bulk as the back rank, so a back-rank combatant always has cover
  in front of it. Each creature counts as a size multiplier: tiny 1/4, small
  1/2, medium 1, large 2, huge 3, colossal 4. The front rank's summed size must
  be greater than or equal to the back rank's, which lets several small
  creatures shelter behind one big one (up to eight tiny behind a single large).
  This gates the combat MOVE between ranks and the initial encounter layout.
  Combat does not enforce this yet: ActMove swaps a member's rank freely and the
  encounter builder caps the front line at three bodies without weighing size,
  so the back-rank cover rule the user specified is unimplemented. Needs a size
  field on the monster and character records to drive the summed-bulk check.
- [gap] (0.30.0) Port the remaining hardcoded party and class data to content
  files. Against the data-driven rule, a few designer-tunable tables still live
  in Pascal literals: the quick-start / pregen party (its classes, names, and
  species in titleui.BuildPregenParty), the random name pool (NAME_POOL in
  gamestate), and the char-creation default class. Move each into a content lump
  with a parser, the way classes, monsters, and spells already load. (The
  built-in combat spell table is already retired in favour of spells.txt.)
- [gap] (0.30.0) Prepared-spell subset on top of the known list (optional
  caster depth): a caster readies a subset of its known spells per rest, the way
  memorized-spell rules work, instead of casting any known spell at will within
  its point pool.
- [gap] (0.30.0) Stat more combat-shaped spells. About fifty of the catalog's
  170 carry a combat line today; the rest fall back to prose only. Extend the
  thematic combat stats across more of the list as content tuning.

### D. Reference, meta, and quality-of-life

- [done] Bestiary of discovered monsters and item identification. A codex
  tracks monsters met and item kinds known; a bestiary tab lists foes with
  their weaknesses, and mystery loot hides its name until quaffed or named at
  the temple.
- [done] (0.25.0) Player-character portraits and the character sheet. A new
  character cycles a pool of Batareya faces at creation (P key), saved and shown
  as a thumbnail in the party strip and the combat panel. The character sheet
  (press I) shows one member at full size with the full stat block and gear, and
  for a caster or a trained character a spell and skill browser.
- [done] (0.25.0) Spell and skill icons, and the UI that uses them. Every spell
  names a per-spell icon from the Batareya "MAGE ICONS BIG PACK" (SI<NN> lumps)
  and every skill an icon from the "250 WARRIOR ICONS" pack (WI<N> lumps), drawn
  wherever the player meets a spell or skill: the character sheet browsers, the
  SPELLS tab, the learn screens, and the combat cast and SKILL menus.
- [partial] (0.30.0) Journal and quest expansion: map pins and auto-markers on
  the full map are done. A fuller quest log can now proceed since the 0.24.0
  quest content shipped.
- [gap] (0.30.0) A run timer or achievements for replay (low priority).
- [done] Refreshed the README screenshots to the current game: the town with
  its elder, each zone, the tavern keeper, a skeleton down a crypt hall, and a
  five-foe fight across the front and back ranks. The shot tool gained a `foe`
  scene and a combat depth, and `scripts/screenshots.sh` regenerates the set.
- [done] A proper title screen, adopting ideas from the DOS RPG at
  ~/DEVEL/dos-rpg (Liminal Kingdoms): the same mountain photo that game uses,
  taken from the original at full colour and dithered to our palette, with
  birds drifting across its sky, a scaled logo and the boxed menu we already
  use.
- [gap] (0.30.0) Evaluate the sprite and portrait file formats from
  ~/DEVEL/dos-rpg for our animated sprites. See its sprfmt.md: the .SPA
  animation bank (named sequences, run-encoded frames that drop the mask plane
  and skip transparent pixels) and the single-sequence .SPC/.SPV with struct
  sprhdr; portraits ship in SPR/PORTRAIT.SPC. Its asset tools are C
  (tools/sprite-split.c, sprite-sheet.c). The main project stays Pascal, but C
  is permitted for off-line tools and support libraries, especially when porting
  from another project. The DOS original's hard limit was a tiny palette; our
  content is mostly 32 colours or fewer, so that constraint is not a real
  blocker.
- [gap] (0.19.0) Remove the AI-generated exit and prop art. The six exit
  billboards (content/sprites/exit_door, exit_up, exit_down, exit_ladder,
  exit_cave, exit_shaft) and the doorway and barrel prop models
  (content/models/doorway.*, barrel.*) were image-generated and look poor; none
  carry a CREDITS entry, unlike the CC0 source art, which always does. Replace
  them with CC0 source art (the SigilsVault kit in theme G ships doors and
  arches, and the public-domain Dungeon Crawl set has stairs, ladders and cave
  features) or fold the exits into the theme G modular-tile geometry. Generate
  no replacement art; see the cross-cutting constraint below.
- [done] Swapped the six NPC portraits to the Batareya "500 Fantasy Pixel Art
  Portraits" pack (free for personal and commercial use, no redistribution
  limit), scaled to the 64x64 dialog format. The previous licensed portrait art
  was then scrubbed from the whole commit history with a git filter-repo
  rewrite, both the image blobs and the text references. The rewrite is local;
  the remotes still carry the old history.

### E. Shipping targets (design sections 23 and 24)

- [partial] (0.31.0, parallel) Finish the fixed-point conversion. The polygon
  rasterizer's per-pixel hot path now runs in fixed point, as the raycaster
  already did, and the framebuffer is 8-bit paletted. What still uses `double`
  is the per-frame, per-vertex boundary: the camera vectors and projection, and
  the scanline edge walk. These are a handful of operations per vertex, not per
  pixel, and convert last when a real DOS or PS1 build needs the FPU gone.
- [gap] (0.31.0) The renderer backend seam for DOS mode 13h and the PS1 GPU,
  with the Linux software rasterizer as one backend behind it.
- [gap] (0.20.0) Resident-memory instrumentation and caps: the overworld cell
  cache and the visited-snapshot store are the main risks against the PS1 2 MB
  budget (design section 23). Add an LRU and a budget warning before they grow.
  Lands with 0.20.0, since the coarse overworld travel is the first real
  pressure on the budget.
- [gap] (0.31.0) Confirm every third-party asset license before a release. The
  Batareya mage-icon, warrior-icon, and portrait packs are offered free for
  commercial use but their exact terms still need confirming against each
  itch.io page; the SigilsVault kits (theme G) and the Dungeon Crawl sprites are
  CC0. This is a release gate, not code.
- [done] Relocatable file paths for an install-free distribution. An apppaths
  unit locates the pak relative to the real executable (resolved through
  /proc/self/exe, _NSGetExecutablePath, or GetModuleFileName, so a launch by
  bare name or through a symlink still finds its data), with the search list
  covering a macOS .app bundle and a unix install prefix. Writable state (the
  save and settings) moves to a per-user directory so a read-only install
  works, with a portable.txt marker to keep everything in one folder. This
  readies the macOS .app and Windows zip layouts, and the per-host path code
  is exercised natively by CI on each of the three desktop targets.
- [done] Cross-platform desktop build and CI. The build compiles for Linux,
  Windows, and macOS from one Makefile (an EXE suffix and a per-OS SDL library
  name list are the only host-specific pieces), with SDL2 loaded at runtime so
  no development library is needed to compile. A GitHub Actions matrix builds
  and runs the full test suite on all three hosts, and a GitLab pipeline does
  the same on Linux, so the three desktop targets stay green on every push.
  DOS and the PS1 remain gated on the renderer backend seam above.
- [future] Multiplayer and LAN play (design section 24). Unscheduled, compiled
  out of the PS1 build, recorded only so nothing now blocks it.

### F. World content and the critical path (design section 17)

- [done] Flesh out the six zones' encounters, landmarks, and loot. Each zone
  carries its authored NPCs, landmarks, lights, hazards, and encounter table:
  the seaside ferryman and wreck, the forest ranger, hunter's camp and moonlit
  glade, the torch-lit crypt, the glowing grotto, and the infernal's lava vents.
  Each wears its own tileset, one colour scheme over the shared patterns, so a
  generated map themes from its area too. Placed caches, barrels across the
  zones, hand coin and gear to a party that opens them once, the take tracked by
  a per-tile flag in the save. Worn gear carries an elemental resist mask: the
  dragonscale shield earned in the crypt halves the demon lord's fire and the
  infernal's lava vents, so the reward pays off. Other elements (frost, shock,
  holy) ride the same mask when gear for them is added.
- [done] The main quest and an ending: the three relic shards (crypt shrine,
  cave grotto, infernal demon-lord) thread across the zones to the Elder, who
  gates the arc on all three held. The quest flags, journal and victory screen
  close the critical path.
- [done] Renamed the game to "Cities of the Sunless Depths" (was "Shadows of
  the Deep") and extended the arc to match. The three-shard quest is now its
  early beat: once the relic is whole the Elder reveals it as a key, not a
  ward, and charges the descent. The capstone is the Sunless Depths layer
  (SUNLESS_DEPTH, the Depths cells below depth 30), where a sealed City Gate in
  the Depths settlement opens on the key and wins the game on the first of the
  lost cities. Touched the title logo, the window caption, the README, the
  dialogue content (ELDER, the new DEPTHS gate), the journal, the Depths
  generator (the gate NPC, GEN_VERSION 3), and the victory screen.
- [gap] (0.29.0) Follow-on arc content: name and populate the lost cities beyond
  the first gate, and balance the depth-30 descent as a real finale rather than
  a single capstone beat. The win currently fires on reaching the first City
  Gate; the cities themselves are still the generated Depths cavern, not
  authored ruins. The authored-ruin half pairs naturally with the modular-tile
  work in theme G.

### G. Sector maps, modular tiles, and terrain (grows out of theme A)

The target look shifts from the uniform-height tile grid to a late-1990s
first-person RPG: Doom-style sectors with per-area floor and ceiling heights,
built indoors from modular tile meshes and outdoors from heightfield terrain.
Sprite billboards and turn-based grid movement stay; only the world geometry
and its data format change. The polygon renderer (theme A) is the foundation,
so this thread opens once that renderer is the default. The whole thread keeps
one eye on the PS1: the modular kits are chosen and budgeted for it.

- [done] (0.26.0) Evaluated the SigilsVault CC0 kits for PS1 feasibility, written
  up in `docs/kit-evaluation.md`. Verdict: GO for the Modular Dungeon kit, a
  conditional go for the Modular Cathedral kit. Measured face counts over every
  GLB piece (dungeon mean 135, max 584; cathedral mean 345, max 1962), proved the
  meshtools pipeline ingests a kit piece end to end (GLB to OBJ to a palette PPM
  to a CMSH lump to a framebuffer render), and set a per-tile budget: 128
  triangles for structural tiles, 256 for hero tiles, 150 for prop meshes, and
  one resident 256x256 8-bit trim sheet per tileset. GLB is the import format;
  the shared trim sheet maps onto the one-resident-tileset model.
- [gap] (0.26.0) Trim-sheet texturing in the asset and mesh pipeline: a single
  shared atlas per tileset, UV-mapped per piece and baked once, so a whole
  modular room costs one texture. This is the PS1-friendly path and the kits
  already ship this way, with a plain and a handpainted trim sheet each.
- [gap] (0.26.0) Per-biome split palette: give each biome or theme its own
  palette that spends most of the 256 entries, 128 or 192, on that biome's
  textures so the quantized trim sheets smooth out and stop sharing one generic
  cube, while reserving the remaining band, 64 or 128 entries, for the character
  sprites and the UI so those stay stable across biomes and never reshade when
  the scene palette swaps. This extends the full-screen `gfx.UsePalette` swap to
  a partial one: the texture band is per biome, the reserved band is fixed. It
  needs the inverse lookup split by band (textures quantize into the texture
  band, sprites and UI index the reserved band) and a per-tileset palette baked
  alongside the trim sheet. Lands with or just after the trim-sheet item, since
  it is what makes the per-tileset textures read well. Sprite art may need
  pre-indexing into the reserved band rather than re-quantizing at load.
- [gap] (0.26.0) Bake a first modular room: import a hand-placed set of kit
  pieces as instanced meshes in the polygon renderer, drawn over the existing
  grid, to prove the look and the budget before the map format changes. This
  reuses the instanced-prop path that already draws the remaining meshes.
- [gap] (0.27.0) The sector map format: sectors carry a floor and a ceiling
  height and a tileset, walls are segments between sectors, and a cell
  references the modular pieces that build it. This replaces the uniform-height
  tile grid as the authored and generated map model and lets halls, vaults,
  balconies, and pits read as height rather than as flat tiles. Collision and
  the turn-based grid decouple from the render geometry: movement stays on a
  logical grid laid over the sectors, so the feel is unchanged. Bump the map and
  GEN versions and keep seed determinism, so generated sector maps rebuild
  identically from a seed and the save still stores the seed plus diffs. The
  raycaster stays only as a flat-grid fallback for the DOS target.
- [gap] (0.27.0) Port mapgen and the authored maps to sectors: the generators
  emit sector geometry assembled from kit pieces, and content/maps/*.map migrate
  to the new format. Vary floor and ceiling heights per area so the generated
  dungeons gain vertical variety over the current single-height rooms.
- [gap] (0.28.0) Outdoor terrain: a heightfield for the overworld surface and
  the open zones, rendered in the polygon path, with the indoor/outdoor seam
  handled by the sector model (a cave mouth opens from a sector onto terrain).
  Keep the billboard foliage and entities over the terrain, and keep the seeded,
  deterministic generation the overworld already uses.

## Sequenced roadmap

Each milestone is a minor version, leaves the game runnable, and is ordered by
value and by what it unblocks. Sizes are rough: S a few days, M a week or two,
L longer. The sector thread (0.26.0 to 0.28.0) is the one hard dependency chain:
it needs the polygon renderer promoted to default in 0.19.0.

### 0.19.0 Finish the polygon renderer (M) [done]

Theme A. Glows in the polygon path, vertex snap and ordered dither, the
prop-collision decision, the promote to default (parity reached, the polygon
renderer is the view the game runs, the raycaster is a P-toggle fallback), and
the rasterizer's per-pixel hot path ported to fixed point. This made the
target-shaped renderer the one the game runs and opened the theme G map rework.
Only the per-vertex camera and edge math still floats, the boundary that
converts last on the theme E hardware track.

### 0.20.0 Navigation and AI consolidation (M)

Theme B, plus the memory instrumentation from theme E. Locked-door handling
(now consulting the Pick Locks skill) and NPC-aware pathing first, since both
auto-travel and pursuit stand on the planners and share the same two blind
spots. Then pursuit persistence and tuning, then the coarse overworld travel
mode on top of the router, with the resident-memory LRU and budget warning
landing alongside it because that travel mode is the first real pressure on the
2 MB budget. Depends on nothing but the routing already in place.

### 0.21.0 Survival systems (M) [done]

Theme C, the exploration-pressure half. Light and food as consumable resources
tied to rest, and the status-effect breadth with its save hooks. Delivered: a
torch fuel budget that gutters and dims the view, spare torches that relight it,
rations spent per member at rest with a hunger toll when short, and the status
breadth (fear, paralysis, fighting blind, lingering disease, encumbrance) with
the monsters and party-strip cues to surface them.

### 0.22.0 Options, accessibility, and inputs (S) [done]

Theme C, the settings half, plus theme E's settings file. Delivered: a config
file beside the save holding the volumes, the difficulty and accessibility
choices, and the core-action key table. The options screen edits them live; a
key-bindings sub-screen rebinds the exploration keys with a press-a-key capture.
Permadeath gates a temple revival service for the slain.

### 0.23.0 Reference and meta screens (S) [done]

Theme D, the reference half. Delivered: a codex unit, saved with the game, that
records monsters met and item kinds identified; a bestiary tab that lists foes
with hit dice, armour, and weakness (unmet shown as ???); mystery loot that is
named by using it or paying the temple; and full-map pins (right-click to cycle)
with auto-markers for discovered stairs, portals, and NPCs.

### 0.24.0 World content and the critical path (L) [done]

Theme F, with hirelings from theme C folded in. Delivered: the six zones each
carry authored landmarks, NPCs, lights, hazards, and an encounter table, each
wearing its own tileset; placed caches and barrels hand gold and gear once,
tracked per tile in the save; worn gear carries an elemental resist mask (the
dragonscale shield halves the demon lord's fire), with a combat-damage assertion
pinning the halving; and the three relic shards thread across the crypt, cave,
and infernal zones to the Elder, whose victory screen gates on all three held.

### 0.25.0 Caster and martial systems, and party presentation (L) [done]

Themes C and D, the systems-and-presentation pass that landed after the world
content. Recorded here so every feature has a milestone home.

Delivered: the axx-rpg spell catalog (170 spells, three domains, six levels)
drives combat and the SPELLS tab; caster classes name a domain in classes.txt
and specialist mages split the arcane list into eight schools; casters learn
from their domain on a learn screen and the known list is saved; out-of-combat
casting (heals, cures, light, read-magic, sense-the-area) runs off a persistent,
rest-restored spell-point pool. The martial counterpart shipped too: a
proficiency-slot skills system with exploration checks (pick locks, find traps,
move silently, first aid) and no-resource combat maneuvers (power attack,
disarm, shield bash, aimed shot, rally) on a SKILL command, data-driven in
content/skills.txt and saved per character. Presentation gained per-spell and
per-skill icons drawn everywhere the player meets a spell or skill, player
portraits in the party strip and combat panel, and a full character sheet with
a spell and skill browser.

### 0.26.0 Modular tiles and PS1 kit evaluation (M)

Theme G, the groundwork. The kit evaluation is done: GO for the Modular Dungeon
kit, with a per-tile poly budget settled in `docs/kit-evaluation.md`. The two
remaining pieces are implementation: bring trim-sheet texturing into the asset
and mesh pipeline, and bake a first hand-placed modular room drawn over the
existing grid to prove the look and the budget. No map-format change yet: this
de-risks the rework before the format churns. Depends on the polygon renderer
being the default (0.19.0).

### 0.27.0 Sector map format (L)

Theme G, the core rework. Define the Doom-style sector data model (per-sector
floor and ceiling height, wall segments, a referenced tileset), decouple
collision and the turn-based grid from the render geometry, and migrate both
mapgen and the authored content/maps to it, bumping the map and GEN versions
while keeping seed determinism. The raycaster drops to a flat-grid fallback.
This is the largest milestone of the thread and the one that changes the game's
look from a flat grid to a late-90s first-person RPG. Depends on 0.26.0.

### 0.28.0 Outdoor terrain (M)

Theme G, the outdoor half. A heightfield terrain for the overworld surface and
the open zones, rendered in the polygon path, with the indoor/outdoor seam
handled by the sector model and the billboard foliage and entities kept over the
terrain. Depends on 0.27.0.

### 0.29.0 Follow-on arc: the lost cities (M)

Theme F, the remaining content. Name and populate the lost cities beyond the
first City Gate, and balance the depth-30 descent as a real finale rather than a
single capstone beat. The authored-ruin half pairs with the modular-tile work,
so it is best taken after at least 0.26.0 so the cities can be built from the
kit rather than the generated cavern.

### 0.30.0 Systems depth and data cleanup (S/M)

Themes C and D, the remaining smaller items gathered into one polish milestone:
rank capacity by creature size, porting the last hardcoded party and class data
to content files (which the data-driven constraint demands), the optional
prepared-spell subset and more combat-statted spells, the fuller quest log now
that 0.24.0's content shipped, and the low-priority run timer and the dos-rpg
sprite-format evaluation. Independent of the renderer and map threads.

### 0.31.0 Target backends: DOS and PS1 (L)

Theme E, the hardware push. Finish the fixed-point conversion, build the
renderer backend seam with the Linux software rasterizer as one backend, and
confirm every third-party asset license before release. Gated on the sector
evaluation (0.26.0, which sets whether the modular geometry fits the PS1) and on
the fixed-point and memory work from earlier milestones.

### Parallel track: the hardware push (theme E)

Finishing fixed point and the memory instrumentation are gated on gameplay only
loosely and can run in parallel with the gameplay milestones. The memory
instrumentation lands with 0.20.0, because the coarse overworld travel and its
cell cache are the first real pressure on the 2 MB budget. The backend seam
itself (0.31.0) should begin in earnest once a target build is attempted, which
the theme G kit evaluation informs.

## Cross-cutting constraints

These hold across every milestone and are the reason for the choices above.

- The PS1 2 MB main RAM budget and a small resident executable. Favor
  generating or loading data in place over resident banks, and cap every cache.
  The modular-tile and terrain work in theme G is budgeted against this from the
  start.
- Data-driven content. Anything a designer would tune lives in `content/*.txt`
  and compiles into the pak, not in Pascal branches.
- Determinism. Dynamic maps and the overworld rebuild from a seed, so the save
  stores the seed plus the player's diffs, never the terrain. The sector format
  keeps this: generated sector maps rebuild identically from a seed.
- No FPU on the targets. New hot-path math is written so it can move to the
  16.16 fixed-point layer.
- Generated art only as a tracked placeholder. Final art comes from CC0 or
  licensed source packs, or from procedural generation in code (the wall, floor
  and door textures are procedural by design). Image-generated art may stand in
  temporarily to fill a slot, but every such placeholder must carry a roadmap
  entry scheduling its replacement with source art. The earlier generated exit
  and prop art is tracked for replacement under theme D.
- Turn-based grid movement and sprite billboards are kept through the map
  rework. The sector geometry is a presentation layer over a logical grid, not a
  change to how the party moves or how beings are drawn.

## Recommended next

0.19.0 is complete and the 0.26.0 kit evaluation returned GO for the Modular
Dungeon kit (see `docs/kit-evaluation.md`), so the sector thread is unblocked
and the order is:

- Continue 0.26.0 with its two implementation pieces now that the kit is
  cleared: trim-sheet texturing in the asset and mesh pipeline (one resident
  256x256 tileset per modular set), then a first hand-placed modular room drawn
  over the existing grid to prove the look and the per-tile budget before the
  map format churns in 0.27.0. The polygon renderer they build on is in place.
- 0.20.0 (navigation and AI) is independent of the renderer and can run in
  parallel at any time. It builds directly on the just-landed routing,
  auto-travel, and pursuit; the locked-door and NPC-pathing fixes are small and
  high-value, and the coarse overworld travel mode is what makes the seeded
  world usable at scale.

The caster and martial systems in themes C and D are complete (0.25.0): spells
and skills both work in and out of combat, with icons, portraits, and a
character sheet. What remains in those themes is optional depth (prepared
spells, more combat-statted spells, rank capacity) and the data-port cleanup,
all gathered into 0.30.0 and dependent on neither the renderer nor the map
threads.
