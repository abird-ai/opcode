/*
 * Opcode Windows TLS backend entry.
 *
 * The vendored mbedTLS implementation of the tls_* contract
 * (src/net/linux/tls_shim.c) is OS-agnostic: it only calls net_send/net_recv
 * plus the glue's os_now_ns/os_random/mem_alloc hooks.  The Windows build
 * compiles this wrapper (see the Makefile) so Layer 1's Windows sources live
 * under src/net/win, while the body stays a single audited file shared with
 * the POSIX targets.
 *
 * The socket side of Layer 1 is the reused src/net/linux/socket.s and dns.s
 * compiled for Windows; their BSD calls are mapped by win_syscall
 * (src/plat/win/sock.s).  See src/net/win/README.md.
 */
#include "../linux/tls_shim.c"
