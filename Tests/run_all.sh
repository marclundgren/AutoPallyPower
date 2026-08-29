#!/usr/bin/env bash
# Runs the pure-Lua test suites. Requires lua5.1 (the version WoW ships).
set -euo pipefail
cd "$(dirname "$0")/.."
export APP_ROOT=.
LUA="${LUA:-lua5.1}"
fail=0
for t in Tests/test_*.lua; do
  echo "--- $t"
  "$LUA" "$t" | tail -n 3 || fail=1
done
exit $fail
