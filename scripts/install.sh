#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
# Build locally, then install for this account. Never requires sudo or changes grants.
INSTALL_DIR="${SPLEEN_INSTALL_DIR:-$HOME/Applications}"
INSTALL_APP="$INSTALL_DIR/Spleen.app"
if pgrep -x Spleen >/dev/null; then
  print -u2 'Quit Spleen from its menu bar before installing or updating.'
  exit 1
fi
if [[ -e "$INSTALL_APP" || -L "$INSTALL_APP" ]]; then
  [[ ! -L "$INSTALL_APP" && -d "$INSTALL_APP" ]] || { print -u2 'Refusing to replace a symlink or non-app file.'; exit 1; }
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALL_APP/Contents/Info.plist")" == 'com.davidkim.spleen' ]] || { print -u2 'Destination belongs to another application.'; exit 1; }
fi
./scripts/build.sh
mkdir -p "$INSTALL_DIR"
INSTALL_STAGE="$(mktemp -d "$INSTALL_DIR/.spleen-install.XXXXXX")"
trap 'rm -rf -- "$INSTALL_STAGE"' EXIT
ditto --norsrc --noextattr build/Spleen.app "$INSTALL_STAGE/Spleen.app"
codesign --verify --strict "$INSTALL_STAGE/Spleen.app"
if [[ -d "$INSTALL_APP" ]]; then mv "$INSTALL_APP" "$INSTALL_STAGE/Previous.app"; fi
if ! mv "$INSTALL_STAGE/Spleen.app" "$INSTALL_APP"; then
  if [[ -d "$INSTALL_STAGE/Previous.app" ]]; then mv "$INSTALL_STAGE/Previous.app" "$INSTALL_APP"; fi
  exit 1
fi
print "Installed: $INSTALL_APP"
print "Open with: open \"$INSTALL_APP\""
