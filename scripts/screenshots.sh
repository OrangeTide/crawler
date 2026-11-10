#!/bin/sh
# Regenerate the README screenshots from the headless shot tool. Each shot is
# the 320x240 framebuffer upscaled 4x with nearest-neighbour, the way the game
# presents it. Run from the repo root: sh scripts/screenshots.sh
set -e

cd "$(dirname "$0")/.."
make shottool >/dev/null
make >/dev/null            # ensure build/game.pak is current

OUT=screenshots
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
SHOT=build/tools/shot

# name  :  shot-tool scene and arguments
# The crypt and cathedral shots stand in procedurally carved dungeon cells
# (named D<cx>_<cy>_<depth>), so the gallery shows the carve-and-clad layout,
# not a hand-authored lump. These are deterministic from the generator version
# and the cell seed; regenerate if either changes.
set -- \
  "hero:map D270_0_1 24 34 E" \
  "town:map TOWN 6 8 N" \
  "seaside:map SEASIDE 10 9 E" \
  "forest:map FOREST 2 7 E" \
  "crypt:map D270_0_1 29 20 E" \
  "cathedral:map D284_0_2 10 10 E 0.15" \
  "grotto:map GROTTO 3 8 N" \
  "infernal:map INFERNAL 2 7 E" \
  "monster:foe DUNGEON 2 7 E SKELETON 8 7" \
  "shop:map TAVERN 3 5 N" \
  "combat:combat 12"

for entry in "$@"; do
    name=${entry%%:*}
    args=${entry#*:}
    "$SHOT" "$TMP/$name.ppm" $args >/dev/null
    convert "$TMP/$name.ppm" -filter point -resize 1280x960 "$OUT/$name.png"
    echo "wrote $OUT/$name.png"
done
