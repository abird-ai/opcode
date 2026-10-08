# Platform layer

Opcode talks to the operating system through two link-time contracts. Portable
code (everything outside `src/plat/` and `src/net/`) is compiled against the
headers `src/plat/plat.inc` and `src/net/net.inc` and never knows which
implementation is linked. The reference implementation is `src/plat/linux/` and `src/net/linux/` (vendored
mbedTLS); test binaries link `src/net/mock.s` instead of the real network. A
macOS arm64 backend exists (`src/plat/mac/` + `src/net/mac/`, with the portable
sources and the Linux wrappers translated to AArch64 — see
`.agents/docs/ports.md` §2); it is implemented and cross-validated on Linux but
has not been run on Apple hardware. The Windows x86-64 backend
(`src/plat/win/` + `src/net/win/`) is implemented, linked `-nostdlib` as a
PE32+, and executed under Wine (see `.agents/docs/ports.md` §3); it has not run
on real Windows. Selection is link-time; there is no runtime backend selection.

---

## 1. Layer 0 — kernel surface

All functions return in `rax`; failures are negative Linux `errno` values.
Two-value returns use `rax`/`rdx`. Buffers are caller-owned and nothing here
allocates except `os_map`.

```asm
# bootstrap
os_init(rsp)                             # record argc/argv/envp from the stack
os_exit(code)                            # never returns; calls g_exit_hook if set

# files and mappings
os_open(path, flags, mode)     -> fd | -errno
os_read(fd, buf, len)          -> n | -errno        # -EAGAIN when non-blocking
os_write(fd, buf, len)         -> n | -errno
os_close(fd)                   -> 0 | -errno
os_lseek(fd, off, whence)      -> off | -errno
os_fstat(fd, statbuf)          -> 0 | -errno
os_fcntl(fd, cmd, arg)         -> value | -errno
os_mkdir(path, mode)           -> 0 | -errno
os_unlink(path)                -> 0 | -errno
os_rename(old, new)            -> 0 | -errno
os_fsync(fd)                   -> 0 | -errno
os_fchmod(fd, mode)            -> 0 | -errno        # mode preservation
os_getcwd(buf, len)            -> n | -errno
os_getdents(fd, buf, len)      -> n | -errno        # Linux getdents64 records
os_map(size)                   -> ptr               # dies on failure
os_map_try(size)               -> ptr | 0
os_unmap(ptr, size)            -> 0 | -errno

# processes
os_pipe(fds)                   -> 0 | -errno        # CLOEXEC; non-blocking read end
os_spawn(argv, envp, cwd, fd_in, fd_out, fd_err, ctty) -> pid | -errno
os_wait(pid, nohang)           -> 128+sig | exit<<8 | -1 running | -2 unknown
os_kill(pid, sig)              -> 0 | -errno
os_kill_group(pid, sig)        -> 0 | -errno        # signal the child's group
# os_init ignores SIGPIPE; os_spawn resets it to SIG_DFL in the child and puts
the child in its own process group.

# terminal
os_tty_raw(saved)              -> 0 | -errno        # saves termios, enables raw mode
os_tty_restore(saved)          -> 0 | -errno
os_tty_size(fd)                -> rax=cols, rdx=rows
os_sig_winch()                 -> 0 | -errno        # SIGWINCH -> byte on a pipe
os_winch_fd()                  -> fd                # non-blocking read end for the loop
os_sig_cleanup()               -> 0 | -errno        # restore tty on fatal signals, re-raise

# sockets used by the OAuth loopback server
os_socket(domain, type, proto) -> fd | -errno
os_bind(fd, addr, addrlen)     -> 0 | -errno
os_listen(fd, backlog)         -> 0 | -errno
os_accept(fd, addr, addrlen*)  -> fd | -errno
os_getsockname(fd, addr, len*) -> 0 | -errno
os_setsockopt(fd, level, optname, val_ptr, val_len) -> 0 | -errno
os_socket_close(fd)            -> 0 | -errno

# time, entropy, events
os_now_ns(clock)               -> ns                # 0=realtime, 1=monotonic
os_sleep_ns(ns)
os_random(buf, len)            -> 0 | -errno
os_poll(pollfds, nfds, timeout_ms) -> n | -errno    # pollfd {i32 fd; i16 events; i16 revents}
```

`src/plat/plat.inc` is the shared Layer-0 include: it carries the socket-option
constants (`SOL_SOCKET`, `SO_REUSEADDR`, `IPPROTO_IPV6`, `IPV6_V6ONLY`) and
repeats the core subset of the `os_*` contract as documentation. The full
per-function contract is the list in this section, implemented once per OS; the
shared syscall constants (`O_*`, `POLL*`, `E*`, `AT_FDCWD`, `WNOHANG`, `SIG*`)
live in `opcode.inc` and the Layer-1 constants in `src/net/net.inc`.
`src/plat/linux/fs.s`, `dir.s`, `tty.s`, `proc.s` and `net.s` add the
functions grouped above; the core contract in `plat.inc` covers the subset every
port must implement first.

### 1.1 Linux (`src/plat/linux/`)

Direct syscalls (`SYS num`), no vDSO dependency, static ELF. `openat` is the
primitive. Time comes from `clock_gettime`; `os_poll` uses `poll(2)`. The
entry is `_start`, which calls `os_init(rsp)` and then `opcode_main`
(`src/base/start.s`).

- `proc.s` — `fork` + `execve` (never `vfork`), `pipe2(O_CLOEXEC)`, non-blocking
  read ends, `wait4`, `kill`, `chdir` for the child's cwd.
- `tty.s` — raw termios, `TIOCGWINSZ`, SIGWINCH delivered as one byte on a pipe;
  `os_sig_cleanup` restores the terminal on fatal signals and re-raises.
- `dir.s` — `getdents64` records (name at +19, type at +18).
- `net.s` — the socket syscalls used by the OAuth loopback callback server.

### 1.2 macOS (arm64)

`src/plat/mac/` implements the same `os_*` names, so no portable file changes.
Only the syscall/entry machinery is native AArch64: `mac.inc` (macros and the
native↔translated register/stack contract), `rt.s` (`_main` builds a Linux-shaped
initial stack and jumps to the translated `_start`; the translator runtime
helpers such as `x_rep_movsb`, `x_repe_cmpsb`, `x_udiv128`), and `sys.s`
(`x_syscall`: a 320-entry table of libSystem entry points keyed by Linux syscall
number, plus the flag/struct/errno/termios conversions). `src/net/mac/net.s`
holds the Layer-1 socket stubs. The `src/plat/linux` and `src/net/linux` wrappers
are compiled for arm64 **through the translator** and call this shim; see
`.agents/docs/ports.md` §2.2 for why. `x_syscall` calls libSystem rather than
trapping with `svc` (Darwin's raw syscall numbers are not a stable ABI); see
`.agents/docs/ports.md` §2.3. Unimplemented syscall numbers return `-ENOSYS`.

### 1.3 Windows (x86-64)

`src/plat/win/` implements the same `os_*` names, so no portable file changes.
Only the syscall/entry machinery is native: `win.inc` (Win32 constants and the
fd-table layout), `fd.s` (the descriptor table, UTF-8↔UTF-16 and error
mapping), `sys.s` (`win_syscall`, which maps the Linux x86-64 numbers in
opcode.inc onto Win32), `sock.s` (ws2_32), `proc.s`, `tty.s`, `dir.s` (native
replacements for the three Linux files that are not thin syscall wrappers),
`rt.s` (the PE entry, the Linux-shaped argv/envp vector and HOME/XDG compat)
and `abi.s` (the C↔assembly ABI thunks). The portable sources and the
`src/plat/linux` + `src/net/linux` wrappers are assembled unchanged with
`--defsym WINDOWS=1`; `SYS n` becomes `mov eax, n; call win_syscall`. Layer 1
reuses the Linux socket/DNS sources through the shim and the same vendored
mbedTLS for TLS. See `.agents/docs/ports.md` §3 for the imported DLL surface,
the Wine results and the documented divergences.

---

## 2. Layer 1 — networking

Sockets diverge too much between Winsock and BSD for the syscall trick to pay
off, so this contract is written per OS — except on macOS, where the same Linux
`socket.s`/`dns.s` is reused through the translator and sits on the
`src/net/mac/net.s` socket stubs (below). The canonical signatures and
semantics are in `src/net/net.inc`.

```asm
net_init()                            -> 0 | -errno   # no-op on POSIX
net_socket()                          -> fd | -errno # AF_INET/STREAM/NONBLOCK/CLOEXEC/NODELAY
net_connect(fd, ip, port_be16, deadline_ms) -> 0 | -EINPROGRESS | -errno
net_connect_result(fd)                -> 0 | -errno   # SO_ERROR after POLLOUT
net_send(fd, ptr, len)                -> n | -errno
net_recv(fd, ptr, len)                -> n | 0 (eof) | -errno
net_close(fd)                         -> 0 | -errno
net_shutdown(fd, how)                 -> 0 | -errno

net_dns(host, out_ip4 /*4 bytes*/, deadline_ms) -> 0 | -errno
net_is_ip4(host)                      -> 1 | 0

tls_new(host, port, opts)             -> conn | 0
tls_set_fd(conn, fd)                  -> 0           # caller owns the socket
tls_handshake(conn)                   -> 0 | -EAGAIN | -errno
tls_read(conn, ptr, len)              -> n | 0 (eof) | -EAGAIN | -errno
tls_write(conn, ptr, len)             -> n | -EAGAIN | -errno
tls_close(conn)                       # never closes the fd
tls_pending(conn)                     -> bytes buffered
tls_want(conn)                        -> 0 | 1 (wait read) | 2 (wait write)
tls_last_error(conn)                  -> cstr | 0    # verification failure text
tls_fd(conn)                          -> the underlying socket fd
```

`opts` bits: `TLS_VERIFY` (the default) and `TLS_INSECURE` (explicit opt-out on
`opcode fetch --insecure`; the agent front ends never disable verification).
`ip`/`out_ip4` use the memory-byte convention: the 32-bit word
whose memory bytes are the address in network order (`127.0.0.1` is
`0x0100007F`).

**Integration rule:** all sockets are non-blocking. `-EAGAIN` is never an error,
and `net_connect` returning `-EINPROGRESS` means "poll for `POLLOUT`, then read
`SO_ERROR`". The TLS handshake is a resumable state machine: the loop calls
`tls_handshake` when the fd is readable or writable and continues on `-EAGAIN`.

### 2.1 Linux (`src/net/linux/`)

- **Sockets:** raw `socket/connect/send/recv/setsockopt/shutdown/close`
  syscalls. `TCP_NODELAY=1` immediately after creation; `MSG_NOSIGNAL` on send.
- **DNS** (`dns.s`): `/etc/hosts` first (case-insensitive name list, first
  IPv4), then up to three `nameserver` entries from `/etc/resolv.conf`,
  falling back to `1.1.1.1` and `8.8.8.8`. A hand-built A query (RD, QTYPE A,
  QCLASS IN) goes over a non-blocking UDP socket; the response walk checks id,
  QR, TC and RCODE, skips the question and any CNAMEs, and returns the first A
  record. Per-server poll budget is 1 s, bounded by the caller's deadline.
- **TLS:** mbedTLS 3.6.2 compiled into the binary as C with
  `-ffreestanding -nostdlib` (`third_party/mbedtls/`,
  `third_party/mbedtls_opcode_config.h`, `third_party/mbedtls_glue.c`) and
  wrapped by `src/net/linux/tls_shim.c`; the CA bundle is embedded from
  `third_party/cacert.pem`. `dlopen` is impossible in a `-nostdlib` static
  process, so this is the only Linux TLS backend. It uses Opcode's allocator,
  clock and entropy; see §4.

### 2.2 macOS (`src/net/mac/` over translated `src/net/linux/`)

Layer 1 is the same `net_*` contract: `src/net/linux/socket.s` and `dns.s` are
compiled for arm64 by the translator and issue Linux socket syscall numbers,
which `x_syscall` maps onto libSystem. `src/net/mac/net.s` is the socket side of
that map (`sys_socket` … `sys_socketpair`): it converts `sockaddr_in`, `MSG_*`,
`SOL_SOCKET`/`SO_ERROR` and the non-blocking/`CLOEXEC` type flags. DNS
(`/etc/hosts`, `/etc/resolv.conf`) has no OS-specific code and is reused as-is.
TLS is the vendored mbedTLS backend of §3, compiled for arm64, not
SecureTransport. Nothing here has been run on macOS; the static checks and the
Linux cross-link are described in `.agents/docs/ports.md` §2.6.

### 2.3 Mock and replay (`src/net/mock.s`)

Tests link this backend instead of `src/net/linux/`. Replay files start with
`"FWIR1\n"` followed by records:

```
u8  dir       0 = client -> server (captured), 1 = server -> client (replayed)
u32 len       little-endian
bytes payload
```

`net_recv` returns replayed server records in order and then EOF. `net_send`
appends to a capture buffer exposed by `mock_sent() -> ptr, len`. DNS returns
`127.0.0.1` for any name. TLS is a plaintext passthrough, so replay files store
the decrypted HTTP bytes. `--record FILE` captures a real session in this format
and `--replay FILE` feeds it back, which is how wire and agent behavior is tested
deterministically.

---

## 3. Vendored TLS

On Windows TLS is part of the OS (SChannel) and using it is the platform answer.
On macOS the OS answer is SecureTransport, but Opcode instead uses the same
vendored mbedTLS as Linux: `src/net/linux/tls_shim.c` is OS-agnostic, so one TLS
code path serves both POSIX targets and no deprecated framework is linked
(`.agents/docs/ports.md` §2.5).
Linux has no OS TLS library, and a `-nostdlib` static binary cannot `dlopen`
`libssl.so`. Opcode therefore vendors **mbedTLS 3.6.2** (Apache-2.0) as an
unmodified upstream subset under `third_party/mbedtls/`, compiles it in
freestanding mode, and links the CA bundle in.

- The core stays assembly; the TLS backend is the one C component on the path,
  isolated entirely behind the `tls_*` contract. Nothing outside `src/net/`
  refers to mbedTLS.
- Security policy: the upstream tag is pinned and recorded in `THIRD_PARTY.md`;
  upstream advisories are treated as release blockers and the pinned version is
  bumped in a dedicated change. `--insecure` never disables verification
  silently: it must be passed explicitly to `opcode fetch`, and the agent front
  ends do not provide it at all.
- A pure-asm TLS 1.3 client remains a possible future replacement; the `tls_*`
  boundary makes that a link-time swap with no portable code changes.

---

## 4. Entropy, time and randomness

`os_random` is the only entropy source: `getrandom(2)` on Linux,
`getentropy`/`arc4random_buf` on macOS, `BCryptGenRandom` on Windows. Opcode
calls it once at startup and feeds the bytes to the mbedTLS entropy/CTR-DRBG
hooks in `third_party/mbedtls_glue.c`; the same hook file adapts time
(`os_now_ns`) and allocation (`mem_alloc`/`mem_free`) for the freestanding
build.

## 5. Failure policy

- Startup failures (no terminal, no memory) call `die(msg)` and exit 1.
- Network and HTTP failures surface as errors in the tool/assistant UI; they do
  not abort the process. There is no automatic retry layer in this build
  (`src/wire/retry.s` is not part of the tree).
- TLS verification failure is a hard error with the reason from
  `tls_last_error`; it is never silently downgraded.
- A plugin crash crashes the process; plugins run in-process. Isolation is the
  user's container's job, and this is documented in the plugin header.
