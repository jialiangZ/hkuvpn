#!/usr/bin/env bash
# Build the native HKUVPN.exe (Win32, MinGW-w64 target).
#
# Toolchain: llvm-mingw (Linux-hosted, no root needed). Fetch once with:
#   https://github.com/mstorsjo/llvm-mingw/releases/latest
#   .../llvm-mingw-*-ucrt-ubuntu-*-x86_64.tar.xz -> ~/tools/
# (Any x86_64-w64-mingw32-g++ + windres works too; see the fallbacks below.)
set -euo pipefail
cd "$(dirname "$0")"

TC=""
for d in "$HOME"/tools/llvm-mingw-*; do [ -d "$d" ] && TC="$d" && break; done

if [ -n "$TC" ]; then
    CXX="$TC/bin/x86_64-w64-mingw32-clang++"
    RC="$TC/bin/llvm-rc"
else
    CXX="$(command -v x86_64-w64-mingw32-g++)" || true
    RC="$(command -v x86_64-w64-mingw32-windres)" || true
    [ -n "$CXX" ] && [ -n "$RC" ] || { echo "no cross toolchain found (llvm-mingw in ~/tools, or apt install g++-mingw-w64-x86-64)"; exit 1; }
fi

"$RC" /fo app.res app.rc
mkdir -p publish
"$CXX" -std=c++17 -O2 -municode -mwindows -static \
    -D_WIN32_WINNT=0x0A00 -DWINVER=0x0A00 -DNTDDI_VERSION=0x0A00000A \
    -Wall -Wno-unused-parameter \
    main.cpp app.res -o publish/HKUVPN.exe \
    -lgdi32 -lcomctl32 -lshell32 -ldwmapi -luser32 -lkernel32
ls -la publish/HKUVPN.exe
