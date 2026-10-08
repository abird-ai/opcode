// opcode on macOS: macros and constants for the native AArch64 code (rt.s, sys.s).
//
// The rest of opcode is x86-64 GNU-as assembly that tools/arm64.py translates. The translation keeps
// the x86 machine model, so this header is the contract between the translated code and the native
// Darwin layer:
//   registers   rax x8, rcx x3, rdx x2, rbx x19, rsp x28, rbp x20, rsi x1, rdi x0, r8 x4, r9 x5,
//               r10 x6, r11 x7, r12-r15 x21-x24; temporaries x9-x17, v24-v31
//   stack       x28 is the x86 rsp: push, pop, call and ret use it as x86 does, and a translated
//               function pops its return address from [x28]
//   flags       NZCV hold ZF SF OF directly and C holds the inverse of CF (AArch64 subtraction
//               sense); flags are produced only where a read follows
//   return      a translated function is an AAPCS function that returns its x86 rax in x8
//
// XCALL calls a translated function: it pushes an x86 return address before bl, so the callee's ret
// lands after the call. XCALLR is the same through a register. XRET returns to translated code from
// a native function the translated code called; it pops the x86 return address and rets through it.
// Native code keeps x19-x28, so a translated caller's x28 survives.

.macro XCALL fn
    adr x17, Lxc\@
    str x17, [x28, #-8]!
    bl \fn
Lxc\@:
.endm

.macro XCALLR reg
    adr x17, Lxc\@
    str x17, [x28, #-8]!
    blr \reg
Lxc\@:
.endm

.macro XRET
    add x28, x28, #8
    ret
.endm

// AAPCS frame with x19-x28 saved; \size bytes of locals at [sp]
.macro ENTER size=0
    stp x29, x30, [sp, #-96]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    stp x23, x24, [sp, #48]
    stp x25, x26, [sp, #64]
    stp x27, x28, [sp, #80]
    .if \size
    sub sp, sp, #\size
    .endif
.endm

.macro LEAVE
    mov sp, x29
    ldp x19, x20, [sp, #16]
    ldp x21, x22, [sp, #32]
    ldp x23, x24, [sp, #48]
    ldp x25, x26, [sp, #64]
    ldp x27, x28, [sp, #80]
    ldp x29, x30, [sp], #96
.endm

// address of a symbol
.macro ADR reg, sym
    adrp \reg, \sym@PAGE
    add \reg, \reg, \sym@PAGEOFF
.endm

// external data symbol (via the GOT)
.macro GOT reg, sym
    adrp \reg, \sym@GOTPAGE
    ldr \reg, [\reg, \sym@GOTPAGEOFF]
.endm

.macro FN name
    .text
    .globl \name
    .p2align 2
\name:
.endm

// Linux errno numbers, returned negative in x8 by the translated code and by sys.s.
.equ L_EPERM, 1
.equ L_ENOENT, 2
.equ L_EINTR, 4
.equ L_EIO, 5
.equ L_EBADF, 9
.equ L_EAGAIN, 11
.equ L_ENOMEM, 12
.equ L_EACCES, 13
.equ L_EFAULT, 14
.equ L_EBUSY, 16
.equ L_EEXIST, 17
.equ L_ENODEV, 19
.equ L_ENOTDIR, 20
.equ L_EISDIR, 21
.equ L_EINVAL, 22
.equ L_ENFILE, 23
.equ L_EMFILE, 24
.equ L_ENOTTY, 25
.equ L_EROFS, 30
.equ L_EPIPE, 32
.equ L_ERANGE, 34
.equ L_ENAMETOOLONG, 36
.equ L_ENOSYS, 38
.equ L_ELOOP, 40
.equ L_ENOTEMPTY, 39
.equ L_ETIMEDOUT, 110
.equ L_EINPROGRESS, 115
.equ L_ESTALE, 116
.equ L_AT_FDCWD, -100
