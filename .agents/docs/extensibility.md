# Extensibility

The design rule is **JSON at external boundaries, typed structs internally**.
Anything crossing a process or ABI boundary speaks JSON (stable, debuggable,
language-agnostic); everything inside the process uses enums and pointers.
There are four extension layers, cheapest first; this document states what is
implemented today and what is deferred.

---

## 1. Process level

### 1.1 MCP client (`src/ext/mcp.s`)

Implemented — **stdio transport only**:

- `mcp_start()` always reads the user-level `<config dir>/mcp.jsonc`; the
  project-level `<cwd>/.opcode/mcp.jsonc` is read only when the cwd is trusted
  (`config_trusted(cwd)`: `--approve`, else a `<config dir>/trust.jsonc`
  entry), the same gate `config_load` applies to the project `config.jsonc`.
  An untrusted project `mcp.jsonc` is skipped silently, so opening an
  untrusted clone cannot spawn its `command` at startup. Both files share the
  format:
  ```jsonc
  {
    "servers": {
      "files": {
        "command": "npx",
        "args": ["-y", "@scope/server"],
        "env": { "SOME_TOKEN": "literal-value" }
      }
    }
  }
  ```
  `env` values are copied verbatim; `{"url": ...}` entries (HTTP transport) are
  ignored.
- Each server is spawned with `os_spawn`; the JSON-RPC 2.0 handshake
  (`initialize` requesting protocol `2024-11-05` / `initialized` / `tools/list`)
  runs at startup with a 10 s deadline per server, before the UI starts.
- Server tools are registered as `mcp__<server>__<tool>` with the server's
  description and input schema; their calls go through the same schema-driven
  `tool_validate` as the built-ins. `tools/call` runs synchronously with a 10 s
  deadline; `result.content[].text` is joined with newlines. The request pipe
  is non-blocking and every write carries the same 10 s deadline, so a server
  that stops reading cannot wedge the agent (`mcp_write_all`).
- Shutdown: close stdin → `SIGTERM` → a bounded, non-blocking reap (200 ms
  `WNOHANG` poll) → `SIGKILL` → a final blocking reap (`mcp_stop`). The child is
  its own process group, so its descendants are signalled too. A `result` with
  `isError:true` sets the job's error flag, so the tool result is reported as a
  tool error.

Deferred: Streamable HTTP transport, `${ENV}` expansion, `nextCursor`
pagination, `notifications/tools/list_changed` re-sync, per-server
`enabled`/`exposure`/`timeout`, non-blocking connect. MCP is **stdio only** and
exposes **tools only**; prompts and resources are not read.

### 1.2 RPC mode (`--mode rpc`)

JSONL on stdin/stdout with Opcode's own documented command set. Each line is one
JSON object with a `"type"` field:

```
→ {"type":"prompt","text":"explain this repo"}
→ {"type":"abort"}
→ {"type":"quit"}
← {"type":"ack"} / {"type":"error","message":"..."}
← {"type":"agent_end", ...}             plus streaming event objects
```

`prompt`, `abort` and `quit` are implemented in this build. Deferred:
`get_state`, `set_model`, `set_thinking_level`, `get_available_models`,
`compact`, `bash`, `new_session`, `get_messages`, and UI request/response
objects.

### 1.3 `--mode json`

`-p` with `--mode json` emits one JSON object per line for the same agent
events (text/thinking deltas, tool start/args/end, tool result, usage, done,
error, `agent_end`); the session header is not part of the stream. The
streaming contract lives in `src/app/modes.s`.

## 2. Declarative layer

No code execution; everything is parsed with the same JSONC/JSONL helpers:

- `<config dir>/config.jsonc` and `<cwd>/.opcode/config.jsonc` — see
  `.agents/docs/core-agent.md` §7.1 for the keys the implementation reads.
- `<config dir>/mcp.jsonc` (always) and `<cwd>/.opcode/mcp.jsonc` (trusted
  projects only, like the project `config.jsonc` above).
- Skills: `<config>/skills/**/SKILL.md` and
  `<cwd>/.opcode/skills/**/SKILL.md`, frontmatter `name`/`description`.
- Prompt templates: `<config>/prompts/*.md` and `<cwd>/.opcode/prompts/*.md`,
  selected with `--template NAME [args...]`.
- `<config>/trust.jsonc` with `{"trusted":["/abs/cwd", ...]}` gates project
  config, project context files and project skills. An interactive TUI on a TTY
  can also prompt for trust and save the answer (`config_trust_ask` /
  `config_trust_save`).

Themes are configurable: `--theme` / config `theme`, and named
`themes/<name>.jsonc` files under the config dir, a trusted project
`<cwd>/.opcode/themes`, or a `resources_discover` theme root, overriding the
built-in `dark`/`light`/`system` palette. Keybindings are not configurable in
this build; the TUI uses its built-in readline key map.

## 3. Native plugins — the C ABI

`include/opcode_plugin.h` is the normative, versioned C ABI (C, Rust, Zig, …).
A plugin exports exactly one symbol:

```c
int opcode_plugin_init(const OpcodeHostV1 *host, OpcodePluginV1 *out);
```

The host table (`OpcodeHostV1`) exposes allocation, logging, tool and command
registration, `tool_done`, `defer`, event registration, JSON helpers, session
info, status/title, model selection, and an HTTP request slot. Tools are
registered as `OpcodeToolV1` descriptors with a JSON Schema and an `execute`
callback. Payloads across the boundary are NUL-terminated UTF-8 JSON unless the
header says otherwise. The rules that keep the ABI alive:

1. Structs are **append-only**; `struct_size` is checked by the host and new
   fields go at the end.
2. `abi_version` changes only for removals or semantic changes; a mismatch is
   logged and the plugin is skipped.
3. JSON strings for tool/event payloads; no compiler-specific structs.
4. The host is single-threaded. Plugins may use threads, but calls into the host
   from another thread must go through `host->defer`.
5. A plugin crash crashes the process; isolation is the user's container's job.

### 3.1 Static plugins (implemented)

The build is static and no-libc, so there is no `dlopen` loader. Instead,
`plugins/manifest.json` lists plugin sources; `tools/gen-plugins.py` emits
`build/plugins.s` with one entry per plugin, and the Makefile compiles each
source with `-Dopcode_plugin_init=opcode_plugin_init_<name>` before linking.
`plugins_init()` (`src/ext/plugin.s`) walks the table, calls each init with the
host vtable, validates the ABI and logs the result. Registered plugin tools join
the same registry and are validated by the schema-driven `tool_validate`.
`plugins/example_c/plugin.c`
is the in-tree example and `tests/plugin_test.s` exercises it.

### 3.2 Host status and limitations

The M6 host implementation (`src/ext/host.s`) now wires part of the table:

- Plugin **commands are dispatched**: `host->register_command` rows are listed
  in the TUI slash menu (after built-ins, templates and skills) and a matching
  `/name` calls the handler; the handler's returned cstr becomes a notice. See
  `tui_cmd_ext` in `src/app/tui.s`.
- `register_tool` copies the descriptor's `prompt_snippet`/`prompt_guidelines`
  into the appended `TL_snippet`/`TL_guidelines` fields and sets `TL_PROMPT`, so
  `prompt_build` uses the snippet as the tool's `# Tools` line and emits the
  guidelines as extra `# Rules` bullets.
- **`resources_discover` is emitted once at startup** (`plugins_init` calls
  `resources_discover_emit` after every handler is registered) with the payload
  `{"cwd":...,"trusted":...}`. A handler registers directories with
  `host->add_resource_root("skills"|"prompts"|"themes", path)` (absolute, no
  `..`, at most 8 roots per kind); `prompt.s` scans the skill/prompt roots and
  `theme.s` the theme roots. The initial template/theme selection runs before the
  event, so those roots are not visible to it; `/theme` and a later re-scan do
  see them.
- `append_entry` writes a `custom` session entry when a session is active.
- `defer` runs the callback immediately (single-threaded host).

Still **not implemented** in the host/ABI:

- `set_status`/`set_title` have no effect (both are no-ops); `session_id`,
  `session_file` and `system_prompt` return 0.
- Hook-bus event dispatch: apart from `resources_discover`, `on_event`
  registrations are recorded in `opcode_host_events` but never invoked, and
  `tool_call` vetoing is not wired.
- Prompt sections contributed by a plugin (other than the per-tool
  snippet/guidelines above) are not composed.
- Asynchronous tools: `register_tool` completes synchronously and
  `OPCODE_TOOL_THREADSAFE` is not honoured; `is_cancelled` always returns 0.
- Custom providers (`set_model`/`set_thinking_level` are no-ops), dynamic
  loading, and `http_request`/`http_cancel` (always return 0).
- Only a C example ships (`plugins/example_c/`); there are no Rust or Zig
  examples.

Runtime loading is future work. Because a static `-nostdlib` binary cannot use
`dlopen`, the options are an in-process ELF relocator for a restricted subset
(relative relocations only, imports limited to the host vtable) or keeping
plugins linked statically. Typed callbacks are deferred with it.

### 3.3 Event names

The names accepted by `host->on_event` are the `OPCODE_EV_*` macros in
`include/opcode_plugin.h`: `project_trust`, `resources_discover`,
`session_start`, `session_shutdown`, `input`, `before_agent_start`,
`agent_start`, `agent_end`, `turn_start`, `turn_end`, `message_start`,
`message_update`, `message_end`, `tool_call`, `tool_result`,
`tool_execution_start`, `tool_execution_update`, `tool_execution_end`,
`before_provider_request`, `after_provider_response`, `provider_stream_event`,
`model_select`, `thinking_level_change`, `mcp_servers_change`. As noted in
§3.2, `resources_discover` is the one event delivered today (once at startup);
the rest are registered but not dispatched.

## 4. Out of scope

Deliberately not provided: a JavaScript/TypeScript extension runtime (it would
require embedding an engine and libc), a WASM/JIT sandbox, dynamic
`dlopen`/`LoadLibrary` loading, model routing/virtual models, and a
client/server attach protocol. MCP plus the RPC mode is the interop story.
