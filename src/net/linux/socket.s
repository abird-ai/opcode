.include "opcode.inc"
# opcode net: linux Layer 1 - raw IPv4 TCP sockets (contract: src/net/net.inc).
#
# Direct x86-64 syscalls, no libc, no allocation. Every entry point returns in
# rax; failures are negative linux errno values. All functions here are leaves
# (syscalls clobber rcx/r11 only), so no PROLOGUE is needed and nothing but
# caller-saved registers is touched.
.include "net/net.inc"

.equ SYS_socket,     41
.equ SYS_connect,    42
.equ SYS_send,       44
.equ SYS_recv,       45
.equ SYS_shutdown,   48
.equ SYS_setsockopt, 54
.equ SYS_getsockopt, 55

.equ SOCK_NONBLOCK, 0x800
.equ SOCK_CLOEXEC,  0x80000
.equ MSG_NOSIGNAL,  0x4000

# ---------------------------------------------------------------- lifecycle
# net_init() -> 0: POSIX has no process-wide socket setup.
FN net_init
    xor eax, eax
    ret

# net_socket() -> fd | -errno
# AF_INET, SOCK_STREAM|SOCK_NONBLOCK|SOCK_CLOEXEC, then TCP_NODELAY=1.
FN net_socket
    mov edi, AF_INET
    mov esi, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC
    xor edx, edx
    SYS SYS_socket
    test rax, rax
    js .Lsk_ret
    sub rsp, 16
    mov dword ptr [rsp], 1              # TCP_NODELAY on
    mov [rsp + 8], rax                  # keep the fd across setsockopt
    mov edi, eax
    mov esi, IPPROTO_TCP
    mov edx, TCP_NODELAY
    mov r10, rsp
    mov r8d, 4
    SYS SYS_setsockopt
    mov rdi, [rsp + 8]
    add rsp, 16
    test rax, rax
    js .Lsk_fail
    mov rax, rdi
.Lsk_ret:
    ret
.Lsk_fail:
    mov r8, rax                         # keep the setsockopt errno
    SYS SYS_close
    mov rax, r8
    ret

# net_connect(fd, ip_be32, port_be16, deadline_ms) -> 0 | -EINPROGRESS | -errno
# The sockaddr_in lives on the stack: family in host order, port and address
# are written verbatim, i.e. the caller's register images are the network
# order bytes. The socket is non-blocking, so a live connect returns -EINPROGRESS.
# deadline_ms is informational here: connect is attempted exactly once.
FN net_connect
    sub rsp, 16
    mov word ptr [rsp], AF_INET
    mov word ptr [rsp + 2], dx
    mov dword ptr [rsp + 4], esi
    mov qword ptr [rsp + 8], 0
    mov rsi, rsp
    mov edx, 16
    SYS SYS_connect
    add rsp, 16
    ret

# net_connect_result(fd) -> 0 | -errno: getsockopt(SOL_SOCKET, SO_ERROR).
FN net_connect_result
    sub rsp, 16
    mov dword ptr [rsp], 0
    mov dword ptr [rsp + 4], 4
    mov esi, SOL_SOCKET
    mov edx, SO_ERROR
    mov r10, rsp
    lea r8, [rsp + 4]
    SYS SYS_getsockopt
    mov ecx, dword ptr [rsp]
    add rsp, 16
    test rax, rax
    js .Lcr_ret
    xor eax, eax
    test ecx, ecx
    jz .Lcr_ret
    movsxd rax, ecx
    neg rax
.Lcr_ret:
    ret

# ---------------------------------------------------------------- stream I/O
# net_send(fd, ptr, len) -> n | -errno; MSG_NOSIGNAL so a reset peer never
# raises SIGPIPE. Syscall 44 is sendto(2): dest_addr/addrlen must be NULL/0.
FN net_send
    mov r10d, MSG_NOSIGNAL
    xor r8d, r8d
    xor r9d, r9d
    SYS SYS_send
    ret

# net_recv(fd, ptr, len) -> n | 0 (eof) | -errno. Syscall 45 is recvfrom(2),
# so the source address arguments must be NULL/0 as well.
FN net_recv
    xor r10d, r10d
    xor r8d, r8d
    xor r9d, r9d
    SYS SYS_recv
    ret

# net_close(fd) -> 0 | -errno. Linux closes the descriptor even when the
# syscall reports EINTR, so there is deliberately no retry.
FN net_close
    SYS SYS_close
    ret

# net_shutdown(fd, how) -> 0 | -errno (SHUT_RD/SHUT_WR/SHUT_RDWR match linux)
FN net_shutdown
    SYS SYS_shutdown
    ret

# ---------------------------------------------------------------- parsing
# parse_ip4(cstr) -> eax = address bytes (memory order: byte0 = first octet),
# edx = 1 | 0. Strict dotted quad, 1..3 digits per octet, 0..255, no trailing
# junk. Leaf; clobbers rax, rcx, rdx, rdi, r8, r9, r10.
.Lparse_ip4:
    xor r8d, r8d                        # packed value
    xor r9d, r9d                        # octet index
    xor r10d, r10d                      # digit count
    xor eax, eax
.Lpi_loop:
    movzx ecx, byte ptr [rdi]
    sub ecx, '0'
    cmp ecx, 9
    ja .Lpi_sep
    imul eax, eax, 10
    add eax, ecx
    inc r10d
    inc rdi
    cmp r10d, 3
    ja .Lpi_bad
    jmp .Lpi_loop
.Lpi_sep:
    test r10d, r10d
    jz .Lpi_bad
    cmp eax, 255
    ja .Lpi_bad
    mov ecx, r9d
    shl ecx, 3
    shl eax, cl
    or r8d, eax
    xor eax, eax
    xor r10d, r10d
    cmp r9d, 3
    je .Lpi_end
    cmp byte ptr [rdi], '.'
    jne .Lpi_bad
    inc rdi
    inc r9d
    jmp .Lpi_loop
.Lpi_end:
    cmp byte ptr [rdi], 0
    jne .Lpi_bad
    mov eax, r8d
    mov edx, 1
    ret
.Lpi_bad:
    xor eax, eax
    xor edx, edx
    ret

# net_is_ip4(cstr) -> 1 | 0
FN net_is_ip4
    PROLOGUE 0
    call .Lparse_ip4
    mov eax, edx
    EPILOGUE
