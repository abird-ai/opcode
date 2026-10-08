#!/usr/bin/env python3
"""Generates tests/data/mcp_replay.wire: two Anthropic-style SSE responses.

Turn 1 calls the MCP tool `mcp__mock__echo` with {"text":"hello"}; turn 2
answers with the text "echo:hello", matching tests/mock_mcp.py. The tool is
executed for real against the mock server; only the provider is replayed.
"""
import json
import os
import struct

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "data", "mcp_replay.wire")


def sse(events):
    out = bytearray()
    for name, data in events:
        out += f"event: {name}\ndata: {json.dumps(data, separators=(',', ':'))}\n\n".encode()
    return bytes(out)


def http_response(body):
    head = (
        "HTTP/1.1 200 OK\r\n"
        "Content-Type: text/event-stream\r\n"
        f"Content-Length: {len(body)}\r\n"
        "Connection: close\r\n\r\n"
    ).encode()
    return head + body


turn1 = sse([
    ("message_start", {"type": "message_start", "message": {
        "id": "msg_m1", "usage": {"input_tokens": 10, "output_tokens": 1}}}),
    ("content_block_start", {"type": "content_block_start", "index": 0,
                              "content_block": {"type": "text", "text": ""}}),
    ("content_block_delta", {"type": "content_block_delta", "index": 0,
                             "delta": {"type": "text_delta", "text": "Calling echo. "}}),
    ("content_block_stop", {"type": "content_block_stop", "index": 0}),
    ("content_block_start", {"type": "content_block_start", "index": 1,
                             "content_block": {"type": "tool_use", "id": "toolu_mcp1",
                                               "name": "mcp__mock__echo", "input": {}}}),
    ("content_block_delta", {"type": "content_block_delta", "index": 1,
                             "delta": {"type": "input_json_delta",
                                       "partial_json": '{"text": "hello"}'}}),
    ("content_block_stop", {"type": "content_block_stop", "index": 1}),
    ("message_delta", {"type": "message_delta",
                       "delta": {"stop_reason": "tool_use"},
                       "usage": {"output_tokens": 25}}),
    ("message_stop", {"type": "message_stop"}),
])

turn2 = sse([
    ("message_start", {"type": "message_start", "message": {
        "id": "msg_m2", "usage": {"input_tokens": 30, "output_tokens": 1}}}),
    ("content_block_start", {"type": "content_block_start", "index": 0,
                              "content_block": {"type": "text", "text": ""}}),
    ("content_block_delta", {"type": "content_block_delta", "index": 0,
                             "delta": {"type": "text_delta", "text": "echo:hello"}}),
    ("content_block_stop", {"type": "content_block_stop", "index": 0}),
    ("message_delta", {"type": "message_delta",
                       "delta": {"stop_reason": "end_turn"},
                       "usage": {"output_tokens": 4}}),
    ("message_stop", {"type": "message_stop"}),
])

with open(OUT, "wb") as f:
    f.write(b"FWIR1\n")
    for body in (http_response(turn1), http_response(turn2)):
        f.write(bytes([1]) + struct.pack("<I", len(body)) + body)
print(f"wrote {OUT} ({os.path.getsize(OUT)} bytes)")
