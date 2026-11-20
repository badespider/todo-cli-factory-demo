#!/usr/bin/env bash
# The perf role's "beyond noise" verdict: is AFTER faster than BEFORE by more than the spread of either? Contract: docs/CONTRACTS.md, "bench-compare.sh".
set -euo pipefail
SF_PROG=bench-compare
# shellcheck source=scripts/lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

usage() {
  cat <<'EOF'
Usage: bench-compare.sh BEFORE AFTER

BEFORE and AFTER are files with one benchmark run per line: one number each, in
seconds or any unit where lower is better. A number is plain decimal digits with an
optional decimal point (12, 0.5, .5, 3.); no sign, exponent or surrounding spaces, and
at most 15 significant digits once both files share one scale.

Bad input (exit 2): a missing or unreadable file, a blank line, a "run failed" line, a
non-number, a carriage return (CRLF line endings), a NUL byte, or fewer than 5 numbers
in either file.

AFTER is a win when its median is lower than BEFORE's median by more than the larger
of the two spreads (max minus min), so overlapping noise never counts as a win. The
comparison is exact decimal arithmetic. Medians of an even count are the mean of the
two middle runs.

Output (stdout; only when both files are valid):
  before median=<m> spread=<s> n=<k>
  after median=<m> spread=<s> n=<k>
  change=<percent>%        AFTER's median against BEFORE's, one decimal, signed
                           (-12.5% is faster; +inf% when BEFORE's median is 0)
The verdict and any input problems go to stderr.

  --          end of options (for a file name that starts with -)
  -h, --help  show this help

Exit: 0 AFTER is faster beyond noise; 1 no win; 2 bad input, usage, or the report could
not be written to stdout.
EOF
}

# The comparison, in POSIX awk. ARGV[1] holds BEFORE's numbers, ARGV[2] AFTER's.
# Every number is turned into an exact integer on one shared decimal scale (10^-D), so
# medians (doubled, to stay whole), spreads and the verdict involve no rounding at all.
# It prints the report on stdout, problems on stderr, and exits 0 win, 1 no win, 2 bad.
# shellcheck disable=SC2016 # an awk program, not shell
BC_AWK='
BEGIN {
  for (i = 1; i < 32; i++) ctl = ctl sprintf("%c", i)
  ctl = ctl sprintf("%c", 127)
  label[1] = "before"; label[2] = "after"
  D = 0
  err = "cat 1>&2"
}
# q(s): s as a JSON string (it is untrusted text), cut to 60 characters.
function q(s,    out, i, c, k) {
  if (length(s) > 60) s = substr(s, 1, 60) "..."
  out = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c == "\\") out = out "\\\\"
    else if (c == "\"") out = out "\\\""
    else if ((k = index(ctl, c)) > 0) out = out sprintf("\\u%04x", k == 32 ? 127 : k)
    else out = out c
  }
  return "\"" out "\""
}
function problem(side, msg) {
  nbad[side]++
  if (nbad[side] <= 5) printf "bench-compare: error: %s: %s\n", label[side], msg | err
}
# fmt(x, d): the non-negative integer x read as x * 10^-d, with exactly d decimals.
function fmt(x, d,    s) {
  s = sprintf("%.0f", x)
  while (length(s) < d + 1) s = "0" s
  if (d == 0) return s
  return substr(s, 1, length(s) - d) "." substr(s, length(s) - d + 1)
}
# show(x2): the doubled non-negative value x2 as a decimal with P decimals.
function show(x2,    r, s) {
  r = x2 % 2
  s = fmt((x2 - r) / 2, D)
  if (P > D) s = s (D == 0 ? "." : "") (r ? "5" : "0")
  return s
}
function hsort(a, n,    i, t, e) {
  for (i = int(n / 2); i >= 1; i--) sift(a, i, n)
  for (e = n; e > 1; e--) { t = a[1]; a[1] = a[e]; a[e] = t; sift(a, 1, e - 1) }
}
function sift(a, i, n,    c, t) {
  while ((c = 2 * i) <= n) {
    if (c < n && a[c + 1] > a[c]) c++
    if (a[i] >= a[c]) return
    t = a[i]; a[i] = a[c]; a[c] = t
    i = c
  }
}
FNR == 1 { side = (FILENAME == ARGV[1]) ? 1 : 2 }
{
  line = $0
  if (line ~ /^[ \t]*$/) { problem(side, "line " FNR " is blank"); next }
  if (tolower(line) ~ /^run failed/) { problem(side, "line " FNR " says the run failed: " q(line)); next }
  if (line !~ /^[0-9]+([.][0-9]*)?$/ && line !~ /^[.][0-9]+$/) {
    problem(side, "line " FNR " is not a number: " q(line))
    next
  }
  dot = index(line, ".")
  if (dot) { ip = substr(line, 1, dot - 1); fp = substr(line, dot + 1) } else { ip = line; fp = "" }
  sub(/0+$/, "", fp)
  n[side]++
  I[side, n[side]] = ip
  F[side, n[side]] = fp
  if (length(fp) > D) D = length(fp)
}
END {
  for (s = 1; s <= 2; s++) {
    if (nbad[s] > 5) printf "bench-compare: error: %s: %d more bad lines\n", label[s], nbad[s] - 5 | err
    if (n[s] + 0 < 5) {
      printf "bench-compare: error: %s: %d number%s; at least 5 runs are needed\n", label[s], n[s] + 0, (n[s] + 0 == 1 ? "" : "s") | err
      nbad[s]++
    }
  }
  if (nbad[1] || nbad[2]) exit 2
  for (s = 1; s <= 2; s++) {
    for (i = 1; i <= n[s]; i++) {
      digits = I[s, i] F[s, i]
      for (k = length(F[s, i]); k < D; k++) digits = digits "0"
      sub(/^0+/, "", digits)
      if (length(digits) > 15) {
        printf "bench-compare: error: %s: run %d has more than 15 significant digits on the shared scale; it cannot be compared exactly\n", label[s], i | err
        exit 2
      }
      if (s == 1) b[i] = digits + 0; else a[i] = digits + 0
    }
  }
  hsort(b, n[1]); hsort(a, n[2])
  m2b = (n[1] % 2) ? 2 * b[(n[1] + 1) / 2] : b[n[1] / 2] + b[n[1] / 2 + 1]
  m2a = (n[2] % 2) ? 2 * a[(n[2] + 1) / 2] : a[n[2] / 2] + a[n[2] / 2 + 1]
  sb = b[n[1]] - b[1]
  sa = a[n[2]] - a[1]
  noise = (sb > sa) ? sb : sa
  P = (m2b % 2 || m2a % 2) ? D + 1 : D
  if (m2b == 0) change = (m2a == 0) ? "0.0" : "+inf"
  else {
    change = sprintf("%+.1f", (m2a - m2b) * 100 / m2b)
    if (change == "+0.0" || change == "-0.0") change = "0.0"
  }
  printf "before median=%s spread=%s n=%d\n", show(m2b), show(2 * sb), n[1]
  printf "after median=%s spread=%s n=%d\n", show(m2a), show(2 * sa), n[2]
  printf "change=%s%%\n", change
  drop = m2b - m2a
  if (drop > 2 * noise) {
    printf "bench-compare: win: the median fell by %s, more than the larger spread %s\n", show(drop), show(2 * noise) | err
    exit 0
  }
  if (drop > 0) printf "bench-compare: no win: the median fell by %s, not more than the larger spread %s\n", show(drop), show(2 * noise) | err
  else if (drop == 0) printf "bench-compare: no win: the medians are equal\n" | err
  else printf "bench-compare: no win: the median rose by %s\n", show(-drop) | err
  exit 1
}
'

BC_TMP=""
# shellcheck disable=SC2329 # invoked by the EXIT trap
bc_cleanup() { if [ -n "$BC_TMP" ]; then rm -rf "$BC_TMP"; fi; }

# bc_copy NAME FILE DEST: copy FILE (which may be a pipe such as <(...)) to DEST, so every
# check below reads the same bytes. Dies (2) when it can't be read.
bc_copy() {
  if [ ! -e "$2" ]; then sf_die "$1 file not found: $2"; fi
  if [ -d "$2" ]; then sf_die "$1 is a directory, not a file: $2"; fi
  if [ ! -r "$2" ]; then sf_die "$1 file not readable: $2"; fi
  # A redirect, not an operand: cat would read a file named "-" as stdin.
  cat <"$2" >"$3" 2>/dev/null || sf_die "could not read the $1 file: $2"
}

# bc_bytes NAME FILE: count the bytes awk could hide (text-mode awks drop a CR before the
# newline; some drop NUL), and complain about them. Returns 1 when there are any.
bc_bytes() {
  local cr nul rc=0
  cr=$(LC_ALL=C tr -dc '\r' <"$2" | wc -c | tr -d ' ')
  nul=$(LC_ALL=C tr -dc '\000' <"$2" | wc -c | tr -d ' ')
  if [ "$cr" -gt 0 ]; then
    printf '%s: error: %s: %s carriage return(s) (CRLF line endings?); use one number per LF-ended line\n' "$SF_PROG" "$1" "$cr" >&2
    rc=1
  fi
  if [ "$nul" -gt 0 ]; then
    printf '%s: error: %s: %s NUL byte(s); not a list of numbers\n' "$SF_PROG" "$1" "$nul" >&2
    rc=1
  fi
  return "$rc"
}

main() {
  local before="" after="" npos=0 opts_done=0 a rc=0
  while [ "$#" -gt 0 ]; do
    a=$1
    if [ "$opts_done" = 0 ]; then
      case "$a" in
        -h | --help)
          usage
          return 0
          ;;
        --)
          opts_done=1
          shift
          continue
          ;;
        -?*) sf_die "unknown option: $a (see --help)" ;;
      esac
    fi
    case "$npos" in
      0) before=$a ;;
      1) after=$a ;;
      *) sf_die "too many arguments: expected BEFORE AFTER (see --help)" ;;
    esac
    npos=$((npos + 1))
    shift
  done
  [ "$npos" -eq 2 ] || sf_die "expected two files: BEFORE AFTER (see --help)"
  if [ -z "$before" ] || [ -z "$after" ]; then sf_die "file names must not be empty"; fi

  BC_TMP=$(sf_mktemp_dir)
  trap bc_cleanup EXIT
  bc_copy before "$before" "$BC_TMP/before"
  bc_copy after "$after" "$BC_TMP/after"
  bc_bytes before "$BC_TMP/before" || rc=2
  bc_bytes after "$BC_TMP/after" || rc=2
  [ "$rc" -eq 0 ] || return 2

  # The report goes through a file so that nothing reaches stdout unless both files are
  # valid (awk writes it only then, but its exit code is what decides).
  rc=0
  LC_ALL=C awk "$BC_AWK" "$BC_TMP/before" "$BC_TMP/after" >"$BC_TMP/report" || rc=$?
  case "$rc" in
    # A report that can't be written is no verdict: 2, never 1 (which would mean "no win").
    0 | 1) cat "$BC_TMP/report" || sf_die "could not write the report to stdout" ;;
    2) ;;
    *) sf_die "the comparison failed (awk exit $rc)" ;;
  esac
  return "$rc"
}

# Everything above only defines functions and constants; this line is parsed whole first.
main "$@"; exit $?
