# macOS arm64 cross-build

Build a macOS Apple Silicon binary of the game from Linux, for a quick manual
test before, or instead of, waiting for the macOS CI leg. A Linux host can
compile and link a Darwin binary but cannot run it, so copy the result to a Mac
to launch it.

## One-time: supply the macOS SDK

OSXCross cannot download Apple's SDK, and the SDK is not redistributable
(Apple's license ties its use to Apple hardware), so you package it yourself on
a Mac that has Xcode or the Command Line Tools.

On the Mac:

```sh
git clone https://github.com/tpoechtrager/osxcross
cd osxcross
./tools/gen_sdk_package.sh          # with full Xcode installed
# or, Command Line Tools only (no Xcode.app):
./tools/gen_sdk_package_tools.sh
```

That packages whatever SDK your current Xcode ships. On a recent Mac that is
the newest SDK (macOS 26, Darwin 25), which OSXCross and FPC may not yet handle
cleanly. For a smoother build, use an older, well-tested SDK (macOS 15, Darwin
24, is the sweet spot).

To get an older SDK cleanly, download the Command Line Tools for an older Xcode
from <https://developer.apple.com/download/all/> (a free Apple ID): the CLT for
Xcode 16.2 carries `MacOSX15.sdk`, and for Xcode 15.x it is `MacOSX14.sdk`.
Install it, then package the SDK directly:

```sh
cd /Library/Developer/CommandLineTools/SDKs
tar -cJf ~/MacOSX15.sdk.tar.xz MacOSX15.sdk
```

Either way, copy the tarball into this folder:

```sh
scp MacOSX*.sdk.tar.xz <user>@<linux-host>:~/Vibe/crawler/docker/macos-cross/
```

The tarball is git-ignored here and must stay out of the repository. Avoid the
community SDK mirrors for anything you ship: they redistribute Apple's SDK
outside its license.

Note the SDK's macOS major version; it sets the Darwin number the toolchain
uses: macOS 13 is Darwin 22, macOS 14 is Darwin 23, macOS 15 is Darwin 24,
macOS 26 is Darwin 25. A mid-range SDK (14 or 15) is the best tested with
OSXCross; a very new SDK (26) may need OSXCross at HEAD (the Dockerfile already
clones that) and, if the link fails, a newer FPC via the FPC_TAG build arg.

## Build

From the repository root:

```sh
make macos DARWIN_VER=24      # 24 for a macOS 15 SDK; 23 for 14, 25 for 26
```

This builds `build/crawler-macos-aarch64`. The data pak is platform neutral and
host-built, so ship it alongside:

```sh
scp build/crawler-macos-aarch64 build/game.pak <user>@<mac>:~/crawler/
# on the Mac:
mv crawler-macos-aarch64 crawler && ./crawler
```

The Mac needs the SDL2 runtime (`brew install sdl2`), which the program loads by
name at startup.

## Notes

The first image build is long: it compiles OSXCross and an FPC Darwin
cross-compiler with its RTL, then caches both in the image. Later `make macos`
runs reuse the cache and only recompile the game. Because SDL2 is loaded at
runtime, nothing links against it in the cross build; only libSystem from the
SDK is needed to link.
