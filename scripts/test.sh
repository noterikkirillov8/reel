#!/usr/bin/env bash
# Logic and render-pipeline tests. Headless: compiles Core/ plus the tests, no app, no windows, no Screen Recording.
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/reel-test.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
flags=()
if [[ ${CODEX_SANDBOX:-} == seatbelt ]]; then flags+=(-Xfrontend -disable-sandbox); fi
swiftc ${flags[@]+"${flags[@]}"} -swift-version 6 -strict-concurrency=complete -parse-as-library -O \
    -module-cache-path "$TEST_DIR/modules" \
    Reel/Sources/Core/*.swift Reel/Sources/App/Recorder.swift Reel/Sources/UI/{Model,Kit}.swift \
    tests/CoreTests.swift tests/IntroFlowTests.swift -o "$TEST_DIR/t"
exec "$TEST_DIR/t" "$@"
