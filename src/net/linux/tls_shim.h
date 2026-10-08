/*
 * Opcode Linux TLS backend - C interface to the mbedTLS-based implementation
 * of the tls_* contract from src/net/net.inc.
 *
 * The assembly side calls these as ordinary SysV C functions:
 *   args in rdi, rsi, rdx..., return in rax; failures are negative errno.
 *
 * Ownership and usage:
 *   conn = tls_new(host, port, opts);   // parses CA bundle lazily, no fd yet
 *   tls_set_fd(conn, fd);               // caller-owned socket from net_socket
 *   ... tls_handshake(conn) -> 0 | -EAGAIN | -errno
 *       on -EAGAIN poll the direction from tls_want(conn), then retry
 *   ... tls_read / tls_write
 *   tls_close(conn);                    // frees conn, does NOT close(fd)
 *   net_close(fd);                      // caller closes the socket itself
 *
 * tls_new(host, port, opts):
 *   opts == TLS_VERIFY   (1)  -> certificate chain + hostname required
 *   opts == TLS_INSECURE (2)  -> MBEDTLS_SSL_VERIFY_NONE (no cert checking)
 *
 * opts values mirror the .equ constants in src/net/net.inc; keep in sync.
 */
#ifndef OPCODE_TLS_SHIM_H
#define OPCODE_TLS_SHIM_H

#include <stddef.h>
#include <stdint.h>

/* OPCODE_SYSV marks the internal SysV-shaped ABI the assembly side uses.  The
 * declarations here stay plain so they can be mixed with the definitions in
 * tls_shim.c, which carry the attribute explicitly; see that file. */
#if defined(_WIN32) && (defined(__x86_64__) || defined(_M_X64))
#define OPCODE_SYSV __attribute__((sysv_abi))
#else
#define OPCODE_SYSV
#endif

#ifdef __cplusplus
extern "C" {
#endif

void *tls_new(const char *host, unsigned short port, long opts) OPCODE_SYSV;
int tls_set_fd(void *conn, int fd) OPCODE_SYSV;
int tls_handshake(void *conn) OPCODE_SYSV;
/* int64_t, not long: Windows long is 32-bit and would zero-extend a
 * negative -EAGAIN/-errno out of the assembly 'return in rax' contract. */
int64_t tls_read(void *conn, void *buf, size_t len) OPCODE_SYSV;
int64_t tls_write(void *conn, const void *buf, size_t len) OPCODE_SYSV;
void tls_close(void *conn) OPCODE_SYSV;
size_t tls_pending(void *conn) OPCODE_SYSV;
int64_t tls_want(void *conn) OPCODE_SYSV;
const char *tls_last_error(void *conn) OPCODE_SYSV;
int tls_fd(void *conn) OPCODE_SYSV;

/* Platform hook bundle for the mbedTLS objects; called by tls_new. */
int opcode_platform_setup(void);

#ifdef __cplusplus
}
#endif

#endif /* OPCODE_TLS_SHIM_H */
