#!/bin/sh
# Project Zombai test runner: syntax-checks every Lua file, then runs the
# offline suites against stubbed PZ APIs. Requires lua5.1/luac5.1
# (matching the game's Kahlua dialect): apt-get install -y lua5.1
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LUA_ROOT="$ROOT/42/media/lua"

find "$ROOT" -name '*.lua' -print0 | xargs -0 -n1 luac5.1 -p
echo "syntax OK"

# The AnimSet overlays are read by the game's own XML parser, which
# rejects a whole file over a detail Lua string checks will not see (an
# XML comment containing "--" cost the mod all ninety of its animation
# nodes at once). Check them with a real parser where one is available.
if command -v python3 >/dev/null 2>&1; then
    python3 - "$ROOT" <<'PYEOF'
import glob, sys, xml.dom.minidom
root = sys.argv[1]
files = sorted(glob.glob(root + "/42/media/AnimSets/**/*.xml", recursive=True))
bad = []
for f in files:
    try:
        xml.dom.minidom.parse(f)
    except Exception as e:
        bad.append("%s: %s" % (f[len(root) + 1:], e))
for line in bad:
    print("  " + line)
if bad:
    sys.exit("AnimSet XML is malformed; the game will load none of these nodes")
print("AnimSet XML well-formed OK (%d files)" % len(files))
PYEOF
else
    echo "python3 not found - skipping AnimSet XML well-formedness check"
fi

for suite in test_archetypes test_zombiethreat test_doors test_scavenge test_vehicles test_debug test_signs test_anim test_movement test_combat test_population test_squads; do
    echo "== $suite =="
    lua5.1 "$ROOT/tests/$suite.lua" "$LUA_ROOT"
done
echo "ALL SUITES PASSED"
