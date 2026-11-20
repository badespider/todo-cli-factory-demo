#!/usr/bin/env bash
# auth-file.sh: write a harness's login file from the environment, then run the harness.
#
# Usage: bash factory/harness/auth-file.sh [--] HARNESS_COMMAND [ARG...]
#
# For a harness whose CI login is a file rather than an environment variable. Put this in
# front of the harness command in harness_cmd, and put both variables below in the
# FACTORY_AGENT_ENV secret (run-agent.sh exports its KEY=VALUE lines for the harness only):
#
#   FACTORY_HARNESS_AUTH_FILE  where the file goes: an absolute path, or one that starts
#                              with ~/ (expanded to $HOME)
#   FACTORY_HARNESS_AUTH_DATA  the file's whole content, base64-encoded on one line
#
# The file is written with mode 600 (an existing file is replaced; missing parent
# directories are created with mode 700). Both variables are then removed from the
# environment and the command replaces this script (exec), so the harness, and everything
# it starts, never inherits them, and the exit code is the harness's own.
#
# Exit 2, without running the command, when: no command is given, the command is a
# relative path, a variable is missing or empty, the data is not valid base64, the
# destination is relative, is a directory or is not a regular file, or the file can't be
# written. Nothing this script prints ever contains the data. -h/--help prints this text.
#
# A relative destination is refused because it would land in the agent's worktree, where
# the exit trap's wip commit could push it. A relative command (./bin/x) is refused because
# it would run a file from that worktree, which a branch under review can change.
set +x # never trace the data, even under `bash -x`
set +a
set -u

# The header above, up to the first line that is not a comment.
au_usage() { awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; }
au_die() {
  printf 'auth-file: %s\n' "$*" >&2
  exit 2
}

case "${1:-}" in
  -h | --help)
    au_usage
    exit 0
    ;;
  --) shift ;;
esac
[ "$#" -gt 0 ] || au_die "no harness command given (usage: bash factory/harness/auth-file.sh HARNESS_COMMAND [ARG...])"
# The harness runs in the agent's worktree: a relative path would run a file a branch can
# change, with the login. A name is looked up in PATH; anything else must be absolute.
case "$1" in
  */*) case "$1" in /* | [A-Za-z]:[\\/]*) ;; *) au_die "the harness command must be a name found in PATH or an absolute path, not $1" ;; esac ;;
esac

au_dest="${FACTORY_HARNESS_AUTH_FILE:-}"
au_data="${FACTORY_HARNESS_AUTH_DATA:-}"
# Gone from the environment before anything else runs, success or not.
unset FACTORY_HARNESS_AUTH_FILE FACTORY_HARNESS_AUTH_DATA

[ -n "$au_dest" ] || au_die "FACTORY_HARNESS_AUTH_FILE is not set or empty (set it in FACTORY_AGENT_ENV)"
[ -n "$au_data" ] || au_die "FACTORY_HARNESS_AUTH_DATA is not set or empty (set it in FACTORY_AGENT_ENV)"

# ~ and ~/... mean $HOME (the variable arrives unexpanded from FACTORY_AGENT_ENV).
# shellcheck disable=SC2088 # a literal "~" is what is being matched
case "$au_dest" in
  "~" | "~/"*)
    [ -n "${HOME:-}" ] || au_die "FACTORY_HARNESS_AUTH_FILE starts with ~ but HOME is not set"
    au_dest="${HOME%/}${au_dest#"~"}"
    ;;
esac
case "$au_dest" in
  /* | [A-Za-z]:[\\/]*) ;;
  *) au_die "FACTORY_HARNESS_AUTH_FILE must be an absolute path or start with ~/" ;;
esac
case "$au_dest" in
  */ | *\\) au_die "FACTORY_HARNESS_AUTH_FILE names a directory: $au_dest" ;;
esac
[ ! -d "$au_dest" ] || au_die "FACTORY_HARNESS_AUTH_FILE is a directory: $au_dest"
[ ! -e "$au_dest" ] || [ -f "$au_dest" ] || au_die "FACTORY_HARNESS_AUTH_FILE is not a regular file: $au_dest"

# Standard base64 (RFC 4648 alphabet, padded); line breaks and blanks are ignored.
au_data=$(printf '%s' "$au_data" | tr -d ' \t\r\n')
au_re='^([A-Za-z0-9+/]{4})*([A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$'
if [ -z "$au_data" ] || ! [[ $au_data =~ $au_re ]]; then
  au_die "FACTORY_HARNESS_AUTH_DATA is not valid base64 (encode the file on one line, e.g. base64 -w0 FILE)"
fi

# A decoder: GNU and BSD base64 both take --decode; older macOS has only -D; else openssl.
au_dec=()
if printf 'YQ==' | base64 --decode >/dev/null 2>&1; then
  au_dec=(base64 --decode)
elif printf 'YQ==' | base64 -D >/dev/null 2>&1; then
  au_dec=(base64 -D)
elif printf 'YQ==' | openssl base64 -d -A >/dev/null 2>&1; then
  au_dec=(openssl base64 -d -A)
else
  au_die "no base64 decoder found (base64 or openssl)"
fi

au_dir=$(dirname "$au_dest") || au_die "cannot tell the directory of $au_dest"
(umask 077 && mkdir -p "$au_dir") || au_die "cannot create the directory $au_dir"
au_tmp=$(umask 077 && mktemp "$au_dir/.auth-file.XXXXXX") || au_die "cannot create a file in $au_dir"
if ! printf '%s' "$au_data" | "${au_dec[@]}" >"$au_tmp" 2>/dev/null; then
  rm -f "$au_tmp"
  au_die "FACTORY_HARNESS_AUTH_DATA could not be decoded"
fi
if ! chmod 600 "$au_tmp" || ! mv -f "$au_tmp" "$au_dest"; then
  rm -f "$au_tmp"
  au_die "cannot write $au_dest"
fi
unset au_data au_dec au_tmp au_dir au_dest au_re

exec "$@"
