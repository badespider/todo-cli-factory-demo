#!/usr/bin/env bash
# Copies the factory (instructions, skills, scripts, templates, workflows) into a project. Contract: docs/CONTRACTS.md, "install.sh".
set -euo pipefail
SF_PROG=install
# shellcheck source=scripts/lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
# shellcheck source=scripts/lib/jq.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/jq.sh"

# What install copies, relative to the factory root, in the contract's order.
# Entries ending in "/" are directories, copied recursively and filtered by want_file.
SF_MANIFEST=(
  AGENTS.md
  CLAUDE.md
  .gemini/settings.json
  skills/
  scripts/
  templates/
  factory/feature-map.schema.json
  factory/crontab.example
  factory/harness/
  .github/workflows/gate.yml
  .github/workflows/build.yml
  .github/workflows/standing-agents.yml
)
# Created in the target only when missing; never overwritten, even with --force.
SF_CONFIG_TEMPLATE=templates/factory.config.yaml
SF_CONFIG=factory.config.yaml
SF_MAP=factory/feature-map.json
SF_NL='
'
# Lines appended to the target's own files where missing (never rewriting what is there).
SF_IGNORE=.gitignore
SF_IGNORE_LINES=.factory/
# The factory's line-ending rules: its bash scripts and the files they read keep LF on
# every OS, whatever core.autocrlf says. text=auto leaves files git detects as binary
# alone (plain "text" would rewrite their CRLF bytes), and the leading "/" keeps each rule
# to the top level (a project's own docs/AGENTS.md is not the factory's; a pattern with a
# "/" inside, such as "scripts/**", was anchored there already). Appended last, they
# win over the project's earlier rules for these paths; the project's own lines, an older
# factory's "scripts/** text eol=lf" among them, stay as they are.
SF_ATTR=.gitattributes
SF_ATTR_LINES="/scripts/** text=auto eol=lf
/skills/** text=auto eol=lf
/templates/** text=auto eol=lf
/factory/** text=auto eol=lf
/.github/workflows/** text=auto eol=lf
/AGENTS.md text=auto eol=lf
/CLAUDE.md text=auto eol=lf"
SF_COMMIT_SUBJECT="chore(factory): install software-factory"
SF_COMMIT_TRAILER="Factory-Operator: install"

usage() {
  cat <<'EOF'
Usage: install.sh TARGET_DIR [--commit] [--force]

Copies the software factory from the factory root holding this script into
TARGET_DIR, which must be the top of a git work tree:
  AGENTS.md, CLAUDE.md, .gemini/settings.json, skills/, scripts/ (*.sh, lib/*.sh,
  lib/*.awk), templates/ (except templates/factory.config.yaml),
  factory/feature-map.schema.json, factory/crontab.example, factory/harness/ and
  .github/workflows/{gate,build,standing-agents}.yml.
Creates factory/feature-map.json ({"version":1,"features":[]}) and
factory.config.yaml (from templates/factory.config.yaml) only when they are
missing; they are never overwritten. Appends ".factory/" to .gitignore, and the
factory's line-ending rules ("/scripts/** text=auto eol=lf" and the like, for
/scripts, /skills, /templates, /factory, /.github/workflows, /AGENTS.md and
/CLAUDE.md) to .gitattributes, each line only where it is missing; the project's
own lines stay, an older factory's "scripts/** text eol=lf" too.

Everything is planned before anything is written. A target file that exists and
differs from the factory's copy is a conflict: the conflicts are printed on stdout
and nothing is written. Identical files are left alone, so a second run is a no-op.
Symlinks in the factory source are never followed or copied.

  --force   overwrite conflicting files (never factory.config.yaml or the map)
  --commit  stage the installed files (scripts/**/*.sh executable) and commit
            "chore(factory): install software-factory" with the trailer
            "Factory-Operator: install", as the repository's own identity.
            Refused before anything is written when other changes are staged,
            git ignores a factory file, git has no identity, or a merge,
            cherry-pick, revert or rebase is in progress

Prints the written paths on stdout, one per line, and a summary on stderr.
Exit codes: 0 installed, 1 conflicts (nothing written), 2 error.
EOF
}

target=""
force=0
commit=0
set_target() {
  [ -z "$target" ] || sf_die "only one TARGET_DIR may be given (see --help)"
  [ -n "$1" ] || sf_die "TARGET_DIR is empty"
  target="$1"
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force) force=1; shift ;;
    --commit) commit=1; shift ;;
    -h | --help) usage; exit 0 ;;
    --) shift; break ;;
    -*) sf_die "unknown argument: $1 (see --help)" ;;
    *) set_target "$1"; shift ;;
  esac
done
for a in "$@"; do set_target "$a"; done
[ -n "$target" ] || sf_die "missing TARGET_DIR (see --help)"
[ -d "$target" ] || sf_die "TARGET_DIR is not a directory: $target"
target=$(cd "$target" && pwd) || sf_die "cannot enter TARGET_DIR: $target"
src="$SF_FACTORY_ROOT"

sf_need git awk cmp cp mkdir find sort tail

# The target must be the top of a git work tree, not a subdirectory or a .git dir.
top=$(git -C "$target" rev-parse --is-inside-work-tree --show-cdup 2>/dev/null) ||
  sf_die "TARGET_DIR is not inside a git work tree: $target"
[ "$top" = true ] || sf_die "TARGET_DIR is not the top of a git work tree: $target"

# --- helpers -------------------------------------------------------------------------
# They set globals instead of printing, so the per-file loops fork no subshells.

# want_file DIR_ENTRY REL: whether REL (a path under DIR_ENTRY) is installed.
want_file() {
  case "$1" in
    scripts/)
      case "$2" in
        */*/*) return 1 ;;
        lib/*.sh | lib/*.awk) return 0 ;;
        */*) return 1 ;;
        *.sh) return 0 ;;
        *) return 1 ;;
      esac ;;
    templates/) [ "$1$2" != "$SF_CONFIG_TEMPLATE" ] ;;
    *) return 0 ;;
  esac
}

# link_in_path ROOT REL: true when REL, or a directory on the way to it, is a symlink.
link_in_path() {
  local root="$1" rest="$2" p=""
  while [ -n "$rest" ]; do
    case "$rest" in
      */*) p="${p:+$p/}${rest%%/*}"; rest="${rest#*/}" ;;
      *) p="${p:+$p/}$rest"; rest="" ;;
    esac
    if [ -L "$root/$p" ]; then return 0; fi
  done
  return 1
}

# target_blocked REL: true (with the reason in SF_WHY) when REL cannot be written as a
# regular file in the target without removing a directory or writing through a symlink.
SF_WHY=""
target_blocked() {
  local rest="$1" p=""
  SF_WHY=""
  while :; do
    case "$rest" in
      */*) p="${p:+$p/}${rest%%/*}"; rest="${rest#*/}" ;;
      *) break ;;
    esac
    if [ -L "$target/$p" ]; then
      SF_WHY="$p is a symlink (install never writes through one)"; return 0
    fi
    if [ -e "$target/$p" ] && [ ! -d "$target/$p" ]; then
      SF_WHY="$p is in the way: it is not a directory"; return 0
    fi
  done
  if [ ! -L "$target/$1" ] && [ -e "$target/$1" ] && [ ! -f "$target/$1" ]; then
    SF_WHY="$1 is in the way: it is not a regular file"; return 0
  fi
  return 1
}

# --- plan: read the source -------------------------------------------------------------
# C_REL[i] is a path relative to both roots; C_ACT[i] is create|overwrite|unchanged.
C_REL=()
C_ACT=()
missing=()
blocked=()
conflicts=()

# plan_copy REL: compare the source file with the target's and record the action.
plan_copy() {
  local rel="$1" dst="$target/$1" st=0
  if target_blocked "$rel"; then
    blocked+=("$SF_WHY")
    return 0
  fi
  if [ -L "$dst" ]; then
    conflicts+=("$rel"); C_REL+=("$rel"); C_ACT+=(overwrite)
  elif [ -f "$dst" ]; then
    cmp -s "$src/$rel" "$dst" || st=$?
    case "$st" in
      0) C_REL+=("$rel"); C_ACT+=(unchanged) ;;
      1) conflicts+=("$rel"); C_REL+=("$rel"); C_ACT+=(overwrite) ;;
      *) sf_die "could not compare $src/$rel with $dst" ;;
    esac
  else
    C_REL+=("$rel"); C_ACT+=(create)
  fi
}

# plan_dir ENTRY: plan every wanted regular file under the source directory ENTRY.
plan_dir() {
  local entry="$1" list f rel n=0
  if link_in_path "$src" "$entry"; then missing+=("$entry (a symlink)"); return 0; fi
  if [ ! -d "$src/$entry" ]; then missing+=("$entry"); return 0; fi
  # No trailing slash: BSD find would print "dir//file". A name holding a line break
  # is listed as "?", so its pieces can never pass for other paths.
  list=$(find "$src/${entry%/}" ! -type d \( -name "*$SF_NL*" -exec printf '%s\n' '?' \; -o -print \) |
    LC_ALL=C sort) || sf_die "could not list $src/$entry"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
      "$src"/*) ;;
      *) sf_die "factory source has a file name with a line break under $entry; rename it" ;;
    esac
    rel="${f#"$src"/}"
    if [ -L "$f" ]; then
      if want_file "$entry" "${rel#"$entry"}"; then
        sf_warn "skipping $rel in the factory source: symlinks are never copied"
      fi
    elif [ -f "$f" ]; then
      want_file "$entry" "${rel#"$entry"}" || continue
      n=$((n + 1))
      plan_copy "$rel"
    elif [ -e "$f" ]; then
      sf_warn "skipping $rel in the factory source: not a regular file"
    else
      sf_die "factory source changed while it was being read: $rel is gone"
    fi
  done <<EOF
$list
EOF
  if [ "$n" -eq 0 ]; then missing+=("$entry (no files)"); fi
}

for entry in "${SF_MANIFEST[@]}"; do
  case "$entry" in
    */) plan_dir "$entry" ;;
    *)
      if link_in_path "$src" "$entry"; then
        missing+=("$entry (a symlink)")
      elif [ ! -f "$src/$entry" ]; then
        missing+=("$entry")
      else
        plan_copy "$entry"
      fi ;;
  esac
done
if link_in_path "$src" "$SF_CONFIG_TEMPLATE"; then
  missing+=("$SF_CONFIG_TEMPLATE (a symlink)")
elif [ ! -f "$src/$SF_CONFIG_TEMPLATE" ]; then
  missing+=("$SF_CONFIG_TEMPLATE")
fi

if [ "${#missing[@]}" -gt 0 ]; then
  names=""
  for m in "${missing[@]}"; do names="${names:+$names, }$m"; done
  sf_die "factory source incomplete: $src lacks $names. Nothing was written."
fi

# --- plan: files created only if missing, and .gitignore ------------------------------
exists() { [ -e "$1" ] || [ -L "$1" ]; }

make_config=0
if ! exists "$target/$SF_CONFIG"; then make_config=1; fi

# A directory (or other non-file) where the config or the map goes is in the way:
# keeping it would leave the factory without either, and --commit would add its contents.
for keep in "$SF_CONFIG" "$SF_MAP"; do
  if [ ! -L "$target/$keep" ] && [ -e "$target/$keep" ] && [ ! -f "$target/$keep" ]; then
    blocked+=("$keep is in the way: it is not a regular file")
  fi
done

# factory/ itself was vetted by plan_copy for factory/feature-map.schema.json.
make_map=0
map_json=""
if ! exists "$target/$SF_MAP"; then
  make_map=1
  sf_need jq
  map_json=$(sf_jq -n --indent 2 '{"version": 1, "features": []}') ||
    sf_die "jq could not write the empty feature map"
fi

# plan_append REL LINES: plan adding to the target's REL each of LINES (one per line) that
# it lacks. Sets AP_ACTION (create: no such file; append; unchanged), AP_ADD (the lines to
# add) and AP_NEWLINE (1 when the file's last line has no "\n" yet). A line is present when
# a line of the file equals it, a trailing "\r" aside, and on the first line a UTF-8 byte
# order mark aside (git skips one there in both files).
AP_ACTION=""
AP_ADD=""
AP_NEWLINE=0
plan_append() {
  local rel="$1" f="$target/$1"
  AP_ACTION=unchanged
  AP_ADD=""
  AP_NEWLINE=0
  if [ -L "$f" ]; then
    blocked+=("$rel is a symlink (install never writes through one)")
  elif ! exists "$f"; then
    AP_ACTION=create
    AP_ADD="$2"
  elif [ ! -f "$f" ]; then
    blocked+=("$rel is in the way: it is not a regular file")
  else
    AP_ADD=$(SF_WANT="$2" awk -v bom="$(printf '\357\273\277')" '
      BEGIN { n = split(ENVIRON["SF_WANT"], want, "\n") }
      NR == 1 && index($0, bom) == 1 { $0 = substr($0, length(bom) + 1) }
      { sub(/\r$/, ""); have[$0] = 1 }
      END { for (i = 1; i <= n; i++) if (want[i] != "" && !(want[i] in have)) print want[i] }' "$f") ||
      sf_die "could not read $f"
    if [ -n "$AP_ADD" ]; then
      AP_ACTION=append
      # Appending to a last line without "\n" would rewrite the operator's last rule.
      if [ -n "$(tail -c 1 "$f")" ]; then AP_NEWLINE=1; fi
    fi
  fi
}

plan_append "$SF_IGNORE" "$SF_IGNORE_LINES"
ignore_action="$AP_ACTION" ignore_add="$AP_ADD" ignore_newline="$AP_NEWLINE"
plan_append "$SF_ATTR" "$SF_ATTR_LINES"
attr_action="$AP_ACTION" attr_add="$AP_ADD" attr_newline="$AP_NEWLINE"

if [ "${#blocked[@]}" -gt 0 ]; then
  for b in "${blocked[@]}"; do sf_log "cannot install: $b"; done
  sf_die "${#blocked[@]} path(s) in $target are in the way (listed above); move them aside and run again. Nothing was written."
fi

# --- plan: --commit preconditions ------------------------------------------------------
# Every path the install covers, written now or by an earlier run.
all_paths=(${C_REL[@]+"${C_REL[@]}"} "$SF_CONFIG" "$SF_MAP" "$SF_IGNORE" "$SF_ATTR")

# Untracked paths that an ignore rule (.gitignore, info/exclude, the global excludes
# file) covers: git add refuses them, which --commit would find out only after writing.
ignored=""
ign_st=0
ignored=$(git -C "$target" -c core.quotepath=off check-ignore -- "${all_paths[@]}") ||
  ign_st=$?
case "$ign_st" in
  0 | 1) ;;
  *)
    # For example a factory path inside a submodule: git add would fail the same way.
    [ "$commit" = 0 ] || sf_die "could not read the ignore rules of $target, so --commit would fail after writing (git's message is above). Nothing was written."
    sf_warn "could not read the ignore rules of $target (git's message is above); the files are installed but git may refuse to add some"
    ignored="" ;;
esac

if [ "$commit" = 1 ]; then
  # The commit must be an ordinary one-parent commit, made with an identity git accepts.
  state=$(git -C "$target" rev-parse --git-path MERGE_HEAD --git-path CHERRY_PICK_HEAD \
    --git-path REVERT_HEAD --git-path rebase-merge --git-path rebase-apply) ||
    sf_die "could not read the git state of $target"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in /* | [A-Za-z]:*) ;; *) p="$target/$p" ;; esac
    if [ -e "$p" ]; then
      sf_die "a merge, cherry-pick, revert or rebase is in progress in $target (${p##*/}); finish or abort it first. Nothing was written."
    fi
  done <<EOF
$state
EOF
  if ! git -C "$target" var GIT_AUTHOR_IDENT >/dev/null 2>&1 ||
    ! git -C "$target" var GIT_COMMITTER_IDENT >/dev/null 2>&1; then
    sf_die "git has no usable author or committer identity in $target; set user.name and user.email. Nothing was written."
  fi
  if [ -n "$ignored" ]; then
    printf '%s\n' "$ignored" | while IFS= read -r p; do sf_log "ignored by git: $p"; done
    sf_die "$target ignores factory files (listed above), so git add would refuse them; un-ignore them or track them with git add -f first. Nothing was written."
  fi
  # The install commit must hold only the factory: refuse to sweep in other staged work.
  # --ignore-submodules=none: the repo's diff.ignoreSubmodules must not hide a gitlink.
  staged=$(git -C "$target" -c core.quotepath=off diff --cached --no-renames \
    --ignore-submodules=none --name-only) ||
    sf_die "could not read the index of $target"
  outside=$(printf '%s\n' "$staged" | SF_SET="$(printf '%s\n' "${all_paths[@]}")" awk '
    BEGIN { n = split(ENVIRON["SF_SET"], a, "\n"); for (i = 1; i <= n; i++) set[a[i]] = 1 }
    $0 != "" && !($0 in set)')
  if [ -n "$outside" ]; then
    printf '%s\n' "$outside" | while IFS= read -r p; do sf_log "staged outside the factory files: $p"; done
    sf_die "$target has staged changes outside the factory files (listed above); commit or unstage them first. Nothing was written."
  fi
fi

if [ "${#conflicts[@]}" -gt 0 ] && [ "$force" = 0 ]; then
  printf '%s\n' "${conflicts[@]}"
  sf_log "${#conflicts[@]} file(s) in $target differ from the factory's copy (listed on stdout). Nothing was written."
  sf_log "re-run with --force to overwrite them (factory.config.yaml and $SF_MAP are never overwritten)"
  exit 1
fi

if [ -n "$ignored" ]; then
  printf '%s\n' "$ignored" | while IFS= read -r p; do
    sf_warn "$p is ignored by git in $target, so git add will not pick it up"
  done
fi

# --- write ---------------------------------------------------------------------------
created=0
overwritten=0
updated=0
unchanged=0
scripts_written=()

write_failed() {
  sf_die "could not write $1 in $target; fix the cause and run install.sh again (it finishes what is left)"
}

# Directories first, in one call (no symlinks on the way: target_blocked checked that).
dirs=()
for i in "${!C_REL[@]}"; do
  case "${C_ACT[$i]}" in
    create | overwrite)
      case "${C_REL[$i]}" in */*) dirs+=("$target/${C_REL[$i]%/*}") ;; esac ;;
  esac
done
if [ "$make_map" = 1 ]; then dirs+=("$target/${SF_MAP%/*}"); fi
if [ "${#dirs[@]}" -gt 0 ]; then
  mkdir -p -- "${dirs[@]}" || write_failed "the directories"
fi

# New files are copied one cp per directory: process start-up is slow on Windows.
batch=()
batch_rel=()
batch_dir=""
flush_batch() {
  local r
  [ "${#batch[@]}" -gt 0 ] || return 0
  cp -- "${batch[@]}" "$target/$batch_dir/" || write_failed "$batch_dir/"
  for r in "${batch_rel[@]}"; do printf '%s\n' "$r"; done
  batch=()
  batch_rel=()
}
note_written() {
  case "$1" in scripts/*.sh) scripts_written+=("$target/$1") ;; esac
}

for i in "${!C_REL[@]}"; do
  rel="${C_REL[$i]}"
  case "${C_ACT[$i]}" in
    unchanged) unchanged=$((unchanged + 1)) ;;
    create)
      case "$rel" in */*) dir="${rel%/*}" ;; *) dir="." ;; esac
      if [ "$dir" != "$batch_dir" ]; then flush_batch; batch_dir="$dir"; fi
      batch+=("$src/$rel")
      batch_rel+=("$rel")
      note_written "$rel"
      created=$((created + 1)) ;;
    overwrite)
      flush_batch
      if [ -L "$target/$rel" ]; then rm -f -- "$target/$rel" || write_failed "$rel"; fi
      cp -f -- "$src/$rel" "$target/$rel" || write_failed "$rel"
      printf '%s\n' "$rel"
      note_written "$rel"
      overwritten=$((overwritten + 1)) ;;
  esac
done
flush_batch

if [ "$make_config" = 1 ]; then
  cp -- "$src/$SF_CONFIG_TEMPLATE" "$target/$SF_CONFIG" || write_failed "$SF_CONFIG"
  printf '%s\n' "$SF_CONFIG"
  created=$((created + 1))
else
  unchanged=$((unchanged + 1))
fi

if [ "$make_map" = 1 ]; then
  printf '%s\n' "$map_json" >"$target/$SF_MAP" || write_failed "$SF_MAP"
  printf '%s\n' "$SF_MAP"
  created=$((created + 1))
else
  unchanged=$((unchanged + 1))
fi

# write_append REL ACTION LINES NEWLINE: carry out what plan_append planned for REL.
write_append() {
  case "$2" in
    create)
      printf '%s\n' "$3" >"$target/$1" || write_failed "$1"
      printf '%s\n' "$1"
      created=$((created + 1)) ;;
    append)
      if [ "$4" = 1 ]; then
        printf '\n%s\n' "$3" >>"$target/$1" || write_failed "$1"
      else
        printf '%s\n' "$3" >>"$target/$1" || write_failed "$1"
      fi
      printf '%s\n' "$1"
      updated=$((updated + 1)) ;;
    *) unchanged=$((unchanged + 1)) ;;
  esac
}
write_append "$SF_IGNORE" "$ignore_action" "$ignore_add" "$ignore_newline"
write_append "$SF_ATTR" "$attr_action" "$attr_add" "$attr_newline"

# Keep the work tree's mode in line with the +x that --commit records.
if [ "${#scripts_written[@]}" -gt 0 ]; then
  chmod +x -- "${scripts_written[@]}" 2>/dev/null || sf_warn "could not mark the installed scripts executable"
fi

sf_log "$created created, $overwritten overwritten, $updated updated, $unchanged unchanged in $target"

[ "$commit" = 1 ] || exit 0

# --- commit (the operator's own commit: their identity, hooks and signing apply) -------
# -f: git add fails on a TRACKED file inside an ignored directory (it reports the
# directory). Untracked ignored paths were refused above, so -f overrides no ignore rule.
git -C "$target" --literal-pathspecs add -f -- "${all_paths[@]}" ||
  sf_die "git add failed in $target; the files are installed but not committed"
# Executable in git: scripts/*.sh and scripts/lib/*.sh (a case pattern's * matches "/").
exec_paths=()
for p in "${all_paths[@]}"; do
  case "$p" in scripts/*.sh) exec_paths+=("$p") ;; esac
done
if [ "${#exec_paths[@]}" -gt 0 ]; then
  git -C "$target" --literal-pathspecs add -f --chmod=+x -- "${exec_paths[@]}" ||
    sf_die "git add --chmod=+x failed in $target; the files are installed but not committed"
fi
if git -C "$target" diff --cached --quiet; then
  sf_log "nothing to commit: the factory files in $target are already committed"
  exit 0
fi
git -C "$target" commit -q -m "$SF_COMMIT_SUBJECT" -m "$SF_COMMIT_TRAILER" ||
  sf_die "git commit failed in $target; the files are installed and staged. Fix the cause and run install.sh --commit again"
sha=$(git -C "$target" rev-parse --short HEAD 2>/dev/null) || sha="?"
sf_log "committed $sha: $SF_COMMIT_SUBJECT"
