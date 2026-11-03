#!/usr/bin/env bash
# Build the HKU VPN desktop app (MyGo native UI) for Windows.
#
# Go 1.27+ is required and no C toolchain: MyGo is pure Go and draws with
# Direct3D 11 on Windows.
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v go >/dev/null 2>&1; then
    export PATH="$HOME/tools/go/bin:$PATH"
fi

mkdir -p publish
GOOS=windows GOARCH=amd64 go build -trimpath -ldflags "-s -w" -o publish/HKUVPN.exe .
ls -la publish/HKUVPN.exe
