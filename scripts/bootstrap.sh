#!/usr/bin/env bash
# Sets up a GitHub repo for the factory: labels, pinned log issue, stop variables, branch protection. Contract: docs/CONTRACTS.md, "bootstrap.sh".
set -euo pipefail
SF_PROG=bootstrap
# shellcheck source=scripts/lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
# shellcheck source=scripts/lib/jq.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/jq.sh"
# shellcheck source=scripts/lib/config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"

usage() {
  cat <<'EOF'
Usage: bootstrap.sh [--repo OWNER/NAME] [--protect] [--config FILE]

Idempotent setup of a repository for the software factory:
  1. creates the factory labels that are missing
  2. creates and pins the "Factory run log" issue (label factory:log) if none is open
  3. sets the repo variables FACTORY_ENABLED and FACTORY_CI_AGENTS to false where
     they are missing (existing values are never changed)
  4. with --protect, requires the "gate" check (strict, admins included) on the base
     branch (config base_branch); a plan without branch protection only warns

--repo defaults to the repository gh resolves for the current directory.
--config (or FACTORY_CONFIG) is read only for --protect.
Prints a summary. Exit codes: 0 done, 2 error.
EOF
}

# name|color|description. GitHub limits descriptions to 100 characters.
SF_LABELS=(
  "role:build|1d76db|Job: build a requested feature"
  "role:bug-fix|d73a4a|Job: reproduce and fix a bug"
  "role:perf|fbca04|Job: measure and improve performance"
  "role:babysit|0e8a16|Job: keep factory pull requests moving"
  "role:ship|5319e7|Job: merge pull requests that pass the policy"
  "agent-filed|c5def5|Opened by a factory agent through scripts/file-issue.sh"
  "needs-human|b60205|Waiting for a decision from a person"
  "escape|e99695|A fix that was closed as done but whose repro fails again"
  "status:blocked|000000|Factory work that cannot continue without help"
  "verify:findings|d93f0b|Reproduced review findings; blocks merge"
  "factory:log|ededed|Pinned issue holding the factory run log"
)
SF_VARIABLES="FACTORY_ENABLED FACTORY_CI_AGENTS"
SF_LOG_TITLE="Factory run log"

repo=""
protect=0
config=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) [ "$#" -ge 2 ] || sf_die "--repo needs OWNER/NAME"; repo="$2"; shift 2 ;;
    --protect) protect=1; shift ;;
    --config) [ "$#" -ge 2 ] || sf_die "--config needs a file"; config="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) sf_die "unknown argument: $1 (see --help)" ;;
  esac
done

base=""
if [ "$protect" -eq 1 ] || [ -n "$config" ]; then
  if [ -n "$config" ]; then sf_config_load "$config"; else sf_config_load; fi
  base=$(sf_cfg base_branch main)
  case "$base" in
    '' | -* | /* | */ | *..* | *[!A-Za-z0-9._/-]*) sf_die "invalid base_branch '$base' in config" ;;
  esac
fi

if [ "${FACTORY_OFFLINE:-}" = "1" ]; then
  sf_die "GitHub is required, but FACTORY_OFFLINE=1 is set"
fi
sf_need gh jq

tmp=$(sf_mktemp_dir)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

if [ -z "$repo" ]; then
  repo=$(sf_gh repo view --json nameWithOwner --jq .nameWithOwner | tr -d '\r') ||
    sf_die "could not tell which repository to bootstrap; pass --repo OWNER/NAME"
fi
case "$repo" in
  */*/* | /* | */ | *[!A-Za-z0-9._/-]*) sf_die "invalid repository '$repo' (expected OWNER/NAME)" ;;
  ?*/?*) ;;
  *) sf_die "invalid repository '$repo' (expected OWNER/NAME)" ;;
esac

# json_to_file VAR_TEXT FILE: keep gh output in a file for sf_jq.
json_to_file() { printf '%s\n' "$1" >"$2"; }

issue_number_from_url() {
  printf '%s\n' "$1" | tr -d '\r' | sed -n 's#.*/issues/\([0-9][0-9]*\).*#\1#p' | tail -n 1
}

# --- 1. labels --------------------------------------------------------------
out=$(sf_gh label list -R "$repo" --limit 1000 --json name) || sf_die "could not list labels of $repo"
json_to_file "$out" "$tmp/labels.json"
have_labels=$(sf_jq -r '.[].name | ascii_downcase' "$tmp/labels.json") || sf_die "could not parse the label list"
created_labels=""
present_labels=0
for spec in "${SF_LABELS[@]}"; do
  name=${spec%%|*}
  rest=${spec#*|}
  color=${rest%%|*}
  desc=${rest#*|}
  if printf '%s\n' "$have_labels" | grep -Fxq -- "$name"; then
    present_labels=$((present_labels + 1))
    continue
  fi
  if err=$(sf_gh label create "$name" -R "$repo" --color "$color" --description "$desc" 2>&1 </dev/null); then
    created_labels="$created_labels $name"
  else
    case "$err" in
      *"already exists"*) present_labels=$((present_labels + 1)) ;;
      *) printf '%s\n' "$err" >&2; sf_die "could not create label $name" ;;
    esac
  fi
done

# --- 2. log issue -----------------------------------------------------------
out=$(sf_gh issue list -R "$repo" --label factory:log --state open --limit 100 --json number,isPinned) ||
  sf_die "could not list factory:log issues"
json_to_file "$out" "$tmp/log.json"
# With several open log issues, a pinned one wins (pinning another would spend one of
# GitHub's 3 pin slots on a second log), then the oldest.
log_info=$(sf_jq -r 'sort_by([(.isPinned != true), .number])
  | if length == 0 then "" else "\(.[0].number) \(.[0].isPinned == true) \(length)" end' "$tmp/log.json") ||
  sf_die "could not parse the factory:log issue list"
log_num=""
log_pinned=false
if [ -n "$log_info" ]; then
  read -r log_num log_pinned log_count <<EOF
$log_info
EOF
  if [ "$log_count" -gt 1 ] && [ "$log_pinned" = true ]; then
    sf_warn "$log_count open factory:log issues; using the pinned one, #$log_num"
  elif [ "$log_count" -gt 1 ]; then
    sf_warn "$log_count open factory:log issues; using the oldest, #$log_num"
  fi
  log_state="#$log_num already open"
else
  cat >"$tmp/log-body.md" <<'EOF'
Run log for the software factory.

Each standing role keeps one comment here with the time of its last start and finish.
`scripts/run-agent.sh` reads and updates those comments to decide which role is due.
Keep this issue open and pinned.
EOF
  out=$(sf_gh issue create -R "$repo" --title "$SF_LOG_TITLE" --body-file - --label factory:log <"$tmp/log-body.md") ||
    sf_die "could not create the factory:log issue"
  log_num=$(issue_number_from_url "$out")
  [ -n "$log_num" ] || sf_die "could not read the log issue number from gh output: $out"
  log_state="#$log_num created"
fi
case "$log_num" in *[!0-9]*) sf_die "unexpected log issue number: $log_num" ;; esac
if [ "$log_pinned" = "true" ]; then
  log_state="$log_state, pinned"
elif sf_gh issue pin "$log_num" -R "$repo" >/dev/null </dev/null; then
  log_state="$log_state, now pinned"
else
  sf_warn "could not pin issue #$log_num (GitHub allows 3 pinned issues); the log still works unpinned"
  log_state="$log_state, not pinned"
fi

# --- 3. stop variables ------------------------------------------------------
out=$(sf_gh variable list -R "$repo" --json name) || sf_die "could not list the variables of $repo"
json_to_file "$out" "$tmp/vars.json"
have_vars=$(sf_jq -r '.[].name' "$tmp/vars.json") || sf_die "could not parse the variable list"
vars_state=""
for v in $SF_VARIABLES; do
  if printf '%s\n' "$have_vars" | grep -Fxq -- "$v"; then
    vars_state="$vars_state $v (kept)"
  else
    sf_gh variable set "$v" -R "$repo" --body false >/dev/null </dev/null || sf_die "could not set variable $v"
    vars_state="$vars_state $v=false (set)"
  fi
done

# --- 4. branch protection ---------------------------------------------------
protect_state="not requested (pass --protect)"
if [ "$protect" -eq 1 ]; then
  cat >"$tmp/protection.json" <<'EOF'
{
  "required_status_checks": {"strict": true, "contexts": ["gate"]},
  "enforce_admins": true,
  "required_pull_request_reviews": null,
  "restrictions": null
}
EOF
  # The request body goes through stdin: gh.exe can't open MSYS paths such as /tmp/... .
  if out=$(sf_gh api -X PUT "repos/$repo/branches/$base/protection" --input - <"$tmp/protection.json" 2>&1); then
    protect_state="$base requires check gate (strict, admins included)"
  else
    case "$out" in
      *"HTTP 403"* | *"HTTP 404"* | *"Upgrade to GitHub Pro"*)
        # GitHub's last line says why: no plan support, no admin rights, or no such branch yet.
        reason=$(printf '%s\n' "$out" | tr -d '\r' | awk 'NF { last = $0 } END { print last }')
        sf_warn "branch protection is not available for $repo ($reason); continuing without it"
        protect_state="skipped ($reason); the audit-merge job still catches bypasses"
        ;;
      *)
        printf '%s\n' "$out" >&2
        sf_die "could not set branch protection on $base"
        ;;
    esac
  fi
fi

printf 'repo: %s\n' "$repo"
printf 'labels: %d already present; created:%s\n' "$present_labels" "${created_labels:- none}"
printf 'log issue: %s\n' "$log_state"
printf 'variables:%s\n' "$vars_state"
printf 'protection: %s\n' "$protect_state"
