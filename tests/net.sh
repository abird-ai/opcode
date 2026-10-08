#!/bin/sh
# M1 integration tests: real HTTP through the live client, SSE, record/replay.
# usage: tests/net.sh   (expects build/opcode to be built; run.sh has done that)
set -e
cd "$(dirname "$0")/.."
[ -x build/opcode ] || make -s all

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
contains() { # name needle haystack
    if printf '%s' "$3" | grep -q "$2"; then
        echo "ok   $1"
    else
        echo "FAIL $1"
        printf '  missing: %s\n  in: %s\n' "$2" "$3"
        fail=1
    fi
}

rm -f build/httpd.port
python3 tests/httpd.py > build/httpd.port &
pid=$!
rm -f build/tlsd.port
python3 tests/tlsd.py > build/tlsd.port &
tlsd_pid=$!
trap 'kill $pid $tlsd_pid 2>/dev/null || true' EXIT
i=0
while [ ! -s build/httpd.port ]; do
    i=$((i + 1))
    [ "$i" -gt 50 ] && { echo "FAIL httpd start"; exit 1; }
    sleep 0.1
done
port=$(cat build/httpd.port)
i=0
while [ ! -s build/tlsd.port ]; do
    i=$((i + 1))
    [ "$i" -gt 50 ] && { echo "FAIL tlsd start"; exit 1; }
    sleep 0.1
done
tls_port=$(cat build/tlsd.port)

# 1. plain HTTP GET
out=$(timeout 30 ./build/opcode fetch "http://127.0.0.1:$port/hello")
check net-get-status "status 200" "$(printf '%s\n' "$out" | head -1)"
contains net-get-body "^hello world$" "$(printf '%s\n' "$out" | tail -1)"

# 2. POST echo
out=$(timeout 30 ./build/opcode fetch --data '{"a":1}' "http://127.0.0.1:$port/echo")
contains net-post-body '^\{"a":1\}$' "$(printf '%s\n' "$out" | tail -1)"

# 2b. chunked transfer encoding through the shared client
out=$(timeout 30 ./build/opcode fetch "http://127.0.0.1:$port/chunked")
contains net-chunked-body '^hello chunked body$' "$(printf '%s\n' "$out" | tail -1)"

# 2c. TLS: an untrusted certificate fails verification with the TLS reason;
# --insecure completes the same request
rc=0
out=$(timeout 30 ./build/opcode fetch "https://127.0.0.1:$tls_port/tls" 2>&1) || rc=$?
check net-tls-verify-rc 1 "$rc"
contains net-tls-verify-msg "TLS error" "$out"
out=$(timeout 30 ./build/opcode fetch --insecure "https://127.0.0.1:$tls_port/tls")
contains net-tls-insecure-body '^tls hello$' "$(printf '%s\n' "$out" | tail -1)"

# 3. SSE
out=$(timeout 30 ./build/opcode fetch "http://127.0.0.1:$port/sse")
contains net-sse-1 '^\[delta\] he$' "$out"
contains net-sse-2 '^\[delta\] llo$' "$out"
contains net-sse-3 '^\[done\] \[DONE\]$' "$out"

# 4. record then replay, identical output
timeout 30 ./build/opcode fetch --record build/net.rec "http://127.0.0.1:$port/hello" >/dev/null
out=$(timeout 30 ./build/opcode fetch --replay build/net.rec "http://127.0.0.1:$port/hello")
check net-replay-status "status 200" "$(printf '%s\n' "$out" | head -1)"
contains net-replay-body "^hello world$" "$(printf '%s\n' "$out" | tail -1)"

# 5. short body: Content-Length promises 10 bytes, the peer sends 3
# (the partial body is streamed, but the fetch must fail with the reason)
rc=0
out=$(timeout 30 ./build/opcode fetch "http://127.0.0.1:$port/truncated" 2>&1) || rc=$?
check net-truncated-rc 1 "$rc"
contains net-truncated-msg "truncated response" "$out"

# 6. overflowing Content-Length is refused, never a silent empty body
rc=0
out=$(timeout 30 ./build/opcode fetch "http://127.0.0.1:$port/clover" 2>&1) || rc=$?
check net-clover-rc 1 "$rc"
contains net-clover-msg "response too large" "$out"

exit $fail
