# mock_test: FWIR1 replay backend - load, recv stream, capture, missing file.
.include "opcode.inc"

.bss
.p2align 3
msb:    .zero SB_SIZE
recbuf: .zero 4096

.section .rodata
.Lwire:    .asciz "tests/data/mock_test.wire"
.Lmissing: .asciz "tests/data/does-not-exist"
.Lpayload: .asciz "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello"
.Lping:    .asciz "PING"
.M_open:   .asciz "mock open ok\n"
.M_recv:   .asciz "mock recv ok\n"
.M_sent:   .asciz "mock sent ok\n"
.M_missing:.asciz "mock missing ok\n"
.M_done:   .asciz "mock done\n"
.M_fail:   .asciz "FAIL mock\n"
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

# sb_equals(sb, cstr) -> 1 | 0
sb_equals:
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rsi
    call strlen
    mov r13, rax
    cmp [rbx + SB_len], rax
    jne .Lse_no
    mov rdi, [rbx + SB_ptr]
    mov rsi, r12
    mov rdx, r13
    call memeq
    EPILOGUE
.Lse_no:
    xor eax, eax
    EPILOGUE

FN opcode_main
    PROLOGUE 0

    # 1. load the replay file
    lea rdi, [rip + .Lwire]
    call mock_open
    test eax, eax
    jnz .Lfail
    lea rdi, [rip + .M_open]
    call print

    # 2. connect through the mock backend
    call net_init
    test eax, eax
    jnz .Lfail
    call net_socket
    cmp eax, 4242
    jne .Lfail
    mov r12d, eax
    mov edi, r12d
    mov esi, 0x0100007f
    mov edx, 0x5000                    # port 80, network order
    mov ecx, 30000
    call net_connect
    test eax, eax
    jnz .Lfail
    mov edi, r12d
    call net_connect_result
    test eax, eax
    jnz .Lfail

    # 3. stream dir=1 records until EOF
    lea r13, [rip + msb]
.Lrecv_loop:
    mov edi, r12d
    lea rsi, [rip + recbuf]
    mov edx, 4096
    call net_recv
    test rax, rax
    js .Lfail
    jz .Lrecv_done
    mov rdi, r13
    lea rsi, [rip + recbuf]
    mov rdx, rax
    call sb_push
    jmp .Lrecv_loop
.Lrecv_done:
    lea rdi, [rip + msb]
    lea rsi, [rip + .Lpayload]
    call sb_equals
    test eax, eax
    jz .Lfail
    lea rdi, [rip + .M_recv]
    call print

    # 4. capture client -> server bytes
    mov edi, r12d
    lea rsi, [rip + .Lping]
    mov edx, 4
    call net_send
    cmp eax, 4
    jne .Lfail
    call mock_sent
    test rax, rax
    jz .Lfail
    cmp rdx, 4
    jne .Lfail
    mov rdi, rax
    lea rsi, [rip + .Lping]
    mov edx, 4
    call memeq
    cmp eax, 1
    jne .Lfail
    lea rdi, [rip + .M_sent]
    call print

    # 5. missing file fails with a negative errno
    lea rdi, [rip + .Lmissing]
    call mock_open
    test eax, eax
    jns .Lfail
    lea rdi, [rip + .M_missing]
    call print

    # TLS passthrough sanity (no output)
    xor edi, edi
    xor esi, esi
    xor edx, edx
    call tls_new
    test rax, rax
    jz .Lfail
    mov r13, rax
    mov rdi, rax
    call tls_fd
    cmp eax, 4242
    jne .Lfail
    mov rdi, r13
    call tls_handshake
    test eax, eax
    jnz .Lfail
    mov rdi, r13
    call tls_pending
    test eax, eax
    jnz .Lfail
    mov rdi, r13
    call tls_want
    test eax, eax
    jnz .Lfail
    mov rdi, r13
    call tls_last_error
    test rax, rax
    jnz .Lfail
    mov rdi, r13
    call tls_close

    lea rdi, [rip + .M_done]
    call print
    xor eax, eax
    EPILOGUE
.Lfail:
    lea rdi, [rip + .M_fail]
    call print
    mov eax, 1
    EPILOGUE
