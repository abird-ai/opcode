.include "opcode.inc"
.include "tui/status.inc"
# status_abi_test: the built-in status provider is an ordinary provider and
# must preserve the callee-saved registers across the callback.  The test sets
# sentinels, calls status_builtin_provider directly, and checks that rbx, r12,
# r13 (and r14/r15) survive.  Golden: tests/data/status_abi_test.expected

.bss
.p2align 4
out:   .zero SV_SIZE * 8
arena: .zero STATUS_ARENA_CAP

.section .rodata
s_ok:   .asciz "status provider preserves callee-saved ok\n"
s_fail: .asciz "FAIL status provider abi\n"

.text
print:
    push rdi
    call strlen
    pop rdi
    mov rdx, rax
    mov rsi, rdi
    mov edi, 1
    jmp write_all

FN opcode_main
    PROLOGUE 16
    mov rbx, 0x1111111111111111
    mov r12, 0x2222222222222222
    mov r13, 0x3333333333333333
    mov r14, 0x4444444444444444
    mov r15, 0x5555555555555555
    lea rsi, [rip + out]
    mov edx, 8
    lea rcx, [rip + arena]
    mov r8d, STATUS_ARENA_CAP
    xor edi, edi
    call status_builtin_provider
    mov rax, 0x1111111111111111
    cmp rbx, rax
    jne .Lfail
    mov rax, 0x2222222222222222
    cmp r12, rax
    jne .Lfail
    mov rax, 0x3333333333333333
    cmp r13, rax
    jne .Lfail
    mov rax, 0x4444444444444444
    cmp r14, rax
    jne .Lfail
    mov rax, 0x5555555555555555
    cmp r15, rax
    jne .Lfail
    lea rdi, [rip + s_ok]
    call print
    xor eax, eax
    EPILOGUE
.Lfail:
    lea rdi, [rip + s_fail]
    call print
    mov eax, 1
    EPILOGUE
