.include "opcode.inc"
.include "tui/markdown.inc"
# md_leak_test: repeatedly re-parsing the trailing incomplete block must not
# leak.  Every append frees and rebuilds the last block's row VEC; the old code
# reset the VEC length but kept (and then lost) its backing, so each append
# leaked one allocation.  g_mem_live must return to its post-init value after
# md_free.  Golden: tests/data/md_leak_test.expected

.bss
.p2align 3
m:        .zero MDK_SIZE
baseline: .zero 8

.section .rodata
.Lchunk: .ascii "word "
.Lchunk_end:
.Lok:    .asciz "markdown leak ok\n"
.Lbad:   .asciz "FAIL markdown leak\n"

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
    lea rdi, [rip + m]
    mov esi, 40
    call md_init
    mov rax, [rip + g_mem_live]
    mov [rip + baseline], rax

    # 200 appends of a word with no newline: the paragraph never completes, so
    # the trailing block is freed and re-parsed on every call.
    xor r12d, r12d
.Lloop:
    cmp r12d, 200
    jae .Ldone
    lea rdi, [rip + m]
    lea rsi, [rip + .Lchunk]
    mov edx, .Lchunk_end - .Lchunk
    call md_append
    inc r12d
    jmp .Lloop
.Ldone:
    lea rdi, [rip + m]
    call md_free
    mov rax, [rip + g_mem_live]
    cmp rax, [rip + baseline]
    jne .Lleak

    lea rdi, [rip + .Lok]
    call print
    xor eax, eax
    EPILOGUE
.Lleak:
    lea rdi, [rip + .Lbad]
    call print
    mov eax, 1
    EPILOGUE
