#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
BUILD_ROOT="${SPLEEN_BUILD_ROOT:-$PWD/.build}"
OUTPUT_DIR="${SPLEEN_OUTPUT_DIR:-$PWD/build}"
mkdir -p "$BUILD_ROOT" "$OUTPUT_DIR"
BUILD_ROOT="${BUILD_ROOT:A}"
OUTPUT_DIR="${OUTPUT_DIR:A}"
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_ROOT/clang-cache"
BUILD_ARGS=(-c release --arch arm64 --disable-sandbox --scratch-path "$BUILD_ROOT" --cache-path "$BUILD_ROOT/swiftpm-cache"
  -Xswiftc -gnone
  -Xswiftc -file-prefix-map -Xswiftc "$PWD=."
  -Xswiftc -file-prefix-map -Xswiftc "$BUILD_ROOT=./.build"
  -Xswiftc -debug-prefix-map -Xswiftc "$HOME=/redacted"
  -Xswiftc -file-compilation-dir -Xswiftc .)
swift build "${BUILD_ARGS[@]}" --product Spleen
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
STAGE="$(mktemp -d "$OUTPUT_DIR/.spleen-build.XXXXXX")"
trap 'rm -rf -- "$STAGE"' EXIT
APP="$STAGE/Spleen.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Spleen" "$APP/Contents/MacOS/Spleen"
cp Resources/Info.plist "$APP/Contents/Info.plist"
swiftc Sources/Spleen/SpleenLogo.swift scripts/icon-generator/main.swift -o "$BUILD_ROOT/spleen-icon-generator"
"$BUILD_ROOT/spleen-icon-generator" "$BUILD_ROOT/Spleen.iconset"
iconutil --convert icns "$BUILD_ROOT/Spleen.iconset" --output "$APP/Contents/Resources/Spleen.icns"
# Release SwiftPM binaries can retain debug paths. Remove debug symbols before signing.
/usr/bin/strip -S "$APP/Contents/MacOS/Spleen"
# Keep the stable source-build identity when one is available, preserving grants.
SIGN_IDENTITY="${SPLEEN_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$( { security find-identity -v -p codesigning 2>/dev/null || true; } | awk '/Developer ID Application|Apple Development/ { print $2; exit }')"
fi
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
SIGN_ARGS=()
if [[ "$SIGN_IDENTITY" == '-' ]]; then
  codesign --force --options runtime --timestamp=none "${SIGN_ARGS[@]}" --sign - "$APP"
else
  codesign --force --options runtime --timestamp "${SIGN_ARGS[@]}" --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"
python3 scripts/validate-package.py "$APP"
if [[ -e "$OUTPUT_DIR/Spleen.app" || -L "$OUTPUT_DIR/Spleen.app" ]]; then
  [[ -d "$OUTPUT_DIR/Spleen.app" && ! -L "$OUTPUT_DIR/Spleen.app" ]] || { print -u2 'Unsafe build output destination'; exit 1; }
  mv "$OUTPUT_DIR/Spleen.app" "$STAGE/Previous.app"
fi
if ! mv "$APP" "$OUTPUT_DIR/Spleen.app"; then
  [[ ! -d "$STAGE/Previous.app" ]] || mv "$STAGE/Previous.app" "$OUTPUT_DIR/Spleen.app"
  exit 1
fi

print "Built: $OUTPUT_DIR/Spleen.app (arm64)"
print 'Signing is separate from notarization; see docs/DISTRIBUTION.md.'
