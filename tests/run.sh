#!/bin/sh
# Run every spec, each in a fresh headless Neovim. Exits non-zero if any fails.
#
#   tests/run.sh                 all specs
#   tests/run.sh tests/picker_spec.lua ...
cd "$(dirname "$0")/.." || exit 1

# A throwaway cache, so the history and context files the specs write are
# never the user's.
XDG_CACHE_HOME=$(mktemp -d)
export XDG_CACHE_HOME
trap 'rm -rf "$XDG_CACHE_HOME"' EXIT

[ $# -gt 0 ] || set -- tests/*_spec.lua
status=0
for spec in "$@"; do
    echo "$spec"
    out=$(nvim --headless --clean -u NONE -l "$spec" 2>&1)
    code=$?
    printf '%s\n' "$out" | tr '\r' '\n' | grep -av '^$'
    [ "$code" -eq 0 ] || status=1
done
exit $status
