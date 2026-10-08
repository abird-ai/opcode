// opcode on Linux AArch64: macros and constants for the native ELF code
// (entry.s, rt.s, sys.s), assembled with aarch64-unknown-linux-gnu-as and
// never run through tools/arm64.py.
//
// The rest of opcode is x86-64 GNU-as assembly that tools/arm64.py translates
// to AArch64 ELF. The translation keeps the x86 machine model, so this header
// is the contract between the translated code and the native layer:
//   registers   rax x8, rcx x3, rdx x2, rbx x19, rsp x28, rbp x20, rsi x1,
//               rdi x0, r8 x4, r9 x5, r10 x6, r11 x7, r12-r15 x21-x24;
//               translator temporaries x9-x17, v24-v31
//   stack       x28 is the x86 rsp: push, pop, call and ret use it as x86
//               does, and a translated function pops its return address from
//               [x28]. The native AAPCS sp is separate and stays 16-aligned.
//   flags       NZCV hold ZF SF OF directly and C holds the inverse of CF
//               (AArch64 subtraction sense); flags are produced only where a
//               read follows
//   return      a translated function is an AAPCS function that returns its
//               x86 rax in x8
//
// Native code keeps x19-x28, so a translated caller's x28 survives every
// helper call.

.macro FN name
    .text
    .globl \name
    .type \name, @function
    .p2align 2
\name:
.endm

// address of a symbol (ELF: adrp + :lo12:)
.macro ADR reg, sym
    adrp \reg, \sym
    add \reg, \reg, :lo12:\sym
.endm

// 32-bit constant into a register (mov + movk)
.macro IMM32 reg, v
    mov \reg, #((\v) & 0xffff)
    movk \reg, #((\v) >> 16), lsl #16
.endm

// Linux errno numbers, returned negative in x8 by the translated code and by
// sys.s.
.equ L_EINVAL, 22
.equ L_ENOSYS, 38
