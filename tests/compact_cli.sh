#!/bin/sh
# M5 compaction CLI tests: forced summary via a huge loaded session + replay,
# and the no-op path below the threshold.
# usage: tests/compact_cli.sh   (expects build/opcode; run.sh has built it)
set -e
cd "$(dirname "$0")/.."
[ -x build/opcode ] || make -s all
command -v python3 > /dev/null 2>&1 || exit 0
[ -f tests/data/agent_replay_simple.wire ] || python3 tests/gen_agent_replay.py

fail=0
check() { # name expected actual
    if [ "$2" = "$3" ]; then
        echo "ok   $1"
    else
        echo "FAIL $1"
        printf '  expected: %s\n  actual:   %s\n' "$2" "$3"
        fail=1
    fi
}
contains() {
    if printf '%s' "$3" | grep -q "$2"; then
        echo "ok   $1"
    else
        echo "FAIL $1"
        printf '  missing: %s\n  in: %s\n' "$2" "$3"
        fail=1
    fi
}
absent() {
    if printf '%s' "$3" | grep -q "$2"; then
        echo "FAIL $1"
        printf '  unexpected: %s\n  in: %s\n' "$2" "$3"
        fail=1
    else
        echo "ok   $1"
    fi
}
file_contains() {
    if grep -q "$2" "$3"; then
        echo "ok   $1"
    else
        echo "FAIL $1"
        printf '  missing: %s\n  in: %s\n' "$2" "$3"
        fail=1
    fi
}

TMP="$PWD/build/compact_cli"
rm -rf "$TMP"
mkdir -p "$TMP/home"
export HOME="$TMP/home"
export XDG_DATA_HOME="$TMP/data"
export XDG_CONFIG_HOME="$TMP/config"
SESS="$TMP/session.jsonl"
WIRE="$TMP/compact.wire"

# A session whose loaded transcript estimates above 200000 - 16384 tokens,
# plus a replay whose first response summarizes and whose second answers.
python3 - "$SESS" "$WIRE" <<'EOF'
import json, struct, sys

sess, wire = sys.argv[1], sys.argv[2]
big = "x" * 800000
with open(sess, "w") as f:
    f.write(json.dumps({"type": "session", "schema_version": 1, "id": "deadbeef",
                         "timestamp": 1, "cwd": "/tmp"}) + "\n")
    f.write(json.dumps({"type": "model_change", "provider": "anthropic",
                         "model": "claude-sonnet-4-5"}) + "\n")
    f.write(json.dumps({"type": "message", "id": "1", "parent_id": None,
                         "message": {"role": "user", "timestamp": 2,
                                     "content": [{"type": "text", "text": big}]}}) + "\n")


def sse(events):
    out = bytearray()
    for name, data in events:
        out += f"event: {name}\ndata: {json.dumps(data, separators=(',', ':'))}\n\n".encode()
    return bytes(out)


def http_response(body):
    head = ("HTTP/1.1 200 OK\r\n"
            "Content-Type: text/event-stream\r\n"
            f"Content-Length: {len(body)}\r\n"
            "Connection: close\r\n\r\n").encode()
    return head + body


def turn(text):
    return sse([
        ("message_start", {"type": "message_start", "message": {
            "id": "m", "usage": {"input_tokens": 1, "output_tokens": 1}}}),
        ("content_block_start", {"type": "content_block_start", "index": 0,
                                 "content_block": {"type": "text", "text": ""}}),
        ("content_block_delta", {"type": "content_block_delta", "index": 0,
                                 "delta": {"type": "text_delta", "text": text}}),
        ("content_block_stop", {"type": "content_block_stop", "index": 0}),
        ("message_delta", {"type": "message_delta",
                           "delta": {"stop_reason": "end_turn"},
                           "usage": {"output_tokens": 1}}),
        ("message_stop", {"type": "message_stop"}),
    ])


with open(wire, "wb") as f:
    f.write(b"FWIR1\n")
    # 1) summarize, 2) the real first turn
    for body in (http_response(turn("SUMMARY-OF-OLD-CONTEXT")),
                 http_response(turn("ANSWER-OK"))):
        f.write(bytes([1]) + struct.pack("<I", len(body)) + body)
EOF

rc=0
out=$(timeout 60 ./build/opcode -p "next question" --provider anthropic --model claude-sonnet-4-5 \
        --api-key test --session "$SESS" --replay "$WIRE" 2>&1) || rc=$?
check compact-forced-rc 0 "$rc"
# the summarize turn must consume the first replay response, so the answer
# text proves the records were drained in order
contains compact-forced-answer "ANSWER-OK" "$out"
contains compact-forced-log "opcode: compacted " "$out"
file_contains compact-forced-session '"custom_type":"compaction"' "$SESS"
file_contains compact-forced-json '"first_kept":1' "$SESS"

# no-op: a small transcript must not compact and must still answer
out=$(timeout 60 ./build/opcode -p "hi" --provider anthropic --api-key test \
        --replay tests/data/agent_replay_simple.wire 2>&1)
absent compact-noop-log "compacted" "$out"
contains compact-noop-answer "Simple answer." "$out"

exit $fail
