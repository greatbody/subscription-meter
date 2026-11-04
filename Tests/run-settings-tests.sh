#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/meter-settings.XXXXXX")
trap 'rm -rf "$TEMP_DIR"' EXIT HUP INT TERM
swiftc "$ROOT/Sources/Models/UsageModels.swift" "$ROOT/Sources/Settings/AppSettings.swift" "$ROOT/Tests/SettingsTests.swift" -o "$TEMP_DIR/settings-tests"
"$TEMP_DIR/settings-tests"
