#!/usr/bin/env bash
# Tests of .github/scripts/release-state.sh: a throwaway clone of a local bare "origin" with tags in a temp dir
# (TMPDIR), the version in its Config/Shared.xcconfig, and a curl stub (first on PATH) in place of the GitHub API: no
# network. Runs the script under $TEST_BASH (default: bash from PATH).
#
#   scripts/tests/release-state_test.sh          KEEP=1 keeps the temp dir
#
# Prints 'ok <name>' / 'not ok <name>: <why>' and exits non-zero on a failure.
# The conditions of check() are eval'd when it runs: single quotes on purpose, and the variables they read are
# set outside them.
# shellcheck disable=SC2016,SC2034
set -u
# SIGPIPE ignored, as on the GitHub runner (every step inherits that from its Node.js), for these tests and the
# scripts they run: a reader that stops early makes its writer fail with "Broken pipe" there instead of dying quietly
trap "" PIPE

HERE="$(cd "$(dirname "$0")" && pwd -P)"
TREE="$(cd "$HERE/../.." && pwd -P)"
BASH_BIN="${TEST_BASH:-bash}"
# no temp dir stops here: an empty WORK would make the current directory (the checkout) the work dir, and the
# EXIT trap would delete it
if ! WORK="$(mktemp -d "${TMPDIR:-/tmp}/release-state-test.XXXXXX")" || ! WORK="$(cd "$WORK" && pwd -P)"; then
  echo "not ok no temp dir in ${TMPDIR:-/tmp}"
  exit 1
fi
if [ -z "${KEEP:-}" ]; then trap 'rm -rf "$WORK"' EXIT; else echo "# work dir: $WORK"; fi

export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/home/.config" GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid
GIT_CEILING_DIRECTORIES="$(dirname "$WORK")"
export GIT_CEILING_DIRECTORIES
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GH_TOKEN GITHUB_API_URL VERSION STUB_STATUS STUB_FAIL
mkdir -p "$HOME"
# release-state.sh's temp file lands here, an absolute path whatever the caller's TMPDIR (the script runs in REPO):
# the test checks that none is left behind
mkdir -p "$WORK/tmp"
export TMPDIR="$WORK/tmp"

pass=0 fail=0
ok() {
  echo "ok $1"
  pass=$((pass + 1))
}
nok() {
  echo "not ok $1: $2"
  fail=$((fail + 1))
}
check() {
  if eval "$2"; then ok "$1"; else nok "$1" "rc=$RC; condition: $2; stdout: $OUT; stderr: $ERR"; fi
}
has_err() { case $ERR in *"$1"*) return 0 ;; esac; return 1; }
# err_is <line>: stderr is exactly this line
err_is() { [ "$ERR" = "$1" ]; }
logged() { grep -qxF -- "$1" "$WORK/curl.log" 2>/dev/null; }
# The annotations of release-state.sh
NO_LINE='::error file=Config/Shared.xcconfig::Config/Shared.xcconfig must have exactly one line MARKETING_VERSION = X.Y.Z.'
# not_xyz <v>: the annotation for a version v that is not X.Y.Z
not_xyz() {
  printf '%s' "::error file=Config/Shared.xcconfig::MARKETING_VERSION \"$1\" must be X.Y.Z (numbers of up to 9" \
    " digits, no leading zeros, no \"v\"): it names the release and its tag. Set it with scripts/make-release.sh."
}
# not_higher <v> <tag>: the annotation for a version v that is not higher than the release tag
not_higher() {
  printf '%s' "::error file=Config/Shared.xcconfig::Version $1 is not higher than the existing tag $2." \
    " Bump it with scripts/make-release.sh."
}

echo "# .github/scripts/release-state.sh under $("$BASH_BIN" -c 'echo "bash $BASH_VERSION"'), $(git --version)"

# The GitHub API: a published release exists when $WORK/releases/<tag> does
mkdir -p "$WORK/bin" "$WORK/releases"
cat >"$WORK/bin/curl" <<'EOF'
#!/bin/sh
# curl stub: logs its arguments one per line, writes a body to its -o file and prints the HTTP status of the URL
# (its last argument): STUB_STATUS when set, else 200 when $STUB_RELEASES/<tag> exists, else 404. STUB_FAIL=1 fails
# like a refused connection (status 000, exit 7). An -o that is not a regular file fails the way curl 8.5
# (ubuntu-24.04) fails on a retry, when it cannot truncate it: exit 23, no status.
for a; do printf '%s\n' "$a"; done >"$STUB_LOG"
out='' prev=''
for a; do
  if [ "$prev" = -o ]; then out=$a; fi
  prev=$a url=$a
done
if [ -n "${STUB_FAIL:-}" ]; then printf 000; exit 7; fi
if [ -n "$out" ]; then
  if [ -e "$out" ] && [ ! -f "$out" ]; then exit 23; fi
  printf '{}' >"$out"
fi
if [ -n "${STUB_STATUS:-}" ]; then printf '%s' "$STUB_STATUS"
elif [ -e "$STUB_RELEASES/${url##*/}" ]; then printf 200
else printf 404
fi
EOF
chmod +x "$WORK/bin/curl"
export STUB_LOG="$WORK/curl.log" STUB_RELEASES="$WORK/releases"

# xcconfig <version>: Config/Shared.xcconfig with that version, shaped like the real one: comments (one names
# MARKETING_VERSION), other settings, the build number, an include
xcconfig() {
  printf '%s\n' \
    '// Shared settings. scripts/make-release.sh sets MARKETING_VERSION and CURRENT_PROJECT_VERSION.' \
    'CODE_SIGN_IDENTITY = -' \
    "MARKETING_VERSION = $1" \
    'CURRENT_PROJECT_VERSION = 7' \
    '// Bump ONLY when helper code changes.' \
    'HELPER_BUILD_VERSION = 6' \
    '#include? "Signing.local.xcconfig"'
}

# origin: A (tag 0.1.0) - B (annotated legacy tag v0.2.0) - C (tag not-a-release); Config/Shared.xcconfig 0.3.0
SEED="$WORK/seed"
mkdir -p "$SEED/Config" "$SEED/scripts/lib" "$SEED/.github/scripts"
cp "$TREE/scripts/lib/version.sh" "$SEED/scripts/lib/"
cp "$TREE/.github/scripts/release-state.sh" "$SEED/.github/scripts/"
xcconfig 0.3.0 >"$SEED/Config/Shared.xcconfig"
(
  set -e
  cd "$SEED"
  git -c init.defaultBranch=master init -q .
  git symbolic-ref HEAD refs/heads/master
  git add -A
  git commit -q -m A
  git tag 0.1.0
  git commit -q --allow-empty -m B
  git tag -a v0.2.0 -m legacy
  git commit -q --allow-empty -m C
  git tag not-a-release
  git init -q --bare "$WORK/origin.git"
  git push -q "$WORK/origin.git" master --tags
  git clone -q "$WORK/origin.git" "$WORK/repo"
) || {
  echo "not ok the test fixture could not be built"
  exit 1
}
REPO="$WORK/repo"
A=$(git -C "$REPO" rev-parse 0.1.0) C=$(git -C "$REPO" rev-parse HEAD)

# rs <GITHUB_SHA> [VAR=value...]: release-state.sh, run in REPO as release.yml runs it; sets OUT, ERR, RC
rs() {
  local sha="$1"
  shift
  rm -f "$WORK/curl.log"
  OUT="$(cd "$REPO" && env PATH="$WORK/bin:$PATH" GITHUB_REPOSITORY=owner/repo GITHUB_SHA="$sha" "$@" \
    "$BASH_BIN" .github/scripts/release-state.sh 2>"$WORK/err")"
  RC=$?
  ERR="$(cat "$WORK/err")"
}
# tag_origin <tag> <commit> [annotated]: puts the tag on origin only (the clone does not fetch it)
tag_origin() {
  if [ -n "${3:-}" ]; then
    git -C "$WORK/origin.git" tag -f -a "$1" -m annotated "$2" >/dev/null
  else
    git -C "$WORK/origin.git" tag -f "$1" "$2" >/dev/null
  fi
}
untag_origin() { git -C "$WORK/origin.git" tag -d "$1" >/dev/null; }

rs "$C"
check "new: no release and no tag of Config/Shared.xcconfig's 0.3.0" '[ $RC = 0 ] && [ "$OUT" = new ] && [ -z "$ERR" ]'
check "...asks the API for the published release of 0.3.0, without a token" \
  'logged "https://api.github.com/repos/owner/repo/releases/tags/0.3.0" && logged "Accept: application/vnd.github+json" && ! grep -q Authorization "$WORK/curl.log"'
check "...the answer goes to a temp file, not /dev/null (curl 8.5 cannot retry into it), and the file is removed" \
  'grep -q "^$WORK/tmp/" "$WORK/curl.log" && ! logged /dev/null && [ -z "$(ls -A "$WORK/tmp")" ]'
rs "$C" GH_TOKEN=secret-token GITHUB_API_URL=https://ghe.example.invalid/api/v3
check "...with GH_TOKEN as a bearer token and GITHUB_API_URL" \
  '[ "$OUT" = new ] && logged "Authorization: Bearer secret-token" && logged "https://ghe.example.invalid/api/v3/repos/owner/repo/releases/tags/0.3.0"'
rs "$C" VERSION=0.4.0
check "VERSION overrides Config/Shared.xcconfig" \
  '[ $RC = 0 ] && [ "$OUT" = new ] && logged "https://api.github.com/repos/owner/repo/releases/tags/0.4.0"'
rm -f "$WORK/curl.log"
OUT="$(cd "$WORK" && env PATH="$WORK/bin:$PATH" GITHUB_REPOSITORY=owner/repo GITHUB_SHA="$C" \
  "$BASH_BIN" "$REPO/.github/scripts/release-state.sh" 2>"$WORK/err")"
RC=$? ERR="$(cat "$WORK/err")"
check "...run from another directory it reads its own checkout" \
  '[ $RC = 0 ] && [ "$OUT" = new ] && logged "https://api.github.com/repos/owner/repo/releases/tags/0.3.0"'

tag_origin 0.3.0 "$C"
rs "$C"
check "retry: the tag 0.3.0 is on GITHUB_SHA, no release" '[ $RC = 0 ] && [ "$OUT" = retry ] && [ -z "$ERR" ]'
tag_origin 0.3.0 "$C" annotated
rs "$C"
check "retry: an annotated tag is followed to its commit" '[ $RC = 0 ] && [ "$OUT" = retry ]'
tag_origin 0.3.0 "$A"
rs "$C"
check "a tag 0.3.0 on another commit without a release is refused" \
  '[ $RC = 1 ] && [ -z "$OUT" ] && err_is "::error::Tag 0.3.0 points at $A, not $C, and has no release. Delete the tag or bump the version (scripts/make-release.sh)."'
touch "$WORK/releases/0.3.0"
rs "$C"
check "released: a published release, wherever its tag is" '[ $RC = 0 ] && [ "$OUT" = released ] && [ -z "$ERR" ]'
rm -f "$WORK/releases/0.3.0"
untag_origin 0.3.0
touch "$WORK/releases/0.1.0"
rs "$C" VERSION=0.1.0
check "released: an old version with a published release is released, not refused" '[ $RC = 0 ] && [ "$OUT" = released ]'
rm -f "$WORK/releases/0.1.0"

rs "$C" VERSION=0.2.0
check "a version equal to a legacy tag v0.2.0 is refused" \
  '[ $RC = 1 ] && [ -z "$OUT" ] && err_is "$(not_higher 0.2.0 v0.2.0)"'
rs "$C" VERSION=0.1.5
check "a version below an existing tag is refused" '[ $RC = 1 ] && [ -z "$OUT" ] && err_is "$(not_higher 0.1.5 v0.2.0)"'
tag_origin 0.9.0 "$A"
rs "$C"
check "a tag only on origin counts (0.3.0 below 0.9.0)" '[ $RC = 1 ] && err_is "$(not_higher 0.3.0 0.9.0)"'
untag_origin 0.9.0
tag_origin v0.10.0 "$A" annotated
rs "$C" VERSION=0.9.0
check "versions compare as numbers (0.9.0 below v0.10.0)" '[ $RC = 1 ] && err_is "$(not_higher 0.9.0 v0.10.0)"'
rs "$C" VERSION=0.11.0
check "...and 0.11.0 above it is new" '[ $RC = 0 ] && [ "$OUT" = new ]'
untag_origin v0.10.0
tag_origin 1000000000.0.0 "$A"
rs "$C"
check "a tag with a number of 10 digits is not a version, so no release tag: 0.3.0 is new" \
  '[ $RC = 0 ] && [ "$OUT" = new ] && [ -z "$ERR" ]'
untag_origin 1000000000.0.0

for v in v0.3.0 0.3 00.3.0 0.3.0-rc1 0.3.0.1 1000000000.0.0 0.1000000000.0 0.3.1000000000 ""; do
  rs "$C" VERSION="$v"
  # an empty VERSION falls back to Config/Shared.xcconfig, like an unset one
  if [ -z "$v" ]; then
    check "an empty VERSION reads Config/Shared.xcconfig" '[ $RC = 0 ] && [ "$OUT" = new ] && logged "https://api.github.com/repos/owner/repo/releases/tags/0.3.0"'
  else
    check "version '$v' (not X.Y.Z, or a number of more than 9 digits) is refused before any API call" \
      '[ $RC = 1 ] && [ -z "$OUT" ] && err_is "$(not_xyz "$v")" && [ ! -e "$WORK/curl.log" ]'
  fi
done
rs "$C" VERSION=999999999.999999999.999999999
check "numbers of up to 9 digits make a version: 999999999.999999999.999999999 is new" \
  '[ $RC = 0 ] && [ "$OUT" = new ] && logged "https://api.github.com/repos/owner/repo/releases/tags/999999999.999999999.999999999"'

F="$REPO/Config/Shared.xcconfig"
printf 'CODE_SIGN_IDENTITY = -\n  MARKETING_VERSION\t= \t0.3.0 \t\nCURRENT_PROJECT_VERSION = 7\n' >"$F"
rs "$C"
check "blanks around the name, the = and the value of MARKETING_VERSION are not part of the version" \
  '[ $RC = 0 ] && [ "$OUT" = new ] && logged "https://api.github.com/repos/owner/repo/releases/tags/0.3.0"'
REF='$(APP_VERSION)'
xcconfig "$REF" >"$F"
rs "$C"
check "a MARKETING_VERSION that is not X.Y.Z (a build setting reference) is refused, naming it" \
  '[ $RC = 1 ] && [ -z "$OUT" ] && err_is "$(not_xyz "$REF")" && [ ! -e "$WORK/curl.log" ]'
{
  xcconfig 0.3.0
  echo 'MARKETING_VERSION = 0.3.0'
} >"$F"
rs "$C"
check "Config/Shared.xcconfig with two MARKETING_VERSION lines is refused" \
  '[ $RC = 1 ] && [ -z "$OUT" ] && err_is "$NO_LINE" && [ ! -e "$WORK/curl.log" ]'
xcconfig 0.3.0 | sed 's|^MARKETING_VERSION|// MARKETING_VERSION|' >"$F"
rs "$C"
check "Config/Shared.xcconfig with its MARKETING_VERSION line commented out is refused" \
  '[ $RC = 1 ] && [ -z "$OUT" ] && err_is "$NO_LINE" && [ ! -e "$WORK/curl.log" ]'
rs "$C" VERSION=0.4.0
check "...unless VERSION is given" '[ $RC = 0 ] && [ "$OUT" = new ]'
rm -f "$F"
rs "$C"
check "a missing Config/Shared.xcconfig is refused" \
  '[ $RC = 1 ] && [ -z "$OUT" ] && has_err "$NO_LINE" && [ ! -e "$WORK/curl.log" ]'
git -C "$REPO" checkout -q -- Config/Shared.xcconfig

rs "$C" STUB_STATUS=500
check "an API error is refused" '[ $RC = 1 ] && [ -z "$OUT" ] && err_is "::error::The GitHub API answered HTTP 500 for release 0.3.0."'
rs "$C" STUB_STATUS=403
check "a rate-limited API (403) is refused, not taken for 'no release'" '[ $RC = 1 ] && has_err "HTTP 403"'
rs "$C" STUB_FAIL=1
check "no answer from the API is refused" '[ $RC = 1 ] && err_is "::error::The GitHub API answered HTTP 000 for release 0.3.0."'
git -C "$REPO" remote set-url origin "$WORK/missing.git"
rs "$C"
check "unreadable origin tags are refused, saying the repository must be public" \
  '[ $RC = 1 ] && [ -z "$OUT" ] && has_err "::error::Cannot read the tags of origin (git ls-remote). The release workflow reads them without credentials: the repository must be public."'
git -C "$REPO" remote set-url origin "$WORK/origin.git"
rs "$C" GITHUB_REPOSITORY=
check "GITHUB_REPOSITORY is required" '[ $RC != 0 ] && [ -z "$OUT" ] && [ ! -e "$WORK/curl.log" ]'
rs ""
check "GITHUB_SHA is required" '[ $RC != 0 ] && [ -z "$OUT" ] && [ ! -e "$WORK/curl.log" ]'

# --- tag_commit (scripts/lib/version.sh) on real `git ls-remote --tags` output: release-state.sh and the final tag
# check of release.yml's publish job read the tag's commit with it
# tc <tag>: tag_commit under BASH_BIN, fed origin's `git ls-remote --tags`; sets OUT, RC
tc() {
  OUT="$(git -C "$REPO" ls-remote --tags origin | "$BASH_BIN" -c '. "$1/scripts/lib/version.sh" && tag_commit "$2"' tc "$TREE" "$1")"
  RC=$?
  ERR=
}
B=$(git -C "$REPO" rev-parse 'v0.2.0^{commit}') B_TAG=$(git -C "$REPO" rev-parse v0.2.0)
tc 0.1.0
check "tag_commit: a lightweight tag's commit" '[ $RC = 0 ] && [ "$OUT" = "$A" ]'
tc v0.2.0
check "tag_commit: an annotated tag is followed to its commit, not the tag object" '[ $RC = 0 ] && [ "$OUT" = "$B" ] && [ "$B" != "$B_TAG" ]'
tag_origin 0.3.0 "$C" annotated
tc 0.3.0
check "tag_commit: an annotated release tag made by hand on GITHUB_SHA is GITHUB_SHA" '[ "$OUT" = "$C" ]'
untag_origin 0.3.0
tc 0.3.0
check "tag_commit: nothing for a tag that is not there" '[ $RC = 0 ] && [ -z "$OUT" ]'

echo "# $pass passed, $fail failed"
[ "$fail" = 0 ]
