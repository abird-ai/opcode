# Core agent

This is the specification of everything under `src/core/`, `src/prov/`,
`src/tools/` and `src/wire/`. All of it is portable code: it includes
`opcode.inc` plus the shared interface headers it needs (`core/core.inc` for the
core ABI, `net/net.inc` for Layer 1 and `wire/url.inc`/`wire/http_client.inc`
for transport), calls Layer 0/1 through `os_*`/`net_*`/`tls_*`, and never
contains an OS branch. The frozen function-level contract is
in `src/core/API.md`.

---

## 1. Data model

The transcript is a `VEC` of `Msg` headers. Strings and block arrays are owned
copies (`mem_alloc`d) and are released as a unit by `tr_free`; nothing is
reference-counted. The exact layouts live in `src/core/core.inc`:

```asm
STRUCT                       # 40 bytes
F M_role, 4                  # MR_SYSTEM, MR_USER, MR_ASSISTANT, MR_TOOL_RESULT
F M_flags, 4                 # error/aborted/pending bits
F M_blocks, 8                # -> VEC of Block
F M_stop, 4                  # SR_* (pending/stop/length/tool_use/error/aborted)
F M_pad, 4
F M_usage, 8                 # -> Usage (assistant/tool only)
F M_call_id, 8               # tool_call id for MR_TOOL_RESULT (owned cstr)
ENDSTRUCT M_SIZE

STRUCT                       # 24 bytes
F B_type, 4                  # BT_TEXT, BT_THINK, BT_TOOLCALL
F B_flags, 4
F B_ptr, 8                   # text bytes | ToolCall* | image bytes
F B_len, 8
ENDSTRUCT B_SIZE

STRUCT                       # ToolCall, 24 bytes; strings owned by the message
F TC_id, 8                   # provider tool_call_id (cstr)
F TC_name, 8                 # tool name (cstr)
F TC_args, 8                 # raw JSON string, parsed lazily (cstr)
ENDSTRUCT TC_SIZE

STRUCT                       # Usage, 24 bytes
F U_input, 4
F U_output, 4
F U_cache_read, 4
F U_cache_write, 4
F U_total, 4
F U_pad, 4
ENDSTRUCT U_SIZE

STRUCT
F TR_msgs, 8                 # VEC* of Msg
F TR_owned, 8                # VEC* of allocated pointers for tr_free
ENDSTRUCT TR_SIZE
```

Tool arguments stay as a raw JSON string while the call streams; they are parsed
once when the call completes and never held as a DOM. JSON DOMs exist only for
wire parsing and config/session work, and the parser arena is reset per document
(`src/base/json.s`).

## 2. Agent loop

`src/core/agent.s` is a non-blocking state machine driven by the watch table
(`src/base/loop.s`). Its states are `AS_IDLE`, `AS_CONNECT`, `AS_HANDSHAKE`,
`AS_SEND`, `AS_RECV`, `AS_TOOLS`, `AS_TURN`, `AS_DONE`, `AS_ERROR`. Entry
points:

```
agent_init()                    # MDF model resolution, session load, plugins, MCP
agent_run(prompt) -> exit code  # print-mode driver: init + submit + step until done
agent_submit(prompt) -> 0|1      # start a turn (0 = accepted, 1 = busy)
agent_step(timeout_ms)           # one loop iteration
agent_busy() -> 1|0
agent_exit_code() -> code
agent_abort()                    # close transport, kill children, synthesize abort
```

The agent is a **process-global singleton**, not an object: its state lives in
file-global storage in `agent.s`, there is exactly one agent per process, and it
is not reentrant (`agent_run`/`agent_submit` must not be called from an agent
callback, and `agent_init` is one-time setup). Callers that need two
conversations fork. `agent_abort()` is cooperative: the next `agent_step` runs
the teardown, emits `SE_DONE`/`SR_ABORTED` once and leaves the run finished with
`agent_exit_code() == 0` (an abort is a user action, not a failure); a real
failure sets exit code 1. Fatal `SIGINT`/`SIGTERM` run the platform exit hook and
re-raise, so the process terminates with `128 + signum`.

The TUI uses `agent_init`/`submit`/`step` directly; `-p`, `--mode json` and
`--mode rpc` use `agent_run` (or the same step API) and differ only in the
installed UI hook.

Behavior:

- The request body is streamed into the send buffer (system prompt + tools +
  transcript) with the JSON writer; no intermediate DOM.
- Connections are resumable: DNS → non-blocking connect → TLS handshake, then
  the transport is closed at the end of each turn (no keep-alive reuse yet).
- SSE events are decoded by the provider into typed `SE_*` events and appended
  to the live assistant message; the UI renders on its own tick, not per delta.
- Tool calls run as jobs (§5). `tool_execution_end` ordering and source-order
  result appends match the job model. `TL_SEQUENTIAL` is enforced by the batch
  driver: when any call in a batch targets a sequential tool (the in-process
  `read`/`ls`/`find`/`grep`), the batch starts one job at a time and waits for it
  before the next; other batches (`bash`, `edit`, `write`) start every job
  concurrently.
- `error` and `aborted` stops are hard stops: remaining tool calls do not run
  and the run ends with an error assistant message.
- Abort closes the transport, kills child processes, appends an aborted
  assistant message, and returns queued input to the editor.

### 2.1 Sink events

Internal consumers (TUI, JSON/RPC front ends) receive typed events through the
sink in `core/core.inc`:

```
SE_TEXT        a=ptr b=len        SE_TEXT_END
SE_THINK       a=ptr b=len        SE_THINK_END
SE_TOOL_START  a=id  b=name       SE_TOOL_DELTA a=ptr b=len     SE_TOOL_END
SE_USAGE       a=Usage*
SE_DONE        a=SR_*
SE_ERROR       a=cstr
SE_TOOL_RESULT a=ptr b=len        # UI hook only, after a tool result is appended
SE_TOOL_EXEC   a=TE*              # UI hook only, full tool-execution record
SE_COMPACT     a=tokens_before u32  b=kept_messages u32
```

There is no separate event bus. JSON is generated from these events only at the
external boundaries: session log, `--mode json`, RPC, and plugin payloads.

## 3. Providers

Each wire API is a vtable (`src/core/core.inc`) selected from the model record's
`api` string in `agent_init` through one static dispatch table plus
`prov_for_api(api)` in `agent.s`; the table falls back to `prov_openai` for an
unknown or missing api, so adding an adapter is one table row:

```asm
STRUCT
F PV_new, 8     # (MD*) -> ctx
F PV_build, 8   # (ctx, SB*, sys cstr, Transcript*) -> 0|-errno  (JSON body)
F PV_path, 8    # (ctx) -> endpoint path
F PV_sse, 8     # (ctx, SS*, event, data) -> 0
F PV_finish, 8  # (ctx, SS*) -> 0; emits SE_DONE/SE_ERROR if the stream ended
F PV_free, 8    # (ctx)
ENDSTRUCT PV_SIZE
```

Request headers, auth and transport stay in `agent.s`; the adapter only builds
the body and maps stream events. Adapters:

- **`anthropic-messages`** (`src/prov/anthropic.s`): `POST /v1/messages` with
  `x-api-key`, `anthropic-version`, `accept: text/event-stream`, optional
  `anthropic-beta`. Body: model, max_tokens, system, messages, tools,
  `stream:true`, optional `thinking`. SSE: `message_start`,
  `content_block_start/delta/stop`, `message_delta`, `message_stop`, `error`.
  Tool arguments accumulate from `input_json_delta` and the call is emitted on
  the tool_use block's `content_block_stop`. Stop map: `end_turn|stop_sequence|
  pause_turn → SR_STOP`, `max_tokens → SR_LENGTH`, `tool_use → SR_TOOL_USE`,
  `refusal → SR_ERROR`.
- **`openai-chat`** (`src/prov/openai.s`): `POST /chat/completions` with
  `Authorization: Bearer` when a key exists; body with model, messages, tools,
  `stream:true`, `stream_options:{include_usage:true}`, optional output cap
  (`max_completion_tokens`, or `max_tokens` for `ollama`/`ollama-cloud`; §7.2).
  Deltas keyed by `tool_calls[].index`; reasoning from
  `reasoning_content`/`reasoning`; `[DONE]` sentinel; tool calls without an id
  get a synthetic `call_<index>`. The `google` provider reuses this adapter
  against Google's OpenAI-compatible base
  (`https://generativelanguage.googleapis.com/v1beta/openai`).
- **`openai-responses`** (`src/prov/openai_responses.s`): `POST
  /responses`, same SSE plumbing, own event map keyed by `output_index`. The
  composed prompt is the top-level `instructions` string, not a `role:"system"`
  input item (§7.2).

## 4. Model catalog and discovery

`runtime/catalog.json` is the built-in seed (21 models: anthropic, google,
openai, ollama, ollama-cloud). `tools/gen-catalog.py` emits `build/catalog.s` —
a sorted string table plus one 56-byte record per model — and `core/catalog.s`
exposes `catalog_find(provider, id)`, `catalog_default(provider)`,
`catalog_count()` and `catalog_at(i)`. There is no runtime JSON parsing of the
built-in table. `catalog_default` prefers the model flagged `MDF_DEFAULT` for a
provider (set by `"default": true` in the catalog), then falls back to the
first model of the provider.

`opcode models --refresh` runs `discover_models()` (`src/core/discover.s`): it
resolves the provider base URL, GETs `<base>/models` (or the Ollama native
`/api/tags` fallback), merges the ids with the built-in catalog and atomically
rewrites `<config dir>/models.jsonc`, which `catalog_load_user()` reads at
startup. See `.agents/docs/design-decisions.md` for the catalog's provenance.

Successful probes also append a `{provider, base, fetched, count}` entry to
`<config dir>/models-cache.jsonc` (one JSON object per line; the newest matching
entry wins). `discover_models_cached(provider, verbose, force)`
(`src/core/discover.s`) reuses that entry while `now - fetched < 24 h`
(`DISC_TTL_MS`), unless `force` is set. `--refresh-models` forces discovery for
the resolved or all configured providers and ignores the fresh cache;
`--offline` never probes and falls back to the cached count. A probe failure is
never fatal: the cached count is returned. The top-level `--list-models [FILTER]`
(`src/app/models.s`) discovers the resolved provider (cache first unless
`--refresh-models`), loads the user catalog, and prints the deduplicated
built-in + discovered set as `provider/id (builtin|discovered)`, optionally
filtered by a substring of provider/id/name, then exits without starting the
agent.

## 5. Tools

### 5.1 Registry

Tools are static descriptors in a `VEC`:

```asm
STRUCT
F TL_name, 8      F TL_label, 8     F TL_desc, 8
F TL_params, 8    # embedded JSON schema (cstr)
F TL_flags, 4     # TL_READONLY, TL_SEQUENTIAL, TL_DESTRUCTIVE, TL_PROMPT
F TL_pad, 4
F TL_exec, 8      # (Job*) -> 0|-errno
F TL_finish, 8    # (Job*) -> 0; at child EOF (may be null)
F TL_snippet, 8   # plugin `# Tools` line, TL_PROMPT only (0 = generic name)
F TL_guidelines, 8# plugin `# Rules` bullets, TL_PROMPT only (0 = none)
ENDSTRUCT TL_SIZE # 72

STRUCT
F J_tool, 8       F J_call_id, 8   F J_args, 8    F J_pid, 8
F J_fd, 8         F J_out, 8       # SB* result text
F J_state, 4      F J_flags, 4     F J_deadline_ms, 8
ENDSTRUCT J_SIZE
```

`tool_validate` is schema-driven: it finds the tool, parses the tool's own
`TL_params` JSON schema and enforces the object root plus every name in that
schema's `required` array, checking the declared `properties` type for the
common JSON types (`string`, `array`, `object`, `integer`, `number`,
`boolean`). Missing, null or wrong-typed required fields and a non-object root
become an error tool result, never a provider error. A new tool only needs a
correct embedded schema; an unknown tool, a tool with no schema or a malformed
schema accepts any object (its `exec` reports).

### 5.2 Built-in tools

| Tool | Behavior |
|---|---|
| `read` | numbered lines, `offset`/`limit`; head truncation at 2000 lines / 50 KB with a continuation hint; first 8 KB NUL sniff rejects binaries |
| `bash` | `sh -lc <command>`, stdout+stderr captured on a non-blocking pipe; default timeout 120 s, cap 1800 s; exit code appended; `[timed out]` marker |
| `edit` | `{path, edits:[{oldText,newText}]}`; matches located in the original text, each unique and non-overlapping, applied right-to-left; BOM/CRLF preserved; atomic temp + rename (shared `tool_write_atomic`); returns a unified diff (capped) |
| `write` | `{path, content}`; creates parents recursively; atomic temp + rename (shared `tool_write_atomic`) |
| `ls` | sorted entries, directories suffixed `/`, limit 200 |
| `find` | own glob matcher; depth 32, 20 000-entry cap, sorted, default limit 200 with a truncation notice |
| `grep` | literal or small regex (`. * ^ $ [sets] \`), case folding, context lines; skips `.git`, `node_modules`, `build`; files ≤ 2 MB, binary skip; 500-byte line cap, default limit 100 |

MCP server tools (`mcp__<server>__<tool>`) join the same registry
(`src/ext/mcp.s`); no managed binaries are downloaded.

## 6. Wire layer

- **URL** (`src/wire/url.s`): `http`/`https`, host/port/path/query pointers into
  the input, default ports 80/443. The `Url` layout is single-sourced in
  `src/wire/url.inc`; scheme, host, path and query reject C0 controls and DEL
  (so CR/LF cannot smuggle a header or request line).
- **HTTP client** (`src/wire/http.s`): request builders append to an `SB`;
  the parser handles status line, a 64-header table, `Content-Length` and
  chunked bodies, `Connection: close`, and byte-boundary splits.
  `Accept-Encoding: identity` (SSE responses are not compressed). A duplicate
  `Content-Length` header is rejected; `Transfer-Encoding` and `Connection` are
  matched as comma-separated tokens (so `xchunked`/`close-me` do not match);
  request-header values and the URL reject CR/LF; a `Content-Length` is parsed
  with a bounded decimal parser rather than the wrapping `parse_u64`.
- **SSE** (`src/wire/sse.s`): incremental `event:`/`data:`/`id:` parser,
  multi-line data joined with `\n`, comments, blank-line dispatch, LF/CRLF/CR.
  Limits: 512 KB line, 1 MB event; overflow sets an error and skips to the next
  event.
- **JSON writer** (`src/wire/jsonw.s`): streaming object/array/key/value
  writer with RFC 8259 escaping, no whitespace.
- **Retry:** not implemented in this build. There is no `src/wire/retry.s`;
  transient failures surface as errors. Backoff is future work
  (`.agents/docs/roadmap.md`).

## 7. System prompt and resources

`prompt_build()` writes the system prompt into an `SB` section by section
(`src/core/prompt.s`):

The composed string is provider-agnostic — the same bytes are built for every
provider, and only JSON placement and a few provider-scoped parameters differ
(§7.2, ADR-7). The blocks, in the order they are emitted:

| # | Block | Purpose | Where (`src/core/prompt.s`) |
|---|---|---|---|
| 1 | preamble | identity and operating behaviour | `<config>/SYSTEM.md`, else the built-in text (`:97-99`, `:1929-1942`) |
| 2 | `# Tools` | one line per active tool, `name: description` | the active `TL_desc` set, or a plugin `TL_snippet` (`:1944-1999`) |
| 3 | `# Rules` | tool and conduct guidelines plus plugin `TL_guidelines` bullets | the `.LS_rules` literal (`:104-108`, `:2000-2027`) |
| 4 | addendum | caller-supplied extra instructions | `<config>/APPEND_SYSTEM.md` and, when trusted, `<cwd>/.opcode/APPEND_SYSTEM.md`, wrapped in `<addendum>` (`:2028-2053`) |
| 5 | project_context | repository instructions | context files from the config dir and every cwd ancestor, wrapped in `<project_instructions path=…>` (`:2054-2070`) |
| 6 | `<available_skills>` | skill index plus one instruction to read a matching skill | `<config>/skills/**/SKILL.md`, `<cwd>/.opcode/skills/**/SKILL.md` and `resources_discover` skill roots (`:2071-2103`) |
| 7 | `# Environment` | `- cwd:`, `- platform:` and `- date:` (UTC) facts | `prompt_build`'s tail, kept last because these are the turn-varying facts (ADR-8/T3, ADR-12) (`:2104-2148`) |

The `# Tools` line and `# Rules` bullets also incorporate a plugin's
`prompt_snippet`/`prompt_guidelines` when its descriptor carries `TL_PROMPT`
(§5.1), and prompt-template discovery scans plugin `resources_discover` roots.
The output always ends with `\n`.

- Context file names: `AGENTS.override.md`, `AGENTS.md`, `OPCODE.md`,
  `CLAUDE.md`. Project context and project skills load only when the directory
  is trusted (`--approve`, an interactive TUI prompt saved with
  `config_trust_save`, or the path saved in `<config>/trust.jsonc`).
- Skills: `<config>/skills/**/SKILL.md` and `<cwd>/.opcode/skills/**/SKILL.md`;
  frontmatter provides `name`/`description`; the body is loaded when the model
  reads the file.
- Prompt templates: `<config>/prompts/*.md` and `<cwd>/.opcode/prompts/*.md`;
  `--template NAME [args...]` expands `$1..$9`, `${N}`, `${N:-default}`,
  `$@`/`$ARGUMENTS`, `${@:N}`, `${@:N:L}`.

### 7.1 Configuration

JSONC files: `<config dir>/config.jsonc` (user) and `<cwd>/.opcode/config.jsonc`
(project, trusted only). `<config dir>` is `$XDG_CONFIG_HOME/opcode`, else
`~/.config/opcode`. Keys the implementation reads:

- `default_provider`, `default_model`
- `session_dir`, `theme`, `default_thinking`
- `providers.<id>.base_url`
- `api_keys.<id>`

Unknown keys are ignored. `opcode models --refresh` writes discovered models to
`<config dir>/models.jsonc`; credentials live in `<config dir>/auth.jsonc`.

### 7.2 Per-provider composition

All three adapters send the same composed string; they differ only in where it
is placed and in the provider-scoped parameters below (ADR-7). The prompt text
is byte-identical for every provider.

| `api` | Where the prompt lands | Tool definition shape | Provider-only extras |
|---|---|---|---|
| `anthropic-messages` | top-level `system` array `[{"type":"text","text":…}]` (`src/prov/anthropic.s:588-616`) | `{name, description, input_schema}` (`anthropic.s:669-712`) | optional `thinking` object (`anthropic.s:568-580`); the OAuth `anthropic-beta` header (§8) |
| `openai-chat` | `messages[0]` as `{"role":"system","content":…}` (`src/prov/openai.s:684-702`) | `{type:"function", function:{name, description, parameters}}` (`openai.s:794-848`) | `stream_options:{include_usage:true}` (`openai.s:757-767`) |
| `openai-responses` | top-level `instructions`, a **string**; no `role:"system"` item in `input` (`src/prov/openai_responses.s:671-684`) | `{type:"function", name, description, parameters, strict:false}` (`openai_responses.s:776-841`) | `tool_choice:"auto"` + `parallel_tool_calls:true`, but **only when the request has tools** (`:763-769`, `:844-857`), plus `store:false` (`:743-749`) and `max_output_tokens` (`:751-760`) |

Three per-provider differences are deliberate, not accidents:

- **OpenAI Responses gets the prompt in top-level `instructions` (ADR-3).**
  The composed prompt is emitted as a string field and the `input` array does
  not carry a `role:"system"` item (`src/prov/openai_responses.s:671-684`).
  Responses is also the only adapter that sends `tool_choice:"auto"` and
  `parallel_tool_calls:true`, emitted only when the request actually has tools
  (`ntools > 0`) (`:763-769`, `:844-857`). Its tool objects also carry the
  explicit `"strict":false` (`:828-836`).
- **The output-cap field name is provider-gated (ADR-4).** `ollama` and
  `ollama-cloud` send `max_tokens`; every other provider sends
  `max_completion_tokens` (`src/prov/openai.s:570-597`, emitted at `:772-782`).
  Ollama's OpenAI-compatible layer maps `max_tokens` to `num_predict` and
  ignores `max_completion_tokens`, so an unconditioned field silently drops the
  cap on local models.
- **`platform` comes from `os_platform()` in the platform layer**, declared in
  `src/plat/plat.inc:28` and emitted in the `# Environment` block
  (`src/core/prompt.s:2104-2148`). The Linux definition is **weak**
  (`src/plat/linux/sys.s:107-110`) while the macOS one is **strong**
  (`src/plat/mac/rt.s:209-214`): the arm64 build translates and links the Linux
  Layer 0, so on Darwin the weak default lowers to `.weak_definition` and the
  native strong symbol wins at link time. This mirrors the existing
  `config_session_dir` pattern, and a plain second definition would be a
  duplicate symbol — do not add one.

### 7.3 Prompt composition and non-goals

`prompt_build` composes the system prompt from the content categories in the
table above: identity and operating behaviour, an explicit `# Rules` block, the
environment facts, and the per-tool descriptions and schemas. The block order,
the tools list and the resource search paths are what the implementation
defines, and the text is written in opcode's own voice.

Several choices are deliberate **non-goals**. They are not gaps; do not "fix"
them:

- **No `cache_control`/`ephemeral` markers (ADR-2).** The adapters only parse
  cache usage from responses and have no emitter. Emitting markers would be
  new, unverified wire behaviour, so none is emitted.
- **No parallelism, tool-vs-shell, path-convention, edit-vs-write, retry or
  stop-and-ask guidance prose (ADR-1).** That guidance lives in the tool
  descriptions (§7.4), not in the system prompt.
- **No per-provider prompt *text* fork (ADR-7).** Only placement and the params
  in §7.2 vary.
- **No new prompt files, dependencies or modules.** Tool names and `required`
  sets are fixed, and only the two provider placement/param corrections
  (ADR-3, ADR-4) touch the wire.

The `# Environment` block carries `- date: YYYY-MM-DD` (ADR-12). The date is
**UTC** because the epoch clock is UTC and a local-timezone conversion would
need tz data, a forbidden new dependency. It is derived from the existing
`os_now_ns(0)` realtime clock (`src/plat/plat.inc:32`, implemented once in
`src/plat/linux/sys.s:155`, which the Darwin layer links).

### 7.4 Tool descriptions and schemas

Each built-in tool owns its description and JSON schema in `src/tools/<name>.s`
(the `TL_desc` and `TL_params` fields), and the `# Tools` block is generated
from those same strings (`src/core/prompt.s:1944-1999`). The description is the
single source for what the model is told a tool does.

A description may only state behaviour the implementation actually has (ADR-9).
Each operational claim is checked against the code and is stated only when
confirmed: a wrong operational claim actively misleads the model, which is
worse than a terser description. The `edit` description, for example, states
only the confirmed "exact, unique old text" and BOM/CRLF preservation rather
than an application order; matches are sorted ascending and applied
left-to-right into a result buffer (`src/tools/edit.s:534-581`).

### 7.5 Testing and the platform seam

`prompt_build` consults two test seams, both declared in `src/core/prompt.s`:
`g_prompt_platform` (`:64-68`), which when non-zero supplies the platform
string instead of calling `os_platform()` (`:2114-2116`), and `g_prompt_date`
(`:72-76`), which when non-zero supplies the date string instead of deriving it
from `os_now_ns(0)` (`:2126-2140`). Production leaves both zero, so one golden
fixture serves every target and every day.

Composition is covered by tests:

- `tests/prompt_files_test.s` renders the full prompt for a fixed platform and
  date and byte-compares it with `tests/data/prompt_files_test.expected`
  (`tests/run.sh:189`).
- A companion prompt-composition test asserts that every expected prompt block
  is present and that each deliberate non-goal is absent (the presence /
  absence checks).

The provider request bodies are asserted per provider: `tests/prov_test.s`
covers `anthropic-messages` (`:40`) and `openai-chat` including the
`ollama`/`ollama-cloud` `max_tokens` cap (`:44-45`, `:461-497`), and
`tests/responses_test.s` covers `openai-responses`, asserting `instructions` is
present and no `"role":"system"` item remains (`:41-43`, `:503`).

## 8. Authentication and OAuth

`auth_key(provider)` resolves in this order, first hit wins:

1. `--api-key` flag;
2. stored OAuth credential for the provider (subscription login);
3. stored API key in `auth.jsonc` (`{"<provider>":{"api_key":...}}`);
4. provider environment variable (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`,
   `GEMINI_API_KEY`/`GOOGLE_API_KEY` for `google`, `OLLAMA_API_KEY`, or the
   generic `<UPPER(provider)>_API_KEY`);
5. config `api_keys.<provider>`.

A stored OAuth credential owns the provider: `auth_key` does not consult the
environment or `api_keys` behind it, and an expired/unrefreshable token is an
error (re-run `opcode login`) rather than a silent fallback to an ambient key.
Automatic refresh-grant exchange is a deliberate non-goal for now
(`oauth_access_token` serves a stored token until it is within the 5-minute
skew window). `agent.s` sends `Authorization: Bearer` plus
`anthropic-beta: oauth-2025-04-20` for Anthropic subscription tokens.

`opcode login [provider]` / `opcode logout [provider]` (`src/app/login.s`,
`src/core/oauth.s`) implement authorization code + PKCE S256 with the
provider's fixed loopback redirect port (Anthropic 53692, OpenAI 1455) on both
`::1` and `127.0.0.1` (never a wildcard address), validate `state`, exchange
the code over the normal fetch/TLS path, and store the tokens in
`<config dir>/auth.jsonc` (0600, atomic rewrite). Tokens are served until
expiry; `--no-browser` prints the URL instead of opening it.

`--manual` (alias `--paste`) selects `oauth_login_manual()`: the same PKCE /
state / token machinery without a loopback listener. It prints the authorize
URL, reads one pasted line from stdin (a bare code, `code#state`, a query string
or the full redirect URL) and completes the exchange; it is meant for
remote/headless hosts. On success either flow sets `default_provider` in the
user config (merging, not rewriting other keys) and prints `default provider
set to <p>` — or a note if the config could not be written. `logout` removes the
provider's stored `oauth` credential **and** its stored `api_key` (dropping the
provider object when nothing else remains), printing `removed stored credential
for <p>`.

## 9. Sessions and compaction

### 9.1 Files

`session_new()` writes `$OPCODE_SESSION_DIR`, else config `session_dir`, else
`$XDG_DATA_HOME/opcode/sessions/--<sanitized-cwd>--/` (default
`~/.local/share/...`), file `<unix_ms>_<id8>.jsonl`. One JSON object per line:
header `{"type":"session","schema_version":1,...}`, then `message`,
`model_change`, `custom`, `compaction` entries. Keys are snake_case, tagged
enums, timestamps are Unix milliseconds, `id`/`parent_id` form a linear chain.
Appends are fsynced on message lines. `--continue` opens the newest session for
the cwd. `--resume` with no explicit `--session` opens the pre-TUI session
picker on a TTY (`opcode_pick_tty`, newest first, each row described by the
first user message or summary) and loads the selected session; a non-TTY
`--resume` falls back to the newest session. `--session PATH|ID` opens a specific
one; `--no-session`
disables persistence; `--list-sessions` prints `<id> <timestamp_ms> <path>` for
the cwd's sessions, newest first (`session_list`). On load, a missing
`schema_version` is treated as
version 1; a value greater than the current 1 refuses the load with the
version pair and "written by a newer opcode", and older/equal values load
unchanged. The full schema is documented in `src/core/API.md`.

### 9.2 Compaction

`compact_maybe_run()` (called before every turn while idle) estimates
`tokens = last usage + chars/4` of trailing messages and, when the estimate
exceeds `context_window - g_compact_reserve` (default **16384**), issues a
blocking summarization request on the streaming wire (every adapter sends
`stream:true`; the blocking path parses the SSE response to completion). The
summary replaces the older transcript prefix, keeping the most recent
`COMPACT_KEEP_TOKENS` (default **20000**) tokens of tail, and a `compaction`
custom entry is recorded. Both constants are compile-time defaults
(`g_compact_reserve` in `src/core/compact.s` and `COMPACT_KEEP_TOKENS` in
`src/core/agent.s`).

## 10. Modes, commands and flags

| Mode | Behavior |
|---|---|
| TUI (default) | inline scrollback shell (`--tui-mode inline`) or fullscreen (`--tui-mode fullscreen`); `/quit`, `/new` |
| `-p` / `--print` | run one prompt, stream assistant text to stdout, exit 0/1 |
| `--mode json` | JSONL of the agent events on stdout |
| `--mode rpc` | JSONL commands in / responses + events out; commands `prompt`, `abort`, `quit` |

Subcommands: `opcode login|logout [provider]` (`login` takes `--manual`/
`--paste`), `opcode models [--refresh] [--provider P]`, `opcode fetch URL`,
`opcode update [--check] [--offline]`
(checks `https://api.github.com/repos/abird-ai/opcode/releases/latest`).

The five TLS/HTTP request paths share `src/wire/http_client.s`: fetch,
update, discover, the OAuth token exchange and the agent's blocking
compaction request all drive the same connect/DNS/TLS/send/recv helpers, and
the agent state machine uses the client's non-blocking pieces
(`hc_resolve_host`, `hc_tls_events`, `hc_send_some`, `hc_recv_some`,
`hc_wait_io`). The client is transport-only: request bytes come from the
`http.s` builders, responses stream through the `http_resp_*` parser, and each
caller keeps its own error policy. The OAuth dual-fd accept loop and
the provider SSE adapters stay separate.

Flags accepted by all agent front ends (the parser, usage renderer and
session resolver are shared in `src/app/cli.s`): `--provider`, `--model`,
`--api-key`, `--base-url`, `--system`, `--replay FILE`, `--max-tokens`,
`--offline`, `--refresh-models`, `--continue`, `--resume`, `--session`,
`--session-dir`, `--no-session`, `--template NAME [args...]`, `--approve`,
`--verbose`.
`--verbose` raises the log gate to `LOG_DEBUG` and emits request/response/tool
diagnostics from `agent.s`. The TUI additionally accepts `--headless WxH`,
`--script FILE`, `--tui-mode inline|fullscreen` and `--headless-capture FILE`;
the modes front ends accept `--mode json|rpc`
and `-p`/`--print`. `--version`/`--help`, `--list-sessions` (list the cwd's
sessions newest first, then exit) and `--list-models [FILTER]` (list built-in +
discovered models, then exit; `--refresh-models`/`--offline`/`--provider`/`--base-url`
are honoured) are handled by top-level dispatch.
`opcode fetch` additionally takes `--method`, `--header`,
`--data`, `--record FILE`, `--dump-wire` and `--insecure`; `--record` is
`fetch`-only (the agent front ends take `--replay FILE` only) and both use the
`FWIR1` format documented in
`.agents/docs/platform.md` §2.2.
