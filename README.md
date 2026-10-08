# opcode

A minimal, extensible coding agent written in **hand-written x86-64 assembly** —
static, no libc, Linux-first, with a linux-aarch64 port, a macOS arm64 port and a
Windows x86-64 port.

> **For production use, pick [agentc](https://github.com/abird-ai/agentc).**
> `opcode` is a **research project** — the far end of one experiment: a real
> coding agent in hand-written x86-64 assembly, statically linked and libc-free.
> `agentc` is the supported production sibling (freestanding C23, the same
> feature surface, real releases) — use it for anything you actually depend on.

- **~0.2 ms** to launch, **~0.5 MB** resident in the TUI, **~706 KiB** static
  binary — no runtime, no interpreter, no GC, no dynamic linker.
- **One source tree, four live targets** (Linux x86-64/aarch64, macOS arm64,
  Windows x86-64) plus a riscv64 target gated closed until its port lands.
- **Direct syscalls and in-tree networking** — sockets, DNS and TLS are
  implemented in the tree; TLS is vendored freestanding mbedTLS.
- **A real TUI, providers, tools, sessions and a stable C ABI** — the feature
  surface matches `agentc`'s, reimplemented from scratch in assembly.

## Footprint

Measured on one Linux x86-64 machine, `make release` (stripped), the same
method for both. `opcode` and `agentc` are the two implementations of the same
design; the external agents are `agentc`'s published figures, shown for scale.

| agent | language | on-disk (stripped) | cold start | idle TUI RSS |
|---|---|---:|---:|---:|
| **opcode** | hand-written x86-64 assembly | **706 KiB** | **~0.2 ms** | **~0.5 MB** |
| agentc | freestanding C23 | 925 KiB | ~0.2 ms | ~0.6 MB |
| codex 0.161.0 | native (Rust) | 279 MiB | ~9 ms | ~25 MB |
| Claude Code 2.1.293 | single-file binary | 241 MiB | ~9 ms | ~39 MB |
| pi 0.99.2 | Node bundle + Node 24 | 17.5 MiB + runtime | ~249 ms | ~113 MB |

- **Cold start** is `--version` (process start to exit, median of 200 runs).
- **Idle TUI RSS** is `VmHWM` sampled from `/proc/<pid>/status` while the TUI
  sits at its first screen in a pty.
- **on-disk** is the stripped release binary; `opcode` and `agentc` are built
  here, the other three are `agentc`'s README figures (vendor Linux releases).
- The gap is the runtime. `opcode` maps ~0.7 MB of its own text and holds a few
  hundred KB of heap; the others carry a language runtime and an interpreter.

## Build and test

Linux x86-64 is the reference. The toolchain is GNU `as` and `ld`, `clang`
(vendored freestanding TLS, C plugins, and the arm64 cross-assembler/compiler)
and `python3` (generated assets/catalog/plugins).

```sh
make                 # build the debug binary build/opcode
make release         # relink build/opcode stripped
make test            # build the unit-test binaries
make check           # build everything and run the full suite (tests/run.sh)
make clean           # remove build/
nix build            # package with Nix (x86_64-linux, aarch64-linux)
nix develop          # development shell with the same toolchain plus cross binutils
```

`make check` runs the golden unit binaries, the CLI checks and the shell/python
integration suites; a clean tree ends `TESTS <n> passed, 0 failed` (run it for
the current count).

Cross targets (the toolchain must be on `PATH` or reachable through `nix develop`):

| Command | Result |
|---|---|
| `make TARGET=linux-aarch64` | cross-build the static, no-libc AArch64 ELF `build/opcode-linux-aarch64` |
| `make test-qemu` | build the AArch64 unit binaries and run the full suite against the ELF under `qemu-aarch64` (0 skipped) |
| `make arm64-translate` | translate + assemble every source for `arm64-apple-macos11` (the syntax gate; also compiles the arm64 C) |
| `make darwin-arm64` | build the mac object set and link `build/opcode-darwin-arm64` on a host with a Mach-O linker |
| `make darwin-arm64-cross ARM64_LD="…/zig cc"` | Linux cross-link of the app + smoke with zig (smoke check only) |
| `nix build .#darwin-arm64-cross` | cross build + `tools/check-macho.sh` (static Mach-O validation) |
| `make TARGET=windows-x86_64` / `make test-wine` | PE32+ build and the Wine execution lane |

### Releases

Tagged pushes are built by `.github/workflows/release.yml`:

```sh
git tag v0.2.0 && git push origin v0.2.0
```

Each artifact is named `opcode-<os>-<arch>[.exe]`, plus a `SHA256SUMS` file; all
of them are attached to the GitHub release for the tag. Tags containing `-` are
marked prerelease.

## Platforms

| target | builds | CI | driven by hand |
|---|---|---|---|
| Linux x86-64 | yes (reference) | native `make check` | yes |
| Linux aarch64 | yes (cross) | golden suite under `qemu-aarch64` | no (qemu only) |
| macOS arm64 | yes (translated Mach-O) | `macos-14`: build + smoke gate; full suite informational (port not hardware-verified) | no |
| Windows x86-64 | yes (PE32+, `-nostdlib`) | Wine lane (suite subset) | no (Wine only) |
| Linux riscv64 | no — no port sources yet | gated closed | no |
| macOS x86-64 | no — the Darwin work is AArch64-only | — | no |

*Driven by hand* means a person ran a real session on that platform, not that a
suite passed. Linux x86-64 is exercised end to end. Everything else is
cross-built and validated as far as a Linux host allows: Linux aarch64 runs the
whole suite under `qemu-aarch64` but has never run on silicon; macOS arm64
builds, packages and passes the Layer-0 smoke in CI (`macos-14`) but its full
suite is still red and is therefore informational until the Darwin platform
layer is driven on real hardware; Windows builds and runs under Wine but has
never run on real Windows. The riscv64 target has no port sources and is gated
closed.

### Help wanted: real hardware

If you have a Mac, an AArch64 Linux box, or a Windows machine, testing is
genuinely useful — platform differences bite first at resize, unicode width,
Ctrl-C, paste, and the inline bottom region.

- **macOS arm64** — `make && make check`, then a real session (`./build/opcode
  --version`, then a prompt that calls a tool). Mention Apple silicon or Intel.
- **AArch64 Linux** — `make linux-aarch64 test-aarch64`, then run the unit
  binaries directly (`build/a64/tests/*` against `tests/data/*.expected`), since
  `make test-qemu` always goes through the emulator.
- **Windows** — `opcode --version`, `opcode models`, then a prompt that calls a
  tool; most useful from a machine that only has Windows PowerShell 5.1.
- Report the exact command, its full output and `uname -a` in an issue. See
  [`.agents/docs/ports.md`](.agents/docs/ports.md) for the port checklist.

**Toolchain:** GNU `as` + `ld` for the assembly, `clang` for the vendored
freestanding TLS and C plugins, `python3` for generated assets, and Nix for
reproducible packaging. A static no-libc binary cannot `dlopen`, so extensions
link in statically (see [Extensions](#mcp-and-extensions)).

## Quick start

```sh
./build/opcode                            # interactive TUI (inline region by default)
./build/opcode --tui-mode fullscreen      # alternate-screen renderer
./build/opcode -p "explain this project"  # one-shot: run and print the answer
./build/opcode --mode json -p "hi"        # machine-readable JSONL events
./build/opcode --mode rpc                 # JSONL commands in, events out
./build/opcode login [provider] [--manual] # OAuth subscription login; --manual pastes a code
./build/opcode --list-models [filter]     # list known models, then exit
./build/opcode --refresh-models           # force model discovery (ignores the 24 h cache)
./build/opcode models --refresh           # refresh and list available models
./build/opcode --list-sessions            # list this directory's sessions, then exit
./build/opcode --resume                   # pick a session to resume (newest first)
./build/opcode --verbose                  # same TUI, with request/tool diagnostics on stderr
./build/opcode fetch https://example.com/ # minimal HTTP(S) client
./build/opcode update                     # check for a newer release
```

With no provider configured the first run opens provider and model pickers. Built-in
providers: **anthropic** (`claude-*`), **openai** (`gpt-*`), **google**
(`gemini-*`, served through Google's OpenAI-compatible endpoint), **ollama**
(local, no key) and **ollama-cloud**. OpenAI is the default provider. Cloud
providers are authenticated with `opcode login <provider>` or an API key (flag,
environment variable or `auth.jsonc`); Google uses
`GEMINI_API_KEY`/`GOOGLE_API_KEY` or `--api-key`.

## Providers, models and first-run setup

- **Built in:** `anthropic`, `openai`, `google`, `ollama` (local, no key),
  `ollama-cloud`. OpenAI-compatible endpoints are reachable through
  `providers.<id>.base_url`.
- **Discovery:** `opcode models --refresh` probes the configured endpoint (and
  Ollama's `/api/tags`) and writes `<config>/models.jsonc`; credentials live in
  `<config>/auth.jsonc` (0600). Successful probes also record a `fetched`
  timestamp in `<config>/models-cache.jsonc`, reused for 24 h; `--list-models`
  reuses a fresh cache, `--refresh-models` ignores it, and `--offline` disables
  the network probes (a cache miss is never fatal).
- **Auth precedence:** `--api-key` › stored OAuth credential › `auth.jsonc`
  api_key › provider environment variable › config `api_keys`. A stored OAuth
  login owns its provider: an expired token is an error, never a silent fallback
  to an ambient key.
- **OAuth subscription logins:** `opcode login [anthropic|openai]` uses an
  authorization-code + PKCE S256 flow with a loopback-only callback and an
  atomic 0600 token store; `--manual` (alias `--paste`) instead prints the
  authorize URL and reads a pasted code, for remote/headless use. On success the
  provider becomes `default_provider`. `opcode logout [provider]` removes the
  stored OAuth credential and clears the provider's stored api_key.

## MCP and extensions

Four ways in, cheapest first:

- **MCP servers** — stdio JSON-RPC configured in `mcp.jsonc` (config dir and
  trusted project `.opcode/`); server tools are exposed as
  `mcp__<server>__<tool>`. Transport is stdio and only `tools/*` is read; a
  server `isError` maps to a tool error, and shutdown is `SIGTERM` → bounded reap
  → `SIGKILL`.
- **Static C plugins** — the stable C ABI lives in
  [`include/opcode_plugin.h`](include/opcode_plugin.h). Plugins are listed in
  `plugins/manifest.json`; `tools/gen-plugins.py` and the Makefile link them with
  a per-plugin `opcode_plugin_init_<name>` symbol. A plugin can register tools
  (with prompt snippets/guidelines), commands, status keys and event handlers,
  and call back into the host vtable. Loading is **static** — a static, no-libc
  binary cannot `dlopen`.
- **Declarative resources** — context files, skills, prompt templates, named
  themes, and project trust. Plugins can contribute skill/prompt/theme roots
  through `resources_discover`.
- **Machine modes** — `--mode json` (JSONL events) and `--mode rpc` for editors
  and harnesses.

Current host limits (the plugin event bus records handlers but only
`resources_discover` is delivered; `set_status`/`set_title` are inert; no async
tools, custom providers or dynamic loading) are documented in
[`.agents/docs/extensibility.md`](.agents/docs/extensibility.md).

## Interactive use

- Slash commands: `/model [id]`, `/thinking`, `/theme [dark|light|<name>]`,
  `/compact`, `/skill:<name>`, any registered prompt template, plugin extension
  commands, `/clear`, `/new`, `/quit`, `/help`.
- **Pickers:** `/model` with no argument opens a modal, type-to-filter list of
  the current provider's models (context window, reasoning/image flags, and
  `(current)`); `/thinking` with no argument opens the filtered
  `off|low|medium|high` list. Up/Down move, Enter selects, Esc cancels.
  `--resume` opens the same picker over this directory's sessions, newest
  first, before the TUI starts; `--continue` stays a shorthand for the newest
  session.
- **TUI modes:** `inline` (default) owns a fixed region at the bottom and keeps
  finished transcript blocks in the terminal's own scrollback; `scrollback` is
  the append-only renderer; `fullscreen` uses the alternate screen; `--tui-mode
  auto` resolves to inline. A live queue strip shows messages submitted during a
  run, and `Esc` returns them to the editor.
- **Editor:** readline keymap, kill/yank/transpose, a disk-backed history,
  bracketed-paste collapse, and `@file` Tab completion. Markdown is rendered
  incrementally; tool calls render as cards with a spinner, elapsed time, diff
  colouring and `Ctrl+O` expand.
- **Themes:** built-in `dark`/`light`, `system` from `$COLORFGBG`, and named
  `themes/<name>.jsonc`; colour is downgraded 24-bit → 256 → 16 automatically.

## Configuration

All files are JSONC (comments and trailing commas; unknown keys are ignored):

- **User config** — `$XDG_CONFIG_HOME/opcode/config.jsonc` (default
  `~/.config/opcode/config.jsonc`).
- **Project config** — `<cwd>/.opcode/config.jsonc`, loaded only when the
  directory is trusted: `--approve`, an interactive `trust this directory?
  [y/N]` prompt in a TTY TUI (saved to `trust.jsonc`), or an existing
  `trust.jsonc` entry.
- **Keys read by this build:** `default_provider`, `default_model`,
  `session_dir`, `theme`, `default_thinking`, `providers.<id>.base_url`,
  `api_keys.<id>`.
- **Sessions** — `$OPCODE_SESSION_DIR`, else config `session_dir`, else
  `$XDG_DATA_HOME/opcode/sessions/--<sanitized-cwd>--/`; one JSONL entry per
  line, `--continue`/`--resume`/`--session`/`--session-dir`/`--no-session`.
- **Context files** — `AGENTS.override.md`, `AGENTS.md`, `OPCODE.md`,
  `CLAUDE.md` from the config dir and every cwd ancestor; `SYSTEM.md` replaces
  the system-prompt preamble and `APPEND_SYSTEM.md` appends to it (project
  variants apply only when trusted).
- **Skills** — `<config>/skills/**/SKILL.md` and
  `<cwd>/.opcode/skills/**/SKILL.md`.
- **Prompt templates** — `<config>/prompts/*.md` and
  `<cwd>/.opcode/prompts/*.md`, expanded with `$1..$9` / `${N:-default}` / `$@`;
  select with `--template NAME [args...]`.

## Architecture

| Layer | Contents |
|---|---|
| `base/` | allocator, SB/VEC, strings, JSONC parser, log, poll/watch event loop |
| `plat/` | Layer 0 kernel surface: files, processes, PTY/TTY, time, poll, RNG (`plat.inc`) |
| `net/` | Layer 1 networking: sockets, DNS, TLS vtable (`net.inc`) |
| `wire/` | HTTP/1.1, SSE, JSON DOM/writer, URL |
| `core/` | agent loop, transcript/messages, prompt, compaction, session JSONL, config, auth, catalog |
| `prov/` | Anthropic Messages and OpenAI Chat/Responses adapters |
| `tools/` | built-in tools: `read`, `bash`, `edit`, `write`, `ls`, `find`, `grep` |
| `tui/` | terminal, cell-grid renderer, editor, input, markdown, cards, status, themes |
| `ext/` | static plugins (C ABI), MCP client |
| `app/` | TUI/print/JSON/RPC modes, subcommands, flags |

Rules between the layers: portable code calls Layer 0/1 and includes `opcode.inc`
plus the shared interface headers it needs (`core/core.inc`, `net/net.inc`,
`wire/url.inc`/`wire/http_client.inc`); `plat/<os>/` and `net/<os>/` never include
core headers; backends are link-time choices (tests link `net/mock.s` for
deterministic replay); every layer returns negative Linux `errno` values in
`rax`; JSON is used only at external boundaries.

## Decisions

- **Language:** hand-written x86-64 assembly (GNU `as`, Intel syntax); the only C
  is the vendored freestanding mbedTLS and freestanding plugin code.
- **Runtime:** none — no libc, no dynamic linker, no GC, no interpreter; direct
  Linux syscalls.
- **TLS:** vendored freestanding mbedTLS 3.6.2 on Linux; the `tls_*` contract keeps
  a future swap link-local.
- **Formats:** JSONC for config/auth/themes, our own JSONL schema for sessions.
- **Auth:** OAuth subscription logins ship in the core feature set.
- **Extensibility:** MCP first, then a versioned, append-only **C ABI**; loading
  is static because a `-nostdlib` static binary cannot `dlopen`.
- **Parallel tool execution** on by default. **MIT** licensed.

## Further documentation

| Document | Contents |
|---|---|
| [`.agents/plans/DESIGN.md`](.agents/plans/DESIGN.md) | goals, requirements, architecture, decisions |
| [`.agents/docs/design-decisions.md`](.agents/docs/design-decisions.md) | the decisions the implementation follows, with code references |
| [`.agents/docs/platform.md`](.agents/docs/platform.md) | Layer 0/1 contracts, ports, DNS, the vendored TLS decision |
| [`.agents/docs/core-agent.md`](.agents/docs/core-agent.md) | agent loop, data model, tools, providers, OAuth, sessions, config |
| [`.agents/docs/extensibility.md`](.agents/docs/extensibility.md) | plugin ABI, events, MCP, skills, RPC |
| [`.agents/docs/tui.md`](.agents/docs/tui.md) | renderer, editor, markdown, cards, status, themes |
| [`.agents/docs/roadmap.md`](.agents/docs/roadmap.md) | per-component status, testing, builds |
| [`.agents/docs/ports.md`](.agents/docs/ports.md) | the linux-aarch64, macOS arm64 and Windows ports, and the riscv64 plan |

## Thanks

Opcode builds upon the designs of two projects.

The [rhun](https://github.com/vshvedov/rhun) project, a hand-written assembly
editor: it showed that a serious, full-featured application can be built in
hand-written assembly, and opcode's allocator, JSON-parser approach and build
style owe a debt to it.

The [pi](https://github.com/earendil-works/pi) project: opcode's UX and
extensibility — context files, skills, prompt templates, MCP, machine modes and
the session model — are inspired by it.

See [THIRD_PARTY.md](THIRD_PARTY.md) for the specific adaptations.

## License

MIT — see [LICENSE](LICENSE). Vendored mbedTLS, the CA bundle and the adapted
base files are documented in [THIRD_PARTY.md](THIRD_PARTY.md).
