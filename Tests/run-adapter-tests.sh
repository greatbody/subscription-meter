#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/subscription-meter-tests.XXXXXX")
trap 'rm -rf "$TEMP_DIR"' EXIT HUP INT TERM
swiftc "$ROOT/Sources/Models/UsageModels.swift" "$ROOT"/Sources/Adapters/*.swift "$ROOT/Tests/AdapterTests.swift" -o "$TEMP_DIR/adapter-tests"
"$TEMP_DIR/adapter-tests"
