# Opcode — guide for coding agents

Opcode is a static, no-libc coding agent written in hand-written x86-64 assembly
(GNU `as`, Intel syntax) targeting Linux first. The core is assembly; the only C
linked in is vendored freestanding mbedTLS and freestanding plugin code.

## Build and test

| Command | Result |
|---|---|
| `make` | build debug `build/opcode` |
| `make release` | relink `build/opcode` stripped |
| `make test` | build the unit-test binaries |
| `make check` | build everything and run `tests/run.sh` |
| `make clean` | remove `build/` |
| `nix build` / `nix develop` | package / dev shell (x86_64-linux, aarch64-linux) |

Toolchain: GNU `as` and `ld`, `clang`, `python3`. `make check` must end with
`TESTS <n> passed, 0 failed` (run it to see the current suite size; do not
hardcode `<n>` in docs).

## Layer boundaries

Lowest to highest: `src/base` (allocator/SB/VEC, strings, JSONC, log, poll
loop), `src/plat` (Layer 0 kernel surface, per OS), `src/net` (Layer 1
sockets/DNS/TLS, per OS), `src/wire` (HTTP/SSE/JSON writer/URL), `src/core`
(agent, messages, prompt, tools, session, config, auth, compaction, diff),
`src/prov` (provider adapters), `src/tools` (built-ins), `src/tui`, `src/ext`
(MCP, static plugin host/loader), `src/app` (modes, flags).

1. Portable layers call Layer 0/1 only and include `opcode.inc` plus the shared
   interface headers they need: `core/core.inc` (core ABI), `net/net.inc`
   (Layer 1) and `wire/url.inc`/`wire/http_client.inc` (transport).
2. `src/plat/<os>/` and `src/net/<os>/` must not include core headers.
3. Backends are link-time choices; tests link `src/net/mock.s`.
4. Errors are negative Linux `errno` values in `rax` everywhere.

## ABI rules

- Args in `rdi, rsi, rdx, rcx, r8, r9`; second return in `rdx`; callee-saved are
  `rbx, rbp, r12-r15`.
- Use `PROLOGUE frame` / `EPILOGUE`; `frame` must be a multiple of 16 and `rsp`
  must stay 16-byte aligned at every `call`. Functions start with `FN name`.
- Struct layouts live in `.inc` files via the `STRUCT`/`F`/`ENDSTRUCT` macros.
- JSON only at external boundaries (wire, sessions, RPC, plugins); typed
  structs internally. No hidden allocations in hot paths.

## Golden-test workflow

- `tests/*.s` are standalone programs linked against the core objects; stdout
  is compared byte-for-byte with `tests/data/<name>.expected`.
- `tests/run.sh` runs those, the CLI checks, and the shell/python integration
  suites. Update the matching `.expected` file with any output change.
- Wire behavior uses `FWIR1` replays (`--record`/`--replay`, `tests/data/*.wire`).
- TUI checks run headlessly: `./build/opcode --headless WxH --script
  tests/scripts/tui.rsc` (verbs `type`, `key`, `prompt`, `wait`, `resize`,
  `print-screen`, `quit`).

## Design docs

- `.agents/plans/DESIGN.md` — goals, architecture, decisions.
- `.agents/docs/` — `design-decisions.md`, `platform.md`, `core-agent.md`,
  `extensibility.md`, `tui.md`, `roadmap.md`, `ports.md`.
- `src/*/API.md` — frozen per-layer API contracts.
