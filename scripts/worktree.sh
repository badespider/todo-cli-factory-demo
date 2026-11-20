#!/usr/bin/env bash
# Race-safe claims, role locks and per-worker git worktrees. Contract: docs/CONTRACTS.md, "worktree.sh".
set -euo pipefail
SF_PROG=worktree
# shellcheck source=scripts/lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
# shellcheck source=scripts/lib/jq.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/jq.sh"
# shellcheck source=scripts/lib/config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"

# The rest of this file is one brace group that ends in `exit`, so bash parses all of it
# before running any of it. bash reads a script file as it executes it, and agents work as
# the same user next to the judging copy: a rewrite of this file while a claim or a release
# is in flight must change nothing. (Sourced files are read whole when sourced.)
{

# Pin the tools before anything runs: bash looks a hashed name up in its table, never in
# PATH again, and subshells inherit the table. A tool that is missing stays missing.
hash bash git jq gh ssh awk sed tr head tail cat date mktemp rm sleep cygpath find sort od mkdir \
  dirname basename 2>/dev/null || true

usage() {
  cat <<'EOF'
Usage: bash scripts/worktree.sh SUBCOMMAND [options]

  claim   KEY [--agent ID] [--base REF]   claim factory/KEY; prints the worktree path
  resume  KEY [--agent ID]                worktree at the tip of factory/KEY; prints the path
  release KEY [--force]                   delete a dead claim; exit 1 if it is live, 2 if its
                                          liveness is unknown (--force: any claim, and drop
                                          uncommitted changes in the local worktree)
  path    KEY                             print the worktree path for KEY
  is-live KEY                             exit 0 live, 1 dead, 2 cannot tell (gh failed, timed
                                          out or gave no count), 3 no such claim
  list    [--json]                        claims and local worktrees: KEY<TAB>SHA<TAB>PATH
                                          ("-" = none; exit 2 if the remote can't be read)
  clean                                   remove clean worktrees whose branch is gone
  lock    NAME [--agent ID] [--ttl-min N] take the role lock factory/lock/NAME
  unlock  NAME [--agent ID]               drop it (with --agent: only if that agent holds it)

KEY is F<n>, issue-<n>, perf-<n>, intake, plan or spike-<name> (the n of issue-<n> and
perf-<n> without a leading zero; name: lowercase letters, digits and -).
Every subcommand also takes --tree DIR (the repo; default: the current one) and --config FILE.
Liveness asks gh about the repository of the remote's URL; for an ssh or scp-like URL the
host is first resolved with `ssh -G HOST`, so an ssh-config alias names the real host.
Environment: FACTORY_AGENT_ID, FACTORY_REMOTE, FACTORY_WORKTREE_ROOT, FACTORY_OFFLINE, FACTORY_CONFIG.
Exit: 0 done, 1 refused or dead, 2 usage, error or cannot tell, 3 claim lost / lock held /
no such claim.
Every git operation that changes something (worktrees, index, commits, refs, fetch, push)
runs with the project's hooks and commit signing off: it is the factory's bookkeeping.
EOF
}

opt_agent=""
opt_base=""
opt_force=0
opt_json=0
opt_ttl_min=""
opt_config=""
opt_tree=""
given=""

REPO=""
NAME=""
ROOT=""
REMOTE=""
AGENT=""
TIP_SHA=""
TIP_TIME=""
TIP_AUTHOR=""
CLEANUP_WT=""
LOCK_DIR=""

# _git_bk ARGS...: git for the factory's own bookkeeping. sf_git_bk turns every project hook
# (post-index-change, reference-transaction, post-checkout, prepare-commit-msg, post-commit
# and the rest, wherever core.hooksPath points, relative paths included) and commit signing
# off. The fsmonitor goes off too: an index refresh (status, add, checkout, worktree add)
# would otherwise run the program core.fsmonitor names, which may be a path in the tree.
_git_bk() { sf_git_bk -c core.fsmonitor=false "$@"; }

# --- exit handling --------------------------------------------------------------

# shellcheck disable=SC2329 # reached only through the EXIT trap
_on_exit() {
  if [ -n "$CLEANUP_WT" ]; then
    _git_bk -C "$REPO" worktree remove --force "$CLEANUP_WT" >/dev/null 2>&1 || rm -rf "$CLEANUP_WT" 2>/dev/null || true
    _git_bk -C "$REPO" worktree prune >/dev/null 2>&1 || true
  fi
  if [ -n "$LOCK_DIR" ]; then rm -rf "$LOCK_DIR" 2>/dev/null || true; fi
}
trap _on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- validation -----------------------------------------------------------------

# _valid_key KEY: F<n>, issue-<n>, perf-<n>, intake, plan or spike-<name>. An issue number
# has no leading zero, so issue-1 and issue-01 can never be two claims on one issue.
_valid_key() {
  local re='^(F[0-9]+|issue-[1-9][0-9]*|perf-[1-9][0-9]*|intake|plan|spike-[a-z0-9][a-z0-9-]*)$'
  [[ $1 =~ $re ]] && git check-ref-format "refs/heads/factory/$1"
}

_valid_lock_name() {
  local re='^[A-Za-z0-9][A-Za-z0-9._-]*$'
  [[ $1 =~ $re ]] && git check-ref-format "refs/heads/factory/lock/$1"
}

# _resolve_agent required|optional: sets AGENT from --agent or FACTORY_AGENT_ID.
_resolve_agent() {
  local re='^[A-Za-z0-9][A-Za-z0-9._-]*$'
  AGENT="${opt_agent:-${FACTORY_AGENT_ID:-}}"
  if [ -z "$AGENT" ]; then
    [ "$1" = optional ] && return 0
    sf_die "an agent id is required: pass --agent ID or set FACTORY_AGENT_ID"
  fi
  [[ $AGENT =~ $re ]] || sf_die "invalid agent id '$AGENT' (use letters, digits, '.', '_' and '-')"
}

_cfg_load() {
  [ -n "$SF_CONFIG_FILE" ] && return 0
  if [ -n "$opt_config" ]; then sf_config_load "$opt_config"; else sf_config_load; fi
}

# _whole_number VALUE WHAT: print VALUE as a decimal number ("08" is 8, not bad octal),
# or die if it is not a whole number.
_whole_number() {
  case "$1" in '' | *[!0-9]*) sf_die "$2 must be a whole number, got '$1'" ;; esac
  printf '%s\n' "$((10#$1))"
}

# --- repo, paths and local state --------------------------------------------------

# _init_repo: find the main repository (also when called from inside a worktree) and cd there.
_init_repo() {
  local start="${opt_tree:-.}" common
  [ -d "$start" ] || sf_die "no such directory: $start"
  common=$(cd "$start" && git rev-parse --git-common-dir 2>/dev/null) || sf_die "not inside a git repository: $start"
  common=$(cd "$start" && cd "$common" && pwd) || sf_die "cannot resolve the git directory of $start"
  case "$(basename "$common")" in
    .git) REPO=$(dirname "$common") ;;
    *) REPO="$common" ;; # bare repository
  esac
  NAME=$(basename "$REPO")
  NAME="${NAME%.git}"
  ROOT="${FACTORY_WORKTREE_ROOT:-$(dirname "$REPO")/.sf-wt}"
  case "$ROOT" in /* | [A-Za-z]:[\\/]*) ;; *) ROOT="$PWD/$ROOT" ;; esac
  ROOT="${ROOT%/}"
  REMOTE=$(sf_remote)
  cd "$REPO"
}

_wt_path() { printf '%s/%s-%s\n' "$ROOT" "$NAME" "$1"; }

# _registered DIR: true if DIR is a worktree registered in this repository.
_registered() {
  local p
  [ -d "$1" ] || return 1
  while IFS= read -r p; do
    [ -n "$p" ] && [ -d "$p" ] && [ "$p" -ef "$1" ] && return 0
  done <<EOF
$(git worktree list --porcelain | sed -n 's/^worktree //p')
EOF
  return 1
}

# _foreign DIR: true if DIR is the top of a live repository or worktree (of another repo).
_foreign() {
  local top
  [ -e "$1/.git" ] || return 1
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 1
  [ -d "$top" ] && [ "$top" -ef "$1" ]
}

# _dirty DIR: true if DIR has uncommitted or untracked changes (or can't be read).
# Bookkeeping git: status refreshes and rewrites the index, which would fire
# post-index-change and run the fsmonitor.
_dirty() {
  local out
  out=$(_git_bk -C "$1" status --porcelain 2>/dev/null) || return 0
  [ -n "$out" ]
}

# _local_worktrees: "KEY<TAB>PATH" for each registered worktree of this repo under ROOT.
_local_worktrees() {
  local p base key
  [ -d "$ROOT" ] || return 0
  while IFS= read -r p; do
    [ -n "$p" ] && [ -d "$p" ] || continue
    [ "$(dirname "$p")" -ef "$ROOT" ] || continue
    base=$(basename "$p")
    case "$base" in "$NAME"-*) key="${base#"$NAME"-}" ;; *) continue ;; esac
    _valid_key "$key" 2>/dev/null || continue
    printf '%s\t%s/%s\n' "$key" "$ROOT" "$base"
  done <<EOF
$(git worktree list --porcelain | sed -n 's/^worktree //p')
EOF
}

# _path_lock KEY [WAIT]: local mkdir lock for one worktree path, so two processes on this
# machine never create or remove the same worktree at once. Locks older than 10 minutes
# are stale. Returns 1 if the lock is still held after WAIT seconds (default 120).
_path_lock() {
  local d="$ROOT/.$NAME-$1.lock" wait="${2:-120}" waited=0
  mkdir -p "$ROOT" || sf_die "cannot create $ROOT"
  while ! mkdir "$d" 2>/dev/null; do
    if [ -n "$(find "$d" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
      sf_warn "removing stale local lock $d"
      rm -rf "$d"
      continue
    fi
    [ "$waited" -lt "$wait" ] || return 1
    sleep 1
    waited=$((waited + 1))
  done
  LOCK_DIR="$d"
  printf '%s %s\n' "$$" "$(sf_now)" >"$d/info" 2>/dev/null || true
}

_path_unlock() {
  [ -n "$LOCK_DIR" ] && rm -rf "$LOCK_DIR"
  LOCK_DIR=""
}

# _enable_worktree_config: turn on extensions.worktreeConfig in the main repo. Writing
# .git/config fails at once while another git process holds .git/config.lock (two claims
# of different keys in one repo), so write only when it is off, and retry for a while.
_enable_worktree_config() {
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ "$(git config --bool --get extensions.worktreeConfig 2>/dev/null || true)" = true ] && return 0
    _git_bk config extensions.worktreeConfig true 2>/dev/null && return 0
    [ "$i" -lt 10 ] && sleep 1
  done
  sf_die "cannot enable extensions.worktreeConfig in $REPO (is $REPO/.git/config.lock held?)"
}

_set_identity() { # _set_identity WORKTREE AGENT
  _enable_worktree_config
  _git_bk -C "$1" config --worktree user.name "$2" || sf_die "cannot write the agent identity into $1"
  _git_bk -C "$1" config --worktree user.email "$2@agents.factory.invalid" || sf_die "cannot write the agent identity into $1"
  _git_bk -C "$1" config --worktree core.longpaths true || sf_die "cannot write core.longpaths into $1"
}

# Every git call in this file that changes something (worktrees, the index, commits, refs,
# config, fetch and push) goes through _git_bk. The plain git calls are read-only queries
# (rev-parse, log, ls-remote, worktree list, config --get) that run no hook and no fsmonitor.

_as_agent() { # _as_agent AGENT CMD...: run CMD with the agent as git author and committer
  local a="$1"
  shift
  GIT_AUTHOR_NAME="$a" GIT_AUTHOR_EMAIL="$a@agents.factory.invalid" \
    GIT_COMMITTER_NAME="$a" GIT_COMMITTER_EMAIL="$a@agents.factory.invalid" "$@"
}

# _clear_path KEY: make the worktree path for KEY usable. Prunes stale registrations and
# removes a directory that is not a registered worktree. Returns 10 if a registered
# worktree is there (the caller decides). Dies if the path belongs to another repository.
_clear_path() {
  local wt
  wt=$(_wt_path "$1")
  _git_bk worktree prune || sf_die "git worktree prune failed"
  [ -e "$wt" ] || return 0
  _registered "$wt" && return 10
  _foreign "$wt" && sf_die "$wt is a worktree of another repository; remove it or set FACTORY_WORKTREE_ROOT"
  sf_log "removing stale directory $wt"
  rm -rf "$wt" || sf_die "cannot remove stale directory $wt"
}

# --- remote helpers --------------------------------------------------------------------

# _remote_sha REF: SHA of REF on the remote (empty if absent); status 2 if unreadable.
_remote_sha() {
  local out
  out=$(git ls-remote "$REMOTE" "$1") || return 2
  printf '%s\n' "$out" | awk -v r="$1" '$2 == r && !f { print $1; f = 1 }'
}

# _confirm REF SHA: 0 if the remote shows SHA at REF, 1 if not, 2 if it can't be read.
_confirm() {
  local i sha
  for i in 1 2 3; do
    if sha=$(_remote_sha "$1"); then
      [ "$sha" = "$2" ] && return 0
      return 1
    fi
    [ "$i" -lt 3 ] && sleep 1
  done
  return 2
}

# _fetch REFSPEC: fetch with retries (concurrent fetches in one repo can collide on ref locks).
_fetch() {
  local i
  for i in 1 2 3; do
    _git_bk fetch -q --no-tags "$REMOTE" "$1" >&2 && return 0
    [ "$i" -lt 3 ] && sleep 1
  done
  return 1
}

# _tip REF: fetch remote REF and set TIP_SHA, TIP_TIME (committer epoch) and TIP_AUTHOR.
# Returns 3 if REF does not exist on the remote, 2 if it can't be read.
_tip() {
  local ref="$1" track sha
  track="refs/remotes/$REMOTE/${ref#refs/heads/}"
  sha=$(_remote_sha "$ref") || return 2
  [ -n "$sha" ] || return 3
  if ! _fetch "+$ref:$track"; then
    sha=$(_remote_sha "$ref") || return 2
    [ -n "$sha" ] || return 3
    return 2
  fi
  TIP_SHA=$(git rev-parse --verify -q "$track^{commit}") || return 2
  TIP_TIME=$(git log -1 --format=%ct "$TIP_SHA") || return 2
  TIP_AUTHOR=$(git log -1 --format=%an "$TIP_SHA") || return 2
}

# _ssh_hostname HOST: the host ssh really connects to for HOST: the "hostname" line of
# `ssh -G HOST`, so an ssh-config alias (Host github-work / HostName github.com) names its
# real host. HOST as written when ssh was not found when the script started (the pinned
# one only: a later lookup could find a planted ssh), or when it fails, takes more than
# SF_WT_SSH_TIMEOUT seconds (default 10; Match exec and CanonicalizeHostname can run
# programs and DNS lookups) or answers anything but one host name. HOST has passed
# _gh_repo_of's host check, so it never starts with "-" (an ssh option).
_ssh_hostname() {
  local h="$1" ssh_bin tmpf st=0 out="" re_host
  re_host='^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$'
  ssh_bin=$(hash -t ssh 2>/dev/null) || ssh_bin=""
  if [ -z "$ssh_bin" ] || ! tmpf=$(mktemp "${TMPDIR:-/tmp}/sf.wt.ssh.XXXXXX" 2>/dev/null); then
    printf '%s\n' "$h"
    return 0
  fi
  # The answer goes to a file, never through $(...): see sf_run_timeout.
  sf_run_timeout "${SF_WT_SSH_TIMEOUT:-10}" "$ssh_bin" -G "$h" </dev/null >"$tmpf" 2>/dev/null || st=$?
  if [ "$st" -eq 0 ]; then
    # awk reads the whole answer itself: a reader that stopped at the hostname line would
    # break the pipe of whatever still wrote the rest, and pipefail would discard the answer.
    out=$(awk '{ gsub(/\r/, "") } $1 == "hostname" && !seen { seen = 1; if (NF == 2) print $2 }' "$tmpf") || out=""
  fi
  rm -f "$tmpf" 2>/dev/null || true
  if [ -n "$out" ] && [[ $out =~ $re_host ]]; then
    printf '%s\n' "$out"
  else
    printf '%s\n' "$h"
  fi
}

# _gh_repo_of URL: the `gh --repo` name of a GitHub-style remote URL: OWNER/REPO on
# github.com (or a subdomain of it, such as ssh.github.com), HOST/OWNER/REPO on any other
# host. The forms are https://[USER@]HOST[:PORT]/OWNER/REPO[.git] (http:// too),
# ssh://[USER@]HOST[:PORT]/OWNER/REPO[.git] and scp-like [USER@]HOST:OWNER/REPO[.git]. In
# the ssh forms HOST may be an ssh-config alias, so it is resolved first (_ssh_hostname).
# Anything else (a local path, a path with more segments) is status 1: gh then resolves
# the repository itself. Pure bash plus tr, _ssh_hostname and SF_MSYS, so tests can load
# it alone.
_gh_repo_of() {
  local u="$1" host path owner repo re_host re_path ssh=0
  re_host='^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$'
  re_path='^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$'
  case "$u" in
    https://* | http://* | ssh://*)
      case "$u" in ssh://*) ssh=1 ;; esac
      u="${u#*://}"
      case "$u" in */*) ;; *) return 1 ;; esac
      host="${u%%/*}"
      path="${u#*/}"
      ;;
    *)
      # scp-like [USER@]HOST:PATH, by git's own rule: no "/" before the first ":", so a
      # local path never passes for one. On Windows (SF_MSYS=1) a lone letter there is a
      # drive (C:x), which git reads as a local path; elsewhere git runs ssh to that host
      # (an alias such as "g" for github.com), so it is a host like any other.
      host="${u%%:*}"
      [ "$host" != "$u" ] || return 1
      case "$host" in */*) return 1 ;; esac
      if [ "${SF_MSYS:-0}" = 1 ]; then
        case "$host" in [A-Za-z]) return 1 ;; esac
      fi
      path="${u#*:}"
      ssh=1
      ;;
  esac
  host="${host##*@}" # user (and password)
  host="${host%:*}"  # port
  [[ $host =~ $re_host ]] || return 1
  path="${path%/}"
  path="${path%.git}"
  [[ $path =~ $re_path ]] || return 1
  owner="${BASH_REMATCH[1]}"
  repo="${BASH_REMATCH[2]}"
  case "/$owner/$repo/" in */./* | */../*) return 1 ;; esac
  [ "$ssh" = 0 ] || host=$(_ssh_hostname "$host")
  case "$host" in *[[:upper:]]*) host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]') ;; esac
  case "$host" in
    github.com | *.github.com) printf '%s/%s\n' "$owner" "$repo" ;;
    *) printf '%s/%s/%s\n' "$host" "$owner" "$repo" ;;
  esac
}

# _gh_repo_for_remote: the `gh --repo` name for $REMOTE (see _gh_repo_of): from its URL as
# git uses it (insteadOf applied), else from its URL as configured; a REMOTE that is not a
# configured remote is taken as a URL itself. Status 1 when none of them is such a URL.
_gh_repo_for_remote() {
  local u nl='
'
  if u=$(git remote get-url "$REMOTE" 2>/dev/null); then
    _gh_repo_of "$u" && return 0
    u=$(git config --get-all "remote.$REMOTE.url" 2>/dev/null) || return 1
    _gh_repo_of "${u%%"$nl"*}"
    return
  fi
  _gh_repo_of "$REMOTE"
}

# _printable TEXT: TEXT cut to 80 characters, everything but [A-Za-z0-9 ._:-] shown as "?",
# so an odd answer can't forge a line of output.
_printable() {
  printf '%s' "${1:0:80}" | tr -c 'A-Za-z0-9 ._:-' '?' || true
}

# _liveness KEY (after _tip): 0 live, 1 dead, 2 unknown (gh did not answer).
# Tip age first, then an open PR. Offline (FACTORY_OFFLINE=1) uses tip age only, by design;
# online, a gh that fails or times out is "unknown", never "dead": deleting the head branch
# of an open PR closes that PR.
_liveness() {
  local key="$1" ttl age n tmpf st=0 repo
  local -a repo_args
  repo_args=()
  _cfg_load
  ttl=$(sf_cfg claims.ttl_hours 6)
  ttl=$(_whole_number "$ttl" "claims.ttl_hours") || exit 2
  age=$(($(sf_now) - TIP_TIME))
  if [ "$age" -lt $((ttl * 3600)) ]; then
    sf_log "factory/$key is live: tip is ${age}s old (ttl ${ttl}h)"
    return 0
  fi
  if [ "${FACTORY_OFFLINE:-}" = 1 ]; then
    sf_log "factory/$key is dead: tip is ${age}s old (ttl ${ttl}h); offline, PRs not checked"
    return 1
  fi
  # The repository the claim lives in, named explicitly: left to itself, gh picks among the
  # checkout's remotes (upstream first), which may be another repository.
  if repo=$(_gh_repo_for_remote); then repo_args=(--repo "$repo"); fi
  # Bounded: a hung gh must not block is-live or release. The answer goes to a file, not
  # through $(...): a process gh leaves behind would hold that pipe open past the timeout.
  tmpf=$(mktemp "${TMPDIR:-/tmp}/sf.wt.gh.XXXXXX") || sf_die "cannot create a temporary file"
  sf_run_timeout "${SF_WT_GH_TIMEOUT:-60}" sf_gh pr list ${repo_args[@]+"${repo_args[@]}"} \
    --head "factory/$key" --state open --json number --jq length </dev/null >"$tmpf" 2>/dev/null || st=$?
  n=$(tr -d '\r' <"$tmpf" 2>/dev/null) || n=""
  rm -f "$tmpf" 2>/dev/null || true
  if [ "$st" -ne 0 ]; then
    sf_warn "gh pr list failed or timed out (exit $st); cannot tell whether factory/$key has an open PR"
    return 2
  fi
  # A count is 1 to 9 digits and nothing else. Anything more (several lines, spaces, or a
  # number too big for [ -gt ], whose error would read as "no open PR") is unknown.
  case "$n" in
    '' | *[!0-9]* | ??????????*)
      sf_warn "unexpected answer from gh pr list ('$(_printable "$n")'); cannot tell whether factory/$key has an open PR"
      return 2
      ;;
  esac
  if [ "$n" -gt 0 ]; then
    sf_log "factory/$key is live: it has an open PR"
    return 0
  fi
  sf_log "factory/$key is dead: tip is ${age}s old (ttl ${ttl}h) and there is no open PR"
  return 1
}

# _remove_local KEY: remove KEY's local worktree, keeping one with uncommitted changes unless --force.
_remove_local() {
  local key="$1" wt st=0
  wt=$(_wt_path "$key")
  _path_lock "$key" || sf_die "another process on this machine holds the lock for $wt"
  _clear_path "$key" || st=$?
  if [ "$st" -eq 10 ]; then
    if [ "$opt_force" != 1 ] && _dirty "$wt"; then
      sf_warn "kept $wt: it has uncommitted changes (--force discards them)"
    else
      _git_bk worktree remove --force "$wt" >&2 || sf_die "cannot remove worktree $wt"
      sf_log "removed worktree $wt"
    fi
  fi
  _path_unlock
}

# --- subcommands -----------------------------------------------------------------------

cmd_claim() {
  local key="$1" base ref wt st=0 sha map nonce head pushed=1
  _resolve_agent required
  _cfg_load
  base="${opt_base:-$(sf_cfg base_branch main)}"
  base="${base#refs/heads/}"
  git check-ref-format --branch "$base" >/dev/null 2>&1 || sf_die "invalid base branch '$base'"
  ref="refs/heads/factory/$key"
  wt=$(_wt_path "$key")

  _fetch "+refs/heads/$base:refs/remotes/$REMOTE/$base" || sf_die "git fetch $REMOTE $base failed"
  _path_lock "$key" || sf_die "another process on this machine is claiming $key"
  _clear_path "$key" || st=$?
  if [ "$st" -eq 10 ]; then
    # A worktree is already registered at our path: a leftover, or this agent's own claim.
    sha=$(_remote_sha "$ref") || sf_die "cannot read $REMOTE"
    if [ -n "$sha" ]; then
      st=0
      _tip "$ref" || st=$?
      case "$st" in
        0 | 3) ;; # 3: deleted since the read above; still not ours to take here
        *) sf_die "cannot read factory/$key from $REMOTE; kept the existing worktree $wt" ;;
      esac
      if [ "$st" = 0 ] && [ "$TIP_AUTHOR" = "$AGENT" ]; then
        sf_log "factory/$key is already claimed by $AGENT"
        printf '%s\n' "$wt"
        exit 0
      fi
      sf_log "claim lost: factory/$key already exists on $REMOTE; kept the existing worktree $wt"
      exit 3
    fi
    _dirty "$wt" && sf_die "$wt has uncommitted changes but no claim branch; commit or move them, or run: worktree.sh release $key --force"
    sf_log "removing leftover worktree $wt (no claim branch on $REMOTE)"
    _git_bk worktree remove --force "$wt" >&2 || sf_die "cannot remove leftover worktree $wt"
  fi

  mkdir -p "$ROOT" || sf_die "cannot create $ROOT"
  CLEANUP_WT="$wt"
  _git_bk -c core.longpaths=true worktree add --force --detach "$wt" "refs/remotes/$REMOTE/$base" >&2 ||
    sf_die "git worktree add $wt failed"
  _set_identity "$wt" "$AGENT"

  case "$key" in
    F*)
      map="$wt/factory/feature-map.json"
      [ -f "$map" ] || sf_die "$REMOTE/$base has no factory/feature-map.json"
      [ -f "$SF_SCRIPTS_DIR/feature-map.sh" ] || sf_die "missing $SF_SCRIPTS_DIR/feature-map.sh"
      (cd "$wt" && bash "$SF_SCRIPTS_DIR/feature-map.sh" mark "$key" in_progress --map "$map") >&2 ||
        sf_die "feature-map.sh mark $key in_progress failed"
      _git_bk -C "$wt" add -- factory/feature-map.json || sf_die "git add factory/feature-map.json failed"
      ;;
  esac
  nonce=$(sf_random_hex 4)
  # A bookkeeping commit: the project's hooks and signing apply to agents' work, not here.
  _as_agent "$AGENT" _git_bk -C "$wt" commit -q --no-verify --allow-empty \
    -m "chore($key): claim by $AGENT [nonce $nonce]" >&2 ||
    sf_die "claim commit failed"
  head=$(git -C "$wt" rev-parse HEAD)

  _git_bk -C "$wt" push -q --no-verify "--force-with-lease=$ref:" "$REMOTE" "HEAD:$ref" >&2 || pushed=0
  st=0
  _confirm "$ref" "$head" || st=$?
  case "$st" in
    0)
      CLEANUP_WT=""
      sf_log "claimed factory/$key as $AGENT"
      printf '%s\n' "$wt"
      exit 0
      ;;
    1)
      sha=$(_remote_sha "$ref" 2>/dev/null) || sha=""
      if [ -n "$sha" ]; then
        sf_log "claim lost: factory/$key is at $sha, not ours ($head); removed $wt"
        exit 3
      fi
      sf_die "push of factory/$key failed (pushed=$pushed)"
      ;;
    *)
      # The push may have landed even though we can't see it. Take our own branch back
      # (lease on our SHA, so a winner's branch is never touched); otherwise it would
      # block the key for claims.ttl_hours.
      # Tried even when the push reported failure: it may have landed before the
      # connection dropped. The lease makes this a no-op unless the branch is ours.
      if _git_bk -C "$wt" push -q --no-verify "--force-with-lease=$ref:$head" "$REMOTE" ":$ref" >/dev/null 2>&1; then
        sf_die "cannot confirm the claim on $REMOTE; deleted our branch again and removed $wt"
      fi
      sf_die "cannot confirm the claim on $REMOTE; removed $wt"
      ;;
  esac
}

cmd_resume() {
  local key="$1" ref wt st=0 head
  _resolve_agent optional
  ref="refs/heads/factory/$key"
  wt=$(_wt_path "$key")
  _tip "$ref" || st=$?
  case "$st" in
    0) ;;
    3)
      sf_log "no claim branch factory/$key on $REMOTE"
      exit 1
      ;;
    *) sf_die "cannot read factory/$key from $REMOTE" ;;
  esac
  _path_lock "$key" || sf_die "another process on this machine holds the lock for $wt"
  st=0
  _clear_path "$key" || st=$?
  if [ "$st" -eq 10 ]; then
    head=$(git -C "$wt" rev-parse HEAD 2>/dev/null) || head=""
    if [ "$head" = "$TIP_SHA" ]; then
      :
    elif _dirty "$wt"; then
      sf_warn "$wt has uncommitted changes; left at ${head:-?} (tip is $TIP_SHA)"
    elif [ -n "$head" ] && git merge-base --is-ancestor "$head" "$TIP_SHA"; then
      _git_bk -C "$wt" checkout -q --detach "$TIP_SHA" >&2 || sf_die "cannot move $wt to $TIP_SHA"
    else
      sf_warn "$wt has local commits not on factory/$key; left at $head"
    fi
  else
    mkdir -p "$ROOT" || sf_die "cannot create $ROOT"
    CLEANUP_WT="$wt"
    _git_bk -c core.longpaths=true worktree add --force --detach "$wt" "$TIP_SHA" >&2 ||
      sf_die "git worktree add $wt failed"
  fi
  [ -n "$AGENT" ] && _set_identity "$wt" "$AGENT"
  CLEANUP_WT=""
  printf '%s\n' "$wt"
}

cmd_release() {
  local key="$1" ref st=0 now_sha
  ref="refs/heads/factory/$key"
  _tip "$ref" || st=$?
  case "$st" in
    0)
      _liveness "$key" || st=$?
      case "$st" in
        0)
          if [ "$opt_force" != 1 ]; then
            sf_log "not released: factory/$key is live (use --force)"
            exit 1
          fi
          sf_log "releasing live claim factory/$key (--force)"
          ;;
        2)
          [ "$opt_force" = 1 ] || sf_die "not released: cannot tell whether factory/$key is live (use --force)"
          sf_log "releasing factory/$key whose liveness is unknown (--force)"
          ;;
      esac
      if ! _git_bk push -q --no-verify "--force-with-lease=$ref:$TIP_SHA" "$REMOTE" ":$ref" >&2; then
        now_sha=$(_remote_sha "$ref") || sf_die "cannot delete factory/$key on $REMOTE"
        if [ -z "$now_sha" ]; then
          sf_log "factory/$key was already deleted"
        elif [ "$now_sha" != "$TIP_SHA" ]; then
          sf_log "not released: factory/$key moved to $now_sha while releasing"
          exit 1
        else
          sf_die "cannot delete factory/$key on $REMOTE"
        fi
      fi
      _git_bk update-ref -d "refs/remotes/$REMOTE/factory/$key" >/dev/null 2>&1 || true
      sf_log "released factory/$key"
      ;;
    3) sf_log "no claim branch factory/$key on $REMOTE" ;;
    *) sf_die "cannot read factory/$key from $REMOTE" ;;
  esac
  _remove_local "$key"
}

cmd_is_live() {
  local key="$1" st=0
  _tip "refs/heads/factory/$key" || st=$?
  case "$st" in
    0) ;;
    3)
      sf_log "no claim branch factory/$key on $REMOTE"
      exit 3
      ;;
    *) sf_die "cannot read factory/$key from $REMOTE" ;;
  esac
  st=0
  _liveness "$key" || st=$?
  case "$st" in
    0) exit 0 ;;
    1) exit 1 ;;
    *) sf_die "cannot tell whether factory/$key is live" ;;
  esac
}

cmd_list() {
  local out remote_rows local_rows rows
  # Fail closed: without the remote, every claim would be listed as gone ("-").
  out=$(git ls-remote "$REMOTE" 'refs/heads/factory/*') || sf_die "cannot read $REMOTE"
  remote_rows=$(printf '%s\n' "$out" | awk '
    index($2, "refs/heads/factory/") == 1 {
      k = substr($2, 20)
      if (k !~ /^lock\//) print "R\t" k "\t" $1
    }')
  local_rows=$(_local_worktrees | awk '{ print "L\t" $0 }')
  rows=$(printf '%s\n%s\n' "$remote_rows" "$local_rows" | awk -F '\t' '
    NF >= 3 {
      keys[$2] = 1
      if ($1 == "R") sha[$2] = $3; else path[$2] = $3
    }
    END {
      for (k in keys) print k "\t" ((k in sha) ? sha[k] : "-") "\t" ((k in path) ? path[k] : "-")
    }' | sort)
  if [ "$opt_json" = 1 ]; then
    printf '%s\n' "$rows" | sf_jq -R -s '
      [split("\n")[] | select(length > 0) | split("\t")
       | {key: .[0], branch: ("factory/" + .[0]),
          sha: (if .[1] == "-" then null else .[1] end),
          path: (if .[2] == "-" then null else .[2] end)}]'
  elif [ -n "$rows" ]; then
    printf '%s\n' "$rows"
  fi
}

cmd_clean() {
  local out key p sha
  out=$(git ls-remote "$REMOTE" 'refs/heads/factory/*') || sf_die "cannot read $REMOTE; nothing removed"
  _git_bk worktree prune || sf_die "git worktree prune failed"
  while IFS=$'\t' read -r key p; do
    [ -n "$key" ] || continue
    if printf '%s\n' "$out" | awk -v r="refs/heads/factory/$key" '$2 == r { f = 1 } END { exit !f }'; then
      sf_log "kept $p: factory/$key still exists on $REMOTE"
      continue
    fi
    if ! _path_lock "$key" 0; then
      sf_log "kept $p: another process is using it"
      continue
    fi
    # Re-read the branch under the lock: a claim may have landed since the listing.
    if ! sha=$(_remote_sha "refs/heads/factory/$key") || [ -n "$sha" ]; then
      sf_log "kept $p: factory/$key exists (or $REMOTE is unreadable)"
    elif _dirty "$p"; then
      sf_log "kept $p: it has uncommitted changes"
    elif _git_bk worktree remove "$p" >&2; then
      printf '%s\n' "$p"
    else
      sf_warn "cannot remove $p"
    fi
    _path_unlock
  done <<EOF
$(_local_worktrees)
EOF
  _git_bk worktree prune || true
}

_lock_commit() { # _lock_commit NAME: print a new parentless commit for the lock branch
  local tree
  tree=$(_git_bk mktree </dev/null) || return 1
  _as_agent "$AGENT" _git_bk commit-tree "$tree" -m "chore(lock): $1 held by $AGENT [nonce $(sf_random_hex 4)]"
}

cmd_lock() {
  local name="$1" ttl ref new st age err="" last_err=""
  _resolve_agent required
  if [ -n "$opt_ttl_min" ]; then
    ttl=$(_whole_number "$opt_ttl_min" "--ttl-min") || exit 2
  else
    _cfg_load
    ttl=$(sf_cfg limits.agent_timeout_minutes 45)
    ttl=$(_whole_number "$ttl" "limits.agent_timeout_minutes") || exit 2
  fi
  ref="refs/heads/factory/lock/$name"
  new=$(_lock_commit "$name") || sf_die "cannot create the lock commit"
  for _ in 1 2 3; do
    # The push's own error is kept: when the lock is still absent afterwards, the push
    # failed for another reason (a hook, permissions) and that reason must be shown.
    if err=$(_git_bk push -q --no-verify "--force-with-lease=$ref:" "$REMOTE" "$new:$ref" 2>&1) && _confirm "$ref" "$new"; then
      sf_log "lock $name taken by $AGENT"
      exit 0
    fi
    st=0
    _tip "$ref" || st=$?
    case "$st" in
      0) ;;
      3) # absent: released between our push and our read, or the push itself failed
        last_err="$err"
        continue
        ;;
      *) sf_die "cannot read lock $name from $REMOTE" ;;
    esac
    if [ "$TIP_SHA" = "$new" ] || [ "$TIP_AUTHOR" = "$AGENT" ]; then
      sf_log "lock $name is held by $AGENT"
      exit 0
    fi
    age=$(($(sf_now) - TIP_TIME))
    if [ "$age" -lt $((ttl * 60)) ]; then
      sf_log "lock $name is held by $TIP_AUTHOR (${age}s old, ttl ${ttl}m)"
      exit 3
    fi
    sf_log "taking over stale lock $name from $TIP_AUTHOR (${age}s old, ttl ${ttl}m)"
    if _git_bk push -q --no-verify "--force-with-lease=$ref:$TIP_SHA" "$REMOTE" "$new:$ref" >&2 && _confirm "$ref" "$new"; then
      sf_log "lock $name taken by $AGENT"
      exit 0
    fi
    sf_log "lost the takeover of lock $name"
    exit 3
  done
  [ -z "$last_err" ] || printf '%s\n' "$last_err" >&2
  sf_die "cannot take lock $name: the push failed (or the lock keeps changing)"
}

cmd_unlock() {
  local name="$1" ref st=0 now_sha
  _resolve_agent optional
  ref="refs/heads/factory/lock/$name"
  _tip "$ref" || st=$?
  case "$st" in
    0) ;;
    3)
      sf_log "lock $name is not held"
      exit 0
      ;;
    *) sf_die "cannot read lock $name from $REMOTE" ;;
  esac
  if [ -n "$AGENT" ] && [ "$TIP_AUTHOR" != "$AGENT" ]; then
    sf_log "lock $name is held by $TIP_AUTHOR, not $AGENT; left alone"
    exit 3
  fi
  if ! _git_bk push -q --no-verify "--force-with-lease=$ref:$TIP_SHA" "$REMOTE" ":$ref" >&2; then
    now_sha=$(_remote_sha "$ref") || sf_die "cannot delete lock $name on $REMOTE"
    if [ -n "$now_sha" ] && [ "$now_sha" != "$TIP_SHA" ]; then
      sf_log "lock $name changed hands while unlocking; left alone"
      exit 3
    fi
    [ -z "$now_sha" ] || sf_die "cannot delete lock $name on $REMOTE"
  fi
  _git_bk update-ref -d "refs/remotes/$REMOTE/factory/lock/$name" >/dev/null 2>&1 || true
  sf_log "lock $name released"
}

# --- main ----------------------------------------------------------------------------------

# _only OPTION...: usage error if an option outside this list (plus --tree/--config) was given.
_only() {
  local g a ok
  for g in $given; do
    ok=0
    for a in --tree --config "$@"; do [ "$g" = "$a" ] && ok=1; done
    [ "$ok" = 1 ] || sf_die "$sub does not take $g"
  done
}

_need_value() { [ "$2" -ge 2 ] || sf_die "$1 needs a value"; }

sub="${1:-}"
case "$sub" in
  -h | --help)
    usage
    exit 0
    ;;
  '')
    usage >&2
    exit 2
    ;;
esac
shift
pos=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --agent) _need_value "$1" "$#"; opt_agent="$2"; given="$given --agent"; shift 2 ;;
    --base) _need_value "$1" "$#"; opt_base="$2"; given="$given --base"; shift 2 ;;
    --ttl-min) _need_value "$1" "$#"; opt_ttl_min="$2"; given="$given --ttl-min"; shift 2 ;;
    --config) _need_value "$1" "$#"; opt_config="$2"; given="$given --config"; shift 2 ;;
    --tree) _need_value "$1" "$#"; opt_tree="$2"; given="$given --tree"; shift 2 ;;
    --force) opt_force=1; given="$given --force"; shift ;;
    --json) opt_json=1; given="$given --json"; shift ;;
    --) shift; pos+=("$@"); break ;;
    -*) sf_die "unknown option: $1" ;;
    *) pos+=("$1"); shift ;;
  esac
done

# A relative --config or FACTORY_CONFIG names a file in the caller's directory; make it
# absolute before _init_repo moves into the repository.
[ -z "$opt_config" ] || FACTORY_CONFIG="$opt_config"
if [ -n "${FACTORY_CONFIG:-}" ]; then
  case "$FACTORY_CONFIG" in /* | [A-Za-z]:[\\/]*) ;; *) FACTORY_CONFIG="$PWD/$FACTORY_CONFIG" ;; esac
  opt_config="$FACTORY_CONFIG"
  export FACTORY_CONFIG # feature-map.sh reads the same config
fi

case "$sub" in
  claim | resume | release | path | is-live)
    case "$sub" in
      claim) _only --agent --base ;;
      resume) _only --agent ;;
      release) _only --force ;;
      *) _only ;;
    esac
    [ "${#pos[@]}" -eq 1 ] || sf_die "usage: worktree.sh $sub KEY (see --help)"
    _valid_key "${pos[0]}" 2>/dev/null || sf_die "invalid key '${pos[0]}' (F<n>, issue-<n>, perf-<n>, intake, plan or spike-<name>)"
    ;;
  lock | unlock)
    if [ "$sub" = lock ]; then _only --agent --ttl-min; else _only --agent; fi
    [ "${#pos[@]}" -eq 1 ] || sf_die "usage: worktree.sh $sub NAME (see --help)"
    _valid_lock_name "${pos[0]}" 2>/dev/null || sf_die "invalid lock name '${pos[0]}'"
    ;;
  list | clean)
    if [ "$sub" = list ]; then _only --json; else _only; fi
    [ "${#pos[@]}" -eq 0 ] || sf_die "$sub takes no arguments"
    ;;
  *) sf_die "unknown subcommand: $sub (see --help)" ;;
esac

_init_repo
case "$sub" in
  claim) cmd_claim "${pos[0]}" ;;
  resume) cmd_resume "${pos[0]}" ;;
  release) cmd_release "${pos[0]}" ;;
  path) _wt_path "${pos[0]}" ;;
  is-live) cmd_is_live "${pos[0]}" ;;
  list) cmd_list ;;
  clean) cmd_clean ;;
  lock) cmd_lock "${pos[0]}" ;;
  unlock) cmd_unlock "${pos[0]}" ;;
esac
# Nothing after this line is ever read from the file.
exit $?
}
