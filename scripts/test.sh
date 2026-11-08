#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p .build/clang-cache .build/swiftpm-cache
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/clang-cache"
swift test --disable-sandbox --scratch-path .build --cache-path .build/swiftpm-cache
./scripts/build.sh
./build/Spleen.app/Contents/MacOS/Spleen --self-test
