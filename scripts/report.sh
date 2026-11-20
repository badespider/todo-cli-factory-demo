#!/usr/bin/env bash
# The honest throughput report: merged factory PRs, fixes that survived the audit window, escapes; posted at most once a day. Contract: docs/CONTRACTS.md, "report.sh".
set -euo pipefail
SF_PROG=report
# shellcheck source=scripts/lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
# shellcheck source=scripts/lib/jq.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/jq.sh"
# shellcheck source=scripts/lib/config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"

usage() {
  cat <<'EOF'
Usage: report.sh throughput [--days D] [--post] [--config FILE]

Counts, over the last D days (default twice merge.audit_days, else 28, so fixes closed
before the audit window are in it), and prints one key=value line per number on stdout:
  days=D
  merged=N     PRs merged from factory/* branches of this repository (not from forks)
  fixes=N      role:bug-fix issues closed as completed
  survived=N   of those fixes, the ones closed more than merge.audit_days ago and never
               labeled escape (a fix counts only once its audit window has passed: with
               the default D that is a fix closed between merge.audit_days and twice
               merge.audit_days ago; with D <= merge.audit_days this is always 0)
  escapes=N    issues labeled escape (the label was added within the window)

  --days D       the window in days (1 to 99999; default twice merge.audit_days)
  --post         also write the report to the log issue (the open issue labeled
                 factory:log: the pinned one, else the oldest) as one comment whose first
                 line is <!-- factory:throughput date=YYYY-MM-DD --> (UTC). At most once
                 a day: a comment already dated today is left alone; otherwise the oldest
                 such comment is edited, or a new one is created.
  --config FILE  config file (default: FACTORY_CONFIG, else the judging copy's
                 factory.config.yaml)
  -h, --help     show this help

GitHub calls (FACTORY_OFFLINE=1 exits 2 before any of them):
  gh repo view --json owner,name
  gh api graphql --paginate -f query=<search> -f q=<search string>, three times:
    repo:O/R is:pr is:merged merged:>=<day before the window>
    repo:O/R is:issue is:closed label:"role:bug-fix" closed:>=<day before the window>
    repo:O/R is:issue label:escape updated:>=<day before the window>
  (each result: number, headRefName, isCrossRepository and mergedAt, or closedAt,
  stateReason and the issue's label events; the exact window is applied to those
  timestamps)
  with --post:
    gh issue list -R O/R --label factory:log --state open --limit 100 --json number,isPinned,createdAt
    gh api repos/O/R/issues/<log>/comments --paginate
    gh api -X PATCH repos/O/R/issues/comments/<id> --input -   (edit), or
    gh issue comment <log> -R O/R --body-file -                 (create)

Exit: 0 reported (and posted, or already posted today); 2 GitHub could not be read or
written, a search had more results than it returned, no open factory:log issue for
--post, FACTORY_OFFLINE=1, the counts could not be written to stdout, a config error or a
usage error (an empty --config is one).
EOF
}

RP_TMP=""
# shellcheck disable=SC2329 # invoked by the EXIT trap
rp_cleanup() { if [ -n "$RP_TMP" ]; then rm -rf "$RP_TMP"; fi; }

# One search query for all three counts; only its search string changes. A search returns
# at most 1000 results, and an issue's first 100 label events are read: anything beyond
# either is detected and fails closed.
# shellcheck disable=SC2016 # GraphQL variables, not shell ones
RP_QUERY='query($q: String!, $endCursor: String) {
  search(query: $q, type: ISSUE, first: 100, after: $endCursor) {
    issueCount
    pageInfo { hasNextPage endCursor }
    nodes {
      ... on PullRequest { number headRefName isCrossRepository mergedAt }
      ... on Issue {
        number
        closedAt
        stateReason
        timelineItems(itemTypes: [LABELED_EVENT], first: 100) {
          totalCount
          nodes { ... on LabeledEvent { createdAt label { name } } }
        }
      }
    }
  }
}'

# rp_posint VALUE WHAT: VALUE as a decimal number from 1 to 99999; dies otherwise.
rp_posint() {
  local v="$1"
  case "$v" in '' | *[!0-9]* | ??????*) sf_die "$2 must be a whole number of days from 1 to 99999: '$v'" ;; esac
  v=$((10#$v))
  [ "$v" -gt 0 ] || sf_die "$2 must be a whole number of days from 1 to 99999: '$v'"
  printf '%s\n' "$v"
}

# rp_date EPOCH: the UTC calendar date of EPOCH.
rp_date() {
  # shellcheck disable=SC2016 # jq variable
  sf_jq -nr --argjson t "$1" '$t | strftime("%Y-%m-%d")' || sf_die "could not format a date"
}

# rp_search NAME QUERY: run one paginated search into $RP_TMP/NAME.json as
# {"count": issueCount, "nodes": [...]}, nodes unique by number. Dies (2) when GitHub can't
# be read, answers something else, or returned fewer results than it counted.
rp_search() {
  local name="$1" q="$2" have want
  if ! sf_gh api graphql --paginate -f query="$RP_QUERY" -f q="$q" </dev/null >"$RP_TMP/$name.raw"; then
    sf_die "could not search GitHub for the $name count"
  fi
  # shellcheck disable=SC2016 # jq program
  if ! sf_jq -n '
    [inputs] as $pages
    | if ($pages | length) == 0 then error("no response") else . end
    | ($pages | map(
        if type == "object" and (.data.search | type) == "object"
           and (.data.search.nodes | type) == "array"
           and (.data.search.issueCount | type) == "number"
        then .data.search else error("not a search response") end)) as $s
    | ([$s[].nodes[] | select(. != null)]
       | map(if type == "object" and (.number | type) == "number" then . else error("bad node") end)
       | unique_by(.number)) as $nodes
    | {count: ([$s[].issueCount] | max), nodes: $nodes}' "$RP_TMP/$name.raw" >"$RP_TMP/$name.json" 2>/dev/null; then
    sf_die "unexpected answer from the $name search"
  fi
  have=$(sf_jq -r '"\(.nodes | length) \(.count)"' "$RP_TMP/$name.json") || sf_die "unexpected answer from the $name search"
  want=${have#* }
  have=${have%% *}
  case "$have$want" in *[!0-9]*) sf_die "unexpected answer from the $name search" ;; esac
  if [ "$have" -lt "$want" ]; then
    sf_die "the $name search counted $want results but returned $have (GitHub returns at most 1000); use a smaller --days"
  fi
}

# rp_count SINCE CUT: print the key=value lines from the three searches. SINCE is the start
# of the window and CUT the latest close time of a fix that counts as survived (epochs).
rp_count() {
  # shellcheck disable=SC2016 # jq program
  sf_jq -nr --argjson since "$1" --argjson cut "$2" \
    --slurpfile m "$RP_TMP/merged.json" --slurpfile f "$RP_TMP/fixes.json" --slurpfile e "$RP_TMP/escapes.json" '
    def t: if type == "string" then fromdateiso8601 else error("bad timestamp") end;
    def events:
      if (.timelineItems | type) != "object" or (.timelineItems.nodes | type) != "array"
        then error("bad label events")
      elif (.timelineItems.totalCount // 0) > (.timelineItems.nodes | length)
        then error("more label events than returned")
      else [.timelineItems.nodes[] | select(type == "object")] end;
    def escape_events: [events[] | select(((.label.name // "") | ascii_downcase) == "escape")];
    ([$m[0].nodes[]
      | select((.headRefName | type) == "string" and (.headRefName | startswith("factory/")))
      | select(.isCrossRepository != true)
      | select(.mergedAt != null and (.mergedAt | t) >= $since)] | length) as $merged
    | [$f[0].nodes[]
       | select(.stateReason == "COMPLETED" and .closedAt != null and (.closedAt | t) >= $since)] as $fixes
    | ([$fixes[] | select((.closedAt | t) < $cut and (escape_events | length) == 0)] | length) as $survived
    | ([$e[0].nodes[] | select(any(escape_events[]; (.createdAt | t) >= $since))] | length) as $escapes
    | "merged=\($merged)", "fixes=\($fixes | length)", "survived=\($survived)", "escapes=\($escapes)"'
}

# rp_post REPO TODAY DAYS AUDIT: write the report in $RP_TMP/counts to the log issue.
rp_post() {
  local repo="$1" today="$2" days="$3" audit="$4" log action id
  if ! sf_gh issue list -R "$repo" --label factory:log --state open --limit 100 \
    --json number,isPinned,createdAt </dev/null >"$RP_TMP/log.json"; then
    sf_die "could not list the factory:log issues"
  fi
  # The log issue: the pinned one, else the oldest (bootstrap.sh and run-agent.sh agree).
  log=$(sf_jq -r 'if type != "array" then error("not a list") else . end
    | sort_by([(.isPinned != true), (.createdAt // ""), .number])
    | if length == 0 then "" else (.[0].number | tostring) end' "$RP_TMP/log.json" 2>/dev/null) ||
    sf_die "could not parse the factory:log issue list"
  [ -n "$log" ] || sf_die "no open factory:log issue to post to (run bootstrap.sh)"
  case "$log" in *[!0-9]*) sf_die "unexpected factory:log issue number" ;; esac

  if ! sf_gh api "repos/$repo/issues/$log/comments" --paginate </dev/null >"$RP_TMP/comments.json"; then
    sf_die "could not read the comments of the factory:log issue #$log"
  fi
  # Marker comments in the order GitHub returns them (oldest first).
  # shellcheck disable=SC2016 # jq program
  action=$(sf_jq -r -n --arg today "$today" '
    [inputs
     | if type == "array" then .[] else error("not a list") end
     | select(type == "object" and (.body | type) == "string" and (.id | type) == "number")
     | ((.body | split("\n")[0]) // "" | rtrimstr("\r")
        | capture("^<!-- factory:throughput date=(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}) -->$")) as $c
     | {id, d: $c.d}] as $marked
    | ($marked | map(select(.d == $today))) as $todays
    | if ($todays | length) > 0 then "today \($todays[0].id)"
      elif ($marked | length) > 0 then "edit \($marked[0].id)"
      else "create -" end' "$RP_TMP/comments.json" 2>/dev/null) ||
    sf_die "could not parse the comments of the factory:log issue #$log"
  id=${action#* }
  action=${action%% *}
  case "$id" in '' | - | *[!0-9]*) [ "$action" = create ] || sf_die "unexpected comment id on #$log" ;; esac
  if [ "$action" = today ]; then
    sf_log "the throughput report for $today is already on #$log (comment $id); left alone"
    return 0
  fi

  # shellcheck disable=SC2016 # Markdown backticks, not command substitution
  {
    printf '<!-- factory:throughput date=%s -->\n' "$today"
    printf '**Factory throughput**, last %s days to %s (UTC). Throughput is not progress: a fix counts as survived only after its %s-day audit window passed without an escape.\n\n' "$days" "$today" "$audit"
    printf '| | count |\n|---|---|\n'
    printf '| PRs merged from `factory/*` branches | %s |\n' "$(rp_value merged)"
    printf '| `role:bug-fix` issues closed as completed | %s |\n' "$(rp_value fixes)"
    printf '| ... of those, closed more than %s days ago and never labeled `escape` | %s |\n' "$audit" "$(rp_value survived)"
    printf '| issues labeled `escape` | %s |\n\n' "$(rp_value escapes)"
    printf '```text\n'
    cat "$RP_TMP/counts"
    printf '```\n'
  } >"$RP_TMP/body.md"

  if [ "$action" = edit ]; then
    # shellcheck disable=SC2016 # jq variable
    sf_jq -n --rawfile b "$RP_TMP/body.md" '{body: $b}' >"$RP_TMP/patch.json" || sf_die "could not build the comment"
    if ! sf_gh api -X PATCH "repos/$repo/issues/comments/$id" --input - <"$RP_TMP/patch.json" >/dev/null; then
      sf_die "could not edit the throughput comment $id on #$log"
    fi
    sf_log "updated the throughput comment $id on #$log for $today"
    return 0
  fi
  if ! sf_gh issue comment "$log" -R "$repo" --body-file - <"$RP_TMP/body.md" >/dev/null; then
    sf_die "could not comment on the factory:log issue #$log"
  fi
  sf_log "posted the throughput report for $today on #$log"
}

# rp_value KEY: the number on the KEY= line of $RP_TMP/counts.
rp_value() { sed -n "s/^$1=//p" "$RP_TMP/counts"; }

main() {
  local cmd="" days="" days_set=0 post=0 config="" now since cut audit today search_day repo owner name
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h | --help)
        usage
        return 0
        ;;
      --days | --config)
        [ "$#" -ge 2 ] || sf_die "$1 needs a value (see --help)"
        # An empty --config would silently mean "the default config".
        [ "$1" = --days ] || [ -n "$2" ] || sf_die "--config needs a non-empty value"
        if [ "$1" = --days ]; then days=$2; days_set=1; else config=$2; fi
        shift 2
        ;;
      --post)
        post=1
        shift
        ;;
      -*) sf_die "unknown option: $1 (see --help)" ;;
      *)
        [ -z "$cmd" ] || sf_die "unexpected argument: $1 (see --help)"
        cmd=$1
        shift
        ;;
    esac
  done
  case "$cmd" in
    throughput) ;;
    '') sf_die "a subcommand is required: throughput (see --help)" ;;
    *) sf_die "unknown subcommand: $cmd (see --help)" ;;
  esac
  if [ "$days_set" = 1 ]; then days=$(rp_posint "$days" --days); fi
  if [ "${FACTORY_OFFLINE:-}" = 1 ]; then
    sf_die "the throughput report needs GitHub, but FACTORY_OFFLINE=1 is set"
  fi
  sf_need gh jq
  if [ -n "$config" ]; then sf_config_load "$config"; else sf_config_load; fi
  audit=$(sf_cfg merge.audit_days 14)
  audit=$(rp_posint "$audit" "$SF_CONFIG_FILE: merge.audit_days")
  # Twice the audit window: a fix closed less than audit_days ago can't have survived yet, so a
  # window of audit_days alone would always report survived=0.
  [ "$days_set" = 1 ] || days=$((audit * 2))

  RP_TMP=$(sf_mktemp_dir)
  trap rp_cleanup EXIT

  # SF_REPORT_NOW (epoch seconds) pins the clock for tests.
  now=${SF_REPORT_NOW:-$(sf_now)}
  case "$now" in '' | *[!0-9]*) sf_die "SF_REPORT_NOW must be epoch seconds: '$now'" ;; esac
  since=$((now - days * 86400))
  cut=$((now - audit * 86400))
  today=$(rp_date "$now")
  # Search dates are whole days; one day of slack, and the exact window is applied after.
  search_day=$(rp_date $((since > 86400 ? since - 86400 : 0)))

  if ! sf_gh repo view --json owner,name </dev/null >"$RP_TMP/repo.json"; then
    sf_die "could not read the repository (gh repo view)"
  fi
  repo=$(sf_jq -r '"\(.owner.login // "")/\(.name // "")"' "$RP_TMP/repo.json" 2>/dev/null) ||
    sf_die "could not parse the repository from gh repo view"
  owner=${repo%%/*}
  name=${repo#*/}
  case "$owner" in '' | *[!A-Za-z0-9_.-]*) sf_die "unexpected repository owner from gh repo view" ;; esac
  case "$name" in '' | *[!A-Za-z0-9_.-]*) sf_die "unexpected repository name from gh repo view" ;; esac

  rp_search merged "repo:$repo is:pr is:merged merged:>=$search_day"
  rp_search fixes "repo:$repo is:issue is:closed label:\"role:bug-fix\" closed:>=$search_day"
  rp_search escapes "repo:$repo is:issue label:escape updated:>=$search_day"
  if ! rp_count "$since" "$cut" >"$RP_TMP/counts.raw" 2>/dev/null; then
    sf_die "unexpected data in the search results (timestamps or label events)"
  fi
  { printf 'days=%s\n' "$days"; cat "$RP_TMP/counts.raw"; } >"$RP_TMP/counts"
  # Unwritable stdout is an error (2), never set -e's 1, which this script never means.
  cat "$RP_TMP/counts" || sf_die "could not write the counts to stdout"

  [ "$post" = 1 ] || return 0
  rp_post "$repo" "$today" "$days" "$audit"
}

# Everything above only defines functions and constants; this line is parsed whole first.
main "$@"; exit $?
