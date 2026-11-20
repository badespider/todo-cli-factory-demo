# shellcheck shell=bash
# Reads factory.config.yaml (a documented YAML subset) without yq.
# Contract: docs/CONTRACTS.md, "Config YAML subset". Requires common.sh.

if [ -n "${SF_CONFIG_LOADED:-}" ]; then return 0; fi
SF_CONFIG_LOADED=1

SF_CONFIG_FILE=""
SF_CONFIG_FLAT=""
SF_AWK="${SF_AWK:-awk}"

# sf_config_load [FILE]: parse FILE (default: FACTORY_CONFIG, else the judging copy's config).
sf_config_load() {
  local f="${1:-${FACTORY_CONFIG:-$SF_FACTORY_ROOT/factory.config.yaml}}" out status=0 bom
  [ -f "$f" ] || sf_die "config not found: $f (pass --config or set FACTORY_CONFIG)"
  bom=$(printf '\357\273\277')
  out=$("$SF_AWK" -v bom="$bom" -f "$SF_LIB_DIR/yaml.awk" "$f") || status=$?
  if [ "$status" -ne 0 ]; then
    local line msg
    line=$(printf '%s\n' "$out" | awk -F '\t' '$1 == "ERR" { print $2; exit }')
    msg=$(printf '%s\n' "$out" | awk -F '\t' '$1 == "ERR" { print $3; exit }')
    sf_die "$f:${line:-?}: ${msg:-could not parse config}"
  fi
  SF_CONFIG_FILE="$f"
  SF_CONFIG_FLAT="$out"
}

_sf_config_ensure() {
  [ -n "$SF_CONFIG_FILE" ] || sf_config_load
}

# _sf_cfg_raw KEY: print the stored value of a scalar key; status 1 if absent.
_sf_cfg_raw() {
  printf '%s\n' "$SF_CONFIG_FLAT" | awk -v k="$1=" '
    index($0, k) == 1 { print substr($0, length(k) + 1); found = 1; exit }
    END { exit !found }'
}

# sf_cfg KEY [DEFAULT]: value of KEY; DEFAULT if missing or empty; dies if neither.
sf_cfg() {
  local v
  _sf_config_ensure
  if v=$(_sf_cfg_raw "$1") && [ -n "$v" ]; then
    printf '%s\n' "$v"
  elif [ "$#" -ge 2 ]; then
    printf '%s\n' "$2"
  else
    sf_die "$SF_CONFIG_FILE: missing required key '$1'"
  fi
}

sf_cfg_has() {
  local v
  _sf_config_ensure
  v=$(_sf_cfg_raw "$1") && [ -n "$v" ]
}

# sf_cfg_globs KEY: the globs of a glob-list key (gate.test_globs, merge.protected_paths),
# one per line: its list items, or its value when it is a single scalar. Nothing for "none"
# or a missing key; sf_cfg_require_globs decides whether that is allowed.
sf_cfg_globs() {
  local items v
  _sf_config_ensure
  items=$(sf_cfg_list "$1")
  if [ -n "$items" ]; then
    printf '%s\n' "$items"
  elif v=$(_sf_cfg_raw "$1") && [ -n "$v" ] && ! sf_is_none "$v"; then
    printf '%s\n' "$v"
  fi
  return 0
}

# sf_cfg_require_globs KEY: die (code 2) unless KEY is "none" or holds at least one glob.
# A missing key, or one whose items are all commented out, would silently mean "no files".
sf_cfg_require_globs() {
  _sf_config_ensure
  sf_cfg_has "$1" || [ -n "$(sf_cfg_list "$1")" ] ||
    sf_die "$SF_CONFIG_FILE: $1 is missing or empty (use none if there are deliberately no such files)"
}

# sf_cfg_list KEY: list items one per line; nothing for a missing key or "none".
sf_cfg_list() {
  _sf_config_ensure
  printf '%s\n' "$SF_CONFIG_FLAT" | awk -v k="$1[]=" 'index($0, k) == 1 { print substr($0, length(k) + 1) }'
}

# sf_duration_seconds VALUE: "<n>s|m|h|d" -> seconds.
sf_duration_seconds() {
  local v="$1" n unit
  case "$v" in
    *[!0-9smhd]* | '' ) sf_die "invalid duration '$v' (use <n>s, <n>m, <n>h or <n>d)" ;;
  esac
  n="${v%[smhd]}"
  unit="${v#"$n"}"
  case "$n" in '' | *[!0-9]*) sf_die "invalid duration '$v' (use <n>s, <n>m, <n>h or <n>d)" ;; esac
  case "$unit" in
    s) printf '%s\n' "$n" ;;
    m) printf '%s\n' "$((n * 60))" ;;
    h) printf '%s\n' "$((n * 3600))" ;;
    d) printf '%s\n' "$((n * 86400))" ;;
    *) sf_die "invalid duration '$v' (missing unit s, m, h or d)" ;;
  esac
}
