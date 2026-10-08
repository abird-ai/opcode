.include "plat/linux/aarch64/linux.inc"

// opcode on Linux AArch64: the helpers translated x86 code calls, mirroring
// src/plat/mac/rt.s. Native AArch64; never runs through tools/arm64.py.
//
// Conventions (from the translator): string instructions rdi x0, rsi x1,
// rcx x3, rax x8; flags are kept (movs, stos). x28 is the x86 rsp and is
// never touched; the native sp is 16-aligned.

// ---- string instructions: rdi x0, rsi x1, rcx x3, rax x8; flags are kept

// rep movsb, forward
FN x_rep_movsb
    cbz x3, 9f
    mrs x16, nzcv
    sub x9, x0, x1
    cmp x9, x3
    b.lo 5f                     // src < dst < src + n: bytes repeat, copy one by one
1:  cmp x3, #32
    b.lo 3f
    ldp q24, q25, [x1], #32
    stp q24, q25, [x0], #32
    sub x3, x3, #32
    b 1b
3:  cbz x3, 8f
5:  ldrb w9, [x1], #1
    strb w9, [x0], #1
    subs x3, x3, #1
    b.ne 5b
8:  msr nzcv, x16
9:  ret

// rep movsb with the direction flag set: rsi and rdi point at the last bytes
FN x_rep_movsb_back
    cbz x3, 9f
    mrs x16, nzcv
    cmp x0, x1
    b.lo 5f
1:  cmp x3, #16
    b.lo 3f
    ldur q24, [x1, #-15]
    stur q24, [x0, #-15]
    sub x1, x1, #16
    sub x0, x0, #16
    sub x3, x3, #16
    b 1b
3:  cbz x3, 8f
5:  ldrb w9, [x1], #-1
    strb w9, [x0], #-1
    subs x3, x3, #1
    b.ne 5b
8:  msr nzcv, x16
9:  ret

// rep stosb / stosd / stosq
FN x_rep_stosb
    cbz x3, 9f
    mrs x16, nzcv
    dup v24.16b, w8
1:  cmp x3, #16
    b.lo 3f
    str q24, [x0], #16
    sub x3, x3, #16
    b 1b
3:  cbz x3, 8f
4:  strb w8, [x0], #1
    sub x3, x3, #1
    cbnz x3, 4b
8:  msr nzcv, x16
9:  ret

FN x_rep_stosd
    cbz x3, 9f
    mrs x16, nzcv
    dup v24.4s, w8
1:  cmp x3, #4
    b.lo 3f
    str q24, [x0], #16
    sub x3, x3, #4
    b 1b
3:  cbz x3, 8f
4:  str w8, [x0], #4
    sub x3, x3, #1
    cbnz x3, 4b
8:  msr nzcv, x16
9:  ret

FN x_rep_stosq
    cbz x3, 9f
    mrs x16, nzcv
    dup v24.2d, x8
1:  cmp x3, #2
    b.lo 3f
    str q24, [x0], #16
    sub x3, x3, #2
    b 1b
3:  cbz x3, 8f
    str x8, [x0], #8
    sub x3, x3, #1
8:  msr nzcv, x16
9:  ret

// repe cmpsb: compare [rsi] with [rdi] while equal; flags of the last
// compare, as 8-bit values
FN x_repe_cmpsb
    cbz x3, 9f
1:  ldrb w9, [x1], #1
    ldrb w10, [x0], #1
    sub x3, x3, #1
    cmp w9, w10
    b.ne 2f
    cbnz x3, 1b
2:  lsl w9, w9, #24
    lsl w10, w10, #24
    cmp w9, w10
9:  ret

// repne scasb: scan [rdi] for al
FN x_repne_scasb
    cbz x3, 9f
    and w11, w8, #0xff
1:  ldrb w10, [x0], #1
    sub x3, x3, #1
    cmp w11, w10
    b.eq 2f
    cbnz x3, 1b
2:  lsl w9, w11, #24
    lsl w10, w10, #24
    cmp w9, w10
9:  ret

// div r64 with rdx not known to be zero: rdx:rax / x12 -> rax, remainder rdx
FN x_udiv128
    cbnz x2, 1f
    udiv x11, x8, x12
    msub x2, x11, x12, x8
    mov x8, x11
    ret
1:  mov x9, #64
2:  lsr x13, x2, #63
    extr x2, x2, x8, #63
    lsl x8, x8, #1
    cmp x2, x12
    cset x14, hs
    orr x14, x14, x13
    cbz x14, 3f
    sub x2, x2, x12
    orr x8, x8, #1
3:  subs x9, x9, #1
    b.ne 2b
    ret
