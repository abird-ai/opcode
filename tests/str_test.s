# str_test: memcpy, strlen, str_eq, str_starts, str_find, parse_u64, fmt_u64
.include "opcode.inc"

.bss
.p2align 3
buf: .zero 64

.section .rodata
.s1:          .asciz "abc"
.hay:         .asciz "hello"
.needle:      .asciz "ll"
.pfx:         .asciz "he"
.num:         .asciz "12345"
.m_memcpy:    .asciz "memcpy ok\n"
.m_strlen:    .asciz "strlen ok\n"
.m_eq:        .asciz "eq ok\n"
.m_starts:    .asciz "starts ok\n"
.m_find:      .asciz "find ok\n"
.m_parse:     .asciz "parse ok\n"
.m_fmt:       .asciz "fmt ok\n"
.m_fail:      .asciz "FAIL str\n"
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

FN opcode_main
    PROLOGUE
    # memcpy "abc\0"
    lea rdi, [rip + buf]
    lea rsi, [rip + .s1]
    mov edx, 4
    call memcpy
    lea rdi, [rip + buf]
    lea rsi, [rip + .s1]
    mov edx, 4
    call memeq
    test eax, eax
    jz .Lfail
    lea rdi, [rip + .m_memcpy]
    call print

    # strlen("hello") == 5
    lea rdi, [rip + .hay]
    call strlen
    cmp eax, 5
    jne .Lfail
    lea rdi, [rip + .m_strlen]
    call print

    # str_eq("hello",5,"hello",5)
    lea rdi, [rip + .hay]
    mov esi, 5
    lea rdx, [rip + .hay]
    mov ecx, 5
    call str_eq
    cmp eax, 1
    jne .Lfail
    lea rdi, [rip + .m_eq]
    call print

    # str_starts("hello",5,"he",2)
    lea rdi, [rip + .hay]
    mov esi, 5
    lea rdx, [rip + .pfx]
    mov ecx, 2
    call str_starts
    cmp eax, 1
    jne .Lfail
    lea rdi, [rip + .m_starts]
    call print

    # str_find("hello",5,"ll",2) == 2
    lea rdi, [rip + .hay]
    mov esi, 5
    lea rdx, [rip + .needle]
    mov ecx, 2
    call str_find
    cmp eax, 2
    jne .Lfail
    lea rdi, [rip + .m_find]
    call print

    # parse_u64("12345",5) == 12345, consumed 5
    lea rdi, [rip + .num]
    mov esi, 5
    call parse_u64
    cmp rax, 12345
    jne .Lfail
    cmp rdx, 5
    jne .Lfail
    lea rdi, [rip + .m_parse]
    call print

    # fmt_u64(buf, 42) == 2, "42"
    lea rdi, [rip + buf]
    mov esi, 42
    call fmt_u64
    cmp eax, 2
    jne .Lfail
    cmp byte ptr [rip + buf], '4'
    jne .Lfail
    cmp byte ptr [rip + buf + 1], '2'
    jne .Lfail
    lea rdi, [rip + .m_fmt]
    call print

    xor eax, eax
    EPILOGUE
.Lfail:
    lea rdi, [rip + .m_fail]
    call print
    mov eax, 1
    EPILOGUE
