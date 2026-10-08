.include "opcode.inc"
# linux x86-64 layer 0: socket syscalls used by the OAuth loopback server.
# Direct syscalls, negative-errno returns, leaf functions. Contract: plat.inc.

.equ SYS_socket,      41
.equ SYS_bind,        49
.equ SYS_listen,      50
.equ SYS_getsockname, 51
.equ SYS_accept4,     288
.equ SYS_setsockopt,  54
.equ SOCK_CLOEXEC,    0x80000

.text

# os_socket(domain, type, proto) -> fd | -errno
FN os_socket
    SYS SYS_socket
    ret

# os_bind(fd, addr, addrlen) -> 0 | -errno
FN os_bind
    SYS SYS_bind
    ret

# os_listen(fd, backlog) -> 0 | -errno
FN os_listen
    SYS SYS_listen
    ret

# os_getsockname(fd, addr, addrlen*) -> 0 | -errno
FN os_getsockname
    SYS SYS_getsockname
    ret

# os_setsockopt(fd, level, optname, val_ptr, val_len) -> 0 | -errno
# Layer 0 for the OAuth loopback server: level/optname are the Linux numbers
# (SOL_SOCKET/SO_REUSEADDR, IPPROTO_IPV6/IPV6_V6ONLY in plat.inc); the Darwin
# and Win32 shims translate the namespace at the syscall boundary.
FN os_setsockopt
    SYS SYS_setsockopt
    ret

# os_accept(fd) -> accepted fd | -errno (accept4 with SOCK_CLOEXEC)
FN os_accept
    xor esi, esi
    xor edx, edx
    mov r10d, SOCK_CLOEXEC
    SYS SYS_accept4
    ret

# os_socket_close(fd) -> 0 | -errno (distinct from os_close for non-POSIX ports)
FN os_socket_close
    SYS SYS_close
    ret
