#!/usr/bin/env bash
# Re-runs reviewer findings and keeps only those whose command fails twice. Contract: docs/CONTRACTS.md, "confirm-findings.sh".
set -euo pipefail
SF_PROG=confirm-findings
# shellcheck source=scripts/lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
# shellcheck source=scripts/lib/jq.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/jq.sh"

# The rest of this file is one brace group that ends in `exit`, so bash parses all of it
# before running any of it. bash reads a script file as it executes it, and the finding
# commands (and the PR code they start) can write this file (same user; SF_FACTORY_ROOT is
# in their environment): an in-place rewrite would otherwise replace whatever follows the
# loop that runs them, e.g. with `exit 0`. (Sourced files are read whole when sourced.)
{

CF_TIMEOUT=120
CF_LABEL='verify:findings'
# The comment lists at most this many findings, each field cut to this many characters,
# and stops listing before the findings take more than CF_MAX_BYTES bytes, so it stays
# under GitHub's 65536-character comment limit. stdout always carries all of them.
CF_MAX_LISTED=20
CF_MAX_FIELD=1500
CF_MAX_BYTES=60000

usage() {
  cat <<'EOF'
Usage: confirm-findings.sh FINDINGS.jsonl [--tree DIR] [--pr N]

Runs each finding's command twice in the tree (bash -c, 120 s timeout each) and keeps
it only when both runs exit non-zero and, when "expect" is given, both outputs contain
it. Input: one JSON object per line,
  {"id":"V1","claim":"...","command":"...","expect":"optional substring"}
Every run gets no credential-like environment variables, and its own new, empty HOME,
TMPDIR, XDG_CONFIG_HOME and GH_CONFIG_DIR, removed after it.
Malformed lines are reported and skipped, never run. A finding whose runs exit 125/126/127
without a matching "expect" is inconclusive; for such a run, the shell's own launch errors
("bash: line 1: x: command not found", "No such file or directory", "Permission denied")
never count as a match. So is one whose runs could not start (the tree was gone, or its
fresh directories could not be made), or whose fields could not be read. Either makes the
run exit 2 unless a finding was confirmed.

  --tree DIR  where commands run (default: the current repo root)
  --pr N      comment the confirmed findings on PR N and add the label verify:findings;
              with only malformed or inconclusive ones, add or keep it; else remove it.
              The repository is resolved (gh repo view, in the tree) before any command
              runs, and every later gh call names it.
  -h, --help  show this help

stdout: the confirmed findings as JSONL. stderr: counts and reasons.
Exit: 0 none confirmed, 1 at least one confirmed, 2 usage, undecidable input or GitHub error.
EOF
}

cf_usage_die() {
  printf '%s: error: %s\n' "$SF_PROG" "$1" >&2
  usage >&2
  exit 2
}

# Validates one slurped line; prints "ok" or the reason it is malformed.
# shellcheck disable=SC2016
CF_VALIDATE='
  def nul: explode | any(. == 0);
  if length != 1 then "expected exactly one JSON value on the line"
  else .[0] |
    if type != "object" then "not a JSON object"
    elif (.id | type) != "string" or .id == "" then "\"id\" must be a non-empty string"
    elif (.claim | type) != "string" then "\"claim\" must be a string"
    elif (.command | type) != "string" or (.command | test("^\\s*$")) then "\"command\" must be a non-empty string"
    elif (.command | nul) then "\"command\" contains a NUL character"
    elif .expect != null and (.expect | type) != "string" then "\"expect\" must be a string"
    elif (.expect // "" | nul) then "\"expect\" contains a NUL character"
    else "ok" end
  end'

# Builds the PR comment from the confirmed findings (slurped). Untrusted text goes into
# indented code blocks only, so it cannot @-mention anyone, render HTML, or forge a
# factory marker comment; "<!--" is broken up even there. Findings are listed in order
# until the next one would pass $max_listed or $max_bytes (indentation can multiply a
# field's size, so the byte budget is what keeps the body under GitHub's limit).
# shellcheck disable=SC2016
CF_BODY='
  def cap: if length > $max_field then .[0:$max_field] + "\n[... cut]" else . end;
  def block: cap | gsub("\r"; "") | gsub("<!--"; "<!-\\-") | split("\n") | map("    " + .) | join("\n");
  def slug: gsub("[^A-Za-z0-9_.:-]"; "_") | .[0:60];
  def bytes: explode | map(if . < 128 then 1 elif . < 2048 then 2 elif . < 65536 then 3 else 4 end) | add // 0;
  def section:
    [ "", "#### \(.id | slug)", "",
      (if (.claim | length) > 0 then (.claim | block) else "    (no claim given)" end), "",
      "Command:", "", (.command | block),
      (if (.expect // "") != "" then "", "Output contained, both times:", "", (.expect | block) else empty end)
    ] | join("\n");
  length as $n
  | (reduce (.[] | section) as $s ({secs: [], bytes: 0, full: false};
      ($s | bytes) as $b
      | if .full or (.secs | length) >= $max_listed or .bytes + $b > $max_bytes
        then .full = true
        else .secs += [$s] | .bytes += $b end)) as $acc
  | ($acc.secs | length) as $k
  | "<!-- factory:findings sha=\($sha) -->",
    "**\($n) confirmed finding\(if $n == 1 then "" else "s" end)** at `\($sha[0:12])`. Each command below exited non-zero on two runs in a row (`scripts/confirm-findings.sh`). The `\($label)` label blocks shipping until a later run confirms none.",
    $acc.secs[],
    (if $n > $k then "", "... and \($n - $k) more; see the job log." else empty end)'

findings=""
tree=""
pr=""
pr_given=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --tree)
      [ "$#" -ge 2 ] || cf_usage_die "--tree needs a directory"
      tree="$2"
      shift 2
      ;;
    --tree=*)
      tree="${1#--tree=}"
      shift
      ;;
    --pr)
      [ "$#" -ge 2 ] || cf_usage_die "--pr needs a number"
      pr="$2"
      pr_given=1
      shift 2
      ;;
    --pr=*)
      pr="${1#--pr=}"
      pr_given=1
      shift
      ;;
    -?*) cf_usage_die "unknown option: $1" ;;
    *)
      [ -z "$findings" ] || cf_usage_die "only one findings file may be given"
      findings="$1"
      shift
      ;;
  esac
done

[ -n "$findings" ] || cf_usage_die "missing FINDINGS.jsonl"
if [ ! -f "$findings" ] || [ ! -r "$findings" ]; then
  cf_usage_die "findings file not found or unreadable: $findings"
fi
# The tools this shell runs once finding commands have run. The commands can put an
# executable named gh (which would get the token), jq, env or sort in a PATH directory they
# can write to (~/.local/bin, say), so each tool must exist now and is pinned below.
CF_TOOLS=(bash jq tr awk sort env mktemp mkdir rm sleep)
# An empty --pr (say, an unset CI variable) is an error, never a silent "no PR".
if [ "$pr_given" -eq 1 ]; then
  case "$pr" in
    '' | *[!0-9]* | 0*) cf_usage_die "--pr must be a pull request number: $pr" ;;
  esac
  [ "${FACTORY_OFFLINE:-}" != 1 ] || sf_die "--pr needs GitHub, but FACTORY_OFFLINE=1"
  CF_TOOLS+=(gh git)
fi
sf_need "${CF_TOOLS[@]}"
if [ -z "$tree" ]; then
  sf_need git
  tree=$(sf_repo_root)
fi
[ -d "$tree" ] || cf_usage_die "--tree is not a directory: $tree"
# No CDPATH: it could send a relative --tree elsewhere (and make cd print the path).
tree=$(CDPATH='' cd -- "$tree" && pwd)

# Pin those tools: bash looks a hashed name up in its table, never in PATH again, and
# subshells inherit the table. Each was found above, so none is left to a later PATH lookup.
# Others are pinned when present (cygpath exists only on Git Bash).
hash "${CF_TOOLS[@]}" || sf_die "could not look up the tools this script needs"
hash git gh sed head tail cat wc date cygpath 2>/dev/null || true
# env (in sf_scrubbed) looks its command up in PATH, so commands run the pinned bash by its path.
CF_BASH=$(hash -t bash 2>/dev/null) || sf_die "required command not found: bash"

head_sha=""
CF_REPO=""
if [ -n "$pr" ]; then
  head_sha=$(git -C "$tree" rev-parse --verify -q 'HEAD^{commit}') ||
    sf_die "--pr needs --tree to be a git checkout of the PR head: $tree"
  # Which repository the PR is in, resolved from the tree's remotes now, before any command
  # runs. Afterwards gh would resolve it again from whatever remotes the commands left (an
  # "upstream" one wins), running whatever git is first on PATH, so every later call names it.
  CF_REPO=$( (cd "$tree" && sf_gh repo view --json owner,name) </dev/null) ||
    sf_die "could not tell which GitHub repository $tree belongs to (gh repo view)"
  # shellcheck disable=SC2016 # a jq program, not shell
  CF_REPO=$(printf '%s\n' "$CF_REPO" | sf_jq -r '
    if type == "object" then . else error("not a JSON object") end
    | [.owner.login, .name]
    | map(if type == "string" and test("\\A[A-Za-z0-9._-]{1,100}\\z") then .
          else error("invalid owner or name") end)
    | join("/")') || sf_die "gh repo view returned an invalid owner or name"
fi

# (Under set -e a failure here would end the run with mktemp's 1, which reads as "confirmed".)
CF_WORK=$(sf_mktemp_dir) || sf_die "could not create a temp dir"
trap 'rm -rf "$CF_WORK"' EXIT
# Absolute (TMPDIR may be relative): each run's HOME and TMPDIR are made in it, and the
# commands that get them run in the tree.
cf_abs=$(cd "$CF_WORK" && pwd) || sf_die "could not find the temp dir"
CF_WORK=$cf_abs
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Read every line before running anything. The commands (and the PR code they start)
# share this script's open files and can find its temp dir, so nothing they could read,
# truncate or rewrite (the findings file, the confirmed list, the comment) is kept in a
# file while they run. Raw NUL bytes, which bash's read would silently drop (turning an
# invalid line into a valid one with a different command), become \001, which jq rejects.
tr '\000' '\001' <"$findings" >"$CF_WORK/findings" || sf_die "could not read $findings"
CF_LINES=()
line=""
while IFS= read -r line || [ -n "$line" ]; do
  CF_LINES+=("$line")
done <"$CF_WORK/findings"
# Never read again, so a copy that can't be removed (Windows may hold a new file open) is
# left; under set -e the failure would end the run with rm's 1, which reads as "confirmed".
rm -f "$CF_WORK/findings" 2>/dev/null || true
CF_CONFIRMED=""

# The commands were written by an agent that read untrusted PR text, so they run through
# sf_scrubbed: no exported entry whose name looks like a credential. sf_scrubbed lists them
# again as it starts each command and can't report that the listing failed, and once one
# command has run, a process it left behind can make that listing fail (kill its awk or
# sort): the command would then run with every credential. So the names are listed once
# now, before any command runs, and removed from every run as well. When they can't be
# (under set -e that would end the run with a status that could read as 1), nothing runs.
CF_NAMES=$(sf_credential_names) || sf_die "could not read the environment"
CF_DROP=()
while IFS= read -r cf_name; do
  if [ -n "$cf_name" ]; then CF_DROP+=(-u "$cf_name"); fi
done <<EOF
$CF_NAMES
EOF

# cf_exec_scrubbed CMD...: replace this shell with CMD, started through sf_scrubbed. It runs
# only as the job sf_run_timeout starts in the background, and sf_run_timeout signals that
# job's own process; sf_scrubbed would start env as a child of it, out of the timeout's
# reach. So here env is a function that execs env (exec finds the pinned program, never the
# function): the job itself becomes env, then the command's bash. Called with arguments (to
# start CMD), it also removes the names listed before any command ran; without, it is the
# listing inside sf_credential_names.
# shellcheck disable=SC2329 # started by name, through sf_run_timeout
cf_exec_scrubbed() {
  env() {
    if [ "$#" -eq 0 ]; then exec env; fi
    exec env ${CF_DROP[@]+"${CF_DROP[@]}"} "$@"
  }
  sf_scrubbed "$@"
}

# cf_run N COMMAND: run COMMAND once in the tree; output in $CF_WORK/out.N. Returns its status.
# When the tree can't be entered or the run's own directories can't be made, COMMAND is not
# run: CF_UNPREPARED becomes the reason.
# "--" keeps a command that starts with - or + from being parsed as bash options. N is
# unique per run: a process a command leaves behind keeps writing to its own file only.
cf_run() {
  local st=0 d=""
  # An earlier command can move the tree away. The run would then exit 1 without running
  # COMMAND at all, which must not read as "it failed".
  if ! (cd "$tree") 2>/dev/null; then
    CF_UNPREPARED="could not enter the tree to run it (did an earlier command move it?)"
    return 0
  fi
  # A new, empty HOME, TMPDIR, XDG_CONFIG_HOME and GH_CONFIG_DIR for every run, removed after
  # it: the runner's own config, gh login and caches stay out of reach, and nothing a run
  # leaves there (a planted tool, a forged config) reaches the next one.
  if ! { d=$(mktemp -d "$CF_WORK/run.XXXXXX") && mkdir "$d/home" "$d/tmp" "$d/config" "$d/gh"; } 2>/dev/null; then
    [ -z "$d" ] || rm -rf "$d" 2>/dev/null || true
    CF_UNPREPARED="could not make a fresh HOME and TMPDIR to run it in"
    return 0
  fi
  (
    cd "$tree" || exit 1
    sf_run_timeout "$CF_TIMEOUT" cf_exec_scrubbed HOME="$d/home" TMPDIR="$d/tmp" \
      XDG_CONFIG_HOME="$d/config" GH_CONFIG_DIR="$d/gh" "$CF_BASH" -c -- "$2"
  ) </dev/null >"$CF_WORK/out.$1" 2>&1 || st=$?
  rm -rf "$d" 2>/dev/null || true
  return "$st"
}

# The shell's own launch errors: the lines `bash -c` prints when the command it was given
# can't be started at all ("bash: line 1: jqq: command not found", "bash: x.sh: No such
# file or directory", "... Permission denied", and "bash: line 1: exec: jqq: not found"
# for `exec jqq`; Git Bash may spell the name bash.exe, and a bash started by its path,
# as every command here is, names itself by that path: "/usr/bin/bash: line 1: ...").
# They say the reviewer's command never ran, so they can't be what "expect" looks for.
# Errors that the code under review prints itself start with its own name
# ("scripts/x.sh: line 2: jqq: command not found") and are kept.
# shellcheck disable=SC2016 # an awk program, not shell
CF_LAUNCH_ERRORS='!/^([^:]*\/)?bash(\.exe)?: (line [0-9]+: )?.*: ((command )?not found|No such file or directory|Permission denied)$/'

# cf_unrunnable STATUS: true for 125 (sf_scrubbed refused to start it), 126 (found but not
# executable) and 127 (not found).
cf_unrunnable() { [ "$1" -eq 125 ] || [ "$1" -eq 126 ] || [ "$1" -eq 127 ]; }

# cf_output_has N STATUS TEXT: true if run N, which exited STATUS, printed TEXT (NUL and CR
# bytes ignored). For a run that exited 125, 126 or 127, the shell's own launch errors are
# removed from its output first.
cf_output_has() {
  local out
  if cf_unrunnable "$2"; then
    out=$(tr -d '\000\r' <"$CF_WORK/out.$1" | LC_ALL=C awk "$CF_LAUNCH_ERRORS")
  else
    out=$(tr -d '\000\r' <"$CF_WORK/out.$1")
  fi
  case "$out" in *"$3"*) return 0 ;; esac
  return 1
}

# cf_lacks N STATUS: the reason given when run N's output lacks the expected text.
cf_lacks() {
  if cf_unrunnable "$2"; then
    printf 'run %s (exit %s) output lacks the expected text once the shell'"'"'s own launch errors are left out' "$1" "$2"
  else
    printf 'run %s output lacks the expected text' "$1"
  fi
}

# cf_field LINE FILTER: one field of a finding as raw text (control characters kept).
cf_field() {
  local v
  v=$(printf '%s\n' "$1" | sf_jq -j "$2 + \"x\"") || return 1
  printf '%s' "${v%x}"
}

lineno=0
confirmed=0
dropped=0
malformed=0
inconclusive=0
bom=$(printf '\357\273\277')
cr=$(printf '\r')
for line in ${CF_LINES[@]+"${CF_LINES[@]}"}; do
  lineno=$((lineno + 1))
  [ "$lineno" -ne 1 ] || line="${line#"$bom"}"
  line="${line%"$cr"}"
  case "$line" in *[![:space:]]*) ;; *) continue ;; esac

  reason=$(printf '%s\n' "$line" | sf_jq -r -s "$CF_VALIDATE" 2>/dev/null) || reason="invalid JSON"
  if [ "$reason" != ok ]; then
    sf_log "line $lineno: malformed, skipped (not run): $reason"
    malformed=$((malformed + 1))
    dropped=$((dropped + 1))
    continue
  fi
  # A valid line whose fields can't be read decided nothing (under set -e, a failed read
  # would end the run with jq's status, which can be 1: "confirmed").
  if ! id=$(printf '%s\n' "$line" | sf_jq -r '.id | gsub("[[:cntrl:]]"; " ")') ||
    ! cmd=$(cf_field "$line" '.command') || ! expect=$(cf_field "$line" '(.expect // "")'); then
    sf_log "line $lineno: inconclusive: could not read the finding (not run)"
    inconclusive=$((inconclusive + 1))
    continue
  fi

  s1=0
  s2=0
  CF_UNPREPARED=""
  cf_run "$lineno.1" "$cmd" || s1=$?
  if [ -z "$CF_UNPREPARED" ]; then
    cf_run "$lineno.2" "$cmd" || s2=$?
  fi
  # A run that could not start (no tree, no fresh directories) decides nothing: neither
  # confirmed nor dropped.
  if [ -n "$CF_UNPREPARED" ]; then
    sf_log "$id: inconclusive: $CF_UNPREPARED"
    inconclusive=$((inconclusive + 1))
    continue
  fi

  # 125/126/127 (refused to start, not executable, not found) is ambiguous: the reviewer's
  # command may be mistyped, or the code under review may itself call a missing command. It
  # never drops a finding: with an "expect" that the run's output matches (the shell's own
  # launch errors left out) it confirms like any failure, otherwise it is inconclusive, which
  # keeps the PR blocked like a malformed line.
  unrunnable=0
  if cf_unrunnable "$s1" || cf_unrunnable "$s2"; then unrunnable=1; fi
  verdict=""
  if [ "$s1" -eq 0 ]; then
    verdict="run 1 exited 0"
  elif [ "$s2" -eq 0 ]; then
    verdict="run 2 exited 0 (run 1 exited $s1)"
  elif [ -n "$expect" ] && ! cf_output_has "$lineno.1" "$s1" "$expect"; then
    verdict=$(cf_lacks 1 "$s1")
  elif [ -n "$expect" ] && ! cf_output_has "$lineno.2" "$s2" "$expect"; then
    verdict=$(cf_lacks 2 "$s2")
  elif [ -z "$expect" ] && [ "$unrunnable" = 1 ]; then
    verdict="exit $s1, then $s2: the command may not have run at all"
  fi
  if [ -n "$verdict" ] && [ "$unrunnable" = 1 ] && [ "$s1" -ne 0 ] && [ "$s2" -ne 0 ]; then
    if [ -n "$expect" ]; then
      sf_log "$id: inconclusive: $verdict (fix the command, or the \"expect\" text)"
    else
      sf_log "$id: inconclusive: $verdict (give it an \"expect\" text, or fix the command)"
    fi
    inconclusive=$((inconclusive + 1))
    continue
  fi
  if [ -n "$verdict" ]; then
    sf_log "$id: dropped: $verdict"
    dropped=$((dropped + 1))
    continue
  fi
  sf_log "$id: confirmed (exit $s1, then $s2)"
  confirmed=$((confirmed + 1))
  # (The line itself, checked above to be one JSON object, if jq can't print it compactly.)
  json=$(printf '%s\n' "$line" | sf_jq -c '.') || json=$line
  printf '%s\n' "$json"
  CF_CONFIRMED="$CF_CONFIRMED$json
"
done

summary="$confirmed confirmed, $dropped dropped ($malformed malformed)"
[ "$inconclusive" -eq 0 ] || summary="$summary, $inconclusive inconclusive"
sf_log "$summary"

# cf_gh_read ARGS...: a gh call made after the commands ran. It names the repository resolved
# before they ran (-R, and GH_REPO; an api call names it in its path instead), and starts in
# /, not in the tree, so neither the remotes the commands left nor a git they put on PATH
# can pick another repository. cf_gh sends its stdout to stderr.
cf_gh_read() {
  if [ "$1" = api ]; then
    (cd / && GH_REPO=$CF_REPO sf_gh "$@")
  else
    (cd / && GH_REPO=$CF_REPO sf_gh "$@" -R "$CF_REPO")
  fi
}
cf_gh() {
  cf_gh_read "$@" >&2
}

if [ -n "$pr" ]; then
  if [ "$confirmed" -gt 0 ]; then
    body=$(printf '%s' "$CF_CONFIRMED" | sf_jq -r -s --arg sha "$head_sha" --arg label "$CF_LABEL" \
      --argjson max_listed "$CF_MAX_LISTED" --argjson max_field "$CF_MAX_FIELD" \
      --argjson max_bytes "$CF_MAX_BYTES" "$CF_BODY") ||
      sf_die "could not build the PR comment"
    # The label is what blocks shipping: add it first, so a failed comment can't leave
    # a PR with confirmed findings unlabelled. If the label fails, still comment, then exit 2.
    label_ok=1
    if cf_gh pr edit "$pr" --add-label "$CF_LABEL"; then
      sf_log "labelled PR #$pr $CF_LABEL"
    else
      label_ok=0
    fi
    # Idempotent: an identical comment from an earlier run is not posted again.
    comments=$(cf_gh_read api "repos/$CF_REPO/issues/$pr/comments" --paginate </dev/null) ||
      sf_die "could not read the comments of PR #$pr"
    # shellcheck disable=SC2016
    dup=$({ printf '%s\n' "$body" | sf_jq -R -s . && printf '%s\n' "$comments"; } |
      sf_jq -s 'def norm: gsub("\r"; "") | sub("\\s+$"; "");
        (.[0] | norm) as $b | [.[1:][] | .[]? | select((.body // "" | norm) == $b)] | length') ||
      sf_die "could not parse the comments of PR #$pr"
    if [ "$dup" -gt 0 ]; then
      sf_log "PR #$pr already has this findings comment; not posting it again"
    else
      printf '%s\n' "$body" | cf_gh pr comment "$pr" --body-file - || sf_die "could not comment on PR #$pr"
      sf_log "commented the confirmed findings on PR #$pr"
    fi
    [ "$label_ok" -eq 1 ] || sf_die "could not add the label $CF_LABEL to PR #$pr"
  elif [ "$malformed" -gt 0 ] || [ "$inconclusive" -gt 0 ]; then
    # Garbage reviewer output must not read as "no findings": keep the PR blocked.
    cf_gh pr edit "$pr" --add-label "$CF_LABEL" || sf_die "could not add the label $CF_LABEL to PR #$pr"
    sf_log "kept PR #$pr labelled $CF_LABEL: $malformed malformed and $inconclusive inconclusive finding(s)"
  else
    labels=$(cf_gh_read pr view "$pr" --json labels </dev/null) || sf_die "could not read the labels of PR #$pr"
    # shellcheck disable=SC2016
    has=$(printf '%s\n' "$labels" | sf_jq -r --arg l "$CF_LABEL" '[.labels[]?.name] | index($l) != null') ||
      sf_die "could not parse the labels of PR #$pr"
    if [ "$has" = true ]; then
      cf_gh pr edit "$pr" --remove-label "$CF_LABEL" || sf_die "could not remove the label $CF_LABEL from PR #$pr"
      sf_log "removed the label $CF_LABEL from PR #$pr"
    fi
  fi
fi

[ "$confirmed" -eq 0 ] || exit 1
# Nothing confirmed, but some lines could not be read: that is "could not decide".
if [ "$malformed" -gt 0 ] || [ "$inconclusive" -gt 0 ]; then
  sf_die "could not decide: $malformed malformed and $inconclusive inconclusive finding(s); fix the reviewer output and rerun"
fi
exit 0
}
