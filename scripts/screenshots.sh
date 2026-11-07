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
set -- \
  "hero:map DUNGEON 2 7 E" \
  "town:map TOWN 6 8 N" \
  "seaside:map SEASIDE 10 9 E" \
  "forest:map FOREST 8 13 N" \
  "crypt:map DUNGEON 13 7 W" \
  "grotto:map GROTTO 3 8 N" \
  "infernal:map INFERNAL 8 13 N" \
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
