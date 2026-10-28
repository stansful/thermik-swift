#!/usr/bin/env bash
# Prepares a release: shows the current version (MARKETING_VERSION in Config/Shared.xcconfig) with its build number
# (CURRENT_PROJECT_VERSION) and the last release tag, asks for the new version (Enter takes the next minor version),
# checks that it is higher than the current version and every release tag (local ones and origin's), writes it and
# the next build number into Config/Shared.xcconfig and commits only that file as "feat: release - version X.Y.Z". It
# never pushes: the release starts when that commit reaches master on GitHub (.github/workflows/release.yml: the CI
# checks, the release build and the release X.Y.Z). No tags here: GitHub creates the tag X.Y.Z when the workflow
# publishes the release.
#
#   scripts/make-release.sh [X.Y.Z|patch|minor|major] [--yes] [--no-commit]
#
# Runs from any directory; bash 3.2 (macOS) or 5 (Linux), BSD or GNU tools. Messages are in Russian.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "$HERE/.." && pwd -P)"
# shellcheck source=scripts/lib/version.sh
. "$HERE/lib/version.sh"

usage() {
  cat <<'EOF'
Готовит релиз Thermik: новая версия в Config/Shared.xcconfig (MARKETING_VERSION, а номер сборки
CURRENT_PROJECT_VERSION — на единицу больше) и коммит «feat: release - version X.Y.Z». Релиз X.Y.Z выходит, когда
этот коммит оказывается в master на GitHub.

  scripts/make-release.sh [X.Y.Z|patch|minor|major] [--yes] [--no-commit]

  X.Y.Z         новая версия; без неё скрипт покажет текущую и спросит (Enter — следующая минорная версия)
  patch, minor, major
                следующая патч-, минорная или мажорная версия (можно и по-русски: патч, минор, мажор)
  -y, --yes     без вопросов: версия — следующая минорная (если не указана), коммит без подтверждения
  --no-commit   только записать версию в Config/Shared.xcconfig, без коммита
  -h, --help    эта справка

Версия — X.Y.Z без ведущих нулей и без «v», каждое число до 9 цифр; она должна быть выше текущей и всех релизных
тегов (своих и в origin). Теги скрипт не ставит: тег X.Y.Z создаёт GitHub при публикации релиза.
EOF
}

say() { printf '%s\n' "$*"; }
warn() { printf 'Внимание: %s\n' "$*" >&2; }
die() {
  printf 'Ошибка: %s\n' "$*" >&2
  exit 1
}
usage_error() {
  printf 'Ошибка: %s\n\n' "$*" >&2
  usage >&2
  exit 2
}
yes_answer() {
  case $1 in
  y | Y | yes | Yes | YES | д | Д | да | Да | ДА) return 0 ;;
  *) return 1 ;;
  esac
}
trim() {
  local s="$1"
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}
# bump_kind <word>: prints patch, minor or major for a bump word; fails for anything else
bump_kind() {
  case $1 in
  patch | Patch | PATCH | патч | Патч) echo patch ;;
  minor | Minor | MINOR | минор | Минор) echo minor ;;
  major | Major | MAJOR | мажор | Мажор) echo major ;;
  *) return 1 ;;
  esac
}

new='' have_new='' yes='' commit=1
while [ $# -gt 0 ]; do
  case $1 in
  -h | --help)
    usage
    exit 0
    ;;
  -y | --yes) yes=1 ;;
  --no-commit) commit= ;;
  -*) usage_error "неизвестный параметр $1" ;;
  *)
    [ -z "$have_new" ] || usage_error "версия указана дважды: $new и $1"
    new=$1 have_new=1
    ;;
  esac
  shift
done

# --- the repository
command -v git >/dev/null 2>&1 || die "нужен git."
top="$(git -C "$ROOT_DIR" rev-parse --show-toplevel 2>/dev/null)" ||
  die "$ROOT_DIR — не git-репозиторий. Сначала git init, первый коммит и git remote add origin <url>."
# -ef, not the paths as strings: on a case-insensitive volume the path typed may differ in case from git's
[ "$top" -ef "$ROOT_DIR" ] || die "$ROOT_DIR — не корень git-репозитория (корень: $top)."
cd "$ROOT_DIR"
git rev-parse -q --verify HEAD >/dev/null || die "в репозитории ещё нет коммитов: сначала закоммитьте проект."
branch="$(git symbolic-ref -q --short HEAD)" ||
  die "HEAD не на ветке (detached HEAD): переключитесь на ветку, например: git switch master."
git ls-files --error-unmatch "$VERSION_FILE" >/dev/null 2>&1 || die "$VERSION_FILE не в git: закоммитьте его."

dirty="$(git status --porcelain --untracked-files=no)"
if [ -n "$dirty" ]; then
  printf 'Ошибка: есть незакоммиченные изменения (рабочее дерево или индекс):\n%s\n' "$dirty" >&2
  printf 'Закоммитьте их или уберите (git stash) и запустите снова: в релизный коммит входит только %s.\n' \
    "$VERSION_FILE" >&2
  exit 1
fi
untracked="$(git ls-files --others --exclude-standard)"
if [ -n "$untracked" ]; then
  warn "есть файлы не в git, в релиз они не попадут:"
  printf '%s\n' "$untracked" | sed -n '1,10s/^/  /p' >&2
  [ "$(printf '%s\n' "$untracked" | wc -l | tr -d ' ')" -le 10 ] || printf '  …\n' >&2
fi

has_origin=
git remote get-url origin >/dev/null 2>&1 && has_origin=1

# The default branch: origin's HEAD, else master or main (origin's or local)
default=
if ref="$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)"; then
  default=${ref#origin/}
else
  for b in master main; do
    if git show-ref -q --verify "refs/remotes/origin/$b" || git show-ref -q --verify "refs/heads/$b"; then
      default=$b
      break
    fi
  done
fi
if [ -z "$default" ]; then
  warn "не удалось определить ветку по умолчанию; релиз выходит только из master."
elif [ "$branch" != "$default" ]; then
  warn "вы на ветке $branch, а релиз выходит из ветки по умолчанию $default: этот коммит выпустится только после слияния в $default."
fi
if [ -n "$has_origin" ] && git show-ref -q --verify "refs/remotes/origin/$branch"; then
  behind="$(git rev-list --count "HEAD..refs/remotes/origin/$branch")"
  [ "$behind" = 0 ] ||
    warn "ветка $branch отстаёт от origin/$branch на $behind коммит(ов) (по последнему fetch): сначала git pull."
fi

# --- versions
current="$(app_version_get "$ROOT_DIR")" ||
  die "в $VERSION_FILE должна быть ровно одна строка MARKETING_VERSION = X.Y.Z: исправьте файл вручную и закоммитьте."
version_valid "$current" ||
  die "в $VERSION_FILE MARKETING_VERSION = «${current}», а не X.Y.Z (без ведущих нулей и «v», числа до 9 цифр): исправьте файл вручную и закоммитьте."
current_build="$(app_build_get "$ROOT_DIR")" ||
  die "в $VERSION_FILE должна быть ровно одна строка CURRENT_PROJECT_VERSION = N: исправьте файл вручную и закоммитьте."
build_valid "$current_build" ||
  die "в $VERSION_FILE CURRENT_PROJECT_VERSION = «${current_build}», а не номер сборки (целое число от 1, до 9 цифр, без ведущих нулей): исправьте файл вручную и закоммитьте."
new_build=$((current_build + 1))
build_valid "$new_build" || die "номер сборки $current_build больше не поднять: в нём уже 9 цифр."

# Releases are tagged on GitHub, so a clone often has no tags of its own: origin's count. tags_known is empty when
# origin has them but they could not be read. --no-column: one tag per line whatever column.ui says.
tags="$(git tag -l --no-column)" tags_known=1
if [ -n "$has_origin" ]; then
  if remote="$(GIT_TERMINAL_PROMPT=0 git ls-remote --tags origin)"; then
    tags="$tags
$remote"
  else
    tags_known=
    warn "не удалось прочитать теги origin ($(git remote get-url origin)): сравниваю только с локальными тегами."
  fi
fi
highest="$(printf '%s\n' "$tags" | highest_tag)"
highest_version=${highest%% *}
last_tag=${highest#* }

say "Текущая версия:         $current ($VERSION_FILE, сборка $current_build)"
if [ -n "$highest" ]; then
  if [ -n "$tags_known" ]; then
    say "Последний релизный тег: $last_tag"
  else
    say "Последний релизный тег: $last_tag (из локальных тегов)"
  fi
elif [ -n "$tags_known" ]; then
  say "Релизных тегов пока нет."
else
  say "Релизные теги неизвестны: локальных нет, а origin не прочитан."
fi
if [ -n "$tags_known" ] && { [ -z "$highest" ] || version_gt "$current" "$highest_version"; }; then
  say "Тега $current ещё нет: если коммит с этой версией уже в master на GitHub, релиз $current выйдет и без новой версии."
fi
base=$current
[ -z "$highest" ] || ! version_gt "$highest_version" "$base" || base=$highest_version
# The bumps of the base that are versions (above the current version and every tag they always are); Enter and
# --yes take the minor one, or the major one when the minor number cannot grow, or the patch one when neither can
choices='' suggested='' first=''
for kind in patch minor major; do
  v="$(version_bump "$base" "$kind")"
  version_valid "$v" || continue
  choices="$choices${choices:+, }$v ($kind)"
  [ -n "$first" ] || first=$v
  [ "$kind" = patch ] || [ -n "$suggested" ] || suggested=$v
done
[ -n "$choices" ] || die "после $base нет версии X.Y.Z с числами до 9 цифр: дальше выпускать некуда."
[ -n "$suggested" ] || suggested=$first

# check_version <v>: prints why v cannot be the new version, and fails
check_version() {
  local v="$1" t
  if [ -z "$v" ]; then
    echo "версия не указана"
    return 1
  fi
  if ! version_valid "$v"; then
    case $v in
    v[0-9]* | V[0-9]*) echo "«${v}»: нужна версия без «v», например ${v#?}" ;;
    *) echo "«${v}» — не версия X.Y.Z (три числа до 9 цифр без ведущих нулей, например $suggested)" ;;
    esac
    return 1
  fi
  t="$(printf '%s\n' "$tags" | tag_of_version "$v")"
  if [ -n "$t" ]; then
    echo "тег $t уже есть: версия $v уже выпускалась"
    return 1
  fi
  if ! version_gt "$v" "$current"; then
    echo "версия $v не выше текущей $current"
    return 1
  fi
  if [ -n "$highest" ] && ! version_gt "$v" "$highest_version"; then
    echo "версия $v не выше последнего релизного тега $last_tag"
    return 1
  fi
}
# resolve <answer>: prints the version an answer names: a bump word becomes that bump of the base version
resolve() {
  local kind
  if kind="$(bump_kind "$1")"; then
    version_bump "$base" "$kind"
  else
    printf '%s' "$1"
  fi
}

if [ -n "$have_new" ]; then
  new="$(resolve "$new")"
  reason="$(check_version "$new")" || die "$reason."
  say "Новая версия: $new (сборка $new_build)"
elif [ -n "$yes" ]; then
  new=$suggested
  reason="$(check_version "$new")" || die "$reason."
  say "Новая версия: $new (сборка $new_build)"
else
  say "Следующая: $choices."
  while :; do
    printf 'Новая версия [%s]: ' "$suggested"
    if ! IFS= read -r answer; then
      echo
      die "ввод прерван, ничего не изменено."
    fi
    answer="$(trim "$answer")"
    [ -n "$answer" ] || answer=$suggested
    answer="$(resolve "$answer")"
    if reason="$(check_version "$answer")"; then
      new=$answer
      break
    fi
    printf '  %s. Введите другую версию.\n' "$reason" >&2
  done
fi

# --- Config/Shared.xcconfig and the commit
message="feat: release - version $new"
numstat="$(printf '2\t2\t%s' "$VERSION_FILE")"
restore() { git checkout -q -- "$VERSION_FILE"; }
# HUP too: a closed terminal or a dropped ssh session at the question must not leave the file rewritten
trap 'restore; printf "\nПрервано: %s возвращён.\n" "$VERSION_FILE" >&2; exit 130' INT TERM HUP
# Exactly the two lines change, to exactly the new version and build number
if ! app_version_set "$ROOT_DIR" "$new" "$new_build" || [ "$(app_version_get "$ROOT_DIR")" != "$new" ] ||
  [ "$(app_build_get "$ROOT_DIR")" != "$new_build" ] ||
  [ "$(git diff --numstat -- "$VERSION_FILE")" != "$numstat" ]; then
  restore
  die "не удалось записать версию $new в $VERSION_FILE, файл возвращён."
fi
git --no-pager diff -- "$VERSION_FILE"

if [ -z "$commit" ]; then
  trap - INT TERM HUP
  say "$VERSION_FILE: версия $new, сборка $new_build. Коммит не создан (--no-commit). Закоммитьте только этот файл:"
  say "  git commit -m '$message' -- $VERSION_FILE"
  exit 0
fi
if [ -z "$yes" ]; then
  printf 'Закоммитить %s как «%s»? [Y/n] ' "$VERSION_FILE" "$message"
  if ! IFS= read -r answer; then
    echo
    restore
    die "ввод прерван, $VERSION_FILE возвращён."
  fi
  answer="$(trim "$answer")"
  if [ -n "$answer" ] && ! yes_answer "$answer"; then
    restore
    say "Отменено: $VERSION_FILE возвращён, коммита нет."
    exit 1
  fi
fi
parent="$(git rev-parse HEAD)"
if ! git commit -q -m "$message" -- "$VERSION_FILE"; then
  restore
  die "git commit не удался, $VERSION_FILE возвращён."
fi
# git hooks (pre-commit and the like) run on the commit's own index: whatever one stages lands in the commit.
# The release commit is the two lines of Config/Shared.xcconfig with the new version and build number and nothing
# else, or it is undone.
changed="$(git diff-tree -r --name-only "$parent" HEAD)"
if [ "$changed" != "$VERSION_FILE" ] || [ "$(git diff --numstat "$parent" HEAD)" != "$numstat" ] ||
  [ "$(git show "HEAD:$VERSION_FILE" 2>/dev/null | app_version_parse)" != "$new" ] ||
  [ "$(git show "HEAD:$VERSION_FILE" 2>/dev/null | app_build_parse)" != "$new_build" ]; then
  git reset -q --soft "$parent"
  git reset -q -- "$VERSION_FILE"
  restore
  trap - INT TERM HUP
  {
    printf 'Ошибка: хук git (pre-commit или другой) изменил релизный коммит, а в нём должны быть только строки версии %s и сборки %s в %s. В коммит попало:\n' "$new" "$new_build" "$VERSION_FILE"
    printf '%s\n' "$changed" | sed 's/^/  /'
    printf 'Коммит отменён, %s возвращён; что хук поменял в рабочем дереве, там и осталось (git status).\n' "$VERSION_FILE"
    printf 'Поправьте хук или закоммитьте в обход хуков: scripts/make-release.sh %s --no-commit, затем\n' "$new"
    printf "  git commit --no-verify -m '%s' -- %s\n" "$message" "$VERSION_FILE"
  } >&2
  exit 1
fi
trap - INT TERM HUP
say "Коммит $(git rev-parse --short HEAD): $message (сборка $new_build)"
say "Релиз $new выйдет, когда этот коммит окажется в master на GitHub (.github/workflows/release.yml)."
