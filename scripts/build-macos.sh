#!/usr/bin/env bash
# Cross-compile the game to a macOS arm64 binary. Runs inside the
# docker/macos-cross image, with the repository mounted at /src.
#
# It calls the FPC Darwin cross compiler (ppcrossa64) directly, pointing it at
# the installed darwin RTL units, the OSXCross binutils, and the staged SDK.
# SDL2 is loaded at runtime, so this links only against libSystem from the SDK.
# The result is a Darwin arm64 Mach-O that must be run on a Mac; pair it with
# build/game.pak, which the host "make" produces.
set -euo pipefail

SDK=$(ls -d /opt/osxcross/target/SDK/MacOSX*.sdk | grep -E 'MacOSX[0-9]+\.[0-9]+\.sdk$' | head -n1)
PPC=$(command -v ppcrossa64 || find /opt/fpc-darwin -name ppcrossa64 | head -n1)
SYSPPU=$(find /opt/fpc-darwin -path '*aarch64-darwin*' -name system.ppu | head -n1)
UROOT=$(dirname "$(dirname "$SYSPPU")")   # .../units/aarch64-darwin
PREFIX="aarch64-apple-darwin${DARWIN_VER:-24}-"
OUT=build/crawler-macos-aarch64

# One -Fu per installed package directory (the FPC path wildcard does not
# expand on the command line, so enumerate them).
UFLAGS=()
for d in "$UROOT"/*/; do UFLAGS+=("-Fu${d%/}"); done

echo "compiler: $PPC"
echo "SDK:      $SDK"
echo "units:    $UROOT (${#UFLAGS[@]} package dirs)"

mkdir -p build/macos-units
# ppcrossa64 fixes the CPU (aarch64) but defaults the OS to the host, so
# -Tdarwin is required. -n skips the host (linux) fpc.cfg; all darwin paths are
# given explicitly. -FD/-XP select the OSXCross binutils, -XR the SDK sysroot.
"$PPC" -n -Tdarwin -Paarch64 -Mobjfpc -Scghi -O2 \
  -Fusrc -Fibuild -FEbuild -FUbuild/macos-units \
  "${UFLAGS[@]}" \
  -FD/opt/osxcross/target/bin -XP"$PREFIX" \
  -XR"$SDK" \
  -o"$OUT" crawler.lpr

echo "---"
ls -la "$OUT"
magic=$(od -An -tx1 -N4 "$OUT" | tr -d ' ')
echo "Mach-O magic: $magic (cffaedfe = 64-bit arm64/little-endian)"
echo "built $OUT  (copy it plus build/game.pak to a Mac to run)"
