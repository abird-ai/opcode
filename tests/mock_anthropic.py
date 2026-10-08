#!/usr/bin/env python3
"""Minimal Anthropic Messages mock for tests/agent.sh.

First request: replies with a tool_use call to `bash {"command": "echo hi"}`.
Any later request that carries a tool_result: replies with text including the
tool output. Everything is a single SSE body with Content-Length.
"""
import http.server
import json
import socketserver

TOOL_USE = [
    ("message_start", {"type": "message_start", "message": {
        "id": "msg_1", "usage": {"input_tokens": 10, "output_tokens": 1}}}),
    ("content_block_start", {"type": "content_block_start", "index": 0,
                              "content_block": {"type": "tool_use", "id": "toolu_1",
                                                "name": "bash", "input": {}}}),
    ("content_block_delta", {"type": "content_block_delta", "index": 1,
                             "delta": {"type": "input_json_delta",
                                       "partial_json": '{"command": "echo hi"}'}}),
    ("content_block_stop", {"type": "content_block_stop", "index": 0}),
    ("message_delta", {"type": "message_delta",
                       "delta": {"stop_reason": "tool_use"},
                       "usage": {"output_tokens": 25}}),
    ("message_stop", {"type": "message_stop"}),
]


def sse(events):
    out = bytearray()
    for name, data in events:
        out += f"event: {name}\ndata: {json.dumps(data, separators=(',', ':'))}\n\n".encode()
    return bytes(out)


def tool_output(req):
    for m in req.get("messages", []):
        if m.get("role") != "user":
            continue
        for c in m.get("content", []):
            if isinstance(c, dict) and c.get("type") == "tool_result":
                for part in c.get("content", []):
                    if part.get("type") == "text":
                        return part["text"].splitlines()[0] if part["text"] else ""
    return ""


class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        req = json.loads(self.rfile.read(n))
        if tool_output(req):
            text = f"Tool said: {tool_output(req)}. All done."
            events = [
                ("message_start", {"type": "message_start", "message": {
                    "id": "msg_2", "usage": {"input_tokens": 30, "output_tokens": 1}}}),
                ("content_block_start", {"type": "content_block_start", "index": 0,
                                          "content_block": {"type": "text", "text": ""}}),
                ("content_block_delta", {"type": "content_block_delta", "index": 0,
                                         "delta": {"type": "text_delta", "text": text}}),
                ("content_block_stop", {"type": "content_block_stop", "index": 0}),
                ("message_delta", {"type": "message_delta",
                                   "delta": {"stop_reason": "end_turn"},
                                   "usage": {"output_tokens": 10}}),
                ("message_stop", {"type": "message_stop"}),
            ]
        else:
            events = TOOL_USE
        body = sse(events)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("127.0.0.1", 0), H) as srv:
        print(srv.server_address[1], flush=True)
        srv.serve_forever()
