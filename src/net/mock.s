.include "opcode.inc"
# opcode net: mock/replay backend used by the test harness.
#
# mock_open(path) loads an "FWIR1\n" replay file (see src/wire/API.md) into
# memory and indexes every record as { i64 payload_offset; u32 len; u8 dir }.
# dir=0 (client -> server) records are skipped by net_recv; dir=1 records are
# streamed back in order, then EOF. net_send/tls_write append to a capture
# buffer exposed by mock_sent(). TLS is plaintext passthrough.

.ifndef E2BIG
.equ E2BIG, 7
.endif

.equ MOCK_FD,       4242
.equ MOCK_MAX_RECS, 4096
.equ MOCK_REC_OFF,  0
.equ MOCK_REC_LEN,  8
.equ MOCK_REC_DIR,  12
.equ MOCK_REC_SIZE, 16
.equ MOCK_READ_CHUNK, 65536
.equ MOCK_TLS_MAGIC, 0x00534c544b434f4d     # "MOCKTLS\0"

.bss
.p2align 3
mock_file:  .zero SB_SIZE                  # whole replay file
mock_cap:   .zero SB_SIZE                  # captured client -> server bytes
mock_recs:  .zero MOCK_MAX_RECS * MOCK_REC_SIZE
mock_nrecs: .zero 8
mock_cur:   .zero 8                        # current record index
mock_off:   .zero 8                        # bytes consumed of the current record

.section .rodata
.Lfwir1: .asciz "FWIR1\n"
.text

# mock_open(path cstr) -> 0 | -errno
FN mock_open
    PROLOGUE 0
    mov r12, rdi
    call mock_free                     # drop any previous replay
    mov rdi, r12
    mov esi, O_RDONLY
    xor edx, edx
    call os_open
    test rax, rax
    js .Lmo_out
    mov r13d, eax
.Lmo_read:
    lea rdi, [rip + mock_file]
    mov esi, MOCK_READ_CHUNK
    call sb_reserve
    mov r14, rax
    mov edi, r13d
    mov rsi, r14
    mov edx, MOCK_READ_CHUNK
    call os_read
    cmp rax, -EINTR
    je .Lmo_read
    test rax, rax
    js .Lmo_read_err
    jz .Lmo_read_eof
    add qword ptr [rip + mock_file + SB_len], rax
    mov byte ptr [r14 + rax], 0
    jmp .Lmo_read
.Lmo_read_eof:
    mov edi, r13d
    call os_close
    # magic: len >= 6 and buf[0..6) == "FWIR1\n"
    mov rsi, [rip + mock_file + SB_len]
    cmp rsi, 6
    jb .Lmo_bad
    mov rdi, [rip + mock_file + SB_ptr]
    lea rsi, [rip + .Lfwir1]
    mov edx, 6
    call memeq
    test eax, eax
    jz .Lmo_bad
    # records: u8 dir; u32 len; payload
    mov rbx, 6
    xor r15d, r15d
.Lmo_parse:
    mov rax, [rip + mock_file + SB_len]
    cmp rbx, rax
    jae .Lmo_ok
    sub rax, rbx
    cmp rax, 5
    jb .Lmo_bad                        # truncated record header
    cmp r15, MOCK_MAX_RECS
    jae .Lmo_big
    mov rdi, [rip + mock_file + SB_ptr]
    movzx ecx, byte ptr [rdi + rbx]
    mov eax, dword ptr [rdi + rbx + 1]
    lea rdx, [rbx + 5]                 # payload offset
    mov r8, r15
    shl r8, 4
    lea r9, [rip + mock_recs]
    add r9, r8
    mov [r9 + MOCK_REC_OFF], rdx
    mov [r9 + MOCK_REC_LEN], eax
    mov [r9 + MOCK_REC_DIR], cl
    add rdx, rax
    cmp rdx, [rip + mock_file + SB_len]
    ja .Lmo_bad                        # truncated payload
    mov rbx, rdx
    inc r15
    jmp .Lmo_parse
.Lmo_ok:
    mov [rip + mock_nrecs], r15
    mov qword ptr [rip + mock_cur], 0
    mov qword ptr [rip + mock_off], 0
    xor eax, eax
    EPILOGUE
.Lmo_bad:
    call mock_free
    mov rax, -EINVAL
    EPILOGUE
.Lmo_big:
    call mock_free
    mov rax, -E2BIG
    EPILOGUE
.Lmo_read_err:
    mov r14, rax
    mov edi, r13d
    call os_close
    call mock_free
    mov rax, r14
    EPILOGUE
.Lmo_out:
    EPILOGUE

# mock_free(): release the replay buffer, the record index and the capture.
FN mock_free
    PROLOGUE 0
    lea rdi, [rip + mock_file]
    call sb_free
    lea rdi, [rip + mock_cap]
    call sb_free
    mov qword ptr [rip + mock_nrecs], 0
    mov qword ptr [rip + mock_cur], 0
    mov qword ptr [rip + mock_off], 0
    xor eax, eax
    EPILOGUE

# mock_sent() -> rax ptr, rdx len
FN mock_sent
    mov rax, [rip + mock_cap + SB_ptr]
    mov rdx, [rip + mock_cap + SB_len]
    ret

# ---------------------------------------------------------------- net backend
FN net_init
    xor eax, eax
    ret

FN net_socket
    mov eax, MOCK_FD
    ret

FN net_connect
    xor eax, eax
    ret

FN net_connect_result
    xor eax, eax
    ret

# net_send(fd, ptr, len) -> len (appends to the capture)
FN net_send
    PROLOGUE 0
    mov rbx, rdx
    lea rdi, [rip + mock_cap]
    call sb_push
    mov rax, rbx
    EPILOGUE

# net_recv(fd, ptr, len) -> n | 0 (eof): at most the current dir=1 record.
FN net_recv
    PROLOGUE 0
    mov rbx, rsi
    mov r12, rdx
    test r12, r12
    jz .Lmr_zero
.Lmr_next:
    mov rax, [rip + mock_cur]
    cmp rax, [rip + mock_nrecs]
    jae .Lmr_zero
    mov rcx, rax
    shl rcx, 4
    lea rdx, [rip + mock_recs]
    add rdx, rcx
    movzx ecx, byte ptr [rdx + MOCK_REC_DIR]
    test cl, cl
    jnz .Lmr_have                     # dir=0 records are not replayed
    inc qword ptr [rip + mock_cur]
    mov qword ptr [rip + mock_off], 0
    jmp .Lmr_next
.Lmr_have:
    mov r13, rdx
    mov r14, [r13 + MOCK_REC_OFF]
    mov r15d, dword ptr [r13 + MOCK_REC_LEN]
    mov rax, [rip + mock_off]
    cmp rax, r15
    jb .Lmr_copy
    inc qword ptr [rip + mock_cur]
    mov qword ptr [rip + mock_off], 0
    jmp .Lmr_next
.Lmr_copy:
    mov rcx, r15
    sub rcx, rax
    cmp rcx, r12
    cmova rcx, r12
    mov r12, rcx                       # n
    mov rsi, [rip + mock_file + SB_ptr]
    add rsi, r14
    add rsi, rax
    mov rdi, rbx
    mov rdx, rcx
    call memcpy
    add [rip + mock_off], r12
    mov rax, r12
    EPILOGUE
.Lmr_zero:
    xor eax, eax
    EPILOGUE

FN net_close
    xor eax, eax
    ret

FN net_shutdown
    xor eax, eax
    ret

# net_dns(host, out_ip4, deadline) -> 0; always 127.0.0.1
FN net_dns
    mov dword ptr [rsi], 0x0100007f
    xor eax, eax
    ret

FN net_is_ip4
    mov eax, 1
    ret

# ---------------------------------------------------------------- tls passthrough
# tls_new(host, port, opts) -> conn | 0
FN tls_new
    PROLOGUE 0
    mov edi, 32
    call mem_alloc
    movabs rdx, MOCK_TLS_MAGIC
    mov [rax], rdx
    EPILOGUE

# tls_set_fd(conn, fd): accepted for callers that set the fd explicitly.
FN tls_set_fd
    xor eax, eax
    ret

FN tls_handshake
    xor eax, eax
    ret

FN tls_read
    mov edi, MOCK_FD
    jmp net_recv

FN tls_write
    mov edi, MOCK_FD
    jmp net_send

FN tls_close
    PROLOGUE 0
    call mem_free
    xor eax, eax
    EPILOGUE

FN tls_pending
    xor eax, eax
    ret

FN tls_want
    xor eax, eax
    ret

FN tls_last_error
    xor eax, eax
    ret

FN tls_fd
    mov eax, MOCK_FD
    ret
