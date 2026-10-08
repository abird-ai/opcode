# Windows x86-64 Layer 1 (`src/net/win`)

Layer 1 is the `net_*` + `tls_*` contract in `src/net/net.inc`.  The Windows
port reuses the portable Linux protocol sources and centralises the WinSock
knowledge in the Layer-0 shim, exactly like the syscall story in
`.agents/docs/ports.md` §3:

| contract | implementation |
|---|---|
| `net_init`, `net_socket`, `net_connect`, `net_connect_result`, `net_send`, `net_recv`, `net_close`, `net_shutdown`, `net_is_ip4` | `src/net/linux/socket.s`, assembled unchanged with `--defsym WINDOWS=1`; its `SYS` calls reach `win_syscall` and are handled by `src/plat/win/sock.s` (ws2_32: `WSAStartup`, `socket`, `ioctlsocket(FIONBIO)`, `connect`, `WSAPoll`, `send`, `recv`, `shutdown`, `setsockopt`, `getsockopt`, `closesocket`) |
| `net_dns` | `src/net/linux/dns.s` unchanged.  It reads `/etc/hosts` (Wine resolves the host file; real Windows falls through to the public resolvers) and `/etc/resolv.conf`, then sends hand-built UDP A queries through the same WinSock syscalls |
| `tls_*` | the vendored freestanding mbedTLS 3.6.2 (Apache-2.0) shared with Linux; `src/net/win/tls_shim.c` includes the OS-agnostic `src/net/linux/tls_shim.c` and is compiled by the mingw cross compiler with the internal SysV-shaped C ABI (`OPCODE_SYSV`) |

SChannel was evaluated and rejected for this milestone: a correct client
needs `AcquireCredentialsHandle`/`InitializeSecurityContext` streaming, the
`SecBuffer`/`SecBufferDesc` marshalling, certificate-chain validation and
hostname matching, and a resumable handshake mapped onto opcode's
`tls_handshake`/`tls_want`/`tls_last_error` seam — all in hand-written
assembly.  mbedTLS already provides exactly that state machine, is vendored
and audited in this tree, compiles freestanding with no MSVCRT, and its
platform hooks are provided by `third_party/mbedtls_glue.c` on the same
`os_now_ns`/`os_random`/`mem_alloc` primitives the rest of the port uses.
The `tls_*` seam is unchanged, so swapping in SChannel later is a link-time
change.
