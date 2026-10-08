.include "opcode.inc"
# opcode platform: linux terminal control (raw mode, size, SIGWINCH).
#
# Direct ioctl(2)/rt_sigaction(2) syscalls, no libc. x86-64 struct termios is
# 60 bytes; callers pass a buffer of at least 64.
#
# Termios layout:
#   0  c_iflag u32      4  c_oflag u32      8  c_cflag u32
#   12 c_lflag u32      16 c_line  u8       17 c_cc[32]
#   52 c_ispeed u32     56 c_ospeed u32

.equ SYS_ioctl, 16
.equ SYS_rt_sigaction, 13
.equ SYS_rt_sigreturn, 15
.equ SYS_pipe2, 293
.equ SYS_getpid, 39
.equ SYS_kill, 62

.equ TCGETS, 0x5401
.equ TCSETS, 0x5402
.equ TIOCGWINSZ, 0x5413

.equ TERMIOS_IFLAG, 0
.equ TERMIOS_LFLAG, 12
.equ TERMIOS_CC, 17
.equ VMIN, 6
.equ VTIME, 5
.equ ICANON, 0x2
.equ ECHO, 0x8
.equ ISIG, 0x1
.equ IXON, 0x400
.equ ICRNL, 0x100

.equ SIGWINCH, 28
.equ SIGHUP, 1
.equ SIGINT, 2
.equ SIGQUIT, 3
.equ SIGABRT, 6
.equ SIGBUS, 7
.equ SIGFPE, 8
.equ SIGSEGV, 11
.equ SIGTERM, 15
.equ SA_RESTORER, 0x04000000
.equ SA_RESTART, 0x10000000
.equ SA_RESETHAND, 0x80000000

.data
.p2align 3
winch_pipe: .zero 8                 # [read fd][write fd]
winch_act:  .zero 32                # struct sigaction
cleanup_act: .zero 32               # struct sigaction for os_sig_cleanup
winch_byte: .byte 0
winch_rfd:  .quad -1
winch_wfd:  .quad -1

.text

# os_tty_raw(saved /* >=64 bytes */) -> 0|-errno
# tcgetattr(0, saved) then tcsetattr(0, raw). `saved` keeps the ORIGINAL
# settings, so os_tty_restore(saved) can undo the mode change.
FN os_tty_raw
    PROLOGUE 64
    mov rbx, rdi
    test rbx, rbx
    jz .Lraw_bad
    xor edi, edi
    mov esi, TCGETS
    mov rdx, rbx
    SYS SYS_ioctl
    test rax, rax
    js .Lraw_out
    # raw settings live in a stack copy; saved stays pristine for restore
    mov rdi, rsp
    mov rsi, rbx
    mov edx, 64
    call memcpy
    and dword ptr [rsp + TERMIOS_LFLAG], 0xFFFFFFF4   # ~(ICANON|ECHO|ISIG)
    and dword ptr [rsp + TERMIOS_IFLAG], 0xFFFFFAFF   # ~(IXON|ICRNL)
    mov byte ptr [rsp + TERMIOS_CC + VMIN], 1
    mov byte ptr [rsp + TERMIOS_CC + VTIME], 0        # OPOST stays enabled
    xor edi, edi
    mov esi, TCSETS
    mov rdx, rsp
    SYS SYS_ioctl
.Lraw_out:
    EPILOGUE
.Lraw_bad:
    mov rax, -EINVAL
    EPILOGUE

# os_tty_restore(saved) -> 0|-errno
FN os_tty_restore
    test rdi, rdi
    jz .Lrest_bad
    mov rdx, rdi
    xor edi, edi
    mov esi, TCSETS
    SYS SYS_ioctl
    ret
.Lrest_bad:
    mov rax, -EINVAL
    ret

# os_tty_size(fd) -> rax=cols, rdx=rows. 80x24 when the ioctl fails or the
# kernel reports a zero dimension (not a tty).
FN os_tty_size
    sub rsp, 16
    mov qword ptr [rsp], 0          # struct winsize { u16 row, col, xpix, ypix }
    mov esi, TIOCGWINSZ
    mov rdx, rsp
    SYS SYS_ioctl
    test rax, rax
    js .Lsize_def
    movzx eax, word ptr [rsp + 2]   # ws_col
    movzx edx, word ptr [rsp]       # ws_row
    test eax, eax
    jz .Lsize_def
    test edx, edx
    jz .Lsize_def
    add rsp, 16
    ret
.Lsize_def:
    mov eax, 80
    mov edx, 24
    add rsp, 16
    ret

# os_sig_winch() -> 0|-errno
# Install a SIGWINCH handler that writes one byte to a non-blocking pipe
# created with pipe2(O_NONBLOCK|O_CLOEXEC). Idempotent.
FN os_sig_winch
    PROLOGUE 0
    cmp qword ptr [rip + winch_rfd], -1
    jne .Lsig_ok
    lea rdi, [rip + winch_pipe]
    mov esi, O_NONBLOCK | O_CLOEXEC
    SYS SYS_pipe2
    test rax, rax
    js .Lsig_out
    mov eax, dword ptr [rip + winch_pipe]
    mov [rip + winch_rfd], rax
    mov eax, dword ptr [rip + winch_pipe + 4]
    mov [rip + winch_wfd], rax
    # sa_handler = winch_handler; sa_flags = SA_RESTORER|SA_RESTART;
    # sa_restorer = rt_sigreturn stub; sa_mask = 0.
    lea rax, [rip + winch_handler]
    mov [rip + winch_act], rax
    mov qword ptr [rip + winch_act + 8], SA_RESTORER | SA_RESTART
    lea rax, [rip + .Lsig_restorer]
    mov [rip + winch_act + 16], rax
    mov qword ptr [rip + winch_act + 24], 0
    mov edi, SIGWINCH
    lea rsi, [rip + winch_act]
    xor edx, edx
    mov r10d, 8                     # _NSIG / 8
    SYS SYS_rt_sigaction
    test rax, rax
    js .Lsig_fail
.Lsig_ok:
    xor eax, eax
.Lsig_out:
    EPILOGUE
.Lsig_fail:
    push rax
    mov edi, dword ptr [rip + winch_rfd]
    SYS SYS_close
    mov edi, dword ptr [rip + winch_wfd]
    SYS SYS_close
    pop rax
    mov qword ptr [rip + winch_rfd], -1
    mov qword ptr [rip + winch_wfd], -1
    EPILOGUE

# os_winch_fd() -> fd read end, or -1 when not installed
FN os_winch_fd
    mov rax, [rip + winch_rfd]
    ret

# os_sig_cleanup() -> 0|-errno
# Install the terminal-restore handler for the fatal signals with
# SA_RESTORER|SA_RESETHAND (a second signal takes its default action).
# Called by the app only after a successful term_init, never in headless mode.
FN os_sig_cleanup
    PROLOGUE 0
    lea rax, [rip + cleanup_handler]
    mov [rip + cleanup_act], rax
    mov eax, SA_RESTORER | SA_RESETHAND
    mov [rip + cleanup_act + 8], rax
    lea rax, [rip + .Lsig_restorer]
    mov [rip + cleanup_act + 16], rax
    mov qword ptr [rip + cleanup_act + 24], 0
    lea rbx, [rip + .Lsig_cleanup_list]
    mov r12d, 8
.Lsc_loop:
    mov edi, [rbx]
    lea rsi, [rip + cleanup_act]
    xor edx, edx
    mov r10d, 8                     # _NSIG / 8
    SYS SYS_rt_sigaction
    test rax, rax
    js .Lsc_out
    add rbx, 4
    dec r12d
    jnz .Lsc_loop
    xor eax, eax
.Lsc_out:
    EPILOGUE

# SIGWINCH handler: async-signal-safe, a single write(2) from a static byte.
# The kernel resumes through the SA_RESTORER stub below.
.p2align 4
.type winch_handler, @function
winch_handler:
    mov edi, dword ptr [rip + winch_wfd]
    lea rsi, [rip + winch_byte]
    mov edx, 1
    SYS SYS_write
    ret
.size winch_handler, .-winch_handler

# Fatal-signal handler: restore the terminal via the exit hook, re-raise the
# signal with the default disposition and return through rt_sigreturn. The
# re-raised signal is delivered as the handler's blocked signal is restored,
# so the process exits with the truthful signal status. Async-signal-safe:
# only ioctl/write (through the hook), getpid, kill and rt_sigreturn.
.p2align 4
.type cleanup_handler, @function
cleanup_handler:
    push rdi                        # signum; keeps the frame 16-byte aligned
    mov rax, [rip + g_exit_hook]
    test rax, rax
    jz 1f
    call rax
1:  mov esi, [rsp]                  # signum for kill
    SYS SYS_getpid
    mov edi, eax
    SYS SYS_kill
    add rsp, 8                      # simulate the handler return address slot
    ret                             # SA_RESTORER -> rt_sigreturn: the pending
                                    # fatal signal now terminates the process
.size cleanup_handler, .-cleanup_handler

# x86-64 requires SA_RESTORER: rt_sigreturn(2) pops the signal frame.
.Lsig_restorer:
    SYS SYS_rt_sigreturn

.section .rodata
.Lsig_cleanup_list: .long SIGHUP, SIGINT, SIGQUIT, SIGABRT, SIGBUS, SIGFPE, SIGSEGV, SIGTERM
