#!/usr/bin/env bash
# Audits the commits a push added to the base branch: each was shipped by ship.sh or marked by an operator; --act opens revert PRs. Contract: docs/CONTRACTS.md, "audit-merge.sh".
set -euo pipefail
SF_PROG=audit-merge
# shellcheck source=scripts/lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
# shellcheck source=scripts/lib/jq.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/jq.sh"
# shellcheck source=scripts/lib/config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"

usage() {
  cat <<'EOF'
Usage: audit-merge.sh --before SHA --after SHA [--act] [--tree DIR] [--config FILE]

Audits every commit a push added to the base branch, oldest first:
git rev-list --first-parent --reverse BEFORE..AFTER in the tree (fetched with history).
When BEFORE is not an ancestor of AFTER (a force push rewrote the branch), every rewritten
commit would look new: it prints "violation <AFTER> force push" and exits 1, and --act does
nothing for it.
A commit C passes when either
  1. an operator committed it on purpose: its message ends in a trailer
     "Factory-Operator: <reason>" with a non-empty reason (git interpret-trailers --parse
     --no-divider, which reads a commit's trailers as git does: a "---" line is text). When
     C is the merge commit of a merged PR (gh api repos/<owner>/<repo>/commits/C/pulls), the
     trailer counts only if neither that PR's title, its description nor any of its own
     commits (gh api .../pulls/<n>/commits) carries one: no line of them starts with
     "Factory-Operator:" (any case, leading blanks ignored), or a writer could have put it
     into the merge message, which GitHub fills from them; or
  2. it was shipped: a merged PR has C as its merge_commit_sha (gh api
     repos/<owner>/<repo>/commits/C/pulls), and for that PR's head H
       - a PR comment's first line is exactly
         <!-- factory:verdict sha=<H> agent=<id> result=pass -->
       - <id> is not the author or committer name of any of the PR's commits
       - the latest "gate" check run of the workflow "gate" on H is SUCCESS
       - for a bug-fix PR (head branch factory/issue-<n>, n without a leading zero, or
         closing an issue of this repository labelled role:bug-fix or bug) the latest
         "verify-fix" check run of the workflow "gate" on H is SUCCESS.
It runs no project code. Every gh call names the repository (resolved once with
gh repo view, then -R <owner>/<repo>, repos/<owner>/<repo>/... or GH_REPO).

Prints one line per commit on stdout:
  ok <sha> shipped #<n>
  ok <sha> operator: "<reason, JSON-quoted>"
  violation <sha> <reason>
A commit that breaks a rule is a violation even when another of its rules could not be read
(the line says so); a commit that breaks none but GitHub could not be read for gets no line,
and stderr says why.

  --before SHA   the base branch tip before the push. All zeros (a new branch) audits
                 nothing and exits 0.
  --after SHA    the base branch tip after the push
  --act          for each violation: make "git revert --no-edit C" (-m 1 for a merge commit)
                 on top of AFTER as a bookkeeping commit in a temporary worktree, push it as
                 factory/revert-<first 12 hex digits of C>, open a PR from it to base_branch
                 titled "revert: <C's subject>" (its first 200 characters; an open PR from
                 that branch of this repository is reused, one from a fork never), whose
                 body says that whoever merges it by hand must add a Factory-Operator
                 trailer, and file a needs-human issue linking both (file-issue.sh --role
                 babysit --label needs-human, deduplicated by title). A revert that does not
                 apply cleanly gets no branch and no PR, and the issue says so.
  --tree DIR     the repository to audit (default: the current repo root); it must hold
                 the full history: a shallow clone exits 2
  --config FILE  config (default: FACTORY_CONFIG, else the judging copy's
                 factory.config.yaml); read for base_branch with --act
  -h, --help     show this help

Stop switch: unless FACTORY_ENABLED is "true", it says "factory stopped" on stderr and exits
0. FACTORY_ENABLED is read from the environment when CI=true or FACTORY_OFFLINE=1, otherwise
with gh variable get (a value that cannot be read counts as stopped).

Environment: FACTORY_ENABLED, CI, FACTORY_OFFLINE (no commit can then be decided, not even
one with an operator trailer, which may be a PR's merge commit: exit 2; an empty range and a
force push still are), FACTORY_REMOTE (default origin), FACTORY_CONFIG, GH_REPO,
FACTORY_AGENT_ID (name on the revert commits and issues; default audit-merge).

Exit: 0 every commit passed, nothing to audit, or the factory is stopped; 1 at least one
violation, or a force push; 2 usage or config error, a shallow or incomplete history, a
commit GitHub could not be read for (could not decide), or an --act step that failed.
EOF
}

# The workflow whose check runs count (gate and verify-fix are its jobs), as in ship.sh.
AM_WORKFLOW=gate
# How much of a commit's sha names its revert branch.
AM_SHORT=12
# The most commits pulls/<n>/commits lists, pages included (GitHub's limit): a PR that lists
# this many may have more, unseen.
AM_PR_COMMITS_MAX=250

# gh repo view --json owner,name -> owner/name.
# shellcheck disable=SC2016 # a jq program, not shell
AM_REPO_JQ='
if type != "object" then error("not a JSON object") else . end
| [.owner.login, .name]
| map(if type == "string" and test("\\A[A-Za-z0-9._-]{1,100}\\z") then . else error("invalid owner or name") end)
| join("/")
'

# carrier: whether a text (a commit message, a PR title or description) carries a
# Factory-Operator line: any line, leading blanks aside, that starts with "Factory-Operator"
# and a colon (any case). A superset of its trailers, so that no text that becomes a trailer
# of a merge message GitHub fills from these texts is missed.
# shellcheck disable=SC2016 # a jq program, not shell
AM_CARRIER_DEF='
def carrier:
  split("\n") | any(.[]; sub("\\A[[:space:]]+"; "") | ascii_downcase | test("\\Afactory-operator[[:space:]]*:"));
'

# commits/<C>/pulls pages (slurped) -> "<number> <head sha> <head ref or -> <text>" for every
# merged PR whose merge commit is $c, oldest first. <text> is about the PR's title and
# description, which GitHub can put into the merge message (a merge commit's default message
# ends in the title; "Pull request title and description" adds the description): "carries"
# when either has a Factory-Operator line (carrier), "clean" when neither has one (a missing
# one has none), "unknown" when one is not text. An open PR also has a merge_commit_sha (its
# test merge), so merged_at decides. Everything here is untrusted: a value that is used must
# be well formed, and a head ref that is not a plain branch name prints as "-".
# shellcheck disable=SC2016 # a jq program, not shell
AM_PULLS_JQ=$AM_CARRIER_DEF'
[ .[] | if type == "array" then .[] else error("a page of pull requests is not a JSON array") end
  | objects
  | select((.merged_at | type) == "string" and (.merged_at | length) > 0 and .merge_commit_sha == $c) ]
| map({ n: (.number | if type == "number" and . > 0 and . == floor and . < 1000000000 then .
                      else error("a merged pull request has no usable number") end),
        h: (.head.sha | if type == "string" and test("\\A[0-9a-f]{40}\\z") then .
                        else error("a merged pull request has no usable head sha") end),
        r: (.head.ref | if type == "string" and test("\\A[A-Za-z0-9._/-]{1,255}\\z") then . else "-" end),
        b: ([.title, .body] | map(select(. != null))
            | if any(.[]; if type == "string" then carrier else false end) then "carries"
              elif any(.[]; type != "string") then "unknown" else "clean" end) })
| sort_by(.n)
| .[] | "\(.n) \(.h) \(.r) \(.b)"
'

# The verdict of one PR from its comments and commits (both slurped pages), for head $h:
#   "ok <id>"      a verdict for $h names <id>, who wrote and committed none of its commits
#   "writer <id>"  every verdict for $h names a writer or committer of the PR
#   "other"        the verdict comments are all for other commits
#   "none"         no verdict comment
# A marker is the first line of a comment, exactly (a CR GitHub kept from the web editor
# aside).
# shellcheck disable=SC2016 # a jq program, not shell
AM_VERDICT_JQ='
[ $comments[] | if type == "array" then .[] else error("a page of comments is not a JSON array") end
  | objects | .body | strings
  | (split("\n") | .[0] // "") | sub("\r\\z"; "")
  | capture("\\A<!-- factory:verdict sha=(?<sha>[0-9a-f]{40}) agent=(?<agent>[A-Za-z0-9][A-Za-z0-9._-]*) result=pass -->\\z") ] as $verdicts
| [ $commits[] | if type == "array" then .[] else error("a page of commits is not a JSON array") end ] as $cs
| if ($cs | length) == 0 then error("the pull request lists no commits") else . end
| [ $cs[]
    | if type == "object" and (.commit.author.name | type) == "string" and (.commit.committer.name | type) == "string"
      then .commit.author.name, .commit.committer.name
      else error("a commit has no author or committer name") end ] as $writers
| [ $verdicts[] | select(.sha == $h) | .agent ] as $mine
| if ($mine | length) == 0 then (if ($verdicts | length) > 0 then "other" else "none" end)
  else ([ $mine[] | select(. as $a | any($writers[]; . == $a) | not) ] | .[0]) as $ok
    | if $ok != null then "ok \($ok)" else "writer \($mine[0])" end
  end
'

# A PR's commits (pulls/<n>/commits pages, slurped) -> "<commits listed> <commits carrying a
# Factory-Operator line>": a commit carries one when its message does (carrier), so that no
# text that becomes a trailer of a squash message made from these messages (GitHub's default)
# is missed. A commit without a message cannot be judged: an error.
# shellcheck disable=SC2016 # a jq program, not shell
AM_CARRIES_JQ=$AM_CARRIER_DEF'
[ .[] | if type == "array" then .[] else error("a page of commits is not a JSON array") end ]
| if length == 0 then error("the pull request lists no commits") else . end
| map(if type == "object" and (.commit.message | type) == "string" then .commit.message
      else error("a commit has no message") end)
| [ .[] | select(carrier) ] as $carriers
| "\(length) \($carriers | length)"
'

# Conclusions of the latest "gate" and "verify-fix" check runs on $h from the workflow $wf,
# one word per line. The check-runs API does not name a run's workflow: a check run belongs
# to the workflow whose run (actions/runs?head_sha=H, slurped as $wfruns) has its check
# suite. As in ship.sh: latest by completed_at; runs completed at that same time must all be
# SUCCESS; a run that has not completed is PENDING; none at all is MISSING.
# shellcheck disable=SC2016 # a jq program, not shell
AM_CHECKS_JQ='
def word: if type == "string" and test("\\A[A-Z_]{1,40}\\z") then . else "INVALID" end;
def latest($list; $name):
  [ $list[] | select(.name == $name)
    | { at: (.completed_at // "" | tostring), c: (.conclusion // "" | tostring | ascii_upcase),
        st: (.status // "" | tostring) }
    | .done = (.st == "completed" and (.c | length) > 0 and (.at | test("\\A[1-9][0-9]{3}-"))) ]
  | if length == 0 then "MISSING"
    elif any(.[]; .done | not) then "PENDING"
    else (map(.at) | max) as $t
      | [ .[] | select(.at == $t) | .c ]
      | (map(select(. != "SUCCESS")) | .[0]) as $c
      | if $c == null then "SUCCESS" else ($c | word) end
    end;
[ $wfruns[]
  | if type == "object" and (.workflow_runs | type) == "array" then .workflow_runs[]
    else error("a page of workflow runs has no workflow_runs list") end
  | objects | select(.name == $wf and (.head_sha // $h) == $h) | .check_suite_id | numbers ] as $suites
| [ $checkpages[]
    | if type == "object" and (.check_runs | type) == "array" then .check_runs[]
      else error("a page of check runs has no check_runs list") end
    | objects | select(.check_suite.id as $s | $s != null and any($suites[]; . == $s)) ] as $runs
| latest($runs; "gate"), latest($runs; "verify-fix")
'

# The closing issues of this repository (gh pr view --json closingIssuesReferences), one
# number per line. As in ship.sh and verify-fix.sh: a reference without repository fields
# counts as this repository, and one of this repository without a usable number is an error.
# shellcheck disable=SC2016 # a jq program, not shell
AM_CLOSING_JQ='
if type != "object" then error("not a JSON object") else . end
| (.closingIssuesReferences // []) as $refs
| if ($refs | type) != "array" then error("closingIssuesReferences is not a list") else $refs[] end
| if type != "object" then error("a closing issue reference is not an object") else . end
| select(((.repository.owner.login // $owner) | tostring | ascii_downcase) == ($owner | ascii_downcase)
    and ((.repository.name // $name) | tostring | ascii_downcase) == ($name | ascii_downcase))
| .number
| if type == "number" and . > 0 and . == floor and . < 1000000000 then tostring
  else error("a closing issue reference of this repository has no usable issue number") end
'

# The bug label an issue carries (gh issue view --json labels): role:bug-fix or bug, compared
# case-insensitively (the rule shared with ship.sh and verify-fix.sh). Empty when neither.
# shellcheck disable=SC2016 # a jq program, not shell
AM_BUGLABEL_JQ='
if type != "object" then error("not a JSON object") else . end
| [ (.labels // [])[]? | objects | .name // "" | tostring | ascii_downcase ] as $names
| first(("role:bug-fix", "bug") | select(. as $l | any($names[]; . == $l))) // ""
'

# The URL of the first open PR from this repository's branch $b in gh pr list --json
# number,url,isCrossRepository,headRefName, or "". --head matches a branch name only, so a
# PR from a fork whose branch has the same name is listed too: anyone can open one, and it is
# not the revert PR.
# shellcheck disable=SC2016 # a jq program, not shell
AM_OPEN_PR_JQ='
if type != "array" then error("not a JSON array") else . end
| [ .[] | objects | select(.isCrossRepository == false and .headRefName == $b)
    | .url | strings | select(test("\\Ahttps://[^[:space:][:cntrl:]\"<>]+\\z")) ] | .[0] // ""
'

# The revert PR's title: GitHub refuses a title longer than 256 characters, and a commit
# subject can be longer, so the subject keeps its first 200 characters.
# shellcheck disable=SC2016 # a jq program, not shell
AM_TITLE_JQ='"revert: " + (if length > 200 then .[0:200] + "..." else . end)'

AM_TREE=""
AM_TMP=""
AM_WT=""
AM_DONE=""
AM_REPO=""
AM_OWNER=""
AM_NAME=""
AM_REMOTE=""
AM_BASE_BRANCH=""
AM_BEFORE=""
AM_AFTER=""
AM_WHO=""
AM_NV=0
AM_UNDECIDED=0
AM_ACT_FAILED=0
AM_V_SHA=()
AM_V_WHY=()

# Exit paths. An unexpected failure under set -e can exit 1, which would read as "violation";
# the EXIT trap turns any exit 1 that was not chosen on purpose into 2.
am_exit() {
  AM_DONE=1
  exit "$1"
}

# shellcheck disable=SC2329 # invoked by the EXIT trap
am_on_exit() {
  local st=$?
  set +e
  if [ -n "$AM_WT" ]; then
    sf_git_bk -C "$AM_TREE" worktree remove --force "$AM_WT" >/dev/null 2>&1
    sf_git_bk -C "$AM_TREE" worktree prune >/dev/null 2>&1
  fi
  if [ -n "$AM_TMP" ]; then rm -rf "$AM_TMP" 2>/dev/null; fi
  if [ "$st" -eq 1 ] && [ -z "$AM_DONE" ]; then
    printf '%s: error: unexpected failure; treating it as an error, not a violation\n' "$SF_PROG" >&2
    st=2
  fi
  exit "$st"
}

# am_quote TEXT: TEXT as a JSON string (untrusted text is printed this way).
am_quote() { printf '%s' "$1" | sf_jq -Rs .; }

# am_repo: resolves owner/name once, before any other gh call, and names it in GH_REPO too
# (file-issue.sh's gh calls). GitHub is required from here on.
am_repo() {
  [ -z "$AM_REPO" ] || return 0
  if [ "${FACTORY_OFFLINE:-}" = 1 ]; then
    sf_die "GitHub is needed (every commit: even one with a Factory-Operator trailer may be a PR's merge commit; the stop switch; --act), but FACTORY_OFFLINE=1 is set"
  fi
  sf_need gh
  sf_gh repo view --json owner,name </dev/null >"$AM_TMP/repo.json" ||
    sf_die "could not tell which GitHub repository $AM_TREE belongs to (gh repo view)"
  AM_REPO=$(sf_jq -r "$AM_REPO_JQ" <"$AM_TMP/repo.json") ||
    sf_die "gh repo view returned no valid owner and name"
  [[ $AM_REPO =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || sf_die "gh repo view returned no valid owner and name"
  AM_OWNER=${AM_REPO%%/*}
  AM_NAME=${AM_REPO#*/}
  GH_REPO=$AM_REPO
  export GH_REPO
}

# am_enabled: 0 when FACTORY_ENABLED is true (run-agent.sh's rule); otherwise it says
# "factory stopped" and returns 1.
am_enabled() {
  local v
  if [ "${CI:-}" = true ] || [ "${FACTORY_OFFLINE:-}" = 1 ]; then
    [ "${FACTORY_ENABLED:-}" = true ] && return 0
    sf_log "factory stopped: FACTORY_ENABLED is not true (read from the environment); nothing audited"
    return 1
  fi
  am_repo
  if ! v=$(sf_gh variable get FACTORY_ENABLED -R "$AM_REPO" </dev/null); then
    sf_log "factory stopped: the repo variable FACTORY_ENABLED could not be read; nothing audited"
    return 1
  fi
  v=$(printf '%s' "$v" | tr -d '[:space:]')
  [ "$v" = true ] && return 0
  sf_log "factory stopped: the repo variable FACTORY_ENABLED is not true; nothing audited"
  return 1
}

# am_operator C: AM_OP is the reason of C's first non-empty Factory-Operator trailer (the
# key compared case-insensitively, as git does); AM_OP_EMPTY=1 when C has only empty ones.
# Returns 1 when the message cannot be read.
am_operator() {
  local out
  AM_OP=""
  AM_OP_EMPTY=""
  git -C "$AM_TREE" log -1 --no-show-signature --format=%B "$1" -- </dev/null >"$AM_TMP/msg" || return 1
  # --no-divider, as git reads a commit's own trailers (%(trailers)): a "---" line in a
  # commit message is text, not the start of a patch that would end the message there.
  git -C "$AM_TREE" interpret-trailers --parse --no-divider <"$AM_TMP/msg" >"$AM_TMP/trailers" || return 1
  out=$(awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    {
      i = index($0, ":")
      if (i == 0 || tolower(trim(substr($0, 1, i - 1))) != "factory-operator") next
      v = trim(substr($0, i + 1))
      if (v == "") { empty = 1; next }
      if (!found) { print "R" v; found = 1 }
    }
    END { if (!found && empty) print "E" }' "$AM_TMP/trailers") || return 1
  case "$out" in
    R*) AM_OP=${out#R} ;;
    E) AM_OP_EMPTY=1 ;;
  esac
  return 0
}

# am_pr_commits N: the commits of PR #N (pulls/N/commits, every page) in $AM_TMP/commits-N.json,
# read once per run: both the trailer rule and the verdict rule need them. Returns 1 when they
# cannot be read.
am_pr_commits() {
  local f="$AM_TMP/commits-$1.json"
  [ ! -f "$f" ] || return 0
  if sf_gh api "repos/$AM_REPO/pulls/$1/commits" --paginate </dev/null >"$f.part"; then
    mv -f "$f.part" "$f" && return 0
  fi
  rm -f "$f.part"
  return 1
}

# am_carriers N: whether PR #N's own commits carry a Factory-Operator line (AM_CARRIES_JQ).
# Sets AM_CARRY to "yes", "no" or "unknown" (with AM_CARRY_WHY).
am_carriers() {
  local n=$1 out total carry
  AM_CARRY=unknown
  AM_CARRY_WHY=""
  if ! am_pr_commits "$n"; then
    AM_CARRY_WHY="could not list the commits of PR #$n"
    return 0
  fi
  if ! out=$(sf_jq -r -s "$AM_CARRIES_JQ" <"$AM_TMP/commits-$n.json"); then
    AM_CARRY_WHY="could not parse the commits of PR #$n"
    return 0
  fi
  read -r total carry <<EOF
$out
EOF
  if ! [[ ${total:-} =~ ^[0-9]+$ ]] || ! [[ ${carry:-} =~ ^[0-9]+$ ]]; then
    AM_CARRY_WHY="unexpected commit scan result for PR #$n"
  elif [ "$carry" -gt 0 ]; then
    AM_CARRY=yes
  elif [ "$total" -ge "$AM_PR_COMMITS_MAX" ]; then
    AM_CARRY_WHY="PR #$n lists $total commits, the most GitHub lists, so a later one may carry a Factory-Operator trailer"
  else
    AM_CARRY=no
  fi
  return 0
}

# am_check_text NAME CONCLUSION H: why the latest NAME check run on H does not count.
am_check_text() {
  case "$2" in
    MISSING) printf 'no %s check run of the workflow %s on %s' "$1" "$AM_WORKFLOW" "$3" ;;
    PENDING) printf 'the latest %s check run of the workflow %s on %s has not completed' "$1" "$AM_WORKFLOW" "$3" ;;
    *) printf 'the latest %s check run of the workflow %s on %s is %s' "$1" "$AM_WORKFLOW" "$3" "$2" ;;
  esac
}

# am_bugfix N REF: AM_BUGFIX says why PR #N is a bug fix (the rule shared with ship.sh and
# verify-fix.sh), or is empty. Returns 1, with AM_PR_WHY, when that cannot be told: an issue
# whose labels cannot be read may carry a bug label, so it is never "not a bug fix". The
# branch is a claim key, factory/issue-<n> with n without a leading zero, as in ship.sh.
am_bugfix() {
  local n=$1 ref=$2 closing i label
  AM_BUGFIX=""
  if [[ $ref =~ ^factory/issue-[1-9][0-9]*$ ]]; then
    AM_BUGFIX="branch $ref"
    return 0
  fi
  if ! sf_gh pr view "$n" -R "$AM_REPO" --json closingIssuesReferences </dev/null >"$AM_TMP/closing.json"; then
    AM_PR_WHY="could not read the closing issues of PR #$n (gh pr view)"
    return 1
  fi
  if ! closing=$(sf_jq -r --arg owner "$AM_OWNER" --arg name "$AM_NAME" "$AM_CLOSING_JQ" <"$AM_TMP/closing.json"); then
    AM_PR_WHY="could not parse the closing issues of PR #$n"
    return 1
  fi
  for i in $closing; do
    if ! sf_gh issue view "$i" -R "$AM_REPO" --json labels </dev/null >"$AM_TMP/issue.json"; then
      AM_PR_WHY="could not read the labels of issue #$i, which PR #$n closes, so whether it is a bug fix is unknown"
      return 1
    fi
    if ! label=$(sf_jq -r "$AM_BUGLABEL_JQ" <"$AM_TMP/issue.json"); then
      AM_PR_WHY="could not parse the labels of issue #$i, which PR #$n closes"
      return 1
    fi
    case "$label" in
      role:bug-fix | bug)
        AM_BUGFIX="closes #$i, labelled $label"
        return 0
        ;;
      '') ;;
      *)
        AM_PR_WHY="could not parse the labels of issue #$i, which PR #$n closes"
        return 1
        ;;
    esac
  done
  return 0
}

# am_audit_pr N H REF: judges merged PR #N with head H. Sets AM_PR_RESULT (ok, violation or
# error) and AM_PR_WHY. A rule that was read and is broken makes a violation even when another
# rule could not be read (as in ship.sh, a refusal wins over "could not decide"): otherwise a
# merge without any verdict would get no revert PR and no issue just because, say, the labels
# of an issue it closes cannot be read. Only when no rule is broken does an unread one make an
# error.
am_audit_pr() {
  local n=$1 h=$2 ref=$3 verdict out gate="" vfix="" whys="" unread=""
  AM_PR_RESULT=error
  AM_PR_WHY=""
  # The verdict and its agent.
  if ! sf_gh api "repos/$AM_REPO/issues/$n/comments" --paginate </dev/null >"$AM_TMP/comments.json"; then
    unread="could not read the comments of PR #$n"
  elif ! am_pr_commits "$n"; then
    unread="could not list the commits of PR #$n"
  elif ! verdict=$(sf_jq -n -r --arg h "$h" --slurpfile comments "$AM_TMP/comments.json" \
    --slurpfile commits "$AM_TMP/commits-$n.json" "$AM_VERDICT_JQ"); then
    unread="could not parse the comments or commits of PR #$n"
  else
    case "$verdict" in
      "ok "*) ;;
      none) whys="no verdict comment for its head $h" ;;
      other) whys="the verdict comments are for other commits, not for its head $h" ;;
      "writer "*)
        whys="the verdict for $h names ${verdict#writer }, who authored or committed commits of the PR (the writer is never the shipper)"
        ;;
      *) unread="unexpected verdict scan result for PR #$n" ;;
    esac
  fi

  # The gate and verify-fix check runs.
  if ! sf_gh api "repos/$AM_REPO/commits/$h/check-runs" --paginate </dev/null >"$AM_TMP/checks.json"; then
    unread="${unread:+$unread; }could not read the check runs on $h (PR #$n)"
  elif ! sf_gh api "repos/$AM_REPO/actions/runs?head_sha=$h" --paginate </dev/null >"$AM_TMP/runs.json"; then
    unread="${unread:+$unread; }could not read the workflow runs on $h (PR #$n)"
  elif ! out=$(sf_jq -n -r --arg h "$h" --arg wf "$AM_WORKFLOW" --slurpfile wfruns "$AM_TMP/runs.json" \
    --slurpfile checkpages "$AM_TMP/checks.json" "$AM_CHECKS_JQ"); then
    unread="${unread:+$unread; }could not parse the check runs or workflow runs on $h (PR #$n)"
  else
    { IFS= read -r gate && IFS= read -r vfix; } <<EOF || true
$out
EOF
    if [ -z "$gate" ] || [ -z "$vfix" ]; then
      unread="${unread:+$unread; }unexpected check run scan result on $h (PR #$n)"
    else
      if [ "$gate" != SUCCESS ]; then
        whys="${whys:+$whys; }$(am_check_text gate "$gate" "$h")"
      fi
      # Only a verify-fix that is not SUCCESS needs the bug-fix question answered.
      if [ "$vfix" != SUCCESS ]; then
        if ! am_bugfix "$n" "$ref"; then
          unread="${unread:+$unread; }$AM_PR_WHY"
        elif [ -n "$AM_BUGFIX" ]; then
          whys="${whys:+$whys; }bug fix ($AM_BUGFIX): $(am_check_text verify-fix "$vfix" "$h")"
        fi
      fi
    fi
  fi

  if [ -n "$whys" ]; then
    AM_PR_RESULT=violation
    AM_PR_WHY="PR #$n skipped the merge policy: $whys${unread:+ (also, $unread)}"
  elif [ -n "$unread" ]; then
    AM_PR_RESULT=error
    AM_PR_WHY=$unread
  else
    AM_PR_RESULT=ok
    AM_PR_WHY=""
  fi
  return 0
}

# am_audit C: decides one commit. Sets AM_RESULT (ok, violation or error), AM_LINE for ok,
# and AM_WHY for a violation or an error.
#
# A Factory-Operator trailer passes C at once, unless C is the merge commit of a merged PR: a
# merge message filled in by GitHub holds the PR's commit messages (a squash), its title (a
# merge commit) or its description, all the writer's, so a writer could have put the trailer
# there. Then it counts only when neither the title, the description nor a commit of any such
# PR carries one (AM_PULLS_JQ, am_carriers); when one does, C passes only as shipped. So every
# commit needs GitHub, operator commits too.
am_audit() {
  local c=$1 rows q="" n h ref text first="" err="" i smuggled="" op_unknown=""
  local -a pn=() ph=() pr=() pb=()
  AM_RESULT=error
  AM_LINE=""
  AM_WHY=""
  if ! am_operator "$c"; then
    AM_WHY="could not read the message of $c"
    return 0
  fi
  if [ -n "$AM_OP" ] && ! q=$(am_quote "$AM_OP"); then
    AM_WHY="could not quote the Factory-Operator reason of $c"
    return 0
  fi

  am_repo
  if ! sf_gh api "repos/$AM_REPO/commits/$c/pulls" --paginate </dev/null >"$AM_TMP/pulls.json"; then
    AM_WHY="could not list the pull requests of $c (gh api)"
    return 0
  fi
  if ! rows=$(sf_jq -r -s --arg c "$c" "$AM_PULLS_JQ" <"$AM_TMP/pulls.json"); then
    AM_WHY="could not parse the pull requests of $c"
    return 0
  fi
  while read -r n h ref text; do
    if [ -n "$n" ]; then
      pn+=("$n")
      ph+=("$h")
      pr+=("$ref")
      pb+=("$text")
    fi
  done <<EOF
$rows
EOF

  # The trailer: it counts unless the title, the description or a commit of a PR with C as its
  # merge commit carries one.
  if [ -n "$AM_OP" ]; then
    i=0
    while [ "$i" -lt "${#pn[@]}" ]; do
      case "${pb[$i]}" in
        carries) smuggled="${smuggled:+$smuggled; }the title or description of PR #${pn[$i]} has one too" ;;
        clean) ;;
        *) [ -n "$op_unknown" ] || op_unknown="the title or description of PR #${pn[$i]} is not text" ;;
      esac
      if [ "${pb[$i]}" != carries ]; then
        am_carriers "${pn[$i]}"
        case "$AM_CARRY" in
          yes) smuggled="${smuggled:+$smuggled; }commits of PR #${pn[$i]} carry one too" ;;
          no) ;;
          *) [ -n "$op_unknown" ] || op_unknown=$AM_CARRY_WHY ;;
        esac
      fi
      i=$((i + 1))
    done
    if [ -z "$smuggled" ] && [ -z "$op_unknown" ]; then
      AM_RESULT=ok
      AM_LINE="ok $c operator: $q"
      return 0
    fi
  fi

  if [ "${#pn[@]}" -eq 0 ]; then
    AM_RESULT=violation
    AM_WHY="not shipped: no merged pull request has it as its merge commit, and it has no Factory-Operator trailer"
  else
    i=0
    while [ "$i" -lt "${#pn[@]}" ]; do
      am_audit_pr "${pn[$i]}" "${ph[$i]}" "${pr[$i]}"
      case "$AM_PR_RESULT" in
        ok)
          AM_RESULT=ok
          AM_LINE="ok $c shipped #${pn[$i]}"
          return 0
          ;;
        violation) [ -n "$first" ] || first=$AM_PR_WHY ;;
        *) [ -n "$err" ] || err=$AM_PR_WHY ;;
      esac
      i=$((i + 1))
    done
    if [ -n "$err" ]; then
      AM_WHY=$err
      return 0
    fi
    if [ -n "$smuggled" ]; then
      AM_RESULT=violation
      AM_WHY="$first; its Factory-Operator trailer does not count: $smuggled, and a writer could have put it into the merge message"
      return 0
    fi
    if [ -n "$op_unknown" ]; then
      # The trailer may count: neither a pass nor a violation.
      AM_WHY="$op_unknown, so whether its Factory-Operator trailer counts cannot be told (and $first)"
      return 0
    fi
    AM_RESULT=violation
    AM_WHY="$first; it has no Factory-Operator trailer"
  fi
  if [ -n "$AM_OP_EMPTY" ]; then
    AM_WHY="$AM_WHY (its Factory-Operator trailer gives no reason)"
  fi
  return 0
}

am_act_fail() {
  AM_ACT_FAILED=$((AM_ACT_FAILED + 1))
  sf_log "error: --act for $1: $2"
}

# am_pr_body C WHY REVERT_CMD: the revert PR's body (the sections of templates/pr-body.md
# that ship.sh looks for). WHY is the audit's own text, never untrusted text.
# shellcheck disable=SC2016 # Markdown backticks and a "$ " prompt, not shell expansions
am_pr_body() {
  printf '## What\n\nReverts %s, which reached `%s` without passing the merge policy: `%s` on top of %s.\n\n' \
    "$1" "$AM_BASE_BRANCH" "$3" "$AM_AFTER"
  printf '## Why\n\n%s\n\n' "$2"
  printf '## Evidence\n\n```text\n$ bash scripts/audit-merge.sh --before %s --after %s\nviolation %s %s\n```\n\n' \
    "$AM_BEFORE" "$AM_AFTER" "$1" "$2"
  printf 'Merge this PR to undo the commit, or close it to keep the commit. Whoever merges this PR by hand (not through ship.sh) must add a `Factory-Operator: <reason>` trailer to the merge commit (for a squash merge, in the merge dialog), or the merge audit flags the revert as well. A commit pushed to `%s` on purpose needs the same trailer.\n' \
    "$AM_BASE_BRANCH"
}

# am_issue_body C WHY REVERT_CMD URL REUSED: the needs-human issue, linking the commit and the
# revert PR (URL), or saying that the revert does not apply (no URL).
# shellcheck disable=SC2016 # Markdown backticks, not command substitutions
am_issue_body() {
  printf 'Commit %s reached `%s` without passing the merge policy (push %s..%s).\n\n' \
    "$1" "$AM_BASE_BRANCH" "$AM_BEFORE" "$AM_AFTER"
  printf 'Why: %s\n\n' "$2"
  if [ -n "$4" ]; then
    printf 'Revert PR: %s%s\n\n' "$4" "${5:+ (it was already open)}"
    printf 'Merge the revert PR to undo the commit (by hand: add a `Factory-Operator: <reason>` trailer to its merge commit), or close it to keep the commit.'
  else
    printf 'Revert: `%s` does not apply cleanly on top of %s, so no revert branch or PR was made. Revert the commit by hand, or keep it.' \
      "$3" "$AM_AFTER"
  fi
  printf ' A commit pushed to `%s` on purpose needs a `Factory-Operator: <reason>` trailer. Answer with a comment whose first line starts with `answer:`.\n' \
    "$AM_BASE_BRANCH"
}

# am_revert C MERGE: makes the revert of C on top of AFTER in a temporary worktree, as a
# bookkeeping commit. AM_REVERT_SHA is the new commit, or empty when the revert does not
# apply cleanly. Returns 1 (after am_act_fail) when the worktree cannot be made.
am_revert() {
  local c=$1 rc=0
  local -a m=()
  [ -z "$2" ] || m=(-m 1)
  AM_REVERT_SHA=""
  AM_WT="$AM_TMP/revert-${c:0:$AM_SHORT}"
  if ! sf_git_bk -C "$AM_TREE" -c core.autocrlf=false -c core.longpaths=true \
    worktree add --detach --quiet "$AM_WT" "$AM_AFTER" \
    </dev/null >"$AM_TMP/wt.out" 2>&1; then
    sed 's/^/  | /' "$AM_TMP/wt.out" >&2
    AM_WT=""
    am_act_fail "$c" "could not create a worktree at $AM_AFTER"
    return 1
  fi
  (
    GIT_AUTHOR_NAME=$AM_WHO
    GIT_AUTHOR_EMAIL="$AM_WHO@agents.factory.invalid"
    GIT_COMMITTER_NAME=$AM_WHO
    GIT_COMMITTER_EMAIL="$AM_WHO@agents.factory.invalid"
    export GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
    sf_git_bk -C "$AM_WT" -c core.autocrlf=false revert --no-edit ${m[@]+"${m[@]}"} "$c"
  ) </dev/null >"$AM_TMP/revert.out" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    if ! AM_REVERT_SHA=$(git -C "$AM_WT" rev-parse --verify --quiet "HEAD^{commit}"); then
      AM_REVERT_SHA=""
      rc=1
    fi
  else
    sed 's/^/  | /' "$AM_TMP/revert.out" >&2
    sf_git_bk -C "$AM_WT" revert --abort >/dev/null 2>&1 || true
  fi
  sf_git_bk -C "$AM_TREE" worktree remove --force "$AM_WT" >/dev/null 2>&1 ||
    sf_warn "could not remove the temporary worktree $AM_WT"
  AM_WT=""
  if [ "$rc" -ne 0 ] || [ -z "$AM_REVERT_SHA" ]; then
    AM_REVERT_SHA=""
    sf_log "$c: git revert --no-edit${2:+ -m 1} does not apply cleanly on top of $AM_AFTER; no revert branch or PR"
  fi
  return 0
}

# am_act C WHY: revert branch, revert PR (or the open one) and a needs-human issue for one
# violation. Failures are counted (exit 2), never fatal, so the other violations are handled.
am_act() {
  local c=$1 why=$2 short branch pr_title merge="" url="" reused="" observed title rc=0 num revert_cmd
  short=${c:0:$AM_SHORT}
  branch="factory/revert-$short"
  if ! git -C "$AM_TREE" log -1 --no-show-signature --format=%s "$c" -- </dev/null >"$AM_TMP/subject" ||
    ! pr_title=$(tr -d '\000-\037\177' <"$AM_TMP/subject" | sf_jq -R -r -s "$AM_TITLE_JQ"); then
    am_act_fail "$c" "could not read its subject"
    return 0
  fi
  if git -C "$AM_TREE" rev-parse --verify --quiet "$c^2" >/dev/null 2>&1; then merge=1; fi
  revert_cmd="git revert --no-edit${merge:+ -m 1} $c"

  if ! sf_gh pr list -R "$AM_REPO" --head "$branch" --state open --json number,url,isCrossRepository,headRefName \
    </dev/null >"$AM_TMP/open.json"; then
    am_act_fail "$c" "could not list the open PRs from $branch"
    return 0
  fi
  if ! url=$(sf_jq -r --arg b "$branch" "$AM_OPEN_PR_JQ" <"$AM_TMP/open.json"); then
    am_act_fail "$c" "could not parse the open PRs from $branch"
    return 0
  fi
  if [ -n "$url" ]; then
    reused=1
    sf_log "$c: reusing the open revert PR $url"
  else
    am_revert "$c" "$merge" || return 0
    if [ -n "$AM_REVERT_SHA" ]; then
      # Replaces a stale branch left without an open PR; a lease on what was observed.
      if ! observed=$(sf_git_bk -C "$AM_TREE" ls-remote "$AM_REMOTE" "refs/heads/$branch" </dev/null); then
        am_act_fail "$c" "could not read $branch on $AM_REMOTE"
        return 0
      fi
      observed=$(printf '%s\n' "$observed" | awk -v r="refs/heads/$branch" '$2 == r { print $1; exit }')
      if ! sf_git_bk -C "$AM_TREE" push --quiet "--force-with-lease=refs/heads/$branch:$observed" \
        "$AM_REMOTE" "$AM_REVERT_SHA:refs/heads/$branch" </dev/null >&2; then
        am_act_fail "$c" "could not push $branch to $AM_REMOTE"
        return 0
      fi
      sf_log "$c: pushed $branch ($AM_REVERT_SHA)"
      am_pr_body "$c" "$why" "$revert_cmd" >"$AM_TMP/pr-body.md"
      if ! sf_gh pr create -R "$AM_REPO" --base "$AM_BASE_BRANCH" --head "$branch" --title "$pr_title" \
        --body-file - <"$AM_TMP/pr-body.md" >"$AM_TMP/pr.out"; then
        am_act_fail "$c" "could not open the revert PR from $branch"
        return 0
      fi
      url=$(grep -Eo 'https://[^[:space:]"<>]+/pull/[0-9]+' "$AM_TMP/pr.out" | tail -n 1) || url=""
      if [ -z "$url" ]; then
        am_act_fail "$c" "gh pr create printed no PR URL"
        return 0
      fi
      sf_log "$c: opened the revert PR $url"
    fi
  fi

  title="audit-merge: commit $short on $AM_BASE_BRANCH skipped the merge policy"
  am_issue_body "$c" "$why" "$revert_cmd" "$url" "$reused" >"$AM_TMP/issue-body.md"
  FACTORY_AGENT_ID=$AM_WHO GH_REPO=$AM_REPO bash "$SF_SCRIPTS_DIR/file-issue.sh" --role babysit \
    --label needs-human --title "$title" --body-file "$AM_TMP/issue-body.md" </dev/null >"$AM_TMP/issue.out" || rc=$?
  num=$(tr -cd '0-9' <"$AM_TMP/issue.out") || num=""
  case "$rc" in
    0) sf_log "$c: filed issue #$num" ;;
    3) sf_log "$c: issue #$num is already open" ;;
    *) am_act_fail "$c" "file-issue.sh exited $rc" ;;
  esac
  return 0
}

main() {
  local before="" after="" act="" tree="" config="" c i code rc
  local -a commits=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h | --help) usage; exit 0 ;;
      --before | --after | --tree | --config)
        [ "$#" -ge 2 ] && [ -n "$2" ] || sf_die "$1 needs a value (see --help)"
        case "$1" in
          --before) before=$2 ;;
          --after) after=$2 ;;
          --tree) tree=$2 ;;
          *) config=$2 ;;
        esac
        shift 2
        ;;
      --act) act=1; shift ;;
      *) sf_die "unknown argument: $(am_quote "$1") (see --help)" ;;
    esac
  done
  [ -n "$before" ] || sf_die "--before is required (see --help)"
  [ -n "$after" ] || sf_die "--after is required (see --help)"
  [[ $before =~ ^[0-9a-f]{4,64}$ ]] || sf_die "--before must be a commit sha (lowercase hex)"
  [[ $after =~ ^[0-9a-f]{4,64}$ ]] || sf_die "--after must be a commit sha (lowercase hex)"
  [[ ! $after =~ ^0+$ ]] || sf_die "--after is all zeros: the branch was deleted, there is no commit to audit"
  if [[ $before =~ ^0+$ ]]; then
    sf_log "--before is all zeros (a new branch): nothing to audit"
    exit 0
  fi

  sf_need git jq
  # Before the cd below: a relative --config or FACTORY_CONFIG names a file from where the
  # caller stands, as in ship.sh.
  if [ -n "$act" ] || [ -n "$config" ]; then
    if [ -n "$config" ]; then sf_config_load "$config"; else sf_config_load; fi
    AM_BASE_BRANCH=$(sf_cfg base_branch main)
    git check-ref-format "refs/heads/$AM_BASE_BRANCH" >/dev/null 2>&1 && [[ $AM_BASE_BRANCH != -* ]] ||
      sf_die "invalid base_branch in $SF_CONFIG_FILE"
  fi
  AM_TREE=$(sf_repo_root "${tree:-.}") || exit 2
  # gh resolves the repository from the tree's remotes.
  cd "$AM_TREE" || sf_die "cannot enter $AM_TREE"
  AM_TREE=$PWD
  AM_REMOTE=$(sf_remote)
  [[ $AM_REMOTE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || sf_die "invalid FACTORY_REMOTE $(am_quote "$AM_REMOTE")"
  AM_WHO=${FACTORY_AGENT_ID:-audit-merge}
  [[ $AM_WHO =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || AM_WHO=audit-merge
  AM_TMP=$(sf_mktemp_dir) || sf_die "could not create a temp dir"
  trap am_on_exit EXIT

  am_enabled || am_exit 0

  # In a shallow clone, rev-list stops at the shallow boundary without an error, so commits
  # of the range would go unaudited: the history must be complete.
  case "$(git -C "$AM_TREE" rev-parse --is-shallow-repository 2>/dev/null)" in
    false) ;;
    true) sf_die "$AM_TREE is a shallow clone: fetch the full history (fetch-depth: 0), or commits of the range would be missed" ;;
    *) sf_die "could not tell whether $AM_TREE is a shallow clone" ;;
  esac

  AM_BEFORE=$(git -C "$AM_TREE" rev-parse --verify --quiet "$before^{commit}") ||
    sf_die "--before $before is not a commit in $AM_TREE (fetch the history first)"
  AM_AFTER=$(git -C "$AM_TREE" rev-parse --verify --quiet "$after^{commit}") ||
    sf_die "--after $after is not a commit in $AM_TREE (fetch the history first)"
  # A force push: BEFORE is not in AFTER's history, so BEFORE..AFTER holds every rewritten
  # commit, each looking new, and reverting them one by one would undo what is not new. It is
  # one violation for a person to look at; --act does nothing for it.
  rc=0
  git -C "$AM_TREE" merge-base --is-ancestor "$AM_BEFORE" "$AM_AFTER" </dev/null || rc=$?
  case "$rc" in
    0) ;;
    1)
      printf 'violation %s force push\n' "$AM_AFTER"
      sf_log "--before $AM_BEFORE is not an ancestor of --after $AM_AFTER: a force push rewrote the branch; its commits are not audited one by one${act:+, and --act does nothing for it}"
      sf_log "audited 0 commit(s): 1 violation (force push), 0 undecided"
      am_exit 1
      ;;
    *) sf_die "git merge-base --is-ancestor $AM_BEFORE $AM_AFTER failed (exit $rc)" ;;
  esac
  git -C "$AM_TREE" rev-list --first-parent --reverse "$AM_BEFORE..$AM_AFTER" -- </dev/null >"$AM_TMP/commits" ||
    sf_die "git rev-list --first-parent $AM_BEFORE..$AM_AFTER failed"
  while IFS= read -r c; do
    if [ -n "$c" ]; then commits+=("$c"); fi
  done <"$AM_TMP/commits"
  if [ "${#commits[@]}" -eq 0 ]; then
    sf_log "no commits in $AM_BEFORE..$AM_AFTER: nothing to audit"
    am_exit 0
  fi

  for c in "${commits[@]}"; do
    [[ $c =~ ^[0-9a-f]{40,64}$ ]] || sf_die "git rev-list printed an unexpected line"
    am_audit "$c"
    case "$AM_RESULT" in
      ok) printf '%s\n' "$AM_LINE" ;;
      violation)
        printf 'violation %s %s\n' "$c" "$AM_WHY"
        AM_V_SHA+=("$c")
        AM_V_WHY+=("$AM_WHY")
        AM_NV=$((AM_NV + 1))
        ;;
      *)
        sf_log "error: could not audit $c: $AM_WHY"
        AM_UNDECIDED=$((AM_UNDECIDED + 1))
        ;;
    esac
  done

  if [ -n "$act" ] && [ "$AM_NV" -gt 0 ]; then
    am_repo
    i=0
    while [ "$i" -lt "$AM_NV" ]; do
      am_act "${AM_V_SHA[$i]}" "${AM_V_WHY[$i]}"
      i=$((i + 1))
    done
  fi

  sf_log "audited ${#commits[@]} commit(s): $AM_NV violation(s), $AM_UNDECIDED undecided"
  # A violation is a decision, so it wins over a commit that could not be decided; an --act
  # step that failed wins over both (the violation was not handled).
  code=0
  if [ "$AM_ACT_FAILED" -gt 0 ]; then
    sf_log "error: $AM_ACT_FAILED --act step(s) failed"
    code=2
  elif [ "$AM_NV" -gt 0 ]; then
    code=1
  elif [ "$AM_UNDECIDED" -gt 0 ]; then
    sf_log "error: could not decide $AM_UNDECIDED commit(s): GitHub could not be read"
    code=2
  fi
  AM_DONE=1
  return "$code"
}

# Everything above only defines functions and constants. bash reads a script file as it runs
# it; function bodies are parsed when defined, and this last line is parsed whole before main
# runs, so an in-place rewrite of this file (a checkout in the same tree, say) changes nothing.
main "$@"; exit $?
