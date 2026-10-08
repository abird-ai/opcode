#!/bin/sh
# MCP stdio client tests: mcp.jsonc discovery + handshake + tools/call, and the
# no-config no-op. usage: tests/mcp.sh (expects build/opcode to be built).
set -e
cd "$(dirname "$0")/.."
[ -x build/opcode ] || make -s all
[ -f tests/data/mcp_replay.wire ] || python3 tests/gen_mcp_replay.py

fail=0
contains() {
    if printf '%s' "$3" | grep -q "$2"; then
        echo "ok   $1"
    else
        echo "FAIL $1"
        printf '  missing: %s\n  in: %s\n' "$2" "$3"
        fail=1
    fi
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/cfg/opcode"
log="$tmp/mock.log"
cat > "$tmp/cfg/opcode/mcp.jsonc" <<EOF
{"servers":{"mock":{"command":"python3",
  "args":["$PWD/tests/mock_mcp.py"],
  "env":{"MCP_MOCK_LOG":"$log"}}}}
EOF

out=$(XDG_CONFIG_HOME="$tmp/cfg" XDG_DATA_HOME="$tmp/data" \
    timeout 30 ./build/opcode -p "use the echo tool" --provider anthropic --api-key test \
    --replay tests/data/mcp_replay.wire --no-session)
contains mcp-final-text "echo:hello" "$out"
contains mcp-initialize '"method":"initialize"' "$(cat "$log" 2>/dev/null || true)"
contains mcp-tools-list '"method":"tools/list"' "$(cat "$log" 2>/dev/null || true)"
contains mcp-tools-call '"method":"tools/call"' "$(cat "$log" 2>/dev/null || true)"
contains mcp-call-args '"text": *"hello"' "$(cat "$log" 2>/dev/null || true)"

# no mcp.jsonc: mcp_start is a no-op and the replay stays a plain single turn
mkdir -p "$tmp/nocfg"
out=$(XDG_CONFIG_HOME="$tmp/nocfg" XDG_DATA_HOME="$tmp/data" \
    timeout 30 ./build/opcode -p "hi" --provider anthropic --api-key test \
    --replay tests/data/agent_replay_simple.wire --no-session)
contains mcp-no-config "Simple answer." "$out"

# an MCP server that exits immediately must yield an error, not SIGPIPE-kill
# opcode (the request write hits a closed pipe during the handshake)
mkdir -p "$tmp/deadcfg/opcode"
cat > "$tmp/deadcfg/opcode/mcp.jsonc" <<EOF
{"servers":{"mock":{"command":"sh","args":["-c","exit 0"],"env":{}}}}
EOF
rc=0
out=$(XDG_CONFIG_HOME="$tmp/deadcfg" XDG_DATA_HOME="$tmp/data" \
    timeout 30 ./build/opcode -p "use the echo tool" --provider anthropic --api-key test \
    --replay tests/data/mcp_replay.wire --no-session 2>&1) || rc=$?
if [ "$rc" = 0 ]; then
    echo "ok   mcp-dead-server"
else
    echo "FAIL mcp-dead-server (rc $rc)"
    printf '%s\n' "$out" | head -5
    fail=1
fi

exit $fail
