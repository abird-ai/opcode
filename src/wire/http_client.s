.include "opcode.inc"
.include "net/net.inc"
.include "wire/http_client.inc"
.include "wire/url.inc"
# opcode wire: one shared HTTP(S) transport for the five request paths that
# used to repeat connect/DNS/TLS/send/recv (src/app/fetch.s, src/app/update.s,
# src/core/discover.s, src/core/oauth.s, src/core/agent.s).
#
# The client is deliberately transport-only: URL splitting, DNS, non-blocking
# connect, TLS handshake, write-all and read-until-done. Request building stays
# with the frozen src/wire/http.s builders and response parsing with the
# http_resp_* parser, so SSE callers stream through their on_body callback and
# never buffer a body here. The OAuth loopback accept server and the provider
# SSE adapters are not part of this client and stay where they are.
#
# The blocking surface (hc_connect/hc_send_all/hc_recv_loop) is used by
# fetch/update/discover and the OAuth token exchange; the step surface
# (hc_wait_io/hc_tls_events/hc_resolve_host/hc_send_some/hc_recv_some) is used
# by the agent state machine and internally by the blocking helpers.
#
# Errors are negative errno. hc_connect never closes on failure: it records the
# furthest step in HC_stage so the caller can classify the error (URL vs
# network vs TLS) and close (or, for `opcode fetch`, report the TLS detail).

.equ HC_HOST_CAP, 512
.equ HC_AUTH_CAP, 512

.text

# hc_init(hc): zero the transport, fd = -1
FN hc_init
    PROLOGUE 0
    mov rbx, rdi
    mov rdi, rbx
    xor esi, esi
    mov edx, HC_SIZE
    call memset
    mov qword ptr [rbx + HC_fd], -1
    EPILOGUE

# hc_setup(hc, url cstr, flags) -> 0 | -EINVAL
# Parses the URL and fills Host/authority copy, HC_tls and HC_flags.
FN hc_setup
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    mov [rbx + HC_flags], edx
    mov rdi, r12
    lea rsi, [rbx + HC_url]
    call url_parse
    test rax, rax
    js .Lhsu_bad
    lea rdi, [rbx + HC_url]
    lea rsi, [rbx + HC_host]
    mov edx, HC_HOST_CAP
    call url_copy_host
    test rax, rax
    js .Lhsu_bad
    lea rdi, [rbx + HC_url]
    lea rsi, [rbx + HC_authority]
    mov edx, HC_AUTH_CAP
    call url_authority
    test rax, rax
    js .Lhsu_bad
    mov [rbx + HC_authlen], eax
    movzx ecx, word ptr [rbx + HC_url + U_flags]
    and ecx, UF_TLS
    mov [rbx + HC_tls], ecx
    xor eax, eax
    EPILOGUE
.Lhsu_bad:
    mov rax, -EINVAL
    EPILOGUE

# hc_set_recbuf(hc, ptr, cap): the caller's receive buffer
FN hc_set_recbuf
    mov [rdi + HC_recbuf], rsi
    mov [rdi + HC_recbuf_cap], rdx
    ret

# hc_resolve_host(host cstr, out_ip4 /*4 bytes*/, dns_ms) -> 0 | -errno
# Literal IPv4 stays local; anything else goes through net_dns. net_init runs
# here so every caller gets it before its first socket call.
FN hc_resolve_host
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    call net_init
    mov rdi, rbx
    call net_is_ip4
    test eax, eax
    jz .Lrh_dns
    mov rdi, rbx
    call hc_ip4_parse
    test eax, eax
    jz .Lrh_bad
    mov [r12], eax
    xor eax, eax
    EPILOGUE
.Lrh_dns:
    mov rdi, rbx
    mov rsi, r12
    mov edx, r13d
    call net_dns
    EPILOGUE
.Lrh_bad:
    mov rax, -EINVAL
    EPILOGUE

# hc_resolve(hc, dns_ms) -> 0 | -errno
FN hc_resolve
    PROLOGUE 0
    mov rbx, rdi
    mov r12d, esi
    lea rdi, [rbx + HC_host]
    lea rsi, [rbx + HC_ip]
    mov edx, r12d
    call hc_resolve_host
    EPILOGUE

# hc_socket_start(hc, connect_ms) -> 0 | -EINPROGRESS | -errno
FN hc_socket_start
    PROLOGUE 0
    mov rbx, rdi
    mov r12d, esi
    call net_socket
    test rax, rax
    js .Lhss_ret
    mov [rbx + HC_fd], rax
    mov edi, eax
    mov esi, [rbx + HC_ip]
    movzx edx, word ptr [rbx + HC_url + U_port]
    rol dx, 8
    mov ecx, r12d
    call net_connect
.Lhss_ret:
    EPILOGUE

# hc_socket_finish(hc) -> 0 | -errno (after the fd is writable)
FN hc_socket_finish
    mov edi, [rdi + HC_fd]
    jmp net_connect_result

# hc_tls_start(hc) -> 0 | -EIO: TLS context for https, no-op for http
FN hc_tls_start
    PROLOGUE 0
    mov rbx, rdi
    test word ptr [rbx + HC_url + U_flags], UF_TLS
    jz .Lhts_ok
    lea rdi, [rbx + HC_host]
    movzx esi, word ptr [rbx + HC_url + U_port]
    mov edx, TLS_VERIFY
    test dword ptr [rbx + HC_flags], HC_F_INSECURE
    jz 1f
    mov edx, TLS_INSECURE
1:  call tls_new
    test rax, rax
    jz .Lhts_fail
    mov [rbx + HC_conn], rax
    mov rdi, rax
    mov esi, [rbx + HC_fd]
    call tls_set_fd
.Lhts_ok:
    xor eax, eax
    EPILOGUE
.Lhts_fail:
    mov rax, -EIO
    EPILOGUE

# .Lwait_deadline(hc, wait_ns) -> rdx: the absolute poll deadline. HC_deadline
# (absolute mode) wins; otherwise now + wait_ns per wait, which is the
# historical fetch/update/discover/agent-blocking behaviour.
.Lwait_deadline:
    mov rdx, [rdi + HC_deadline]
    test rdx, rdx
    jnz 1f
    push rdi
    push rsi
    mov edi, CLOCK_MONOTONIC
    call os_now_ns
    pop rsi
    pop rdi
    mov rdx, rax
    add rdx, rsi
1:  ret

# hc_handshake(hc, wait_ns) -> 0 | -errno
FN hc_handshake
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
.Lhh_loop:
    mov rdi, [rbx + HC_conn]
    call tls_handshake
    movsxd rax, eax                 # the shim returns C int: sign-extend
    test rax, rax
    jz .Lhh_ok
    cmp rax, -EAGAIN
    jne .Lhh_ret
    mov rdi, [rbx + HC_conn]
    call hc_tls_events
    mov r13d, eax
    mov rdi, rbx
    mov rsi, r12
    call .Lwait_deadline
    mov edi, [rbx + HC_fd]
    mov esi, r13d
    call hc_wait_io
    test rax, rax
    js .Lhh_ret
    jmp .Lhh_loop
.Lhh_ok:
    xor eax, eax
.Lhh_ret:
    EPILOGUE

# hc_connect(hc, url cstr, flags, dns_ms, wait_ns, absolute) -> 0 | -errno
# Full blocking connect: parse, resolve, socket, non-blocking connect, TLS
# handshake. On failure the transport is left as-is and HC_stage records how
# far it got (HC_STAGE_*).
# hc_connect_started(hc, dns_ms, wait_ns, absolute) -> 0 | -errno
# Resolve/connect/TLS/handshake on an HC already filled by hc_setup. Used by
# callers that keep their own URL storage (discover, the agent blocking path)
# and by hc_connect.
FN hc_connect_started
    PROLOGUE 0
    mov rbx, rdi
    mov r12d, esi                   # dns_ms
    mov r13, rdx                    # wait_ns
    test ecx, ecx
    jnz 0f
    mov qword ptr [rbx + HC_deadline], 0
    jmp 1f
0:  mov edi, CLOCK_MONOTONIC
    call os_now_ns
    add rax, r13
    mov [rbx + HC_deadline], rax
1:  mov dword ptr [rbx + HC_stage], HC_STAGE_RESOLVE
    mov rdi, rbx
    mov esi, r12d
    call hc_resolve
    test rax, rax
    js .Lhcs_ret
    mov dword ptr [rbx + HC_stage], HC_STAGE_SOCKET
    mov rdi, rbx
    mov esi, r12d
    call hc_socket_start
    test rax, rax
    jns .Lhcs_connected
    cmp rax, -EINPROGRESS
    jne .Lhcs_ret
    mov rdi, rbx
    mov rsi, r13
    call .Lwait_deadline
    mov edi, [rbx + HC_fd]
    mov esi, POLLOUT
    call hc_wait_io
    test rax, rax
    js .Lhcs_ret
.Lhcs_connected:
    mov dword ptr [rbx + HC_stage], HC_STAGE_CONNECT
    mov rdi, rbx
    call hc_socket_finish
    test rax, rax
    js .Lhcs_ret
    mov dword ptr [rbx + HC_stage], HC_STAGE_TLS
    mov rdi, rbx
    call hc_tls_start
    test rax, rax
    js .Lhcs_ret
    cmp qword ptr [rbx + HC_conn], 0
    je .Lhcs_ok
    mov dword ptr [rbx + HC_stage], HC_STAGE_HANDSHAKE
    mov rdi, rbx
    mov rsi, r13
    call hc_handshake
    test rax, rax
    js .Lhcs_ret
.Lhcs_ok:
    xor eax, eax
.Lhcs_ret:
    EPILOGUE

# hc_connect(hc, url cstr, flags, dns_ms, wait_ns, absolute) -> 0 | -errno
# Full blocking connect: parse, resolve, socket, non-blocking connect, TLS
# handshake. On failure the transport is left as-is and HC_stage records how
# far it got (HC_STAGE_*).
FN hc_connect
    PROLOGUE 48
    mov rbx, rdi
    mov [rsp], rsi                  # url
    mov [rsp + 8], rdx              # flags
    mov [rsp + 16], rcx             # dns_ms
    mov [rsp + 24], r8              # wait_ns
    mov [rsp + 32], r9              # absolute
    mov dword ptr [rbx + HC_stage], HC_STAGE_URL
    mov rdi, rbx
    mov rsi, [rsp]
    mov edx, dword ptr [rsp + 8]
    call hc_setup
    test rax, rax
    js .Lhcc_ret
    mov rdi, rbx
    mov esi, dword ptr [rsp + 16]
    mov rdx, [rsp + 24]
    mov ecx, dword ptr [rsp + 32]
    call hc_connect_started
.Lhcc_ret:
    EPILOGUE

# hc_close(hc): close the TLS context and socket; idempotent
FN hc_close
    PROLOGUE 0
    mov rbx, rdi
    mov rdi, [rbx + HC_conn]
    test rdi, rdi
    jz 1f
    call tls_close
    mov qword ptr [rbx + HC_conn], 0
1:  mov edi, [rbx + HC_fd]
    cmp edi, 0
    jl 2f
    call net_close
2:  mov qword ptr [rbx + HC_fd], -1
    EPILOGUE

# hc_send_some(fd, conn, ptr, len) -> n>0 | -EAGAIN | -errno
# call/ret, not a tail jmp: the x86->arm64 translator marshals a native C
# return only across a call, and tls_write returns in the native register.
# hc_send_some(fd, conn, ptr, len) -> n>0 | -EAGAIN | -errno
# A real frame (not a tail jmp): the arm64 translator marshals a native C
# return only across a call, and a leaf frame keeps RSP aligned for it.
FN hc_send_some
    PROLOGUE 0
    test rsi, rsi
    jz .Lhss_plain
    mov rdi, rsi
    mov rsi, rdx
    mov rdx, rcx
    call tls_write
    EPILOGUE
.Lhss_plain:
    mov rsi, rdx
    mov rdx, rcx
    call net_send
    EPILOGUE

# hc_recv_some(conn, fd, buf, cap) -> n>0 | 0 eof | -EAGAIN | -errno
FN hc_recv_some
    PROLOGUE 0
    test rdi, rdi
    jz .Lhrs_plain
    mov rsi, rdx
    mov rdx, rcx
    call tls_read
    EPILOGUE
.Lhrs_plain:
    mov edi, esi
    mov rsi, rdx
    mov rdx, rcx
    call net_recv
    EPILOGUE

# hc_send_all(fd, conn, ptr, len, deadline_ns) -> 0 | -errno
# One deadline for the whole request (all historical send loops did this; the
# OAuth exchange reuses its request deadline, which is already absolute).
FN hc_send_all
    PROLOGUE 0
    mov rbx, rdi                    # fd
    mov r12, rsi                    # conn
    mov r13, rdx                    # ptr
    mov r14, rcx                    # remaining
    mov r15, r8                     # deadline
.Lsa_loop:
    test r14, r14
    jz .Lsa_ok
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    mov rcx, r14
    call hc_send_some
    test rax, rax
    jg .Lsa_sent
    cmp rax, -EAGAIN
    je .Lsa_wait
    test rax, rax
    jnz .Lsa_ret
    mov rax, -EIO                   # a zero write is a closed peer
    EPILOGUE
.Lsa_sent:
    add r13, rax
    sub r14, rax
    jmp .Lsa_loop
.Lsa_wait:
    mov eax, POLLOUT
    test r12, r12
    jz 1f
    mov rdi, r12
    call hc_tls_events
1:  mov edi, ebx
    mov esi, eax
    mov rdx, r15
    call hc_wait_io
    test rax, rax
    js .Lsa_ret
    jmp .Lsa_loop
.Lsa_ok:
    xor eax, eax
.Lsa_ret:
    EPILOGUE

# hc_recv_loop(hc, resp, flags, on_data, ctx, deadline_ns) -> 0 | -errno
#   on_data(ctx, ptr, len) runs for every raw chunk before the parser sees it
#   (record/dump hooks); pass 0 to skip it. flags is HCR_* and selects the
#   historical error policy. Returns -EINVAL for parser/body errors; the
#   caller reads http_resp_error for the message.
FN hc_recv_loop
    PROLOGUE 16
    mov rbx, rdi                    # hc
    mov r12, rsi                    # resp
    mov r13d, edx                   # flags
    mov r14, rcx                    # on_data
    mov r15, r8                     # ctx
    mov [rsp], r9                   # deadline
.Lrl_loop:
    mov rdi, r12
    call http_resp_done
    test eax, eax
    jnz .Lrl_done
    mov rdi, [rbx + HC_conn]
    mov esi, [rbx + HC_fd]
    mov rdx, [rbx + HC_recbuf]
    mov rcx, [rbx + HC_recbuf_cap]
    call hc_recv_some
    test rax, rax
    jg .Lrl_data
    jz .Lrl_eof
    cmp rax, -EAGAIN
    je .Lrl_wait
    EPILOGUE
.Lrl_data:
    mov [rsp + 8], rax
    test r14, r14
    jz 1f
    mov rdi, r15
    mov rsi, [rbx + HC_recbuf]
    mov rdx, rax
    call r14
1:  mov rdi, r12
    mov rsi, [rbx + HC_recbuf]
    mov rdx, [rsp + 8]
    call http_resp_feed
    test r13d, HCR_PROGRESS
    jz 2f
    test rax, rax
    jg 2f
    mov rdi, r12
    call http_resp_done
    test eax, eax
    jnz 2f
    mov rax, -EINVAL
    EPILOGUE
2:  test r13d, HCR_CHECK_FEED
    jz .Lrl_loop
    mov rdi, r12
    call http_resp_error
    test rax, rax
    jnz .Lrl_err
    jmp .Lrl_loop
.Lrl_wait:
    mov eax, POLLIN
    cmp qword ptr [rbx + HC_conn], 0
    je 1f
    mov rdi, [rbx + HC_conn]
    call hc_tls_events
1:  mov edi, [rbx + HC_fd]
    mov esi, eax
    mov rdx, [rsp]
    call hc_wait_io
    test rax, rax
    js .Lrl_ret
    jmp .Lrl_loop
.Lrl_eof:
    mov rdi, r12
    call http_resp_eof
    test r13d, HCR_CHECK_EOF
    jz .Lrl_ok
    mov rdi, r12
    call http_resp_error
    test rax, rax
    jnz .Lrl_err
    jmp .Lrl_ok
.Lrl_done:
    test r13d, HCR_CHECK_DONE
    jz .Lrl_ok
    mov rdi, r12
    call http_resp_error
    test rax, rax
    jnz .Lrl_err
.Lrl_ok:
    xor eax, eax
.Lrl_ret:
    EPILOGUE
.Lrl_err:
    mov rax, -EINVAL
    EPILOGUE

# hc_wait_io(fd, events, deadline_ns) -> 1 ready | -errno
FN hc_wait_io
    PROLOGUE 16
    mov r12d, edi
    mov r13d, esi
    mov r14, rdx
1:  mov edi, CLOCK_MONOTONIC
    call os_now_ns
    mov rcx, r14
    sub rcx, rax
    jbe 3f
    mov rax, rcx
    xor edx, edx
    mov ecx, 1000000
    div rcx
    mov dword ptr [rsp], r12d
    mov word ptr [rsp + 4], r13w
    mov word ptr [rsp + 6], 0
    mov rdi, rsp
    mov esi, 1
    mov rdx, rax
    call os_poll
    test rax, rax
    js 2f
    jz 1b
    mov eax, 1
    EPILOGUE
2:  EPILOGUE
3:  mov rax, -ETIMEDOUT
    EPILOGUE

# hc_tls_events(conn) -> poll events for the current TLS want direction
FN hc_tls_events
    PROLOGUE 0
    call tls_want
    mov ecx, POLLOUT
    mov edx, POLLIN
    cmp eax, 2
    cmove edx, ecx
    mov eax, edx
    EPILOGUE

# hc_ip4_parse(cstr) -> be32 in memory-byte convention | 0 (leaf)
FN hc_ip4_parse
    xor r8d, r8d
    xor ecx, ecx
1:  xor eax, eax
    xor r10d, r10d
2:  movzx edx, byte ptr [rdi]
    sub edx, '0'
    cmp edx, 9
    ja 3f
    imul eax, eax, 10
    add eax, edx
    inc r10d
    inc rdi
    cmp r10d, 3
    ja 9f
    jmp 2b
3:  test r10d, r10d
    jz 9f
    cmp eax, 255
    ja 9f
    shl r8d, 8
    or r8d, eax
    cmp ecx, 3
    je 4f
    cmp byte ptr [rdi], '.'
    jne 9f
    inc rdi
    inc ecx
    jmp 1b
4:  cmp byte ptr [rdi], 0
    jne 9f
    mov eax, r8d
    bswap eax
    ret
9:  xor eax, eax
    ret
