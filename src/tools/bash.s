.include "opcode.inc"
.include "core/core.inc"
# bash tool: run "sh -lc <command>" with stdout+stderr captured through a
# non-blocking pipe. The agent loop drains J_fd into J_out and calls TL_finish
# at EOF; TL_finish reaps the child and appends the exit status.
# Contract: src/core/API.md.

.equ BASH_DEFAULT_TIMEOUT, 120
.equ BASH_MAX_TIMEOUT,     1800
.equ SIGKILL,              9

.section .rodata
.Lname:    .asciz "bash"
.Llabel:   .asciz "bash"
.Ldesc:    .asciz "Run a shell command with sh -lc; capture stdout and stderr and append the exit status."
.Lparams:  .asciz "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\",\"description\":\"Shell command to run\"},\"timeout\":{\"type\":\"integer\",\"description\":\"Timeout in seconds\"}},\"required\":[\"command\"]}"
.Lcommand: .asciz "command"
.Ltimeout_key: .asciz "timeout"
.Lsh:      .asciz "/bin/sh"
.Llc:      .asciz "-lc"
.Lerr_spawn: .asciz "error: cannot start command"
.Lbadargs: .asciz "error: invalid arguments"
.Lexit:    .asciz "[exit "
.Lsignal:  .asciz "[signal "
.Ltimeout: .asciz "[timed out]"
.Lbrk:     .asciz "]"

.section .data
.p2align 3
bash_tl:
    .quad .Lname
    .quad .Llabel
    .quad .Ldesc
    .quad .Lparams
    .long 0
    .long 0
    .quad bash_exec
    .quad bash_finish

.text

# bash_tool_init() -> 0 | -ENOSPC
FN bash_tool_init
    lea rdi, [rip + bash_tl]
    jmp tools_add

# bash_exec(job) -> 0
FN bash_exec
    PROLOGUE 48
    mov rbx, rdi                    # job
    mov rdi, [rbx + J_args]
    test rdi, rdi
    jz .Lbe_invalid
    call strlen
    mov rsi, rax
    mov rdi, [rbx + J_args]
    call json_parse
    test rax, rax
    jz .Lbe_invalid
    mov r13, rax
    mov rdi, r13
    lea rsi, [rip + .Lcommand]
    call json_get_cstr
    test rax, rax
    jz .Lbe_invalid
    mov r12, rax                    # command
    mov rdi, r13
    lea rsi, [rip + .Ltimeout_key]
    mov edx, BASH_DEFAULT_TIMEOUT
    call json_get_u64
    cmp rax, BASH_MAX_TIMEOUT
    jbe 1f
    mov eax, BASH_MAX_TIMEOUT
1:  mov r14, rax                    # timeout seconds (0 = no deadline)
    # argv = { "/bin/sh", "-lc", command, 0 }
    lea rax, [rip + .Lsh]
    mov [rsp], rax
    lea rax, [rip + .Llc]
    mov [rsp + 8], rax
    mov [rsp + 16], r12
    mov qword ptr [rsp + 24], 0
    # pipe; fds[0] is O_NONBLOCK, fds[1] blocking and inherited by the child
    lea rdi, [rsp + 32]
    call os_pipe
    test rax, rax
    js .Lbe_pipeerr
    # spawn with stdout = stderr = fds[1]
    lea rdi, [rsp]
    mov rsi, [rip + g_envp]
    xor edx, edx                    # cwd = inherit
    mov ecx, -1                     # stdin = inherit
    mov r8d, [rsp + 36]
    mov r9d, r8d
    sub rsp, 16
    mov qword ptr [rsp], 0          # ctty = 0
    call os_spawn
    add rsp, 16
    mov r15, rax                    # pid | -errno
    mov edi, [rsp + 36]             # parent closes the write end
    call os_close
    test r15, r15
    js .Lbe_spawnerr
    mov [rbx + J_pid], r15
    mov eax, [rsp + 32]
    cdqe
    mov [rbx + J_fd], rax
    mov dword ptr [rbx + J_state], JS_RUNNING
    test r14, r14
    jz .Lbe_nodeadline
    mov edi, CLOCK_MONOTONIC
    call os_now_ns
    xor edx, edx
    mov ecx, 1000000
    div rcx                         # ms
    imul r14, r14, 1000
    add rax, r14
    mov [rbx + J_deadline_ms], rax
    xor eax, eax
    EPILOGUE
.Lbe_nodeadline:
    mov qword ptr [rbx + J_deadline_ms], 0
    xor eax, eax
    EPILOGUE
.Lbe_pipeerr:
    mov rdi, rbx
    lea rsi, [rip + .Lerr_spawn]
    call tool_err
    xor eax, eax
    EPILOGUE
.Lbe_spawnerr:
    mov edi, [rsp + 32]
    call os_close
    mov rdi, rbx
    lea rsi, [rip + .Lerr_spawn]
    call tool_err
    xor eax, eax
    EPILOGUE
.Lbe_invalid:
    mov rdi, rbx
    lea rsi, [rip + .Lbadargs]
    call tool_err
    xor eax, eax
    EPILOGUE

# bf_sep(job): ensure the result buffer ends with a newline (no blank line).
# The child's stdout usually ends with one; the status marker should follow on
# the next line, not after a spurious empty line.
bf_sep:
    mov rdi, [rdi + J_out]
    mov rax, [rdi + SB_len]
    test rax, rax
    jz 1f
    mov rcx, [rdi + SB_ptr]
    cmp byte ptr [rcx + rax - 1], 10
    je 1f
    mov esi, 10
    jmp sb_push_byte
1:  xor eax, eax
    ret

# bash_finish(job) -> 0: reap the child, append the status, complete.
FN bash_finish
    PROLOGUE
    mov rbx, rdi
    mov r12, [rbx + J_pid]
    test r12, r12
    jz .Lbf_done
    mov rdi, [rbx + J_fd]
    test rdi, rdi
    js 1f
    call os_close
    mov qword ptr [rbx + J_fd], -1
1:  xor r13d, r13d                  # timed-out flag
    test dword ptr [rbx + J_flags], JF_TIMEOUT
    setnz r13b                      # the loop's watchdog killed it
    # deadline first: kill before reaping if it has passed
    mov rax, [rbx + J_deadline_ms]
    test rax, rax
    jz .Lbf_wait
    mov rdi, CLOCK_MONOTONIC
    call os_now_ns
    xor edx, edx
    mov ecx, 1000000
    div rcx
    cmp rax, [rbx + J_deadline_ms]
    jb .Lbf_wait
    mov rdi, r12
    mov esi, SIGKILL
    call os_kill_group
    mov r13d, 1
.Lbf_wait:
    mov rdi, r12
    mov esi, 1
    call os_wait
    cmp rax, -1
    jne .Lbf_status
    mov r14d, 100                   # a few 1 ms attempts
.Lbf_loop:
    mov edi, 1000000
    call os_sleep_ns
    mov rdi, r12
    mov esi, 1
    call os_wait
    cmp rax, -1
    jne .Lbf_status
    dec r14d
    jnz .Lbf_loop
    test r13d, r13d
    jnz 2f
    mov rdi, r12
    mov esi, SIGKILL
    call os_kill_group
    mov r13d, 1
2:  mov rdi, r12
    xor esi, esi                     # blocking reap
    call os_wait
.Lbf_status:
    cmp rax, -2
    jne 3f
    xor eax, eax                     # unknown child: report a clean exit
3:  mov r14, rax
    test r13d, r13d
    jz 4f
    mov rdi, rbx
    call bf_sep
    mov rdi, [rbx + J_out]
    lea rsi, [rip + .Ltimeout]
    call sb_push_cstr
4:  cmp r14, 128
    jb .Lbf_exit
    cmp r14, 256
    jb .Lbf_sig
.Lbf_exit:
    mov rdi, rbx
    call bf_sep
    mov rdi, [rbx + J_out]
    lea rsi, [rip + .Lexit]
    call sb_push_cstr
    mov rdi, [rbx + J_out]
    mov rsi, r14
    shr rsi, 8
    call sb_push_u64
    jmp .Lbf_mark
.Lbf_sig:
    mov rdi, rbx
    call bf_sep
    mov rdi, [rbx + J_out]
    lea rsi, [rip + .Lsignal]
    call sb_push_cstr
    mov rdi, [rbx + J_out]
    mov rsi, r14
    sub rsi, 128
    call sb_push_u64
.Lbf_mark:
    mov rdi, [rbx + J_out]
    lea rsi, [rip + .Lbrk]
    call sb_push_cstr
    mov qword ptr [rbx + J_pid], 0
.Lbf_done:
    mov rdi, rbx
    call tool_done
    xor eax, eax
    EPILOGUE
