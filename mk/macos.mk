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

macos: $(PAK)
	@test -n "$(OSX_SDK)" || { echo "Put the MacOSX*.sdk.tar.* SDK in docker/macos-cross/ (see its README)"; exit 1; }
	docker build -t $(MACOS_IMAGE) \
	  --build-arg OSX_SDK="$(OSX_SDK)" \
	  --build-arg DARWIN_VER="$(DARWIN_VER)" \
	  docker/macos-cross
	docker run --rm -v "$(CURDIR)":/src -w /src $(MACOS_IMAGE) bash scripts/build-macos.sh

# Package the macOS arm64 build as a release archive, matching the release
# workflow's layout, for the local backfill the release step cannot run on CI.
# Pass VER as the tag, e.g. make macos-dist VER=v0.24.0, then:
#   gh release upload $(VER) dist/crawler-$(VER)-macos-aarch64.tar.gz --repo OrangeTide/crawler
VER ?= dev
macos-dist: macos
	@pkg="crawler-$(VER)-macos-aarch64"; \
	rm -rf "dist/$$pkg" && mkdir -p "dist/$$pkg"; \
	cp build/crawler-macos-aarch64 "dist/$$pkg/crawler"; \
	cp build/game.pak README.md "dist/$$pkg/"; \
	tar -C dist -czf "dist/$$pkg.tar.gz" "$$pkg"; \
	echo "packaged dist/$$pkg.tar.gz"
