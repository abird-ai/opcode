#!/bin/sh
# M5 modes tests: --mode json (JSONL event stream) and --mode rpc (stdin JSONL
# command loop) over the deterministic replay wire.
# usage: tests/modes.sh    (OPCODE=/path/to/binary overrides ./build/opcode)
set -e
cd "$(dirname "$0")/.."
OPCODE="${OPCODE:-./build/opcode}"
if [ "$OPCODE" = "./build/opcode" ] && [ ! -x build/opcode ]; then make -s all; fi
[ -f tests/data/agent_replay.wire ] || python3 tests/gen_agent_replay.py

# A user config can pin default_provider/default_model and override --provider;
# isolate config and state so the suite is deterministic here and in CI.
modes_tmp=$(mktemp -d "${TMPDIR:-/tmp}/opcode-modes.XXXXXX")
trap 'rm -rf "$modes_tmp"' EXIT INT TERM HUP
export XDG_CONFIG_HOME="$modes_tmp/config"
export XDG_STATE_HOME="$modes_tmp/state"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_STATE_HOME"

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

COMMON="--replay tests/data/agent_replay.wire --no-session --provider anthropic --api-key test"

# 1. json mode: exact event stream
out=$(timeout 30 "$OPCODE" --mode json -p "hi" $COMMON)
if printf '%s\n' "$out" | cmp -s - tests/data/modes.expected; then
    echo "ok   modes-json-expected"
else
    echo "FAIL modes-json-expected"
    printf '%s\n' "$out" | diff -u tests/data/modes.expected - | head -20 || true
    fail=1
fi

# 2. json mode: every line is a JSON object, text_delta + final agent_end exit 0
if printf '%s\n' "$out" | python3 -c '
import json, sys
objs = [json.loads(line) for line in sys.stdin if line.strip()]
assert all(isinstance(o, dict) and "type" in o for o in objs), "non-object line"
assert any(o.get("type") == "text_delta" and o.get("text") for o in objs), "no text_delta"
assert objs[-1].get("type") == "agent_end" and objs[-1].get("exit") == 0, "no final agent_end"
' 2>/dev/null; then
    echo "ok   modes-json-shape"
else
    echo "FAIL modes-json-shape"
    fail=1
fi

# 3. rpc mode: prompt + quit, exact event stream (ready, ack, agent_end)
rout=$(printf '{"type":"prompt","text":"hi"}\n{"type":"quit"}\n' | \
    timeout 30 "$OPCODE" --mode rpc $COMMON)
if printf '%s\n' "$rout" | cmp -s - tests/data/modes_rpc.expected; then
    echo "ok   modes-rpc-expected"
else
    echo "FAIL modes-rpc-expected"
    printf '%s\n' "$rout" | diff -u tests/data/modes_rpc.expected - | head -20 || true
    fail=1
fi

# 4. rpc mode: valid JSONL, ready first, ack for the prompt, final agent_end
if printf '%s\n' "$rout" | python3 -c '
import json, sys
objs = [json.loads(line) for line in sys.stdin if line.strip()]
assert all(isinstance(o, dict) and "type" in o for o in objs), "non-object line"
assert objs[0].get("type") == "ready", "first line is not ready"
assert any(o.get("type") == "ack" for o in objs), "no ack"
assert objs[-1].get("type") == "agent_end" and objs[-1].get("exit") == 0, "no final agent_end"
' 2>/dev/null; then
    echo "ok   modes-rpc-shape"
else
    echo "FAIL modes-rpc-shape"
    fail=1
fi

# 5. rpc mode: EOF (no quit) waits for the run and exits 0
rc=0
eout=$(printf '{"type":"prompt","text":"hi"}\n' | timeout 30 "$OPCODE" --mode rpc $COMMON) || rc=$?
check modes-rpc-eof-rc 0 "$rc"
if printf '%s\n' "$eout" | grep -q '"type":"agent_end"'; then
    echo "ok   modes-rpc-eof-end"
else
    echo "FAIL modes-rpc-eof-end"
    fail=1
fi

# 6. json mode without a prompt is a usage error
rc=0
timeout 30 "$OPCODE" --mode json $COMMON > /dev/null 2>&1 || rc=$?
check modes-json-noprompt 2 "$rc"

# 7. both front ends print the error once, with a single "opcode: " prefix
# (the bug was "opcode: opcode: missing prompt")
rc=0
out=$(timeout 30 "$OPCODE" --mode json $COMMON 2>&1 >/dev/null) || rc=$?
check modes-json-noprompt-msg "opcode: missing prompt" "$(printf '%s\n' "$out" | head -1)"
rc=0
out=$(timeout 30 "$OPCODE" -p 2>&1 >/dev/null) || rc=$?
check modes-p-noprompt-msg "opcode: missing prompt" "$(printf '%s\n' "$out" | head -1)"

exit $fail
