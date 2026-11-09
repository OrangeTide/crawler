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
SPELLS    = content/spells.txt
SKILLS    = content/skills.txt
SHOPS     = content/shops.txt
ENCOUNTERS = content/encounters.txt
WORLD     = content/world.txt
# Prop meshes only; monsters and NPCs are billboard sprites (see SPRITENAMES).
MODELNAMES = barrel doorway
MODELSRC  = $(foreach n,$(MODELNAMES),content/models/$(n).obj content/models/$(n).ppm)
# Modular kit tiles: shared-texture meshes baked from SigilsVault GLBs (OBJ
# only), all drawing from one trim-sheet atlas. The theme G proof set.
TILENAMES = mod_floor mod_wall mod_ceil mod_pillar
TILESRC   = $(foreach n,$(TILENAMES),content/rooms/pieces/$(n).obj)
TRIMSRC   = content/rooms/trim_mossy.ppm
# Billboard sprites: a PNG per id in content/sprites, keyed to magenta and
# compiled to a PIC lump. Omit a monster's id here to fall back to a glyph.
SPRITENAMES = crea1 crea2 crea3 crea4 crea5 crea6 crea7 crea8 crea9 \
              crea10 crea11 crea12 crea13 crea14 crea15 crea16 \
              flesh1 flesh2 npc \
              npc_elder npc_ranger npc_hunter npc_ferry npc_barkeep \
              npc_apoth npc_altar npc_shrine1 npc_shrine2 \
              exit_door exit_up exit_down exit_ladder exit_cave exit_shaft
SPRITESRC = $(foreach n,$(SPRITENAMES),content/sprites/$(n).ppm)
# NPC dialog portraits: a 64x64 PNG per dialog id in content/portraits,
# keyed to magenta and baked to a PORT_<ID> PIC lump via the sprite path.
PORTRAITNAMES = port_elder port_barkeep port_apothecary port_ranger \
                port_hunter port_dockhand
PORTRAITSRC = $(foreach n,$(PORTRAITNAMES),content/portraits/$(n).ppm)
# Player-character portrait pool: pc00..pcNN in content/portraits, baked the
# same way to PORT_PC<NN> lumps. A new character cycles through these at
# creation, and the chosen face shows in the party strip.
PCPORTRAITIDS = $(shell seq -w 0 23)
PCPORTRAITSRC = $(foreach i,$(PCPORTRAITIDS),content/portraits/pc$(i).ppm)
# Spell icons: the Batareya mage-icon faces that content/spells.txt names, one
# si<NN>.png per icon, baked the same way to SI<NN> lumps. The set is whatever
# PNGs are present in content/icons.
SPELLICONPNG = $(wildcard content/icons/si*.png)
SPELLICONSRC = $(SPELLICONPNG:.png=.ppm)
# Skill icons: the Batareya warrior-icon faces that content/skills.txt names,
# one wi<N>.png per icon in content/skillicons, baked to WI<N> lumps.
SKILLICONPNG = $(wildcard content/skillicons/wi*.png)
SKILLICONSRC = $(SKILLICONPNG:.png=.ppm)
# Title background: a 320x240 scene (from Jon's photo) and its own 256-colour
# palette, baked to TITLE_BG and TITLE_PAL PIC lumps via the sprite path. The
# title swaps this palette in, PlayStation 8-bit-CLUT style, for a smooth scene.
TITLEBGSRC = content/title/title_bg.ppm content/title/title_pal.ppm
# music tracks: each lump name paired with its module file. Files may be
# absent; a missing track just stays silent.
MUSICTRACKS = MUS_TITLE:title MUS_TOWN:town MUS_DUNGEON:dungeon MUS_COMBAT:combat
MUSICSRC  = $(foreach t,$(MUSICTRACKS),$(wildcard content/music/$(word 2,$(subst :, ,$(t))).*))
CONTENT   = $(ITEMS) $(MONSTERS) $(SPECIES) $(CLASSES) $(BACKG) $(DIALOGS) \
            $(SPELLS) $(SKILLS) $(SHOPS) $(ENCOUNTERS) $(WORLD) $(MAPS) \
            $(MODELSRC) $(TILESRC) $(TRIMSRC) $(SPRITESRC) $(PORTRAITSRC) \
            $(PCPORTRAITSRC) $(SPELLICONSRC) $(SKILLICONSRC) $(TITLEBGSRC) \
            $(MUSICSRC)
MAPARGS   = $(foreach m,$(MAPS),map $(m))
MODELARGS = $(foreach n,$(MODELNAMES),model $(n) content/models/$(n).obj content/models/$(n).ppm)
# Modular tiles share the trim atlas, so they bake with the tile verb (no
# per-piece texture) and the atlas bakes once onto the modular tileset.
TILEARGS  = $(foreach n,$(TILENAMES),tile $(n) content/rooms/pieces/$(n).obj 256)
TRIMARG   = trim 9 content/rooms/trim_mossy.ppm
SPRITEARGS = $(foreach n,$(SPRITENAMES),sprite $(n) content/sprites/$(n).ppm)
PORTRAITARGS = $(foreach n,$(PORTRAITNAMES),sprite $(n) content/portraits/$(n).ppm)
PCPORTRAITARGS = $(foreach i,$(PCPORTRAITIDS),sprite port_pc$(i) content/portraits/pc$(i).ppm)
SPELLICONARGS = $(foreach f,$(SPELLICONPNG),sprite $(basename $(notdir $(f))) $(f:.png=.ppm))
SKILLICONARGS = $(foreach f,$(SKILLICONPNG),sprite $(basename $(notdir $(f))) $(f:.png=.ppm))
TITLEBGARG = sprite TITLE_BG content/title/title_bg.ppm \
             sprite TITLE_PAL content/title/title_pal.ppm
MUSICARGS = $(foreach t,$(MUSICTRACKS),music $(word 1,$(subst :, ,$(t))) \
            $(firstword $(wildcard content/music/$(word 2,$(subst :, ,$(t))).*) content/music/$(word 2,$(subst :, ,$(t))).mod))
TABLEARGS = items $(ITEMS) monsters $(MONSTERS) species $(SPECIES) \
            classes $(CLASSES) backgrounds $(BACKG) dialogs $(DIALOGS) \
            spells $(SPELLS) skills $(SKILLS) shops $(SHOPS) \
            encounters $(ENCOUNTERS) world $(WORLD)

.PHONY: all run clean tools meshtools shottool test

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

# Headless screenshot tool: renders a real game screen (title, world,
# a map at a position, or combat) to a PPM with no window, via SDL's
# dummy video driver. Used by the headless-run skill.
shottool: build/tools/shot

build/tools/shot: tools/shot.pas src/*.pas | build
	mkdir -p build/tools
	$(FPC) $(TOOLFLAGS) -obuild/tools/shot tools/shot.pas

$(PAK): $(MKASSETS) $(CONTENT)
	$(MKASSETS) $(PAK) $(TABLEARGS) $(MAPARGS) $(MODELARGS) $(TILEARGS) $(TRIMARG) $(SPRITEARGS) $(PORTRAITARGS) $(PCPORTRAITARGS) $(SPELLICONARGS) $(SKILLICONARGS) $(TITLEBGARG) $(MUSICARGS)

# Billboard source: a PNG (with alpha) flattened onto the magenta key and
# scaled to a billboard-sized PPM for the asset builder.
content/sprites/%.ppm: content/sprites/%.png
	convert $< -filter point -resize 64x96 -alpha on -channel A -threshold 50% +channel \
	  -background '#FF00FF' -flatten -depth 8 ppm:$@

# Portrait source: a 64x64 PNG (with alpha) flattened onto the magenta key.
# Kept at native size, no scaling, so the face stays square.
content/portraits/%.ppm: content/portraits/%.png
	convert $< -alpha on -channel A -threshold 50% +channel \
	  -background '#FF00FF' -flatten -depth 8 ppm:$@

# Spell icon source: a 64x64 PNG, opaque, passed through like a portrait.
content/icons/%.ppm: content/icons/%.png
	convert $< -alpha on -channel A -threshold 50% +channel \
	  -background '#FF00FF' -flatten -depth 8 ppm:$@

content/skillicons/%.ppm: content/skillicons/%.png
	convert $< -alpha on -channel A -threshold 50% +channel \
	  -background '#FF00FF' -flatten -depth 8 ppm:$@

# Title background: an opaque 320x240 PNG, already dithered to the palette.
# Passed straight through to a PPM; no resize or colour key.
content/title/%.ppm: content/title/%.png
	convert $< -depth 8 ppm:$@

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
