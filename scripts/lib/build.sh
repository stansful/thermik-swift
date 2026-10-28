#!/bin/sh
# Thermik dev build (no unit tests in v1). Usage: scripts/lib/build.sh [Debug|Release] [--debuggable]
# l10n merge → xcodegen generate → xcodebuild (full log: build/xcodebuild-<config>.log) → codesign + peer self-check.
# --debuggable (Debug only) is the developer opt-in THERMIK_DEBUGGABLE=YES (Config/Debug.xcconfig): both binaries
# get get-task-allow and the embedded helper ACCEPTS debuggable clients. Without it this script always builds with
# THERMIK_DEBUGGABLE=NO (a YES in Config/Signing.local.xcconfig only affects builds started from Xcode).
set -eu
CONFIG=Debug
DEBUGGABLE=NO
for arg in "$@"; do
    case "$arg" in
        Debug|Release) CONFIG="$arg" ;;
        --debuggable) DEBUGGABLE=YES ;;
        *) echo "usage: scripts/lib/build.sh [Debug|Release] [--debuggable]" >&2; exit 64 ;;
    esac
done
[ "$DEBUGGABLE" = NO ] || [ "$CONFIG" = Debug ] || { echo "--debuggable is for Debug builds only" >&2; exit 64; }
cd "$(dirname "$0")/../.."
command -v xcodegen >/dev/null || { echo "XcodeGen missing: brew install xcodegen" >&2; exit 1; }
python3 -I scripts/lib/l10n-merge.py
xcodegen generate --quiet
mkdir -p build
LOG="build/xcodebuild-$CONFIG.log"
# The explicit destination avoids xcodebuild's "multiple matching destinations" warning (arm64 + x86_64 "My Mac").
# The log goes to a file so a failing xcodebuild fails this script (a pipe into `tail` would hide its exit status).
if ! xcodebuild -project Thermik.xcodeproj -scheme Thermik -configuration "$CONFIG" \
        -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath build/DerivedData \
        THERMIK_DEBUGGABLE="$DEBUGGABLE" build >"$LOG" 2>&1; then
    grep -E "error:" "$LOG" | sort -u >&2 || true
    tail -20 "$LOG" >&2
    echo "xcodebuild FAILED (full log: $LOG)" >&2
    exit 1
fi
# Print every warning, unfiltered (the target is 0). The app links AppIntents (App/Runtime/Intents.swift), so the
# App Intents metadata extractor runs and logs nothing.
grep -E "warning:" "$LOG" | sort -u || true
tail -3 "$LOG"
APP="build/DerivedData/Build/Products/$CONFIG/Thermik.app"
HELPER="$APP/Contents/MacOS/thermik-helper"
APP_EXE="$APP/Contents/MacOS/Thermik"
codesign -dvv "$HELPER" 2>&1 | grep -E "Identifier=|flags=|TeamIdentifier=" || true

# Peer self-check (read-only, no root): the built helper prints the exact client requirement it would enforce once
# the legacy installer pinned this app (`--peer-requirement`, same cdhashes as the in-app installer), and codesign
# checks the built app against it, slice by slice. A mismatch here means "fan control never works" at runtime
# (PeerValidator: "requirement not met"), e.g. a get-task-allow entitlement that the helper forbids.
fail_check() { echo "peer self-check FAILED: $1" >&2; exit 1; }
for bin in "$APP_EXE" "$HELPER"; do   # the helper requires CS_RUNTIME on its client; Xcode drops it for ad-hoc
    codesign -dv "$bin" 2>&1 | grep -Eq '^CodeDirectory .*flags=[^ ]*runtime' || fail_check "no hardened runtime: $bin"
done
REQ="$("$HELPER" --peer-requirement "$APP")" || fail_check "the helper produced no client requirement"
for arch in $(lipo -archs "$APP_EXE"); do
    codesign --verify --strict -a "$arch" -R "=$REQ" "$APP" 2>&1 \
        || fail_check "the $arch app does not satisfy the helper's requirement: $REQ"
done
# The helper must refuse debuggable clients unless this build opted in (Release never does).
case "$REQ" in
    *'!(entitlement["com.apple.security.get-task-allow"]'*) HELPER_DEBUGGABLE=NO ;;
    *) HELPER_DEBUGGABLE=YES ;;
esac
[ "$HELPER_DEBUGGABLE" = "$DEBUGGABLE" ] \
    || fail_check "helper accepts debuggable clients = $HELPER_DEBUGGABLE, but THERMIK_DEBUGGABLE = $DEBUGGABLE"
echo "Peer self-check OK ($(lipo -archs "$APP_EXE")): $REQ"
if [ "$DEBUGGABLE" = YES ]; then
    echo "WARNING: --debuggable: this helper accepts clients a debugger can attach to. Install it only for a" \
         "debugging session, then reinstall the helper from a normal build."
fi
echo "Built: $APP"
