# Crawler: Roadmap

This roadmap sequences the work that remains to carry the game from where it is
now to a finished, shippable crawler on its three targets. It is grounded in the
design doc (`expanded-edition-design.md`), whose build order (section 19) runs
through milestone 0.19.0, and in the open items that work and the recent
navigation and AI work have left behind.

Numbering continues the design doc's milestone scheme. The engine is renderer
and content agnostic, so most of this is additive and each milestone leaves the
game runnable.

## Where things stand

Milestones 0.1.0 through 0.18.0 are complete: the module layout and state
machine, PAK and PIC assets, the multi-map world with portals, turn based grid
movement with free look, party and classes and items and character creation,
the AX&X combat loop with tactical options, fog of war and the HUD and full map,
dialog and shops and the town hub, save and load, roguelike generation, audio,
the six zones in skeleton, rest, traps, poison, options for volume, the seeded
overworld and biomes, vertical space and the Sunless Depths, and the time,
day-night, and moon systems with lycanthropy and the light-well puzzles.

Milestone 0.19.0 (the PSX-style polygon renderer) is in progress: the
rasterizer, mesh format, bake pipeline, grid-through-rasterizer draw, instanced
props, and monster meshes framed into combat slots all exist. The raycaster is
still the default.

Recent work past the build order added cross-map pathfinding (`pathfind`,
`maproute`), player-known party auto-travel, and omniscient monster pursuit on
the game clock (`pursuit`). These opened a navigation and AI track that the
backlog below carries forward.

## Open backlog by theme

Tags: [gap] not started, [partial] exists but incomplete.

### A. Polygon renderer and the target path (finish 0.19.0)

- [partial] Draw the portal and light-source glows in the polygon path that the
  raycaster already shows.
- [gap] Vertex snap and ordered dither for the PSX look.
- [gap] Decide and apply prop collision: props do not block movement yet, which
  may be intentional for decorations but wrong for furniture.
- [gap] Reach parity with the raycaster, then make the polygon renderer the
  default and keep the raycaster as a compile-time fallback.
- [partial] Port the rasterizer hot path to fixed point (the camera still uses a
  few floats per frame; see theme E).

### B. Navigation and AI (continues the recent track)

- [gap] Locked-door handling in routing: `pathfind` treats every door as
  passable, so a route can plan through a door the party cannot open.
- [gap] NPC-aware pathing: auto-travel can stall on an NPC-occupied tile, and a
  pursuer can path through one, because the planners read only the static grid.
- [gap] Persist pursuers in the save so a hunt survives a save and load (they
  are transient today).
- [partial] Pursuit tuning: spawn cadence and caps, and letting a fled fight
  keep the hunter on the trail instead of consuming it on contact.
- [gap] Coarse overworld travel mode (design section 20): one cell per step for
  long journeys, built on the same router, with the time system advancing
  faster. The local cross-map auto-travel is the detailed mode only.
- [gap] Broader omniscient AI uses now that the router exists: patrols, fleeing
  to reinforcements, guards that converge on an alarm.

### C. RPG systems depth (design section 16)

- [gap] Status effects breadth: disease, fear, paralysis, blindness in dim
  light, encumbrance. Poison is the only one wired.
- [gap] Light and food as consumable resources tied to rest. Torches are
  cosmetic today and rest costs only time.
- [partial] Difficulty and accessibility options: permadeath versus temple
  revive, combat speed, text speed, the optional critical-hit rules. Only volume
  options exist; a revive item exists but no policy toggle.
- [gap] Key rebinding and settings persistence stored next to the save.
- [gap] Hirelings and followers from the tavern, sharing the party structure
  with a temporary flag.

### D. Reference, meta, and quality-of-life

- [gap] Bestiary of discovered monsters and item identification screens. The
  `identified` flag exists on item instances but drives no screen or mechanic.
- [partial] Journal and quest expansion: the flag-backed journal logs a few set
  quests; add map notes and pins and a fuller quest log.
- [gap] A run timer or achievements for replay (low priority).

### E. Shipping targets (design sections 23 and 24)

- [partial] Finish the fixed-point conversion: the camera vectors, and the
  polygon hot path, still use `double`. The raycaster already runs in fixed
  point and the framebuffer is 8-bit paletted.
- [gap] The renderer backend seam for DOS mode 13h and the PS1 GPU, with the
  Linux software rasterizer as one backend behind it.
- [gap] Resident-memory instrumentation and caps: the overworld cell cache and
  the visited-snapshot store are the main risks against the PS1 2 MB budget
  (design section 23). Add an LRU and a budget warning before they grow.
- [future] Multiplayer and LAN play (design section 24). Unscheduled, compiled
  out of the PS1 build, recorded only so nothing now blocks it.

### F. World content and the critical path (design section 17)

- [partial] Flesh out the six zones' encounters, landmarks, and loot beyond the
  skeleton maps.
- [partial] The main quest and an ending: the quest flags (QUEST_MAIN,
  QUEST_CRYPT, QUEST_RELIC, QUEST_WON) and a victory screen exist, but the relic
  thread across the crypt, cave, and infernal zones is not built out.

## Sequenced roadmap

Each milestone is a minor version, leaves the game runnable, and is ordered by
value and by what it unblocks. Sizes are rough: S a few days, M a week or two,
L longer.

### 0.19.0 Finish the polygon renderer (M)

Theme A. Glows in the polygon path, vertex snap and dither, the prop-collision
decision, then promote the polygon renderer to default with the raycaster as a
fallback. This closes the in-progress milestone and makes the target-shaped
renderer the one the game actually runs, which de-risks everything downstream.

### 0.20.0 Navigation and AI consolidation (M)

Theme B. Locked-door handling and NPC-aware pathing first, since both auto-travel
and pursuit stand on the planners and both have the same two blind spots. Then
pursuit persistence and tuning, then the coarse overworld travel mode on top of
the router. This milestone turns the recent one-off systems into a coherent
layer and makes long-distance travel real. It depends on nothing but the routing
already in place.

### 0.21.0 Survival systems (M)

Theme C, the exploration-pressure half. Light and food as consumable resources
tied to rest, and the status-effect breadth with its save hooks. These give
torches, rations, and the Thief and Cleric their intended jobs and make the
dungeon loop tense rather than frictionless. Status effects reuse the save
system already in place.

### 0.22.0 Options, accessibility, and inputs (S)

Theme C, the settings half, plus theme E's settings file. Difficulty and
accessibility toggles, key rebinding, and a settings file stored next to the
save. Small, self-contained, and needed once there are this many actions and
rules to tune. Best done before wider playtesting.

### 0.23.0 Reference and meta screens (S)

Theme D. The bestiary and item identification, and the journal notes and pins.
These are reward and legibility features that pair with the content build-out,
so they land just before it.

### 0.24.0 World content and the critical path (L)

Theme F, with hirelings from theme C folded in. Build out the six zones and
thread the relic quest across the crypt, cave, and infernal zones to an ending,
so the game concludes rather than stops. This is the largest milestone and the
one that turns a systems demo into a game. It depends on the survival and AI
systems being in place so the content can lean on them.

### Parallel track: the hardware push (theme E)

Finishing fixed point, the renderer backend seam, and the memory instrumentation
are gated on starting an actual DOS or PS1 build, not on gameplay. They can run
in parallel with the gameplay milestones and should begin in earnest when a
target build is attempted. The memory instrumentation should land with or just
after 0.20.0, because the coarse overworld travel and its cell cache are the
first real pressure on the 2 MB budget.

## Cross-cutting constraints

These hold across every milestone and are the reason for the choices above.

- The PS1 2 MB main RAM budget and a small resident executable. Favor
  generating or loading data in place over resident banks, and cap every cache.
- Data-driven content. Anything a designer would tune lives in `content/*.txt`
  and compiles into the pak, not in Pascal branches.
- Determinism. Dynamic maps and the overworld rebuild from a seed, so the save
  stores the seed plus the player's diffs, never the terrain.
- No FPU on the targets. New hot-path math is written so it can move to the
  16.16 fixed-point layer.

## Recommended next

Two sensible entry points:

- Finish 0.19.0 (the polygon renderer) to close the stated in-progress milestone
  and make the target-shaped renderer the default. This is the tidy choice if
  the goal is to get the rendering foundation settled before more systems.
- Start 0.20.0 (navigation and AI) to build directly on the just-landed routing,
  auto-travel, and pursuit. The locked-door and NPC-pathing fixes are small and
  high-value, and the coarse overworld travel mode is the feature that makes the
  seeded world usable at scale.

If the recent AI thread is the live interest, 0.20.0 has the most momentum and
the lowest startup cost. If a clean renderer baseline matters more, 0.19.0 is the
one unfinished milestone on the books.
