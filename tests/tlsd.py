#!/usr/bin/env python3
"""TLS test server for tests/net.sh. Prints its port, then serves
   GET /tls -> "tls hello\\n" over a self-signed certificate.

The certificate in tests/data is deliberately self-signed, so the verified
client must fail the handshake (net-tls-verify-*) while --insecure succeeds
(net-tls-insecure-*).
"""
import http.server
import socketserver
import ssl


class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        body = b"tls hello\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain("tests/data/tls_test_cert.pem",
                        "tests/data/tls_test_key.pem")
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("127.0.0.1", 0), H) as srv:
        srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
        print(srv.server_address[1], flush=True)
        srv.serve_forever()
