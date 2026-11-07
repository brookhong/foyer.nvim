#!/bin/sh
# Run every spec, each in a fresh headless Neovim. Exits non-zero if any fails.
#
#   tests/run.sh                 all specs
#   tests/run.sh tests/picker_spec.lua ...
cd "$(dirname "$0")/.." || exit 1

# Throwaway caches, so the history the specs write is never the user's -- and,
# one per spec, never another spec's: a prompt one sends would otherwise rank in
# the history the next one lists.
caches=$(mktemp -d)
trap 'rm -rf "$caches"' EXIT

[ $# -gt 0 ] || set -- tests/*_spec.lua
status=0
for spec in "$@"; do
    echo "$spec"
    XDG_CACHE_HOME=$(mktemp -d "$caches/spec.XXXXXX")
    export XDG_CACHE_HOME
    out=$(nvim --headless --clean -u NONE -n -l "$spec" 2>&1)
    code=$?
    # LC_ALL=C: bytes, not characters, so no output is lost to one that is not
    # valid in the locale.
    printf '%s\n' "$out" | LC_ALL=C tr '\r' '\n' | grep -av '^$'
    [ "$code" -eq 0 ] || status=1
done
exit $status
