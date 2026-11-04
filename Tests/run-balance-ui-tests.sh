#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/subscription-meter-ui-tests.XXXXXX")
trap 'rm -rf "$TEMP_DIR"' EXIT HUP INT TERM
cat "$ROOT/Sources/UI/MenuBarController.swift" "$ROOT/Tests/BalanceUITests.swift" > "$TEMP_DIR/UI.swift"
swiftc -parse-as-library "$ROOT/Sources/Models/UsageModels.swift" "$ROOT/Sources/Settings/AppSettings.swift" "$TEMP_DIR/UI.swift" -o "$TEMP_DIR/tests"
"$TEMP_DIR/tests"
