# http_eof_test: close-delimited bodies (no Content-Length, no chunked) + SSE-style split feeds
.include "opcode.inc"

.bss
.p2align 3
resp: .zero 2048
body: .zero SB_SIZE
.text

.section .rodata
.r1:
    .ascii "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nhello"
.r1len = . - .r1
.r2a:
    .ascii "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\nhe"
.r2alen = . - .r2a
.r2b:
    .ascii "llo"
.r2blen = . - .r2b
.hello:   .asciz "hello"
.m_body:  .asciz "eof body ok\n"
.m_close: .asciz "eof close ok\n"
.m_pend:  .asciz "eof pending ok\n"
.m_done:  .asciz "eof done ok\n"
.m_split: .asciz "eof split ok\n"
.m_fail:  .asciz "FAIL eof\n"
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

# on_body(ctx, ptr, len): append to the body SB
on_body:
    push rsi
    push rdx
    lea rdi, [rip + body]
    pop rdx
    pop rsi
    jmp sb_push

FN opcode_main
    PROLOGUE
    # --- case 1: close-delimited
    lea rdi, [rip + body]
    call sb_clear
    lea rdi, [rip + resp]
    lea rsi, [rip + on_body]
    xor edx, edx
    call http_resp_init
    lea rdi, [rip + resp]
    lea rsi, [rip + .r1]
    mov edx, .r1len
    call http_resp_feed
    cmp rax, .r1len
    jne .Lfail
    # body delivered
    mov rax, [rip + body + SB_ptr]
    mov dl, [rax]
    cmp dl, 'h'
    jne .Lfail
    cmp qword ptr [rip + body + SB_len], 5
    jne .Lfail
    lea rdi, [rip + body]
    lea rsi, [rip + .hello]
    call sb_push_cstr              # NUL for the compare below
    lea rdi, [rip + resp]
    call http_resp_done
    test eax, eax
    jnz .Lfail                     # not done before EOF
    lea rdi, [rip + resp]
    call http_resp_close
    cmp eax, 1
    jne .Lfail
    lea rdi, [rip + resp]
    call http_resp_eof
    lea rdi, [rip + resp]
    call http_resp_done
    cmp eax, 1
    jne .Lfail
    lea rdi, [rip + .m_body]
    call print
    lea rdi, [rip + .m_close]
    call print

    # --- case 2: split feed, no length
    lea rdi, [rip + body]
    call sb_clear
    lea rdi, [rip + resp]
    lea rsi, [rip + on_body]
    xor edx, edx
    call http_resp_init
    lea rdi, [rip + resp]
    lea rsi, [rip + .r2a]
    mov edx, .r2alen
    call http_resp_feed
    cmp rax, .r2alen
    jne .Lfail
    # done must still be 0 here
    lea rdi, [rip + resp]
    call http_resp_done
    test eax, eax
    jnz .Lfail
    lea rdi, [rip + .m_pend]
    call print
    lea rdi, [rip + resp]
    lea rsi, [rip + .r2b]
    mov edx, .r2blen
    call http_resp_feed
    cmp rax, .r2blen
    jne .Lfail
    lea rdi, [rip + resp]
    call http_resp_eof
    lea rdi, [rip + resp]
    call http_resp_done
    cmp eax, 1
    jne .Lfail
    cmp qword ptr [rip + body + SB_len], 5
    jne .Lfail
    mov rax, [rip + body + SB_ptr]
    cmp byte ptr [rax + 4], 'o'
    jne .Lfail
    lea rdi, [rip + .m_split]
    call print
    lea rdi, [rip + .m_done]
    call print

    xor eax, eax
    EPILOGUE
.Lfail:
    lea rdi, [rip + .m_fail]
    call print
    mov eax, 1
    EPILOGUE
