#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if [[ ! -x build/Spleen.app/Contents/MacOS/Spleen ]]; then ./scripts/build.sh; fi
open "$PWD/build/Spleen.app" --args --data-dir "$PWD/.local-state" "$@"
