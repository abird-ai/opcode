# net: Layer 1 contract. Implemented at link time by exactly one directory:
#
#   src/net/linux/*.s   raw sockets + DNS resolver + vendored freestanding mbedTLS
#                       (dlopen is impossible in a nostdlib static binary, so Linux
#                        TLS is compiled in; see .agents/docs/platform.md)
#   src/net/mac/*.s     BSD sockets + libSystem + SecureTransport (later)
#   src/net/win/*.s     WinSock + DnsQuery + SChannel (later)
#   src/net/mock.s      scripted replay for tests (tests link this one)
#
# Rules:
#   - All functions return in rax; failures are negative linux errno.
#   - Sockets are non-blocking. -EAGAIN is never an error; net_connect returns
#     -EINPROGRESS and the caller polls POLLOUT then calls net_connect_result.
#   - tls_* integrate with the same poll loop: handshake/read/write return -EAGAIN
#     and the caller polls the direction reported by tls_want.
#   - The mock backend provides the same symbol names; tests link it instead of
#     the real one (see the Makefile). mock_open(path) loads a "FWIR1" replay file;
#     mock_sent() -> rax ptr, rdx len exposes what the client wrote.

.equ AF_INET, 2
.equ SOCK_STREAM, 1
.equ IPPROTO_TCP, 6
.equ SOL_SOCKET, 1
.equ SO_ERROR, 4
.equ TCP_NODELAY, 1
.equ SHUT_RD, 0
.equ SHUT_WR, 1
.equ SHUT_RDWR, 2

.equ TLS_VERIFY, 1
.equ TLS_INSECURE, 2

#   net_init()                          -> 0 (no-op on POSIX)
#   net_socket()                        -> fd (AF_INET, STREAM, NONBLOCK, CLOEXEC, NODELAY)
#   net_connect(fd, ip, port_be16, deadline_ms) -> 0 | -EINPROGRESS | -errno
#       ip and net_dns' out_ip4 use the memory-byte convention: the 32-bit word
#       whose little-endian memory bytes are the address in network order
#       (127.0.0.1 -> 0x0100007F, i.e. bytes 7F 00 00 01).
#   net_connect_result(fd)              -> 0 | -errno    (SO_ERROR after writable)
#   net_send(fd, ptr, len)              -> n | -errno
#   net_recv(fd, ptr, len)              -> n | 0 (eof) | -errno
#   net_close(fd)                       -> 0 | -errno
#   net_shutdown(fd, how)               -> 0 | -errno
#   net_dns(host cstr, out_ip4 /*4 bytes*/, deadline_ms) -> 0 | -errno
#   net_is_ip4(cstr)                    -> 1 | 0
#
#   tls_new(host cstr, port u16, opts)  -> conn | 0
#   tls_set_fd(conn, fd)                -> 0     (the caller owns the socket)
#   tls_handshake(conn)                 -> 0 | -EAGAIN | -errno
#   tls_read(conn, ptr, len)            -> n | 0 (eof) | -EAGAIN | -errno
#   tls_write(conn, ptr, len)           -> n | -EAGAIN | -errno
#   tls_close(conn)
#   tls_pending(conn)                   -> bytes buffered
#   tls_want(conn)                      -> 0 | 1 (wait read) | 2 (wait write)
#   tls_last_error(conn)                -> cstr | 0 (verification failure text)
#   tls_fd(conn)                        -> the underlying socket fd
