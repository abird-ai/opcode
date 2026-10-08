#!/usr/bin/env python3
"""Minimal stdio MCP server for tests/mcp.sh.

Reads newline-delimited JSON-RPC 2.0 from stdin and answers initialize,
tools/list (one `echo` tool) and tools/call. Every received line is appended
to $MCP_MOCK_LOG when set, so the shell test can prove the client really talked
to the server. Exits at EOF.
"""
import json
import os
import sys

LOG = os.environ.get("MCP_MOCK_LOG")


def send(obj):
    sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
    sys.stdout.flush()


for raw in sys.stdin.buffer:
    if LOG:
        with open(LOG, "ab") as f:
            f.write(raw if raw.endswith(b"\n") else raw + b"\n")
    line = raw.strip()
    if not line:
        continue
    try:
        msg = json.loads(line)
    except ValueError:
        continue
    method = msg.get("method")
    mid = msg.get("id")
    if method == "initialize":
        params = msg.get("params") or {}
        send({"jsonrpc": "2.0", "id": mid,
              "result": {
                  "protocolVersion": params.get("protocolVersion", "2024-11-05"),
                  "capabilities": {"tools": {}},
                  "serverInfo": {"name": "mock", "version": "0.1"}}})
    elif method == "notifications/initialized":
        pass
    elif method == "tools/list":
        send({"jsonrpc": "2.0", "id": mid,
              "result": {"tools": [{
                  "name": "echo",
                  "description": "Echo text back to the caller.",
                  "inputSchema": {
                      "type": "object",
                      "properties": {"text": {"type": "string"}},
                      "required": ["text"]}}]}})
    elif method == "tools/call":
        args = (msg.get("params") or {}).get("arguments") or {}
        send({"jsonrpc": "2.0", "id": mid,
              "result": {
                  "content": [{"type": "text", "text": "echo:" + str(args.get("text", ""))}],
                  "isError": False}})
    elif mid is not None:
        send({"jsonrpc": "2.0", "id": mid,
              "error": {"code": -32601, "message": "method not found"}})
