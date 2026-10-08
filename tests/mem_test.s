# mem_test: allocator, SB, VEC
.include "opcode.inc"

.bss
.p2align 3
sb:      .zero SB_SIZE
vec:     .zero VEC_SIZE

.section .rodata
.msg_hello: .asciz "hello"
.m_alloc: .asciz "mem alloc ok\n"
.m_cap:   .asciz "mem cap ok\n"
.m_zero:  .asciz "mem zero ok\n"
.m_reuse: .asciz "mem reuse ok\n"
.m_sb:    .asciz "sb ok\n"
.m_vec:   .asciz "vec ok\n"
.m_fail:  .asciz "FAIL mem\n"
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
    # p = mem_alloc(100)
    mov edi, 100
    call mem_alloc
    mov r12, rax
    test r12, r12
    jz .Lfail
    lea rdi, [rip + .m_alloc]
    call print

    # mem_capacity(p) >= 100
    mov rdi, r12
    call mem_capacity
    cmp rax, 100
    jb .Lfail
    lea rdi, [rip + .m_cap]
    call print

    # contents zeroed
    xor ecx, ecx
1:  cmp ecx, 100
    jae 2f
    cmp byte ptr [r12 + rcx], 0
    jne .Lfail
    inc ecx
    jmp 1b
2:  lea rdi, [rip + .m_zero]
    call print

    # free + alloc same class returns zeroed memory
    mov edi, 10
    call mem_alloc
    mov r13, rax
    mov byte ptr [r13], 7
    mov rdi, r13
    call mem_free
    mov edi, 10
    call mem_alloc
    cmp byte ptr [rax], 0
    jne .Lfail
    lea rdi, [rip + .m_reuse]
    call print

    # sb push "hello" + '!'
    lea rdi, [rip + sb]
    lea rsi, [rip + .msg_hello]
    call sb_push_cstr
    lea rdi, [rip + sb]
    mov esi, '!'
    call sb_push_byte
    cmp qword ptr [rip + sb + SB_len], 6
    jne .Lfail
    mov rax, [rip + sb + SB_ptr]
    cmp byte ptr [rax], 'h'
    jne .Lfail
    cmp byte ptr [rax + 5], '!'
    jne .Lfail
    cmp byte ptr [rax + 6], 0
    jne .Lfail
    lea rdi, [rip + .m_sb]
    call print

    # vec push 3 items of 8
    lea rdi, [rip + vec]
    mov esi, 8
    call vec_push
    mov qword ptr [rax], 11
    lea rdi, [rip + vec]
    mov esi, 8
    call vec_push
    mov qword ptr [rax], 22
    lea rdi, [rip + vec]
    mov esi, 8
    call vec_push
    mov qword ptr [rax], 33
    cmp qword ptr [rip + vec + VEC_len], 3
    jne .Lfail
    mov rax, [rip + vec + VEC_ptr]
    cmp qword ptr [rax], 11
    jne .Lfail
    cmp qword ptr [rax + 8], 22
    jne .Lfail
    cmp qword ptr [rax + 16], 33
    jne .Lfail
    lea rdi, [rip + .m_vec]
    call print

    xor eax, eax
    EPILOGUE
.Lfail:
    lea rdi, [rip + .m_fail]
    call print
    mov eax, 1
    EPILOGUE
