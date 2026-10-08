.include "opcode.inc"
# linux Layer 0: process control (fork/exec, wait, signals, pipes).
# Contract: src/plat/plat.inc + src/core/API.md. Raw syscalls only, no libc.
#
#   os_pipe(fds)                -> 0 | -errno    pipe2(O_CLOEXEC), read end O_NONBLOCK
#   os_spawn(argv,envp,cwd,
#            fd_in,fd_out,fd_err,ctty) -> pid | -errno
#   os_wait(pid, nohang)        -> 128+sig | exit<<8 | -1 running | -2 unknown
#   os_kill(pid, sig)           -> 0 | -errno
#
# The child is allowed to fail safely: fork(57) + execve(59), never vfork.

.equ SYS_dup2,       33
.equ SYS_fork,       57
.equ SYS_execve,     59
.equ SYS_wait4,      61
.equ SYS_kill,       62
.equ SYS_fcntl,      72
.equ SYS_chdir,      80
.equ SYS_pipe2,      293

.equ F_SETFL,        4
.equ WNOHANG,        1
.equ ECHILD,         10

.bss
.p2align 3
# SIG_DFL action the spawn child installs for SIGPIPE (see os_init)
sp_sigpipe_act: .zero 32

.text

# os_pipe(fds) -> 0 | -errno
# fds[0] is non-blocking so the agent loop can drain it with os_read/os_poll;
# fds[1] stays blocking so the child never gets short writes.
FN os_pipe
    push rbx
    push r12
    mov rbx, rdi
    mov esi, O_CLOEXEC
    SYS SYS_pipe2
    test rax, rax
    js .Lop_ret
    mov edi, [rbx]                  # read end
    mov esi, F_SETFL
    mov edx, O_NONBLOCK
    SYS SYS_fcntl
    test rax, rax
    jns .Lop_ok
    # A read end that stayed blocking would wedge the agent loop on the
    # first drain, so close both ends and return the fcntl error.
    mov r12, rax
    mov edi, [rbx]
    SYS SYS_close
    mov edi, [rbx + 4]
    SYS SYS_close
    mov rax, r12
.Lop_ret:
    pop r12
    pop rbx
    ret
.Lop_ok:
    xor eax, eax
    pop r12
    pop rbx
    ret

# sp_dup2(old, new): dup2 in the child; _exit(127) on failure
sp_dup2:
    test edi, edi
    js 9f
    cmp edi, esi
    je 9f
    mov eax, SYS_dup2
    syscall
    test rax, rax
    js sp_fail
9:  ret

# sp_close(fd): close in the child when fd > 2 (double close is harmless)
sp_close:
    cmp edi, 3
    jl 9f
    mov eax, SYS_close
    syscall
9:  ret

# child-only failure exit; never returns
sp_fail:
    mov edi, 127
    SYS SYS_exit_group

# os_spawn(argv, envp, cwd, fd_in, fd_out, fd_err, ctty) -> pid | -errno
FN os_spawn
    PROLOGUE 16
    mov rbx, rdi                    # argv
    mov r12, rsi                    # envp
    mov r13, rdx                    # cwd (0 = inherit)
    mov r14, rcx                    # fd_in  (-1 = inherit)
    mov r15, r8                     # fd_out (-1 = inherit)
    mov [rsp], r9                   # fd_err
    mov rax, [rbp + 16]             # ctty (7th arg; 0 for now)
    mov [rsp + 8], rax
    SYS SYS_fork
    test rax, rax
    js .Lsp_ret                     # fork error: -errno in rax
    jz .Lsp_child
.Lsp_ret:
    EPILOGUE

.Lsp_child:
    # own process group: the parent kills the whole tree (sh + descendants)
    # so a timed-out or aborted tool cannot outlive its pipe
    xor edi, edi
    xor esi, esi
    mov eax, SYS_setpgid
    syscall
    # restore the default SIGPIPE disposition os_init ignored, so exec'd
    # programs keep the normal pipe semantics (e.g. `yes | head`)
    mov qword ptr [rip + sp_sigpipe_act], SIG_DFL
    mov edi, SIGPIPE
    lea rsi, [rip + sp_sigpipe_act]
    xor edx, edx
    mov r10d, 8
    mov eax, SYS_rt_sigaction
    syscall
    # wire up stdio
    mov edi, r14d
    xor esi, esi
    call sp_dup2
    mov edi, r15d
    mov esi, 1
    call sp_dup2
    mov edi, [rsp]
    mov esi, 2
    call sp_dup2
    # drop the original ends so the parent's pipe descriptors do not leak
    mov edi, r14d
    call sp_close
    mov edi, r15d
    call sp_close
    mov edi, [rsp]
    call sp_close
    mov edi, [rsp + 8]
    call sp_close
    # working directory
    test r13, r13
    jz 1f
    mov rdi, r13
    mov eax, SYS_chdir
    syscall
    test rax, rax
    js sp_fail
    # exec
1:  mov rdi, [rbx]
    mov rsi, rbx
    mov rdx, r12
    mov eax, SYS_execve
    syscall
    jmp sp_fail                     # exec failed: _exit(127), no output

# os_wait(pid, nohang) -> 128+sig | exit<<8 | -1 running | -2 unknown
FN os_wait
    push rbp
    mov rbp, rsp
    sub rsp, 32
    mov qword ptr [rsp], 0
    mov rdx, rsi
    and edx, 1                      # nohang != 0 -> WNOHANG
    mov rsi, rsp                    # &status
    xor r10d, r10d                  # rusage = NULL
    SYS SYS_wait4
    test rax, rax
    js .Low_err
    jz .Low_running
    mov edx, [rsp]                  # wait status
    mov ecx, edx
    and ecx, 0x7f
    test ecx, ecx
    jz .Low_exit
    cmp ecx, 0x7f                   # stopped: treat as still running
    je .Low_running
    lea eax, [rcx + 128]            # killed by signal
    leave
    ret
.Low_exit:
    mov eax, edx
    and eax, 0xff00                 # exit code << 8
    leave
    ret
.Low_running:
    mov rax, -1
    leave
    ret
.Low_err:
    cmp rax, -ECHILD
    jne .Low_eintr
    mov rax, -2
    leave
    ret
.Low_eintr:
    mov rax, -1
    leave
    ret

# os_kill(pid, sig) -> 0 | -errno
FN os_kill
    SYS SYS_kill
    ret

# os_kill_group(pid, sig) -> 0 | -errno: signal the process group led by pid
# (os_spawn puts every child in its own group). Used to stop a tool's whole
# process tree; a negative pid is understood by every supported kernel.
FN os_kill_group
    neg rdi
    SYS SYS_kill
    ret
