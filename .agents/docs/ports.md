# Porting Opcode

The Linux x86-64 build is the reference. This document is the checklist for
linux-aarch64, macOS arm64, Windows x86-64 and riscv64. The linux-aarch64 port
is **implemented and executed under `qemu-aarch64`** — the full suite runs
against the static aarch64 ELF (section 4). The macOS arm64 port is
**implemented and cross-validated on Linux, but has never been run on an Apple
machine**; the linux-aarch64 target does not exercise its Darwin layer
(section 2.9). The Windows x86-64 port is **implemented and executed under Wine**
(section 3) but has never run on a real Windows machine; riscv64 has no sources
yet. The goal remains that when a port lands, nothing portable has to change.

## 1. What a port must provide

Everything outside `src/plat/` and `src/net/` is portable. A port adds one
directory per layer and selects it in the build:

```
src/plat/mac/{mac.inc,rt.s,sys.s}   Layer 0 over libSystem  (entry: _main in rt.s)
src/net/mac/net.s                  Layer 1 socket stubs over libSystem
src/plat/win/{win.inc,rt.s,fd.s,sys.s,sock.s,proc.s,tty.s,dir.s,abi.s}
                                   Layer 0 over Win32; win_syscall + native
                                   process/console/directory layers
src/net/win/tls_shim.c             the shared mbedTLS tls_* backend, compiled
                                   for the Windows C ABI
```

The macOS layer is unusual: only the syscall/entry machinery is native AArch64.
Every portable source **and** the `src/plat/linux` + `src/net/linux` wrappers are
compiled for arm64 by the translator, because those wrappers are pure `SYS n`
shims over the Linux ABI that `x_syscall` reimplements (section 2.2).

The contract is the set of symbols documented in `.agents/docs/platform.md`
(Layer 0) and `src/net/net.inc` (Layer 1):

- Layer 0: bootstrap (`os_init`, `os_exit`), files/mappings, processes
  (`os_pipe`, `os_spawn`, `os_wait`, `os_kill`), terminal (`os_tty_raw`,
  `os_tty_restore`, `os_tty_size`, SIGWINCH pipe), time/entropy/poll, and the
  OAuth socket helpers.
- Layer 1: `net_*` plus the `tls_*` vtable. The `tls_*` semantics (resumable
  handshake, `-EAGAIN`, `tls_want`, `tls_last_error`) are what the agent loop
  and HTTP client rely on.

Layer 0/1 are link-time choices. Tests already prove this by linking
`src/net/mock.s` instead of `src/net/linux`.

## 2. macOS (arm64) — implemented, not yet run

### 2.1 Translation architecture and why

Opcode's assembly is x86-64 GNU-as Intel syntax. Rather than rewrite ~40 portable
modules for AArch64, the port vendors rhun's `tools/arm64.py` (MIT; see
`THIRD_PARTY.md`), which keeps the x86 machine model and emits AAPCS-valid
AArch64 (register map `rax x8, rsp x28, rbp x20, rdi x0, rsi x1, rdx x2, rcx x3,
r8 x4, r9 x5, r10 x6, r11 x7`, `x28` as the x86 stack pointer, flags materialised
where read, `syscall` → `bl x_syscall`). `tools/arm64.py` is a host-side build
tool: it is never compiled into the binary and is not used by the Linux build.

The translator is vendored with its MIT notice and patched for the constructs
opcode uses (the full list is in its file header):

- `.extern` dropped (declaration-only) and `.weak` lowered to Mach-O
  `.weak_definition`/`.weak_reference`;
- a bare GNU-as `NAME = value` lowered to `.set NAME, value`;
- `.equ`/`.set` and data-directive operands emit the value captured at *parse*
  time (the struct-layout macros are otherwise re-evaluated against the final
  constant table);
- label differences (`.equ NAME, end - start`, `NAME = . - start`) folded to
  numbers, with a guard: a folded difference whose span crosses the alignment
  padding the layout pass inserts before an unaligned `.quad` is rejected,
  because the x86 build does not add that padding and the constant would differ
  between the two builds (this is the one known platform divergence);
- `.align`/`.balign` laid out and emitted through one byte-alignment helper;
- `.rept`/`.endr` expanded at parse time;
- `leave` lowered to `mov rsp, rbp` + `pop rbp`.

Coverage: the translation gate covers every portable and generated `src/`
source and every `tests/*.s` (plus `src/net/mock.s`), and `make arm64-translate`
assembles them with the three native Darwin sources and compiles the 62 arm64 C
objects (mbedTLS, the glue, the TLS shim, the plugin). The mac app build
additionally translates the eight `src/plat/linux`+`src/net/linux` wrappers and
links 133 objects. Nothing is linked by the gate.

### 2.2 Layer-0/1 reuse decision

`src/plat/mac/` owns the Darwin knowledge (`rt.s`, `sys.s`, `mac.inc`), and
`src/net/mac/net.s` owns the Layer-1 socket stubs. The existing
`src/plat/linux/*.s` and `src/net/linux/*.s` are compiled for macOS **through the
translator**: they are nothing but `SYS n` wrappers over the Linux ABI, which
`x_syscall` implements on top of libSystem. This is deliberate (rhun's proven
architecture), not an accident: duplicating ~1800 lines of
wrappers that contain no Linux-specific logic once the shim restores Linux
semantics would add zero capability and a large block of code that cannot be
executed before CI runs. Keeping one big, reviewable, statically checkable shim
minimises the untested surface.

### 2.3 The Darwin syscall story

Darwin's raw syscall convention on Apple silicon is: syscall number in `x16`,
arguments in `x0`–`x8`, trap with `svc #0x80`; on error the **carry flag is set**
and `x0` holds a **positive errno**, on success carry is clear and `x0` holds the
result. That interface is deliberately **not** used here. Darwin's raw syscall
numbers are not a stable ABI (they change between releases; `syscall(2)` is
documented as obsolete and callers are told to use the C library), and the
platform contract is libSystem — a Mach-O process always links libSystem anyway,
and no `-nostdlib` static binary is possible on macOS. Opcode therefore calls
libSystem rather than trapping.

`x_syscall` (in `src/plat/mac/sys.s`) takes the **Linux** syscall number in `x8`
(`rax`) and arguments in `x0 x1 x2 x6 x4 x5` (`rdi rsi rdx r10 r8 r9`), looks the
number up in a 320-entry `sys_table` of libSystem entry points, performs the
Darwin↔Linux conversion the call needs (flags, struct layouts, errno, socket
addresses, termios), and returns the result or `-errno` (Linux numbering) in
`x8`. Slots not in the table return `-ENOSYS`. Register preservation matches the
x86 `syscall`: besides `x8`, only `x3` (`rcx`) and `x7` (`r11`) are clobbered;
`x28` (the translated `rsp`) is never touched. Conversions include `open_flags`,
`stat_linux`, `sys_getdents64` (Linux `dirent64` records synthesised from
`readdir`), `sys_ioctl` + `cc_map` (Linux↔Darwin termios), `sys_rt_sigaction`
(Linux handler wrapped in a native trampoline), `sockaddr_in`, `sys_accept4`,
`sys_pipe2`, `sys_fcntl`, `sys_poll`, `sys_clock_gettime`, `sys_wait4`,
`sys_mmap`, and an `errno_map` (Darwin→Linux errno). Network stubs are separate
in `src/net/mac/net.s`; the table references their globals.

### 2.4 File map

| file | lines | role |
|---|---:|---|
| `src/plat/mac/mac.inc` | 110 | macros (`FN`, `ENTER`, `LEAVE`, `XCALL`, `XCALLR`, `XRET`, `ADR`, `GOT`) and Linux errno constants; the native↔translated register/stack contract |
| `src/plat/mac/rt.s` | 204 | `_main` entry (builds a Linux-shaped initial stack and jumps to the translated `_start`), plus the translator runtime helpers (`x_rep_movsb`, `x_rep_movsb_back`, `x_rep_stosb/stosd/stosq`, `x_repe_cmpsb`, `x_repne_scasb`, `x_udiv128`) |
| `src/plat/mac/sys.s` | 822 | `x_syscall`, the 320-entry `sys_table`, `errno_map`, `cc_map`, signal trampoline, struct conversions |
| `src/net/mac/net.s` | 287 | Layer-1 socket stubs (`sys_socket` … `sys_socketpair`) |
| `src/plat/mac/smoke.s` | 177 | Layer-0 smoke program (x86-64 source, translated) — write/exit/monotonic clock/file IO/socketpair |

`sys.s` and `net.s` are adapted from rhun's `src/mac/linux.s`; `rt.s` and
`mac.inc` from rhun's `src/mac/{rt.s,mac.inc}`. Provenance and the exact list of
local modifications are in the file headers and `THIRD_PARTY.md`. `smoke.s` is
original.

### 2.5 TLS on macOS: vendored mbedTLS, not SecureTransport

macOS uses the same vendored freestanding **mbedTLS 3.6.2** backend as Linux
(`third_party/mbedtls/`, `third_party/mbedtls_glue.c`,
`src/net/linux/tls_shim.c`), compiled for arm64. There is no SecureTransport and
no Security.framework: `tls_shim.c` is already OS-agnostic (it only calls
`net_send`/`net_recv` plus the glue's `os_now_ns`/`os_random`/`mem_alloc`), and
the two C files pin their Mach-O symbol names with `__asm__` labels so
the translated callers resolve against the bare names. One TLS code path serves
both POSIX targets, with no deprecated framework and no extra link. `--insecure`
and the verification policy are unchanged from `platform.md` §3.

### 2.6 What is verified where

| level | command | status |
|---|---|---|
| translates | `python3 tools/arm64.py -I src -I build <in.s> <out.s>`; `make arm64-translate` | **yes** — every portable/generated/test source in the gate |
| assembles | `make arm64-translate` (translated + native), `clang -target arm64-apple-macos11 -c …` | **yes** — all translated sources + 3 native AArch64 objects + the arm64 C objects; Mach-O arm64 |
| links (Linux cross, zig) | `make darwin-arm64-cross darwin-arm64-test ARM64_CC=clang ARM64_LD="<zig>/bin/zig cc" ARM64_LDFLAGS="-target aarch64-macos.11.0 -mmacosx-version-min=11.0"`; `nix build path:$PWD#darwin-arm64-cross` | **yes** — the app, the Layer-0 smoke binary and the unit-test binaries link as Mach-O arm64, import only `/usr/lib/libSystem.B.dylib`, and pass `tools/check-macho.sh` (app, smoke, and the `str_test` unit binary). A **smoke check**, not the release artifact |
| runs in CI | `macos-14` job in `ci.yml` (`nix build .#darwin-arm64`, `make darwin-arm64-smoke`, `tests/run.sh`) and in `release.yml` (`make darwin-arm64`, smoke, `tests/run.sh`, publish) | **defined; NOT executed here** — no git remote and no macOS runner in this environment |
| verified on hardware | run `build/opcode-darwin-arm64` on Apple silicon | **not done** |

The translated corpus and the C↔asm ABI boundary now also execute under
`qemu-aarch64` as the linux-aarch64 target (section 4). That is the **Linux**
platform layer, not the Darwin one; what it does and does not establish for this
section is spelled out in section 2.9.

`tools/check-macho.sh` proves statically that a cross-linked file is a Mach-O
arm64 executable with a non-zero `LC_MAIN`, imports only `/usr/lib/libSystem.B.dylib`,
links with undefined-symbol errors fatal, and defines the expected opcode
symbols. It does **not** run the binary, exercise Apple frameworks, or say
anything about code signing or runtime behaviour.

Reproduce each level (Linux host; no macOS machine required):

```sh
# translate + assemble + compile the arm64 C objects
make arm64-translate

# assemble the mac object set; on Linux the link is skipped with a message
make darwin-arm64 darwin-arm64-smoke

# cross-link with zig and validate statically (needs a zig; `nix shell nixpkgs#zig`)
make darwin-arm64-cross darwin-arm64-test ARM64_CC=clang \
    ARM64_LD="/nix/store/…-zig-0.16.0/bin/zig cc" \
    ARM64_LDFLAGS="-target aarch64-macos.11.0 -mmacosx-version-min=11.0"
tools/check-macho.sh build/opcode-darwin-arm64
tools/check-macho.sh --smoke build/smoke-darwin-arm64
tools/check-macho.sh --smoke build/mac/tests/str_test

# the flake wraps the same thing and runs check-macho.sh as its checkPhase
# (`path:` includes the working tree; plain .#darwin-arm64-cross is equivalent
#  once flake.nix is committed)
nix build path:$PWD#darwin-arm64-cross
```

On a macOS host, `make darwin-arm64` links with clang (a Mach-O linker),
`tests/run.sh` builds and runs the Mach-O unit binaries and the integration
suites, and the expected native result is a full-suite pass with no skips (run
`make check` for the current count); nothing else changes. `pkgsCross.aarch64-darwin` is **not** used: it is
unbuildable on x86_64-linux
(`apple-sdk` needs `Csu`, which needs a
darwin-native clang, and the stdenv's `bintools` is darwin-runtime `cctools`;
`allowUnfree` + `allowUnsupportedSystem` are required even to evaluate it). Zig
links libSystem only — no Apple frameworks — which is why the cross build is a
smoke check and the release artifact can only come from macOS.

### 2.7 Known gaps and unimplemented paths

Every unimplemented path returns a negative errno; nothing is a silent no-op.

- `sys_table[15]` (`rt_sigreturn`) is deliberately NULL → `-ENOSYS`. That stub is
  the Linux `sa_restorer` address baked into the translated `tty.s`; Darwin has no
  `sa_restorer` and the native trampoline returns through Darwin's sigtramp, so
  the slot is never reached. It is the one reachable-but-dead entry.
- Any Linux number absent from `sys_table` returns `-ENOSYS`. Opcode never issues
  `17 pread`, `21 access`, `25 mremap`, `83 mkdir`, `84 rmdir`, `87 unlink`,
  `89 readlink`, `91 fchmod`, `112 setsid` (opcode uses `openat`/`mkdirat`/`unlinkat`).
- The termios flag words (`c_iflag`/`c_oflag`/`c_cflag`/`c_lflag`) are translated
  bit-by-bit in both directions, and `c_line`, the `c_cc` array and
  `c_ispeed`/`c_ospeed` are mapped. Only the oflag delay fields and cflag
  `CBAUD`/flow-control are left untranslated; opcode never writes them, and
  `TCSETS` preserves their live Darwin values because it fetches the current
  termios first.
- A `connect` interrupted by a signal returns `-EINTR` on Darwin, not
  `-EINPROGRESS`; non-blocking connect returns `EINPROGRESS` directly in the
  common case.
- Signal numbers are not translated (opcode uses only 1, 2, 3, 6, 11, 15, 28,
  which coincide on Darwin).
- `setsockopt`/`getsockopt` translate only `SOL_SOCKET`/`SO_ERROR`; opcode's only
  options are `TCP_NODELAY` (identical) and `SO_ERROR`.
- `rt_sigaction` does not fill a non-NULL `oact` (no caller queries it).
- `_fork` is used from a libSystem process; safe while opcode is single-threaded
  and the child allocates nothing before `execve`. If opcode ever gains threads,
  `os_spawn` must move to `posix_spawn`.
- No code signing, notarisation, or Apple-framework linking is performed by the
  cross or flake build.
- The mbedTLS glue defines libc-named globals (`calloc`, `free`, `memcmp`,
  `strcmp`, …) that collide with libSystem's C symbols. Mach-O's two-level
  namespace means libSystem's own references still bind to libSystem and only
  the image's own references bind to the glue, so this is assessed as safe — but
  it is unproven on hardware (a load-time failure would show before `main`).

### 2.8 Shim defects fixed statically

Two runtime defects in the shim are fixed; neither path has been executed on
macOS.

- **Process exit must call `__exit`.** `sys_exit`/`sys_exit_group` must not call
  `_exit`. On Mach-O the symbol `_exit` is C `exit`, which
  `third_party/mbedtls_glue.c` defines as a wrapper over `os_exit`; libc's
  `_exit` is `__exit`. Calling `_exit` loops
  `os_exit → sys_exit_group → _exit → os_exit …` on the native stack until it
  crashes. Both stubs in `src/plat/mac/sys.s` call `__exit`.
- **Raw mode requires translated termios flags.** The termios `TCGETS`/`TCSETS`
  shim must not copy the four flag words verbatim, because Linux and Darwin use
  different bit positions (Linux `ICANON 0x2`, `ISIG 0x1`, `IXON 0x400`; Darwin
  `ICANON 0x100`, `ISIG 0x80`, `IXON 0x200`). `os_tty_raw` clears the *Linux*
  bits, so copying them verbatim would leave `ICANON`/`ISIG` set on Darwin: raw
  mode would never engage, and the PTY test (`tests/term_state.py`) would fail.
  In `src/plat/mac/sys.s` the four flag words are translated bit-by-bit in both
  directions through `(linux_bit, darwin_bit)` tables, and
  `c_ispeed`/`c_ospeed` are mapped too.

Both checks are static. The first thing the `macos-14` runner will do is the
Layer-0 smoke binary and `tests/term_state.py`, which is where these two paths
are exercised.

The `darwin-arm64` flake package builds only on a macOS host: `buildable`
requires the target's OS to match the builder, so a Linux builder excludes the
macOS targets instead of cross-linking a foreign binary. On `aarch64-darwin`,
`nix build .#darwin-arm64` builds the Mach-O app; the `macos-14` CI job (§6) runs
it and `tests/run.sh`.

### 2.9 What AArch64 execution establishes

The linux-aarch64 port (section 4) **executes** the translated corpus under
`qemu-aarch64`, which sharpens several statements above:

- **Executable, not merely assembled or linked:** the translator's output, the
  object-derived C↔asm ABI boundary (section 4.4), the shim's x86-64-ABI model
  and every non-Darwin-specific source, because the full suite runs the
  `opcode-linux-aarch64` ELF. This is the **Linux** platform layer executing: it
  exercises the shared core plus `src/plat/linux` and `src/net/linux`, **not**
  `src/plat/mac` / `src/net/mac`. The macOS binary itself has still never run.
- **Still requires the `macos-14` runner:** the Darwin platform layer
  (`src/plat/mac/*`, `src/net/mac/*`), the libSystem calls themselves, Mach-O
  loading and runtime behaviour, the exit path (`__exit`) and the raw-mode/
  termios path on Darwin, and code signing. The two-level-namespace assumption
  for the mbedTLS glue's libc-named globals (`calloc`, `free`, `memcmp`, …) is
  still **unproven on hardware**; a load-time failure would show before `main`.
- **`-ffixed-x28` is required on the arm64 C objects:** they compile with
  `-ffixed-x28`, exactly like the Linux aarch64 C objects. The requirement is
  established by *executing* the aarch64 binary:
  `mbedtls_x509_crt_parse_der_internal` reuses `x28` — the translator's x86
  `rsp` — and then calls a translated `memset`, corrupting the ASN.1 cursor
  (section 4.4). The Darwin C tree carries the same flag; the Darwin
  arm64 objects are still only assembled and statically cross-linked here.

Claims are not upgraded beyond their evidence: the Darwin binary is
**assembled**, **statically cross-linked** and **statically validated**
(`tools/check-macho.sh`), while the shared/translated code and the Linux
platform layer are **executed under QEMU**. "Executed under QEMU" is not
"executed natively", and neither one is "executed on Apple hardware".

## 3. Windows (x86-64) — implemented, executed under Wine

`src/plat/win/` + `src/net/win/` exist and the target is **open**: the PE32+
executable builds with the mingw-w64 cross toolchain, links `-nostdlib` with no
MSVCRT, and the whole verification lane runs it under Wine on Linux
(`make test-wine`: the suite subset under Wine, 15 documented divergences — §3.6).
The binary has **never run on real Windows**; §3.7 separates what Wine proves
from what only a Windows machine can.

### 3.1 Architecture: the syscall shim, exactly like macOS/aarch64

The portable corpus is x86-64 already, so no translation is needed. The
`src/plat/linux/*.s` wrappers are assembled unchanged with
`as --defsym WINDOWS=1`: `opcode.inc`'s `SYS` macro lowers `SYS n` to
`mov eax, n; call win_syscall`, and a raw `syscall` token (a few unit tests)
is macro-replaced with the same call. `win_syscall` (in
`src/plat/win/sys.s`) implements the Linux x86-64 convention in/out — number in
`eax`, args in `rdi rsi rdx r10 r8 r9`, result or `-errno` in `rax`, only
`rcx`/`r11` clobbered — and dispatches to handlers that call Win32. It
normalizes the stack to 16 bytes before every Win32 call and preserves the
Linux clobber contract across the dispatcher.

Three Linux files are *not* thin syscall wrappers and get native Windows
replacements instead of being reused:

| Linux file | Windows source | why |
|---|---|---|
| `src/plat/linux/proc.s` | `src/plat/win/proc.s` | Win32 has no fork/execve; `CreateProcessW` builds the child directly |
| `src/plat/linux/tty.s` | `src/plat/win/tty.s` | console modes, not termios; SIGWINCH does not exist |
| `src/plat/linux/dir.s` | `src/plat/win/dir.s` | `FindFirstFileW`/`FindNextFileW`, not `getdents64` |

Everything else is reused through the shim: files/mappings/time/entropy/poll
(`src/plat/linux/sys.s`, `fs.s`, `net.s`) and the whole Layer-1 socket/DNS
stack (`src/net/linux/socket.s`, `dns.s`). File map:

| file | role |
|---|---|
| `src/plat/win/win.inc` | Win32 constants, the fd-table layout, errno additions |
| `src/plat/win/fd.s` | fd table (`fd 0/1/2` = standard handles), UTF-8↔UTF-16, Win32/WSA↔errno |
| `src/plat/win/sys.s` | `win_syscall` + all file/memory/time/poll/misc handlers |
| `src/plat/win/sock.s` | ws2_32 handlers, Linux↔WinSock option/address-family/error translation |
| `src/plat/win/proc.s` | `os_pipe`, `os_spawn`, `os_wait`, `os_kill`, `os_kill_group` |
| `src/plat/win/tty.s` | console raw/restore/size; no SIGWINCH |
| `src/plat/win/dir.s` | `os_getdents` over `FindFirstFileW` |
| `src/plat/win/rt.s` | PE entry (`win_start`), Linux-shaped initial stack, argv/envp, HOME/XDG compat |
| `src/plat/win/abi.s` | MS→internal ABI thunks for the four compiler libcalls |
| `src/net/win/tls_shim.c` | includes the shared mbedTLS `tls_shim.c` for the Windows C build |
| `tests/run-wine.sh` | the Wine execution lane |

`win_start` parses `GetCommandLineW` with `CommandLineToArgvW` and
`GetEnvironmentStringsW`, converts both to UTF-8 arenas and lays out the
Linux-shaped `argc, argv[], NULL, envp[], NULL` vector at the top of a
256 KiB reservation on the **real thread stack** (linked with
`-Wl,--stack,16777216`). Keeping the real stack matters: Windows SEH/TEB
unwinding rejects a heap-allocated stack, and running the whole program on a
`VirtualAlloc` stack crashes inside `__wine_setjmpex`. `win_env_compat`
synthesizes `HOME`/`XDG_DATA_HOME`/
`XDG_CONFIG_HOME` when Windows lacks them: Wine renames the host variables to
`WINE_HOST_*`, and real Windows only has `USERPROFILE` — the portable config
and session code keeps reading the names it always did, with no core changes.

### 3.2 The C ABI

The vendored mbedTLS (and the plugin corpus) is compiled by
`x86_64-w64-mingw32-gcc -ffreestanding -nostdlib`. Windows x64 uses the
Microsoft ABI; opcode's assembly uses its internal SysV-shaped convention, so
the crossing symbols are annotated `__attribute__((sysv_abi))`
(`OPCODE_SYSV`): `os_*`/`mem_*`/`net_send`/`net_recv` externs, the `tls_*`
definitions, and every function pointer in `include/opcode_plugin.h`. A
shadow `string.h`/`stdio.h` under `src/plat/win/include/` declares the string
and formatting functions the same way (the mingw `<stdio.h>` also defines
`snprintf` as an inline CRT wrapper, which would collide). The plugin ABI is
unchanged on Linux/macOS (the attribute is empty).

### 3.3 Win32 API surface

The link imports exactly four DLLs through the mingw-w64 import libraries
(`-lkernel32 -lws2_32 -lbcrypt -lshell32`); no MSVCRT, no Windows SDK, no
`LoadLibrary`. `llvm-objdump -p` on the release PE lists:

- **kernel32.dll** — `AssignProcessToJobObject`, `CloseHandle`,
  `CreateDirectoryW`, `CreateFileW`, `CreateJobObjectW`, `CreatePipe`,
  `CreateProcessW`, `DeleteFileW`, `DuplicateHandle`, `ExitProcess`,
  `FindClose`, `FindFirstFileW`, `FindNextFileW`, `FlushFileBuffers`,
  `FreeEnvironmentStringsW`, `GetCommandLineW`, `GetConsoleMode`,
  `GetConsoleScreenBufferInfo`, `GetCurrentDirectoryW`, `GetCurrentProcess`,
  `GetCurrentProcessId`, `GetEnvironmentStringsW`, `GetEnvironmentVariableW`,
  `GetExitCodeProcess`, `GetFileAttributesW`,
  `GetFileSizeEx`, `GetFileType`, `GetFinalPathNameByHandleW`, `GetLastError`,
  `GetNumberOfConsoleInputEvents`, `GetStdHandle`,
  `GetSystemTimePreciseAsFileTime`, `GetTickCount64`, `LocalFree`,
  `MoveFileExW`, `MultiByteToWideChar`, `PeekNamedPipe`,
  `QueryPerformanceCounter`, `QueryPerformanceFrequency`, `ReadFile`,
  `RemoveDirectoryW`, `SetConsoleMode`, `SetCurrentDirectoryW`,
  `SetEnvironmentVariableW`, `SetFilePointerEx`, `SetHandleInformation`,
  `SetInformationJobObject`, `Sleep`, `TerminateJobObject`, `TerminateProcess`,
  `VirtualAlloc`, `VirtualFree`, `WaitForSingleObject`, `WideCharToMultiByte`,
  `WriteFile`
- **ws2_32.dll** — `WSAStartup`, `WSAGetLastError`, `WSAPoll`, `socket`,
  `connect`, `bind`, `listen`, `accept`, `getsockname`, `getsockopt`,
  `setsockopt`, `ioctlsocket`, `send`, `recv`, `shutdown`, `closesocket`,
  `inet_pton`
- **bcrypt.dll** — `BCryptGenRandom` (the `os_random` source; it returns the
  byte count so the portable `os_random` loop sees a completed `getrandom`)
- **shell32.dll** — `CommandLineToArgvW`

### 3.4 Build and link

```sh
# inside `nix develop` (mingw-w64 binutils + gcc, wine64)
make windows-x86_64            # or: make TARGET=windows-x86_64
# -> build/opcode-windows-x86_64.exe
```

Assembly is `x86_64-w64-mingw32-as --64 -I src -I build -I src/plat/win
--defsym WINDOWS=1`; C is `x86_64-w64-mingw32-gcc -O2 -ffreestanding
-fno-stack-protector -fno-builtin -fno-pic -nostdlib -mno-red-zone
-mno-stack-arg-probe` (the shadow `stdio.h`/`string.h` shadow the CRT ones).
The link is the gcc driver with `-nostdlib -Wl,-e,win_start
-Wl,--subsystem,console -Wl,--stack,16777216` and the four import libraries
above. The build produces a PE32+ `(Windows CUI)` executable; `objdump -p`
shows no `.tls`, no load config and no MSVCRT. `WINDOWS` also suppresses the
ELF-only `.type`/`.size` directives through the `GTYPE`/`GSIZE` macros in
`opcode.inc` (COFF gas rejects `@function`/`@object`).

### 3.5 Layer 1: WinSock, DNS, mbedTLS (not SChannel)

- **Sockets**: the Linux `socket.s` calls reach `win_syscall`; `sock.s` maps
  `SOCK_NONBLOCK`/`SOCK_CLOEXEC` to `ioctlsocket(FIONBIO)`, translates Linux
  `AF_INET6` (10) to WinSock's 23 in `socket`/`bind`/`connect`/`getsockname`,
  maps `SOL_SOCKET` 1→`0xFFFF`, `SO_ERROR` 4→`0x1007`, `SO_REUSEADDR`
  2→`SO_EXCLUSIVEADDRUSE` (so binding a port another process listens on fails
  like Linux), `IPV6_V6ONLY` 26→27, and WSA errors to negative Linux errno.
  Non-blocking `connect` returns `-EINPROGRESS`; `net_connect_result` rewrites
  `SO_ERROR` in place as a Linux errno.
- **DNS**: `src/net/linux/dns.s` is reused unchanged. Under Wine `/etc/hosts`
  resolves first; on real Windows that file is normally absent, so the resolver
  falls through to the hand-built A queries to the public resolvers.
- **TLS**: the OS-agnostic vendored **mbedTLS 3.6.2** is compiled for Windows
  and wrapped exactly as on Linux (`src/net/win/tls_shim.c` includes
  `src/net/linux/tls_shim.c`; the glue's time/entropy/allocation hooks call the
  platform layer). SChannel is deliberately not used: a correct streaming client
  would need `AcquireCredentialsHandle`/
  `InitializeSecurityContext`/`EncryptMessage`/`DecryptMessage` struct
  marshalling, chain validation and a resumable handshake in assembly, while
  mbedTLS already implements the `tls_*` state machine and is vendored,
  audited and freestanding in this tree (the same choice macOS makes,
  §2.5). The `tls_*` seam is unchanged, so SChannel remains a link-time swap.

### 3.6 What Wine verifies, and the documented divergences

```sh
make test-wine     # builds the PE + its unit binaries, then tests/run-wine.sh
```

Result on this host (Wine 11.0, x86-64 Linux): **the suite subset under Wine passes**, 15
checks skipped with a reason. The lane runs every unit binary against its
golden output, the three CLI checks, and the integration suites in the same
order as `tests/run.sh` (net, update, agent, compact, session, tui,
term_state, modes, onboarding, mcp, oauth). What passes includes `--version`,
`--help`, `-p` against both the replayed and the live loopback mock provider,
the read/bash tool loop, session write/read/continue, the TUI in headless
script mode, `login`'s IPv4+IPv6 loopback server, the update/check JSON, and
the onboarding/config flows.

The 15 skips are all one of four documented divergences, printed with the
reason by the harness:

1. **cmd.exe CRLF** (`modes-json-expected`, `modes-rpc-expected`,
   `tui-screens`): `/bin/sh` does not exist on Windows, so the platform layer
   maps the bash tool's `sh -lc CMD` to `cmd.exe /d /s /c CMD`; `echo hi`
   then emits `hi\r\n`. The golden files are byte-exact Linux output.
2. **Unix PTY ≠ Win32 console** (the five `term-state/*` cases and the
   interactive `pty-*` onboarding cases): a Python PTY gives Wine a pipe, not
   a console, so `GetConsoleMode` fails and `os_tty_raw` reports `-ENOTTY`,
   exactly like a non-tty on Linux. The headless TUI path (`--headless
   --script`) is fully exercised and passes.
3. **MCP is a Unix process** (`mcp-initialize`, `mcp-tools-list`,
   `mcp-tools-call`, `mcp-call-args`): the tests spawn
   `python3 tests/mock_mcp.py`; Wine's `CreateProcessW` cannot execute an ELF
   binary. On real Windows the MCP command is a real Windows executable, so
   this is a harness limitation, not a platform one.
4. **POSIX file modes** (the trailing `oauth` assertion that `auth.jsonc` is
   `0600`): `os_fchmod` returns `-ENOSYS` on Windows (no POSIX mode bits); the
   caller treats that as a best-effort miss and the file keeps the host mode.

Wine is not Windows: it implements the API surface faithfully for this
program, but it is a compatibility layer, not a hardware/kernel test.

### 3.7 What still needs real Windows

- First-run behaviour against a real console (`os_tty_raw`/`SetConsoleMode`,
  the alternate screen and VT output) — Wine only exercised the headless path.
- **SIGWINCH/resize**: Win32 has no signals. `os_sig_winch` succeeds (no
  handler to install) and `os_winch_fd` returns `-1`, so a resize is not
  delivered; the TUI keeps its startup size. A `ReadConsoleInputW` reader
  thread would fix this and is the plan.
- Fatal-signal cleanup: `os_sig_cleanup` returns `-ENOSYS`; Ctrl+C takes the
  default Win32 action (process exit).
- `os_fchmod`: `-ENOSYS` (no POSIX mode bits). `os_kill`/`os_kill_group` map
  to `TerminateProcess`/`TerminateJobObject` (exit status carries the signal
  number in the `128+sig` slot the portable code expects).
- The `cmd.exe` shell mapping means bash tool commands are cmd syntax, not
  POSIX shell; users with Git Bash/WSL would want a configurable shell.
- Wine cannot probe anonymous Unix pipes (`PeekNamedPipe` returns
  `ERROR_NOT_SUPPORTED` for the pipes it maps to std handles); the port treats
  a blocking std pipe as readable in `os_poll` and reads it with `ReadFile`,
  and a non-blocking one as `-EAGAIN`. The pipes opcode creates itself
  (`CreatePipe`) are probed normally.
- The PE has only been run under Wine; no code signing, no `USERPROFILE`
  smoke test on a real Windows machine, and the `--version`/tool-loop/
  session/TUI subset has not been repeated on Windows proper.

## 4. Linux AArch64 — implemented, executed under QEMU

Opcode's Linux AArch64 port reuses the same x86-64 assembly corpus through
`tools/arm64.py --os linux` and adds a native AArch64 syscall shim. It is fully
**executable** on this host under `qemu-aarch64`, which is what distinguishes it
from the macOS arm64 port (section 2), whose Darwin layer cannot run here.

### 4.1 Build

```sh
make TARGET=linux-aarch64          # equivalent: make linux-aarch64
```

produces `build/opcode-linux-aarch64`, a static, no-libc
`ELF 64-bit LSB executable, ARM aarch64, … statically linked`. The
toolchain comes from the flake devShell:

- `aarch64-unknown-linux-gnu-as`, `aarch64-unknown-linux-gnu-ld`;
- `aarch64-unknown-linux-gnu-gcc` (`pkgsCross.aarch64-multiplatform.stdenv.cc`,
  GCC 16.2.0). The Linux C objects use the cross gcc rather than clang: clang
  `--target=aarch64-unknown-linux-gnu` against the host glibc headers fails the
  data model (`__int64_t` redefinition, glibc `bits/types.h:58`) — S2a §5;
- `qemu-user` (`qemu-aarch64`) for execution.

The link line is `$(A64_LD) $(A64_LDFLAGS) -o build/opcode-linux-aarch64 $(A64_OBJS)`
with `A64_LDFLAGS` =

```
-static -nostdlib --no-dynamic-linker -z noexecstack -e opcode_entry
```

(`Makefile`); `opcode_entry` (`src/plat/linux/aarch64/entry.s`) is the ELF entry
point.

### 4.2 The shim

`src/plat/linux/aarch64/` holds four native AArch64 files; the rest of the
binary is translated x86-64:

| file | role |
|---|---|
| `linux.inc` | the contract header: `FN`/`ADR`/`IMM32` macros, `L_EINVAL`/`L_ENOSYS`, and the register/stack/flag/return convention |
| `entry.s` | `opcode_entry` (section 4.3) |
| `rt.s` | the translator runtime helpers (`x_rep_movsb(_back)`, `x_rep_stosb/d/q`, `x_repe_cmpsb`, `x_repne_scasb`, `x_udiv128`) |
| `sys.s` | `x_syscall`, the x86-64→aarch64 `sys_table`, the slow paths, `x_sig_tramp` |

`x_syscall`'s ABI is the x86-64 one the translated code was written against:
the **x86-64** syscall number in `x8` (`rax`), arguments in `x0 x1 x2 x6 x4 x5`
(`rdi rsi rdx r10 r8 r9`), result or `-errno` (Linux numbering) in `x8`. It
looks the x86-64 number up in a 320-entry `sys_table` and either remaps the
number or runs a slow path. It preserves the x86 clobber contract: besides `x8`
only `x3` (`rcx`) and `x7` (`r11`) may change; `x0–x6`, the `q0–q7`/`q16–q23`
vector registers are saved, and `x28` (the translated `rsp`) is never touched.
A number with no slot returns `-ENOSYS` (`-38`), never 0.

The number translation covers exactly the 43 x86-64 numbers the translated
sources issue: 34 pure remaps and 9 slow paths. The slow paths
reshape arguments:

| x86-64 | aarch64 | transformation |
|---|---|---|
| `poll(7)` | `ppoll(73)` | ms `int` → `timespec` on the shim's scratch area; bit 31 → infinite; sigmask NULL, sigsetsize 8 |
| `rename(82)` | `renameat(38)` | `renameat(AT_FDCWD, old, AT_FDCWD, new)` |
| `dup2(33)` | `dup3(24)` | `dup3(old, new, 0)` |
| `send(44)` | `sendto(206)` | `sendto(fd, buf, len, flags, NULL, 0)` |
| `recv(45)` | `recvfrom(207)` | `recvfrom(fd, buf, len, flags, NULL, NULL)` |
| `fork(57)` | `clone(220)` | `clone(SIGCHLD, 0, NULL, NULL, 0)` (aarch64 has no `fork`) |
| `fstat(5)` | `fstat(80)` | remap + in-place `struct stat` conversion (below) |
| `openat(257)` | `openat(56)` | remap + translate the three divergent `O_*` bits (below) |
| `rt_sigaction(13)` | `rt_sigaction(134)` | trampoline install + per-signal act record (below) |

`sys_fstat` rewrites the asm-generic 128-byte `struct stat` into the x86-64
144-byte layout in the caller's buffer (all loads happen before any store, so
the in-place rewrite is safe): `st_mode` moves 16→24, `st_nlink` 20→16 and is
zero-extended 32→64, `st_uid`/`st_gid` move, `st_rdev` 32→40, `__pad0`/`__unused`
are zeroed; the two fields the translated consumers read, `st_mode` (`ls.s:319`)
and `st_size` (`grep.s:650`), are covered along with the whole struct.

`sys_openat` is the general lesson. asm-generic shares most `O_*` bits with
x86-64 but not all:

| constant | x86-64 | asm-generic (aarch64) | shim action |
|---|---|---|---|
| `O_DIRECT` | `0x4000` | `0x10000` | translate |
| `O_DIRECTORY` | `0x10000` | `0x4000` | translate |
| `O_NOFOLLOW` | `0x20000` | `0x8000` | translate |

`opcode.inc` holds the x86-64 values, so the shim translates these three and
passes the rest through (`O_RDONLY`…`O_APPEND`, `O_NONBLOCK`, `O_NOCTTY`,
`O_CLOEXEC` are identical): S2c §2. The rule this exemplifies is the shim's
whole reason to exist: **the shim presents the x86-64 ABI to the translated code
on every OS, so the syscall numbers *and* every ABI-valued constant (open flags,
`struct stat`, `termios`, errno) are the shim's job, not the portable layer's.**

`sys_rt_sigaction` records the caller's action per signal and installs the
native `x_sig_tramp` instead of the translated handler; the trampoline builds an
x86-shaped frame on `x28`, runs the translated handler and returns into the
kernel's vDSO `rt_sigreturn` (the aarch64 and x86-64 `struct sigaction` layouts
are identical, so the struct itself is never converted). `SA_SIGINFO` is cleared
(the trampoline delivers the plain signum). `SA_RESTORER` is **stripped**:
the aarch64 kernel ignores it, but qemu-user honours it and would route the
handler return through the translated `.Lsig_restorer` stub, whose
`rt_sigreturn` through `x_syscall` moves `sp` off the frame qemu locates by `sp`
— a forced SIGSEGV. The stub stays dead on real hardware too.

### 4.3 The entry stub and the two-stack design

The translated x86 `call` pushes its return address on `x28`, the x86 `rsp`. The
shim's own AAPCS frames use the real `sp`, which on the Linux initial stack is
the *same* memory. The very first `--version` run failed here: a translated
`call os_write` pushed its resume address at `[x28-8]`, the native `x_syscall`
frame (368 bytes below `sp`) overwrote it, and the return read 0. The
fix, exactly mirroring the mac `rt.s:_main`, is that `opcode_entry` gives the x86
model its **own 16 MiB stack** in a fresh `mmap`, with a 16 KiB `PROT_NONE`
guard at the bottom and the argc/argv/envp vector copied to the top; native `sp`
(the shim's frames, the kernel's signal frames) never touches it. That also
fixes signal delivery: the kernel's sigframe lands below the native `sp`, so it
cannot smash the x86 stack. `opcode_entry` also calls `setrlimit(RLIMIT_CORE,
{0,0})` so the agent never drops a core in a user's repository.

### 4.4 The C↔asm ABI boundary

The translated code and the C corpus (vendored mbedTLS, the glue, `tls_shim.c`,
the plugins) meet at a real ABI seam: the x86 model returns in `x8` (`rax`),
AAPCS returns in `x0`. The boundary is derived from the **linked objects**, not
guessed from assembly syntax:

- `C_CALLEES` = symbols defined by the C objects (`nm --defined-only`). A
  **direct** `call` gets a `mov x8, x0` after the `bl` iff its target is in this
  set (866 names); an **indirect** call always gets it.
- `CALLBACKS` = symbols undefined in the C objects and defined by translated
  objects (`nm -u` over the C objects, intersected per file with what the unit
  defines): **13** symbols (11 functions + the two `opcode_cacert*` data symbols).
  A definition in this set gets a `mov x0, x8` before `ret`; a C-referenced
  definition gets a full AAPCS **entry stub** instead — `SYM` is the stub that
  saves `x30`, pushes a resume label on `x28`, calls `SYM.x86`, publishes
  `x8`→`x0` and returns to C, while `SYM.x86` is the body. Transcribed direct
  calls target the body; `.quad SYM`/address-taken targets the stub.

The C corpus is additionally compiled with `-ffixed-x28`: AAPCS lets a C function
*use* `x19`–`x28`, and `mbedtls_x509_crt_parse_der_internal` reused `x28` and
then called a translated `memset`, handing it a garbage `x28` and stranding the
entry stub's resume label inside the C frame. `-ffixed-x28` removes every `x28`
use from the C objects (36 → 0 in `x509_crt.o`) so `x28` is the translated `rsp`
at every C→asm boundary.

**Why derived, not guessed.** The obvious alternatives fail.
A blanket dual bridge (`mov x8, x0` after every call *and* `mov x0, x8` before
every translated `ret`) clobbers `rdi` at every return and drops the suite to
`66 passed, 43 failed`; scoping the ret side but leaving the call-side bridge
unconditional still corrupts ~100 cross-unit translated definitions whose
callers read the result out of `x0` instead of the callee's `x8` — e.g.
`str_eq_cstr` (63 callers) leaves `x0` pointing into a string, so every
`rax != 0` test silently sees a truthy pointer. The corruption is
invisible to passing tests, which is exactly why the mechanism must be derived
from the objects rather than tuned to a green suite.

### 4.5 `-ENOSYS` and the "nothing silently succeeds" rule

Every x86-64 number in `0..319` with no `sys_table` slot returns `-ENOSYS`
(`-38`); `>= 320` returns `-ENOSYS` too. The numbers the translated sources
never issue are deliberately unimplemented: `open(2)` (opcode uses `openat`),
`stat(4)`/`lstat(6)` (`fstat`), `access(21)`, `pipe(22)`, `mkdir(83)`,
`unlink(87)`, `readlink(89)`, `exit(60)` (opcode uses `exit_group`), and
everything else. No stub returns 0 without doing the work.

### 4.6 The emulation matrix

| level | how | status |
|---|---|---|
| translates | `tools/arm64.py --os linux` | **yes** — every portable source plus the `src/plat/linux` + `src/net/linux` wrappers |
| assembles | `make TARGET=linux-aarch64` | **yes** — `aarch64-unknown-linux-gnu-as` over the translated set and the native shim; `aarch64-unknown-linux-gnu-gcc` for the C objects |
| links | the `A64_LD` line in section 4.1 | **yes** — static aarch64 ELF, no dynamic linker, zero undefined symbols |
| executes under QEMU | `qemu-aarch64 build/opcode-linux-aarch64`; `make test-qemu` | **yes** — the whole suite runs under `qemu-aarch64` (qemu-user 11.1.1) |
| executed natively (x86-64) | `./build/opcode`; `./tests/run.sh` | **yes** — unchanged; full suite passes |
| executed on real AArch64 hardware | — | **not done** |

**What QEMU execution proves:** the translated codebase really runs. The full
suite executes the portable core (mem, str, json, http, the agent loop, tui,
render, editor, markdown, tools, plugins), the Linux platform layer, the syscall
shim (including signals, PTY/termios, sockets and the mbedTLS TLS path), because
the suites drive the actual `opcode-linux-aarch64` binary and the aarch64 unit
binaries. A translator or shim defect surfaces as a real guest crash or a failed
assertion.

**What it cannot prove:**

- Darwin syscalls and Mach-O runtime behaviour — a different platform layer
  (`src/plat/mac/*`, `src/net/mac/*`), not exercised by this target (section 2.9).
- real aarch64 hardware behaviour: `qemu-aarch64` is an emulator, not silicon; it
  does not prove timing, real signal delivery, or kernel-version-specific
  behaviour.
- performance of the aarch64 build.
- anything Darwin-specific in `src/plat/mac` / `src/net/mac`.

One harness adjustment is disclosed: `term-state/sigsegv`
filters exactly one stderr line that qemu-user 11.1.1 prints when a guest dies
from SIGSEGV — `qemu: uncaught target signal … - core dumped`. The filter
applies only in emulation mode (`EMULATOR` set) and only to that prefix; every
assertion about the program's own output, its exit status and the terminal state
is unchanged. The line is qemu's, not opcode's; on real hardware the check passes
completely. (`setrlimit(RLIMIT_CORE,0)` in `entry.s` suppresses the core file but
not qemu's message.)

### 4.7 Reproduce each level

Linux host; the flake devShell (`nix develop`) provides the cross toolchain and
`qemu-aarch64`.

```sh
# cross-build (src/plat/linux/aarch64/ is tracked, so `path:$PWD` and
# `.#linux-aarch64` name the same build)
make linux-aarch64                     # or: make TARGET=linux-aarch64
nix build path:$PWD#linux-aarch64      # the package form (equivalently .#linux-aarch64)

# execute the ELF directly under qemu
qemu-aarch64 build/opcode-linux-aarch64 --version
qemu-aarch64 build/opcode-linux-aarch64 --help

# the full suite against the emulated binary (re-execs through `nix develop`
# when qemu-aarch64 and the cross `as` are not already on PATH)
make test-qemu
OPCODE_TARGET=linux-aarch64 EMULATOR=qemu-aarch64 make -j8 test-qemu

# the flake check: cross-build + the sandbox-safe subset under qemu-aarch64
nix build path:$PWD#checks.x86_64-linux.linux-aarch64-qemu
```

### 4.8 Current suite result

Run `make check` for the current native suite count. The linux-aarch64 lane is:

```
$ nix develop --command sh -c 'OPCODE_TARGET=linux-aarch64 EMULATOR=qemu-aarch64 make -j8 test-qemu'
…
TESTS <n> passed, 0 failed
```

under `qemu-aarch64` 11.1.1, from a clean tree (`rm -rf build/a64`), with **0
skipped**. The native x86-64 suite passes the same way. The flake check runs the
sandbox-safe subset (the unit binaries + 3 CLI checks) and prints that the
loopback-dependent integration suites run on the CI/release host instead.

## 5. riscv64 (Linux)

No sources exist; the target stays gated on `src/plat/riscv64` +
`src/net/riscv64` and is skipped by CI. The flake already provides
`pkgsCross.riscv64.binutils`, and `make CROSS=riscv64-unknown-linux-gnu
TARGET=linux-riscv64` is the local equivalent of the CI build, but there is no
translator target for riscv64 and no platform layer.

## 6. CI and the cross-build matrix

`tools/targets.sh` prints the table (its output today, `nix run .#targets` runs
the same script); the same table lives in `lib.opcodeTargets` in `flake.nix`:

```
TARGET             GATE                                                                                                                    ENABLED  ARTIFACT
linux-x86_64       native                                                                                                                  yes      opcode-linux-x86_64
linux-aarch64      tools/arm64.py + src/plat/linux/aarch64 + QEMU CI (cross-build + full suite; Darwin arm64 unverified on its own runner) yes      opcode-linux-aarch64
linux-riscv64      src/plat/riscv64 + src/net/riscv64                                                                                      no       opcode-linux-riscv64
windows-x86_64     src/plat/win + src/net/win + Wine CI (win_syscall PE, unit/CLI/integration subset)                                   yes      opcode-windows-x86_64.exe
darwin-arm64       src/plat/mac + src/net/mac + tools/arm64.py + macos-14 CI job                                                           yes      opcode-darwin-arm64
darwin-x86_64      src/plat/mac/x86_64 + src/net/mac/x86_64                                                                                no       opcode-darwin-x86_64
```

A target is built only when all paths of its gate exist — `linux-aarch64` also
requires the QEMU CI job and the release verification step, `windows-x86_64`
the Wine CI job and release verification step, and `darwin-arm64` the
`macos-14` CI job (`tools/targets.sh` and the flake agree) — and a target is
built only by a host of its own OS, except for the two explicit cross-builds
(`linux-aarch64` and `windows-x86_64`, both from `x86_64-linux`). A closed gate
is skipped with `::notice::<target>: port not implemented` and never fails the
release.

Open gates today: `linux-x86_64` (native), `linux-aarch64` (cross-built on
`x86_64-linux` and executed under `qemu-aarch64` — section 4), `windows-x86_64`
(cross-built on `x86_64-linux` and executed under Wine — section 3; the CI lane
is defined, and the local Wine run is green) and
`darwin-arm64` (sources and the translator are present; its `macos-14` lane is
defined but has not run here). `linux-riscv64` is gated closed on sources that
do not exist. `darwin-x86_64` is **deliberately not implemented** — the port
is AArch64-only; its gate names the `src/plat/mac/x86_64` +
`src/net/mac/x86_64` sources, which do not exist, and `make TARGET=darwin-x86_64`
(and any `darwin-*` other than `darwin-arm64`) fails fast at parse time rather
than emitting a mislabeled ELF.

The linux-aarch64 lane is defined end to end: the flake package
`.#linux-aarch64`; the flake check
`.#checks.x86_64-linux.linux-aarch64-qemu` (cross-build plus the sandbox-safe
subset under `qemu-aarch64`; the full suite runs in CI/release because it needs
loopback); the `linux-aarch64` job in `ci.yml`
(`nix build .#linux-aarch64`, then `nix develop --command sh -c
'OPCODE_TARGET=linux-aarch64 EMULATOR=qemu-aarch64 make -j$NIX_BUILD_CORES
test-qemu'`); and the `Build and verify linux-aarch64 under QEMU` step in
`release.yml` (the same `nix develop --command … test-qemu`) before
`nix build .#release-all`. The gate requires both workflow files, so the target
cannot ship on a cross-build that was never executed.

The macOS CI lane **is defined**: `ci.yml` has a `macos` job (`macos-14`:
`nix build .#darwin-arm64`, `make darwin-arm64-smoke`, `tests/run.sh`), and
`release.yml` has a `darwin-arm64` job (`macos-14`: `make darwin-arm64`,
smoke, `tests/run.sh`, artifact `opcode-darwin-arm64`) that the publish job
consumes. It has **not been executed from this environment** (no git remote, no
macOS runner), so the docs still stop short of claiming the binary runs on
macOS. The macOS suite is expected to run every check with no skips (run `make check`
for the current count).

### Flipping a target on

The gate is the port's definition of done; CI needs no other edit.

- **linux-aarch64**: gate **open** — the port is implemented and ships from an
  `x86_64-linux` job. What it provides:
  1. translated every portable source and the `src/plat/linux` +
     `src/net/linux` wrappers for `aarch64-linux-gnu` (`tools/arm64.py --os
     linux`); translation coverage is the build's job, not this checklist's;
  2. added the native shim under `src/plat/linux/aarch64/` (section 4.2) and the
     ELF entry stub with its own x86 stack (section 4.3);
  3. assembled with `aarch64-unknown-linux-gnu-as` and linked static with
     `-static -nostdlib --no-dynamic-linker -z noexecstack -e opcode_entry`;
  4. added the flake package `.#linux-aarch64`, the flake check
     `.#checks.x86_64-linux.linux-aarch64-qemu`, the `linux-aarch64` job in
     `ci.yml` and the release verification step in `release.yml`;
  5. executed the full suite under `qemu-aarch64` from a clean tree with
     all checks passing and 0 skipped (section 4.8).
  The gate (`tools/targets.sh` and `flake.nix`) opens only when the shim, the
  translator and both the CI job and the release step exist, so a port without
  verification cannot ship.
- **linux-riscv64**: add `src/plat/riscv64/` and `src/net/riscv64/` implementing
  `plat.inc` / `net.inc` (section 5).
- **windows-x86_64**: the port is implemented (section 3); the gate is open.
  What it provides: the `win_syscall` shim with native `proc.s`/`tty.s`/`dir.s`;
  the PE entry/initial-vector/`HOME` compat code; the fd table and Win32 error
  mapping; ws2_32 with Linux↔WinSock translation; the mbedTLS TLS shim;
  the mingw-w64 `-nostdlib` link; the `windows` job in `ci.yml` and the
  verification step in `release.yml` that run `make test-wine` before
  `release-all`; `tests/run-wine.sh` (the suite subset under Wine, 15 documented
  divergences). What remains is the first run on real Windows (section 3.7).
- **darwin-arm64**: sources and translator are present and cross-validated; the
  `macos-14` CI lane is defined (§6). What remains is its first real run on Apple
  hardware. The runner supplies the macOS SDK and system frameworks; no SDK is
  provided by the flake.
- **darwin-x86_64**: deliberately not implemented (the port is AArch64-only).
  The gate is open only because it shares the `src/plat/mac` + `src/net/mac`
  paths; building it would need an x86-64 Mach-O link recipe and a decision
  about the translated code.

Notes for port authors:

- `CROSS=<triple>` overrides `AS`/`LD` with `<triple>-as` / `<triple>-ld`,
  drops the x86-only `--64` assembler flag and `TARGET=<name>` names the
  output `build/opcode-<name>`. The native path is unchanged when both are unset.
- Cross targets set `doCheck = false` (foreign binaries cannot run on the
  build host); the native linux-x86_64 target still runs the full suite in CI,
  and `make test-qemu` is the execution step for the linux-aarch64 target
  (section 4.7).
- `nix build .#default` stays the unstripped debug package; `nix build
  .#release` is the stripped native build.
