.include "opcode.inc"
.include "core/core.inc"
# diff_leak_test: a diff that hits the line cap must free every internal
# allocation before returning.  The truncation path used to EPILOGUE directly
# (skipping .Ld_free), leaking the line records, the LCS rows and the op array
# on every capped edit.  g_mem_live must return to its pre-call value.
# Golden: tests/data/diff_leak_test.expected

.bss
.p2align 3
outsb:    .zero SB_SIZE
baseline: .zero 8

.section .rodata
.Llabel: .asciz "build/diff_leak.tmp"
# 60 wholly different lines: the LCS allocates both line tables, the two
# rolling rows, the direction bits and the op array, then truncates mid-hunk.
.Lold:
         .rept 60
         .ascii "aaaaaaaa\n"
         .endr
.Lold_end:
.Lnew:
         .rept 60
         .ascii "bbbbbbbb\n"
         .endr
.Lnew_end:
.Ltrunc: .asciz "[diff truncated]"
.Lok:    .asciz "diff leak ok\n"
.Lbad:   .asciz "FAIL diff leak\n"
.Lbad2:  .asciz "FAIL diff not truncated\n"

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
    mov rax, [rip + g_mem_live]
    mov [rip + baseline], rax

    # capped diff: max_lines = 3 (two header lines + one hunk header)
    lea rdi, [rip + .Llabel]
    lea rsi, [rip + .Lold]
    mov rdx, .Lold_end - .Lold
    lea rcx, [rip + .Lnew]
    mov r8, .Lnew_end - .Lnew
    lea r9, [rip + outsb]
    sub rsp, 16
    mov qword ptr [rsp], 3
    call diff_unified
    add rsp, 16

    # the cap must actually have been hit (otherwise the leak path is untested)
    lea rdi, [rip + .Ltrunc]
    call strlen
    mov rcx, rax
    mov rdi, [rip + outsb + SB_ptr]
    mov rsi, [rip + outsb + SB_len]
    lea rdx, [rip + .Ltrunc]
    call str_find
    cmp rax, -1
    je .Lnot_trunc

    lea rdi, [rip + outsb]
    call sb_free
    mov rax, [rip + g_mem_live]
    cmp rax, [rip + baseline]
    jne .Lleak

    lea rdi, [rip + .Lok]
    call print
    xor eax, eax
    EPILOGUE
.Lnot_trunc:
    lea rdi, [rip + .Lbad2]
    call print
    mov eax, 1
    EPILOGUE
.Lleak:
    lea rdi, [rip + .Lbad]
    call print
    mov eax, 1
    EPILOGUE
