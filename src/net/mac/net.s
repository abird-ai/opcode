// opcode on macOS: the Layer-1 socket syscall stubs the Darwin sys_table needs.
//
// Adapted from rhun (MIT), src/mac/linux.s; see THIRD_PARTY.md. Sockets live with
// the rest of the network layer (src/net) rather than src/plat/mac, because they
// are network-layer concerns; src/plat/mac/sys.s references these globals through
// its sys_table. Native AArch64, libSystem only, negative Linux errno on failure.
// The shared helpers linux_ret and set_fl are defined in src/plat/mac/sys.s.
.include "mac.inc"

.ifndef L_EAFNOSUPPORT
.equ L_EAFNOSUPPORT, 97
.endif

.text

// msg_flags(w3 Linux flags) -> w3 Darwin flags. opcode sends MSG_NOSIGNAL only;
// the common shared bits are mapped and Linux-only bits are dropped.
msg_flags:
    mov w4, wzr
    tst w3, #0x1
    b.eq 1f
    orr w4, w4, #0x1            // MSG_OOB
1:  tst w3, #0x2
    b.eq 2f
    orr w4, w4, #0x2            // MSG_PEEK
2:  tst w3, #0x4
    b.eq 3f
    orr w4, w4, #0x4            // MSG_DONTROUTE
3:  tst w3, #0x40
    b.eq 4f
    orr w4, w4, #0x80           // MSG_DONTWAIT
4:  tst w3, #0x100
    b.eq 5f
    orr w4, w4, #0x40           // MSG_WAITALL
5:  tst w3, #0x4000
    b.eq 6f
    orr w4, w4, #0x80000        // MSG_NOSIGNAL
6:  mov w3, w4
    ret

// sockaddr_in_mac(x1 Linux sockaddr_in, x9 buffer) -> x1 Darwin sockaddr,
// w2 = length. AF_INET and AF_INET6 are converted; another family gives x1 = 0.
sockaddr_in_mac:
    ldrh w10, [x1]
    cmp w10, #2
    b.ne 1f
    ldrh w10, [x1, #2]
    strh w10, [x9, #2]          // sin_port
    ldr w10, [x1, #4]
    str w10, [x9, #4]           // sin_addr
    mov w10, #16
    strb w10, [x9]              // sin_len
    mov w10, #2
    strb w10, [x9, #1]          // sin_family
    str xzr, [x9, #8]           // sin_zero
    mov x1, x9
    mov w2, #16
    ret
1:  cmp w10, #10                // Linux AF_INET6
    b.ne 8f
    ldrh w10, [x1, #2]
    strh w10, [x9, #2]          // sin6_port
    ldr w10, [x1, #4]
    str w10, [x9, #4]           // sin6_flowinfo
    ldr x10, [x1, #8]
    str x10, [x9, #8]           // sin6_addr[0..7]
    ldr x10, [x1, #16]
    str x10, [x9, #16]          // sin6_addr[8..15]
    ldr w10, [x1, #24]
    str w10, [x9, #24]          // sin6_scope_id
    mov w10, #28
    strb w10, [x9]              // sin6_len
    mov w10, #30                // Darwin AF_INET6
    strb w10, [x9, #1]          // sin6_family
    mov x1, x9
    mov w2, #28
    ret
8:  mov x1, #0
    ret

// sock_opt(w1 Linux level, w2 Linux optname) -> w1,w2 Darwin: only the options
// opcode uses are converted (SOL_SOCKET/SO_ERROR and IPPROTO_IPV6/V6ONLY;
// IPPROTO_TCP and TCP_NODELAY have the same numbers on both).
sock_opt:
    cmp w1, #1                  // Linux SOL_SOCKET
    b.ne 1f
    mov w1, #0xffff             // Darwin SOL_SOCKET
    cmp w2, #4                  // Linux SO_ERROR
    b.ne 9f
    mov w2, #0x1007             // Darwin SO_ERROR
    ret
1:  cmp w1, #41                 // IPPROTO_IPV6 is 41 on both
    b.ne 9f
    cmp w2, #26                 // Linux IPV6_V6ONLY
    b.ne 9f
    mov w2, #27                 // Darwin IPV6_V6ONLY
9:  ret

// socket(domain, type | SOCK_NONBLOCK | SOCK_CLOEXEC, proto)
FN sys_socket
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x1, [sp, #16]
    cmp w0, #10                 // Linux AF_INET6 -> Darwin AF_INET6 (30)
    b.ne 1f
    mov w0, #30
1:  and w1, w1, #0xf            // Linux SOCK_NONBLOCK/CLOEXEC are not type bits
    bl _socket
    sxtw x0, w0
    bl linux_ret
    ldr x1, [sp, #16]
    bl set_fl
    ldp x29, x30, [sp], #32
    ret

// connect(fd, sockaddr_in, len): non-blocking keeps returning -EINPROGRESS, as
// Darwin's EINPROGRESS maps to Linux 115.
FN sys_connect
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    sub sp, sp, #32
    str x0, [sp, #16]
    mov x9, sp
    bl sockaddr_in_mac
    cbz x1, 2f
    ldr x0, [sp, #16]
    bl _connect
    sxtw x0, w0
    bl linux_ret
    b 9f
2:  mov x0, #-L_EAFNOSUPPORT
9:  add sp, sp, #32
    ldp x29, x30, [sp], #16
    ret

// send(fd, buf, len, flags): syscall 44 is sendto, so dest_addr/addrlen are ignored
FN sys_send
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl msg_flags
    bl _send
    sxtw x0, w0
    bl linux_ret
    ldp x29, x30, [sp], #16
    ret

// recv(fd, buf, len, flags): syscall 45 is recvfrom, so src_addr/addrlen are ignored
FN sys_recv
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl msg_flags
    bl _recv
    sxtw x0, w0
    bl linux_ret
    ldp x29, x30, [sp], #16
    ret

// shutdown(fd, how): SHUT_RD/WR/RDWR are the same numbers
FN sys_shutdown
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl _shutdown
    sxtw x0, w0
    bl linux_ret
    ldp x29, x30, [sp], #16
    ret

// bind(fd, sockaddr_in, len)
FN sys_bind
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    sub sp, sp, #32
    str x0, [sp, #16]
    mov x9, sp
    bl sockaddr_in_mac
    cbz x1, 2f
    ldr x0, [sp, #16]
    bl _bind
    sxtw x0, w0
    bl linux_ret
    b 9f
2:  mov x0, #-L_EAFNOSUPPORT
9:  add sp, sp, #32
    ldp x29, x30, [sp], #16
    ret

// listen(fd, backlog)
FN sys_listen
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl _listen
    sxtw x0, w0
    bl linux_ret
    ldp x29, x30, [sp], #16
    ret

// getsockname(fd, sockaddr, addrlen*): Darwin writes a Darwin sockaddr_in or
// sockaddr_in6, which is converted back to the Linux layout the caller reads.
// A full 128-byte sockaddr_storage is used: AF_INET6 writes 28 bytes, so a
// 16-byte buffer would clobber the saved fd/pointer slots and the conversion
// would read uninitialised memory.
FN sys_getsockname
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    sub sp, sp, #176
    str x0, [sp, #128]          // fd
    str x1, [sp, #136]          // sockaddr out
    str x2, [sp, #144]          // addrlen out
    mov w9, #128                // Darwin may write a whole sockaddr_storage
    str w9, [sp, #152]
    ldr x0, [sp, #128]
    mov x1, sp                  // buffer at [sp, #0..127]
    add x2, sp, #152
    bl _getsockname
    sxtw x0, w0
    bl linux_ret
    tbnz x0, #63, 9f
    ldrb w10, [sp, #1]          // Darwin sa_family
    cmp w10, #30                // AF_INET6
    b.eq .Lgn6
    ldr w9, [sp, #152]
    cmp w9, #16
    b.lo 9f
    ldr x9, [sp, #136]
    mov w10, #2
    strh w10, [x9]              // sin_family
    ldrh w10, [sp, #2]
    strh w10, [x9, #2]          // sin_port
    ldr w10, [sp, #4]
    str w10, [x9, #4]           // sin_addr
    str xzr, [x9, #8]
    ldr x9, [sp, #144]
    cbz x9, 9f
    mov w10, #16
    str w10, [x9]
    b 9f
.Lgn6:
    ldr w9, [sp, #152]
    cmp w9, #28
    b.lo 9f
    ldr x9, [sp, #136]
    mov w10, #10
    strh w10, [x9]              // sin6_family (Linux AF_INET6)
    ldrh w10, [sp, #2]
    strh w10, [x9, #2]          // sin6_port
    ldr w10, [sp, #4]
    str w10, [x9, #4]           // sin6_flowinfo
    ldr x10, [sp, #8]
    str x10, [x9, #8]           // sin6_addr[0..7]
    ldr x10, [sp, #16]
    str x10, [x9, #16]          // sin6_addr[8..15]
    ldr w10, [sp, #24]
    str w10, [x9, #24]          // sin6_scope_id
    ldr x9, [sp, #144]
    cbz x9, 9f
    mov w10, #28
    str w10, [x9]
9:  add sp, sp, #176
    ldp x29, x30, [sp], #16
    ret

// accept4(fd, 0, 0, flags): accept, then apply SOCK_NONBLOCK/SOCK_CLOEXEC.
// Darwin passes the listener's O_NONBLOCK on, so it is cleared when unasked.
FN sys_accept4
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x3, [sp, #16]
    mov x1, #0
    mov x2, #0
    bl _accept
    sxtw x0, w0
    bl linux_ret
    tbnz x0, #63, 9f
    str x0, [sp, #24]
    ldr x9, [sp, #16]
    tst w9, #0x800
    cset w9, ne
    lsl w9, w9, #2
    sub sp, sp, #16
    str x9, [sp]
    mov w1, #4                  // F_SETFL
    bl _fcntl
    add sp, sp, #16
    ldr x0, [sp, #24]
    ldr x1, [sp, #16]
    and w1, w1, #0x80000        // O_CLOEXEC
    bl set_fl
9:  ldp x29, x30, [sp], #32
    ret

// setsockopt(fd, level, optname, optval, optlen)
FN sys_setsockopt
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl sock_opt
    bl _setsockopt
    sxtw x0, w0
    bl linux_ret
    ldp x29, x30, [sp], #16
    ret

// getsockopt(fd, level, optname, optval, optlen*)
FN sys_getsockopt
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl sock_opt
    bl _getsockopt
    sxtw x0, w0
    bl linux_ret
    ldp x29, x30, [sp], #16
    ret

// socketpair(domain, type | flags, proto, sv[2]): Darwin has no flags on the
// pair, so SOCK_NONBLOCK/SOCK_CLOEXEC are applied to both descriptors after.
FN sys_socketpair
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x1, [sp, #16]
    str x3, [sp, #24]
    and w1, w1, #0xf
    bl _socketpair
    sxtw x0, w0
    bl linux_ret
    tbnz x0, #63, 9f
    ldr x9, [sp, #24]
    ldr x1, [sp, #16]
    mov w10, #0x800
    movk w10, #0x8, lsl #16
    and w1, w1, w10
    cbz w1, 9f
    ldr w0, [x9]
    bl set_fl
    ldr x9, [sp, #24]
    ldr x1, [sp, #16]
    mov w10, #0x800
    movk w10, #0x8, lsl #16
    and w1, w1, w10
    ldr w0, [x9, #4]
    bl set_fl
    mov x0, #0
9:  ldp x29, x30, [sp], #32
    ret
