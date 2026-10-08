.include "opcode.inc"
# adapted from rhun (MIT), see THIRD_PARTY.md
#
# linux x86-64 layer 0: the kernel surface from src/plat/plat.inc, direct
# syscalls, no vDSO and no libc. Every entry point returns in rax; failures are
# negative linux errno values. The syscall instruction clobbers rcx and r11.

.bss
.p2align 3
.globl g_argc, g_argv, g_envp
g_argc: .zero 8
g_argv: .zero 8
g_envp: .zero 8
# Optional async-signal-safe cleanup hook run by os_exit before exit_group.
# term_init sets it to term_restore; 0 means no hook.
.globl g_exit_hook
g_exit_hook: .zero 8
# sigaction scratch used by os_init (ignore SIGPIPE) and the os_spawn child
# (restore SIG_DFL before exec).
sigpipe_act: .zero 32

.text

CSTR .Lox_oom, "opcode: out of memory"

# ---------------------------------------------------------------- bootstrap
# os_init(rsp_at_entry): record argc/argv/envp from the initial process stack,
# then ignore SIGPIPE. A closed child pipe (a dead MCP server, a tool whose
# reader stopped) must surface as -EPIPE to the caller instead of killing the
# process. os_spawn restores SIG_DFL in the child so exec'd programs keep the
# normal signal semantics.
FN os_init
    mov rax, [rdi]
    mov [rip + g_argc], rax
    lea rcx, [rdi + 8]
    mov [rip + g_argv], rcx
    lea rcx, [rcx + rax*8 + 8]
    mov [rip + g_envp], rcx
    mov qword ptr [rip + sigpipe_act], SIG_IGN
    mov qword ptr [rip + sigpipe_act + 8], 0
    mov qword ptr [rip + sigpipe_act + 16], 0
    mov qword ptr [rip + sigpipe_act + 24], 0
    mov edi, SIGPIPE
    lea rsi, [rip + sigpipe_act]
    xor edx, edx
    mov r10d, 8
    SYS SYS_rt_sigaction
    xor eax, eax
    ret

# os_exit(code): run the cleanup hook (if any), then end the whole process;
# never returns. The hook must be async-signal-safe.
FN os_exit
    push rdi
    mov rax, [rip + g_exit_hook]
    test rax, rax
    jz 1f
    call rax
1:  pop rdi
    SYS SYS_exit_group
    ud2

# ---------------------------------------------------------------- files
# os_open(path, flags, mode) -> fd: openat(AT_FDCWD, path, flags, mode); the
# mode of openat is the fourth argument, in r10.
FN os_open
    mov r10, rdx
    mov rdx, rsi
    mov rsi, rdi
    mov edi, AT_FDCWD
    SYS SYS_openat
    ret

# os_read(fd, buf, len) -> n | -errno
FN os_read
    SYS SYS_read
    ret

# os_write(fd, buf, len) -> n | -errno
FN os_write
    SYS SYS_write
    ret

# os_close(fd) -> 0 | -errno
FN os_close
    SYS SYS_close
    ret

# os_lseek(fd, off, whence) -> off | -errno
FN os_lseek
    SYS SYS_lseek
    ret

# os_fstat(fd, statbuf) -> 0 | -errno
FN os_fstat
    SYS SYS_fstat
    ret

# os_mkdir(path, mode) -> 0 | -errno: mkdirat(AT_FDCWD, path, mode).
FN os_mkdir
    mov rdx, rsi
    mov rsi, rdi
    mov edi, AT_FDCWD
    SYS SYS_mkdirat
    ret

# os_unlink(path) -> 0 | -errno: unlinkat(AT_FDCWD, path, 0).
FN os_unlink
    xor edx, edx
    mov rsi, rdi
    mov edi, AT_FDCWD
    SYS SYS_unlinkat
    ret

# os_getcwd(buf, len) -> n | -errno (n counts the terminating NUL)
FN os_getcwd
    SYS SYS_getcwd
    ret

# os_platform() -> cstr: the OS name reported to the model in the system
# prompt. Weak so the native macOS layer (src/plat/mac/rt.s) overrides it on
# Darwin; both linux targets (x86-64 and translated aarch64) report "linux".
.weak os_platform
FN os_platform
    lea rax, [rip + .Lox_plat_linux]
    ret

# ---------------------------------------------------------------- memory
# os_map(size) -> ptr: anonymous private read/write mapping, zeroed by the
# kernel; dies when the mapping cannot be made.
FN os_map
    PROLOGUE
    mov rsi, rdi
    xor edi, edi
    mov edx, PROT_READ | PROT_WRITE
    mov r10d, MAP_PRIVATE | MAP_ANONYMOUS
    mov r8, -1
    xor r9d, r9d
    SYS SYS_mmap
    cmp rax, -4096
    ja .Lox_map_fail
    EPILOGUE
.Lox_map_fail:
    lea rdi, [rip + .Lox_oom]
    call die
    ud2

# os_map_try(size) -> ptr | 0: os_map, but 0 instead of dying.
FN os_map_try
    mov rsi, rdi
    xor edi, edi
    mov edx, PROT_READ | PROT_WRITE
    mov r10d, MAP_PRIVATE | MAP_ANONYMOUS
    mov r8, -1
    xor r9d, r9d
    SYS SYS_mmap
    cmp rax, -4096
    jbe .Lox_map_try_ok
    xor eax, eax
.Lox_map_try_ok:
    ret

# os_unmap(ptr, size) -> 0 | -errno
FN os_unmap
    SYS SYS_munmap
    ret

# ---------------------------------------------------------------- time
# os_now_ns(clock) -> nanoseconds; clock 0 is CLOCK_REALTIME, 1 CLOCK_MONOTONIC.
# The 16-byte timespec lives on the stack; on failure rax is -errno.
FN os_now_ns
    sub rsp, 16
    mov rsi, rsp
    SYS SYS_clock_gettime
    test rax, rax
    js .Lox_now_done
    mov rax, [rsp]
    imul rax, rax, 1000000000
    add rax, [rsp + 8]
.Lox_now_done:
    add rsp, 16
    ret

# os_sleep_ns(ns) -> 0 | -errno: split into seconds and nanoseconds on the stack.
FN os_sleep_ns
    sub rsp, 16
    mov rax, rdi
    xor edx, edx
    mov ecx, 1000000000
    div rcx
    mov [rsp], rax
    mov [rsp + 8], rdx
    mov rdi, rsp
    xor esi, esi
    SYS SYS_nanosleep
    add rsp, 16
    ret

# ---------------------------------------------------------------- entropy
# os_random(buf, len) -> 0 | -errno
# getrandom(2) until the buffer is full; a kernel without getrandom reads
# /dev/urandom instead.
FN os_random
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
.Lox_rand_loop:
    test r13, r13
    jz .Lox_rand_ok
    mov rdi, r12
    mov rsi, r13
    xor edx, edx
    SYS SYS_getrandom
    cmp rax, -ENOSYS
    je .Lox_rand_fallback
    cmp rax, -EINTR
    je .Lox_rand_loop
    test rax, rax
    js .Lox_rand_ret
    jz .Lox_rand_eio
    add r12, rax
    sub r13, rax
    jmp .Lox_rand_loop
.Lox_rand_eio:
    mov rax, -EIO
.Lox_rand_ret:
    EPILOGUE
.Lox_rand_ok:
    xor eax, eax
    EPILOGUE
.Lox_rand_fallback:
    lea rdi, [rip + .Lox_urandom]
    mov esi, O_RDONLY | O_CLOEXEC
    xor edx, edx
    call os_open
    test rax, rax
    js .Lox_rand_ret
    mov ebx, eax
.Lox_rand_fill:
    test r13, r13
    jz .Lox_rand_close
    mov edi, ebx
    mov rsi, r12
    mov rdx, r13
    call os_read
    cmp rax, -EINTR
    je .Lox_rand_fill
    test rax, rax
    js .Lox_rand_fill_fail
    jz .Lox_rand_fill_eof
    add r12, rax
    sub r13, rax
    jmp .Lox_rand_fill
.Lox_rand_fill_eof:
    mov rax, -EIO
.Lox_rand_fill_fail:
    mov r14, rax
    mov edi, ebx
    call os_close
    mov rax, r14
    EPILOGUE
.Lox_rand_close:
    mov edi, ebx
    call os_close
    EPILOGUE

.section .rodata
.Lox_urandom: .asciz "/dev/urandom"
.Lox_plat_linux: .asciz "linux"
.text

# ---------------------------------------------------------------- events
# os_poll(fds, nfds, timeout_ms) -> ready descriptors | -errno
FN os_poll
    SYS SYS_poll
    ret
