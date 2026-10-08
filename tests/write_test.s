.include "opcode.inc"
.include "core/core.inc"
# write tool integration test.
# Golden output: tests/data/write_test.expected

.bss
.p2align 3
t_job:   .zero J_SIZE
t_out:   .zero SB_SIZE
readbuf: .zero 8192

.section .rodata
.Lnl:        .asciz "\n"
.Lwrite:     .asciz "write"
.Lfail_msg:  .asciz "FAIL: write_test"
.Lok:        .asciz "write ok"
.Lok_nested: .asciz "write nested ok"
.Ldone:      .asciz "write done"

.Lf1:      .asciz "build/write_test.tmp"
.Lc1:      .ascii "hello world\n"
.Lc1e:
.La1:      .asciz "{\"path\":\"build/write_test.tmp\",\"content\":\"hello world\\n\"}"
.Lneed_len: .asciz "12 bytes"

.Lf2:      .asciz "build/write_test_dir/a/b/c.txt"
.Lc2:      .ascii "nested\n"
.Lc2e:
.La2:      .asciz "{\"path\":\"build/write_test_dir/a/b/c.txt\",\"content\":\"nested\\n\"}"
.Lc2b:     .ascii "again\n"
.Lc2be:
.La2b:     .asciz "{\"path\":\"build/write_test_dir/a/b/c.txt\",\"content\":\"again\\n\"}"

.text

# print_line(cstr)
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

# sb_has(sb, needle cstr) -> 1 | 0
sb_has:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    mov rdi, r12
    call strlen
    mov rcx, rax
    mov rdi, [rbx + SB_ptr]
    test rdi, rdi
    jz 1f
    mov rsi, [rbx + SB_len]
    mov rdx, r12
    call str_find
    cmp rax, -1
    setne al
    movzx eax, al
    jmp 2f
1:  xor eax, eax
2:  add rsp, 8
    pop r12
    pop rbx
    ret

# file_eq(path, ptr, len) -> 1 | 0
file_eq:
    PROLOGUE 32
    mov [rsp], rsi
    mov [rsp + 8], rdx
    xor esi, esi
    xor edx, edx
    call os_open
    test rax, rax
    js .Lfe_fail
    mov [rsp + 16], rax
    mov edi, eax
    lea rsi, [rip + readbuf]
    mov edx, 8192
    call os_read
    mov r12, rax
    mov edi, [rsp + 16]
    call os_close
    test r12, r12
    js .Lfe_fail
    cmp r12, [rsp + 8]
    jne .Lfe_fail
    lea rdi, [rip + readbuf]
    mov rsi, [rsp]
    mov rdx, r12
    call memeq
    EPILOGUE
.Lfe_fail:
    xor eax, eax
    EPILOGUE

# run_write(args cstr) -> 0
run_write:
    PROLOGUE
    mov r12, rdi
    lea rdi, [rip + t_job]
    xor esi, esi
    mov edx, J_SIZE
    call memset
    lea rdi, [rip + t_out]
    call sb_clear
    lea rax, [rip + t_out]
    lea rcx, [rip + t_job]
    mov [rcx + J_out], rax
    mov [rcx + J_args], r12
    mov qword ptr [rcx + J_fd], -1
    mov dword ptr [rcx + J_state], JS_NEW
    lea rdi, [rip + .Lwrite]
    call tools_find
    test rax, rax
    jz .Lrw_fail
    lea rcx, [rip + t_job]
    mov [rcx + J_tool], rax
    mov rdi, rcx
    call [rax + TL_exec]
    xor eax, eax
    EPILOGUE
.Lrw_fail:
    mov eax, 1
    EPILOGUE

FN opcode_main
    PROLOGUE
    call edit_write_tool_init

    # ---- write a plain file ----
    lea rdi, [rip + .La1]
    call run_write
    lea rdi, [rip + .Lf1]
    lea rsi, [rip + .Lc1]
    mov edx, .Lc1e - .Lc1
    call file_eq
    test eax, eax
    jz .Lfail
    lea rdi, [rip + t_out]
    lea rsi, [rip + .Lneed_len]
    call sb_has
    test eax, eax
    jz .Lfail
    lea rdi, [rip + .Lok]
    call print_line

    # ---- create parent directories, then replace the same file ----
    lea rdi, [rip + .La2]
    call run_write
    lea rdi, [rip + .Lf2]
    lea rsi, [rip + .Lc2]
    mov edx, .Lc2e - .Lc2
    call file_eq
    test eax, eax
    jz .Lfail
    lea rdi, [rip + .La2b]
    call run_write
    lea rdi, [rip + .Lf2]
    lea rsi, [rip + .Lc2b]
    mov edx, .Lc2be - .Lc2b
    call file_eq
    test eax, eax
    jz .Lfail
    lea rdi, [rip + .Lok_nested]
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
