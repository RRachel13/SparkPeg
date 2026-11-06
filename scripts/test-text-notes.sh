#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/local-module-cache work
SIDELINE_SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
if [ ! -d "$SIDELINE_SDK" ]; then SIDELINE_SDK="$(xcrun --show-sdk-path)"; fi
TEST_TEMP="$(mktemp -d "$PWD/work/text-tests.XXXXXX")"
trap 'rm -rf "$TEST_TEMP"' EXIT
APP_SOURCES=()
for source in Sources/Tendedero/*.swift; do
  if [ "$source" != Sources/Tendedero/main.swift ]; then APP_SOURCES+=("$source"); fi
done
xcrun swiftc -sdk "$SIDELINE_SDK" -target "$(uname -m)-apple-macosx14.0" \
  -module-name Tendedero -module-cache-path "$PWD/.build/local-module-cache" \
  "${APP_SOURCES[@]}" Tests/TextNotesTests/main.swift -o "$TEST_TEMP/text-note-tests"
"$TEST_TEMP/text-note-tests"
