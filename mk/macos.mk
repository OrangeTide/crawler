# Cross-build a macOS arm64 binary from Linux through the docker image.
# Rarely needed, so it lives here and is pulled in by the main Makefile's
# "-include mk/*.mk". Place the macOS SDK tarball in docker/macos-cross/ first
# (see its README) and pass DARWIN_VER for your SDK (macOS 13->22, 14->23,
# 15->24, 26->25). The data pak is host-built and platform neutral, so ship
# build/game.pak beside the binary.

.PHONY: macos macos-dist

MACOS_IMAGE ?= crawler-macos-cross
OSX_SDK     ?= $(notdir $(firstword $(wildcard docker/macos-cross/MacOSX*.sdk.tar.*)))
DARWIN_VER  ?= 24

macos: $(PAK) build/version.inc
	@test -n "$(OSX_SDK)" || { echo "Put the MacOSX*.sdk.tar.* SDK in docker/macos-cross/ (see its README)"; exit 1; }
	docker build -t $(MACOS_IMAGE) \
	  --build-arg OSX_SDK="$(OSX_SDK)" \
	  --build-arg DARWIN_VER="$(DARWIN_VER)" \
	  docker/macos-cross
	docker run --rm -v "$(CURDIR)":/src -w /src $(MACOS_IMAGE) bash scripts/build-macos.sh

# Package the macOS arm64 build as a self-contained Crawler.app, bundling SDL2
# so the download needs no Homebrew. Pass VER as the tag, e.g.
# make macos-dist VER=v0.24.0, then:
#   gh release upload $(VER) dist/crawler-$(VER)-macos-aarch64.tar.gz --repo OrangeTide/crawler
#
# You supply the macOS arm64 SDL2 dylib (zlib-licensed and redistributable,
# unlike the SDK): place the official framework's binary at the path below. See
# docker/macos-cross/README.md. The game dlopens it from Contents/Frameworks.
VER        ?= dev
MACOS_SDL2 ?= docker/macos-cross/libSDL2.dylib
macos-dist: macos
	@test -f "$(MACOS_SDL2)" || { echo "Put a macOS arm64 libSDL2.dylib at $(MACOS_SDL2) (see docker/macos-cross/README.md)"; exit 1; }
	@pkg="crawler-$(VER)-macos-aarch64"; app="dist/$$pkg/Crawler.app"; \
	rm -rf "dist/$$pkg"; \
	mkdir -p "$$app/Contents/MacOS" "$$app/Contents/Frameworks" "$$app/Contents/Resources"; \
	cp build/crawler-macos-aarch64 "$$app/Contents/MacOS/crawler"; \
	cp "$(MACOS_SDL2)" "$$app/Contents/Frameworks/libSDL2.dylib"; \
	cp build/game.pak "$$app/Contents/Resources/game.pak"; \
	sed 's/@VERSION@/$(PROJ_VERSION)/g' mk/macos-info.plist.in > "$$app/Contents/Info.plist"; \
	cp README.md CREDITS "dist/$$pkg/"; \
	tar -C dist -czf "dist/$$pkg.tar.gz" "$$pkg"; \
	echo "packaged dist/$$pkg.tar.gz"
