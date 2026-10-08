# Design decisions

The decisions below are the ones the current implementation follows. They are
listed with the code that embodies them; proposals not reflected in the code
are not repeated here.

## Binary and runtime

- **Static `-nostdlib` binary, no libc, no dynamic linker.** Linked with
  `ld -static -nostdlib --no-dynamic-linker -z noexecstack`; `_start` calls
  `os_init` and `opcode_main` directly (`src/base/start.s`). The only C compiled
  in is the vendored freestanding mbedTLS and plugin objects; no C runtime is
  linked.
- **Linux-syscall ABI as the Layer 0 boundary.** Portable code calls only
  `os_*` functions whose signatures and semantics are documented in
  `.agents/docs/platform.md` and implemented per OS (`src/plat/linux/`;
  `src/plat/plat.inc` carries the shared constants and a subset stub). The
  Linux adapter issues raw `syscall` instructions
  (`src/plat/linux/`). Ports implement the same functions over libSystem or
  Win32; selection is at link time. Failures are negative Linux `errno` values
  on every platform.
- **Single-threaded poll loop.** One static watch table (`src/base/loop.s`,
  max 96 entries) plus non-blocking I/O everywhere; timers are deadlines checked
  by the loop. No threads on the hot path, no blocking reads in the agent or
  TUI. `os_poll` is the only wait primitive.

## Memory and data

- **Power-of-two allocator plus `SB`/`VEC` containers.** `src/base/mem.s`
  implements 12 size classes up to 64 KiB out of 1 MiB mappings with a 16-byte
  header; larger blocks get their own mapping. `SB` is a growable
  NUL-terminated byte buffer, `VEC` a growable array of fixed-size items; both
  live in `opcode.inc` and are used everywhere instead of ad-hoc allocation.
- **Arena per parse/request.** The JSON parser owns a chained 1 MiB arena that
  is reset before each document (`src/base/json.s`); the HTTP response parser
  and SSE scratch are reset/released at the start of each agent turn
  (`src/core/agent.s`). Transcript strings are owned copies freed as a unit by
  `tr_free` (`src/core/messages.s`).
- **JSONC parser.** The JSON parser accepts VS Code JSONC (line and block
  comments, trailing commas) and is used for config, auth and other
  hand-written files, so one parser and one wire writer cover every format
  (`src/base/json.s`). Unknown config keys are ignored rather than rejected.
- **Typed internal events, JSON only at boundaries.** Providers emit typed
  `SE_*` events into a single sink (`src/core/core.inc`); the transcript is an
  array of fixed-size message/block structs. JSON is produced only for the
  session log, `--mode json`, RPC, plugins, and HTTP bodies.

## Agent and I/O

- **Vendored freestanding mbedTLS behind the `tls_*` contract.** `dlopen` is
  impossible in a static `-nostdlib` process, so Linux TLS is mbedTLS 3.6.2
  compiled in (`third_party/mbedtls/`, `third_party/mbedtls_glue.c`,
  `src/net/linux/tls_shim.c`) and exposed through the same `tls_new`/
  `tls_handshake`/`tls_read`/`tls_write`/`tls_want` interface as any future OS
  backend (`src/net/net.inc`). The CA bundle is embedded from
  `third_party/cacert.pem`.
- **Provider adapters behind a vtable.** Each wire API is a `PV_*` table
  (`PV_new`, `PV_build`, `PV_path`, `PV_sse`, `PV_finish`, `PV_free`) selected
  from the model record's `api` field through one static dispatch table
  (`prov_table`/`prov_for_api` in `src/core/agent.s`, falling back to
  `prov_openai` for an unknown api): `anthropic-messages`, `openai-chat`,
  `openai-responses` (`src/core/core.inc`, `src/prov/`). The agent owns
  transport, sessions and tool execution and never branches on provider names
  outside this selection. Providers that speak an existing wire API share an
  adapter and differ only in catalog/base/auth data: `ollama`, `ollama-cloud`
  and `google` all use `openai-chat` (Google via its OpenAI-compatible
  endpoint), so adding a provider is normally a catalog + auth change, not a
  new adapter.
- **Tool/job model.** Tools are static `TL_*` descriptors with an embedded JSON
  schema, an `exec` and an optional `finish`. `tool_validate` parses the tool's
  own `TL_params` schema and enforces its `required`/`properties` types, so a
  new tool needs a correct schema rather than a validator edit. `edit` and
  `write` share `tool_write_atomic` (temp file + rename, symlink refusal). A
  tool call becomes a `J_*` job, either an in-process operation or a child
  process watched through its stdout pipe. Results append
  in source order while `tool_execution_end` fires in completion order; the
  loop kills jobs past `J_deadline_ms` (`src/core/core.inc`,
  `src/core/tools.s`, `src/tools/`).
- **JSONL sessions with our own schema.** Append-only JSONL, one tagged object
  per line (`session`, `message`, `model_change`, `custom`, `compaction`; and
  other serde-friendly entries), Unix millisecond timestamps, `id`/`parent_id`
  tree links, `schema_version` in the header. There is no external format
  compatibility target (`src/core/session.s`, contract in `src/core/API.md`).
- **TUI is inline by default.** The normal terminal scrollback is the primary
  surface; the renderer redraws a live footer and streams transcript rows
  (`--tui-mode inline`). `--tui-mode fullscreen` (alternate screen, full cell
  grid) is the alternative rendering of the same state (`src/app/tui.s`,
  `src/tui/`). The view stores a 16-bit byte length per row and a display-column
  cursor, so wrapping and wide/combining codepoints align; control characters
  are replaced with U+FFFD before they reach the terminal.

## Process, signal and credential policy

- **SIGPIPE is ignored and children are their own group.** `os_init` sets
  `SIGPIPE` to `SIG_IGN` so a write to a dead tool/MCP pipe returns `-EPIPE`
  and the turn reports an error instead of the process dying; `os_spawn`
  restores `SIG_DFL` and calls `setpgid(0,0)` in the child, and timeout/abort
  paths use `os_kill_group` so a shell's descendants cannot keep the pipe open
  (`src/plat/linux/sys.s`, `proc.s`, `tests/sigpipe_test.s`).
- **OAuth uses a loopback-only callback server.** It binds `::1` and
  `127.0.0.1` on the same port (never a wildcard) and polls both listeners in
  the accept loop (`src/core/oauth.s`). An expired OAuth credential is
  fail-closed (no ambient fallback) and automatic refresh is a deliberate
  non-goal; re-run `opcode login` (`src/core/auth.s`).
- **Providers normalize tool-call streaming for the agent's single pending
  slot.** The agent keeps one pending tool call, so a provider that may
  interleave indices (OpenAI chat) buffers arguments per index and emits each
  call's `SE_TOOL_START`/`SE_TOOL_DELTA`/`SE_TOOL_END` as one contiguous group
  at `finish_reason`/`[DONE]` (`src/prov/openai.s`). The Responses adapter
  relies on the API streaming output items sequentially and additionally
  backfills an item's `arguments` when no delta was streamed
  (`src/prov/openai_responses.s`).
- **Tool results carry exactly one separator before the status marker.**
  `bash_finish` appends `[exit N]`/`[signal N]` on a fresh line only when the
  captured stdout does not already end with a newline (`src/tools/bash.s`).
- **Tools are unconfined filesystem primitives, by design.** `read`/`edit`/
  `write`/`ls`/`find`/`grep` accept the model's path verbatim (absolute or
  relative); there is no workspace jail. This is deliberate for a coding agent
  that operates in the user's environment, and `edit`/`write` remain
  `TL_DESTRUCTIVE` for UI confirmation. `edit`/`write` refuse to replace a
  symlink and preserve the target mode.

## Catalog provenance

`runtime/catalog.json` carries MIT-licensed model catalog data from the pi
project. Only factual model metadata (ids, providers, base URLs, context
windows, limits and capability flags) is used, and the file is maintained here
as our own data.
