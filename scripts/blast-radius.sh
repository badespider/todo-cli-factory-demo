#!/usr/bin/env bash
# Blast radius of a change: files, symbols, dependents, affected tests, approval classes. Contract: docs/CONTRACTS.md, "blast-radius.sh".
set -euo pipefail
SF_PROG=blast-radius
# shellcheck source=scripts/lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
# shellcheck source=scripts/lib/jq.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/jq.sh"
# shellcheck source=scripts/lib/config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"

usage() {
  cat <<'EOF'
Usage: blast-radius.sh --base REF [--head REF] [--tree DIR] [--feature ID] [--run-tests]
                       [--json] [--fail-on CLASS]... [--config FILE] [--map FILE]

Reports what the change base...head touches: changed files, symbols, dependent files,
affected tests and the classes that need operator approval (needs_approval).

  --base REF       compare from the merge base of REF and head (required)
  --head REF       head of the change (default: HEAD of the tree)
  --tree DIR       tree under test (default: the current repo root)
  --feature ID     also list changed files outside the feature's "files" globs
  --map FILE       feature map (default: <tree>/factory/feature-map.json, or FACTORY_MAP)
  --config FILE    config (default: FACTORY_CONFIG, else the judging copy's factory.config.yaml)
  --run-tests      run gate.test_files on the affected tests (gate.test when it is none),
                   in the tree as checked out, after the report and the --fail-on classes
                   are decided; without credential-like environment variables, and with a
                   new, empty HOME, TMPDIR, XDG_CONFIG_HOME and GH_CONFIG_DIR
  --json           print one JSON document instead of the text report
  --fail-on CLASS  exit 1 when CLASS is present; repeatable. CLASS is rules-change,
                   protected, test-removed or out-of-scope (needs --feature)
  -h, --help       show this help

Globs (gate.test_globs, merge.protected_paths, a feature's files) use git pathspec glob
semantics, so they match the same paths on every OS.

Exit: 0 done; 1 tests failed or a --fail-on class is present; 2 usage or config error.
EOF
}

BR_TAB=$(printf '\t')
BR_NL='
'
BR_SYMBOL_CAP=200
BR_MAP_PATH=factory/feature-map.json

BR_TREE=""
BR_WORK=""
BR_BASE=""
BR_HEAD=""
BR_MB=""
BR_EMPTY_BLOB=""
# The pinned bash and env the affected tests run with, by their paths (set with --run-tests).
BR_BASH=""
BR_ENV=""
# Newline-wrapped sets ("\na\nb\n") of this change's own paths; see br_in_set. Lookups scan
# the whole string, so the dependents (possibly tens of thousands) are never put in them.
BR_CANDIDATE_SET=$BR_NL
BR_TEST_SET=$BR_NL
BR_PROTECTED_SET=$BR_NL

# These would change how every glob below matches (GIT_LITERAL_PATHSPECS turns :(glob) off,
# so nothing would be protected or a test). The globs mean the same thing for every caller.
unset GIT_LITERAL_PATHSPECS GIT_GLOB_PATHSPECS GIT_NOGLOB_PATHSPECS GIT_ICASE_PATHSPECS

# Symbol extraction from `git diff -U0` (POSIX awk). Language-agnostic heuristics:
#  - definition lines: optional modifiers, then function|def|class|func|fn|sub|const|let|var|
#    interface|type|struct|enum NAME; also Go methods "func (r T) NAME" and "NAME() {"
#    (shell functions, class methods);
#  - hunk header context: the same, else a C-style "type NAME(" (something must precede NAME,
#    so plain calls such as describe(...) are not taken for definitions).
# Run with $SF_AWK so the tests can check it under gawk --posix.
# shellcheck disable=SC2016 # an awk program, not shell
BR_SYMBOL_AWK='
BEGIN {
  n = split("if for while switch catch return sizeof elif foreach with until unless when match and or not in is new delete typeof await yield throw case else do try function def class func fn sub const let var interface type struct enum", w, " ")
  for (i = 1; i <= n; i++) stop[w[i]] = 1
}
function emit(name) {
  if (length(name) < 2 || (name in stop) || (name in seen)) return
  seen[name] = 1
  print name
}
function defname(s,    t) {
  t = s
  sub(/^[ \t]+/, "", t)
  while (match(t, /^(export|default|public|private|protected|internal|static|async|abstract|final|declare|readonly|unsafe|extern|inline|override|virtual|sealed|partial|local|pub|pub\([a-z]+\))[ \t]+/))
    t = substr(t, RLENGTH + 1)
  if (match(t, /^func[ \t]*\([^)]*\)[ \t]*[A-Za-z_][A-Za-z0-9_]*/)) {
    t = substr(t, 1, RLENGTH)
    sub(/^func[ \t]*\([^)]*\)[ \t]*/, "", t)
    return t
  }
  if (match(t, /^(function|def|class|func|fn|sub|const|let|var|interface|type|struct|enum)[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) {
    t = substr(t, 1, RLENGTH)
    sub(/^[a-z]+[ \t]+/, "", t)
    return t
  }
  if (match(t, /^[A-Za-z_][A-Za-z0-9_]*[ \t]*\(\)[ \t]*\{/)) {
    t = substr(t, 1, RLENGTH)
    sub(/[ \t]*\(.*$/, "", t)
    return t
  }
  return ""
}
function ctxname(s,    name, pre, last) {
  name = defname(s)
  if (name != "") return name
  if (!match(s, /[A-Za-z_][A-Za-z0-9_]*[ \t]*\(/)) return ""
  name = substr(s, RSTART, RLENGTH)
  sub(/[ \t]*\($/, "", name)
  pre = substr(s, 1, RSTART - 1)
  sub(/[ \t]+$/, "", pre)
  if (pre == "") return ""
  last = substr(pre, length(pre), 1)
  if (last !~ /[]A-Za-z0-9_>*&:]/) return ""
  if (match(pre, /[A-Za-z_][A-Za-z0-9_]*$/) && (substr(pre, RSTART) in stop)) return ""
  return name
}
/^diff --git / { inhunk = 0; next }
/^@@ / {
  inhunk = 1
  ctx = $0
  if (sub(/^@@ [^@]*@@/, "", ctx)) emit(ctxname(ctx))
  next
}
inhunk && /^[-+]/ { emit(defname(substr($0, 2))) }
'

br_git() { git -C "$BR_TREE" -c core.quotepath=false "$@"; }

# br_resolve REF: full commit id of REF in the tree; dies (2) when it is not a commit.
br_resolve() {
  case "$1" in -* | '') sf_die "invalid ref '$1'" ;; esac
  br_git rev-parse --verify --quiet "$1^{commit}" || sf_die "not a commit in $BR_TREE: $1"
}

# Paths travel as TAB-separated lines; refuse (fail closed) rather than misread one.
br_check_path() {
  case "$1" in
    '') sf_die "empty path in git diff output" ;;
    *"$BR_TAB"* | *"$BR_NL"*) sf_die "a changed path contains a tab or newline; refusing to classify it: $(printf '%q' "$1")" ;;
  esac
}

# br_in_set SET PATH: PATH is a member of the newline-wrapped SET (always case-sensitive).
br_in_set() {
  local found=1 nocase=0
  if shopt -q nocasematch; then
    nocase=1
    shopt -u nocasematch
  fi
  case "$1" in *"$BR_NL$2$BR_NL"*) found=0 ;; esac
  if [ "$nocase" -eq 1 ]; then shopt -s nocasematch; fi
  return "$found"
}

# br_load_set VAR FILE: VAR becomes the newline-wrapped set of FILE's lines (one read, not
# one string copy per line, which was quadratic).
br_load_set() {
  local s
  s=$(cat "$2") || sf_die "could not read $2"
  printf -v "$1" '%s' "$BR_NL$s${s:+$BR_NL}"
}

# br_keep_listed LIST FILE: the lines of FILE that are also lines of LIST, in FILE's order.
br_keep_listed() {
  LC_ALL=C awk 'FILENAME == ARGV[1] { keep[$0] = 1; next } $0 in keep' "$1" "$2"
}

# br_list_changes: $BR_WORK/changes = STATUS<TAB>PATH lines sorted by path. A rename becomes
# "R new" plus "D old"; a copy (only seen with diff.renames=copies) becomes "A new".
br_list_changes() {
  local raw="$BR_WORK/name-status.z" status path old
  br_git diff --name-status -z -M --no-color --no-ext-diff "$BR_MB" "$BR_HEAD" >"$raw" ||
    sf_die "git diff --name-status failed"
  while IFS= read -r -d '' status; do
    case "$status" in
      R* | C*)
        IFS= read -r -d '' old || sf_die "truncated git diff output"
        IFS= read -r -d '' path || sf_die "truncated git diff output"
        br_check_path "$old"
        br_check_path "$path"
        case "$status" in
          R*) printf 'R\t%s\nD\t%s\n' "$path" "$old" ;;
          *) printf 'A\t%s\n' "$path" ;;
        esac
        ;;
      *)
        IFS= read -r -d '' path || sf_die "truncated git diff output"
        br_check_path "$path"
        printf '%s\t%s\n' "${status:0:1}" "$path"
        ;;
    esac
  done <"$raw" >"$BR_WORK/changes.unsorted"
  LC_ALL=C sort -t "$BR_TAB" -k2,2 -k1,1 "$BR_WORK/changes.unsorted" >"$BR_WORK/changes"
}

# br_numstat MODE OUT: OUT = PATH<TAB>ADDED<TAB>DELETED ("-" for binary). MODE is -M (a rename
# is keyed by its new path) or --no-renames (both halves of a rename appear on their own).
br_numstat() {
  local raw="$BR_WORK/numstat.z" rec rest added deleted path old
  br_git diff --numstat -z "$1" --no-color --no-ext-diff --no-textconv "$BR_MB" "$BR_HEAD" >"$raw" ||
    sf_die "git diff --numstat failed"
  while IFS= read -r -d '' rec; do
    added=${rec%%"$BR_TAB"*}
    rest=${rec#*"$BR_TAB"}
    deleted=${rest%%"$BR_TAB"*}
    path=${rest#*"$BR_TAB"}
    if [ -z "$path" ]; then
      IFS= read -r -d '' old || sf_die "truncated git diff output"
      IFS= read -r -d '' path || sf_die "truncated git diff output"
    fi
    printf '%s\t%s\t%s\n' "$path" "$added" "$deleted"
  done <"$raw" >"$2"
}

# br_approval_input: $BR_WORK/approval-input = STATUS<TAB>PATH<TAB>ADDED<TAB>DELETED, the
# needs_approval input. The D half of a rename gets the old file's own counts.
br_approval_input() {
  br_numstat -M "$BR_WORK/numstat.renames"
  br_numstat --no-renames "$BR_WORK/numstat.plain"
  LC_ALL=C awk -F '\t' -v OFS='\t' '
    FILENAME == ARGV[1] { r[$1] = $2 OFS $3; next }
    FILENAME == ARGV[2] { p[$1] = $2 OFS $3; next }
    {
      if ($1 == "D" && ($2 in p)) c = p[$2]
      else if ($2 in r) c = r[$2]
      else if ($2 in p) c = p[$2]
      else c = "-" OFS "-"
      print $1, $2, c
    }' "$BR_WORK/numstat.renames" "$BR_WORK/numstat.plain" "$BR_WORK/changes" >"$BR_WORK/approval-input"
}

# br_symbols: $BR_WORK/symbols, sorted, capped at BR_SYMBOL_CAP.
br_symbols() {
  local all="$BR_WORK/symbols.all" n
  br_git diff -U0 -M --no-color --no-ext-diff --no-textconv "$BR_MB" "$BR_HEAD" >"$BR_WORK/diff.u0" ||
    sf_die "git diff -U0 failed"
  LC_ALL=C "$SF_AWK" "$BR_SYMBOL_AWK" "$BR_WORK/diff.u0" >"$all.unsorted"
  LC_ALL=C sort -u "$all.unsorted" >"$all"
  n=$(wc -l <"$all" | tr -d ' ')
  if [ "$n" -gt "$BR_SYMBOL_CAP" ]; then
    sf_log "symbols capped at $BR_SYMBOL_CAP of $n (sorted; the rest are not searched for dependents)"
    head -n "$BR_SYMBOL_CAP" "$all" >"$BR_WORK/symbols"
  else
    cp "$all" "$BR_WORK/symbols"
  fi
}

# br_dependents: $BR_WORK/dependents = files at head, outside the diff, containing a symbol or
# a changed file's basename without its extension as a whole word.
br_dependents() {
  local terms="$BR_WORK/terms" raw="$BR_WORK/grep.z" status path base rc=0 p
  cp "$BR_WORK/symbols" "$terms.unsorted"
  while IFS="$BR_TAB" read -r status path; do
    base=${path##*/}
    if [ -n "${base%.*}" ]; then base=${base%.*}; fi
    printf '%s\n' "$base"
  done <"$BR_WORK/changes" >>"$terms.unsorted"
  LC_ALL=C sort -u "$terms.unsorted" | LC_ALL=C awk 'length($0) > 0' >"$terms"
  : >"$raw"
  if [ -s "$terms" ]; then
    br_git grep -l -z -w -F -I --no-color -f "$terms" "$BR_HEAD" -- >"$raw" || rc=$?
    [ "$rc" -le 1 ] || sf_die "git grep failed (exit $rc)"
  fi
  # NUL-separated "<head>:<path>" records, turned into lines in bulk (the list can be huge, and
  # bash reads NUL-separated input one byte per system call). A line without the "<head>:"
  # prefix continues a name that holds a newline; such names, and names with a tab, can't
  # travel in the line-based lists below and are skipped.
  tr '\0' '\n' <"$raw" >"$BR_WORK/grep.lines"
  LC_ALL=C awk -F '\t' -v pre="$BR_HEAD:" '
    function flush() {
      if (!have) return
      if (bad || index(cur, "\t") > 0) print "S\t" cur
      else if (!(cur in changed)) print "P\t" cur
      have = 0
    }
    FILENAME == ARGV[1] { changed[$2] = 1; next }
    index($0, pre) == 1 { flush(); cur = substr($0, length(pre) + 1); have = 1; bad = 0; next }
    { cur = cur "\\n" $0; bad = 1 }
    END { flush() }' "$BR_WORK/changes" "$BR_WORK/grep.lines" >"$BR_WORK/grep.tagged"
  LC_ALL=C awk -F '\t' '$1 == "P" { print substr($0, 3) }' "$BR_WORK/grep.tagged" >"$BR_WORK/dependents"
  LC_ALL=C awk -F '\t' '$1 == "S" { print substr($0, 3) }' "$BR_WORK/grep.tagged" >"$BR_WORK/grep.skipped"
  while IFS= read -r p; do
    sf_warn "skipping a dependent whose name contains a tab or newline: $(printf '%q' "$p")"
  done <"$BR_WORK/grep.skipped"
}

# br_fake_index FILE < PATHS: a throwaway index at FILE listing PATHS (as empty blobs). git
# then matches pathspecs against exactly these paths, the way it would against a real tree.
# The tree's own index and work tree are never touched. Records are NUL-terminated (-z):
# line-based --index-info reads a path that starts with '"' as C-quoted, so '"x".spec.js'
# would be matched as 'x' (and '"x' would be a fatal error). PATHS never hold a newline.
br_fake_index() {
  rm -f "$1"
  if [ -z "$BR_EMPTY_BLOB" ]; then
    BR_EMPTY_BLOB=$(br_git hash-object -t blob --stdin </dev/null) || sf_die "git hash-object failed"
  fi
  LC_ALL=C awk -v b="$BR_EMPTY_BLOB" '$0 != "" { printf "100644 %s\t%s\n", b, $0 }' | tr '\n' '\0' |
    GIT_INDEX_FILE="$1" git -C "$BR_TREE" -c core.protectNTFS=false -c core.protectHFS=false \
      update-index -z --add --index-info ||
    sf_die "could not build the path-matching index"
}

# br_matching MAGIC GLOBFILE INDEX...: paths in the INDEXes matched by any glob in GLOBFILE,
# as git pathspecs ":(MAGIC)glob". A leading "/" or "./" is dropped: pathspecs are rooted
# at the top of the tree already.
br_matching() {
  local magic=$1 globs=$2 g n=0 idx
  local specs=()
  shift 2
  while IFS= read -r g || [ -n "$g" ]; do
    g=${g#./}
    while [ "${g#/}" != "$g" ]; do g=${g#/}; done
    [ -n "$g" ] || continue
    specs+=(":($magic)$g")
    n=$((n + 1))
  done <"$globs"
  [ "$n" -gt 0 ] || return 0
  for idx in "$@"; do
    [ -f "$idx" ] || continue
    GIT_INDEX_FILE="$idx" git -C "$BR_TREE" -c core.quotepath=false ls-files -z -- "${specs[@]}" >"$BR_WORK/ls.z" ||
      sf_die "git ls-files failed while matching the globs in $globs"
    tr '\0' '\n' <"$BR_WORK/ls.z"
  done
}

# br_path_matches SET MAGIC GLOBFILE PATH: PATH matches a glob. Paths of this change are looked
# up in the precomputed SET; any other path is matched on its own.
br_path_matches() {
  local out
  if br_in_set "$BR_CANDIDATE_SET" "$4"; then
    br_in_set "$1" "$4"
    return
  fi
  case "$4" in '' | *"$BR_TAB"* | *"$BR_NL"*) return 1 ;; esac
  if ! printf '%s\n' "$4" | br_fake_index "$BR_WORK/one.index"; then
    sf_die "could not match path: $4"
  fi
  out=$(br_matching "$2" "$3" "$BR_WORK/one.index") || sf_die "could not match path: $4"
  [ -n "$out" ]
}

# Helpers for needs_approval (and anything else that classifies paths).
# is_test_path PATH: PATH matches gate.test_globs.
is_test_path() { br_path_matches "$BR_TEST_SET" glob "$BR_WORK/globs.test" "$1"; }
# is_protected_path PATH: PATH matches merge.protected_paths, ignoring case (on a
# case-insensitive checkout PACKAGE.JSON and package.json are the same file).
is_protected_path() { br_path_matches "$BR_PROTECTED_SET" glob,icase "$BR_WORK/globs.protected" "$1"; }

# ---- USER CONTRIBUTION POINT: needs_approval ----
# Decides which changed paths need an operator's "approve <full head sha>" comment before
# ship.sh merges (rules-change), or are reported for --fail-on (every class).
# The trade-off: too strict, and standing agents stall on approvals for routine work; too
# loose, and agents loosen the checks that judge them (ISF: 7 of the 40 CI PRs agents wrote
# loosened checks). A needless approval costs a minute; a loosened check costs every merge
# after it, so when in doubt, classify.
#
# stdin:  STATUS<TAB>PATH<TAB>ADDED<TAB>DELETED per changed path. STATUS is one letter from
#         git diff --name-status (A, M, D, T, ...); a rename arrives as R (new path) plus
#         D (old path). ADDED/DELETED are --numstat line counts, "-" for binary files.
# stdout: CLASS<TAB>PATH lines.
# Helpers: is_test_path PATH, is_protected_path PATH (git pathspec globs from the config).
needs_approval() {
  local status path added deleted
  while IFS="$BR_TAB" read -r status path added deleted; do
    [ -n "$path" ] || continue
    # The factory's own rules (PLAN §4.5). Case-insensitive, so that Scripts/x cannot stand
    # in for scripts/x on a case-insensitive checkout.
    shopt -s nocasematch
    case "$path" in
      .github/* | scripts/* | skills/* | templates/* | AGENTS.md | CLAUDE.md | \
        .gemini/* | .claude/* | .cursor/* | .codex/* | .agents/* | factory.config.yaml | \
        factory/harness/* | factory/feature-map.schema.json)
        printf 'rules-change\t%s\n' "$path"
        ;;
    esac
    shopt -u nocasematch
    if is_protected_path "$path"; then
      printf 'protected\t%s\n' "$path"
    fi
    # Deleting, renaming away or cutting lines from a test can weaken it; adding lines cannot.
    if is_test_path "$path"; then
      case "$status" in
        A | R) ;;
        D) printf 'test-removed\t%s\n' "$path" ;;
        *) if [ "$deleted" != 0 ]; then printf 'test-removed\t%s\n' "$path"; fi ;;
      esac
    fi
  done
}
# ---- end needs_approval ----

# br_feature_globs ID MAP OUT: write the feature's files globs to OUT. Returns 3 when the
# feature declares no files; dies when the map or the feature is missing.
br_feature_globs() {
  local kind
  [ -f "$2" ] || sf_die "feature map not found: $2"
  sf_need jq
  # shellcheck disable=SC2016 # a jq program, not shell
  sf_jq -r --arg id "$1" '
    [.features[]? | select(.id == $id)] as $m
    | if ($m | length) == 0 then "missing"
      elif $m[0].files == null then "nofiles"
      elif ($m[0].files | type) != "array" then "bad"
      else "files", ($m[0].files[] | tostring)
      end' <"$2" >"$BR_WORK/feature.out" || sf_die "could not read the feature map: $2"
  kind=$(head -n 1 "$BR_WORK/feature.out")
  case "$kind" in
    files) tail -n +2 "$BR_WORK/feature.out" >"$3" ;;
    nofiles) return 3 ;;
    missing) sf_die "feature $1 is not in $2" ;;
    *) sf_die "feature $1 has an invalid files field in $2" ;;
  esac
}

# br_visible FILE: FILE's lines with control characters shown as "?". Paths come from the tree
# under test; a raw ESC or CR could repaint or hide lines of a report a person reads.
br_visible() { LC_ALL=C awk '{ gsub(/[[:cntrl:]]/, "?"); print }' "$1"; }

# br_section TITLE FILE: one text-report section.
br_section() {
  local n
  n=$(wc -l <"$2" | tr -d ' ')
  printf '\n%s (%s):\n' "$1" "$n"
  if [ "$n" -eq 0 ]; then
    printf '  (none)\n'
  else
    br_visible "$2" | LC_ALL=C awk '{ print "  " $0 }'
  fi
}

br_print_text() { # FEATURE
  printf 'base: %s\nhead: %s\nmerge base: %s\n' "$BR_BASE" "$BR_HEAD" "$BR_MB"
  LC_ALL=C awk -F '\t' '{ printf "%s  %s\n", $1, $2 }' "$BR_WORK/changes" >"$BR_WORK/show.files"
  br_section files "$BR_WORK/show.files"
  br_section symbols "$BR_WORK/symbols"
  br_section dependents "$BR_WORK/dependents"
  br_section "affected tests" "$BR_WORK/affected"
  LC_ALL=C awk -F '\t' '{ printf "%-13s %s\n", $1, $2 }' "$BR_WORK/classes" >"$BR_WORK/show.classes"
  br_section classes "$BR_WORK/show.classes"
  if [ -n "$1" ]; then br_section "out of scope for $1" "$BR_WORK/out_of_scope"; fi
}

br_print_json() {
  sf_need jq
  # One KIND<TAB>FIELDS... line per item; KIND names the source file.
  LC_ALL=C awk '
    FILENAME == ARGV[1] { k = "F" }
    FILENAME == ARGV[2] { k = "S" }
    FILENAME == ARGV[3] { k = "P" }
    FILENAME == ARGV[4] { k = "T" }
    FILENAME == ARGV[5] { k = "C" }
    FILENAME == ARGV[6] { k = "O" }
    { print k "\t" $0 }' "$BR_WORK/changes" "$BR_WORK/symbols" "$BR_WORK/dependents" \
    "$BR_WORK/affected" "$BR_WORK/classes" "$BR_WORK/out_of_scope" >"$BR_WORK/json.tsv"
  # shellcheck disable=SC2016 # a jq program, not shell
  sf_jq -c -R -s --arg base "$BR_BASE" --arg head "$BR_HEAD" '
    def col(r; k): [r[] | select(.[0] == k) | .[1]];
    [split("\n")[] | select(length > 0) | split("\t")] as $r
    | {base: $base, head: $head,
       files: [$r[] | select(.[0] == "F") | {status: .[1], path: .[2]}],
       symbols: col($r; "S"),
       dependents: col($r; "P"),
       affected_tests: col($r; "T"),
       classes: [$r[] | select(.[0] == "C") | {class: .[1], path: (.[2] // "")}],
       out_of_scope: col($r; "O")}' <"$BR_WORK/json.tsv" || sf_die "jq failed while writing the report"
}

# br_fill_files TEMPLATE FILES: TEMPLATE with every "{files}" replaced by FILES.
br_fill_files() {
  local rest=$1 out=""
  while :; do
    case "$rest" in
      *"{files}"*)
        out="$out${rest%%"{files}"*}$2"
        rest=${rest#*"{files}"}
        ;;
      *) break ;;
    esac
  done
  printf '%s' "$out$rest"
}

# br_run_tests JSON: run the affected tests; the PASS|FAIL|SKIP line goes to stdout in the
# text report and to stderr with --json. Returns 1 when the tests fail.
br_run_tests() {
  local json=$1 tf t cmd files="" p q started rc=0 line d names n
  local -a drop=()
  tf=$(sf_cfg gate.test_files none)
  t=$(sf_cfg gate.test none)
  if sf_is_none "$tf" && sf_is_none "$t"; then
    sf_log "run-tests: gate.test_files and gate.test are none"
    line="SKIP affected-tests (0s)"
  elif [ ! -s "$BR_WORK/affected" ]; then
    sf_log "run-tests: no affected tests"
    line="SKIP affected-tests (0s)"
  else
    if ! sf_is_none "$tf"; then
      # Paths come from the tree under test: quote each one so a hostile file name stays data.
      while IFS= read -r p; do
        printf -v q '%q' "$p"
        files="$files${files:+ }$q"
      done <"$BR_WORK/affected"
      cmd=$(br_fill_files "$tf" "$files")
    else
      cmd=$t
    fi
    # The tests are the change's own code: they run through sf_scrubbed (no exported entry
    # whose name looks like a credential). sf_scrubbed lists the names again as it starts
    # them and can't report that this listing failed (it would then remove nothing), so they
    # are listed here first: a failure is an error (2), never unscrubbed tests or a failing
    # test (1). The names found here are removed as well, by a second env (by its pinned
    # path), so a listing that fails inside sf_scrubbed still hands on none of them.
    names=$(sf_credential_names) || sf_die "could not read the environment"
    while IFS= read -r n; do
      if [ -n "$n" ]; then drop+=(-u "$n"); fi
    done <<EOF
$names
EOF
    # And a new, empty HOME, TMPDIR, XDG_CONFIG_HOME and GH_CONFIG_DIR, removed after them, so
    # the runner's own config, gh login and caches stay out of their reach.
    if ! { d=$(mktemp -d "$BR_WORK/run.XXXXXX") && mkdir "$d/home" "$d/tmp" "$d/config" "$d/gh"; }; then
      sf_die "could not make a fresh HOME and TMPDIR for the tests"
    fi
    sf_log "run-tests: $cmd"
    started=$(date +%s)
    # env (in sf_scrubbed) looks its command up in PATH: env and bash run by their pinned paths.
    (cd "$BR_TREE" && sf_scrubbed "$BR_ENV" ${drop[@]+"${drop[@]}"} HOME="$d/home" TMPDIR="$d/tmp" \
      XDG_CONFIG_HOME="$d/config" GH_CONFIG_DIR="$d/gh" "$BR_BASH" -c "$cmd") </dev/null 1>&2 || rc=$?
    rm -rf "$d" 2>/dev/null || true
    # 125: sf_scrubbed refused to start the tests (it could not list the credential names).
    # They never ran, so this is "could not decide", never a failing test. A test command that
    # itself exits 125 is reported the same way: an error, which never passes the gate either.
    if [ "$rc" -eq 125 ]; then
      sf_die "run-tests: the affected tests could not be started scrubbed; nothing ran"
    fi
    if [ "$rc" -eq 0 ]; then
      line="PASS affected-tests ($(($(date +%s) - started))s)"
    else
      line="FAIL affected-tests ($(($(date +%s) - started))s)"
      sf_log "run-tests: exit $rc"
    fi
  fi
  if [ "$json" -eq 1 ]; then
    printf '%s\n' "$line" >&2
  else
    printf '\n%s\n' "$line"
  fi
  [ "$rc" -eq 0 ]
}

main() {
  local base="" head=HEAD tree="" feature="" config="" map="${FACTORY_MAP:-}"
  local run_tests=0 json=0 rc=0 frc=0 c path
  local fail_on=() hits=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h | --help)
        usage
        exit 0
        ;;
      --base | --head | --tree | --feature | --config | --map | --fail-on)
        [ "$#" -ge 2 ] || sf_die "$1 needs a value (see --help)"
        case "$1" in
          --base) base=$2 ;;
          --head) head=$2 ;;
          --tree) tree=$2 ;;
          --feature) feature=$2 ;;
          --config) config=$2 ;;
          --map) map=$2 ;;
          --fail-on) fail_on+=("$2") ;;
        esac
        shift 2
        ;;
      --run-tests)
        run_tests=1
        shift
        ;;
      --json)
        json=1
        shift
        ;;
      *) sf_die "unknown argument: $1 (see --help)" ;;
    esac
  done
  [ -n "$base" ] || sf_die "--base REF is required (see --help)"
  if [ -n "$feature" ]; then
    case "$feature" in
      F[0-9]*) case "${feature#F}" in *[!0-9]*) sf_die "invalid feature id '$feature' (expected F<n>)" ;; esac ;;
      *) sf_die "invalid feature id '$feature' (expected F<n>)" ;;
    esac
  fi
  for c in ${fail_on[@]+"${fail_on[@]}"}; do
    case "$c" in
      rules-change | protected | test-removed) ;;
      out-of-scope) [ -n "$feature" ] || sf_die "--fail-on out-of-scope needs --feature ID" ;;
      *) sf_die "--fail-on: unknown class '$c' (rules-change, protected, test-removed, out-of-scope)" ;;
    esac
  done

  sf_need git
  # Pin the tools this shell uses once --run-tests has run the project's tests: they can put
  # an executable named awk, cp or git in a PATH directory they can write to (~/.local/bin,
  # say) and so change the classes or the exit code. bash looks a hashed name up in its
  # table, never in PATH again, and subshells inherit the table. The ones --run-tests needs
  # (to start the tests, and after them) must exist now: a name hash could not find would be
  # looked up in PATH again later. The rest are pinned when present.
  if [ "$run_tests" -eq 1 ]; then
    sf_need bash env awk sort mktemp mkdir rm date
    hash bash env awk sort mktemp mkdir rm date || sf_die "could not look up the tools --run-tests needs"
    BR_BASH=$(hash -t bash) || sf_die "required command not found: bash"
    BR_ENV=$(hash -t env) || sf_die "required command not found: env"
  fi
  hash bash git jq gh awk sed tr head tail cat cp sort wc date mktemp mkdir rm sleep env cygpath 2>/dev/null || true
  if [ -n "$config" ]; then sf_config_load "$config"; else sf_config_load; fi
  BR_TREE=$(sf_repo_root "${tree:-.}") || exit 2
  BR_BASE=$(br_resolve "$base") || exit 2
  BR_HEAD=$(br_resolve "$head") || exit 2
  BR_MB=$(br_git merge-base "$BR_BASE" "$BR_HEAD") || sf_die "no merge base between $base and $head"
  BR_WORK=$(sf_mktemp_dir) || sf_die "could not create a temp dir"
  trap 'rm -rf "$BR_WORK"' EXIT
  # Absolute (TMPDIR may be relative): --run-tests makes the tests' HOME and TMPDIR in it,
  # and the tests run in the tree.
  c=$(cd "$BR_WORK" && pwd) || sf_die "could not find the temp dir"
  BR_WORK=$c

  br_list_changes
  br_approval_input
  br_symbols
  br_dependents

  # Every path this run classifies: changed paths that exist at head, plus dependents, in one
  # index; deleted paths (which exist at the merge base) in another, so that a file replaced
  # by a directory of the same name never collides.
  LC_ALL=C awk -F '\t' '{ print $2 }' "$BR_WORK/changes" >"$BR_WORK/cand.changed"
  LC_ALL=C awk -F '\t' '$1 == "D" { print $2 }' "$BR_WORK/changes" >"$BR_WORK/cand.base"
  LC_ALL=C awk -F '\t' '$1 != "D" { print $2 }' "$BR_WORK/changes" >"$BR_WORK/cand.head"
  cat "$BR_WORK/dependents" >>"$BR_WORK/cand.head"
  # An empty candidate list gets no index at all (br_matching skips a missing one).
  if [ -s "$BR_WORK/cand.head" ]; then br_fake_index "$BR_WORK/head.index" <"$BR_WORK/cand.head"; fi
  if [ -s "$BR_WORK/cand.base" ]; then br_fake_index "$BR_WORK/base.index" <"$BR_WORK/cand.base"; fi
  br_load_set BR_CANDIDATE_SET "$BR_WORK/cand.changed"

  # Without globs no file would ever be a test, so test-removed could never fire. A missing
  # key or an empty one (every item commented out) fails closed; "none" is the deliberate way.
  # A glob list may also be one scalar glob. protected_paths may be none or missing.
  sf_cfg_require_globs gate.test_globs
  sf_cfg_globs gate.test_globs >"$BR_WORK/globs.test"
  sf_cfg_globs merge.protected_paths >"$BR_WORK/globs.protected"
  br_matching glob "$BR_WORK/globs.test" "$BR_WORK/head.index" "$BR_WORK/base.index" >"$BR_WORK/match.test"
  br_keep_listed "$BR_WORK/match.test" "$BR_WORK/cand.changed" >"$BR_WORK/match.test.changed"
  br_load_set BR_TEST_SET "$BR_WORK/match.test.changed"
  br_matching glob,icase "$BR_WORK/globs.protected" "$BR_WORK/head.index" "$BR_WORK/base.index" >"$BR_WORK/match.protected"
  br_keep_listed "$BR_WORK/match.protected" "$BR_WORK/cand.changed" >"$BR_WORK/match.protected.changed"
  br_load_set BR_PROTECTED_SET "$BR_WORK/match.protected.changed"

  # Affected tests: test-glob files among the changed files that still exist, plus dependents.
  br_keep_listed "$BR_WORK/match.test" "$BR_WORK/cand.head" >"$BR_WORK/affected.unsorted"
  LC_ALL=C sort -u "$BR_WORK/affected.unsorted" >"$BR_WORK/affected"

  if ! needs_approval <"$BR_WORK/approval-input" >"$BR_WORK/classes"; then
    sf_die "needs_approval failed"
  fi

  : >"$BR_WORK/out_of_scope"
  if [ -n "$feature" ]; then
    br_feature_globs "$feature" "${map:-$BR_TREE/$BR_MAP_PATH}" "$BR_WORK/globs.scope" || frc=$?
    if [ "$frc" -eq 3 ]; then
      sf_log "feature $feature declares no files globs; scope not checked"
    else
      br_matching glob "$BR_WORK/globs.scope" "$BR_WORK/head.index" "$BR_WORK/base.index" >"$BR_WORK/match.scope"
      # Out of scope: changed paths that are not in scope, not test files and not the map.
      LC_ALL=C awk -F '\t' -v map="$BR_MAP_PATH" '
        FILENAME == ARGV[1] || FILENAME == ARGV[2] { skip[$0] = 1; next }
        $2 != map && !($2 in skip) { print $2 }' \
        "$BR_WORK/match.scope" "$BR_WORK/match.test" "$BR_WORK/changes" >"$BR_WORK/out_of_scope"
    fi
  fi

  # What --fail-on reports is decided now, in memory, before --run-tests runs the project's
  # tests: they can find $BR_WORK ($TMPDIR/sf.*) and empty the class or scope lists in it.
  for c in ${fail_on[@]+"${fail_on[@]}"}; do
    if [ "$c" = out-of-scope ]; then
      cp "$BR_WORK/out_of_scope" "$BR_WORK/hits"
    else
      LC_ALL=C awk -F '\t' -v c="$c" '$1 == c { print $2 }' "$BR_WORK/classes" >"$BR_WORK/hits"
    fi
    br_visible "$BR_WORK/hits" >"$BR_WORK/hits.shown"
    while IFS= read -r path; do
      hits+=("$c: $path")
    done <"$BR_WORK/hits.shown"
  done

  if [ "$json" -eq 1 ]; then br_print_json; else br_print_text "$feature"; fi

  if [ "$run_tests" -eq 1 ]; then
    br_run_tests "$json" || rc=1
  fi

  for c in ${hits[@]+"${hits[@]}"}; do
    sf_log "fail-on $c"
    rc=1
  done
  return "$rc"
}

# Everything above only defines functions and constants. bash reads a script file as it runs
# it, and --run-tests runs the project's tests, which can write this file (same user;
# SF_FACTORY_ROOT is in their environment). Function bodies are parsed when defined, and this
# last line is parsed whole before main runs, so an in-place rewrite changes nothing.
main "$@"; exit $?
