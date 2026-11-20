#!/usr/bin/env bash
# Mirrors skills/<name>/ into .claude/skills/ and .agents/skills/ for native skill discovery. Contract: docs/CONTRACTS.md, "link-skills.sh".
set -euo pipefail
SF_PROG=link-skills
# shellcheck source=scripts/lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: link-skills.sh [--copy | --check | --clean] [--tree DIR]

For every skills/<name>/ that holds a SKILL.md, makes .claude/skills/<name> and
.agents/skills/<name> point at it: a symlink to ../../skills/<name> where the
system can make one, otherwise a copy. Prints one line per mirror saying which.
The mirrors are kept out of git (via .git/info/exclude when no ignore rule covers them).

  --copy   make copies even where symlinks work
  --check  exit 1 if any mirror is missing or differs from its skill
  --clean  remove the mirrors this script makes; anything else is left alone
  --tree   the project root (default: the current git repository's root)

On Windows, Git Bash's "ln -s" copies instead of linking unless native symlinks
are allowed (Developer Mode); this script detects that and reports a copy.
Exit codes: 0 done, 1 --check found a problem or a path was in the way, 2 error.
EOF
}

MIRRORS=".claude/skills .agents/skills"
# A file inside each copy marks it as made by this script, so a project's own skill
# with the same name is never overwritten or removed.
MARK=".factory-mirror"

mode="link"
tree=""
action="link"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --copy) mode=copy; shift ;;
    --check)
      [ "$action" = link ] || sf_die "use only one of --check and --clean"
      action=check; shift ;;
    --clean)
      [ "$action" = link ] || sf_die "use only one of --check and --clean"
      action=clean; shift ;;
    --tree) [ "$#" -ge 2 ] || sf_die "--tree needs a directory"; tree="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) sf_die "unknown argument: $1 (see --help)" ;;
  esac
done
if [ "$mode" = copy ] && [ "$action" != link ]; then
  sf_die "--copy cannot be combined with --check or --clean"
fi

if [ -n "$tree" ]; then
  [ -d "$tree" ] || sf_die "no such directory: $tree"
  root=$(cd "$tree" && pwd)
else
  root=$(sf_repo_root)
fi
[ -d "$root/skills" ] || sf_die "no skills/ directory in $root"

skills=""
for d in "$root"/skills/*/; do
  [ -f "${d}SKILL.md" ] || continue
  name=$(basename "$d")
  case "$name" in
    .* | *[!A-Za-z0-9._-]*) sf_warn "skipping skills/$name: use letters, digits, '.', '_' and '-' in skill names"; continue ;;
  esac
  skills="$skills $name"
done
if [ -z "$skills" ]; then
  sf_log "no skills/<name>/SKILL.md found in $root; nothing to do"
  exit 0
fi

# tree_files DIR: relative paths of the regular files under DIR, minus the marker.
tree_files() {
  (cd "$1" && find . -type f ! -name "$MARK" | LC_ALL=C sort)
}

# same_tree SRC DST: true when both hold the same files with the same bytes.
same_tree() {
  local a="$1" b="$2" list f
  list=$(tree_files "$a")
  [ "$list" = "$(tree_files "$b")" ] || return 1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    cmp -s "$a/$f" "$b/$f" || return 1
  done <<EOF
$list
EOF
}

# mirror_kind SRC DST: missing | link (resolves to SRC) | copy (made here) | foreign.
mirror_kind() {
  local src="$1" dst="$2"
  if [ -L "$dst" ]; then
    if [ -d "$dst" ] && [ "$(cd "$dst" && pwd -P)" = "$(cd "$src" && pwd -P)" ]; then
      echo link
    else
      echo foreign
    fi
  elif [ -d "$dst" ] && [ -f "$dst/$MARK" ]; then
    echo copy
  elif [ -e "$dst" ]; then
    echo foreign
  else
    echo missing
  fi
}

# try_symlink TARGET LINK: make LINK a real symlink to TARGET or fail, leaving nothing
# behind. winsymlinks:nativestrict makes Git Bash create a native Windows symlink or
# fail, instead of silently copying; other systems ignore MSYS.
try_symlink() {
  MSYS="${MSYS:+$MSYS }winsymlinks:nativestrict" ln -s "$1" "$2" 2>/dev/null || return 1
  [ -L "$2" ] && return 0
  rm -rf "$2"
  return 1
}

# symlinks_work DIR: can a real directory symlink be made inside DIR?
SF_PROBE=""
cleanup() { if [ -n "$SF_PROBE" ]; then rm -rf "$SF_PROBE"; fi; }
trap cleanup EXIT
symlinks_work() {
  local ok=1
  SF_PROBE=$(mktemp -d "$1/.sf-link-probe.XXXXXX") || return 1
  mkdir "$SF_PROBE/target"
  if try_symlink target "$SF_PROBE/link"; then ok=0; fi
  rm -rf "$SF_PROBE"
  SF_PROBE=""
  return "$ok"
}

# make_copy NAME SRC DST: the marker goes in first, so a copy that fails halfway is
# still recognised as ours: the next run replaces it and --clean removes it.
make_copy() {
  if ! mkdir "$3" ||
    ! printf 'Copy of skills/%s made by scripts/link-skills.sh. Edit skills/%s, then run link-skills.sh again.\n' \
      "$1" "$1" >"$3/$MARK" ||
    ! cp -R "$2/." "$3/"; then
    sf_die "could not copy skills/$1 to ${3#"$root"/}; fix the cause and run again (--clean removes the partial copy)"
  fi
}

# remove_copy DST REL: delete a copy, the marker last, so a removal that stops halfway
# (Windows refuses to delete a file another program holds open) leaves it marked.
remove_copy() {
  local f
  for f in "$1"/* "$1"/.*; do
    case "${f##*/}" in . | .. | "$MARK") continue ;; esac
    if [ -e "$f" ] || [ -L "$f" ]; then
      rm -rf "$f" || sf_die "could not remove $2; close programs using it and run again"
    fi
  done
  if ! rm -f "$1/$MARK" || ! rmdir "$1"; then
    sf_die "could not remove $2; close programs using it and run again"
  fi
}

# keep_out_of_git REL: add /REL to .git/info/exclude unless an ignore rule covers it.
keep_out_of_git() {
  local rel="$1" exclude prefix line
  git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  # --no-index: judge tracked mirrors by the rules too, or every run would add them again.
  git -C "$root" check-ignore -q --no-index -- "$rel" 2>/dev/null && return 0
  exclude=$(git -C "$root" rev-parse --git-path info/exclude) || return 0
  prefix=$(git -C "$root" rev-parse --show-prefix) || return 0
  case "$exclude" in /* | [A-Za-z]:*) ;; *) exclude="$root/$exclude" ;; esac
  line="/$prefix$rel"
  if [ -f "$exclude" ]; then
    if grep -Fxq -- "$line" "$exclude"; then return 0; fi
    # Appending to a last line that has no "\n" would rewrite the operator's rule.
    if [ -n "$(tail -c 1 "$exclude")" ]; then printf '\n' >>"$exclude"; fi
  else
    mkdir -p "$(dirname "$exclude")"
  fi
  printf '%s\n' "$line" >>"$exclude"
  sf_log "added $line to $exclude"
}

problems=0

do_check() {
  local name m src dst rel
  for name in $skills; do
    src="$root/skills/$name"
    for m in $MIRRORS; do
      rel="$m/$name"
      dst="$root/$rel"
      if [ ! -e "$dst" ] && [ ! -L "$dst" ]; then
        sf_log "missing: $rel"
      elif [ ! -f "$dst/SKILL.md" ]; then
        sf_log "stale: $rel has no SKILL.md"
      elif ! cmp -s "$src/SKILL.md" "$dst/SKILL.md"; then
        sf_log "stale: $rel/SKILL.md differs from skills/$name/SKILL.md"
      elif [ ! -L "$dst" ] && ! same_tree "$src" "$dst"; then
        sf_log "stale: $rel differs from skills/$name"
      else
        continue
      fi
      problems=$((problems + 1))
    done
  done
  if [ "$problems" -gt 0 ]; then
    sf_log "$problems mirror(s) missing or stale; run: bash scripts/link-skills.sh"
    return 1
  fi
  sf_log "all mirrors are current"
}

do_clean() {
  local name m src dst rel kind dir
  for name in $skills; do
    src="$root/skills/$name"
    for m in $MIRRORS; do
      rel="$m/$name"
      dst="$root/$rel"
      kind=$(mirror_kind "$src" "$dst")
      case "$kind" in
        link) rm -f "$dst"; printf 'removed %s (symlink)\n' "$rel" ;;
        copy) remove_copy "$dst" "$rel"; printf 'removed %s (copy)\n' "$rel" ;;
        foreign) sf_warn "left $rel alone: it was not made by link-skills.sh" ;;
        missing) ;;
      esac
    done
  done
  for m in $MIRRORS; do
    dir="$root/$m"
    if [ -d "$dir" ] && rmdir "$dir" 2>/dev/null; then
      rmdir "$(dirname "$dir")" 2>/dev/null || true
    fi
  done
}

do_link() {
  local want="$mode" why name m src dst rel kind made_links=0 made_copies=0
  for m in $MIRRORS; do
    mkdir -p "$root/$m" || sf_die "could not create $m"
  done
  why="--copy"
  if [ "$want" = link ] && ! symlinks_work "$root/${MIRRORS%% *}"; then
    want=copy
    why="symlinks are not available here"
  fi
  for name in $skills; do
    src="$root/skills/$name"
    for m in $MIRRORS; do
      rel="$m/$name"
      dst="$root/$rel"
      kind=$(mirror_kind "$src" "$dst")
      if [ "$kind" = foreign ]; then
        sf_warn "conflict: $rel exists and was not made by link-skills.sh; left alone"
        problems=$((problems + 1))
        continue
      fi
      if [ "$want" = link ]; then
        if [ "$kind" = link ]; then
          printf 'unchanged %s (symlink)\n' "$rel"
        else
          if [ "$kind" = copy ]; then remove_copy "$dst" "$rel"; fi
          if try_symlink "../../skills/$name" "$dst"; then
            printf 'linked %s -> ../../skills/%s (symlink)\n' "$rel" "$name"
            made_links=$((made_links + 1))
          else
            make_copy "$name" "$src" "$dst"
            printf 'copied %s (copy: ln -s did not make a symlink)\n' "$rel"
            made_copies=$((made_copies + 1))
          fi
        fi
      elif [ "$kind" = link ] && [ "$mode" = link ]; then
        # ln stopped working here (e.g. Developer Mode was turned off), but this link
        # still resolves to the skill: keep it rather than swap it for a copy.
        printf 'unchanged %s (symlink)\n' "$rel"
      elif [ "$kind" = copy ] && same_tree "$src" "$dst"; then
        printf 'unchanged %s (copy)\n' "$rel"
      else
        case "$kind" in
          link) rm -f "$dst" ;;
          copy) remove_copy "$dst" "$rel" ;;
        esac
        make_copy "$name" "$src" "$dst"
        printf 'copied %s (copy: %s)\n' "$rel" "$why"
        made_copies=$((made_copies + 1))
      fi
      keep_out_of_git "$rel"
    done
  done
  if [ "$made_copies" -gt 0 ] && [ "$mode" = link ]; then
    sf_warn "made copies, not symlinks: ln -s cannot create symlinks here (on Windows, turn on Developer Mode). Re-run after editing a skill, or check with --check."
  elif [ "$made_links" -gt 0 ]; then
    sf_log "made symlinks"
  fi
  if [ "$problems" -gt 0 ]; then
    sf_log "$problems path(s) were in the way; move them aside and run again"
    return 1
  fi
}

case "$action" in
  check) do_check ;;
  clean) do_clean ;;
  link) do_link ;;
esac
