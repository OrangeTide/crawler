FPC      ?= fpc
MODE     ?= -O2
FPCFLAGS  = -Mobjfpc -Scghi $(MODE) -Fusrc -FEbuild -FUbuild
TOOLFLAGS = -Mobjfpc -Scghi $(MODE) -Fusrc -FEbuild/tools -FUbuild/tools
TARGET    = build/crawler
PAK       = build/game.pak
MKASSETS  = build/tools/mkassets

.PHONY: all run clean tools

all: $(TARGET) $(PAK)

$(TARGET): crawler.lpr src/*.pas | build
	$(FPC) $(FPCFLAGS) -o$(TARGET) crawler.lpr

tools: $(MKASSETS)

$(MKASSETS): tools/mkassets.pas src/*.pas | build
	mkdir -p build/tools
	$(FPC) $(TOOLFLAGS) -o$(MKASSETS) tools/mkassets.pas

$(PAK): $(MKASSETS)
	$(MKASSETS) $(PAK)

build:
	mkdir -p build

run: all
	./$(TARGET)

clean:
	rm -rf build
