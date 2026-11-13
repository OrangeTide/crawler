# Changelog

All notable changes to this project are recorded here. The format follows
Keep a Changelog, and each release is cut as an annotated tag whose message is
that release's section below.

This is the first tagged release. It builds on milestones 0.1.0 through 0.23.0,
whose development history is summarized in docs/roadmap.md.

## [Unreleased]

### Added
- The sprite animation bank format (design section 27), phase one. A new `SPBK`
  lump holds many named sequences (IDLE, WALKN, HURT), each with its own
  bounding box, a shared anchor, a loop mode, a mirror hint and default frame
  ticks, wrapping the existing CPIC frames behind a frame-offset table. Banks
  bake from a text manifest in `content/banks` through a new `mkassets` `bank`
  verb. This is the offline format and baker only; nothing animates yet.
  `t_sprbank` round-trips the directory and decodes frames.
- A run timer. Real play time accumulates across a playthrough (a speedrun-style
  wall clock, not the in-world day-night clock) while the run is in progress, and
  pauses on the title, during party creation, and at the game-over and victory
  screens. It shows as H:MM:SS in the JOURNAL tab's foot and on the victory
  screen, and is part of the save. `t_runtimer` covers the formatting.
- A data-driven quest log. Quests, their flag-gated stages, completion flags,
  composite derive rules and freeform log events come from
  `content/quests.txt`, baked into the QUST lump, replacing the hardcoded
  journal sync. The meta JOURNAL tab now shows each active quest by title with
  its current objective, marks a finished quest with its completion line, and
  lists freeform events under a LOG heading. Quest state reads from the story
  flags, so the save is unchanged. `t_quests` covers the table and the queries.
- Optional prepared-spell subset, a settings toggle (PREPARE SPELLS, off by
  default). With it on, a caster may cast only spells it has readied, and
  readying is bounded by per-spell-level slots in the AD&D style: one slot when a
  spell level first opens, and one more every six character levels. Spell points
  stay the casting cost. Ready and un-ready spells on the meta SPELLS tab with P;
  the readied set is saved with the character. Off by default, casting works as
  before (any known spell at will).
- Rank capacity by creature size. Every combatant carries a size class (tiny,
  small, medium, large, huge, colossal) with a bulk weight, and a rank's cover
  is its summed bulk. The front rank must hold at least as much bulk as the
  back, so a back-rank body always has cover and several small foes can shelter
  behind one large one. This gates the combat MOVE (a front member cannot fall
  back if it would leave the rear exposed) and the encounter layout (foes are
  promoted to the front until it covers the back, replacing the old flat
  three-body cap). Monster sizes come from a `size:` tag in `content/monsters.txt`
  (default medium); player characters are medium. `t_size` covers the rule.

### Changed
- The save format is version 16: it stores each caster's readied-spell list and
  the run timer. Saves from earlier versions no longer load.
- More of the spell catalog carries combat stats. Nine prose-only spells now
  have a cast line (the castable count rose from 51 to 60): Flame Arrow, Haste,
  Vampiric Touch and Grease (magic-user), Trip, Pyrotechnics, Snare and Hold
  Plant (druid), and Magic Stone (cleric). Each is calibrated to its prose and
  to the already-statted spells of its level; pure-utility spells stay prose
  only.
- Starting equipment is data-driven. A new character's gear, the equipped
  weapon, offhand, armor and light plus the starting pack, now comes from a
  `content/gear.txt` table keyed by the class kit archetype, with a common row
  given to every character. It replaces the hardcoded `case` in `GiveClassKit`,
  so a loadout tweak or a new kit is a table edit, not code. Baked into a new
  `GEAR` lump; `t_gear` pins the archetype loadouts.
- New-game data is data-driven. The random name pool, the quick-start pregen
  party, and the character-creation default species and class now load from a
  `content/newgame.txt` table instead of Pascal literals in `gamestate`,
  `titleui`, and `charcreateui`. Baked into a new `NEWG` lump; `t_newgame`
  pins the table.

## [0.29.1] - 2026-11-12

### Fixed
- A bare `make` builds the binary again, not just the CLUT. The `build/clut`
  rule had become the first target in the Makefile, so make took it as the
  default goal and `make` alone skipped `build/crawler`. CI and the release
  workflow run `make`, so their package step could not find the binary. The
  `all` target is now the file's first target, which restores building
  everything on any make version. The Windows FPC toolchain bundles a make too
  old to honor `.DEFAULT_GOAL`, so the first-target order is what fixes it
  there.
- The macOS cross-build finds units under `src/ui`. `scripts/build-macos.sh`
  passed only `-Fusrc`, so a forced recompile of a `src/ui` unit could not
  locate its source; it now also passes `-Fusrc/ui`, matching the host build.

## [0.29.0] - 2026-11-12

### Added
- An OpenGL ES 2.0 present backend, the first stage of the renderer backend
  seam. A new `video` unit owns the window and the present path and prefers a
  GLES2 context, drawing the 320x240 software framebuffer as a textured quad; a
  `gles2` unit binds the GL entry points at runtime through SDL_GL_GetProcAddress
  so there is no link-time GL dependency. It falls back to the SDL 2D renderer
  when no GL context or shader is available, so the game still runs, and
  CRAWLER_GL=0 forces that fallback. Built for the Raspberry Pi and Linux; it
  ports to Windows and macOS on desktop GL 3.x or ANGLE next.
- The GPU now draws the explore scene, the second stage of the backend seam (a
  new `glrender` unit), and it is the default whenever a GL context is up. It
  renders through a 320x240 offscreen target upscaled nearest for the retro
  look, carries the PSX vertex snap and a 4x4 ordered dither with a 5-bit
  quantize in the shaders, and covers the non-kit grid walls, floors and
  ceilings, the kit cladding, placed props, door and ladder portal meshes,
  sprite billboards, the surface-map terrain and sky gradient, the emissive
  floor glow, multi-material kit pieces, and the emission channel that makes a
  window's stained glass glow by its own light in a dim nave, with the 2D HUD
  composited over it. It shares the software renderer's projection and content,
  so the two agree in idiom without matching pixel for pixel, and it reaches
  parity with the software explore view. The software explore path stays the
  fallback with no GL (CRAWLER_GL=0), and CRAWLER_GL3D=0 forces it for
  comparison. The dialog overlay composites its panel over the GPU scene,
  dimmed by a GL veil, rather than re-rendering the backdrop in software.
  Verified on aarch64 through GLES2 on a Raspberry Pi.
- Per-tileset colour on the GPU, through a baked CLUT. The asset build
  median-cuts each kit tileset's own trim atlases to a 256-colour `CLUT`
  lump, and the GPU explore backend now renders kit cladding through it: it
  samples the trim as CLUT indices and looks them up in the tileset CLUT bound
  per primitive, the way the PlayStation samples an indexed texture against a
  CLUT. Each tileset keeps its own colour instead of quantizing into the shared
  6x6x6 cube, so the gold trim band, the red-brown brick and the stained glass
  render in their own hues rather than drifting to the nearest cube level.
  Emission stays a direct additive channel, outside the CLUT, and a tileset with
  no CLUT falls back to the shared palette. The software renderer still samples
  the shared-palette indexed atlas, so its output is unchanged. In true-colour
  mode the procedural biome walls, floors and ceilings also render from their
  own RGBA rather than the shared cube, so the texture-colour toggle reaches
  the non-kit maps; the GPU texture cache is invalidated on a tileset swap so a
  later map does not show the previous tileset's surfaces.
- A TEXTURE COLOR option in the settings menu, choosing how the GPU renders kit
  cladding: the per-tileset CLUT for the PlayStation look (the default) or full
  direct colour. The choice persists in the settings file.
- Per-piece multi-material meshes for the modular kits. A kit piece's mesh now
  carries a material per triangle, and the kit text names a trim atlas and an
  optional emission atlas per material slot, so one piece clads from several
  sheets. The cathedral clerestory wall is now the full window, a stone frame
  around stained glass as a single piece, the frame scene-lit from the cathedral
  trim and the glass glowing from its own diffuse and emission.
- Roaming monsters now patrol, raise alarms, and converge. A spawned hunter
  roams its map until it spots the party, rather than knowing where they are;
  the sighting raises an alarm that pulls the other roamers in to converge, and
  breaking off a fight rallies them the same way, so a hunter the party flees
  brings reinforcements. Several can roam at once and gang up.
- A resident-memory bound on the visited-map snapshot store, so the vast seeded
  world cannot grow it without limit against the PlayStation 2 MB budget. An LRU
  drops the least-recently-visited maps to keep the fog and door store under a
  cap, and the map loader warns when the estimated resident set nears the budget.
  A dropped map loses only its remembered fog and open doors, which regenerate
  from the seed on return.

### Changed
- Combat holds its state in a single fight instance, groundwork for the
  multiplayer design's map-located battles (design section 24). The per-fight
  state that `combatstate` kept as unit globals, and the turn queue and pacing
  that `combat` kept as its own private globals, now live in one `TCombat`
  record reached everywhere through `Active^`. Single player runs exactly one
  fight, so play is unchanged; the gain is that the fight is now addressable,
  which the later multi-instance work needs. The cross-fight options (criticals
  and combat speed) stay separate, since they persist across fights.
- Roaming hunters survive a fight the party breaks off. A hunter that catches
  the party is no longer consumed on contact: a win finishes it, but fleeing
  leaves it alive and set back a short way, so it picks up the trail again. A
  cooldown now paces hunter spawns, so an ended hunt (a kill, safe ground, or a
  flight) leaves a breather before the next one. New `pursuit.RepositionPursuer`
  moves a hunter for the setback.
- Lockpick-aware route planning. A route may now plan through a locked door when
  the party can pick it. `pathfind` gained a `canPick` flag threaded through
  `maproute`, and auto-travel passes `skillbook.PartyCanPickLocks` (true when an
  upright member carries the Pick Locks skill), so a party with a lockpick routes
  through locked doors and the walk picks each one on arrival, while a party
  without one routes around. Monster pursuit leaves the flag off, since monsters
  do not pick locks. NPC-occupied tiles already block a planner, so auto-travel
  plans around NPCs and pursuers no longer path through them.

## [0.28.0] - 2026-11-10

Theme G's outdoor terrain and carve-and-clad generation, the polygon
renderer retiring the raycaster, and source-art exits and props.

### Added
- A crate prop and scattered clutter in generated levels. The CC0 BakaFoxArt
  Crate joins the barrel as a 3D prop (content/models/crate.*), and the dungeon,
  cave, cathedral and Depths generators now dress each level with a few passable
  containers, an even draw between a barrel and a crate, standing against the
  walls where they can (generator version bumped to 11). Authored maps are
  unchanged; this is generation-only clutter.
- Light-source glows on kit-clad floors. A brazier, torch, biolume or vent on a
  kit-clad floor now casts its coloured glow onto the floor in the polygon path,
  as it always did on non-kit floors. A kit floor is one merged native piece per
  block, so the glow is drawn as a per-cell decal that tints the floor already
  there, z-tested so walls and props occlude it. This was the last 0.19.0 render
  item, so the raycaster's retirement leaves no visible gap.
- Carve-and-clad map generation (`carve`). A level is carved on a coarse module
  grid, one module per kit floor piece, then each module expands to its N by N
  cells, so every open region is a union of grid-aligned single-sector blocks and
  the smallest corridor is one module wide. That is exactly the cladding's
  native-piece condition, so a carved level clads from whole kit pieces with no
  scaled fillers, proven headlessly by the `shot carve` scene and by the
  claddable-invariant test. A companion repair pass conforms an arbitrary grid
  (carved or hand-authored) to the module: it snaps rooms by a majority rule,
  drops sub-module notches, reconnects anything the snap strands, and relocates
  stranded entities, so random generation and manual authoring can share the same
  carve and repair steps. Generated dungeons now carve this way across three
  styles: the crypt carves mausoleum rooms, a cave carves organic grotto caverns
  (so caves are kit-clad now, where they were flat and untextured before), and
  the cathedral carves its cruciform bays, each clad from whole native pieces
  with no ragged fillers (generator version bumped to 10). A hand-authored map
  can opt into the same conform with a `conform N` directive, which snaps its
  grid to the kit module at bake time before a final edit.
- Wall-derived prop facing. A prop authored as `prop X Y NAME auto` takes its
  yaw from the walls around its cell: a door (or any wall-backed prop) faces away
  from the wall behind it, into the open, and a freestanding cell defaults to
  facing south. The town, outskirts and temple doorways now use `auto` instead of
  a hand-set yaw, so their facing follows the layout and survives a conform.
  Braziers stay point lights with no facing to derive.
- Outdoor terrain heightfield. A surface map's ground can carry relief: hills,
  slopes and valleys drawn in the polygon path, with the camera and the
  floor-anchored billboards and props riding the slope. The height is a
  render-only layer beside the logical grid, so collision and turn order are
  unchanged. It builds from a baked heightmap asset (a grayscale image, the
  `heightmap` bake verb, and a `heightmap LUMP ZMIN ZMAX` map directive; map
  format bumped to 14) and renders at a per-target subdivision knob
  (`terrain.TERRAIN_SUBDIV`), mirroring the trim-sheet knob: dense on the
  desktop, coarse and vertex-snapped on the PlayStation path from one source.
  Generated wilderness cells also carry relief, built from the world seed: the
  elevation rides the broad terrain field so high ground rises and plains stay
  flat, and because it samples absolute world coordinates, neighbor cells seam
  with nothing stored (generator version bumped to 8).
- Billboard foliage over the terrain. Surface obstacles (trees, rocks) are now
  walk-through billboards standing on the ground instead of grid walls, so the
  wilderness reads as an open field dotted with trees rather than a maze. A
  `foliage X Y [KIND]` map directive places them, generated cells scatter them
  by biome, and each rides the terrain through the shared ground anchor (map
  format bumped to 15). The tree sprite is the loafbrr Generic Foliage conifer
  (CC BY 1.0, credited).
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
- Reorganized the UI source. The per-state screen units now live under `src/ui`,
  one unit per game state, and the catch-all `miscui` was split into its nine
  screens (`fullmapui`, `menuui`, `charsheetui`, `learnspellui`, `learnskillui`,
  `optionsui`, `keybindui`, `gameoverui`, `victoryui`). No behaviour change; the
  split also resolves a latent `LearnableCount`/`LearnableNth` name clash by
  giving the spell and skill learn screens only their own backing unit.
- Moved combat logic out of the combat UI unit. `combatui` had held game rules
  that do not belong in a screen unit: the two item-usability checks now live in
  `items` (`ItemUsableInCombat`, `ItemRevives`) and the won-fight spoils (the
  loot roll and the boss story-flag award) now live in `combat`, so the UI unit
  only renders, routes input and announces the result. No behaviour change; the
  loot roll still draws from the global RNG stream, not the combat core's, so
  the deterministic combat rolls are undisturbed.
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
- Brought the README up to date. The Layout tables now list every source unit:
  the cladding, kit, sprite, combat-core and field-cast units that had fallen
  off, and the combat row split to match the current driver. The renderer notes
  now say the polygon path is the default view, which it has been since the
  terrain work, in place of the old "experimental" and "raycaster is the
  default" wording.
- Subdivided the grid's floor, ceiling and wall faces to tame affine texture
  warp. The rasterizer maps textures affinely, so a cell drawn as one large
  quad kinked a straight brick course at the quad's diagonal when seen at a
  grazing angle. Each face now draws as a small grid of sub-quads
  (`DrawTexQuadSub`), so straight lines stay straight, the way the PlayStation
  tessellated surfaces for the same reason. The subdivision is a per-target knob
  (`GRID_SUBDIV`) beside `raster.VSNAP` and `terrain.TERRAIN_SUBDIV`: dense on
  the desktop, coarse under `GRID_COARSE` for the FPU-less targets. Kit meshes
  and the outdoor terrain carry their own tessellation and are unchanged.
- Door exits now stand the doorway mesh in the world instead of the flat
  EXIT_DOOR billboard. The renderer draws the `DOORWAY` prop mesh in every door
  portal, so a door reads as framed geometry rather than a flat card, and the
  redundant hand-placed DOORWAY props at those portals (town, outskirts, temple)
  were removed. The door is set into the wall backing its cell rather than
  centred on the walkable tile, so it sits in the wall plane instead of floating
  a half-tile in front of it. The `exit_door` sprite and its bake entry are
  dropped.
- Replaced the image-generated exit art with source art. The stair, cave and
  shaft exits now draw public-domain Dungeon Crawl feature tiles (the same CC0
  set the monster and NPC sprites come from): `stone_stairs_up` and
  `stone_stairs_down` for the up and down exits, `dngn_entrance` for a cave
  mouth, and `dngn_trap_shaft` for a shaft. The ladder exit becomes a 3D prop
  mesh (the trillobit3s Ladder model, like the doorway) that the renderer stands
  in every ladder portal, turned to face the camera the way the old billboard
  did, so a ladder reads as real geometry with rungs and scene lighting. The
  generated `exit_ladder` billboard is dropped. CREDITS records both sources;
  the ladder model is freeware (free to use, optional donation).
- Replaced the image-generated barrel prop with a source mesh. The barrel is now
  the CC0 BakaFoxArt Wooden Barrel model (its visual mesh isolated from the kit's
  FBX, the bundled collision box dropped), with a CREDITS entry. This clears the
  last image-generated exit or prop from the game.

### Removed
- Retired the raycaster. The PSX-style polygon renderer has been the default
  view since the terrain work and now carries everything the game draws, so the
  raycaster fallback and its `P`-key A/B toggle are gone and `src/raycast.pas` is
  deleted. The polygon path is the only renderer, with its PlayStation look
  (vertex snap and 4x4 Bayer ordered dither) and its fixed-point per-pixel hot
  path in place.

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

[0.29.1]: https://gitlab.com/OrangeTide/crawler/-/tags/v0.29.1
[0.29.0]: https://gitlab.com/OrangeTide/crawler/-/tags/v0.29.0
[0.28.0]: https://gitlab.com/OrangeTide/crawler/-/tags/v0.28.0
[0.27.1]: https://gitlab.com/OrangeTide/crawler/-/tags/v0.27.1
[0.27.0]: https://gitlab.com/OrangeTide/crawler/-/tags/v0.27.0
[0.24.0]: https://gitlab.com/OrangeTide/crawler/-/tags/v0.24.0
