#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "$0")/../.." && pwd)"
TEST_ROOT="$(mktemp -d /private/tmp/nool-media-remote-test.XXXXXX)"
trap '/bin/rm -rf "$TEST_ROOT"' EXIT

xcrun clang -fobjc-arc -fblocks -Wall -Wextra \
    -I "$PROJECT_ROOT/Sources/NoolMediaRemoteAdapter/include" \
    -framework AppKit -framework Foundation \
    "$PROJECT_ROOT/Tests/MediaRemoteAdapter/serialization.test.m" \
    -o "$TEST_ROOT/serialization-tests"
"$TEST_ROOT/serialization-tests"
