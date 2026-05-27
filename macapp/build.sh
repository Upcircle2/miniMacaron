#!/bin/bash
# Swift Package → 메뉴바 .app 번들 조립 (xcodegen/Xcode GUI 불필요).
set -euo pipefail
cd "$(dirname "$0")"

echo "[1/3] swift build (release)…"
swift build -c release

APP="build/miniMacaron.app"
echo "[2/3] .app 번들 조립: $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/release/miniMacaron" "$APP/Contents/MacOS/miniMacaron"
cp "Info.plist" "$APP/Contents/Info.plist"

echo "[3/3] 완료. 실행:"
echo "  open $PWD/$APP"
