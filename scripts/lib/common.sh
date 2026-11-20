# shellcheck shell=bash
# Shared helpers for software-factory scripts. Source this file; don't run it.
# Works with bash 3.2+ (stock macOS), Git Bash on Windows and Linux.
# Contract: docs/CONTRACTS.md, section "Shared library".

if [ -n "${SF_COMMON_LOADED:-}" ]; then return 0; fi
SF_COMMON_LOADED=1

# Exit codes shared by every script (docs/CONTRACTS.md); used by the scripts that source this.
# shellcheck disable=SC2034
SF_OK=0
# shellcheck disable=SC2034
SF_FAIL=1
SF_USAGE=2

# Environment a caller (or a git hook) can leak into us that would silently change
# what the scripts check:
# - CDPATH can send `cd relative/dir` somewhere else and makes cd print the path.
# - GIT_*_PATHSPECS turn the :(glob) magic off or make it case-insensitive.
# - GIT_DIR and friends (exported to hooks) override every `git -C <tree>`.
unset CDPATH GIT_LITERAL_PATHSPECS GIT_GLOB_PATHSPECS GIT_NOGLOB_PATHSPECS GIT_ICASE_PATHSPECS
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX GIT_NAMESPACE
unset GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
# - Config injected through the environment (git exports GIT_CONFIG_PARAMETERS to hooks and
#   aliases; GIT_CONFIG_COUNT/KEY_n/VALUE_n can set anything, core.hooksPath included).
unset GIT_CONFIG_PARAMETERS
for _sf_v in $(compgen -e); do
  case "$_sf_v" in GIT_CONFIG_COUNT | GIT_CONFIG_KEY_* | GIT_CONFIG_VALUE_*) unset "$_sf_v" ;; esac
done
unset _sf_v
# History exactly as committed: project code that runs before a check reads history could
# plant a replace ref or a graft and make one commit look like another. The graft file is
# /dev/null (nul on Git for Windows) because a real path would be visible, and writable, to
# that same code. Reading it makes git print a deprecation advice, which is turned off.
export GIT_NO_REPLACE_OBJECTS=1 GIT_GRAFT_FILE=/dev/null
# core.commitGraph=false: a commit-graph file is a cache the same code could forge, and git
# would believe its root trees over the commit objects.
export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=advice.graftFileDeprecated GIT_CONFIG_VALUE_0=false
export GIT_CONFIG_KEY_1=core.commitGraph GIT_CONFIG_VALUE_1=false
# - A relative PATH entry (or an empty one, meaning ".") resolves against whatever tree a
#   script has cd'ed into, so a judged tree could supply its own git or jq. Keep only
#   absolute entries (globbing off while splitting, restored after).
case $- in *f*) _sf_glob_was_off=1 ;; *) _sf_glob_was_off=0; set -f ;; esac
_sf_path=""
_sf_ifs=$IFS
IFS=:
for _sf_p in $PATH; do
  case "$_sf_p" in /*) _sf_path="${_sf_path:+$_sf_path:}$_sf_p" ;; esac
done
IFS=$_sf_ifs
[ "$_sf_glob_was_off" = 1 ] || set +f
PATH=$_sf_path
export PATH
unset _sf_path _sf_ifs _sf_p _sf_glob_was_off
# Never wait for a credential prompt: every script must be able to run unattended.
export GIT_TERMINAL_PROMPT="${GIT_TERMINAL_PROMPT:-0}"
export GCM_INTERACTIVE="${GCM_INTERACTIVE:-never}"
# A relative TMPDIR would resolve against whatever directory a script later cd's into, so
# temp files (sf_run_timeout's marker among them) would land in the tree under test, or fail.
case "${TMPDIR:-}" in
  '' | /*) ;;
  *)
    TMPDIR=$(cd -- "$TMPDIR" 2>/dev/null && pwd) || TMPDIR=/tmp
    export TMPDIR
    ;;
esac

# Directory holding the scripts that are running: the *judging* copy of the factory.
SF_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SF_SCRIPTS_DIR="$(cd "$SF_LIB_DIR/.." && pwd)"
SF_FACTORY_ROOT="${FACTORY_ROOT:-$SF_SCRIPTS_DIR/..}"
# Absolute, so scripts that cd into a tree still find the judging copy's config.
SF_FACTORY_ROOT="$(cd "$SF_FACTORY_ROOT" && pwd)" || {
  printf 'factory: error: FACTORY_ROOT is not a directory: %s\n' "${FACTORY_ROOT:-}" >&2
  exit 2
}
export SF_FACTORY_ROOT

# Git Bash (MSYS) rewrites "/"-looking text in arguments and environment values passed
# to native Windows programs (jq.exe, gh.exe). SF_MSYS=1 there; helpers below use it.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*) SF_MSYS=1 ;;
  *) SF_MSYS=0 ;;
esac
if [ "$SF_MSYS" = 1 ] && [ -z "${SF_MSYS_TMP:-}" ]; then
  SF_MSYS_TMP=$(cygpath -m /tmp 2>/dev/null) || SF_MSYS_TMP=/tmp
  export SF_MSYS_TMP
fi

# sf_native_path PATH: PATH as a native program can open it. On Git Bash, /tmp/x becomes
# C:/Users/.../Temp/x (needed when path conversion is off, e.g. for sf_gh --body-file).
# Elsewhere, and for relative paths, PATH is printed unchanged.
sf_native_path() {
  local p="$1"
  if [ "$SF_MSYS" != 1 ]; then printf '%s\n' "$p"; return 0; fi
  case "$p" in
    # Drive paths and /tmp are the common cases; handle them without a process.
    /[A-Za-z]) printf '%s:/\n' "${p:1:1}" ;;
    /[A-Za-z]/*) printf '%s:/%s\n' "${p:1:1}" "${p:3}" ;;
    /tmp|/tmp/*) printf '%s%s\n' "$SF_MSYS_TMP" "${p#/tmp}" ;;
    /*) cygpath -m -- "$p" ;;
    *) printf '%s\n' "$p" ;;
  esac
}

sf_log()  { printf '%s: %s\n' "${SF_PROG:-factory}" "$*" >&2; }
sf_warn() { printf '%s: warning: %s\n' "${SF_PROG:-factory}" "$*" >&2; }

# sf_die MESSAGE [CODE]: print an error and exit (default code 2 = fail closed).
sf_die() {
  printf '%s: error: %s\n' "${SF_PROG:-factory}" "$1" >&2
  exit "${2:-$SF_USAGE}"
}

sf_need() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || sf_die "required command not found: $c"
  done
}

sf_is_none() { [ "${1:-}" = "none" ]; }

sf_now() { date +%s; }

# sf_random_hex [BYTES]: lowercase hex from /dev/urandom (default 4 bytes = 8 chars).
sf_random_hex() {
  od -An -N"${1:-4}" -tx1 /dev/urandom | tr -d ' \n'
}

# sf_repo_root [DIR]: top level of the git work tree containing DIR (default: cwd).
sf_repo_root() {
  local d="${1:-.}" top
  top=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null) || sf_die "not inside a git repository: $d"
  printf '%s\n' "$top"
}

sf_remote() { printf '%s\n' "${FACTORY_REMOTE:-origin}"; }

# sf_gh ARGS...: gh without interactive prompts and without MSYS path rewriting.
# Git Bash rewrites arguments that start with "/" into Windows paths, which breaks
# "gh api /repos/..."; always write API paths without the leading slash.
sf_gh() {
  MSYS_NO_PATHCONV=1 GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 gh "$@"
}

# sf_run_timeout SECONDS CMD [ARGS...]: run CMD; return its exit status, or 124 if it
# had to be killed after SECONDS. Portable replacement for GNU timeout (absent on macOS).
# Limits: it signals only CMD's own process; children CMD started can outlive a timeout. A
# timed command's output must be captured through a file, never $(...), or such a child
# keeps the pipe (and the caller) waiting.
sf_run_timeout() {
  local secs="$1" pid watcher status=0 fired
  shift
  fired=$(mktemp "${TMPDIR:-/tmp}/sf.timeout.XXXXXX")
  rm -f "$fired"
  "$@" &
  pid=$!
  # The watcher's own sleeps run as waited-on children that it kills when it is stopped,
  # so no `sleep SECS` is left behind for the full timeout after CMD finishes early.
  (
    sp=""
    trap '[ -n "$sp" ] && kill "$sp" 2>/dev/null; exit 0' TERM
    sleep "$secs" &
    sp=$!
    wait "$sp"
    kill -0 "$pid" 2>/dev/null || exit 0
    : >"$fired"
    kill -TERM "$pid" 2>/dev/null || exit 0
    sleep 5 &
    sp=$!
    wait "$sp"
    kill -KILL "$pid" 2>/dev/null || true
  ) </dev/null >/dev/null 2>&1 &
  watcher=$!
  wait "$pid" || status=$?
  kill "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  if [ -e "$fired" ]; then
    rm -f "$fired"
    status=124
  fi
  return "$status"
}

# sf_git_bk ARGS...: git for the factory's own bookkeeping (claim, lock, PR-link and wip
# commits, their worktrees, status checks and pushes). Every project hook is off:
# core.hooksPath=/dev/null also stops prepare-commit-msg, post-commit, post-checkout,
# post-index-change and reference-transaction, which --no-verify does not. So is signing.
sf_git_bk() { git -c core.hooksPath=/dev/null -c core.fsmonitor= -c commit.gpgsign=false "$@"; }

# sf_credential_names: names of exported environment entries that look like credentials, one
# per line. `env` also lists entries whose names are not shell identifiers (for example
# npm_config_//registry.example/:_authToken), which bash can neither list nor unset but
# still passes to every child. A multi-line value can add a line that merely looks like an
# entry; listing a name that does not exist is harmless (`env -u` ignores it).
sf_credential_names() {
  # pipefail in a subshell: a failure of any stage (env, awk, sort) must fail the listing,
  # whatever the caller's shell options are.
  (
    set -o pipefail
    env | awk '
      match($0, /^[^=]+=/) {
        n = substr($0, 1, RLENGTH - 1); u = toupper(n)
        if (u ~ /TOKEN|SECRET|PASSW|CREDENTIAL|API_?KEY|PRIVATE_?KEY|ACCESS_?KEY/ ||
            u ~ /(^|_)PAT(_|$)/ || n == "FACTORY_AGENT_ENV" || n == "SSH_AUTH_SOCK") print n
      }' | sort -u
  )
}

# _sf_scrub_args: fill the array SF_SCRUB_ARGS with "-u NAME" pairs for env. Returns 2 when
# the credential names can't be listed: then nothing may run, because it would run unscrubbed.
_sf_scrub_args() {
  local names n
  SF_SCRUB_ARGS=()
  names=$(sf_credential_names) || return 2
  while IFS= read -r n; do
    [ -n "$n" ] && SF_SCRUB_ARGS+=(-u "$n")
  done <<EOF
$names
EOF
  return 0
}

# sf_scrubbed CMD...: run CMD (an external command, not a shell function) with every
# sf_credential_names entry removed from its environment. Refuses (status 2) when the names
# can't be listed, with 125: the code env itself uses when it cannot start a command, so a
# caller never mistakes the refusal for the command's own exit 2.
sf_scrubbed() {
  _sf_scrub_args || { sf_warn "cannot list credential-like variables; not running $1"; return 125; }
  env ${SF_SCRUB_ARGS[@]+"${SF_SCRUB_ARGS[@]}"} "$@"
}

# sf_scrubbed_exec CMD...: the same, but exec's env, so the calling process becomes CMD.
# Call it only as the last command of a subshell or a background job, for example
# `sf_run_timeout SECS sf_scrubbed_exec bash -c ...`: then the timeout's signal reaches CMD
# itself on every bash version (bash 5.2 does not exec the last command of a function).
sf_scrubbed_exec() {
  _sf_scrub_args || { sf_warn "cannot list credential-like variables; not running $1"; exit 125; }
  exec env ${SF_SCRUB_ARGS[@]+"${SF_SCRUB_ARGS[@]}"} "$@"
}

# sf_lock DIR / sf_unlock DIR: local mutual exclusion; mkdir is atomic everywhere.
sf_lock()   { mkdir "$1" 2>/dev/null; }
sf_unlock() { rmdir "$1" 2>/dev/null || true; }

sf_mktemp_dir() { mktemp -d "${TMPDIR:-/tmp}/sf.XXXXXX"; }

# sf_trim STRING: strip leading and trailing whitespace.
sf_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}
