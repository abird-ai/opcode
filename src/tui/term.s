.include "opcode.inc"
# opcode tui: terminal lifecycle, frame flush and SIGWINCH resize handling.
#
# API: src/tui/API.md. g_tui_headless is set by the app before term_init; in
# that mode no terminal state is touched and term_size reports the size given
# to term_set_size (tests).

.data
.p2align 3
.globl g_tui_headless
g_tui_headless: .quad 0
# g_tui_inline: set by the app before term_init; inline mode keeps the normal
# screen (no alternate buffer, no clear) and only restores the tty on exit.
.globl g_tui_inline
g_tui_inline:   .quad 0
# g_tui_capture: cstr path for a headless frame-capture sink (0 = none);
# g_tui_capture_fd: open fd for that sink (-1 = none).  When set, the app
# routes fd-1 terminal writes here so a golden can assert the raw emitted
# bytes of the inline/fullscreen writer.
.globl g_tui_capture
g_tui_capture:    .quad 0
.globl g_tui_capture_fd
g_tui_capture_fd: .quad -1

# term_flags: exactly what term_init changed, so term_restore only undoes that.
.equ TERM_F_RAW,    1              # original termios saved; raw mode is active
.equ TERM_F_ALT,    2              # alternate screen entered
.equ TERM_F_CURSOR, 4              # cursor hidden
.equ TERM_F_PASTE,  8              # bracketed paste enabled

.bss
.p2align 4
term_saved:      .zero 64          # original termios for term_restore
term_flags:      .zero 8           # TERM_F_* bits
term_cache_cols: .zero 8
term_cache_rows: .zero 8
term_set_cols:   .zero 8           # headless size override
term_set_rows:   .zero 8
term_bg_set:     .zero 4           # OSC 11 background pushed
term_sb:         .zero SB_SIZE

.text

# term_init() -> 0|-errno
# Interactive: save + raw mode, enter the alternate screen, hide the cursor,
# clear the screen, install SIGWINCH. Headless: only install SIGWINCH.
FN term_init
    PROLOGUE 0
    lea rax, [rip + term_restore]
    mov [rip + g_exit_hook], rax
    cmp qword ptr [rip + g_tui_headless], 0
    jne .Ltinit_headless
    cmp qword ptr [rip + g_tui_inline], 0
    jne .Ltinit_inline
    cmp dword ptr [rip + term_flags], 0
    jne .Ltinit_ok
    lea rdi, [rip + term_saved]
    call os_tty_raw
    test rax, rax
    js .Ltinit_out
    or dword ptr [rip + term_flags], TERM_F_RAW
    mov edi, 1
    lea rsi, [rip + .Ltinit_enter]
    mov edx, 26
    call write_all
    test rax, rax
    js .Ltinit_out
    or dword ptr [rip + term_flags], TERM_F_ALT | TERM_F_CURSOR | TERM_F_PASTE
    call os_sig_winch
    test rax, rax
    js .Ltinit_out
    call term_size
    mov [rip + term_cache_cols], rax
    mov [rip + term_cache_rows], rdx
    xor eax, eax
.Ltinit_out:
    EPILOGUE
.Ltinit_headless:
    call os_sig_winch
    xor eax, eax
    EPILOGUE
.Ltinit_inline:
    cmp dword ptr [rip + term_flags], 0
    jne .Ltinit_ok
    lea rdi, [rip + term_saved]
    call os_tty_raw
    test rax, rax
    js .Ltinit_out
    or dword ptr [rip + term_flags], TERM_F_RAW
    mov edi, 1
    lea rsi, [rip + .Ltpaste_on]
    mov edx, 8
    call write_all
    test rax, rax
    js .Ltinit_out
    or dword ptr [rip + term_flags], TERM_F_PASTE
    call os_sig_winch
    test rax, rax
    js .Ltinit_out
    call term_size
    mov [rip + term_cache_cols], rax
    mov [rip + term_cache_rows], rdx
    xor eax, eax
    EPILOGUE
.Ltinit_ok:
    xor eax, eax
    EPILOGUE

# term_set_bg(color ARGB): OSC 11 set-background.  The fixed dark/light theme
# owns its background; `system`/named themes call term_reset_bg instead.
# term_hex2(rdi=buf, eax=byte) -> rdi advanced past two lowercase hex digits.
term_hex2:
    mov edx, eax
    shr edx, 4
    and edx, 0xF
    lea rcx, [rip + .Lt_hex]
    mov dl, [rcx + rdx]
    mov [rdi], dl
    mov edx, eax
    and edx, 0xF
    mov dl, [rcx + rdx]
    mov [rdi + 1], dl
    add rdi, 2
    ret

FN term_set_bg
    PROLOGUE 64
    cmp qword ptr [rip + g_tui_headless], 0
    jne .Ltsb_done
    mov r12d, edi
    lea rdi, [rsp]
    lea rsi, [rip + .Lt_osc11]
    mov edx, 9
    call memcpy
    mov eax, r12d
    shr eax, 16
    and eax, 0xFF
    lea rdi, [rsp + 9]
    call term_hex2
    mov byte ptr [rdi], '/'
    inc rdi
    mov eax, r12d
    shr eax, 8
    and eax, 0xFF
    call term_hex2
    mov byte ptr [rdi], '/'
    inc rdi
    mov eax, r12d
    and eax, 0xFF
    call term_hex2
    mov byte ptr [rdi], 0x1B
    inc rdi
    mov byte ptr [rdi], '\\'
    inc rdi
    mov rdx, rdi
    lea rsi, [rsp]
    sub rdx, rsi
    mov edi, 1
    call write_all
    mov dword ptr [rip + term_bg_set], 1
.Ltsb_done:
    xor eax, eax
    EPILOGUE

# term_reset_bg(): OSC 111 reset-background (idempotent)
FN term_reset_bg
    PROLOGUE 0
    cmp qword ptr [rip + g_tui_headless], 0
    jne .Ltrb_done
    cmp dword ptr [rip + term_bg_set], 0
    je .Ltrb_done
    mov edi, 1
    lea rsi, [rip + .Lt_osc111]
    mov edx, 7
    call write_all
    mov dword ptr [rip + term_bg_set], 0
.Ltrb_done:
    xor eax, eax
    EPILOGUE

# term_restore(): idempotent; shows the cursor, leaves the alternate screen
# only if it was entered, restores termios and ends the line in inline mode.
# Uses only write(2)/ioctl(2): safe from a signal handler or an os_exit hook.
FN term_restore
    PROLOGUE 0
    mov r12d, dword ptr [rip + term_flags]
    test r12d, r12d
    jz .Ltrest_ok
    # always restore autowrap first: a bracketed inline/fullscreen frame leaves
    # it off only for the duration of one write, but a fatal signal can land
    # inside that write.
    mov edi, 1
    lea rsi, [rip + .Lawrap_on]
    mov edx, 5
    call write_all
    test r12d, TERM_F_PASTE
    jz .Ltrest_paste_done
    mov edi, 1
    lea rsi, [rip + .Ltpaste_off]
    mov edx, 8
    call write_all
.Ltrest_paste_done:
    cmp dword ptr [rip + term_bg_set], 0
    je .Ltrest_nobg
    mov edi, 1
    lea rsi, [rip + .Lt_osc111]
    mov edx, 7
    call write_all
    mov dword ptr [rip + term_bg_set], 0
.Ltrest_nobg:
    mov edi, 1
    lea rsi, [rip + .Ltsgr0]
    mov edx, 4
    call write_all
    mov edi, 1
    lea rsi, [rip + .Ltshow]
    mov edx, 6
    call write_all
    test r12d, TERM_F_ALT
    jz .Ltrest_raw
    mov edi, 1
    lea rsi, [rip + .Ltrest_alt]
    mov edx, 8
    call write_all
.Ltrest_raw:
    test r12d, TERM_F_RAW
    jz .Ltrest_clear
    lea rdi, [rip + term_saved]
    call os_tty_restore
    test r12d, TERM_F_ALT
    jnz .Ltrest_clear
    mov edi, 1
    lea rsi, [rip + .Ltnl]
    mov edx, 1
    call write_all
.Ltrest_clear:
    mov dword ptr [rip + term_flags], 0
.Ltrest_ok:
    xor eax, eax
    EPILOGUE

# term_size() -> rax=cols, rdx=rows
FN term_size
    cmp qword ptr [rip + g_tui_headless], 0
    jne .Ltsz_headless
    mov rax, [rip + term_cache_cols]
    test rax, rax
    jz .Ltsz_query
    mov rdx, [rip + term_cache_rows]
    ret
.Ltsz_query:
    PROLOGUE 0
    xor edi, edi
    call os_tty_size
    mov [rip + term_cache_cols], rax
    mov [rip + term_cache_rows], rdx
    EPILOGUE
.Ltsz_headless:
    mov rax, [rip + term_set_cols]
    mov rdx, [rip + term_set_rows]
    test rax, rax
    jnz .Ltsz_ret
    mov eax, 80
    mov edx, 24
.Ltsz_ret:
    ret

# term_set_size(cols, rows): headless/test override for term_size.
FN term_set_size
    mov [rip + term_set_cols], rdi
    mov [rip + term_set_rows], rsi
    xor eax, eax
    ret

# term_flush(g, cursor_x, cursor_y, cursor_visible) -> 0|-errno
# One write: begin-sync, diffed frame, cursor position, cursor visibility,
# end-sync. Uses render_build so the frame is not flushed separately.
FN term_flush
    PROLOGUE 48
    mov rbx, rdi
    mov r12, rsi                   # cursor x
    mov r13, rdx                   # cursor y
    mov r14d, ecx                  # cursor visible
    call render_build
    mov r15, rax
    mov [rsp], rdx                 # frame length
    lea rdi, [rip + term_sb]
    call sb_clear
    lea rdi, [rip + term_sb]
    lea rsi, [rip + .Ltsync_h]
    mov edx, 8
    call sb_push
    lea rdi, [rip + term_sb]
    lea rsi, [rip + .Lawrap_off]
    mov edx, 5
    call sb_push
    lea rdi, [rip + term_sb]
    mov rsi, r15
    mov rdx, [rsp]
    call sb_push
    test r12, r12
    js .Ltfl_cursor_done
    test r13, r13
    js .Ltfl_cursor_done
    lea rdi, [rip + term_sb]
    lea rsi, [rip + .Ltcsi]
    mov edx, 2
    call sb_push
    lea rdi, [rip + term_sb]
    lea rsi, [r13 + 1]
    call sb_push_u64
    lea rdi, [rip + term_sb]
    lea rsi, [rip + .Ltsemi]
    mov edx, 1
    call sb_push
    lea rdi, [rip + term_sb]
    lea rsi, [r12 + 1]
    call sb_push_u64
    lea rdi, [rip + term_sb]
    lea rsi, [rip + .LtH]
    mov edx, 1
    call sb_push
.Ltfl_cursor_done:
    lea rdi, [rip + term_sb]
    test r14d, r14d
    jz .Ltfl_hide
    lea rsi, [rip + .Ltshow]
    mov edx, 6
    jmp .Ltfl_vis
.Ltfl_hide:
    lea rsi, [rip + .Lthide]
    mov edx, 6
.Ltfl_vis:
    call sb_push
    lea rdi, [rip + term_sb]
    lea rsi, [rip + .Lawrap_on]
    mov edx, 5
    call sb_push
    lea rdi, [rip + term_sb]
    lea rsi, [rip + .Ltsync_l]
    mov edx, 8
    call sb_push
    mov rax, [rip + g_tui_capture_fd]
    test rax, rax
    js 1f
    mov edi, eax
    jmp 2f
1:  mov edi, 1
2:  lea rax, [rip + term_sb]
    mov rsi, [rax + SB_ptr]
    mov rdx, [rax + SB_len]
    call write_all
    EPILOGUE

# term_resized() -> 1|0: drain the SIGWINCH pipe; on a resize byte refresh the
# cached size.
FN term_resized
    PROLOGUE 16
    call os_winch_fd
    test rax, rax
    js .Ltrz_no
    mov r12, rax
    xor r13d, r13d                 # saw a byte
.Ltrz_drain:
    mov edi, r12d
    mov rsi, rsp
    mov edx, 1
    call os_read
    cmp rax, -EINTR
    je .Ltrz_drain
    test rax, rax
    jle .Ltrz_drained
    mov r13d, 1
    jmp .Ltrz_drain
.Ltrz_drained:
    test r13d, r13d
    jz .Ltrz_no
    cmp qword ptr [rip + g_tui_headless], 0
    jne .Ltrz_yes
    xor edi, edi
    call os_tty_size
    mov [rip + term_cache_cols], rax
    mov [rip + term_cache_rows], rdx
.Ltrz_yes:
    mov eax, 1
    EPILOGUE
.Ltrz_no:
    xor eax, eax
    EPILOGUE

# term_poll_resize() -> 1|0: query the terminal size independently of the
# SIGWINCH pipe and refresh the cache when it changed.  Headless is a no-op.
FN term_poll_resize
    PROLOGUE 0
    cmp qword ptr [rip + g_tui_headless], 0
    jne .Ltpr_no
    xor edi, edi
    call os_tty_size
    test rax, rax
    jz .Ltpr_no
    mov r12, rax
    mov r13, rdx
    cmp r12, [rip + term_cache_cols]
    jne .Ltpr_yes
    cmp r13, [rip + term_cache_rows]
    je .Ltpr_no
.Ltpr_yes:
    mov [rip + term_cache_cols], r12
    mov [rip + term_cache_rows], r13
    mov eax, 1
    EPILOGUE
.Ltpr_no:
    xor eax, eax
    EPILOGUE

.section .rodata
.Ltinit_enter: .ascii "\033[?1049h\033[?25l\033[2J\033[?2004h"
.Ltpaste_on:   .ascii "\033[?2004h"
.Lt_osc11:     .ascii "\033]11;rgb:"
.Lt_osc111:    .ascii "\033]111\033\\"
.Lt_hex:       .ascii "0123456789abcdef"
.Ltpaste_off:  .ascii "\033[?2004l"
.Ltsgr0:       .ascii "\033[0m"
.Ltrest_alt:   .ascii "\033[?1049l"
.Ltnl:         .byte 10
.Ltsync_h:     .ascii "\033[?2026h"
.Ltsync_l:     .ascii "\033[?2026l"
.Lawrap_off:   .ascii "\033[?7l"
.Lawrap_on:    .ascii "\033[?7h"
.Ltshow:       .ascii "\033[?25h"
.Lthide:       .ascii "\033[?25l"
.Ltcsi:        .ascii "\033["
.Ltsemi:       .ascii ";"
.LtH:          .ascii "H"
