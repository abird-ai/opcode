# opcode: shared macros, constants and struct offsets.
# Every source file includes this first. GNU as, Intel syntax.
.intel_syntax noprefix

# ---------------------------------------------------------------- linux x86-64 syscalls
# These numbers are the portable kernel ABI: every OS adapter implements them
# (see .agents/docs/platform.md). Core code never calls anything else at Layer 0.
.equ SYS_read, 0
.equ SYS_write, 1
.equ SYS_close, 3
.equ SYS_fstat, 5
.equ SYS_poll, 7
.equ SYS_lseek, 8
.equ SYS_mmap, 9
.equ SYS_munmap, 11
.equ SYS_rt_sigaction, 13
.equ SYS_nanosleep, 35
.equ SYS_getcwd, 79
.equ SYS_setpgid, 109
.equ SYS_mkdirat, 258
.equ SYS_unlinkat, 263
.equ SYS_clock_gettime, 228
.equ SYS_exit_group, 231
.equ SYS_openat, 257
.equ SYS_getrandom, 318

.equ AT_FDCWD, -100

.equ O_RDONLY, 0
.equ O_WRONLY, 1
.equ O_RDWR, 2
.equ O_CREAT, 0x40
.equ O_EXCL, 0x80
.equ O_TRUNC, 0x200
.equ O_APPEND, 0x400
.equ O_NONBLOCK, 0x800
.equ O_DIRECTORY, 0x10000
.equ O_CLOEXEC, 0x80000

.equ PROT_READ, 1
.equ PROT_WRITE, 2
.equ MAP_SHARED, 1
.equ MAP_PRIVATE, 2
.equ MAP_ANONYMOUS, 0x20

.equ CLOCK_REALTIME, 0
.equ CLOCK_MONOTONIC, 1

.equ POLLIN, 1
.equ POLLOUT, 4
.equ POLLERR, 8
.equ POLLHUP, 16

.equ EPERM, 1
.equ ENOENT, 2
.equ EINTR, 4
.equ EIO, 5
.equ EINPROGRESS, 115
.equ EAGAIN, 11
.equ ENOMEM, 12
.equ EACCES, 13
.equ EPIPE, 32
.equ EEXIST, 17
.equ ENOTDIR, 20
.equ EISDIR, 21
.equ EINVAL, 22
.equ EBUSY, 16
.equ EFBIG, 27
.equ ENOSPC, 28
.equ ENOSYS, 38
.equ ERANGE, 34
.equ ESTALE, 116
.equ ETIMEDOUT, 110

# signal dispositions used by the Layer 0 signal helpers
.equ SIG_DFL, 0
.equ SIG_IGN, 1
.equ SIGPIPE, 13

# ---------------------------------------------------------------- function helpers
# FN name: define an exported function, 16-byte aligned.
.macro FN name
    .text
    .globl \name
    .ifndef WINDOWS
    .type \name, @function
    .endif
    .p2align 4
\name:
.endm

# PROLOGUE frame: save rbp/rbx/r12-r15, keep the stack 16-byte aligned for calls,
# and reserve `frame` bytes at [rsp, rsp+frame). `frame` must be a multiple of 16.
.macro PROLOGUE frame=0
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8 + \frame
    .ifdef WINDOWS
    # Win32 requires RSP to be 16-byte aligned at the call boundary; portable
    # callers reach this function at either alignment, so normalize here.
    # EPILOGUE restores through rbp, which is set before the adjustment.
    and rsp, -16
    .endif
.endm

.macro EPILOGUE
    lea rsp, [rbp - 40]
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret
.endm

# SYS num: raw linux system call. Clobbers rcx and r11.
.macro SYS num
    mov eax, \num
    XSYS
.endm

.macro XSYS
    .ifdef WINDOWS
    call win_syscall
    .else
    syscall
    .endif
.endm

# Raw `syscall` in portable sources (a few unit tests) must also route through
# the Windows shim; on every other target the macro is never defined and the
# real instruction is used.
.ifdef WINDOWS
.macro syscall
    call win_syscall
.endm
.endif

# ------------------------------------------------------------------- struct layout
# STRUCT / F name,size / ENDSTRUCT name accumulate byte offsets. No automatic
# alignment: insert padding fields by hand.
.macro STRUCT
    .set __so, 0
.endm
.macro F name, size
    .equ \name, __so
    .set __so, __so + \size
.endm
.macro ENDSTRUCT name
    .equ \name, __so
.endm

# CSTR name, text: NUL-terminated string in .rodata, back to .text.
.macro CSTR name, text
    .section .rodata
\name: .asciz "\text"
    .text
.endm

# ------------------------------------------------------------------- sections
# .type/.size are ELF directives; when the sources are assembled for the
# Windows target (--defsym WINDOWS=1) gas emits COFF and rejects them, so
# portable sources use these two macros instead of the raw directives.
.macro GTYPE name, kind
    .ifndef WINDOWS
    .type \name, \kind
    .endif
.endm

.macro GSIZE name, size
    .ifndef WINDOWS
    .size \name, \size
    .endif
.endm

# ------------------------------------------------------------------- containers
# growable byte buffer; strings are NUL-terminated at [ptr+len]
STRUCT
F SB_ptr, 8
F SB_len, 8
F SB_cap, 8
ENDSTRUCT SB_SIZE

# growable array of fixed-size items
STRUCT
F VEC_ptr, 8
F VEC_len, 8
F VEC_cap, 8
ENDSTRUCT VEC_SIZE

# ------------------------------------------------------------------- json values
.equ JT_NULL, 0
.equ JT_TRUE, 1
.equ JT_FALSE, 2
.equ JT_NUM, 3
.equ JT_STR, 4
.equ JT_ARR, 5
.equ JT_OBJ, 6

STRUCT
F JV_type, 4
F JV_n, 4              # elements / pairs / string bytes
F JV_ptr, 8            # string bytes, or child pointers (objects: key,value pairs)
ENDSTRUCT JV_SIZE

# ------------------------------------------------------------------- allocation
.equ MEM_CLASSES, 12
.equ MEM_MAXSMALL, 65536
.equ MEM_CHUNK, 1 << 20
