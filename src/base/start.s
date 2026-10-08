.include "opcode.inc"
# opcode entry point: align the stack, hand the initial stack pointer to os_init,
# run opcode_main and exit with its status.

FN _start
    mov rdi, rsp
    and rsp, -16
    call os_init
    call opcode_main
    mov edi, eax
    jmp os_exit
