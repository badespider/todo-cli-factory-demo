# shellcheck shell=bash
# sf_jq: jq that behaves the same on Linux, macOS and Git Bash on Windows.
#
# Two Windows problems are handled here:
# 1. The native jq.exe writes CRLF unless run with -b, which turns "F1" into "F1\r"
#    and breaks every git ref, comparison and loop built from it.
# 2. Git Bash rewrites "/"-looking text inside arguments and environment values passed
#    to native programs: the program '"#/a/b"' arrives as '"#A:/b"', and
#    --arg t "/api" arrives as "C:/Program Files/Git/api". sf_jq turns that rewriting
#    off for the jq call and converts only the arguments that really are file paths
#    (input files, -f/--from-file, --rawfile/--slurpfile, -L).
# Requires common.sh (SF_MSYS).

if [ -n "${SF_JQ_LOADED:-}" ]; then return 0; fi
SF_JQ_LOADED=1

if [ -z "${SF_JQ_MODE:-}" ]; then
  if jq -b -n 1 >/dev/null 2>&1; then
    SF_JQ_MODE=binary
  elif [ "${SF_MSYS:-0}" = 1 ]; then
    SF_JQ_MODE="strip"
  else
    SF_JQ_MODE=plain
  fi
  export SF_JQ_MODE
fi

# _sf_jq_native_args ARGS...: fills SF_JQ_ARGV with ARGS, converting file operands
# with sf_native_path. Program text and --arg/--argjson values are left alone.
_sf_jq_native_args() {
  local a want="" program_seen=0 positional_values=0 opts_done=0
  SF_JQ_ARGV=()
  for a in "$@"; do
    # Values owed to the previous option.
    case "$want" in
      file) SF_JQ_ARGV+=("$(sf_native_path "$a")"); want=""; continue ;;
      skip) SF_JQ_ARGV+=("$a"); want=""; continue ;;
      name-then-file) SF_JQ_ARGV+=("$a"); want="file"; continue ;;
      name-then-value) SF_JQ_ARGV+=("$a"); want="skip"; continue ;;
    esac
    if [ "$opts_done" = 0 ]; then
      case "$a" in
        --) SF_JQ_ARGV+=("$a"); opts_done=1; continue ;;
        --from-file) SF_JQ_ARGV+=("$a"); want="file"; program_seen=1; continue ;;
        --rawfile|--slurpfile) SF_JQ_ARGV+=("$a"); want=name-then-file; continue ;;
        --arg|--argjson) SF_JQ_ARGV+=("$a"); want=name-then-value; continue ;;
        --indent|--library-path) SF_JQ_ARGV+=("$a")
          if [ "$a" = --library-path ]; then want="file"; else want="skip"; fi
          continue ;;
        --args|--jsonargs) SF_JQ_ARGV+=("$a"); positional_values=1; continue ;;
        -L) SF_JQ_ARGV+=("$a"); want="file"; continue ;;
        -L*) SF_JQ_ARGV+=("-L$(sf_native_path "${a#-L}")"); continue ;;
        --*) SF_JQ_ARGV+=("$a"); continue ;;
        -?*)
          SF_JQ_ARGV+=("$a")
          case "$a" in
            -*f*) want="file"; program_seen=1 ;;
          esac
          continue ;;
      esac
    fi
    # A positional argument: the program text first (unless -f gave a file), then
    # input files, or plain values after --args/--jsonargs.
    if [ "$program_seen" = 0 ]; then
      SF_JQ_ARGV+=("$a")
      program_seen=1
    elif [ "$positional_values" = 1 ]; then
      SF_JQ_ARGV+=("$a")
    else
      SF_JQ_ARGV+=("$(sf_native_path "$a")")
    fi
  done
}

sf_jq() {
  if [ "${SF_MSYS:-0}" = 1 ]; then
    _sf_jq_native_args "$@"
    set -- ${SF_JQ_ARGV[@]+"${SF_JQ_ARGV[@]}"}
    case "$SF_JQ_MODE" in
      binary) MSYS_NO_PATHCONV=1 jq -b "$@" ;;
      *)
        MSYS_NO_PATHCONV=1 jq "$@" | tr -d '\r'
        return "${PIPESTATUS[0]}"
        ;;
    esac
    return
  fi
  case "$SF_JQ_MODE" in
    binary) jq -b "$@" ;;
    strip)
      jq "$@" | tr -d '\r'
      return "${PIPESTATUS[0]}"
      ;;
    *) jq "$@" ;;
  esac
}
