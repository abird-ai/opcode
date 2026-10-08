#!/usr/bin/env python3
"""Tiny deterministic HTTP server for tests/net.sh. Prints its port, then serves:
   GET  /hello -> "hello world\\n"
   GET  /sse   -> three server-sent events
   POST /echo  -> echoes the request body as application/json
"""
import http.server
import socketserver
import sys


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
        if self.path == "/sse":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers()
            for name, data in (("delta", "he"), ("delta", "llo"), ("done", "[DONE]")):
                self.wfile.write(f"event: {name}\ndata: {data}\n\n".encode())
                self.wfile.flush()
            return
        if self.path == "/chunked":
            # Transfer-Encoding: chunked, split across two writes; the shared
            # client must reassemble and finish on the last chunk.
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Transfer-Encoding", "chunked")
            self.send_header("Connection", "close")
            self.end_headers()
            for part in (b"hello ", b"chunked body\n"):
                self.wfile.write(b"%x\r\n" % len(part) + part + b"\r\n")
                self.wfile.flush()
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
            return
        if self.path == "/truncated":
            # Promise 10 bytes, send 3, close: the parser must flag truncation.
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", "10")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(b"abc")
            self.wfile.flush()
            self.close_connection = True
            return
        if self.path == "/clover":
            # A Content-Length above 2^63-1 must be refused outright, not
            # silently treated as an empty body.
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", "18446744073709551616")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(b"abc")
            self.wfile.flush()
            self.close_connection = True
            return
        self._send(200, "text/plain", b"hello world\n")

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(n)
        self._send(200, "application/json", body)


if __name__ == "__main__":
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("127.0.0.1", 0), H) as srv:
        print(srv.server_address[1], flush=True)
        srv.serve_forever()
