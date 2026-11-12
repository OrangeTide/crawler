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

Milestone 0.19.0 (the PSX-style polygon renderer) is essentially complete: the
rasterizer, mesh format, bake pipeline, grid-through-rasterizer draw, and
instanced props all exist, the polygon renderer is the view the game runs, and
the raycaster has been retired, so the polygon path is the only renderer. It
carries the PSX look (vertex snap and ordered dither), emissive-tile floor
glows, and 3D props. Monsters and NPCs are front-facing billboard sprites in
both the combat slots and the world view; stair, cave and shaft exits draw as
floor-anchored billboards (doors and ladders stand as 3D prop meshes), replacing
the old coloured floor pads; and surface maps open onto a gradient sky instead
of a ceiling. The rasterizer's per-pixel hot path now runs
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
player-character portraits, and a full character sheet.

Theme G then opened and its first two milestones shipped. 0.26.0 evaluated the
SigilsVault CC0 kits for the PS1 budget and built the trim-sheet mesh pipeline.
0.27.0 (and the 0.27.1 tooling follow-up) landed the sector map format over the
movement grid, the modular-kit cladding, a polygon trigger layer, and the port
of the generators and authored zones to the kits: themed crypt dungeons, the
cathedral theme, the reused town temple, and the starter DUNGEON re-authored to
the kit's scale. 0.28.0 then landed the outdoor half of theme G: a heightfield
terrain for surface maps, from a baked heightmap asset and from the world seed,
with the camera, billboards and props riding the relief and surface obstacles
turned into walk-through foliage billboards. That same release bundled the
carve-and-clad generation pipeline, the retirement of the raycaster, and a
source-art pass that replaced the last image-generated exits and props: the
doorway, ladder and barrel are now 3D meshes, the stair, cave and shaft exits
draw Dungeon Crawl tiles, and a new crate joins the barrel as clutter the
generators scatter through a level. With the navigation milestone 0.20.0 since
complete (below), the open forward work is theme E's hardware track, theme G's
remaining sector and content passes, the 0.30.0 systems depth, and the
follow-on world content.

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

The hardware track then opened (theme E, 0.31.0) and its first two stages of the
renderer backend seam landed. Stage 1 added an OpenGL ES 2.0 present backend: a
`video` unit owns the window and prefers a GLES2 context, with `gles2` binding
the entry points at runtime so there is no link-time GL dependency; it presents
the 320x240 software framebuffer as a textured quad and falls back to the SDL 2D
renderer when no GL context is available. Stage 2 moved the explore scene itself
onto the GPU (`glrender`), now the default whenever a GL context is up: it
renders through a 320x240 offscreen target upscaled nearest, carries the vertex
snap and ordered dither in its shaders, and draws the grid, kit cladding, props,
portals, billboards, terrain, sky, floor glow, multi-material pieces and the
emission channel, with the 2D HUD composited over it, reaching parity with the
software explore view. The software explore path remains the fallback with no GL
(CRAWLER_GL=0), and CRAWLER_GL3D=0 forces it even on GL for comparison. Both are
validated on x86-64 and aarch64 Linux, the aarch64 build
through GLES2 on a Raspberry Pi. A baked per-tileset palette (CLUT) landed
alongside, and the GPU now samples kit cladding through its tileset CLUT, bound
per primitive the way the PlayStation will, so each tileset keeps its own colour
rather than the shared cube. The near-term focus stays on x86-64 and aarch64
Linux; the Windows and macOS port (desktop GL 3.x or ANGLE) is deferred.

## Open backlog by theme

Tags: [gap] not started, [partial] exists but incomplete, [future] recorded but
unscheduled. Each open item names its target milestone. Completed work is not
listed here; it is recorded in CHANGELOG.md and the git history.

### A. Polygon renderer and the target path (finish 0.19.0)

- [done] (0.19.0) Light-source glows on kit-clad floors. A light tile's glow is
  mixed into the non-kit floor quad directly, but a kit-clad floor is one merged
  native piece per block and cannot carry a per-cell tint, so a brazier, torch
  or biolume on a kit floor showed no glow. A per-cell floor-glow decal in the
  rasterizer (`DrawFloorGlow`) now reads the framebuffer, mixes the glow over
  the clad floor shaded by the cell light, and writes it back, z-tested so walls
  and props occlude it. With vertex snap and ordered dither already in place,
  this was the last 0.19.0 render item, so the raycaster's retirement left no
  visible gap.

### B. Navigation and AI (continues the recent track, 0.20.0)

- [done] (0.20.0) Locked-door handling in routing. A locked door is a wall to a
  planner unless it may count on opening it: `PathPassable` gained a `canPick`
  flag, and the auto-travel router passes `skillbook.PartyCanPickLocks` (true
  when an upright member carries the Pick Locks skill), so a party with a
  lockpick routes through locked doors (the per-tile walk picks them) and a
  party without one routes around. Monster pursuit and the pursuit-spawn
  reachability check leave the flag false, since monsters do not pick locks.
- [done] (0.20.0) NPC-aware pathing. `PathPassable` blocks a tile an NPC stands
  on, so auto-travel plans around NPCs and re-plans when one steps into the
  route, and a pursuer no longer paths through one. Both planners share the
  check, since both read the same static grid through `pathfind`.
- [done] (0.20.0) Persist pursuers in the save so a hunt survives a save and
  load. The save stores each active hunter's monster, map and tile; a load
  clears the live set and restores them, with the clock read back first so the
  hunt resumes with no backlog of catch-up steps. A save round-trip test covers
  it.
- [done] (0.20.0) Pursuit tuning: spawn cadence and the fled-fight carryover. A
  hunter is no longer consumed on contact. The catch records a pending fight and
  `ResolveHunterFightOutcome` settles it when combat hands back control: a win
  finishes the hunter, while breaking off leaves it alive but set back past
  `HUNTER_MIN_DIST`, so it takes up the trail again instead of vanishing. A
  `HUNTER_COOLDOWN` paces the spawns, so an ended hunt (a kill, a shake on safe
  ground, or a flight) leaves a breather before the next hunter appears. The
  `MAX_HUNTERS` cap stays the tunable limit on how many hunt at once.
- [done] (0.20.0) Coarse overworld travel mode (design section 20). `overworldui`
  is a map-scale mode reached from the open surface: a top-down biome grid where
  one key press moves one cell, the time system advances faster
  (`OVERWORLD_STEP_MIN` per cell), and descending commits the journey and clears
  local hunters. It is a biome-grid walk rather than the portal router, which
  plans over detailed local maps; the cross-map auto-travel stays the detailed
  mode. Ocean cells block until a boat exists.
- [done] (0.20.0) Broader omniscient AI uses on the router. A pursuer now carries
  a mode: `PM_PATROL` roams waypoints on its own map until it spots the party
  within `PURSUIT_DETECT`, `PM_HUNT` routes to the party across maps as before,
  and `PM_CONVERGE` heads for a raised alarm. A sighting raises an alarm that
  turns every patroller on the map to converge, and breaking off a fight rallies
  them the same way, so a hunter the party flees brings reinforcements. Spawned
  monsters now start as patrollers, so they find the party rather than knowing
  where it stands, and `MAX_HUNTERS` rose so several can roam and gang up.
  Authoring fixed guard posts and designed patrol routes in the map data is the
  separate content layer, left for later; this is the engine behaviour on the
  generated hunters. Covered by `t_pursuit`.

### C. RPG systems depth (design section 16)

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

- [partial] (0.30.0) Journal and quest expansion: map pins and auto-markers on
  the full map are done. A fuller quest log can now proceed since the 0.24.0
  quest content shipped.
- [gap] (0.30.0) A run timer or achievements for replay (low priority).
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
- [done] (0.19.0) Remove the AI-generated exit and prop art. Every exit and prop
  now uses source art with a CREDITS entry. The doorway and the ladder are 3D
  prop meshes (content/models/doorway.* from the CC0 loafbrr Low Poly Doors kit,
  content/models/ladder.* from the trillobit3s Ladder kit, freeware with an
  optional donation), the stair, cave and shaft exits draw public-domain Dungeon
  Crawl feature tiles, and the barrel is the CC0 BakaFoxArt Wooden Barrel mesh
  (content/models/barrel.*). No image-generated exit or prop art remains.
- [future] Replace the retro 8-bit monospace font with a nicer proportional
  one. TTF is not required and a baked font atlas is likely preferable, so the
  glyphs suit PS1 rendering later (the same pre-baked, fixed-palette shape the
  textures and sprites take) rather than being rasterized at runtime. Candidate
  sources are the Palm Pilot bitmap fonts at ~/Source/fonts/PalmOS-Fonts. The
  bitmap rendering is public domain in the author's jurisdiction; if anything is
  derived from that collection, add its CC BY-NC-SA 4.0 line to CREDITS. This
  touches gfx.pas (the bitmap font) and every HUD and UI unit that measures text
  by a fixed glyph width, so proportional metrics are the real work.
- [gap] Capture screenshots of the new modular areas (the clad crypt DUNGEON,
  the cathedral theme, the warm-tinted town temple) through the headless shot
  tool, and fold the best into the README screenshot set.
- [gap] Online help for the keyboard commands: a HELP overlay bound to F1 and
  reachable from a main-menu HELP item, listing the controls. Source the key
  list from the same binding table the game already uses so it stays in step.

### E. Shipping targets (design sections 23 and 24)

- [partial] (0.31.0, parallel) Finish the fixed-point conversion. The polygon
  rasterizer's per-pixel hot path now runs in fixed point, as the raycaster
  already did, and the framebuffer is 8-bit paletted. What still uses `double`
  is the per-frame, per-vertex boundary: the camera vectors and projection, and
  the scanline edge walk. These are a handful of operations per vertex, not per
  pixel, and convert last when a real PS1 build needs the FPU gone.
- [partial] (0.31.0) The renderer backend seam for the PS1 GPU and desktop
  OpenGL, with the software rasterizer as the interim backend behind it. Stage 1
  landed: a `video` unit owns the window and the present path and prefers an
  OpenGL ES 2.0 context (a `gles2` unit binds the entry points through
  SDL_GL_GetProcAddress, so there is no link-time GL dependency), presenting the
  320x240 software framebuffer as a textured quad; it falls back to the SDL 2D
  renderer when no GL context or shader is available, so the game still runs
  (CRAWLER_GL=0 forces the fallback). Validated on x86-64 and aarch64 Linux: the
  aarch64 build renders the title screen through GLES2 on a Raspberry Pi. The
  near-term focus stays on x86-64 and aarch64 Linux; the Windows and macOS port
  (desktop GL 3.x or ANGLE) is deferred. Stage 2 has landed: the explore scene
  renders on the GPU by default whenever a GL context is up, driven from the
  explore camera with the clad mesh hook pointed at the GL backend
  (CRAWLER_GL3D=0 forces the software path). It draws through an offscreen
  320x240 colour target upscaled nearest for the retro look, carries the PSX
  vertex snap and a 4x4 ordered dither with a 5-bit quantize in the shaders, and
  covers the non-kit grid walls, floors and ceilings, the kit cladding, placed
  props and door and ladder portal meshes, sprite billboards, the surface-map
  terrain and the sky gradient, the emissive glow on light-well and brazier
  floors, multi-material kit pieces (a window's stone frame and its stained
  glass), and the emission channel that makes that glass glow by its own light
  in a dim nave, with the 2D HUD composited over it. All of this is verified on
  the aarch64 Pi through GLES2, reaching parity with the software explore view.
  The PS1 GPU backend and the Windows and macOS ports are the work that keeps
  this item open. The same game runs on the PS1 and the desktop, but the
  backends need not look identical, so each renders in its own idiom (affine,
  dithered, fixed point on the PS1; higher precision on the desktop) rather than
  matching pixel for pixel.
- [done] (0.20.0) Resident-memory instrumentation and caps (design section 23).
  The visited-snapshot store is the live growth risk: the seeded world is vast,
  so `mapstate` would hold a fog and door snapshot per visited map without limit.
  An LRU (`MapStateTrim`) now drops the least-recently-visited maps to keep the
  store under `SNAPSHOT_CAP_BYTES`, sized so the estimated resident set
  (`MapStateResidentBytes`, a baseline plus the store) stays under the 2 MB
  budget, and the map loader warns once the estimate passes the warn line. A
  dropped map loses only its remembered fog and open doors, which regenerate from
  the seed on return. There is no neighbor cell cache: every cell border is a
  doorway that loads the neighbor map, so one map is resident at a time and the
  snapshot store is the only growth lever.
- [done] (0.31.0) Confirm every third-party asset license before a release. All
  three Batareya packs are confirmed against their itch.io pages: the portraits
  and the warrior skill icons are free for personal and commercial use, and the
  magical spell icons are free for commercial and non-commercial use but require
  crediting the author, which CREDITS does. The SigilsVault and loafbrr kits, the
  BakaFoxArt props and the Dungeon Crawl sprites are CC0, and the trillobit3s
  ladder is freeware with an optional donation. Every asset license is now
  recorded and cleared in CREDITS.
- [future] Multiplayer and LAN play (design section 24). Unscheduled, compiled
  out of the PS1 build, recorded only so nothing now blocks it.

### F. World content and the critical path (design section 17)

- [gap] (0.29.0) Follow-on arc content: name and populate the lost cities beyond
  the first gate, and balance the depth-30 descent as a real finale rather than
  a single capstone beat. The win currently fires on reaching the first City
  Gate; the cities themselves are still the generated Depths cavern, not
  authored ruins. The authored-ruin half pairs naturally with the modular-tile
  work in theme G.

### G. Sector maps, modular tiles, and terrain (grows out of theme A)

The target look shifts from the uniform-height tile grid to a late-1990s
first-person RPG: per-area floor and ceiling heights, built indoors from
modular tile meshes and outdoors from heightfield terrain. Sprite billboards
and turn-based grid movement stay; only the world geometry and its data format
change. The polygon renderer (theme A) is the foundation, so this thread opens
once that renderer is the default. The whole thread keeps one eye on the PS1:
the modular kits are chosen and budgeted for it.

The organizing principle is a split between a logical layer and a visual layer.
A coarse grid carries movement, collision, and turn order, and stays identical
on every target. The visual geometry over it is modular kit tile-meshes indoors
or a heightfield mesh outdoors, chosen per area and tuned per target. Polygon
trigger areas overlay the grid for encounters and region effects, decoupled
from the geometry. This is the Neverwinter Nights approach, a grid of 3D tile
modules plus polygon triggers, with the sector floor and ceiling heights giving
the per-area elevation NWN handled poorly. The raycaster retires as the polygon
path reaches full coverage; there is no flat-grid fallback renderer, so the
geometry is not bound to the grid, and kit pieces that span several grid units
ride as multi-cell mesh instances rather than per-cell quads.

- [partial] (0.32.0) Per-tileset palette. On the direct-colour backends (desktop
  OpenGL and the PS1 GPU) each texture names its own palette, so every tileset
  gets a full palette tuned to its own textures instead of quantizing into one
  shared cube, and the quantized trim sheets smooth out. Sprites and the UI keep
  their own palettes the same way, with no global swap and no band reserved out
  of a single 256, because a direct-colour framebuffer lets each primitive name
  its own CLUT and two tilesets can share a frame freely. On the PS1 the palette
  is a baked CLUT per tileset for its 4bpp or 8bpp textures; on desktop OpenGL
  the textures can be direct RGBA. This largely folds into the backend seam
  (0.31.0), which is what makes per-primitive palettes available. The CLUT path
  has landed end to end on the GPU: the asset build median-cuts each kit
  tileset's trim atlases to a 256-colour `CLUT<tileset>` lump, `textures`
  decodes it and remaps the resident diffuse trim to those indices, and the GPU
  samples the trim as CLUT indices and looks them up in the CLUT bound per
  primitive, the way the PlayStation samples an indexed texture against a CLUT.
  Kit cladding (the gold trim band, the red-brown brick, the stained glass)
  renders in its own per-tileset colour instead of drifting to the nearest
  shared-cube level. Emission stays a direct additive channel, outside the CLUT.
  The software renderer still samples the shared-palette indexed atlas, so its
  output is unchanged. The remaining work is the PS1 backend binding these same
  CLUTs in VRAM, and carrying per-tileset colour to the procedural biome
  surfaces and embedded prop textures, which still go through the shared palette.
  (An earlier plan reserved a fixed band of a single
  global palette for sprites and the UI while swapping a per-biome texture band.
  That was a concession to an 8-bit indexed framebuffer, dropped along with
  MS-DOS.)
- [partial] (0.27.0) The sector map format, foundation landed. Sectors are
  regions of open cells carrying a floor and ceiling height, added over the
  wall grid (MAP_VERSION 10, GEN_VERSION 4). The wall grid stays the movement
  grid and the raycaster's input, so collision, routing, fog, determinism and
  the save are undisturbed; the sector layer is additive. The polygon renderer
  draws floors and ceilings at the cell's sector height and the risers and
  lintels between sectors of differing height; the camera eye rides the sector
  floor, and movement gained a step-up rule. Flat maps render pixel-identically.
  The map compiler gained sector and fill directives for authoring height. The
  earlier linedef (explicit wall-segment) plan is dropped: with no flat-grid
  renderer to keep geometry grid-aligned, non-square and multi-unit kit pieces
  are handled as mesh instances, and the polygon idea is spent on trigger areas
  instead of a wall-segment renderer.
- [partial] (0.27.0) Port mapgen and the authored zones to the kit. Landed: the
  modular kit has its own tileset (10, past the biomes, opt-in), base-unit (1x1)
  kit pieces so ragged non-grid-aligned rooms tile clean fillers instead of
  stretched ones, and crypt-themed generated dungeon levels now wear the kit and
  clad in play, each level painting coarse blocks of open cells with varied
  floor and ceiling heights from the level seed (floors step at most half a
  unit so the dungeon stays traversable, ceilings vary freely) for vertical
  relief instead of one flat room. The authored crypt DUNGEON is now clad too:
  it sits on the modular tileset with kit-appropriate ceiling heights (three
  units base) and a taller sunken grand gallery down its central hall, authored
  with the sector and fill directives. A second kit has landed: the SigilsVault
  modular cathedral kit on tileset 11, kept at its grand native scale (eight-unit
  module, sixteen-unit walls, vaulted ceilings). The mountain biome now generates
  a cathedral theme from it, a cruciform of eight-cell bays (nave, transept, and
  random corner chapels) with soaring bay vaults, brazier lighting and a dim
  clerestory ambient. The town TEMPLE is rebuilt from the same cathedral meshes
  on tileset 12, drawn from a warm candlelit tint of the trim atlas and lit
  bright as a sunlit sanctum, showing the kit reused across two moods with no new
  geometry. Multi-atlas residency has landed: a tileset can hold several
  resident trim sheets at once and each kit piece names the one it samples (an
  `@N` token in the kit text), so a multi-material kit clads floors, walls and
  ceilings from separate sheets, and a map that mixes a modular sector with a
  procedural one no longer shares a single atlas. This unblocks kits whose art
  spans more than one trim sheet. On that path the dungeon kit was replaced: the
  modular tileset (10) now wears the loafbrr Mausoleum Dungeon kit, a
  multi-material crypt kit (dressed-stone floor, ashlar wall, concrete ceiling
  slab, stone pillar, each on its own atlas) in place of the SigilsVault mossy
  kit, at the same 1-unit scale so the DUNGEON and the generated crypts clad
  unchanged. The GROTTO got its own theme kit too: the loafbrr Mines and Cave
  Set on tileset 13, an organic 4-unit cave kit (rocky ground and cave-rock
  walls on two atlases, the ceiling reused from the floor flipped), with the
  cave re-authored to a wide open cavern, rock-pillar islands and a sunken
  crystal pool lit by bioluminescence. The emission channel has landed too: a
  kit piece can name an emission atlas (an `!N` token) whose colour is added
  over the scene-lit surface so it glows in the dark, demonstrated by a stained
  glass clerestory (tileset 14, the GLASSHALL proof map) built from the cathedral
  kit's window glass. Per-piece multi-material meshes have landed too: a kit
  piece's mesh now carries a material per triangle, the kit text names an atlas
  (and emission) per material slot, and the cladding binds each triangle's atlas
  as it draws, so one piece clads from several trim sheets. The GLASSHALL wall is
  now the full SigilsVault window, a stone frame around the stained glass as one
  piece: the frame samples the cathedral trim and the glass its own diffuse and
  emission, in place of the earlier glass-pane curtain wall. The INFERNAL
  zone got its volcanic kit too: the loafbrr Canyon Terrain rock (warm basalt) on
  tileset 15, re-authored to a cavern with a sunken lava lake that glows through
  the emission channel. The lake is a sector on a lava tileset (16), which needed
  per-tileset trim-atlas residency: the atlases are now keyed by tileset and all
  kit tilesets load at once, so a map can mix sectors of different tilesets and
  clad each from its own atlases. The lava emission texture is a procedural
  placeholder, marked for replacement with authored lava art. Kit pillars now
  place too: a `pillar X Y` map directive marks a cell, the cladding pass draws
  the tileset kit's pillar piece there at native scale, and the cell blocks
  movement. The DUNGEON's sunken gallery wears a colonnade of them.
- [done] (0.28.0) Outdoor terrain: a heightfield for the overworld surface and
  the open zones, rendered in the polygon path, with the indoor/outdoor seam
  handled by the shared logical grid (a cave mouth opens from a sector onto
  terrain). The heightfield is an asset, not part of the grid: a source
  heightmap at whatever fidelity the content needs, built into a render grid at
  load time by sampling and interpolating. That build is a per-target knob, the
  same shape as the trim-sheet size knob from 0.26.0: desktop gets a dense grid,
  a coarse build a sparse vertex-snapped one, both from one source. Landed from
  a baked heightmap asset and from the world seed; the camera, billboards and
  props ride the relief, and surface obstacles became walk-through foliage
  billboards. The logical grid stays coarse, so collision and turn order are
  identical no matter how detailed the terrain renders.
- [done] (0.28.0) Formula-driven carve-and-clad generation. Today a modular map is
  authored by hand: the wall grid, the sectors, and discrete props each placed,
  sized and rotated by a person (the town door's yaw, for one). The cladding
  itself is already rule-driven (CladView merges aligned floor blocks, CladWalls
  snaps wall runs to the largest fitting piece, pillars and steps place from the
  grid), so the missing half is the layout. The foundation has landed (`carve`):
  a generator carves on a coarse module grid, one module per floor piece, then
  expands each module to its N by N cells, so every open region is a union of
  N-aligned single-sector blocks (the cladding's native-piece condition) and the
  smallest corridor is one module wide. A repair pass conforms an arbitrary grid
  (carved or hand-authored) to the module: it snaps rooms to the module by a
  majority rule, drops sub-module notches, reconnects anything the snap strands,
  and relocates stranded entities, so both random generation and manual authoring
  can share the same carve and repair steps. Generated dungeons now carve across
  three styles, one per kit theme (generator version 10): the crypt carves
  mausoleum rooms, a cave carves organic grotto caverns (kit-clad now, where they
  were flat before), and the cathedral carves its cruciform bays. A hand-authored
  map opts into the same conform with a `conform N` directive applied at bake
  time. Discrete props now take their facing from the carve: a prop authored as
  `auto` faces away from the wall behind it (the town, outskirts and temple
  doorways use it), so a door follows the layout rather than an authored yaw.
  Braziers stay point lights with no facing to derive. This generalizes the
  crypt-level generator into a full carve-then-clad pipeline, and pairs with the
  authored-ruin content in theme F.

## Sequenced roadmap

Each milestone is a minor version, leaves the game runnable, and is ordered by
value and by what it unblocks. Sizes are rough: S a few days, M a week or two,
L longer. The sector thread (0.26.0 to 0.28.0) is the one hard dependency chain:
it needs the polygon renderer promoted to default in 0.19.0.

### 0.19.0 Finish the polygon renderer (M) [done]

Theme A. Glows in the polygon path, vertex snap and ordered dither, the
prop-collision decision, the promote to default (parity reached, the polygon
renderer is the view the game runs, the raycaster has since been retired so the
polygon path is the only view), and the rasterizer's per-pixel hot path ported
to fixed point. This made the
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

### 0.26.0 Modular tiles and PS1 kit evaluation (M) [done]

Theme G, the groundwork, complete. The kit evaluation returned GO for the
Modular Dungeon kit, with a per-tile poly budget settled in
`docs/kit-evaluation.md`. Trim-sheet texturing then landed in the asset and
mesh pipeline: shared-texture meshes (CMSH version 2) that sample a resident
per-tileset trim atlas, so a whole modular room costs one texture. A first
hand-placed room (the mossy kit, in content/rooms/chamber.room) renders through
the polygon path's shared mesh instancing, proving the look and the budget. No
map-format change yet: this de-risked the rework before the format churns.
Depended on the polygon renderer being the default (0.19.0).

### 0.27.0 Sector map format (L) [done]

Theme G, the core rework. The foundation is in: a sector layer over the wall
grid (sectors as regions of open cells with a floor and ceiling height,
MAP_VERSION 10, GEN_VERSION 4), a polygon renderer that draws per-sector heights
and the steps between them, the camera eye riding the sector floor, a movement
step-up rule, and map-compiler directives for authoring height. Collision and
the grid stay decoupled from the geometry, flat maps are pixel-identical, and
the save and determinism are untouched. The cladding then landed: a data-driven
kit per tileset draws a sector's floors, ceilings and walls from modular kit
meshes, merged to native scale over the world grid, with the first authored kit
map proving it through the live load path. Shipped as 0.27.0 and 0.27.1: the
polygon trigger and zone layer landed, and the kit port reached the generators
and the authored zones (the crypt DUNGEON, re-authored to the kit's scale, plus
the cathedral theme and the reused town temple). The remaining follow-ons carry
forward as the theme G [partial] items: more trigger effect kinds, GROTTO and
INFERNAL theme kits, stained-glass emission, and multi-atlas residency. The
earlier linedef plan is dropped, since the retiring raycaster leaves no
flat-grid renderer to keep geometry grid-aligned and multi-unit kit pieces ride
as mesh instances. This is the milestone that turns the flat grid into a
late-90s first-person RPG. Depends on 0.26.0.

### 0.28.0 Outdoor terrain (M) [done]

Theme G, the outdoor half. A heightfield terrain for the overworld surface and
the open zones, rendered in the polygon path. The heightfield is a tunable
asset: a source heightmap built into a render grid at load time, with the
subdivision density and height-snap a per-target knob, so desktop renders dense
terrain and a coarse build renders a sparse, snapped mesh from one source. The
indoor/outdoor seam is the shared logical grid, which stays coarse and
target-independent, and the billboard foliage and entities are kept over the
terrain. Delivered: the terrain layer (`src/terrain.pas`) with a baked-heightmap
source (`src/heightfmt.pas`, the `heightmap` bake verb and map directive) and a
procedural wilderness source from the world seed (edge-matched, generator version
8); the renderer draws subdivided height-displaced ground and the camera,
billboards and props ride it; and surface obstacles became walk-through foliage
billboards (the tree sprite a placeholder for the loafbrr foliage art). The
fixed-point conversion of the terrain vertex math rides the rest of the polygon
path on the theme E track. Depends on 0.27.0.

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

### 0.31.0 Target backends: PS1 and desktop OpenGL (L)

Theme E, the hardware push. Finish the fixed-point conversion, build the
renderer backend seam for the PS1 GPU and desktop OpenGL with the software
rasterizer as the interim backend, and confirm every third-party asset license
before release. The backend seam starts with an OpenGL ES present path on
x86-64 and aarch64 Linux (the `video` and `gles2` units, stage 1) that blits
the software framebuffer; the near-term focus stays on those two, and the
Windows and macOS port (GL 3.x or ANGLE) is deferred. Stage 2 then moves the 3D
explore scene onto the GPU (the `glrender` unit) through a 320x240 target with
vertex snap and ordered dither, and it has landed: the grid, cladding, props,
portals, billboards, terrain, sky, the emissive floor glow, multi-material
pieces and the emission channel all render there, at parity with the software
explore view and verified on the aarch64 Pi. The same game runs on the PS1
and the desktop; the two need not look identical, so each backend renders in
its own idiom rather than reproducing the other pixel for pixel. Gated on the
sector
evaluation (0.26.0, which sets whether the modular geometry fits the PS1) and on
the fixed-point and memory work from earlier milestones.

### 0.32.0 Per-tileset palette (S/M)

Theme G, a texture-quality pass. On the direct-colour backends each texture
names its own palette, so every tileset gets a full palette tuned to its
textures instead of sharing one global cube, and sprites and the UI keep their
own palettes with no global swap. On the PS1 this is a baked CLUT per tileset
for its indexed textures; on desktop OpenGL the textures can be direct RGBA. It
largely rides on the backend seam (0.31.0) that makes per-primitive palettes
available, and it sharpens how the kit textures look on the PS1 target. The
earlier reserved-band split of a single 256-colour palette is dropped with
MS-DOS, since only an 8-bit indexed framebuffer needed it.

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

0.26.0 is complete and the 0.27.0 foundation has landed: the map carries a
sector layer, the polygon renderer draws per-sector heights and the steps
between them, and height is authorable (see `docs/sector-heights.png`). The
order from here is:

- Continue 0.27.0. Cladding has landed: kit tilesets draw their floors, ceilings
  and walls from modular meshes. The next pieces are a polygon trigger and zone
  layer and the larger port that brings the kit to the generators and the
  authored zones (which wants base-unit kit pieces or kit-grid authoring, and
  more than one resident trim atlas for mixed-tileset maps). Each is additive
  over the foundation and leaves the game runnable.
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
