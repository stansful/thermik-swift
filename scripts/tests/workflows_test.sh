#!/usr/bin/env bash
# Static checks that the release pieces agree: ci.yml's release-build job builds with scripts/build-release.sh the
# files release_assets (scripts/lib/version.sh) lists and uploads them as the artifact release-<version>; release.yml
# runs on every push to master, calls ci.yml (which skips those pushes) and publishes that artifact, checked against
# release_assets, as release "Thermik X.Y.Z" with the plain tag X.Y.Z, made the latest, with the notes of
# release-notes.sh; the tag's commit is read one way (tag_commit over every tag); the draft is handled by the id the
# API returns; the macOS jobs run on the xcode-27 runners with the Xcode that docs/development.md and project.yml
# name; the CI runs these tests under bash 5 and 3.2 and shellchecks every script; every remote action is pinned to
# a commit. The patterns match the workflows' and scripts' own text, $VERSION and the like included.
# release_assets and release.yml's tag lookups also run, under $TEST_BASH (default: bash from PATH): the lookups in
# a clone of a throwaway origin with an annotated and a lightweight tag. Files go to a temp dir (TMPDIR); the
# repository is only read.
#
#   scripts/tests/workflows_test.sh          KEEP=1 keeps the temp dir
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
CI="$TREE/.github/workflows/ci.yml"
RELEASE="$TREE/.github/workflows/release.yml"
XCODE_ACTION="$TREE/.github/actions/xcode/action.yml"
ACTIONLINT="$TREE/.github/actionlint.yaml"
STATE="$TREE/.github/scripts/release-state.sh"
NOTES="$TREE/.github/scripts/release-notes.sh"
BUILD="$TREE/scripts/build-release.sh"
MAKE="$TREE/scripts/make-release.sh"
LIB="$TREE/scripts/lib/version.sh"
DOCS="$TREE/docs/development.md"
PROJECT="$TREE/project.yml"
# The runner label of every macOS job: GitHub's Xcode 27 image
MACOS_RUNNER=xcode-27
BASH_BIN="${TEST_BASH:-bash}"
# no temp dir stops here: an empty WORK would make the current directory (the checkout) the work dir, and the
# EXIT trap would delete it
if ! WORK="$(mktemp -d "${TMPDIR:-/tmp}/workflows-test.XXXXXX")" || ! WORK="$(cd "$WORK" && pwd -P)"; then
  echo "not ok no temp dir in ${TMPDIR:-/tmp}"
  exit 1
fi
if [ -z "${KEEP:-}" ]; then trap 'rm -rf "$WORK"' EXIT; else echo "# work dir: $WORK"; fi

export HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/home/.config" GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.invalid
GIT_CEILING_DIRECTORIES="$(dirname "$WORK")"
export GIT_CEILING_DIRECTORIES
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_CONFIG_GLOBAL VERSION
mkdir -p "$HOME"

pass=0 fail=0
ok() {
  echo "ok $1"
  pass=$((pass + 1))
}
nok() {
  echo "not ok $1: $2"
  fail=$((fail + 1))
}
# check <name> <condition> [why]: ok when the condition holds, else not ok with why and the condition
check() {
  if eval "$2"; then ok "$1"; else nok "$1" "${3:+$3; }condition: $2"; fi
}
# has <text> <file>: the file has the text; line <text> <file>: one of its lines is exactly the text
has() { grep -qF -- "$1" "$2"; }
line() { grep -qxF -- "$1" "$2"; }
# has_all <file> <text...>: the file has every text; has_lines <file> <line...>: every line is one of the file's
has_all() {
  local file="$1" text
  shift
  for text; do has "$text" "$file" || return 1; done
}
has_lines() {
  local file="$1" text
  shift
  for text; do line "$text" "$file" || return 1; done
}
lines() { printf '%s\n' "$@"; }
# fn <function> [args...]: a function of version.sh in a fresh BASH_BIN under set -euo pipefail, as the scripts and
# the workflow steps (bash -euo pipefail) run it; sets OUT, ERR, RC
fn() {
  ERR="$("$BASH_BIN" -c 'set -euo pipefail; . "$0"; "$@"' "$LIB" "$@" 2>&1 >"$WORK/out" </dev/null)"
  RC=$?
  OUT="$(cat "$WORK/out")"
}

# The workflows are read as they are written, two spaces per level (actionlint checks the YAML itself)
# job <workflow> <id>: the lines of the job, from its "  <id>:" line up to the next line indented by two spaces or
# less (the next job, or the comment above it)
job() {
  JOB="  $2:" awk '/^jobs:$/ { j = 1; next }
    j && $0 == ENVIRON["JOB"] { on = 1; print; next }
    on && /^(  )?[^ ]/ { exit }
    on' "$1"
}
# step <job file> <line>: the step of the job (from its "      - " line up to the next one) with exactly this line
step() {
  LINE="$2" awk '/^      - / { if (found) exit; s = "" }
    { s = s $0 "\n" }
    $0 == ENVIRON["LINE"] { found = 1 }
    END { if (found) printf "%s", s }' "$1"
}
# runners <workflow>: "<job> <runs-on>" for every job, "<job> uses <workflow>" for a call of a reusable workflow
runners() {
  awk '/^jobs:$/ { j = 1; next }
    !j { next }
    /^[^ ]/ { exit }
    /^  [^ #][^ ]*:$/ { id = substr($0, 3, length($0) - 3) }
    /^    runs-on: / { print id, $2 }
    /^    uses: / { print id, "uses", $2 }' "$1"
}
# events <workflow>: the events of its "on:" block, each followed by a space
events() {
  awk '/^on:$/ { on = 1; next }
    on && /^[^ ]/ { exit }
    on && /^  [^ #]/ { sub(/^  /, ""); sub(/:.*/, ""); printf "%s ", $0 }' "$1"
}
# trigger <workflow> <event>: the lines under that event in its "on:" block, blank ones left out
trigger() {
  EVENT="  $2:" awk '/^on:$/ { on = 1; next }
    on && /^[^ ]/ { exit }
    on && /^  [^ ]/ { e = ($0 == ENVIRON["EVENT"]); next }
    e && NF' "$1"
}

echo "# the workflows and the release scripts; version.sh and the tag lookups under $("$BASH_BIN" -c 'echo "bash $BASH_VERSION"'), $(git --version)"

for j in scripts selftest debug release-build; do job "$CI" "$j" >"$WORK/ci.$j"; done
for j in gate quality publish; do job "$RELEASE" "$j" >"$WORK/release.$j"; done
runners "$CI" >"$WORK/ci.runners"
runners "$RELEASE" >"$WORK/release.runners"
# build-release.sh's help: its usage() with the text it prints
awk '/^usage\(\) \{$/ { u = 1 } u { print } u && /^EOF$/ { exit }' "$BUILD" >"$WORK/build-release.usage"

# --- the release files: release_assets, which build-release.sh builds and release.yml publishes
fn release_assets 1.2.3
lines Thermik-1.2.3.zip Thermik-1.2.3-dSYMs.zip SHA256SUMS >"$WORK/expected"
check "release_assets 1.2.3 is exactly Thermik-1.2.3.zip Thermik-1.2.3-dSYMs.zip SHA256SUMS, one per line, in this order" \
  '[ $RC = 0 ] && cmp -s "$WORK/out" "$WORK/expected" && [ -z "$ERR" ]' "rc=$RC; stdout: '$OUT'; stderr: '$ERR'"
assets_from='assets="$(release_assets "$version" |'
check "build-release.sh builds the files release_assets lists" 'has "$assets_from" "$BUILD"' \
  "build-release.sh does not take its list from release_assets"
fn release_assets X.Y.Z
help_names='' docs_names=''
for name in $OUT; do
  has "$name" "$WORK/build-release.usage" || help_names="$help_names $name"
  has "$name" "$DOCS" || docs_names="$docs_names $name"
done
check "build-release.sh's help and docs/development.md name the files of release_assets X.Y.Z ($(printf '%s' "$OUT" | tr '\n' ' '))" \
  '[ $RC = 0 ] && [ -n "$OUT" ] && [ -z "$help_names$docs_names" ]' \
  "not in build-release.sh:${help_names:- -}; not in docs/development.md:${docs_names:- -}"
fn release_assets '$VERSION'
notes_names=''
for name in $OUT; do has "$name" "$NOTES" || notes_names="$notes_names $name"; done
check "the release notes (release-notes.sh) name every file of release_assets \$VERSION" \
  '[ $RC = 0 ] && [ -n "$OUT" ] && [ -z "$notes_names" ]' "not in release-notes.sh:$notes_names"

# --- ci.yml's release build: the artifact release-<version>
build_run='        run: scripts/build-release.sh --out "$RUNNER_TEMP/release"'
check "ci.yml's release-build job runs scripts/build-release.sh --out \"\$RUNNER_TEMP/release\"" \
  'line "$build_run" "$WORK/ci.release-build" && line "  --out)" "$BUILD"' \
  "no such step in the release-build job (or build-release.sh has no --out)"
upload_name='          name: release-${{ steps.version.outputs.version }}'
upload_path='          path: ${{ runner.temp }}/release/'
step "$WORK/ci.release-build" "$upload_name" >"$WORK/ci.release-build.upload"
check "...and uploads that directory as the artifact release-\${{ steps.version.outputs.version }}" \
  'has "uses: actions/upload-artifact@" "$WORK/ci.release-build.upload" &&
    has_lines "$WORK/ci.release-build.upload" "$upload_path" "          if-no-files-found: error"' \
  "the release-build job uploads the release files another way"
version_out='          echo "version=$(app_version_get .)" >> "$GITHUB_OUTPUT"'
step "$WORK/ci.release-build" '        id: version' >"$WORK/ci.release-build.version"
check "...the version in that name being app_version_get's (the step version)" \
  'has_lines "$WORK/ci.release-build.version" "          . scripts/lib/version.sh" "$version_out"' \
  "the release-build job reads the version another way"
gate_read='          if ! version="$(app_version_get .)"; then'
gate_echo='            echo "version=$version"'
gate_out='      version: ${{ steps.decide.outputs.version }}'
publish_version='      VERSION: ${{ needs.gate.outputs.version }}'
check "release.yml's gate reads the version the same way and hands it to the publish job as VERSION" \
  'has_lines "$WORK/release.gate" "$gate_read" "$gate_echo" "$gate_out" && line "$publish_version" "$WORK/release.publish"' \
  "the gate reads the version another way, or publish takes VERSION from elsewhere"

# --- release.yml's publish job: that artifact, exactly the files of release_assets
download_name='          name: release-${{ env.VERSION }}'
download_path='          path: ${{ runner.temp }}/release-assets'
step "$WORK/release.publish" "$download_name" >"$WORK/release.publish.download"
check "release.yml's publish job downloads the artifact release-\${{ env.VERSION }} to \$RUNNER_TEMP/release-assets" \
  'has "uses: actions/download-artifact@" "$WORK/release.publish.download" && line "$download_path" "$WORK/release.publish.download"' \
  "the publish job takes the release files from elsewhere"
expected_from='expected="$(release_assets "$VERSION" | LC_ALL=C sort)"'
actual_from='actual="$(find "$RUNNER_TEMP/release-assets" -mindepth 1 -maxdepth 1 '
sums_checked='(cd "$RUNNER_TEMP/release-assets" && sha256sum -c SHA256SUMS)'
check "...checks them against release_assets and their SHA256SUMS" \
  'has_all "$WORK/release.publish" "$expected_from" "$actual_from" "$sums_checked"' \
  "the publish job compares the artifact with another list"
assets_read='done < <(release_assets "$VERSION")'
asset_path='assets+=("$RUNNER_TEMP/release-assets/$name")'
upload_url='"https://uploads.github.com/repos/$GH_REPO/releases/$id/assets?name=$(basename "$f")"'
asset_count='-ne "${#assets[@]}" ]]'
check "...and uploads exactly the release_assets files, and the draft must hold as many" \
  'has_all "$WORK/release.publish" "$assets_read" "$asset_path" "$upload_url" "$asset_count" &&
    [ "$(grep -c uploads.github.com "$RELEASE")" = 1 ]' \
  "the publish step uploads another list"

# --- the release: its tag, title, notes and state
tag_name='-f tag_name="$VERSION"'
state_url='/releases/tags/$VERSION"'
v_tag='v\$VERSION|v\$\{VERSION\}|tag_name="v'
check "the release and its tag are the plain version X.Y.Z" \
  'has "$tag_name" "$RELEASE" && has "$state_url" "$STATE" && ! grep -Eq -- "$v_tag" "$RELEASE" "$STATE"' \
  "release.yml or release-state.sh creates or reads a vX.Y.Z tag"
title='-f name="Thermik $VERSION"'
check "the release's title is \"Thermik \$VERSION\"" 'has "$title" "$RELEASE"' "another release title"
check "the release is published as the latest one" 'has "-F draft=false -f make_latest=true" "$RELEASE"' \
  "no make_latest=true on publish"
notes_run='bash .github/scripts/release-notes.sh > "$RUNNER_TEMP/release-notes.md"'
notes_body='-F body=@"$RUNNER_TEMP/release-notes.md"'
check "the release notes come from release-notes.sh, over the whole history (fetch-depth: 0)" \
  'has_all "$WORK/release.publish" "$notes_run" "$notes_body" && line "          fetch-depth: 0" "$WORK/release.publish"' \
  "the notes come from somewhere else"
make_message="$(sed -n 's/^message="\(.*\)"$/\1/p' "$MAKE")"
notes_filter="$(sed -n "s/.*grep -Ev '\([^']*\)'.*/\1/p" "$NOTES")"
notes_left="$(lines '- feat: release - version 1.2.3' '- feat: release - version 10.20.30' '- feat: release - versioning docs' |
  grep -Ev -- "${notes_filter:-^$}")"
gate_notice='Bump it with scripts/make-release.sh (commit \"feat: release - version X.Y.Z\")'
check "make-release.sh commits \"feat: release - version X.Y.Z\", the subject release-notes.sh leaves out and the gate's notice names" \
  '[ "$make_message" = "feat: release - version \$new" ] && [ "$notes_left" = "- feat: release - versioning docs" ] &&
    has "$gate_notice" "$WORK/release.gate"' \
  "make-release.sh's message '$make_message', release-notes.sh's filter '$notes_filter' keeps '$notes_left'"

# `git ls-remote` given a pattern leaves out an annotated tag's peeled line, so it reads the tag object, not the
# commit: an annotated tag release-state.sh accepts as retry would fail the publish job after publishing
yml_lookup='tag_sha="$(git ls-remote --tags origin | tag_commit "$VERSION")"'
state_lookup='tag_sha="$(tag_commit "$VERSION" <<<"$refs")"'
state_refs='refs="$(git -C "$ROOT_DIR" ls-remote --tags origin)"'
check "release.yml checks the tag's commit the way release-state.sh reads it (tag_commit over every tag)" \
  'has "$yml_lookup" "$RELEASE" && has_all "$STATE" "$state_lookup" "$state_refs" &&
    ! grep -Eq "ls-remote[^|]*refs/tags" "$RELEASE" "$STATE"' \
  "a tag is read another way (ls-remote with a pattern?)"

# The release list lags behind a draft created a moment ago: the publish step takes the draft's id from the create
# call and never looks the draft up by its tag
create_call='id="$(gh api --method POST "repos/$GH_REPO/releases"'
create_id='-F draft=true --jq .id)"'
publish_call='gh api --method PATCH "repos/$GH_REPO/releases/$id" -F draft=false -f make_latest=true'
check "publish works with the id the API returns for the new draft, not a lookup by tag" \
  'has_all "$RELEASE" "$create_call" "$create_id" "$upload_url" "$publish_call" &&
    ! grep -Eq "gh release (create|upload|edit)" "$RELEASE"' \
  "release.yml creates or finds the draft another way"

# --- release.yml's tag lookups, run as written: every $(...) of release.yml that pipes into tag_commit, in a clone
# of a local origin where 1.2.3 is an annotated tag on commit A and 1.2.4 a lightweight one on commit B
(
  set -e
  mkdir -p "$WORK/seed"
  cd "$WORK/seed"
  git -c init.defaultBranch=master init -q .
  git symbolic-ref HEAD refs/heads/master
  git commit -q --allow-empty -m A
  git tag -a 1.2.3 -m 'Thermik 1.2.3'
  git commit -q --allow-empty -m B
  git tag 1.2.4
  git init -q --bare "$WORK/origin.git"
  git push -q "$WORK/origin.git" master --tags
  git clone -q "$WORK/origin.git" "$WORK/repo"
) || {
  echo "not ok the test fixture could not be built"
  exit 1
}
A="$(git -C "$WORK/repo" rev-parse '1.2.3^{commit}')" B="$(git -C "$WORK/repo" rev-parse 1.2.4)"
TAG_OBJECT="$(git -C "$WORK/repo" rev-parse 1.2.3)"
# lookup <$(...) of release.yml> <version>: the command substitution in a fresh BASH_BIN that sourced version.sh under
# set -euo pipefail, as the publish step runs it, in the clone with VERSION=<version>; sets OUT, ERR, RC
lookup() {
  ERR="$(cd "$WORK/repo" && VERSION="$2" "$BASH_BIN" -c 'set -euo pipefail; . "$0"; eval "sha=$1"; printf "%s\n" "$sha"' \
    "$LIB" "$1" 2>&1 >"$WORK/out" </dev/null)"
  RC=$?
  OUT="$(cat "$WORK/out")"
}
# release.yml without its comment lines
grep -v '^ *#' "$RELEASE" >"$WORK/release.code"
grep -o '\$([^()]*| *tag_commit [^()]*)' "$WORK/release.code" >"$WORK/lookups"
uses_n="$(grep -o tag_commit "$WORK/release.code" | wc -l | tr -d ' ')"
lookups_n="$(wc -l <"$WORK/lookups" | tr -d ' ')"
check "every tag_commit in release.yml is a \$(...) lookup that pipes into it ($lookups_n of $uses_n)" \
  '[ "$lookups_n" -gt 0 ] && [ "$lookups_n" = "$uses_n" ]' "release.yml calls tag_commit another way"
LC_ALL=C sort -u "$WORK/lookups" >"$WORK/lookups.unique"
while IFS= read -r cmd; do
  lookup "$cmd" 1.2.3
  check "release.yml's $cmd is the commit of an annotated tag, not the tag object" \
    '[ $RC = 0 ] && [ "$OUT" = "$A" ] && [ -z "$ERR" ]' \
    "want $A (the tag object is $TAG_OBJECT); rc=$RC; stdout: '$OUT'; stderr: '$ERR'"
  lookup "$cmd" 1.2.4
  check "...the commit of a lightweight tag" '[ $RC = 0 ] && [ "$OUT" = "$B" ] && [ -z "$ERR" ]' \
    "want $B; rc=$RC; stdout: '$OUT'; stderr: '$ERR'"
  lookup "$cmd" 1.2.5
  check "...nothing for a version without a tag" '[ $RC = 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ]' \
    "rc=$RC; stdout: '$OUT'; stderr: '$ERR'"
done <"$WORK/lookups.unique"

# --- the triggers: a push to master starts release.yml only (which calls ci.yml), no second CI run for that push
check "release.yml runs on pushes to master only (and by hand, workflow_dispatch)" \
  '[ "$(events "$RELEASE")" = "push workflow_dispatch " ] && [ "$(trigger "$RELEASE" push)" = "$(lines "    branches:" "      - master")" ]' \
  "release.yml's events: $(events "$RELEASE"); under push:$(trigger "$RELEASE" push | tr -s '\n ' ' ')"
master_only='if [[ "$GITHUB_REF" != "refs/heads/master" ]]; then'
check "...and its gate publishes from master only (a dry run builds any branch)" 'has "$master_only" "$WORK/release.gate"' \
  "the gate does not refuse another branch"
check "ci.yml runs for the other branches' pushes and pull requests, not for a push to master" \
  '[ "$(trigger "$CI" push)" = "    branches-ignore: [master]" ] && [ "$(events "$CI")" = "push pull_request workflow_dispatch workflow_call " ]' \
  "ci.yml's events: $(events "$CI"); under push:$(trigger "$CI" push | tr -s '\n ' ' ')"
check "release.yml runs the whole CI: its quality job calls ci.yml with release: true" \
  'has_lines "$WORK/release.quality" "    uses: ./.github/workflows/ci.yml" "    with:" "      release: true"' \
  "the quality job does not call ci.yml with release: true"
trigger "$CI" workflow_call >"$WORK/ci.workflow_call"
check "...an input ci.yml declares for workflow_call (a boolean)" \
  'line "      release:" "$WORK/ci.workflow_call" && line "        type: boolean" "$WORK/ci.workflow_call"' \
  "ci.yml has no workflow_call input release"
check "the publish job needs the gate and the CI (needs: [gate, quality])" \
  'line "    needs: [gate, quality]" "$WORK/release.publish"' "the publish job does not need quality"
publish_if="    if: needs.gate.outputs.publish == 'true'"
check "...and runs only when both succeeded: its if is the gate's decision alone (no always() or !cancelled())" \
  'line "$publish_if" "$WORK/release.publish"' "another if"
version_file="$("$BASH_BIN" -c '. "$0"; printf "%s\n" "$VERSION_FILE"' "$LIB" </dev/null)"
for j in gate publish; do
  check "release.yml's $j job checks out what its scripts read: /$version_file, /scripts/lib/, /.github/scripts/" \
    '[ -n "$version_file" ] &&
      has_lines "$WORK/release.$j" "            /$version_file" "            /scripts/lib/" "            /.github/scripts/"' \
    "the sparse checkout lacks one of them"
done

# --- the runners and the Xcode
# other_runners: the jobs on neither Ubuntu nor the macOS label, where release.yml's own jobs run on Ubuntu only;
# calls: the reusable workflows called, ci.yml alone, whose jobs are all checked here
other_runners="$(awk '$2 !~ /^ubuntu-/ && $2 != "uses"' "$WORK/release.runners"
  awk -v m="$MACOS_RUNNER" '$2 !~ /^ubuntu-/ && $2 != m' "$WORK/ci.runners")"
calls="$(awk '$2 == "uses" { print $1, $3 }' "$WORK/release.runners" "$WORK/ci.runners")"
check "every job runs on Ubuntu or on $MACOS_RUNNER, the only macOS label: release.yml's own on Ubuntu (GNU find, sha256sum)" \
  '[ -z "$other_runners" ] && [ "$calls" = "quality ./.github/workflows/ci.yml" ]' \
  "other runners: ${other_runners:--}; reusable workflow calls: ${calls:--}"
macos_jobs="$(awk -v m="$MACOS_RUNNER" '$2 == m { printf "%s ", $1 }' "$WORK/ci.runners")"
check "the macOS jobs are ci.yml's selftest, debug and release-build" \
  '[ "$macos_jobs" = "selftest debug release-build " ]' "on $MACOS_RUNNER: $macos_jobs"
# xcode_first: the jobs that select the Xcode (./.github/actions/xcode) before their first run step; xcode_any: the
# jobs that use it at all
xcode_first='' xcode_any=''
while read -r id _; do
  job "$CI" "$id" >"$WORK/job"
  line '      - uses: ./.github/actions/xcode' "$WORK/job" || continue
  xcode_any="$xcode_any$id "
  if awk '/^      - uses: \.\/\.github\/actions\/xcode$/ && !x { x = NR }
    /^ +run: / && !r { r = NR }
    END { exit !(x && r && x < r) }' "$WORK/job"; then
    xcode_first="$xcode_first$id "
  fi
done <"$WORK/ci.runners"
check "every macOS job selects the Xcode (./.github/actions/xcode) before its first run step, and no other job uses it" \
  '[ -n "$macos_jobs" ] && [ "$xcode_first" = "$macos_jobs" ] && [ "$xcode_any" = "$macos_jobs" ] && ! grep -q "\./\.github/actions/xcode" "$RELEASE"' \
  "macOS jobs: $macos_jobs; select it first: $xcode_first; use it: $xcode_any"
actionlint_run='        run: docker run --rm -v "$PWD:/repo" -w /repo "$ACTIONLINT_IMAGE" -color'
check "actionlint (ci.yml's scripts job) knows the runner label $MACOS_RUNNER from .github/actionlint.yaml" \
  'line "$actionlint_run" "$WORK/ci.scripts" && has_lines "$ACTIONLINT" "self-hosted-runner:" "  labels:" "    - $MACOS_RUNNER"' \
  ".github/actionlint.yaml does not declare $MACOS_RUNNER (or the scripts job runs no actionlint)"
xcode_action="$(awk '/^  xcode-version:$/ { on = 1; next }
  on && /^  [^ ]/ { exit }
  on && /^    default: / { v = $2; gsub(/"/, "", v); print v }' "$XCODE_ACTION")"
xcode_docs="$(sed -n 's/^- Xcode \([0-9][0-9.]*\) or later.*$/\1/p' "$DOCS")"
xcode_project="$(sed -nE 's/^  xcodeVersion: "?([0-9][0-9.]*)"?$/\1/p' "$PROJECT")"
check "the CI's Xcode (.github/actions/xcode, $xcode_action) is the one docs/development.md and project.yml (xcodeVersion) name" \
  '[ -n "$xcode_action" ] && [ "$xcode_action" = "$xcode_docs" ] && [ "$xcode_action" = "$xcode_project" ]' \
  "action.yml '$xcode_action', docs/development.md '$xcode_docs', project.yml '$xcode_project'"
check "...its major version is the runners' $MACOS_RUNNER" '[ "xcode-${xcode_action%%.*}" = "$MACOS_RUNNER" ]' \
  "Xcode $xcode_action on $MACOS_RUNNER"
check "...and build-release.sh's help asks for it" \
  'has "Нужны Xcode $xcode_action или новее" "$WORK/build-release.usage"' "build-release.sh's help names another Xcode"

# --- the checks of the CI itself: these tests under both bashes, shellcheck over every script
check "ci.yml's selftest job runs the thermik-probe self-checks (scripts/lib/selftest.sh)" \
  'line "        run: scripts/lib/selftest.sh" "$WORK/ci.selftest"' "the selftest job has no step run: scripts/lib/selftest.sh"
step "$WORK/ci.selftest" '        run: scripts/tests/run.sh' >"$WORK/ci.selftest.tests"
check "...and these tests under macOS's bash 3.2 (scripts/tests/run.sh with TEST_BASH=/bin/bash)" \
  'line "          TEST_BASH: /bin/bash" "$WORK/ci.selftest.tests"' \
  "the selftest job has no step run: scripts/tests/run.sh with TEST_BASH: /bin/bash"
step "$WORK/ci.scripts" '        run: scripts/tests/run.sh' >"$WORK/ci.scripts.tests"
check "ci.yml's scripts job runs them under Ubuntu's bash 5 (scripts/tests/run.sh, no TEST_BASH)" \
  '[ -s "$WORK/ci.scripts.tests" ] && ! has TEST_BASH "$WORK/ci.scripts.tests"' \
  "the scripts job has no step run: scripts/tests/run.sh, or it sets TEST_BASH"
# the command line, which ends in a backslash: the files follow on the next line
shellcheck_run='          docker run --rm -v "$PWD:/repo" -w /repo --entrypoint shellcheck "$ACTIONLINT_IMAGE" -x -f gcc'
shellcheck_files='            scripts/*.sh scripts/lib/*.sh scripts/tests/*.sh .github/scripts/*.sh'
step "$WORK/ci.scripts" "$shellcheck_files" >"$WORK/ci.scripts.shellcheck"
check "ci.yml's shellcheck step covers scripts/*.sh scripts/lib/*.sh scripts/tests/*.sh .github/scripts/*.sh" \
  'line "$shellcheck_run \\" "$WORK/ci.scripts.shellcheck"' "the shellcheck step checks other files"
unchecked="$(cd "$TREE" && find scripts .github -name '*.sh' | LC_ALL=C sort |
  grep -vE '^(scripts|scripts/lib|scripts/tests|\.github/scripts)/[^/]+\.sh$')"
check "...which are all the shell scripts under scripts/ and .github/" '[ -z "$unchecked" ]' "not shellchecked: $unchecked"

# --- the actions: every remote one pinned to a commit
: >"$WORK/uses"
for f in "$TREE"/.github/workflows/*.yml "$TREE"/.github/workflows/*.yaml "$TREE"/.github/actions/*/action.yml \
  "$TREE"/.github/actions/*/action.yaml; do
  [ -f "$f" ] || continue
  FILE="${f#"$TREE"/}" awk '/^ *(- )?uses: / { sub(/^ *(- )?uses: /, ""); print ENVIRON["FILE"] ": " $0 }' "$f" >>"$WORK/uses"
done
remote_n="$(grep -cE '^[^:]*: [A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@' "$WORK/uses")"
unpinned="$(grep -vE '^[^:]*: (\./[^ ]+|[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40} # v[0-9]+\.[0-9]+\.[0-9]+)$' "$WORK/uses")"
check "every remote action (uses:, $remote_n of them) is pinned to a 40-hex commit SHA with a # vX.Y.Z comment" \
  '[ "$remote_n" -gt 0 ] && [ -z "$unpinned" ]' "not pinned that way: $unpinned"
pinned_twice="$(sed -nE 's/^[^:]*: ([^@ ]+)@([0-9a-f]{40}) # (v[0-9.]+)$/\1 \2 \3/p' "$WORK/uses" | LC_ALL=C sort -u |
  awk '{ n[$1]++ } n[$1] == 2 { print $1 }')"
check "...each action to one commit and version everywhere" '[ -z "$pinned_twice" ]' "pinned differently: $pinned_twice"

echo "# $pass passed, $fail failed"
[ "$fail" = 0 ]
