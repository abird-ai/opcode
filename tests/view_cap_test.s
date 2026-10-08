.include "opcode.inc"
.include "core/core.inc"
# View row-cap regression: appending past V_MAX (20000) rows must saturate and
# never write past the row buffer (the old view_new_row left Vrows short and
# view_append_span kept writing at a growing Vlast).
.text

print_line:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    call strlen
    mov rdx, rax
    mov rsi, rbx
    mov edi, 1
    call write_all
    lea rsi, [rip + .Lnl]
    mov edx, 1
    mov edi, 1
    call write_all
    add rsp, 8
    pop r12
    pop rbx
    ret

.bss
.p2align 3
v_view: .zero 64

.section .rodata
.Lnl:    .asciz "\n"
.Lten:   .ascii "aaaaaaaaaa"
.Lok:    .asciz "view cap ok"
.Lbadmsg:.asciz "FAIL: view_cap_test"

.text
FN opcode_main
    PROLOGUE
    lea rdi, [rip + v_view]
    mov esi, 40
    call view_init
    xor r12d, r12d
1:  cmp r12d, 25000
    jae 2f
    lea rdi, [rip + v_view]
    mov esi, 1
    lea rdx, [rip + .Lten]
    mov ecx, 10
    call view_append_span
    lea rdi, [rip + v_view]
    call view_break
    inc r12d
    jmp 1b
2:  lea rdi, [rip + v_view]
    call view_total
    cmp eax, 20000
    ja .Lbad
    lea rdi, [rip + v_view]
    xor esi, esi
    call view_row_len
    cmp eax, 10
    jne .Lbad
    lea rdi, [rip + .Lok]
    call print_line
    lea rdi, [rip + v_view]
    call view_free
    xor eax, eax
    EPILOGUE
.Lbad:
    lea rdi, [rip + .Lbadmsg]
    call print_line
    lea rdi, [rip + v_view]
    call view_free
    mov eax, 1
    EPILOGUE
