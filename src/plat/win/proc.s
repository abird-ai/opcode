.include "opcode.inc"
.include "plat/win/win.inc"
# win: Layer 0 processes over CreateProcessW.
#
# The Linux implementation is fork + execve; Win32 has neither, so this file
# replaces src/plat/linux/proc.s for the Windows target while keeping the
# contract exactly:
#   os_pipe(fds)              -> 0 | -errno      (read end non-blocking)
#   os_spawn(argv,envp,cwd,fd_in,fd_out,fd_err,ctty) -> pid | -errno
#   os_wait(pid, nohang)      -> 128+sig | exit<<8 | -1 running | -2 unknown
#   os_kill(pid, sig)         -> 0 | -errno
#   os_kill_group(pid, sig)   -> 0 | -errno      (terminates the child's job)
#
# Children are put in a Job object with KILL_ON_JOB_CLOSE, the Win32
# equivalent of the child process group.  argv[0] == "/bin/sh" is mapped to
# the system command interpreter (cmd.exe /d /s /c) because Windows has no
# /bin/sh; that is the one semantic change the bash tool sees.

.bss
.p2align 4
win_proc_table: .zero 256 * 32
win_cmdline16:  .zero 65536

.section .rdata
.p2align 1
# UTF-16 "cmd.exe /d /s /c \"" is built at run time from the ASCII literal
CSTR .Lsh, "/bin/sh"
CSTR .Lshellcmd, "cmd.exe /d /s /c \""
CSTR .Lempty, ""
.text

# proc_free_slot() -> index | -1: first free or reaped slot, closing the old
# handles of a reaped slot before reuse.
FN proc_free_slot
    lea rax, [rip + win_proc_table]
    xor ecx, ecx
.Lpf_loop:
    cmp ecx, 256
    jae .Lpf_none
    cmp dword ptr [rax + 4], 0
    je .Lpf_ret
    cmp dword ptr [rax + 4], 2
    je .Lpf_reuse
    add rax, 32
    inc ecx
    jmp .Lpf_loop
.Lpf_reuse:
    push rbx
    push r12
    sub rsp, 40
    mov rbx, rax
    mov r12d, ecx
    mov rcx, [rbx + 8]
    call CloseHandle
    mov rcx, [rbx + 16]
    test rcx, rcx
    jz 1f
    call CloseHandle
1:  add rsp, 40
    pop r12
    pop rbx
    mov eax, r12d
    ret
.Lpf_ret:
    mov eax, ecx
    ret
.Lpf_none:
    mov rax, -1
    ret

# proc_find(pid) -> entry pointer | 0
FN proc_find
    lea rax, [rip + win_proc_table]
    xor ecx, ecx
.Lpq_loop:
    cmp ecx, 256
    jae .Lpq_none
    cmp dword ptr [rax], edi
    jne 1f
    cmp dword ptr [rax + 4], 0
    jne .Lpq_found
1:  add rax, 32
    inc ecx
    jmp .Lpq_loop
.Lpq_found:
    ret
.Lpq_none:
    xor eax, eax
    ret

# ---------------------------------------------------------------- pipe
# os_pipe(fds) -> 0 | -errno
FN os_pipe
    PROLOGUE 64
    mov r12, rdi
    mov dword ptr [rsp + 32], 24    # SECURITY_ATTRIBUTES
    mov qword ptr [rsp + 40], 0
    mov dword ptr [rsp + 48], 1     # bInheritHandle
    lea rcx, [rsp + 56]
    lea rdx, [rsp + 64]
    lea r8, [rsp + 32]
    xor r9d, r9d
    call CreatePipe
    test eax, eax
    jz .Lpi_err
    mov r13, [rsp + 56]
    mov r14, [rsp + 64]
    mov rcx, r13
    mov edx, HANDLE_FLAG_INHERIT    # clear inheritance on the read end
    xor r8d, r8d
    call SetHandleInformation   # read end: parent only
    mov edi, FK_PIPE_R
    mov rsi, r13
    mov edx, O_NONBLOCK
    call win_fd_new
    test rax, rax
    js .Lpi_fail_read
    mov r15, rax
    mov edi, FK_PIPE_W
    mov rsi, r14
    xor edx, edx
    call win_fd_new
    test rax, rax
    js .Lpi_fail_write
    mov [r12], r15d
    mov [r12 + 4], eax
    xor eax, eax
    EPILOGUE
.Lpi_fail_write:
    mov rcx, r14
    call CloseHandle
    mov rdi, r15
    call win_fd_close
    mov rax, -EMFILE
    EPILOGUE
.Lpi_fail_read:
    mov rcx, r13
    call CloseHandle
    mov rcx, r14
    call CloseHandle
    mov rax, -EMFILE
    EPILOGUE
.Lpi_err:
    call win_last_error
    EPILOGUE

# win_std_handle(fd, default_std) -> HANDLE, made inheritable for the child
FN win_std_handle
    test rdi, rdi
    js .Lsh_default
    push rsi
    call win_fd_entry
    pop rsi
    test rax, rax
    jz .Lsh_default
    mov rax, [rax + FD_HANDLE]
    jmp .Lsh_inh
.Lsh_default:
    push rsi
    sub rsp, 48
    mov ecx, esi
    call GetStdHandle
    add rsp, 48
    pop rsi
    test rax, rax
    jz .Lsh_none
.Lsh_inh:
    push rax
    mov rcx, rax
    mov edx, HANDLE_FLAG_INHERIT
    mov r8d, HANDLE_FLAG_INHERIT
    sub rsp, 32                     # Win32 shadow space
    call SetHandleInformation
    add rsp, 32
    pop rax
.Lsh_none:
    ret

# win_build_env(envp) -> UTF-16 environment block | 0
# Two passes so the block is exactly sized; CreateProcessW copies it.
FN win_build_env
    PROLOGUE 0
    mov rbx, rdi
    xor r12, r12                    # total units (including NULs)
    mov r13, rbx
.Lbe_size:
    mov rdi, [r13]
    test rdi, rdi
    jz .Lbe_alloc
    lea rsi, [rip + win_scratch16]
    call win_utf8_to_utf16
    test rax, rax
    js .Lbe_none
    add r12, rax
    add r13, 8
    jmp .Lbe_size
.Lbe_alloc:
    test r12, r12
    jz .Lbe_empty
    lea rdx, [r12 * 2 + 2]
    mov rcx, 0
    mov r8d, MEM_COMMIT | MEM_RESERVE
    mov r9d, PAGE_READWRITE
    call VirtualAlloc
    test rax, rax
    jz .Lbe_none
    mov r14, rax
    mov r13, rbx
    mov r15, rax
.Lbe_fill:
    mov rdi, [r13]
    test rdi, rdi
    jz .Lbe_fin
    mov rsi, r15
    call win_utf8_to_utf16
    test rax, rax
    js .Lbe_free_none
    lea r15, [r15 + rax * 2]
    add r13, 8
    jmp .Lbe_fill
.Lbe_fin:
    mov word ptr [r15], 0
    mov rax, r14
    EPILOGUE
.Lbe_empty:
    mov rcx, 0
    mov edx, 2
    mov r8d, MEM_COMMIT | MEM_RESERVE
    mov r9d, PAGE_READWRITE
    call VirtualAlloc
    test rax, rax
    jz .Lbe_none
    mov word ptr [rax], 0
    EPILOGUE
.Lbe_free_none:
    mov rcx, r14
    xor edx, edx
    mov r8d, MEM_RELEASE
    call VirtualFree
.Lbe_none:
    xor eax, eax
    EPILOGUE

# append_arg(dst u16*, argw u16*) -> new dst; Windows quoting: backslashes are
# doubled only when they precede a quote or the end of the argument.
FN win_append_arg
    mov r8, rdi
    mov word ptr [r8], '"'
    add r8, 2
.Laa_loop:
    xor ecx, ecx
.Laa_bs:
    cmp word ptr [rsi], 0x5C
    jne .Laa_after
    inc ecx
    add rsi, 2
    jmp .Laa_bs
.Laa_after:
    movzx eax, word ptr [rsi]
    cmp eax, '"'
    je .Laa_quote
    test eax, eax
    jz .Laa_end
1:  test ecx, ecx
    jz 2f
    mov word ptr [r8], 0x5C
    add r8, 2
    dec ecx
    jmp 1b
2:  mov [r8], ax
    add r8, 2
    add rsi, 2
    jmp .Laa_loop
.Laa_quote:
    add ecx, ecx
3:  test ecx, ecx
    jz 4f
    mov word ptr [r8], 0x5C
    add r8, 2
    dec ecx
    jmp 3b
4:  mov word ptr [r8], 0x5C
    add r8, 2
    mov word ptr [r8], '"'
    add r8, 2
    add rsi, 2
    jmp .Laa_loop
.Laa_end:
    add ecx, ecx
5:  test ecx, ecx
    jz 6f
    mov word ptr [r8], 0x5C
    add r8, 2
    dec ecx
    jmp 5b
6:  mov word ptr [r8], '"'
    add r8, 2
    mov word ptr [r8], ' '
    add r8, 2
    mov rax, r8
    ret

# ---------------------------------------------------------------- spawn
# Frame: args 32..79, fd_err 80, env 88, cwd 96, spare 104/112,
# STARTUPINFOW 128..231, PROCESS_INFORMATION 232..255, job info 256..399.
FN os_spawn
    PROLOGUE 400
    mov rbx, rdi                    # argv
    mov r12, rsi                    # envp
    mov r13, rdx                    # cwd
    movsxd r14, ecx                 # fd_in
    movsxd r15, r8d                 # fd_out
    movsxd rax, r9d
    mov [rsp + 80], rax             # fd_err
    mov qword ptr [rsp + 88], 0
    mov qword ptr [rsp + 96], 0
    # ---- command line
    mov rdi, [rbx]
    lea rsi, [rip + .Lsh]
.Lsp_sh:
    mov al, [rdi]
    cmp al, [rsi]
    jne .Lsp_join
    test al, al
    jz .Lsp_shell
    inc rdi
    inc rsi
    jmp .Lsp_sh
.Lsp_shell:
    lea rdi, [rip + .Lshellcmd]
    lea rsi, [rip + win_cmdline16]
    call win_utf8_to_utf16
    test rax, rax
    js .Lsp_bad
    lea rdi, [rip + win_cmdline16]
1:  cmp word ptr [rdi], 0
    je 2f
    add rdi, 2
    jmp 1b
2:  mov [rsp + 120], rdi            # NUL position: command goes here
    mov rdi, [rbx + 16]
    test rdi, rdi
    jnz 3f
    lea rdi, [rip + .Lempty]
3:  mov rsi, [rsp + 120]
    call win_utf8_to_utf16
    test rax, rax
    js .Lsp_bad
    mov rdi, [rsp + 120]
4:  cmp word ptr [rdi], 0
    je 5f
    add rdi, 2
    jmp 4b
5:  mov word ptr [rdi], '"'
    mov word ptr [rdi + 2], 0
    jmp .Lsp_env
.Lsp_join:
    lea rdi, [rip + win_cmdline16]
    mov word ptr [rdi], 0
    mov [rsp + 112], rbx
.Lsp_argloop:
    mov rax, [rsp + 112]
    mov rdi, [rax]
    test rdi, rdi
    jz .Lsp_env
    lea rsi, [rip + win_scratch16]
    call win_utf8_to_utf16
    test rax, rax
    js .Lsp_bad
    lea rdi, [rip + win_cmdline16]
5:  cmp word ptr [rdi], 0
    je 6f
    add rdi, 2
    jmp 5b
6:  lea rsi, [rip + win_scratch16]
    call win_append_arg
    mov word ptr [rax], 0
    add qword ptr [rsp + 112], 8
    jmp .Lsp_argloop
.Lsp_env:
    # ---- environment block (CreateProcessW copies it)
    test r12, r12
    jz .Lsp_cwd
    mov rdi, r12
    call win_build_env
    mov [rsp + 88], rax
.Lsp_cwd:
    test r13, r13
    jz .Lsp_si
    mov rdi, r13
    lea rsi, [rip + win_scratch8]
    call win_utf8_to_utf16
    test rax, rax
    js .Lsp_bad
    lea rax, [rip + win_scratch8]
    mov [rsp + 96], rax
.Lsp_si:
    lea rdi, [rsp + 128]
    xor eax, eax
    mov ecx, 13
    rep stosq
    mov dword ptr [rsp + 128], 104
    mov dword ptr [rsp + 128 + 60], STARTF_USESTDHANDLES
    mov rdi, r14
    mov esi, STD_INPUT_HANDLE
    call win_std_handle
    mov [rsp + 128 + 80], rax
    mov rdi, r15
    mov esi, STD_OUTPUT_HANDLE
    call win_std_handle
    mov [rsp + 128 + 88], rax
    mov rdi, [rsp + 80]
    mov esi, STD_ERROR_HANDLE
    call win_std_handle
    mov [rsp + 128 + 96], rax
    # ---- CreateProcessW
    xor ecx, ecx
    lea rdx, [rip + win_cmdline16]
    xor r8d, r8d
    xor r9d, r9d
    mov dword ptr [rsp + 32], 1     # bInheritHandles
    mov dword ptr [rsp + 40], CREATE_UNICODE_ENVIRONMENT
    mov rax, [rsp + 88]
    mov [rsp + 48], rax
    mov rax, [rsp + 96]
    mov [rsp + 56], rax
    lea rax, [rsp + 128]
    mov [rsp + 64], rax
    lea rax, [rsp + 232]
    mov [rsp + 72], rax
    call CreateProcessW
    test eax, eax
    jz .Lsp_fail
    mov rcx, [rsp + 232 + 8]        # hThread
    call CloseHandle
    # ---- job object (KILL_ON_JOB_CLOSE)
    xor ecx, ecx
    xor edx, edx
    call CreateJobObjectW
    mov [rsp + 104], rax
    test rax, rax
    jz .Lsp_nojob
    lea rdi, [rsp + 256]
    xor eax, eax
    mov ecx, 18
    rep stosq
    mov dword ptr [rsp + 256 + 16], JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    mov rcx, [rsp + 104]
    mov edx, JobObjectExtendedLimitInformation
    lea r8, [rsp + 256]
    mov r9d, 144
    call SetInformationJobObject
    mov rcx, [rsp + 104]
    mov rdx, [rsp + 232]
    call AssignProcessToJobObject
.Lsp_nojob:
    call proc_free_slot
    cmp eax, -1
    je .Lsp_noslot
    mov ecx, eax
    shl rcx, 5
    lea rdx, [rip + win_proc_table]
    add rdx, rcx
    mov ecx, [rsp + 232 + 16]
    mov [rdx], ecx
    mov dword ptr [rdx + 4], 1
    mov rcx, [rsp + 232]
    mov [rdx + 8], rcx
    mov rcx, [rsp + 104]
    mov [rdx + 16], rcx
    mov dword ptr [rdx + 24], 0
    # free the environment block; the child has its own copy
    mov rcx, [rsp + 88]
    test rcx, rcx
    jz 7f
    xor edx, edx
    mov r8d, MEM_RELEASE
    call VirtualFree
7:  mov eax, [rsp + 232 + 16]
    EPILOGUE
.Lsp_noslot:
    mov rcx, [rsp + 232]
    call TerminateProcess
    mov rcx, [rsp + 104]
    test rcx, rcx
    jz 8f
    call CloseHandle
8:  mov rax, -EMFILE
    EPILOGUE
.Lsp_fail:
    call win_last_error
    mov r12, rax
    mov rcx, [rsp + 88]
    test rcx, rcx
    jz 9f
    xor edx, edx
    mov r8d, MEM_RELEASE
    call VirtualFree
9:  mov rax, r12
    EPILOGUE
.Lsp_bad:
    mov rax, -EINVAL
    EPILOGUE

# ---------------------------------------------------------------- wait/kill
# os_wait(pid, nohang) -> 128+sig | exit<<8 | -1 running | -2 unknown
FN os_wait
    PROLOGUE 32
    mov r12d, esi
    call proc_find
    test rax, rax
    jz .Low_unknown
    mov rbx, rax
    mov rcx, [rbx + 8]
    xor edx, edx
    test r12d, r12d
    jnz 1f
    mov rdx, INFINITE
1:  call WaitForSingleObject
    cmp eax, WAIT_TIMEOUT
    je .Low_running
    cmp eax, WAIT_OBJECT_0
    jne .Low_unknown
    mov dword ptr [rbx + 4], 2
    mov eax, [rbx + 24]             # kill signal recorded by os_kill*
    test eax, eax
    jz .Low_exit
    add eax, 128
    EPILOGUE
.Low_exit:
    mov rcx, [rbx + 8]
    lea rdx, [rsp + 32]
    call GetExitCodeProcess
    test eax, eax
    jz .Low_unknown
    mov eax, [rsp + 32]
    shl rax, 8
    EPILOGUE
.Low_running:
    mov rax, -1
    EPILOGUE
.Low_unknown:
    mov rax, -2
    EPILOGUE

# os_kill(pid, sig) -> 0 | -errno
FN os_kill
    PROLOGUE 32
    mov r12d, esi
    call proc_find
    test rax, rax
    jz .Lok_none
    mov dword ptr [rax + 24], r12d
    mov rcx, [rax + 8]
    lea edx, [r12d + 128]
    call TerminateProcess
    test eax, eax
    jz .Lok_err
    xor eax, eax
    EPILOGUE
.Lok_err:
    call win_last_error
    EPILOGUE
.Lok_none:
    mov rax, -ESRCH
    EPILOGUE

# os_kill_group(pid, sig) -> 0 | -errno
FN os_kill_group
    PROLOGUE 32
    mov r12d, esi
    call proc_find
    test rax, rax
    jz .Lkg_none
    mov dword ptr [rax + 24], r12d
    mov rcx, [rax + 16]             # job
    test rcx, rcx
    jz .Lkg_proc
    lea edx, [r12d + 128]
    call TerminateJobObject
    test eax, eax
    jz .Lkg_err
    xor eax, eax
    EPILOGUE
.Lkg_proc:
    mov rcx, [rax + 8]
    lea edx, [r12d + 128]
    call TerminateProcess
    test eax, eax
    jz .Lkg_err
    xor eax, eax
    EPILOGUE
.Lkg_err:
    call win_last_error
    EPILOGUE
.Lkg_none:
    mov rax, -ESRCH
    EPILOGUE
