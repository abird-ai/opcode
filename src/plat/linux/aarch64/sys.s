.include "plat/linux/aarch64/linux.inc"

// opcode on Linux AArch64: the x86-64 Linux syscalls the translated code makes,
// natively. Native AArch64; never runs through tools/arm64.py.
//
// x_syscall takes the Linux syscall number in x8 (rax) and the arguments in
// x0 x1 x2 x6 x4 x5 (rdi rsi rdx r10 r8 r9), returns the result or -errno
// (Linux numbering) in x8, and emulates the x86 syscall instruction's clobber
// contract: besides x8 only x3 (rcx) and x7 (r11) may change; x0 x1 x2 x4 x5
// x6, q0-q7 and q16-q23 (xmm0-15) are saved and restored, and x28 (the
// translated rsp) is never touched. Flags carry no obligation across the
// call (the translator treats syscall as a flow terminator).
//
// The x86-64 and aarch64 syscall numbers differ (read 0->63, write 1->64,
// openat 257->56, ...), so x_syscall looks the x86 number up in sys_table and
// runs a per-syscall function: a pure number remap, or a conversion for the
// syscalls whose argument shape differs. A number with no entry returns
// -ENOSYS (38), never 0.
//
// rt_sigaction installs the native x_sig_tramp instead of a translated
// handler: the aarch64 kernel returns from a handler through its vDSO
// rt_sigreturn stub in x30, while a translated handler returns through the
// x86 stack (x28), so the trampoline builds an x86-shaped frame on x28,
// pushes a resume address, runs the translated handler and, when the
// handler returns, restores x28 and rets into the kernel's sigtramp.
// SA_RESETHAND is honoured by the kernel; the trampoline clears its recorded
// handler at delivery time so a later rt_sigaction query reports what the
// kernel would.

.equ NSYS, 320
.equ SIG_MAX, 32

.bss
.p2align 3
// Per-signal record of the action installed by rt_sigaction, in the x86-64
// struct sigaction layout (identical to aarch64 asm-generic): handler@0,
// flags@8, restorer@16, mask@24. All-zero = never installed = SIG_DFL.
sig_acts: .zero 32 * (SIG_MAX + 1)

.text

// ---------------------------------------------------------------- x_syscall
FN x_syscall
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    sub sp, sp, #368            // 304 saved registers + 64 bytes of scratch
    stp x0, x1, [sp, #0]
    stp x2, x4, [sp, #16]
    stp x5, x6, [sp, #32]
    stp q0, q1, [sp, #48]
    stp q2, q3, [sp, #80]
    stp q4, q5, [sp, #112]
    stp q6, q7, [sp, #144]
    stp q16, q17, [sp, #176]
    stp q18, q19, [sp, #208]
    stp q20, q21, [sp, #240]
    stp q22, q23, [sp, #272]
    mov x3, x6                 // arg4 from r10's home into svc's x3 slot
    cmp x8, #NSYS
    b.hs 1f
    ADR x9, sys_table
    ldr x9, [x9, x8, lsl #3]
    cbz x9, 1f
    blr x9                     // per-syscall fn: result (or -errno) in x0
    b 2f
1:  mov x0, #-L_ENOSYS
2:  mov x8, x0
    ldp x0, x1, [sp, #0]
    ldp x2, x4, [sp, #16]
    ldp x5, x6, [sp, #32]
    ldp q0, q1, [sp, #48]
    ldp q2, q3, [sp, #80]
    ldp q4, q5, [sp, #112]
    ldp q6, q7, [sp, #144]
    ldp q16, q17, [sp, #176]
    ldp q18, q19, [sp, #208]
    ldp q20, q21, [sp, #240]
    ldp q22, q23, [sp, #272]
    mov sp, x29
    ldp x29, x30, [sp], #16
    mov x7, #0                 // x86 syscall clobbers r11; no value promised
    ret

// ---------------------------------------------------------------- slow paths
// poll(fds, nfds, timeout_ms) -> ppoll(fds, nfds, ts, NULL, 8): the timeout
// is an int of milliseconds on x86-64 and a timespec pointer on aarch64.
// Negative (bit 31 set) means wait forever, as for an int timeout on x86-64.
sys_poll:
    tbnz x2, #31, 1f           // negative timeout: NULL timespec
    mov x9, #1000
    udiv x10, x2, x9           // seconds
    msub x9, x10, x9, x2       // milliseconds remainder
    IMM32 x11, 1000000
    mul x9, x9, x11            // nanoseconds
    str x10, [x29, #-64]
    str x9, [x29, #-56]
    add x2, x29, #-64
    b 2f
1:  mov x2, #0
2:  mov x3, #0                 // sigmask NULL
    mov x4, #8                 // sigsetsize: ppoll requires sizeof(sigset_t)
    mov x8, #73
    svc #0
    ret

// rename(old, new) -> renameat(AT_FDCWD, old, AT_FDCWD, new): renameat is
// (olddirfd x0, oldpath x1, newdirfd x2, newpath x3), both paths relative
// to the cwd.
sys_rename:
    mov x9, x0                  // oldpath
    mov x0, #-100               // olddirfd = AT_FDCWD
    mov x2, #-100               // newdirfd = AT_FDCWD
    mov x3, x1                  // newpath
    mov x1, x9                  // oldpath
    mov x8, #38
    svc #0
    ret

// dup2(old, new) -> dup3(old, new, 0)
sys_dup2:
    mov x2, #0
    mov x8, #24
    svc #0
    ret

// send(fd, buf, len, flags) -> sendto(fd, buf, len, flags, NULL, 0)
sys_send:
    mov x3, x6
    mov x4, #0
    mov x5, #0
    mov x8, #206
    svc #0
    ret

// recv(fd, buf, len, flags) -> recvfrom(fd, buf, len, flags, NULL, NULL)
sys_recv:
    mov x3, x6
    mov x4, #0
    mov x5, #0
    mov x8, #207
    svc #0
    ret

// fork() -> clone(SIGCHLD, 0, NULL, NULL, 0): aarch64 has no fork; a clone
// with only CSIGNAL|SIGCHLD and no child stack is it.
sys_fork:
    mov x0, #17                // SIGCHLD
    mov x1, #0
    mov x2, #0
    mov x3, #0
    mov x4, #0
    mov x8, #220
    svc #0
    ret

// fstat(fd, buf) -> fstat + aarch64 -> x86-64 struct stat conversion in buf.
// aarch64 asm-generic stat (128 B): st_mode@16 st_nlink@20 st_uid@24
// st_gid@28 st_rdev@32 st_size@48 st_blksize@56 st_blocks@64, times at
// 72/88/104. x86-64 stat (144 B): st_nlink@16 st_mode@24 st_uid@28 st_gid@32
// __pad0@36 st_rdev@40 st_size@48 st_blksize@56 st_blocks@64, times at
// 72/88/104, __unused@120. The translated consumers read st_mode (ls.s:319)
// and st_size (grep.s:650); every field is converted and the tail is zeroed.
// The loads all happen before the stores, so the in-buffer rewrite is safe.
sys_fstat:
    mov x8, #80
    svc #0
    tbnz x0, #63, 1f
    ldr x9, [x1, #0]           // st_dev
    ldr x10, [x1, #8]          // st_ino
    ldr w11, [x1, #16]         // st_mode
    ldr w12, [x1, #20]         // st_nlink
    ldr w13, [x1, #24]         // st_uid
    ldr w14, [x1, #28]         // st_gid
    ldr x15, [x1, #32]         // st_rdev
    ldr x16, [x1, #48]         // st_size
    ldrsw x17, [x1, #56]       // st_blksize (s32)
    ldr x2, [x1, #64]          // st_blocks (x2 is frame-restored later)
    str x9, [x1, #0]
    str x10, [x1, #8]
    str x12, [x1, #16]         // st_nlink, 32 -> 64 bits
    str w11, [x1, #24]         // st_mode
    str w13, [x1, #28]         // st_uid
    str w14, [x1, #32]         // st_gid
    str wzr, [x1, #36]         // __pad0
    str x15, [x1, #40]         // st_rdev
    str x16, [x1, #48]         // st_size
    str x17, [x1, #56]         // st_blksize, 32 -> 64 bits
    str x2, [x1, #64]          // st_blocks
    // st_atim/st_mtim/st_ctim keep their offsets (72/80, 88/96, 104/112)
    stp xzr, xzr, [x1, #120]   // __unused + pad
    str xzr, [x1, #136]
    mov x0, #0
1:  ret

// openat(dirfd, path, flags, mode): the O_* bits that differ between x86-64
// and asm-generic are translated; everything else (O_RDONLY..O_APPEND,
// O_NONBLOCK 0x800, O_NOCTTY 0x100, O_CLOEXEC 0x80000) is identical.
// x86-64 -> asm-generic (aarch64): O_DIRECT 0x4000 -> 0x10000,
// O_DIRECTORY 0x10000 -> 0x4000, O_NOFOLLOW 0x20000 -> 0x8000. The source
// bits are collected first because the translated targets reuse the same
// bit positions (0x4000/0x8000/0x10000).
sys_openat:
    mov x3, x6                  // mode (arg4, r10's home)
    mov x9, x2                  // x86-64 flags
    mov x10, #0                 // translated divergent bits
    and x11, x9, #0x4000        // x86-64 O_DIRECT
    cbz x11, 1f
    orr x10, x10, #0x10000      // asm-generic O_DIRECT
1:  and x11, x9, #0x10000       // x86-64 O_DIRECTORY
    cbz x11, 2f
    orr x10, x10, #0x4000       // asm-generic O_DIRECTORY
2:  and x11, x9, #0x20000       // x86-64 O_NOFOLLOW
    cbz x11, 3f
    orr x10, x10, #0x8000       // asm-generic O_NOFOLLOW
3:  IMM32 x11, 0x34000
    bic x9, x9, x11             // drop the three x86-64 bits
    orr x2, x9, x10
    mov x8, #56
    svc #0
    ret

// rt_sigaction(sig, act, oact, sigsetsize): the aarch64 kernel's struct
// sigaction has the same 32-byte layout as x86-64 (handler@0, flags@8,
// restorer@16, mask@24), but a translated handler must run under x_sig_tramp
// and the kernel ignores sa_restorer, so:
//   * a real handler installs the trampoline with the caller's flags/mask;
//     SA_SIGINFO is cleared because the trampoline delivers the plain signum;
//     SA_RESTORER is cleared too: it is inert on the real aarch64 kernel,
//     but qemu-user honours it and returns the handler through the caller's
//     sa_restorer (the translated .Lsig_restorer stub), whose rt_sigreturn
//     through x_syscall moves sp off the signal frame qemu locates it by —
//     a forced SIGSEGV (D4);
//   * SIG_DFL/SIG_IGN are installed with SA_RESTORER/restorer dropped;
//   * the caller's act is recorded per signal, and oact is answered from
//     that record: the kernel would report the trampoline, not the
//     translated handler, and opcode never queries (oact is NULL in both
//     callers, tty.s:154,197).
sys_rt_sigaction:
    cmp w0, #SIG_MAX
    b.hs 8f
    cbz x1, 9f                 // act == NULL: a query
    cbz x2, 2f                 // no oact
    ADR x12, sig_acts
    add x12, x12, x0, lsl #5
    ldp x13, x14, [x12, #0]
    stp x13, x14, [x2, #0]
    ldp x13, x14, [x12, #16]
    stp x13, x14, [x2, #16]
2:  ldr x9, [x1, #0]           // sa_handler
    cmp x9, #1
    b.ls 3f                    // SIG_DFL (0) / SIG_IGN (1)
    // a real translated handler: record it, install the trampoline instead
    ldr w11, [x1, #8]          // sa_flags
    ldr x13, [x1, #24]         // sa_mask
    bic w11, w11, #4           // SA_SIGINFO off: we deliver the signum in x0
    bic w11, w11, #0x04000000  // SA_RESTORER off: qemu-user would honour it
    ADR x14, sig_acts
    add x14, x14, x0, lsl #5
    str x9, [x14, #0]          // the translated handler
    str x11, [x14, #8]         // sa_flags: full 64 bits (w11 zero-extends)
    str xzr, [x14, #16]        // sa_restorer: not installed (kernel-inert)
    str x13, [x14, #24]
    adr x9, x_sig_tramp
    add x10, x29, #-64         // native act in the scratch area
    str x9, [x10, #0]
    str x11, [x10, #8]         // sa_flags: full 64 bits
    str xzr, [x10, #16]
    str x13, [x10, #24]
    mov x1, x10
    b 4f
3:  // SIG_DFL / SIG_IGN: install with SA_RESTORER/restorer dropped, so no
    // path can ever return through the caller's dead x86 restorer stub
    add x10, x29, #-64
    ldp x9, x11, [x1, #0]
    stp x9, x11, [x10, #0]
    ldp x9, x11, [x1, #16]
    stp x9, x11, [x10, #16]
    ldr w11, [x10, #8]
    bic w11, w11, #0x04000000
    str x11, [x10, #8]         // sa_flags: clear the full 64-bit slot
    str xzr, [x10, #16]
    ADR x14, sig_acts
    add x14, x14, x0, lsl #5
    ldp x9, x11, [x10, #0]
    stp x9, x11, [x14, #0]
    ldp x9, x11, [x10, #16]
    stp x9, x11, [x14, #16]
    mov x1, x10
4:  mov x2, #0                 // oact answered above; the kernel must not fill it
    mov x3, x6                 // sigsetsize (the translated code passes 8)
    mov x8, #134
    svc #0
    b 7f
9:  cbz x2, 7f                 // query with no oact: nothing to answer
    ADR x12, sig_acts
    add x12, x12, x0, lsl #5
    ldp x13, x14, [x12, #0]
    stp x13, x14, [x2, #0]
    ldp x13, x14, [x12, #16]
    stp x13, x14, [x2, #16]
    mov x0, #0
    b 7f
8:  mov x0, #-L_EINVAL
7:  ret

// x_sig_tramp(signum): the handler the kernel actually calls. It runs with
// x0 = signum, x30 = the kernel's vDSO rt_sigreturn stub, sp = the signal
// frame, and x28 = the interrupted translated rsp. A translated handler
// returns through x28, so push a resume address there (with the x86 kernel's
// rsp = 8 mod 16 handler-entry alignment), run the handler and return into
// the kernel's sigtramp, which restores the interrupted registers.
FN x_sig_tramp
    cmp w0, #SIG_MAX
    b.hs 9f
    ADR x9, sig_acts
    add x9, x9, x0, lsl #5
    ldr x11, [x9, #0]          // recorded handler
    cbz x11, 9f
    ldr w10, [x9, #8]          // recorded flags
    tbz w10, #31, 1f           // SA_RESETHAND?
    str xzr, [x9, #0]          // clear before delivery, like the x86 kernel
1:  mov x10, x28
    tbz x10, #3, 2f            // bit3 == 0 -> already 16-byte aligned
    sub x10, x10, #8
2:  adr x12, L_sig_finish
    str x12, [x10, #-8]!       // resume address; handler sees x28 = 8 mod 16
    stp x28, x30, [sp, #-16]!  // keep the interrupted rsp and the sigtramp
    mov x28, x10
    blr x11
L_sig_finish:
    ldp x28, x30, [sp], #16
9:  ret                        // x30 -> kernel vDSO rt_sigreturn

// ---------------------------------------------------------------- remaps
// Pure number remaps: arguments keep their slots (arg4 was moved x6 -> x3
// before the dispatch), so two instructions per syscall are enough.
.macro REMAP name, nr
.p2align 2
\name:
    mov x8, #\nr
    svc #0
    ret
.endm

REMAP sys_read, 63
REMAP sys_write, 64
REMAP sys_close, 57
REMAP sys_lseek, 62
REMAP sys_mmap, 222
REMAP sys_munmap, 215
REMAP sys_rt_sigreturn, 139    // the .Lsig_restorer stub (tty.s:243); dead on aarch64
REMAP sys_ioctl, 29
REMAP sys_dup, 23
REMAP sys_nanosleep, 101
REMAP sys_getpid, 172
REMAP sys_socket, 198
REMAP sys_connect, 203
REMAP sys_shutdown, 210
REMAP sys_bind, 200
REMAP sys_listen, 201
REMAP sys_getsockname, 204
REMAP sys_setsockopt, 208
REMAP sys_getsockopt, 209
REMAP sys_execve, 221
REMAP sys_wait4, 260
REMAP sys_kill, 129
REMAP sys_fcntl, 25
REMAP sys_fchmod, 52
REMAP sys_fsync, 82
REMAP sys_getcwd, 17
REMAP sys_chdir, 49
REMAP sys_getdents64, 61
REMAP sys_clock_gettime, 113
REMAP sys_exit_group, 94
REMAP sys_mkdirat, 34
REMAP sys_unlinkat, 35
REMAP sys_accept4, 242
REMAP sys_pipe2, 59
REMAP sys_getrandom, 278
REMAP sys_setpgid, 154

// ---------------------------------------------------------------- sys_table
// 8 bytes per x86-64 syscall number; a zero slot returns -ENOSYS.
.section .rodata
.p2align 3
.macro SYS num, fn
    .org sys_table + \num * 8
    .quad \fn
.endm
sys_table:
    SYS 0, sys_read
    SYS 1, sys_write
    SYS 3, sys_close
    SYS 5, sys_fstat
    SYS 7, sys_poll
    SYS 8, sys_lseek
    SYS 9, sys_mmap
    SYS 11, sys_munmap
    SYS 13, sys_rt_sigaction
    SYS 15, sys_rt_sigreturn
    SYS 16, sys_ioctl
    SYS 32, sys_dup
    SYS 33, sys_dup2
    SYS 35, sys_nanosleep
    SYS 39, sys_getpid
    SYS 41, sys_socket
    SYS 42, sys_connect
    SYS 44, sys_send
    SYS 45, sys_recv
    SYS 48, sys_shutdown
    SYS 49, sys_bind
    SYS 50, sys_listen
    SYS 51, sys_getsockname
    SYS 54, sys_setsockopt
    SYS 55, sys_getsockopt
    SYS 57, sys_fork
    SYS 59, sys_execve
    SYS 61, sys_wait4
    SYS 62, sys_kill
    SYS 72, sys_fcntl
    SYS 74, sys_fsync
    SYS 79, sys_getcwd
    SYS 80, sys_chdir
    SYS 82, sys_rename
    SYS 91, sys_fchmod
    SYS 109, sys_setpgid
    SYS 217, sys_getdents64
    SYS 228, sys_clock_gettime
    SYS 231, sys_exit_group
    SYS 257, sys_openat
    SYS 258, sys_mkdirat
    SYS 263, sys_unlinkat
    SYS 288, sys_accept4
    SYS 293, sys_pipe2
    SYS 318, sys_getrandom
    .org sys_table + NSYS * 8
