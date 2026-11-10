#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if [[ ! -x build/Spleen.app/Contents/MacOS/Spleen ]]; then ./scripts/build.sh; fi
# `open` only re-activates a copy that is already running, ignoring a fresh build and
# these arguments. Quit that copy first; Spleen saves and quits on SIGTERM.
EXE="$PWD/build/Spleen.app/Contents/MacOS/Spleen"
running=()
while read -r pid command; do
  [[ "$command" == "$EXE" || "$command" == "$EXE "* ]] || continue
  [[ "$command" == *" --self-test"* || "$command" == *" --render-preview"* ]] && continue
  running+=("$pid")
done < <(ps -axo pid=,command=)
if (( ${#running} )); then
  print "Restarting the running Spleen (pid ${running[*]})."
  kill -TERM "${running[@]}" 2>/dev/null || true
  for _ in {1..50}; do
    alive=()
    for pid in "${running[@]}"; do kill -0 "$pid" 2>/dev/null && alive+=("$pid"); done
    (( ${#alive} )) || break
    sleep 0.1
  done
  if (( ${#alive} )); then
    print -u2 "Spleen (pid ${alive[*]}) did not quit. Quit it from the menu bar, then run this again."
    exit 1
  fi
fi
open "$PWD/build/Spleen.app" --args --data-dir "$PWD/.local-state" "$@"
