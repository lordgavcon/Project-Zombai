#!/bin/sh
# Project Zombai test runner: syntax-checks every Lua file, then runs the
# offline suites against stubbed PZ APIs. Requires lua5.1/luac5.1
# (matching the game's Kahlua dialect): apt-get install -y lua5.1
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LUA_ROOT="$ROOT/42/media/lua"

find "$ROOT" -name '*.lua' -print0 | xargs -0 -n1 luac5.1 -p
echo "syntax OK"

for suite in test_archetypes test_zombiethreat test_doors test_scavenge test_vehicles test_debug; do
    echo "== $suite =="
    lua5.1 "$ROOT/tests/$suite.lua" "$LUA_ROOT"
done
echo "ALL SUITES PASSED"
