#!/bin/sh
# Thermik dev build (no tests in v1). Usage: Scripts/build.sh [Debug|Release]
# l10n merge → xcodegen generate → xcodebuild (full log: build/xcodebuild-<config>.log) → codesign check.
set -eu
CONFIG="${1:-Debug}"
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo "XcodeGen missing: brew install xcodegen" >&2; exit 1; }
python3 -I Scripts/l10n-merge.py
xcodegen generate --quiet
mkdir -p build
LOG="build/xcodebuild-$CONFIG.log"
# The explicit destination avoids xcodebuild's "multiple matching destinations" warning (arm64 + x86_64 "My Mac").
# The log goes to a file so a failing xcodebuild fails this script (a pipe into `tail` would hide its exit status).
if ! xcodebuild -project Thermik.xcodeproj -scheme Thermik -configuration "$CONFIG" \
        -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath build/DerivedData build >"$LOG" 2>&1; then
    grep -E "error:" "$LOG" | sort -u >&2 || true
    tail -20 "$LOG" >&2
    echo "xcodebuild FAILED (full log: $LOG)" >&2
    exit 1
fi
# Print every warning, unfiltered (the target is 0). The App Intents extractor, which used to log one, is
# switched off in project.yml (LM_SKIP_METADATA_EXTRACTION).
grep -E "warning:" "$LOG" | sort -u || true
tail -3 "$LOG"
APP="build/DerivedData/Build/Products/$CONFIG/Thermik.app"
codesign -dvv "$APP/Contents/MacOS/thermik-helper" 2>&1 | grep -E "Identifier=|flags=|TeamIdentifier=" || true
echo "Built: $APP"
