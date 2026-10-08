# Opcode — design

Opcode is a coding agent written in hand-written x86-64 assembly: one static,
libc-free binary that runs a real terminal UI, talks to model providers over
HTTP and TLS, executes tools, persists sessions and loads native plugins. The
core is assembly (GNU `as`, Intel syntax); the only C linked in is vendored
freestanding mbedTLS and plugin code. Linux x86-64 is the reference target,
alongside a Linux AArch64 port, a macOS arm64 port and a Windows x86-64 port.
This document is the architecture and rationale. The current status and build
details are in `.agents/docs/ports.md` and the frozen per-layer APIs are in
`src/*/API.md`.

> **Research project.** Opcode pushes one extreme idea as far as it will go: a real coding agent in hand-written assembly, static and libc-free. For production work, use the maintained project at <https://github.com/abird-ai/agentc>.

Goal in one sentence:

> **A fast, minimal coding agent in one static binary — a real TUI, model
> providers, tools, sessions and a stable extension ABI — with no runtime
> dependency at all.**

---

## 1. Requirements

| # | Requirement | How the design satisfies it |
|---|---|---|
| R1 | Core in assembly directly | x86-64 GNU `as`, Intel syntax, custom ABI (`FN`/`PROLOGUE`/`EPILOGUE`); no code generation for the core |
| R2 | No stdlibs | `-static -nostdlib --no-dynamic-linker`; own allocator, strings, JSON, HTTP, TLS; no libc |
| R3 | Low-level platform libraries | Raw kernel syscalls for files, processes, terminal/TTY, sockets and DNS; vendored freestanding mbedTLS for TLS |
| R4 | Platform abstractions separate from the core | Two link-time contracts — `src/plat/plat.inc` (Layer 0 kernel surface) and `src/net/net.inc` (Layer 1 sockets/DNS/TLS); portable code never includes an OS header |
| R5 | Maximum performance | Single-threaded poll/watch loop, zero-copy wire path, arena reset per request, no GC, tick-driven rendering, `TCP_NODELAY` |
| R6 | Minimalism | One static binary, embedded model catalog and CA bundle, small config surface |
| R7 | Joyful to use | Streaming text, a terminal-native editor and view buffer, inline or fullscreen rendering, abort anywhere |
| R8 | Extensible with C, Rust and other languages | Process-level MCP and RPC first, plus a versioned **C ABI** (`include/opcode_plugin.h`); plugins link statically |
| R9 | Linux + macOS + Windows | One source tree; per-OS Layer 0/1 adapters selected at link time |

## 2. Non-goals

- No JavaScript/TypeScript extension runtime (no embedded engine).
- No in-process WebAssembly/JIT sandbox; MCP is the interop story.
- No image generation, classifiers, or cloud-specific APIs beyond the adapters
  in `src/prov/`.
- No GUI: the terminal is the product.
- No external file-format compatibility target: config and auth are JSONC,
  sessions use opcode's own JSONL schema.
- No in-tree retry/backoff layer: transient network and HTTP failures surface as
  errors rather than being retried.

## 3. Architecture

```
app/     modes: tui · print · json · rpc  ·  subcommands (login, logout, models, fetch, update) · flags · onboarding
ext/     MCP stdio client · static plugins (C ABI) host
tui/     terminal · cell-grid renderer · view buffer · editor/composer · input parser · markdown · tool cards · menu · status footer · themes
tools/   built-ins: read · bash · edit · write · ls · find · grep
prov/    anthropic-messages · openai-chat · openai-responses
core/    agent loop · messages/transcript · system prompt · compaction · session JSONL · config · auth/OAuth · catalog · discovery · diff · tool registry
wire/    http/1.1 · shared HTTP(S) client · sse · json writer · url
base/    mem (allocator, SB, VEC) · str · unicode width · json (JSONC, arena) · log · loop (poll + watch table)
──────────────────────────────────────────────────────────────────────────────
LAYER 1  net.inc:  socket · connect · send/recv · dns · tls_* vtable
LAYER 0  plat.inc: files · mappings · processes · tty · time · entropy · poll · OAuth socket helpers
```

**Layer 0** is the kernel surface: `os_*` functions declared per OS and
summarized in `src/plat/plat.inc` (see §5.2 below). **Layer 1** is networking: `net_*` plus
the resumable `tls_*` state machine, declared in `src/net/net.inc`. Both are
link-time choices with no runtime dispatch; the test suite links `src/net/mock.s`
in place of the platform network stack.

Boundary rules:

1. Portable layers (`base/`, `core/`, `prov/`, `tools/`, `wire/`, `tui/`,
   `ext/`, `app/`) call Layer 0/1 functions only and include `opcode.inc` plus
   the shared interface headers each layer needs — `core/core.inc` (core ABI),
   `net/net.inc` (Layer 1) and `wire/url.inc`/`wire/http_client.inc`
   (transport).
2. `src/plat/<os>/` and `src/net/<os>/` never include core headers.
3. Platform and network backends are selected at link time, never at runtime.
4. Every layer returns negative Linux `errno` values in `rax`; OS adapters
   translate their own error codes, and non-blocking calls return `-EAGAIN`
   rather than an error in the control-flow sense.
5. JSON crosses external boundaries (wire, sessions, RPC, plugins); typed
   structs stay inside.

## 4. ABI and conventions (`src/opcode.inc`)

- Intel syntax without prefixes; every source begins with `.intel_syntax
  noprefix` and includes `opcode.inc` first.
- Arguments in `rdi, rsi, rdx, rcx, r8, r9`; a second return value in `rdx`;
  callee-saved registers are `rbx, rbp, r12-r15`.
- `FN name` declares an exported, 16-byte-aligned function. `PROLOGUE frame`
  saves the callee-saved registers, reserves `frame` bytes (a multiple of 16)
  and leaves the stack aligned for a `call`; `EPILOGUE` restores and returns.
- `STRUCT`/`F name,size`/`ENDSTRUCT` accumulate struct offsets with no implicit
  padding; every shared layout lives in an `.inc` file.
- `SYS num` issues a raw kernel call (clobbering `rcx` and `r11`); on the
  Windows target it lowers to `call win_syscall`, so one source assembles for
  both. `CSTR`, `GTYPE` and `GSIZE` keep the shared sources free of ELF-only
  directives.
- Errors are negative `errno` values in `rax`. Callers treat `-EAGAIN` as
  "wait for the watch table", not as a failure.

## 5. Components

### 5.1 Base (`src/base/`)

The allocator is a power-of-two size-class allocator (12 classes up to 64 KiB)
over 1 MiB mappings, with a 16-byte header; larger blocks get their own
mapping. `SB` is a growable, NUL-terminated byte buffer and `VEC` is a growable
array of fixed-size items; both live in `opcode.inc`. Strings, UTF-8 decoding
and the shared Unicode width table live in `str.s` and `uni.s`; the width table
is the single source for display columns, used by the composer, the transcript
and the cell grid. The JSON parser accepts JSONC (comments and trailing commas)
with a chained arena that is reset per document. `log.s` handles fatal output
plus a level-gated `log_debug_*` diagnostic API (`log_set_level` and the
`LOG_ERROR`/`LOG_INFO`/`LOG_DEBUG` scale; `--verbose` raises the gate to
`LOG_DEBUG`), and `loop.s` is the poll/watch table (at most 96 entries)
that drives every non-blocking path. `start.s` is the entry point:
`os_init(rsp)` then `opcode_main`. The frozen function contract is
`src/base/API.md`.

### 5.2 Platform (`src/plat/`)

Layer 0 exposes bootstrap, files and mappings, processes, terminal, time,
entropy, `poll`, and the socket helpers the OAuth loopback server needs.
`src/plat/plat.inc` is the shared Layer-0 include: it carries the socket-option
constants the portable layers share and repeats the core subset of the `os_*`
contract as documentation; the full per-function contract is the list in this
section, implemented once per OS. The shared syscall constants (`O_*`, `POLL*`,
`E*`, `AT_FDCWD`, `WNOHANG`, `SIG*`) live in `opcode.inc`; `src/net/net.inc`
carries the Layer-1 constants (`AF_INET`, `SOL_SOCKET`, `SO_ERROR`,
`TCP_NODELAY`, `TLS_*`).

- **Linux x86-64** (`src/plat/linux/`): direct syscalls, no vDSO dependency.
  `openat` is the primitive; `proc.s` uses `fork`+`execve` (never `vfork`),
  `pipe2(O_CLOEXEC)` with non-blocking read ends, and `wait4`; `tty.s` handles
  raw termios, `TIOCGWINSZ` and SIGWINCH delivered as one byte on a pipe;
  `os_sig_cleanup` restores the terminal on fatal signals and re-raises.
  `_start` calls `os_init(rsp)` and `opcode_main` (`src/base/start.s`).
- **Linux AArch64** (`src/plat/linux/aarch64/`): a native AArch64
  `x_syscall` shim, the translator runtime helpers, and the ELF entry point
  `opcode_entry`, which gives the translated x86 stack model its own guarded
  16 MiB mapping. The portable corpus and the `src/plat/linux` wrappers are
  translated to AArch64.
- **macOS arm64** (`src/plat/mac/`): the same `os_*` names over libSystem.
  `mac.inc` carries the native↔translated register/stack contract, `rt.s` the
  `_main` entry and runtime helpers, `sys.s` the `x_syscall` table plus
  flag/struct/errno/termios conversions, and `src/net/mac/net.s` the socket
  stubs. The `src/plat/linux` and `src/net/linux` wrappers are compiled for
  arm64 through the translator and sit on this shim.
- **Windows x86-64** (`src/plat/win/`): the same `os_*` names over Win32.
  `win_syscall` maps the Linux syscall numbers in `opcode.inc` onto Win32;
  `fd.s` owns the descriptor table and UTF-8↔UTF-16 and error mapping; `proc.s`,
  `tty.s` and `dir.s` are native replacements for the three Linux files that are
  not thin syscall wrappers; `sock.s` covers ws2_32; `rt.s` is the PE entry and
  `abi.s` the C↔assembly ABI thunks. The portable sources and the
  `src/plat/linux` + `src/net/linux` wrappers assemble unchanged with
  `--defsym WINDOWS=1`.

### 5.3 Net and TLS (`src/net/`)

Layer 1 declares `net_socket`, `net_connect`, send/recv, shutdown and DNS, plus
the `tls_*` vtable (`tls_new`, `tls_set_fd`, `tls_handshake`, `tls_read`,
`tls_write`, `tls_close`, `tls_pending`, `tls_want`, `tls_last_error`,
`tls_fd`). All sockets are non-blocking; `-EAGAIN` is never an error, and the
TLS handshake is resumable.

- **Linux** (`src/net/linux/`): raw socket syscalls with `TCP_NODELAY=1` and
  `MSG_NOSIGNAL` on send; a hand-built A-record DNS resolver that reads
  `/etc/hosts`, then up to three `nameserver` entries from `/etc/resolv.conf`,
  then public resolvers. TLS is vendored **mbedTLS 3.6.2**, compiled
  freestanding (`third_party/mbedtls/`, `third_party/mbedtls_glue.c`,
  `src/net/linux/tls_shim.c`) with the CA bundle embedded from
  `third_party/cacert.pem`. `dlopen` is impossible in a `-nostdlib` static
  process, so this is the Linux TLS backend.
- **macOS arm64** and **Windows x86-64**: the same vendored mbedTLS backend,
  compiled for the target; Windows reuses the Linux `socket.s`/`dns.s` through
  `win_syscall` and ws2_32, and macOS reuses them through the translator.
- **Mock and replay** (`src/net/mock.s`): the test backend. `FWIR1` files store
  captured client→server records and replayed server→client records; `net_recv`
  returns the replayed bytes then EOF, TLS is a plaintext passthrough, and
  `--record`/`--replay` produce and consume the same format.

### 5.4 Wire (`src/wire/`)

`url.s` parses `http`/`https` URLs into pointer fields (the `Url` layout is
single-sourced in `wire/url.inc` and the parser rejects C0/DEL). `http.s`
builds requests into an `SB` and parses responses (status line, a 64-header
table, `Content-Length` and chunked bodies, `Connection: close`, byte-boundary
splits), rejecting a duplicate `Content-Length` and matching
`Transfer-Encoding`/`Connection` as comma-separated tokens;
`http_client.s` is the shared HTTP(S) transport used by fetch, update, discover,
the OAuth token exchange and the agent's blocking compaction request, and
exposes non-blocking `hc_*` steps for the agent state machine. `sse.s` is an
incremental `event:`/`data:`/`id:` parser with multi-line data, comments and
line-ending tolerance. `jsonw.s` is the streaming JSON writer with RFC 8259
escaping and no whitespace. `Accept-Encoding: identity` is used because SSE
responses are not compressed. The frozen contract is `src/wire/API.md`.

### 5.5 Core agent (`src/core/`)

**Data model.** The transcript is a `VEC` of 40-byte `Msg` headers; content
blocks are 24-byte records (text, thinking, tool call); tool calls hold owned
id/name/args strings; usage is 24 bytes. Strings are owned copies released as a
unit by `tr_free`. Tool arguments stay a raw JSON string while streaming and are
parsed once on completion; JSON DOMs are used only for wire parsing and
config/session work, with the parser arena reset per document.

**Loop.** `src/core/agent.s` is a single non-blocking state machine
(`AS_IDLE`, `AS_CONNECT`, `AS_HANDSHAKE`, `AS_SEND`, `AS_RECV`, `AS_TOOLS`,
`AS_TURN`, `AS_DONE`, `AS_ERROR`) driven by the watch table. A turn streams
connect → TLS handshake → send → receive/SSE → tools → next turn or finish, and
the transport closes at the end of each turn. The UI hook receives typed `SE_*`
events (`SE_TEXT`, `SE_TEXT_END`, `SE_THINK`, `SE_THINK_END`,
`SE_TOOL_START/DELTA/END`, `SE_USAGE`, `SE_DONE`, `SE_ERROR`,
`SE_TOOL_RESULT`, `SE_COMPACT`, `SE_TOOL_EXEC`); `-p`, `--mode json` and
`--mode rpc` consume the same events. Abort closes the connection, kills child
jobs, synthesizes an aborted assistant message and returns queued input to the
editor.

**Providers.** Each wire API is a `PV_*` vtable (`PV_new`, `PV_build`,
`PV_path`, `PV_sse`, `PV_finish`, `PV_free`) selected from the model record's
`api` field through one static dispatch table (`prov_table`/`prov_for_api`),
which falls back to `prov_openai` for an unknown api. `anthropic-messages` (`src/prov/anthropic.s`) posts
`/v1/messages` with the prompt in a top-level `system` array and an optional
`thinking` object. `openai-chat` (`src/prov/openai.s`) posts
`/chat/completions` with the prompt as a `role:"system"` message, buffers
`tool_calls` by index, and is shared by `openai`, `google` (via Google's
OpenAI-compatible endpoint) and `ollama`/`ollama-cloud`. `openai-responses`
(`src/prov/openai_responses.s`) posts `/responses` with the prompt in
top-level `instructions` and its own event map. Anthropic thinking levels map
to `budget_tokens` on models flagged as reasoning-capable, clamped below
`max_tokens`.

**Auth and OAuth.** `auth_key(provider)` resolves `--api-key` → stored OAuth
credential → `auth.jsonc` API key → provider environment variable → config
`api_keys.<provider>`. A stored OAuth credential owns the provider: an expired
token is fail-closed, never a silent fallback. `opcode login`/`opcode logout`
implement authorization code + PKCE S256 with a loopback-only callback server
bound to both `::1` and `127.0.0.1`; tokens are stored atomically with mode
0600 and served until expiry.

**Sessions.** Append-only JSONL, one tagged object per line (`session`,
`message`, `model_change`, `custom`, `compaction`), snake_case keys, Unix
millisecond timestamps, an `id`/`parent_id` chain and `schema_version` in the
header. Files live under `$OPCODE_SESSION_DIR`, else config `session_dir`, else
`$XDG_DATA_HOME/opcode/sessions/--<sanitized-cwd>--/`. `--continue`/`--resume`
open the newest session for the cwd, `--session` names one, and `--no-session`
disables persistence. The full schema is in `src/core/API.md`.

**Prompt and resources.** `prompt_build` writes named sections in order:
preamble, tools, rules, addendum, project context, skills, and the environment
block (cwd, platform, UTC date). Context files are `AGENTS.override.md`,
`AGENTS.md`, `OPCODE.md` and `CLAUDE.md` from the config dir and every cwd
ancestor; `SYSTEM.md` replaces the preamble and `APPEND_SYSTEM.md` appends.
Skills and prompt templates are discovered from the config dir and, when the
directory is trusted, the project `.opcode/` tree. Project resources are gated
on `--approve`, an interactive trust prompt in an interactive TUI
(`config_trust_ask`, saved by `config_trust_save`), or a `<config>/trust.jsonc`
entry; a plugin can contribute extra skill/prompt/theme roots through the
`resources_discover` event (`add_resource_root`).

**Compaction.** Before every idle turn, `compact_maybe_run` estimates
`last usage + chars/4` of trailing messages and, when the estimate exceeds
`context_window - 16384` (the `g_compact_reserve` headroom default), requests a
summary on the streaming wire and replaces the old transcript prefix, keeping
the most recent `COMPACT_KEEP_TOKENS` (20000) tokens of tail and recording a
`compaction` entry. `SE_COMPACT` reports the tokens before and the messages
kept.

**Catalog and discovery.** `runtime/catalog.json` is the built-in seed;
`tools/gen-catalog.py` emits `build/catalog.s`, a sorted table of 56-byte model
records exposed through `catalog_find`, `catalog_default`, `catalog_count` and
`catalog_at`. `opcode models --refresh` runs `discover_models`
(`src/core/discover.s`), merges ids from the provider's `/models` endpoint (or
Ollama's `/api/tags`) into the built-in catalog, and rewrites
`<config>/models.jsonc`. `diff.s` provides the line-based unified diff used by
the `edit` tool. The design decisions the implementation follows are listed in
`.agents/docs/design-decisions.md`.

### 5.6 Tools (`src/tools/`)

Tools are static `TL_*` descriptors with a name, description, embedded JSON
schema, flags (`TL_READONLY`, `TL_SEQUENTIAL`, `TL_DESTRUCTIVE`, plus
`TL_PROMPT` on appended plugin descriptors) and an `exec`
plus optional `finish`. `tool_validate` parses the tool's own `TL_params` schema
and enforces its `required`/`properties` types; a new tool needs a correct
schema, not a validator edit. `edit` and `write` share the `tool_write_atomic`
helper (temp file + rename, symlink refusal). Each call becomes a `J_*` job: an
in-process operation
or a child process watched through a non-blocking output pipe. A batch starts
every call as a job; a batch containing any `TL_SEQUENTIAL` tool starts one at a
time and waits for it before the next, otherwise the jobs run concurrently;
results append in source order while jobs complete, and
the loop kills a child that passes its absolute `J_deadline_ms`. Plugin tools may
append `TL_snippet`/`TL_guidelines` (`TL_PROMPT`) to feed the system prompt.
Built-ins are
`read` (numbered lines with `offset`/`limit` and head truncation), `bash`
(`sh -lc command`, stdout+stderr captured, default 120 s timeout), `edit`
(unique non-overlapping `oldText`/`newText`, BOM/CRLF preserved, atomic write,
unified diff), `write` (recursive parents, atomic write), `ls`, `find` (own
glob matcher with depth and entry caps) and `grep` (literal or small regex,
case folding, context lines, binary/large-file skips). Tools accept the model's
path verbatim: there is no workspace jail. MCP server tools join the same
registry as `mcp__<server>__<tool>`.

### 5.7 TUI (`src/tui/`)

The TUI is a shell over `agent_init`/`agent_submit`/`agent_step` and the typed
`SE_*` sink; it never reimplements the agent and never parses JSON. It offers
three renderers over the same state: `scrollback` (append-only history with a
redrawn footer), `inline` (the default: a rectangular bottom region that
commits finished messages into real scrollback) and `fullscreen` (the alternate
screen and a full cell grid). `term.s` owns raw mode, SIGWINCH, the alternate
screen, the OSC 11 background and signal-safe restore. `render.s` is a 24-byte
cell grid with one combining mark per cell, `CELL_CONT` continuation cells for
width-2 glyphs, and a differential `writev` flush. `view.s` is the fixed-row
styled transcript buffer. `editor.s` is the multiline UTF-8 composer with a
readline key map, bracketed-paste collapsing and disk-backed history;
`input.s` is the incremental escape-sequence parser (CSI/SS3/kitty, bracketed
paste, a 50 ms lone-ESC disambiguation). `menu.s` is the slash-command menu,
`status.s` a provider segment registry that renders the footer, `markdown.s` a
streaming block model, and `card.s` the tool-card state machine and renderer.
`theme.s` resolves a built-in dark/light/system palette plus named
`themes/<name>.jsonc` files and downgrades SGR for 256/16-colour terminals.
`--headless WxH --script FILE` renders into the in-memory grid for golden tests,
and `--headless-capture FILE` asserts the raw byte stream. The frozen contract
is `src/tui/API.md`; the renderer and editor details are in
`.agents/docs/tui.md`.

### 5.8 Ext (`src/ext/`)

`ext/mcp.s` is a stdio JSON-RPC 2.0 MCP client: it reads `mcp.jsonc` from the
config dir and project `.opcode/`, spawns each server, performs the
`initialize`/`initialized`/`tools/list` handshake with a deadline, registers
server tools in the tool registry, and runs `tools/call` through the same job
path; a `result.isError` maps to a tool error and shutdown closes stdin, sends
`SIGTERM`, reaps with a bounded non-blocking grace, then `SIGKILL`s the child's
process group. `ext/plugin.s` and `ext/host.s` implement the static C ABI from
`include/opcode_plugin.h`: a plugin exports one `opcode_plugin_init` symbol, the
build compiles each manifest entry with a unique init name and links it, and the
host vtable exposes allocation, logging, tool and command registration, event
registration, JSON helpers and session/status hooks. Registered plugin commands
are listed in the slash menu and dispatched; `resources_discover` roots feed the
skill/prompt/theme scanners. The ABI is append-only with
`struct_size`/`abi_version` checks. Runtime loading is not available in a static
`-nostdlib` binary. Details and current host limitations are in
`.agents/docs/extensibility.md`.

### 5.9 App (`src/app/`)

`main.s` dispatches subcommands, `--version`/`--help` and `--list-sessions`;
`cli.s` is the shared
flag parser, usage renderer and session resolver; `modes.s` implements the JSON
and RPC front ends; `run.s` and `tui.s` drive print mode and the TUI;
`onboard.s` is the first-run provider menu; `login.s`, `models.s`, `fetch.s` and
`update.s` implement the subcommands.

Modes: the TUI (the default), `-p`/`--print` (one prompt to stdout, exit 0/1),
`--mode json` (JSONL events on stdout) and `--mode rpc` (JSONL commands in,
responses and events out, with the documented command set).

Subcommands: `opcode login|logout [provider]`, `opcode models [--refresh]
[--provider P]`, `opcode fetch URL`, `opcode update [--check] [--offline]`
(checks `https://api.github.com/repos/abird-ai/opcode/releases/latest`);
`opcode --list-sessions` prints the cwd's sessions (newest first) and exits.

Agent front-end flags: `--provider`, `--model`, `--api-key`, `--base-url`,
`--system`, `--replay FILE`, `--max-tokens`, `--thinking`, `--offline`,
`--continue`, `--resume`, `--session`, `--session-dir`, `--no-session`,
`--template NAME [args...]`, `--approve`, `--verbose`. `--verbose` raises the
log gate to `LOG_DEBUG` and emits request/response/tool diagnostics. The TUI
additionally accepts `--headless WxH`, `--headless-capture FILE`, `--script FILE`,
`--tui-mode`, and `--theme`; the modes front ends accept `--mode json|rpc` and
`-p`/`--print`; `opcode fetch` accepts request/record flags such as `--method`,
`--header`, `--data`, `--record FILE`, `--dump-wire` and `--insecure`; `--record`
is `fetch`-only — the agent front ends take `--replay FILE` only.

## 6. Performance budget

| Metric | Target |
|---|---|
| time to first frame (`--version`) | < 3 ms |
| RSS idle (TUI, 20k-token session) | < 12 MB |
| binary size (stripped, static) | ~640 KB (vendored mbedTLS + CA bundle included) |
| stream→screen latency per delta | < 100 µs |
| allocations per assistant turn | O(1) amortized (arena reset) |
| syscalls per fullscreen frame | one `writev` |

Mechanisms: arena reset per request, the zero-copy TLS→HTTP→SSE path, no DOM for
deltas, tick-driven coalesced rendering, static buffers for prompt assembly,
`TCP_NODELAY` on agent sockets, and a single non-blocking poll loop.

## 7. Testing and build

The toolchain is GNU `as` and `ld`, `clang` (vendored freestanding TLS, plugin C,
and the arm64 cross-assembler/compiler) and `python3` (generated assets,
catalog and plugin tables).

| Command | Result |
|---|---|
| `make` | build the debug binary `build/opcode` |
| `make release` | relink `build/opcode` stripped |
| `make test` | build the unit-test binaries |
| `make check` | build everything and run `tests/run.sh`; run it for the current count (a clean tree ends `0 failed`) |
| `make TARGET=linux-aarch64` / `make linux-aarch64` | cross-build the static no-libc AArch64 ELF |
| `make test-qemu` | run the full suite against the AArch64 ELF under `qemu-aarch64` |
| `make arm64-translate` | translate and assemble every portable source for `arm64-apple-macos11` (the syntax gate) |
| `make darwin-arm64` / `darwin-arm64-smoke` / `darwin-arm64-test` | build the mac app / smoke / unit binaries; on a non-Darwin host the objects assemble and the link is skipped |
| `make darwin-arm64-cross ARM64_LD="…/zig cc"` | Linux cross-link of the app and smoke as Mach-O arm64 |
| `make windows-x86_64` / `make test-wine` | build the PE32+ `-nostdlib` binary / run the Wine lane |
| `nix build` / `nix build .#release` | package the native debug / stripped release |
| `nix build .#linux-aarch64` | package the cross-built AArch64 ELF |
| `nix build .#darwin-arm64-cross` | the Linux cross build plus `tools/check-macho.sh` |
| `nix run .#targets` | print the cross-build target table |

`make check` combines golden unit binaries (`tests/*.s` compared byte-for-byte
with `tests/data/<name>.expected`), CLI checks and the shell/python integration
suites (loopback HTTP/SSE/TLS, agent round-trip, sessions, modes, onboarding,
Ollama, MCP, OAuth, update, term state and the headless TUI). Wire behaviour is
driven by `FWIR1` record/replay files; the TUI is driven headlessly with
`--headless --script`. `opcode.inc` and `tests/run.sh` are the reference for the
ABI and the suite, and a tested contract change updates the matching `.expected`
file in the same change.

## 8. Port status

- **linux-x86_64** — the reference platform: direct syscalls, the full suite,
  exercised end to end.
- **linux-aarch64** — implemented: the portable corpus and the Linux wrappers
  are translated to AArch64 by `tools/arm64.py`, a native shim under
  `src/plat/linux/aarch64/` provides syscalls and the ELF entry, and the full
  suite runs against the static ELF under `qemu-aarch64`. It has not yet run on
  AArch64 hardware.
- **darwin-arm64** — implemented: native AArch64 Darwin sources
  (`src/plat/mac/`, `src/net/mac/`) sit under translated portable and Linux
  wrapper sources, and the same vendored mbedTLS backend is compiled for arm64.
  The app, the Layer-0 smoke binary and the unit binaries cross-link as Mach-O
  arm64 on Linux and pass `tools/check-macho.sh`. The `macos-14` CI lane is
  defined but has not been executed here, and the binary has not run on Apple
  hardware.
- **windows-x86_64** — implemented: the portable corpus assembles with
  `--defsym WINDOWS=1`, `src/plat/win/` provides the syscall shim and native
  process/console/directory layers, and the PE32+ binary links `-nostdlib`
  against kernel32, ws2_32, bcrypt and shell32. The Wine lane passes with a set
  of documented divergences (CRLF from `cmd.exe`, no Unix PTY, no ELF MCP
  servers, no POSIX mode bits). It has not run on real Windows.
- **linux-riscv64** — no port sources exist; the target stays gated closed.
- **darwin-x86_64** — deliberately not implemented; the Darwin work is
  AArch64-only.

`.agents/docs/ports.md` carries the port checklist, the emulation matrix and the
evidence for each level. `.agents/docs/platform.md` documents the Layer 0/1
contracts, DNS and the vendored TLS decision.

## 9. Licensing and attribution

Opcode is MIT — see `LICENSE`. `THIRD_PARTY.md` documents the bundled and adapted
components: the unmodified vendored **mbedTLS 3.6.2** subset (Apache-2.0 or
GPL-2.0-or-later), the embedded **Mozilla CA bundle** from
<https://curl.se/ca/cacert.pem> (MPL-2.0), and the files adapted from the
MIT-licensed **rhun** project (the allocator, strings and JSON-parser approach,
the negative-errno syscall convention, the `tools/arm64.py` translator and the
macOS/AArch64 platform layer).

Opcode thanks **rhun** (<https://github.com/vshvedov/rhun>), a hand-written
assembly editor that showed a serious full-featured application can be built in
hand-written assembly, and **pi** (<https://github.com/earendil-works/pi>) for
design and terminal-UX inspiration; the built-in model catalog carries
MIT-licensed model metadata published by pi.

## 10. Settled decisions

1. **Name:** Opcode.
2. **Formats:** JSONC for config, auth and themes; opcode's own serde-friendly
   JSONL schema for sessions. There is no external interop target.
3. **Authentication:** OAuth subscription logins ship in the core feature set,
   with a loopback-only callback server and PKCE S256.
4. **macOS:** arm64 only; Intel macOS is not supported.
5. **Tool scheduling:** parallel tool execution is the default; `TL_SEQUENTIAL`
   marks a tool that must serialize, and the batch driver enforces it (one job
   at a time).
6. **TLS:** vendored mbedTLS serves every target from the start; the `tls_*`
   contract keeps a future replacement (including a pure-assembly TLS 1.3
   client) a link-local swap.
7. **Tools are unconfined filesystem primitives:** they act on the user's
   environment by design; `edit` and `write` are destructive and keep the
   target mode and atomic-write behavior.
8. **Process and signal policy:** `os_init` ignores `SIGPIPE`; `os_spawn` puts
   each child in its own process group and timeout/abort paths signal the group.

## 11. Repository layout

```
.agents/AGENTS.md              coding-agent guide (build, ABI, tests)
.agents/plans/DESIGN.md        this document
.agents/docs/                  design-decisions, platform, core-agent, extensibility, tui, ports
include/opcode_plugin.h         stable C ABI (C/Rust/Zig)
Makefile                       Linux/native build plus the cross-build recipes
flake.nix / flake.lock         Nix packages, checks and dev shell
runtime/catalog.json           built-in model seed
src/opcode.inc                  macros, constants, struct offsets
src/base/                      start, mem, str, uni, json (JSONC), log, loop
src/plat/linux/                Layer 0: sys, fs, dir, proc, tty, net
src/plat/linux/aarch64/        native AArch64 shim and ELF entry
src/plat/mac/                  Layer 0 over libSystem (arm64)
src/plat/win/                  Layer 0 over Win32
src/net/linux/                 Layer 1: socket, dns, tls_shim.c  (+ src/net/mock.s)
src/net/mac/  src/net/win/     Layer 1 per-OS socket/TLS shims
src/wire/                      url, http, http_client, sse, jsonw
src/core/                      agent, messages, prompt, tools, catalog, auth, oauth, session, config, diff, compact, discover
src/prov/                      anthropic, openai, openai_responses
src/tools/                     read, bash, edit, write, ls, find, grep
src/tui/                       term, render, view, editor, input, menu, status, markdown, card, theme
src/ext/                       host, plugin, mcp
src/app/                       main, cli, run, modes, tui, fetch, login, models, update, onboard
plugins/                       manifest + example C plugin
tests/                         unit tests, golden data, integration suites, TUI scripts
third_party/                   vendored mbedTLS subset, CA bundle, glue
tools/                         asset/catalog/plugin generators, arm64 translator, port checks
```
