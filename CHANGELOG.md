# Changelog

All notable changes to this project are recorded here. The format follows
Keep a Changelog, and each release is cut as an annotated tag whose message is
that release's section below.

This is the first tagged release. It builds on milestones 0.1.0 through 0.23.0,
whose development history is summarized in docs/roadmap.md.

## [Unreleased]

### Added
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
  text. The art is licensed portrait packs by a third-party artist, bundled under
  content/portraits with their license; see CREDITS.
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

[0.24.0]: https://gitlab.com/OrangeTide/crawler/-/tags/v0.24.0
