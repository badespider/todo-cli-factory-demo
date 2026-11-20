#!/usr/bin/env bash
# Held-out quality gate: judges a tree with the judging copy's config and scripts. Contract: docs/CONTRACTS.md, "gate.sh".
set -euo pipefail
SF_PROG=gate
# shellcheck source=scripts/lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
# shellcheck source=scripts/lib/jq.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/jq.sh"
# shellcheck source=scripts/lib/config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"
# shellcheck source=scripts/lib/redgreen.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/redgreen.sh"

# The rest of this file is one brace group that ends in `exit`, so bash parses all of it
# before running any of it. bash reads a script file as it executes it, and the project
# code the gate runs can write this file (same user; SF_FACTORY_ROOT is in its environment):
# an in-place rewrite would otherwise replace the rest of the gate, e.g. with `exit 0`.
# (Sourced files are read whole when sourced.)
{

usage() {
  cat <<'EOF'
Usage: gate.sh [--tree DIR] [--config FILE] [--base SHA] [--head SHA] [--branch REF]
               [--record-pr N] [--json]
       gate.sh --attempts --pr N [--config FILE]

Runs the held-out quality gate against --tree (default: the current repo root). Config,
scripts and the map rules come from the judging copy (the factory holding this script, or
--config / FACTORY_CONFIG), never from the tree; the tree's factory/feature-map.json and
factory/spec.md are only data.

Steps, printed in this order, each as "PASS|FAIL|SKIP <step> (<secs>s)":
  setup         project.setup (SKIP when none). If it fails, every later step is SKIP.
  test          gate.test (none: SKIP, but FAIL while any feature in the tree's map is done)
  lint          gate.lint (none: SKIP)
  typecheck     gate.typecheck (none: SKIP)
  map           feature-map.sh validate of the tree's map (with --spec when
                factory/spec.md exists; on a feature branch also --against BASE --own F<n>)
  tests-tagged  feature branch only: feature-map.sh check-tests F<n> --ref BASE
  red-green     feature branch with gate.require_red_green: true: redgreen_check
What the gate decides from the tree's data and history runs before any of the tree's own
code: the map and tests-tagged checks, the "test: none" rule, then the whole red-green step
(it reads history, then runs the red and green trees in throwaway worktrees). Only then do
setup, test, lint and typecheck run in the tree. The lines are still printed in the order
above. factory/, the map and the spec must be regular files (no symlinks). Every git call
ignores replace refs and graft files.
Commands run with bash -c in the tree, stdin from /dev/null, bounded by
limits.agent_timeout_minutes, without the exported variables whose names look like
credentials (*TOKEN*, *SECRET*, ...; also names bash itself can't hold).

A check that cannot decide (feature-map.sh exits 2, red/green returns 2 or 3) prints
FAIL <step> with the reason and the other steps still run, but the gate then has no
verdict: it exits 2, --json says "result":"error", and --record-pr posts nothing, so an
inconclusive run never counts as a fix attempt. A failed setup is a fail (exit 1) even
then: it is a decisive fail of the tree's own code.

Options:
  --tree DIR      tree under test (default: the repo containing the current directory)
  --config FILE   judging config (default: FACTORY_CONFIG, else the judging copy's)
  --base SHA      PR mode: the base commit; needs --branch and must resolve in the tree
  --head SHA      the commit being judged; the tree's HEAD must be exactly this commit
  --branch REF    the PR's head branch; factory/F<n> (or refs/heads/factory/F<n>) makes it
                  a feature branch, which needs --base
  --record-pr N   post one PR comment headed <!-- factory:gate result=pass|fail sha=<head> -->
                  (gh pr comment N --body-file -). The tree must have no uncommitted
                  changes (exit 2 before anything runs). The repository is GH_REPO, or what
                  gh repo view says in the tree, resolved before any project code runs. Not
                  with FACTORY_OFFLINE=1; nothing is posted when a check could not decide.
  --json          print one JSON document instead of the step lines: {"result":
                  "pass|fail|error","head","base","branch","steps":[{"name","result","secs"}]}
  --attempts      with --pr N: count the fix attempts on PR N so far, the distinct sha=
                  values of comments whose first line is
                  <!-- factory:gate result=fail sha=<sha> --> (gh api
                  repos/{owner}/{repo}/issues/N/comments --paginate), counting only shas
                  that are commits of PR N (gh api repos/{owner}/{repo}/pulls/N/commits
                  --paginate), and print attempts=<count> limit=<limits.fix_attempts>.
                  A PR that lists 250 commits (the most GitHub lists) can't be counted
                  (exit 2). Needs GitHub; set GH_REPO when calling it from a PR worktree.
  --pr N          the PR for --attempts
  -h, --help      this text

Exit codes (gate): 0 every step passed or was skipped; 1 a step failed; 2 usage or config
error, a required tool missing, a check that could not decide, a dirty tree with
--record-pr, or a verdict that could not be recorded.
Exit codes (--attempts): 0 attempts < limit; 1 the limit is reached; 2 usage, config or
GitHub error.
Contract: docs/CONTRACTS.md, "gate.sh".
EOF
}

gate_usage_die() {
  printf '%s: error: %s\n' "$SF_PROG" "$1" >&2
  printf "%s: run 'bash scripts/gate.sh --help' for usage\n" "$SF_PROG" >&2
  exit 2
}

GATE_NL=$'\n'

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------

OPT_TREE=""
OPT_CONFIG=""
OPT_BASE=""
OPT_HEAD=""
OPT_BRANCH=""
OPT_PR=""
OPT_JSON=0
OPT_ATTEMPTS=0
OPT_ATTEMPTS_PR=""
OPT_GATE_ONLY=""   # a gate-run option that was given (not allowed with --attempts)

gate_set_opt() { # gate_set_opt OPTION VALUE
  [ -n "$2" ] || gate_usage_die "$1 needs a non-empty value"
  case "$1" in
    --tree) OPT_TREE="$2" ;;
    --config) OPT_CONFIG="$2" ;;
    --base) OPT_BASE="$2" ;;
    --head) OPT_HEAD="$2" ;;
    --branch) OPT_BRANCH="$2" ;;
    --record-pr) OPT_PR="$2" ;;
    --pr) OPT_ATTEMPTS_PR="$2" ;;
  esac
  case "$1" in --config | --pr) ;; *) OPT_GATE_ONLY="$1" ;; esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --json) OPT_JSON=1; OPT_GATE_ONLY=--json; shift ;;
    --attempts) OPT_ATTEMPTS=1; shift ;;
    --tree | --config | --base | --head | --branch | --record-pr | --pr)
      [ "$#" -ge 2 ] || gate_usage_die "$1 needs a value"
      gate_set_opt "$1" "$2"
      shift 2
      ;;
    --tree=* | --config=* | --base=* | --head=* | --branch=* | --record-pr=* | --pr=*)
      gate_set_opt "${1%%=*}" "${1#*=}"
      shift
      ;;
    *) gate_usage_die "unknown argument: $(printf '%q' "$1")" ;;
  esac
done

# gate_pr_number OPTION VALUE: a PR number has no sign, no leading zero, at most 9 digits.
gate_pr_number() {
  case "$2" in
    *[!0-9]* | 0* | ??????????*) gate_usage_die "$1 needs a PR number (got $(printf '%q' "$2"))" ;;
  esac
}

if [ "$OPT_ATTEMPTS" -eq 1 ]; then
  [ -n "$OPT_ATTEMPTS_PR" ] || gate_usage_die "--attempts needs --pr N"
  [ -z "$OPT_GATE_ONLY" ] || gate_usage_die "--attempts takes only --pr and --config, not $OPT_GATE_ONLY"
  gate_pr_number --pr "$OPT_ATTEMPTS_PR"
  [ "${FACTORY_OFFLINE:-}" != 1 ] || gate_usage_die "--attempts reads the PR's comments from GitHub, but FACTORY_OFFLINE=1"
elif [ -n "$OPT_ATTEMPTS_PR" ]; then
  gate_usage_die "--pr is for --attempts; to record a gate verdict use --record-pr N"
fi

if [ -n "$OPT_PR" ]; then
  gate_pr_number --record-pr "$OPT_PR"
  [ "${FACTORY_OFFLINE:-}" != 1 ] || gate_usage_die "--record-pr needs GitHub, but FACTORY_OFFLINE=1"
fi
# The branch name comes from GitHub: it is data. A ref name never holds whitespace or
# control characters, so refuse those instead of carrying them into any output.
case "$OPT_BRANCH" in
  *[[:space:][:cntrl:]]*) gate_usage_die "--branch must be a git ref name (no whitespace or control characters)" ;;
esac

# Only the tree's own factory/feature-map.json is judged; a caller's FACTORY_MAP must not
# reach the map checks or the commands.
unset FACTORY_MAP

# ---------------------------------------------------------------------------
# Config (the judging copy's, or --config / FACTORY_CONFIG)
# ---------------------------------------------------------------------------

if [ -n "$OPT_CONFIG" ]; then
  case "$OPT_CONFIG" in -*) OPT_CONFIG="./$OPT_CONFIG" ;; esac
  sf_config_load "$OPT_CONFIG"
else
  sf_config_load
fi

# Absolute TMPDIR: commands run inside the tree, where a relative one would point elsewhere.
TMPDIR=$(cd -- "${TMPDIR:-/tmp}" 2>/dev/null && pwd) || sf_die "TMPDIR is not a usable directory"
export TMPDIR
GATE_W=$(sf_mktemp_dir) || sf_die "cannot create a temporary directory"
trap 'rm -rf "$GATE_W" 2>/dev/null || true' EXIT

# ---------------------------------------------------------------------------
# --attempts --pr N: fix attempts so far vs limits.fix_attempts
# ---------------------------------------------------------------------------

# Comments come from anyone who can comment, so only a marker on the first line counts (as
# the gate writes it), and only its sha: the same sha posted twice is one attempt. And only
# a sha that is a commit of the PR: anyone can write a marker naming an invented sha (or a
# commit of another PR) to spend the writer's attempts. gh --paginate prints one JSON array
# per page; they arrive slurped. GATE_JQ_PR_COMMITS turns the commit pages into one list of
# shas; GATE_JQ_ATTEMPTS gets that list as $pr (--slurpfile, so $pr[0]).
# shellcheck disable=SC2016 # jq program
GATE_JQ_PR_COMMITS='
if length == 0 then error("no output") else . end
| [ .[] | if type == "array" then .[] else error("not a list of commits") end
    | if type == "object" and (.sha | type) == "string" then .sha else error("not a commit") end ]'
# GitHub lists at most this many commits of a PR (pulls/N/commits). A list that long may
# be cut short, and a failed marker on a commit it leaves out would count for nothing: an
# attempt limit that is never reached.
GATE_PR_COMMITS_MAX=250
# shellcheck disable=SC2016 # jq program
GATE_JQ_ATTEMPTS='
(reduce $pr[0][] as $s ({}; .[$s] = true)) as $commit
| if length == 0 then error("no output") else . end
| [ .[] | if type == "array" then .[] else error("not a list of comments") end
    | if type == "object" then . else error("not a comment") end
    | .body | select(type == "string")
    | (split("\n")[0] // "") | rtrimstr("\r")
    | capture("\\A<!-- factory:gate result=fail sha=(?<sha>[0-9a-f]{40}(?:[0-9a-f]{24})?) -->\\z")
    | .sha | select($commit[.] == true) ]
| unique | length'

gate_attempts() {
  local raw limit count total
  raw=$(sf_cfg limits.fix_attempts)
  case "$raw" in
    '' | *[!0-9]* | ?????????*) limit=0 ;;
    *) limit=$((10#$raw)) ;;
  esac
  [ "$limit" -gt 0 ] ||
    sf_die "$SF_CONFIG_FILE: limits.fix_attempts must be a positive whole number (got $(printf '%q' "$raw"))"
  sf_need gh jq
  if ! sf_gh api "repos/{owner}/{repo}/issues/$OPT_ATTEMPTS_PR/comments" --paginate \
    </dev/null >"$GATE_W/comments.json" 2>"$GATE_W/comments.err"; then
    sf_die "could not read the comments of PR #$OPT_ATTEMPTS_PR: $(head -n 1 "$GATE_W/comments.err" | tr -d '\r')"
  fi
  if ! sf_gh api "repos/{owner}/{repo}/pulls/$OPT_ATTEMPTS_PR/commits" --paginate \
    </dev/null >"$GATE_W/commits.json" 2>"$GATE_W/commits.err"; then
    sf_die "could not read the commits of PR #$OPT_ATTEMPTS_PR: $(head -n 1 "$GATE_W/commits.err" | tr -d '\r')"
  fi
  sf_jq -c -s "$GATE_JQ_PR_COMMITS" "$GATE_W/commits.json" >"$GATE_W/pr-shas.json" 2>"$GATE_W/commits.err" ||
    sf_die "unexpected output from gh api for the commits of PR #$OPT_ATTEMPTS_PR"
  total=$(sf_jq -r 'length' "$GATE_W/pr-shas.json" 2>/dev/null) || total=""
  case "$total" in '' | *[!0-9]*) sf_die "internal error: could not count the commits of PR #$OPT_ATTEMPTS_PR" ;; esac
  [ "$total" -lt "$GATE_PR_COMMITS_MAX" ] ||
    sf_die "PR #$OPT_ATTEMPTS_PR lists $total commits, the most GitHub lists, so a failed marker on a later commit could not be checked"
  count=$(sf_jq -r -s --slurpfile pr "$GATE_W/pr-shas.json" "$GATE_JQ_ATTEMPTS" "$GATE_W/comments.json" \
    2>"$GATE_W/comments.err") ||
    sf_die "unexpected output from gh api for the comments of PR #$OPT_ATTEMPTS_PR"
  case "$count" in '' | *[!0-9]*) sf_die "internal error: could not count the gate comments" ;; esac
  printf 'attempts=%s limit=%s\n' "$count" "$limit"
  [ "$count" -lt "$limit" ] || return 1
  return 0
}

if [ "$OPT_ATTEMPTS" -eq 1 ]; then
  sf_cfg_has limits.fix_attempts || sf_die "$SF_CONFIG_FILE: missing required key 'limits.fix_attempts'"
  if gate_attempts; then exit 0; else exit 1; fi
fi

# ---------------------------------------------------------------------------
# Gate config
# ---------------------------------------------------------------------------

# Required: a missing key is not "none" (none is a deliberate choice), so fail closed.
CFG_SETUP=$(sf_cfg project.setup)
CFG_TEST=$(sf_cfg gate.test)
CFG_LINT=$(sf_cfg gate.lint)
CFG_TYPECHECK=$(sf_cfg gate.typecheck)
CFG_RG=$(sf_cfg gate.require_red_green)
# Required on every branch (docs/CONTRACTS.md, Conventions), not only where a check reads it:
# none, or at least one glob (a key whose items are all commented out is not "none").
sf_cfg_require_globs gate.test_globs
case "$CFG_RG" in
  true | false) ;;
  *) sf_die "$SF_CONFIG_FILE: gate.require_red_green must be true or false (got $(printf '%q' "$CFG_RG"))" ;;
esac
CFG_MINUTES=$(sf_cfg limits.agent_timeout_minutes 45)
# At most 8 digits (no overflow), read as decimal ("08" would be octal in $((...))).
case "$CFG_MINUTES" in
  '' | *[!0-9]* | ?????????*) CFG_MINUTES=0 ;;
  *) CFG_MINUTES=$((10#$CFG_MINUTES)) ;;
esac
[ "$CFG_MINUTES" -gt 0 ] ||
  sf_die "$SF_CONFIG_FILE: limits.agent_timeout_minutes must be a positive whole number (got $(printf '%q' "$(sf_cfg limits.agent_timeout_minutes 45)"))"
GATE_TIMEOUT=$((CFG_MINUTES * 60))
# Project commands share the tree's .git with the checks. A `git replace` ref or an
# info/grafts line written there could swap the commits red/green inspects; common.sh exports
# GIT_NO_REPLACE_OBJECTS=1 and GIT_GRAFT_FILE=/dev/null (advice off) for every script, so
# every git call the gate makes ignores both.

# Credentials are for the gate (posting the verdict), never for the tree's code: setup,
# test, lint, typecheck and red/green's runs execute what the PR wrote. They run under
# `env -u` for every exported name that looks like a credential (sf_credential_names), which
# also removes names bash itself can neither list nor unset (NPM.TOKEN, DEPLOY-SECRET).
# A listing that fails must stop the gate with 2 (could not decide): under set -e the bare
# assignment would exit 1, which reads as "the PR failed the gate".
GATE_CRED_NAMES=$(sf_credential_names) ||
  sf_die "cannot list the credential-like variables, so no project command may run"
GATE_DROP=()
while IFS= read -r gate_v; do
  [ -z "$gate_v" ] || GATE_DROP+=(-u "$gate_v")
done <<EOF
$GATE_CRED_NAMES
EOF
# gate_unset_credentials: in a subshell that runs git for the checks (red/green's worktree
# checkouts can start the repo's filter drivers), drop the credential-like variables bash can
# unset. red/green removes the rest from the project code it runs itself.
gate_unset_credentials() {
  local n
  while IFS= read -r n; do
    [ -z "$n" ] || unset -v "$n" 2>/dev/null || true
  done <<EOF
$GATE_CRED_NAMES
EOF
  return 0
}

# Pin the tools that this shell (and red/green, which runs in it) uses once project code has
# run: that code can put an executable named gh (which would get the token), git, env, bash or
# grep in a PATH directory it can write to (~/.local/bin, say). bash looks a hashed name up
# in its table, never in PATH again, as long as nothing assigns PATH in this shell (that
# empties the table).
hash bash git jq gh env awk sed grep cut tr head tail cat wc date mkdir mktemp rm sleep sort find cksum ls cygpath \
  2>/dev/null || true
# A name that is not hashed is looked up in PATH again on every call, where it may be the
# project's by then. So every tool this shell runs after project code must exist now (gh
# only for --record-pr, cygpath only on Git Bash); a missing one fails closed before any step.
sf_need bash git jq env awk sed grep cut tr head tail cat wc date mkdir mktemp rm sleep sort find cksum ls
if [ "$SF_MSYS" = 1 ]; then sf_need cygpath; fi
if [ -n "$OPT_PR" ]; then sf_need gh; fi
# The bash that runs project commands, by its path: env would look `bash` up in PATH.
GATE_BASH="$BASH"
# gh runs git by a PATH lookup when it has to find a repository; the post below puts the
# pinned git's directory first in gh's PATH all the same.
GATE_GIT_BIN=$(hash -t git 2>/dev/null) || GATE_GIT_BIN=""
GATE_GH_BIN=$(hash -t gh 2>/dev/null) || GATE_GH_BIN=""
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# ---------------------------------------------------------------------------
# Tree, head, base and branch
# ---------------------------------------------------------------------------

TREE=$(sf_repo_root "${OPT_TREE:-.}")

# gate_resolve WHAT REV: the commit REV names in the tree, or exit 2.
gate_resolve() {
  local sha
  case "$2" in -*) gate_usage_die "$1: invalid revision $(printf '%q' "$2")" ;; esac
  sha=$(git -C "$TREE" rev-parse --verify -q "$2^{commit}" 2>/dev/null) ||
    sf_die "$1 $(printf '%q' "$2") does not name a commit in $TREE"
  printf '%s\n' "$sha"
}

HEAD_SHA=$(git -C "$TREE" rev-parse --verify -q 'HEAD^{commit}' 2>/dev/null) ||
  sf_die "the tree has no commit checked out: $TREE"
if [ -n "$OPT_HEAD" ]; then
  want=$(gate_resolve --head "$OPT_HEAD")
  [ "$want" = "$HEAD_SHA" ] ||
    sf_die "the tree's HEAD is $HEAD_SHA, not --head $want; the gate never checks anything out, so check out the head commit first"
fi

# A feature branch is factory/F<n>, with or without refs/heads/.
FID=""
GATE_BRANCH="${OPT_BRANCH#refs/heads/}"
case "$GATE_BRANCH" in
  factory/F*)
    case "${GATE_BRANCH#factory/F}" in
      '' | *[!0-9]*) ;;
      *) FID="${GATE_BRANCH#factory/}" ;;
    esac
    ;;
esac

BASE_SHA=""
if [ -n "$OPT_BASE" ]; then
  # PR mode: without the branch the gate cannot tell which rules apply, so fail closed.
  [ -n "$OPT_BRANCH" ] || gate_usage_die "--base (PR mode) needs --branch, the PR's head branch"
  BASE_SHA=$(gate_resolve --base "$OPT_BASE")
elif [ -n "$FID" ]; then
  # tests-tagged and red-green compare against the base; without it they cannot run.
  gate_usage_die "the feature branch factory/$FID needs --base (tests-tagged and red-green compare against it)"
fi

# ---------------------------------------------------------------------------
# --record-pr: a clean tree, and the repository, before anything runs
# ---------------------------------------------------------------------------

# The recorded verdict names sha=<head>, so it must describe exactly that commit: no
# uncommitted change and no untracked file (ignored files are not the commit's either way).
# Untracked files and submodules are asked for explicitly: status.showUntrackedFiles=no or
# diff.ignoreSubmodules in some git config would otherwise hide them.
GATE_REPO=""
# [HOST/]OWNER/REPO, as GH_REPO takes it.
GATE_REPO_RE='^([A-Za-z0-9][A-Za-z0-9.-]*/)?[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'
if [ -n "$OPT_PR" ]; then
  gate_dirty=$(sf_git_bk -C "$TREE" status --porcelain --untracked-files=normal --ignore-submodules=none \
    2>"$GATE_W/status.err") ||
    sf_die "cannot read the tree's status (git status): $(head -n 1 "$GATE_W/status.err" | tr -d '\r')"
  if [ -n "$gate_dirty" ]; then
    sf_die "--record-pr: the tree has uncommitted changes or untracked files, and the verdict would name sha=$HEAD_SHA; commit or remove them first"
  fi
  # gh calls after project code ran name the repository (GH_REPO): resolved now, while the
  # tree's remotes and git config are still what the checkout wrote.
  if [ -n "${GH_REPO:-}" ]; then
    GATE_REPO="$GH_REPO"
  else
    (cd "$TREE" && sf_gh repo view --json owner,name) </dev/null >"$GATE_W/repo.json" 2>"$GATE_W/repo.err" ||
      sf_die "could not tell which GitHub repository the tree belongs to (gh repo view): $(head -n 1 "$GATE_W/repo.err" | tr -d '\r')"
    # shellcheck disable=SC2016 # jq program
    GATE_REPO=$(sf_jq -r 'if type == "object" and (.owner.login | type) == "string" and (.name | type) == "string"
      then .owner.login + "/" + .name else error("unexpected shape") end' "$GATE_W/repo.json" 2>/dev/null) ||
      sf_die "could not parse the output of gh repo view"
  fi
  [[ $GATE_REPO =~ $GATE_REPO_RE ]] ||
    sf_die "not a repository name ([HOST/]OWNER/REPO): $(printf '%q' "$GATE_REPO")"
fi

# ---------------------------------------------------------------------------
# Step bookkeeping
# ---------------------------------------------------------------------------

GATE_STEPS=""   # "<name> <RESULT> <secs>" per step, in order
GATE_LINES=""   # the step lines as printed
GATE_FAILED=0   # some step said no
GATE_ERROR=0    # some check could not decide: the gate exits 2

# gate_tail NAME REASON LOG: header naming the failed step, then the last 60 lines of LOG.
gate_tail() {
  printf '%s: ---- %s failed (%s); last 60 lines of its output:\n' "$SF_PROG" "$1" "$2" >&2
  # Only a regular file: project code may have swapped the log for a directory or a FIFO.
  # Control characters other than tab are dropped, so that a carriage return or an escape
  # sequence in the output cannot overwrite the "  | " prefix on a terminal or in a CI log.
  if [ -f "$3" ] && [ -s "$3" ]; then
    tail -n 60 "$3" 2>/dev/null | LC_ALL=C tr -d '\000-\010\013-\037\177' | sed 's/^/  | /' >&2 || true
  else
    printf '  | (no output)\n' >&2
  fi
}

# gate_report NAME RESULT SECS [REASON LOG]: record one step and print its line.
gate_report() {
  local line="$2 $1 ($3s)"
  GATE_STEPS="$GATE_STEPS$1 $2 $3$GATE_NL"
  GATE_LINES="$GATE_LINES$line$GATE_NL"
  if [ "$OPT_JSON" -eq 0 ]; then
    printf '%s\n' "$line"
  fi
  if [ "$2" = FAIL ]; then
    GATE_FAILED=1
    gate_tail "$1" "$4" "$5"
  fi
}

gate_skip() { # gate_skip NAME WHY
  sf_log "$1: skipped ($2)"
  gate_report "$1" SKIP 0
}

# gate_cmd NAME COMMAND: run COMMAND (project code) with bash -c in the tree under the
# timeout, without credential-like variables, and report the step. Output goes to
# $GATE_W/NAME.log. env execs bash, so the timeout stops the command itself.
gate_cmd() {
  local name="$1" log="$GATE_W/$1.log" start rc=0 secs
  start=$(sf_now)
  (cd "$TREE" && sf_run_timeout "$GATE_TIMEOUT" env ${GATE_DROP[@]+"${GATE_DROP[@]}"} "$GATE_BASH" -c "$2") \
    </dev/null >"$log" 2>&1 || rc=$?
  secs=$(($(sf_now) - start))
  if [ "$rc" -eq 0 ]; then
    gate_report "$name" PASS "$secs"
  elif [ "$rc" -eq 124 ]; then
    gate_report "$name" FAIL "$secs" "timed out after ${GATE_TIMEOUT}s" "$log"
  else
    gate_report "$name" FAIL "$secs" "exit $rc" "$log"
  fi
}

# ---------------------------------------------------------------------------
# Checks that read the tree's data and history. They all run before any project command
# (setup, test, lint, typecheck run the tree's own code, which could rewrite its working
# files and the objects, refs and config in .git), and their results are reported in step
# order below.
# ---------------------------------------------------------------------------

GATE_MAP="$TREE/factory/feature-map.json"
GATE_SPEC="$TREE/factory/spec.md"
# The map and the spec are read only as regular files at their own paths. A symlink
# (factory/ itself, the map or the spec) would point the checks at a file that the map
# rules, which key on the path factory/feature-map.json, never see, or at a device that
# never ends. feature-map.sh only ever writes a regular file.
MAP_BAD=""
if [ -L "$TREE/factory" ]; then
  MAP_BAD="factory/ is a symlink; the map must live in the tree's own factory/ directory"
elif [ -L "$GATE_MAP" ] || { [ -e "$GATE_MAP" ] && [ ! -f "$GATE_MAP" ]; }; then
  MAP_BAD="factory/feature-map.json must be a regular file (feature-map.sh writes one), not a symlink or anything else"
fi
SPEC_BAD=""
if [ -L "$GATE_SPEC" ] || { [ -e "$GATE_SPEC" ] && [ ! -f "$GATE_SPEC" ]; }; then
  SPEC_BAD="factory/spec.md must be a regular file, not a symlink or anything else"
fi
HAS_MAP=0
if [ -n "$MAP_BAD" ] || [ -e "$GATE_MAP" ]; then HAS_MAP=1; fi

# gate.test: none is the bootstrap exemption, valid only while no feature is done. Its log
# is written now: once project code has run, the gate's own files are not to be trusted.
DONE_RC=0
DONE_IDS=""
# shellcheck disable=SC2016 # jq program
GATE_JQ_DONE='[.[] | objects | .features | arrays | .[] | objects | select(.status == "done")
  | .id | if type == "string" and test("\\AF[0-9]+\\z") then . else "(invalid id)" end] | join(" ")'
if sf_is_none "$CFG_TEST" && [ "$HAS_MAP" -eq 1 ]; then
  if [ -n "$MAP_BAD" ]; then
    printf '%s\n' "$MAP_BAD" >"$GATE_W/test.log"
    DONE_RC=1
  else
    DONE_IDS=$(sf_jq -r -s "$GATE_JQ_DONE" "$GATE_MAP" 2>"$GATE_W/test.log") || DONE_RC=$?
  fi
  if [ "$DONE_RC" -eq 0 ] && [ -n "$DONE_IDS" ]; then
    printf 'gate.test is none, but these features are done: %s\nOnce a feature is done the project needs a test command (gate.test).\n' \
      "$DONE_IDS" >"$GATE_W/test.log"
  fi
fi

# map: on a feature branch it always runs, so deleting the map cannot skip the --own rule.
MAP_RUN=0
MAP_RC=0
MAP_SECS=0
if [ "$HAS_MAP" -eq 1 ] || [ -n "$FID" ]; then
  MAP_RUN=1
  if [ -n "$MAP_BAD$SPEC_BAD" ] || [ "$HAS_MAP" -eq 0 ]; then
    {
      if [ -n "$MAP_BAD" ]; then printf '%s\n' "$MAP_BAD"; fi
      if [ "$HAS_MAP" -eq 0 ]; then
        printf 'factory/feature-map.json is missing from the tree; the feature branch factory/%s must keep the map\n' "$FID"
      fi
      if [ -n "$SPEC_BAD" ]; then printf '%s\n' "$SPEC_BAD"; fi
    } >"$GATE_W/map.log"
    MAP_RC=1
  else
    map_args=(validate --tree "$TREE" --map "$GATE_MAP" --config "$SF_CONFIG_FILE")
    if [ -e "$GATE_SPEC" ]; then
      map_args+=(--spec "$GATE_SPEC")
    fi
    if [ -n "$FID" ]; then
      map_args+=(--against "$BASE_SHA" --own "$FID")
    fi
    start=$(sf_now)
    bash "$SF_SCRIPTS_DIR/feature-map.sh" "${map_args[@]}" </dev/null >"$GATE_W/map.log" 2>&1 || MAP_RC=$?
    MAP_SECS=$(($(sf_now) - start))
  fi
fi

TT_RC=0
TT_SECS=0
if [ -n "$FID" ]; then
  start=$(sf_now)
  bash "$SF_SCRIPTS_DIR/feature-map.sh" check-tests "$FID" --tree "$TREE" --ref "$BASE_SHA" \
    --config "$SF_CONFIG_FILE" </dev/null >"$GATE_W/tests-tagged.log" 2>&1 || TT_RC=$?
  TT_SECS=$(($(sf_now) - start))
fi

# red-green, whole, before the tree's own code runs: it reads history, then checks out its
# throwaway worktrees and only then runs project code in them (lib/redgreen.sh, "Order").
# The tree's setup, which runs next, could otherwise rewrite the objects red/green reads.
RG_RC=0
RG_SECS=0
RG_SKIP=""
if [ -z "$FID" ]; then
  RG_SKIP="not a feature branch"
elif [ "$CFG_RG" != true ]; then
  RG_SKIP="gate.require_red_green is false"
else
  start=$(sf_now)
  (gate_unset_credentials && redgreen_check "$TREE" "$BASE_SHA" "$HEAD_SHA") </dev/null >"$GATE_W/red-green.log" 2>&1 ||
    RG_RC=$?
  RG_SECS=$(($(sf_now) - start))
fi

# gate_report_check NAME RC SECS WHAT: report a feature-map.sh result (0 pass, 1 no,
# anything else: it could not decide, so the step fails and the gate exits 2).
gate_report_check() {
  local log="$GATE_W/$1.log"
  case "$2" in
    0) gate_report "$1" PASS "$3" ;;
    1) gate_report "$1" FAIL "$3" "$4 said no" "$log" ;;
    *)
      GATE_ERROR=1
      gate_report "$1" FAIL "$3" "$4 could not decide: exit $2" "$log"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Steps, in contract order. setup, test, lint and typecheck run now; the checks above are
# only reported.
# ---------------------------------------------------------------------------

if sf_is_none "$CFG_SETUP"; then
  gate_skip setup "project.setup is none"
else
  gate_cmd setup "$CFG_SETUP"
fi

if [ "$GATE_FAILED" -eq 1 ]; then
  # A failed setup is a decisive fail of the tree's own code: the checks that already ran
  # are not reported, so one that could not decide does not turn the fail into "no verdict".
  for step in test lint typecheck map tests-tagged red-green; do
    gate_skip "$step" "setup failed"
  done
else
  # test
  if ! sf_is_none "$CFG_TEST"; then
    gate_cmd test "$CFG_TEST"
  elif [ "$DONE_RC" -ne 0 ]; then
    gate_report test FAIL 0 \
      "gate.test is none, and the tree's map could not be read to confirm that no feature is done" \
      "$GATE_W/test.log"
  elif [ -n "$DONE_IDS" ]; then
    gate_report test FAIL 0 "gate.test is none while a feature is done" "$GATE_W/test.log"
  else
    gate_skip test "gate.test is none and no feature is done"
  fi

  # lint, typecheck
  if sf_is_none "$CFG_LINT"; then gate_skip lint "gate.lint is none"; else gate_cmd lint "$CFG_LINT"; fi
  if sf_is_none "$CFG_TYPECHECK"; then
    gate_skip typecheck "gate.typecheck is none"
  else
    gate_cmd typecheck "$CFG_TYPECHECK"
  fi

  # map
  if [ "$MAP_RUN" -eq 0 ]; then
    gate_skip map "the tree has no factory/feature-map.json"
  else
    gate_report_check map "$MAP_RC" "$MAP_SECS" "feature-map.sh validate"
  fi

  # tests-tagged
  if [ -z "$FID" ]; then
    gate_skip tests-tagged "not a feature branch"
  else
    gate_report_check tests-tagged "$TT_RC" "$TT_SECS" "feature-map.sh check-tests $FID"
  fi

  # red-green. Only 0 and 1 are verdicts. Inconclusive (3), a bad call or config (2) or
  # anything else means red/green could not decide: the step fails, and the gate has no
  # verdict (exit 2).
  if [ -n "$RG_SKIP" ]; then
    gate_skip red-green "$RG_SKIP"
  else
    case "$RG_RC" in
      0) gate_report red-green PASS "$RG_SECS" ;;
      1) gate_report red-green FAIL "$RG_SECS" "the red/green check said no" "$GATE_W/red-green.log" ;;
      3)
        GATE_ERROR=1
        gate_report red-green FAIL "$RG_SECS" "inconclusive: the red/green check could not decide" "$GATE_W/red-green.log"
        ;;
      2)
        GATE_ERROR=1
        gate_report red-green FAIL "$RG_SECS" "the red/green check could not run: exit 2 (bad call or config)" \
          "$GATE_W/red-green.log"
        ;;
      *)
        GATE_ERROR=1
        gate_report red-green FAIL "$RG_SECS" "the red/green check could not decide: exit $RG_RC" "$GATE_W/red-green.log"
        ;;
    esac
  fi
fi

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------

# A check that could not decide outweighs every other result, a FAIL included: the run as a
# whole is inconclusive, so it exits 2 and is never recorded as a fix attempt.
if [ "$GATE_ERROR" -eq 1 ]; then
  RESULT=error
elif [ "$GATE_FAILED" -eq 1 ]; then
  RESULT=fail
else
  RESULT=pass
fi

if [ "$OPT_JSON" -eq 1 ]; then
  # shellcheck disable=SC2016 # jq program
  sf_jq -n -c --arg result "$RESULT" --arg head "$HEAD_SHA" --arg base "$BASE_SHA" \
    --arg branch "$OPT_BRANCH" --arg steps "$GATE_STEPS" '{
      result: $result,
      head: $head,
      base: (if $base == "" then null else $base end),
      branch: (if $branch == "" then null else $branch end),
      steps: [$steps | split("\n")[] | select(length > 0) | split(" ")
              | {name: .[0], result: (.[1] | ascii_downcase), secs: (.[2] | tonumber)}]
    }' || sf_die "internal error: could not build the JSON result"
fi

if [ "$GATE_ERROR" -eq 1 ]; then
  if [ -n "$OPT_PR" ]; then
    sf_warn "not recording a verdict on PR #$OPT_PR: a check could not decide"
  fi
  sf_die "a check could not decide (see above), so the gate has no verdict"
fi

if [ -n "$OPT_PR" ]; then
  failed=$(printf '%s' "$GATE_STEPS" | awk '$2 == "FAIL" { printf "%s%s", sep, $1; sep = ", " }')
  gate_comment() {
    printf '<!-- factory:gate result=%s sha=%s -->\n' "$RESULT" "$HEAD_SHA"
    if [ "$RESULT" = pass ]; then
      printf '**Gate passed** at %s' "$HEAD_SHA"
    else
      printf '**Gate failed** at %s' "$HEAD_SHA"
    fi
    if [ -n "$BASE_SHA" ]; then printf ' (base %s)' "$BASE_SHA"; fi
    printf '.\n'
    if [ -n "$failed" ]; then printf "Failed steps: %s. Their output is in the gate run's log.\n" "$failed"; fi
    # shellcheck disable=SC2016 # a Markdown code fence, not a command substitution
    printf '\n```text\n%s```\n' "$GATE_LINES"
  }
  # gate_post: run in a subshell. gh names the repository resolved before project code ran
  # (GH_REPO) and runs outside the tree, whose .git that code could have rewritten; if it
  # still runs git, the pinned git's directory comes first in its PATH. Assigning PATH
  # empties this subshell's hash table, so gh is pinned again by hand.
  gate_post() {
    cd / || return 1
    export GH_REPO="$GATE_REPO"
    if [ -n "$GATE_GIT_BIN" ]; then PATH="${GATE_GIT_BIN%/*}:$PATH"; fi
    if [ -n "$GATE_GH_BIN" ]; then hash -p "$GATE_GH_BIN" gh; fi
    gate_comment | sf_gh pr comment "$OPT_PR" --body-file -
  }
  # The body reaches gh through a pipe, not a file: project code has run by now and can reach
  # the gate's temp dir. Any failure to post means "not recorded" (2), never "no" (1).
  if ! gh_out=$(gate_post 2>&1); then
    sf_warn "could not post the gate comment on PR #$OPT_PR, so the verdict was not recorded: $(printf '%s\n' "$gh_out" | head -n 1 | tr -d '\r')"
    exit 2
  fi
  sf_log "recorded result=$RESULT for $HEAD_SHA on PR #$OPT_PR in $GATE_REPO"
fi

if [ "$GATE_FAILED" -eq 1 ]; then exit 1; fi
exit 0
}
