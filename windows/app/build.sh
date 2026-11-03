#!/usr/bin/env bash
# Build the native HKUVPN.exe (RmlUi frontend, MinGW-w64 target).
#
# Toolchain: llvm-mingw (Linux-hosted, no root needed). Fetch once with:
#   https://github.com/mstorsjo/llvm-mingw/releases/latest
#   .../llvm-mingw-*-ucrt-ubuntu-*-x86_64.tar.xz -> ~/tools/
#
# The RmlUi library (rml/build/rmlui) and FreeType (rml/install) are
# cross-built once with the helper below:
#   ./build.sh deps      # build RmlUi + FreeType (needs cmake + ninja)
#   ./build.sh           # build HKUVPN.exe
set -euo pipefail
cd "$(dirname "$0")"

TC=""
for d in "$HOME"/tools/llvm-mingw-*; do [ -d "$d" ] && TC="$d" && break; done
if [ -z "$TC" ]; then
    echo "no llvm-mingw toolchain in ~/tools"; exit 1
fi
CXX="$TC/bin/x86_64-w64-mingw32-clang++"
RC="$TC/bin/llvm-rc"

build_deps() {
    cmake="$(command -v cmake)"; ninja="$(command -v ninja)"
    [ -n "$cmake" ] || cmake="$(ls -d /tmp/opencode/buildenv/bin/cmake 2>/dev/null | head -1)"
    [ -n "$ninja" ] || ninja="$(ls -d /tmp/opencode/buildenv/bin/ninja 2>/dev/null | head -1)"
    [ -n "$cmake" ] && [ -n "$ninja" ] || { echo "cmake + ninja needed for deps build (pip install cmake ninja)"; exit 1; }

    [ -d rml/freetype-2.13.3 ] || { echo "rml/freetype-2.13.3 missing - run the bootstrap notes in build.sh"; exit 1; }

    "$cmake" -S rml/freetype-2.13.3 -B rml/build/freetype -G Ninja \
      -DCMAKE_SYSTEM_NAME=Windows \
      -DCMAKE_C_COMPILER="$TC/bin/x86_64-w64-mingw32-clang" \
      -DCMAKE_CXX_COMPILER="$TC/bin/x86_64-w64-mingw32-clang++" \
      -DCMAKE_RC_COMPILER="$TC/bin/x86_64-w64-mingw32-windres" \
      -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
      -DFT_DISABLE_ZLIB=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_PNG=ON \
      -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON \
      -DCMAKE_INSTALL_PREFIX="$PWD/rml/install"
    "$cmake" --build rml/build/freetype
    "$cmake" --install rml/build/freetype

    "$cmake" -S rml/RmlUi -B rml/build/rmlui -G Ninja \
      -DCMAKE_SYSTEM_NAME=Windows \
      -DCMAKE_C_COMPILER="$TC/bin/x86_64-w64-mingw32-clang" \
      -DCMAKE_CXX_COMPILER="$TC/bin/x86_64-w64-mingw32-clang++" \
      -DCMAKE_RC_COMPILER="$TC/bin/x86_64-w64-mingw32-windres" \
      -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
      -DRMLUI_SAMPLES=OFF -DRMLUI_TESTS=OFF \
      -DCMAKE_DISABLE_PRECOMPILE_HEADERS=ON \
      -DFREETYPE_LIBRARY="$PWD/rml/install/lib/libfreetype.a" \
      -DFREETYPE_INCLUDE_DIRS="$PWD/rml/install/include/freetype2"
    "$cmake" --build rml/build/rmlui
    echo "deps built"
    exit 0
}
[ "${1:-}" = "deps" ] && build_deps

"$RC" /fo app.res app.rc
mkdir -p publish
"$CXX" -std=c++17 -O2 -municode -mwindows -static \
    -D_WIN32_WINNT=0x0A00 -DWINVER=0x0A00 -DNTDDI_VERSION=0x0A00000A \
    -Wall -Wno-unused-parameter \
    -I rml/RmlUi/Include \
    main.cpp \
    RmlUi_Platform_Win32.cpp RmlUi_Renderer_GL2.cpp RmlUi_Backend_Win32_GL2.cpp \
    rml/build/rmlui/librmlui.a rml/install/lib/libfreetype.a \
    app.res -o publish/HKUVPN.exe \
    -lopengl32 -lgdi32 -lcomctl32 -lshell32 -ldwmapi -luser32 -lkernel32 -limm32 -lshlwapi -lwinmm -lws2_32
ls -la publish/HKUVPN.exe
