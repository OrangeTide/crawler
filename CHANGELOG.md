# Changelog

All notable changes to this project are recorded here. The format follows
Keep a Changelog, and each release is cut as an annotated tag whose message is
that release's section below.

This is the first tagged release. It builds on milestones 0.1.0 through 0.23.0,
whose development history is summarized in docs/roadmap.md.

## [Unreleased]

### Added
- Kit pillars. A `pillar X Y` map directive marks a cell to carry a pillar; the
  cladding pass draws the tileset kit's pillar piece there at native scale, and
  the cell blocks movement. Previously the pillar role was defined but inert.
  The DUNGEON's sunken gallery now wears a colonnade of stone columns (map
  format bumped to 13).
- An ambient-light zone trigger (TRIG_AMBIENT): a polygon that overrides the
  scene's ambient light level while the party stands inside it, for a shadowed
  alcove or a brighter chamber within one map. Authored with the `trigger
  ambient` map directive; the DUNGEON's torch-lit sunken gallery now reads
  brighter than its dim side halls.
- A fire-on-enter event trigger (TRIG_EVENT): a polygon that, the first time the
  party enters it, sets a story flag and shows a one-line message, then stays
  quiet on return. The fire-once state reuses the save's flag system, so it
  persists like a sprung trap. Authored with a `trigger event` polygon plus an
  `eventmsg` line for the message text (map format bumped to 12). The DUNGEON
  announces its sunken gallery on first descent.
- A hazard zone trigger (TRIG_HAZARD): a polygon that bites the party each step
  they linger in it, element-typed and halved by warding gear, or seeps poison
  when its tag is `poison`. Authored with a `trigger hazard <damage> <element>`
  directive. The INFERNAL hall now carries a seam of lava.

### Added
- An infernal volcanic kit. The INFERNAL zone now wears the loafbrr Canyon
  Terrain kit (warm basalt) on tileset 15, re-authored to a wide volcanic cavern
  with rock-pillar islands and a sunken lava lake. The lake is a sector on a
  lava tileset (16) whose floor glows molten through the emission channel. The
  lava emission is a procedural placeholder.
- Per-tileset trim-atlas residency. The trim atlases are now keyed by tileset
  and every kit tileset's atlases load at once, so a map whose sectors point at
  different tilesets (a lava lake inside a rock cavern) can clad each sector from
  its own atlases. Previously only the map's base tileset had atlases resident.
- An emission channel for kit cladding. A kit piece can name an emission atlas
  (an `!N` token in the kit text) whose colour is added over the scene-lit
  surface, so it glows regardless of the scene light. A new clerestory tileset
  (14) uses it for stained-glass walls: a glass pane from the cathedral kit's
  window mesh, glowing in tinted colours through a dim nave. The GLASSHALL proof
  map shows it. A full window wall with a stone frame around the glass still
  wants per-piece multi-material meshes; this proof uses the glass pane alone.
- A crystal-grotto theme kit. The GROTTO cave now wears the loafbrr Mines and
  Cave Set on its own tileset (13): organic rocky ground, cave-rock walls, and a
  ceiling reused from the floor piece flipped to face down, floors and ceiling on
  the ground atlas and walls on the cave-rock atlas. The cave was re-authored to
  the kit's 4-unit scale, a wide open cavern with rock-pillar islands and a
  sunken crystal pool lit by bioluminescence, in place of the old one-tile-wide
  passages on the biome tileset.

### Changed
- Replaced the dungeon kit. The modular tileset (10), which the authored DUNGEON
  and the generated crypt levels ride, now wears the loafbrr Mausoleum Dungeon
  kit in place of the SigilsVault mossy kit. It is a multi-material crypt kit:
  dressed-stone floors, ashlar walls, a concrete ceiling slab and a stone
  pillar, each sampling its own trim atlas through the new multi-atlas path. The
  pieces sit on the same 1 metre = 1 grid unit scale, so the maps clad unchanged.
- Kit cladding now supports multiple resident trim atlases per tileset. Each
  kit piece names the atlas it samples (an `@N` token in the kit text, default
  0), so a multi-material kit can clad its floors, walls and ceilings from
  separate sheets instead of one shared trim sheet. The baker writes extra
  atlas lumps (`TRIM<t>_<n>`) and the renderer resolves each piece's sheet at
  draw time. Single-atlas kits are unchanged.
- Re-authored the starter DUNGEON to the modular mossy kit's scale. The old
  hand-built level was one tile wide, so the 4-unit kit pieces could not tile
  it and their relief jammed into the corridors, which read as corrupt, narrow
  geometry with glitched corners. It is now built from wide open halls joined by
  short doorways, with pillar blocks for crypt character, so the kit clads it
  cleanly. All portals, markers, and features are preserved.

## [0.27.1] - 2026-11-09

Release tooling fixes for the 0.27 line.

### Fixed
- The release and CI builds install ImageMagick, so the asset bake's `convert`
  step runs on the GitHub and GitLab runners instead of failing the build.
- The macOS cross-build generates and includes `build/version.inc`, so the
  version-stamped binary compiles through the docker cross path.

### Changed
- Headless title screenshots now show the build version string.
- CI also runs when `version.mk` changes.

## [0.27.0] - 2026-11-09

Character systems and modular geometry.

### Added
- A modular-kit cladding pass: a tileset's sectors now draw from instanced
  modular tile-meshes instead of the procedural surface quads. Floors, ceilings
  and walls clad from a kit of pieces declared per tileset in tilesets.txt, each
  with its grid footprint; the pass merges open cells into native-scale pieces
  aligned to the kit grid and drops to one-unit base pieces at ragged edges, so
  the tiling stays stable as the camera moves. Walls scale to each sector's
  height, and the risers and lintels between sectors of differing height clad
  too. The first kit is the SigilsVault mossy dungeon set on a dedicated tileset
  past the biome range, so a map clads only when it opts in.
- Themed modular dungeons. Crypt-themed generated levels wear the mossy kit and
  gain vertical relief, each level painting coarse blocks of open cells with
  varied floor and ceiling heights from its seed (floors step at most half a
  unit so the level stays walkable, ceilings vary freely). The authored crypt
  DUNGEON is clad to match, with kit-height ceilings and a sunken grand gallery
  authored through new sector and fill map directives.
- A cathedral theme, from a second modular kit. The SigilsVault cathedral kit
  rides a tileset of its own at its native grand scale (an eight-unit module,
  soaring vaults). The mountain biome now generates a cathedral: a cruciform of
  eight-cell bays, a nave and transept with random corner chapels, lit by
  braziers under a dim clerestory ambient. The town temple is rebuilt from the
  same meshes in a warm candlelit tint, reusing the kit across two moods with no
  new geometry.
- A polygon trigger layer over the grid. A map may carry trigger polygons,
  regions that act on the party while it stands inside, decoupled from the
  geometry and tested with an all-integer point-in-polygon lookup. The first
  effect is an encounter region that overrides the wandering-monster table
  while the party is in it. The map format and its compiler gained the trigger,
  and the map format version is bumped.
- A build version scheme. version.mk holds the authoritative version; the build
  refines it with git describe and bakes the string into the game, shown on the
  title screen and in the window caption. A release-check target verifies the
  version file and the git tag agree before a release is cut.
- A sector layer in the map format, the foundation for height in levels.
  Sectors are regions of open cells that carry their own floor and ceiling
  height, laid over the wall grid. The polygon renderer draws floors and
  ceilings at each cell's sector height and the risers and lintels between
  sectors that differ, the camera eye rides the sector floor, and movement
  gained a step-up rule (a floor too tall to climb blocks, a drop is allowed).
  The wall grid stays the movement grid and the flat-grid raycaster's input, so
  existing maps look unchanged. The map compiler gained sector and fill
  directives for authoring height.
- Trim-sheet texturing in the asset and mesh pipeline, the groundwork for
  modular tile levels. A baked mesh now either ships its own texture (props,
  unchanged) or carries none and samples a shared trim-sheet atlas the renderer
  supplies, so a whole modular room draws from one resident texture. The asset
  tools gained verbs to bake modular tiles and the per-tileset atlas, and a
  first hand-placed room from the SigilsVault mossy dungeon kit renders through
  the polygon path as a proof of the look and the per-tile budget.
- A skills system, the martial counterpart to spells. Characters train
  non-spell abilities with proficiency slots, banked at creation and on
  level-up and generous for the thief kit, and spent on a learn-a-skill screen
  reached with T on the character sheet. Spending a slot on a known skill ranks
  it up. Exploration skills work in the world: a party lockpick opens a locked
  door, a trapfinder disarms a trap before it springs, a quiet party slips past
  a wandering foe, and First Aid mends a wounded member between rests. Combat
  maneuvers work in a fight, through a new SKILL command: Power Attack trades
  accuracy for a heavier blow, Disarm knocks a foe off balance, Shield Bash can
  stun, Aimed Shot steadies a ranged attack, and Rally lifts the party's fear.
  Maneuvers cost no resource, faithful to AD&D: the strongest are limited to a
  few uses per fight, reset each encounter. Skills are data-driven in
  skills.txt, baked to a SKIL lump, with per-skill icons from the "250 WARRIOR
  ICONS" pack baked to WI<N> lumps. The save format carries each character's
  trained skills and unspent slots (version 14).
- Casting outside combat. From the SPELLS tab a caster can now work a spell's
  out-of-combat effect while exploring: heal and raise a hurt member, lift
  poison, disease and curses, refuel the party light, read the magic on carried
  loot, and sense the ground around the party. A spell declares its field effect
  with a field line in spells.txt; an ally heal is a field heal already. With
  this, spell points became a persistent pool: a fight no longer refills them,
  and rest restores them, so a caster spends down across a delve.
- Spell icons across the rest of the spell screens, and the party face in
  combat. The per-spell icons now draw on the SPELLS tab, the learn-a-spell
  screen, and the combat cast menu, not only the character sheet. Each party
  member's portrait sits beside its name and bars on the combat party panel,
  and pressing P on the character sheet repicks that member's face in play.
- Spell icons, and a spell browser on the character sheet. Every spell in the
  catalog now names a pixel icon, carried on an icon line in spells.txt. A
  caster's character sheet lists its known spells with those icons, sorted by
  level and scrolled with the up and down keys, and shows the selected spell's
  level and school. The icons are a per-spell selection from the Batareya
  mage-icon pack, baked to lumps of their own and decoded into a dedicated
  cache, so they stay clear of the world-billboard budget.
- A character sheet. Pressing I in the world opens a per-member sheet: the
  portrait at full size beside the name, species, class, and past, then level
  and experience, hit points, armour class, attack, the six ability scores with
  their modifiers, the equipped gear, and for a caster the number of spells
  known and its arcane specialty. The left and right keys page through the
  party, and I or escape closes it. It reuses the state that was reserved for
  an inventory screen but never used.
- A portrait for each party member. A new character cycles through a pool of
  baked portrait faces at creation with the P key, and the chosen face is kept
  on the character and in the save. The face shows as a small thumbnail beside
  each member's name and health in the party strip, so the roster reads at a
  glance. Generated starting parties and tavern hirelings each draw a varied
  face. The pool is twenty-four portraits from the Batareya pack, decoded into
  a small cache of their own rather than the world-billboard budget. The save
  format version is bumped to carry the portrait index.
- Arcane schools for the Magic-User list. Every Magic-User spell now names one
  of the eight schools (abjuration, conjuration, divination, enchantment,
  evocation, illusion, necromancy, transmutation), tagged in spells.txt and
  carried on the spell record. A mage class may name a favored school in
  classes.txt, which makes it a specialist: it is barred from learning or
  casting its AD&D opposition schools, keeps Lesser Divination (any divination
  spell of level four or lower) regardless, knows one extra spell for its
  focus, and casts its favored-school spells at a steeper save. Eight specialist
  classes ship (Abjurer, Conjurer, Diviner, Enchanter, Invoker, Illusionist,
  Necronimus, Transmuter); Wizard and the other mage classes stay generalists
  with the whole list. The learn screen and the SPELLS tab show the school, and
  the opposition filter runs through the shared spellbook rules. Covered by a
  new t_school.
- Known spells, chosen at level-up. A caster no longer commands its whole
  domain. It learns a growing list of spells, one at creation and one for each
  level it gains, picked by the player on a learn-a-spell screen that opens
  before play resumes whenever a caster is owed a choice. The screen lists the
  domain spells the caster's level reaches, marks the non-combat ones, and
  shows each spell's full effect. The known list is kept on the character and
  in the save, so the combat menu and the spells tab show only what a caster
  has learned. A new spellbook unit holds the rules (the known target, the
  learnable and known queries, and the pick trigger); generated parties and
  hirelings learn automatically so they never stop for the screen. The save
  format version is bumped to carry the known list.
- Spell domains for the caster classes. Each class names a spell domain in
  classes.txt (cleric, druid, magicuser, or none), carried on the class record
  and read with ClassDomain. The priest-track classes draw from the Cleric
  list, the mage-track from the Magic-User list, and the Forestal from the
  Druid list. A SPELLS tab joins the journal and bestiary on the meta screen
  (J): it lists a caster's whole domain in level order, paged, with the
  highlighted spell's prose shown in full, and the left and right keys switch
  between the party's casters. Combat still casts its own built-in spells; this
  is the readable catalog, not yet the combat wiring.
- An imported spell catalog. All 170 spells from the AX&X lists (Cleric,
  Druid, and Magic-User across six levels) are compiled from content/spells.txt
  into a SPEL lump and loaded at runtime by a new spelldb unit, with a
  spelltext parser and a t_spells round-trip. Each spell keeps its level, save,
  damage type, material components, and the effect prose that defines its
  behaviour; a helper maps the damage type onto the engine's five elements
  thematically, so a spell later wired into combat approximates the intent
  rather than reproducing exact tabletop mechanics. Combat does not cast from
  the catalog yet; this is the data foundation for per-class spell domains. See
  CREDITS for provenance.
- A title screen in place of the plain text menu: a mountain photo under a
  two-line logo with birds drifting across its sky and the menu in a framed
  box. The scene carries its own optimised 256-colour palette, swapped in while
  the title shows and restored on the way out, the way a PlayStation 8-bit
  background works. This renders the photo smoothly, free of the chunky dither
  the shared 6x6x6 cube would impose, with the menu and logo colours reserved
  in that palette. The scene is the same one the DOS game the project grows
  from uses, taken from the original photo at full colour and framed to the
  same crop. A scaled-text helper in the graphics unit draws the logo. With no
  save to continue, the menu opens on NEW GAME and skips the dead CONTINUE row.
- Materialized cross-map routes. The party's auto-travel now plans the whole
  portal-linked route once, as an ordered list of per-map legs, and follows
  it. It re-searches only when the stored plan no longer covers the current
  map or a leg will not path, instead of re-running the search on every tile.
- Route preview on the full map. The map screen draws the trail a left click
  would walk to the tile under the cursor, and the active route's leg on the
  current map.
- Billboard sprites for monsters and NPCs. A new sprites unit holds a runtime
  store of front-facing PIC images keyed for transparency, and a sprite asset
  kind in the baker builds them from PNG art. Combat foes draw as sprites in
  their slots, and the world view draws every NPC and active pursuer as a
  camera-facing billboard in both renderers. The raycaster gained a per-column
  depth array and a distance-sorted sprite pass; the polygon renderer draws a
  camera-facing quad against its depth buffer. A monster or NPC with no sprite
  still falls back to its drawn glyph.
- CC0 pixel art for the full monster roster and the NPCs, from the public
  domain "Dungeon Crawl 32x32 tiles" set and its supplemental set. Every
  monster now has its own distinct tile: the shore crab and zombie gained
  sprites, and the werewolf, acolyte, and bandit were split off the tiles
  they used to share with the demon and the cultist. No monster falls back
  to a glyph.
- A per-NPC sprite field in the map format. A map NPC may now name its own
  billboard sprite as an optional fifth argument on its npc line, so NPCs no
  longer all share one placeholder. An NPC that names none keeps the default
  human art, and a named sprite that will not load falls back to it. The map
  format version is bumped accordingly. Every NPC in the game now names its
  own CC0 tile: the elder, ranger, hunter, ferryman, barkeep, and apothecary
  each get a distinct figure, and the infernal altar and the two shrines draw
  as statues rather than people.
- Portraits for the interactible NPCs. A talking NPC with a PORT_<dialog-id>
  portrait lump shows a framed face in the dialog box, with the text reflowed
  beside it; speakers that name none (a shrine, an altar) keep the full-width
  text. The art is from the Batareya "500 Fantasy Pixel Art Portraits" pack,
  free for personal and commercial use, bundled under content/portraits; see
  CREDITS.
- An open sky on surface maps. Instead of a dungeon ceiling, a surface map now
  draws a gradient sky above the horizon in both renderers, shaded by the
  day and moon light so it darkens at night. The outskirts where a new party
  starts, and the town, read as outdoors rather than roofed. Underground maps
  keep their ceiling.
- A gender enum (beings unit) on every being: party characters, NPCs, and
  monster definitions each carry a TGender, defaulting to unspecified. It
  persists in the save, in the map format (a new npc line field), and in the
  monster table (a `gender:` tag in monsters.txt). The save and map format
  versions are bumped accordingly.
- A headless screenshot tool (`make shottool`, `scripts/shots.sh`). It drives
  the game's own init and render paths on SDL's dummy video driver, so it
  renders a real game screen (title, world, a map at a position, or combat) to
  an image with no window, display or GPU. This makes the UI verifiable in a
  headless or sandboxed environment where the SDL window will not open.

### Changed
- Combat now casts from the spell catalog instead of a fixed built-in table. A
  caster's command menu is the castable spells it has learned from its class
  domain, gated by character level (higher levels reach higher spell levels)
  and spell points,
  and resolved with the ability modifier from its class prime. A catalog spell
  becomes castable by carrying an optional thematic combat line in spells.txt
  (spell-point cost, target mode, effect, dice, with the element taken from its
  damage type); the combat-shaped spells across all six spell levels in all
  three domains are statted (about fifty: Cleric 14, Druid 13, Magic-User 24),
  and the old seven hardcoded combat spells are retired. The in-combat spell
  menu is ordered by level and scrolls a window when a caster knows more spells
  than fit. Foe spellcasting is unchanged.
- Renamed the game to "Cities of the Sunless Depths" (was "Shadows of the
  Deep"). The title logo and the window caption carry the new name.
- Generated dungeon levels now choose stairs or a ladder for each vertical
  exit from the ground around it. The way up favours a staircase at the foot
  of a wide wall near the entrance; the way down favours a ladder standing in
  an open chamber, and falls back to stairs where the deep end is cramped. The
  generator version is bumped, so stored dungeon seeds regenerate under the new
  rule. A ladder exit is marked as a stair pin on the full map.
- Exits now stand in the world as billboards instead of coloured floor pads.
  A door, staircase, ladder, cave mouth or shaft is drawn as a front-facing
  sprite on its tile, scaled and lit with distance and occluded by walls, in
  both the raycaster and the polygon renderer through the shared sprite gather
  step. A door and a ladder stand a full tile tall while stairs down and a
  shaft sit low on the floor. The old cyan, amber and green floor glows are
  gone; the map and the minimap still mark where an exit leads.
- A combatant now gets both a move and a full action each turn, in either
  order, instead of one or the other. MOVE spends the move slot; ATTACK, CAST,
  ITEM, or DEFEND spends the action slot; the turn ends once both are spent. A
  new SKIP command ends the turn early, forfeiting whatever is unused. Spent
  commands grey out, and a context line in the message box states what the
  acting member may still do.
- Split the 1423-line combat unit along its concerns into combatstate (the
  shared state), combatcore (resolution and tactics), combatai (the foe AI),
  and a thin combat driver (turn order, setup, player actions). Internal
  structure only, no behavior change; the combat tests pass unchanged.
- Retired the per-monster combat meshes in favor of sprites. The CREA* and
  FLESH* models leave the registry, which now holds only the prop meshes, so
  the model cache no longer overflows its VRAM budget.
- Split IsWallTile out of IsBlocking so the renderers cast against tile
  geometry only. An NPC tile no longer draws as a phantom wall, while movement
  still stops on it.
- Extended the main quest to a capstone in the Sunless Depths. The three-shard
  relic quest is now the arc's early beat: once the relic is whole the Elder
  reveals it as a key rather than a ward and charges the party to descend. A
  sealed City Gate now stands in the Depths settlement and opens on the key,
  winning the game on the first of the drowned cities. The Depths generator
  places the gate and the generator version is bumped; the victory screen is
  rewritten for the new ending.

### Fixed
- The sprite bake step emitted 16-bit PPMs that the reader decoded as 8-bit,
  turning art into color noise. It now emits 8-bit channels with a hard alpha
  mask for clean keyed edges, and the PPM reader rejects a non 8-bit file
  rather than corrupt it.

## [0.24.0] - 2026-11-06

World content and the critical path.

### Added
- Six connected zones, each in its own tileset over the shared wall and floor
  patterns: a town hub, a seaside, a forest, a torch-lit crypt, dynamic caves
  and a glowing grotto, and an infernal depth. Each carries authored landmarks,
  NPCs, lights, hazards, and an encounter table.
- A main quest and an ending: three relic shards thread across the crypt, cave,
  and infernal zones to the town elder, who gates the victory on all three.
- Placed loot: caches and barrels across the zones hand gold and gear to a
  party that opens them once, tracked by a per-tile flag in the save.
- Elemental resist on worn gear. The dragonscale shield earned in the crypt
  halves the demon lord's fire and the infernal lava vents.
- Tavern hirelings that join for a charisma-eased fee and draw a monthly wage.
- Relocatable, install-free file layout: assets are found relative to the real
  executable (including a macOS .app bundle and a unix install prefix), while
  the save and settings move to a per-user directory so a read-only install
  works. A portable.txt marker beside the binary keeps everything in one folder.
- Cross-platform desktop builds from one Makefile for Linux, Windows, and
  macOS, with SDL2 loaded at runtime so no development library is needed to
  compile. A macOS arm64 cross-build from Linux is available via `make macos`.
- Continuous integration: a GitHub Actions matrix builds and tests on all three
  desktop hosts, a GitLab pipeline does the same on Linux, and a tag-triggered
  release workflow publishes per-OS archives.

### Changed
- Refreshed the README and the screenshots to the current six-zone game, and
  regenerated the module layout from the current source tree.

[0.27.1]: https://gitlab.com/OrangeTide/crawler/-/tags/v0.27.1
[0.27.0]: https://gitlab.com/OrangeTide/crawler/-/tags/v0.27.0
[0.24.0]: https://gitlab.com/OrangeTide/crawler/-/tags/v0.24.0
