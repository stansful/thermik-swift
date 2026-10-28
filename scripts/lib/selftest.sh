#!/usr/bin/env bash
# Thermik's regression suite (docs/development.md, Verification): builds thermik-probe (swift build, debug) and runs
# its self-checks: `helper selftest`, `alerts replay`, `diagnostics selftest`, `fans sim` and `log write` into a temp
# dir. None of them needs root or touches the hardware: mock fans, a fake SMC and synthetic data. A check passes when
# it exits 0 and prints its own summary line with nothing failed (`fans sim` always exits 0, and an unknown subcommand
# prints the usage and exits 0 too). Prints one line per check; the output of each is in build/selftest/<check>.log,
# and a failing check's output is printed as well. Exits 1 when a check fails. .github/workflows/ci.yml runs it, and
# so does scripts/build-release.sh --test.
#
#   scripts/lib/selftest.sh
#
# bash 3.2 (macOS); needs Xcode 27.1 or later (Swift 6).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
PACKAGE="$ROOT_DIR/Packages/ThermikCore"
LOGS="$ROOT_DIR/build/selftest"

echo "== swift build --product thermik-probe"
swift build --package-path "$PACKAGE" --product thermik-probe
probe="$(swift build --package-path "$PACKAGE" --show-bin-path)/thermik-probe"
[ -x "$probe" ] || {
  echo "selftest: no thermik-probe at $probe" >&2
  exit 1
}

rm -rf "$LOGS"
mkdir -p "$LOGS"
work="$(mktemp -d "${TMPDIR:-/tmp}/thermik-selftest.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/logs"

failed=0
# run_check <log name> <summary: an awk program that exits 0 when the output says nothing failed> <args...>:
# thermik-probe <args...>, its output into build/selftest/<log name>.log
run_check() {
  local log="$LOGS/$1.log" summary="$2" rc=0
  shift 2
  "$probe" "$@" >"$log" 2>&1 || rc=$?
  if [ "$rc" = 0 ] && awk "$summary" "$log"; then
    printf 'ok      thermik-probe %s: %s\n' "$*" "$(grep -v '^[[:space:]]*$' "$log" | tail -n 1)"
  else
    printf 'FAILED  thermik-probe %s (exit %s); its output (%s):\n' "$*" "$rc" "${log#"$ROOT_DIR"/}"
    sed 's/^/    /' "$log"
    failed=1
  fi
}

echo "== thermik-probe self-checks (logs: build/selftest/)"
# shellcheck disable=SC2016 # an awk program: $3 is awk's
run_check helper-selftest '/^helper selftest: [0-9]+\/[0-9]+ PASS$/ { split($3, n, "/"); ok = n[1] > 0 && n[1] == n[2] }
  END { exit !ok }' helper selftest
run_check alerts-replay '/^[1-9][0-9]* passed, 0 failed$/ { ok = 1 } END { exit !ok }' alerts replay
run_check diagnostics-selftest '/^all checks passed$/ { ok = 1 } END { exit !ok }' diagnostics selftest
run_check fans-sim '/^sim result: [1-9][0-9]* passed, 0 failed$/ { ok = 1 } END { exit !ok }' fans sim
run_check log-write '/^all checks passed$/ { ok = 1 } END { exit !ok }' log write "$work/logs"

if [ "$failed" != 0 ]; then
  echo "selftest: a check failed." >&2
  exit 1
fi
echo "All self-checks passed."
