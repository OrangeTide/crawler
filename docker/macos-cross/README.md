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

## One-time: supply the SDL2 dylib

The packaged `.app` bundles SDL2 so a download needs no Homebrew. Unlike the
SDK, SDL2 is redistributable (zlib license), so you may ship it. Supply the
official arm64 macOS build, which depends only on system frameworks.

On a Mac, or from the SDL2 release's `SDL2-2.x.y.dmg`
(<https://github.com/libsdl-org/SDL/releases>, the SDL2 line), take the
framework's binary and drop it here as `libSDL2.dylib`:

```sh
cp /Library/Frameworks/SDL2.framework/Versions/A/SDL2 libSDL2.dylib
scp libSDL2.dylib <user>@<linux-host>:~/Vibe/crawler/docker/macos-cross/
```

It is git-ignored here. The game `dlopen`s it from the app's
`Contents/Frameworks` by absolute path, so its install name does not matter.

## Build

From the repository root:

```sh
make macos DARWIN_VER=24      # 24 for a macOS 15 SDK; 23 for 14, 25 for 26
```

This builds `build/crawler-macos-aarch64`, a loose binary that still loads a
system or Homebrew SDL2 (`brew install sdl2`) by name. To make the shipping
bundle instead, which carries its own SDL2 and needs no Homebrew:

```sh
make macos-dist VER=v0.27.1   # builds dist/crawler-vX.Y.Z-macos-aarch64.tar.gz
```

That archive holds `Crawler.app` (binary, bundled SDL2, `game.pak`, Info.plist)
alongside the README and CREDITS. Copy it to a Mac, unzip, and open the app.

## Notes

The first image build is long: it compiles OSXCross and an FPC Darwin
cross-compiler with its RTL, then caches both in the image. Later `make macos`
runs reuse the cache and only recompile the game. Because SDL2 is loaded at
runtime, nothing links against it in the cross build; only libSystem from the
SDK is needed to link.
