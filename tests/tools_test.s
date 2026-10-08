.include "opcode.inc"
.include "core/core.inc"
# tools + read + bash integration test.
# Golden output: tests/data/tools_test.expected

.bss
.p2align 3
t_job: .zero J_SIZE
t_out: .zero SB_SIZE

.section .rodata
.Lnl:          .asciz "\n"
.Lfail_msg:    .asciz "FAIL: tools_test"
.Lok_count:    .asciz "tools count ok"
.Lok_read:     .asciz "read ok"
.Lok_missing:  .asciz "read missing ok"
.Lok_offset:   .asciz "read offset ok"
.Lok_limit:    .asciz "read limit ok"
.Lok_bash:     .asciz "bash ok"
.Lok_exit:     .asciz "bash exit ok"
.Ldone:        .asciz "tools done"

.Lread:        .asciz "read"
.Lbash:        .asciz "bash"
.Ltmp:         .asciz "build/tools_test.tmp"
.Lfile:        .ascii "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n"
.Lfile_end:

.Largs_read:    .asciz "{\"path\":\"build/tools_test.tmp\"}"
.Largs_missing: .asciz "{\"path\":\"build/tools_test.tmp.nope\"}"
.Largs_offset:  .asciz "{\"path\":\"build/tools_test.tmp\",\"offset\":9,\"limit\":1}"
.Largs_limit:   .asciz "{\"path\":\"build/tools_test.tmp\",\"limit\":3}"
.Largs_bash:    .asciz "{\"command\":\"echo hi\"}"

.Lneed_1:      .asciz "1\t"
.Lneed_10:     .asciz "10\t"
.Lneed_4:      .asciz "4\t"
.Lneed_off3:   .asciz "offset=3"
.Lneed_cannot: .asciz "cannot open"
.Lneed_hi:     .asciz "hi"
.Lneed_exit:   .asciz "exit 0"

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

# run_tool(name cstr, args cstr) -> TL_exec result; fills t_job / t_out
run_tool:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
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
    mov rdi, rbx
    call tools_find
    lea rcx, [rip + t_job]
    mov [rcx + J_tool], rax
    mov rdi, rcx
    call [rax + TL_exec]
    EPILOGUE

# drive_bash(): poll + drain t_job.J_fd into t_out until EOF
drive_bash:
    PROLOGUE 16
    mov edi, 65536
    call mem_alloc
    mov r12, rax
    mov r13d, 100
.Ldb_poll:
    mov rax, [rip + t_job + J_fd]
    mov [rsp], eax
    mov word ptr [rsp + 4], POLLIN
    mov word ptr [rsp + 6], 0
    mov rdi, rsp
    mov esi, 1
    mov edx, 200
    call os_poll
    test rax, rax
    js .Ldb_stop
    jz .Ldb_next
.Ldb_read:
    mov edi, [rip + t_job + J_fd]
    mov rsi, r12
    mov edx, 65536
    call os_read
    test rax, rax
    jg .Ldb_data
    js .Ldb_eagain
    jmp .Ldb_stop                  # EOF
.Ldb_eagain:
    cmp rax, -EAGAIN
    je .Ldb_poll
    jmp .Ldb_stop
.Ldb_data:
    lea rdi, [rip + t_out]
    mov rsi, r12
    mov rdx, rax
    call sb_push
    jmp .Ldb_read
.Ldb_next:
    dec r13d
    jnz .Ldb_poll
.Ldb_stop:
    mov rdi, r12
    call mem_free
    EPILOGUE

FN opcode_main
    PROLOGUE
    call tools_init
    call tools_count
    cmp rax, 7
    jne .Lfail
    lea rdi, [rip + .Lread]
    call tools_find
    test rax, rax
    jz .Lfail
    lea rdi, [rip + .Lbash]
    call tools_find
    test rax, rax
    jz .Lfail
    call tools_active
    cmp qword ptr [rax + VEC_len], 7
    jne .Lfail
    lea rdi, [rip + .Lok_count]
    call print_line

    # ---- temp file with 10 numbered lines ----
    lea rdi, [rip + .Ltmp]
    mov esi, O_WRONLY | O_CREAT | O_TRUNC
    mov edx, 0644
    call os_open
    test rax, rax
    js .Lfail
    mov r12d, eax
    mov edi, r12d
    lea rsi, [rip + .Lfile]
    mov edx, .Lfile_end - .Lfile
    call os_write
    mov edi, r12d
    call os_close

    # ---- read ok ----
    lea rdi, [rip + .Lread]
    lea rsi, [rip + .Largs_read]
    call run_tool
    cmp dword ptr [rip + t_job + J_state], JS_DONE
    jne .Lfail
    lea rdi, [rip + t_out]
    lea rsi, [rip + .Lneed_1]
    call sb_has
    test eax, eax
    jz .Lfail
    lea rdi, [rip + t_out]
    lea rsi, [rip + .Lneed_10]
    call sb_has
    test eax, eax
    jz .Lfail
    lea rdi, [rip + .Lok_read]
    call print_line

    # ---- read missing ----
    lea rdi, [rip + .Lread]
    lea rsi, [rip + .Largs_missing]
    call run_tool
    lea rdi, [rip + t_out]
    lea rsi, [rip + .Lneed_cannot]
    call sb_has
    test eax, eax
    jz .Lfail
    lea rdi, [rip + .Lok_missing]
    call print_line

    # ---- read offset ----
    lea rdi, [rip + .Lread]
    lea rsi, [rip + .Largs_offset]
    call run_tool
    lea rdi, [rip + t_out]
    lea rsi, [rip + .Lneed_10]
    call sb_has
    test eax, eax
    jz .Lfail
    lea rdi, [rip + .Lok_offset]
    call print_line

    # ---- read limit: limit=3 must cap at 3 lines and hint offset=3 ----
    lea rdi, [rip + .Lread]
    lea rsi, [rip + .Largs_limit]
    call run_tool
    lea rdi, [rip + t_out]
    lea rsi, [rip + .Lneed_4]
    call sb_has
    test eax, eax
    jnz .Lfail                  # line 4 must not be present
    lea rdi, [rip + t_out]
    lea rsi, [rip + .Lneed_off3]
    call sb_has
    test eax, eax
    jz .Lfail
    lea rdi, [rip + .Lok_limit]
    call print_line

    # ---- bash: exec, drain the pipe, finish ----
    lea rdi, [rip + .Lbash]
    lea rsi, [rip + .Largs_bash]
    call run_tool
    test eax, eax
    js .Lfail
    call drive_bash
    lea rdi, [rip + .Lbash]
    call tools_find
    test rax, rax
    jz .Lfail
    mov rax, [rax + TL_finish]
    test rax, rax
    jz .Lfail
    lea rdi, [rip + t_job]
    call rax
    lea rdi, [rip + t_out]
    lea rsi, [rip + .Lneed_hi]
    call sb_has
    mov r12d, eax
    lea rdi, [rip + t_out]
    lea rsi, [rip + .Lneed_exit]
    call sb_has
    mov r13d, eax
    test r12d, r12d
    jz .Lfail
    test r13d, r13d
    jz .Lfail
    lea rdi, [rip + .Lok_bash]
    call print_line
    lea rdi, [rip + .Lok_exit]
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
