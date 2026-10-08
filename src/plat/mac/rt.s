// opcode on macOS: process entry and the helpers translated x86 code calls.
// Native AArch64; never runs through tools/arm64.py.
.include "mac.inc"

.equ STACK_SIZE, 16 << 20
.equ GUARD, 16384

// _main(argc, argv, envp): clang's crt1.o start calls _main with the three arguments. Build a
// Linux-shaped initial stack in a fresh mapping (argc, argv..., 0, envp..., 0) with a guard page at
// the bottom, point the x86 rsp x28 at it, and branch to the translated entry _start. The argv and
// envp strings stay where crt1 found them, in the original process stack.
FN _main
    ENTER 0
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x0, #0
    mov x1, #STACK_SIZE
    mov w2, #3                  // PROT_READ | PROT_WRITE
    mov w3, #0x1002             // MAP_PRIVATE | MAP_ANON
    mov x4, #-1
    mov x5, #0
    bl _mmap
    cmn x0, #1
    b.eq 9f
    mov x22, x0
    mov x1, #GUARD
    mov w2, #0                  // PROT_NONE
    bl _mprotect
    mov x9, #STACK_SIZE
    add x28, x22, x9
    // argc, argv..., 0, envp..., 0
    mov x10, #0
1:  ldr x11, [x21, x10, lsl #3]
    cbz x11, 2f
    add x10, x10, #1
    b 1b
2:  add x11, x19, x10
    add x11, x11, #3
    sub x28, x28, x11, lsl #3
    and x28, x28, #~15
    str x19, [x28]
    add x12, x28, #8
    mov x13, #0
3:  cmp x13, x19
    b.hs 4f
    ldr x14, [x20, x13, lsl #3]
    str x14, [x12], #8
    add x13, x13, #1
    b 3b
4:  str xzr, [x12], #8
    mov x13, #0
5:  cmp x13, x10
    b.hs 6f
    ldr x14, [x21, x13, lsl #3]
    str x14, [x12], #8
    add x13, x13, #1
    b 5b
6:  str xzr, [x12]
    bl _start
9:  mov w0, #111
    bl _exit

// ---- string instructions: rdi x0, rsi x1, rcx x3, rax x8; flags are kept (movs, stos)

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

// repe cmpsb: compare [rsi] with [rdi] while equal; flags of the last compare, as 8-bit values
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

// os_platform() -> "macos": the native override of the weak default in the
// translated Linux layer 0 (src/plat/linux/sys.s). On Darwin that definition
// lowers to .weak_definition, so this strong one wins at link time.
FN os_platform
    ADR x0, Lplat_macos
    ret

.section __DATA,__const
Lplat_macos: .asciz "macos"
