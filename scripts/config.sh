#!/usr/bin/env bash
# Prints one value or one glob list from the judging copy's config; the only way agents read config. Contract: docs/CONTRACTS.md, "config.sh".
set -euo pipefail
SF_PROG=config
# shellcheck source=scripts/lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
# shellcheck source=scripts/lib/config.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/config.sh"

usage() {
  cat <<'EOF'
Usage: config.sh get KEY [DEFAULT] [--config FILE]
       config.sh globs KEY [--config FILE]

Reads the judging copy's config: FACTORY_CONFIG when it is set, else the
factory.config.yaml of the factory copy holding this script (FACTORY_ROOT, default
scripts/..). A factory.config.yaml in the current directory or in the tree under test
is never read, so an agent in a PR worktree sees the rules that judge it: run the main
checkout's copy of this script.

  get KEY [DEFAULT]  print the value of the dotted KEY (for example gate.test or
                     roles.perf.bench). A missing or empty key prints DEFAULT, or exits 2
                     when no DEFAULT is given. A list key exits 2: read it with globs.
  globs KEY          print the globs of a glob-list key (gate.test_globs,
                     merge.protected_paths), one per line: its list items, or its value
                     when it is one scalar. none prints nothing (exit 0). A missing key,
                     or one whose items are all commented out, exits 2.
  --config FILE      read FILE instead (overrides FACTORY_CONFIG); it is always loaded
                     and checked
  --                 end of options (for a DEFAULT that starts with -)
  -h, --help         show this help

KEY is one or more names of letters, digits, _ and -, joined by dots.

Exit: 0 printed; 2 a missing key without a DEFAULT, a list key read with get, a missing
or invalid config, or a usage error.
EOF
}

# cfg_valid_key KEY: true for dot-joined names of [A-Za-z0-9_-].
cfg_valid_key() {
  case "$1" in
    '' | .* | *. | *..* | *[!A-Za-z0-9_.-]*) return 1 ;;
  esac
  return 0
}

main() {
  local config="" cmd="" key="" def="" have_def=0 npos=0 opts_done=0 a
  while [ "$#" -gt 0 ]; do
    a=$1
    if [ "$opts_done" = 0 ]; then
      case "$a" in
        -h | --help)
          usage
          return 0
          ;;
        --config)
          [ "$#" -ge 2 ] || sf_die "--config needs a value (see --help)"
          [ -n "$2" ] || sf_die "--config needs a non-empty value"
          config=$2
          shift 2
          continue
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
      0) cmd=$a ;;
      1) key=$a ;;
      2) def=$a; have_def=1 ;;
      *) sf_die "too many arguments (see --help)" ;;
    esac
    npos=$((npos + 1))
    shift
  done

  case "$cmd" in
    get | globs) ;;
    '') sf_die "a subcommand is required: get or globs (see --help)" ;;
    *) sf_die "unknown subcommand: $cmd (use get or globs; see --help)" ;;
  esac
  [ "$npos" -ge 2 ] || sf_die "$cmd needs a KEY (see --help)"
  if [ "$cmd" = globs ] && [ "$have_def" = 1 ]; then
    sf_die "globs takes no DEFAULT (see --help)"
  fi
  cfg_valid_key "$key" || sf_die "invalid key '$key' (dot-joined names of letters, digits, _ and -)"

  # Never the current directory's or the tree's config: the library's default is the
  # judging copy (FACTORY_CONFIG, else $SF_FACTORY_ROOT/factory.config.yaml).
  if [ -n "$config" ]; then sf_config_load "$config"; else sf_config_load; fi

  if [ "$cmd" = globs ]; then
    sf_cfg_require_globs "$key"
    sf_cfg_globs "$key"
    return 0
  fi
  # sf_cfg sees only scalars, so a list key would read as missing (or as DEFAULT).
  if [ -n "$(sf_cfg_list "$key")" ]; then
    sf_die "$SF_CONFIG_FILE: $key is a list; read it with: config.sh globs $key"
  fi
  if [ "$have_def" = 1 ]; then
    sf_cfg "$key" "$def"
  else
    sf_cfg "$key"
  fi
}

# Everything above only defines functions; this line is parsed whole before main runs.
main "$@"; exit $?
