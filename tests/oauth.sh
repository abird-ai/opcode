#!/bin/sh
# OAuth login/logout integration test: tests/mock_oauth.py + the real
# `opcode login|logout` CLI (src/app/login.s), including a live run against an
# inline Anthropic mock that records the Authorization headers.
#
# usage: tests/oauth.sh
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
# Wine tears a killed process down asynchronously, so the fixed callback port
# can still be bound when the next case starts.  Wait (bounded) for it to be
# released; native releases immediately, so this is a no-op there.
wait_port_free() {
    i=0
    while [ "$i" -lt 50 ]; do
        if python3 -c '
import socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    s.bind(("127.0.0.1", 1455))
    s.close()
    sys.exit(0)
except OSError:
    sys.exit(1)
' 2>/dev/null; then
            return 0
        fi
        i=$((i + 1))
        sleep 0.1
    done
    return 0
}

tmp=$(mktemp -d)
pid=""
lpid=""
apid=""
opid=""
hpid=""
cleanup() {
    for p in "$pid" "$lpid" "$apid" "$opid" "$hpid"; do
        [ -n "$p" ] && kill "$p" 2>/dev/null || true
    done
    rm -rf "$tmp"
}
trap cleanup EXIT

mkdir -p "$tmp/cfg/opcode"
export XDG_CONFIG_HOME="$tmp/cfg"
export XDG_DATA_HOME="$tmp/data"
export OAUTH_LOG="$tmp/requests.log"
python3 tests/mock_oauth.py > "$tmp/port" 2> "$tmp/mock.err" &
pid=$!
i=0
while [ ! -s "$tmp/port" ]; do
    i=$((i + 1))
    [ "$i" -gt 50 ] && { echo "FAIL mock start"; cat "$tmp/mock.err"; exit 1; }
    sleep 0.1
done
port=$(cat "$tmp/port")

# ------------------------------------------ built-in authorize URL defaults
# The registered redirect URIs are fixed by the official clients: OpenAI
# localhost:1455/auth/callback, Anthropic localhost:53692/callback. The state
# is the PKCE verifier for Anthropic, random for OpenAI, and both carry the
# provider-specific authorize parameters.
timeout 30 ./build/opcode login openai --no-browser \
    > "$tmp/openai.url.out" 2> "$tmp/openai.url.err" &
opid=$!
i=0
while ! grep -q '^http' "$tmp/openai.url.err" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -gt 100 ] && break
    sleep 0.1
done
ourl=$(grep -m1 '^http' "$tmp/openai.url.err" 2>/dev/null || true)
contains oauth-openai-url-redirect "localhost%3A1455%2Fauth%2Fcallback" "$ourl"
contains oauth-openai-url-codex "codex_cli_simplified_flow=true" "$ourl"
contains oauth-openai-url-organizations "id_token_add_organizations=true" "$ourl"
contains oauth-openai-url-originator "originator=opcode" "$ourl"
if [ -n "$ourl" ] && python3 - "$ourl" <<'PY'
import sys, urllib.error, urllib.parse, urllib.request

redirect = urllib.parse.parse_qs(urllib.parse.urlparse(sys.argv[1]).query)["redirect_uri"][0]
try:
    urllib.request.urlopen(redirect + "?code=x&state=y", timeout=5)
except urllib.error.HTTPError as e:
    if e.code == 400:          # wrong state, but the 1455 listener answered
        print("ok   oauth-openai-bound-1455")
        sys.exit(0)
print("FAIL oauth-openai-bound-1455")
sys.exit(1)
PY
then
    :
else
    fail=1
fi
kill "$opid" 2>/dev/null || true
wait "$opid" 2>/dev/null || true
opid=""
wait_port_free

# ------------------------------------------- loopback server robustness
# The callback listener must survive everything a browser throws at it before
# the real redirect (Happy-Eyeballs preconnect, favicon, HEAD, torn request)
# and must answer on ::1 as well as 127.0.0.1. These cases fail on the old
# IPv4-only single-accept server: the first stray connection closed the
# listener, so the callback got ECONNREFUSED exactly like the browser did.
have_ipv6() {
    python3 - <<'PY'
import socket
try:
    s = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
    s.bind(("::1", 0))
    s.close()
    print("yes")
except OSError:
    print("no")
PY
}
callback_status() { # url -> HTTP status, 000 when the connection failed
    curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1" 2>/dev/null || true
}
start_fixed_login() { # `login openai --no-browser`, wait for the printed URL
    timeout 30 ./build/opcode login openai --no-browser \
        > "$tmp/fixed.out" 2> "$tmp/fixed.err" &
    opid=$!
    i=0
    while ! grep -q '^http' "$tmp/fixed.err" 2>/dev/null; do
        i=$((i + 1))
        [ "$i" -gt 100 ] && { echo "FAIL fixed login url"; cat "$tmp/fixed.err"; return 1; }
        sleep 0.1
    done
    return 0
}
stop_fixed_login() {
    kill "$opid" 2>/dev/null || true
    wait "$opid" 2>/dev/null || true
    opid=""
    wait_port_free
}

if [ "$(have_ipv6)" = yes ]; then
    start_fixed_login || fail=1
    v6=$(callback_status "http://[::1]:1455/auth/callback?code=x&state=y")
    check oauth-openai-bound-ipv6 400 "$v6"
    stop_fixed_login
else
    echo "skip oauth-openai-bound-ipv6 (no ::1 on this host)"
fi

start_fixed_login || fail=1
python3 - <<'PY'
import socket
for host in ("127.0.0.1", "::1"):
    try:
        s = socket.create_connection((host, 1455), timeout=3)
        s.close()               # bare preconnect: connect, send nothing, close
    except OSError:
        pass
PY
pre=$(callback_status "http://localhost:1455/auth/callback?code=x&state=y")
check oauth-openai-preconnect-survives 400 "$pre"
stop_fixed_login

start_fixed_login || fail=1
fav=$(callback_status "http://localhost:1455/favicon.ico")
cb=$(callback_status "http://localhost:1455/auth/callback?code=x&state=y")
check oauth-openai-favicon-404 404 "$fav"
check oauth-openai-favicon-survives 400 "$cb"
stop_fixed_login

start_fixed_login || fail=1
head=$(curl -s -I -o /dev/null -w '%{http_code}' --max-time 5 \
    "http://localhost:1455/auth/callback" 2>/dev/null || true)
cb=$(callback_status "http://localhost:1455/auth/callback?code=x&state=y")
check oauth-openai-head-404 404 "$head"
check oauth-openai-head-survives 400 "$cb"
stop_fixed_login

start_fixed_login || fail=1
python3 - <<'PY'
import socket
s = socket.create_connection(("127.0.0.1", 1455), timeout=3)
s.sendall(b"GET /auth/call")     # torn request line, then close
s.close()
PY
cb=$(callback_status "http://localhost:1455/auth/callback?code=x&state=y")
check oauth-openai-incomplete-survives 400 "$cb"
stop_fixed_login

# the wait budget can be shortened for tests; expiry must be clear and non-zero
t0=$(date +%s)
rc=0
out=$(OPCODE_OAUTH_WAIT_MS=500 timeout 20 ./build/opcode login openai --no-browser 2>&1) || rc=$?
t1=$(date +%s)
check oauth-timeout-rc 1 "$rc"
contains oauth-timeout-msg "timed out waiting for the browser callback" "$out"
if [ $((t1 - t0)) -le 5 ]; then
    echo "ok   oauth-timeout-quick"
else
    echo "FAIL oauth-timeout-quick (took $((t1 - t0))s)"
    fail=1
fi

timeout 30 ./build/opcode login anthropic --no-browser \
    > "$tmp/anthropic.url.out" 2> "$tmp/anthropic.url.err" &
opid=$!
i=0
while ! grep -q '^http' "$tmp/anthropic.url.err" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -gt 100 ] && break
    sleep 0.1
done
aurl=$(grep -m1 '^http' "$tmp/anthropic.url.err" 2>/dev/null || true)
contains oauth-anthropic-url-redirect "localhost%3A53692%2Fcallback" "$aurl"
contains oauth-anthropic-url-code "code=true" "$aurl"
if [ -n "$aurl" ] && python3 - "$aurl" <<'PY'
import sys, urllib.error, urllib.parse, urllib.request

redirect = urllib.parse.parse_qs(urllib.parse.urlparse(sys.argv[1]).query)["redirect_uri"][0]
try:
    urllib.request.urlopen(redirect + "?code=x&state=y", timeout=5)
except urllib.error.HTTPError as e:
    if e.code == 400:          # wrong state, but the 53692 listener answered
        print("ok   oauth-anthropic-bound-53692")
        sys.exit(0)
print("FAIL oauth-anthropic-bound-53692")
sys.exit(1)
PY
then
    :
else
    fail=1
fi
kill "$opid" 2>/dev/null || true
wait "$opid" 2>/dev/null || true
opid=""

# a busy fixed port must be a clear error, never a silent fallback
python3 -c '
import socket, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 1455))
s.listen(1)
time.sleep(30)
' > /dev/null 2>&1 &
hpid=$!
sleep 0.3
rc=0
out=$(timeout 30 ./build/opcode login openai --no-browser 2>&1) || rc=$?
kill "$hpid" 2>/dev/null || true
wait "$hpid" 2>/dev/null || true
hpid=""
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'cannot bind port 1455'; then
    echo "ok   oauth-openai-port-busy"
else
    echo "FAIL oauth-openai-port-busy"
    printf '  rc=%s out=%s\n' "$rc" "$out"
    fail=1
fi

authf="$tmp/cfg/opcode/auth.jsonc"
# pre-seed another provider so login has to merge, not clobber
printf '%s\n' '{"openai":{"api_key":"KEEP-ME"}}' > "$authf"

# ---------------------------------------------------------------- login
timeout 30 ./build/opcode login anthropic \
    --oauth-auth-url "http://127.0.0.1:$port/authorize" \
    --oauth-token-url "http://127.0.0.1:$port/token" \
    --oauth-client-id test-client --oauth-scope test-scope --no-browser \
    > "$tmp/login.out" 2> "$tmp/login.err" &
lpid=$!
i=0
while ! grep -q '^http' "$tmp/login.err" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -gt 100 ] && { echo "FAIL login url"; cat "$tmp/login.err"; exit 1; }
    sleep 0.1
done
url=$(grep -m1 '^http' "$tmp/login.err")
# the mock 302s back to the loopback redirect_uri with code=TESTCODE
python3 - "$url" <<'PY'
import sys, urllib.request
urllib.request.urlopen(sys.argv[1]).read()
PY
rc=0
wait "$lpid" || rc=$?
lpid=""
check oauth-login-rc 0 "$rc"
contains oauth-login-msg "logged in to anthropic" "$(cat "$tmp/login.out")"

# ---------------------------------------------------------------- store
if [ -f "$authf" ]; then
    echo "ok   oauth-store-exists"
else
    echo "FAIL oauth-store-exists"
    fail=1
fi
python3 - "$authf" <<'PY'
import json, os, sys, time
d = json.load(open(sys.argv[1]))
t = d["anthropic"]["oauth"]
assert t["access_token"] == "ACCESS-TEST-TOKEN", t
assert t["refresh_token"] == "REFRESH-TEST-TOKEN", t
assert t["account_id"] == "acct-test", t
assert int(t["expires_at"]) > time.time() * 1000 + 300000, t
assert oct(os.stat(sys.argv[1]).st_mode & 0o777) == "0o600", oct(os.stat(sys.argv[1]).st_mode)
assert d["openai"]["api_key"] == "KEEP-ME", d
print("ok   oauth-store")
PY

# ---------------------------------------------------------------- PKCE
if grep -q 'code_challenge_method=S256' "$tmp/requests.log" \
   && grep -q 'code_verifier' "$tmp/requests.log"; then
    echo "ok   oauth-pkce"
else
    echo "FAIL oauth-pkce"
    fail=1
fi
# Anthropic exchanges a JSON body with state=verifier (Anthropic's postJson shape)
if grep -q '"grant_type":"authorization_code"' "$tmp/requests.log" \
   && grep -q '"code_verifier":"' "$tmp/requests.log" \
   && grep -q '"state":"' "$tmp/requests.log"; then
    echo "ok   oauth-anthropic-json-body"
else
    echo "FAIL oauth-anthropic-json-body"
    fail=1
fi

# ---------------------------------------------- openai form token exchange
# OpenAI posts a form body and uses an ephemeral
# loopback port only because the auth URL is overridden for the mock.
timeout 30 ./build/opcode login openai \
    --oauth-auth-url "http://127.0.0.1:$port/authorize" \
    --oauth-token-url "http://127.0.0.1:$port/token" \
    --oauth-client-id test-client --oauth-scope test-scope --no-browser \
    > "$tmp/ologin.out" 2> "$tmp/ologin.err" &
lpid=$!
i=0
while ! grep -q '^http' "$tmp/ologin.err" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -gt 100 ] && { echo "FAIL oauth-openai-login-url"; cat "$tmp/ologin.err"; exit 1; }
    sleep 0.1
done
ourl2=$(grep -m1 '^http' "$tmp/ologin.err")
python3 - "$ourl2" <<'PY'
import sys, urllib.request
urllib.request.urlopen(sys.argv[1]).read()
PY
rc=0
wait "$lpid" || rc=$?
lpid=""
check oauth-openai-login-rc 0 "$rc"
contains oauth-openai-login-msg "logged in to openai" "$(cat "$tmp/ologin.out")"
if grep -q 'POST /token grant_type=authorization_code' "$tmp/requests.log"; then
    echo "ok   oauth-openai-form-body"
else
    echo "FAIL oauth-openai-form-body"
    fail=1
fi
python3 - "$authf" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
t = d["openai"]["oauth"]
assert t["access_token"] == "ACCESS-TEST-TOKEN", t
assert t["refresh_token"] == "REFRESH-TEST-TOKEN", t
print("ok   oauth-openai-store")
PY

# ------------------------------ obstacle course still completes the login
# Same mock-backed run as above, but the loopback server first sees the full
# browser-noise sequence (preconnect, favicon, HEAD, torn request); the token
# exchange and the 0600 atomic auth.jsonc write must still complete.
timeout 30 ./build/opcode login openai \
    --oauth-auth-url "http://127.0.0.1:$port/authorize" \
    --oauth-token-url "http://127.0.0.1:$port/token" \
    --oauth-client-id test-client --oauth-scope test-scope --no-browser \
    > "$tmp/obstacles.out" 2> "$tmp/obstacles.err" &
lpid=$!
i=0
while ! grep -q '^http' "$tmp/obstacles.err" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -gt 100 ] && { echo "FAIL oauth-obstacles url"; cat "$tmp/obstacles.err"; exit 1; }
    sleep 0.1
done
oburl=$(grep -m1 '^http' "$tmp/obstacles.err")
obredir=$(python3 - "$oburl" <<'PY'
import sys, urllib.parse
print(urllib.parse.parse_qs(urllib.parse.urlparse(sys.argv[1]).query)["redirect_uri"][0])
PY
)
python3 - "$obredir" <<'PY'
import socket, sys, urllib.parse, urllib.request, urllib.error
u = urllib.parse.urlparse(sys.argv[1])
base = "http://%s:%d" % (u.hostname, u.port)
try:
    s = socket.create_connection((u.hostname, u.port), timeout=3)
    s.close()                                    # preconnect
except OSError:
    pass
try:
    urllib.request.urlopen(base + "/favicon.ico", timeout=3)
except urllib.error.HTTPError as e:
    assert e.code == 404, e.code
except OSError:
    pass
try:
    urllib.request.urlopen(urllib.request.Request(base + "/auth/callback",
        method="HEAD"), timeout=3)
except urllib.error.HTTPError as e:
    assert e.code == 404, e.code
except OSError:
    pass
try:
    s = socket.create_connection((u.hostname, u.port), timeout=3)
    s.sendall(b"GET /auth/call")
    s.close()                                    # torn request
except OSError:
    pass
PY
# the mock /authorize 302s to the loopback with the recorded state
python3 - "$oburl" <<'PY'
import sys, urllib.request
urllib.request.urlopen(sys.argv[1]).read()
PY
rc=0
wait "$lpid" || rc=$?
lpid=""
check oauth-obstacles-login-rc 0 "$rc"
contains oauth-obstacles-login-msg "logged in to openai" "$(cat "$tmp/obstacles.out")"
python3 - "$authf" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1]))
t = d["openai"]["oauth"]
assert t["access_token"] == "ACCESS-TEST-TOKEN", t
assert oct(os.stat(sys.argv[1]).st_mode & 0o777) == "0o600"
print("ok   oauth-obstacles-store")
PY

# ------------------------------------------------- live token use (auth_key)
# Inline Anthropic mock: records the request headers, replies with one text
# turn. The stored OAuth credential must win over env/config (none here).
cat > "$tmp/anthropic_mock.py" <<'PY'
import http.server, socketserver, sys
log = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        self.rfile.read(n)
        with open(log, "a") as f:
            f.write("auth=" + self.headers.get("Authorization", "") + "\n")
            f.write("beta=" + self.headers.get("anthropic-beta", "") + "\n")
        sse = "\n\n".join([
            'event: message_start\ndata: {"type":"message_start","message":{"id":"m","usage":{"input_tokens":1,"output_tokens":1}}}',
            'event: content_block_start\ndata: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}',
            'event: content_block_delta\ndata: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"oauth-ok"}}',
            'event: content_block_stop\ndata: {"type":"content_block_stop","index":0}',
            'event: message_delta\ndata: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}',
            'event: message_stop\ndata: {"type":"message_stop"}',
        ]).encode() + b"\n\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(sse)))
        self.end_headers()
        self.wfile.write(sse)
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", 0), H) as srv:
    print(srv.server_address[1], flush=True)
    srv.serve_forever()
PY
python3 "$tmp/anthropic_mock.py" "$tmp/headers.log" > "$tmp/aport" 2> "$tmp/amock.err" &
apid=$!
i=0
while [ ! -s "$tmp/aport" ]; do
    i=$((i + 1))
    [ "$i" -gt 50 ] && { echo "FAIL anthro mock start"; cat "$tmp/amock.err"; exit 1; }
    sleep 0.1
done
aport=$(cat "$tmp/aport")
rc=0
out=$(timeout 30 env -u ANTHROPIC_API_KEY ./build/opcode -p "hi" --provider anthropic \
        --no-session --base-url "http://127.0.0.1:$aport" 2>&1) || rc=$?
check oauth-live-rc 0 "$rc"
contains oauth-live-text "oauth-ok" "$out"
contains oauth-live-bearer "Bearer ACCESS-TEST-TOKEN" "$(cat "$tmp/headers.log" 2>/dev/null || true)"
contains oauth-live-beta "oauth-2025-04-20" "$(cat "$tmp/headers.log" 2>/dev/null || true)"
kill "$apid" 2>/dev/null || true
wait "$apid" 2>/dev/null || true
apid=""

# ---------------------------------------------------------------- logout
out=$(timeout 30 ./build/opcode logout anthropic)
contains oauth-logout-msg "removed stored credential for anthropic" "$out"
python3 - "$authf" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert "anthropic" not in d, d
assert d["openai"]["api_key"] == "KEEP-ME", d
print("ok   oauth-logout-keeps-other")
PY
# logout clears both the OAuth credential and the stored api_key, so a provider
# that only had an api_key is dropped entirely
out=$(timeout 30 ./build/opcode logout openai)
contains oauth-logout-openai "removed stored credential for openai" "$out"
python3 - "$authf" <<'PY'
import json, os, sys
path = sys.argv[1]
if os.path.exists(path):
    d = json.load(open(path))
    assert "openai" not in d or "api_key" not in d.get("openai", {}), d
print("ok   oauth-logout-openai-clears-key")
PY

# ---------------------------------------------------------------- expiry
printf '%s\n' '{"anthropic":{"oauth":{"access_token":"EXPIRED","refresh_token":"R","expires_at":1}}}' > "$authf"
rc=0
out=$(timeout 30 env -u ANTHROPIC_API_KEY ./build/opcode -p "hi" --provider anthropic \
        --no-session 2>&1) || rc=$?
check oauth-expired-rc 1 "$rc"
contains oauth-expired-msg "no API key" "$out"
timeout 30 ./build/opcode logout anthropic > /dev/null
if [ -e "$authf" ]; then
    echo "FAIL oauth-expired-cleanup"
    fail=1
else
    echo "ok   oauth-expired-cleanup"
fi

exit $fail
