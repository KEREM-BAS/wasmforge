#!/usr/bin/env bash
#
# Compiles the demo's worker entrypoint and stages it (plus the wasmforge
# bootstrap) under web/workers/, where the app's WorkerPool expects it.
#
#   bash tool/build_worker.sh         # dart2wasm (default)
#   bash tool/build_worker.sh --js    # dart2js fallback artifact
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

MODE="${1:-wasm}"
mkdir -p web/workers

if [[ "$MODE" == "--js" ]]; then
  echo "==> dart compile js (fallback worker)"
  dart compile js lib/worker/blur_worker_main.dart \
    -o web/workers/blur_worker.js -O2
else
  echo "==> dart compile wasm (worker)"
  dart compile wasm lib/worker/blur_worker_main.dart \
    -o web/workers/blur_worker.wasm --no-source-maps
fi

echo "==> staging wasmforge_worker_bootstrap.js"
dart run wasmforge:copy_bootstrap web/workers
echo "worker artifacts ready in web/workers/"
