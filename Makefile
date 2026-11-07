FPC      ?= fpc
MODE     ?= -O2
# Windows FPC appends .exe to its output; mirror that so the targets and the
# binaries the recipes invoke carry the right name on every host.
ifeq ($(OS),Windows_NT)
  EXE := .exe
else
  EXE :=
endif
FPCFLAGS  = -Mobjfpc -Scghi $(MODE) -Fusrc -FEbuild -FUbuild
TOOLFLAGS = -Mobjfpc -Scghi $(MODE) -Fusrc -FEbuild/tools -FUbuild/tools
TESTFLAGS = -Mobjfpc -Scghi $(MODE) -Fusrc -Futests -FEbuild/tests -FUbuild/tests
TESTSRC   = $(wildcard tests/t_*.pas)
TARGET    = build/crawler$(EXE)
PAK       = build/game.pak
MKASSETS  = build/tools/mkassets$(EXE)
MAPS      = $(wildcard content/maps/*.map)
ITEMS     = content/items.txt
MONSTERS  = content/monsters.txt
SPECIES   = content/species.txt
CLASSES   = content/classes.txt
BACKG     = content/backgrounds.txt
DIALOGS   = content/dialogs.txt
SHOPS     = content/shops.txt
ENCOUNTERS = content/encounters.txt
WORLD     = content/world.txt
# Prop meshes only; monsters and NPCs are billboard sprites (see SPRITENAMES).
MODELNAMES = barrel doorway
MODELSRC  = $(foreach n,$(MODELNAMES),content/models/$(n).obj content/models/$(n).ppm)
# Billboard sprites: a PNG per id in content/sprites, keyed to magenta and
# compiled to a PIC lump. Omit a monster's id here to fall back to a glyph.
SPRITENAMES = crea1 crea2 crea3 crea4 crea5 crea6 crea7 crea8 crea9 \
              crea10 crea11 crea12 crea13 crea14 crea15 crea16 \
              flesh1 flesh2 npc
SPRITESRC = $(foreach n,$(SPRITENAMES),content/sprites/$(n).ppm)
# music tracks: each lump name paired with its module file. Files may be
# absent; a missing track just stays silent.
MUSICTRACKS = MUS_TITLE:title MUS_TOWN:town MUS_DUNGEON:dungeon MUS_COMBAT:combat
MUSICSRC  = $(foreach t,$(MUSICTRACKS),$(wildcard content/music/$(word 2,$(subst :, ,$(t))).*))
CONTENT   = $(ITEMS) $(MONSTERS) $(SPECIES) $(CLASSES) $(BACKG) $(DIALOGS) \
            $(SHOPS) $(ENCOUNTERS) $(WORLD) $(MAPS) $(MODELSRC) $(SPRITESRC) \
            $(MUSICSRC)
MAPARGS   = $(foreach m,$(MAPS),map $(m))
MODELARGS = $(foreach n,$(MODELNAMES),model $(n) content/models/$(n).obj content/models/$(n).ppm)
SPRITEARGS = $(foreach n,$(SPRITENAMES),sprite $(n) content/sprites/$(n).ppm)
MUSICARGS = $(foreach t,$(MUSICTRACKS),music $(word 1,$(subst :, ,$(t))) \
            $(firstword $(wildcard content/music/$(word 2,$(subst :, ,$(t))).*) content/music/$(word 2,$(subst :, ,$(t))).mod))
TABLEARGS = items $(ITEMS) monsters $(MONSTERS) species $(SPECIES) \
            classes $(CLASSES) backgrounds $(BACKG) dialogs $(DIALOGS) \
            shops $(SHOPS) encounters $(ENCOUNTERS) world $(WORLD)

.PHONY: all run clean tools meshtools test

all: $(TARGET) $(PAK)

$(TARGET): crawler.lpr src/*.pas | build
	$(FPC) $(FPCFLAGS) -o$(TARGET) crawler.lpr

tools: $(MKASSETS)

$(MKASSETS): tools/mkassets.pas src/*.pas | build
	mkdir -p build/tools
	$(FPC) $(TOOLFLAGS) -o$(MKASSETS) tools/mkassets.pas

# Mesh pipeline tools. mkmesh bakes an assimp OBJ plus a PPM texture into
# a CMSH lump; meshshot renders a baked mesh to a PPM for inspection.
meshtools: build/tools/mkmesh build/tools/meshshot

build/tools/mkmesh: tools/mkmesh.pas src/*.pas | build
	mkdir -p build/tools
	$(FPC) $(TOOLFLAGS) -obuild/tools/mkmesh tools/mkmesh.pas

build/tools/meshshot: tools/meshshot.pas src/*.pas | build
	mkdir -p build/tools
	$(FPC) $(TOOLFLAGS) -obuild/tools/meshshot tools/meshshot.pas

$(PAK): $(MKASSETS) $(CONTENT)
	$(MKASSETS) $(PAK) $(TABLEARGS) $(MAPARGS) $(MODELARGS) $(SPRITEARGS) $(MUSICARGS)

# Billboard source: a PNG (with alpha) flattened onto the magenta key and
# scaled to a billboard-sized PPM for the asset builder.
content/sprites/%.ppm: content/sprites/%.png
	convert $< -filter point -resize 64x96 -alpha on -channel A -threshold 50% +channel \
	  -background '#FF00FF' -flatten -depth 8 ppm:$@

build:
	mkdir -p build

run: all
	./$(TARGET)

test: $(PAK)
	@mkdir -p build/tests
	@fail=0; \
	for s in $(TESTSRC); do \
	  b=build/tests/`basename $$s .pas`$(EXE); \
	  if ! $(FPC) $(TESTFLAGS) -o$$b $$s > build/tests/compile.log 2>&1; then \
	    echo "COMPILE FAIL: $$s"; cat build/tests/compile.log; fail=1; continue; \
	  fi; \
	  echo "== `basename $$s .pas` =="; \
	  if ! $$b; then fail=1; fi; \
	done; \
	if [ $$fail -ne 0 ]; then echo "SOME TESTS FAILED"; exit 1; fi; \
	echo "ALL TESTS PASSED"

clean:
	rm -rf build

# Optional cross-build targets (macOS, and others later) live in mk/*.mk and
# are pulled in here. They are needed only to produce foreign binaries, so they
# stay out of the way of the common build above. The leading dash keeps make
# quiet when the directory is empty.
-include mk/*.mk
