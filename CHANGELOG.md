# Changelog

All notable changes to this project are recorded here. The format follows
Keep a Changelog, and each release is cut as an annotated tag whose message is
that release's section below.

This is the first tagged release. It builds on milestones 0.1.0 through 0.23.0,
whose development history is summarized in docs/roadmap.md.

## [Unreleased]

### Added
- Materialized cross-map routes. The party's auto-travel now plans the whole
  portal-linked route once, as an ordered list of per-map legs, and follows
  it. It re-searches only when the stored plan no longer covers the current
  map or a leg will not path, instead of re-running the search on every tile.
- Route preview on the full map. The map screen draws the trail a left click
  would walk to the tile under the cursor, and the active route's leg on the
  current map.

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
