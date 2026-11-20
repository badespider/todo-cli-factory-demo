#!/usr/bin/env bash
# Merge policy for factory PRs and the only path to merge (the writer is never the shipper). Contract: docs/CONTRACTS.md, "ship.sh".
set -euo pipefail
SF_PROG=ship
# shellcheck source=scripts/lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
# shellcheck source=scripts/lib/jq.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/jq.sh"
# shellcheck source=scripts/lib/config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"

usage() {
  cat <<'EOF'
Usage: ship.sh check N [--sha SHA] [--ci] [--tree DIR] [--config FILE]
       ship.sh merge N [--sha SHA] [--tree DIR] [--config FILE]

check  judges PR #N against the merge policy and prints one "ship: policy: <reason>" line
       on stderr for every rule it breaks:
         - with --sha: the PR head is still SHA ("ship: policy: head moved" otherwise)
         - the latest "gate" CheckRun from the workflow "gate" on the head is SUCCESS
           (latest by completedAt; all runs at that time SUCCESS; one still running fails)
         - bug fixes (branch factory/issue-<n>, n without a leading zero, or closing an
           issue of this repository labelled role:bug-fix or bug; factory/perf-<n> is not
           one): the latest "verify-fix" CheckRun from the workflow "gate" is SUCCESS
         - every approval class (blast-radius.sh classes, plus "checkpoint" for the
           intake/plan branches, factory/spec.md, and factory/feature-map.json off a
           factory/F<n> branch) needs a comment that is exactly "approve <full head sha>",
           by a login in merge.approvers; with merge.approvers none, by an account whose
           author_association is OWNER, MEMBER or COLLABORATOR (a missing or empty
           merge.approvers exits 2)
         - rules-change: the latest "gate-self" CheckRun from the workflow "gate" is SUCCESS
         - open, targets base_branch, not a draft, mergeable, the head contains
           origin/<base>, no verify:findings label, a conventional title (type feat, fix,
           perf, refactor, test, docs, chore, ci, build or revert), and ## What, ## Why
           and ## Evidence sections in the body
       mergeable UNKNOWN is asked again 10 times; still UNKNOWN exits 2 (could not decide)
       unless another rule already refuses the PR.
merge  needs FACTORY_AGENT_ID. Runs check; refuses when FACTORY_AGENT_ID authored or
       committed any commit of the PR; for a bug fix, re-runs verify-fix.sh --pr N
       (judging copy, in the tree) with the labels and links as they are now: it runs
       before any of the PR's code, with ship's own GitHub access, which it needs to read
       the PR and its issues and keeps from the code it runs (not verified refuses;
       inconclusive, an error, "nothing to verify", or a head that moved while it ran
       exits 2); then re-runs gate.sh (judging copy) in a detached worktree at the head,
       without credential-like variables (a list of them that cannot be made exits 2)
       and with an empty GH_CONFIG_DIR. Then posts the verdict comment; merges with
       merge.method and --match-head-commit; reads mergedAt back; deletes a factory/*
       head branch. Prints the PR URL.

  --sha SHA      the full (40-hex) head sha the caller reviewed; a PR whose head is
                 anything else is refused ("head moved"). A malformed SHA exits 2
  --tree DIR     repository to fetch into and judge (default: the current repo root)
  --config FILE  config (default: FACTORY_CONFIG, else the judging copy's factory.config.yaml)
  --ci           check only; reserved for checks that only make sense at merge time
  -h, --help     show this help

Environment: FACTORY_AGENT_ID (merge), FACTORY_REMOTE (default origin), FACTORY_OFFLINE=1
(exits 2: ship needs GitHub), SF_SHIP_RETRY_SLEEP (seconds between retries, default 3).

Exit: 0 passes the policy / merged; 1 refused (a policy line, the shipper's own commits, a
failing gate re-run, a fix verify-fix does not verify); 2 usage or config error, or could
not decide (GitHub unreadable, the head moved during the run, a gate or verify-fix re-run
that could not decide); 3 merged but mergedAt not read back.
EOF
}

SHIP_PR_FIELDS=number,title,body,isDraft,mergeable,headRefOid,headRefName,baseRefName,labels,statusCheckRollup,url,state,closingIssuesReferences
SHIP_RETRIES=10
SHIP_READBACK_TRIES=3
SHIP_FINDINGS_LABEL=verify:findings
# The workflow whose CheckRuns count (gate, verify-fix, gate-self are its jobs).
SHIP_WORKFLOW=gate
# Never handed to the gate re-run (the contract's list), whatever sf_credential_names finds;
# every other credential-like name goes too (ship_judge_scrubbed).
SHIP_SCRUB_ALWAYS="GH_TOKEN GITHUB_TOKEN FACTORY_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN FACTORY_AGENT_ENV SSH_AUTH_SOCK"
# Conventional commit title. \A and \z: a title must be one line, start to end. revert: the
# revert PRs audit-merge.sh opens are titled "revert: <subject>".
SHIP_TITLE_RE='\A(feat|fix|perf|refactor|test|docs|chore|ci|build|revert)(\([^)]+\))?!?: .+\z'

# Parses `gh pr view --json $SHIP_PR_FIELDS` into one line per value, in a fixed order.
# Everything in a PR is untrusted: a value that could break a line, or a missing field,
# is an error (exit 2), and free text (title, body) never leaves jq except JSON-quoted.
# $repo is `gh repo view --json owner,name`, slurped; its owner and name come first.
# shellcheck disable=SC2016 # a jq program, not shell
SHIP_PR_JQ='
def bad: test("[[:cntrl:]]");
def field($k):
  .[$k] as $v
  | if ($v | type) == "string" and ($v | length) > 0 and ($v | bad | not) then $v
    else error("field \($k) is missing or is not a single-line string") end;
def word: if type == "string" and test("\\A[A-Z_]{1,40}\\z") then . else "INVALID" end;
# Conclusion of the latest CheckRun named $name from the workflow $wf, by completedAt. Runs
# that completed at that same latest time must all be SUCCESS. A run that has not completed
# (no conclusion, or no real completedAt: gh prints 0001-01-01 while it runs) has a verdict
# still to come, later than any completed one: PENDING.
def latest($name; $wf):
  [ (.statusCheckRollup // [])[]? | objects
    | select(.__typename == "CheckRun" and .name == $name and .workflowName == $wf)
    | { at: (.completedAt // "" | tostring), c: (.conclusion // "" | tostring) }
    | .done = ((.c | length) > 0 and (.at | test("\\A[1-9][0-9]{3}-"))) ]
  | if length == 0 then "MISSING"
    elif any(.[]; .done | not) then "PENDING"
    else (map(.at) | max) as $t
      | [ .[] | select(.at == $t) | .c ]
      | (map(select(. != "SUCCESS")) | .[0]) as $c
      | if $c == null then "SUCCESS" else ($c | word) end
    end;
($repo[0] | if type == "object" then . else error("gh repo view: not a JSON object") end
 | [.owner.login, .name]
 | map(if type == "string" and test("\\A[A-Za-z0-9._-]{1,100}\\z") then .
       else error("gh repo view: invalid owner or name") end)) as [$owner, $name]
| if type != "object" then error("not a JSON object") else . end
| $owner, $name,
  (.number | if type == "number" then tostring else error("field number is missing") end),
  field("headRefOid"), field("headRefName"), field("baseRefName"),
  field("mergeable"), field("url"), field("state"),
  (if .isDraft == true then "true" elif .isDraft == false then "false"
   else error("field isDraft is missing") end),
  latest("gate"; $wf), latest("verify-fix"; $wf), latest("gate-self"; $wf),
  ([ (.labels // [])[]? | objects | .name // "" | tostring | ascii_downcase ]
   | any(.[]; . == $findings) | tostring),
  (.title | if type == "string" and (bad | not) and test($title_re) then "ok" else tojson end),
  ((.body // "" | if type == "string" then . else "" end | split("\n")
    | map(sub("[ \\t\\r]+\\z"; ""))) as $lines
   | [ "## What", "## Why", "## Evidence" | select(. as $s | any($lines[]; . == $s) | not) ]
   | join(", ")),
  # A missing owner or name reads as this repository (as in verify-fix.sh): dropping such a
  # reference would drop the verify-fix requirement, so the doubt goes to checking more. For the
  # same reason a reference of this repository without a usable issue number is an error.
  ((.closingIssuesReferences // []) as $refs
   | if ($refs | type) != "array" then error("closingIssuesReferences is not a list") else . end
   | [ $refs[]
       | if type != "object" then error("a closing issue reference is not an object") else . end
       | select(((.repository.owner.login // $owner) | tostring | ascii_downcase) == ($owner | ascii_downcase)
           and ((.repository.name // $name) | tostring | ascii_downcase) == ($name | ascii_downcase))
       | .number
       | if type == "number" and . > 0 and . == floor and . < 1000000000 then tostring
         else error("a closing issue reference of this repository has no usable issue number") end ]
   | unique | join(" "))
'

# Approval classes: blast-radius.sh classes plus the fixed "checkpoint" policy.
# shellcheck disable=SC2016 # a jq program, not shell
SHIP_CLASSES_JQ='
def cls: if type == "string" and test("\\A[A-Za-z0-9._:-]{1,64}\\z") then . else "unnamed-class" end;
if type != "object" or (.classes | type) != "array" or (.files | type) != "array"
then error("the blast-radius report has no classes or files") else . end
| [ .files[] | (if type == "object" then .path else null end) | tostring | ascii_downcase ] as $files
| [ (.classes[] | (if type == "object" then .class else null end) | cls),
    (if ($branch | ascii_downcase | test("\\Afactory/(intake|plan)\\z"))
        or any($files[]; . == "factory/spec.md")
        or (any($files[]; . == "factory/feature-map.json")
            and ($branch | test("\\Afactory/F[0-9]+\\z") | not))
     then "checkpoint" else empty end) ]
| unique | join(" ")
'

# Approval comments: "<valid> <by-others> <for-another-sha>". A valid one is by a login in
# merge.approvers ($approvers, one per line); with approvers none ($approvers empty), by an
# account whose author_association (the issues comments API gives it) is OWNER, MEMBER or
# COLLABORATOR: anyone else who can comment (CONTRIBUTOR, NONE, ...) could approve otherwise.
# A comment without an author_association is nobody's.
# shellcheck disable=SC2016 # a jq program, not shell
SHIP_APPROVAL_JQ='
[ .[] | if type == "array" then .[] else error("a page of comments is not a JSON array") end | objects ] as $all
| ($approvers | split("\n") | map(select(length > 0) | ascii_downcase)) as $who
| [ $all[] | { login: (.user.login // "" | tostring | ascii_downcase),
               assoc: (.author_association // "" | tostring),
               body: (.body // "" | tostring | sub("[[:space:]]+\\z"; "")) } ] as $cs
| [ $cs[] | select(.body == $want) ] as $hits
| ([ $hits[]
     | select(if ($who | length) == 0 then (.assoc as $a | any("OWNER", "MEMBER", "COLLABORATOR"; . == $a))
              else (.login as $l | any($who[]; . == $l)) end) ]
   | length) as $ok
| ([ $cs[] | select(.body != $want and (.body | test("\\Aapprove [0-9a-fA-F]{7,40}\\z"))) ] | length) as $stale
| "\($ok) \(($hits | length) - $ok) \($stale)"
'

# Commits: the count, then the sha of every commit $id authored or committed.
# shellcheck disable=SC2016 # a jq program, not shell
SHIP_COMMITS_JQ='
[ .[] | if type == "array" then .[] else error("a page of commits is not a JSON array") end ]
| if length == 0 then error("the PR lists no commits") else . end
| map(if type == "object" and (.commit.author.name | type) == "string"
        and (.commit.committer.name | type) == "string"
      then . else error("a commit has no author or committer name") end)
| "\(length)",
  (.[] | select(.commit.author.name == $id or .commit.committer.name == $id)
       | (.sha // "" | tostring | if test("\\A[0-9a-f]{7,40}\\z") then . else "(unknown sha)" end))
'

# The bug label an issue carries (`gh issue view --json labels`): role:bug-fix or bug, the
# rule shared with verify-fix.sh. Empty when it has neither. GitHub label names are
# case-insensitive, so "Bug" is the label bug.
# shellcheck disable=SC2016 # a jq program, not shell
SHIP_BUGLABEL_JQ='
if type != "object" then error("not a JSON object") else . end
| [ (.labels // [])[]? | objects | .name // "" | tostring | ascii_downcase ] as $names
| first(("role:bug-fix", "bug") | select(. as $l | any($names[]; . == $l))) // ""
'

SHIP_DONE=""
SHIP_UNDECIDED=""
SHIP_TMP=""
SHIP_WT=""
SHIP_TREE=""

# Exit paths. An unexpected failure under set -e can exit 1, which would read as
# "refused"; the EXIT trap turns any exit 1 that was not chosen on purpose into 2.
ship_exit() {
  SHIP_DONE=1
  exit "$1"
}

# shellcheck disable=SC2329 # invoked by the EXIT trap
ship_on_exit() {
  local st=$?
  # Cleaning up never changes the verdict. The head's code (the gate re-run) can leave files
  # or processes in its worktree that cannot be removed, and under set -e a command failing
  # here would end ship with status 1, "refused", even after a merge.
  set +e
  if [ -n "$SHIP_WT" ] && [ -n "$SHIP_TREE" ]; then
    sf_git_bk -C "$SHIP_TREE" worktree remove --force "$SHIP_WT" >/dev/null 2>&1 || true
  fi
  if [ -n "$SHIP_TMP" ] && ! rm -rf "$SHIP_TMP" 2>/dev/null; then
    sf_warn "could not remove $SHIP_TMP (the gate re-run may have left files or processes in it)"
  fi
  if [ -n "$SHIP_WT" ] && [ -n "$SHIP_TREE" ]; then
    sf_git_bk -C "$SHIP_TREE" worktree prune >/dev/null 2>&1 || true
  fi
  if [ "$st" -eq 1 ] && [ -z "$SHIP_DONE" ]; then
    printf '%s: error: unexpected failure; treating it as an error, not a refusal\n' "$SF_PROG" >&2
    st=2
  fi
  exit "$st"
}

SHIP_VIOLATIONS=0
violation() {
  SHIP_VIOLATIONS=$((SHIP_VIOLATIONS + 1))
  sf_log "policy: $*"
}

# ship_word VALUE: VALUE when it looks like a GitHub enum, else INVALID (safe to print).
ship_word() {
  if [[ $1 =~ ^[A-Z_]{1,40}$ ]]; then printf '%s' "$1"; else printf 'INVALID'; fi
}

# Every git call ship makes in the tree is bookkeeping (Conventions): no hook of the tree runs,
# not even reference-transaction on a fetch, so nothing planted in .git/hooks gets the token.
ship_git() { sf_git_bk -C "$SHIP_TREE" "$@"; }

# ship_branch_ok NAME: NAME is a valid branch name that cannot be read as an option.
# Plain names are judged in bash (process start-up is slow on Windows); anything else
# goes to git check-ref-format.
ship_branch_ok() {
  case "$1" in '' | -*) return 1 ;; esac
  [ "${#1}" -le 255 ] || return 1
  if [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]]; then
    case "$1" in
      *..* | *//* | */ | *. | */.* | *.lock | *.lock/*) ;;
      *) return 0 ;;
    esac
  fi
  git check-ref-format "refs/heads/$1" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Reading the PR
# ---------------------------------------------------------------------------

# ship_repo: owner/name of the tree's GitHub repo, parsed together with the PR (one jq).
ship_repo() {
  sf_gh repo view --json owner,name </dev/null >"$SHIP_TMP/repo.json" ||
    sf_die "could not tell which GitHub repository $SHIP_TREE belongs to (gh repo view)"
}

ship_parse_pr() {
  sf_jq -r --arg findings "$SHIP_FINDINGS_LABEL" --arg title_re "$SHIP_TITLE_RE" \
    --arg wf "$SHIP_WORKFLOW" --slurpfile repo "$SHIP_TMP/repo.json" "$SHIP_PR_JQ" \
    <"$SHIP_TMP/pr.json" >"$SHIP_TMP/pr.fields" ||
    sf_die "could not parse gh pr view (and gh repo view) output for PR #$SHIP_N"
  {
    IFS= read -r SHIP_OWNER &&
      IFS= read -r SHIP_REPO &&
      IFS= read -r PR_NUMBER &&
      IFS= read -r PR_SHA &&
      IFS= read -r PR_HEAD &&
      IFS= read -r PR_BASE &&
      IFS= read -r PR_MERGEABLE &&
      IFS= read -r PR_URL &&
      IFS= read -r PR_STATE &&
      IFS= read -r PR_DRAFT &&
      IFS= read -r PR_GATE &&
      IFS= read -r PR_VERIFY &&
      IFS= read -r PR_GATESELF &&
      IFS= read -r PR_FINDINGS &&
      IFS= read -r PR_TITLE &&
      IFS= read -r PR_MISSING &&
      IFS= read -r PR_CLOSING
  } <"$SHIP_TMP/pr.fields" || sf_die "unexpected gh pr view output for PR #$SHIP_N"
  if ! [[ $SHIP_OWNER =~ ^[A-Za-z0-9._-]+$ ]] || ! [[ $SHIP_REPO =~ ^[A-Za-z0-9._-]+$ ]]; then
    sf_die "gh repo view returned an invalid owner or name"
  fi
  [ "$PR_NUMBER" = "$SHIP_N" ] || sf_die "gh pr view $SHIP_N returned PR #$PR_NUMBER"
  [[ $PR_SHA =~ ^[0-9a-f]{40}$ ]] || sf_die "PR #$SHIP_N: headRefOid is not a full commit sha"
  ship_branch_ok "$PR_HEAD" || sf_die "PR #$SHIP_N: the head branch name is not a valid branch"
  ship_branch_ok "$PR_BASE" || sf_die "PR #$SHIP_N: the base branch name is not a valid branch"
  case "$PR_URL" in
    https://*[[:space:]]* | *'"'*) sf_die "PR #$SHIP_N: invalid url" ;;
    https://?*) ;;
    *) sf_die "PR #$SHIP_N: invalid url" ;;
  esac
}

# ship_read_pr: gh pr view, asked again while mergeable is UNKNOWN (GitHub computes it
# lazily). Every check then judges the same, last snapshot.
ship_read_pr() {
  local tries=0
  while :; do
    sf_gh pr view "$SHIP_N" --json "$SHIP_PR_FIELDS" </dev/null >"$SHIP_TMP/pr.json" ||
      sf_die "could not read PR #$SHIP_N (gh pr view)"
    ship_parse_pr
    [ "$PR_MERGEABLE" = UNKNOWN ] || break
    [ "$tries" -lt "$SHIP_RETRIES" ] || break
    tries=$((tries + 1))
    sf_log "PR #$SHIP_N: mergeable is UNKNOWN; asking again in ${SHIP_SLEEP}s ($tries/$SHIP_RETRIES)"
    sleep "$SHIP_SLEEP"
  done
}

# ship_bugfix: sets SHIP_BUGFIX to why this is a bug-fix PR, or empty. The rule is shared
# with verify-fix.sh: the branch is factory/issue-<n> (a claim key: n has no leading zero, so
# factory/issue-03 is not one), or an issue of this repository that the PR closes is labelled
# role:bug-fix or bug. A factory/perf-<n> branch (a perf fix) is not a bug fix by its name.
ship_bugfix() {
  local n label
  SHIP_BUGFIX=""
  if [[ $PR_HEAD =~ ^factory/issue-[1-9][0-9]*$ ]]; then
    SHIP_BUGFIX="branch $PR_HEAD"
    return 0
  fi
  for n in $PR_CLOSING; do
    sf_gh issue view "$n" -R "$SHIP_OWNER/$SHIP_REPO" --json labels </dev/null >"$SHIP_TMP/issue.json" ||
      sf_die "could not read the labels of issue #$n, which PR #$SHIP_N closes"
    label=$(sf_jq -r "$SHIP_BUGLABEL_JQ" <"$SHIP_TMP/issue.json") ||
      sf_die "could not parse the labels of issue #$n"
    case "$label" in
      role:bug-fix | bug)
        SHIP_BUGFIX="closes #$n, labelled $label"
        return 0
        ;;
      '') ;;
      *) sf_die "could not parse the labels of issue #$n" ;;
    esac
  done
  return 0
}

# ---------------------------------------------------------------------------
# Git: fetch, head identity, merge base, up to date
# ---------------------------------------------------------------------------

ship_fetch() {
  local tip
  [ "$PR_HEAD" != "$PR_BASE" ] || sf_die "PR #$SHIP_N: head and base are the same branch ($PR_BASE)"
  ship_git fetch --quiet --no-tags "$SHIP_REMOTE" \
    "+refs/heads/$PR_HEAD:refs/remotes/$SHIP_REMOTE/$PR_HEAD" \
    "+refs/heads/$PR_BASE:refs/remotes/$SHIP_REMOTE/$PR_BASE" </dev/null >&2 ||
    sf_die "could not fetch $PR_HEAD and $PR_BASE from $SHIP_REMOTE into $SHIP_TREE"
  tip=$(ship_git rev-parse --verify --quiet "refs/remotes/$SHIP_REMOTE/$PR_HEAD^{commit}") ||
    sf_die "$SHIP_REMOTE/$PR_HEAD did not resolve after the fetch"
  if [ "$tip" != "$PR_SHA" ]; then
    sf_die "the head moved: $SHIP_REMOTE/$PR_HEAD is at $tip, but GitHub reports $PR_SHA for PR #$SHIP_N; run again"
  fi
  SHIP_BASE_REF="refs/remotes/$SHIP_REMOTE/$PR_BASE"
  SHIP_MB=$(ship_git merge-base "$SHIP_BASE_REF" "$PR_SHA") ||
    sf_die "no merge base between $SHIP_REMOTE/$PR_BASE and $PR_SHA"
}

# ship_up_to_date: 0 when the head contains origin/<base>, 1 when it does not.
ship_up_to_date() {
  local rc=0
  ship_git merge-base --is-ancestor "$SHIP_BASE_REF" "$PR_SHA" || rc=$?
  case "$rc" in
    0 | 1) return "$rc" ;;
    *) sf_die "git merge-base --is-ancestor failed (exit $rc)" ;;
  esac
}

ship_classes() {
  local rc=0
  bash "$SF_SCRIPTS_DIR/blast-radius.sh" --base "$SHIP_MB" --head "$PR_SHA" --tree "$SHIP_TREE" \
    --config "$SHIP_CONFIG" --json </dev/null >"$SHIP_TMP/blast.json" || rc=$?
  [ "$rc" -eq 0 ] || sf_die "blast-radius.sh exited $rc; cannot tell which approvals PR #$SHIP_N needs"
  SHIP_CLASSES=$(sf_jq -r --arg branch "$PR_HEAD" "$SHIP_CLASSES_JQ" <"$SHIP_TMP/blast.json") ||
    sf_die "could not read the blast-radius report"
}

ship_check_approval() {
  local counts ok others stale
  sf_gh api "repos/{owner}/{repo}/issues/$SHIP_N/comments" --paginate </dev/null >"$SHIP_TMP/comments.json" ||
    sf_die "could not read the comments of PR #$SHIP_N"
  counts=$(sf_jq -r -s --arg want "approve $PR_SHA" --arg approvers "$SHIP_APPROVERS" "$SHIP_APPROVAL_JQ" \
    <"$SHIP_TMP/comments.json") || sf_die "could not parse the comments of PR #$SHIP_N"
  read -r ok others stale <<EOF
$counts
EOF
  [ "$ok" -gt 0 ] && return 0
  if [ "$others" -gt 0 ] && [ -z "$SHIP_APPROVERS" ]; then
    violation "approval needed ($SHIP_CLASSES): \"approve $PR_SHA\" was posted only by accounts that are not OWNER, MEMBER or COLLABORATOR of the repository (author_association; merge.approvers is none)"
  elif [ "$others" -gt 0 ]; then
    violation "approval needed ($SHIP_CLASSES): \"approve $PR_SHA\" was posted only by logins not in merge.approvers"
  elif [ "$stale" -gt 0 ]; then
    violation "approval needed ($SHIP_CLASSES): the approvals found are for another commit; a new commit voids them. Comment exactly \"approve $PR_SHA\""
  else
    violation "approval needed ($SHIP_CLASSES): no comment that is exactly \"approve $PR_SHA\""
  fi
}

# ship_need_success NAME CONCLUSION CONTEXT
ship_need_success() {
  [ "$2" = SUCCESS ] && return 0
  case "$2" in
    MISSING) violation "$3: no $1 check run on $PR_SHA; it must be SUCCESS" ;;
    *) violation "$3: the latest $1 check run on $PR_SHA is $2; it must be SUCCESS" ;;
  esac
}

# ---------------------------------------------------------------------------
# check
# ---------------------------------------------------------------------------

ship_check() {
  local skip_git=""
  ship_repo
  ship_read_pr
  ship_bugfix

  # --sha: the caller reviewed that commit. Any other head is not what was reviewed, whatever
  # else it passes (approvals and check runs below are about the current head).
  if [ -n "$SHIP_WANT_SHA" ] && [ "$PR_SHA" != "$SHIP_WANT_SHA" ]; then
    violation "head moved: PR #$SHIP_N is at $PR_SHA, not at the reviewed $SHIP_WANT_SHA"
  fi
  if [ "$PR_STATE" != OPEN ]; then
    violation "PR #$SHIP_N is $(ship_word "$PR_STATE"), not OPEN"
    skip_git=1
  fi
  if [ "$PR_BASE" != "$SHIP_BASE_BRANCH" ]; then
    violation "the PR targets $PR_BASE, not the configured base_branch $SHIP_BASE_BRANCH"
    skip_git=1
  fi
  ship_need_success "gate (workflow $SHIP_WORKFLOW)" "$PR_GATE" "gate"
  if [ -n "$SHIP_BUGFIX" ]; then
    ship_need_success "verify-fix (workflow $SHIP_WORKFLOW)" "$PR_VERIFY" "bug-fix PR ($SHIP_BUGFIX)"
  fi
  if [ "$PR_DRAFT" != false ]; then violation "the PR is a draft"; fi
  case "$PR_MERGEABLE" in
    MERGEABLE) ;;
    # GitHub has not computed it: neither yes nor no. Another rule may still refuse the PR
    # (exit 1); otherwise check exits 2.
    UNKNOWN)
      SHIP_UNDECIDED="mergeable is still UNKNOWN after $SHIP_RETRIES retries"
      sf_log "could not decide whether PR #$SHIP_N is mergeable: $SHIP_UNDECIDED"
      ;;
    *) violation "mergeable is $(ship_word "$PR_MERGEABLE"), not MERGEABLE" ;;
  esac
  if [ "$PR_FINDINGS" != false ]; then
    violation "the PR has the $SHIP_FINDINGS_LABEL label (confirmed review findings)"
  fi
  if [ "$PR_TITLE" != ok ]; then
    violation "the title $PR_TITLE is not conventional: type(scope)!: summary, type one of feat fix perf refactor test docs chore ci build revert"
  fi
  if [ -n "$PR_MISSING" ]; then
    violation "the body is missing the section line(s): $PR_MISSING"
  fi

  if [ -n "$skip_git" ]; then
    sf_log "skipping the git checks and approvals: they need an open PR on $SHIP_BASE_BRANCH"
  else
    ship_fetch
    if ! ship_up_to_date; then
      violation "the head does not contain $SHIP_REMOTE/$PR_BASE; update the branch"
    fi
    ship_classes
    sf_log "approval classes: ${SHIP_CLASSES:-none}"
    if [ -n "$SHIP_CLASSES" ]; then
      ship_check_approval
      case " $SHIP_CLASSES " in
        *" rules-change "*)
          ship_need_success "gate-self (workflow $SHIP_WORKFLOW)" "$PR_GATESELF" "rules-change PR"
          ;;
      esac
    fi
  fi

  # The verdict is SHIP_VIOLATIONS, then SHIP_UNDECIDED (ship_check_verdict). ship_check is
  # never called as a condition, so set -e stays in force inside it.
  if [ "$SHIP_VIOLATIONS" -gt 0 ]; then
    sf_log "PR #$SHIP_N fails the merge policy ($SHIP_VIOLATIONS violation(s))"
  elif [ -z "$SHIP_UNDECIDED" ]; then
    sf_log "PR #$SHIP_N passes the merge policy at $PR_SHA"
  fi
}

# ship_check_undecided WHAT: after a check with no violation, exit 2 when a rule could not be
# decided. A refusal is a decision, so violations are handled (exit 1) before this.
ship_check_undecided() {
  [ -z "$SHIP_UNDECIDED" ] ||
    sf_die "could not decide whether PR #$SHIP_N may merge: $SHIP_UNDECIDED; run again later$1"
}

# ---------------------------------------------------------------------------
# merge
# ---------------------------------------------------------------------------

ship_refuse() {
  sf_log "merge refused: $*"
  ship_exit 1
}

# ship_check_writers: the shipper must not have written or committed any commit.
ship_check_writers() {
  local out count line hits="" rc
  sf_gh api "repos/{owner}/{repo}/pulls/$SHIP_N/commits" --paginate </dev/null >"$SHIP_TMP/commits.json" ||
    sf_die "could not list the commits of PR #$SHIP_N"
  out=$(sf_jq -r -s --arg id "$SHIP_AGENT" "$SHIP_COMMITS_JQ" <"$SHIP_TMP/commits.json") ||
    sf_die "could not parse the commits of PR #$SHIP_N"
  count=""
  while IFS= read -r line; do
    if [ -z "$count" ]; then
      count=$line
    elif [ -n "$line" ]; then
      hits="$hits $line"
    fi
  done <<EOF
$out
EOF
  if [ -n "$hits" ]; then
    ship_refuse "$SHIP_AGENT authored or committed commit(s)$hits; the writer is never the shipper"
  fi
  # The API lists at most 250 commits; the fetched history has all of them. grep: 0 found,
  # 1 not found, anything else is an error (never read as "not found").
  ship_git log --format='%an%n%cn' "$SHIP_MB..$PR_SHA" >"$SHIP_TMP/names" ||
    sf_die "git log $SHIP_MB..$PR_SHA failed"
  rc=0
  grep -Fxq -- "$SHIP_AGENT" "$SHIP_TMP/names" || rc=$?
  case "$rc" in
    0) ship_refuse "$SHIP_AGENT authored or committed commits in $SHIP_MB..$PR_SHA; the writer is never the shipper" ;;
    1) ;;
    *) sf_die "could not scan the commit names of $SHIP_MB..$PR_SHA (grep exit $rc)" ;;
  esac
  sf_log "writers: none of the $count commit(s) is by $SHIP_AGENT"
}

# ship_judge_scrubbed SCRIPT ARGS...: runs a judging-copy script that executes project code
# (gate.sh) with bash, stdin from /dev/null and its stdout on stderr (ship's stdout is the PR
# URL only). The shipper's token can merge, so that code gets no
# credential-like variable (sf_scrubbed: names bash cannot hold or unset included) and no stored
# gh login (a fresh, empty GH_CONFIG_DIR), as in CI, where the gate job never sees
# FACTORY_TOKEN. Only this run loses them: ship itself still needs its token to post the
# verdict and merge. bash goes by the path pinned before any project code ran: env, which
# sf_scrubbed runs, looks a command name up in PATH itself, where that code may have planted
# one. The new directory has a random name, so nothing planted next to it can stand in for it.
#
# A listing of the names can fail (a sort, awk or env that fails) or come back empty (one that
# prints nothing): the names are listed first (ship_credential_names), and a listing that fails
# stops ship (exit 2) before anything runs; sf_scrubbed's own listing failing makes it run
# nothing (status 125: "gate.sh exited 125", or no worktree). The names found, and the contract's
# own list (SHIP_SCRUB_ALWAYS), are unset as well (ship_unset_names), so a listing that comes
# back empty inside sf_scrubbed still hands on no token bash can hold.
ship_judge_scrubbed() {
  local ghcfg names
  names=$(ship_credential_names "${1##*/}") || exit 2
  ghcfg=$(mktemp -d "$SHIP_TMP/ghcfg.XXXXXX") || sf_die "could not create a temp dir"
  ghcfg=$(sf_native_path "$ghcfg") || sf_die "could not resolve a temp dir"
  (
    ship_unset_names "$names"
    GH_CONFIG_DIR=$ghcfg
    export GH_CONFIG_DIR
    sf_scrubbed "$SHIP_BASH" "$@"
  ) </dev/null >&2
}

# ship_credential_names WHAT: sf_credential_names, or exit 2 naming WHAT it was for.
ship_credential_names() {
  sf_credential_names ||
    sf_die "could not list the credential-like variables to keep from $1; not running it"
}

# ship_unset_names NAMES: in the subshell that calls it, unsets every name in NAMES (one per line)
# and in SHIP_SCRUB_ALWAYS that bash can hold.
ship_unset_names() {
  local n
  while IFS= read -r n; do
    [ -z "$n" ] || unset -v "$n" 2>/dev/null || true
  done <<EOF
$1
EOF
  for n in $SHIP_SCRUB_ALWAYS; do unset -v "$n" 2>/dev/null || true; done
  return 0
}

# ship_git_after ARGS...: git in the tree once project code has run (or may have). That code could
# write the tree's shared config and info/attributes from its worktree, and git runs commands they
# name (a filter on checkout): bookkeeping git (no hook, no fsmonitor), by the path pinned before
# that code ran, without credentials (scrubbed like ship_judge_scrubbed; a listing that fails
# exits 2, never runs git with them).
ship_git_after() {
  local names
  names=$(ship_credential_names "git in $SHIP_TREE") || exit 2
  (
    ship_unset_names "$names"
    git() { sf_scrubbed "$SHIP_GIT" "$@"; }
    sf_git_bk -C "$SHIP_TREE" "$@"
  ) </dev/null
}

ship_rerun_gate() {
  local rc=0
  SHIP_WT="$SHIP_TMP/head"
  # Bookkeeping git: no hook runs, so creating the worktree runs none of the head's code. For a
  # bug fix, the verify-fix re-run has run the PR's code by now, in worktrees that share this
  # tree's config and info/attributes: a filter it named there runs during this checkout, so
  # the checkout goes through ship_git_after (scrubbed, by the pinned path).
  ship_git_after -c core.autocrlf=false -c core.longpaths=true \
    worktree add --detach --quiet "$SHIP_WT" "$PR_SHA" >&2 ||
    sf_die "could not create a worktree at $PR_SHA"
  sf_log "re-running gate.sh at $PR_SHA"
  # gate.sh runs the head's own code (project.setup, gate.test, ...).
  ship_judge_scrubbed "$SF_SCRIPTS_DIR/gate.sh" --tree "$SHIP_WT" --config "$SHIP_CONFIG" \
    --base "$SHIP_MB" --head "$PR_SHA" --branch "$PR_HEAD" || rc=$?
  case "$rc" in
    0) ;;
    1) ship_refuse "gate.sh failed at $PR_SHA" ;;
    *) sf_die "gate.sh exited $rc at $PR_SHA" ;;
  esac
}

# ship_rerun_verify_fix (merge step 1b): a bug fix is verified again at merge time, with the
# labels and links as they are now: the verify-fix CheckRun may predate a label change.
# verify-fix.sh --pr reads the PR and its issues from GitHub itself (GH_REPO names the
# repository), fetches the head into the tree, checks it is still headRefOid and runs the repro
# at the merge base and at the head. Reading GitHub needs ship's own access, so it runs before
# any of the PR's code has run here (the gate re-run comes after it): the judging copy is still
# the one ship started from, and verify-fix.sh keeps credentials from the project code it runs
# (contract: its project.setup goes through sf_scrubbed, its repro under env -i). Run scrubbed,
# or after the gate re-run had a chance to rewrite it, it could never read the PR.
ship_rerun_verify_fix() {
  local rc=0 tip out="$SHIP_TMP/verify-fix.out"
  sf_log "re-running verify-fix.sh --pr $SHIP_N at $PR_SHA (bug fix: $SHIP_BUGFIX)"
  "$SHIP_BASH" "$SF_SCRIPTS_DIR/verify-fix.sh" --pr "$SHIP_N" --tree "$SHIP_TREE" \
    --config "$SHIP_CONFIG" </dev/null >"$out" || rc=$?
  # Its report goes to stderr: ship's stdout is the PR URL only.
  cat "$out" >&2 || true
  case "$rc" in
    0) ;;
    1) ship_refuse "verify-fix.sh did not verify the fix at $PR_SHA" ;;
    3) sf_die "verify-fix.sh was inconclusive (exit 3) at $PR_SHA; not merging" ;;
    *) sf_die "verify-fix.sh exited $rc at $PR_SHA; not merging" ;;
  esac
  # Exit 0 also means "not a bug fix: nothing to verify". ship found one ($SHIP_BUGFIX), so the
  # labels or links changed since it read them (or the two rules disagree): nothing was verified,
  # and the verdict would say it was. grep: 0 found, 1 not found, anything else an error.
  rc=0
  grep -Fxq 'not a bug fix: nothing to verify' "$out" || rc=$?
  case "$rc" in
    0) sf_die "verify-fix.sh found no bug issue to verify, but PR #$SHIP_N is a bug fix ($SHIP_BUGFIX); the labels or links changed while ship read them; not merging" ;;
    1) ;;
    *) sf_die "could not read the verify-fix.sh report (grep exit $rc); not merging" ;;
  esac
  # verify-fix.sh --pr verifies the head GitHub reports when it runs, fetched into this tree as
  # refs/remotes/pull/N/head. If the PR moved since ship read it (even to move back before the
  # merge), that verdict is about another commit. Two checks: GitHub's current head (asked the
  # same way ship first asked), and the commit verify-fix actually fetched, when it left one.
  local now
  now=$(sf_gh pr view "$SHIP_N" --json "$SHIP_PR_FIELDS" </dev/null | sf_jq -r '.headRefOid // ""') ||
    sf_die "could not read PR #$SHIP_N again after verify-fix.sh; not merging"
  [ "$now" = "$PR_SHA" ] ||
    sf_die "the head moved while verify-fix.sh ran: PR #$SHIP_N is at ${now:-nothing}, not $PR_SHA; not merging"
  tip=$(ship_git_after rev-parse --verify --quiet "refs/remotes/pull/$SHIP_N/head^{commit}") || tip=""
  [ -z "$tip" ] || [ "$tip" = "$PR_SHA" ] ||
    sf_die "the head moved while verify-fix.sh ran: it verified refs/pull/$SHIP_N/head at $tip, not $PR_SHA; not merging"
}

# ship_merged_at: prints mergedAt, or nothing when the PR does not read as merged.
# No temp file: the head's code has run by now, next to $SHIP_TMP (see ship_merge).
ship_merged_at() {
  local out v
  out=$(sf_gh pr view "$SHIP_N" --json mergedAt </dev/null) || return 0
  # shellcheck disable=SC2016 # a jq program, not shell
  v=$(printf '%s\n' "$out" |
    sf_jq -r '.mergedAt // "" | if type == "string" and test("\\A[0-9]{4}-[0-9]{2}-[0-9]{2}T") then . else "" end' \
      2>/dev/null) || return 0
  case "$v" in 0001-*) v="" ;; esac
  printf '%s' "$v"
}

ship_merge() {
  local tries=0 merged="" reruns
  ship_check
  if [ "$SHIP_VIOLATIONS" -gt 0 ]; then
    ship_refuse "PR #$SHIP_N does not pass the merge policy"
  fi
  ship_check_undecided "; not merging"
  ship_check_writers

  # gh, which holds the token, finds the repository of a command without -R by running the git
  # it finds on PATH, where the PR's code (the re-runs below) may plant one (ship's own hash pins
  # nothing for gh). GH_REPO names the repository instead, the one gh repo view reported; the
  # verify-fix re-run reads that same repository.
  if [ -z "${GH_REPO:-}" ]; then
    GH_REPO="$SHIP_OWNER/$SHIP_REPO"
    export GH_REPO
  fi
  # Step 1b, before the gate re-run: verify-fix.sh needs ship's GitHub access (see there).
  if [ -n "$SHIP_BUGFIX" ]; then
    ship_rerun_verify_fix
    reruns="a fresh verify-fix run and a fresh gate run"
  else
    reruns="a fresh gate run"
  fi
  ship_rerun_gate

  # From here on, the head's own code has run (the re-runs) in worktrees inside temp dirs and may
  # have left processes behind; nothing below goes through a file there.
  printf '<!-- factory:verdict sha=%s agent=%s result=pass -->\nship: %s passed the merge policy and %s; merging with --%s.\n' \
    "$PR_SHA" "$SHIP_AGENT" "$PR_SHA" "$reruns" "$SHIP_METHOD" |
    sf_gh pr comment "$SHIP_N" --body-file - >&2 ||
    sf_die "could not post the verdict comment on PR #$SHIP_N; not merging"

  sf_gh pr merge "$SHIP_N" -R "$SHIP_OWNER/$SHIP_REPO" "--$SHIP_METHOD" --match-head-commit "$PR_SHA" </dev/null >&2 ||
    sf_die "gh pr merge failed for PR #$SHIP_N"

  while :; do
    merged=$(ship_merged_at)
    [ -z "$merged" ] || break
    tries=$((tries + 1))
    [ "$tries" -lt "$SHIP_READBACK_TRIES" ] || break
    sleep "$SHIP_SLEEP"
  done
  if [ -z "$merged" ]; then
    sf_log "error: gh pr merge succeeded, but PR #$SHIP_N does not read back as merged (no mergedAt)"
    ship_exit 3
  fi
  sf_log "merged PR #$SHIP_N at $merged"

  case "$PR_HEAD" in
    factory/*)
      if [[ $PR_HEAD =~ ^factory/[A-Za-z0-9._/-]+$ ]]; then
        if sf_gh api -X DELETE "repos/$SHIP_OWNER/$SHIP_REPO/git/refs/heads/$PR_HEAD" </dev/null >/dev/null 2>&1; then
          sf_log "deleted branch $PR_HEAD"
        else
          sf_warn "could not delete branch $PR_HEAD (the merge stands)"
        fi
      else
        sf_warn "not deleting branch $PR_HEAD: its name needs URL escaping"
      fi
      ;;
  esac
  printf '%s\n' "$PR_URL"
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

main() {
  local sub="" n="" tree="" config="" ci=0 cfg_dir v sha=""
  # Pin the tools ship uses before the head's code runs (the gate re-run): that code can put
  # an executable named gh (which would get the token), git, rm or sleep in a PATH directory
  # it can write to (~/.local/bin, say). bash looks a hashed name up in its table, never in
  # PATH again; subshells inherit the table. A missing tool stays missing (hash reports it).
  # env and sort: sf_scrubbed, which starts the gate re-run (and its worktree's checkout) after
  # the verify-fix re-run ran the PR's code.
  hash bash git gh jq awk tr cat grep mkdir mktemp rm sleep env sort cygpath 2>/dev/null || true
  # env finds the command it runs in PATH by itself: it gets bash by this pinned path (type -P
  # prints the hashed one).
  SHIP_BASH=$(type -P bash 2>/dev/null) || SHIP_BASH=""
  [ -n "$SHIP_BASH" ] || sf_die "required command not found: bash"
  SHIP_GIT=$(type -P git 2>/dev/null) || SHIP_GIT=""
  [ -n "$SHIP_GIT" ] || sf_die "required command not found: git"
  case "${1:-}" in
    -h | --help) usage; exit 0 ;;
    check | merge) sub=$1; shift ;;
    '') sf_die "missing subcommand: check or merge (see --help)" ;;
    *) sf_die "unknown subcommand '$1' (see --help)" ;;
  esac
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h | --help) usage; exit 0 ;;
      --tree | --config | --sha)
        [ "$#" -ge 2 ] && [ -n "$2" ] || sf_die "$1 needs a value (see --help)"
        case "$1" in
          --tree) tree=$2 ;;
          --config) config=$2 ;;
          *) sha=$2 ;;
        esac
        shift 2
        ;;
      --ci)
        [ "$sub" = check ] || sf_die "--ci is only for check"
        ci=1
        shift
        ;;
      -*) sf_die "unknown option: $1 (see --help)" ;;
      *)
        [ -z "$n" ] || sf_die "unexpected argument: $1 (see --help)"
        n=$1
        shift
        ;;
    esac
  done
  [ -n "$n" ] || sf_die "$sub needs a PR number (see --help)"
  [[ $n =~ ^[1-9][0-9]{0,9}$ ]] || sf_die "invalid PR number '$n'"
  SHIP_N=$n
  : "$ci" # --ci skips nothing today
  # --sha: the full head sha, as GitHub and git print it (hex case does not matter).
  SHIP_WANT_SHA=""
  if [ -n "$sha" ]; then
    [[ $sha =~ ^[0-9a-fA-F]{40}$ ]] ||
      sf_die "invalid --sha: give the full 40-character head sha the caller reviewed (see --help)"
    SHIP_WANT_SHA=$(printf '%s' "$sha" | tr 'A-F' 'a-f')
  fi

  if [ "$sub" = merge ]; then
    SHIP_AGENT=${FACTORY_AGENT_ID:-}
    [ -n "$SHIP_AGENT" ] || sf_die "merge needs FACTORY_AGENT_ID (the shipper's identity)"
    [[ $SHIP_AGENT =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] ||
      sf_die "invalid FACTORY_AGENT_ID (use letters, digits, '.', '_' and '-')"
  fi

  SHIP_SLEEP=${SF_SHIP_RETRY_SLEEP:-3}
  [[ $SHIP_SLEEP =~ ^[0-9]{1,4}$ ]] || sf_die "SF_SHIP_RETRY_SLEEP must be a whole number of seconds"

  if [ -n "$config" ]; then sf_config_load "$config"; else sf_config_load; fi
  # Absolute, so blast-radius.sh and gate.sh read the same file from any directory.
  case "$SF_CONFIG_FILE" in
    */*) cfg_dir=${SF_CONFIG_FILE%/*} ;;
    *) cfg_dir=. ;;
  esac
  cfg_dir=$(cd "${cfg_dir:-/}" && pwd) || sf_die "cannot resolve the config path"
  SHIP_CONFIG="${cfg_dir%/}/${SF_CONFIG_FILE##*/}"
  SHIP_BASE_BRANCH=$(sf_cfg base_branch main)
  ship_branch_ok "$SHIP_BASE_BRANCH" || sf_die "invalid base_branch in $SHIP_CONFIG"
  SHIP_METHOD=$(sf_cfg merge.method squash)
  case "$SHIP_METHOD" in
    merge | squash | rebase) ;;
    *) sf_die "invalid merge.method in $SHIP_CONFIG (merge, squash or rebase)" ;;
  esac
  # merge.approvers: a list of logins; a single scalar counts as one; none = the repository's
  # owners, members and collaborators (author_association). A key that is missing, or whose
  # logins are all commented out, is not "none": read as "no list" it could let others approve,
  # so it fails closed (exit 2), like a missing gate.test_globs.
  SHIP_APPROVERS=$(sf_cfg_globs merge.approvers)
  if [ -z "$SHIP_APPROVERS" ]; then
    v=$(sf_cfg merge.approvers "")
    sf_is_none "$v" ||
      sf_die "$SHIP_CONFIG: merge.approvers is missing or empty; list the logins whose approvals count, or set it to none to let the repository's owners, members and collaborators approve"
  fi

  if [ "${FACTORY_OFFLINE:-}" = 1 ]; then
    sf_die "ship.sh needs GitHub, but FACTORY_OFFLINE=1 is set"
  fi
  sf_need git gh jq

  SHIP_REMOTE=$(sf_remote)
  [[ $SHIP_REMOTE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || sf_die "invalid FACTORY_REMOTE '$SHIP_REMOTE'"
  SHIP_TREE=$(sf_repo_root "${tree:-.}") || exit 2
  # gh resolves {owner}/{repo} and the PR from the tree's remotes.
  cd "$SHIP_TREE" || sf_die "cannot enter $SHIP_TREE"
  SHIP_TREE=$PWD
  SHIP_TMP=$(sf_mktemp_dir) || sf_die "could not create a temp dir"
  trap ship_on_exit EXIT

  if [ "$sub" = check ]; then
    ship_check
    if [ "$SHIP_VIOLATIONS" -gt 0 ]; then ship_exit 1; fi
    ship_check_undecided ""
    ship_exit 0
  fi
  ship_merge
  ship_exit 0
}

# Parsed whole before it runs: everything above only defines constants and functions, and
# main and the exit are read as one line before main starts. bash reads a script file as it
# executes it, and the head's code (the gate re-run) can write this file (same user;
# SF_FACTORY_ROOT is in its environment); nothing ship does is read from it after this line.
# shellcheck disable=SC2317 # main always exits; the exit is there in case it ever returns
{ main "$@"; exit $?; }
