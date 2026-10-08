#!/usr/bin/env python3
"""Mock OAuth IdP for tests/oauth.sh.

GET  /authorize -> 302 to the caller's redirect_uri with
                   ?code=TESTCODE&state=<echo>
POST /token     -> JSON {access_token, refresh_token, expires_in, account_id}
                   accepting application/json and x-www-form-urlencoded
                   (400 invalid_grant when the PKCE S256 challenge recorded at
                   /authorize does not match base64url(sha256(code_verifier)))

Requests are appended to $OAUTH_LOG when that variable is set. The port is
printed on stdout so the shell can point the client at it. Set OAUTH_PORT to
bind a fixed port instead of an ephemeral one; $OAUTH_LOG bodies are logged
verbatim so the tests can tell JSON and form requests apart.
"""
import base64
import hashlib
import http.server
import json
import os
import socketserver
import urllib.parse

LOG = os.environ.get("OAUTH_LOG")
challenges = {}


def log(line):
    if LOG:
        with open(LOG, "a") as f:
            f.write(line + "\n")


def parse_body(ctype, raw):
    """Return a flat {key: value} dict from a JSON or form request body."""
    if "json" in ctype:
        try:
            data = json.loads(raw)
        except ValueError:
            return {}
        if not isinstance(data, dict):
            return {}
        return {k: str(v) for k, v in data.items()}
    return {k: v[0] for k, v in urllib.parse.parse_qs(raw).items()}


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _send(self, code, ctype, body):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        qs = urllib.parse.parse_qs(u.query)
        log("GET " + self.path)
        if u.path != "/authorize":
            self._send(404, "text/plain", b"not found")
            return
        redirect_uri = qs.get("redirect_uri", [""])[0]
        state = qs.get("state", [""])[0]
        if not redirect_uri:
            self._send(400, "text/plain", b"missing redirect_uri")
            return
        challenges[state] = qs.get("code_challenge", [""])[0]
        sep = "&" if "?" in redirect_uri else "?"
        loc = redirect_uri + sep + urllib.parse.urlencode(
            {"code": "TESTCODE", "state": state})
        self.send_response(302)
        self.send_header("Location", loc)
        self.send_header("Content-Length", "0")
        self.send_header("Connection", "close")
        self.end_headers()

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(n).decode()
        log("POST " + self.path + " " + raw)
        if self.path != "/token":
            self._send(404, "text/plain", b"not found")
            return
        body = parse_body(self.headers.get("Content-Type", ""), raw)
        if body.get("grant_type") == "refresh_token":
            if not body.get("refresh_token"):
                self._send(400, "application/json",
                           json.dumps({"error": "invalid_grant"}).encode())
                return
            self._send(200, "application/json", json.dumps({
                "access_token": "ACCESS-REFRESHED-TOKEN",
                "refresh_token": "REFRESH-TEST-TOKEN",
                "token_type": "Bearer",
                "expires_in": 3600,
            }).encode())
            return
        verifier = body.get("code_verifier", "")
        got = base64.urlsafe_b64encode(
            hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
        if body.get("grant_type") != "authorization_code" \
                or got not in challenges.values():
            self._send(400, "application/json",
                       json.dumps({"error": "invalid_grant"}).encode())
            return
        self._send(200, "application/json", json.dumps({
            "access_token": "ACCESS-TEST-TOKEN",
            "refresh_token": "REFRESH-TEST-TOKEN",
            "token_type": "Bearer",
            "expires_in": 3600,
            "account_id": "acct-test",
        }).encode())


if __name__ == "__main__":
    socketserver.TCPServer.allow_reuse_address = True
    port = int(os.environ.get("OAUTH_PORT", "0"))
    with socketserver.TCPServer(("127.0.0.1", port), H) as srv:
        print(srv.server_address[1], flush=True)
        srv.serve_forever()
