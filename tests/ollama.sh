#!/bin/sh
# Ollama integration test: local chat with no API key, no Authorization header,
# and runtime model discovery against tests/mock_ollama.py.
#
# Discovery must use the OpenAI-compatible /v1/models endpoint for the local
# provider; a second mock whose /v1/models 404s verifies the native /api/tags
# fallback.
#
# usage: tests/ollama.sh
set -e
cd "$(dirname "$0")/.."

HOST=$(uname -s 2>/dev/null || echo unknown)
EMULATOR=${EMULATOR:-}
own_wrapper=

# Harness timeouts (never an assertion): qemu-user runs the guest 5-50x
# slower, so the emulation mode scales them by tests/run.sh's factor.
to=30
if [ "${OPCODE_TARGET:-}" = "linux-aarch64" ]; then
    scale=${EMU_TIMEOUT_SCALE:-10}
    to=$((to * scale))
fi

# The live-discovery helper is tests/discover_test.s built with OPCODE_LIVE
# defined, so it uses the real network stack.  Linux keeps the original static
# x86-64 GNU as/ld build (a Mach-O host cannot use that toolchain); Darwin asks
# the Makefile for the Mach-O arm64 helper, whose recipe owns the cross-detail;
# linux-aarch64 asks the Makefile for the translated aarch64 helper (cross
# as/ld over the aarch64 object tree) and runs everything under $EMULATOR.
if [ "$HOST" = "Darwin" ]; then
    live=build/mac/tests/discover_live
    if [ ! -x build/opcode ]; then
        make -s darwin-arm64
        ln -sf opcode-darwin-arm64 build/opcode
    fi
    make -s darwin-arm64-discover-live
elif [ "${OPCODE_TARGET:-}" = "linux-aarch64" ]; then
    live=build/a64/tests/discover_live
    [ -n "$EMULATOR" ] || EMULATOR=qemu-aarch64
    if [ ! -x build/opcode ]; then
        # Standalone run (tests/run.sh installs its own wrapper for the full
        # suite): build the aarch64 app and put a temporary emulator wrapper at
        # ./build/opcode for the chat checks below.  Only remove what this
        # script installed.
        make -s linux-aarch64
        cat > build/opcode <<SH
#!/usr/bin/env bash
# Temporary emulator exec wrapper installed by tests/ollama.sh
# (OPCODE_TARGET=linux-aarch64); removed on exit.  bash, not sh: the stderr
# filter uses process substitution.
#
# qemu-user 11.1.1 writes its own "qemu: uncaught target signal N (...) -
# core dumped" line to stderr when a guest dies of a signal — emulator noise,
# not program output (the guest's exit status and real output are untouched).
# Filter exactly that line from stderr only; the exec preserves the exit code.
exec $EMULATOR "$PWD/build/opcode-linux-aarch64" "\$@" \\
    2> >(grep --line-buffered -v '^qemu: uncaught target signal .* - core dumped\$' >&2)
SH
        chmod +x build/opcode
        own_wrapper=1
    fi
    make -s linux-aarch64-discover-live
else
    live=build/discover_live
    [ -x build/opcode ] || make -s all
    # real-net objects (all) + mock test objects (discover_test)
    make -s all test > /dev/null 2>&1 || true
    objs=$(find build/obj -name '*.o' ! -path 'build/obj/src/app/*' \
           ! -path 'build/obj/src/net/mock.o' ! -path 'build/obj/tests/*')
    as --64 -I src -I build -g --defsym OPCODE_LIVE=1 \
       -o build/obj/tests/discover_live.o tests/discover_test.s
    # shellcheck disable=SC2086
    ld -static -nostdlib --no-dynamic-linker -z noexecstack \
       -o "$live" build/obj/tests/discover_live.o $objs
fi

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
require() { # okline needle haystack
    if printf '%s' "$3" | grep -q "$2"; then
        echo "$1"
    else
        echo "FAIL $1"
        printf '  missing: %s\n  in: %s\n' "$2" "$3"
        fail=1
    fi
}

tmp=$(mktemp -d)
pid=""
pid2=""
cleanup() {
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    [ -n "$pid2" ] && kill "$pid2" 2>/dev/null || true
    if [ -n "$own_wrapper" ]; then
        rm -f build/opcode
    fi
    rm -rf "$tmp"
}
trap cleanup EXIT

mkdir -p "$tmp/cfg/opcode"
export XDG_CONFIG_HOME="$tmp/cfg"
export OLLAMA_LOG="$tmp/ollama.log"

python3 tests/mock_ollama.py > "$tmp/port" 2> "$tmp/mock.err" &
pid=$!
i=0
while [ ! -s "$tmp/port" ]; do
    i=$((i + 1))
    [ "$i" -gt 50 ] && { echo "FAIL mock start"; cat "$tmp/mock.err"; exit 1; }
    sleep 0.1
done
port=$(cat "$tmp/port")

# ---------------------------------------------------------------- local chat
# no --api-key: the MDF_NO_KEY model must run and answer
rc=0
out=$(timeout "$to" env -u OLLAMA_API_KEY ./build/opcode -p "hi" --provider ollama \
        --model llama3.2 --base-url "http://127.0.0.1:$port/v1" --no-session 2>&1) || rc=$?
check ollama-chat-rc 0 "$rc"
require "ollama chat ok" "Hello from Ollama!" "$out"

# ---------------------------------------------------------------- no auth
if grep -q '^POST /v1/chat/completions endpoint=chat auth=$' "$tmp/ollama.log" 2>/dev/null; then
    echo "ollama no-auth ok"
else
    echo "FAIL ollama no-auth ok"
    printf '  log: %s\n' "$(cat "$tmp/ollama.log" 2>/dev/null || true)"
    fail=1
fi

# ------------------------------------------------- live model discovery
# helper already built above (Linux: static x86-64 ELF; Darwin: Mach-O arm64),
# pointed at the running server

# primary path: <base>/models (the mock's OpenAI-compatible endpoint)
rc=0
out=$(timeout "$to" env -u OLLAMA_API_KEY $EMULATOR "./$live" "http://127.0.0.1:$port/v1" 2>&1) || rc=$?
check discover-live-rc 0 "$rc"
require "discover primary ok" "discover tags ok" "$out"
require "discover /v1/models used" \
    "GET /v1/models endpoint=models auth=$" "$(cat "$tmp/ollama.log")"
if grep -q '^GET /api/tags' "$tmp/ollama.log"; then
    echo "FAIL discover primary used native fallback"
    fail=1
else
    echo "discover primary endpoint ok"
fi
if [ -f "$tmp/cfg/opcode/models.jsonc" ] && python3 - "$tmp/cfg/opcode/models.jsonc" <<'PY'
import json, sys
with open(sys.argv[1]) as handle:
    data = json.load(handle)
assert data.get("discovered_at", 0) > 0, data
ids = [m["id"] for m in data["models"]]
assert "llama3.2:latest" in ids, ids
assert "qwen2.5:7b" in ids, ids
PY
then
    echo "discover cache ok"
else
    echo "FAIL discover cache ok"
    fail=1
fi

# ------------------------------------------------- native fallback
# a second mock 404s /v1/models but serves /api/tags: discovery must still find
# both models through the native parser
export OLLAMA_LOG="$tmp/ollama_fallback.log"
OLLAMA_NO_V1_MODELS=1 python3 tests/mock_ollama.py > "$tmp/port2" 2> "$tmp/mock2.err" &
pid2=$!
i=0
while [ ! -s "$tmp/port2" ]; do
    i=$((i + 1))
    [ "$i" -gt 50 ] && { echo "FAIL fallback mock start"; cat "$tmp/mock2.err"; exit 1; }
    sleep 0.1
done
port2=$(cat "$tmp/port2")

export XDG_CONFIG_HOME="$tmp/cfg2"
mkdir -p "$tmp/cfg2/opcode"
rc=0
out=$(timeout "$to" env -u OLLAMA_API_KEY $EMULATOR "./$live" "http://127.0.0.1:$port2/v1" 2>&1) || rc=$?
check discover-fallback-rc 0 "$rc"
require "discover fallback ok" "discover tags ok" "$out"
require "discover fallback tried /v1/models" \
    "GET /v1/models endpoint=models auth=$" "$(cat "$tmp/ollama_fallback.log")"
require "discover fallback used /api/tags" \
    "GET /api/tags endpoint=tags auth=$" "$(cat "$tmp/ollama_fallback.log")"
if [ -f "$tmp/cfg2/opcode/models.jsonc" ] && python3 - "$tmp/cfg2/opcode/models.jsonc" <<'PY'
import json, sys
with open(sys.argv[1]) as handle:
    data = json.load(handle)
ids = [m["id"] for m in data["models"]]
assert "llama3.2:latest" in ids, ids
assert "qwen2.5:7b" in ids, ids
PY
then
    echo "discover fallback cache ok"
else
    echo "FAIL discover fallback cache ok"
    fail=1
fi

echo "ollama done"
exit $fail
