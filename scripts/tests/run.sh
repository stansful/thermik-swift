#!/usr/bin/env bash
# Runs the tests of the release scripts (scripts/tests/*_test.sh): scripts/lib/version.sh, scripts/make-release.sh,
# scripts/build-release.sh (against a fake tree with stub build tools), .github/scripts/release-state.sh and
# release-notes.sh, and the static checks of the workflows, in throwaway directories in TMPDIR. Never runs Xcode,
# never writes into this repository. Needs bash 3.2+ and git; TEST_BASH=<bash> runs the tests and the scripts under
# that bash (macOS: /bin/bash is 3.2), KEEP=1 keeps the temp dirs.
#
#   scripts/tests/run.sh
#
# Exits non-zero when a test fails.
set -u
# SIGPIPE ignored, as on the GitHub runner (every step inherits that from its Node.js), for these tests and the
# scripts they run: a reader that stops early makes its writer fail with "Broken pipe" there instead of dying quietly
trap "" PIPE

HERE="$(cd "$(dirname "$0")" && pwd -P)"
fail=0
for t in "$HERE"/*_test.sh; do
  echo "# ${t##*/}"
  "${TEST_BASH:-bash}" "$t" || fail=1
done
exit "$fail"
