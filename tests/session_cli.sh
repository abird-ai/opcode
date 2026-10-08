#!/bin/sh
# M3 session CLI tests: creation, JSON validity, --continue append, --no-session.
set -e
cd "$(dirname "$0")/.."
[ -x build/opcode ] || make -s all
[ -f tests/data/agent_replay_simple.wire ] || python3 tests/gen_agent_replay.py

fail=0
check() {
    if [ "$2" = "$3" ]; then
        echo "ok   $1"
    else
        echo "FAIL $1"
        printf '  expected: %s\n  actual:   %s\n' "$2" "$3"
        fail=1
    fi
}

TMP="$PWD/build/session_cli"
rm -rf "$TMP"
mkdir -p "$TMP/home"
export HOME="$TMP/home"
export XDG_DATA_HOME="$TMP/data"
export XDG_CONFIG_HOME="$TMP/config"

run() { timeout 30 ./build/opcode "$@"; }

# 1. first run creates a session
run -p "first" --provider anthropic --api-key test --replay tests/data/agent_replay.wire > /dev/null
f=$(find "$XDG_DATA_HOME/opcode/sessions" -name '*.jsonl' 2>/dev/null | head -1)
if [ -n "$f" ]; then echo "ok   session-created"; else echo "FAIL session-created"; fail=1; fi

# header + model_change + user + assistant(tool_use) + tool_result + assistant = 6 lines
check session-lines 6 "$(wc -l < "$f")"

# every line is plain JSON (serde-compatible)
if python3 -c '
import json, sys
for line in open(sys.argv[1]):
    if line.strip():
        json.loads(line)
' "$f" 2>/dev/null; then
    echo "ok   session-json"
else
    echo "FAIL session-json"
    fail=1
fi

# the file name and header carry the same id
if python3 - "$f" <<'EOF'
import json, sys, os
path = sys.argv[1]
head = json.loads(open(path).readline())
sid = os.path.basename(path).rsplit("_", 1)[1].removesuffix(".jsonl")
ok = head["type"] == "session" and head["schema_version"] == 1 and head["id"] == sid and head["cwd"]
sys.exit(0 if ok else 1)
EOF
then
    echo "ok   session-header"
else
    echo "FAIL session-header"
    fail=1
fi

# 2. --continue loads the history and appends user + assistant (8 lines, no new model_change)
run -p "second" --continue --provider anthropic --api-key test \
    --replay tests/data/agent_replay_simple.wire > /dev/null
check session-continue-lines 8 "$(wc -l < "$f")"
if grep -q '"text":"second"' "$f"; then
    echo "ok   session-continue-text"
else
    echo "FAIL session-continue-text"
    fail=1
fi

# 3. --no-session leaves the store unchanged
before=$(find "$XDG_DATA_HOME/opcode/sessions" -name '*.jsonl' | wc -l)
run -p "third" --no-session --provider anthropic --api-key test \
    --replay tests/data/agent_replay_simple.wire > /dev/null
after=$(find "$XDG_DATA_HOME/opcode/sessions" -name '*.jsonl' | wc -l)
check session-nosession "$before" "$after"

# 4. schema_version policy: a newer session refuses with a clear message and a
# non-zero exit; a session with no version field is treated as the legacy 1.
NEWER="$TMP/newer.jsonl"
cat > "$NEWER" <<'JSON'
{"type":"session","schema_version":2,"id":"deadbeef","timestamp":1,"cwd":"/tmp"}
{"type":"message","id":"1","parent_id":null,"message":{"role":"user","timestamp":2,"content":[{"type":"text","text":"old"}]}}
JSON
out=$(run -p "newer" --session "$NEWER" --provider anthropic --api-key test \
    --replay tests/data/agent_replay_simple.wire 2>&1) && rc=0 || rc=$?
check session-schema-newer-rc 1 "$rc"
if printf '%s' "$out" | grep -q "written by a newer opcode"; then
    echo "ok   session-schema-newer-msg"
else
    echo "FAIL session-schema-newer-msg"
    fail=1
fi

LEGACY="$TMP/legacy.jsonl"
cat > "$LEGACY" <<'JSON'
{"type":"session","id":"deadbeef","timestamp":1,"cwd":"/tmp"}
{"type":"message","id":"1","parent_id":null,"message":{"role":"user","timestamp":2,"content":[{"type":"text","text":"old"}]}}
JSON
run -p "legacy" --session "$LEGACY" --provider anthropic --api-key test \
    --replay tests/data/agent_replay_simple.wire > /dev/null 2>&1 && rc=0 || rc=$?
check session-schema-legacy-rc 0 "$rc"

exit $fail
