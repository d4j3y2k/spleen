#!/bin/zsh
# Standalone: uses only tools included with macOS, never builds or downloads code.
set -euo pipefail
APP_NAME='Spleen'
BUNDLE_ID='com.davidkim.spleen'
SOURCE_APP="${0:A:h}/$APP_NAME.app"
INSTALL_DIR="${SPLEEN_INSTALL_DIR:-$HOME/Applications}"
ALLOW_DOWNGRADE=0
fail() { print -u2 -- "$*"; exit 1; }
while (( $# )); do
  case "$1" in
    --app) (( $# >= 2 )) || fail 'Missing --app path'; SOURCE_APP="$2"; shift 2 ;;
    --destination) (( $# >= 2 )) || fail 'Missing --destination folder'; INSTALL_DIR="$2"; shift 2 ;;
    --allow-downgrade) ALLOW_DOWNGRADE=1; shift ;;
    --help) print "Usage: $0 [--app /path/$APP_NAME.app] [--destination folder] [--allow-downgrade]"; exit 0 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done
[[ "$EUID" != 0 ]] || fail 'Run this installer as your own account, without sudo.'
[[ "$(/usr/bin/uname -m)" == arm64 ]] || fail 'This download requires an Apple silicon Mac.'
[[ -d "$SOURCE_APP" && ! -L "$SOURCE_APP" ]] || fail "App bundle not found, or is a symlink: $SOURCE_APP"
SOURCE_APP="${SOURCE_APP:A}"
plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"; }
validate() {
  [[ "$(plist "$1" CFBundleIdentifier)" == "$BUNDLE_ID" ]] || fail 'The app has the wrong bundle identifier.'
  [[ "$(plist "$1" CFBundleExecutable)" == "$APP_NAME" ]] || fail 'The app has an unexpected executable.'
  [[ "$(plist "$1" CFBundlePackageType)" == APPL ]] || fail 'The source is not an application bundle.'
  [[ -f "$1/Contents/MacOS/$APP_NAME" && ! -L "$1/Contents/MacOS/$APP_NAME" ]] || fail 'The app executable is missing or is a symlink.'
  /usr/bin/file -b "$1/Contents/MacOS/$APP_NAME" | /usr/bin/grep -q 'arm64' || fail 'The app does not contain an Apple silicon executable.'
  /usr/bin/codesign --verify --strict "$1" || fail 'The app signature is invalid. Download a fresh copy.'
}
validate "$SOURCE_APP"
MINIMUM="$(plist "$SOURCE_APP" LSMinimumSystemVersion)"
CURRENT="$(/usr/bin/sw_vers -productVersion)"
autoload -Uz is-at-least
is-at-least "$MINIMUM" "$CURRENT" || fail "$APP_NAME requires macOS $MINIMUM or later."
NEW_BUILD="$(plist "$SOURCE_APP" CFBundleVersion)"
[[ "$NEW_BUILD" == <-> ]] || fail 'The new app has an unsupported build number.'
[[ ! -L "$INSTALL_DIR" ]] || fail 'The destination folder must not be a symlink.'
/bin/mkdir -p "$INSTALL_DIR"
INSTALL_DIR="${INSTALL_DIR:A}"
INSTALL_APP="$INSTALL_DIR/$APP_NAME.app"
[[ "$SOURCE_APP" != "$INSTALL_APP" ]] || fail 'Source and destination are the same app.'
LOCK="$INSTALL_DIR/.spleen-install.lock"
/bin/mkdir "$LOCK" 2>/dev/null || fail "Another installation may be in progress. Check $LOCK before retrying."
STAGE=''
COMPLETED=0
cleanup() {
  local result=$?
  # Restore after a failed move or interrupt; never discard the sole old copy.
  if [[ -n "$STAGE" && -d "$STAGE/Previous.app" && "$COMPLETED" == 0 ]]; then
    if [[ ! -e "$INSTALL_APP" && ! -L "$INSTALL_APP" ]]; then
      /bin/mv "$STAGE/Previous.app" "$INSTALL_APP" || { print -u2 "Restore the previous app from $STAGE/Previous.app"; /bin/rmdir "$LOCK"; return 1; }
    else
      print -u2 "Previous app retained at $STAGE/Previous.app"
      /bin/rmdir "$LOCK"
      return "$result"
    fi
  fi
  [[ -z "$STAGE" ]] || /bin/rm -rf -- "$STAGE"
  /bin/rmdir "$LOCK"
  return "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
STAGE="$(/usr/bin/mktemp -d "$INSTALL_DIR/.spleen-install.XXXXXX")"
check_destination() {
  if [[ -e "$INSTALL_APP" || -L "$INSTALL_APP" ]]; then
    [[ -d "$INSTALL_APP" && ! -L "$INSTALL_APP" ]] || fail 'Refusing to replace a symlink or non-app file.'
    [[ "$(plist "$INSTALL_APP" CFBundleIdentifier)" == "$BUNDLE_ID" ]] || fail 'Destination belongs to another application.'
    local old_build="$(plist "$INSTALL_APP" CFBundleVersion)"
    [[ "$old_build" == <-> ]] || fail 'The installed app has an unsupported build number.'
    if (( 10#$NEW_BUILD < 10#$old_build && ! ALLOW_DOWNGRADE )); then
      fail 'A newer build is installed. Use --allow-downgrade only for an intentional rollback.'
    fi
    local old_team new_team
    old_team="$(/usr/bin/codesign -dv "$INSTALL_APP" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p')"
    new_team="$(/usr/bin/codesign -dv "$SOURCE_APP" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p')"
    if [[ -n "$old_team" && "$old_team" != 'not set' && "$old_team" != "$new_team" ]]; then
      fail 'The new app has a different signing team. Refusing to replace the installed app.'
    fi
  fi
  # Only the destination being replaced matters. Never quit other copies.
  /bin/ps -ww -axo comm= > "$STAGE/processes" || fail 'Could not check running apps; installation stopped.'
  local command
  while IFS= read -r command; do
    [[ "$command" != /* ]] || command="${command:A}"
    [[ "$command" != "$INSTALL_APP/Contents/MacOS/$APP_NAME" ]] || fail "Quit the installed $APP_NAME before updating."
  done < "$STAGE/processes"
}
check_destination
# Preserve extended attributes, including download quarantine; never change Gatekeeper.
/usr/bin/ditto "$SOURCE_APP" "$STAGE/$APP_NAME.app"
validate "$STAGE/$APP_NAME.app"
check_destination
if [[ -d "$INSTALL_APP" ]]; then /bin/mv "$INSTALL_APP" "$STAGE/Previous.app"; fi
/bin/mv "$STAGE/$APP_NAME.app" "$INSTALL_APP"
COMPLETED=1
print -- "Installed: $INSTALL_APP"
print -- 'Preferences, permissions, conversation data, and key files were not changed.'
print -- "Open it in Finder, or run: open ${(q)INSTALL_APP}"
