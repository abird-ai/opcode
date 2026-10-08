.include "opcode.inc"
.include "net/net.inc"
.include "wire/http_client.inc"
# http_client_test: the shared wire/http_client transport against the mock
# net backend: content-length vs chunked vs EOF bodies, reassembly across
# records, mid-body truncation, a malformed chunk, send capture, timeout and
# idempotent close. Live TLS and redirect behaviour are covered by the
# integration suites (tests/net.sh), not here.

.bss
.p2align 3
hc:     .zero HC_SIZE
resp:   .zero 2048
recbuf: .zero 4096
body:   .zero SB_SIZE

.section .rodata
.Lurl:        .asciz "http://127.0.0.1:80/"
.Lreq:        .ascii "GET / HTTP/1.1\r\n"
.set LREQ_LEN, . - .Lreq
.Lw_chunked:  .asciz "tests/data/http_client_chunked.wire"
.Lw_cl:       .asciz "tests/data/http_client_cl.wire"
.Lw_eof:      .asciz "tests/data/http_client_eof.wire"
.Lw_trunc:    .asciz "tests/data/http_client_trunc.wire"
.Lw_badchunk: .asciz "tests/data/http_client_badchunk.wire"
.Lhello:      .asciz "hello"
.Lworld:      .asciz "hello world"
.Lip4:        .asciz "127.0.0.1"
.Lip4bad:     .asciz "999.1.1.1"
.Lm_connect:  .asciz "http-client connect ok\n"
.Lm_send:     .asciz "http-client send ok\n"
.Lm_chunked:  .asciz "http-client chunked ok\n"
.Lm_cl:       .asciz "http-client cl ok\n"
.Lm_eof:      .asciz "http-client eof ok\n"
.Lm_trunc:    .asciz "http-client trunc ok\n"
.Lm_badchunk: .asciz "http-client badchunk ok\n"
.Lm_close:    .asciz "http-client close ok\n"
.Lm_timeout:  .asciz "http-client timeout ok\n"
.Lm_ip4:      .asciz "http-client ip4 ok\n"
.Lm_done:     .asciz "http-client done\n"
.Lm_fail:     .asciz "FAIL http-client\n"

.text

# print(cstr)
print:
    push rdi
    call strlen
    pop rdi
    mov rdx, rax
    mov rsi, rdi
    mov edi, 1
    jmp write_all

# on_body(ctx, ptr, len): append to body
on_body:
    push rsi
    push rdx
    lea rdi, [rip + body]
    pop rdx
    pop rsi
    jmp sb_push

# case_begin(wire cstr) -> 0 | -1: mock replay + connect + parser reset
case_begin:
    PROLOGUE
    mov rdi, rdi
    mov r12, rdi
    call mock_open
    test rax, rax
    js .Lcb_bad
    lea rdi, [rip + hc]
    call hc_init
    lea rdi, [rip + hc]
    lea rsi, [rip + .Lurl]
    xor edx, edx
    mov ecx, 30000
    mov r8, 3000000000
    xor r9d, r9d
    call hc_connect
    test rax, rax
    js .Lcb_bad
    lea rdi, [rip + hc]
    lea rsi, [rip + recbuf]
    mov edx, 4096
    call hc_set_recbuf
    lea rdi, [rip + body]
    call sb_clear
    lea rdi, [rip + resp]
    lea rsi, [rip + on_body]
    xor edx, edx
    call http_resp_init
    xor eax, eax
    EPILOGUE
.Lcb_bad:
    mov rax, -1
    EPILOGUE

# recv_case(flags) -> 0 | -errno
recv_case:
    PROLOGUE
    mov edx, edi
    lea rdi, [rip + hc]
    lea rsi, [rip + resp]
    xor ecx, ecx
    xor r8d, r8d
    mov r9, 0x7fffffffffffffff
    call hc_recv_loop
    EPILOGUE

# body_eq(cstr) -> 1 | 0
body_eq:
    PROLOGUE
    mov r12, rdi
    mov rdi, r12
    call strlen
    mov r13, rax
    cmp [rip + body + SB_len], rax
    jne .Lbe_no
    mov rdi, [rip + body + SB_ptr]
    mov rsi, r12
    mov rdx, r13
    call memeq
    EPILOGUE
.Lbe_no:
    xor eax, eax
    EPILOGUE

FN opcode_main
    PROLOGUE
    # ---- connect + send capture ------------------------------------------
    lea rdi, [rip + .Lw_chunked]
    call case_begin
    test rax, rax
    js .Lfail
    lea rdi, [rip + .Lm_connect]
    call print
    mov edi, [rip + hc + HC_fd]
    mov rsi, [rip + hc + HC_conn]
    lea rdx, [rip + .Lreq]
    mov ecx, LREQ_LEN
    mov r8, 0x7fffffffffffffff
    call hc_send_all
    test rax, rax
    js .Lfail
    call mock_sent
    cmp rdx, LREQ_LEN
    jne .Lfail
    mov rdi, rax
    lea rsi, [rip + .Lreq]
    mov rdx, LREQ_LEN
    call memeq
    cmp eax, 1
    jne .Lfail
    lea rdi, [rip + .Lm_send]
    call print

    # ---- chunked body, reassembled across records ------------------------
    mov edi, HCR_STRICT
    call recv_case
    test rax, rax
    js .Lfail
    lea rdi, [rip + resp]
    call http_resp_status
    cmp eax, 200
    jne .Lfail
    lea rdi, [rip + resp]
    call http_resp_done
    cmp eax, 1
    jne .Lfail
    lea rdi, [rip + .Lhello]
    call body_eq
    cmp eax, 1
    jne .Lfail
    lea rdi, [rip + .Lm_chunked]
    call print

    # ---- content-length body split across records ------------------------
    lea rdi, [rip + .Lw_cl]
    call case_begin
    test rax, rax
    js .Lfail
    mov edi, HCR_STRICT
    call recv_case
    test rax, rax
    js .Lfail
    lea rdi, [rip + resp]
    call http_resp_done
    cmp eax, 1
    jne .Lfail
    lea rdi, [rip + .Lworld]
    call body_eq
    cmp eax, 1
    jne .Lfail
    lea rdi, [rip + .Lm_cl]
    call print

    # ---- EOF-delimited body ----------------------------------------------
    lea rdi, [rip + .Lw_eof]
    call case_begin
    test rax, rax
    js .Lfail
    mov edi, HCR_STRICT
    call recv_case
    test rax, rax
    js .Lfail
    lea rdi, [rip + resp]
    call http_resp_done
    cmp eax, 1
    jne .Lfail
    lea rdi, [rip + .Lworld]
    call body_eq
    cmp eax, 1
    jne .Lfail
    lea rdi, [rip + .Lm_eof]
    call print

    # ---- truncation: Content-Length promised 20, EOF after 5 -------------
    lea rdi, [rip + .Lw_trunc]
    call case_begin
    test rax, rax
    js .Lfail
    mov edi, HCR_STRICT
    call recv_case
    cmp rax, -EINVAL
    jne .Lfail
    lea rdi, [rip + resp]
    call http_resp_error
    test rax, rax
    jz .Lfail
    lea rdi, [rip + .Lm_trunc]
    call print

    # ---- malformed chunk size --------------------------------------------
    lea rdi, [rip + .Lw_badchunk]
    call case_begin
    test rax, rax
    js .Lfail
    mov edi, HCR_CHECK_FEED
    call recv_case
    cmp rax, -EINVAL
    jne .Lfail
    lea rdi, [rip + resp]
    call http_resp_error
    test rax, rax
    jz .Lfail
    lea rdi, [rip + .Lm_badchunk]
    call print

    # ---- close is idempotent (fresh and just-closed transports) ----------
    lea rdi, [rip + hc]
    call hc_close
    lea rdi, [rip + hc]
    call hc_close
    lea rdi, [rip + .Lm_close]
    call print

    # ---- timeout: a deadline already in the past -------------------------
    xor edi, edi
    mov esi, POLLIN
    mov edx, 1
    call hc_wait_io
    cmp rax, -ETIMEDOUT
    jne .Lfail
    lea rdi, [rip + .Lm_timeout]
    call print

    # ---- ip4 parser ------------------------------------------------------
    lea rdi, [rip + .Lip4]
    call hc_ip4_parse
    cmp eax, 0x0100007F
    jne .Lfail
    lea rdi, [rip + .Lip4bad]
    call hc_ip4_parse
    test eax, eax
    jnz .Lfail
    lea rdi, [rip + .Lm_ip4]
    call print

    lea rdi, [rip + .Lm_done]
    call print
    xor eax, eax
    EPILOGUE
.Lfail:
    lea rdi, [rip + .Lm_fail]
    call print
    mov eax, 1
    EPILOGUE
