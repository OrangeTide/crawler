FPC      ?= fpc
MODE     ?= -O2
FPCFLAGS  = -Mobjfpc -Scghi $(MODE) -Fusrc -FEbuild -FUbuild
TOOLFLAGS = -Mobjfpc -Scghi $(MODE) -Fusrc -FEbuild/tools -FUbuild/tools
TESTFLAGS = -Mobjfpc -Scghi $(MODE) -Fusrc -Futests -FEbuild/tests -FUbuild/tests
TESTSRC   = $(wildcard tests/t_*.pas)
TARGET    = build/crawler
PAK       = build/game.pak
MKASSETS  = build/tools/mkassets
MAPS      = $(wildcard content/maps/*.map)
ITEMS     = content/items.txt
MONSTERS  = content/monsters.txt
SPECIES   = content/species.txt
CLASSES   = content/classes.txt
BACKG     = content/backgrounds.txt
DIALOGS   = content/dialogs.txt
WORLD     = content/world.txt
CONTENT   = $(ITEMS) $(MONSTERS) $(SPECIES) $(CLASSES) $(BACKG) $(DIALOGS) \
            $(WORLD) $(MAPS)
MAPARGS   = $(foreach m,$(MAPS),map $(m))
TABLEARGS = items $(ITEMS) monsters $(MONSTERS) species $(SPECIES) \
            classes $(CLASSES) backgrounds $(BACKG) dialogs $(DIALOGS) \
            world $(WORLD)

.PHONY: all run clean tools test

all: $(TARGET) $(PAK)

$(TARGET): crawler.lpr src/*.pas | build
	$(FPC) $(FPCFLAGS) -o$(TARGET) crawler.lpr

tools: $(MKASSETS)

$(MKASSETS): tools/mkassets.pas src/*.pas | build
	mkdir -p build/tools
	$(FPC) $(TOOLFLAGS) -o$(MKASSETS) tools/mkassets.pas

$(PAK): $(MKASSETS) $(CONTENT)
	$(MKASSETS) $(PAK) $(TABLEARGS) $(MAPARGS)

build:
	mkdir -p build

run: all
	./$(TARGET)

test: $(PAK)
	@mkdir -p build/tests
	@fail=0; \
	for s in $(TESTSRC); do \
	  b=build/tests/`basename $$s .pas`; \
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
