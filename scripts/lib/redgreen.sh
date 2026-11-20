# shellcheck shell=bash
# Red/green check: a feature branch must open with a tests-only commit whose tests fail,
# and those same tests must pass at HEAD. Source this file; don't run it.
# Contract: docs/CONTRACTS.md, "lib/redgreen.sh". The caller loads config first.

if [ -n "${SF_REDGREEN_LOADED:-}" ]; then return 0; fi
SF_REDGREEN_LOADED=1

# Both have double-source guards, so this is a no-op when the caller already loaded them.
# shellcheck source=scripts/lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
# shellcheck source=scripts/lib/config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"

# Output at the red commit that means "the tests could not run", not "the tests failed".
SF_RG_INCONCLUSIVE_RE='Cannot find module|MODULE_NOT_FOUND|command not found|No such file or directory'
# The only file a commit before the red commit may touch.
SF_RG_MAP_PATH='factory/feature-map.json'

# redgreen_check TREE BASE HEAD: 0 pass, 1 fail, 3 inconclusive (2 = bad call or bad config).
# BASE must contain every base-branch commit merged into HEAD: pass the merge-base of HEAD
# and the base branch tip, not a stale fork point.
# Runs in a subshell so its traps, `set +e` and tool pins never leak into the caller.
redgreen_check() {
  # An empty TREE would be `git -C ""`, i.e. whatever repo the caller's cwd is in.
  if [ "$#" -ne 3 ] || [ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ]; then
    sf_log "red-green: usage: redgreen_check TREE BASE HEAD (none of them empty)"
    return 2
  fi
  (_rg_main "$1" "$2" "$3")
}

_rg_log() { sf_log "red-green: $*"; }

# _rg_tail FILE: the last 40 lines of a command's output, on stderr. Only a regular file:
# the code that wrote it may have swapped it for a FIFO, which would never end.
_rg_tail() {
  [ -f "$1" ] && [ -s "$1" ] || return 0
  tail -n 40 "$1" | sed 's/^/  | /' >&2
}

# _rg_short SHA: abbreviated sha for messages.
_rg_short() { printf '%s' "$1" | cut -c1-12; }

# _rg_shquote STRING: STRING as one bash word. File names come from the PR under
# test, so they are data: quote them before they are spliced into a command line.
_rg_shquote() {
  local q="'\\''"
  case "$1" in
    '') printf "''" ;;
    *[!A-Za-z0-9_./@%+=:,-]*) printf "'%s'" "${1//\'/$q}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# _rg_subst TEMPLATE VALUE: TEMPLATE with every "{files}" replaced by VALUE.
# Done by hand: ${var//pat/rep} treats "&" in rep specially on bash 5.2+.
_rg_subst() {
  local rest="$1" out=""
  while :; do
    case "$rest" in
      *"{files}"*)
        out="$out${rest%%"{files}"*}$2"
        rest="${rest#*"{files}"}"
        ;;
      *)
        printf '%s' "$out$rest"
        return 0
        ;;
    esac
  done
}

# _rg_pin TOOL...: look each TOOL up in PATH now, before any project code runs, and keep
# that path (bash's hash table) for the rest of this subshell: project code can put an
# executable of the same name in a PATH directory it can write to. A name the caller already
# pinned keeps the caller's path (looking it up again could find a planted one by now).
_rg_pin() {
  local t
  for t in "$@"; do
    hash -t "$t" >/dev/null 2>&1 || hash "$t" 2>/dev/null || {
      _rg_log "required command not found: $t"
      return 1
    }
  done
  return 0
}

# _rg_read_list FILE: load NUL-separated FILE into the array _RG_LIST.
_rg_read_list() {
  local f
  _RG_LIST=()
  while IFS= read -r -d '' f; do
    _RG_LIST+=("$f")
  done <"$1"
}

# _rg_in WORD LIST...: true if WORD is one of LIST.
_rg_in() {
  local x="$1" y
  shift
  for y in "$@"; do
    [ "$x" = "$y" ] && return 0
  done
  return 1
}

# _rg_nparents C: the number of parents of commit C, on stdout.
_rg_nparents() {
  local p
  p=$(git -C "$_RG_TREE" rev-list --parents -n 1 "$1") || return 1
  # shellcheck disable=SC2086 # split the sha list into words on purpose
  set -- $p
  printf '%s\n' "$(($# - 1))"
}

# _rg_auto_tree C: sets _RG_AUTO to the tree git's own automatic merge of C's two parents
# would produce (remembering the last answer: callers ask twice for the same merge).
# Needs git 2.38+ (merge-tree --write-tree). It exits 1 on conflicts but still prints the
# tree (with conflict markers) first, which is what a hand resolution is compared against.
_rg_auto_tree() {
  local out st=0
  if [ "${_RG_AUTO_OF:-}" = "$1" ]; then return 0; fi
  out=$(git -C "$_RG_TREE" merge-tree --write-tree --no-messages "$1^1" "$1^2" 2>"$_RG_WORK/merge-tree.err") || st=$?
  case "$st" in
    0 | 1)
      _RG_AUTO="${out%%$'\n'*}"
      _RG_AUTO_OF="$1"
      ;;
    *)
      _rg_log "INCONCLUSIVE: git merge-tree failed for merge $(_rg_short "$1") (git 2.38+ is needed for branches that contain merges)"
      _rg_tail "$_RG_WORK/merge-tree.err"
      return 1
      ;;
  esac
}

# _rg_changes C OUT FILTER [-- PATHSPEC...]: NUL-separated paths that commit C changed by
# hand, written to OUT (FILTER is a --diff-filter value or ""). An ordinary commit is
# compared with its parent (a root commit with nothing). A two-parent merge is compared with
# git's automatic merge of its parents, so only its hand edits and conflict resolutions
# count: a clean merge changes nothing (each side's own commits are judged on their own),
# a conflict resolved in the map is a map change, and an "evil merge" can't hide anything.
# Returns 1 (logged) when it can't tell, an octopus merge included.
_rg_changes() {
  local c="$1" out="$2" filter="$3" n
  local opts=(-r --no-commit-id --name-only -z)
  shift 3
  if [ -n "$filter" ]; then
    opts+=("--diff-filter=$filter")
  fi
  if ! n=$(_rg_nparents "$c"); then
    _rg_log "INCONCLUSIVE: cannot read the parents of $(_rg_short "$c")"
    return 1
  fi
  case "$n" in
    0) git -C "$_RG_TREE" diff-tree --root "${opts[@]}" "$c" ${1+"$@"} >"$out" ;;
    1) git -C "$_RG_TREE" diff-tree "${opts[@]}" "$c" ${1+"$@"} >"$out" ;;
    2)
      _rg_auto_tree "$c" || return 1
      git -C "$_RG_TREE" diff-tree "${opts[@]}" "$_RG_AUTO" "$c^{tree}" ${1+"$@"} >"$out"
      ;;
    *)
      _rg_log "INCONCLUSIVE: $(_rg_short "$c") is an octopus merge; its hand edits can't be told apart from what it merges (git merge-tree takes two parents)"
      return 1
      ;;
  esac || {
    _rg_log "INCONCLUSIVE: cannot list the files changed by $(_rg_short "$c")"
    return 1
  }
}

# _rg_branch_test_edits RED HEAD OUT PATHSPEC...: NUL-separated test files the branch itself
# changed after RED, written to OUT (may repeat a path). "The branch" is every commit in
# HEAD ^RED ^BASE on all parent lines, so a side branch merged in is covered too. An ordinary
# commit counts with all its test-file changes; a merge counts only where it differs from
# git's automatic merge of its parents (a hand edit, or a conflict resolution). Commits that
# came from the base branch are in BASE and don't count. Returns 3 (logged) if it can't tell.
_rg_branch_test_edits() {
  local red="$1" head="$2" out="$3" c
  shift 3
  : >"$out"
  if ! git -C "$_RG_TREE" rev-list "$head" "^$red" "^$_RG_BASE" >"$_RG_WORK/after"; then
    _rg_log "INCONCLUSIVE: cannot list the commits after the red commit $(_rg_short "$red")"
    return 3
  fi
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    _rg_changes "$c" "$_RG_WORK/edits.one" "" -- "$@" || return 3
    cat "$_RG_WORK/edits.one" >>"$out"
  done <"$_RG_WORK/after"
  return 0
}

# _rg_add_worktree SHA NAME: detached worktree at SHA in $_RG_WORK/NAME. Git only: no project
# code runs here. Returns non-zero (after logging why) when the tree can't be created.
_rg_add_worktree() {
  local sha="$1" name="$2" wt="$_RG_WORK/$2"
  # Register first: a half-created worktree must still be cleaned up.
  _RG_WTS+=("$wt")
  # core.autocrlf=false: run the bytes that were committed, whatever the machine's
  # global git config says (.gitattributes still applies). core.hooksPath=<empty dir>:
  # the repo's post-checkout hook (git-lfs, lefthook, ...) neither runs nor fails the add.
  if ! git -C "$_RG_TREE" -c core.autocrlf=false -c core.hooksPath="$_RG_WORK/nohooks" -c core.fsmonitor= \
    worktree add --detach "$wt" "$sha" >"$_RG_WORK/$name.worktree.log" 2>&1 || [ ! -d "$wt" ]; then
    _rg_log "INCONCLUSIVE: could not create a worktree at $(_rg_short "$sha")"
    _rg_tail "$_RG_WORK/$name.worktree.log"
    return 1
  fi
  return 0
}

# _rg_run SECS NAME LOG COMMAND: COMMAND (project code) with bash -c in the NAME worktree,
# stdin from /dev/null, output to LOG, bounded by SECS, without credential-like variables
# (env -u, which also removes names bash can't hold; env execs bash, so the timeout stops it).
_rg_run() {
  (cd "$_RG_WORK/$2" && sf_run_timeout "$1" env ${_RG_DROP[@]+"${_RG_DROP[@]}"} "$_RG_BASH" -c "$4") \
    </dev/null >"$3" 2>&1
}

# _rg_setup NAME LOG: project.setup in the NAME worktree, output to LOG. Returns non-zero
# (logged) on failure.
_rg_setup() {
  local st=0
  sf_is_none "$_RG_SETUP" && return 0
  _rg_run "$_RG_SETUP_SECS" "$1" "$2" "$_RG_SETUP" || st=$?
  if [ "$st" -ne 0 ]; then
    _rg_log "INCONCLUSIVE: project.setup exited $st in the $1 tree"
    _rg_tail "$2"
    return 1
  fi
  return 0
}

# _rg_exec NAME OUT: run the test command in the NAME worktree; output to OUT.
_rg_exec() {
  _rg_run "$_RG_SECS" "$1" "$2" "$_RG_CMD"
}

# _rg_fingerprint DIR: every entry under DIR, with a checksum of each regular file, the
# executable ones and where each symlink points, sorted. Kept in memory, not on disk, so the
# code that runs between two fingerprints can't edit the first one. Tools by their pinned
# paths (find runs cksum and ls itself, through PATH otherwise).
_rg_fingerprint() {
  (
    cd "$1" || exit 1
    find . ! -type f -print
    find . -type f -exec "$_RG_CKSUM" {} +
    find . -type f -perm -u+x -print | sed 's/^/x /'
    find . -type l -exec "$_RG_LS" -ld {} +
  ) 2>&1 | LC_ALL=C sort
}

_rg_cleanup() {
  local wt
  # Bookkeeping git after project code ran: no hooks, no fsmonitor (that code can write the
  # shared config), no credentials, and git by its pinned path.
  for wt in ${_RG_WTS[@]+"${_RG_WTS[@]}"}; do
    env ${_RG_DROP[@]+"${_RG_DROP[@]}"} "${_RG_GIT:-git}" -c core.hooksPath=/dev/null -c core.fsmonitor= \
      -C "$_RG_TREE" worktree remove --force "$wt" >/dev/null 2>&1 || true
  done
  if [ -n "${_RG_WORK:-}" ]; then
    rm -rf "$_RG_WORK" 2>/dev/null || true
  fi
  env ${_RG_DROP[@]+"${_RG_DROP[@]}"} "${_RG_GIT:-git}" -c core.hooksPath=/dev/null -c core.fsmonitor= \
    -C "$_RG_TREE" worktree prune >/dev/null 2>&1 || true
  return 0
}

_rg_main() {
  local base head c f red="" short st=0 secs n missing="" green_print glogs
  local globs=() specs=() ispecs=() all=() tests=() runfiles=() edited=() restore=() removed=() repair=()
  local joined="" test_files test_cmd
  # Every failure below is handled explicitly; an inherited `set -e` would turn an
  # unexpected non-zero into a misleading "1 = fail".
  set +e
  # TREE is explicit. git's repo-locating variables (git exports them to hooks, so a
  # gate run from a hook inherits them) would send these commands, and the tests run in
  # the worktrees, to another repo or index. This subshell only.
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
    GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_PREFIX
  _RG_TREE="$1"
  _RG_WORK=""
  _RG_WTS=()
  _RG_LIST=()
  _RG_DROP=()
  _RG_GIT=""
  _RG_AUTO=""
  _RG_AUTO_OF=""
  trap '_rg_cleanup' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  # The tools this subshell runs once project code has run (in red's or green's worktree),
  # pinned now. Missing ones are a bad environment, not a verdict.
  _rg_pin git env find cksum ls sort sed grep tail cut cat rm mkdir mktemp sleep || return 2
  _RG_GIT=$(hash -t git)
  _RG_CKSUM=$(hash -t cksum)
  _RG_LS=$(hash -t ls)
  # The running bash, by its path: env (not this shell) starts it, through a PATH lookup of
  # its own otherwise.
  _RG_BASH="${BASH:-bash}"
  # Credential-like variables never reach project code (sf_credential_names: names bash
  # can't unset included; env -u removes them).
  while IFS= read -r f; do
    [ -n "$f" ] && _RG_DROP+=(-u "$f")
  done <<EOF
$(sf_credential_names)
EOF

  if ! git -C "$_RG_TREE" rev-parse --git-dir >/dev/null 2>&1; then
    _rg_log "INCONCLUSIVE: not a git tree: $_RG_TREE"
    return 3
  fi
  if ! base=$(git -C "$_RG_TREE" rev-parse --verify -q "$2^{commit}"); then
    _rg_log "INCONCLUSIVE: cannot resolve base '$2'"
    return 3
  fi
  if ! head=$(git -C "$_RG_TREE" rev-parse --verify -q "$3^{commit}"); then
    _rg_log "INCONCLUSIVE: cannot resolve head '$3'"
    return 3
  fi
  _RG_BASE="$base"

  # Config (normally loaded by the caller). Touch it once outside $(...) so a missing or
  # invalid config ends this subshell with sf_die's 2 instead of reading as empty values.
  sf_cfg_has gate.test || :
  # Defaults keep a sparse config usable. The globs are gate.test_globs' list items, or its
  # value when it is one scalar glob; none or a missing key gives none (a 2 below).
  while IFS= read -r f; do
    [ -n "$f" ] && globs+=("$f")
  done <<EOF
$(sf_cfg_globs gate.test_globs)
EOF
  test_files=$(sf_cfg gate.test_files none)
  test_cmd=$(sf_cfg gate.test none)
  _RG_SETUP=$(sf_cfg project.setup none)
  secs=$(sf_cfg limits.repro_timeout_seconds 120)
  n=$(sf_cfg limits.agent_timeout_minutes 45)
  # At most 8 digits (no overflow), read as decimal: "08" would be an octal error in $((...)).
  case "$secs" in '' | *[!0-9]* | ?????????*) secs=bad ;; *) secs=$((10#$secs)) ;; esac
  case "$n" in '' | *[!0-9]* | ?????????*) n=bad ;; *) n=$((10#$n)) ;; esac
  case "$secs" in bad | 0) _rg_log "invalid limits.repro_timeout_seconds: '$(sf_cfg limits.repro_timeout_seconds 120)'"; return 2 ;; esac
  case "$n" in bad | 0) _rg_log "invalid limits.agent_timeout_minutes: '$(sf_cfg limits.agent_timeout_minutes 45)'"; return 2 ;; esac
  _RG_SECS="$secs"
  _RG_SETUP_SECS=$((n * 60))

  # ispecs match case-insensitively: on NTFS or APFS a later "Calc_TEST.sh" overwrites a red
  # "calc_test.sh" at checkout, so a case alias must count as an edit of a test file.
  for f in ${globs[@]+"${globs[@]}"}; do
    case "$f" in
      :*) specs+=("$f"); ispecs+=("$f") ;;  # already carries pathspec magic
      *) specs+=(":(glob)$f"); ispecs+=(":(glob,icase)$f") ;;
    esac
  done
  # Without globs no commit can be the tests-only one; that is a config problem, not a "no".
  if [ "${#specs[@]}" -eq 0 ]; then
    _rg_log "gate.test_globs is empty or none, so the tests-only commit cannot be found; set it in the config"
    return 2
  fi

  # Absolute TMPDIR for everything below (this subshell only): `git -C TREE worktree add`
  # would read a relative path against TREE, and sf_run_timeout against the worktree.
  if ! TMPDIR=$(CDPATH='' cd -- "${TMPDIR:-/tmp}" 2>/dev/null && pwd); then
    _rg_log "INCONCLUSIVE: TMPDIR is not a usable directory"
    return 3
  fi
  export TMPDIR

  if ! _RG_WORK=$(sf_mktemp_dir); then
    _RG_WORK=""
    _rg_log "INCONCLUSIVE: cannot create a temporary directory"
    return 3
  fi
  mkdir -p "$_RG_WORK/nohooks"

  # 1. Find the red commit: the first commit in BASE..HEAD that touches a test file.
  # Topological order (parents first), not commit dates, which the branch controls. Every
  # merge counts only by its hand edits (_rg_changes), so a clean merge of the base branch
  # is part of the base, and a conflict it resolved in the map is a map change.
  if ! git -C "$_RG_TREE" rev-list --reverse --topo-order "$base..$head" >"$_RG_WORK/commits"; then
    _rg_log "INCONCLUSIVE: git rev-list $(_rg_short "$base")..$(_rg_short "$head") failed"
    return 3
  fi
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    short=$(_rg_short "$c")
    _rg_changes "$c" "$_RG_WORK/all" "" || return 3
    _rg_read_list "$_RG_WORK/all"
    all=(${_RG_LIST[@]+"${_RG_LIST[@]}"})
    # Nothing by hand (a clean merge, an empty commit): nothing to judge.
    [ "${#all[@]}" -gt 0 ] || continue
    _rg_changes "$c" "$_RG_WORK/tests" "" -- "${specs[@]}" || return 3
    _rg_read_list "$_RG_WORK/tests"
    tests=(${_RG_LIST[@]+"${_RG_LIST[@]}"})
    if [ "${#tests[@]}" -eq 0 ]; then
      for f in "${all[@]}"; do
        if [ "$f" != "$SF_RG_MAP_PATH" ]; then
          _rg_log "FAIL: commit $short changes '$f' before the tests-only commit (only $SF_RG_MAP_PATH may change before it)"
          return 1
        fi
      done
      continue
    fi
    for f in "${all[@]}"; do
      if ! _rg_in "$f" "${tests[@]}"; then
        _rg_log "FAIL: the red commit $short must change only test files (gate.test_globs), but it changes '$f'"
        return 1
      fi
    done
    red="$c"
    break
  done <"$_RG_WORK/commits"

  if [ -z "$red" ]; then
    _rg_log "FAIL: no tests-only commit in $(_rg_short "$base")..$(_rg_short "$head"); a feature branch must first commit failing tests (files matching gate.test_globs)"
    return 1
  fi
  short=$(_rg_short "$red")
  if [ "$red" = "$head" ]; then
    _rg_log "FAIL: the red commit $short is HEAD; no commit makes its tests pass"
    return 1
  fi
  # Order alone can be gamed (a merge can put an older line of work behind red), so check the
  # set: every commit under red that is not in BASE may touch only the map, merges by their
  # hand edits.
  if ! git -C "$_RG_TREE" rev-list "$red^@" "^$base" >"$_RG_WORK/before"; then
    _rg_log "INCONCLUSIVE: cannot list the commits under the red commit $short"
    return 3
  fi
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    _rg_changes "$c" "$_RG_WORK/all" "" || return 3
    _rg_read_list "$_RG_WORK/all"
    for f in ${_RG_LIST[@]+"${_RG_LIST[@]}"}; do
      if [ "$f" != "$SF_RG_MAP_PATH" ]; then
        _rg_log "FAIL: commit $(_rg_short "$c") under the tests-only commit $short changes '$f' (only $SF_RG_MAP_PATH may change before it)"
        return 1
      fi
    done
  done <"$_RG_WORK/before"

  # The red commit's test files that exist after it (a deleted file can't be run).
  _rg_changes "$red" "$_RG_WORK/run" "d" -- "${specs[@]}" || return 3
  _rg_read_list "$_RG_WORK/run"
  runfiles=(${_RG_LIST[@]+"${_RG_LIST[@]}"})
  if [ "${#runfiles[@]}" -eq 0 ]; then
    _rg_log "FAIL: the red commit $short adds or changes no test file it could run (it only deletes tests)"
    return 1
  fi

  if ! sf_is_none "$test_files"; then
    for f in "${runfiles[@]}"; do
      joined="$joined${joined:+ }$(_rg_shquote "$f")"
    done
    _RG_CMD=$(_rg_subst "$test_files" "$joined")
  elif ! sf_is_none "$test_cmd"; then
    _RG_CMD="$test_cmd"
  else
    _rg_log "INCONCLUSIVE: gate.test_files and gate.test are both none; nothing can run the tests"
    return 3
  fi

  # 2. The test files the branch itself changed after red. Green undoes those edits, so a
  # later commit can't rescue a wrong implementation by weakening a red test, a helper it
  # sources, or by adding a setup file that neuters it. (HEAD's own tests, edits included,
  # still run in the gate's test step.)
  st=0
  _rg_branch_test_edits "$red" "$head" "$_RG_WORK/edited" ${ispecs[@]+"${ispecs[@]}"} || st=$?
  [ "$st" -eq 0 ] || return "$st"
  _rg_read_list "$_RG_WORK/edited"
  for f in ${_RG_LIST[@]+"${_RG_LIST[@]}"}; do
    _rg_in "$f" ${edited[@]+"${edited[@]}"} || edited+=("$f")
  done

  # Both worktrees, green with the undo applied, are written now, before any project code
  # runs: that code (red's setup and tests) could rewrite the objects, refs or config in the
  # shared .git, and a checkout made after it would write whatever it put there.
  _rg_add_worktree "$red" red || return 3
  _rg_add_worktree "$head" green || return 3
  # Green: the branch's own later test edits undone. Files it added are removed, files it
  # changed or deleted are put back as they were at red. Removals come first, then a fresh
  # checkout of the red files: on a case-insensitive filesystem a removed case alias can
  # take a red file with it.
  if [ "${#edited[@]}" -gt 0 ]; then
    _rg_log "note: the branch changed test files after the red commit $short; green undoes that: ${edited[*]}"
    for f in "${edited[@]}"; do
      if git -C "$_RG_TREE" cat-file -e "$red:$f" 2>/dev/null; then
        restore+=(":(literal)$f")
      else
        removed+=(":(literal)$f")
        rm -f -- "$_RG_WORK/green/$f"
      fi
    done
    # Repair any unedited red file that a removed case alias took with it (one file on disk):
    # write it again from HEAD, where the branch did not change it.
    if [ "${#removed[@]}" -gt 0 ]; then
      repair=()
      for f in "${runfiles[@]}"; do
        _rg_in ":(literal)$f" ${restore[@]+"${restore[@]}"} || repair+=(":(literal)$f")
      done
      if [ "${#repair[@]}" -gt 0 ] &&
        ! git -C "$_RG_WORK/green" -c core.autocrlf=false -c core.hooksPath="$_RG_WORK/nohooks" -c core.fsmonitor= \
          checkout -q HEAD -- "${repair[@]}" >"$_RG_WORK/green.repair.log" 2>&1; then
        _rg_log "INCONCLUSIVE: could not write the red commit's test files again after removing later ones"
        _rg_tail "$_RG_WORK/green.repair.log"
        return 3
      fi
    fi
    if [ "${#restore[@]}" -gt 0 ] &&
      ! git -C "$_RG_WORK/green" -c core.autocrlf=false -c core.hooksPath="$_RG_WORK/nohooks" -c core.fsmonitor= \
        checkout -q "$red" -- "${restore[@]}" >"$_RG_WORK/green.restore.log" 2>&1; then
      _rg_log "INCONCLUSIVE: could not put the red commit's test files back in the HEAD tree"
      _rg_tail "$_RG_WORK/green.restore.log"
      return 3
    fi
  fi
  # A red test file missing now was removed or renamed by the base branch, not by the branch.
  # Noted now, reported after red's verdict.
  for f in "${runfiles[@]}"; do
    if [ ! -e "$_RG_WORK/green/$f" ]; then
      missing="$f"
      break
    fi
  done
  # Red's code runs while green's tree already exists, and could edit it (it is a sibling
  # directory): remember exactly what is there. This covers green's own tree only. Config a
  # runner finds in parent directories or HOME, processes red's code leaves running, and a
  # file forged to keep its cksum (a CRC) are not: real isolation is the workflows' job.
  green_print=$(_rg_fingerprint "$_RG_WORK/green")

  # 3. Red: the tests must fail at the red commit, for a reason other than "can't run".
  # From here on project code runs; nothing below reads git.
  _rg_setup red "$_RG_WORK/red.setup.log" || return 3
  st=0
  _rg_exec red "$_RG_WORK/red.out" || st=$?
  if [ "$(_rg_fingerprint "$_RG_WORK/green")" != "$green_print" ]; then
    _rg_log "FAIL: the run at the red commit $short changed files in the green (HEAD) tree; the tests must not touch other trees"
    return 1
  fi
  if [ ! -f "$_RG_WORK/red.out" ]; then
    _rg_log "INCONCLUSIVE: the output of the run at the red commit $short is no longer a regular file"
    return 3
  fi
  if [ "$st" -eq 0 ]; then
    _rg_log "FAIL: tests passed before the code existed (red commit $short, command: $_RG_CMD)"
    _rg_tail "$_RG_WORK/red.out"
    return 1
  fi
  if [ "$st" -eq 126 ] || [ "$st" -eq 127 ]; then
    _rg_log "INCONCLUSIVE: the tests could not run at the red commit $short (exit $st, command: $_RG_CMD)"
    _rg_tail "$_RG_WORK/red.out"
    return 3
  fi
  # A hang (watch mode, a missing server) is not an assertion failure.
  if [ "$st" -eq 124 ]; then
    _rg_log "INCONCLUSIVE: the tests timed out at the red commit $short after ${_RG_SECS}s (command: $_RG_CMD)"
    _rg_tail "$_RG_WORK/red.out"
    return 3
  fi
  if grep -Eq "$SF_RG_INCONCLUSIVE_RE" "$_RG_WORK/red.out"; then
    _rg_log "INCONCLUSIVE: the red commit $short failed for a missing module, command or file, not an assertion (exit $st)"
    _rg_tail "$_RG_WORK/red.out"
    return 3
  fi
  _rg_log "red confirmed at $short (exit $st)"

  # 4. Green: the same files must pass at HEAD, with the branch's own later test edits undone.
  if [ -n "$missing" ]; then
    _rg_log "INCONCLUSIVE: the red commit's test file '$missing' no longer exists at HEAD (the base branch removed or renamed it); rebuild the branch on the current base"
    return 3
  fi
  # Green's output goes to a directory made now, after red's code ran, under a name that code
  # could not know. At a fixed path, red's code could have left a hard link (or a symlink) to
  # a file in green's tree there, say green's test runner: green's own redirect would then
  # truncate that file after the fingerprint was compared.
  if ! glogs=$(mktemp -d "$_RG_WORK/green-logs.XXXXXX"); then
    _rg_log "INCONCLUSIVE: cannot create a directory for the output of the green run"
    return 3
  fi
  _rg_setup green "$glogs/setup.log" || return 3
  st=0
  _rg_exec green "$glogs/out" || st=$?
  if [ "$st" -ne 0 ]; then
    if [ "$st" -eq 124 ]; then
      _rg_log "FAIL: the red commit's tests timed out at HEAD $(_rg_short "$head") after ${_RG_SECS}s"
    else
      _rg_log "FAIL: the red commit's tests fail at HEAD $(_rg_short "$head") (exit $st, command: $_RG_CMD)"
    fi
    _rg_tail "$glogs/out"
    return 1
  fi
  _rg_log "green confirmed at HEAD $(_rg_short "$head")"
  return 0
}
