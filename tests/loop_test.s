# loop_test: watch table + loop_poll dispatch, using a real /dev/null fd.
.include "opcode.inc"

.equ MAGIC_CTX, 0x5a5a1234

.bss
.p2align 3
rec_fd:      .quad 0
rec_revents: .quad 0
rec_ctx:     .quad 0
rec_calls:   .quad 0

.section .rodata
.s_devnull: .asciz "/dev/null"
.m_watch:   .asciz "watch ok\n"
.m_count:   .asciz "count ok\n"
.m_events:  .asciz "events ok\n"
.m_remove:  .asciz "remove ok\n"
.m_empty:   .asciz "empty ok\n"
.m_missing: .asciz "missing ok\n"
.m_fail:    .asciz "FAIL loop\n"
.text

# cb(fd, revents, ctx): record the call into .bss.
cb:
    mov [rip + rec_fd], rdi
    movzx eax, si
    mov [rip + rec_revents], rax
    mov [rip + rec_ctx], rdx
    inc qword ptr [rip + rec_calls]
    ret

# print(cstr)
print:
    push rdi
    call strlen
    pop rdi
    mov rdx, rax
    mov rsi, rdi
    mov edi, 1
    jmp write_all

FN opcode_main
    PROLOGUE 0
    # fd = os_open("/dev/null", O_RDONLY, 0)
    lea rdi, [rip + .s_devnull]
    mov esi, O_RDONLY
    xor edx, edx
    call os_open
    test rax, rax
    js .Lfail
    mov r12, rax

    # watch_add(fd, POLLIN, cb, magic)
    mov rdi, r12
    mov esi, POLLIN
    lea rdx, [rip + cb]
    mov ecx, MAGIC_CTX
    call watch_add
    test rax, rax
    jnz .Lfail

    # loop_poll(0) calls cb once with (fd, POLLIN, magic)
    xor edi, edi
    call loop_poll
    cmp rax, 1
    jne .Lfail
    cmp qword ptr [rip + rec_calls], 1
    jne .Lfail
    cmp qword ptr [rip + rec_fd], r12
    jne .Lfail
    cmp qword ptr [rip + rec_revents], POLLIN
    jne .Lfail
    mov rax, MAGIC_CTX
    cmp qword ptr [rip + rec_ctx], rax
    jne .Lfail
    lea rdi, [rip + .m_watch]
    call print

    # watch_count() == 1
    call watch_count
    cmp rax, 1
    jne .Lfail
    lea rdi, [rip + .m_count]
    call print

    # watch_set_events: 0 for the live fd, -ENOENT for an unknown fd
    mov rdi, r12
    mov esi, POLLOUT
    call watch_set_events
    test rax, rax
    jnz .Lfail
    lea rdi, [r12 + 12345]
    mov esi, POLLOUT
    call watch_set_events
    cmp rax, -ENOENT
    jne .Lfail
    lea rdi, [rip + .m_events]
    call print

    # watch_remove(fd) == 0; watch_count() == 0
    mov rdi, r12
    call watch_remove
    test rax, rax
    jnz .Lfail
    call watch_count
    test rax, rax
    jnz .Lfail
    lea rdi, [rip + .m_remove]
    call print

    # loop_poll(0) == 0 with an empty table
    xor edi, edi
    call loop_poll
    test rax, rax
    jnz .Lfail
    lea rdi, [rip + .m_empty]
    call print

    # a second watch_remove(fd) is -ENOENT
    mov rdi, r12
    call watch_remove
    cmp rax, -ENOENT
    jne .Lfail
    lea rdi, [rip + .m_missing]
    call print

    mov rdi, r12
    call os_close
    xor eax, eax
    EPILOGUE
.Lfail:
    lea rdi, [rip + .m_fail]
    call print
    mov eax, 1
    EPILOGUE
