// opcode on macOS: the Linux system calls opcode makes, on libSystem.
//
// Adapted from rhun (MIT), src/mac/linux.s <https://github.com/earendil-works/rhun>;
// see THIRD_PARTY.md. rhun's structure and naming survive so a future re-vendor
// stays a clean diff. The local modifications are:
//   - the socket stubs live in src/net/mac/net.s (network-layer concerns) and the
//     sys_table below references their globals,
//   - sys_mkdirat (258), sys_unlinkat (263), sys_dup (32), sys_socketpair (53,
//     used by the arm64 smoke program) and sys_getrandom (318) were added,
//   - rt_sigaction installs a native trampoline so a *translated* handler runs,
//     instead of rhun's SIG_DFL/SIG_IGN-only subset,
//   - pty-path and pty-ioctl translation was dropped (opcode opens no ptys),
//   - rhun's AppKit hooks g_xsp/g_poll_hook were dropped (opcode has no AppKit).
//
// x_syscall takes the Linux number in x8 (rax) and arguments in x0 x1 x2 x6 x4 x5
// (rdi rsi rdx r10 r8 r9), returns the result or -errno (Linux numbering) in x8,
// and keeps every other register the x86 syscall instruction keeps: besides x8
// only x3 (rcx) and x7 (r11) are clobbered. x0 x1 x2 x4 x5 x6 and q0-q23 are
// saved/restored, and x28 (the translated rsp) is never touched. Flags,
// structures and error numbers are converted where Darwin differs.
.include "mac.inc"

.equ NSYS, 320
.equ SIG_MAX, 32

// mac.inc owns the L_* error constants; these guards only supply the few this
// file needs when it is assembled before mac.inc lands.
.ifndef L_ENOSYS
.equ L_ENOSYS, 38
.endif
.ifndef L_ENOTTY
.equ L_ENOTTY, 25
.endif

.text

FN x_syscall
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    sub sp, sp, #304
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
    mov x3, x6
    cmp x8, #NSYS
    b.hs 1f
    adrp x9, sys_table@PAGE
    add x9, x9, sys_table@PAGEOFF
    ldr x9, [x9, x8, lsl #3]
    cbz x9, 1f
    blr x9
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
    ret

// linux_ret(x0): a libSystem -1 becomes -errno in Linux numbering. Shared with
// net/mac/net.s, which is why it is global here.
.globl linux_ret
linux_ret:
    cmn x0, #1
    b.ne 1f
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl ___error
    ldr w0, [x0]
    bl linux_errno
    neg x0, x0
    ldp x29, x30, [sp], #16
1:  ret

// linux_errno(w0 Darwin errno) -> x0 Linux errno
linux_errno:
    cmp w0, #107
    b.hs 1f
    adrp x9, errno_map@PAGE
    add x9, x9, errno_map@PAGEOFF
    ldrb w0, [x9, w0, uxtw]
    ret
1:  mov x0, #5
    ret

// a system call that is one libSystem function; kind 32 when it returns int
.macro LIBC name, fn, kind=64
\name:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl \fn
    .if \kind == 32
    sxtw x0, w0
    .endif
    bl linux_ret
    ldp x29, x30, [sp], #16
    ret
.endm

LIBC sys_read, _read
LIBC sys_write, _write
LIBC sys_lseek, _lseek
LIBC sys_poll, _poll, 32
LIBC sys_munmap, _munmap, 32
LIBC sys_dup, _dup, 32
LIBC sys_dup2, _dup2, 32
LIBC sys_nanosleep, _nanosleep, 32
LIBC sys_getpid, _getpid, 32
LIBC sys_fork, _fork, 32
LIBC sys_execve, _execve, 32
LIBC sys_kill, _kill, 32
LIBC sys_fsync, _fsync, 32
LIBC sys_chdir, _chdir, 32
LIBC sys_rename, _rename, 32
LIBC sys_fchmod, _fchmod, 32
LIBC sys_setpgid, _setpgid, 32

// wait4(pid, status, options, rusage): Darwin encodes the status alike; rusage
// is not filled
FN sys_wait4
    mov x3, #0
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl _wait4
    sxtw x0, w0
    bl linux_ret
    ldp x29, x30, [sp], #16
    ret

FN sys_exit_group
    bl __exit

FN sys_exit
    bl __exit

// ---------------------------------------------------------------- files
// open_flags(w1 Linux open flags) -> w1 Darwin flags
open_flags:
    and w9, w1, #3
    tst w1, #0x40
    b.eq 1f
    orr w9, w9, #0x200          // O_CREAT
1:  tst w1, #0x80
    b.eq 1f
    orr w9, w9, #0x800          // O_EXCL
1:  tst w1, #0x200
    b.eq 1f
    orr w9, w9, #0x400          // O_TRUNC
1:  tst w1, #0x400
    b.eq 1f
    orr w9, w9, #0x8            // O_APPEND
1:  tst w1, #0x800
    b.eq 1f
    orr w9, w9, #0x4            // O_NONBLOCK
1:  tst w1, #0x10000
    b.eq 1f
    orr w9, w9, #0x100000       // O_DIRECTORY
1:  tst w1, #0x20000
    b.eq 1f
    orr w9, w9, #0x100          // O_NOFOLLOW
1:  tst w1, #0x80000
    b.eq 1f
    orr w9, w9, #0x1000000      // O_CLOEXEC
1:  tst w1, #0x100
    b.eq 1f
    orr w9, w9, #0x20000        // O_NOCTTY
1:  mov w1, w9
    ret

// openat(dirfd, path, flags, mode)
FN sys_openat
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    cmn w0, #100
    b.ne 1f
    mov w0, #-2                 // AT_FDCWD
1:  mov x10, x1
    mov w1, w2
    bl open_flags
    mov w2, w1
    mov x1, x10
    sub sp, sp, #16
    str x3, [sp]
    bl _openat
    add sp, sp, #16
    sxtw x0, w0
    bl linux_ret
    ldp x29, x30, [sp], #16
    ret

// mkdirat(dirfd, path, mode): Darwin has mkdirat at the same ABI
FN sys_mkdirat
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    cmn w0, #100
    b.ne 1f
    mov w0, #-2                 // AT_FDCWD
1:  bl _mkdirat
    sxtw x0, w0
    bl linux_ret
    ldp x29, x30, [sp], #16
    ret

// unlinkat(dirfd, path, flags): Linux AT_REMOVEDIR 0x200 -> Darwin 0x80
FN sys_unlinkat
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    cmn w0, #100
    b.ne 1f
    mov w0, #-2                 // AT_FDCWD
1:  and w9, w2, #0x200
    cbz w9, 3f
    mov w2, #0x80              // AT_REMOVEDIR
    b 4f
3:  mov w2, #0
4:  bl _unlinkat
    sxtw x0, w0
    bl linux_ret
    ldp x29, x30, [sp], #16
    ret

// close(fd): directories being listed close with their DIR
FN sys_close
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    cmp w0, #1024
    b.hs 1f
    adrp x9, dirs@PAGE
    add x9, x9, dirs@PAGEOFF
    ldr x10, [x9, w0, uxtw #3]
    cbz x10, 1f
    str xzr, [x9, w0, uxtw #3]
    adrp x9, pend@PAGE
    add x9, x9, pend@PAGEOFF
    str xzr, [x9, w0, uxtw #3]
    mov x0, x10
    bl _closedir
    b 2f
1:  bl _close
2:  sxtw x0, w0
    bl linux_ret
    ldp x29, x30, [sp], #16
    ret

// stat_linux(x0 Darwin stat, x1 Linux stat)
stat_linux:
    ldr w9, [x0, #0]            // st_dev is 32-bit on Darwin: zero-extend
    str x9, [x1, #0]            // st_dev
    ldr x9, [x0, #8]
    str x9, [x1, #8]            // st_ino
    ldrh w9, [x0, #6]
    str x9, [x1, #16]           // st_nlink
    ldrh w9, [x0, #4]
    str w9, [x1, #24]           // st_mode
    ldr w9, [x0, #16]
    str w9, [x1, #28]           // st_uid
    ldr w9, [x0, #20]
    str w9, [x1, #32]           // st_gid
    str wzr, [x1, #36]
    ldr w9, [x0, #24]           // st_rdev is 32-bit on Darwin: zero-extend
    str x9, [x1, #40]           // st_rdev
    ldr x9, [x0, #96]
    str x9, [x1, #48]           // st_size
    ldrsw x9, [x0, #112]
    str x9, [x1, #56]           // st_blksize
    ldr x9, [x0, #104]
    str x9, [x1, #64]           // st_blocks
    ldp x9, x10, [x0, #32]
    stp x9, x10, [x1, #72]      // st_atim
    ldp x9, x10, [x0, #48]
    stp x9, x10, [x1, #88]      // st_mtim
    ldp x9, x10, [x0, #64]
    stp x9, x10, [x1, #104]     // st_ctim
    stp xzr, xzr, [x1, #120]
    str xzr, [x1, #136]
    ret

// fstat(fd, buf)
FN sys_fstat
    stp x29, x30, [sp, #-176]!
    mov x29, sp
    str x1, [sp, #16]
    add x1, sp, #32
    bl _fstat
    sxtw x0, w0
    bl linux_ret
    tbnz x0, #63, 1f
    add x0, sp, #32
    ldr x1, [sp, #16]
    bl stat_linux
    mov x0, #0
1:  ldp x29, x30, [sp], #176
    ret

// getdents64(fd, buf, count): readdir on a DIR kept per descriptor; an entry
// that does not fit waits in pend (readdir's buffer stays valid until the next
// call). Records are Linux dirent64: d_reclen at +16, d_type at +18, name at +19.
FN sys_getdents64
    ENTER 16
    mov w19, w0
    mov x20, x1
    mov x21, x2
    mov x22, #0                 // bytes written
    cmp w19, #1024
    b.hs 6f
    adrp x9, dirs@PAGE
    add x9, x9, dirs@PAGEOFF
    ldr x23, [x9, w19, uxtw #3]
    cbnz x23, 1f
    mov w0, w19
    bl _fdopendir
    cbz x0, 8f
    mov x23, x0
    adrp x9, dirs@PAGE
    add x9, x9, dirs@PAGEOFF
    str x23, [x9, w19, uxtw #3]
1:  adrp x9, pend@PAGE
    add x9, x9, pend@PAGEOFF
    ldr x25, [x9, w19, uxtw #3]
    str xzr, [x9, w19, uxtw #3]
    cbnz x25, 2f
    mov x0, x23
    bl _readdir
    cbz x0, 7f
    mov x25, x0
2:  ldrh w26, [x25, #18]        // d_namlen
    add x27, x26, #19 + 1 + 7   // header, name, NUL, rounded to 8
    and x27, x27, #~7
    add x9, x22, x27
    cmp x9, x21
    b.hi 5f
    add x0, x20, x22
    ldr x9, [x25, #0]
    str x9, [x0, #0]            // d_ino
    str x9, [x0, #8]            // d_off (unused)
    strh w27, [x0, #16]         // d_reclen
    ldrb w9, [x25, #20]
    strb w9, [x0, #18]          // d_type
    add x0, x0, #19
    add x1, x25, #21
    mov x2, x26
    bl _memcpy
    add x9, x20, x22
    add x9, x9, #19
    strb wzr, [x9, x26]
    add x22, x22, x27
    b 1b
5:  adrp x9, pend@PAGE
    add x9, x9, pend@PAGEOFF
    str x25, [x9, w19, uxtw #3]
    cbnz x22, 7f
6:  mov x0, #-22                // EINVAL: buffer too small, or a descriptor past the table
    b 9f
7:  mov x0, x22
    b 9f
8:  mov x0, #-1
    bl linux_ret
9:  LEAVE
    ret

// mmap(addr, len, prot, flags, fd, off)
FN sys_mmap
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    mov w10, #0x13              // MAP_SHARED MAP_PRIVATE MAP_FIXED
    and w9, w3, w10
    tst w3, #0x20
    b.eq 1f
    orr w9, w9, #0x1000         // MAP_ANON
    mov w4, #-1
1:  mov w3, w9
    bl _mmap
    bl linux_ret
    ldp x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------- signals
// rt_sigaction(sig, act, oact, setsize): Darwin has no sa_restorer, so a native
// trampoline (x_sig_tramp) is installed with signal() and the translated handler
// is stored per signal. The trampoline honours Linux SA_RESETHAND; SA_RESTART is
// what signal() already gives. opcode never queries the old action (oact is NULL).
// A signal number outside the table, or a libSystem install failure, is not a
// silent success: both return -errno like every other translated call.
FN sys_rt_sigaction
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x0, [sp, #16]           // sig
    cmp w0, #SIG_MAX
    b.hs 8f                     // out of range -> -EINVAL
    mov x0, #0
    cbz x1, 9f                  // NULL act is a query: success
    str x1, [sp, #24]           // act
    ldr x9, [x1]                // Linux sa_handler
    cmp x9, #1
    b.hi 2f                     // a real handler
    mov x1, x9                  // SIG_DFL (0) or SIG_IGN (1)
    bl _signal
    bl linux_ret                // signal() -1 becomes -errno
    tbnz x0, #63, 9f            // install failed
    ldr x0, [sp, #16]
    adrp x9, sig_handlers@PAGE
    add x9, x9, sig_handlers@PAGEOFF
    str xzr, [x9, x0, lsl #3]
    adrp x9, sig_flags@PAGE
    add x9, x9, sig_flags@PAGEOFF
    str wzr, [x9, x0, lsl #2]
    mov x0, #0
    b 9f
2:  adrp x1, x_sig_tramp@PAGE
    add x1, x1, x_sig_tramp@PAGEOFF
    bl _signal
    bl linux_ret                // signal() -1 becomes -errno
    tbnz x0, #63, 9f            // install failed
    ldr x1, [sp, #24]           // act
    ldr x9, [x1]                // Linux sa_handler
    ldr w11, [x1, #8]           // Linux sa_flags
    ldr x0, [sp, #16]
    adrp x10, sig_handlers@PAGE
    add x10, x10, sig_handlers@PAGEOFF
    str x9, [x10, x0, lsl #3]
    adrp x10, sig_flags@PAGE
    add x10, x10, sig_flags@PAGEOFF
    str w11, [x10, x0, lsl #2]
    mov x0, #0
    b 9f
8:  mov x0, #-L_EINVAL
9:  ldp x29, x30, [sp], #32
    ret

// x_sig_tramp(signo): the installed Darwin handler. It saves the interrupted
// x28, builds an x86-shaped stack for the translated handler, runs it, and
// returns through L_sig_finish (which the handler reaches via x28). A translated
// handler's ret pops x28, so the return address pushed here is what resumes.
FN x_sig_tramp
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x28, [sp, #16]
    cmp w0, #SIG_MAX
    b.hs 8f
    adrp x9, sig_handlers@PAGE
    add x9, x9, sig_handlers@PAGEOFF
    ldr x9, [x9, x0, lsl #3]
    cbz x9, 8f
    str x0, [sp, #0]
    str x9, [sp, #8]
    adrp x10, sig_flags@PAGE
    add x10, x10, sig_flags@PAGEOFF
    ldr w10, [x10, x0, lsl #2]
    tbnz w10, #31, 2f           // Linux SA_RESETHAND: one shot
1:  ldr x0, [sp, #0]
    ldr x9, [sp, #8]
    mov x10, sp
    sub x10, x10, #2048         // x86 stack below the native one, no overlap
    and x10, x10, #-16
    adr x11, L_sig_finish
    str x11, [x10, #-8]!
    mov x28, x10
    blr x9
L_sig_finish:
    mov sp, x29
    ldr x28, [sp, #16]
    ldp x29, x30, [sp], #32
    ret
2:  ldr w9, [sp, #0]
    adrp x10, sig_handlers@PAGE
    add x10, x10, sig_handlers@PAGEOFF
    str xzr, [x10, x9, lsl #3]
    mov x0, x9
    mov x1, #0                  // SIG_DFL
    bl _signal
    b 1b
8:  mov sp, x29
    ldr x28, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------- terminal
.macro IMM32 reg, v
    mov \reg, #((\v) & 0xffff)
    movk \reg, #((\v) >> 16), lsl #16
.endm
.macro IS req, label
    IMM32 w9, \req
    cmp w1, w9
    b.eq \label
.endm

.equ T_TIOCSCTTY, 0x20007461
.equ T_TIOCSWINSZ, 0x80087467
.equ T_TIOCGWINSZ, 0x40087468
.equ T_TIOCGETA, 0x40487413
.equ T_TIOCSETA, 0x80487414

// ioctl3(w0 fd, x1 request, x2 arg) -> w0: the argument is variadic, so on the stack
ioctl3:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    sub sp, sp, #16
    str x2, [sp]
    bl _ioctl
    add sp, sp, #16
    ldp x29, x30, [sp], #16
    ret

// Termios flag translation.  Linux and Darwin put the same flags at different
// bit positions (ICANON 0x2/0x100, ISIG 0x1/0x80, IXON 0x400/0x200, ICRNL
// 0x100/0x100, oflag ONLCR 0x4/0x2, ...).  Each table entry is a
// (linux_bit, darwin_bit) pair; the mapping sets or clears the destination bit
// for every mapped source bit and leaves destination bits outside the tables
// alone (so the Darwin delay fields and flow-control bits survive a round trip).
// Caller keeps x9/x20; these clobber x2/x4/x5/x10 and w0/w1.
// flags_m2l(w1 Darwin word, x2 table, x0 current Linux word) -> w0 Linux word
flags_m2l:
    mov w10, w0
1:  ldr w4, [x2]
    cbz w4, 9f
    ldr w5, [x2, #4]
    tst w1, w5
    b.eq 2f
    orr w10, w10, w4
    b 3f
2:  bic w10, w10, w4
3:  add x2, x2, #8
    b 1b
9:  mov w0, w10
    ret

// flags_l2m(w1 Linux word, x2 table, x0 current Darwin word) -> w0 Darwin word
flags_l2m:
    mov w10, w0
1:  ldr w4, [x2]
    cbz w4, 9f
    ldr w5, [x2, #4]
    tst w1, w4
    b.eq 2f
    orr w10, w10, w5
    b 3f
2:  bic w10, w10, w5
3:  add x2, x2, #8
    b 1b
9:  mov w0, w10
    ret

// ioctl(fd, request, arg): the terminal requests opcode makes, converted to
// Darwin numbering. The Linux kernel termios is 4 u32 flags, c_line and a
// 19-byte c_cc[]; Darwin's is 4 u64 flags, c_cc[20] and speeds.
FN sys_ioctl
    stp x29, x30, [sp, #-240]!
    mov x29, sp
    stp x19, x20, [sp, #16]
    mov w19, w0
    mov x20, x2
    IS 0x540e, 1f
    IS 0x5414, 2f
    IS 0x5413, 3f
    IS 0x5401, 6f
    IS 0x5402, 7f
    mov x0, #-L_ENOTTY
    b 99f
1:  IMM32 w1, T_TIOCSCTTY
    b 10f
2:  IMM32 w1, T_TIOCSWINSZ
    b 10f
3:  IMM32 w1, T_TIOCGWINSZ
10: bl ioctl3
    b 98f
6:  // TCGETS: Darwin termios -> Linux kernel termios, flags bit-by-bit
    mov w0, w19
    IMM32 w1, T_TIOCGETA
    add x2, sp, #64
    bl ioctl3
    cbnz w0, 98f
    add x9, sp, #64
    adrp x2, iflag_tbl@PAGE
    add x2, x2, iflag_tbl@PAGEOFF
    ldr w1, [x9, #0]
    mov w0, #0
    bl flags_m2l
    str w0, [x20, #0]
    adrp x2, oflag_tbl@PAGE
    add x2, x2, oflag_tbl@PAGEOFF
    ldr w1, [x9, #8]
    mov w0, #0
    bl flags_m2l
    str w0, [x20, #4]
    adrp x2, cflag_tbl@PAGE
    add x2, x2, cflag_tbl@PAGEOFF
    ldr w1, [x9, #16]
    mov w0, #0
    bl flags_m2l
    str w0, [x20, #8]
    adrp x2, lflag_tbl@PAGE
    add x2, x2, lflag_tbl@PAGEOFF
    ldr w1, [x9, #24]
    mov w0, #0
    bl flags_m2l
    str w0, [x20, #12]
    strb wzr, [x20, #16]        // c_line
    adrp x12, cc_map@PAGE
    add x12, x12, cc_map@PAGEOFF
    mov x10, #0
62: ldrb w11, [x12, x10]
    mov w13, #0
    cmp w11, #0xff
    b.eq 63f
    add x13, x9, #32
    ldrb w13, [x13, w11, uxtw]
63: add x14, x20, #17
    strb w13, [x14, x10]
    add x10, x10, #1
    cmp x10, #19
    b.lo 62b
    ldr w11, [x9, #56]          // c_ispeed: Darwin u64 -> Linux u32
    str w11, [x20, #52]
    ldr w11, [x9, #64]          // c_ospeed
    str w11, [x20, #56]
    mov w0, #0
    b 98f
7:  // TCSETS: Linux flags bit-by-bit onto the current Darwin termios
    mov w0, w19
    IMM32 w1, T_TIOCGETA
    add x2, sp, #64
    bl ioctl3
    cbnz w0, 98f
    add x9, sp, #64
    adrp x2, iflag_tbl@PAGE
    add x2, x2, iflag_tbl@PAGEOFF
    ldr w0, [x9, #0]
    ldr w1, [x20, #0]
    bl flags_l2m
    str w0, [x9, #0]
    adrp x2, oflag_tbl@PAGE
    add x2, x2, oflag_tbl@PAGEOFF
    ldr w0, [x9, #8]
    ldr w1, [x20, #4]
    bl flags_l2m
    str w0, [x9, #8]
    adrp x2, cflag_tbl@PAGE
    add x2, x2, cflag_tbl@PAGEOFF
    ldr w0, [x9, #16]
    ldr w1, [x20, #8]
    bl flags_l2m
    str w0, [x9, #16]
    adrp x2, lflag_tbl@PAGE
    add x2, x2, lflag_tbl@PAGEOFF
    ldr w0, [x9, #24]
    ldr w1, [x20, #12]
    bl flags_l2m
    str w0, [x9, #24]
    adrp x12, cc_map@PAGE
    add x12, x12, cc_map@PAGEOFF
    mov x10, #0
72: ldrb w11, [x12, x10]
    cmp w11, #0xff
    b.eq 73f
    add x14, x20, #17
    ldrb w13, [x14, x10]
    add x15, x9, #32
    strb w13, [x15, w11, uxtw]
73: add x10, x10, #1
    cmp x10, #19
    b.lo 72b
    ldr w11, [x20, #52]         // c_ispeed: Linux u32 -> Darwin u64
    str x11, [x9, #56]
    ldr w11, [x20, #56]
    str x11, [x9, #64]
    mov w0, w19
    IMM32 w1, T_TIOCSETA
    add x2, sp, #64
    bl ioctl3
98: sxtw x0, w0
    bl linux_ret
    b 99f
99: ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #240
    ret

// ---------------------------------------------------------------- process I/O
// fcntl(fd, cmd, arg): the O_NONBLOCK and O_APPEND bits differ
FN sys_fcntl
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x1, [sp, #16]
    cmp w1, #4                  // F_SETFL
    b.ne 1f
    and w9, w2, #3
    tst w2, #0x800
    b.eq 2f
    orr w9, w9, #4
2:  tst w2, #0x400
    b.eq 3f
    orr w9, w9, #8
3:  mov w2, w9
1:  sub sp, sp, #16
    str x2, [sp]
    bl _fcntl
    add sp, sp, #16
    sxtw x0, w0
    bl linux_ret
    ldr x1, [sp, #16]
    cmp w1, #3                  // F_GETFL
    b.ne 9f
    tbnz x0, #63, 9f
    and w9, w0, #3
    tst w0, #4
    b.eq 4f
    orr w9, w9, #0x800
4:  tst w0, #8
    b.eq 5f
    orr w9, w9, #0x400
5:  mov w0, w9
9:  ldp x29, x30, [sp], #32
    ret

// set_fl(w0 fd, w1 Linux flags): O_NONBLOCK and O_CLOEXEC after the fact; keeps x0.
// Shared with net/mac/net.s, which is why it is global here.
.globl set_fl
set_fl:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x0, x1, [sp, #16]
    tbnz w0, #31, 9f
    tst w1, #0x800
    b.eq 1f
    sub sp, sp, #16
    mov x9, #4                  // O_NONBLOCK
    str x9, [sp]
    mov w1, #4                  // F_SETFL
    bl _fcntl
    add sp, sp, #16
1:  ldp x0, x1, [sp, #16]
    tst w1, #0x80000
    b.eq 9f
    sub sp, sp, #16
    mov x9, #1                  // FD_CLOEXEC
    str x9, [sp]
    mov w1, #2                  // F_SETFD
    bl _fcntl
    add sp, sp, #16
9:  ldp x0, x1, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

// pipe2(fds, flags)
FN sys_pipe2
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    stp x0, x1, [sp, #16]
    bl _pipe
    sxtw x0, w0
    bl linux_ret
    tbnz x0, #63, 9f
    ldp x9, x1, [sp, #16]
    ldr w0, [x9]
    bl set_fl
    ldp x9, x1, [sp, #16]
    ldr w0, [x9, #4]
    bl set_fl
    mov x0, #0
9:  ldp x29, x30, [sp], #32
    ret

// clock_gettime(clock, ts): Linux CLOCK_MONOTONIC=1 is Darwin's 6
FN sys_clock_gettime
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    cmp w0, #1
    b.ne 1f
    mov w0, #6
1:  bl _clock_gettime
    sxtw x0, w0
    bl linux_ret
    ldp x29, x30, [sp], #16
    ret

// getcwd(buf, size) -> length with the NUL
FN sys_getcwd
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x0, [sp, #16]
    bl _getcwd
    cbnz x0, 1f
    mov x0, #-1
    bl linux_ret
    b 9f
1:  ldr x0, [sp, #16]
    bl _strlen
    add x0, x0, #1
9:  ldp x29, x30, [sp], #32
    ret

// getrandom(buf, len, flags): Darwin has no getrandom; getentropy is capped at
// 256 bytes a call, so loop, and fall back to arc4random_buf (which cannot fail).
FN sys_getrandom
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    str x0, [sp, #16]           // buf
    str x1, [sp, #24]           // remaining
1:  ldr x10, [sp, #24]
    cbz x10, 9f
    ldr x0, [sp, #16]
    mov x1, #256
    cmp x10, #256
    b.hs 2f
    mov x1, x10
2:  str x1, [sp, #8]            // chunk
    bl _getentropy
    cbnz w0, 3f
    ldr x1, [sp, #8]
    ldr x9, [sp, #16]
    add x9, x9, x1
    str x9, [sp, #16]
    ldr x10, [sp, #24]
    sub x10, x10, x1
    str x10, [sp, #24]
    b 1b
3:  ldr x0, [sp, #16]
    ldr x1, [sp, #24]
    bl _arc4random_buf
9:  mov x0, #0
    ldp x29, x30, [sp], #32
    ret

// ---------------------------------------------------------------- sys_table
// 8 bytes per Linux syscall number; a zero slot returns -ENOSYS. The socket
// stubs are defined in src/net/mac/net.s and resolve at link time.
.section __DATA,__const
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
    SYS 53, sys_socketpair
    SYS 54, sys_setsockopt
    SYS 55, sys_getsockopt
    SYS 57, sys_fork
    SYS 59, sys_execve
    SYS 60, sys_exit
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

// Linux c_cc index -> Darwin's (0xff: none): VINTR VQUIT VERASE VKILL VEOF VTIME
// VMIN VSWTC VSTART VSTOP VSUSP VEOL VREPRINT VDISCARD VWERASE VLNEXT VEOL2,
// then Linux's two unused slots
cc_map: .byte 8, 9, 3, 5, 0, 17, 16, 0xff, 12, 13, 10, 1, 6, 15, 4, 14, 2, 0xff, 0xff

// Termios flag bit maps, (linux_bit, darwin_bit) pairs terminated by (0,0).
// Darwin constants from <sys/termios.h>; Linux from <bits/termios-c_*.h>.
// iflag: only IXON and IXOFF move; everything else is common.
.p2align 3
iflag_tbl:
    .long 0x1,    0x1           // IGNBRK
    .long 0x2,    0x2           // BRKINT
    .long 0x4,    0x4           // IGNPAR
    .long 0x8,    0x8           // PARMRK
    .long 0x10,   0x10          // INPCK
    .long 0x20,   0x20          // ISTRIP
    .long 0x40,   0x40          // INLCR
    .long 0x80,   0x80          // IGNCR
    .long 0x100,  0x100         // ICRNL
    .long 0x400,  0x200         // IXON
    .long 0x800,  0x800         // IXANY
    .long 0x1000, 0x400         // IXOFF
    .long 0x2000, 0x2000        // IMAXBEL
    .long 0x4000, 0x4000        // IUTF8
    .long 0, 0
// oflag: the simple bits only; the Linux/Darwin delay fields encode differently
// and opcode never touches c_oflag, so those Darwin bits are left alone.
oflag_tbl:
    .long 0x1,   0x1            // OPOST
    .long 0x4,   0x2            // ONLCR
    .long 0x8,   0x10           // OCRNL
    .long 0x10,  0x20           // ONOCR
    .long 0x20,  0x40           // ONLRET
    .long 0x40,  0x80           // OFILL
    .long 0x80,  0x20000        // OFDEL
    .long 0, 0
// cflag: CSIZE is a 2-bit field moved from bits 4-5 to bits 8-9, so each of its
// two bits maps individually; the baud/flow-control fields are not translated.
cflag_tbl:
    .long 0x10,  0x100          // CSIZE bit 0 (CS6)
    .long 0x20,  0x200          // CSIZE bit 1 (CS7)
    .long 0x40,  0x400          // CSTOPB
    .long 0x80,  0x800          // CREAD
    .long 0x100, 0x1000         // PARENB
    .long 0x200, 0x2000         // PARODD
    .long 0x400, 0x4000         // HUPCL
    .long 0x800, 0x8000         // CLOCAL
    .long 0, 0
// lflag: the full common set (Linux XCASE and Darwin ALTWERASE/NOKERNINFO have
// no counterpart and are left out).
lflag_tbl:
    .long 0x1,     0x80         // ISIG
    .long 0x2,     0x100        // ICANON
    .long 0x8,     0x8          // ECHO
    .long 0x10,    0x2          // ECHOE
    .long 0x20,    0x4          // ECHOK
    .long 0x40,    0x10         // ECHONL
    .long 0x80,    0x80000000   // NOFLSH
    .long 0x100,   0x400000     // TOSTOP
    .long 0x200,   0x40         // ECHOCTL
    .long 0x400,   0x20         // ECHOPRT
    .long 0x800,   0x1          // ECHOKE
    .long 0x1000,  0x800000     // FLUSHO
    .long 0x4000,  0x20000000   // PENDIN
    .long 0x8000,  0x400        // IEXTEN
    .long 0x10000, 0x800        // EXTPROC
    .long 0, 0

// Darwin errno -> Linux errno
errno_map:
    .byte 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 35, 12, 13, 14, 15, 16, 17, 18, 19
    .byte 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 11, 115, 114, 88, 89
    .byte 90, 91, 92, 93, 94, 95, 96, 97, 98, 99, 100, 101, 102, 103, 104, 105, 106, 107, 108, 109
    .byte 110, 111, 40, 36, 112, 113, 39, 11, 87, 122, 116, 66, 5, 5, 5, 5, 5, 37, 38, 5
    .byte 5, 5, 5, 5, 75, 5, 5, 5, 5, 125, 43, 42, 84, 61, 74, 72, 61, 67, 63
    .byte 60, 71, 62, 95, 5, 131, 130, 5

.bss
.p2align 3
dirs: .zero 8 * 1024
pend: .zero 8 * 1024
.p2align 3
sig_handlers: .zero 8 * (SIG_MAX + 1)
sig_flags:    .zero 4 * (SIG_MAX + 1)
