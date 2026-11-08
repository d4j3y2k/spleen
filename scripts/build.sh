#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/clang-cache .build/swiftpm-cache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/clang-cache"
swift build -c release --product Spleen --disable-sandbox --scratch-path .build --cache-path .build/swiftpm-cache
APP="$PWD/build/Spleen.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Spleen "$APP/Contents/MacOS/Spleen.next"
mv -f "$APP/Contents/MacOS/Spleen.next" "$APP/Contents/MacOS/Spleen"
cp Resources/Info.plist "$APP/Contents/Info.plist"
swiftc Sources/Spleen/SpleenLogo.swift scripts/icon-generator/main.swift -o .build/spleen-icon-generator
.build/spleen-icon-generator .build/Spleen.iconset
iconutil --convert icns .build/Spleen.iconset --output "$APP/Contents/Resources/Spleen.icns"
# Ad-hoc signatures change every build, and macOS keys the Accessibility grant to the
# signature, so each rebuild silently lost Claude/Codex observation. A certificate
# identity keeps the same designated requirement across builds. Override with
# SPLEEN_SIGN_IDENTITY; set it to "-" for an ad-hoc build.
SIGN_IDENTITY="${SPLEEN_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
  | awk -F'"' '/Developer ID Application|Apple Development/ { print $2; exit }')}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
codesign --force --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict "$APP"
print "Built: $APP"
print "Signed with: $SIGN_IDENTITY"
