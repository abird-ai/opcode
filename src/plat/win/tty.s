.include "opcode.inc"
.include "plat/win/win.inc"
# win: Layer 0 terminal control over the Win32 console.
#
# The Linux implementation is termios + ioctl(TIOCGWINSZ) + SIGWINCH; this
# file replaces src/plat/linux/tty.s for the Windows target.
#
#   os_tty_raw(saved)   -> 0 | -errno   GetConsoleMode, then raw input and VT output
#   os_tty_restore(saved)-> 0 | -errno  put both console modes back
#   os_tty_size(fd)     -> rax=cols, rdx=rows (80x24 when not a console)
#   os_sig_winch()      -> 0 | -errno   no SIGWINCH on Windows
#   os_winch_fd()       -> -1           resize wakeup is not delivered
#   os_sig_cleanup()    -> -ENOSYS      Win32 has no POSIX fatal signals
#
# `saved` (>=64 bytes) holds {magic, input mode, output mode}; the layout is
# private to this file and restore is idempotent.  The raw output mode enables
# ENABLE_VIRTUAL_TERMINAL_PROCESSING so the TUI's ANSI sequences work on a
# real console; a redirect (pipe/file) fails GetConsoleMode and os_tty_raw
# reports -ENOTTY, exactly like a non-tty on Linux.

.bss
.p2align 3
win_stdin_handle:  .zero 8
win_stdout_handle: .zero 8

.equ TTY_MAGIC, 0x77696E54          # 'winT'

.text

# tty_handles(): cache stdin/stdout handles
FN tty_handles
    mov rax, [rip + win_stdin_handle]
    test rax, rax
    jnz 1f
    sub rsp, 40
    mov ecx, STD_INPUT_HANDLE
    call GetStdHandle
    mov [rip + win_stdin_handle], rax
    mov ecx, STD_OUTPUT_HANDLE
    call GetStdHandle
    mov [rip + win_stdout_handle], rax
    add rsp, 40
1:  ret

# os_tty_raw(saved) -> 0 | -errno
FN os_tty_raw
    PROLOGUE 32
    mov r12, rdi
    test r12, r12
    jz .Lrw_bad
    call tty_handles
    mov rcx, [rip + win_stdin_handle]
    lea rdx, [rsp + 32]
    call GetConsoleMode
    test eax, eax
    jz .Lrw_notty
    mov r13d, [rsp + 32]            # original input mode
    mov rcx, [rip + win_stdout_handle]
    lea rdx, [rsp + 36]
    mov dword ptr [rsp + 36], 0
    call GetConsoleMode
    test eax, eax
    jz .Lrw_out_zero
    mov r14d, [rsp + 36]
    jmp .Lrw_out_ok
.Lrw_out_zero:
    xor r14d, r14d
.Lrw_out_ok:
    mov dword ptr [r12], TTY_MAGIC
    mov [r12 + 4], r13d
    mov [r12 + 8], r14d
    # raw input: no echo/line/processed, VT sequences for the arrows
    mov eax, r13d
    and eax, ~(ENABLE_ECHO_INPUT | ENABLE_LINE_INPUT | ENABLE_PROCESSED_INPUT)
    or eax, ENABLE_VIRTUAL_TERMINAL_INPUT
    mov rcx, [rip + win_stdin_handle]
    mov edx, eax
    call SetConsoleMode
    test eax, eax
    jz .Lrw_err
    # VT output when stdout is a console; a redirect is not an error
    test r14d, r14d
    jz .Lrw_ok
    mov eax, r14d
    or eax, ENABLE_VIRTUAL_TERMINAL_PROCESSING | DISABLE_NEWLINE_AUTO_RETURN
    mov rcx, [rip + win_stdout_handle]
    mov edx, eax
    call SetConsoleMode
.Lrw_ok:
    xor eax, eax
    EPILOGUE
.Lrw_bad:
    mov rax, -EINVAL
    EPILOGUE
.Lrw_notty:
    mov rax, -ENOTTY
    EPILOGUE
.Lrw_err:
    call win_last_error
    EPILOGUE

# os_tty_restore(saved) -> 0 | -errno
FN os_tty_restore
    PROLOGUE 32
    mov r12, rdi
    test r12, r12
    jz .Lrs_bad
    cmp dword ptr [r12], TTY_MAGIC
    jne .Lrs_bad
    call tty_handles
    mov rcx, [rip + win_stdin_handle]
    mov edx, [r12 + 4]
    call SetConsoleMode
    mov r13d, eax
    cmp dword ptr [r12 + 8], 0
    jz .Lrs_out
    mov rcx, [rip + win_stdout_handle]
    mov edx, [r12 + 8]
    call SetConsoleMode
.Lrs_out:
    test r13d, r13d
    jz .Lrs_err
    xor eax, eax
    EPILOGUE
.Lrs_bad:
    mov rax, -EINVAL
    EPILOGUE
.Lrs_err:
    call win_last_error
    EPILOGUE

# os_tty_size(fd) -> rax=cols, rdx=rows
FN os_tty_size
    PROLOGUE 48
    call win_fd_entry
    test rax, rax
    jz .Lsz_stdout
    mov rcx, [rax + FD_HANDLE]
    jmp .Lsz_info
.Lsz_stdout:
    call tty_handles
    mov rcx, [rip + win_stdout_handle]
.Lsz_info:
    lea rdx, [rsp + 32]
    call GetConsoleScreenBufferInfo
    test eax, eax
    jz .Lsz_def
    movzx eax, word ptr [rsp + 32 + 10 + 4]   # srWindow.Right
    movzx ecx, word ptr [rsp + 32 + 10]       # srWindow.Left
    sub eax, ecx
    inc eax
    movzx edx, word ptr [rsp + 32 + 10 + 6]   # srWindow.Bottom
    movzx ecx, word ptr [rsp + 32 + 10 + 2]   # srWindow.Top
    sub edx, ecx
    inc edx
    test eax, eax
    jz .Lsz_def
    test edx, edx
    jz .Lsz_def
    EPILOGUE
.Lsz_def:
    mov eax, 80
    mov edx, 24
    EPILOGUE

# os_sig_winch() -> 0: Win32 has no SIGWINCH.  A real console resize could be
# watched with ReadConsoleInputW(WINDOW_BUFFER_SIZE_EVENT); this port does
# not start a reader thread, so os_winch_fd() reports -1 and the TUI keeps its
# initial size.  Returning success here is honest only about "no handler to
# install"; the missing capability is documented in .agents/docs/ports.md.
FN os_sig_winch
    xor eax, eax
    ret

# os_winch_fd() -> -1 (never installed)
FN os_winch_fd
    mov rax, -1
    ret

# os_sig_cleanup() -> -ENOSYS: there are no POSIX fatal signals to catch.
# Console Ctrl+C takes the default action (process exit); the console is
# restored by the shell, and Windows terminals do not need the alternate
# screen reset the POSIX path performs.
FN os_sig_cleanup
    mov rax, -ENOSYS
    ret
