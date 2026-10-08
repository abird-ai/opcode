.include "opcode.inc"
# opcode base: stderr logging.
#
# A minimal level gate: log_debug_* are no-ops until log_set_level(LOG_DEBUG)
# raises the threshold.  The default (LOG_ERROR) keeps --verbose off and the
# hot paths pay only a single compare.
.equ LOG_ERROR, 0
.equ LOG_INFO,  1
.equ LOG_DEBUG, 2

.section .bss
.p2align 2
.globl g_log_level
g_log_level: .zero 4

# write_all(fd, ptr, len) -> 0 | -errno (retries -EINTR and -EAGAIN)
FN write_all
    PROLOGUE 0
    mov ebx, edi
    mov r12, rsi
    mov r13, rdx
.Lwa_loop:
    test r13, r13
    jz .Lwa_ok
    mov edi, ebx
    mov rsi, r12
    mov rdx, r13
    call os_write
    cmp rax, -EINTR
    je .Lwa_loop
    cmp rax, -EAGAIN
    je .Lwa_loop
    test rax, rax
    js .Lwa_out
    add r12, rax
    sub r13, rax
    jmp .Lwa_loop
.Lwa_ok:
    xor eax, eax
.Lwa_out:
    EPILOGUE

# log_write(ptr, len) -> 0 | -errno (fd 2)
FN log_write
    mov rdx, rsi
    mov rsi, rdi
    mov edi, 2
    jmp write_all

# log_cstr(cstr) -> 0 | -errno
FN log_cstr
    PROLOGUE 0
    mov rbx, rdi
    call strlen
    mov rdi, rbx
    mov rsi, rax
    call log_write
    EPILOGUE

# log_u64(value) -> 0 | -errno
FN log_u64
    PROLOGUE 32
    mov rsi, rdi
    mov rdi, rsp
    call fmt_u64
    mov rdi, rsp
    mov rsi, rax
    call log_write
    EPILOGUE

# log_nl() -> 0 | -errno
FN log_nl
    lea rdi, [rip + .Lnl]
    mov esi, 1
    jmp log_write

# log_set_level(level): set the log_debug_* threshold (see LOG_* above).
FN log_set_level
    mov [rip + g_log_level], edi
    xor eax, eax
    ret

# log_debug_write(ptr, len) -> 0 | -errno: log_write, but only at LOG_DEBUG
FN log_debug_write
    cmp dword ptr [rip + g_log_level], LOG_DEBUG
    jb 1f
    jmp log_write
1:  xor eax, eax
    ret

# log_debug_cstr(cstr) -> 0 | -errno
FN log_debug_cstr
    cmp dword ptr [rip + g_log_level], LOG_DEBUG
    jb 1f
    jmp log_cstr
1:  xor eax, eax
    ret

# log_debug_u64(value) -> 0 | -errno
FN log_debug_u64
    cmp dword ptr [rip + g_log_level], LOG_DEBUG
    jb 1f
    jmp log_u64
1:  xor eax, eax
    ret

# log_debug_nl() -> 0 | -errno
FN log_debug_nl
    cmp dword ptr [rip + g_log_level], LOG_DEBUG
    jb 1f
    jmp log_nl
1:  xor eax, eax
    ret

# die(cstr): log the message plus newline and exit(1); never returns
FN die
    PROLOGUE 0
    call log_cstr
    call log_nl
    mov edi, 1
    call os_exit
    ud2

.section .rodata
.Lnl: .byte 10
