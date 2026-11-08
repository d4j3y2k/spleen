#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
./scripts/build.sh
PACKAGE_APP="$PWD/build/Spleen.app"
PACKAGE_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PACKAGE_APP/Contents/Info.plist")
[[ "$PACKAGE_VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 'Invalid bundle version'; exit 1; }
PACKAGE_NAME="Spleen-$PACKAGE_VERSION-macos-arm64-local.zip"
mkdir -p dist
/usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$PACKAGE_APP" "$PWD/dist/$PACKAGE_NAME"
(
    cd dist
    /usr/bin/shasum -a 256 "$PACKAGE_NAME" > "$PACKAGE_NAME.sha256"
    /usr/bin/unzip -tq "$PACKAGE_NAME"
)
print "Local development archive: $PWD/dist/$PACKAGE_NAME"
print 'Contains only Spleen.app; no saved state, conversation data, or source history. Signed with the build identity (see scripts/build.sh); not notarized.'
