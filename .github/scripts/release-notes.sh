#!/usr/bin/env bash
# Prints the notes of release $VERSION: the commit subjects since the previous release tag (the highest X.Y.Z or
# vX.Y.Z tag in the history of $GITHUB_SHA other than $VERSION), newest first, one "- " line each, without merges
# and without the release commits of scripts/make-release.sh ("feat: release - version X.Y.Z"); then how to install
# the build.
#
# Env: GITHUB_SHA (default HEAD), VERSION (default: Config/Shared.xcconfig).
# Reads the tags and the history of this checkout (release.yml fetches them all).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "$HERE/../.." && pwd -P)"
# shellcheck source=scripts/lib/version.sh
. "$ROOT_DIR/scripts/lib/version.sh"

sha="${GITHUB_SHA:-HEAD}"
VERSION="${VERSION:-$(app_version_get "$ROOT_DIR" || true)}"
version_valid "$VERSION" || {
  echo "release-notes: «${VERSION}» is not X.Y.Z" >&2
  exit 1
}

# --no-column: one tag per line whatever column.ui says
prev="$(git -C "$ROOT_DIR" tag --no-column --merged "$sha" | highest_tag "$VERSION")"
prev=${prev#* }
changes="$(git -C "$ROOT_DIR" log --no-merges --max-count=200 --pretty=format:'- %s' "${prev:+$prev..}$sha" |
  { grep -Ev '^- feat: release - version (0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' || true; })"

printf '%s\n' "${changes:-- Release $VERSION}"
# One line: GitHub shows every newline of a release body as a line break
printf '\n%s%s%s%s%s%s\n' \
  "**Install:** open \`Thermik-$VERSION.dmg\` and drag \`Thermik.app\` to Applications, " \
  "or unzip \`Thermik-$VERSION.zip\` and move \`Thermik.app\` there. " \
  "The app is ad-hoc signed and not notarized, so macOS blocks its first launch: open it once, then allow it in " \
  "System Settings › Privacy & Security › Open Anyway, " \
  "or run \`xattr -dr com.apple.quarantine /Applications/Thermik.app\`. " \
  "\`Thermik-$VERSION.sha256\` holds the checksums."
