.include "plat/linux/aarch64/linux.inc"

// opcode on Linux AArch64: process entry.
//
// The kernel enters opcode_entry with the Linux initial stack (argc, argv...,
// envp...) in sp, 16-aligned. Translated code keeps the x86 rsp in x28 and
// src/base/start.s reads rdi = rsp, so opcode_entry gives the x86 model its
// own 16 MiB stack in a fresh mapping, exactly as mac rt.s _main does for
// Darwin: native code (this shim, the kernel's signal frames) keeps the
// kernel stack as the AAPCS sp, and x28's pushes can never collide with it.
// The initial stack vector (argc, argv pointers, NULL, envp pointers, NULL)
// is copied into the new stack; the pointed-to strings stay in the kernel
// stack, which lives for the whole process.

.equ STACK_SIZE, 16 << 20
.equ GUARD, 16384

FN opcode_entry
    // setrlimit(RLIMIT_CORE, {0, 0}): the aarch64 opcode never dumps a core.
    // A translated-binary core has no debugging value and the agent runs in
    // users' repositories; it also keeps signal deaths clean under
    // qemu-user, whose guest core-dump path appends "qemu: uncaught target
    // signal N ... - core dumped" to stderr only when the guest's core limit
    // is nonzero (the dump hook then fails and the death is silent, exactly
    // as on a real kernel).
    sub sp, sp, #16
    stp xzr, xzr, [sp]          // struct rlimit { rlim_cur = 0, rlim_max = 0 }
    mov x0, #4                  // RLIMIT_CORE
    mov x1, sp
    mov x8, #164                // setrlimit
    svc #0
    add sp, sp, #16
    mov x19, sp                 // the kernel's initial stack
    mov x0, #0
    IMM32 x1, STACK_SIZE
    mov w2, #3                  // PROT_READ | PROT_WRITE
    mov w3, #0x22               // MAP_PRIVATE | MAP_ANONYMOUS
    mov x4, #-1
    mov x5, #0
    mov x8, #222                // mmap
    svc #0
    mov x9, #-4096
    cmp x0, x9
    b.hi 9f                     // mmap failed: die (nothing to continue with)
    mov x20, x0                 // mapping base
    mov x0, x20
    mov x1, #GUARD
    mov w2, #0                  // PROT_NONE
    mov x8, #226                // mprotect
    svc #0                      // best-effort guard page at the bottom
    ldr x21, [x19]              // argc
    add x22, x19, #8            // argv
    add x23, x22, x21, lsl #3
    add x23, x23, #8            // envp, past the NULL after argv
    mov x24, #0                 // envp count
1:  ldr x9, [x23, x24, lsl #3]
    cbz x9, 2f
    add x24, x24, #1
    b 1b
2:  // place argc, argv..., NULL, envp..., NULL at the top of the mapping,
    // 16-aligned with x28 pointing at argc, the x86-64 entry shape
    add x9, x21, x24
    add x9, x9, #3
    IMM32 x11, STACK_SIZE
    add x10, x20, x11
    sub x28, x10, x9, lsl #3
    and x28, x28, #-16
    str x21, [x28]
    add x10, x28, #8
    mov x11, #0
3:  cmp x11, x21
    b.hs 4f
    ldr x9, [x22, x11, lsl #3]
    str x9, [x10], #8
    add x11, x11, #1
    b 3b
4:  str xzr, [x10], #8
    mov x11, #0
5:  cmp x11, x24
    b.hs 6f
    ldr x9, [x23, x11, lsl #3]
    str x9, [x10], #8
    add x11, x11, #1
    b 5b
6:  str xzr, [x10]
    bl _start                   // mov rdi, rsp; and rsp, -16; call os_init; ...
9:  brk #1                      // _start does not return (translated ud2)
