#!/usr/bin/env python3
"""Mock Ollama server for tests/ollama.sh.

Serves the native tags endpoint (/api/tags), the OpenAI-compatible model list
(/v1/models) and a canned chat-completions SSE stream (/v1/chat/completions)
on 127.0.0.1. Every request is appended to $OLLAMA_LOG as

    <METHOD> <path> endpoint=<models|tags|chat|other> auth=<Authorization>

when that env var is set, so the test can assert which endpoint discovery used
and that local requests carry no Authorization header. With
OLLAMA_NO_V1_MODELS=1, /v1/models answers 404 so the native fallback can be
exercised. Prints the chosen port to stdout.
"""
import http.server
import json
import os
import socketserver

TAGS = {
    "models": [
        {"name": "llama3.2:latest", "model": "llama3.2:latest",
         "modified_at": "2025-01-01T00:00:00Z", "size": 2019393189,
         "digest": "aaaa", "details": {"format": "gguf", "family": "llama"}},
        {"name": "qwen2.5:7b", "model": "qwen2.5:7b",
         "modified_at": "2025-01-01T00:00:00Z", "size": 4683087332,
         "digest": "bbbb", "details": {"format": "gguf", "family": "qwen2"}},
    ]
}

MODELS = {
    "object": "list",
    "data": [
        {"id": "llama3.2:latest", "object": "model", "created": 0, "owned_by": "library"},
        {"id": "qwen2.5:7b", "object": "model", "created": 0, "owned_by": "library"},
    ],
}


def sse(*chunks):
    out = bytearray()
    for chunk in chunks:
        out += b"data: " + json.dumps(chunk, separators=(",", ":")).encode() + b"\n\n"
    out += b"data: [DONE]\n\n"
    return bytes(out)


def chat_stream():
    base = {"id": "chatcmpl-test", "object": "chat.completion.chunk",
            "created": 0, "model": "llama3.2"}
    return sse(
        {**base, "choices": [{"index": 0, "delta": {"role": "assistant", "content": ""},
                               "finish_reason": None}]},
        {**base, "choices": [{"index": 0, "delta": {"content": "Hello from Ollama!"},
                               "finish_reason": None}]},
        {**base, "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]},
        {**base, "choices": [], "usage": {"prompt_tokens": 5, "completion_tokens": 4,
                                          "total_tokens": 9}},
    )


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _log(self):
        log = os.environ.get("OLLAMA_LOG")
        if not log:
            return
        if self.path.startswith("/v1/models"):
            endpoint = "models"
        elif self.path.startswith("/api/tags"):
            endpoint = "tags"
        elif self.path.startswith("/v1/chat/completions"):
            endpoint = "chat"
        else:
            endpoint = "other"
        with open(log, "a") as handle:
            handle.write("%s %s endpoint=%s auth=%s\n"
                         % (self.command, self.path, endpoint,
                            self.headers.get("Authorization", "")))

    def _json(self, obj):
        body = json.dumps(obj, separators=(",", ":")).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self._log()
        if self.path.startswith("/api/tags"):
            self._json(TAGS)
        elif self.path.startswith("/v1/models"):
            if os.environ.get("OLLAMA_NO_V1_MODELS"):
                self.send_response(404)
                self.send_header("Content-Length", "0")
                self.end_headers()
            else:
                self._json(MODELS)
        else:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        self.rfile.read(n)
        self._log()
        if self.path.startswith("/v1/chat/completions"):
            body = chat_stream()
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()


if __name__ == "__main__":
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("127.0.0.1", 0), H) as srv:
        print(srv.server_address[1], flush=True)
        srv.serve_forever()
