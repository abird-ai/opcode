.include "opcode.inc"
.include "core/core.inc"
# static plugin loader test: build/plugins.s has exactly the example_c plugin.
# Golden output: tests/data/plugin_test.expected

.section .rodata
.Lok_loaded: .asciz "plugin loaded ok"
.Lok_tool:   .asciz "plugin tool ok"
.Ldone:      .asciz "plugin done"
.Lfail_msg:  .asciz "FAIL: plugin_test"
.Lhello:     .asciz "hello"
.Lnl:        .byte 10

.text

# print_line(cstr): write the string + newline to stdout
print_line:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov rdi, rbx
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
    PROLOGUE
    call tools_init
    call plugins_init
    cmp rax, 1
    jne .Lfail
    lea rdi, [rip + .Lok_loaded]
    call print_line

    lea rdi, [rip + .Lhello]
    call tools_find
    test rax, rax
    jz .Lfail
    lea rdi, [rip + .Lok_tool]
    call print_line

    lea rdi, [rip + .Ldone]
    call print_line
    xor eax, eax
    EPILOGUE
.Lfail:
    lea rdi, [rip + .Lfail_msg]
    call print_line
    mov eax, 1
    EPILOGUE
