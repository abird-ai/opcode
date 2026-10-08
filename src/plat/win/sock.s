.include "opcode.inc"
.include "plat/win/win.inc"
# win: Layer 0 socket syscalls for the OAuth loopback server, and the numbers
# used by src/net/linux/socket.s and dns.s through the same win_syscall shim.
# Winsock has a different option namespace (SOL_SOCKET 1 vs 0xFFFF, SO_ERROR 4
# vs 0x1007) and returns WSA error codes; both are normalized here.

# ---------------------------------------------------------------- creation
# socket(domain, type, proto) -> fd | -errno
FN winh_socket
    PROLOGUE 64
    mov r14d, edi                   # domain (Linux numbering)
    mov r15d, esi                   # type with Linux flag bits
    mov r12d, esi                   # type
    mov r13d, edx                   # proto
    and r12d, 0xFFF7F7FF            # strip SOCK_NONBLOCK | SOCK_CLOEXEC
    cmp r14d, 10                    # Linux AF_INET6 -> WinSock AF_INET6 (23)
    jne 0f
    mov r14d, 23
0:  call winwsa_init
    test rax, rax
    js .Lsk_out
    mov ecx, r14d
    mov edx, r12d
    mov r8d, r13d
    call socket
    cmp rax, -1
    je .Lsk_err
    mov r13, rax                    # SOCKET
    mov rcx, r13                    # never inherited by a spawned child
    mov edx, HANDLE_FLAG_INHERIT
    xor r8d, r8d
    call SetHandleInformation
    test r15d, SOCK_NONBLOCK
    jz .Lsk_fd
    mov rcx, r13
    mov edx, FIONBIO
    lea r8, [rsp + 40]
    mov dword ptr [rsp + 40], 1
    call ioctlsocket
.Lsk_fd:
    mov edi, FK_SOCKET
    mov rsi, r13
    xor edx, edx
    test r15d, SOCK_NONBLOCK
    jz 1f
    mov edx, O_NONBLOCK
1:  call win_fd_new
    test rax, rax
    jns .Lsk_out
    mov r12, rax
    mov rcx, r13
    call closesocket
    mov rax, r12
.Lsk_out:
    EPILOGUE
.Lsk_err:
    call win_wsa_error
    EPILOGUE

# connect(fd, addr, len) -> 0 | -EINPROGRESS | -errno
FN winh_connect
    PROLOGUE 48
    mov r12, rsi
    mov r13, rdx
    call win_fd_entry
    test rax, rax
    jz .Lco_bad
    cmp word ptr [r12], 10          # Linux AF_INET6 -> WinSock AF_INET6
    jne 1f
    mov word ptr [r12], 23
1:  mov rcx, [rax + FD_HANDLE]
    mov rdx, r12
    mov r8, r13
    call connect
    test eax, eax
    jz .Lco_ok
    call WSAGetLastError
    cmp eax, WSAEWOULDBLOCK
    je .Lco_inprog
    cmp eax, WSAEINPROGRESS
    je .Lco_inprog
    cmp eax, WSAEALREADY
    je .Lco_inprog
    mov edi, eax
    call win_errno_from_code
    EPILOGUE
.Lco_inprog:
    mov rax, -EINPROGRESS
    EPILOGUE
.Lco_ok:
    xor eax, eax
    EPILOGUE
.Lco_bad:
    mov rax, -EBADF
    EPILOGUE

# send(fd, buf, len, flags) -> n | -errno
FN winh_send
    PROLOGUE 48
    mov r12, rsi
    mov r13, rdx
    call win_fd_entry
    test rax, rax
    jz .Lsd_bad
    mov rcx, [rax + FD_HANDLE]
    mov rdx, r12
    mov r8, r13
    xor r9d, r9d
    call send
    cmp eax, -1
    je .Lsd_err
    cdqe
    EPILOGUE
.Lsd_err:
    call win_wsa_error
    EPILOGUE
.Lsd_bad:
    mov rax, -EBADF
    EPILOGUE

# recv(fd, buf, len, flags) -> n | 0 (eof) | -errno
FN winh_recv
    PROLOGUE 48
    mov r12, rsi
    mov r13, rdx
    call win_fd_entry
    test rax, rax
    jz .Lrv_bad
    mov rcx, [rax + FD_HANDLE]
    mov rdx, r12
    mov r8, r13
    xor r9d, r9d
    call recv
    cmp eax, -1
    je .Lrv_err
    cdqe
    EPILOGUE
.Lrv_err:
    call win_wsa_error
    EPILOGUE
.Lrv_bad:
    mov rax, -EBADF
    EPILOGUE

# shutdown(fd, how) -> 0 | -errno (SHUT_* == SD_*)
FN winh_shutdown
    PROLOGUE 32
    mov r12d, esi
    call win_fd_entry
    test rax, rax
    jz .Lsh_bad
    mov rcx, [rax + FD_HANDLE]
    mov edx, r12d
    call shutdown
    test eax, eax
    jnz .Lsh_err
    xor eax, eax
    EPILOGUE
.Lsh_err:
    call win_wsa_error
    EPILOGUE
.Lsh_bad:
    mov rax, -EBADF
    EPILOGUE

# bind(fd, addr, len) -> 0 | -errno
FN winh_bind
    PROLOGUE 48
    mov r12, rsi
    mov r13, rdx
    call win_fd_entry
    test rax, rax
    jz .Lbd_bad
    cmp word ptr [r12], 10          # Linux AF_INET6 -> WinSock AF_INET6
    jne 1f
    mov word ptr [r12], 23
1:  mov rcx, [rax + FD_HANDLE]
    mov rdx, r12
    mov r8, r13
    call bind
    test eax, eax
    jnz .Lbd_err
    xor eax, eax
    EPILOGUE
.Lbd_err:
    call win_wsa_error
    EPILOGUE
.Lbd_bad:
    mov rax, -EBADF
    EPILOGUE

# listen(fd, backlog) -> 0 | -errno
FN winh_listen
    PROLOGUE 32
    mov r12d, esi
    call win_fd_entry
    test rax, rax
    jz .Lli_bad
    mov rcx, [rax + FD_HANDLE]
    mov edx, r12d
    call listen
    test eax, eax
    jnz .Lli_err
    xor eax, eax
    EPILOGUE
.Lli_err:
    call win_wsa_error
    EPILOGUE
.Lli_bad:
    mov rax, -EBADF
    EPILOGUE

# getsockname(fd, addr, addrlen*) -> 0 | -errno
FN winh_getsockname
    PROLOGUE 48
    mov r12, rsi
    mov r13, rdx
    call win_fd_entry
    test rax, rax
    jz .Lgn_bad
    mov rcx, [rax + FD_HANDLE]
    mov rdx, r12
    mov r8, r13
    call getsockname
    test eax, eax
    jnz .Lgn_err
    cmp word ptr [r12], 23          # WinSock AF_INET6 -> Linux AF_INET6
    jne 1f
    mov word ptr [r12], 10
1:  xor eax, eax
    EPILOGUE
.Lgn_err:
    call win_wsa_error
    EPILOGUE
.Lgn_bad:
    mov rax, -EBADF
    EPILOGUE

# accept4(fd, addr, addrlen*, flags) -> fd | -errno
FN winh_accept4
    PROLOGUE 48
    mov r15d, r10d                  # accept4 flags (SOCK_NONBLOCK/CLOEXEC)
    call win_fd_entry
    test rax, rax
    jz .Lac_bad
    mov rcx, [rax + FD_HANDLE]
    xor edx, edx
    xor r8d, r8d
    call accept
    cmp rax, -1
    je .Lac_err
    mov r13, rax
    mov rcx, r13                    # accepted socket: non-inheritable
    mov edx, HANDLE_FLAG_INHERIT
    xor r8d, r8d
    call SetHandleInformation
    test r15d, SOCK_NONBLOCK
    jz 1f
    mov rcx, r13
    mov edx, FIONBIO
    lea r8, [rsp + 40]
    mov dword ptr [rsp + 40], 1
    call ioctlsocket
1:  mov edi, FK_SOCKET
    mov rsi, r13
    xor edx, edx
    test r15d, SOCK_NONBLOCK
    jz 2f
    mov edx, O_NONBLOCK
2:  call win_fd_new
    test rax, rax
    jns .Lac_out
    mov r12, rax
    mov rcx, r13
    call closesocket
    mov rax, r12
.Lac_out:
    EPILOGUE
.Lac_err:
    call win_wsa_error
    EPILOGUE
.Lac_bad:
    mov rax, -EBADF
    EPILOGUE

# setsockopt(fd, level, optname, val, len) -> 0 | -errno
FN winh_setsockopt
    PROLOGUE 48
    mov r12, r10                    # optval
    mov r13, r8                     # optlen
    mov r14d, esi                   # level
    mov r15d, edx                   # optname
    call win_fd_entry
    test rax, rax
    jz .Lso_bad
    mov rcx, [rax + FD_HANDLE]
    mov edx, r14d
    cmp edx, 1
    jne 1f
    mov edx, 0xFFFF
1:  mov r8d, r15d
    cmp r14d, 1                     # SOL_SOCKET
    jne 2f
    cmp r8d, 4                      # SO_ERROR
    jne 3f
    mov r8d, 0x1007
    jmp 2f
3:  cmp r8d, 2                      # SO_REUSEADDR
    jne 2f
    mov r8d, -5                     # SO_EXCLUSIVEADDRUSE: fail when in use
    jmp 2f
2:  cmp r14d, 41                    # IPPROTO_IPV6
    jne 4f
    cmp r8d, 26                     # IPV6_V6ONLY
    jne 4f
    mov r8d, 27
4:  mov r9, r12
    mov [rsp + 32], r13
    call setsockopt
    test eax, eax
    jnz .Lso_err
    xor eax, eax
    EPILOGUE
.Lso_err:
    call win_wsa_error
    EPILOGUE
.Lso_bad:
    mov rax, -EBADF
    EPILOGUE

# getsockopt(fd, level, optname, val, len*) -> 0 | -errno
# SO_ERROR returns a WSA code; it is rewritten in place as a positive Linux
# errno so the portable net_connect_result() sees the Linux convention.
FN winh_getsockopt
    PROLOGUE 64
    mov r12, r10                    # optval
    mov r13, r8                     # optlen pointer
    mov r14d, esi                   # level
    mov r15d, edx                   # optname
    call win_fd_entry
    test rax, rax
    jz .Lgo_bad
    mov rcx, [rax + FD_HANDLE]
    mov edx, r14d
    cmp edx, 1
    jne 1f
    mov edx, 0xFFFF
1:  mov r8d, r15d
    cmp r14d, 1                     # SOL_SOCKET
    jne 2f
    cmp r8d, 4                      # SO_ERROR
    jne 2f
    mov r8d, 0x1007
2:  mov r9, r12
    mov [rsp + 32], r13
    call getsockopt
    test eax, eax
    jnz .Lgo_err
    cmp r14d, 1
    jne .Lgo_ok
    cmp r15d, 4
    jne .Lgo_ok
    mov eax, [r12]
    test eax, eax
    jz .Lgo_ok
    mov edi, eax
    call win_errno_from_code
    neg eax
    mov [r12], eax
.Lgo_ok:
    xor eax, eax
    EPILOGUE
.Lgo_err:
    call win_wsa_error
    EPILOGUE
.Lgo_bad:
    mov rax, -EBADF
    EPILOGUE
