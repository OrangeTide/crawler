FPC      ?= fpc
MODE     ?= -O2
FPCFLAGS  = -Mobjfpc -Scghi $(MODE) -Fusrc -FEbuild -FUbuild
TARGET    = build/crawler

.PHONY: all run clean

all: $(TARGET)

$(TARGET): crawler.lpr src/*.pas | build
	$(FPC) $(FPCFLAGS) -o$(TARGET) crawler.lpr

build:
	mkdir -p build

run: all
	./$(TARGET)

clean:
	rm -rf build
