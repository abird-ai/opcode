#!/usr/bin/env python3
"""Generates tests/data/agent_replay.wire: two Anthropic-style SSE responses.

Turn 1 asks for `bash {command: "echo hi"}`, turn 2 answers with text.
The FWIR1 records contain full HTTP/1.1 responses (server -> client).
"""
import json
import os
import struct

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "data", "agent_replay.wire")


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
        "id": "msg_1", "usage": {"input_tokens": 10, "output_tokens": 1}}}),
    ("content_block_start", {"type": "content_block_start", "index": 0,
                              "content_block": {"type": "text", "text": ""}}),
    ("content_block_delta", {"type": "content_block_delta", "index": 0,
                             "delta": {"type": "text_delta", "text": "Let me check. "}}),
    ("content_block_stop", {"type": "content_block_stop", "index": 0}),
    ("content_block_start", {"type": "content_block_start", "index": 1,
                             "content_block": {"type": "tool_use", "id": "toolu_1",
                                               "name": "bash", "input": {}}}),
    ("content_block_delta", {"type": "content_block_delta", "index": 1,
                             "delta": {"type": "input_json_delta",
                                       "partial_json": '{"command": "echo hi"}'}}),
    ("content_block_stop", {"type": "content_block_stop", "index": 1}),
    ("message_delta", {"type": "message_delta",
                       "delta": {"stop_reason": "tool_use"},
                       "usage": {"output_tokens": 25}}),
    ("message_stop", {"type": "message_stop"}),
])

turn2 = sse([
    ("message_start", {"type": "message_start", "message": {
        "id": "msg_2", "usage": {"input_tokens": 30, "output_tokens": 1}}}),
    ("content_block_start", {"type": "content_block_start", "index": 0,
                              "content_block": {"type": "text", "text": ""}}),
    ("content_block_delta", {"type": "content_block_delta", "index": 0,
                             "delta": {"type": "text_delta", "text": "All done."}}),
    ("content_block_stop", {"type": "content_block_stop", "index": 0}),
    ("message_delta", {"type": "message_delta",
                       "delta": {"stop_reason": "end_turn"},
                       "usage": {"output_tokens": 4}}),
    ("message_stop", {"type": "message_stop"}),
])

simple = sse([
    ("message_start", {"type": "message_start", "message": {
        "id": "msg_s", "usage": {"input_tokens": 5, "output_tokens": 1}}}),
    ("content_block_start", {"type": "content_block_start", "index": 0,
                              "content_block": {"type": "text", "text": ""}}),
    ("content_block_delta", {"type": "content_block_delta", "index": 0,
                             "delta": {"type": "text_delta", "text": "Simple answer."}}),
    ("content_block_stop", {"type": "content_block_stop", "index": 0}),
    ("message_delta", {"type": "message_delta",
                       "delta": {"stop_reason": "end_turn"},
                       "usage": {"output_tokens": 3}}),
    ("message_stop", {"type": "message_stop"}),
])
SIMPLE = os.path.join(HERE, "data", "agent_replay_simple.wire")
with open(SIMPLE, "wb") as f:
    f.write(b"FWIR1\n")
    body = http_response(simple)
    f.write(bytes([1]) + struct.pack("<I", len(body)) + body)

# Queue/steering replay: turn 1 keeps the agent busy with a tool call, then
# three more text turns let one queued message drain per idle tick.
def text_turn(msg_id, text, in_tokens, out_tokens):
    return sse([
        ("message_start", {"type": "message_start", "message": {
            "id": msg_id, "usage": {"input_tokens": in_tokens, "output_tokens": 1}}}),
        ("content_block_start", {"type": "content_block_start", "index": 0,
                              "content_block": {"type": "text", "text": ""}}),
        ("content_block_delta", {"type": "content_block_delta", "index": 0,
                                 "delta": {"type": "text_delta", "text": text}}),
        ("content_block_stop", {"type": "content_block_stop", "index": 0}),
        ("message_delta", {"type": "message_delta",
                           "delta": {"stop_reason": "end_turn"},
                           "usage": {"output_tokens": out_tokens}}),
        ("message_stop", {"type": "message_stop"}),
    ])

QUEUE = os.path.join(HERE, "data", "agent_replay_queue.wire")
queue_turns = [
    http_response(turn1),
    http_response(text_turn("msg_q2", "Drained one.", 40, 4)),
    http_response(text_turn("msg_q3", "Drained two.", 50, 4)),
    http_response(text_turn("msg_q4", "Drained three.", 60, 4)),
]
with open(QUEUE, "wb") as f:
    f.write(b"FWIR1\n")
    for body in queue_turns:
        f.write(bytes([1]) + struct.pack("<I", len(body)) + body)

with open(OUT, "wb") as f:
    f.write(b"FWIR1\n")
    for body in (http_response(turn1), http_response(turn2)):
        f.write(bytes([1]) + struct.pack("<I", len(body)) + body)

# Tool-card replay: an unknown-tool error turn, a slow multi-line bash turn
# (so a headless script can observe the running card before it finishes), then
# a text turn.  See tests/scripts/tui_cards.rsc.
CARDS = os.path.join(HERE, "data", "agent_replay_cards.wire")
err_turn = sse([
    ("message_start", {"type": "message_start", "message": {
        "id": "msg_c1", "usage": {"input_tokens": 5, "output_tokens": 1}}}),
    ("content_block_start", {"type": "content_block_start", "index": 0,
                              "content_block": {"type": "tool_use", "id": "toolu_c1",
                                                "name": "missing_tool", "input": {}}}),
    ("content_block_delta", {"type": "content_block_delta", "index": 0,
                             "delta": {"type": "input_json_delta", "partial_json": "{}"}}),
    ("content_block_stop", {"type": "content_block_stop", "index": 0}),
    ("message_delta", {"type": "message_delta",
                       "delta": {"stop_reason": "tool_use"},
                       "usage": {"output_tokens": 3}}),
    ("message_stop", {"type": "message_stop"}),
])
slow_turn = sse([
    ("message_start", {"type": "message_start", "message": {
        "id": "msg_c2", "usage": {"input_tokens": 10, "output_tokens": 1}}}),
    ("content_block_start", {"type": "content_block_start", "index": 0,
                              "content_block": {"type": "tool_use", "id": "toolu_c2",
                                                "name": "bash", "input": {}}}),
    ("content_block_delta", {"type": "content_block_delta", "index": 0,
                             "delta": {"type": "input_json_delta",
                                       "partial_json": '{"command": "for i in 1 2 3 4 5; do echo line$i; done; sleep 1"}'}}),
    ("content_block_stop", {"type": "content_block_stop", "index": 0}),
    ("message_delta", {"type": "message_delta",
                       "delta": {"stop_reason": "tool_use"},
                       "usage": {"output_tokens": 5}}),
    ("message_stop", {"type": "message_stop"}),
])
cards_turns = [
    http_response(err_turn),
    http_response(slow_turn),
    http_response(text_turn("msg_c3", "Cards done.", 20, 4)),
]
with open(CARDS, "wb") as f:
    f.write(b"FWIR1\n")
    for body in cards_turns:
        f.write(bytes([1]) + struct.pack("<I", len(body)) + body)

# Markdown replay: one assistant turn exercising headings, inline bold/code,
# bullets, a quote, a fenced block and a trailing paragraph.  See
# tests/scripts/tui_markdown.rsc.
MARKDOWN = os.path.join(HERE, "data", "agent_replay_markdown.wire")
md_text = (
    "# Title\n\n"
    "Some **bold** text and `code`.\n\n"
    "- one\n- two\n\n"
    "> quote\n\n"
    "```\nraw <code>\n```\n\n"
    "Done.\n"
)
markdown_turn = sse([
    ("message_start", {"type": "message_start", "message": {
        "id": "msg_md", "usage": {"input_tokens": 5, "output_tokens": 1}}}),
    ("content_block_start", {"type": "content_block_start", "index": 0,
                              "content_block": {"type": "text", "text": ""}}),
    ("content_block_delta", {"type": "content_block_delta", "index": 0,
                             "delta": {"type": "text_delta", "text": md_text}}),
    ("content_block_stop", {"type": "content_block_stop", "index": 0}),
    ("message_delta", {"type": "message_delta",
                       "delta": {"stop_reason": "end_turn"},
                       "usage": {"output_tokens": 12}}),
    ("message_stop", {"type": "message_stop"}),
])
with open(MARKDOWN, "wb") as f:
    f.write(b"FWIR1\n")
    body = http_response(markdown_turn)
    f.write(bytes([1]) + struct.pack("<I", len(body)) + body)

# Hostile replay: a tool call whose name and raw argument JSON carry terminal
# escape sequences.  In scrollback mode the tool card header is written inline,
# so this proves the sanitizer keeps a raw ESC/OSC/C1 out of the emitted bytes.
# One tool turn; EOF finishes the run cleanly.  See tests/scripts/tui_hostile.rsc.
HOSTILE = os.path.join(HERE, "data", "agent_replay_hostile.wire")
hostile_turn = sse([
    ("message_start", {"type": "message_start", "message": {
        "id": "msg_h1", "usage": {"input_tokens": 5, "output_tokens": 1}}}),
    ("content_block_start", {"type": "content_block_start", "index": 0,
                              "content_block": {"type": "tool_use", "id": "toolu_h1",
                                                "name": "missing\x1btool", "input": {}}}),
    ("content_block_delta", {"type": "content_block_delta", "index": 0,
                             "delta": {"type": "input_json_delta",
                                       "partial_json": '{"x":"\x1b[2K\x1b]0;PWNED\x07"}'}}),
    ("content_block_stop", {"type": "content_block_stop", "index": 0}),
    ("message_delta", {"type": "message_delta",
                       "delta": {"stop_reason": "tool_use"},
                       "usage": {"output_tokens": 5}}),
    ("message_stop", {"type": "message_stop"}),
])
# A turn with no visible content so the run ends cleanly (the provider still
# gets a message_stop) without printing text after the tool card; this lets a
# scrollback Ctrl+O act on the card as the tail output.
finish_turn = sse([
    ("message_start", {"type": "message_start", "message": {
        "id": "msg_fin", "usage": {"input_tokens": 8, "output_tokens": 1}}}),
    ("message_delta", {"type": "message_delta",
                       "delta": {"stop_reason": "end_turn"},
                       "usage": {"output_tokens": 1}}),
    ("message_stop", {"type": "message_stop"}),
])
with open(HOSTILE, "wb") as f:
    f.write(b"FWIR1\n")
    for body in (http_response(hostile_turn), http_response(finish_turn)):
        f.write(bytes([1]) + struct.pack("<I", len(body)) + body)

# Scrollback card replay: a single bash tool turn with a five-line result and
# no following text, so the finished card is the last inline output and a
# scrollback Ctrl+O can erase and reprint it expanded.  See
# tests/scripts/tui_scroll_cards.rsc.
SCROLL = os.path.join(HERE, "data", "agent_replay_scroll.wire")
scroll_turn = sse([
    ("message_start", {"type": "message_start", "message": {
        "id": "msg_s1", "usage": {"input_tokens": 5, "output_tokens": 1}}}),
    ("content_block_start", {"type": "content_block_start", "index": 0,
                              "content_block": {"type": "tool_use", "id": "toolu_s1",
                                                "name": "bash", "input": {}}}),
    ("content_block_delta", {"type": "content_block_delta", "index": 0,
                             "delta": {"type": "input_json_delta",
                                       "partial_json": '{"command": "for i in 1 2 3 4 5; do echo line$i; done"}'}}),
    ("content_block_stop", {"type": "content_block_stop", "index": 0}),
    ("message_delta", {"type": "message_delta",
                       "delta": {"stop_reason": "tool_use"},
                       "usage": {"output_tokens": 5}}),
    ("message_stop", {"type": "message_stop"}),
])
with open(SCROLL, "wb") as f:
    f.write(b"FWIR1\n")
    for body in (http_response(scroll_turn), http_response(finish_turn)):
        f.write(bytes([1]) + struct.pack("<I", len(body)) + body)

print(f"wrote {OUT} ({os.path.getsize(OUT)} bytes), {SIMPLE} "
      f"({os.path.getsize(SIMPLE)} bytes) and {QUEUE} ({os.path.getsize(QUEUE)} bytes)")
