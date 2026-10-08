# opcode

An opcode is a single machine instruction — the atom a processor executes. This
project is the same idea one layer up: a coding agent built from the smallest
possible primitives, following its instructions to the letter.

> **Note** — opcode is a *research* project, not production software. It exists
> to push an extreme idea as far as it can go: a real coding agent in
> hand-written assembly, static and libc-free. If you are looking for production
> code, use **[agentc](https://github.com/abird-ai/agentc)** instead.

A minimal, extensible coding agent written in hand-written x86-64 assembly —
static, no libc, Linux-first, with a linux-aarch64 port (cross-built and
executed under `qemu-aarch64`), a Windows x86-64 port (PE32+, `-nostdlib`,
executed under Wine on Linux, not yet run on real Windows) and a macOS arm64
port (cross-validated on Linux, not yet run on Apple hardware).

## Why

Figures are approximate and measured on the **reference Linux x86-64 build**
(stripped release).

| | |
|---|---|
| startup | **~0.15 ms** per invocation, including fork/exec |
| binary | **~640 KB** static, stripped release (vendored mbedTLS + CA bundle included) |
| runtime | none — no libc, no dynamic linker, no GC, no interpreter |
| I/O | direct Linux syscalls; sockets, DNS and TLS are implemented in-tree |
| TLS | vendored freestanding mbedTLS 3.6.2 (no OpenSSL, no `dlopen`) |
| concurrency | a single poll/watch event loop; no threads on the hot path |

## Install & build

Linux x86-64 is the reference. The toolchain is GNU `as` and `ld`, `clang`
(vendored freestanding TLS, C plugins, and the arm64 cross-assembler/compiler)
and `python3` (generated assets/catalog/plugins).

| Command | Result |
|---|---|
| `make` | build the debug binary `build/opcode` |
| `make release` | relink `build/opcode` stripped |
| `make test` | build the unit-test binaries |
| `make check` | build everything and run the full suite (`tests/run.sh`) |
| `make TARGET=linux-aarch64` | cross-build the static, no-libc AArch64 ELF `build/opcode-linux-aarch64` |
| `make test-qemu` | build the AArch64 unit binaries and run the full suite against the ELF under `qemu-aarch64` (full suite passes, 0 skipped; run `make check` for the current count) |
| `nix build .#linux-aarch64` | package the AArch64 static ELF (cross-built on `x86_64-linux`) |
| `nix build .#checks.x86_64-linux.linux-aarch64-qemu` | flake check: cross-build plus the sandbox-safe subset under `qemu-aarch64` |
| `nix build` | package with Nix for `x86_64-linux` / `aarch64-linux` |
| `nix build .#release` | stripped native release package (`RELEASE=1`) |
| `nix run .#targets` | print the cross-build target table (what CI can build) |
| `nix develop` | development shell with the same toolchain plus cross binutils |

`make test-qemu` verifies linux-aarch64 by cross-building the AArch64 ELF and
executing the whole suite under `qemu-aarch64`; it re-execs through `nix develop`
when the cross toolchain is not already on `PATH`. That execution is the Linux
platform layer, not the Darwin one.

macOS arm64 (implemented; not yet run on Apple hardware — see
[`.agents/docs/ports.md`](.agents/docs/ports.md)):

| Command | Result |
|---|---|
| `make arm64-translate` | translate + assemble every source for `arm64-apple-macos11` (the syntax gate; also compiles the arm64 C) |
| `make darwin-arm64` | build the mac object set and link `build/opcode-darwin-arm64` on a host with a Mach-O linker; on Linux it assembles the 133 objects and skips the link with a message |
| `make darwin-arm64-smoke` | same for the Layer-0 smoke binary `build/smoke-darwin-arm64` |
| `make darwin-arm64-test` | build the unit-test binaries as Mach-O arm64 |
| `make darwin-arm64-cross ARM64_LD="…/zig cc"` | Linux cross-link of the app + smoke with zig (`-target aarch64-macos.11.0`); smoke check only |
| `nix build .#darwin-arm64-cross` | the cross build of the app, smoke and the unit binaries plus `tools/check-macho.sh` (static Mach-O validation) |

## Releases

Tagged pushes are built by `.github/workflows/release.yml`:

```sh
git tag v0.2.0 && git push origin v0.2.0
```

The Linux `build` job verifies `linux-aarch64` under `qemu-aarch64`, then
cross-builds every Linux target whose port layer is present and skips the rest
with a `::notice::`; the `darwin-arm64` job builds `opcode-darwin-arm64` natively
on `macos-14`. Each artifact is named
`opcode-<os>-<arch>[.exe]`, plus a `SHA256SUMS` file; all of them are attached to
the GitHub release for the tag (`gh release upload`). Tags containing `-` (e.g.
`v0.2.0-rc1`) are marked prerelease.

`darwin-arm64` is defined and validated up to the point a Linux host allows:

- **Cross-checked on Linux**: `nix build .#darwin-arm64-cross` links the app, the
  Layer-0 smoke binary and the unit-test binaries as Mach-O arm64 with zig,
  imports only `/usr/lib/libSystem.B.dylib`, and passes `tools/check-macho.sh`.
  This is a smoke check, never the release artifact.
- **macOS CI lane (defined, not executed here)**: `ci.yml` has a `macos` job on
  `macos-14` (`nix build .#darwin-arm64`, `make darwin-arm64-smoke`, then
  `tests/run.sh`), and `release.yml` has a `darwin-arm64` job on `macos-14` that
  builds and tests the binary and publishes it. The native run is expected to
  pass the full suite with no skips (run `make check` for the current count).

Neither workflow has been executed from this environment (there is no git
remote and no macOS runner here), and the binary has not been run on Apple
hardware. `tools/targets.sh` (or `nix run .#targets`) shows which gates are open,
and `nix build .#<target>` builds one locally. See
[`.agents/docs/ports.md`](.agents/docs/ports.md) for how to flip a target on.

## Platform support: what is tested, and where help is wanted

| target | builds | test suite | tested by hand |
|---|---|---|---|
| linux-x86_64 | yes | full suite (`make check`; run it for the current count) | yes |
| linux-aarch64 | yes | the same suite under `qemu-aarch64` (`make test-qemu`, full suite passes), and the full suite inside the Nix sandbox check `nix build .#checks.x86_64-linux.linux-aarch64-qemu` | no (qemu only, never on AArch64 hardware) |
| darwin-arm64 | yes (translated to Mach-O arm64; link checked by `tools/check-macho.sh`) | unit binaries cross-built, never executed; the `macos-14` lane runs `tests/run.sh` but has not run yet | no |
| linux-riscv64 | no — no port sources yet | — | no |
| windows-x86_64 | yes (PE32+, mingw-w64 cross toolchain, `-nostdlib`) | the unit binaries + CLI + integration subset under Wine (`make test-wine`, the suite subset under Wine, 15 documented divergences) | no (Wine only; never on real Windows) |
| darwin-x86_64 | no — not an Opcode port; the Darwin work is AArch64-only | — | no |

*Tested by hand* means a person has run that binary for a real session on that
platform, which is not the same as a suite passing in CI. Linux x86-64 is
exercised end to end. linux-aarch64 passes the whole suite under `qemu-aarch64`
but has never run on silicon. macOS arm64 assembles and cross-links to a valid
Mach-O on Linux (`nix build .#darwin-arm64-cross`, `tools/check-macho.sh`); the
same sources run under `qemu-aarch64` through the linux-aarch64 target, but the
Darwin platform layer itself (`src/plat/mac`, `src/net/mac`) has never run — it
needs a `macos-14` runner or a Mac. Windows x86-64 builds and runs under Wine
(the CI lane is defined; the local lane is green), but it has never run on real
Windows — see [`.agents/docs/ports.md`](.agents/docs/ports.md) §3.7 for what
only a Windows machine can settle. riscv64 has no port sources;
`tools/targets.sh` keeps that target gated closed and it is not built.

If you have a Mac or AArch64 Linux hardware, testing is genuinely useful:

- on macOS arm64, `tests/run.sh` builds the Mach-O app and the arm64 unit
  binaries and runs the full suite natively; the expected result is a full-suite
  pass (run `make check` for the current count). A real session (`./build/opcode --version`, then
  a prompt that calls a tool) is the most useful report — the TUI is where
  platform differences bite first;
- on AArch64 Linux, `make linux-aarch64 test-aarch64` builds the unit binaries;
  run them directly (`build/a64/tests/*` against `tests/data/*.expected`) since
  `make test-qemu` always goes through the emulator;
- report the exact command, its full output and `uname -a` in an issue. See
  [`.agents/docs/ports.md`](.agents/docs/ports.md) for the port checklist and
  what a port must provide.

## Quick start

```sh
./build/opcode                          # interactive TUI (inline scrollback by default)
./build/opcode --tui-mode fullscreen    # full-screen renderer instead
./build/opcode -p "explain this project"   # one-shot: run and print the answer
./build/opcode --mode json -p "hi"      # machine-readable JSONL events
./build/opcode --mode rpc               # JSONL commands in, events out
./build/opcode login anthropic          # OAuth subscription login (login|logout)
./build/opcode models --refresh         # refresh and list available models
./build/opcode fetch https://example.com/  # minimal HTTP(S) client
./build/opcode update                   # check for a newer release
```

With no provider configured the first run shows an onboarding menu. Built-in
providers: **anthropic** (`claude-*`), **openai** (`gpt-*`), **google**
(`gemini-*`, served through Google's OpenAI-compatible endpoint), **ollama**
(local, no key) and **ollama-cloud**. OpenAI is the default provider. Cloud
providers are authenticated with `opcode login <provider>` or an API key (flag,
environment or `auth.jsonc`); Google uses `GEMINI_API_KEY`/`GOOGLE_API_KEY` or
`--api-key`.

## Configuration

All files are JSONC (comments and trailing commas; unknown keys are ignored):

- **User config** — `$XDG_CONFIG_HOME/opcode/config.jsonc` (default
  `~/.config/opcode/config.jsonc`).
- **Project config** — `<cwd>/.opcode/config.jsonc`, loaded only when the
  directory is trusted (`trust.jsonc`, `--approve`).
- **Keys read by this build**: `default_provider`, `default_model`,
  `session_dir`, `theme`, `default_thinking`, `providers.<id>.base_url`,
  `api_keys.<id>`.
- **Discovered models** — `opcode models --refresh` writes
  `<config>/models.jsonc`; credentials live in `<config>/auth.jsonc` (0600).
- **Sessions** — `$OPCODE_SESSION_DIR`, else config `session_dir`, else
  `$XDG_DATA_HOME/opcode/sessions/--<sanitized-cwd>--/`; one JSONL entry per line.
- **Context files** — `AGENTS.override.md`, `AGENTS.md`, `OPCODE.md`,
  `CLAUDE.md` from the config dir and every cwd ancestor; `SYSTEM.md` replaces
  the system prompt preamble and `APPEND_SYSTEM.md` appends to it (project
  variants apply only when trusted).
- **Skills** — `<config>/skills/**/SKILL.md` and
  `<cwd>/.opcode/skills/**/SKILL.md`.
- **Prompt templates** — `<config>/prompts/*.md` and
  `<cwd>/.opcode/prompts/*.md`, expanded with `$1..$9` / `${N:-default}` / `$@`;
  select with `--template NAME [args...]`.

## Extensibility

- **MCP servers** — stdio JSON-RPC configured in `mcp.jsonc` (config dir and
  project `.opcode/`); server tools are exposed as `mcp__<server>__<tool>`.
- **Static C plugins** — the stable C ABI lives in
  [`include/opcode_plugin.h`](include/opcode_plugin.h); plugins are listed in
  `plugins/manifest.json`, and `tools/gen-plugins.py` plus the Makefile link
  them with a per-plugin `opcode_plugin_init_<name>` symbol. A plugin can
  register tools, commands and event handlers and call back into the host
  vtable. Loading is static: the Makefile's plugin symbol rename keeps the
  linked init names unique, and a static no-libc binary cannot `dlopen`. The
  current host limitations and the runtime-loading options are documented in
  [`.agents/docs/extensibility.md`](.agents/docs/extensibility.md).
- **Machine modes** — `--mode json` (JSONL events) and `--mode rpc` (own
  documented command set) for editors and harnesses.

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
| `tui/` | terminal, cell-grid renderer, editor, input, markdown, view |
| `ext/` | static plugins (C ABI), MCP client |
| `app/` | TUI/print/JSON/RPC modes, subcommands, flags |

Rules between the layers:

1. `base/`, `core/`, `prov/`, `tools/`, `wire/`, `tui/`, `ext/` and `app/`
   call Layer 0/1 functions only and include `opcode.inc` plus the shared
   interface headers each layer needs — `core/core.inc` (core ABI),
   `net/net.inc` (Layer 1) and `wire/url.inc`/`wire/http_client.inc`
   (transport).
2. `plat/<os>/` and `net/<os>/` never include core headers.
3. Platform/network backends are selected at link time; the tests link
   `net/mock.s` for deterministic replay instead of the real sockets.
4. Every layer returns negative Linux `errno` values in `rax`; OS adapters
   translate their own error codes.
5. JSON at external boundaries, typed structs inside.

## Status & roadmap

Opcode is implemented on Linux x86-64 (the reference) and has working
linux-aarch64, macOS arm64 and Windows x86-64 ports; see
[`.agents/docs/roadmap.md`](.agents/docs/roadmap.md) for the per-component
state. `make check` runs the full suite on the native build (run it for the
current count; a clean tree ends `0 failed`), and `make test-qemu` runs the
same suite against the cross-built AArch64 ELF under `qemu-aarch64`, with 0
skipped.

Remaining work: runtime plugin loading
([`.agents/docs/extensibility.md`](.agents/docs/extensibility.md) §3.2), a
retry/backoff layer for transient network and HTTP 429/5xx failures, the
linux-riscv64 port, and the first runs on real hardware — linux-aarch64 passes
under `qemu-aarch64` but has not run on silicon, the macOS arm64 port's
`macos-14` CI lane is defined but has not run, and the Windows binary has never
run on real Windows (`.agents/docs/ports.md`).

Further documentation:

| Document | Contents |
|---|---|
| [`.agents/plans/DESIGN.md`](.agents/plans/DESIGN.md) | goals, requirements, architecture, decisions |
| [`.agents/docs/design-decisions.md`](.agents/docs/design-decisions.md) | the decisions the implementation follows, with code references |
| [`.agents/docs/platform.md`](.agents/docs/platform.md) | Layer 0/1 contracts, ports, DNS, the vendored TLS decision |
| [`.agents/docs/core-agent.md`](.agents/docs/core-agent.md) | agent loop, data model, tools, providers, OAuth, sessions, config |
| [`.agents/docs/extensibility.md`](.agents/docs/extensibility.md) | plugin ABI, events, MCP, skills, RPC |
| [`.agents/docs/tui.md`](.agents/docs/tui.md) | renderer, editor, markdown, view buffer |
| [`.agents/docs/roadmap.md`](.agents/docs/roadmap.md) | per-component status, testing, builds |
| [`.agents/docs/ports.md`](.agents/docs/ports.md) | the linux-aarch64 port (shim, ABI boundary, emulation matrix), the macOS arm64 port (translation, syscall shim, verification levels, gaps), and Windows and riscv64 plans |

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
