# Cross-compile the game to macOS arm64 from Linux.
#
# This image carries three layers the host FPC does not: OSXCross (the Darwin
# linker and binutils plus a clang that targets Darwin), the macOS SDK you
# supply, and an FPC Darwin aarch64 cross-compiler with its RTL. SDL2 is loaded
# at runtime, so nothing links against it here; the cross-link only needs
# libSystem from the SDK.
#
# Build args:
#   OSX_SDK     the SDK tarball filename placed in this directory (not committed)
#   DARWIN_VER  the Darwin major that matches the SDK: macOS 13 -> 22,
#               macOS 14 -> 23, macOS 15 -> 24, macOS 26 -> 25. It sets the
#               OSXCross tool prefix.
#   FPC_TAG     the FPC source tag to build the cross-RTL from (match host FPC).
#               A very new SDK may need a newer branch (fixes_3_2 or main) if
#               the 3.2.2 linker invocation is too old for its ld64.

# Ubuntu 24.04 brings clang 18, new enough to parse a modern macOS SDK's
# libc++ headers while building OSXCross. Debian bookworm's clang 14 is not.
FROM ubuntu:24.04

ARG OSX_SDK=MacOSX.sdk.tar.xz
ARG DARWIN_VER=24
ARG FPC_TAG=release_3_2_2

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      git cmake make patch python3 ca-certificates xz-utils cpio bzip2 \
      clang llvm-dev lld libxml2-dev liblzma-dev libssl-dev zlib1g-dev libbz2-dev \
      uuid-dev fpc binutils \
    && rm -rf /var/lib/apt/lists/*

# --- OSXCross: Darwin toolchain built against the supplied SDK ---
# Force clang as the host compiler; the SDK's libc++ headers need it.
WORKDIR /opt
RUN git clone --depth 1 https://github.com/tpoechtrager/osxcross
COPY ${OSX_SDK} /opt/osxcross/tarballs/
RUN cd osxcross && CC=clang CXX=clang++ UNATTENDED=1 \
      TARGET_DIR=/opt/osxcross/target ./build.sh
ENV PATH="/opt/osxcross/target/bin:${PATH}"

# OSXCross names its tools with the full SDK version (aarch64-apple-darwin24.5-*)
# and puts the SDK in MacOSX15.5.sdk, but FPC's BINUTILSPREFIX uses the short
# triple (aarch64-apple-darwin24-) and the generic wrappers look for a major
# -version SDK (MacOSX15.sdk). Alias the short tool names to the real versioned
# ones (clang, ld, ar and the rest are SDK-aware), and add a major-version SDK
# symlink so any generic wrapper finds it too.
RUN set -e; cd /opt/osxcross/target/bin; \
    echo "== tools =="; ls -1 | grep -E 'aarch64-apple-darwin.*(clang|ld|ar|as|strip|ranlib)$' || true; \
    for f in aarch64-apple-darwin${DARWIN_VER}.*; do \
      short=$(printf '%s' "$f" | sed -E "s/darwin${DARWIN_VER}\.[0-9]+-/darwin${DARWIN_VER}-/"); \
      [ "$short" = "$f" ] || [ -e "$short" ] || ln -s "$f" "$short"; \
    done; \
    cd /opt/osxcross/target/SDK; echo "== SDKs =="; ls -1; \
    for d in MacOSX*.sdk; do \
      maj=$(printf '%s' "$d" | sed -E 's/^(MacOSX[0-9]+)\.[0-9]+\.sdk$/\1.sdk/'); \
      [ "$maj" = "$d" ] || [ -e "$maj" ] || ln -sfn "$d" "$maj"; \
    done; \
    echo "== after =="; ls -1

# --- FPC Darwin aarch64 cross-compiler and RTL ---
# crossall builds the compiler and units; crossinstall lays them under
# INSTALL_PREFIX. BINUTILSPREFIX must match the OSXCross tool names on PATH.
RUN git clone --depth 1 -b ${FPC_TAG} \
      https://gitlab.com/freepascal.org/fpc/source.git /opt/fpc-src
RUN cd /opt/fpc-src && \
    make crossall crossinstall \
      FPC=/usr/bin/fpc \
      CPU_TARGET=aarch64 OS_TARGET=darwin \
      BINUTILSPREFIX=aarch64-apple-darwin${DARWIN_VER}- \
      INSTALL_PREFIX=/opt/fpc-darwin \
      NOGDB=1

# crossinstall lays down the compiler as ppcrossa64 (no fpc driver), so expose
# it on PATH. The build script calls it directly with explicit unit and SDK
# paths, which sidesteps the host fpc.cfg.
RUN ln -sf "$(find /opt/fpc-darwin -name ppcrossa64 | head -n1)" /usr/local/bin/ppcrossa64

# Carry the Darwin version into the image so the build script forms the right
# tool prefix (aarch64-apple-darwin<ver>-) without hardcoding it.
ENV DARWIN_VER=${DARWIN_VER}
WORKDIR /src
