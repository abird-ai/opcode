#!/bin/sh
# M2 agent tests: deterministic replay, live mock provider, missing-key error.
# usage: tests/agent.sh   (expects build/opcode to be built; run.sh has done that)
set -e
cd "$(dirname "$0")/.."
[ -x build/opcode ] || make -s all
[ -f tests/data/agent_replay.wire ] || python3 tests/gen_agent_replay.py

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
contains() {
    if printf '%s' "$3" | grep -q "$2"; then
        echo "ok   $1"
    else
        echo "FAIL $1"
        printf '  missing: %s\n  in: %s\n' "$2" "$3"
        fail=1
    fi
}

# 1. deterministic replay: text, tool call (bash echo hi), second turn
out=$(timeout 30 ./build/opcode -p "do it" --provider anthropic --api-key test \
        --replay tests/data/agent_replay.wire)
contains agent-replay-text1 "Let me check." "$out"
contains agent-replay-text2 "All done." "$out"

# 2. live mock Anthropic endpoint over loopback HTTP
rm -f build/anthropic.port
python3 tests/mock_anthropic.py > build/anthropic.port &
pid=$!
trap 'kill $pid 2>/dev/null || true' EXIT
i=0
while [ ! -s build/anthropic.port ]; do
    i=$((i + 1))
    [ "$i" -gt 50 ] && { echo "FAIL mock start"; exit 1; }
    sleep 0.1
done
port=$(cat build/anthropic.port)
out=$(timeout 30 ./build/opcode -p "do it" --provider anthropic --model claude-sonnet-4-5 \
        --api-key test --base-url "http://127.0.0.1:$port")
contains agent-live-text1 "Tool said: hi" "$out"
contains agent-live-text2 "All done." "$out"

# 3. missing key is a clean error, not a crash
rc=0
out=$(timeout 30 env -u ANTHROPIC_API_KEY ./build/opcode -p "x" --provider anthropic 2>&1) || rc=$?
check agent-nokey-rc 1 "$rc"
contains agent-nokey-msg "no API key" "$out"

exit $fail
