#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
./scripts/build.sh
exec /bin/zsh ./scripts/install-app.sh --app "${SPLEEN_OUTPUT_DIR:-$PWD/build}/Spleen.app" "$@"
