#!/bin/bash
#
# Headless screenshots of the real game.
#
# Drives build/tools/shot, which runs the game's own init and render
# paths on SDL's dummy video driver, so no window, display or GPU is
# needed. Each scene is written as a PPM and converted to a PNG.
#
# Usage:
#   scripts/shots.sh [OUTDIR] [SCENE ...]
#
# With no scene arguments it captures the default set (title, world,
# town, combat). A scene argument is one of:
#   title
#   world
#   combat
#   map:NAME:X:Y:DIR          e.g. map:TOWN:6:3:E
# OUTDIR defaults to build/shots (git-ignored).
#
# Examples:
#   shots.sh
#   shots.sh build/shots map:FOREST:2:3:E map:SEASIDE:10:9:E
#
set -uo pipefail

# Repo root, however the script is invoked.
ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null)"
[ -n "$ROOT" ] || ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

OUT="build/shots"
if [ "${1:-}" ] && [ "${1#map:}" = "${1}" ] && \
   [ "$1" != title ] && [ "$1" != world ] && [ "$1" != combat ]; then
  OUT="$1"; shift
fi
mkdir -p "$OUT"

echo "building tool and assets..."
make -s shottool || { echo "build failed"; exit 1; }
make -s          || { echo "asset build failed"; exit 1; }

export SDL_VIDEODRIVER=dummy

snap() {
  # snap <name> <scene-args...>
  local name="$1"; shift
  if ./build/tools/shot "$OUT/$name.ppm" "$@"; then
    convert "$OUT/$name.ppm" "$OUT/$name.png" && rm -f "$OUT/$name.ppm"
    echo "  $OUT/$name.png"
  else
    echo "  FAILED: $name ($*)"
  fi
}

if [ "$#" -eq 0 ]; then
  set -- title world combat map:TOWN:6:3:E
fi

for s in "$@"; do
  case "$s" in
    map:*)
      IFS=: read -r _ m x y d <<< "$s"
      snap "map_${m}_${x}_${y}" map "$m" "$x" "$y" "$d"
      ;;
    *)
      snap "$s" "$s"
      ;;
  esac
done

echo "done -> $OUT"
