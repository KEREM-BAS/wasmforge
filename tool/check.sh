#!/usr/bin/env bash
#
# wasmforge quality gate. Run after every build phase; the build must not
# advance while this is red.
#
# Stages whose inputs do not exist yet (tests, bootstrap asset, example app)
# skip themselves so the gate is usable from phase P0 onwards.
#
# Flags (environment variables):
#   FORGE_SKIP_BROWSER=1   skip `dart test -p chrome`
#   FORGE_WASM_TESTS=1     additionally run browser tests compiled w/ dart2wasm
#   FORGE_SKIP_EXAMPLE=1   skip example analyze + build
#   FORGE_PUBLISH_CHECK=1  run `dart pub publish --dry-run`
set -euo pipefail

# Project root (path may contain spaces — keep everything quoted).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Directories that exist at the current phase.
DIRS=()
for d in lib test tool bin; do
  if [[ -d "$d" ]]; then DIRS+=("$d"); fi
done

echo "==> dart pub get"
dart pub get

echo "==> dart format (check only)"
dart format --output=none --set-exit-if-changed "${DIRS[@]}"

echo "==> dart analyze --fatal-infos"
dart analyze --fatal-infos "${DIRS[@]}"

echo "==> banned-import grep"
# Bans the legacy web libraries that do not compile under dart2wasm, plus the
# legacy package:js and the escape-hatch dart:js_interop_unsafe. The closing
# quote in dart:js["'] keeps dart:js_interop from matching.
Q="[\"']"
BANNED="(import|export)[[:space:]]+${Q}(dart:html|dart:svg|dart:indexed_db|dart:web_audio|dart:web_gl|dart:js${Q}|dart:js_util|dart:js_interop_unsafe|package:js${Q}|package:js/)"
GREP_DIRS=()
for d in lib test tool bin example/lib example/tool; do
  if [[ -d "$d" ]]; then GREP_DIRS+=("$d"); fi
done
if grep -rnE --include='*.dart' "$BANNED" "${GREP_DIRS[@]}"; then
  echo "FAIL: banned import found (matches above)"
  exit 1
fi

if [[ -f lib/src/assets/wasmforge_worker_bootstrap.js ]]; then
  echo "==> bootstrap copies in sync (lib asset vs web/)"
  cmp lib/src/assets/wasmforge_worker_bootstrap.js web/wasmforge_worker_bootstrap.js
fi

echo "==> dart2wasm smoke compile"
SMOKE_OUT="$(mktemp -d)"
trap 'rm -rf "$SMOKE_OUT"' EXIT
dart compile wasm tool/smoke/wasm_smoke.dart -o "$SMOKE_OUT/smoke.wasm" --no-source-maps

if ls test/*_test.dart >/dev/null 2>&1; then
  echo "==> VM tests"
  dart test
fi

if [[ "${FORGE_SKIP_BROWSER:-0}" != "1" && -d test/web ]]; then
  echo "==> browser tests (chrome, dart2js)"
  dart test -p chrome test/web
  if [[ "${FORGE_WASM_TESTS:-0}" == "1" ]]; then
    echo "==> browser tests (chrome, dart2wasm)"
    dart test -p chrome -c dart2wasm test/web
  fi
fi

if [[ "${FORGE_SKIP_EXAMPLE:-0}" != "1" && -f example/pubspec.yaml ]]; then
  echo "==> example: pub get + format + analyze + worker build + wasm build"
  (
    cd example
    flutter pub get
    EX_DIRS=()
    for d in lib tool test; do
      if [[ -d "$d" ]]; then EX_DIRS+=("$d"); fi
    done
    dart format --output=none --set-exit-if-changed "${EX_DIRS[@]}"
    dart analyze --fatal-infos
    bash tool/build_worker.sh
    flutter build web --wasm
  )
fi

if [[ "${FORGE_PUBLISH_CHECK:-0}" == "1" ]]; then
  echo "==> pub publish dry-run"
  dart pub publish --dry-run
fi

echo "OK: all checks passed"
