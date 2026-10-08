# Roadmap, testing and builds

---

## 1. Status

Opcode is implemented and verified as follows. Linux x86-64 is the reference;
the other targets reuse the same portable layers through a platform layer
selected at link time.

| Component | State |
|---|---|
| `base/` | implemented — allocator, `SB`/`VEC`, strings, JSONC, log, poll/watch loop |
| `plat/` Linux x86-64 | reference; the full suite runs in `make check` |
| `plat/` Linux aarch64 | implemented; executed under `qemu-aarch64` (in the flake check) |
| `plat/` macOS arm64 | implemented, translated Mach-O, statically cross-validated on Linux; never run on Apple hardware |
| `plat/` Windows x86-64 | implemented (PE32+, `-nostdlib`); executed under Wine; never run on real Windows |
| `plat/` Linux riscv64 | no sources yet — the target is gated closed |
| `net/`, TLS | implemented — raw sockets, own DNS resolver, freestanding mbedTLS as the TLS backend on every target |
| `wire/` | implemented — URL, HTTP/1.1, SSE, JSON writer, `FWIR1` record/replay |
| `core/` | implemented — agent loop, transcript/messages, prompt builder, tool registry, sessions, config, auth, compaction, diff, catalog |
| `prov/` | implemented — Anthropic Messages, OpenAI Chat/Responses, Ollama, ollama-cloud, Google |
| `tools/` | implemented — `read`, `bash`, `edit`, `write`, `ls`, `find`, `grep` |
| `tui/` | implemented — terminal lifecycle, cell renderer, input parser, editor, view buffer, markdown-lite, inline and fullscreen modes, headless script runner |
| `ext/` | static C plugins implemented (ABI header, host vtable, static loader, example plugin, plugin test); stdio MCP client implemented. Runtime plugin loading is the remaining piece |
| `app/` | implemented — TUI/print/JSON/RPC modes, subcommands, flags |

Remaining work is limited to genuinely unimplemented items: runtime plugin
loading (`.agents/docs/extensibility.md` §3.2), a retry/backoff layer for
transient network and HTTP 429/5xx failures (`src/wire/retry.s` is not in the
tree), and the riscv64 port.

## 2. Testing strategy

### 2.1 Golden unit tests

`tests/*.s` are standalone programs linked against the core objects and the mock
network backend. `tests/run.sh` runs each and compares stdout byte-for-byte
with `tests/data/<name>.expected`. Coverage includes mem/vec/sb, strings, JSON
parse/write, URL, HTTP parsing in split chunks, SSE, diff, markdown, input
parsing, catalog lookup, session JSONL round-trips, tool validation, and plugin
loading. The CLI checks (`--version`, `--help`, unknown option) are part of the
same count.

### 2.2 Wire, integration and TUI suites

- `src/net/mock.s` replays recorded `FWIR1` byte streams; `--record`/`--replay`
  produce and consume the same format.
- Shell/python suites under `tests/` exercise live loopback HTTP/SSE/TLS, the
  agent round-trip, sessions, modes, onboarding, Ollama, MCP, OAuth and `update`
  against local mocks. Python is optional; without it those suites are skipped
  and reported.
- TUI behavior is verified headlessly with
  `./build/opcode --headless WxH --script tests/scripts/tui.rsc` against golden
  screen dumps.

`make check` runs the full suite and reports the current count; a clean tree
ends with `0 failed`. Run it to see the current suite size. A change to a
tested contract must update the matching `.expected` file in the same change.

### 2.3 Future test work

Fuzzing (JSON, SSE, markdown, editor input) and a long-running soak that checks
`g_mem_live` and RSS are not part of the tree yet. Port CI should run the unit
binaries and `tests/run.sh` on the ported runtime.

## 3. Build and release

- `make [release|test|check|clean]` — GNU `as` + `ld` for the assembly, `clang`
  for freestanding mbedTLS and plugins, `python3` for generated files.
- `tools/gen-assets.sh` (version + embedded CA bundle),
  `tools/gen-catalog.py` (model table) and `tools/gen-plugins.py` (static plugin
  table) run as part of the build; their outputs are deterministic.
- `flake.nix` packages `x86_64-linux` and `aarch64-linux` and provides a dev
  shell with the same toolchain.
- The macOS arm64 recipe (`make darwin-arm64`, `make darwin-arm64-cross`), the
  linux-aarch64 recipe (`make linux-aarch64`, `make test-qemu`) and the Windows
  x86-64 recipe (`make windows-x86_64`, `make test-wine`) live in the same
  `Makefile` and are exercised by the flake packages/checks. riscv64 only has
  cross binutils staged and no port sources (see `.agents/docs/ports.md`).
  `opcode update` checks the GitHub release endpoint.

## 4. Performance

Published measurements per release (reference build: stripped release binary
on Linux x86-64):

| Benchmark | Tool |
|---|---|
| startup | `hyperfine 'opcode --version'` |
| RSS idle / after many turns | `/proc/self/status`, `time -v` |
| binary size | `ls -l`, `size -A` |
| first-token latency | mock-server timestamp vs. TUI frame timestamp |
| SSE parse throughput | replay a large `.wire` file |

The design budget the code is built around: arena/parser reset per request,
zero-copy TLS→HTTP→SSE path, no DOM for deltas, tick-driven rendering, one
`writev` per fullscreen frame, and `TCP_NODELAY` on agent sockets.

## 5. Risks

1. **Windows port** — the port is implemented and the Wine lane is green, but
   the binary has never run on real Windows. That first real run is the open
   risk: real-console first-run behaviour, SIGWINCH/resize (Win32 has no
   signals, so `os_winch_fd` returns `-1` and a resize is not delivered),
   fatal-signal cleanup and `cmd.exe` shell semantics are what only a Windows
   machine can settle (`.agents/docs/ports.md` §3.7).
2. **macOS port** — the source dialect is x86-64 assembly; the port needs an
   x86-64→AArch64 translation step or a native AArch64 port. Keep new code
   scalar (no SIMD beyond basic moves) so translation stays tractable.
3. **Scope** — the supported surface is deliberately small; new features must
   keep the layer boundaries and the `tls_*`/`PV_*` contracts intact.
4. **TLS maintenance** — the pinned mbedTLS version needs upstream advisory
   monitoring; the `tls_*` boundary confines any replacement.
5. **Format stability** — session files carry `schema_version` (currently
   1). On load a missing value is read as version 1, a value greater than
   the current schema refuses the load with an actionable error, and values
   older or equal load unchanged, so a future bump has one gate to raise;
   config/auth/models/trust files carry no version field and stay lenient.
