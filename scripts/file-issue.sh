#!/usr/bin/env bash
# Files a role-labelled agent issue, deduplicated by title; the only way agents open issues. Contract: docs/CONTRACTS.md, "file-issue.sh".
set -euo pipefail
SF_PROG=file-issue
# shellcheck source=scripts/lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
# shellcheck source=scripts/lib/jq.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/jq.sh"

SF_MARKER='<!-- factory:agent-filed'
SF_DUPLICATE=3

usage() {
  cat <<'EOF'
Usage:
  file-issue.sh --role ROLE --title TITLE --body-file FILE [--label LABEL]...
  file-issue.sh --enforce N

Files an issue labelled role:ROLE and agent-filed (plus any --label), and appends
an agent-filed marker naming FACTORY_AGENT_ID (default: unknown-agent) to the body.
Prints the new issue number.

If an open role:ROLE issue already has the same title (compared case-insensitively,
with whitespace collapsed and trimmed), nothing is filed: the existing number is
printed and the exit code is 3.

--enforce N adds the agent-filed label to issue N when its body carries the
agent-filed marker, the label is missing, and the issue's author_association is OWNER,
MEMBER or COLLABORATOR (read with gh api repos/{owner}/{repo}/issues/N). An issue by
anyone else is logged and left unlabelled (exit 0): open agent-filed issues count
toward the finders' backpressure, so labelling theirs would let anyone pause the finders.

Exit codes: 0 created or enforced (or nothing to do), 3 duplicate, 2 error.
EOF
}

role=""
title=""
body_file=""
enforce=""
labels=()
need_value() { [ "$2" -ge 2 ] || sf_die "$1 needs a value (see --help)"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --role) need_value "$1" "$#"; role="$2"; shift 2 ;;
    --title) need_value "$1" "$#"; title="$2"; shift 2 ;;
    --body-file) need_value "$1" "$#"; body_file="$2"; shift 2 ;;
    --label) need_value "$1" "$#"; labels+=("$2"); shift 2 ;;
    --enforce) need_value "$1" "$#"; enforce="$2"; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) sf_die "unknown argument: $1 (see --help)" ;;
  esac
done

tmp=""
cleanup() { if [ -n "$tmp" ]; then rm -rf "$tmp"; fi; }
trap cleanup EXIT

require_github() {
  if [ "${FACTORY_OFFLINE:-}" = "1" ]; then
    sf_die "GitHub is required, but FACTORY_OFFLINE=1 is set"
  fi
  sf_need gh jq
  tmp=$(sf_mktemp_dir)
}

# issue_number_from_url TEXT: the number from the last ".../issues/<n>" URL in TEXT.
issue_number_from_url() {
  printf '%s\n' "$1" | tr -d '\r' | sed -n 's#.*/issues/\([0-9][0-9]*\).*#\1#p' | tail -n 1
}

enforce_label() {
  local n="$1" verdict
  case "$n" in '' | *[!0-9]*) sf_die "--enforce needs an issue number, got '$n'" ;; esac
  # The REST issue holds the body, the labels and the author's association in one answer.
  # {owner}/{repo} is gh's own placeholder (GH_REPO, else the current repository).
  sf_gh api "repos/{owner}/{repo}/issues/$n" </dev/null >"$tmp/issue.json" ||
    sf_die "could not read issue #$n"
  # Anything that is not an issue as the API documents it (no author_association string, no
  # labels array) is an error: the association decides who may trip the backpressure.
  # shellcheck disable=SC2016 # jq variables, not shell ones
  verdict=$(sf_jq -r --arg m "$SF_MARKER" '
    if type != "object" then error("not an issue") else . end
    | if (.author_association | type) != "string" then error("no author_association") else . end
    | if (.labels | type) != "array" then error("no labels") else . end
    | if (.body | type) == "string" or .body == null then . else error("bad body") end
    | ((.body // "") | contains($m)) as $marked
    | ([.labels[] | if type == "object" then .name else . end | strings | ascii_downcase]
       | any(. == "agent-filed")) as $labelled
    | .author_association as $assoc
    | if ($marked | not) then "unmarked"
      elif $labelled then "labelled"
      elif ($assoc | IN("OWNER", "MEMBER", "COLLABORATOR")) then "add"
      else "untrusted \($assoc | tojson)" end' "$tmp/issue.json" 2>/dev/null) ||
    sf_die "could not parse issue #$n"
  case "$verdict" in
    add)
      sf_gh issue edit "$n" --add-label agent-filed </dev/null >/dev/null || sf_die "could not add agent-filed to #$n"
      sf_log "#$n: added the agent-filed label"
      ;;
    labelled) sf_log "#$n: already labelled agent-filed" ;;
    unmarked) sf_log "#$n: no agent-filed marker in the body; nothing to do" ;;
    "untrusted "*)
      sf_log "#$n: author association ${verdict#untrusted } is not OWNER, MEMBER or COLLABORATOR; not labelled agent-filed"
      ;;
    *) sf_die "unexpected answer while checking #$n" ;;
  esac
}

if [ -n "$enforce" ]; then
  if [ -n "$role$title$body_file" ] || [ "${#labels[@]}" -gt 0 ]; then
    sf_die "--enforce takes no other options (see --help)"
  fi
  require_github
  enforce_label "$enforce"
  exit 0
fi

[ -n "$role" ] || sf_die "--role is required (see --help)"
[ -n "$body_file" ] || sf_die "--body-file is required (see --help)"
case "$role" in
  -* | *[!a-z0-9-]*) sf_die "invalid role '$role' (use lowercase letters, digits and '-')" ;;
esac
title=$(sf_trim "$title")
[ -n "$title" ] || sf_die "--title is required and must not be blank"
case "$title" in
  *$'\n'* | *$'\r'*) sf_die "--title must be a single line" ;;
esac
if [ ! -f "$body_file" ] || [ ! -r "$body_file" ]; then
  sf_die "body file not readable: $body_file"
fi
for l in ${labels[@]+"${labels[@]}"}; do
  [ -n "$(sf_trim "$l")" ] || sf_die "--label must not be blank"
done

agent=$(printf '%s' "${FACTORY_AGENT_ID:-unknown-agent}" | tr -c 'A-Za-z0-9._-' '_')
[ -n "$agent" ] || agent=unknown-agent

require_github

# Dedupe against open issues of this role. The list API is used instead of search,
# because search results lag behind issues filed moments ago.
list=$(sf_gh issue list --label "role:$role" --state open --limit 200 --json number,title) ||
  sf_die "could not list open role:$role issues"
printf '%s\n' "$list" >"$tmp/list.json"
# The title reaches jq through a file: Git Bash rewrites "/..." in --arg values and
# in environment variables before native jq.exe sees them.
printf '%s' "$title" >"$tmp/title.txt"
# shellcheck disable=SC2016 # jq variables, not shell ones
dup=$(sf_jq -r --rawfile t "$tmp/title.txt" '
  def norm: ascii_downcase | gsub("\\s+"; " ") | ltrimstr(" ") | rtrimstr(" ");
  ($t | norm) as $want
  | if type == "array" then . else error("gh issue list did not return a JSON array") end
  | [.[] | select(((.title // "") | norm) == $want) | .number] | sort | first // empty
' "$tmp/list.json") || sf_die "could not parse the open role:$role issue list"
if [ -n "$dup" ]; then
  case "$dup" in *[!0-9]*) sf_die "unexpected issue number in gh output: $dup" ;; esac
  sf_log "duplicate of open issue #$dup; nothing filed"
  printf '%s\n' "$dup"
  exit "$SF_DUPLICATE"
fi

cp "$body_file" "$tmp/body.md"
if [ -s "$tmp/body.md" ] && [ -n "$(tail -c 1 "$tmp/body.md")" ]; then
  printf '\n' >>"$tmp/body.md"
fi
printf '\n%s agent=%s -->\n' "$SF_MARKER" "$agent" >>"$tmp/body.md"

args=(issue create --title "$title" --body-file - --label "role:$role" --label agent-filed)
for l in ${labels[@]+"${labels[@]}"}; do
  case "$l" in "role:$role" | agent-filed) continue ;; esac
  args+=(--label "$l")
done
# The body goes through stdin: gh.exe can't open MSYS paths such as /tmp/... .
out=$(sf_gh "${args[@]}" <"$tmp/body.md") || sf_die "gh issue create failed"
num=$(issue_number_from_url "$out")
[ -n "$num" ] || sf_die "could not read the new issue number from gh output: $out"
sf_log "filed #$num (role:$role, agent $agent)"
printf '%s\n' "$num"
