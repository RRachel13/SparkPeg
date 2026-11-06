#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/local-module-cache work
SIDELINE_SDK="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
if [ ! -d "$SIDELINE_SDK" ]; then SIDELINE_SDK="$(xcrun --show-sdk-path)"; fi
TEST_TEMP="$(mktemp -d "$PWD/work/hover-tests.XXXXXX")"
trap 'rm -rf "$TEST_TEMP"' EXIT
xcrun swiftc -sdk "$SIDELINE_SDK" -target "$(uname -m)-apple-macosx14.0" \
  -module-cache-path "$PWD/.build/local-module-cache" \
  Sources/Tendedero/HoverRevealRegion.swift Tests/HoverRevealRegionTests/main.swift \
  -o "$TEST_TEMP/hover-tests"
"$TEST_TEMP/hover-tests"
