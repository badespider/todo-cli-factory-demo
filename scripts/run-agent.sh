#!/usr/bin/env bash
# Runs one memoryless agent task in one harness and leaves all state in git and GitHub. Contract: docs/CONTRACTS.md, "run-agent.sh".
set -euo pipefail
SF_PROG=run-agent
# shellcheck source=scripts/lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
# shellcheck source=scripts/lib/jq.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/jq.sh"
# shellcheck source=scripts/lib/config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"

# The rest of this file is one brace group that ends in `exit`, so bash parses all of it
# before running any of it. bash reads a script file as it executes it, and the agent the
# harness runs can write this file (same user; it may be the main checkout's own copy): a
# rewrite or an append would otherwise run as part of the exit trap's tail, with the tokens
# in our environment. (Sourced files are read whole when sourced; the other scripts it runs
# come from a snapshot taken before any agent code runs: see _snapshot_judge.)
# shellcheck disable=SC2329 # the exit trap's functions are reached only through `trap`
{

# Pin the tools before any agent or project code runs: that code can put an executable named
# gh (which would get the token), git or bash in a PATH directory it can write to
# (~/.local/bin, say). bash looks a hashed name up in its table, never in PATH again, and
# subshells inherit the table. A tool that is missing stays missing (hash reports it).
RA_TOOLS="bash git jq gh awk sed tr head tail cat wc date mktemp rm mv sleep cygpath grep od mkdir cp dirname basename"
# shellcheck disable=SC2086 # a fixed list of names
hash $RA_TOOLS 2>/dev/null || true

usage() {
  cat <<'EOF'
Usage:
  bash scripts/run-agent.sh --role ROLE [--feature ID] [--issue N] [--pr N] [--task TEXT]
                            [--idea TEXT] [--due] [--dry-run] [--config FILE] [--tree DIR]
  bash scripts/run-agent.sh --due [--dry-run] [--config FILE] [--tree DIR]

Runs exactly one agent task in one harness. The harness argv is FACTORY_HARNESS_CMD, else
config harness_cmd (for verify, config review_harness_cmd replaces both when it is not
none), split on whitespace (quotes are not interpreted), plus the prompt as one final
argument. A relative wrapper path (argv[0], or argv[1] after bash or sh) is resolved against
the main checkout. The preflight looks for the harness binary: argv[0], or, after bash or sh
and a wrapper script, the command that follows the wrapper (argv[2]; argv[3] after "--"),
and the wrapper itself. stdin is /dev/null; output is teed to
<main>/.factory/logs/<agent id>.log.

Roles:
  build           first resumes the oldest stale draft PR from factory/intake or
                  factory/plan (as intake or plan-features); else picks the build stage
                  from origin/<base>: intake when there is no factory/spec.md or it is a raw
                  request (its first line is not <!-- factory:spec -->); plan-features for a
                  spec, an empty feature map and no open needs-human issue titled
                  "intake: ..."; else build-feature
  intake          resumes a stale draft PR from factory/intake first; else writes
                  factory/spec.md (needs --idea, or a raw request in factory/spec.md)
  plan-features   resumes a stale draft PR from factory/plan first; else writes
                  factory/feature-map.json (needs a marked factory/spec.md)
  build-feature   --feature F<n>; else resumes the oldest stale draft PR from factory/F<n>;
                  else claims the first ready feature it wins (feature-map.sh next --all
                  --live; a lost claim moves on to the next ready id, up to 5 tries)
  verify          --pr N (required); reviews the PR head in a fresh detached worktree
                  (<repo>-verify-<n>-<hex>) that is removed with its leftovers at exit
  handoff         runs in the main checkout, claims nothing
  bug-fix, perf   standing: --issue N; else resumes the oldest stale draft PR from
                  factory/issue-<n> (perf: factory/perf-<n>); else claims the oldest
                  role:<role> issue whose claim is free (never one labeled needs-human or
                  status:blocked); else hunt / measure mode in a throwaway worktree,
                  unless backpressure says wait. perf does nothing while roles.perf.bench
                  is none (unless --issue is given)
  babysit         standing: --pr N; else the oldest open non-draft factory/<key> PR with a
                  failing check, the verify:findings label or a DIRTY / BEHIND merge state,
                  unless it was handed back to its writer at its head. With none, it does
                  its housekeeping without an agent: release dead claims (online only), then
                  bash scripts/report.sh throughput --post (when installed)
  ship            standing: --pr N; else the oldest open non-draft factory/<key> PR that
                  passes ship.sh check (at most 10 PRs tried, oldest first)
A stale draft is one whose tip is older than limits.agent_timeout_minutes + 15 minutes: its
writer is gone. Before resuming one, a run takes the lock factory/lock/resume-<key>
(worktree.sh lock; held by another run: the next stale draft is tried) and releases it at
exit, so two runs never resume one draft together; a dry run only reads that lock. --task
adds an operator note to the task.
A local run (not CI, not offline) warns once when the gh login its agents get has the
workflow scope (gh auth status, else the X-OAuth-Scopes header of gh api -i user, both
without the GitHub tokens the harness never gets and with FACTORY_AGENT_ENV's lines): then
agents can push workflow changes. It never fails on that.
Only the writer roles (build-feature, bug-fix, perf, intake, plan-features, babysit) have
their leftovers saved at exit: an unfinished merge, rebase, cherry-pick or revert is aborted,
leftover test files go first in a commit of their own while the branch has no tests-only
commit yet, the rest follows as a wip commit, and the branch is pushed (fast-forward only).
verify, ship and handoff never commit or push.

Options:
  --role ROLE  the role to run (above)
  --feature ID build-feature: the feature to claim (F<n>)
  --issue N    bug-fix, perf: the issue to claim
  --pr N       babysit, ship, verify: the PR to work on
  --task TEXT  an operator note added to the task
  --idea TEXT  intake (and build when its stage is intake): the idea to turn into a spec
  --due        run only if the role is due (roles.<role>.every, read from the role's comment
               on the factory:log issue). Without --role: run every standing role that is
               due, one after another, and exit with the worst status (a role stopped by
               SIGHUP/SIGINT/SIGTERM ends the run with that role's status).
  --dry-run    check the stop switches (a stopped factory says "factory stopped (dry run
               continues)" and goes on), the due check and the pick, then print the harness
               argv, one "argv[i]=..." line per element (prompt included), and what would be
               claimed or resumed, without locking, claiming, releasing, writing to GitHub
               or launching.
  --config F   config file (default: FACTORY_CONFIG, else the judging copy's)
  --tree DIR   the main checkout (default: the current repository)
  -h, --help   this text

Environment: FACTORY_HARNESS_CMD, FACTORY_AGENT_ENV (a file, or KEY=VALUE lines, exported
for the harness only), FACTORY_ENABLED and FACTORY_CI_AGENTS (read from the environment
when CI=true; FACTORY_ENABLED also with FACTORY_OFFLINE=1), FACTORY_OFFLINE, FACTORY_REMOTE,
FACTORY_WORKTREE_ROOT, FACTORY_CONFIG, GH_REPO (online, the repository is GH_REPO or what gh
repo view says in the main checkout, resolved before any agent code runs; the gh calls made
after the agent ran name it, from /).

Exit codes: 0 the harness exited 0, or nothing to do / stopped / not due / role locked;
1 the harness exited non-zero; 2 config, usage or preflight error, the harness could not
start (126/127), or a pick that could not decide; 3 the claim was lost; 4 timeout;
129/130/143 stopped by SIGHUP/SIGINT/SIGTERM (after the exit trap).
Contract: docs/CONTRACTS.md, "run-agent.sh".
EOF
}

STANDING_ROLES="bug-fix perf babysit ship"
ALL_ROLES="build intake plan-features build-feature verify handoff $STANDING_ROLES"
# Roles whose leftovers the exit trap saves (wip commit, push, handoff comment). verify, ship
# and handoff never commit or push: a reviewer's leftovers must not change the head it reviewed.
WRITER_ROLES="build-feature bug-fix perf intake plan-features babysit"
# Never handed to the harness unless FACTORY_AGENT_ENV passes them explicitly.
SCRUBBED_ENV="GH_TOKEN GITHUB_TOKEN FACTORY_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN FACTORY_AGENT_ENV"
SPEC_MARKER='<!-- factory:spec -->'
# How many ready features build-feature tries to claim, and how many PRs ship checks.
CLAIM_TRIES=5
SHIP_TRIES=10
NL=$'\n'
TAB=$'\t'

# --- options ------------------------------------------------------------------------------

opt_role="" opt_feature="" opt_issue="" opt_pr="" opt_task="" opt_idea="" opt_config="" opt_tree=""
opt_due=0
opt_dry=0
given=""

_need_value() {
  [ "$2" -ge 2 ] || sf_die "$1 needs a value (see --help)"
  [ -n "$3" ] || sf_die "$1 needs a non-empty value"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --role | --feature | --issue | --pr | --task | --idea | --config | --tree)
      _need_value "$1" "$#" "${2:-}"
      case "$1" in
        --role) opt_role="$2" ;;
        --feature) opt_feature="$2" ;;
        --issue) opt_issue="$2" ;;
        --pr) opt_pr="$2" ;;
        --task) opt_task="$2" ;;
        --idea) opt_idea="$2" ;;
        --config) opt_config="$2" ;;
        --tree) opt_tree="$2" ;;
      esac
      given="$given $1"
      shift 2
      ;;
    --due) opt_due=1; shift ;;
    --dry-run) opt_dry=1; shift ;;
    *) sf_die "unknown argument: $(printf '%s' "$1" | tr '\001-\037\177' '?') (see --help)" ;;
  esac
done

# _in_list WORD LIST: WORD is one of the space-separated words of LIST (exactly, so "a b" is not).
_in_list() {
  local w
  for w in $2; do [ "$w" = "$1" ] && return 0; done
  return 1
}
_is_standing() { _in_list "$1" "$STANDING_ROLES"; }
_given() { case "$given " in *" $1 "*) return 0 ;; esac; return 1; }
_offline() { [ "${FACTORY_OFFLINE:-}" = 1 ]; }
_number_ok() { case "$1" in '' | 0* | *[!0-9]*) return 1 ;; esac; [ "${#1}" -le 9 ]; }
_feature_ok() { case "$1" in F[0-9]*) case "${1#F}" in *[!0-9]*) return 1 ;; esac ;; *) return 1 ;; esac; }
# _clean TEXT: TEXT with control characters shown as "?", so it can't forge a log line.
_clean() { printf '%s' "${1//[[:cntrl:]]/?}"; }
# _one_line TEXT: TEXT with CR and LF written as \r and \n (dry-run argv lines).
_one_line() {
  local s="$1" cr='\r' lf='\n'
  s="${s//$'\r'/"$cr"}"
  s="${s//$'\n'/"$lf"}"
  printf '%s' "$s"
}
# _whole VALUE WHAT: VALUE as a decimal whole number, or die.
_whole() {
  case "$1" in '' | *[!0-9]*) sf_die "$2 must be a whole number, got '$(_clean "$1")'" ;; esac
  [ "${#1}" -le 9 ] || sf_die "$2 is too large: $1"
  printf '%s\n' "$((10#$1))"
}

if [ -z "$opt_role" ]; then
  [ "$opt_due" = 1 ] || sf_die "--role ROLE or --due is required (see --help)"
  for o in $given; do
    case "$o" in --config | --tree) ;; *) sf_die "--due without --role takes only --dry-run, --config and --tree (got $o)" ;; esac
  done
else
  _in_list "$opt_role" "$ALL_ROLES" || sf_die "unknown role '$(_clean "$opt_role")' (one of: $ALL_ROLES)"
  ! _given --feature || [ "$opt_role" = build-feature ] || sf_die "--feature is only for build-feature"
  ! _given --issue || [ "$opt_role" = bug-fix ] || [ "$opt_role" = perf ] || sf_die "--issue is only for bug-fix and perf"
  ! _given --idea || [ "$opt_role" = intake ] || [ "$opt_role" = build ] || sf_die "--idea is only for intake and build"
  if _given --pr; then
    case "$opt_role" in babysit | ship | verify) ;; *) sf_die "--pr is only for babysit, ship and verify" ;; esac
    _number_ok "$opt_pr" || sf_die "--pr needs a PR number, got '$(_clean "$opt_pr")'"
  fi
  if _given --feature; then _feature_ok "$opt_feature" || sf_die "--feature needs an id like F3, got '$(_clean "$opt_feature")'"; fi
  if _given --issue; then _number_ok "$opt_issue" || sf_die "--issue needs an issue number, got '$(_clean "$opt_issue")'"; fi
  [ "$opt_role" != verify ] || _given --pr || sf_die "verify needs --pr N"
  [ "$opt_due" = 0 ] || _is_standing "$opt_role" || sf_die "--due is only for the standing roles ($STANDING_ROLES)"
fi
ROLE="$opt_role"

# The tools pinned above must exist now: a name `hash` could not find would be looked up in
# PATH again after the agent ran, where it may have planted one. gh is needed only online.
sf_need bash git jq awk sed tr head tail cat date mktemp rm mv sleep grep od mkdir cp dirname basename
if [ "$SF_MSYS" = 1 ]; then sf_need cygpath; fi
if ! _offline; then sf_need gh; fi

# The hash table pins the tools for this shell only. Every process it starts looks its own
# tools up in PATH again: worktree.sh in the exit trap, git's helpers (ssh, credential
# helpers) and each role of a --due run start after an agent ran, and would find what it
# planted (with the tokens in their environment). So run-agent's PATH starts with the pinned
# tools' directories, in the order PATH had them: no directory before a tool's own held that
# tool when it was pinned. The harness alone gets the PATH run-agent was started with
# (RA_HARNESS_PATH; the roles of a --due run get it from that run as SF_RA_HARNESS_PATH).
RA_PINS=() # NAME=PATH of each pinned tool
# _abs_entries LIST: the absolute entries of the :-separated LIST, as common.sh keeps PATH's.
_abs_entries() {
  local rest="$1:" e out=""
  while [ -n "$rest" ]; do
    e="${rest%%:*}"
    rest="${rest#*:}"
    case "$e" in /*) out="${out:+$out:}$e" ;; esac
  done
  printf '%s' "$out"
}
# _repin: pin every tool again (assigning PATH empties the hash table).
_repin() {
  local kv
  for kv in ${RA_PINS[@]+"${RA_PINS[@]}"}; do hash -p "${kv#*=}" "${kv%%=*}"; done
}
# _pin_path: RA_PINS from the hash table, then PATH = the pinned tools' directories (in PATH
# order, each once), then PATH's other entries.
_pin_path() {
  local t p d dirs=":" rest e n front=":" back=""
  # shellcheck disable=SC2086 # a fixed list of names
  while IFS="$TAB" read -r t p; do
    if [ -z "$p" ]; then # a bare path (hash -t prints NAME<TAB> only before several names)
      p="$t"
      t="${p##*/}"
    fi
    case "$p" in /*/*) ;; *) continue ;; esac
    RA_PINS+=("$t=$p")
    d="${p%/*}"
    case "$dirs" in *":$d:"*) ;; *) dirs="$dirs$d:" ;; esac
  done <<EOF
$(hash -t $RA_TOOLS 2>/dev/null)
EOF
  rest="$PATH:"
  while [ -n "$rest" ]; do
    e="${rest%%:*}"
    rest="${rest#*:}"
    n="$e"
    while [ "${#n}" -gt 1 ] && [ "${n%/}" != "$n" ]; do n="${n%/}"; done
    case "$dirs" in
      *":$n:"*)
        front="$front$n:"
        dirs="${dirs/":$n:"/:}"
        ;;
      *)
        case "$front" in *":$n:"*) ;; *) back="${back:+$back:}$e" ;; esac
        ;;
    esac
  done
  # A pinned directory that PATH spells differently goes last among them.
  front="$front${dirs#:}"
  front="${front#:}"
  front="${front%:}"
  # (Never an empty entry: that would mean the current directory.)
  if [ -n "$front" ] && [ -n "$back" ]; then PATH="$front:$back"; else PATH="$front$back"; fi
  export PATH
  _repin
}
RA_HARNESS_PATH=$(_abs_entries "${SF_RA_HARNESS_PATH:-$PATH}")
unset SF_RA_HARNESS_PATH
# The roles of a --due run: that run already looked at the gh login's scopes (_scope_warning).
RA_SCOPE_CHECKED=0
[ "${SF_RA_SCOPE_CHECKED:-}" != 1 ] || RA_SCOPE_CHECKED=1
unset SF_RA_SCOPE_CHECKED
_pin_path

# --- config, main checkout and FACTORY_AGENT_ENV (all resolved before leaving the caller's cwd) ---

cfg="${opt_config:-${FACTORY_CONFIG:-}}"
if [ -n "$cfg" ]; then
  case "$cfg" in /* | [A-Za-z]:[\\/]*) ;; *) cfg="$PWD/$cfg" ;; esac
  sf_config_load "$cfg"
else
  sf_config_load
fi
CFG="$SF_CONFIG_FILE"

if [ -n "${FACTORY_WORKTREE_ROOT:-}" ]; then
  case "$FACTORY_WORKTREE_ROOT" in /* | [A-Za-z]:[\\/]*) ;; *) FACTORY_WORKTREE_ROOT="$PWD/$FACTORY_WORKTREE_ROOT" ;; esac
  export FACTORY_WORKTREE_ROOT
fi

# FACTORY_AGENT_ENV: a readable file, or the KEY=VALUE lines themselves. Lines are parsed,
# never evaluated; only ^[A-Za-z_][A-Za-z0-9_]*= lines count.
AENV_PAIRS=() # NAME=VALUE strings
AENV_N=0
_read_agent_env() {
  local v="${FACTORY_AGENT_ENV:-}" text line name re='^[A-Za-z_][A-Za-z0-9_]*='
  [ -n "$v" ] || return 0
  if [ -f "$v" ]; then
    text=$(cat -- "$v") || sf_die "cannot read the FACTORY_AGENT_ENV file"
  else
    case "$v" in
      *"$NL"* | *=*) text="$v" ;;
      *) sf_die "FACTORY_AGENT_ENV is neither a readable file nor KEY=VALUE lines" ;;
    esac
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    [[ $line =~ $re ]] || continue
    name="${line%%=*}"
    # run-agent sets the agent's identity for every run, and ship.sh tells writer from
    # shipper by it: FACTORY_AGENT_ENV may not set any of these names.
    case "$name" in
      FACTORY_AGENT_ID | GIT_AUTHOR_* | GIT_COMMITTER_*)
        sf_warn "FACTORY_AGENT_ENV: ignored $name (run-agent sets the agent identity for every run)"
        continue
        ;;
    esac
    AENV_PAIRS+=("$line")
    AENV_N=$((AENV_N + 1))
  done <<EOF
$text
EOF
  [ "$AENV_N" -gt 0 ] || sf_warn "FACTORY_AGENT_ENV holds no KEY=VALUE lines"
  # The secrets are for the harness alone: no other process run-agent starts (git and its
  # hooks, gh, worktree.sh) gets them.
  unset FACTORY_AGENT_ENV
}

start="${opt_tree:-.}"
[ -d "$start" ] || sf_die "no such directory: $start"
common=$(cd "$start" && git rev-parse --git-common-dir 2>/dev/null) || sf_die "not inside a git repository: $start"
common=$(cd "$start" && cd "$common" && pwd) || sf_die "cannot resolve the git directory of $start"
[ "$(basename "$common")" = .git ] || sf_die "$start is not a checkout with a .git directory"
MAIN=$(dirname "$common")
REPO_NAME=$(basename "$MAIN")
REPO_NAME="${REPO_NAME%.git}"
WT_ROOT="${FACTORY_WORKTREE_ROOT:-$(dirname "$MAIN")/.sf-wt}"
WT_ROOT="${WT_ROOT%/}"
REMOTE=$(sf_remote)
BASE=$(sf_cfg base_branch main) || exit 2
BASE="${BASE#refs/heads/}"
git check-ref-format --branch "$BASE" >/dev/null 2>&1 || sf_die "invalid base_branch '$(_clean "$BASE")'"
if [ -n "$ROLE" ]; then
  _read_agent_env
elif [ -n "${FACTORY_AGENT_ENV:-}" ] && [ -f "$FACTORY_AGENT_ENV" ]; then
  # --due alone: each role runs as a child from the main checkout, so a relative file path
  # is made absolute here, while it still means what the caller meant.
  case "$FACTORY_AGENT_ENV" in /* | [A-Za-z]:[\\/]*) ;; *) FACTORY_AGENT_ENV="$PWD/$FACTORY_AGENT_ENV" ;; esac
  export FACTORY_AGENT_ENV
fi
cd "$MAIN"

# --- state (the exit trap reads it) -----------------------------------------------------------

TMPD=""
JUDGE_SCRIPTS=""
JUDGE_CFG=""
JUDGE_TEMPLATE=""
RUN_START=$(sf_now)
RUN_ID=""
AGENT_ID=""
MODE=""          # claim | resume | hunt | verify | main
KEY=""
TASK=""
CANDIDATES=""    # build-feature: the ready ids to try, in order
PR_TITLE=""
PR_NUM=""
PR_URL=""
PR_OID=""        # the PR's head SHA (verify)
HEAD_REF=""
WT=""            # claimed or resumed worktree of a writer (the exit trap saves its work)
THROW_WT=""      # throwaway worktree for hunt / measure / verify (removed at exit)
WORKDIR=""       # where the harness runs
FETCHED=0
CLAIMED=0
CLAIM_SHA=""
BOOK_SHA=""
LOCKED=0
LOG_READ=0
LOG_ISSUE=""
LOG_COMMENT=""
LOG_LAST_START=""
LOG_START=""
HARNESS_ARGV=()
HARNESS_WRAPPER=""  # argv[1] when argv[0] is bash or sh and argv[1] a wrapper script
HARNESS_BIN=""      # the binary the preflight looks for: argv[0], or the command after the wrapper
HARNESS_JOB=""
RESUME_LOCK=""      # resume-<key> while this run holds that lock (the exit trap releases it)
RESUME_AGENT=""     # the agent id of the resume lock (the agent id of the resumed run)
INTAKE_PLAN_LOOKED=0 # 1 once the stale factory/intake and factory/plan drafts were looked for
RUN_REASON=""
PROMPT=""
AGENT_MINS=""    # limits.agent_timeout_minutes, once validated
RA_REPO=""       # [HOST/]OWNER/REPO (GH_REPO), resolved before any agent code runs (online)

# --- small helpers ---------------------------------------------------------------------------------

_nothing() {
  sf_log "nothing to do: $1"
  exit 0
}

_is_writer() { _in_list "$ROLE" "$WRITER_ROLES"; }

# _agent_minutes: AGENT_MINS = limits.agent_timeout_minutes (default 45), at least 1, or die.
_agent_minutes() {
  local m
  [ -z "$AGENT_MINS" ] || return 0
  m=$(sf_cfg limits.agent_timeout_minutes 45) || exit 2
  m=$(_whole "$m" limits.agent_timeout_minutes) || exit 2
  [ "$m" -gt 0 ] || sf_die "limits.agent_timeout_minutes must be at least 1"
  AGENT_MINS="$m"
}

_new_agent_id() { AGENT_ID="$ROLE-$RUN_ID-$(sf_random_hex 4)"; }

_wt_script() { # _wt_script SUBCOMMAND ARGS...: the snapshot's worktree.sh on the main checkout
  bash "$JUDGE_SCRIPTS/worktree.sh" "$@" --tree "$MAIN" --config "$JUDGE_CFG" </dev/null
}

# _git_bk ARGS...: git for run-agent's own bookkeeping (the base fetch, PR link and wip
# commits, their pushes, the throwaway worktrees), like worktree.sh's. --no-verify alone still
# runs prepare-commit-msg, post-commit, post-index-change and reference-transaction hooks (a
# fetch runs the last one); with a relative core.hooksPath (husky) those come from the agent's
# branch, or from the main checkout's work tree, where ship and handoff agents work, and they
# would run with the tokens in run-agent's environment. No project hook runs, nothing is signed.
# Nor does a core.fsmonitor command (status, add and commit run it), which the agent can set in
# the repository's config as easily as a hook (worktree.sh turns it off the same way).
_git_bk() { sf_git_bk -c core.fsmonitor=false "$@"; }

_fetch_base() {
  local i
  [ "$FETCHED" = 0 ] || return 0
  for i in 1 2 3; do
    if _git_bk fetch -q --no-tags "$REMOTE" "+refs/heads/$BASE:refs/remotes/$REMOTE/$BASE" </dev/null >&2; then
      FETCHED=1
      return 0
    fi
    [ "$i" -lt 3 ] && sleep 1
  done
  sf_die "git fetch $REMOTE $BASE failed"
}

# _remote_sha BRANCH: SHA of refs/heads/BRANCH on the remote ("" if absent); 2 if unreadable.
_remote_sha() {
  local out
  out=$(_git_bk ls-remote "$REMOTE" "refs/heads/$1" </dev/null) || return 2
  printf '%s\n' "$out" | awk -v r="refs/heads/$1" '$2 == r { print $1; exit }'
}

# _clean_tree DIR: true only when git status in DIR worked and shows nothing. (status may
# rewrite the index, which runs a post-index-change hook: hence _git_bk.)
_clean_tree() {
  local out
  out=$(_git_bk -C "$1" status --porcelain 2>/dev/null) || return 1
  [ -z "$out" ]
}

# _valid_key KEY: a claim key (worktree.sh): F<n>, issue-<n>, perf-<n> (n without a leading
# zero), intake, plan or spike-<name>.
_valid_key() {
  local re='^(F[0-9]+|issue-[1-9][0-9]*|perf-[1-9][0-9]*|intake|plan|spike-[a-z0-9][a-z0-9-]*)$'
  [[ $1 =~ $re ]]
}

_sleep_short() { sleep 0.1 2>/dev/null || sleep 1; }

# _resolve_repo: RA_REPO and GH_REPO = the GitHub repository every gh call of this run means
# ([HOST/]OWNER/REPO): GH_REPO when the caller set it, else what `gh repo view` says in the
# main checkout. Called (online) before any agent code runs: afterwards the main checkout's
# remotes and git config are the agent's to write (worktrees share them), and gh resolving a
# repository from them would run git and could pick another repository. Dies with 2 when it
# can't be told.
_resolve_repo() {
  local out repo re='^([A-Za-z0-9][A-Za-z0-9.-]*/)?[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'
  [ -z "$RA_REPO" ] || return 0
  ! _offline || return 0
  if [ -n "${GH_REPO:-}" ]; then
    repo="$GH_REPO"
  else
    out=$(sf_gh repo view --json owner,name </dev/null) ||
      sf_die "could not tell which GitHub repository $MAIN belongs to (gh repo view)"
    # shellcheck disable=SC2016 # jq program
    repo=$(printf '%s\n' "$out" | sf_jq -r '
      if type == "object" and (.owner.login | type) == "string" and (.name | type) == "string"
      then .owner.login + "/" + .name else error("unexpected shape") end' 2>/dev/null) ||
      sf_die "could not parse the output of gh repo view"
  fi
  [[ $repo =~ $re ]] || sf_die "not a repository name ([HOST/]OWNER/REPO): $(_clean "$repo")"
  RA_REPO="$repo"
  GH_REPO="$repo"
  export GH_REPO
}

# _gh_late ARGS...: sf_gh for the calls made after the agent ran (the exit trap). It names the
# repository resolved before (GH_REPO) and starts in /, not in the main checkout, whose .git
# the agent could have rewritten. (If gh still runs git, PATH starts with the pinned git's
# directory: see _pin_path.)
_gh_late() {
  if [ -z "$RA_REPO" ]; then
    sf_gh "$@"
    return
  fi
  (
    cd / || exit 2
    export GH_REPO="$RA_REPO"
    sf_gh "$@"
  )
}

# --- the judging snapshot (step 1) ---------------------------------------------------------------

# _snapshot_judge: copy the judging copy's scripts, the PR body template and the loaded config
# into $TMPD/judge, before any agent code runs; every helper run-agent starts (worktree.sh,
# feature-map.sh, ship.sh, report.sh, the --due children) runs from that copy with that config.
# The agent can write the judging copy (same user; it is often the main checkout itself), and
# the exit trap (worktree.sh release and unlock) and the next --due child run after it: a
# rewritten worktree.sh, config or run-agent.sh would otherwise run with the tokens in our
# environment.
_snapshot_judge() {
  local d="$TMPD/judge" f
  local scripts=() lib=()
  for f in "$SF_SCRIPTS_DIR"/*.sh; do
    if [ -f "$f" ]; then scripts+=("$f"); fi
  done
  for f in "$SF_LIB_DIR"/*; do
    if [ -f "$f" ]; then lib+=("$f"); fi
  done
  if [ "${#scripts[@]}" -eq 0 ] || [ "${#lib[@]}" -eq 0 ]; then
    sf_die "the judging copy $SF_SCRIPTS_DIR has no scripts"
  fi
  if ! { mkdir -p "$d/scripts/lib" "$d/templates" && cp -- "${scripts[@]}" "$d/scripts/" &&
    cp -- "${lib[@]}" "$d/scripts/lib/" && cp -- "$CFG" "$d/factory.config.yaml"; }; then
    sf_die "cannot copy the judging copy to $d"
  fi
  if [ -f "$SF_FACTORY_ROOT/templates/pr-body.md" ]; then
    cp -- "$SF_FACTORY_ROOT/templates/pr-body.md" "$d/templates/pr-body.md" ||
      sf_die "cannot copy $SF_FACTORY_ROOT/templates/pr-body.md to $d"
  fi
  JUDGE_SCRIPTS="$d/scripts"
  JUDGE_CFG="$d/factory.config.yaml"
  JUDGE_TEMPLATE="$d/templates/pr-body.md"
}

# --- harness argv (step 1) ---------------------------------------------------------------------------

_harness_argv() {
  local cmd="" src="" i
  if [ "$ROLE" = verify ]; then
    cmd=$(sf_cfg review_harness_cmd none) || exit 2
    if sf_is_none "$cmd"; then cmd=""; else src=review_harness_cmd; fi
  fi
  if [ -z "$cmd" ] && [ -n "${FACTORY_HARNESS_CMD:-}" ]; then
    cmd="$FACTORY_HARNESS_CMD"
    src=FACTORY_HARNESS_CMD
  fi
  if [ -z "$cmd" ]; then
    cmd=$(sf_cfg harness_cmd) || exit 2
    src=harness_cmd
  fi
  ! sf_is_none "$cmd" || sf_die "harness_cmd is none; set it in $CFG or FACTORY_HARNESS_CMD"
  HARNESS_ARGV=()
  read -r -d '' -a HARNESS_ARGV <<<"$cmd" || true
  [ "${#HARNESS_ARGV[@]}" -gt 0 ] || sf_die "$src is empty"
  # A relative wrapper path (factory/harness/x.sh) is the main checkout's copy, never the copy
  # in the agent's worktree, which an earlier agent's branch (or the PR under review) could
  # have changed: as argv[0], or as the script bash or sh runs.
  case "${HARNESS_ARGV[0]}" in
    /* | [A-Za-z]:[\\/]*) ;;
    */*) HARNESS_ARGV[0]="$MAIN/${HARNESS_ARGV[0]}" ;;
  esac
  HARNESS_WRAPPER=""
  HARNESS_BIN="${HARNESS_ARGV[0]}"
  if [ "${#HARNESS_ARGV[@]}" -ge 2 ]; then
    case "${HARNESS_ARGV[0]}" in
      bash | sh | */bash | */sh | bash.exe | sh.exe | */bash.exe | */sh.exe)
        case "${HARNESS_ARGV[1]}" in
          -*) ;; # an option of bash itself (bash -x, bash -c): no wrapper
          /* | [A-Za-z]:[\\/]*) HARNESS_WRAPPER="${HARNESS_ARGV[1]}" ;;
          *)
            HARNESS_ARGV[1]="$MAIN/${HARNESS_ARGV[1]}"
            HARNESS_WRAPPER="${HARNESS_ARGV[1]}"
            ;;
        esac
        ;;
    esac
  fi
  # Behind a wrapper (bash factory/harness/x.sh HARNESS ARGS...), the binary the preflight looks
  # for is the command the wrapper runs: argv[2], or argv[3] after a "--" (auth-file.sh takes
  # one). A wrapper with nothing after it, or only options of its own (x.sh --flag), is the
  # harness itself: then the wrapper and its shell are what is looked for.
  if [ -n "$HARNESS_WRAPPER" ]; then
    i=2
    [ "${HARNESS_ARGV[2]:-}" != -- ] || i=3
    case "${HARNESS_ARGV[$i]:-}" in
      '' | -*) ;;
      *) HARNESS_BIN="${HARNESS_ARGV[$i]}" ;;
    esac
  fi
  sf_log "harness ($src): $(_clean "${HARNESS_ARGV[*]}")"
}

# --- stop switches (step 2) ---------------------------------------------------------------------

# _stop_switches: 0 when the factory may run; otherwise says "factory stopped" and returns 1.
_stop_switches() {
  local v
  if [ "${CI:-}" = true ]; then
    if [ "${FACTORY_ENABLED:-}" != true ]; then
      sf_log "factory stopped: FACTORY_ENABLED is not true"
      return 1
    fi
    if [ "${FACTORY_CI_AGENTS:-}" != true ]; then
      sf_log "factory stopped: FACTORY_CI_AGENTS is not true (CI agents are off)"
      return 1
    fi
    return 0
  fi
  if _offline; then
    [ "${FACTORY_ENABLED:-}" = true ] && return 0
    sf_log "factory stopped: FACTORY_ENABLED is not true (offline: read from the environment)"
    return 1
  fi
  if ! v=$(sf_gh variable get FACTORY_ENABLED </dev/null); then
    sf_log "factory stopped: the repo variable FACTORY_ENABLED could not be read"
    return 1
  fi
  v=$(printf '%s' "$v" | tr -d '[:space:]')
  [ "$v" = true ] && return 0
  sf_log "factory stopped: the repo variable FACTORY_ENABLED is not true"
  return 1
}

# _stopped_exit: a stopped factory ends the run (exit 0), except a dry run, which says so and
# goes on: it still writes nothing.
_stopped_exit() {
  [ "$opt_dry" = 1 ] || exit 0
  sf_log "factory stopped (dry run continues)"
}

# --- the gh login's scopes (PLAN 4.7) --------------------------------------------------------------

# _has_workflow_scope FILE KIND: "yes", "no" or "unknown": whether the gh output in FILE grants the
# workflow scope. KIND "status": `gh auth status` (the "Token scopes:" line of each account, except
# one marked "Active account: false"; an account runs from its "Logged in to" or "Failed to log in
# to" line to the next one); KIND "headers": `gh api -i user` (its X-OAuth-Scopes header).
_has_workflow_scope() {
  LC_ALL=C awk -v kind="$2" -v q="'" '
    function has_wf(s,   n, a, i) {
      gsub("[" q "\",]", " ", s)
      n = split(s, a, /[ \t]+/)
      for (i = 1; i <= n; i++) if (a[i] == "workflow") return 1
      return 0
    }
    function flush() {
      if (have && active != "false") { seen = 1; if (has_wf(scopes)) found = 1 }
      have = 0
    }
    { sub(/\r$/, "") }
    kind == "headers" && $0 == "" { exit }
    kind == "headers" && index(tolower($0), "x-oauth-scopes:") == 1 {
      seen = 1
      if (has_wf(substr($0, 16))) found = 1
    }
    kind == "status" && /(Logged in to|log in to) / { flush(); active = "" }
    kind == "status" && /Active account:/ { active = ($0 ~ /true/) ? "true" : "false" }
    kind == "status" && /Token scopes:/ { scopes = $0; sub(/^.*Token scopes:/, "", scopes); have = 1 }
    END { flush(); print (found ? "yes" : (seen ? "no" : "unknown")) }' "$1" 2>/dev/null || printf 'unknown\n'
}

# _scope_probe ARGS...: gh ARGS (at most 30 s) with the GitHub credentials the harness gets (step
# 10): the scrubbed names removed (GH_TOKEN, ...) and FACTORY_AGENT_ENV's lines added. An operator's
# GH_TOKEN never reaches the agent, whose gh then uses the stored login, unless FACTORY_AGENT_ENV
# passes it back. Runs in a subshell: nothing it sets stays.
_scope_probe() (
  local kv
  # --due alone: each role reads FACTORY_AGENT_ENV itself; here it only tells what they will get.
  [ -n "$ROLE" ] || _read_agent_env >/dev/null 2>&1 || exit 2
  # shellcheck disable=SC2086 # fixed list of variable names
  unset $SCRUBBED_ENV
  for kv in ${AENV_PAIRS[@]+"${AENV_PAIRS[@]}"}; do
    # shellcheck disable=SC2163 # kv holds NAME=VALUE; NAME is what gets exported
    export "$kv" 2>/dev/null || true
  done
  # (A PATH line empties the hash table: the pinned tools stay what runs.)
  _repin
  sf_run_timeout 30 sf_gh "$@" </dev/null
)

# _scope_warning: a local run (not CI, not offline) gives its agents the operator's own gh login
# (_scope_probe). When that login has the workflow scope, agents can push changes to
# .github/workflows: the barrier a FACTORY_TOKEN without the Workflows permission gives CI runs
# does not hold. Warns once per run (a --due run for all its roles), bounded in time, and never
# fails the run.
_scope_warning() {
  local out="$TMPD/gh-scopes.out" ans=unknown
  [ "$RA_SCOPE_CHECKED" = 0 ] || return 0
  RA_SCOPE_CHECKED=1
  [ "${CI:-}" != true ] || return 0
  ! _offline || return 0
  # (Through a file: sf_run_timeout's leftovers must not hold a pipe open.)
  if _scope_probe auth status >"$out" 2>&1 || [ -s "$out" ]; then
    ans=$(_has_workflow_scope "$out" status)
  fi
  if [ "$ans" = unknown ] && _scope_probe api -i user >"$out" 2>/dev/null; then
    ans=$(_has_workflow_scope "$out" headers)
  fi
  rm -f "$out" 2>/dev/null || true
  [ "$ans" = yes ] || return 0
  sf_warn "your gh login has the workflow scope: agents of local runs can push changes to .github/workflows, which CI's FACTORY_TOKEN (no Workflows permission) prevents; for unattended runs use a token without it"
  return 0
}

# --- role log on the factory:log issue (step 3) -------------------------------------------------

# _log_read: find the log issue (pinned first, else oldest) and this role's comment.
# Sets LOG_ISSUE ("" = none), LOG_COMMENT and LOG_LAST_START ("" = no usable entry).
# Returns 2 when GitHub could not be read.
_log_read() {
  local out row cid line2 now marker re
  LOG_READ=1
  LOG_ISSUE=""
  LOG_COMMENT=""
  LOG_LAST_START=""
  out=$(_gh_late issue list --label factory:log --state open --limit 100 --json number,isPinned,createdAt </dev/null) || {
    sf_warn "could not list the factory:log issues"
    return 2
  }
  row=$(printf '%s\n' "$out" | sf_jq -r '
    if type != "array" then error("not a list") else . end
    | sort_by([(.isPinned != true), (.createdAt // ""), .number])
    | if length == 0 then "" else (.[0].number | tostring) end') || {
    sf_warn "could not parse the factory:log issue list"
    return 2
  }
  _number_ok "$row" || {
    [ -z "$row" ] && return 0
    sf_warn "unexpected factory:log issue number"
    return 2
  }
  LOG_ISSUE="$row"
  out=$(_gh_late api "repos/{owner}/{repo}/issues/$LOG_ISSUE/comments" --paginate </dev/null) || {
    sf_warn "could not read the comments of the factory:log issue #$LOG_ISSUE"
    return 2
  }
  marker="<!-- factory:role-log role=$ROLE -->"
  # shellcheck disable=SC2016 # jq program
  row=$(printf '%s\n' "$out" | sf_jq -r -n --arg m "$marker" '
    first(inputs
      | if type == "array" then .[] else error("not a list") end
      | select(type == "object" and (.body | type) == "string")
      | select((.body | split("\n")[0] | rtrimstr("\r")) == $m)
      | [(.id | tostring), ((.body | split("\n")[1] // "") | rtrimstr("\r"))]
      | @tsv)') || {
    sf_warn "could not parse the comments of the factory:log issue #$LOG_ISSUE"
    return 2
  }
  [ -n "$row" ] || return 0
  cid="${row%%"$TAB"*}"
  line2="${row#*"$TAB"}"
  [ "$line2" != "$row" ] || line2=""
  _number_ok "$cid" || {
    sf_warn "unexpected role-log comment id"
    return 2
  }
  LOG_COMMENT="$cid"
  re='^last_start=([0-9]{1,12}) last_finish=([0-9]{1,12}|-) last_exit=([0-9]{1,3}|-) agent=[A-Za-z0-9._-]+$'
  if [[ $line2 =~ $re ]]; then
    LOG_LAST_START=$((10#${BASH_REMATCH[1]}))
    now=$(sf_now)
    if [ "$LOG_LAST_START" -gt $((now + 600)) ]; then
      sf_warn "the role log of $ROLE starts in the future; ignored"
      LOG_LAST_START=""
    fi
  else
    sf_warn "the role-log comment of $ROLE is malformed; treating it as missing"
  fi
}

# _log_write START FINISH EXIT: edit (or create) this role's comment. Warns on failure.
_log_write() {
  local body out id
  body="<!-- factory:role-log role=$ROLE -->${NL}last_start=$1 last_finish=$2 last_exit=$3 agent=$AGENT_ID"
  if [ -n "$LOG_COMMENT" ]; then
    if ! _gh_late api -X PATCH "repos/{owner}/{repo}/issues/comments/$LOG_COMMENT" -f "body=$body" </dev/null >/dev/null; then
      sf_warn "could not update the role-log comment of $ROLE"
      return 1
    fi
    return 0
  fi
  if ! out=$(printf '%s\n' "$body" | _gh_late issue comment "$LOG_ISSUE" --body-file -); then
    sf_warn "could not add the role-log comment of $ROLE to #$LOG_ISSUE"
    return 1
  fi
  id=$(printf '%s\n' "$out" | sed -n 's/.*#issuecomment-\([0-9][0-9]*\).*/\1/p' | head -n 1)
  LOG_COMMENT="$id"
}

_log_start() {
  _is_standing "$ROLE" || return 0
  if _offline; then
    sf_warn "offline: the role log is not written"
    return 0
  fi
  if [ "$LOG_READ" = 0 ]; then
    if ! _log_read; then
      sf_warn "the role log is not written for this run"
      return 0
    fi
  fi
  if [ -z "$LOG_ISSUE" ]; then
    sf_warn "no open factory:log issue (run bootstrap.sh); the role log is not written"
    return 0
  fi
  LOG_START=$(sf_now)
  _log_write "$LOG_START" - - || true
}

_log_finish() {
  [ -n "$LOG_START" ] || return 0
  [ -n "$LOG_COMMENT" ] || _log_read || return 0
  [ -n "$LOG_ISSUE" ] || return 0
  _log_write "$LOG_START" "$(sf_now)" "$1" || true
}

# _due_check: exits 0 when the role is not due (step 3).
_due_check() {
  local raw every age
  raw=$(sf_cfg "roles.$ROLE.every") || exit 2
  if sf_is_none "$raw"; then
    sf_log "$ROLE is not scheduled (roles.$ROLE.every: none)"
    exit 0
  fi
  every=$(sf_duration_seconds "$raw") || exit 2
  if _offline; then
    sf_warn "offline: the role log is not read, so $ROLE counts as due"
    return 0
  fi
  _log_read || sf_die "could not read the role log; not deciding whether $ROLE is due"
  if [ -z "$LOG_ISSUE" ]; then
    sf_warn "no open factory:log issue; $ROLE counts as due"
    return 0
  fi
  if [ -z "$LOG_LAST_START" ]; then
    sf_log "$ROLE has no role-log entry on #$LOG_ISSUE; due"
    return 0
  fi
  age=$(($(sf_now) - LOG_LAST_START))
  if [ "$age" -ge $((every - 1800)) ]; then
    sf_log "$ROLE is due: last start ${age}s ago (every $raw)"
    return 0
  fi
  sf_log "$ROLE is not due: last start ${age}s ago (every $raw)"
  exit 0
}

# --- --due without a role: every standing role that is due, each as its own run ------------

_due_all() {
  local r every child st worst=0 worst_rank=0 rank
  DUE_CHILD=""
  # _due_stop CODE: a stop of this run (cron, a supervisor or an operator signalling only this
  # process, or Ctrl-C) stops the role that is running, waits for its exit trap, starts no later
  # role and exits CODE. Each role runs in the background so that the signal reaches this trap
  # at once (bash runs traps only between foreground commands, and a foreground role can run
  # for limits.agent_timeout_minutes). The role gets TERM: a background job of a
  # non-interactive shell ignores SIGINT.
  _due_stop() {
    trap '' INT TERM HUP
    if [ -n "$DUE_CHILD" ]; then
      kill -TERM "$DUE_CHILD" 2>/dev/null || true
      wait "$DUE_CHILD" 2>/dev/null || true
    fi
    exit "$1"
  }
  TMPD=$(sf_mktemp_dir) || sf_die "cannot create a temporary directory"
  trap '[ -z "$TMPD" ] || rm -rf "$TMPD"' EXIT
  trap '_due_stop 143' TERM
  trap '_due_stop 130' INT
  trap '_due_stop 129' HUP
  _snapshot_judge
  _stop_switches || _stopped_exit
  # Once for every role (each child is told it was done).
  _scope_warning
  # Every role after the first starts after an agent ran: all of them name the repository
  # resolved now (GH_REPO, exported to the children), before any agent code runs.
  [ "$opt_dry" = 1 ] || _resolve_repo
  for r in $STANDING_ROLES; do
    every=$(sf_cfg "roles.$r.every" none) || exit 2
    if sf_is_none "$every"; then
      sf_log "$r: not scheduled (roles.$r.every is not set)"
      continue
    fi
    child=(--role "$r" --due --config "$JUDGE_CFG" --tree "$MAIN")
    [ "$opt_dry" = 0 ] || child+=(--dry-run)
    st=0
    # The role starts with this run's PATH (the pinned tools' directories first: an earlier
    # role's agent may have planted tools) and hands its harness the PATH this run was given.
    SF_RA_HARNESS_PATH="$RA_HARNESS_PATH" SF_RA_SCOPE_CHECKED="$RA_SCOPE_CHECKED" \
      bash "$JUDGE_SCRIPTS/run-agent.sh" "${child[@]}" </dev/null &
    DUE_CHILD=$!
    wait "$DUE_CHILD" || st=$?
    DUE_CHILD=""
    sf_log "$r: exit $st"
    case "$st" in
      129 | 130 | 143)
        # The child was stopped (SIGHUP/SIGINT/SIGTERM): a stop means stop, not "next role".
        sf_log "$r was stopped by a signal; the remaining standing roles are not run"
        exit "$st"
        ;;
    esac
    case "$st" in 0) rank=0 ;; 3) rank=1 ;; 1) rank=2 ;; 4) rank=3 ;; 2) rank=4 ;; *) rank=5 ;; esac
    if [ "$rank" -gt "$worst_rank" ]; then
      worst="$st"
      worst_rank="$rank"
    fi
  done
  exit "$worst"
}

# --- preflight (step 4; runs before anything is locked or claimed) ------------------------------

_preflight() {
  local install bench bin="$HARNESS_BIN"
  # The wrapper is a file of the main checkout (_harness_argv): one that is not there would only
  # fail at launch (exit 127), after the claim and the draft PR.
  # (The shell that runs the wrapper is looked for as well; harness_install is for the harness.)
  if [ -n "$HARNESS_WRAPPER" ] && ! command -v "${HARNESS_ARGV[0]}" >/dev/null 2>&1; then
    if [ "$opt_dry" = 1 ]; then
      sf_warn "harness binary not found: $(_clean "${HARNESS_ARGV[0]}") (a real run exits 2)"
    else
      sf_die "harness binary not found: $(_clean "${HARNESS_ARGV[0]}") (set harness_cmd or FACTORY_HARNESS_CMD)"
    fi
  fi
  if [ -n "$HARNESS_WRAPPER" ] && [ ! -f "$HARNESS_WRAPPER" ]; then
    if [ "$opt_dry" = 1 ]; then
      sf_warn "harness wrapper not found: $(_clean "$HARNESS_WRAPPER") (a real run exits 2)"
    else
      sf_die "harness wrapper not found: $(_clean "$HARNESS_WRAPPER") (set harness_cmd or FACTORY_HARNESS_CMD)"
    fi
  fi
  if ! command -v "$bin" >/dev/null 2>&1; then
    if [ "$opt_dry" = 1 ]; then
      sf_warn "harness binary not found: $(_clean "$bin") (a real run exits 2)"
    else
      install=none
      if [ "${CI:-}" = true ]; then install=$(sf_cfg harness_install none) || exit 2; fi
      sf_is_none "$install" &&
        sf_die "harness binary not found: $(_clean "$bin") (set harness_cmd or FACTORY_HARNESS_CMD)"
      _agent_minutes
      sf_log "harness $(_clean "$bin") not found; running harness_install"
      # With the PATH run-agent was given, as the harness gets it.
      (
        PATH="$RA_HARNESS_PATH"
        export PATH
        _repin
        sf_run_timeout $((AGENT_MINS * 60)) bash -c "$install" </dev/null >&2
      ) || sf_die "harness_install failed"
      # No `hash -r`: a name that was not found is not remembered, so command -v looks again,
      # and forgetting the table would undo the pinning of the tools.
      command -v "$bin" >/dev/null 2>&1 ||
        sf_die "harness binary still not found after harness_install: $(_clean "$bin")"
    fi
  fi
  if [ "$ROLE" = perf ] && [ -z "$opt_issue" ]; then
    bench=$(sf_cfg roles.perf.bench none) || exit 2
    ! sf_is_none "$bench" || _nothing "roles.perf.bench is none, so perf work is skipped"
  fi
}

# --- role lock (step 5) -------------------------------------------------------------------------

_lock_role() {
  local st=0
  _is_standing "$ROLE" || return 0
  # The lock outlives the harness's own timeout by 15 minutes: the claim, the PR and the exit
  # trap's work happen around the harness, under the same lock.
  _agent_minutes
  _wt_script lock "role-$ROLE" --agent "$AGENT_ID" --ttl-min $((AGENT_MINS + 15)) >&2 || st=$?
  case "$st" in
    0) LOCKED=1 ;;
    3)
      sf_log "role locked: another $ROLE run holds factory/lock/role-$ROLE"
      exit 0
      ;;
    *) sf_die "could not take the role lock role-$ROLE (worktree.sh exit $st)" ;;
  esac
}

_unlock_role() {
  [ "$LOCKED" = 1 ] || return 0
  _wt_script unlock "role-$ROLE" --agent "$AGENT_ID" >&2 || sf_warn "could not release the role lock role-$ROLE"
  LOCKED=0
}

# --- backpressure (step 6) -------------------------------------------------------------------------

# _backpressure: exits 0 (nothing to do) when finder work must wait.
_backpressure() {
  local max_i max_p n out
  if _offline; then
    sf_warn "offline: backpressure is not checked"
    return 0
  fi
  max_i=$(sf_cfg limits.open_agent_issues 10) || exit 2
  max_i=$(_whole "$max_i" limits.open_agent_issues) || exit 2
  max_p=$(sf_cfg limits.open_agent_prs 5) || exit 2
  max_p=$(_whole "$max_p" limits.open_agent_prs) || exit 2
  n=$(sf_gh issue list --label agent-filed --state open --limit 1000 --json number --jq length </dev/null) ||
    sf_die "could not count the open agent-filed issues"
  n=$(printf '%s' "$n" | tr -d '[:space:]')
  _number_ok "$n" || [ "$n" = 0 ] || sf_die "unexpected count of agent-filed issues"
  if [ "$n" -ge "$max_i" ]; then
    _nothing "backpressure: $n open agent-filed issues (limit $max_i), so $ROLE finder work waits"
  fi
  out=$(sf_gh pr list --state open --limit 1000 --json headRefName </dev/null) || sf_die "could not list the open PRs"
  n=$(printf '%s\n' "$out" | sf_jq -r '
    if type != "array" then error("not a list") else . end
    | [.[] | select((.headRefName // "") | tostring | startswith("factory/"))] | length') ||
    sf_die "could not parse the open PR list"
  if [ "$n" -ge "$max_p" ]; then
    _nothing "backpressure: $n open factory/* PRs (limit $max_p), so $ROLE finder work waits"
  fi
}

# --- reading the repository and GitHub for the pick (step 7) ----------------------------------------

# _spec_state: "none" (no factory/spec.md on origin/<base>), "raw" (a request: its first line is
# not the spec marker) or "marked" (a spec intake wrote).
_spec_state() {
  local ref="refs/remotes/$REMOTE/$BASE" first=""
  if [ "$(git cat-file -t "$ref:factory/spec.md" 2>/dev/null)" != blob ]; then
    printf 'none\n'
    return 0
  fi
  git show "$ref:factory/spec.md" >"$TMPD/spec.md" 2>/dev/null || sf_die "cannot read factory/spec.md on $REMOTE/$BASE"
  IFS= read -r first <"$TMPD/spec.md" || true
  first="${first#$'\357\273\277'}"
  first=$(sf_trim "${first%$'\r'}")
  if [ "$first" = "$SPEC_MARKER" ]; then printf 'marked\n'; else printf 'raw\n'; fi
}

# _load_map: origin/<base>'s factory/feature-map.json in $TMPD/map-base.json; 1 when there is none.
_load_map() {
  local ref="refs/remotes/$REMOTE/$BASE"
  [ ! -f "$TMPD/map-base.json" ] || return 0
  [ "$(git cat-file -t "$ref:factory/feature-map.json" 2>/dev/null)" = blob ] || return 1
  git show "$ref:factory/feature-map.json" >"$TMPD/map-base.tmp" 2>/dev/null ||
    sf_die "cannot read factory/feature-map.json on $REMOTE/$BASE"
  mv -f "$TMPD/map-base.tmp" "$TMPD/map-base.json" || sf_die "cannot write $TMPD/map-base.json"
}

# _map_is_empty: true when origin/<base> has no feature map, or one without features.
_map_is_empty() {
  local n
  _load_map || return 0
  n=$(sf_jq -r 'if (.features | type) == "array" then (.features | length) else error("no features list") end' \
    "$TMPD/map-base.json") || sf_die "factory/feature-map.json on $REMOTE/$BASE is not a feature map"
  [ "$n" = 0 ]
}

# _intake_questions_open: true when an open needs-human issue is titled "intake: ...".
_intake_questions_open() {
  local out n
  if _offline; then
    sf_warn "offline: open intake questions (needs-human issues) are not checked"
    return 1
  fi
  out=$(sf_gh issue list --label needs-human --state open --limit 500 --json number,title </dev/null) ||
    sf_die "could not list the open needs-human issues"
  n=$(printf '%s\n' "$out" | sf_jq -r '
    if type != "array" then error("not a list") else . end
    | [.[] | select((.title // "") | tostring | ascii_downcase | sub("^\\s+"; "") | startswith("intake:"))]
    | length') || sf_die "could not parse the open needs-human issues"
  case "$n" in '' | *[!0-9]*) sf_die "could not count the open intake questions" ;; esac
  [ "$n" -gt 0 ]
}

# _list_open_prs: the open PRs, once, in $TMPD/prs.json.
_list_open_prs() {
  local out
  [ ! -f "$TMPD/prs.json" ] || return 0
  _offline && sf_die "offline: $ROLE needs GitHub to list the open PRs (pass --pr N)"
  out=$(sf_gh pr list --state open --limit 100 \
    --json number,url,headRefName,headRefOid,isDraft,isCrossRepository,labels,mergeStateStatus,statusCheckRollup,createdAt \
    </dev/null) || sf_die "could not list the open PRs"
  printf '%s\n' "$out" | sf_jq -e 'type == "array"' >/dev/null 2>&1 || sf_die "could not parse the open PR list"
  printf '%s\n' "$out" >"$TMPD/prs.json" || sf_die "cannot write $TMPD/prs.json"
}

# _tip_time BRANCH: committer time (epoch) of the tip of BRANCH on the remote; 1 if unreadable.
_tip_time() {
  local t
  _git_bk fetch -q --no-tags "$REMOTE" "+refs/heads/$1:refs/remotes/$REMOTE/$1" </dev/null >&2 || return 1
  t=$(git log -1 --format=%ct "refs/remotes/$REMOTE/$1" 2>/dev/null) || return 1
  case "$t" in '' | *[!0-9]*) return 1 ;; esac
  printf '%s\n' "$t"
}

# _resume_agent_id KEY: the agent id of the run that resumes factory/KEY: this run's, except for
# build, which becomes the role of that key (intake or plan-features) with an id of that role.
_resume_agent_id() {
  case "$ROLE:$1" in
    build:intake) printf 'intake-%s-%s\n' "$RUN_ID" "$(sf_random_hex 4)" ;;
    build:plan) printf 'plan-features-%s-%s\n' "$RUN_ID" "$(sf_random_hex 4)" ;;
    *) printf '%s\n' "$AGENT_ID" ;;
  esac
}

# _resume_lock KEY PR LIMIT: take the lock resume-KEY (worktree.sh lock) before resuming the stale
# draft PR from factory/KEY, so parallel runs (build slots, a crontab and a CI run) never resume one
# draft together; the exit trap releases it. Returns 1 when another run holds it, and when the tip
# moved meanwhile (read again once the lock is ours: a run that held the lock may have pushed its
# work and released it since the PR list was read). Sets RESUME_LOCK and RESUME_AGENT. A dry run
# takes no lock: it only reads it (_resume_lock_dry).
_resume_lock() {
  local key="$1" head="factory/$1" id st=0 tip age
  id=$(_resume_agent_id "$key")
  _agent_minutes
  if [ "$opt_dry" = 1 ]; then
    _resume_lock_dry "$key" "$2" || return 1
    RESUME_AGENT="$id"
    return 0
  fi
  # Set before the lock is taken: a signal that arrives meanwhile is handled only once worktree.sh
  # returned, and the exit trap must then release the lock it took. (unlock --agent leaves a lock
  # that another run holds alone.)
  RESUME_LOCK="resume-$key"
  RESUME_AGENT="$id"
  _wt_script lock "resume-$key" --agent "$id" --ttl-min $((AGENT_MINS + 15)) >&2 || st=$?
  case "$st" in
    0) ;;
    3)
      RESUME_LOCK=""
      sf_log "another run is resuming the draft PR #$2 ($head: it holds factory/lock/resume-$key); trying the next one"
      return 1
      ;;
    *) sf_die "could not take the resume lock resume-$key (worktree.sh exit $st)" ;;
  esac
  if ! tip=$(_tip_time "$head"); then
    sf_warn "cannot read the tip of $head again; the draft PR #$2 is not resumed"
    _unlock_resume
    return 1
  fi
  age=$(($(sf_now) - tip))
  if [ "$age" -le "$3" ]; then
    sf_log "the draft PR #$2 ($head) moved ${age}s ago, while this run took its resume lock; not resumed"
    _unlock_resume
    return 1
  fi
  return 0
}

# _resume_lock_dry KEY PR: what worktree.sh lock would say about resume-KEY, read without taking
# it. 1 when another run took it less than its TTL (limits.agent_timeout_minutes + 15) ago: then
# a real run tries the next stale draft, and so does the dry run's pick.
_resume_lock_dry() {
  local name="resume-$1" sha t age
  sha=$(_remote_sha "factory/lock/$name") || sf_die "cannot read the lock $name from $REMOTE"
  if [ -n "$sha" ]; then
    if t=$(_tip_time "factory/lock/$name"); then
      age=$(($(sf_now) - t))
      if [ "$age" -lt $(((AGENT_MINS + 15) * 60)) ]; then
        sf_log "dry run: another run is resuming the draft PR #$2 (factory/$1: it holds factory/lock/$name); a real run tries the next one"
        return 1
      fi
      sf_log "dry run: would take over the stale resume lock $name (${age}s old)"
      return 0
    fi
    # Released between the two reads, or unreadable.
    sha=$(_remote_sha "factory/lock/$name") || sf_die "cannot read the lock $name from $REMOTE"
    [ -z "$sha" ] || sf_die "cannot read the lock $name from $REMOTE"
  fi
  sf_log "dry run: would take the resume lock $name"
}

_unlock_resume() {
  [ -n "$RESUME_LOCK" ] || return 0
  _wt_script unlock "$RESUME_LOCK" --agent "$RESUME_AGENT" >&2 || sf_warn "could not release the resume lock $RESUME_LOCK"
  RESUME_LOCK=""
}

# _writer_resume KEY_RE: the oldest open draft PR (from this repository) whose branch is
# factory/<KEY_RE> and whose tip is older than limits.agent_timeout_minutes + 15 minutes: its
# writer is gone; the first of them whose resume lock this run takes (_resume_lock). Sets
# MODE=resume, KEY, PR_NUM, PR_URL, HEAD_REF and RESUME_AGENT; 1 when there is none.
# (Called as a condition, so every error is handled explicitly.)
_writer_resume() {
  local re="$1" rows row num head url key limit tip age
  if _offline; then
    sf_log "offline: stale draft PRs are not looked for"
    return 1
  fi
  _list_open_prs
  # shellcheck disable=SC2016 # jq program
  rows=$(sf_jq -r --arg re "^factory/($re)\$" '
    [.[] | select(type == "object" and .isCrossRepository != true and .isDraft == true)
         | select((.headRefName // "") | tostring | test($re))]
    | sort_by([(.createdAt // ""), .number]) | .[]
    | [(.number | tostring), .headRefName, (.url // "" | tostring)]
    | map(gsub("[[:cntrl:]]"; "?")) | join("\u001f")' "$TMPD/prs.json") ||
    sf_die "could not parse the open PR list"
  _agent_minutes
  limit=$(((AGENT_MINS + 15) * 60))
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    IFS=$'\037' read -r num head url <<EOF
$row
EOF
    _number_ok "$num" || sf_die "unexpected PR number in the PR list"
    key="${head#factory/}"
    _valid_key "$key" || continue
    if ! tip=$(_tip_time "$head"); then
      sf_warn "cannot read the tip of $head; the draft PR #$num is not resumed"
      continue
    fi
    age=$(($(sf_now) - tip))
    if [ "$age" -le "$limit" ]; then
      sf_log "the draft PR #$num ($head) moved ${age}s ago; its writer may still be at work"
      continue
    fi
    _resume_lock "$key" "$num" "$limit" || continue
    PR_NUM="$num"
    HEAD_REF="$head"
    KEY="$key"
    MODE=resume
    _set_pr_url "$url"
    sf_log "resuming the stale draft PR #$num ($head, tip ${age}s old)"
    return 0
  done <<EOF
$rows
EOF
  return 1
}

_set_pr_url() {
  local re='^https://[^[:space:][:cntrl:]]+$'
  PR_URL=""
  if [[ $1 =~ $re ]]; then PR_URL="$1"; fi
}

# _pr_view: HEAD_REF, PR_URL and PR_OID of PR_NUM; nothing to do when it is closed.
_pr_view() {
  local out row state cross url oid
  _offline && sf_die "offline: $ROLE needs GitHub to read PR #$PR_NUM"
  out=$(sf_gh pr view "$PR_NUM" --json number,url,headRefName,headRefOid,state,isCrossRepository </dev/null) ||
    sf_die "could not read PR #$PR_NUM"
  # Fields are joined with US (0x1f), not TAB: IFS whitespace would merge an empty field away.
  row=$(printf '%s\n' "$out" | sf_jq -r '
    [(.state // ""), (.isCrossRepository == true), (.headRefName // ""), (.url // ""), (.headRefOid // "")]
    | map(tostring | gsub("[[:cntrl:]]"; "?")) | join("\u001f")') ||
    sf_die "could not parse PR #$PR_NUM"
  IFS=$'\037' read -r state cross HEAD_REF url oid <<EOF
$row
EOF
  [ "$state" = OPEN ] || _nothing "PR #$PR_NUM is not open"
  [ "$cross" = false ] || sf_die "PR #$PR_NUM comes from a fork; run-agent only works on this repository's factory/* branches"
  _set_pr_url "$url"
  PR_OID=""
  if [[ $oid =~ ^[0-9a-f]{40}$ ]]; then PR_OID="$oid"; fi
}

# _key_from_head: KEY from HEAD_REF (factory/<key>), or die.
_key_from_head() {
  case "$HEAD_REF" in
    factory/*) KEY="${HEAD_REF#factory/}" ;;
    *) sf_die "PR #$PR_NUM's branch '$(_clean "$HEAD_REF")' is not a factory/* branch" ;;
  esac
  _valid_key "$KEY" || sf_die "PR #$PR_NUM's branch '$(_clean "$HEAD_REF")' is not a factory/<key> branch"
}

# --- picking the task (step 7) ------------------------------------------------------------------------

_pick_build() {
  local state
  _fetch_base
  # Before anything else: a stale draft from factory/intake or factory/plan (its writer is gone).
  # The run becomes the role of that key, with an agent id of that role (_resume_agent_id).
  if _resume_intake_plan 'intake|plan'; then
    if [ "$KEY" = intake ]; then ROLE=intake; else ROLE=plan-features; fi
    AGENT_ID="$RESUME_AGENT"
    sf_log "build: the stale draft PR #$PR_NUM from factory/$KEY is resumed first, so the stage is $ROLE"
    if [ -n "$opt_idea" ] && [ "$ROLE" != intake ]; then sf_warn "--idea is ignored: the build stage is $ROLE"; fi
    return 0
  fi
  state=$(_spec_state) || exit 2
  case "$state" in
    marked)
      if _map_is_empty; then
        if _intake_questions_open; then
          _nothing "build: the feature map is empty and intake questions are open (needs-human issues titled \"intake: ...\")"
        fi
        _set_stage plan-features "a spec and an empty feature map"
      else
        _set_stage build-feature "a spec and a feature map"
      fi
      ;;
    raw) _set_stage intake "factory/spec.md is a raw request" ;;
    *) _set_stage intake "no factory/spec.md" ;;
  esac
  if [ -n "$opt_idea" ] && [ "$ROLE" != intake ]; then sf_warn "--idea is ignored: the build stage is $ROLE"; fi
  _pick_task
}

_set_stage() { # _set_stage ROLE WHY
  ROLE="$1"
  sf_log "build: $2 on $REMOTE/$BASE, so the stage is $1"
  _new_agent_id
}

# _resume_intake_plan KEY_RE: resume the oldest stale draft from factory/intake or factory/plan
# (KEY_RE) before anything else, and set its TASK and PR_TITLE. They are looked for once: build
# looks for both before it picks its stage, and its stage does not look again.
_resume_intake_plan() {
  [ "$INTAKE_PLAN_LOOKED" = 0 ] || return 1
  INTAKE_PLAN_LOOKED=1
  _writer_resume "$1" || return 1
  if [ "$KEY" = intake ]; then
    PR_TITLE="docs(factory): spec"
    TASK="Finish factory/spec.md from the idea or request this draft PR started from"
    if [ -n "$opt_idea" ]; then
      sf_warn "--idea is ignored: the stale draft PR #$PR_NUM from factory/intake is resumed first"
    fi
  else
    PR_TITLE="docs(factory): feature map"
    TASK="Plan the features of factory/spec.md into factory/feature-map.json"
  fi
  return 0
}

_pick_intake() {
  local state
  _fetch_base
  _resume_intake_plan intake && return 0
  KEY=intake
  MODE=claim
  PR_TITLE="docs(factory): spec"
  if [ -n "$opt_idea" ]; then
    TASK="Turn this idea into factory/spec.md: $opt_idea"
    return 0
  fi
  state=$(_spec_state) || exit 2
  case "$state" in
    raw) TASK="Turn the request in factory/spec.md into the spec" ;;
    marked) _nothing "factory/spec.md on $REMOTE/$BASE is already a spec (its first line is $SPEC_MARKER); intake needs --idea" ;;
    *) _nothing "intake needs --idea or a request in factory/spec.md on $REMOTE/$BASE" ;;
  esac
}

_pick_plan() {
  local state
  _fetch_base
  _resume_intake_plan plan && return 0
  state=$(_spec_state) || exit 2
  [ "$state" = marked ] ||
    _nothing "plan-features needs a spec on $REMOTE/$BASE (factory/spec.md whose first line is $SPEC_MARKER)"
  KEY=plan
  MODE=claim
  PR_TITLE="docs(factory): feature map"
  TASK="Plan the features of factory/spec.md into factory/feature-map.json"
}

# _set_feature_task ID [resume]: KEY, PR_TITLE and TASK for feature ID (its title from the map
# on origin/<base>). A resumed feature that is not in that map keeps a generic title.
_set_feature_task() {
  local id="$1" title=""
  if _load_map; then
    # shellcheck disable=SC2016 # jq program
    title=$(sf_jq -r --arg id "$id" '[.features[]? | select(.id == $id) | .title | tostring][0] // ""' \
      "$TMPD/map-base.json") || sf_die "cannot read the feature map on $REMOTE/$BASE"
  elif [ "${2:-}" != resume ]; then
    sf_die "no factory/feature-map.json on $REMOTE/$BASE"
  fi
  title="${title//[[:cntrl:]]/ }"
  if [ -z "$title" ]; then
    [ "${2:-}" = resume ] || sf_die "no feature $id in the feature map on $REMOTE/$BASE"
    title="feature $id"
  fi
  KEY="$id"
  PR_TITLE="feat($id): ${title:0:200}"
  TASK="Build feature $id: ${title:0:200}. Run bash scripts/feature-map.sh context $id for its acceptance criteria and context"
}

_pick_build_feature() {
  local ids st=0 id n=0
  _fetch_base
  MODE=claim
  if [ -n "$opt_feature" ]; then
    CANDIDATES="$opt_feature"
    _set_feature_task "$opt_feature"
    return 0
  fi
  if _writer_resume 'F[0-9]+'; then
    _set_feature_task "$KEY" resume
    return 0
  fi
  ids=$(bash "$JUDGE_SCRIPTS/feature-map.sh" next --all --ref "$REMOTE/$BASE" --live --tree "$MAIN" --config "$JUDGE_CFG" </dev/null) || st=$?
  case "$st" in
    0) ;;
    3) _nothing "no feature is ready (waiting, claimed or blocked)" ;;
    4) _nothing "every feature is done" ;;
    5) _nothing "the feature map is empty" ;;
    *) sf_die "feature-map.sh next failed (exit $st)" ;;
  esac
  CANDIDATES=""
  while IFS= read -r id; do
    id="${id%$'\r'}"
    [ -n "$id" ] || continue
    _feature_ok "$id" || sf_die "feature-map.sh next printed an unexpected id"
    CANDIDATES="${CANDIDATES:+$CANDIDATES }$id"
    n=$((n + 1))
    [ "$n" -lt "$CLAIM_TRIES" ] || break
  done <<EOF
$ids
EOF
  [ -n "$CANDIDATES" ] || sf_die "feature-map.sh next printed no feature id"
  _set_feature_task "${CANDIDATES%% *}"
}

_issue_key() { if [ "$ROLE" = perf ]; then printf 'perf-%s\n' "$1"; else printf 'issue-%s\n' "$1"; fi; }

_set_issue_task() { # _set_issue_task N TITLE
  local title="${2//[[:cntrl:]]/ }"
  KEY=$(_issue_key "$1")
  [ -n "$title" ] || title="issue $1"
  if [ "$ROLE" = bug-fix ]; then
    PR_TITLE="fix(#$1): ${title:0:200}"
    TASK="Fix issue #$1 (read it with: gh issue view $1)"
  else
    PR_TITLE="perf(#$1): ${title:0:200}"
    TASK="Fix performance issue #$1 (read it with: gh issue view $1)"
  fi
}

_pick_issue_role() {
  local out rows row n held title state st max key re
  MODE=claim
  if [ -n "$opt_issue" ]; then
    title=""
    if ! _offline; then
      out=$(sf_gh issue view "$opt_issue" --json number,title,state </dev/null) || sf_die "could not read issue #$opt_issue"
      row=$(printf '%s\n' "$out" | sf_jq -r '"\(.state)\t\(.title | tostring | gsub("[[:cntrl:]]"; " "))"') ||
        sf_die "could not parse issue #$opt_issue"
      state="${row%%"$TAB"*}"
      title="${row#*"$TAB"}"
      [ "$state" = OPEN ] || _nothing "issue #$opt_issue is not open"
    fi
    _set_issue_task "$opt_issue" "$title"
    return 0
  fi
  if [ "$ROLE" = perf ]; then re='perf-[0-9]+'; else re='issue-[0-9]+'; fi
  if _writer_resume "$re"; then
    _set_issue_task "${KEY#*-}" ""
    return 0
  fi
  if _offline; then
    sf_warn "offline: open role:$ROLE issues are not listed"
  else
    out=$(sf_gh issue list --label "role:$ROLE" --state open --limit 100 --json number,title,createdAt,labels </dev/null) ||
      sf_die "could not list the open role:$ROLE issues"
    # Fields are joined with US (0x1f): IFS whitespace would merge an empty field away.
    rows=$(printf '%s\n' "$out" | sf_jq -r '
      if type != "array" then error("not a list") else . end
      | sort_by([(.createdAt // ""), .number]) | .[]
      | [(.number | tostring),
         ([.labels[]? | (.name // "") | tostring | ascii_downcase]
           | any(. == "needs-human" or . == "status:blocked") | tostring),
         (.title | tostring)]
      | map(gsub("[[:cntrl:]]"; " ")) | join("\u001f")') ||
      sf_die "could not parse the role:$ROLE issue list"
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      IFS=$'\037' read -r n held title <<EOF
$row
EOF
      _number_ok "$n" || continue
      if [ "$held" = true ]; then
        sf_log "issue #$n is labeled needs-human or status:blocked; skipped"
        continue
      fi
      key=$(_issue_key "$n")
      st=0
      _wt_script is-live "$key" >/dev/null 2>"$TMPD/is-live.err" || st=$?
      case "$st" in
        3)
          _set_issue_task "$n" "$title"
          return 0
          ;;
        0) sf_log "issue #$n is claimed (live claim); skipped" ;;
        1) sf_log "issue #$n has a dead claim (babysit releases it); skipped" ;;
        *)
          sed 's/^/  | /' "$TMPD/is-live.err" >&2
          sf_warn "cannot tell whether issue #$n is claimed (worktree.sh is-live exit $st); skipped"
          ;;
      esac
    done <<EOF
$rows
EOF
  fi
  # Nothing to fix: finder work, unless backpressure says wait.
  _backpressure
  MODE=hunt
  KEY=""
  if [ "$ROLE" = bug-fix ]; then
    max=$(sf_cfg roles.bug-fix.hunt_max_issues 1) || exit 2
    max=$(_whole "$max" roles.bug-fix.hunt_max_issues) || exit 2
    TASK="HUNT mode: no open role:bug-fix issue is free. Hunt for bugs and file each one with bash scripts/file-issue.sh --role bug-fix (at most $max in this run); do not fix anything in this run"
  else
    TASK="MEASURE mode: no open role:perf issue is free. Run the committed benchmark (roles.perf.bench) and file each regression with bash scripts/file-issue.sh --role perf; do not change code in this run"
  fi
}

# _handed_back N SHA: 0 when the newest <!-- factory:handback sha=... --> comment on PR N names
# SHA (babysit handed it back to its writer at this head), 1 when not, 2 when unreadable.
_handed_back() {
  local out sha
  [[ $2 =~ ^[0-9a-f]{40}$ ]] || return 2
  out=$(sf_gh api "repos/{owner}/{repo}/issues/$1/comments" --paginate </dev/null) || return 2
  # shellcheck disable=SC2016 # jq program
  sha=$(printf '%s\n' "$out" | sf_jq -r -n '
    [inputs
      | if type == "array" then .[] else error("not a list") end
      | select(type == "object" and (.body | type) == "string")
      | (.body | split("\n")[0] | rtrimstr("\r")) as $l
      | select($l | startswith("<!-- factory:handback "))
      | {t: ((.created_at // "") | tostring), id: (.id // 0), l: $l}]
    | sort_by([.t, .id])
    | if length == 0 then "" else
        (last.l | [scan("sha=([0-9a-fA-F]{40})")] | if length == 0 then "" else (.[0][0] | ascii_downcase) end)
      end') || return 2
  [ -n "$sha" ] && [ "$sha" = "$2" ] && return 0
  return 1
}

# _sweep_dead_claims: babysit releases every dead claim (is-live 1), never a live (0), an
# unknown (2) or a vanished (3) one, and never with --force. A dry run only says what it would do.
_sweep_dead_claims() {
  local out keys key st
  if ! out=$(_git_bk ls-remote "$REMOTE" 'refs/heads/factory/*' </dev/null); then
    sf_warn "cannot list the claims on $REMOTE; no dead claim was released"
    return 0
  fi
  keys=$(printf '%s\n' "$out" | awk '
    index($2, "refs/heads/factory/") == 1 { k = substr($2, 20); if (k !~ /^lock\//) print k }')
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    _valid_key "$key" || continue
    st=0
    _wt_script is-live "$key" >/dev/null 2>"$TMPD/is-live.err" || st=$?
    case "$st" in
      1)
        if [ "$opt_dry" = 1 ]; then
          sf_log "dry run: would release the dead claim factory/$key"
        elif _wt_script release "$key" >/dev/null 2>"$TMPD/release.err"; then
          sf_log "released the dead claim factory/$key"
        else
          sed 's/^/  | /' "$TMPD/release.err" >&2
          sf_warn "could not release the dead claim factory/$key"
        fi
        ;;
      0 | 3) ;;
      *)
        sed 's/^/  | /' "$TMPD/is-live.err" >&2
        sf_log "cannot tell whether factory/$key is live; left alone"
        ;;
    esac
  done <<EOF
$keys
EOF
}

# _housekeeping: babysit with no PR to work on. Releases dead claims (online only: offline,
# tip age alone can't tell an open PR's claim from a dead one), posts the throughput report
# (report.sh posts at most once a day) and exits 0 without launching an agent.
_housekeeping() {
  local st=0
  if _offline; then
    sf_log "offline: dead claims are not released (without GitHub an open PR's claim looks dead)"
  else
    _sweep_dead_claims
  fi
  if _offline; then
    sf_log "offline: the throughput report is not posted"
  elif [ ! -f "$JUDGE_SCRIPTS/report.sh" ]; then
    sf_log "scripts/report.sh is not installed; the throughput report is skipped"
  elif [ "$opt_dry" = 1 ]; then
    sf_log "dry run: would run bash scripts/report.sh throughput --post"
  else
    FACTORY_CONFIG="$JUDGE_CFG" bash "$JUDGE_SCRIPTS/report.sh" throughput --post </dev/null >&2 || st=$?
    if [ "$st" = 0 ]; then
      sf_log "ran report.sh throughput --post"
    else
      sf_warn "report.sh throughput --post failed (exit $st)"
    fi
  fi
  _nothing "no open factory/* PR needs babysit (housekeeping done)"
}

_babysit_task() {
  TASK="Babysit PR #$PR_NUM (branch factory/$KEY): get its checks green, address verify:findings and resolve merge conflicts"
}

_pick_babysit() {
  local rows row num head url oid key st
  MODE=resume
  if [ -n "$opt_pr" ]; then
    PR_NUM="$opt_pr"
    _pr_view
    _key_from_head
    _babysit_task
    return 0
  fi
  if _offline; then
    sf_warn "offline: the open PRs are not listed"
    _housekeeping
  fi
  _list_open_prs
  # A failing check, the verify:findings label, or a merge state that needs work (DIRTY:
  # conflicts; BEHIND: the base moved on). Drafts belong to their writer's resume.
  # Fields are joined with US (0x1f): IFS whitespace would merge an empty field away.
  # shellcheck disable=SC2016 # jq program
  rows=$(sf_jq -r '
    def failing: [.statusCheckRollup[]? | ((.conclusion // .state // "") | tostring | ascii_upcase)]
      | any(. == "FAILURE" or . == "ERROR" or . == "TIMED_OUT" or . == "CANCELLED"
            or . == "STARTUP_FAILURE" or . == "ACTION_REQUIRED" or . == "STALE");
    def findings: any(.labels[]?; .name == "verify:findings");
    def stuck: ((.mergeStateStatus // "") | tostring | ascii_upcase) as $m | ($m == "DIRTY" or $m == "BEHIND");
    [.[] | select(type == "object" and .isCrossRepository != true and .isDraft != true)
         | select((.headRefName // "") | tostring | startswith("factory/") and (startswith("factory/lock/") | not))
         | select(failing or findings or stuck)]
    | sort_by([(.createdAt // ""), .number]) | .[]
    | [(.number | tostring), .headRefName, (.url // "" | tostring), (.headRefOid // "" | tostring)]
    | map(gsub("[[:cntrl:]]"; "?")) | join("\u001f")' "$TMPD/prs.json") ||
    sf_die "could not parse the open PR list"
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    IFS=$'\037' read -r num head url oid <<EOF
$row
EOF
    _number_ok "$num" || sf_die "unexpected PR number in the PR list"
    key="${head#factory/}"
    # babysit resumes the PR's claim branch: a factory/* branch that is no claim key (an
    # audit-merge revert branch, say) can't be resumed, and must not block the PRs after it.
    if ! _valid_key "$key"; then
      sf_log "PR #$num's branch $head is not a factory/<key> claim branch, so babysit can't resume it; skipped"
      continue
    fi
    st=0
    _handed_back "$num" "$oid" || st=$?
    case "$st" in
      0)
        sf_log "PR #$num was handed back to its writer at its head $oid; skipped"
        continue
        ;;
      1) ;;
      *)
        sf_warn "cannot tell whether PR #$num was handed back at its head; skipped"
        continue
        ;;
    esac
    PR_NUM="$num"
    HEAD_REF="$head"
    KEY="$key"
    _set_pr_url "$url"
    _babysit_task
    return 0
  done <<EOF
$rows
EOF
  _housekeeping
}

_pick_ship() {
  local rows row num head url key st n=0
  MODE=main
  if [ -n "$opt_pr" ]; then
    PR_NUM="$opt_pr"
    # Online, the prompt names the PR's URL (offline it says none), and a PR that is not open
    # is nothing to do.
    if ! _offline; then _pr_view; fi
    TASK="Ship PR #$PR_NUM if it passes the merge policy"
    return 0
  fi
  _offline && sf_die "offline: ship needs GitHub to pick a PR (pass --pr N)"
  _list_open_prs
  rows=$(sf_jq -r '
    [.[] | select(type == "object" and .isCrossRepository != true and .isDraft != true)
         | select((.headRefName // "") | tostring | startswith("factory/") and (startswith("factory/lock/") | not))]
    | sort_by([(.createdAt // ""), .number]) | .[]
    | [(.number | tostring), .headRefName, (.url // "" | tostring)]
    | map(gsub("[[:cntrl:]]"; "?")) | join("\u001f")' "$TMPD/prs.json") ||
    sf_die "could not parse the open PR list"
  # The oldest PR that passes ship.sh check (from the snapshot): one waiting for an approval,
  # a fix or a rebase is skipped, so it can't starve newer ones.
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    IFS=$'\037' read -r num head url <<EOF
$row
EOF
    _number_ok "$num" || sf_die "unexpected PR number in the PR list"
    key="${head#factory/}"
    if ! _valid_key "$key"; then
      sf_log "PR #$num's branch $head is not a factory/<key> claim branch; skipped"
      continue
    fi
    n=$((n + 1))
    if [ "$n" -gt "$SHIP_TRIES" ]; then
      sf_log "checked $SHIP_TRIES PRs; the newer ones wait for the next run"
      break
    fi
    st=0
    bash "$JUDGE_SCRIPTS/ship.sh" check "$num" --tree "$MAIN" --config "$JUDGE_CFG" </dev/null >/dev/null \
      2>"$TMPD/ship-check.err" || st=$?
    case "$st" in
      0)
        PR_NUM="$num"
        HEAD_REF="$head"
        _set_pr_url "$url"
        TASK="Ship PR #$PR_NUM if it passes the merge policy"
        sf_log "PR #$num passes ship.sh check"
        return 0
        ;;
      1) sf_log "PR #$num does not pass ship.sh check; skipped" ;;
      *) sf_warn "ship.sh check could not decide PR #$num (exit $st); skipped" ;;
    esac
    tr -d '\r' <"$TMPD/ship-check.err" | sed 's/^/  | /' >&2
  done <<EOF
$rows
EOF
  _nothing "no open factory/* PR passes ship.sh check"
}

_pick_verify() {
  MODE=verify
  PR_NUM="$opt_pr"
  _pr_view
  _key_from_head
  [ -n "$PR_OID" ] || sf_die "could not read the head SHA of PR #$PR_NUM"
  TASK="Review PR #$PR_NUM (branch factory/$KEY, head $PR_OID)"
}

_pick_task() {
  case "$ROLE" in
    build) _pick_build ;;
    intake) _pick_intake ;;
    plan-features) _pick_plan ;;
    build-feature) _pick_build_feature ;;
    bug-fix | perf) _pick_issue_role ;;
    babysit) _pick_babysit ;;
    ship) _pick_ship ;;
    verify) _pick_verify ;;
    handoff)
      MODE=main
      TASK="Write a handoff summary of the current factory state"
      ;;
    *) sf_die "no picker for role $ROLE" ;;
  esac
}

# --- identity and environment (step 8) ------------------------------------------------------------

_export_identity() {
  export FACTORY_AGENT_ID="$AGENT_ID"
  export GIT_AUTHOR_NAME="$AGENT_ID" GIT_COMMITTER_NAME="$AGENT_ID"
  export GIT_AUTHOR_EMAIL="$AGENT_ID@agents.factory.invalid" GIT_COMMITTER_EMAIL="$AGENT_ID@agents.factory.invalid"
  export GIT_EDITOR=true GIT_SEQUENCE_EDITOR=true GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never
  export GH_PROMPT_DISABLED=1 GIT_PAGER=cat PAGER=cat
}

# --- workspace: claim, resume, throwaway worktrees, draft PR and PR link (step 9) -----------------

# _fill_template FILE: FILE with the placeholders AGENT_ID, ROLE, KEY and BASE_BRANCH replaced
# in one pass, so a value is copied as it is: a base branch may hold "&", "/" or another
# placeholder's name (release/ROLE), which sed or a second pass would rewrite.
_fill_template() {
  local line out name best pos p val
  while IFS= read -r line || [ -n "$line" ]; do
    out=""
    while :; do
      best=""
      pos=-1
      for name in AGENT_ID ROLE KEY BASE_BRANCH; do
        p="${line%%"$name"*}"
        [ "$p" != "$line" ] || continue
        if [ "$pos" -lt 0 ] || [ "${#p}" -lt "$pos" ]; then
          pos=${#p}
          best="$name"
        fi
      done
      [ -n "$best" ] || break
      case "$best" in
        AGENT_ID) val="$AGENT_ID" ;;
        ROLE) val="$ROLE" ;;
        KEY) val="$KEY" ;;
        *) val="$BASE" ;;
      esac
      out="$out${line:0:pos}$val"
      line="${line:pos+${#best}}"
    done
    printf '%s\n' "$out$line"
  done <"$1"
}

_open_pr() {
  local out row head="factory/$KEY" template="$JUDGE_TEMPLATE"
  out=$(sf_gh pr list --head "$head" --state open --json number,url,isCrossRepository </dev/null) ||
    sf_die "could not look for an open PR from $head"
  row=$(printf '%s\n' "$out" | sf_jq -r '
    if type != "array" then error("not a list") else . end
    | [.[] | select(.isCrossRepository != true)]
    | if length == 0 then "" else (.[0] | [(.number | tostring), (.url // "" | tostring)] | @tsv) end') ||
    sf_die "could not parse the PR list for $head"
  if [ -n "$row" ]; then
    PR_NUM="${row%%"$TAB"*}"
    _set_pr_url "${row#*"$TAB"}"
    if ! _number_ok "$PR_NUM" || [ -z "$PR_URL" ]; then sf_die "unexpected PR data for $head"; fi
    sf_log "reusing the open PR #$PR_NUM from $head"
    return 0
  fi
  _fill_template "$template" >"$TMPD/pr-body.md" || sf_die "cannot fill $template"
  out=$(sf_gh pr create --draft --base "$BASE" --head "$head" --title "$PR_TITLE" --body-file - <"$TMPD/pr-body.md") ||
    sf_die "could not open the draft PR from $head"
  _set_pr_url "$(printf '%s\n' "$out" | grep -Eo 'https://[^[:space:]]+/pull/[0-9]+' | tail -n 1)"
  [ -n "$PR_URL" ] || sf_die "could not read the PR URL from gh pr create"
  PR_NUM="${PR_URL##*/}"
  sf_log "opened draft PR #$PR_NUM: $PR_URL"
}

_link_pr() {
  local map="$WT/factory/feature-map.json"
  (cd "$WT" && bash "$JUDGE_SCRIPTS/feature-map.sh" mark "$KEY" in_progress --pr "$PR_URL" --map "$map" --config "$JUDGE_CFG") \
    </dev/null >&2 || sf_die "feature-map.sh mark $KEY in_progress --pr failed"
  if _git_bk -C "$WT" diff --quiet -- factory/feature-map.json; then
    sf_log "the map already links $PR_URL"
    return 0
  fi
  _git_bk -C "$WT" add -- factory/feature-map.json || sf_die "git add factory/feature-map.json failed"
  _git_bk -C "$WT" commit --no-verify -q -m "chore($KEY): link PR" </dev/null >&2 ||
    sf_die "the PR link commit failed"
  BOOK_SHA=$(_git_bk -C "$WT" rev-parse HEAD) || sf_die "cannot read HEAD in $WT"
  _git_bk -C "$WT" push --no-verify -q "$REMOTE" "HEAD:refs/heads/factory/$KEY" </dev/null >&2 ||
    sf_die "could not push the PR link commit to factory/$KEY"
}

# _claim_try: claim KEY; 0 claimed, 3 lost (another agent holds it). Called as a condition,
# so every error is handled explicitly.
_claim_try() {
  local st=0 out
  out=$(_wt_script claim "$KEY" --agent "$AGENT_ID" --base "$BASE") || st=$?
  case "$st" in
    0) ;;
    3) return 3 ;;
    *) sf_die "worktree.sh claim $KEY failed (exit $st)" ;;
  esac
  CLAIMED=1
  WT=$(printf '%s\n' "$out" | tail -n 1)
  [ -d "$WT" ] || sf_die "worktree.sh claim printed no worktree path"
  CLAIM_SHA=$(_git_bk -C "$WT" rev-parse HEAD) || sf_die "cannot read HEAD in $WT"
  BOOK_SHA="$CLAIM_SHA"
  WORKDIR="$WT"
  return 0
}

_claim() {
  local id st tries=0
  if ! _offline; then
    [ -f "$JUDGE_TEMPLATE" ] || sf_die "missing $SF_FACTORY_ROOT/templates/pr-body.md"
  fi
  if [ "$ROLE" = build-feature ]; then
    # A lost race for one ready feature moves on to the next one (at most CLAIM_TRIES).
    for id in $CANDIDATES; do
      tries=$((tries + 1))
      _set_feature_task "$id"
      st=0
      _claim_try || st=$?
      [ "$st" -ne 0 ] || break
      if [ -n "$opt_feature" ]; then
        sf_log "claim lost: factory/$id belongs to another agent"
        exit 3
      fi
      sf_log "claim lost: factory/$id belongs to another agent; trying the next ready feature"
    done
    if [ "$CLAIMED" != 1 ]; then
      sf_log "claim lost: every ready feature tried ($tries) was claimed by another agent"
      exit 3
    fi
  else
    st=0
    _claim_try || st=$?
    if [ "$st" -ne 0 ]; then
      sf_log "claim lost: factory/$KEY belongs to another agent"
      exit 3
    fi
  fi
  if _offline; then
    sf_log "offline: no draft PR for factory/$KEY"
    return 0
  fi
  _open_pr
  case "$KEY" in F*) _link_pr ;; esac
}

_resume() {
  local st=0 out
  # The exit trap reads origin/<base> (has the branch a tests-only commit yet?).
  _fetch_base
  out=$(_wt_script resume "$KEY" --agent "$AGENT_ID") || st=$?
  case "$st" in
    0) ;;
    1) _nothing "factory/$KEY no longer exists" ;;
    *) sf_die "worktree.sh resume $KEY failed (exit $st)" ;;
  esac
  WT=$(printf '%s\n' "$out" | tail -n 1)
  [ -d "$WT" ] || sf_die "worktree.sh resume printed no worktree path"
  WORKDIR="$WT"
}

# _throwaway_worktree NAME REV: a detached worktree <root>/<repo>-NAME-<hex> at REV, removed at exit.
_throwaway_worktree() {
  mkdir -p "$WT_ROOT" || sf_die "cannot create $WT_ROOT"
  THROW_WT="$WT_ROOT/$REPO_NAME-$1-$(sf_random_hex 4)"
  _git_bk -c core.longpaths=true worktree add -q --detach "$THROW_WT" "$2" </dev/null >&2 ||
    sf_die "could not create the worktree $THROW_WT"
  WORKDIR="$THROW_WT"
}

# _verify_worktree: verify reviews the PR's head in a fresh worktree of its own, never in the
# claim's worktree: a reviewer's leftovers can't reach the writer's branch, and two reviewers
# never share a tree.
_verify_worktree() {
  _git_bk fetch -q --no-tags "$REMOTE" "+refs/heads/$HEAD_REF:refs/remotes/$REMOTE/$HEAD_REF" </dev/null >&2 ||
    sf_die "could not fetch $HEAD_REF from $REMOTE"
  git cat-file -e "$PR_OID^{commit}" 2>/dev/null ||
    sf_die "the head $PR_OID of PR #$PR_NUM is not on $HEAD_REF (did the PR move?)"
  _throwaway_worktree "verify-$PR_NUM" "$PR_OID"
}

_workspace() {
  case "$MODE" in
    claim) _claim ;;
    resume) _resume ;;
    hunt)
      _fetch_base
      _throwaway_worktree "hunt-$ROLE" "refs/remotes/$REMOTE/$BASE"
      ;;
    verify) _verify_worktree ;;
    *) WORKDIR="$MAIN" ;;
  esac
}

# --- prompt (step 11) ----------------------------------------------------------------------------------

_build_prompt() {
  local where main mode branch task deadline
  # As a native Windows harness can open them (C:/... on Git Bash; unchanged elsewhere).
  where=$(sf_native_path "$WORKDIR") || where="$WORKDIR"
  main=$(sf_native_path "$MAIN") || main="$MAIN"
  case "$MODE" in
    claim) mode=new ;;
    resume) mode=resume ;;
    hunt) if [ "$ROLE" = perf ]; then mode=measure; else mode=hunt; fi ;;
    *) mode=new ;;
  esac
  case "$MODE" in
    claim | resume) branch="factory/$KEY" ;;
    *) branch=none ;;
  esac
  _agent_minutes
  deadline=$((RUN_START + AGENT_MINS * 60))
  task="$TASK"
  if [ "$MODE" = resume ]; then
    task="$task. This run resumes factory/$KEY: follow the Resume section of $main/skills/handoff/SKILL.md first"
  fi
  if [ -n "$opt_task" ]; then task="$task. Operator note: $opt_task"; fi
  PROMPT="You are a software-factory agent. Agent id: $AGENT_ID. Role: $ROLE. Mode: $mode. Worktree: $where. Branch: $branch. Base: $BASE. PR: ${PR_URL:-none}. Main checkout: $main. Deadline: $deadline. Task: $task. Read $main/AGENTS.md, then follow $main/skills/factory-mode/SKILL.md for this role. Never declare a check passed yourself: run the scripts it names and report their exit codes."
}

# _dry_run: say what would be claimed or resumed, print the argv and exit 0.
_dry_run() {
  local i a
  case "$MODE" in
    claim)
      WORKDIR="$WT_ROOT/$REPO_NAME-$KEY"
      sf_log "dry run: would claim factory/$KEY ($PR_TITLE)"
      ;;
    resume)
      WORKDIR="$WT_ROOT/$REPO_NAME-$KEY"
      sf_log "dry run: would resume factory/$KEY for PR #$PR_NUM"
      ;;
    hunt)
      WORKDIR="$WT_ROOT/$REPO_NAME-hunt-$ROLE-<hex>"
      sf_log "dry run: would run in a throwaway worktree at $REMOTE/$BASE, claiming nothing"
      ;;
    verify)
      WORKDIR="$WT_ROOT/$REPO_NAME-verify-$PR_NUM-<hex>"
      sf_log "dry run: would review PR #$PR_NUM in a fresh worktree at $PR_OID, claiming nothing"
      ;;
    *)
      WORKDIR="$MAIN"
      sf_log "dry run: would run in the main checkout, claiming nothing"
      ;;
  esac
  _build_prompt
  i=0
  for a in ${HARNESS_ARGV[@]+"${HARNESS_ARGV[@]}"} "$PROMPT"; do
    printf 'argv[%d]=%s\n' "$i" "$(_one_line "$a")"
    i=$((i + 1))
  done
  exit 0
}

# --- launch (steps 10 and 12) ------------------------------------------------------------------------

# _stop_harness: TERM (then KILL) the harness when it is still running.
_stop_harness() {
  local pid="" i=0
  [ -n "$HARNESS_JOB" ] || return 0
  pid=$(cat "$TMPD/harness.pid" 2>/dev/null) || pid=""
  case "$pid" in '' | *[!0-9]*) pid="" ;; esac
  if [ -n "$pid" ]; then kill -TERM "$pid" 2>/dev/null || true; else kill -TERM "$HARNESS_JOB" 2>/dev/null || true; fi
  while kill -0 "$HARNESS_JOB" 2>/dev/null && [ "$i" -lt 50 ]; do
    _sleep_short
    i=$((i + 1))
  done
  if kill -0 "$HARNESS_JOB" 2>/dev/null; then
    [ -z "$pid" ] || kill -KILL "$pid" 2>/dev/null || true
    kill -KILL "$HARNESS_JOB" 2>/dev/null || true
  fi
  wait "$HARNESS_JOB" 2>/dev/null || true
  HARNESS_JOB=""
}

_launch() {
  local mins secs st="" logdir log end
  _agent_minutes
  mins="$AGENT_MINS"
  secs=$((mins * 60))
  logdir="$MAIN/.factory/logs"
  mkdir -p "$logdir" || sf_die "cannot create $logdir"
  log="$logdir/$AGENT_ID.log"
  : >>"$log" || sf_die "cannot write $log"
  end="run-agent-end-$(sf_random_hex 8)"
  sf_log "launching $ROLE as $AGENT_ID in $WORKDIR (timeout ${mins}m, log $log)"
  # The job runs in the background so that a signal reaches our trap at once (bash runs traps
  # only between foreground commands).
  # The harness writes into a pipe that awk copies to stdout and the log. Nothing may wait for
  # that pipe's EOF: a process the harness leaves running (a dev server, the test it was killed
  # over) keeps the pipe open for good. So once the harness has exited, a random end marker
  # goes down the pipe and awk stops there. (A process substitution in place of the pipe would
  # also hand its descriptor to sf_run_timeout's watcher, whose sleep outlives the run.)
  (
    {
      (
        cd "$WORKDIR" || exit 2
        # The harness gets the PATH run-agent was started with, not the one that starts with
        # the pinned tools' directories (_pin_path); the tools that start it stay pinned.
        PATH="$RA_HARNESS_PATH"
        export PATH
        _repin
        # Only positional parameters from here on: FACTORY_AGENT_ENV names (PROMPT, TMPD, ...)
        # are environment for the harness and must not change what runs or where state goes.
        set -- "$secs" "$TMPD/harness.pid" "$TMPD/harness.status" ${HARNESS_ARGV[@]+"${HARNESS_ARGV[@]}"} "$PROMPT"
        # shellcheck disable=SC2086 # fixed list of variable names
        unset $SCRUBBED_ENV
        # common.sh exports where the running copy lives; in a --due child that is the parent's
        # judging snapshot, which the later roles run from: the agent is not told where it is.
        unset SF_FACTORY_ROOT
        for _ra_kv in ${AENV_PAIRS[@]+"${AENV_PAIRS[@]}"}; do
          # shellcheck disable=SC2163 # _ra_kv holds NAME=VALUE; NAME is what gets exported
          export "$_ra_kv" 2>/dev/null || sf_warn "FACTORY_AGENT_ENV: cannot export ${_ra_kv%%=*}"
        done
        # The wrapper records the harness pid (exec keeps it), so a signal can stop the harness itself.
        # shellcheck disable=SC2016 # $$ and $@ belong to the wrapper
        if sf_run_timeout "$1" bash -c 'printf "%s\n" "$$" >"$1" || exit 126; shift; exec "$@"' run-agent-harness \
          "$2" "${@:4}"; then
          printf '0\n' >"$3"
        else
          printf '%s\n' "$?" >"$3"
        fi
      )
      printf '%s\n' "$end"
    } 2>&1 | RA_LOG="$log" RA_END="$end" LC_ALL=C awk '
      function emit(s) { print s; print s >> lf; fflush(); fflush(lf) }
      BEGIN { lf = ENVIRON["RA_LOG"]; e = ENVIRON["RA_END"] }
      { i = index($0, e); if (i) { if (i > 1) emit(substr($0, 1, i - 1)); exit } emit($0) }'
  ) </dev/null &
  HARNESS_JOB=$!
  wait "$HARNESS_JOB" || true
  HARNESS_JOB=""
  st=$(cat "$TMPD/harness.status" 2>/dev/null) || st=""
  case "$st" in '' | *[!0-9]*) st=127 ;; esac
  # Returned, not exited: the caller exits with this status.
  case "$st" in
    0)
      RUN_REASON="after harness exit 0"
      sf_log "the harness exited 0"
      return 0
      ;;
    124)
      RUN_REASON="by timeout"
      sf_log "timeout: the harness ran longer than ${mins}m"
      return 4
      ;;
    126 | 127)
      RUN_REASON="after harness exit $st"
      sf_log "the harness could not be executed (exit $st)"
      return 2
      ;;
    *)
      RUN_REASON="after harness exit $st"
      sf_log "the harness exited $st"
      return 1
      ;;
  esac
}

# --- exit trap (step 13) --------------------------------------------------------------------------------

_is_bookkeeping() { [ -n "$1" ] && { [ "$1" = "$CLAIM_SHA" ] || [ "$1" = "$BOOK_SHA" ]; }; }

_handoff_comment() { # _handoff_comment WIP_SHA PUSHED
  local where
  if [ "$2" = 1 ]; then
    where="They were saved as the wip commit \`$1\` on \`factory/$KEY\`."
  else
    where="They were saved as the local wip commit \`$1\`, which could not be pushed to \`factory/$KEY\`."
  fi
  printf '%s\n' "<!-- factory:handoff agent=$AGENT_ID key=$KEY -->" \
    "Run \`$AGENT_ID\` (role $ROLE) stopped $RUN_REASON with uncommitted changes. $where" \
    "The next agent continues with \`bash scripts/worktree.sh resume $KEY\`." |
    _gh_late pr comment "$PR_NUM" --body-file - >/dev/null || sf_warn "could not post the handoff comment on PR #$PR_NUM"
}

# _abort_in_progress: abort an unfinished merge, rebase (or am), cherry-pick or revert in WT, so
# the wip commit below never commits conflict markers or a half-applied history.
_abort_in_progress() {
  local gd
  gd=$(_git_bk -C "$WT" rev-parse --absolute-git-dir 2>/dev/null) || return 0
  [ -n "$gd" ] && [ -d "$gd" ] || return 0
  if [ -f "$gd/rebase-apply/applying" ]; then
    _abort_op "git am" am --abort
  elif [ -d "$gd/rebase-merge" ] || [ -d "$gd/rebase-apply" ]; then
    _abort_op rebase rebase --abort
  fi
  if [ -f "$gd/MERGE_HEAD" ]; then _abort_op merge merge --abort; fi
  if [ -f "$gd/REVERT_HEAD" ]; then _abort_op revert revert --abort; fi
  if [ -f "$gd/CHERRY_PICK_HEAD" ] || [ -d "$gd/sequencer" ]; then
    _abort_op cherry-pick cherry-pick --abort || _abort_op revert revert --abort
  fi
}

_abort_op() { # _abort_op WHAT GIT_ARGS...
  local what="$1"
  shift
  if _git_bk -C "$WT" "$@" </dev/null >&2; then
    sf_log "aborted an unfinished $what in $WT"
    return 0
  fi
  sf_warn "could not abort the unfinished $what in $WT"
  return 1
}

# _test_specs: gate.test_globs as git pathspecs, one per line (none for "none" or a missing key).
_test_specs() {
  local g
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    case "$g" in
      :*) printf '%s\n' "$g" ;; # already carries pathspec magic
      *) printf ':(glob)%s\n' "$g" ;;
    esac
  done <<EOF
$(sf_cfg_globs gate.test_globs)
EOF
}

# _commit_wip MESSAGE: commit what is staged in WT as a bookkeeping commit; prints its SHA.
_commit_wip() {
  _git_bk -C "$WT" commit --no-verify -q -m "$1" </dev/null >&2 || return 1
  _git_bk -C "$WT" rev-parse HEAD 2>/dev/null
}

# _save_leftovers: commit what the writer left in WT. Prints the last wip commit's SHA ("" = none).
_save_leftovers() {
  local -a specs=()
  local s wip="" sha
  _abort_in_progress
  if _clean_tree "$WT"; then return 0; fi
  if [ -n "$(_git_bk -C "$WT" ls-files -u 2>/dev/null)" ]; then
    sf_warn "$WT has unresolved conflicts; its changes stay uncommitted there (conflict markers are never committed)"
    return 0
  fi
  # red/green needs a tests-only commit first on a feature or bug-fix branch: while the branch
  # has none, leftover test files are committed first, alone.
  case "$KEY" in
    F[0-9]* | issue-[0-9]*)
      while IFS= read -r s; do [ -z "$s" ] || specs+=("$s"); done <<EOF
$(_test_specs)
EOF
      if [ "${#specs[@]}" -gt 0 ] &&
        [ -z "$(_git_bk -C "$WT" rev-list -n 1 HEAD "^refs/remotes/$REMOTE/$BASE" -- "${specs[@]}" 2>/dev/null)" ]; then
        # Nothing staged by the agent may ride along: the tests commit holds test files only.
        _git_bk -C "$WT" reset -q </dev/null >/dev/null 2>&1 || true
        for s in "${specs[@]}"; do
          # A glob that matches no file is an error for git add; the others still count.
          _git_bk -C "$WT" add -A -- "$s" >/dev/null 2>&1 || true
        done
        if ! _git_bk -C "$WT" diff --cached --quiet 2>/dev/null; then
          if sha=$(_commit_wip "wip($KEY): interrupted, tests"); then
            wip="$sha"
            sf_log "saved the leftover test files as the wip commit $sha"
          else
            sf_warn "could not commit the leftover test files in $WT"
          fi
        fi
      fi
      ;;
  esac
  if ! _clean_tree "$WT"; then
    if _git_bk -C "$WT" add -A >&2 && sha=$(_commit_wip "wip($KEY): interrupted $RUN_REASON"); then
      wip="$sha"
      sf_log "saved uncommitted changes as the wip commit $sha"
    else
      sf_warn "could not commit the uncommitted changes in $WT; they stay there"
    fi
  fi
  printf '%s\n' "$wip"
}

# _finish_work: save, push and hand off the claimed or resumed worktree of a writer role;
# release a claim that never got any work. Every git call is bookkeeping (_git_bk).
_finish_work() {
  local wip="" pushed=0 head remote st=0
  [ -n "$WT" ] || return 0
  # Only writers have a claimed or resumed worktree; readers never commit or push.
  _is_writer || return 0
  if [ ! -d "$WT" ]; then
    sf_warn "the worktree $WT is gone"
    return 0
  fi
  wip=$(_save_leftovers) || wip=""
  head=$(_git_bk -C "$WT" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null) || head=""
  remote=$(_remote_sha "factory/$KEY") || st=$?
  if [ "$st" -ne 0 ]; then
    sf_warn "cannot read $REMOTE: local commits in $WT were not pushed and the claim is kept"
    remote=""
  elif [ -z "$remote" ]; then
    sf_warn "factory/$KEY is gone from $REMOTE; local commits stay in $WT"
  elif [ -n "$head" ] && [ "$head" != "$remote" ]; then
    # No "+" in the refspec: the push is fast-forward only.
    if _git_bk -C "$WT" push --no-verify -q "$REMOTE" "HEAD:refs/heads/factory/$KEY" </dev/null >&2; then
      remote="$head"
      pushed=1
      sf_log "pushed the local commits to factory/$KEY"
    else
      sf_warn "could not push the commits in $WT to factory/$KEY (not a fast-forward?); they stay in $WT"
    fi
  fi
  if [ -n "$wip" ] && [ -n "$PR_NUM" ] && ! _offline; then _handoff_comment "$wip" "$pushed"; fi
  [ "$CLAIMED" = 1 ] || return 0
  if _is_bookkeeping "$remote" && _is_bookkeeping "$head" && _clean_tree "$WT"; then
    sf_log "no work reached factory/$KEY: closing the draft PR and releasing the claim"
    if [ -n "$PR_NUM" ] && ! _offline; then
      _gh_late pr close "$PR_NUM" --comment "Closed by run-agent: run $AGENT_ID ended without work, so the claim on factory/$KEY was released." \
        </dev/null >&2 || sf_warn "could not close the draft PR #$PR_NUM"
    fi
    _wt_script release "$KEY" --force >&2 || sf_warn "could not release factory/$KEY"
  fi
}

# _finish_throwaway: remove the hunt, measure or verify worktree with everything left in it.
_finish_throwaway() {
  [ -n "$THROW_WT" ] || return 0
  _git_bk worktree remove --force --force "$THROW_WT" >/dev/null 2>&1 || true
  [ ! -e "$THROW_WT" ] || rm -rf "$THROW_WT" 2>/dev/null || true
  _git_bk worktree prune >/dev/null 2>&1 || true
}

_on_exit() {
  local code=$?
  set +e
  trap '' INT TERM HUP
  _stop_harness
  [ -n "$RUN_REASON" ] || RUN_REASON="after run-agent exit $code"
  _finish_work
  _finish_throwaway
  _log_finish "$code"
  # After the push: the draft's tip is fresh again before another run may take the lock.
  _unlock_resume
  _unlock_role
  [ -z "$TMPD" ] || rm -rf "$TMPD"
  exit "$code"
}

_on_signal() { # _on_signal NAME CODE
  RUN_REASON="by signal $1"
  sf_log "received $1"
  trap '' INT TERM HUP
  exit "$2"
}

# --- main ----------------------------------------------------------------------------------------------

[ -n "$ROLE" ] || _due_all

# 1. Config (loaded above) and the judging snapshot, then the harness argv.
TMPD=$(sf_mktemp_dir) || sf_die "cannot create a temporary directory"
trap _on_exit EXIT
trap '_on_signal TERM 143' TERM
trap '_on_signal INT 130' INT
trap '_on_signal HUP 129' HUP
_snapshot_judge
_harness_argv
# 2. Stop switches.
_stop_switches || _stopped_exit
if [ "${CI:-}" = true ] && [ -n "${GITHUB_RUN_ID:-}" ]; then
  RUN_ID="$GITHUB_RUN_ID.${GITHUB_RUN_ATTEMPT:-1}.${GITHUB_JOB:-job}"
else
  RUN_ID=$(sf_now)
fi
RUN_ID=$(printf '%s' "$RUN_ID" | tr -c 'A-Za-z0-9._-' '-')
_new_agent_id
# 3. Due check (then the local token warning, PLAN 4.7). 4. Preflight. 5. Role lock (and the
# role log's start).
[ "$opt_due" = 0 ] || _due_check
_scope_warning
_preflight
if [ "$opt_dry" = 0 ]; then
  # The repository the exit trap's gh calls name, resolved before anything is locked.
  _resolve_repo
  _lock_role
  _log_start
fi
# 6, 7. Backpressure and the pick (build picks its stage here and becomes that role).
_pick_task
# 8. Identity and environment.
_export_identity
[ "$opt_dry" = 0 ] || _dry_run
# 9. Workspace. 10-12. Agent environment, prompt and launch. 13. The exit trap.
_workspace
_build_prompt
# _launch returns the exit code (set -e exits with a non-zero one at once; the EXIT trap runs
# either way). Nothing after this line is ever read from the file.
_launch
exit $?
}
