.include "opcode.inc"
.include "core/core.inc"
# agent_abort_test: an aborted run must reach the shell.
#
#   agent_handle_abort tears the transport down and, with the provider's
#   PV_finish out of the picture, must emit SE_DONE with SR_ABORTED to the UI
#   hook exactly once.  A turn whose done flag is already set emits nothing.
#   Golden: agent_abort_test.expected

.bss
.p2align 4
rec_n: .quad 0
rec_a: .quad 0

.section .rodata
.Lnl:    .asciz "\n"
.Lp_n:   .asciz "done: "
.Lp_a:   .asciz "stop: "
.Lok:    .asciz "agent abort ok\n"
.Lfail_msg:  .asciz "agent abort FAIL\n"

.text

print:
    push rdi
    call strlen
    pop rdi
    mov rdx, rax
    mov rsi, rdi
    mov edi, 1
    jmp write_all

# print_n(ptr, len)
print_n:
    mov rdx, rsi
    mov rsi, rdi
    mov edi, 1
    jmp write_all

# p_snum(label, value): "<label><value>\n"
p_snum:
    push rbx
    push r12
    sub rsp, 40
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rbx
    call print
    mov rax, r12
    test rax, rax
    jns 1f
    mov byte ptr [rsp], '-'
    mov edi, 1
    lea rsi, [rsp]
    mov edx, 1
    call write_all
    mov rax, r12
    neg rax
1:  lea rdi, [rsp]
    mov rsi, rax
    call fmt_u64
    lea rdi, [rsp]
    mov rsi, rax
    call print_n
    lea rdi, [rip + .Lnl]
    call print
    add rsp, 40
    pop r12
    pop rbx
    ret

# ui_rec(ctx, event, a, b): count SE_DONE and remember its stop reason.
ui_rec:
    cmp esi, SE_DONE
    jne 1f
    inc qword ptr [rip + rec_n]
    mov [rip + rec_a], rdx
1:  ret

FN opcode_main
    PROLOGUE 16
    lea rax, [rip + ui_rec]
    mov [rip + g_agent_ui_fn], rax
    xor eax, eax
    mov [rip + g_agent_ui_ctx], rax
    call agent_handle_abort
    call agent_handle_abort          # guarded: no second SE_DONE
    mov rsi, [rip + rec_n]
    lea rdi, [rip + .Lp_n]
    call p_snum
    mov rsi, [rip + rec_a]
    lea rdi, [rip + .Lp_a]
    call p_snum
    cmp qword ptr [rip + rec_n], 1
    jne .Lfail
    cmp qword ptr [rip + rec_a], SR_ABORTED
    jne .Lfail
    lea rdi, [rip + .Lok]
    call print
    xor eax, eax
    EPILOGUE
.Lfail:
    lea rdi, [rip + .Lfail_msg]
    call print
    mov eax, 1
    EPILOGUE
