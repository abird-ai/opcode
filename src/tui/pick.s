# opcode tui: standalone modal list picker.  Reuses the cell grid/renderer and
# the slash menu's list chrome (filter, selection, Up/Down/PageUp/PageDown,
# Enter/Esc) outside the main TUI event loop, so a pre-TUI flow (session
# resume) can present a picker before term_init owns the screen.
#
#   opcode_pick(title, names, descs, n, initial) -> rax index | -1
#       Core picker over the already-open terminal.  The caller owns raw/alt
#       mode; input/output default to fds 0/1 and can be redirected with
#       g_pick_fd / g_pick_out_fd.
#
#   opcode_pick_tty(title, names, descs, n, initial) -> rax index | -1
#       Convenience wrapper: opens the controlling tty, enters raw/alt mode,
#       runs opcode_pick and restores.  Headless (g_tui_headless != 0) simply
#       runs the core, which draws to the in-memory grid and takes its keys
#       from g_pick_read, so unit tests never touch a terminal.
#
# Test/in-memory backend:
#   g_pick_read: fn(rdi=buf, rsi=cap) -> n | -errno, or 0 to read g_pick_fd.
#   With g_tui_headless set and no reader, the core draws one frame and returns
#   -1 rather than blocking.

.include "opcode.inc"

.equ PK_ENTER, 0x0a
.equ PK_ESC,   0x1b

.equ PK_MAXDIM, 4096
.equ PK_READSZ, 4096
# Poll window for the real terminal.  Same order as the main TUI's 50 ms tick
# so a deferred lone ESC is flushed by input_idle without busy-spinning.
.equ PK_POLL_MS, 50

.data
.p2align 3
# In-memory key source for tests; 0 falls back to g_pick_fd (or EOF when
# headless, so the core never blocks).
.globl g_pick_read
g_pick_read:  .quad 0
# Picker I/O fds.  g_pick_out_fd is honoured by render_flush.
.globl g_pick_fd
g_pick_fd:    .quad 0
.globl g_pick_out_fd
g_pick_out_fd: .quad 1

.bss
.p2align 4
pick_grid:    .zero 512
pick_in:      .zero 4096
pick_inbuf:   .zero PK_READSZ
pick_pfd:     .zero 8               # one pollfd { fd, events, revents }
pick_dirty:   .zero 4               # redraw only when state changed
pick_ev:      .zero 32
pick_sb:      .zero SB_SIZE
pick_title:   .zero 8
pick_w:       .zero 4
pick_h:       .zero 4

.section .rodata
.Lp_hint: .asciz "type filter   up/down move   enter select   esc cancel"
.Lp_devtty: .asciz "/dev/tty"
.Lp_nl: .byte 10

.text

# pick_read(rdi=buf, rsi=cap) -> n | -errno.  The in-memory hook first, then a
# real read from g_pick_fd; headless with no hook reports EOF (0).
pick_read:
    PROLOGUE 0
    mov r12, rdi
    mov r13, rsi
    mov rax, [rip + g_pick_read]
    test rax, rax
    jz 1f
    mov rdi, r12
    mov rsi, r13
    call rax
    EPILOGUE
1:  cmp qword ptr [rip + g_tui_headless], 0
    jne 2f
    mov rdi, [rip + g_pick_fd]
    mov rsi, r12
    mov rdx, r13
    call os_read
    EPILOGUE
2:  xor eax, eax
    EPILOGUE

# pk_idle(): pump the input parser's lone-ESC / partial-sequence timeout using
# the monotonic clock.  Called on every poll timeout (and right after a feed)
# so a lone ESC sitting in the parser becomes K_ESC instead of blocking.
pk_idle:
    PROLOGUE 0
    mov edi, CLOCK_MONOTONIC
    call os_now_ns
    mov rcx, 1000000
    xor edx, edx
    div rcx
    lea rdi, [rip + pick_in]
    mov rsi, rax
    call input_idle
    EPILOGUE

# pick_draw(): clear the grid and paint the title, the filtered rows and the
# key hint.  Reads pick_title / pick_w / pick_h.
pick_draw:
    PROLOGUE 0
    lea rdi, [rip + pick_grid]
    xor esi, esi
    xor edx, edx
    call grid_clear

    # Title at (1, 0), bold.
    mov rdi, [rip + pick_title]
    test rdi, rdi
    jz 1f
    call strlen
    mov r14, rax                 # title length
    lea rdi, [rip + pick_grid]
    mov esi, 1
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    mov r9d, 1                   # A_BOLD
    sub rsp, 16
    mov rax, [rip + pick_title]
    mov [rsp], rax
    mov [rsp + 8], r14
    call grid_text
    add rsp, 16
1:
    # The list body, one blank row under the title.
    lea rdi, [rip + pick_grid]
    mov esi, 1                   # x
    mov edx, 2                   # y
    mov ecx, [rip + pick_w]
    sub ecx, 2                   # width
    mov r8d, [rip + pick_h]
    sub r8d, 3                   # maxrows (a hint row is reserved)
    call menu_render

    # Hint at (1, h-1), dim.
    lea rdi, [rip + .Lp_hint]
    call strlen
    mov r14, rax
    lea rdi, [rip + pick_grid]
    mov esi, 1
    mov edx, [rip + pick_h]
    dec edx
    xor ecx, ecx
    xor r8d, r8d
    mov r9d, 4                   # A_DIM
    sub rsp, 16
    lea rax, [rip + .Lp_hint]
    mov [rsp], rax
    mov [rsp + 8], r14
    call grid_text
    add rsp, 16
    EPILOGUE

# pick_emit(): headless -> dump the frame to fd 1 for a byte golden;
# otherwise flush the diff to the picker output fd.
pick_emit:
    PROLOGUE 0
    cmp qword ptr [rip + g_tui_headless], 0
    je 1f
    lea rdi, [rip + pick_sb]
    call sb_clear
    lea rdi, [rip + pick_grid]
    lea rsi, [rip + pick_sb]
    call render_dump
    mov edi, 1
    mov rsi, [rip + pick_sb + SB_ptr]
    mov rdx, [rip + pick_sb + SB_len]
    call write_all
    mov edi, 1
    lea rsi, [rip + .Lp_nl]
    mov edx, 1
    call write_all
    EPILOGUE
1:  lea rdi, [rip + pick_grid]
    mov rsi, [rip + g_pick_out_fd]
    call render_flush
    EPILOGUE

# opcode_pick(rdi=title, rsi=names, rdx=descs, rcx=n, r8=initial) -> index | -1
FN opcode_pick
    PROLOGUE 96
    mov [rbp - 48], rdi          # title
    mov [rbp - 56], rsi          # names
    mov [rbp - 64], rdx          # descs
    mov [rbp - 72], rcx          # n
    mov [rbp - 80], r8           # initial
    test rcx, rcx
    jle .Lpk_cancel
    test rsi, rsi
    jz .Lpk_cancel
    mov [rip + pick_title], rdi

    call term_size
    test rax, rax
    jg 1f
    mov eax, 80
1:  cmp rax, PK_MAXDIM
    jbe 2f
    mov eax, PK_MAXDIM
2:  cmp rax, 8
    jae 3f
    mov eax, 8
3:  mov [rip + pick_w], eax
    test rdx, rdx
    jg 4f
    mov edx, 24
4:  cmp rdx, PK_MAXDIM
    jbe 5f
    mov edx, PK_MAXDIM
5:  cmp rdx, 5
    jae 6f
    mov edx, 5
6:  mov [rip + pick_h], edx

    lea rdi, [rip + pick_grid]
    mov esi, [rip + pick_w]
    mov edx, [rip + pick_h]
    call grid_init
    test eax, eax
    js .Lpk_cancel

    mov esi, 3                   # MENU_KIND_PICK (src/tui/menu.s)
    call menu_begin
    mov rdi, [rbp - 56]
    mov rsi, [rbp - 64]
    mov edx, [rbp - 72]
    mov ecx, [rbp - 80]
    call menu_rows

    lea rdi, [rip + pick_in]
    call input_init

    lea rdi, [rip + pick_in]
    call input_init
    mov dword ptr [rip + pick_dirty], 1

.Lpk_loop:
    cmp dword ptr [rip + pick_dirty], 0
    je .Lpk_nodraw
    mov dword ptr [rip + pick_dirty], 0
    call pick_draw
    call pick_emit
.Lpk_nodraw:

    xor r15d, r15d               # r15 = 1 once the input source is exhausted

    # In-memory hook first (tests / headless): non-blocking, may return test
    # bytes then EOF.  No fd to poll, so call it directly.
    mov rax, [rip + g_pick_read]
    test rax, rax
    jnz .Lpk_hook
    cmp qword ptr [rip + g_tui_headless], 0
    jne .Lpk_eof                 # headless, no hook: EOF, never block

    # Real terminal: poll the picker fd with a short timeout so a deferred lone
    # ESC is flushed by pk_idle instead of blocking forever in pick_read.
    mov eax, [rip + g_pick_fd]
    mov [rip + pick_pfd], eax
    mov word ptr [rip + pick_pfd + 4], POLLIN
    mov word ptr [rip + pick_pfd + 6], 0
    lea rdi, [rip + pick_pfd]
    mov esi, 1
    mov edx, PK_POLL_MS
    call os_poll
    test rax, rax
    js .Lpk_eof                  # poll error: treat as end of input
    jz .Lpk_timeout
    lea rdi, [rip + pick_inbuf]
    mov esi, PK_READSZ
    call pick_read
    jmp .Lpk_ready

.Lpk_hook:
    lea rdi, [rip + pick_inbuf]
    mov esi, PK_READSZ
    call rax
    jmp .Lpk_ready

.Lpk_timeout:
    # No byte within the window: pump the parser timeout and drain any K_ESC.
    call pk_idle
    jmp .Lpk_events

.Lpk_eof:
    xor eax, eax
.Lpk_ready:
    test rax, rax
    jg .Lpk_feed
    mov r15d, 1                  # EOF/error: cancel after draining
    call pk_idle                 # flush a lone ESC from a scripted byte stream
    jmp .Lpk_events
.Lpk_feed:
    mov rdx, rax
    lea rdi, [rip + pick_in]
    lea rsi, [rip + pick_inbuf]
    call input_feed
    # Arm the lone-ESC timer now; the next byte of a real sequence disarms it.
    # A lone ESC then fires on the next idle pump (~50 ms), never blocking.
    call pk_idle

.Lpk_events:
    lea rdi, [rip + pick_in]
    lea rsi, [rip + pick_ev]
    call input_next
    test eax, eax
    jz .Lpk_drained
    mov r12d, [rip + pick_ev + 0]   # key
    mov r13d, [rip + pick_ev + 4]   # cp
    mov r14d, [rip + pick_ev + 8]   # mods
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    call menu_key
    cmp r12d, PK_ENTER
    je .Lpk_select
    cmp r12d, PK_ESC
    je .Lpk_cancel_loop
    # Any other key changes the filter/selection: redraw on the next pass.
    mov dword ptr [rip + pick_dirty], 1
    jmp .Lpk_events

.Lpk_drained:
    test r15d, r15d
    jz .Lpk_loop
    jmp .Lpk_cancel_loop

.Lpk_select:
    call menu_count
    test eax, eax
    jz .Lpk_events_redraw
    # menu_sel_base maps the filtered view row back to the base row the
    # caller's arrays are indexed by, so a typed filter cannot select the
    # wrong session.
    call menu_sel_base
    mov [rbp - 88], eax
    jmp .Lpk_finish
.Lpk_events_redraw:
    mov dword ptr [rip + pick_dirty], 1
    jmp .Lpk_events
.Lpk_cancel_loop:
    mov eax, -1
    mov [rbp - 88], eax
.Lpk_finish:
    call menu_close
    lea rdi, [rip + pick_in]
    call input_free
    lea rdi, [rip + pick_grid]
    call grid_free
    mov eax, [rbp - 88]
    EPILOGUE
.Lpk_cancel:
    mov eax, -1
    EPILOGUE

# opcode_pick_tty(rdi=title, rsi=names, rdx=descs, rcx=n, r8=initial) -> index|-1
#
# Convenience wrapper.  Headless runs the core directly (in-memory keys).
# Otherwise it opens /dev/tty, enters the terminal's raw + alternate-screen
# mode via term_init, runs the core with the tty as its I/O fd, then restores.
# Any terminal setup failure (no tty) cancels rather than corrupting state.
FN opcode_pick_tty
    PROLOGUE 48
    mov [rbp - 48], rdi
    mov [rbp - 56], rsi
    mov [rbp - 64], rdx
    mov [rbp - 72], rcx
    mov [rbp - 80], r8
    cmp qword ptr [rip + g_tui_headless], 0
    jne .Lpt_core

    lea rdi, [rip + .Lp_devtty]
    mov esi, O_RDWR
    xor edx, edx
    call os_open
    test rax, rax
    js .Lpt_core                  # no controlling tty: try fds 0/1
    mov [rbp - 88], rax          # tty fd
    mov [rip + g_pick_fd], rax
    mov [rip + g_pick_out_fd], rax
    mov qword ptr [rip + g_tui_inline], 0
    call term_init
    test rax, rax
    js .Lpt_fail
    call .Lpt_call
    mov r12, rax
    call term_restore
    mov rdi, [rbp - 88]
    mov qword ptr [rip + g_pick_fd], 0
    mov qword ptr [rip + g_pick_out_fd], 1
    call os_close
    mov rax, r12
    EPILOGUE

.Lpt_fail:
    mov rdi, [rbp - 88]
    mov qword ptr [rip + g_pick_fd], 0
    mov qword ptr [rip + g_pick_out_fd], 1
    call os_close
    mov eax, -1
    EPILOGUE

.Lpt_core:
    call .Lpt_call
    EPILOGUE

# .Lpt_call(): run the core with opcode_pick_tty's saved arguments.
.Lpt_call:
    mov rdi, [rbp - 48]
    mov rsi, [rbp - 56]
    mov rdx, [rbp - 64]
    mov rcx, [rbp - 72]
    mov r8, [rbp - 80]
    jmp opcode_pick
