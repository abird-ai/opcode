.include "opcode.inc"
# SIGPIPE regression: os_init must ignore SIGPIPE, so writing to a pipe whose
# read end is closed returns -EPIPE instead of terminating the process. This
# guards the MCP client (and any future child-pipe writer) against a dead peer.
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

FN opcode_main
    PROLOGUE 8
    mov rdi, rsp
    call os_pipe
    test rax, rax
    js .Lfail
    mov edi, [rsp]              # close the read end
    call os_close
    mov edi, [rsp + 4]
    lea rsi, [rip + .Lmsg]
    mov edx, 1
    call os_write
    cmp rax, -EPIPE
    jne .Lfail
    lea rdi, [rip + .Lok]
    call print_line
    mov edi, [rsp + 4]
    call os_close
    xor eax, eax
    EPILOGUE
.Lfail:
    lea rdi, [rip + .Lbad]
    call print_line
    mov eax, 1
    EPILOGUE

.section .rodata
.Lmsg: .ascii "x"
.Lnl:  .asciz "\n"
.Lok:  .asciz "sigpipe ok"
.Lbad: .asciz "FAIL: sigpipe_test"
