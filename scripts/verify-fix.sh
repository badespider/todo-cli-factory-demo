#!/usr/bin/env bash
# Checks a bug fix against its issue's repro: it must fail at base and pass at head, twice each. Contract: docs/CONTRACTS.md, "verify-fix.sh".
set -euo pipefail
SF_PROG=verify-fix
# shellcheck source=scripts/lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
# shellcheck source=scripts/lib/jq.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/jq.sh"
# shellcheck source=scripts/lib/config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"
# shellcheck source=scripts/lib/redgreen.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/redgreen.sh"

# The rest of this file is one brace group that ends in `exit`, so bash parses all of it
# before running any of it. bash reads a script file as it executes it, and the code this
# script runs (project.setup, the repros, red/green's tests) can write this file (same
# user; SF_FACTORY_ROOT is in its environment): an in-place rewrite would otherwise replace
# the rest of the judge. (Sourced files are read whole when sourced.)
{

# Pin the tools this shell (and red/green, which runs in a subshell of it) uses once project
# code has run: that code can put an executable named gh (which would get the token), git,
# env or bash in a PATH directory it can write to (~/.local/bin, say). bash looks a hashed
# name up in its table, never in PATH again. A tool that is missing stays missing.
# Red/green pins its own tools (find, cksum and ls fingerprint its green tree) when it starts,
# which here is after the base and head code ran: it keeps a path this shell already hashed,
# so every one of them is pinned here too.
hash bash git jq gh awk sed tr head tail cat wc date mktemp rm sleep cygpath env grep cut \
  mkdir od sort find touch dirname ls cksum 2>/dev/null || true
# env (an external program) finds the command it runs in PATH by itself: give it the
# pinned bash by its full path.
VF_BASH=$(type -P bash 2>/dev/null) || VF_BASH=""
[ -n "$VF_BASH" ] || sf_die "required command not found: bash"
VF_GIT=$(type -P git 2>/dev/null) || VF_GIT=""
[ -n "$VF_GIT" ] || sf_die "required command not found: git"

# Credentials are for this script (reading GitHub, recording an escape), never for project
# code: project.setup and red/green's runs execute what the PR (or the base branch) wrote.
# Project code runs through sf_scrubbed (every sf_credential_names entry removed, names bash
# can't hold included). The repro itself runs under env -i and gets nothing at all.

# vf_unset_credentials: in the subshell that calls it (red/green, a shell function, which env
# can't run), unset every sf_credential_names variable bash can hold. Entries whose names are
# not shell identifiers stay in the environment bash hands on: vf_red_green's git and
# lib/redgreen.sh's project code (env -u) lose them.
vf_unset_credentials() {
  local n
  while IFS= read -r n; do
    [ -z "$n" ] || unset -v "$n" 2>/dev/null || true
  done <<EOF
$(sf_credential_names)
EOF
  return 0
}

# vf_red_green BASE HEAD: redgreen_check without credentials. It runs after the base and head
# code ran, and that code can have written the repository's shared config and info/attributes
# (a smudge filter, a merge driver), which git runs when red/green checks out its worktrees or
# merges: every git it runs goes through sf_scrubbed (the pinned git, by its path), which also
# removes the entries bash can't unset.
vf_red_green() {
  (
    vf_unset_credentials
    git() { sf_scrubbed "$VF_GIT" "$@"; }
    redgreen_check "$VF_TREE" "$1" "$2"
  ) </dev/null >&2
}

# vf_git_bk ARGS...: sf_git_bk for the temporary worktrees (add, remove, prune), which runs
# again after project code ran. That code can write the repository's shared config and
# info/attributes from its worktree (a linked worktree shares them), and git runs the
# commands they name (a smudge filter, core.fsmonitor) during the next checkout: git, and so
# those commands, run through sf_scrubbed (the pinned git, by its path).
vf_git_bk() {
  (
    git() { sf_scrubbed "$VF_GIT" "$@"; }
    sf_git_bk "$@"
  )
}

usage() {
  cat <<'EOF'
Usage:
  verify-fix.sh --pr N                                 [--tree DIR] [--config FILE]
  verify-fix.sh --issue N --base SHA --head SHA        [--tree DIR] [--config FILE]
  verify-fix.sh --repro-file F --base SHA --head SHA   [--tree DIR] [--config FILE]
  verify-fix.sh --base-only (--issue N | --repro-file F) --base SHA [--tree DIR] [--config FILE]
  verify-fix.sh --audit [--days D]                     [--tree DIR] [--config FILE]

The repro is the first fenced block (```sh, ```bash, ```shell, bare ``` or ~~~) in the
section under a "### Repro" heading, plus an optional "expect: <substring>" line in that
section. It runs as a file (bash <file>) twice at base and twice at head, each time in a
fresh detached worktree after project.setup (run without credential-like variables), with
a clean environment (env -i: PATH, a fresh HOME and TMPDIR, SYSTEMROOT/WINDIR when set; no
tokens) and a timeout of limits.repro_timeout_seconds. Every base run is judged before any
head code runs.

Verified when both base runs fail (with output containing expect, when given), both
head runs exit 0, and, when a commit in BASE..HEAD touches gate.test_globs (a clean merge
of the base branch does not count), the red/green check passes (gate.test_globs: none
skips it). Exit 126/127 or a timeout at base is inconclusive.

  --pr N          PR N, when it is a bug fix: its head branch is factory/issue-<n> (n
                  without a leading zero), or it closes an issue of this repository
                  labeled role:bug-fix or bug. A factory/perf-<n> branch is a perf fix:
                  its name never makes the PR a bug fix (a closing bug issue still does).
                  Every bug issue is verified (the branch's issue first, then the closing
                  bug issues), each against head = the PR head and base = its merge-base
                  with the base branch: any "not verified" wins, then an error, then an
                  inconclusive. The head is fetched as refs/pull/N/head (a PR from a
                  fork too) and must be the head commit GitHub reports (else exit 2: the
                  PR moved). A PR that is not a bug fix prints
                  "not a bug fix: nothing to verify" and exits 0
  --issue N       issue N's repro, read from the issue's ORIGINAL revision. The author
                  must be OWNER, MEMBER or COLLABORATOR, and the issue must be labeled
                  role:bug-fix or bug
  --repro-file F  read the issue text from file F (offline; no trust checks)
  --base SHA      the base commit (with --issue or --repro-file)
  --head SHA      the head commit (with --issue or --repro-file, never with --base-only)
  --base-only     with --issue or --repro-file and --base, no --head: does the repro
                  still reproduce at base? The same trust checks and runs, at base only.
                  Exit 0 when both runs exit non-zero (with output containing expect,
                  when given): it reproduces; 1 when it does not; 3 when a run exits 124,
                  126 or 127 or the base tree can't be prepared; 2 on an error or an
                  untrusted repro
  --audit         re-run the repros of role:bug-fix issues closed as completed in the
                  last D days on origin/<base_branch>. A repro that fails there (any
                  non-zero exit but 124, 126 and 127: 1-123, 125, 128+) is an escape: its
                  issue is reopened, labeled escape and commented on. Exit 124, 126 or
                  127 means the repro could not run there: an error, never an escape
  --days D        with --audit: the window in days (default merge.audit_days)
  --tree DIR      the repository (default: the current repo root)
  --config FILE   config file (default: FACTORY_CONFIG, else the judging copy's)
  -h, --help      print this help and exit 0

stdout: one line per run with its exit code, then the verdict (with --base-only:
"verdict: reproduces", "verdict: does not reproduce: ..." or "verdict: inconclusive: ...").
Exit: 0 verified (or a PR that is not a bug fix, or an audit with no escape and no
error, or --base-only: it reproduces), 1 not verified (or an escape found, or
--base-only: it does not reproduce), 2 usage, config, GitHub error or untrusted repro (or
an audit with errors and no escape), 3 inconclusive.
EOF
}

vf_usage_die() {
  printf '%s: error: %s (see --help)\n' "$SF_PROG" "$1" >&2
  exit 2
}

# --- exit paths ------------------------------------------------------------------------

VF_TREE=""
VF_WORK=""
VF_WTS=()

# shellcheck disable=SC2329 # invoked by the EXIT trap (vf_on_exit)
vf_cleanup() {
  local wt
  if [ -n "$VF_TREE" ]; then
    for wt in ${VF_WTS[@]+"${VF_WTS[@]}"}; do
      [ -e "$wt" ] || continue
      vf_git_bk -C "$VF_TREE" worktree remove --force "$wt" >/dev/null 2>&1 || true
    done
  fi
  if [ -n "$VF_WORK" ]; then
    rm -rf "$VF_WORK" 2>/dev/null || true
  fi
  if [ -n "$VF_TREE" ]; then
    vf_git_bk -C "$VF_TREE" worktree prune >/dev/null 2>&1 || true
  fi
  return 0
}

# An unexpected failure under set -e exits 1, which would read as "not verified"; the EXIT
# trap (set before anything else can fail) turns any exit 1 that was not chosen on purpose
# (vf_exit) into 2.
VF_DONE=""
vf_exit() {
  VF_DONE=1
  exit "$1"
}

# shellcheck disable=SC2329 # invoked by the EXIT trap
vf_on_exit() {
  local st=$?
  vf_cleanup
  if [ "$st" -eq 1 ] && [ -z "$VF_DONE" ]; then
    printf '%s: error: unexpected failure; treating it as an error, not as a verdict\n' "$SF_PROG" >&2
    st=2
  fi
  exit "$st"
}
trap 'vf_on_exit' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Original revision of an issue. Each userContentEdits entry's diff is the full text of
# that version; the oldest one is the text as filed. totalCount shows whether one page
# held them all.
# shellcheck disable=SC2016
VF_ISSUE_QUERY='query($owner: String!, $name: String!, $number: Int!) { repository(owner: $owner, name: $name) { issue(number: $number) { body authorAssociation labels(first: 100) { nodes { name } } userContentEdits(first: 100) { totalCount nodes { createdAt diff } } } } }'

# One tab-separated line: found, author association, has a bug label (yes, no, or unknown
# when the answer holds no list of labels), where the original text comes from. No field is
# ever empty (read would merge adjacent tabs).
# Label names are compared without case, as GitHub (and ship.sh) do.
# The body is the LATEST text, so it is used only when the history is known to be empty:
# a missing history, or one that counts edits it does not list, can't fall back to it.
# Two different versions sharing the oldest timestamp make the original ambiguous.
# shellcheck disable=SC2016
VF_ISSUE_META='
  .data.repository.issue as $i
  | if ($i | type) != "object" then "missing\t-\t-\t-"
    else
      $i.userContentEdits as $e
      | [ "ok",
          (($i.authorAssociation // "-") | tostring | gsub("[^A-Za-z_]"; "?") | if . == "" then "-" else . end),
          (if ($i.labels | type) != "object" or ($i.labels.nodes | type) != "array" then "unknown"
           elif ([$i.labels.nodes[] | objects | .name // "" | tostring | ascii_downcase]
               | any(. == "role:bug-fix" or . == "bug")) then "yes" else "no" end),
          (if ($e | type) != "object" or ($e.nodes | type) != "array" or ($e.totalCount | type) != "number" then "nohistory"
           elif $e.totalCount > ($e.nodes | length) then "truncated"
           elif ($e.nodes | length) == 0 then (if ($i.body | type) == "string" then "body" else "nobody" end)
           elif ([$e.nodes[] | select(type != "object" or (.createdAt | type) != "string")] | length) > 0 then "nodate"
           else
             ($e.nodes | min_by(.createdAt) | .createdAt) as $t0
             | [$e.nodes[] | select(.createdAt == $t0) | .diff] as $oldest
             | if ($oldest[0] | type) != "string" then "deleted"
               elif ($oldest | unique | length) > 1 then "ambiguous"
               else "edit\($e.nodes | length)" end
           end)
        ] | join("\t")
    end'

# shellcheck disable=SC2016
VF_ISSUE_TEXT='
  .data.repository.issue as $i
  | ($i.userContentEdits.nodes // []) as $n
  | if ($n | length) == 0 then $i.body else ($n | sort_by(.createdAt) | .[0].diff) end'

# Every closing reference that points at this repository, in order, one number per line (a
# cross-repo "closes other/repo#5" must not be looked up here as #5). A reference whose
# repository fields are missing counts as this repository: dropping it would drop the
# verification. "bad" marks a reference of this repository without a usable number.
# shellcheck disable=SC2016
VF_CLOSING='
  (.closingIssuesReferences // []) as $refs
  | if ($refs | type) != "array" then error("closingIssuesReferences is not a list") else $refs[] end
  | if type != "object" then "bad"
    elif ((.repository.name // $name) | tostring | ascii_downcase) == ($name | ascii_downcase)
         and ((.repository.owner.login // $owner) | tostring | ascii_downcase) == ($owner | ascii_downcase)
    then (.number | if type == "number" and . > 0 and . == floor and . < 1000000000 then tostring else "bad" end)
    else empty end'

# Closed role:bug-fix issues: completed, and closed at or after $cut (epoch seconds). A
# closedAt that cannot be parsed keeps the issue in (auditing too much is safe).
# shellcheck disable=SC2016
VF_AUDIT_FILTER='
  if type != "array" then error("not a list of issues") else . end
  | [ .[] | select(type == "object" and .stateReason == "COMPLETED")
      | select(((.closedAt // "") | tostring
                | (try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch null)) as $t
               | $t == null or $t >= $cut)
      | .number | select(type == "number" and . > 0 and . == floor) ]
  | unique | .[]'

# Repro parser: a pure function of the issue text. Writes the block to rfile and the
# expect value to efile. Exit 3: no "### Repro" heading; 4: no fenced block in that
# section; 5: the block is not closed; 6: the section's first block is not a shell block.
# POSIX awk (no interval expressions), run with LC_ALL=C.
# shellcheck disable=SC2016
VF_PARSE_AWK='
function lead(s,    i) { i = 0; while (substr(s, i + 1, 1) == " ") i++; return i }
function runlen(s, c, from,    n) { n = 0; while (substr(s, from + n, 1) == c) n++; return n }
BEGIN { insec = 0; seen = 0; done = 0; infence = 0; cap = 0; incomment = 0; rejected = 0; haveexp = 0; buf = ""; expect = "" }
{
  line = $0
  sub(/\r$/, "", line)
  if (NR == 1 && bom != "" && index(line, bom) == 1) line = substr(line, length(bom) + 1)
  ind = lead(line)
  if (infence) {
    if (ind <= 3 && substr(line, ind + 1, 1) == fch) {
      n = runlen(line, fch, ind + 1)
      rest = substr(line, ind + 1 + n)
      if (n >= flen && rest ~ /^[ \t]*$/) {
        infence = 0
        if (cap) { cap = 0; done = 1 }
        next
      }
    }
    if (cap) {
      k = (ind < find) ? ind : find
      buf = buf substr(line, k + 1) "\n"
    }
    next
  }
  if (incomment) {
    if (index(line, "-->") > 0) incomment = 0
    next
  }
  if (ind <= 3) {
    c = substr(line, ind + 1, 1)
    if (c == "`" || c == "~") {
      n = runlen(line, c, ind + 1)
      info = substr(line, ind + 1 + n)
      if (n >= 3 && !(c == "`" && index(info, "`") > 0)) {
        infence = 1; fch = c; flen = n; find = ind
        if (insec && !done && !rejected) {
          sub(/^[ \t]+/, "", info)
          sub(/[ \t].*$/, "", info)
          lang = tolower(info)
          if (lang == "" || lang == "sh" || lang == "bash" || lang == "shell") cap = 1
          else rejected = 1
        }
        next
      }
    }
    rest = substr(line, ind + 1)
    if (substr(rest, 1, 4) == "<!--") {
      if (index(substr(rest, 5), "-->") == 0) incomment = 1
      next
    }
    if (substr(rest, 1, 1) == "#") {
      n = runlen(rest, "#", 1)
      after = substr(rest, n + 1, 1)
      if (n <= 6 && (after == "" || after == " " || after == "\t")) {
        if (insec && n <= 3) insec = 0
        if (!seen && line ~ /^### Repro[ \t]*$/) { insec = 1; seen = 1 }
        next
      }
    }
  }
  if (insec && !haveexp && line ~ /^[ \t]*expect:/) {
    v = line
    sub(/^[ \t]*expect:[ \t]*/, "", v)
    sub(/[ \t]+$/, "", v)
    if (length(v) >= 2 && substr(v, 1, 1) == "`" && substr(v, length(v), 1) == "`") v = substr(v, 2, length(v) - 2)
    if (v != "") { expect = v; haveexp = 1 }
  }
}
END {
  if (!seen) exit 3
  if (cap) exit 5
  if (!done && rejected) exit 6
  if (!done) exit 4
  printf "%s", buf > rfile
  printf "%s", expect > efile
  exit 0
}'

# --- arguments -------------------------------------------------------------------------

mode=""
VF_NUM=""
VF_FILE=""
base_arg=""
head_arg=""
base_given=0
head_given=0
base_only=0
days=""
days_given=0
tree=""
config=""

vf_set_mode() {
  [ -z "$mode" ] || vf_usage_die "give only one of --pr, --issue, --repro-file and --audit"
  mode="$1"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --*=*)
      opt="${1%%=*}"
      val="${1#*=}"
      shift
      set -- "$opt" "$val" ${1+"$@"}
      continue
      ;;
  esac
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --audit)
      vf_set_mode audit
      shift
      continue
      ;;
    --base-only)
      base_only=1
      shift
      continue
      ;;
    --pr | --issue | --repro-file | --base | --head | --days | --tree | --config)
      # An empty value (an unset variable in a workflow) must not silently mean the default.
      [ "$#" -ge 2 ] && [ -n "$2" ] || vf_usage_die "$1 needs a value"
      ;;
    *) vf_usage_die "unknown argument: $1" ;;
  esac
  case "$1" in
    --pr) vf_set_mode pr; VF_NUM="$2" ;;
    --issue) vf_set_mode issue; VF_NUM="$2" ;;
    --repro-file) vf_set_mode file; VF_FILE="$2" ;;
    --base) base_arg="$2"; base_given=1 ;;
    --head) head_arg="$2"; head_given=1 ;;
    --days) days="$2"; days_given=1 ;;
    --tree) tree="$2" ;;
    --config) config="$2" ;;
  esac
  shift 2
done

[ -n "$mode" ] || vf_usage_die "give one of --pr, --issue, --repro-file or --audit"
case "$mode" in
  pr | issue)
    case "$VF_NUM" in
      '' | 0* | *[!0-9]* | ??????????*) vf_usage_die "--$mode needs a number: $VF_NUM" ;;
    esac
    ;;
esac
if [ "$base_only" -eq 1 ]; then
  case "$mode" in
    issue | file) ;;
    *) vf_usage_die "--base-only goes with --issue or --repro-file only" ;;
  esac
  [ "$head_given" -eq 0 ] || vf_usage_die "--head does not go with --base-only (it runs the repro at --base only)"
fi
case "$mode" in
  issue | file)
    if [ "$base_given" -eq 0 ] || [ -z "$base_arg" ]; then vf_usage_die "--$mode needs --base"; fi
    if [ "$base_only" -eq 0 ]; then
      if [ "$head_given" -eq 0 ] || [ -z "$head_arg" ]; then vf_usage_die "--$mode needs --head"; fi
    fi
    for r in "$base_arg" "$head_arg"; do
      case "$r" in -* | *[[:space:]]*) vf_usage_die "--base and --head must be revisions: $r" ;; esac
    done
    ;;
  *)
    if [ "$base_given" -eq 1 ] || [ "$head_given" -eq 1 ]; then
      vf_usage_die "--base and --head go with --issue or --repro-file only"
    fi
    ;;
esac
if [ "$days_given" -eq 1 ]; then
  [ "$mode" = audit ] || vf_usage_die "--days goes with --audit only"
  case "$days" in '' | 0* | *[!0-9]* | ??????*) vf_usage_die "--days needs a positive number of days: $days" ;; esac
fi
if [ "$mode" = file ]; then
  [ -f "$VF_FILE" ] && [ -r "$VF_FILE" ] || vf_usage_die "repro file not found or unreadable: $VF_FILE"
fi

if [ "$mode" != file ]; then
  [ "${FACTORY_OFFLINE:-}" != 1 ] || sf_die "--$mode needs GitHub, but FACTORY_OFFLINE=1 (use --repro-file offline)"
  sf_need gh jq
fi
# Also every tool used once project code has run (pinned by the hash above), red/green's
# included: a name hash could not find would be looked up in PATH again later.
sf_need git bash env awk sort tr grep sed head tail cat cut mkdir mktemp rm sleep find ls cksum

# --- config ----------------------------------------------------------------------------

if [ -n "$config" ]; then
  sf_config_load "$config"
else
  sf_config_load
fi

# vf_posint KEY DEFAULT: a config value that must be a positive decimal number.
vf_posint() {
  local v
  v=$(sf_cfg "$1" "$2")
  case "$v" in '' | *[!0-9]* | ?????????*) sf_die "$SF_CONFIG_FILE: $1 must be a positive number: '$v'" ;; esac
  v=$((10#$v))
  [ "$v" -gt 0 ] || sf_die "$SF_CONFIG_FILE: $1 must be a positive number: '$v'"
  printf '%s\n' "$v"
}

VF_SECS=$(vf_posint limits.repro_timeout_seconds 120)
VF_SETUP_SECS=$(vf_posint limits.agent_timeout_minutes 45)
VF_SETUP_SECS=$((VF_SETUP_SECS * 60))
VF_SETUP=$(sf_cfg project.setup none)
VF_BASE_BRANCH=$(sf_cfg base_branch main)
if [ "$mode" = audit ] && [ "$days_given" -eq 0 ]; then
  days=$(vf_posint merge.audit_days 14)
fi

# gate.test_globs is required: a missing key, or one whose items are all commented out,
# exits 2. none = the project has no test files, so red/green is skipped.
sf_cfg_require_globs gate.test_globs
VF_SPECS=()
while IFS= read -r g; do
  [ -n "$g" ] || continue
  case "$g" in :*) VF_SPECS+=("$g") ;; *) VF_SPECS+=(":(glob)$g") ;; esac
done <<EOF
$(sf_cfg_globs gate.test_globs)
EOF

# --- tree and work dir -----------------------------------------------------------------

if [ -z "$tree" ]; then
  tree=$(sf_repo_root)
fi
[ -d "$tree" ] || vf_usage_die "--tree is not a directory: $tree"
# A directory that can't be entered (no search permission) can't be judged: an error, never
# "not verified".
vf_tree=$(CDPATH='' cd -- "$tree" && pwd) && [ -n "$vf_tree" ] ||
  sf_die "cannot enter the --tree directory: $tree"
VF_TREE="$vf_tree"
git -C "$VF_TREE" rev-parse --git-dir >/dev/null 2>&1 || sf_die "not a git repository: $VF_TREE"
VF_REMOTE=$(sf_remote)

# Absolute TMPDIR: `git -C TREE worktree add` would read a relative path against TREE.
TMPDIR=$(CDPATH='' cd -- "${TMPDIR:-/tmp}" 2>/dev/null && pwd) || sf_die "TMPDIR is not a usable directory"
export TMPDIR

VF_WORK=$(sf_mktemp_dir) || sf_die "cannot create a temporary directory"

# --- helpers ---------------------------------------------------------------------------

vf_short() { printf '%s' "$1" | cut -c1-12; }

# Untrusted text on stderr: control characters (terminal escapes, CR) removed, every line
# indented, so it can never pass for one of this script's own lines.
vf_sanitize() { LC_ALL=C tr -d '\000-\010\013-\037\177'; }
vf_quote_lines() { vf_sanitize | sed 's/^/  | /' >&2; }

vf_tail() {
  [ -s "$1" ] || return 0
  tail -n 40 "$1" | vf_quote_lines
}

# vf_gh ARGS...: gh from inside the tree, so it resolves the repository from it.
vf_gh() { (cd "$VF_TREE" && sf_gh "$@"); }

# vf_quote TEXT: TEXT as one JSON string. Untrusted text that is not quoted line by line
# (a branch name the PR's author chose) is printed this way: as data, with clear ends.
# shellcheck disable=SC2016
vf_quote() { sf_jq -n --arg s "$1" '$s'; }

# vf_valid_branch NAME: a plain branch name that is safe to put in a refspec.
vf_valid_branch() {
  case "$1" in '' | -* | *[[:space:]]* | *:*) return 1 ;; esac
  git check-ref-format "refs/heads/$1" >/dev/null 2>&1
}

# vf_fetch BRANCH: fetch BRANCH from the remote into refs/remotes/<remote>/BRANCH and print
# its commit. Bookkeeping git: the project's hooks (reference-transaction) never run.
vf_fetch() {
  local b="$1"
  sf_git_bk -C "$VF_TREE" fetch -q --no-tags "$VF_REMOTE" "+refs/heads/$b:refs/remotes/$VF_REMOTE/$b" >&2 ||
    return 1
  git -C "$VF_TREE" rev-parse --verify -q "refs/remotes/$VF_REMOTE/$b^{commit}"
}

# vf_fetch_pr N: fetch PR N's head the way GitHub publishes it, refs/pull/N/head on the
# remote (it exists for a PR from a fork too, whose branch is not on the remote), into
# refs/remotes/pull/N/head, and print its commit. Bookkeeping git, like vf_fetch.
vf_fetch_pr() {
  local ref="refs/remotes/pull/$1/head"
  sf_git_bk -C "$VF_TREE" fetch -q --no-tags "$VF_REMOTE" "+refs/pull/$1/head:$ref" >&2 || return 1
  git -C "$VF_TREE" rev-parse --verify -q "$ref^{commit}"
}

VF_OWNER=""
VF_NAME=""
# vf_repo: owner and name of the repository (for the GraphQL query and closing refs).
vf_repo() {
  local out tsv
  [ -z "$VF_OWNER" ] || return 0
  out=$(vf_gh repo view --json owner,name) || {
    sf_log "could not read the repository (gh repo view)"
    return 1
  }
  tsv=$(printf '%s\n' "$out" | sf_jq -r '[(.owner.login // "-"), (.name // "-")] | map(tostring) | @tsv' 2>/dev/null) || {
    sf_log "could not parse the output of gh repo view"
    return 1
  }
  IFS=$'\t' read -r VF_OWNER VF_NAME <<<"$tsv"
  case "$VF_OWNER" in '' | - | *[!A-Za-z0-9._-]*) VF_OWNER="" ;; esac
  case "$VF_NAME" in '' | - | *[!A-Za-z0-9._-]*) VF_NAME="" ;; esac
  if [ -z "$VF_OWNER" ] || [ -z "$VF_NAME" ]; then
    VF_OWNER=""
    sf_log "gh repo view returned no usable owner and name"
    return 1
  fi
}

VF_REPRO=""
VF_EXPECT=""
VF_WHY=""

# vf_parse FILE: the repro and expect from an issue text. 0, or 2 with VF_WHY set.
vf_parse() {
  local st=0 bom
  bom=$(printf '\357\273\277')
  rm -f "$VF_WORK/parsed.repro" "$VF_WORK/parsed.expect"
  LC_ALL=C awk -v bom="$bom" -v rfile="$VF_WORK/parsed.repro" -v efile="$VF_WORK/parsed.expect" \
    "$VF_PARSE_AWK" "$1" >&2 || st=$?
  case "$st" in
    0) ;;
    3) VF_WHY='no repro: the text has no "### Repro" heading' ;;
    4) VF_WHY='no repro: no fenced code block in the "### Repro" section' ;;
    5) VF_WHY='no repro: the code block in the "### Repro" section is never closed' ;;
    6) VF_WHY='no repro: the first code block in the "### Repro" section is not a shell block (fence it as sh, bash, shell or bare)' ;;
    *) VF_WHY="no repro: the issue text could not be parsed (awk exited $st)" ;;
  esac
  if [ "$st" -ne 0 ]; then
    sf_log "$VF_WHY"
    return 2
  fi
  VF_REPRO=$(tr -d '\000' <"$VF_WORK/parsed.repro")
  VF_EXPECT=$(tr -d '\000\r\n' <"$VF_WORK/parsed.expect")
  case "$VF_REPRO" in
    *[![:space:]]*) ;;
    *)
      VF_WHY='no repro: the code block in the "### Repro" section is empty'
      sf_log "$VF_WHY"
      return 2
      ;;
  esac
  return 0
}

# Metadata of the issue vf_issue_fetch read last.
VF_M_ASSOC=""
VF_M_LABEL=""
VF_M_SRC=""

# vf_issue_fetch N: reads issue N (one GraphQL query; owner and name go as strings with -f,
# the number as a number with -F), keeps the answer in $VF_WORK/issue-N.json and sets
# VF_M_*. 0, or 5 when GitHub could not be read (VF_WHY says why).
vf_issue_fetch() {
  local n="$1" resp meta found
  VF_WHY=""
  VF_M_ASSOC=""
  VF_M_LABEL=""
  VF_M_SRC=""
  if ! vf_repo; then
    VF_WHY="could not read the repository's owner and name"
    return 5
  fi
  resp=$(vf_gh api graphql -f query="$VF_ISSUE_QUERY" -f owner="$VF_OWNER" -f name="$VF_NAME" -F number="$n") || {
    VF_WHY="the GitHub query failed"
    sf_log "issue #$n: $VF_WHY"
    return 5
  }
  printf '%s\n' "$resp" >"$VF_WORK/issue-$n.json" || sf_die "cannot write $VF_WORK/issue-$n.json"
  meta=$(sf_jq -r "$VF_ISSUE_META" "$VF_WORK/issue-$n.json" 2>/dev/null) || {
    VF_WHY="could not parse the GitHub response"
    sf_log "issue #$n: $VF_WHY"
    return 5
  }
  IFS=$'\t' read -r found VF_M_ASSOC VF_M_LABEL VF_M_SRC <<<"$meta"
  if [ "$found" != ok ]; then
    VF_WHY="not found"
    sf_log "issue #$n: not found"
    return 5
  fi
  return 0
}

# vf_issue_load N: after vf_issue_fetch N, the trust checks and the repro from the issue's
# original revision. 0 = VF_REPRO/VF_EXPECT set; 2 = untrusted or unparsable (VF_WHY says
# why); 5 = the text could not be extracted.
vf_issue_load() {
  local n="$1"
  VF_WHY=""
  case "$VF_M_ASSOC" in
    OWNER | MEMBER | COLLABORATOR) ;;
    *)
      VF_WHY="untrusted: the author's association is $VF_M_ASSOC; only repros by OWNER, MEMBER or COLLABORATOR are run"
      sf_log "issue #$n: $VF_WHY"
      return 2
      ;;
  esac
  case "$VF_M_LABEL" in
    yes) ;;
    no) VF_WHY="not a bug: the issue has neither the label role:bug-fix nor bug" ;;
    *) VF_WHY="GitHub returned no list of the issue's labels, so whether it is a bug is unknown" ;;
  esac
  if [ -n "$VF_WHY" ]; then
    sf_log "issue #$n: $VF_WHY"
    return 2
  fi
  case "$VF_M_SRC" in
    body) sf_log "issue #$n: never edited; using its body" ;;
    edit*) sf_log "issue #$n: using the original revision (the oldest of ${VF_M_SRC#edit} recorded versions)" ;;
    truncated) VF_WHY="the issue has more edits than one query returns, so its original revision cannot be read" ;;
    nohistory) VF_WHY="GitHub returned no usable edit history (userContentEdits), so the original revision is unknown" ;;
    deleted) VF_WHY="the original revision was deleted from the issue's edit history" ;;
    ambiguous) VF_WHY="the oldest versions in the issue's edit history share a timestamp but differ, so the original revision is ambiguous" ;;
    nodate) VF_WHY="an edit in the issue's history has no date, so the original revision is unknown" ;;
    *) VF_WHY="the issue has no text" ;;
  esac
  if [ -n "$VF_WHY" ]; then
    sf_log "issue #$n: $VF_WHY"
    return 2
  fi
  sf_jq -j "$VF_ISSUE_TEXT" "$VF_WORK/issue-$n.json" >"$VF_WORK/issue-$n.md" || {
    VF_WHY="could not extract the original text"
    sf_log "issue #$n: $VF_WHY"
    return 5
  }
  vf_parse "$VF_WORK/issue-$n.md" || return 2
  return 0
}

# vf_issue_repro N: the repro from issue N's original revision, after the trust checks.
# 0 = VF_REPRO/VF_EXPECT set; 2 = untrusted or unparsable (VF_WHY says why); 5 = GitHub
# could not be read.
vf_issue_repro() {
  local rc=0
  vf_issue_fetch "$1" || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  vf_issue_load "$1" || rc=$?
  return "$rc"
}

# The repros to run, one entry per issue (one entry in --repro-file mode), all read into
# memory before any project code runs. STATE: run (REPRO/EXPECT hold the repro), error
# (WHY says why it cannot run), skip (--audit: untrusted or unparsable).
VF_I_NUM=()
VF_I_STATE=()
VF_I_WHY=()
VF_I_REPRO=()
VF_I_EXPECT=()

vf_add_issue() { # NUM: the repro in VF_REPRO/VF_EXPECT
  VF_I_NUM+=("$1")
  VF_I_STATE+=(run)
  VF_I_WHY+=("")
  VF_I_REPRO+=("$VF_REPRO")
  VF_I_EXPECT+=("$VF_EXPECT")
}

vf_add_other() { # NUM STATE WHY
  VF_I_NUM+=("$1")
  VF_I_STATE+=("$2")
  VF_I_WHY+=("$3")
  VF_I_REPRO+=("")
  VF_I_EXPECT+=("")
}

# vf_show_repro K PREFIX: entry K's repro and expect, on stderr.
vf_show_repro() {
  sf_log "${2}repro:"
  printf '%s\n' "${VF_I_REPRO[$1]}" | vf_quote_lines
  if [ -n "${VF_I_EXPECT[$1]}" ]; then
    sf_log "${2}expect: $(printf '%s' "${VF_I_EXPECT[$1]}" | vf_sanitize)"
  else
    sf_log "${2}expect: (none; any non-zero exit at base counts)"
  fi
}

# vf_prepare NAME SHA: detached worktree $VF_WORK/wt-NAME at SHA, then project.setup
# (credential-like variables removed). Returns 1 (after saying why) when the tree is unusable.
vf_prepare() {
  local name="$1" sha="$2" wt="$VF_WORK/wt-$1" st=0
  # Register first: a half-created worktree must still be removed.
  VF_WTS+=("$wt")
  # core.autocrlf=false: run the committed bytes whatever the machine's git config says.
  # vf_git_bk: the project's checkout hooks neither run nor fail the add, and whatever the
  # config names by now runs without credentials.
  if ! vf_git_bk -C "$VF_TREE" -c core.autocrlf=false \
    worktree add --detach "$wt" "$sha" >"$VF_WORK/$name.worktree.log" 2>&1 || [ ! -d "$wt" ]; then
    sf_log "could not create a worktree at $(vf_short "$sha")"
    vf_tail "$VF_WORK/$name.worktree.log"
    return 1
  fi
  if ! sf_is_none "$VF_SETUP"; then
    # sf_scrubbed_exec: the timed process becomes setup's own bash, so the timeout signals
    # setup itself. bash does not reliably exec the last command of a backgrounded function
    # (5.2 does not; 5.3 not when run from a -c string), and a signal to the function's
    # subshell would leave setup running.
    (cd "$wt" && sf_run_timeout "$VF_SETUP_SECS" sf_scrubbed_exec "$VF_BASH" -c "$VF_SETUP") \
      </dev/null >"$VF_WORK/$name.setup.log" 2>&1 || st=$?
    if [ "$st" -ne 0 ]; then
      sf_log "project.setup exited $st in the ${name%%-*} tree ($(vf_short "$sha"))"
      vf_tail "$VF_WORK/$name.setup.log"
      return 1
    fi
  fi
  return 0
}

# vf_drop NAME: remove the worktree of vf_prepare NAME now.
vf_drop() {
  local wt="$VF_WORK/wt-$1"
  [ -e "$wt" ] || return 0
  vf_git_bk -C "$VF_TREE" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt" 2>/dev/null || true
  vf_git_bk -C "$VF_TREE" worktree prune >/dev/null 2>&1 || true
}

# vf_run TAG NAME K: run entry K's repro once in the NAME worktree; returns its exit status
# (124 = timed out). The repro is a file, written from memory for every run, and runs
# under env -i with only PATH (plus SYSTEMROOT/WINDIR when set) and a fresh HOME and
# TMPDIR, so no token or credential of this process can reach it. Output:
# $VF_WORK/run-TAG/out. The run directory must be new: nothing may sit in HOME or TMPDIR.
vf_run() {
  local d="$VF_WORK/run-$1" wt="$VF_WORK/wt-$2" st=0
  local envv=()
  if ! mkdir "$d" || ! mkdir "$d/home" "$d/tmp"; then sf_die "cannot create a fresh $d"; fi
  printf '%s\n' "${VF_I_REPRO[$3]}" >"$d/repro.sh" || sf_die "cannot write $d/repro.sh"
  envv=("PATH=$PATH" "HOME=$d/home" "TMPDIR=$d/tmp")
  if [ -n "${SYSTEMROOT:-}" ]; then envv+=("SYSTEMROOT=$SYSTEMROOT"); fi
  if [ -n "${WINDIR:-}" ]; then envv+=("WINDIR=$WINDIR"); fi
  # A tree it can't be started in: the repro could not run (126), which must never read as
  # the exit 1 of a repro that failed (at base, "it reproduces").
  (
    cd "$wt" || {
      printf '%s: cannot enter the worktree; the repro did not run\n' "$SF_PROG" >&2
      exit 126
    }
    sf_run_timeout "$VF_SECS" env -i "${envv[@]}" "$VF_BASH" "$d/repro.sh"
  ) </dev/null >"$d/out" 2>&1 || st=$?
  return "$st"
}

# vf_has_expect TAG K: run TAG's output contains entry K's expect text (NUL and CR ignored).
vf_has_expect() {
  local f="$VF_WORK/run-$1/out" e="${VF_I_EXPECT[$2]}"
  [ -n "$e" ] || return 0
  LC_ALL=C tr -d '\000\r' <"$f" >"$f.clean" || return 1
  LC_ALL=C grep -F -q -e "$e" -- "$f.clean"
}

vf_print_run() { # PREFIX SIDE N STATUS
  case "$4" in
    124) printf '%s%s run %s: exit 124 (timed out after %ss)\n' "$1" "$2" "$3" "$VF_SECS" ;;
    *) printf '%s%s run %s: exit %s\n' "$1" "$2" "$3" "$4" ;;
  esac
}

vf_print_verdict() { # PREFIX VERDICT REASON
  case "$2" in
    0) printf '%sverdict: verified\n' "$1" ;;
    1) printf '%sverdict: not verified: %s\n' "$1" "$3" ;;
    3) printf '%sverdict: inconclusive: %s\n' "$1" "$3" ;;
    *) printf '%sverdict: error: %s\n' "$1" "$3" ;;
  esac
}

# vf_cannot_run STATUS: the repro could not run at all (timeout, not executable, not found).
vf_cannot_run() {
  case "$1" in 124 | 126 | 127) return 0 ;; esac
  return 1
}

# vf_clean_base_merge C BASE: C is a two-parent merge with a parent already in BASE whose
# tree is exactly git's automatic merge of its parents (lib/redgreen.sh's "clean base
# merge"): the base branch arriving, not the branch's own work. Needs git 2.38+
# (merge-tree --write-tree, which exits 1 on conflicts but still prints the tree first);
# without it no merge is clean.
vf_clean_base_merge() {
  local c="$1" auto tree st=0
  git -C "$VF_TREE" merge-base --is-ancestor "$c^2" "$2" 2>/dev/null ||
    git -C "$VF_TREE" merge-base --is-ancestor "$c^1" "$2" 2>/dev/null || return 1
  auto=$(git -C "$VF_TREE" merge-tree --write-tree --no-messages "$c^1" "$c^2" 2>/dev/null) || st=$?
  case "$st" in 0 | 1) ;; *) return 1 ;; esac
  tree=$(git -C "$VF_TREE" rev-parse --verify -q "$c^{tree}") || return 1
  [ -n "$tree" ] && [ "${auto%%$'\n'*}" = "$tree" ]
}

# vf_touches_tests BASE HEAD: 0 when a commit in BASE..HEAD changes a gate.test_globs file
# (a merge is compared with its first parent, and a clean base merge is skipped, as
# lib/redgreen.sh does when it looks for the tests-only commit: test files the base branch
# changed are not the fix's tests), 1 when none does, 2 when git failed, 4 when
# gate.test_globs is none.
vf_touches_tests() {
  local c p1 p2 rest
  [ "${#VF_SPECS[@]}" -gt 0 ] || return 4
  git -C "$VF_TREE" rev-list --parents "$1..$2" >"$VF_WORK/revs" 2>"$VF_WORK/revs.err" || {
    vf_tail "$VF_WORK/revs.err"
    return 2
  }
  # diff-tree --stdin reads "<commit> <parent>": each commit against its first parent.
  while read -r c p1 p2 rest; do
    [ -n "$c" ] || continue
    if [ -n "$p2" ] && [ -z "$rest" ] && vf_clean_base_merge "$c" "$1"; then continue; fi
    if [ -n "$p1" ]; then printf '%s %s\n' "$c" "$p1"; else printf '%s\n' "$c"; fi
  done <"$VF_WORK/revs" >"$VF_WORK/pairs"
  [ -s "$VF_WORK/pairs" ] || return 1
  git -C "$VF_TREE" diff-tree --stdin -r --name-only --root -- "${VF_SPECS[@]}" \
    <"$VF_WORK/pairs" >"$VF_WORK/touched" 2>"$VF_WORK/revs.err" || {
    vf_tail "$VF_WORK/revs.err"
    return 2
  }
  [ -s "$VF_WORK/touched" ]
}

# The base runs of every entry: VF_BOK[K] is 1 when entry K's base tree was prepared (and
# its repro ran twice there), else 0. Run I (1 or 2) of entry K is at index K*2+I-1 of
# VF_BS (its exit status) and VF_BE (yes or no: its output holds the expect text).
VF_BOK=()
VF_BS=()
VF_BE=()

# vf_base_runs K BASE: prepare a tree at BASE and run entry K's repro there twice. Each run
# is judged (exit code and expect) right after it runs, before any later code can touch
# its output.
vf_base_runs() {
  local k="$1" i j st
  VF_BOK[k]=0
  if vf_prepare "base-$k" "$2"; then
    VF_BOK[k]=1
    for i in 1 2; do
      j=$((k * 2 + i - 1))
      st=0
      vf_run "$k-base-$i" "base-$k" "$k" || st=$?
      VF_BS[j]="$st"
      if vf_has_expect "$k-base-$i" "$k"; then VF_BE[j]=yes; else VF_BE[j]=no; fi
    done
  fi
  vf_drop "base-$k"
}

# vf_print_base_runs PREFIX K: the two base run lines of entry K.
vf_print_base_runs() {
  local i j
  for i in 1 2; do
    j=$(($2 * 2 + i - 1))
    if [ "${VF_BOK[$2]}" -eq 1 ]; then
      vf_print_run "$1" base "$i" "${VF_BS[$j]}"
    else
      printf '%sbase run %s: not run\n' "$1" "$i"
    fi
  done
}

# vf_judge_base K STYLE: does entry K reproduce at base? Both runs must exit non-zero, for
# the reason the issue names (expect). Sets VF_JV (0 yes, 1 no, 3 inconclusive) and VF_JWHY,
# worded for STYLE: "verify" (a reason for "not verified") or "base-only".
VF_JV=0
VF_JWHY=""
vf_judge_base() {
  local k="$1" style="$2" i j st
  VF_JV=0
  VF_JWHY=""
  if [ "${VF_BOK[$k]}" -ne 1 ]; then
    VF_JV=3
    VF_JWHY="could not prepare the base tree"
    return 0
  fi
  for i in 1 2; do
    j=$((k * 2 + i - 1))
    if [ "${VF_BS[$j]}" -eq 0 ]; then
      VF_JV=1
      if [ "$style" = verify ]; then
        VF_JWHY="repro does not reproduce at base (run $i exited 0)"
      else
        VF_JWHY="run $i exited 0"
      fi
      vf_tail "$VF_WORK/run-$k-base-$i/out"
      return 0
    fi
  done
  for i in 1 2; do
    j=$((k * 2 + i - 1))
    st="${VF_BS[$j]}"
    case "$st" in
      124) VF_JV=3; VF_JWHY="repro timed out at base (run $i, after ${VF_SECS}s)" ;;
      126 | 127) VF_JV=3; VF_JWHY="repro could not run at base (run $i exited $st)" ;;
    esac
    if [ "$VF_JV" -ne 0 ]; then
      vf_tail "$VF_WORK/run-$k-base-$i/out"
      return 0
    fi
  done
  for i in 1 2; do
    j=$((k * 2 + i - 1))
    if [ "${VF_BE[$j]}" != yes ]; then
      VF_JV=1
      if [ "$style" = verify ]; then
        VF_JWHY="expected output missing at base (run $i output lacks the expect text)"
      else
        VF_JWHY="run $i output lacks the expect text"
      fi
      vf_tail "$VF_WORK/run-$k-base-$i/out"
      return 0
    fi
  done
  return 0
}

# vf_verify BASE HEAD: run every entry's repro at BASE, then at HEAD, then red/green; print
# the summary and set VF_VERDICT. Always returns 0 (callers exit with VF_VERDICT).
# Everything read from git, and every base run's verdict, is settled BEFORE any head tree
# is prepared: from then on the code under test runs (project.setup and the repro execute
# it), as this user, next to $VF_WORK and the tree's .git, so it could rewrite both. That is
# why all the base runs (of every issue) come first.
# With one entry the lines are unprefixed; with several, each issue's lines start with
# "#<n> " and end with its own verdict, and the last line is the combined verdict: any
# "not verified" wins, then an error, then an inconclusive.
VF_VERDICT=2
vf_verify() {
  local base="$1" head="$2" k i j st p tt=0 rg rgst=0 verdict=0 reason=""
  local cnt="${#VF_I_NUM[@]}" multi=0 v why k1="" k2="" k3=""
  local hok=() hs=() vv=() vw=()
  [ "$cnt" -le 1 ] || multi=1
  printf 'base: %s\nhead: %s\n' "$base" "$head"
  k=0
  while [ "$k" -lt "$cnt" ]; do
    if [ "${VF_I_STATE[$k]}" = run ]; then
      p=""
      if [ "$multi" -eq 1 ]; then p="issue #${VF_I_NUM[$k]}: "; fi
      vf_show_repro "$k" "$p"
    fi
    k=$((k + 1))
  done

  vf_touches_tests "$base" "$head" || tt=$?

  # Base, for every entry: each run is judged (exit code and expect) right after it runs.
  k=0
  while [ "$k" -lt "$cnt" ]; do
    VF_BOK[k]=0
    if [ "${VF_I_STATE[$k]}" = run ]; then
      vf_base_runs "$k" "$base"
    fi
    k=$((k + 1))
  done
  # Head, for every entry whose base tree could be prepared.
  k=0
  while [ "$k" -lt "$cnt" ]; do
    hok[k]=0
    if [ "${VF_BOK[$k]}" -eq 1 ]; then
      if vf_prepare "head-$k" "$head"; then
        hok[k]=1
        for i in 1 2; do
          j=$((k * 2 + i - 1))
          st=0
          vf_run "$k-head-$i" "head-$k" "$k" || st=$?
          hs[j]="$st"
        done
      fi
      vf_drop "head-$k"
    fi
    k=$((k + 1))
  done

  # Each entry's verdict.
  k=0
  while [ "$k" -lt "$cnt" ]; do
    p=""
    if [ "$multi" -eq 1 ]; then p="#${VF_I_NUM[$k]} "; fi
    v=0
    why=""
    if [ "${VF_I_STATE[$k]}" != run ]; then
      v=2
      why="${VF_I_WHY[$k]}"
    else
      vf_print_base_runs "$p" "$k"
      for i in 1 2; do
        j=$((k * 2 + i - 1))
        if [ "${hok[$k]}" -eq 1 ]; then vf_print_run "$p" head "$i" "${hs[$j]}"; else printf '%shead run %s: not run\n' "$p" "$i"; fi
      done
      # Base: both runs must fail, for the reason the issue names.
      vf_judge_base "$k" verify
      v="$VF_JV"
      why="$VF_JWHY"
      # Head: both runs must pass.
      if [ "$v" -eq 0 ] && [ "${hok[$k]}" -eq 0 ]; then
        v=3
        why="could not prepare the head tree"
      fi
      if [ "$v" -eq 0 ]; then
        for i in 1 2; do
          j=$((k * 2 + i - 1))
          st="${hs[$j]}"
          if [ "$st" -ne 0 ]; then
            v=1
            if [ "$st" -eq 124 ]; then
              why="repro still fails at head (run $i timed out after ${VF_SECS}s)"
            else
              why="repro still fails at head (run $i exited $st)"
            fi
            vf_tail "$VF_WORK/run-$k-head-$i/out"
            break
          fi
        done
      fi
    fi
    vv[k]="$v"
    vw[k]="$why"
    if [ "$multi" -eq 1 ]; then vf_print_verdict "$p" "$v" "$why"; fi
    case "$v" in
      1) [ -n "$k1" ] || k1="$k" ;;
      2) [ -n "$k2" ] || k2="$k" ;;
      3) [ -n "$k3" ] || k3="$k" ;;
    esac
    k=$((k + 1))
  done

  # Combined: any "not verified" wins, then an error, then an inconclusive.
  k=""
  if [ -n "$k1" ]; then k="$k1"; elif [ -n "$k2" ]; then k="$k2"; elif [ -n "$k3" ]; then k="$k3"; fi
  if [ -n "$k" ]; then
    verdict="${vv[$k]}"
    reason="${vw[$k]}"
    if [ "$multi" -eq 1 ]; then reason="#${VF_I_NUM[$k]}: $reason"; fi
  elif [ "$cnt" -eq 0 ]; then
    verdict=2
    reason="nothing to verify"
  fi

  # Red/green, when the fix comes with tests. It runs project code (project.setup and the
  # tests): no credentials for it.
  if [ "$verdict" -ne 0 ]; then
    rg="not run (repro not verified)"
  else
    case "$tt" in
      0)
        vf_red_green "$base" "$head" || rgst=$?
        case "$rgst" in
          0) rg=pass ;;
          1) rg=fail; verdict=1; reason="the red/green check failed" ;;
          3) rg=inconclusive; verdict=3; reason="the red/green check was inconclusive" ;;
          *) rg="error (exit $rgst)"; verdict=2; reason="the red/green check could not run (bad call or config)" ;;
        esac
        ;;
      1) rg="skipped (no commit in base..head touches gate.test_globs)" ;;
      4) rg="skipped (gate.test_globs is none: the project has no test files)" ;;
      *) rg=error; verdict=2; reason="could not list the commits in base..head" ;;
    esac
  fi
  printf 'red-green: %s\n' "$rg"

  vf_print_verdict "" "$verdict" "$reason"
  case "$verdict" in
    0) sf_log "verified" ;;
    1) sf_log "not verified: $reason" ;;
    3) sf_log "inconclusive: $reason" ;;
    *) sf_log "error: $reason" ;;
  esac
  VF_VERDICT="$verdict"
  return 0
}

# vf_rev REV: the full commit id of REV in the tree.
vf_rev() {
  git -C "$VF_TREE" rev-parse --verify -q "$1^{commit}" || sf_die "not a commit in $VF_TREE: $1"
}

# --- modes (each ends in exit) ---------------------------------------------------------

vf_mode_file() {
  local base head
  base=$(vf_rev "$base_arg") || exit 2
  head=$(vf_rev "$head_arg") || exit 2
  vf_parse "$VF_FILE" || exit 2
  vf_add_issue file
  vf_verify "$base" "$head"
  vf_exit "$VF_VERDICT"
}

# --base-only: does the repro (of --issue N, after the same trust checks, or of
# --repro-file F) reproduce at BASE? The same tree and runs as vf_verify's base side.
# 0 reproduces, 1 does not, 3 inconclusive, 2 error or untrusted.
vf_mode_base_only() {
  local base rc=0
  base=$(vf_rev "$base_arg") || exit 2
  if [ "$mode" = issue ]; then
    vf_issue_repro "$VF_NUM" || rc=$?
    [ "$rc" -eq 0 ] || exit 2
    vf_add_issue "$VF_NUM"
    printf 'issue: %s\n' "$VF_NUM"
  else
    vf_parse "$VF_FILE" || exit 2
    vf_add_issue file
  fi
  printf 'base: %s\n' "$base"
  vf_show_repro 0 ""
  vf_base_runs 0 "$base"
  vf_print_base_runs "" 0
  vf_judge_base 0 base-only
  case "$VF_JV" in
    0)
      printf 'verdict: reproduces\n'
      sf_log "reproduces at $(vf_short "$base")"
      ;;
    1)
      printf 'verdict: does not reproduce: %s\n' "$VF_JWHY"
      sf_log "does not reproduce at $(vf_short "$base"): $VF_JWHY"
      ;;
    *)
      printf 'verdict: inconclusive: %s\n' "$VF_JWHY"
      sf_log "inconclusive: $VF_JWHY"
      ;;
  esac
  vf_exit "$VF_JV"
}

vf_mode_issue() {
  local base head rc=0
  base=$(vf_rev "$base_arg") || exit 2
  head=$(vf_rev "$head_arg") || exit 2
  vf_issue_repro "$VF_NUM" || rc=$?
  [ "$rc" -eq 0 ] || exit 2
  vf_add_issue "$VF_NUM"
  printf 'issue: %s\n' "$VF_NUM"
  vf_verify "$base" "$head"
  vf_exit "$VF_VERDICT"
}

# The shared bug-fix rule (ship.sh keeps the same one): the head branch is
# factory/issue-<n>, or a closing issue of this repository carries role:bug-fix or bug.
# Every such issue is verified, the branch's issue first. A closing issue's labels come from
# the same GraphQL answer that holds its repro.
vf_mode_pr() {
  local n="$VF_NUM" out tsv href="" hoid="" bref="" binum="" closing c cands="" tip base rc k
  vf_repo || exit 2
  out=$(vf_gh pr view "$n" --json headRefName,headRefOid,baseRefName,closingIssuesReferences) ||
    sf_die "could not read PR #$n (gh pr view)"
  printf '%s\n' "$out" >"$VF_WORK/pr.json"
  tsv=$(sf_jq -r '[(.headRefName // "-"), (.headRefOid // "-"), (.baseRefName // "-")]
    | map(tostring | if . == "" then "-" else . end) | @tsv' "$VF_WORK/pr.json" 2>/dev/null) ||
    sf_die "could not parse the output of gh pr view $n"
  IFS=$'\t' read -r href hoid bref <<<"$tsv"
  case "$hoid" in
    *[!0-9a-f]*) sf_die "PR #$n: GitHub returned an invalid head commit id" ;;
  esac
  [ "${#hoid}" -eq 40 ] || [ "${#hoid}" -eq 64 ] || sf_die "PR #$n: GitHub returned an invalid head commit id"
  vf_valid_branch "$href" || sf_die "PR #$n: unusable head branch name"
  vf_valid_branch "$bref" || sf_die "PR #$n: unusable base branch name"

  # The branch is a bug-fix branch only when it is a claim key's: factory/issue-<n> with n
  # a number without a leading zero (factory/issue-012 is no key, so the closing issues
  # decide). A factory/perf-<n> branch is a perf fix: its name never makes it a bug fix.
  case "$href" in
    factory/issue-[1-9]*)
      binum="${href#factory/issue-}"
      case "$binum" in
        *[!0-9]*) binum="" ;;
        # ship.sh counts this branch as a bug fix, so it must name an issue we can verify.
        ??????????*) sf_die "PR #$n: head branch $(vf_quote "$href") names an issue number that is too large" ;;
      esac
      ;;
  esac
  if [ -z "$binum" ]; then
    case "$href" in
      factory/issue-* | factory/perf-*)
        sf_log "PR #$n: head branch $(vf_quote "$href") is not a bug-fix branch (factory/issue-<n>, n without a leading zero); its closing issues decide" ;;
    esac
  fi
  closing=$(sf_jq -r --arg owner "$VF_OWNER" --arg name "$VF_NAME" "$VF_CLOSING" "$VF_WORK/pr.json" 2>/dev/null) ||
    sf_die "could not parse the closing issues of PR #$n"
  for c in $binum $closing; do
    case "$c" in
      '' | 0* | *[!0-9]* | ??????????*)
        sf_die "PR #$n: a closing issue reference of this repository has no usable issue number" ;;
    esac
    case " $cands " in *" $c "*) ;; *) cands="$cands $c" ;; esac
  done

  # Read every candidate (and every repro) before anything runs.
  for c in $cands; do
    rc=0
    vf_issue_fetch "$c" || rc=$?
    if [ "$rc" -ne 0 ]; then
      if [ "$c" = "$binum" ]; then
        vf_add_other "$c" error "could not read issue #$c from GitHub ($VF_WHY)"
      else
        vf_add_other "$c" error "could not read issue #$c, which the PR closes, so whether it is a bug is unknown ($VF_WHY)"
      fi
      continue
    fi
    if [ "$c" != "$binum" ] && [ "$VF_M_LABEL" = no ]; then
      sf_log "issue #$c, which PR #$n closes, has neither the label role:bug-fix nor bug: not a bug issue"
      continue
    fi
    # Labels that could not be read may hold a bug label: an error (vf_issue_load says
    # why), never "not a bug".
    rc=0
    vf_issue_load "$c" || rc=$?
    if [ "$rc" -eq 0 ]; then
      vf_add_issue "$c"
    else
      vf_add_other "$c" error "$VF_WHY"
    fi
  done

  if [ "${#VF_I_NUM[@]}" -eq 0 ]; then
    sf_log "PR #$n: the branch is not factory/issue-<n> and it closes no role:bug-fix or bug issue of this repository"
    printf 'not a bug fix: nothing to verify\n'
    exit 0
  fi
  sf_log "PR #$n fixes issue(s):$(printf ' #%s' "${VF_I_NUM[@]}")"

  # The head as GitHub publishes it (refs/pull/N/head): the head branch itself may live in a
  # fork, and a branch of the same name on the remote may be another commit entirely.
  tip=$(vf_fetch_pr "$n") || sf_die "could not fetch the PR head (refs/pull/$n/head) from $VF_REMOTE"
  [ "$tip" = "$hoid" ] ||
    sf_die "PR #$n moved: GitHub reports head $(vf_short "$hoid"), but refs/pull/$n/head on $VF_REMOTE is at $(vf_short "$tip"); re-run for the new head"
  vf_fetch "$bref" >/dev/null || sf_die "could not fetch the PR base branch from $VF_REMOTE"
  base=$(git -C "$VF_TREE" merge-base "refs/remotes/$VF_REMOTE/$bref" "$hoid") ||
    sf_die "PR #$n: the head has no merge-base with its base branch"

  printf 'pr: %s\n' "$n"
  for k in "${VF_I_NUM[@]}"; do
    printf 'issue: %s\n' "$k"
  done
  vf_verify "$base" "$hoid"
  vf_exit "$VF_VERDICT"
}

VF_A_CHECKED=0
VF_A_ESCAPES=0
VF_A_SKIPPED=0
VF_A_ERRORS=0

# vf_audit_one K SHA: audit entry K on the base branch at SHA; updates the VF_A_* counts.
vf_audit_one() {
  local k="$1" sha="$2" n short s1=0 s2=0 body rec
  n="${VF_I_NUM[$k]}"
  short=$(vf_short "$sha")
  case "${VF_I_STATE[$k]}" in
    skip)
      VF_A_SKIPPED=$((VF_A_SKIPPED + 1))
      sf_warn "issue #$n skipped: ${VF_I_WHY[$k]}"
      printf '#%s skipped: %s\n' "$n" "${VF_I_WHY[$k]}"
      return 0
      ;;
    error)
      VF_A_ERRORS=$((VF_A_ERRORS + 1))
      printf '#%s error: %s\n' "$n" "${VF_I_WHY[$k]}"
      return 0
      ;;
  esac
  VF_A_CHECKED=$((VF_A_CHECKED + 1))
  sf_log "issue #$n: running its repro on $VF_BASE_BRANCH ($short)"
  vf_show_repro "$k" ""
  if ! vf_prepare "audit-$n" "$sha"; then
    VF_A_ERRORS=$((VF_A_ERRORS + 1))
    printf '#%s error: could not prepare a tree at %s\n' "$n" "$short"
    vf_drop "audit-$n"
    return 0
  fi
  vf_run "audit-$n-1" "audit-$n" "$k" || s1=$?
  vf_run "audit-$n-2" "audit-$n" "$k" || s2=$?
  vf_drop "audit-$n"
  if [ "$s1" -eq 0 ] && [ "$s2" -eq 0 ]; then
    printf '#%s still fixed (exit 0, 0)\n' "$n"
    return 0
  fi
  if [ "$s1" -ne 0 ]; then vf_tail "$VF_WORK/run-audit-$n-1/out"; else vf_tail "$VF_WORK/run-audit-$n-2/out"; fi
  # 124 (timed out), 126 and 127 say the repro could not run on this runner, not that the
  # bug is back: an error, never an escape. Nothing is reopened, labeled or commented.
  if vf_cannot_run "$s1" || vf_cannot_run "$s2"; then
    VF_A_ERRORS=$((VF_A_ERRORS + 1))
    sf_log "issue #$n: the repro could not run on $VF_BASE_BRANCH (exit $s1, $s2); not counted as an escape"
    printf '#%s error: repro could not run on %s at %s (exit %s, %s); not counted as an escape\n' \
      "$n" "$VF_BASE_BRANCH" "$short" "$s1" "$s2"
    return 0
  fi
  body="<!-- factory:escape sha=$sha -->
**Escape.** The repro from this issue's original text fails again on \`$VF_BASE_BRANCH\` at \`$short\`:

- run 1: exit $s1
- run 2: exit $s2

The fix that closed this issue no longer holds, so \`scripts/verify-fix.sh --audit\` reopened it and added the label \`escape\`."
  # Label and comment first, reopen last: if anything fails the issue stays closed, so
  # the next audit finds it again and finishes the job.
  # -R names the repository (the one gh repo view reported): without it gh, which holds the
  # token, finds the repository by running the git it finds on PATH, where the project code
  # that just ran may have planted one (this script's hash pins nothing for gh).
  rec=1
  [ -n "$VF_OWNER" ] && [ -n "$VF_NAME" ] || rec=0
  if [ "$rec" -eq 1 ]; then
    vf_gh issue edit "$n" --add-label escape -R "$VF_OWNER/$VF_NAME" >&2 || rec=0
  fi
  if [ "$rec" -eq 1 ]; then
    printf '%s\n' "$body" | vf_gh issue comment "$n" --body-file - -R "$VF_OWNER/$VF_NAME" >&2 || rec=0
  fi
  if [ "$rec" -eq 1 ]; then
    vf_gh issue reopen "$n" -R "$VF_OWNER/$VF_NAME" >&2 || rec=0
  fi
  if [ "$rec" -eq 1 ]; then
    VF_A_ESCAPES=$((VF_A_ESCAPES + 1))
    sf_log "issue #$n: ESCAPE (exit $s1, $s2); reopened and labeled escape"
    printf '#%s escape: repro fails on %s at %s (exit %s, %s); reopened and labeled escape\n' \
      "$n" "$VF_BASE_BRANCH" "$short" "$s1" "$s2"
  else
    # Not recorded: an error (the verdict did not reach GitHub), as gate.sh does.
    VF_A_ERRORS=$((VF_A_ERRORS + 1))
    sf_log "issue #$n: ESCAPE (exit $s1, $s2), but recording it on GitHub failed"
    printf '#%s escape: repro fails on %s at %s (exit %s, %s); recording it on GitHub FAILED\n' \
      "$n" "$VF_BASE_BRANCH" "$short" "$s1" "$s2"
  fi
  return 0
}

vf_mode_audit() {
  local cut list nums n sha rc k cnt
  vf_valid_branch "$VF_BASE_BRANCH" || sf_die "$SF_CONFIG_FILE: base_branch is not a valid branch name"
  cut=$(($(date +%s) - days * 86400))
  list=$(vf_gh issue list --label role:bug-fix --state closed --limit 100 --json number,closedAt,stateReason) ||
    sf_die "could not list the closed role:bug-fix issues"
  nums=$(printf '%s\n' "$list" | sf_jq -r --argjson cut "$cut" "$VF_AUDIT_FILTER" 2>/dev/null) ||
    sf_die "could not parse the issue list"
  if [ "$(printf '%s\n' "$list" | sf_jq 'length' 2>/dev/null || echo 0)" -ge 100 ]; then
    sf_warn "the issue list hit its limit of 100; older fixes in the window may be missed"
  fi
  if [ -z "$nums" ]; then
    printf 'audit: no role:bug-fix issues closed as completed in the last %s days\n' "$days"
    exit 0
  fi
  # Every repro is read (and judged trustworthy or not) before any project code runs: the
  # trees below run the base branch's project.setup and the repros.
  for n in $nums; do
    case "$n" in '' | 0* | *[!0-9]*) continue ;; esac
    rc=0
    vf_issue_repro "$n" || rc=$?
    case "$rc" in
      0) vf_add_issue "$n" ;;
      2) vf_add_other "$n" skip "$VF_WHY" ;;
      *) vf_add_other "$n" error "could not read the issue from GitHub" ;;
    esac
  done
  sha=$(vf_fetch "$VF_BASE_BRANCH") || sf_die "could not fetch $VF_BASE_BRANCH from $VF_REMOTE"
  printf 'audit: %s/%s at %s, issues closed in the last %s days\n' "$VF_REMOTE" "$VF_BASE_BRANCH" "$sha" "$days"

  cnt="${#VF_I_NUM[@]}"
  k=0
  while [ "$k" -lt "$cnt" ]; do
    vf_audit_one "$k" "$sha"
    k=$((k + 1))
  done

  printf 'audit: %s checked, %s escaped, %s skipped, %s errors\n' \
    "$VF_A_CHECKED" "$VF_A_ESCAPES" "$VF_A_SKIPPED" "$VF_A_ERRORS"
  [ "$VF_A_ESCAPES" -eq 0 ] || vf_exit 1
  [ "$VF_A_ERRORS" -eq 0 ] || exit 2
  exit 0
}

if [ "$base_only" -eq 1 ]; then
  vf_mode_base_only
fi
case "$mode" in
  file) vf_mode_file ;;
  issue) vf_mode_issue ;;
  pr) vf_mode_pr ;;
  audit) vf_mode_audit ;;
esac
exit 2
}
