#!/bin/sh
# tests/update.sh: `opcode update` against a deterministic local JSON release server.
# usage: tests/update.sh   (expects build/opcode to be built; run.sh has done that)
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

v=$(cat VERSION)

sv_pid=""
cleanup() {
    if [ -n "$sv_pid" ]; then
        kill "$sv_pid" 2>/dev/null || true
        wait "$sv_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT

cat > build/update_httpd.py <<'PY'
import http.server
import socketserver
import sys

tag = sys.argv[1]
payload = ('{"tag_name":"%s","html_url":"https://example.com/release/%s"}'
           % (tag, tag)).encode()


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path != "/release":
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)


if __name__ == "__main__":
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("127.0.0.1", 0), H) as srv:
        print(srv.server_address[1], flush=True)
        srv.serve_forever()
PY

# start_server TAG: background server, sv_pid set, port written to build/update.port
start_server() {
    rm -f build/update.port
    python3 build/update_httpd.py "$1" > build/update.port &
    sv_pid=$!
    i=0
    while [ ! -s build/update.port ]; do
        i=$((i + 1))
        [ "$i" -gt 50 ] && { echo "FAIL update httpd start"; return 1; }
        sleep 0.1
    done
}
stop_server() {
    kill "$sv_pid" 2>/dev/null || true
    wait "$sv_pid" 2>/dev/null || true
    sv_pid=""
}

# 1. up-to-date: the tag's leading 'v' must be ignored
start_server "v$v"
port=$(cat build/update.port)
out=$(timeout 30 ./build/opcode update --url "http://127.0.0.1:$port/release" 2>&1) && rc=0 || rc=$?
check update-uptodate-rc 0 "$rc"
check update-uptodate "opcode $v is up to date" "$out"
out=$(timeout 30 ./build/opcode update --check --url "http://127.0.0.1:$port/release" 2>&1) && rc=0 || rc=$?
check update-check "opcode $v is up to date" "$out"
stop_server

# 2. available: human line + download URL, and --json raw body
start_server "v9.9.9"
port=$(cat build/update.port)
out=$(timeout 30 ./build/opcode update --url "http://127.0.0.1:$port/release" 2>&1) && rc=0 || rc=$?
check update-available-rc 0 "$rc"
exp=$(printf 'opcode %s -> v9.9.9 is available\ndownload: https://example.com/release/v9.9.9' "$v")
check update-available "$exp" "$out"
out=$(timeout 30 ./build/opcode update --json --url "http://127.0.0.1:$port/release" 2>&1) && rc=0 || rc=$?
check update-json '{"tag_name":"v9.9.9","html_url":"https://example.com/release/v9.9.9"}' "$out"
stop_server

# 3. offline mode prints and exits 0 without touching the network
out=$(timeout 30 ./build/opcode update --offline 2>&1) && rc=0 || rc=$?
check update-offline-rc 0 "$rc"
check update-offline "opcode: offline" "$out"

# 4. network error -> message on stderr and exit 1
out=$(timeout 30 ./build/opcode update --url "http://127.0.0.1:1/release" 2>&1) && rc=0 || rc=$?
check update-error-rc 1 "$rc"
check update-error "opcode: update check failed" "$out"

exit $fail
