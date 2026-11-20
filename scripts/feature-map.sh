#!/usr/bin/env bash
# Reads, checks and updates the feature map (factory/feature-map.json). Contract: docs/CONTRACTS.md, "feature-map.sh".
set -euo pipefail
SF_PROG=feature-map
# shellcheck source=scripts/lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
# shellcheck source=scripts/lib/jq.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/jq.sh"
# shellcheck source=scripts/lib/config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"

# ---- USER CONTRIBUTION POINT: order_ready ----
# Which ready feature should the next agent take? Declared order (the default) is predictable
# and lets the planner set priority. Fewest-dependents-first ships small leaf features quickly
# but can leave the critical path waiting. Most-unblocking-first (most transitive dependents)
# frees the most later work and parallelism, but may start the biggest, riskiest feature first.
# stdin: JSON array of the ready features, in declared order. stdout: their ids, one per line,
# in the order agents should take them. The whole validated map is in the file "$FM_MAP_FILE".
# Use sf_jq (never bare jq): it keeps "/" in jq programs intact on Git Bash.
order_ready() {
  sf_jq -r '.[].id'
}
# ---- end order_ready ----

usage() {
  cat <<'EOF'
Usage:
  feature-map.sh validate [--map F] [--against REF] [--own ID] [--spec FILE]
  feature-map.sh next     [--map F | --ref REF] [--all] [--live]
  feature-map.sh context  ID [--map F | --ref REF] [--transitive]
  feature-map.sh mark     ID STATUS [--pr URL] [--reason TEXT] [--code-ref PATH]... [--map F]
  feature-map.sh check-tests ID [--tree DIR] [--map F | --ref REF]
  feature-map.sh list     [--map F | --ref REF] [--live] [--json]
  feature-map.sh fmt      [--map F] [--check]
  feature-map.sh add      --from FILE [--map F]
  feature-map.sh show     ID [--map F | --ref REF]

Every subcommand also accepts --tree DIR (default: the current repo root), --config FILE
(always read when given; a missing or broken file exits 2) and -h/--help.
The map is <tree>/factory/feature-map.json unless --map or FACTORY_MAP says
otherwise; --ref REF reads it with `git show REF:factory/feature-map.json` instead.
Live claims are remote branches refs/heads/factory/F<n> (remote: FACTORY_REMOTE, default origin).
mark --pr none clears the PR link.
add --from FILE appends the complete new feature entries in FILE (a JSON array) in their
order, and writes the map only if the result is valid. Every entry must be new work:
status todo, pr null and an empty context.code_refs. An id the map already has is an
error: add never changes an existing entry.
show ID prints that feature's whole entry as canonical JSON (jq --indent 2).

Exit codes: 0 ok; 1 the check said no (validate, mark, check-tests, fmt --check; add: the
result would be invalid, an entry is not new work, an id already exists or FILE is not a
JSON array, and nothing was written); 2 usage, config or input error (a missing map,
add's FILE missing, show or context of an id the map lacks). next: 0 printed ids,
3 nothing ready but work remains, 4 every feature is done, 5 the map is empty.
Contract: docs/CONTRACTS.md, "feature-map.sh".
EOF
}

# ---------------------------------------------------------------------------
# jq programs. They are written to files and run with jq -f, never passed as arguments:
# Git Bash rewrites anything that looks like a "/path" inside an argument to a native
# program, even in the middle of a jq program. Every program reads the map with -s.
#
# Problem lines are "<label>: <problem>". <label> is a valid feature id, "features[<i>]"
# or "map"; untrusted text inside a problem is JSON-quoted (tojson), so map content can
# never forge an extra diagnostic line.
# ---------------------------------------------------------------------------

FM_JQ_LIB='
def fm_isid: type == "string" and test("\\AF[0-9]+\\z");
def fm_q: tojson;
def fm_feats: if type == "object" and (.features | type) == "array" then .features else [] end;
def fm_good: [fm_feats[] | select(type == "object" and (.id | fm_isid))];
def fm_deps: if (.depends_on | type) == "array" then [.depends_on[] | select(fm_isid)] else [] end;
'

# The rules, as jq functions that emit [label, problem] pairs; validate.jq and add.jq share them.
# shellcheck disable=SC2016 # jq program: $names are jq variables
FM_JQ_RULES='
def fm_fields: ["id", "title", "description", "depends_on", "acceptance_criteria", "status", "context", "pr", "provides", "files", "blocked_reason"];
def fm_required: ["id", "title", "description", "depends_on", "acceptance_criteria", "status", "context", "pr"];
def fm_statuses: ["todo", "in_progress", "done", "blocked"];
def fm_strs: type == "array" and all(.[]; type == "string");

def shape_top:
  if type != "object" then ["map", "the top level must be an object"]
  else
    (keys_unsorted[] | select(IN("version", "features") | not) | ["map", "unknown top-level field \(fm_q)"]),
    (if has("version") | not then ["map", "missing field \"version\""]
     elif .version != 1 then ["map", "version must be 1 (got \(.version | fm_q))"]
     else empty end),
    (if has("features") | not then ["map", "missing field \"features\""]
     elif (.features | type) != "array" then ["map", "features must be an array"]
     else empty end)
  end;

def shape_feature($i):
  (if type == "object" and (.id | fm_isid) then .id else "features[\($i)]" end) as $l
  | if type != "object" then [$l, "a feature must be an object"]
    else
      (keys_unsorted[] | select(IN(fm_fields[]) | not) | [$l, "unknown field \(fm_q)"]),
      (fm_required[] as $k | select(has($k) | not) | [$l, "missing field \"\($k)\""]),
      (if has("id") and (.id | fm_isid | not) then [$l, "id must match ^F[0-9]+$ (got \(.id | fm_q))"] else empty end),
      (if has("title") then
         if (.title | type) != "string" then [$l, "title must be a string"]
         elif .title == "" then [$l, "title must not be empty"]
         else empty end
       else empty end),
      (if has("description") and (.description | type) != "string" then [$l, "description must be a string"] else empty end),
      (if has("depends_on") then
         if (.depends_on | type) != "array" then [$l, "depends_on must be an array"]
         else .depends_on[] | select(fm_isid | not) | [$l, "depends_on entries must be feature ids (got \(fm_q))"]
         end
       else empty end),
      (if has("acceptance_criteria") then
         if (.acceptance_criteria | type) != "array" then [$l, "acceptance_criteria must be an array"]
         elif (.acceptance_criteria | length) == 0 then [$l, "acceptance_criteria must not be empty"]
         else .acceptance_criteria | to_entries[]
           | select((.value | type) != "string" or .value == "")
           | [$l, "acceptance criterion \(.key + 1) must be a non-empty string"]
         end
       else empty end),
      (if has("status") and (.status | IN(fm_statuses[]) | not)
       then [$l, "status must be one of todo, in_progress, done, blocked (got \(.status | fm_q))"] else empty end),
      (if has("context") then
         if (.context | type) != "object" then [$l, "context must be an object"]
         else .context
           | (keys_unsorted[] | select(IN("business", "design", "code_refs") | not)
               | [$l, "unknown field \("context." + . | fm_q)"]),
             (("business", "design") as $k
               | if has($k) | not then [$l, "missing field \"context.\($k)\""]
                 elif (.[$k] | type) != "string" then [$l, "context.\($k) must be a string"]
                 else empty end),
             (if has("code_refs") | not then [$l, "missing field \"context.code_refs\""]
              elif (.code_refs | fm_strs | not) then [$l, "context.code_refs must be an array of strings"]
              else empty end)
         end
       else empty end),
      (if has("pr") and .pr != null and ((.pr | type) != "string" or (.pr | test("\\Ahttps://[!-~]+\\z") | not))
       then [$l, "pr must be null or a one-line https:// URL without spaces (got \(.pr | fm_q))"] else empty end),
      (if has("provides") then
         if (.provides | type) != "object" then [$l, "provides must be an object"]
         else .provides | to_entries[]
           | (if .key | fm_isid | not then [$l, "provides keys must be feature ids (got \(.key | fm_q))"] else empty end),
             (if (.value | type) != "string" then [$l, "provides[\(.key | fm_q)] must be a string"]
              elif (.value | test("[\\r\\n]")) then [$l, "provides[\(.key | fm_q)] must be a single line"]
              else empty end)
         end
       else empty end),
      (if has("files") and (.files | fm_strs | not) then [$l, "files must be an array of strings"] else empty end),
      (if has("blocked_reason") and (.blocked_reason | type) != "string" then [$l, "blocked_reason must be a string"] else empty end)
    end;

def graph_rules:
  fm_good as $fs
  | [$fs[].id] as $ids
  | ($ids | group_by(.) | .[] | select(length > 1) | [.[0], "duplicate id (used \(length) times)"]),
    ($fs[] | .id as $id | fm_deps[]
      | if . == $id then [$id, "depends on itself"]
        elif IN($ids[]) | not then [$id, "depends on unknown feature \(.)"]
        else empty end),
    ($fs[] | .id as $id | select((.provides | type) == "object")
      | .provides | keys_unsorted[] | select(fm_isid) | . as $k
      | select(any($fs[]; .id == $k and any(fm_deps[]; . == $id)) | not)
      | [$id, "provides a note for \($k), but \($k) does not depend on \($id)"]);

# Cycles: repeatedly remove nodes whose dependencies are all removed. Every node left
# depends on another node left, so following first dependencies from any of them must
# revisit a node, and that loop is a cycle. Report it, drop its nodes, repeat.
def fm_peel:
  . as $g
  | [$g[].id] as $left
  | [$g[] | select(any(.deps[]; IN($left[])) | not) | .id] as $free
  | if ($free | length) == 0 then $g
    else [$g[] | select(.id | IN($free[]) | not)] | fm_peel end;
def fm_walk($g; $path):
  ($path | last) as $cur
  | (first($g[] | select(.id == $cur) | .deps[] | select(. as $d | any($g[]; .id == $d))) // null) as $next
  | (first($path | to_entries[] | select(.value == $next) | .key) // null) as $at
  | if $next == null then $path
    elif $at != null then $path[$at:] + [$next]
    else fm_walk($g; $path + [$next]) end;
def fm_cycles:
  fm_peel
  | if length == 0 then empty
    else fm_walk(.; [.[0].id]) as $c
      | $c, ([.[] | select(.id | IN($c[]) | not)] | fm_cycles)
    end;
def cycle_rules:
  fm_good as $fs
  | [$fs[].id] as $ids
  | [$fs[] | .id as $id | {id: $id, deps: [fm_deps[] | select(. != $id and IN($ids[]))]}]
  | fm_cycles
  | [.[0], "dependency cycle: \(join(" -> "))"];

def status_rules:
  fm_good as $fs
  | ($fs | map({key: .id, value: .status}) | from_entries) as $st
  | $fs[] | .id as $id | .status as $s
  | (if $s == "done" or $s == "in_progress" then
       fm_deps[] | . as $d
       | select($d != $id and ($st | has($d)) and $st[$d] != "done")
       | [$id, "\($s) requires dependency \($d) to be done (it is \($st[$d] | fm_q))"]
     else empty end),
    (if $s == "done" and .pr == null then [$id, "done requires pr to be set"] else empty end),
    (if $s == "done" and (((.context | type) == "object" and (.context.code_refs | type) == "array"
                           and (.context.code_refs | length) > 0) | not)
     then [$id, "done requires a non-empty context.code_refs"] else empty end),
    (if $s == "blocked" and ((.blocked_reason | type) != "string" or .blocked_reason == "")
     then [$id, "blocked requires a blocked_reason"] else empty end);

def spec_rules($spec):
  fm_good[] | .id as $id
  | select((.context | type) == "object" and (.context.design | type) == "string")
  | [.context.design | scan("(?<![A-Za-z0-9_-])D-[A-Za-z0-9_]+(?:-[A-Za-z0-9_]+)*")] | unique[]
  | . as $t
  | select($spec | test("(?<![A-Za-z0-9_-])" + $t + "(?![A-Za-z0-9_]|-[A-Za-z0-9_])") | not)
  | [$id, "design ref \($t) is not in the spec"];

def against_rules($o):
  ($o | fm_good) as $old
  | (fm_good | map({key: .id, value: .}) | from_entries) as $nm
  | $old[] | .id as $id
  | if ($nm | has($id) | not) then [$id, "feature was removed (it exists in the --against map)"]
    else $nm[$id] as $n
      | (if .status == "done" and . != $n then [$id, "a done feature may not change"] else empty end),
        (if (.acceptance_criteria | type) == "array" then
           .acceptance_criteria as $oac
           | ($n.acceptance_criteria | if type == "array" then . else [] end) as $nac
           | range(0; $oac | length) as $k
           | select($nac[$k] != $oac[$k])
           | [$id, "acceptance criterion \($id)-ac\($k + 1) was changed or removed"]
         else empty end)
    end;

def fm_own_strip:
  del(.status, .pr, .blocked_reason)
  | if (.context | type) == "object" then del(.context.code_refs) else . end;
def own_rules($o; $own):
  ($o | fm_good) as $old
  | fm_good as $new
  | [$old[].id] as $oids
  | [$new[].id] as $nids
  | ($nids[] | select(IN($oids[]) | not) | [., "new features may not be added on the \($own) branch"]),
    (if any($oids[]; . == $own) then empty else [$own, "\($own) is not in the --against map"] end),
    ($new[] | . as $n | select(.id != $own)
      | first($old[] | select(.id == $n.id)) as $p
      | select($n != $p)
      | [$n.id, "only \($own) may change on the \($own) branch"]),
    ($new[] | select(.id == $own) | . as $n
      | first($old[] | select(.id == $own)) as $p
      | select(($n | fm_own_strip) != ($p | fm_own_strip))
      | [$own, "only status, pr, context.code_refs and blocked_reason may change on the \($own) branch"]),
    (if [$nids[] | select(IN($oids[]))] != [$oids[] | select(IN($nids[]))]
     then ["map", "the order of features may not change on the \($own) branch"] else empty end);

# The core rules every map must pass: shape, graph and status.
def core_rules:
  shape_top,
  (fm_feats | to_entries[] | .key as $i | .value | shape_feature($i)),
  graph_rules,
  cycle_rules,
  status_rules;
'

# shellcheck disable=SC2016 # jq program: $names are jq variables
FM_JQ_VALIDATE='
if length != 1 then "map: invalid JSON: expected exactly one JSON document, found \(length)"
elif $rules | not then empty
else
  .[0]
  | ($old | length > 0) as $hasold
  | [ core_rules,
      (if $checkspec then spec_rules($spec) else empty end),
      (if $hasold then against_rules($old[0]) else empty end),
      (if $hasold and $own != "" then own_rules($old[0]; $own) else empty end)
    ]
  | .[]
  | "\(.[0]): \(.[1])"
end
'

# next, on a valid map: line 1 "<total> <done> <ready>", line 2 the ready features (JSON),
# line 3 their ids, line 4 a summary, then one "blocked: <id> (...)" line per blocked feature.
# shellcheck disable=SC2016
FM_JQ_NEXT='
.[0]
| (.features | map({key: .id, value: .status}) | from_entries) as $st
| [.features[] | select(.status == "todo" and all(.depends_on[]; $st[.] == "done"))] as $met
| [$met[] | select(.id | IN($claims[]) | not)] as $ready
| [$met[] | select(.id | IN($claims[])) | .id] as $claimed
| [.features[] | select(.status == "todo" and (all(.depends_on[]; $st[.] == "done") | not)) | .id] as $waiting
| [.features[] | select(.status == "in_progress") | .id] as $inprog
| [.features[] | select(.status == "blocked")] as $blocked
| "\(.features | length) \([.features[] | select(.status == "done")] | length) \($ready | length)",
  ($ready | tojson),
  ([$ready[].id] | join(" ")),
  ([ (if ($inprog | length) > 0 then "in progress: \($inprog | join(" "))" else empty end),
     (if ($claimed | length) > 0 then "claimed: \($claimed | join(" "))" else empty end),
     (if ($waiting | length) > 0 then "waiting on dependencies: \($waiting | join(" "))" else empty end),
     (if ($blocked | length) > 0 then "blocked: \([$blocked[].id] | join(" "))" else empty end)
   ] | join("; ")),
  ($blocked[] | "blocked: \(.id) (reason: \(.blocked_reason // "" | fm_q))")
'

# shellcheck disable=SC2016
FM_JQ_CONTEXT='
def fm_text: if . == null or . == "" then "(none)" else . end;
def fm_bullets: if length == 0 then "(none)" else map("- " + .) | join("\n") end;
def fm_closure($by):
  . as $s
  | ($s + [$s[] | $by[.].depends_on[]] | unique) as $n
  | if ($n | length) == ($s | length) then $s else $n | fm_closure($by) end;
.[0]
| if any(.features[]; .id == $id) then . else "no such feature\n" | halt_error(4) end
| (.features | map({key: .id, value: .}) | from_entries) as $by
| $by[$id] as $f
| (if $transitive then ($f.depends_on | unique | fm_closure($by)) else $f.depends_on end) as $want
| [.features[] | select(.id | IN($want[]))] as $deps
| [ "# \($id): \($f.title)",
    "",
    "Status: \($f.status)",
    "",
    ($f.description | fm_text),
    "",
    "## Acceptance criteria",
    "",
    ($f.acceptance_criteria | to_entries[] | "- \($id)-ac\(.key + 1): \(.value)"),
    "",
    "Tag each test with the id of the criterion it covers (for example \($id)-ac1); `feature-map.sh check-tests \($id)` looks for those tags.",
    "",
    "## Context",
    "",
    "### Business",
    "",
    ($f.context.business | fm_text),
    "",
    "### Design",
    "",
    ($f.context.design | fm_text),
    "",
    "### Code refs",
    "",
    ($f.context.code_refs | fm_bullets),
    (if ($f.files // []) | length > 0 then "", "### Files (expected scope)", "", ($f.files | fm_bullets) else empty end),
    (if $f.status == "blocked" then "", "### Blocked", "", ($f.blocked_reason | fm_text) else empty end),
    "",
    (if $transitive then "## Dependencies (all ancestors)" else "## Dependencies" end),
    "",
    (if ($deps | length) == 0 then "None.", ""
     else $deps[]
       | "### \(.id): \(.title)",
         "",
         "- Status: \(.status)",
         "- PR: \(.pr // "none")",
         "- Provides for \($id): \(.provides[$id] // "(no note)")",
         "- Code refs: \(if (.context.code_refs | length) == 0 then "(none)" else .context.code_refs | join(", ") end)",
         ""
     end)
  ]
| join("\n")
'

# shellcheck disable=SC2016
FM_JQ_MARK='
.[0]
| if type == "object" and (.features | type) == "array" and any(.features[]; type == "object" and .id == $id) then .
  else "no such feature\n" | halt_error(4) end
| ($refs_text | split("\n") | map(select(. != ""))) as $refs
| .features |= map(
    if type == "object" and .id == $id then
      .status = $status
      | (if $setpr then .pr = (if $pr == "none" then null else $pr end) else . end)
      | (if $status == "blocked" then (if $setreason then .blocked_reason = $reason else . end)
         else del(.blocked_reason) end)
      | (if $setrefs and (.context | type) == "object" then .context.code_refs = $refs else . end)
    else . end)
'

# shellcheck disable=SC2016
FM_JQ_CRITERIA='
.[0]
| first(.features[] | select(.id == $id) | .acceptance_criteria | length)
  // ("no such feature\n" | halt_error(4))
'

# shellcheck disable=SC2016
FM_JQ_LIST='
.[0]
| (.features | map({key: .id, value: .status}) | from_entries) as $st
| [.features[]
   | (.id | IN($claims[])) as $claimed
   | { id, title, status, depends_on, pr,
       ready: (.status == "todo" and all(.depends_on[]; $st[.] == "done") and ($claimed | not)),
       claimed: (if $live then $claimed else null end) }] as $rows
| if $json then $rows
  else $rows[]
    | [.id, .status]
      + (if $live then [if .claimed then "claimed" else "-" end] else [] end)
      + [.title | gsub("[\\t\\r\\n]"; " ")]
    | join("\t")
  end
'

# add, problems only: reads the input file (-s) and the map ($map). An input entry whose id is
# already in the map is reported and left out; every other entry must be new work (status todo,
# pr null, empty context.code_refs: a plan adds work, never finished work); then they are
# appended and the core rules run on the result. Entries without a valid id are labelled
# input[<index in the input file>].
# shellcheck disable=SC2016
FM_JQ_ADD_CHECK='
def fm_relabel($base; $keep):
  if (.[0] | test("\\Afeatures\\[[0-9]+\\]\\z")) and (.[0][9:-1] | tonumber) >= $base
  then .[0] = "input[\($keep[(.[0][9:-1] | tonumber) - $base])]"
  else . end;
def fm_new_work($l):
  (if has("status") and .status != "todo"
   then [$l, "a new feature must have status todo (got \(.status | fm_q)): a plan adds work, never started or finished work"] else empty end),
  (if has("pr") and .pr != null
   then [$l, "a new feature must have pr null (got \(.pr | fm_q))"] else empty end),
  (if (.context | type) == "object" and (.context.code_refs | type) == "array" and (.context.code_refs | length) > 0
   then [$l, "a new feature must have an empty context.code_refs (got \(.context.code_refs | fm_q))"] else empty end);
if length != 1 then "input: invalid JSON: expected exactly one JSON document, found \(length)"
elif (.[0] | type) != "array" then "input: must be a JSON array of feature entries (got \(.[0] | type))"
else
  .[0] as $in
  | $map[0] as $m
  | [$m | fm_good[].id] as $have
  | [$in | to_entries[] | select(.value | type == "object" and (.id | fm_isid) and (.id | IN($have[]))) | .key] as $clash
  | [range(0; $in | length) | select(IN($clash[]) | not)] as $keep
  | ($m | fm_feats | length) as $base
  | ($clash[] | "\($in[.].id): already in the map; add never changes an existing entry"),
    ( $keep[] as $k | $in[$k] | select(type == "object")
      | fm_new_work(if (.id | fm_isid) then .id else "input[\($k)]" end)
      | "\(.[0]): \(.[1])"),
    ( (if ($m | type) == "object" and ($m.features | type) == "array"
       then $m | .features += [$keep[] as $k | $in[$k]] else $m end)
      | core_rules
      | fm_relabel($base; $keep)
      | "\(.[0]): \(.[1])")
end
'

# add, the new map: the map (-s) with every input entry ($new) appended in order.
# shellcheck disable=SC2016
FM_JQ_ADD_MERGE='
.[0] | .features += $new[0]
'

# shellcheck disable=SC2016
FM_JQ_SHOW='
.[0]
| first(.features[] | select(.id == $id))
  // ("no such feature\n" | halt_error(4))
'

fm_write_programs() {
  printf '%s\n%s\n%s\n' "$FM_JQ_LIB" "$FM_JQ_RULES" "$FM_JQ_VALIDATE" >"$FM_TMP/validate.jq"
  printf '%s\n%s\n%s\n' "$FM_JQ_LIB" "$FM_JQ_RULES" "$FM_JQ_ADD_CHECK" >"$FM_TMP/add-check.jq"
  printf '%s\n' "$FM_JQ_ADD_MERGE" >"$FM_TMP/add-merge.jq"
  printf '%s\n' "$FM_JQ_SHOW" >"$FM_TMP/show.jq"
  printf '%s\n%s\n' "$FM_JQ_LIB" "$FM_JQ_NEXT" >"$FM_TMP/next.jq"
  printf '%s\n' "$FM_JQ_CONTEXT" >"$FM_TMP/context.jq"
  printf '%s\n' "$FM_JQ_MARK" >"$FM_TMP/mark.jq"
  printf '%s\n' "$FM_JQ_CRITERIA" >"$FM_TMP/criteria.jq"
  printf '%s\n' "$FM_JQ_LIST" >"$FM_TMP/list.jq"
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

FM_CMD=""
FM_ARGS=()
FM_NARGS=0
OPT_MAP="" OPT_REF="" OPT_TREE="" OPT_CONFIG="" OPT_AGAINST="" OPT_OWN="" OPT_SPEC="" OPT_FROM=""
OPT_PR="" OPT_PR_SET=0 OPT_REASON="" OPT_REASON_SET=0
OPT_ALL=0 OPT_LIVE=0 OPT_TRANSITIVE=0 OPT_JSON=0 OPT_CHECK=0
OPT_CODE_REFS=()
OPT_CODE_REFS_SET=0
FM_NL=$'\n'
FM_CR=$'\r'

fm_usage_die() {
  printf '%s: error: %s\n' "$SF_PROG" "$1" >&2
  printf "%s: run 'bash scripts/feature-map.sh --help' for usage\n" "$SF_PROG" >&2
  exit 2
}

fm_allowed_options() {
  case "$FM_CMD" in
    validate) echo "--map --against --own --spec" ;;
    next) echo "--map --ref --all --live" ;;
    context) echo "--map --ref --transitive" ;;
    mark) echo "--map --pr --reason --code-ref" ;;
    check-tests) echo "--map --ref" ;;
    list) echo "--map --ref --live --json" ;;
    fmt) echo "--map --check" ;;
    add) echo "--map --from" ;;
    show) echo "--map --ref" ;;
  esac
}

fm_parse_args() {
  local allowed opt val has_val
  allowed=" --tree --config $(fm_allowed_options) "
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h | --help) usage; exit 0 ;;
      --)
        shift
        while [ "$#" -gt 0 ]; do FM_ARGS+=("$1"); FM_NARGS=$((FM_NARGS + 1)); shift; done
        ;;
      --*)
        opt="${1%%=*}"
        has_val=0
        val=""
        case "$1" in *=*) has_val=1; val="${1#*=}" ;; esac
        case "$allowed" in *" $opt "*) ;; *) fm_usage_die "$FM_CMD: unknown option $opt" ;; esac
        case "$opt" in
          --all | --live | --transitive | --json | --check)
            [ "$has_val" -eq 0 ] || fm_usage_die "$opt takes no value"
            case "$opt" in
              --all) OPT_ALL=1 ;;
              --live) OPT_LIVE=1 ;;
              --transitive) OPT_TRANSITIVE=1 ;;
              --json) OPT_JSON=1 ;;
              --check) OPT_CHECK=1 ;;
            esac
            shift
            ;;
          *)
            if [ "$has_val" -eq 0 ]; then
              [ "$#" -ge 2 ] || fm_usage_die "$opt needs a value"
              val="$2"
              shift 2
            else
              shift
            fi
            [ -n "$val" ] || fm_usage_die "$opt needs a non-empty value"
            case "$opt" in
              --map) OPT_MAP="$val" ;;
              --ref) OPT_REF="$val" ;;
              --tree) OPT_TREE="$val" ;;
              --config) OPT_CONFIG="$val" ;;
              --against) OPT_AGAINST="$val" ;;
              --own) OPT_OWN="$val" ;;
              --spec) OPT_SPEC="$val" ;;
              --from) OPT_FROM="$val" ;;
              --pr) OPT_PR="$val"; OPT_PR_SET=1 ;;
              --reason) OPT_REASON="$val"; OPT_REASON_SET=1 ;;
              --code-ref)
                case "$val" in *"$FM_NL"*) fm_usage_die "--code-ref must be a single line" ;; esac
                OPT_CODE_REFS+=("$val")
                OPT_CODE_REFS_SET=1
                ;;
            esac
            ;;
        esac
        ;;
      -?*) fm_usage_die "$FM_CMD: unknown option $1" ;;
      *) FM_ARGS+=("$1"); FM_NARGS=$((FM_NARGS + 1)); shift ;;
    esac
  done
  if [ -n "$OPT_MAP" ] && [ -n "$OPT_REF" ]; then
    fm_usage_die "--map and --ref cannot be used together"
  fi
}

fm_valid_id() {
  case "$1" in
    F[0-9]*) case "${1#F}" in *[!0-9]*) return 1 ;; esac ;;
    *) return 1 ;;
  esac
}

fm_expect_id_arg() { # fm_expect_id_arg N WHAT: exactly N positional arguments, the first a feature id.
  [ "$FM_NARGS" -eq "$1" ] || fm_usage_die "$FM_CMD: expected $2"
  fm_valid_id "${FM_ARGS[0]}" || fm_usage_die "invalid feature id '${FM_ARGS[0]}' (expected F<number>)"
}

fm_expect_no_args() {
  [ "$FM_NARGS" -eq 0 ] || fm_usage_die "$FM_CMD: unexpected argument '${FM_ARGS[0]}'"
}

# ---------------------------------------------------------------------------
# Locating, checking and writing the map
# ---------------------------------------------------------------------------

FM_TMP=""
FM_PENDING=""
FM_TREE=""
FM_MAP=""
FM_FILE=""
FM_SRC=""
FM_PROBLEMS=""
# Inputs of fm_check beyond the core rules (shape, graph, status).
FMV_RULES=true
FMV_SPEC=""
FMV_OLD=""
FMV_OWN=""

fm_cleanup() {
  if [ -n "$FM_PENDING" ]; then rm -f "$FM_PENDING"; fi
  if [ -n "$FM_TMP" ]; then rm -rf "$FM_TMP"; fi
}

# fm_tree: FM_TREE = top level of --tree (default: the repo containing the current directory).
fm_tree() {
  if [ -z "$FM_TREE" ]; then
    FM_TREE=$(sf_repo_root "${OPT_TREE:-.}") || exit 2
  fi
}

# fm_safe_path PATH: PATH with "./" in front when it starts with "-", so that jq, awk, cmp,
# head and mv never read a file name as an option.
fm_safe_path() {
  case "$1" in
    -*) printf './%s\n' "$1" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# fm_map_path: FM_MAP = --map, else FACTORY_MAP, else <tree>/factory/feature-map.json.
fm_map_path() {
  if [ -n "$OPT_MAP" ]; then
    FM_MAP=$(fm_safe_path "$OPT_MAP")
  elif [ -n "${FACTORY_MAP:-}" ]; then
    FM_MAP=$(fm_safe_path "$FACTORY_MAP")
  else
    fm_tree
    FM_MAP="$FM_TREE/factory/feature-map.json"
  fi
}

# fm_git_map REF DEST: write factory/feature-map.json at REF to DEST; returns 3 if REF has no map.
fm_git_map() {
  local ref="$1" dest="$2"
  case "$ref" in -*) fm_usage_die "invalid git ref '$ref'" ;; esac
  fm_tree
  git -C "$FM_TREE" rev-parse --verify --quiet "$ref^{commit}" >/dev/null ||
    sf_die "unknown git ref: $ref"
  if ! git -C "$FM_TREE" cat-file -e "$ref:factory/feature-map.json" 2>/dev/null; then
    return 3
  fi
  git -C "$FM_TREE" show "$ref:factory/feature-map.json" >"$dest" ||
    sf_die "could not read factory/feature-map.json at $ref"
}

# fm_load: FM_FILE = the map to read (the map file itself, or the blob at --ref saved in
# FM_TMP); FM_SRC names it in messages.
fm_load() {
  local rc=0
  if [ -n "$OPT_REF" ]; then
    fm_git_map "$OPT_REF" "$FM_TMP/ref.json" || rc=$?
    [ "$rc" -eq 0 ] || sf_die "no factory/feature-map.json at $OPT_REF"
    FM_FILE="$FM_TMP/ref.json"
    FM_SRC="$OPT_REF:factory/feature-map.json"
  else
    fm_map_path
    [ -f "$FM_MAP" ] || sf_die "map not found: $FM_MAP"
    FM_FILE="$FM_MAP"
    FM_SRC="$FM_MAP"
  fi
}

fm_jq_error() {
  head -n 1 "$FM_TMP/jq.err" | tr -d '\r' | sed -e 's/^jq: //' -e 's/^error ([^)]*): //' -e 's/^parse error: //'
}

fm_is_parse_error() { grep -q 'parse error' "$FM_TMP/jq.err"; }

# fm_clean_bytes FILE: 0 when FILE holds no NUL and no Ctrl-Z byte, 1 when it holds one, 2 when
# it could not be read. No JSON text holds either byte raw, but jq stops reading at them (a NUL
# can end its input buffer; Windows text mode reads Ctrl-Z as the end of the file), so it would
# judge only the part of the file before one, and two jq calls could each see a different part.
fm_clean_bytes() {
  local rc=0
  LC_ALL=C tr -d '\000\032' <"$1" >"$FM_TMP/clean.bin" || return 2
  cmp -s "$1" "$FM_TMP/clean.bin" || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

# fm_check FILE: FM_PROBLEMS = one "<label>: <problem>" line per problem in FILE, "" if none.
# Always checks that FILE holds exactly one JSON document; with FMV_RULES=true also the
# shape, graph and status rules, plus --spec, --against and --own when FMV_* are set.
fm_check() {
  local rc=0 args
  args=(--argjson rules "$FMV_RULES" --arg own "$FMV_OWN")
  if [ -n "$FMV_SPEC" ]; then
    args+=(--argjson checkspec true --rawfile spec "$FMV_SPEC")
  else
    args+=(--argjson checkspec false --arg spec "")
  fi
  if [ -n "$FMV_OLD" ]; then
    args+=(--slurpfile old "$FMV_OLD")
  else
    args+=(--argjson old "[]")
  fi
  FM_PROBLEMS=$(sf_jq -r -s "${args[@]}" -f "$FM_TMP/validate.jq" "$1" 2>"$FM_TMP/jq.err") || rc=$?
  if [ "$rc" -ne 0 ]; then
    fm_is_parse_error || sf_die "internal error: the validation program failed: $(fm_jq_error)"
    FM_PROBLEMS="map: invalid JSON: $(fm_jq_error)"
  fi
}

fm_report() { # fm_report LINES: print each line to stderr with the script prefix.
  printf '%s\n' "$1" | while IFS= read -r line; do
    printf '%s: %s\n' "$SF_PROG" "$line" >&2
  done
}

# fm_read_valid: load the map and exit 2 if it breaks any shape, graph or status rule,
# because nothing can be decided from an invalid map.
fm_read_valid() {
  fm_load
  fm_check "$FM_FILE"
  if [ -n "$FM_PROBLEMS" ]; then
    fm_report "$FM_PROBLEMS"
    sf_die "$FM_SRC is invalid; run: bash scripts/feature-map.sh validate"
  fi
}

# fm_format_reason FILE: print why FILE is not canonical (jq --indent 2, LF, no BOM,
# trailing newline) and return 0; return 1 when it is canonical; return 2, with the reason,
# when jq could not render the canonical text (fail closed: never "canonical" by accident).
# Leaves the canonical text in $FM_TMP/canon.json. The comparison is on bytes, outside jq:
# native Windows jq reads files in text mode and never sees a CR.
fm_format_reason() {
  if ! sf_jq --indent 2 . "$1" >"$FM_TMP/canon.json" 2>"$FM_TMP/jq.err"; then
    printf 'jq could not render the canonical text of %s: %s\n' "$1" "$(fm_jq_error)"
    return 2
  fi
  if cmp -s "$1" "$FM_TMP/canon.json"; then return 1; fi
  if [ "$(head -c 3 "$1" | od -An -tx1 | tr -d ' \n')" = "efbbbf" ]; then
    echo "the file starts with a UTF-8 BOM"
  elif tr -d '\r' <"$1" >"$FM_TMP/nocr.json" && ! cmp -s "$FM_TMP/nocr.json" "$1"; then
    echo "the file has CR (CRLF) line endings"
  else
    echo "the file is not canonical JSON (jq --indent 2, LF line endings, trailing newline)"
  fi
}

# fm_begin_write: FM_PENDING = a new temp file next to FM_MAP, so the final mv is atomic.
fm_begin_write() {
  local dir=.
  case "$FM_MAP" in */*) dir="${FM_MAP%/*}" ;; esac
  [ -n "$dir" ] || dir=/
  FM_PENDING="$dir/.feature-map.json.$$.$RANDOM.tmp"
  : >"$FM_PENDING" || sf_die "cannot create a temporary file in $dir"
}

fm_commit_write() {
  mv -f "$FM_PENDING" "$FM_MAP" || sf_die "could not replace $FM_MAP"
  FM_PENDING=""
}

# fm_claims_json: JSON array of the feature ids that have a branch refs/heads/factory/F<n>
# on the remote. Uses git, not gh, so it also works with FACTORY_OFFLINE=1.
fm_claims_json() {
  local remote out ids id json=""
  fm_tree
  remote=$(sf_remote)
  out=$(git -C "$FM_TREE" ls-remote "$remote" 'refs/heads/factory/F*' 2>"$FM_TMP/ls-remote.err") ||
    sf_die "git ls-remote $remote failed, so live claims are unknown: $(head -n 1 "$FM_TMP/ls-remote.err" | tr -d '\r')"
  ids=$(printf '%s\n' "$out" | awk -F '\t' '{
    r = $2; sub(/\r$/, "", r)
    if (sub(/^refs\/heads\/factory\//, "", r) && r ~ /^F[0-9]+$/) print r }')
  for id in $ids; do
    json="$json${json:+,}\"$id\""
  done
  printf '[%s]\n' "$json"
}

# fm_order READY_FILE READY_IDS COUNT: run order_ready on READY_FILE and check it printed
# each ready id exactly once. FM_ORDERED = the ids, space-separated, in its order.
fm_order() {
  local out id seen=" " n=0
  FM_MAP_FILE="$FM_FILE"
  export FM_MAP_FILE
  out=$(order_ready <"$1") || sf_die "order_ready failed"
  set -f
  for id in $out; do
    id="${id%"$FM_CR"}"
    case " $2 " in *" $id "*) ;; *) n=-1; break ;; esac
    case "$seen" in *" $id "*) n=-1; break ;; esac
    seen="$seen$id "
    n=$((n + 1))
  done
  set +f
  [ "$n" -eq "$3" ] ||
    sf_die "order_ready must print each ready id exactly once; ready: $2; got: $(printf '%s' "$out" | tr '\n' ' ')"
  FM_ORDERED="${seen# }"
}

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------

cmd_validate() {
  local reason rc=0 problems
  fm_expect_no_args
  if [ -n "$OPT_OWN" ]; then
    [ -n "$OPT_AGAINST" ] || fm_usage_die "--own needs --against REF"
    fm_valid_id "$OPT_OWN" || fm_usage_die "--own: invalid feature id '$OPT_OWN'"
  fi
  fm_load
  if [ -n "$OPT_SPEC" ]; then
    [ -f "$OPT_SPEC" ] || sf_die "spec not found: $OPT_SPEC"
    FMV_SPEC=$(fm_safe_path "$OPT_SPEC")
  fi
  if [ -n "$OPT_AGAINST" ]; then
    fm_git_map "$OPT_AGAINST" "$FM_TMP/old.json" || rc=$?
    if [ "$rc" -eq 3 ]; then
      sf_log "no factory/feature-map.json at $OPT_AGAINST; comparing against an empty map"
      printf '{"version":1,"features":[]}\n' >"$FM_TMP/old.json"
    fi
    sf_jq -e -s 'length == 1' "$FM_TMP/old.json" >/dev/null 2>&1 ||
      sf_die "the map at $OPT_AGAINST is not a single valid JSON document"
    FMV_OLD="$FM_TMP/old.json"
    FMV_OWN="$OPT_OWN"
  fi

  fm_check "$FM_FILE"
  problems="$FM_PROBLEMS"
  case "$problems" in
    "map: invalid JSON"*) ;;
    *)
      rc=0
      reason=$(fm_format_reason "$FM_FILE") || rc=$?
      case "$rc" in
        0) problems="${problems:+$problems$FM_NL}map: $reason; run: bash scripts/feature-map.sh fmt" ;;
        1) ;;
        *) sf_die "internal error: $reason" ;;
      esac
      ;;
  esac
  if [ -n "$problems" ]; then
    fm_report "$problems"
    exit 1
  fi
  sf_log "valid: $FM_SRC"
}

cmd_next() {
  local claims="[]" total done_count nready ready_json ready_ids summary blocked
  fm_expect_no_args
  fm_read_valid
  if [ "$OPT_LIVE" -eq 1 ]; then claims=$(fm_claims_json); fi
  sf_jq -r -s --argjson claims "$claims" -f "$FM_TMP/next.jq" "$FM_FILE" >"$FM_TMP/next.txt" ||
    sf_die "internal error: could not compute the ready features"
  {
    read -r total done_count nready
    IFS= read -r ready_json
    IFS= read -r ready_ids
    IFS= read -r summary
  } <"$FM_TMP/next.txt"
  printf '%s\n' "$ready_json" >"$FM_TMP/ready.json"
  blocked=$(tail -n +5 "$FM_TMP/next.txt")

  if [ "$total" -eq 0 ]; then
    sf_log "the map is empty"
    exit 5
  fi
  if [ "$done_count" -eq "$total" ]; then
    sf_log "every feature is done"
    exit 4
  fi
  if [ "$nready" -eq 0 ]; then
    sf_log "nothing is ready ($summary)"
    if [ -n "$blocked" ]; then fm_report "$blocked"; fi
    exit 3
  fi
  fm_order "$FM_TMP/ready.json" "$ready_ids" "$nready"
  if [ "$OPT_ALL" -eq 1 ]; then
    # shellcheck disable=SC2086 # split the checked, space-separated ids (no glob characters)
    printf '%s\n' $FM_ORDERED
  else
    printf '%s\n' "${FM_ORDERED%% *}"
  fi
}

cmd_context() {
  local id transitive=false rc=0
  fm_expect_id_arg 1 "one feature ID"
  id="${FM_ARGS[0]}"
  [ "$OPT_TRANSITIVE" -eq 0 ] || transitive=true
  fm_read_valid
  sf_jq -r -s --arg id "$id" --argjson transitive "$transitive" -f "$FM_TMP/context.jq" "$FM_FILE" \
    2>"$FM_TMP/jq.err" || rc=$?
  case "$rc" in
    0) ;;
    4) sf_die "no feature $id in $FM_SRC" ;;
    *) sf_die "internal error: could not build the context for $id: $(fm_jq_error)" ;;
  esac
}

cmd_mark() {
  local id status rc=0 setpr=false setreason=false setrefs=false
  fm_expect_id_arg 2 "ID and STATUS"
  id="${FM_ARGS[0]}"
  status="${FM_ARGS[1]}"
  case "$status" in
    todo | in_progress | done | blocked) ;;
    *) fm_usage_die "invalid status '$status' (todo, in_progress, done or blocked)" ;;
  esac
  if [ "$OPT_REASON_SET" -eq 1 ] && [ "$status" != blocked ]; then
    fm_usage_die "--reason is only valid with status blocked"
  fi
  fm_load
  FMV_RULES=false
  fm_check "$FM_FILE"
  [ -z "$FM_PROBLEMS" ] || sf_die "$FM_SRC is not valid JSON: ${FM_PROBLEMS#map: invalid JSON: }"

  # Values reach jq through files: Git Bash rewrites arguments that start with "/".
  printf '%s' "$OPT_PR" >"$FM_TMP/pr.txt"
  printf '%s' "$OPT_REASON" >"$FM_TMP/reason.txt"
  : >"$FM_TMP/refs.txt"
  if [ "$OPT_CODE_REFS_SET" -eq 1 ]; then
    printf '%s\n' "${OPT_CODE_REFS[@]+"${OPT_CODE_REFS[@]}"}" >"$FM_TMP/refs.txt"
    setrefs=true
  fi
  [ "$OPT_PR_SET" -eq 0 ] || setpr=true
  [ "$OPT_REASON_SET" -eq 0 ] || setreason=true

  fm_begin_write
  sf_jq --indent 2 -s --arg id "$id" --arg status "$status" \
    --argjson setpr "$setpr" --rawfile pr "$FM_TMP/pr.txt" \
    --argjson setreason "$setreason" --rawfile reason "$FM_TMP/reason.txt" \
    --argjson setrefs "$setrefs" --rawfile refs_text "$FM_TMP/refs.txt" \
    -f "$FM_TMP/mark.jq" "$FM_FILE" >"$FM_PENDING" 2>"$FM_TMP/jq.err" || rc=$?
  case "$rc" in
    0) ;;
    4) sf_die "no feature $id in $FM_SRC" ;;
    *) sf_die "internal error: could not update $FM_SRC: $(fm_jq_error)" ;;
  esac

  FMV_RULES=true
  fm_check "$FM_PENDING"
  if [ -n "$FM_PROBLEMS" ]; then
    fm_report "$FM_PROBLEMS"
    sf_log "not written: marking $id $status would make the map invalid"
    exit 1
  fi
  fm_commit_write
  sf_log "$id: marked $status"
}

cmd_check_tests() {
  local id n k tag files rc=0 globs g missing="" specs=() nspecs=0
  fm_expect_id_arg 1 "one feature ID"
  id="${FM_ARGS[0]}"
  [ -n "$SF_CONFIG_FILE" ] || sf_config_load # an explicit --config is already loaded (main)
  # A missing key, or one whose items are all commented out, dies here (2). The globs are the
  # list items, or the value when it is one scalar glob.
  sf_cfg_require_globs gate.test_globs
  globs=$(sf_cfg_globs gate.test_globs)
  while IFS= read -r g; do
    if [ -n "$g" ]; then
      specs+=(":(glob)$g")
      nspecs=$((nspecs + 1))
    fi
  done <<EOF
$globs
EOF
  # "none" (no test files) passes sf_cfg_require_globs, but this check needs test files.
  [ "$nspecs" -gt 0 ] ||
    sf_die "$SF_CONFIG_FILE: gate.test_globs is empty or none, so no test can be found; check-tests needs test files"
  fm_tree
  fm_read_valid
  n=$(sf_jq -r -s --arg id "$id" -f "$FM_TMP/criteria.jq" "$FM_FILE" 2>"$FM_TMP/jq.err") || rc=$?
  case "$rc" in
    0) ;;
    4) sf_die "no feature $id in $FM_SRC" ;;
    *) sf_die "internal error: could not read the criteria of $id: $(fm_jq_error)" ;;
  esac

  k=1
  while [ "$k" -le "$n" ]; do
    tag="$id-ac$k"
    if files=$(git -C "$FM_TREE" grep -lw -E "$tag" -- "${specs[@]}" 2>"$FM_TMP/grep.err"); then
      sf_log "$tag: ${files%%"$FM_NL"*}"
    else
      rc=$?
      [ "$rc" -eq 1 ] || sf_die "git grep failed in $FM_TREE: $(head -n 1 "$FM_TMP/grep.err" | tr -d '\r')"
      missing="$missing$tag$FM_NL"
    fi
    k=$((k + 1))
  done
  if [ -n "$missing" ]; then
    printf '%s' "$missing"
    sf_log "$id: acceptance criteria without a tagged test in gate.test_globs: $(printf '%s' "$missing" | tr '\n' ' ')"
    exit 1
  fi
  sf_log "$id: all $n acceptance criteria have a tagged test"
}

cmd_list() {
  local claims="[]" live=false json=false
  fm_expect_no_args
  fm_read_valid
  if [ "$OPT_LIVE" -eq 1 ]; then
    claims=$(fm_claims_json)
    live=true
  fi
  [ "$OPT_JSON" -eq 0 ] || json=true
  sf_jq -r -s --argjson claims "$claims" --argjson live "$live" --argjson json "$json" \
    -f "$FM_TMP/list.jq" "$FM_FILE" || sf_die "internal error: could not list $FM_SRC"
}

cmd_fmt() {
  local reason rc=0
  fm_expect_no_args
  fm_load
  FMV_RULES=false
  fm_check "$FM_FILE"
  if [ -n "$FM_PROBLEMS" ]; then
    if [ "$OPT_CHECK" -eq 1 ]; then
      fm_report "$FM_PROBLEMS"
      exit 1
    fi
    sf_die "cannot format $FM_SRC: ${FM_PROBLEMS#map: }"
  fi
  reason=$(fm_format_reason "$FM_FILE") || rc=$?
  case "$rc" in
    0) ;;
    1) return 0 ;;
    *) sf_die "internal error: $reason" ;;
  esac
  if [ "$OPT_CHECK" -eq 1 ]; then
    printf '%s: map: %s\n' "$SF_PROG" "$reason" >&2
    exit 1
  fi
  fm_begin_write
  cp "$FM_TMP/canon.json" "$FM_PENDING" || sf_die "could not write $FM_PENDING"
  fm_commit_write
  sf_log "formatted $FM_MAP"
}

# add --from FILE: append the complete new entries in FILE (a JSON array), in order. The map is
# written (canonical, atomically) only when the result is valid; an id the map already has is
# a problem, so add never changes an existing entry.
cmd_add() {
  local from rc=0 problems added
  fm_expect_no_args
  [ -n "$OPT_FROM" ] || fm_usage_die "add: --from FILE is required"
  from=$(fm_safe_path "$OPT_FROM")
  [ -f "$from" ] || sf_die "input file not found: $OPT_FROM"
  fm_load
  # Snapshots, so every step below reads the same bytes even if a file changes meanwhile.
  cp "$from" "$FM_TMP/input.json" || sf_die "could not read $OPT_FROM"
  cp "$FM_FILE" "$FM_TMP/map.json" || sf_die "could not read $FM_SRC"
  fm_clean_bytes "$FM_TMP/map.json" || rc=$?
  [ "$rc" -ne 1 ] || sf_die "$FM_SRC is not valid JSON: it holds a NUL or Ctrl-Z byte"
  [ "$rc" -eq 0 ] || sf_die "could not read $FM_SRC"
  FMV_RULES=false
  fm_check "$FM_TMP/map.json"
  [ -z "$FM_PROBLEMS" ] || sf_die "$FM_SRC is not valid JSON: ${FM_PROBLEMS#map: invalid JSON: }"

  fm_clean_bytes "$FM_TMP/input.json" || rc=$?
  [ "$rc" -le 1 ] || sf_die "could not read $OPT_FROM"
  if [ "$rc" -eq 1 ]; then
    problems="input: invalid JSON: the file holds a NUL or Ctrl-Z byte (JSON must be UTF-8 text)"
  else
    problems=$(sf_jq -r -s --slurpfile map "$FM_TMP/map.json" -f "$FM_TMP/add-check.jq" \
      "$FM_TMP/input.json" 2>"$FM_TMP/jq.err") || rc=$?
    if [ "$rc" -ne 0 ]; then
      fm_is_parse_error || sf_die "internal error: could not check the new features: $(fm_jq_error)"
      problems="input: invalid JSON: $(fm_jq_error)"
    fi
  fi
  if [ -n "$problems" ]; then
    fm_report "$problems"
    sf_log "not written: the features in $OPT_FROM cannot be added to $FM_SRC"
    exit 1
  fi

  fm_begin_write
  sf_jq --indent 2 -s --slurpfile new "$FM_TMP/input.json" -f "$FM_TMP/add-merge.jq" \
    "$FM_TMP/map.json" >"$FM_PENDING" 2>"$FM_TMP/jq.err" ||
    sf_die "internal error: could not update $FM_SRC: $(fm_jq_error)"
  # The written map is judged as validate judges it, whatever the checks above found.
  FMV_RULES=true
  fm_check "$FM_PENDING"
  if [ -n "$FM_PROBLEMS" ]; then
    fm_report "$FM_PROBLEMS"
    sf_log "not written: the features in $OPT_FROM cannot be added to $FM_SRC"
    exit 1
  fi
  added=$(sf_jq -r '[.[].id] | join(" ")' "$FM_TMP/input.json") ||
    sf_die "internal error: could not read the ids in $OPT_FROM"
  fm_commit_write
  if [ -n "$added" ]; then
    sf_log "added $added"
  else
    sf_log "nothing to add: $OPT_FROM holds no features"
  fi
}

# show ID: the feature's whole entry as canonical JSON (jq --indent 2, LF, trailing newline).
cmd_show() {
  local id rc=0
  fm_expect_id_arg 1 "one feature ID"
  id="${FM_ARGS[0]}"
  fm_read_valid
  sf_jq --indent 2 -s --arg id "$id" -f "$FM_TMP/show.jq" "$FM_FILE" >"$FM_TMP/show.json" \
    2>"$FM_TMP/jq.err" || rc=$?
  case "$rc" in
    0) cat "$FM_TMP/show.json" ;;
    4) sf_die "no feature $id in $FM_SRC" ;;
    *) sf_die "internal error: could not read $id from $FM_SRC: $(fm_jq_error)" ;;
  esac
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

FM_CMD="${1:-}"
case "$FM_CMD" in
  -h | --help | help) usage; exit 0 ;;
  validate | next | context | mark | check-tests | list | fmt | add | show) shift ;;
  '') usage >&2; exit 2 ;;
  *) fm_usage_die "unknown subcommand '$FM_CMD'" ;;
esac
fm_parse_args "$@"
# An explicit --config is always read, so a missing or broken file fails closed (exit 2)
# even in subcommands that use no config key. Without --config, only check-tests reads it.
if [ -n "$OPT_CONFIG" ]; then sf_config_load "$(fm_safe_path "$OPT_CONFIG")"; fi

FM_TMP=$(sf_mktemp_dir) || sf_die "cannot create a temporary directory"
trap fm_cleanup EXIT
fm_write_programs

case "$FM_CMD" in
  validate) cmd_validate ;;
  next) cmd_next ;;
  context) cmd_context ;;
  mark) cmd_mark ;;
  check-tests) cmd_check_tests ;;
  list) cmd_list ;;
  fmt) cmd_fmt ;;
  add) cmd_add ;;
  show) cmd_show ;;
esac
