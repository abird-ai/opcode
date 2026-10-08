# tui: full-screen shell over the agent (viewport, editor, status bar, script runner).
.include "opcode.inc"
.include "core/core.inc"
.include "tui/status.inc"
.include "tui/card.inc"
.include "tui/theme.inc"
.include "tui/markdown.inc"

.equ VS_ASSIST,    3
.equ VS_USER,      4
.equ VS_TOOL,      5
.equ VS_TOOL_OUT,  6
.equ VS_ERR,      10
.equ VS_CODE,     11
.equ VS_DIM,       2

# grid struct offsets (src/tui/render.s) used by the inline footer emitter
.equ IG_w,     0
.equ IG_h,     4
.equ IG_cells, 8
.equ IG_CELL,  24
.equ IG_CELL_CONT, 0xFFFFFFFF
# Cell field offsets (src/tui/render.s), for the inline scrollbar overlay.
.equ IG_Ccp,    0
.equ IG_Ccomb,  4
.equ IG_Cfg,    8
.equ IG_Cbg,    12
.equ IG_Cattrs, 16

# cell attribute bits (src/tui/render.s)
.equ A_BOLD,      1
.equ A_UNDERLINE, 2
.equ A_DIM,       4
.equ A_REVERSE,   8
.equ A_ITALIC,    16

# view struct offsets (src/tui/view.s) used by the sticky-bottom logic
.equ VV_rows, 4
.equ VV_top,  8
.equ VV_vh,   28

# tui_draw_inline locals (rbp-relative, below the saved registers)
.set LI_total,  -48
.set LI_currow, -52
.set LI_curcol, -56
.set LI_erows,  -60
.set LI_fh,     -64
.set LI_top,    -68
.set LI_srow,   -72
.set LI_scol,   -76
.set LI_up,     -80
.set LI_mh,     -84
.set LI_cx,     -88
.set LI_cy,     -92
.set LI_q,     -96
.set FS_erows,  -48
.set FS_mh,     -52
.set FS_chat,   -56
.set FS_cy,     -60
.set FS_cx,     -64
.set FS_q,      -68
# tui_draw_region locals (owned inline region)
.set RG_q,      -48
.set RG_erows,  -52
.set RG_mh,     -56
.set RG_chat,   -60
.set RG_fh,     -64
.set RG_cx,     -68
.set RG_cy,     -72
.set RG_tot,    -80
.set RG_bud,    -84
.set RG_s,      -88
.set RG_j,      -92
.set RG_w,      -96

.equ K_ESC,   0x1b
.equ K_ENTER, 0x0a
.equ K_TAB,   0x09
.equ K_UP,    0x110001
.equ K_DOWN,  0x110002
.equ K_PGUP,  0x110007
.equ K_PGDN,  0x110008
.equ K_PASTE, 0x110010

# modal picker kinds (mirror src/tui/menu.s)
.equ MK_MODEL,    1
.equ MK_THINKING, 2
.equ MK_SESSION,  4

.equ RECV_CHUNK2, 65536
.equ TUI_MAX_DIM, 4096
.equ FOOT_MAXED,  4

.section .rodata
.Lnl:        .asciz "\n"
.Lopcode:    .asciz "opcode  "
.Lban_opcode: .asciz "opcode "
.Lban_tools: .asciz "\ntools: "
.Lban_session: .asciz "\nsession: "
.Lban_comma:  .asciz ", "
.Lban_dim:    .ascii "\033[2m"
.Lban_reset:  .ascii "\033[0m\n"
.Lslash:     .asciz "/"
.Lgap:       .asciz "  "
.Lready:     .asciz "ready"
.Lworking:   .asciz "working"
.Larrow:     .asciz "> "
.Ltool_open: .asciz "[tool] "
.Laborted:   .asciz "[aborted]"
.Lhint:      .asciz "enter send   esc abort   ctrl-c quit"
.Lin_csi:    .ascii "\033["
.Lin_A:      .ascii "A"
.Lin_C:      .ascii "C"
.Lin_cr:     .ascii "\r"
.Lin_crlf:   .ascii "\r\n"
.Lin_erase:  .ascii "\033[J"
.Lin_sgr0:   .ascii "\033[0m"
.Lin_fg:     .ascii "\033[38;2;"
.Lin_bg:     .ascii "\033[48;2;"
.Lin_semi:   .ascii ";"
.Lin_m:      .ascii "m"
.Lin_dim:    .ascii "\033[2m"
.Lin_bold:   .ascii "\033[1m"
.Lin_under:  .ascii "\033[4m"
.Lin_rev:    .ascii "\033[7m"
.Lin_ital:   .ascii "\033[3m"
.Lin_red:    .ascii "\033[31m"
.Lin_tool:   .ascii "[tool] "
.Lin_indent: .ascii "  "
.Lin_aw_off: .ascii "\033[?7l"
.Lin_aw_on:  .ascii "\033[?7h"
.Lin_hide:   .ascii "\033[?25l"
.Lin_decsc:  .ascii "\0337"
.Lin_decrc:  .ascii "\0338"
.Lin_rowclr: .ascii "\033[2K"
.Lin_down1:  .ascii "\033[1B"
.Lin_col1:   .ascii "\033[1G"
.Lin_space:  .ascii " "
.Lin_empty_out: .asciz "  (no output)\n"
.Lcmd_quit:  .asciz "/quit"
.Lcmd_new:   .asciz "/new"
.Lcmd_clear: .asciz "/clear"
.Lcmd_help:  .asciz "/help"
.Lcmd_model: .asciz "/model"
.Lw_clear:    .asciz "clear"
.Lw_help:     .asciz "help"
.Lw_model:    .asciz "model"
.Lw_new:      .asciz "new"
.Lw_quit:     .asciz "quit"
.Lw_thinking: .asciz "thinking"
.Lw_compact:  .asciz "compact"
.Lw_resume:   .asciz "resume"
.Lw_continue: .asciz "continue"
.Lw_theme:    .asciz "theme"
.Lsystem:     .asciz "system"
.Ltgl_dark:   .asciz "dark"
.Ltgl_light:  .asciz "light"
.Ltheme_pre:  .asciz "theme: "
.Ltheme_bad:  .asciz "theme: unknown '"
.Lnew_msg:   .asciz "[new session]"
# in-TUI /resume and /continue
.Lresume_none:   .asciz "resume: no stored sessions"
.Lresume_wait:   .asciz "resume: cancelling the current run..."
.Lresume_fail:   .asciz "resume: cannot open the session"
.Lresume_prefix: .asciz "resumed "
.Lempty_session: .asciz "(empty session)"
.Lage_now:       .asciz "now"
.Lage_m:         .asciz "m"
.Lage_h:         .asciz "h"
.Lage_d:         .asciz "d"
.Lcleared:   .asciz "[cleared]"
.Lmodel:     .asciz "model: "
.Lparen:     .asciz "("
.Lparen_close: .asciz ")"
.Lmodel_wait: .asciz "model: wait for the current run to finish"
.Lcannot:    .asciz "cannot switch to '"
.Lthinking:  .asciz "thinking: "
.Lthinking_bad: .asciz "thinking: unknown '"
.Lthinking_suf: .asciz "' (off|low|medium|high)"
# modal picker row metadata (model picker descriptions, thinking rows)
.Lpick_cur:   .asciz "(current) "
.Lpick_ctx:   .asciz " ctx="
.Lpick_reason: .asciz " reasoning"
.Lpick_image: .asciz " image"
.Ltn_off:     .asciz "off"
.Ltn_low:     .asciz "low"
.Ltn_medium:  .asciz "medium"
.Ltn_high:    .asciz "high"
.Ltd_off:     .asciz "disable reasoning"
.Ltd_low:     .asciz "low reasoning effort"
.Ltd_medium:  .asciz "medium reasoning effort"
.Ltd_high:    .asciz "high reasoning effort"
.p2align 3
.Lthink_names:
    .quad .Ltn_off, .Ltn_low, .Ltn_medium, .Ltn_high
.Lthink_descs:
    .quad .Ltd_off, .Ltd_low, .Ltd_medium, .Ltd_high
.Lprompt_fail:  .asciz "prompt: cannot expand '"
.Lskill_missing: .asciz "skill: missing skill name (try /skill:<name>)"
.Lskill_unknown: .asciz "skill: unknown skill '"
.Lskill_toobig:  .asciz "skill: '"
.Lskill_toobig2: .asciz "' is too large"
.Lcompact_prefix: .asciz "[compacted "
.Lcompact_suffix: .asciz " tokens]"
.Lcompact_busy:   .asciz "compact: wait for the current run to finish"
.Lcompact_done:   .asciz "compacted"
.Lcompact_none:   .asciz "nothing to compact"
.Lquote_nl:       .asciz "'"
.Ldouble_nl:     .asciz "\n\n"
.Lthink_prefix:  .ascii "~ "
.Lplaceholder: .asciz "Ready. Press Ctrl-C once to clear, twice to exit"
.Lq_prefix: .asciz "queued "
.Lq_open:   .asciz ": \""
.Lq_close:  .asciz "\" (esc aborts)"
.Lq_suffix: .asciz " (esc aborts)"
.Lhelp:
    .ascii "# opcode\n"
    .ascii "- Enter submit, Alt+Enter newline\n"
    .ascii "- Esc abort run, Ctrl+C clear, Ctrl+D delete/quit\n"
    .ascii "- Ctrl+A/E line ends, Ctrl+B/F chars, Alt+B/F words\n"
    .ascii "- Ctrl+W/Alt+Backspace kill word, Ctrl+K/U/Y kill/yank\n"
    .ascii "- PgUp/PgDn scroll, Tab complete @file, Ctrl+O expand tool\n"
    .ascii "- /model [id] switch model (no argument reports it)\n"
    .ascii "- /thinking [off|low|medium|high]\n"
    .ascii "- /compact compact the conversation into a summary\n"
    .ascii "- /resume /continue switch session\n"
    .ascii "- /theme [dark|light|<name>]\n"
    .asciz "- /quit /new /clear /help\n"
.Lxdg:       .asciz "XDG_STATE_HOME"
.Lhomenv:    .asciz "HOME"
.Ltermenv:   .asciz "TERM"
.Ldumb:      .asciz "dumb"
.Lopcode_ascii: .asciz "OPCODE_ASCII"
.Lpath_xdg:  .asciz "/opcode/history"
.Lpath_home: .asciz "/.local/state/opcode/history"
.Lerr_script:  .asciz "opcode: cannot read script: "
.Lhint_auth:
    .ascii "opcode: hint: 'opcode login <provider>' stores a subscription token,\n"
    .ascii "opcode:       or pass --api-key / set ANTHROPIC_API_KEY or OPENAI_API_KEY.\n"
    .asciz ""
.Lerr_init:
    .ascii "opcode: no interactive terminal detected (stdin is not a TTY).\n"
    .ascii "opcode: use  opcode -p \"your prompt\"  for a one-shot run,\n"
    .ascii "opcode: use  opcode --mode rpc        for JSONL control,\n"
    .ascii "opcode: or run opcode inside a real terminal for the TUI.\n"
    .asciz ""
.Lhintlen = 35

.bss
.p2align 3
.globl g_tui_script
g_tui_script:   .quad 0

t_w:        .zero 4
t_h:        .zero 4
t_dirty:    .zero 4
t_quit:     .zero 4
t_resized:  .zero 4
t_exit:     .zero 4
t_grid:     .zero 256
t_view:     .zero 256
t_ed:       .zero 2048
# sizeof(struct input) = ring (IN_MAXEV*IN_EVSZ = 64*32 = 2048) plus parser
# state/params (IN_par) and IN_pbuf (SB, 24) + flags + IN_paste_prev.  Size the
# buffer generously so the ring can never overrun t_inbuf.
t_in:       .zero 4096
t_inbuf:    .zero 4096
t_scr:      .zero 64
t_stat:     .zero SB_SIZE
t_dump:     .zero SB_SIZE
t_script:   .zero SB_SIZE
t_submit:   .zero SB_SIZE
t_osb:      .zero SB_SIZE
t_san:      .zero SB_SIZE
t_tname:    .zero SB_SIZE
t_targs:    .zero SB_SIZE
t_len:      .zero 8
t_ui_mode:    .zero 4
t_footer_rows: .zero 4
t_footer_up:  .zero 4
t_stream_line: .zero 4
t_streamed:   .zero 4
t_histset:    .zero 4
t_ctrlc_ns:   .zero 8
t_vp_h:       .zero 4
t_last_max:   .zero 4
t_top_pre:    .zero 4
t_was_bottom: .zero 4
t_histpath:   .zero 4096
t_mbuf:       .zero 256
t_bstate:     .zero ST_SIZE
t_usage:      .zero USAGE_SIZE
t_body:       .zero SB_SIZE
t_run_started_ms: .zero 8
t_frame_ms:       .zero 8
t_think_line:     .zero 4
t_compact_seen:   .zero 4
t_qvec:           .zero 8
t_qn:             .zero 4
t_qcap:           .zero 4
t_chat:           .zero CH_SIZE
t_cards_dirty:    .zero 4
t_card_reemit:    .zero 4         # scrollback Ctrl+O: erase+reprint last card
t_theme:          .zero TH_SIZE
t_theme_cfg:      .zero 8
t_md_scratch:     .zero MD_SIZE
t_md_live:        .zero MD_SIZE
t_md_live_base:   .zero 8
t_md_live_on:     .zero 4
# Modal picker row storage: the pointer arrays handed to menu_rows plus a bump
# arena for the model-picker descriptions built each open.
t_pickname:       .zero 8 * 32
t_pickdesc:       .zero 8 * 32
t_picktext:       .zero 8192
t_pickbump:       .zero 8
# Owned session list for the in-TUI resume picker (session_recent VEC).
t_sessions:       .zero 8
# Run-in-flight /resume defers the switch until the abort unwinds.
t_switch_pending: .zero 4
# S7 owned inline region state.  t_in_rows is the region height painted last
# frame; t_in_commit is the first transcript message not yet printed to
# scrollback; t_in_live_base is the number of view rows those committed
# messages occupied when the view was last built; t_in_cw holds each owned
# row's last content column so a resize can estimate its reflowed height.
t_in_rows:        .zero 4
t_in_commit:      .zero 4
t_in_live_base:   .zero 4
# Progressive inline commit: t_in_offset counts the view rows at the top that
# were already printed to scrollback (0 after a rebuild, the committed prefix
# height after a mid-stream commit); t_in_base_len is the transcript length the
# view prefix rendered up to, so a grow can force a rebuild before committing.
t_in_offset:      .zero 4
t_in_base_len:    .zero 4
t_in_cw:          .zero 16384

.text

# ---------------------------------------------------------------- small helpers
cstr_has_slash:
1:  mov al, [rdi]
    test al, al
    jz 2f
    cmp al, '/'
    je 3f
    inc rdi
    jmp 1b
2:  xor eax, eax
    ret
3:  mov eax, 1
    ret

# tui_env(name cstr) -> cstr | 0.  Case-sensitive walk of g_envp.
tui_env:
    mov r8, [rip + g_envp]
    test r8, r8
    jz .Lte_none
    mov r9, rdi
.Lte_next:
    mov rsi, [r8]
    test rsi, rsi
    jz .Lte_none
    mov rdi, r9
    mov rdx, rsi
.Lte_cmp:
    mov al, [rdi]
    test al, al
    jz .Lte_name_end
    cmp al, [rdx]
    jne .Lte_skip
    inc rdi
    inc rdx
    jmp .Lte_cmp
.Lte_name_end:
    cmp byte ptr [rdx], '='
    jne .Lte_skip
    lea rax, [rdx + 1]
    ret
.Lte_skip:
    add r8, 8
    jmp .Lte_next
.Lte_none:
    xor eax, eax
    ret

# tui_banner(): one-shot dim+muted startup banner above the live region.
# Printed once, before term_init, so it lands in the terminal scrollback and is
# never part of a redraw.  Dynamic text (version, registered tool names, the
# active session id) is sanitized.  Suppressed for plain --headless runs; a
# headless capture sink keeps it so a golden can assert it.
#
# Tool summary choice: opcode resolves the banner's engine summary itself, with
# no external backend selector, so the banner lists the names registered in the
# core tool registry instead.
FN tui_banner
    PROLOGUE 0
    cmp qword ptr [rip + g_tui_headless], 0
    je 1f
    cmp qword ptr [rip + g_tui_capture_fd], 0
    jl .Lbn_ret
1:  lea rdi, [rip + t_osb]
    call sb_clear
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lban_opcode]
    call sb_push_cstr
    lea rdi, [rip + t_osb]
    lea rsi, [rip + opcode_version]
    call sb_push_cstr
    call tools_count
    mov r13, rax
    test r13, r13
    jz .Lbn_session
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lban_tools]
    call sb_push_cstr
    xor r12d, r12d
2:  cmp r12, r13
    jae .Lbn_session
    test r12, r12
    jz 3f
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lban_comma]
    call sb_push_cstr
3:  mov rdi, r12
    call tools_at
    test rax, rax
    jz 4f
    lea rdi, [rip + t_osb]
    mov rsi, [rax + TL_name]
    call sb_push_cstr
4:  inc r12
    jmp 2b
.Lbn_session:
    mov rdi, [rip + g_agent_session]
    test rdi, rdi
    jz .Lbn_emit
    call session_id
    test rax, rax
    jz .Lbn_emit
    mov r14, rax
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lban_session]
    call sb_push_cstr
    lea rdi, [rip + t_osb]
    mov rsi, r14
    call sb_push_cstr
.Lbn_emit:
    mov rdi, [rip + t_osb + SB_ptr]
    mov rsi, [rip + t_osb + SB_len]
    lea rdx, [rip + t_san]
    call grid_sanitize_bytes
    mov edi, 1
    lea rsi, [rip + .Lban_dim]
    mov edx, 4
    call tui_write_all
    lea rdi, [rip + t_dump]
    call sb_clear
    mov esi, TH_MUTED
    call theme_rgb
    mov esi, eax
    lea rdi, [rip + t_dump]
    call theme_emit_fg
    mov edi, 1
    mov rsi, [rip + t_dump + SB_ptr]
    mov rdx, [rip + t_dump + SB_len]
    call tui_write_all
    mov edi, 1
    mov rsi, [rip + t_san + SB_ptr]
    mov rdx, [rip + t_san + SB_len]
    call tui_write_all
    mov edi, 1
    lea rsi, [rip + .Lban_reset]
    mov edx, 5
    call tui_write_all
.Lbn_ret:
    EPILOGUE

# tui_notice(ptr, len): append a dim notice in the active presentation mode.
FN tui_notice
    PROLOGUE 0
    mov r12, rdi
    mov r13, rsi
    cmp dword ptr [rip + t_ui_mode], 0
    jne .Lnt_grid
    call inline_prepare
    mov edi, 1
    lea rsi, [rip + .Lin_dim]
    mov edx, 4
    call tui_write_all
    mov rdi, r12
    mov rsi, r13
    call inline_write_san
    mov edi, 1
    lea rsi, [rip + .Lin_sgr0]
    mov edx, 4
    call tui_write_all
    mov edi, 1
    lea rsi, [rip + .Lnl]
    mov edx, 1
    call tui_write_all
    mov dword ptr [rip + t_dirty], 1
    EPILOGUE
.Lnt_grid:
    lea rdi, [rip + t_view]
    mov esi, VS_DIM
    mov rdx, r12
    mov rcx, r13
    call view_append_span
    lea rdi, [rip + t_view]
    call view_break
    mov dword ptr [rip + t_dirty], 1
    EPILOGUE

# tui_menu_sync(): refresh the command menu from the editor text.
FN tui_menu_sync
    PROLOGUE 0
    lea rdi, [rip + t_ed]
    call editor_text
    mov rdi, rax
    mov rsi, rdx
    call menu_update
    EPILOGUE

# tui_placeholder() -> cstr | 0.  Shown only while the transcript is empty and
# no run is in flight; inline tracks t_streamed, fullscreen the view rows.
FN tui_placeholder
    PROLOGUE 0
    call agent_busy
    test eax, eax
    jnz .Lph_none
    cmp dword ptr [rip + t_ui_mode], 0
    jne .Lph_grid
    cmp dword ptr [rip + t_streamed], 0
    jne .Lph_none
    lea rax, [rip + .Lplaceholder]
    EPILOGUE
.Lph_grid:
    lea rdi, [rip + t_view]
    call view_rows
    test eax, eax
    jnz .Lph_none
    lea rax, [rip + .Lplaceholder]
    EPILOGUE
.Lph_none:
    xor eax, eax
    EPILOGUE

# tui_mkdir_p(path): best-effort create every parent component of path.
FN tui_mkdir_p
    PROLOGUE 0
    mov r12, rdi
    mov r13, 1
.Lmp_loop:
    movzx eax, byte ptr [r12 + r13]
    test al, al
    jz .Lmp_done
    cmp al, '/'
    je .Lmp_slash
    inc r13
    jmp .Lmp_loop
.Lmp_slash:
    mov byte ptr [r12 + r13], 0
    mov rdi, r12
    mov esi, 0755
    call os_mkdir
    mov byte ptr [r12 + r13], '/'
    inc r13
    jmp .Lmp_loop
.Lmp_done:
    EPILOGUE

# tui_history_setup(): resolve $XDG_STATE_HOME/opcode/history else
# $HOME/.local/state/opcode/history, create its parent directories and record it.
FN tui_history_setup
    PROLOGUE 0
    lea rdi, [rip + .Lxdg]
    call tui_env
    test rax, rax
    jz .Lhso_home
    cmp byte ptr [rax], 0
    je .Lhso_home
    mov r12, rax
    lea rdi, [rip + t_osb]
    call sb_clear
    lea rdi, [rip + t_osb]
    mov rsi, r12
    call sb_push_cstr
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lpath_xdg]
    call sb_push_cstr
    jmp .Lhso_emit
.Lhso_home:
    lea rdi, [rip + .Lhomenv]
    call tui_env
    test rax, rax
    jz .Lhso_none
    cmp byte ptr [rax], 0
    je .Lhso_none
    mov r12, rax
    lea rdi, [rip + t_osb]
    call sb_clear
    lea rdi, [rip + t_osb]
    mov rsi, r12
    call sb_push_cstr
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lpath_home]
    call sb_push_cstr
.Lhso_emit:
    lea rdi, [rip + t_histpath]
    mov rsi, [rip + t_osb + SB_ptr]
    mov rcx, [rip + t_osb + SB_len]
    inc rcx
    cmp rcx, 4095
    jbe 1f
    mov ecx, 4095
1:  rep movsb
    mov byte ptr [rdi], 0        # always NUL-terminate the path
    mov dword ptr [rip + t_histset], 1
    lea rdi, [rip + t_histpath]
    call tui_mkdir_p
    EPILOGUE
.Lhso_none:
    mov dword ptr [rip + t_histset], 0
    EPILOGUE

out_cstr:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rsi
    call strlen
    mov edi, ebx
    mov rsi, r12
    mov rdx, rax
    call tui_write_all
    EPILOGUE

read_file:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov rdi, r12
    mov esi, O_RDONLY
    xor edx, edx
    call os_open
    test rax, rax
    js .Lrf_ret
    mov r12d, eax
    mov edi, RECV_CHUNK2
    call mem_alloc
    mov rbx, rax
1:  mov edi, r12d
    mov rsi, rbx
    mov edx, RECV_CHUNK2
    call os_read
    test rax, rax
    js .Lrf_err
    jz 2f
    mov rdi, r13
    mov rsi, rbx
    mov rdx, rax
    call sb_push
    jmp 1b
2:  mov edi, r12d
    call os_close
    mov rdi, rbx
    call mem_free
    xor eax, eax
    EPILOGUE
.Lrf_err:
    mov r14, rax
    mov edi, r12d
    call os_close
    mov rdi, rbx
    call mem_free
    mov rax, r14
.Lrf_ret:
    EPILOGUE

# ---------------------------------------------------------------- draw helpers
# tui_row_fill(y, cp, fg, bg): fill one screen row
tui_row_fill:
    PROLOGUE
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov r15d, ecx
    lea rdi, [rip + t_grid]
    xor esi, esi
    mov edx, r12d
    mov ecx, [rip + t_w]
    mov r8d, 1
    mov r9d, r13d
    sub rsp, 16
    mov dword ptr [rsp], r14d
    mov dword ptr [rsp + 8], r15d
    call grid_fill
    add rsp, 16
    EPILOGUE

# tui_str(x, y, fg, bg, cstr)
tui_str:
    PROLOGUE
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov r15d, ecx
    mov rbx, r8
    mov rdi, rbx
    call strlen
    mov [rip + t_len], rax
    lea rdi, [rip + t_grid]
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    mov r8d, r15d
    xor r9d, r9d
    sub rsp, 24
    mov [rsp], rbx
    mov rax, [rip + t_len]
    mov [rsp + 8], rax
    call grid_text
    add rsp, 24
    EPILOGUE

# ---------------------------------------------------------------- inline mode
# Inline (scrollback) renderer: finalized content is written to stdout once and
# only a live footer (status + editor + hint) is redrawn at the bottom.

# tui_write_all(fd, ptr, len): write_all, except fd 1 goes to the headless
# frame-capture sink when one is active, so a script golden can assert the raw
# bytes an inline/fullscreen frame would have emitted.
tui_write_all:
    cmp edi, 1
    jne write_all
    mov rax, [rip + g_tui_capture_fd]
    test rax, rax
    js write_all
    mov edi, eax
    jmp write_all

# inline_push_color(sb, 0xAARRGGBB): append r;g;b without the SGR prefix
FN inline_push_color
    PROLOGUE 0
    mov rbx, rdi
    mov r12d, esi
    mov esi, r12d
    shr esi, 16
    and esi, 0xff
    mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lin_semi]
    mov edx, 1
    call sb_push
    mov esi, r12d
    shr esi, 8
    and esi, 0xff
    mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lin_semi]
    mov edx, 1
    call sb_push
    mov esi, r12d
    and esi, 0xff
    mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lin_m]
    mov edx, 1
    call sb_push
    EPILOGUE

# inline_write_cstr(cstr) -> stdout
FN inline_write_cstr
    PROLOGUE 0
    mov rbx, rdi
    call strlen
    mov edi, 1
    mov rsi, rbx
    mov rdx, rax
    call tui_write_all
    EPILOGUE

# inline_write_san_cstr(cstr): sanitizing variant of inline_write_cstr.
FN inline_write_san_cstr
    PROLOGUE 0
    mov r12, rdi
    call strlen
    mov rdi, r12
    mov rsi, rax
    call inline_write_san
    EPILOGUE

# inline_write_san(ptr, len): write untrusted bytes to stdout through the
# sanitizer.  '\n'/\t' survive; C0/DEL/C1 controls become U+FFFD.
FN inline_write_san
    PROLOGUE 0
    mov r12, rdi
    mov r13, rsi
    mov dword ptr [rip + card_inline_rows], 0
    lea rdi, [rip + t_san]
    call sb_clear
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + t_san]
    call grid_sanitize_bytes
    lea rax, [rip + t_san]
    mov rsi, [rax + SB_ptr]
    mov rdx, [rax + SB_len]
    mov edi, 1
    call tui_write_all
    EPILOGUE

# inline_emit_row(sb, y): append grid row y as ANSI text (no newline)
FN inline_emit_row
    PROLOGUE 48
    mov r12, rdi                # sb
    mov r13d, esi               # y
    mov eax, dword ptr [rip + t_grid + IG_h]
    cmp r13d, eax
    jae .Lier_row_done          # row outside a very short grid
    mov eax, dword ptr [rip + t_grid + IG_w]
    mov r14d, eax               # width
    mov eax, r13d
    imul rax, r14
    imul rax, rax, IG_CELL
    add rax, [rip + t_grid + IG_cells]
    mov [rsp], rax              # row base
    mov r15d, r14d              # last visible column
.Lier_trim:
    test r15d, r15d
    jz .Lier_trim_done
    mov eax, r15d
    dec eax
    imul rax, rax, IG_CELL
    add rax, [rsp]
    mov ecx, [rax]
    test ecx, ecx                  # cp == 0 is padding too
    jz .Lier_trim_blank
    cmp ecx, 0x20
    jne .Lier_trim_done            # content
.Lier_trim_blank:
    # keep a reverse-video caret and a themed band at the row edge, matching
    # render_build and inline_row_width so all three renderers agree.
    test word ptr [rax + 16], A_REVERSE
    jnz .Lier_trim_done
    cmp dword ptr [rax + 12], 0
    jne .Lier_trim_done
.Lier_trim_one:
    dec r15d
    jmp .Lier_trim
.Lier_trim_done:
    mov dword ptr [rsp + 8], 0  # i
    mov dword ptr [rsp + 12], -1
    mov dword ptr [rsp + 16], -1
    mov dword ptr [rsp + 32], -1
.Lier_row_loop:
    mov ecx, [rsp + 8]
    cmp ecx, r15d
    jae .Lier_row_done
    mov rax, [rsp]
    mov rdx, rcx
    imul rdx, rdx, IG_CELL
    add rax, rdx
    mov edx, [rax + 8]          # fg
    mov ecx, [rax + 12]         # bg
    movzx ebx, word ptr [rax + 16]  # attrs
    mov [rsp + 20], edx
    mov [rsp + 24], ecx
    mov [rsp + 28], ebx
    cmp edx, [rsp + 12]
    jne .Lier_style
    cmp ecx, [rsp + 16]
    jne .Lier_style
    cmp ebx, [rsp + 32]
    je .Lier_emit
.Lier_style:
    mov rdi, r12
    lea rsi, [rip + .Lin_sgr0]
    mov edx, 4
    call sb_push
    mov rdi, r12
    mov esi, [rsp + 20]
    call theme_emit_fg
    mov rdi, r12
    mov esi, [rsp + 24]
    call theme_emit_bg
    test ebx, A_BOLD
    jz 1f
    mov rdi, r12
    lea rsi, [rip + .Lin_bold]
    mov edx, 4
    call sb_push
1:  test ebx, A_DIM
    jz 2f
    mov rdi, r12
    lea rsi, [rip + .Lin_dim]
    mov edx, 4
    call sb_push
2:  test ebx, A_UNDERLINE
    jz 3f
    mov rdi, r12
    lea rsi, [rip + .Lin_under]
    mov edx, 4
    call sb_push
3:  test ebx, A_REVERSE
    jz 4f
    mov rdi, r12
    lea rsi, [rip + .Lin_rev]
    mov edx, 4
    call sb_push
4:  test ebx, A_ITALIC
    jz 5f
    mov rdi, r12
    lea rsi, [rip + .Lin_ital]
    mov edx, 4
    call sb_push
5:  mov eax, [rsp + 20]
    mov [rsp + 12], eax
    mov eax, [rsp + 24]
    mov [rsp + 16], eax
    mov eax, [rsp + 28]
    mov [rsp + 32], eax
.Lier_emit:
    mov rax, [rsp]
    mov ecx, [rsp + 8]
    imul rcx, rcx, IG_CELL
    add rax, rcx
    mov esi, [rax]
    cmp esi, IG_CELL_CONT
    je .Lier_emit_next          # continuation column: base glyph covers it
    cmp esi, 0x20
    jb .Lier_emit_sp
    cmp esi, 0x7f
    jne .Lier_emit_cp
.Lier_emit_sp:
    mov esi, 0x20
.Lier_emit_cp:
    mov rdi, r12
    call sb_push_utf8
    mov rax, [rsp]
    mov ecx, [rsp + 8]
    imul rcx, rcx, IG_CELL
    add rax, rcx
    mov esi, [rax + 4]          # combining mark
    test esi, esi
    jz .Lier_emit_next
    cmp esi, 0x20
    jb .Lier_emit_next
    cmp esi, 0x7f
    je .Lier_emit_next
    mov rdi, r12
    call sb_push_utf8
.Lier_emit_next:
    inc dword ptr [rsp + 8]
    jmp .Lier_row_loop
.Lier_row_done:
    EPILOGUE

# inline_footer_clear(): erase the live footer and return to its top row
FN inline_footer_clear
    PROLOGUE 0
    cmp dword ptr [rip + t_footer_rows], 0
    je .Lifc_done
    lea rdi, [rip + t_osb]
    call sb_clear
    mov eax, [rip + t_footer_up]
    test eax, eax
    jz .Lifc_erase
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lin_csi]
    mov edx, 2
    call sb_push
    lea rdi, [rip + t_osb]
    mov esi, [rip + t_footer_up]
    call sb_push_u64
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lin_A]
    mov edx, 1
    call sb_push
.Lifc_erase:
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lin_erase]
    mov edx, 3
    call sb_push
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lin_cr]
    mov edx, 1
    call sb_push
    mov edi, 1
    lea rax, [rip + t_osb]
    mov rsi, [rax + SB_ptr]
    mov rdx, [rax + SB_len]
    call tui_write_all
    mov dword ptr [rip + t_footer_rows], 0
    mov dword ptr [rip + t_footer_up], 0
.Lifc_done:
    EPILOGUE

# inline_prepare(): clear the footer and terminate an open stream line
FN inline_prepare
    call inline_footer_clear
    mov dword ptr [rip + card_inline_rows], 0
    cmp dword ptr [rip + t_stream_line], 0
    je 1f
    mov edi, 1
    lea rsi, [rip + .Lnl]
    mov edx, 1
    call tui_write_all
    mov dword ptr [rip + t_stream_line], 0
1:  xor eax, eax
    ret

# inline_reemit_last_card(): scrollback Ctrl+O.  Erase the terminal rows of the
# last printed card and reprint it with the new expansion state.  Bounded: it
# runs only while the card is the most recent inline output (card_inline_rows
# nonzero), moving up that many rows and clearing from there to the end of the
# screen before re-emitting.
FN inline_reemit_last_card
    PROLOGUE 16
    mov eax, [rip + card_inline_rows]
    test eax, eax
    jz .Lrec_done
    lea rdi, [rip + t_chat]
    call chat_count
    test eax, eax
    jz .Lrec_done
    dec eax
    cmp eax, [rip + card_last_index]
    jne .Lrec_done
    lea rdi, [rip + t_osb]
    call sb_clear
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lin_csi]
    mov edx, 2
    call sb_push
    lea rdi, [rip + t_osb]
    mov esi, [rip + card_inline_rows]
    call sb_push_u64
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lin_A]
    mov edx, 1
    call sb_push
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lin_erase]
    mov edx, 3
    call sb_push
    mov edi, 1
    mov rsi, [rip + t_osb + SB_ptr]
    mov rdx, [rip + t_osb + SB_len]
    call tui_write_all
    mov dword ptr [rip + card_inline_rows], 0
    call tui_now_ms
    mov rdx, rax
    lea rdi, [rip + t_chat]
    mov esi, [rip + t_w]
    call chat_emit_last_inline
.Lrec_done:
    EPILOGUE

# inline_note(cstr): dim one-line note in the transcript
FN inline_note
    PROLOGUE 0
    mov r12, rdi
    call inline_prepare
    mov edi, 1
    lea rsi, [rip + .Lin_dim]
    mov edx, 4
    call tui_write_all
    mov rdi, r12
    call inline_write_san_cstr
    mov edi, 1
    lea rsi, [rip + .Lin_sgr0]
    mov edx, 4
    call tui_write_all
    mov edi, 1
    lea rsi, [rip + .Lnl]
    mov edx, 1
    call tui_write_all
    mov dword ptr [rip + t_dirty], 1
    EPILOGUE

# inline_emit_result(ptr, len): dim, indented, whitespace-trimmed tool output
FN inline_emit_result
    PROLOGUE 32
    mov r12, rdi                # ptr
    mov r13, rsi                # len
    mov dword ptr [rip + card_inline_rows], 0
    xor r14d, r14d              # start
.Lierl_lead:
    cmp r14, r13
    jae .Lierl_empty
    movzx eax, byte ptr [r12 + r14]
    cmp al, ' '
    je 1f
    cmp al, 9
    je 1f
    cmp al, 10
    je 1f
    cmp al, 13
    jne .Lierl_trail
1:  inc r14
    jmp .Lierl_lead
.Lierl_trail:
    mov r15, r13
2:  cmp r15, r14
    jbe .Lierl_empty
    movzx eax, byte ptr [r12 + r15 - 1]
    cmp al, ' '
    je 3f
    cmp al, 9
    je 3f
    cmp al, 10
    je 3f
    cmp al, 13
    jne .Lierl_build
3:  dec r15
    jmp 2b
.Lierl_build:
    # Sanitize the trimmed, untrusted payload once, then indent every line of
    # the safe result.  This keeps model/tool output from injecting escapes.
    lea rdi, [rip + t_san]
    call sb_clear
    lea rdi, [r12 + r14]
    mov rsi, r15
    sub rsi, r14
    lea rdx, [rip + t_san]
    call grid_sanitize_bytes
    lea rdi, [rip + t_osb]
    call sb_clear
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lin_dim]
    mov edx, 4
    call sb_push
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lin_indent]
    mov edx, 2
    call sb_push
    mov r12, [rip + t_san + SB_ptr]
    mov r13, [rip + t_san + SB_len]
    xor r14d, r14d
4:  cmp r14, r13
    jae 5f
    movzx esi, byte ptr [r12 + r14]
    lea rdi, [rip + t_osb]
    call sb_push_byte
    inc r14
    movzx eax, byte ptr [r12 + r14 - 1]
    cmp al, 10
    jne 4b
    cmp r14, r13
    jae 4b
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lin_indent]
    mov edx, 2
    call sb_push
    jmp 4b
5:  lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lnl]
    mov edx, 1
    call sb_push
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lin_sgr0]
    mov edx, 4
    call sb_push
    mov edi, 1
    lea rax, [rip + t_osb]
    mov rsi, [rax + SB_ptr]
    mov rdx, [rax + SB_len]
    call tui_write_all
    EPILOGUE
.Lierl_empty:
    mov edi, 1
    lea rsi, [rip + .Lin_empty_out]
    call out_cstr
    EPILOGUE

# inline_hist_text(msg): print every BT_TEXT block in a message
FN inline_hist_text
    PROLOGUE
    mov r12, [rdi + M_blocks]
    test r12, r12
    jz .Lihx_done
    xor r13d, r13d
1:  cmp r13, [r12 + VEC_len]
    jae .Lihx_done
    mov rax, [r12 + VEC_ptr]
    mov rcx, r13
    imul rcx, rcx, B_SIZE
    add rax, rcx
    cmp dword ptr [rax + B_type], BT_TEXT
    jne 2f
    mov rdi, [rax + B_ptr]
    mov rsi, [rax + B_len]
    call inline_write_san
2:  inc r13d
    jmp 1b
.Lihx_done:
    EPILOGUE

# inline_hist_msg(msg): replay one transcript message into scrollback
FN inline_hist_msg
    PROLOGUE
    mov r12, rdi
    test r12, r12
    jz .Lihm_done
    mov eax, [r12 + M_role]
    cmp eax, MR_USER
    je .Lihm_user
    cmp eax, MR_ASSISTANT
    je .Lihm_assist
    cmp eax, MR_TOOL_RESULT
    je .Lihm_result
    EPILOGUE
.Lihm_user:
    mov edi, 1
    lea rsi, [rip + .Larrow]
    mov edx, 2
    call tui_write_all
    mov rdi, r12
    call inline_hist_text
    mov edi, 1
    lea rsi, [rip + .Lnl]
    mov edx, 1
    call tui_write_all
    EPILOGUE
.Lihm_assist:
    mov r13, [r12 + M_blocks]
    test r13, r13
    jz .Lihm_done
    xor r14d, r14d
    mov r15, 0
1:  cmp r14, [r13 + VEC_len]
    jae .Lihm_done
    mov r15, [r13 + VEC_ptr]
    mov rax, r14
    imul rax, rax, B_SIZE
    add r15, rax
    mov esi, [r15 + B_type]
    cmp esi, BT_TEXT
    je 2f
    cmp esi, BT_TOOLCALL
    je 3f
4:  inc r14
    jmp 1b
2:  mov rdi, [r15 + B_ptr]
    mov rsi, [r15 + B_len]
    call tui_inline_md
    jmp 4b
3:  mov edi, 1
    lea rsi, [rip + .Lin_tool]
    mov edx, 7
    call tui_write_all
    mov rdi, [r15 + B_ptr]
    mov rdi, [rdi + TC_name]
    call inline_write_san_cstr
    mov rdi, [r15 + B_ptr]
    mov rdi, [rdi + TC_args]
    test rdi, rdi
    jz 5f
    mov edi, 1
    lea rsi, [rip + .Lin_space]
    mov edx, 1
    call tui_write_all
    mov rdi, [r15 + B_ptr]
    mov rdi, [rdi + TC_args]
    call inline_write_san_cstr
5:  mov edi, 1
    lea rsi, [rip + .Lnl]
    mov edx, 1
    call tui_write_all
    jmp 4b
.Lihm_result:
    mov r13, [r12 + M_blocks]
    test r13, r13
    jz .Lihm_done
    xor r14d, r14d
6:  cmp r14, [r13 + VEC_len]
    jae .Lihm_done
    mov r15, [r13 + VEC_ptr]
    mov rax, r14
    imul rax, rax, B_SIZE
    add r15, rax
    cmp dword ptr [r15 + B_type], BT_TEXT
    jne 7f
    mov rdi, [r15 + B_ptr]
    mov rsi, [r15 + B_len]
    call inline_emit_result
7:  inc r14
    jmp 6b
.Lihm_done:
    EPILOGUE

# inline_history(): replay an existing session transcript once
FN inline_history
    PROLOGUE
    call agent_transcript
    mov r12, [rax + TR_msgs]
    xor r13d, r13d
    cmp qword ptr [r12 + VEC_len], 0
    je .Lih_nostream
    mov dword ptr [rip + t_streamed], 1
.Lih_nostream:
1:  cmp r13, [r12 + VEC_len]
    jae 2f
    mov rax, [r12 + VEC_ptr]
    mov rdi, [rax + r13*8]
    call inline_hist_msg
    inc r13d
    jmp 1b
2:  call agent_current_msg
    test rax, rax
    jz 3f
    mov dword ptr [rip + t_streamed], 1
    mov rdi, rax
    call inline_hist_msg
3:  EPILOGUE

# tui_hook_inline(ctx, event, a, b): append-only transcript events
FN tui_hook_inline
    PROLOGUE
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    cmp r12d, SE_TEXT
    je .Lhi_text
    cmp r12d, SE_TEXT_END
    je .Lhi_text_end
    cmp r12d, SE_TOOL_START
    je .Lhi_tool_start
    cmp r12d, SE_TOOL_DELTA
    je .Lhi_tool_delta
    cmp r12d, SE_TOOL_END
    je .Lhi_tool_end
    cmp r12d, SE_TOOL_RESULT
    je .Lhi_result
    cmp r12d, SE_TOOL_EXEC
    je .Lhi_exec
    cmp r12d, SE_ERROR
    je .Lhi_error
    cmp r12d, SE_THINK
    je .Lhi_think
    cmp r12d, SE_THINK_END
    je .Lhi_think_end
    cmp r12d, SE_COMPACT
    je .Lhi_compact
    EPILOGUE
.Lhi_text:
    test r14, r14
    jz .Lhi_ret
    mov dword ptr [rip + t_streamed], 1
    call inline_footer_clear
    mov rdi, r13
    mov rsi, r14
    call inline_write_san
    mov eax, 1
    cmp byte ptr [r13 + r14 - 1], 10
    jne 1f
    xor eax, eax
1:  mov [rip + t_stream_line], eax
    mov dword ptr [rip + t_dirty], 1
    EPILOGUE
.Lhi_text_end:
    cmp dword ptr [rip + t_stream_line], 0
    je .Lhi_ret
    call inline_prepare
    mov dword ptr [rip + t_dirty], 1
    EPILOGUE
.Lhi_tool_start:
    call tui_now_ms
    mov rcx, rax
    lea rdi, [rip + t_chat]
    mov rsi, r13
    mov rdx, r14
    call chat_tool_start
    EPILOGUE
.Lhi_tool_delta:
    lea rdi, [rip + t_chat]
    mov rsi, r13
    mov rdx, r14
    call chat_tool_delta
    EPILOGUE
.Lhi_tool_end:
    # inline cannot repaint an owned region yet (S7): the finished card is
    # emitted once on SE_TOOL_EXEC, so nothing is printed here.
    EPILOGUE
.Lhi_result:
    # body lives in SE_TOOL_EXEC
    EPILOGUE
.Lhi_exec:
    call inline_prepare
    lea rdi, [rip + t_chat]
    mov rsi, r13
    call chat_tool_exec
    call tui_now_ms
    mov rdx, rax
    lea rdi, [rip + t_chat]
    mov esi, [rip + t_w]
    call chat_emit_last_inline
    mov dword ptr [rip + t_streamed], 1
    mov dword ptr [rip + t_dirty], 1
    EPILOGUE
.Lhi_error:
    call inline_prepare
    mov dword ptr [rip + t_streamed], 1
    mov edi, 2
    lea rsi, [rip + .Lin_red]
    mov edx, 5
    call tui_write_all
    lea rdi, [rip + t_san]
    call sb_clear
    mov rdi, r13
    call strlen
    mov rsi, rax
    mov rdi, r13
    lea rdx, [rip + t_san]
    call grid_sanitize_bytes
    mov edi, 2
    lea rax, [rip + t_san]
    mov rsi, [rax + SB_ptr]
    mov rdx, [rax + SB_len]
    call tui_write_all
    mov edi, 2
    lea rsi, [rip + .Lin_sgr0]
    mov edx, 4
    call tui_write_all
    mov edi, 2
    lea rsi, [rip + .Lnl]
    mov edx, 1
    call tui_write_all
    mov dword ptr [rip + t_dirty], 1
.Lhi_ret:
    EPILOGUE

# SE_THINK/SE_THINK_END: the transcript records the block either way; the view
# renders it only while the configured level is non-off.
.Lhi_think:
    test r14, r14
    jz .Lhi_ret
    call agent_thinking
    test eax, eax
    jz .Lhi_ret
    mov dword ptr [rip + t_streamed], 1
    cmp dword ptr [rip + t_think_line], 0
    jne 1f
    call inline_footer_clear
    mov edi, 1
    lea rsi, [rip + .Lin_dim]
    mov edx, 4
    call tui_write_all
    mov edi, 1
    lea rsi, [rip + .Lthink_prefix]
    mov edx, 2
    call tui_write_all
    mov dword ptr [rip + t_think_line], 1
1:  mov rdi, r13
    mov rsi, r14
    call inline_write_san
    mov eax, 1
    cmp byte ptr [r13 + r14 - 1], 10
    jne 2f
    xor eax, eax
2:  mov [rip + t_stream_line], eax
    mov dword ptr [rip + t_dirty], 1
    EPILOGUE
.Lhi_think_end:
    cmp dword ptr [rip + t_think_line], 0
    je .Lhi_ret
    mov dword ptr [rip + t_think_line], 0
    cmp dword ptr [rip + t_stream_line], 0
    je 1f
    mov edi, 1
    lea rsi, [rip + .Lnl]
    mov edx, 1
    call tui_write_all
    mov dword ptr [rip + t_stream_line], 0
1:  mov edi, 1
    lea rsi, [rip + .Lin_sgr0]
    mov edx, 4
    call tui_write_all
    mov dword ptr [rip + t_dirty], 1
    EPILOGUE
.Lhi_compact:
    mov dword ptr [rip + t_compact_seen], 1
    lea rdi, [rip + t_osb]
    call sb_clear
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lcompact_prefix]
    call sb_push_cstr
    lea rdi, [rip + t_osb]
    mov esi, r13d
    call sb_push_u64
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lcompact_suffix]
    call sb_push_cstr
    mov rdi, [rip + t_osb + SB_ptr]
    mov rsi, [rip + t_osb + SB_len]
    call tui_notice
    EPILOGUE

# tui_draw_inline(): redraw the live footer: composer, menu, status at the end.
FN tui_draw_inline
    PROLOGUE 64
    call inline_footer_clear
    cmp dword ptr [rip + t_card_reemit], 0
    je 1f
    mov dword ptr [rip + t_card_reemit], 0
    call inline_reemit_last_card
1:  call tui_menu_sync
    call tui_status
    # qrows = 1 while the shell queue has pending messages
    xor eax, eax
    cmp dword ptr [rip + t_qn], 0
    je 20f
    mov eax, 1
20: mov [rbp + LI_q], eax
    # composer_rows = min(editor_visual_rows(ed,W), 6), at least 1
    lea rdi, [rip + t_ed]
    mov esi, [rip + t_w]
    call editor_visual_rows
    test eax, eax
    jnz 21f
    mov eax, 1
21: cmp eax, 6
    jbe 22f
    mov eax, 6
22: # clamp to H-1-qrows so the mandatory footer row always fits
    mov ecx, [rip + t_h]
    dec ecx
    sub ecx, [rbp + LI_q]
    cmp ecx, 1
    jge 23f
    mov ecx, 1
23: cmp eax, ecx
    jbe 24f
    mov eax, ecx
24: mov [rbp + LI_erows], eax
    # menu_h = menu_height(H - qrows - composer_rows - 1); the menu yields first
    mov ecx, [rip + t_h]
    sub ecx, [rbp + LI_q]
    sub ecx, eax
    dec ecx
    jns 25f
    xor ecx, ecx
25: mov esi, ecx
    call menu_height
    mov [rbp + LI_mh], eax
    # footer_rows = qrows + composer_rows + menu_h + 1
    mov eax, [rbp + LI_q]
    add eax, [rbp + LI_erows]
    add eax, [rbp + LI_mh]
    inc eax
    mov [rbp + LI_fh], eax
    # blank the composer rows (rule/input/rule are painted by editor_render)
    xor r12d, r12d
26: cmp r12d, [rbp + LI_erows]
    jae 27f
    mov esi, TH_FG
    call theme_rgb
    mov r14d, eax
    mov edi, r12d
    add edi, [rbp + LI_q]
    mov esi, ' '
    mov edx, r14d
    xor ecx, ecx
    call tui_row_fill
    inc r12d
    jmp 26b
    # queue strip on the first live footer row
27: cmp dword ptr [rbp + LI_q], 0
    je 28f
    xor edi, edi
    call tui_queue_strip
    # composer below the strip
28: call tui_placeholder
    mov r15, rax
    mov esi, TH_MUTED
    call theme_rgb
    mov r14d, eax
    lea rdi, [rip + t_ed]
    lea rsi, [rip + t_grid]
    xor edx, edx                 # x = 0
    mov ecx, [rbp + LI_q]        # y = qrows
    mov r8d, [rip + t_w]
    mov r9d, [rbp + LI_erows]
    sub rsp, 32
    mov dword ptr [rsp], 0                # bg = terminal default
    mov [rsp + 8], r14d                   # muted
    mov dword ptr [rsp + 16], 1           # cursor_visible
    mov [rsp + 24], r15                   # placeholder
    call editor_render
    add rsp, 32
    mov [rbp + LI_cx], eax
    mov [rbp + LI_cy], edx
    test edx, edx
    jns 80f
    mov dword ptr [rbp + LI_cy], 0
80: # menu between the composer and the footer
    cmp dword ptr [rbp + LI_mh], 0
    jle 8f
    lea rdi, [rip + t_grid]
    xor esi, esi
    mov edx, [rbp + LI_erows]
    add edx, [rbp + LI_q]
    mov ecx, [rip + t_w]
    mov r8d, [rbp + LI_mh]
    call menu_render
    # status footer on the last live row
8:  mov esi, [rbp + LI_fh]
    dec esi
    call tui_status
    # serialise the live footer; suppress autowrap around the full-width rows
    lea rdi, [rip + t_osb]
    call sb_clear
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lin_aw_off]
    mov edx, 5
    call sb_push
    xor r12d, r12d
9:  cmp r12d, [rbp + LI_fh]
    jae 10f
    test r12d, r12d
    jz 11f
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lin_crlf]
    mov edx, 2
    call sb_push
11: lea rdi, [rip + t_osb]
    mov esi, r12d
    call inline_emit_row
    inc r12d
    jmp 9b
10: lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lin_aw_on]
    mov edx, 5
    call sb_push
    mov edi, 1
    lea rax, [rip + t_osb]
    mov rsi, [rax + SB_ptr]
    mov rdx, [rax + SB_len]
    call tui_write_all
    # park the hardware cursor on the composer caret
    lea rdi, [rip + t_osb]
    call sb_clear
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lin_cr]
    mov edx, 1
    call sb_push
    mov eax, [rbp + LI_fh]
    dec eax
    sub eax, [rbp + LI_cy]
    mov [rbp + LI_up], eax
    test eax, eax
    jz 12f
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lin_csi]
    mov edx, 2
    call sb_push
    lea rdi, [rip + t_osb]
    mov esi, [rbp + LI_up]
    call sb_push_u64
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lin_A]
    mov edx, 1
    call sb_push
12: mov eax, [rbp + LI_cx]
    test eax, eax
    jns 13f
    xor eax, eax
13: mov ecx, [rip + t_w]
    dec ecx
    cmp eax, ecx
    jbe 14f
    mov eax, ecx
14: test eax, eax
    jz 15f
    mov [rbp + LI_scol], eax
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lin_csi]
    mov edx, 2
    call sb_push
    lea rdi, [rip + t_osb]
    mov esi, [rbp + LI_scol]
    call sb_push_u64
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lin_C]
    mov edx, 1
    call sb_push
15: mov edi, 1
    lea rax, [rip + t_osb]
    mov rsi, [rax + SB_ptr]
    mov rdx, [rax + SB_len]
    call tui_write_all
    mov eax, [rbp + LI_fh]
    mov [rip + t_footer_rows], eax
    mov eax, [rbp + LI_cy]
    test eax, eax
    jns 16f
    xor eax, eax
16: mov [rip + t_footer_up], eax
    EPILOGUE

# ------------------------------------------------------- owned inline region
# S7: the region owns the bottom h rows (transcript tail + queue strip +
# composer + menu + footer).  Between frames the hardware cursor is parked
# (hidden) at the region top-left, so a commit prints at the region top with
# newline mode and pushes the region down into real scrollback.  Every owned
# row is repainted with a full-line clear; all movement is cursor-relative so
# a repaint can never scroll the screen (autowrap is off around the frame).

# inline_row_width(edi=y) -> eax: last content column + wide (0 = blank).
# Counts text, a themed background band and the reverse-video caret, so a
# resize can estimate how many rows this owned row re-wraps to.
FN inline_row_width
    PROLOGUE
    mov r12d, edi
    mov eax, [rip + t_grid + IG_h]
    cmp r12d, eax
    jae .Lirw_zero
    mov r14d, [rip + t_grid + IG_w]
    test r14d, r14d
    jz .Lirw_zero
    mov eax, r12d
    imul rax, r14
    imul rax, rax, IG_CELL
    add rax, [rip + t_grid + IG_cells]
    mov r13, rax
    mov ecx, r14d
    dec ecx
.Lirw_loop:
    mov eax, ecx
    imul rax, rax, IG_CELL
    lea rdx, [r13 + rax]
    mov eax, [rdx]
    cmp eax, IG_CELL_CONT
    je .Lirw_next
    test eax, eax
    jz .Lirw_band
    cmp eax, ' '
    jne .Lirw_hit
.Lirw_band:
    cmp dword ptr [rdx + 12], 0
    jne .Lirw_hit
    test word ptr [rdx + 16], 8
    jnz .Lirw_hit
.Lirw_next:
    dec ecx
    jns .Lirw_loop
.Lirw_zero:
    xor eax, eax
    EPILOGUE
.Lirw_hit:
    mov eax, ecx
    inc eax
    cmp eax, r14d
    jae .Lirw_ret
    mov edx, eax
    imul rdx, rdx, IG_CELL
    lea rdx, [r13 + rdx]
    cmp dword ptr [rdx], IG_CELL_CONT
    jne .Lirw_ret
    inc eax
.Lirw_ret:
    EPILOGUE

# inline_emit_committed(): print the view rows [t_in_offset, t_in_live_base)
# that belong to the finished transcript prefix into scrollback exactly once,
# each under a full-line clear and a CRLF.  One write.  The caller advances
# t_in_commit/t_in_offset; the live tail (a_msg + unmatched cards) starts at
# t_in_live_base and is never printed.  Can run while the agent is busy: the
# committed rows are whole finished messages, so nothing is printed twice.
FN inline_emit_committed
    PROLOGUE 16
    lea rdi, [rip + t_osb]
    call sb_clear
    lea rdi, [rip + t_osb]; lea rsi, [rip + .Lin_hide];   mov edx, 6; call sb_push
    lea rdi, [rip + t_osb]; lea rsi, [rip + .Lin_aw_off]; mov edx, 5; call sb_push
    lea rdi, [rip + t_view]
    xor esi, esi
    xor edx, edx
    mov ecx, [rip + t_w]
    mov r8d, 1
    call view_set_vp
    mov r12d, [rip + t_in_offset]
.Liec_loop:
    cmp r12d, [rip + t_in_live_base]
    jae .Liec_done
    mov dword ptr [rip + t_view + VV_top], r12d
    lea rdi, [rip + t_osb]; lea rsi, [rip + .Lin_rowclr]; mov edx, 4; call sb_push
    lea rdi, [rip + t_grid]
    xor esi, esi
    xor edx, edx
    call grid_clear
    lea rdi, [rip + t_view]
    lea rsi, [rip + t_grid]
    xor edx, edx
    xor ecx, ecx
    call view_draw
    lea rdi, [rip + t_osb]
    xor esi, esi
    call inline_emit_row
    lea rdi, [rip + t_osb]; lea rsi, [rip + .Lin_crlf]; mov edx, 2; call sb_push
    inc r12d
    jmp .Liec_loop
.Liec_done:
    lea rdi, [rip + t_osb]; lea rsi, [rip + .Lin_aw_on]; mov edx, 5; call sb_push
    mov edi, 1
    lea rax, [rip + t_osb]
    mov rsi, [rax + SB_ptr]
    mov rdx, [rax + SB_len]
    call tui_write_all
    EPILOGUE

# tui_commit_prefix_len(rdi=TR_msgs VEC*, esi=from) -> eax: the largest message
# index >= from such that every message in [from, eax) is finished.  A message
# stays live while one of its tool cards is still running, so a progressive
# commit must stop before it.  Streaming assistant text is not a block in the
# transcript yet, so it never appears here.
FN tui_commit_prefix_len
    PROLOGUE 16
    mov r12, rdi                # VEC* of Msg*
    mov r13d, esi               # from
.Lcpl_loop:
    cmp r13d, [r12 + VEC_len]
    jae .Lcpl_done
    mov rax, [r12 + VEC_ptr]
    mov rdi, [rax + r13*8]      # Msg*
    test rdi, rdi
    jz .Lcpl_next
    mov rax, [rdi + M_blocks]
    test rax, rax
    jz .Lcpl_next
    mov r15, rax                # VEC* of Block
    mov dword ptr [rbp - 48], 0
.Lcpl_blk:
    mov eax, [rbp - 48]
    cmp rax, [r15 + VEC_len]
    jae .Lcpl_next
    mov rax, [r15 + VEC_ptr]
    mov ecx, [rbp - 48]
    imul rcx, rcx, B_SIZE
    add rax, rcx
    cmp dword ptr [rax + B_type], BT_TOOLCALL
    jne .Lcpl_bnext
    mov rdi, [rax + B_ptr]      # ToolCall*
    test rdi, rdi
    jz .Lcpl_bnext
    mov rsi, [rdi + TC_id]
    test rsi, rsi
    jz .Lcpl_bnext
    lea rdi, [rip + t_chat]
    call chat_find
    test rax, rax
    jz .Lcpl_bnext
    cmp dword ptr [rax + CD_running], 0
    jne .Lcpl_done
.Lcpl_bnext:
    inc dword ptr [rbp - 48]
    jmp .Lcpl_blk
.Lcpl_next:
    inc r13d
    jmp .Lcpl_loop
.Lcpl_done:
    mov eax, r13d
    EPILOGUE

# tui_suppress_committed_cards(rdi=chat, rsi=TR_msgs VEC*, edx=committed): mark
# every tool card referenced by an already-committed transcript message as
# rendered.  A rebuild only draws messages from t_in_commit on, so a committed
# message's card is otherwise "unmatched" and chat_render_unmatched would paint
# it into the live region a second time.  Runs after chat_reset_marks so the
# flag survives the rebuild.
FN tui_suppress_committed_cards
    PROLOGUE 16
    mov r12, rdi                # chat
    mov r13, rsi                # VEC* of Msg*
    mov r14d, edx               # committed message count
    test r14d, r14d
    jz .Ltsc_done
    cmp r14d, [r13 + VEC_len]
    jbe 1f
    mov r14d, [r13 + VEC_len]
1:  xor ebx, ebx
.Ltsc_msg:
    cmp ebx, r14d
    jae .Ltsc_done
    mov rax, [r13 + VEC_ptr]
    mov rdi, [rax + rbx*8]      # Msg*
    test rdi, rdi
    jz .Ltsc_next
    mov rax, [rdi + M_blocks]
    test rax, rax
    jz .Ltsc_next
    mov r15, rax                # VEC* of Block
    mov dword ptr [rbp - 48], 0
.Ltsc_blk:
    mov eax, [rbp - 48]
    cmp rax, [r15 + VEC_len]
    jae .Ltsc_next
    mov rax, [r15 + VEC_ptr]
    mov ecx, [rbp - 48]
    imul rcx, rcx, B_SIZE
    add rax, rcx
    cmp dword ptr [rax + B_type], BT_TOOLCALL
    jne .Ltsc_bnext
    mov rdi, [rax + B_ptr]      # ToolCall*
    test rdi, rdi
    jz .Ltsc_bnext
    mov rsi, [rdi + TC_id]
    test rsi, rsi
    jz .Ltsc_bnext
    mov rdi, r12
    call chat_find
    test rax, rax
    jz .Ltsc_bnext
    mov dword ptr [rax + CD_rendered], 1
.Ltsc_bnext:
    inc dword ptr [rbp - 48]
    jmp .Ltsc_blk
.Ltsc_next:
    inc ebx
    jmp .Ltsc_msg
.Ltsc_done:
    EPILOGUE

# tui_scrollbar(edi=track, rsi=total, rdx=visible, rcx=scroll)
# A one-column scrollbar in the grid's last column over `track` rows: a dim `|`
# track with a reverse-video thumb sized by visible/total and positioned by
# `scroll` rows from the bottom (0 = bottom).  A no-op when total <= visible or
# the geometry is degenerate.
FN tui_scrollbar
    PROLOGUE 48
    test edi, edi
    jle .Lsb_done
    test rsi, rsi
    jz .Lsb_done
    test rdx, rdx
    jz .Lsb_done
    cmp rsi, rdx
    jbe .Lsb_done
    mov r12d, edi                 # track
    mov r13, rsi                  # total
    mov r14, rdx                  # visible
    mov r15, rcx                  # scroll from bottom
    mov rax, r12
    imul rax, r14
    xor edx, edx
    div r13
    test rax, rax
    jnz 1f
    mov eax, 1
1:  cmp rax, r12
    jbe 2f
    mov rax, r12
2:  mov [rbp - 48], rax           # thumb rows
    mov rbx, r13
    sub rbx, r14                  # max_scroll
    cmp r15, rbx
    jbe 3f
    mov r15, rbx
3:  mov rax, rbx
    sub rax, r15
    mov rcx, r12
    sub rcx, [rbp - 48]
    imul rax, rcx
    test rbx, rbx
    jz 4f
    xor edx, edx
    div rbx
4:  mov [rbp - 56], rax           # top row
    mov esi, TH_FG
    call theme_rgb
    mov [rbp - 64], eax
    mov esi, TH_MUTED
    call theme_rgb
    mov [rbp - 68], eax
    mov rax, [rip + t_grid + IG_cells]
    mov [rbp - 72], rax
    mov eax, [rip + t_grid + IG_w]
    mov [rbp - 80], eax
    xor r13d, r13d                 # y
.Lsb_loop:
    cmp r13d, r12d
    jae .Lsb_done
    mov eax, [rbp - 80]
    dec eax
    test eax, eax
    js .Lsb_done
    mov rcx, r13
    imul rcx, [rbp - 80]
    add rcx, rax
    imul rcx, rcx, IG_CELL
    add rcx, [rbp - 72]
    mov rax, [rbp - 56]
    cmp r13, rax
    jb .Lsb_track
    add rax, [rbp - 48]
    cmp r13, rax
    jae .Lsb_track
    mov dword ptr [rcx + IG_Ccp], ' '
    mov dword ptr [rcx + IG_Ccomb], 0
    mov eax, [rbp - 64]
    mov [rcx + IG_Cfg], eax
    mov dword ptr [rcx + IG_Cbg], 0
    mov word ptr [rcx + IG_Cattrs], 8       # A_REVERSE
    jmp .Lsb_next
.Lsb_track:
    mov dword ptr [rcx + IG_Ccp], '|'
    mov dword ptr [rcx + IG_Ccomb], 0
    mov eax, [rbp - 68]
    mov [rcx + IG_Cfg], eax
    mov dword ptr [rcx + IG_Cbg], 0
    mov word ptr [rcx + IG_Cattrs], 4       # A_DIM
.Lsb_next:
    inc r13d
    jmp .Lsb_loop
.Lsb_done:
    xor eax, eax
    EPILOGUE

# tui_draw_region(): compose and paint the owned inline region.
FN tui_draw_region
    PROLOGUE 64
    # ---- commit the finished transcript prefix (busy or idle) ------------
    # Every transcript message is finished by construction: the live, still
    # changing content is a_msg plus any unmatched/running card, and both are
    # rendered after t_in_live_base.  So the prefix can flow to real scrollback
    # on every frame instead of waiting for the run to end.  t_in_offset counts
    # the view rows already printed; the region
    # draws only [t_in_offset, view_total), so a commit that cannot rebuild the
    # view mid-stream still leaves just the live tail on screen.
    call agent_transcript
    mov r12, [rax + TR_msgs]
    mov eax, [rip + t_in_commit]
    cmp eax, [r12 + VEC_len]
    jbe .Lrg_cmp
    mov dword ptr [rip + t_in_commit], 0
    mov dword ptr [rip + t_in_offset], 0
    mov dword ptr [rip + t_in_base_len], 0
    xor eax, eax
.Lrg_cmp:
    # C = the largest finished prefix.  A message with a still-running tool card
    # is live and must not be printed yet (the old idle guard implicitly waited
    # for it); everything before C is a finished whole message.
    mov rdi, r12
    mov esi, eax
    call tui_commit_prefix_len
    mov r13d, eax
    cmp eax, [rip + t_in_commit]
    jbe .Lrg_layout                # nothing new finished
    # The view prefix must cover C before it is printed.  A rebuild resets the
    # live markdown scratch, so while a text block streams the new prefix is
    # deferred; the common case (C unchanged since the last rebuild) commits
    # straight from the view, mid-run.
    mov ecx, [rip + t_in_base_len]
    cmp ecx, r13d
    jae .Lrg_cancommit
    cmp dword ptr [rip + t_md_live_on], 0
    jne .Lrg_layout
    call tui_render_all
.Lrg_cancommit:
    mov eax, [rip + t_in_live_base]
    cmp eax, [rip + t_in_offset]
    jbe .Lrg_layout
    call inline_emit_committed
    mov eax, [rip + t_in_live_base]
    mov [rip + t_in_offset], eax
    mov [rip + t_in_commit], r13d
    # Idle: nothing is live, so the committed cards can be dropped outright,
    # which bounds the card vector over a long session.  While busy they stay
    # and tui_render_all's committed-card pass keeps them out of the region.
    call agent_busy
    test eax, eax
    jnz .Lrg_layout
    lea rdi, [rip + t_chat]
    call chat_clear
.Lrg_layout:
    call tui_menu_sync
    # q = queue strip rows
    xor eax, eax
    cmp dword ptr [rip + t_qn], 0
    je .Lrg_q
    mov eax, 1
.Lrg_q:
    mov [rbp + RG_q], eax
    # erows = min(editor rows, 6), clamped to H-1-q (a footer row is mandatory)
    lea rdi, [rip + t_ed]
    mov esi, [rip + t_w]
    call editor_visual_rows
    test eax, eax
    jnz .Lrg_e1
    mov eax, 1
.Lrg_e1:
    cmp eax, 6
    jbe .Lrg_e2
    mov eax, 6
.Lrg_e2:
    mov ecx, [rip + t_h]
    dec ecx
    sub ecx, [rbp + RG_q]
    cmp ecx, 1
    jge .Lrg_e3
    mov ecx, 1
.Lrg_e3:
    cmp eax, ecx
    jbe .Lrg_e4
    mov eax, ecx
.Lrg_e4:
    mov [rbp + RG_erows], eax
    # menu yields first
    mov ecx, [rip + t_h]
    dec ecx
    sub ecx, [rbp + RG_q]
    sub ecx, eax
    jns .Lrg_m1
    xor ecx, ecx
.Lrg_m1:
    mov esi, ecx
    call menu_height
    mov [rbp + RG_mh], eax
    # budget = H - 1 - q - erows - menu
    mov ecx, [rip + t_h]
    dec ecx
    sub ecx, [rbp + RG_q]
    sub ecx, [rbp + RG_erows]
    sub ecx, [rbp + RG_mh]
    jns .Lrg_b1
    xor ecx, ecx
.Lrg_b1:
    mov [rbp + RG_bud], ecx
    # chat = min(budget, view_total - t_in_offset): the region is only as tall
    # as the uncommitted live tail; printed rows at the view top are skipped.
    lea rdi, [rip + t_view]
    call view_total
    mov ecx, [rip + t_in_offset]
    sub rax, rcx
    jns .Lrg_lo
    xor eax, eax
.Lrg_lo:
    mov [rbp + RG_tot], rax
    mov eax, [rbp + RG_bud]
    cmp rax, [rbp + RG_tot]
    jbe .Lrg_c1
    mov eax, [rbp + RG_tot]
.Lrg_c1:
    mov [rbp + RG_chat], eax
    mov [rip + t_vp_h], eax
    lea rdi, [rip + t_view]
    xor esi, esi
    xor edx, edx
    mov ecx, [rip + t_w]
    mov r8d, eax
    call view_set_vp
    # rebuild the view from cards while a tool runs or once a card changed
    cmp dword ptr [rip + t_cards_dirty], 0
    jne .Lrg_rb
    lea rdi, [rip + t_chat]
    call chat_has_running
    test eax, eax
    jz .Lrg_norb
.Lrg_rb:
    call tui_render_all
    mov dword ptr [rip + t_cards_dirty], 0
.Lrg_norb:
    call tui_stick_bottom
    # Never draw a row that was already committed to scrollback.  The bottom
    # anchor is normally above t_in_offset; this only matters if a scroll
    # reached past the committed boundary.
    mov eax, [rip + t_in_offset]
    cmp [rip + t_view + VV_top], eax
    jae .Lrg_offok
    mov [rip + t_view + VV_top], eax
.Lrg_offok:
    lea rdi, [rip + t_grid]
    xor esi, esi
    xor edx, edx
    call grid_clear
    lea rdi, [rip + t_view]
    lea rsi, [rip + t_grid]
    xor edx, edx
    xor ecx, ecx
    call view_draw
    # Scrollbar when the uncommitted tail is taller than the region; the thumb
    # follows the viewport so PgUp/PgDn visibly move it.
    mov edi, [rbp + RG_chat]      # track = visible
    mov rsi, [rbp + RG_tot]       # total = uncommitted tail rows
    mov edx, edi                 # visible
    mov ecx, esi
    sub ecx, edi                 # max_scroll = total - visible
    mov eax, [rip + t_view + VV_top]
    sub eax, [rip + t_in_offset]
    jns 1f
    xor eax, eax
1:  sub ecx, eax                 # scroll from bottom
    jns 2f
    xor ecx, ecx
2:  call tui_scrollbar
    cmp dword ptr [rbp + RG_q], 0
    je .Lrg_noq
    mov edi, [rbp + RG_chat]
    call tui_queue_strip
.Lrg_noq:
    call tui_placeholder
    mov r15, rax
    mov esi, TH_MUTED
    call theme_rgb
    mov r14d, eax
    lea rdi, [rip + t_ed]
    lea rsi, [rip + t_grid]
    xor edx, edx
    mov ecx, [rbp + RG_chat]
    add ecx, [rbp + RG_q]
    mov r8d, [rip + t_w]
    mov r9d, [rbp + RG_erows]
    sub rsp, 32
    mov dword ptr [rsp], 0
    mov [rsp + 8], r14d
    mov dword ptr [rsp + 16], 1
    mov [rsp + 24], r15
    call editor_render
    add rsp, 32
    mov [rbp + RG_cx], eax
    mov [rbp + RG_cy], edx
    # Inline: the command menu sits between the composer and the footer;
    # fullscreen keeps it above.
    cmp dword ptr [rbp + RG_mh], 0
    jle .Lrg_nomenu
    lea rdi, [rip + t_grid]
    xor esi, esi
    mov edx, [rbp + RG_chat]
    add edx, [rbp + RG_q]
    add edx, [rbp + RG_erows]
    mov ecx, [rip + t_w]
    mov r8d, [rbp + RG_mh]
    call menu_render
.Lrg_nomenu:
    mov eax, [rbp + RG_chat]
    add eax, [rbp + RG_q]
    add eax, [rbp + RG_erows]
    add eax, [rbp + RG_mh]
    inc eax
    mov [rbp + RG_fh], eax
    mov esi, eax
    dec esi
    call tui_status
    # ---- one serialised write --------------------------------------------
    lea rdi, [rip + t_osb]
    call sb_clear
    lea rdi, [rip + t_osb]; lea rsi, [rip + .Lin_hide];   mov edx, 6; call sb_push
    lea rdi, [rip + t_osb]; lea rsi, [rip + .Lin_aw_off]; mov edx, 5; call sb_push
    mov eax, [rip + t_in_rows]
    test eax, eax
    jz .Lrg_noclr
    mov [rbp + RG_s], eax
    lea rdi, [rip + t_osb]; lea rsi, [rip + .Lin_decsc]; mov edx, 2; call sb_push
    xor r12d, r12d
.Lrg_clr:
    cmp r12d, [rbp + RG_s]
    jae .Lrg_clr_done
    lea rdi, [rip + t_osb]; lea rsi, [rip + .Lin_rowclr]; mov edx, 4; call sb_push
    mov eax, r12d
    inc eax
    cmp eax, [rbp + RG_s]
    jae .Lrg_clr_next
    lea rdi, [rip + t_osb]; lea rsi, [rip + .Lin_down1]; mov edx, 4; call sb_push
.Lrg_clr_next:
    inc r12d
    jmp .Lrg_clr
.Lrg_clr_done:
    lea rdi, [rip + t_osb]; lea rsi, [rip + .Lin_decrc]; mov edx, 2; call sb_push
.Lrg_noclr:
    xor r12d, r12d
.Lrg_row:
    cmp r12d, [rbp + RG_fh]
    jae .Lrg_rows_done
    mov edi, r12d
    call inline_row_width
    lea rdx, [rip + t_in_cw]
    mov ecx, r12d
    mov [rdx + rcx*4], eax
    lea rdi, [rip + t_osb]; lea rsi, [rip + .Lin_rowclr]; mov edx, 4; call sb_push
    lea rdi, [rip + t_osb]
    mov esi, r12d
    call inline_emit_row
    mov eax, r12d
    inc eax
    cmp eax, [rbp + RG_fh]
    jae .Lrg_row_next
    lea rdi, [rip + t_osb]; lea rsi, [rip + .Lin_crlf];  mov edx, 2; call sb_push
.Lrg_row_next:
    inc r12d
    jmp .Lrg_row
.Lrg_rows_done:
    mov eax, [rbp + RG_fh]
    cmp eax, 1
    jbe .Lrg_park
    dec eax
    mov [rbp + RG_j], eax
    lea rdi, [rip + t_osb]; lea rsi, [rip + .Lin_csi]; mov edx, 2; call sb_push
    lea rdi, [rip + t_osb]
    mov esi, [rbp + RG_j]
    call sb_push_u64
    lea rdi, [rip + t_osb]; lea rsi, [rip + .Lin_A]; mov edx, 1; call sb_push
.Lrg_park:
    lea rdi, [rip + t_osb]; lea rsi, [rip + .Lin_col1]; mov edx, 4; call sb_push
    lea rdi, [rip + t_osb]; lea rsi, [rip + .Lin_hide]; mov edx, 6; call sb_push
    lea rdi, [rip + t_osb]; lea rsi, [rip + .Lin_aw_on]; mov edx, 5; call sb_push
    mov edi, 1
    lea rax, [rip + t_osb]
    mov rsi, [rax + SB_ptr]
    mov rdx, [rax + SB_len]
    call tui_write_all
    mov eax, [rbp + RG_fh]
    mov [rip + t_in_rows], eax
    EPILOGUE

# inline_region_erase(edi=new_cols): clear the owned region before trusting
# new geometry, using only cursor-relative movement.  The rows the region can
# occupy after the terminal re-wraps every owned row at new_cols is
# sum(ceil(width/new_cols)), at least the old height, capped to the height.
FN inline_region_erase
    PROLOGUE 32
    mov r12d, edi
    test r12d, r12d
    jnz .Lire_c
    mov r12d, 1
.Lire_c:
    mov eax, [rip + t_in_rows]
    mov [rbp - 48], eax
    test eax, eax
    jz .Lire_done
    mov qword ptr [rbp - 56], 0
    xor r13d, r13d
.Lire_sum:
    cmp r13d, [rbp - 48]
    jae .Lire_sum_done
    lea rdx, [rip + t_in_cw]
    mov eax, [rdx + r13*4]
    test eax, eax
    jz .Lire_one
    add eax, r12d
    dec eax
    xor edx, edx
    div r12d
    jmp .Lire_add
.Lire_one:
    mov eax, 1
.Lire_add:
    add [rbp - 56], rax
    inc r13d
    jmp .Lire_sum
.Lire_sum_done:
    mov rax, [rbp - 56]
    cmp rax, [rbp - 48]
    jae .Lire_have
    mov rax, [rbp - 48]
.Lire_have:
    mov ecx, [rip + t_h]
    cmp rax, rcx
    jbe .Lire_clamp
    mov rax, rcx
.Lire_clamp:
    test rax, rax
    jnz .Lire_nz
    mov eax, 1
.Lire_nz:
    mov [rbp - 64], rax
    lea rdi, [rip + t_osb]
    call sb_clear
    lea rdi, [rip + t_osb]; lea rsi, [rip + .Lin_aw_off]; mov edx, 5; call sb_push
    lea rdi, [rip + t_osb]; lea rsi, [rip + .Lin_decsc];  mov edx, 2; call sb_push
    xor r13d, r13d
.Lire_loop:
    cmp r13, [rbp - 64]
    jae .Lire_loop_done
    lea rdi, [rip + t_osb]; lea rsi, [rip + .Lin_rowclr]; mov edx, 4; call sb_push
    lea rax, [r13 + 1]
    cmp rax, [rbp - 64]
    jae .Lire_ln
    lea rdi, [rip + t_osb]; lea rsi, [rip + .Lin_down1]; mov edx, 4; call sb_push
.Lire_ln:
    inc r13
    jmp .Lire_loop
.Lire_loop_done:
    lea rdi, [rip + t_osb]; lea rsi, [rip + .Lin_decrc]; mov edx, 2; call sb_push
    lea rdi, [rip + t_osb]; lea rsi, [rip + .Lin_aw_on]; mov edx, 5; call sb_push
    mov edi, 1
    lea rax, [rip + t_osb]
    mov rsi, [rax + SB_ptr]
    mov rdx, [rax + SB_len]
    call tui_write_all
.Lire_done:
    mov dword ptr [rip + t_in_rows], 0
    EPILOGUE

# tui_fill_state(): copy the agent's footer-relevant values into t_bstate.
tui_fill_state:
    PROLOGUE 16
    # model = provider/id, bounded to ST_model
    lea rdi, [rip + t_osb]
    call sb_clear
    call agent_model_provider
    mov r12, rax
    call agent_model_id
    mov r13, rax
    lea rdi, [rip + t_osb]
    mov rsi, r12
    call sb_push_cstr
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lslash]
    mov edx, 1
    call sb_push
    lea rdi, [rip + t_osb]
    mov rsi, r13
    call sb_push_cstr
    lea rdi, [rip + t_bstate + ST_model]
    mov rsi, [rip + t_osb + SB_ptr]
    mov rcx, [rip + t_osb + SB_len]
    cmp rcx, 191
    jbe 1f
    mov ecx, 191
1:  test rcx, rcx
    jz 2f
    rep movsb
2:  mov byte ptr [rdi], 0
    # thinking name
    call agent_thinking
    mov esi, eax
    call agent_thinking_name
    lea rdi, [rip + t_bstate + ST_thinking]
    mov rsi, rax
    xor ecx, ecx
3:  mov al, [rsi + rcx]
    test al, al
    jz 4f
    cmp ecx, 23
    jae 4f
    mov [rdi + rcx], al
    inc ecx
    jmp 3b
4:  mov byte ptr [rdi + rcx], 0
    # usage totals
    lea rdi, [rip + t_usage]
    call agent_usage_totals
    mov eax, [rip + t_usage + USG_input]
    mov [rip + t_bstate + ST_tok_in], rax
    mov eax, [rip + t_usage + USG_output]
    mov [rip + t_bstate + ST_tok_out], rax
    # no pricing table yet: cost stays unknown and the segment is omitted
    mov qword ptr [rip + t_bstate + ST_cost_micro], -1
    call agent_busy
    mov [rip + t_bstate + ST_running], eax
    test eax, eax
    jz 7f
    mov edi, CLOCK_MONOTONIC
    call os_now_ns
    mov rcx, 1000000
    xor edx, edx
    div rcx
    mov r12, rax
    mov rax, r12
    xor edx, edx
    mov rcx, 100
    div rcx
    and eax, 3
    mov [rip + t_bstate + ST_spinner], eax
    mov rax, r12
    sub rax, [rip + t_run_started_ms]
    test rax, rax
    jns 6f
    xor eax, eax
6:  mov [rip + t_bstate + ST_elapsed_ms], rax
    jmp 70f
7:  mov dword ptr [rip + t_bstate + ST_spinner], 0
    mov qword ptr [rip + t_bstate + ST_elapsed_ms], 0
70: # A headless script has no wall clock; freeze the run segment so the
    # captured golden cannot depend on scheduler timing.
    cmp qword ptr [rip + g_tui_headless], 0
    je 8f
    mov dword ptr [rip + t_bstate + ST_spinner], 0
    mov qword ptr [rip + t_bstate + ST_elapsed_ms], 0
8:  EPILOGUE

# tui_status(esi=row): refresh the built-in state and render the footer band.
tui_status:
    PROLOGUE 16
    mov [rsp], esi
    call tui_fill_state
    lea rdi, [rip + t_bstate]
    call status_builtin_set
    lea rdi, [rip + t_grid]
    mov esi, [rsp]
    mov edx, [rip + t_w]
    call status_render
    EPILOGUE

# tui_now_ms() -> rax: CLOCK_MONOTONIC in whole milliseconds.
tui_now_ms:
    PROLOGUE
    mov edi, CLOCK_MONOTONIC
    call os_now_ns
    mov rcx, 1000000
    xor edx, edx
    div rcx
    EPILOGUE

# tui_stick_bottom(): after new content was appended to an existing view,
# keep the viewport pinned to the bottom when the user has not scrolled up;
# otherwise leave Vtop alone so the reading position stays anchored as the
# transcript grows (the bottom-pinning rule, reduced: `top == last_max`
# means "at the bottom").  Updates t_last_max.
tui_stick_bottom:
    mov eax, [rip + t_view + VV_vh]
    test eax, eax
    jle .Lstick_ret
    mov eax, [rip + t_view + VV_rows]
    sub eax, [rip + t_view + VV_vh]
    jns 1f
    xor eax, eax
1:  mov ecx, [rip + t_view + VV_top]
    cmp ecx, [rip + t_last_max]
    jb 2f
    mov [rip + t_view + VV_top], eax
2:  mov ecx, [rip + t_view + VV_top]
    cmp ecx, eax
    jbe 3f
    mov [rip + t_view + VV_top], eax
    mov ecx, eax
3:  test ecx, ecx
    jns 4f
    mov dword ptr [rip + t_view + VV_top], 0
4:  mov [rip + t_last_max], eax
.Lstick_ret:
    ret

# tui_restore_anchor(): finish a full transcript rebuild (view_clear reset
# Vtop to 0).  If the frame before the rebuild was at the bottom, keep it
# pinned; otherwise restore the saved reading offset, clamped.  No viewport
# yet (Vvh == 0) means nothing to anchor.
tui_restore_anchor:
    mov eax, [rip + t_view + VV_vh]
    test eax, eax
    jle .Lanchor_ret
    mov eax, [rip + t_view + VV_rows]
    sub eax, [rip + t_view + VV_vh]
    jns 1f
    xor eax, eax
1:  cmp dword ptr [rip + t_was_bottom], 0
    je 2f
    mov [rip + t_view + VV_top], eax
    jmp 3f
2:  mov ecx, [rip + t_top_pre]
    cmp ecx, eax
    jbe 4f
    mov ecx, eax
4:  test ecx, ecx
    jns 5f
    xor ecx, ecx
5:  mov [rip + t_view + VV_top], ecx
3:  mov [rip + t_last_max], eax
.Lanchor_ret:
    ret

tui_draw:
    mov eax, [rip + t_ui_mode]
    test eax, eax
    je tui_draw_inline
    cmp eax, 2
    je tui_draw_grid
    jmp tui_draw_region
tui_draw_grid:
    PROLOGUE 32
    lea rdi, [rip + t_grid]
    xor esi, esi
    xor edx, edx
    call grid_clear
    call tui_menu_sync
    # qrows = 1 while the shell queue has pending messages
    xor eax, eax
    cmp dword ptr [rip + t_qn], 0
    je 30f
    mov eax, 1
30: mov [rbp + FS_q], eax
    # composer_rows = min(editor_visual_rows(ed,W), 6), at least 1
    lea rdi, [rip + t_ed]
    mov esi, [rip + t_w]
    call editor_visual_rows
    test eax, eax
    jnz 31f
    mov eax, 1
31: cmp eax, 6
    jbe 32f
    mov eax, 6
32: # clamp to H-2-qrows: footer, queue strip and >=1 transcript row are mandatory
    mov ecx, [rip + t_h]
    sub ecx, 2
    sub ecx, [rbp + FS_q]
    cmp ecx, 1
    jge 33f
    mov ecx, 1
33: cmp eax, ecx
    jbe 34f
    mov eax, ecx
34: mov [rbp + FS_erows], eax
    # menu_h = menu_height(rows left after composer+footer+queue); menu yields first
    mov ecx, [rip + t_h]
    sub ecx, eax
    sub ecx, 2
    sub ecx, [rbp + FS_q]
    jns 35f
    xor ecx, ecx
35: mov esi, ecx
    call menu_height
    mov [rbp + FS_mh], eax
    # chat_h = H - 1 - qrows - composer_rows - menu_h; reserve >=1 transcript row
    mov ecx, [rip + t_h]
    sub ecx, 1
    sub ecx, [rbp + FS_q]
    sub ecx, [rbp + FS_erows]
    sub ecx, eax
    cmp ecx, 1
    jge 36f
    mov ecx, 1
36: mov [rbp + FS_chat], ecx
    mov [rip + t_vp_h], ecx
    # transcript above the menu/composer
    lea rdi, [rip + t_view]
    xor esi, esi
    xor edx, edx
    mov ecx, [rip + t_w]
    mov r8d, [rbp + FS_chat]
    call view_set_vp
    # Rebuild the transcript from cards while a tool runs, or once after a
    # card changes (start/delta/end/toggle), so the live spinner advances.
    # Must happen after view_set_vp: view_scroll_bottom needs Vvh.
    cmp dword ptr [rip + t_cards_dirty], 0
    jne 1f
    lea rdi, [rip + t_chat]
    call chat_has_running
    test eax, eax
    jz 2f
1:  call tui_render_all
    mov dword ptr [rip + t_cards_dirty], 0
2:  lea rdi, [rip + t_view]
    lea rsi, [rip + t_grid]
    xor edx, edx
    xor ecx, ecx
    call view_draw
    # menu between transcript and the queue strip
    cmp dword ptr [rbp + FS_mh], 0
    jle 7f
    lea rdi, [rip + t_grid]
    xor esi, esi
    mov edx, [rbp + FS_chat]
    mov ecx, [rip + t_w]
    mov r8d, [rbp + FS_mh]
    call menu_render
    # queue strip just above the composer
7:  cmp dword ptr [rbp + FS_q], 0
    je 70f
    mov edi, [rbp + FS_chat]
    add edi, [rbp + FS_mh]
    call tui_queue_strip
    # composer below the strip
70: call tui_placeholder
    mov r15, rax
    mov esi, TH_MUTED
    call theme_rgb
    mov r14d, eax
    lea rdi, [rip + t_ed]
    lea rsi, [rip + t_grid]
    xor edx, edx
    mov ecx, [rbp + FS_chat]
    add ecx, [rbp + FS_mh]
    add ecx, [rbp + FS_q]
    mov r8d, [rip + t_w]
    mov r9d, [rbp + FS_erows]
    sub rsp, 32
    mov dword ptr [rsp], 0                # bg = terminal default
    mov [rsp + 8], r14d                   # muted
    mov dword ptr [rsp + 16], 1           # cursor_visible
    mov [rsp + 24], r15                   # placeholder
    call editor_render
    add rsp, 32
    mov [rbp + FS_cx], eax
    mov [rbp + FS_cy], edx
    # status footer on row H-1
    mov esi, [rip + t_h]
    dec esi
    call tui_status
    # cursor + flush
    cmp qword ptr [rip + g_tui_headless], 0
    je 7f
    # headless: no terminal to flush to unless a capture sink is active
    cmp qword ptr [rip + g_tui_capture_fd], 0
    jl 8f
7:  cmp dword ptr [rbp + FS_cx], 0
    jl 9f
    lea rdi, [rip + t_grid]
    mov esi, [rbp + FS_cx]
    mov edx, [rbp + FS_cy]
    mov ecx, 1
    call term_flush
    jmp 8f
9:  lea rdi, [rip + t_grid]
    mov esi, [rbp + FS_cx]
    mov edx, [rbp + FS_cy]
    xor ecx, ecx
    call term_flush
8:  # remember the drawn max scroll for the next sticky-bottom decision
    mov eax, [rip + t_view + VV_rows]
    sub eax, [rip + t_view + VV_vh]
    jns 6f
    xor eax, eax
6:  mov [rip + t_last_max], eax
    EPILOGUE

# ---------------------------------------------------------------- agent hook
tui_hook:
    PROLOGUE
    cmp dword ptr [rip + t_ui_mode], 0
    jne .Lh_grid
    call tui_hook_inline
    EPILOGUE
.Lh_grid:
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    mov dword ptr [rip + t_dirty], 1
    cmp r12d, SE_TEXT
    je .Lh_text
    cmp r12d, SE_TEXT_END
    je .Lh_break
    cmp r12d, SE_TOOL_START
    je .Lh_tool_start
    cmp r12d, SE_TOOL_DELTA
    je .Lh_tool_delta
    cmp r12d, SE_TOOL_END
    je .Lh_break
    cmp r12d, SE_TOOL_RESULT
    je .Lh_tool_result
    cmp r12d, SE_TOOL_EXEC
    je .Lh_tool_exec
    cmp r12d, SE_ERROR
    je .Lh_error
    cmp r12d, SE_DONE
    je .Lh_break
    cmp r12d, SE_THINK
    je .Lh_think
    cmp r12d, SE_THINK_END
    je .Lh_break
    cmp r12d, SE_COMPACT
    je .Lh_compact
    EPILOGUE
.Lh_text:
    # Live markdown.  Accumulate the assistant deltas in t_md_live and redraw
    # only from the block that was last rendered: completed blocks keep their
    # view rows (md_append rolls back just the trailing incomplete block).
    cmp dword ptr [rip + t_md_live_on], 0
    jne 1f
    lea rdi, [rip + t_md_live]
    call md_reset
    lea rdi, [rip + t_md_live]
    mov esi, [rip + t_w]
    call md_set_width
    lea rdi, [rip + t_view]
    call view_total
    mov [rip + t_md_live_base], rax
    mov dword ptr [rip + t_md_live_on], 1
1:  lea rdi, [rip + t_md_live]
    call md_nblocks
    test rax, rax
    jz 2f
    dec rax
2:  mov rbx, rax
    lea rdi, [rip + t_md_live]
    mov rsi, r13
    mov rdx, r14
    call md_append
    lea rdi, [rip + t_md_live]
    mov rsi, rbx
    call md_rows_before
    add rax, [rip + t_md_live_base]
    lea rdi, [rip + t_view]
    mov esi, eax
    call view_truncate
    lea rdi, [rip + t_md_live]
    lea rsi, [rip + t_view]
    mov edx, VS_ASSIST
    mov ecx, ebx
    call md_emit_view_from
    call tui_stick_bottom
    EPILOGUE
.Lh_tool_start:
    call tui_now_ms
    mov rcx, rax
    lea rdi, [rip + t_chat]
    mov rsi, r13                 # SE_TOOL_START a = call id
    mov rdx, r14                 # SE_TOOL_START b = tool name
    call chat_tool_start
    mov dword ptr [rip + t_cards_dirty], 1
    EPILOGUE
.Lh_tool_delta:
    lea rdi, [rip + t_chat]
    mov rsi, r13
    mov rdx, r14
    call chat_tool_delta
    mov dword ptr [rip + t_cards_dirty], 1
    EPILOGUE
.Lh_break:
    mov dword ptr [rip + t_md_live_on], 0
    lea rdi, [rip + t_view]
    call view_break
    call tui_stick_bottom
    EPILOGUE
.Lh_tool_result:
    # the card body comes from SE_TOOL_EXEC; keep the event for old hooks
    mov dword ptr [rip + t_cards_dirty], 1
    EPILOGUE
.Lh_tool_exec:
    lea rdi, [rip + t_chat]
    mov rsi, r13                 # rdx=&TE for SE_TOOL_EXEC
    call chat_tool_exec
    mov dword ptr [rip + t_cards_dirty], 1
    EPILOGUE
.Lh_error:
    lea rdi, [rip + t_view]
    mov esi, VS_ERR
    mov rdx, r13
    mov rcx, r14
    call view_append_span
    lea rdi, [rip + t_view]
    call view_break
    call tui_stick_bottom
    EPILOGUE
.Lh_think:
    call agent_thinking
    test eax, eax
    jz .Lh_think_ret
    lea rdi, [rip + t_view]
    mov esi, VS_DIM
    mov rdx, r13
    mov rcx, r14
    call view_append_span
    call tui_stick_bottom
.Lh_think_ret:
    EPILOGUE
.Lh_compact:
    mov dword ptr [rip + t_compact_seen], 1
    lea rdi, [rip + t_osb]
    call sb_clear
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lcompact_prefix]
    call sb_push_cstr
    lea rdi, [rip + t_osb]
    mov esi, r13d
    call sb_push_u64
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lcompact_suffix]
    call sb_push_cstr
    mov rdi, [rip + t_osb + SB_ptr]
    mov rsi, [rip + t_osb + SB_len]
    call tui_notice
    EPILOGUE

# tui_md_view(ptr, len): render one text block through the markdown block
# model into the fullscreen view (sanitization happens per cell in grid_put).
tui_md_view:
    PROLOGUE 0
    mov r12, rdi
    mov r13, rsi
    lea rdi, [rip + t_md_scratch]
    call md_reset
    lea rdi, [rip + t_md_scratch]
    mov esi, [rip + t_w]
    call md_set_width
    lea rdi, [rip + t_md_scratch]
    mov rsi, r12
    mov rdx, r13
    call md_append
    lea rdi, [rip + t_md_scratch]
    lea rsi, [rip + t_view]
    mov edx, VS_ASSIST
    call md_emit_view
    EPILOGUE

# tui_inline_md(ptr, len): sanitize and emit one assistant text block as
# styled ANSI rows through the markdown block model (S1 stays enforced).
tui_inline_md:
    PROLOGUE 0
    mov r12, rdi
    mov r13, rsi
    mov dword ptr [rip + card_inline_rows], 0
    lea rdi, [rip + t_san]
    call sb_clear
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + t_san]
    call grid_sanitize_bytes
    lea rdi, [rip + t_md_scratch]
    call md_reset
    lea rdi, [rip + t_md_scratch]
    mov esi, 1000000
    call md_set_width
    lea rdi, [rip + t_md_scratch]
    mov rsi, [rip + t_san + SB_ptr]
    mov rdx, [rip + t_san + SB_len]
    call md_append
    lea rdi, [rip + t_osb]
    call sb_clear
    lea rdi, [rip + t_md_scratch]
    lea rsi, [rip + t_osb]
    mov edx, TH_ASSISTANT
    call md_emit_ansi
    lea rax, [rip + t_osb]
    mov rsi, [rax + SB_ptr]
    mov rdx, [rax + SB_len]
    mov edi, 1
    call tui_write_all
    mov edi, 1
    lea rsi, [rip + .Lin_sgr0]
    mov edx, 4
    call tui_write_all
    EPILOGUE

# ---------------------------------------------------------------- transcript
# tui_render_text_blocks(msg, style): append all BT_TEXT blocks with a style
tui_render_text_blocks:
    PROLOGUE 16
    mov r12, rdi
    mov r13d, esi
    mov r14, [r12 + M_blocks]
    test r14, r14
    jz .Lrtb_done
    xor r15d, r15d
1:  cmp r15, [r14 + VEC_len]
    jae .Lrtb_done
    mov rax, [r14 + VEC_ptr]
    mov rcx, r15
    imul rcx, rcx, B_SIZE
    add rax, rcx
    cmp dword ptr [rax + B_type], BT_TEXT
    jne 2f
    mov rdx, [rax + B_ptr]
    mov rcx, [rax + B_len]
    lea rdi, [rip + t_view]
    mov esi, r13d
    call view_append_span
2:  inc r15d
    jmp 1b
.Lrtb_done:
    EPILOGUE

tui_render_msg:
    PROLOGUE 32
    mov r12, rdi
    test rdi, rdi
    jz .Lrm_done
    mov eax, [r12 + M_role]
    cmp eax, MR_USER
    je .Lrm_user
    cmp eax, MR_ASSISTANT
    je .Lrm_assist
    cmp eax, MR_TOOL_RESULT
    je .Lrm_result
    jmp .Lrm_done
.Lrm_user:
    lea rdi, [rip + t_view]
    mov esi, VS_USER
    lea rdx, [rip + .Larrow]
    mov ecx, 2
    call view_append_span
    mov rdi, r12
    mov esi, VS_USER
    call tui_render_text_blocks
    lea rdi, [rip + t_view]
    call view_break
    jmp .Lrm_done
.Lrm_assist:
    mov r13, [r12 + M_blocks]
    test r13, r13
    jz .Lrm_done
    xor r14d, r14d
1:  cmp r14, [r13 + VEC_len]
    jae .Lrm_done
    mov rax, [r13 + VEC_ptr]
    mov rcx, r14
    imul rcx, rcx, B_SIZE
    add rax, rcx
    mov [rsp], rax
    mov esi, [rax + B_type]
    cmp esi, BT_TEXT
    je 2f
    cmp esi, BT_TOOLCALL
    je 3f
    cmp esi, BT_THINK
    je 5f
4:  inc r14d
    jmp 1b
2:  mov rax, [rsp]
    mov rdi, [rax + B_ptr]
    mov rsi, [rax + B_len]
    call tui_md_view
    lea rdi, [rip + t_view]
    call view_break
    jmp 4b
3:  mov rax, [rsp]
    mov r15, [rax + B_ptr]      # TC*
    call tui_now_ms
    mov r8, rax
    lea rdi, [rip + t_view]
    lea rsi, [rip + t_chat]
    mov rdx, [r15 + TC_id]
    mov ecx, [rip + t_w]
    call chat_render_by_id
    test eax, eax
    jnz 4b
    # no card (resumed history): fall back to the plain tool line
    lea rdi, [rip + t_view]
    mov esi, VS_TOOL
    lea rdx, [rip + .Ltool_open]
    mov ecx, 7
    call view_append_span
    mov rdi, [r15 + TC_name]
    call strlen
    mov rcx, rax
    lea rdi, [rip + t_view]
    mov esi, VS_TOOL
    mov rdx, [r15 + TC_name]
    call view_append_span
    mov rdi, [r15 + TC_args]
    call strlen
    mov rcx, rax
    lea rdi, [rip + t_view]
    mov esi, VS_TOOL
    mov rdx, [r15 + TC_args]
    call view_append_span
    lea rdi, [rip + t_view]
    call view_break
    jmp 4b
5:  call agent_thinking
    test eax, eax
    jz 4b
    mov rax, [rsp]
    lea rdi, [rip + t_view]
    mov esi, VS_DIM
    mov rdx, [rax + B_ptr]
    mov rcx, [rax + B_len]
    call view_append_span
    jmp 4b
.Lrm_result:
    lea rdi, [rip + t_chat]
    mov rsi, [r12 + M_call_id]
    call chat_find
    test rax, rax
    jnz .Lrm_done
    mov rdi, r12
    mov esi, VS_TOOL_OUT
    call tui_render_text_blocks
    lea rdi, [rip + t_view]
    call view_break
.Lrm_done:
    EPILOGUE

tui_render_all:
    PROLOGUE
    mov dword ptr [rip + t_md_live_on], 0
    # Remember the reading position across the rebuild: view_clear resets Vtop
    # to 0, so an anchored scroll would otherwise snap to the top.
    mov eax, [rip + t_view + VV_top]
    mov [rip + t_top_pre], eax
    xor ecx, ecx
    cmp eax, [rip + t_last_max]
    setae cl
    mov [rip + t_was_bottom], ecx
    lea rdi, [rip + t_view]
    call view_clear
    mov dword ptr [rip + t_in_offset], 0
    lea rdi, [rip + t_chat]
    call chat_reset_marks
    call agent_transcript
    mov r12, [rax + TR_msgs]     # TR_msgs is a pointer to the VEC
    mov r13d, [rip + t_in_commit]
    cmp r13, [r12 + VEC_len]
    jbe .Ltra_from
    xor r13d, r13d
.Ltra_from:
    # C = the finished prefix end: whole messages with no running card.  Rows
    # before it are the progressive inline commit boundary; [C, len) plus a_msg
    # and any unmatched card is the live tail.
    mov rdi, r12
    mov esi, r13d
    call tui_commit_prefix_len
    mov [rbp - 48], eax
.Ltra_prefix:
    cmp r13d, [rbp - 48]
    jae .Ltra_livebase
    mov rax, [r12 + VEC_ptr]
    mov rdi, [rax + r13*8]
    call tui_render_msg
    inc r13d
    jmp .Ltra_prefix
.Ltra_livebase:
    # rows occupied by the finished prefix [t_in_commit, C): the S7 inline commit
    # boundary.  Everything rendered after this point is the live tail.
    lea rdi, [rip + t_view]
    call view_total
    mov [rip + t_in_live_base], eax
    mov ecx, [rbp - 48]
    mov [rip + t_in_base_len], ecx
.Ltra_live:
    # live transcript messages [C, len) are shown but never committed
    cmp r13d, [r12 + VEC_len]
    jae .Ltra_current
    mov rax, [r12 + VEC_ptr]
    mov rdi, [rax + r13*8]
    call tui_render_msg
    inc r13d
    jmp .Ltra_live
.Ltra_current:
    call agent_current_msg
    test rax, rax
    jz .Ltra_suppress
    # a just-finished message is already the transcript tail; do not render it
    # twice while a_msg has not yet been replaced by the next turn
    mov rcx, [r12 + VEC_len]
    test rcx, rcx
    jz .Ltra_render_current
    dec rcx
    mov rdx, [r12 + VEC_ptr]
    cmp rax, [rdx + rcx*8]
    je .Ltra_suppress
.Ltra_render_current:
    mov rdi, rax
    call tui_render_msg
.Ltra_suppress:
    lea rdi, [rip + t_chat]
    mov rsi, r12
    mov edx, [rip + t_in_commit]
    call tui_suppress_committed_cards
    call tui_now_ms
    mov rcx, rax
    lea rdi, [rip + t_view]
    lea rsi, [rip + t_chat]
    mov edx, [rip + t_w]
    call chat_render_unmatched
    call tui_restore_anchor
    mov dword ptr [rip + t_dirty], 1
    EPILOGUE

# ---------------------------------------------------------------- input handling
tui_on_stdin:
    PROLOGUE
    # One read per poll callback: the fd is blocking (VMIN=1), so looping
    # here would stall the event loop after the first chunk.
    xor edi, edi
    lea rsi, [rip + t_inbuf]
    mov edx, 4096
    call os_read
    test rax, rax
    jg 2f
    js 3f
    mov dword ptr [rip + t_quit], 1
    EPILOGUE
2:  mov rdx, rax
    lea rdi, [rip + t_in]
    lea rsi, [rip + t_inbuf]
    call input_feed
    mov dword ptr [rip + t_dirty], 1
    EPILOGUE
3:  cmp rax, -EAGAIN
    je 4f
    mov dword ptr [rip + t_quit], 1
4:  EPILOGUE

tui_on_winch:
    PROLOGUE
    call term_resized
    test eax, eax
    jz 1f
    mov dword ptr [rip + t_resized], 1
1:  EPILOGUE

# tui_handle_event(): route the single InputEvent already loaded in t_scr.
tui_handle_event:
    PROLOGUE
    mov r12d, [rip + t_scr + 0]     # key
    mov r13d, [rip + t_scr + 4]     # cp
    mov r14d, [rip + t_scr + 8]     # mods
    call menu_is_modal
    test eax, eax
    jnz .Le_modal
    call tui_menu_sync
    call menu_open
    test eax, eax
    jz .Le_no_menu
    mov esi, r12d                # key
    mov edx, r13d                # cp
    mov ecx, r14d                # mods
    call menu_key
    test eax, eax
    jz .Le_no_menu
    # consumed by the menu: Up/Down updated the selection in place.
    cmp r12d, K_TAB
    je .Le_menu_tab
    cmp r12d, K_ENTER
    je .Le_menu_enter
    mov dword ptr [rip + t_dirty], 1
    EPILOGUE
.Le_menu_tab:
    call menu_sel
    mov edi, eax
    call menu_name                # rax ptr, rdx len
    mov r15, rax
    mov rbx, rdx
    lea rdi, [rip + t_mbuf]
    mov byte ptr [rdi], '/'
    inc rdi
    mov rsi, r15
    mov rcx, rbx
    rep movsb
    mov byte ptr [rdi], ' '
    mov byte ptr [rdi + 1], 0
    lea rdi, [rip + t_ed]
    lea rsi, [rip + t_mbuf]
    lea rdx, [rbx + 2]
    call editor_set
    mov dword ptr [rip + t_dirty], 1
    EPILOGUE
.Le_menu_enter:
    test r14d, 1                 # Alt+Enter is not consumed by the menu
    jnz .Le_editor
    call menu_sel
    mov edi, eax
    call menu_name
    mov r15, rax
    mov rbx, rdx
    lea rdi, [rip + t_mbuf]
    mov byte ptr [rdi], '/'
    inc rdi
    mov rsi, r15
    mov rcx, rbx
    rep movsb
    mov byte ptr [rdi], 0
    lea rdi, [rip + t_ed]
    lea rsi, [rip + t_mbuf]
    lea rdx, [rbx + 1]
    call editor_set
    call tui_submit_editor
    EPILOGUE

# ---- modal picker (MODEL/THINKING/SESSION) --------------------------------
# menu_key edits the filter and moves the selection; the shell applies the
# highlighted row on Enter and lets Esc cancel (menu_key already closed it).
.Le_modal:
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    call menu_key
    cmp r12d, K_ENTER
    je .Le_modal_enter
    cmp r12d, K_ESC
    je .Le_modal_esc
    mov dword ptr [rip + t_dirty], 1
    EPILOGUE
.Le_modal_esc:
    call tui_session_pick_free
    mov dword ptr [rip + t_dirty], 1
    EPILOGUE
.Le_modal_enter:
    test r14d, 1                # only a plain Enter selects
    jnz .Le_modal_done
    call menu_count
    test eax, eax
    jz .Le_modal_done         # no match: keep the picker open
    call menu_sel
    mov edi, eax
    call menu_name              # rax = selected cstr
    mov rbx, rax
    call menu_kind
    cmp eax, MK_MODEL
    je .Le_modal_model
    cmp eax, MK_THINKING
    je .Le_modal_think
    cmp eax, MK_SESSION
    je .Le_modal_session
    call menu_close
    jmp .Le_modal_done
.Le_modal_model:
    call menu_close
    mov rdi, rbx
    call tui_cmd_model
    jmp .Le_modal_done
.Le_modal_think:
    call menu_close
    mov rdi, rbx
    call tui_cmd_thinking
    jmp .Le_modal_done
.Le_modal_session:
    mov rdi, rbx
    call tui_session_accept
    call menu_close
.Le_modal_done:
    mov dword ptr [rip + t_dirty], 1
    EPILOGUE
.Le_no_menu:
    cmp r12d, 0x0f               # ctrl-o: toggle the last tool card
    je .Le_ctrlo
    cmp r12d, 0x03               # ctrl-c
    je .Le_ctrlc
    cmp r12d, 0x04               # ctrl-d
    je .Le_ctrld
    cmp r12d, K_ESC
    je .Le_esc
    cmp r12d, K_PGUP
    je .Le_pgup
    cmp r12d, K_PGDN
    je .Le_pgdn
    cmp r12d, K_PASTE
    je .Le_paste
    jmp .Le_editor
.Le_ctrlo:
    lea rdi, [rip + t_chat]
    call chat_toggle_last
    mov dword ptr [rip + t_cards_dirty], 1
    cmp dword ptr [rip + t_ui_mode], 0
    jne 1f
    mov dword ptr [rip + t_card_reemit], 1
1:  mov dword ptr [rip + t_dirty], 1
    EPILOGUE
.Le_ctrlc:
    lea rdi, [rip + t_ed]
    call editor_empty
    test eax, eax
    jz .Le_ctrlc_clear
    mov edi, CLOCK_MONOTONIC
    call os_now_ns
    mov rbx, rax
    mov rcx, [rip + t_ctrlc_ns]
    test rcx, rcx
    jz .Le_ctrlc_arm
    mov rdx, rbx
    sub rdx, rcx
    cmp rdx, 1000000000
    ja .Le_ctrlc_arm
    mov dword ptr [rip + t_quit], 1
    EPILOGUE
.Le_ctrlc_arm:
    mov [rip + t_ctrlc_ns], rbx
    mov dword ptr [rip + t_dirty], 1
    EPILOGUE
.Le_ctrlc_clear:
    lea rdi, [rip + t_ed]
    call editor_clear
    mov edi, CLOCK_MONOTONIC
    call os_now_ns
    mov [rip + t_ctrlc_ns], rax
    mov dword ptr [rip + t_dirty], 1
    EPILOGUE
.Le_ctrld:
    lea rdi, [rip + t_ed]
    call editor_empty
    test eax, eax
    jz .Le_editor
    mov dword ptr [rip + t_quit], 1
    EPILOGUE
.Le_esc:
    call agent_busy
    test eax, eax
    jz .Le_esc_clear
    call agent_abort
    lea rdi, [rip + .Laborted]
    mov esi, 9
    call tui_notice
    call tui_queue_to_editor
    EPILOGUE
.Le_esc_clear:
    lea rdi, [rip + t_ed]
    call editor_clear
    mov dword ptr [rip + t_dirty], 1
    EPILOGUE
.Le_pgup:
    mov esi, [rip + t_vp_h]
    dec esi
    cmp esi, 1
    jge 1f
    mov esi, 1
1:  neg esi
    lea rdi, [rip + t_view]
    call view_scroll
    mov dword ptr [rip + t_dirty], 1
    EPILOGUE
.Le_pgdn:
    mov esi, [rip + t_vp_h]
    dec esi
    cmp esi, 1
    jge 1f
    mov esi, 1
1:  lea rdi, [rip + t_view]
    call view_scroll
    mov dword ptr [rip + t_dirty], 1
    EPILOGUE
.Le_paste:
    lea rdi, [rip + t_ed]
    mov rsi, [rip + t_scr + 16]
    mov rdx, [rip + t_scr + 24]
    call editor_paste
    mov dword ptr [rip + t_dirty], 1
    EPILOGUE
.Le_editor:
    lea rdi, [rip + t_ed]
    mov esi, r12d
    mov edx, r13d
    mov ecx, r14d
    call editor_key
    mov dword ptr [rip + t_dirty], 1
    test eax, eax
    jz 1f
    call tui_submit_editor
1:  EPILOGUE

tui_process_keys:
    PROLOGUE
1:  lea rdi, [rip + t_in]
    lea rsi, [rip + t_scr]
    call input_next
    test eax, eax
    jz 9f
    call tui_handle_event
    jmp 1b
9:  EPILOGUE

# tui_session_reset(): close the active session and open a fresh one in the
# same cwd/session dir, so /new keeps persistence enabled and the new session
# carries a model_change header.  Core owns the swap; the TUI must not touch
# g_agent_session itself.
tui_session_reset:
    PROLOGUE
    mov rdi, [rip + cl_sdir]
    lea rsi, [rip + cl_cwd]
    call agent_reset_session
    EPILOGUE

.set SE_word, -128
.set SE_args, -136
.set SE_len,  -144

# tui_word_end(rdi=cstr) -> rax index of the first space/tab/newline/NUL.
tui_word_end:
    xor eax, eax
1:  mov cl, [rdi + rax]
    test cl, cl
    jz 2f
    cmp cl, ' '
    je 2f
    cmp cl, 9
    je 2f
    cmp cl, 10
    je 2f
    inc rax
    jmp 1b
2:  ret

# ---------------------------------------------------------------- shell queue
# Bounded FIFO of owned strings (grow from 4).  A submit while a
# run is in flight pushes here; the loop drains exactly one per idle tick.

# tui_queue_push(rdi=cstr): append an owned copy.
tui_queue_push:
    PROLOGUE 16
    mov r12, rdi
    mov eax, [rip + t_qn]
    cmp eax, [rip + t_qcap]
    jb .Lqp_store
    mov ecx, [rip + t_qcap]
    test ecx, ecx
    jnz 1f
    mov ecx, 4
    jmp 2f
1:  add ecx, ecx
2:  mov r13d, ecx
    mov rdi, [rip + t_qvec]
    mov rsi, r13
    shl rsi, 3
    call mem_realloc
    mov [rip + t_qvec], rax
    mov [rip + t_qcap], r13d
.Lqp_store:
    mov rdi, r12
    call strlen
    mov rsi, rax
    mov rdi, r12
    call mem_dup
    mov rcx, [rip + t_qvec]
    mov edx, [rip + t_qn]
    mov [rcx + rdx*8], rax
    inc dword ptr [rip + t_qn]
    mov dword ptr [rip + t_dirty], 1
    EPILOGUE

# tui_queue_pop() -> rax owned cstr | 0
tui_queue_pop:
    mov eax, [rip + t_qn]
    test eax, eax
    jz 3f
    mov rcx, [rip + t_qvec]
    mov rax, [rcx]
    mov edx, 1
1:  cmp edx, [rip + t_qn]
    jae 2f
    mov rsi, [rcx + rdx*8]
    mov [rcx + rdx*8 - 8], rsi
    inc edx
    jmp 1b
2:  dec dword ptr [rip + t_qn]
    mov edx, [rip + t_qn]
    mov qword ptr [rcx + rdx*8], 0
    ret
3:  xor eax, eax
    ret

# tui_queue_free(): release every owned string; keep the vector.
tui_queue_free:
    PROLOGUE 16
    xor r12d, r12d
1:  cmp r12d, [rip + t_qn]
    jae 2f
    mov rax, [rip + t_qvec]
    mov rdi, [rax + r12*8]
    call mem_free
    inc r12d
    jmp 1b
2:  mov dword ptr [rip + t_qn], 0
    EPILOGUE

# tui_queue_drain(): when idle, pop exactly one queued message and submit it.
tui_queue_drain:
    PROLOGUE 16
    call agent_busy
    test eax, eax
    jnz .Lqd_ret
    call tui_queue_pop
    test rax, rax
    jz .Lqd_ret
    mov r12, rax
    mov rdi, r12
    call strlen
    mov rsi, rax
    mov rdi, r12
    call tui_submit_text
    mov rdi, r12
    call mem_free
.Lqd_ret:
    EPILOGUE

# tui_submit_or_queue(rdi=ptr, rsi=len): command expansions that become model
# text queue it while a run is in flight instead of replacing the editor.
tui_submit_or_queue:
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    call agent_busy
    test eax, eax
    jz .Lsq_submit
    mov rdi, r12
    call tui_queue_push
    mov dword ptr [rip + t_dirty], 1
    EPILOGUE
.Lsq_submit:
    mov rdi, r12
    mov rsi, r13
    call tui_submit_text
    EPILOGUE

# tui_queue_to_editor(): join queued messages with '\n' into the editor,
# replace its contents and drop the queue; anchor the transcript to the bottom.
tui_queue_to_editor:
    PROLOGUE 16
    cmp dword ptr [rip + t_qn], 0
    je .Lqe_scroll
    lea rdi, [rip + t_osb]
    call sb_clear
    xor r12d, r12d
1:  cmp r12d, [rip + t_qn]
    jae 2f
    test r12d, r12d
    jz 3f
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lnl]
    mov edx, 1
    call sb_push
3:  mov rax, [rip + t_qvec]
    mov rsi, [rax + r12*8]
    lea rdi, [rip + t_osb]
    call sb_push_cstr
    inc r12d
    jmp 1b
2:  lea rdi, [rip + t_ed]
    mov rsi, [rip + t_osb + SB_ptr]
    mov rdx, [rip + t_osb + SB_len]
    call editor_set
    call tui_queue_free
.Lqe_scroll:
    cmp dword ptr [rip + t_ui_mode], 0
    je 4f
    lea rdi, [rip + t_view]
    call view_scroll_bottom
4:  mov dword ptr [rip + t_dirty], 1
    EPILOGUE

# tui_queue_strip(edi=y): one warn row above the composer.  No background band;
# clipped to width-1; the transcript/scrollback is never touched.
tui_queue_strip:
    PROLOGUE 32
    mov r12d, edi                 # y
    mov r13d, [rip + t_w]
    mov esi, TH_WARN
    call theme_rgb
    mov [rsp], eax
    mov edx, [rsp]
    mov edi, r12d
    mov esi, ' '
    xor ecx, ecx                  # no background band
    call tui_row_fill
    lea rdi, [rip + t_osb]
    call sb_clear
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lq_prefix]
    call sb_push_cstr
    lea rdi, [rip + t_osb]
    mov esi, [rip + t_qn]
    call sb_push_u64
    mov rax, [rip + t_qvec]
    test rax, rax
    jz .Lq_empty
    mov r14, [rax]
    test r14, r14
    jz .Lq_empty
    movzx eax, byte ptr [r14]
    test al, al
    jz .Lq_empty
    cmp al, 10
    je .Lq_empty
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lq_open]
    call sb_push_cstr
    mov rdi, r14
    call strlen
    mov r15, rax
    xor ebx, ebx                  # byte offset
    xor r11d, r11d                # codepoints kept
.Lq_scan:
    cmp rbx, r15
    jae .Lq_scan_done
    movzx eax, byte ptr [r14 + rbx]
    test al, al
    jz .Lq_scan_done
    cmp al, 10
    je .Lq_scan_done
    mov ecx, eax
    and ecx, 0xc0
    cmp ecx, 0x80
    je .Lq_scan_byte             # continuation byte: part of the last char
    cmp r11d, 60
    jae .Lq_scan_done
    inc r11d
.Lq_scan_byte:
    inc rbx
    jmp .Lq_scan
.Lq_scan_done:
    lea rdi, [rip + t_osb]
    mov rsi, r14
    mov rdx, rbx
    call sb_push
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lq_close]
    call sb_push_cstr
    jmp .Lq_render
.Lq_empty:
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lq_suffix]
    call sb_push_cstr
.Lq_render:
    lea rdi, [rip + t_grid]
    xor esi, esi
    mov edx, r12d
    mov ecx, [rsp]
    xor r8d, r8d
    xor r9d, r9d
    sub rsp, 16
    mov rax, [rip + t_osb + SB_ptr]
    mov [rsp], rax
    mov rax, [rip + t_osb + SB_len]
    mov [rsp + 8], rax
    call grid_text
    add rsp, 16
    mov ecx, r13d
    dec ecx
    jle .Lq_done
    lea rdi, [rip + t_grid]
    mov esi, ecx
    mov edx, r12d
    mov ecx, ' '
    mov r8d, [rsp]
    xor r9d, r9d
    sub rsp, 16
    mov qword ptr [rsp], 0
    call grid_put
    add rsp, 16
.Lq_done:
    EPILOGUE

# tui_submit_editor(): tokenize the submitted line, dispatch a slash command,
# else submit it as a normal message.
tui_submit_editor:
    PROLOGUE 128
    lea rdi, [rip + t_ed]
    call editor_take             # rax owned cstr; clears the editor
    test rax, rax
    jz .Lse_done
    mov r12, rax
    mov rdi, r12
    call strlen
    mov r13, rax
    mov [rbp + SE_len], r13
    test r13, r13
    jz .Lse_free                 # empty: free and return
    cmp byte ptr [r12], '/'
    jne .Lse_plain
    lea rdi, [r12 + 1]
    call tui_word_end
    mov r13, rax                 # word length
    cmp r13, 63
    ja .Lse_plain                # too long for a command word
    lea rdi, [rbp + SE_word]
    lea rsi, [r12 + 1]
    mov rcx, r13
    test rcx, rcx
    jz 1f
    rep movsb
1:  mov byte ptr [rdi], 0
    lea rsi, [r12 + 1]
    add rsi, r13
2:  mov al, [rsi]
    cmp al, ' '
    je 3f
    cmp al, 9
    jne 4f
3:  inc rsi
    jmp 2b
4:  mov [rbp + SE_args], rsi
    lea rdi, [rbp + SE_word]
    mov rsi, [rbp + SE_args]
    call tui_cmd_builtin
    test eax, eax
    jnz .Lse_free
    lea rdi, [rbp + SE_word]
    mov rsi, [rbp + SE_args]
    call tui_cmd_skill
    test eax, eax
    jnz .Lse_free
    lea rdi, [rbp + SE_word]
    mov rsi, [rbp + SE_args]
    call tui_cmd_prompt
    test eax, eax
    jnz .Lse_free
    lea rdi, [rbp + SE_word]
    mov rsi, [rbp + SE_args]
    call tui_cmd_ext
    test eax, eax
    jnz .Lse_free
.Lse_plain:
    call agent_busy
    test eax, eax
    jz .Lse_submit
    mov rdi, r12                 # busy: queue the text; the editor is clear
    call tui_queue_push
    jmp .Lse_free
.Lse_submit:
    mov rdi, r12
    mov rsi, [rbp + SE_len]
    call tui_submit_text
.Lse_free:
    mov rdi, r12
    call mem_free
.Lse_done:
    mov dword ptr [rip + t_dirty], 1
    EPILOGUE

# tui_submit_text(rdi=ptr, rsi=len): echo, record history and hand a stable
# copy to agent_submit.  Used by the editor and by /skill:|prompt expansion.
tui_submit_text:
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    cmp dword ptr [rip + t_ui_mode], 0
    jne .Lst_grid
    call inline_footer_clear
    mov edi, 1
    lea rsi, [rip + .Larrow]
    mov edx, 2
    call tui_write_all
    mov rdi, r12
    mov rsi, r13
    call inline_write_san
    mov edi, 1
    lea rsi, [rip + .Lnl]
    mov edx, 1
    call tui_write_all
    mov dword ptr [rip + t_stream_line], 0
    mov dword ptr [rip + t_streamed], 1
    jmp .Lst_hist
.Lst_grid:
    lea rdi, [rip + t_view]
    mov esi, VS_USER
    lea rdx, [rip + .Larrow]
    mov ecx, 2
    call view_append_span
    lea rdi, [rip + t_view]
    mov esi, VS_USER
    mov rdx, r12
    mov rcx, r13
    call view_append_span
    lea rdi, [rip + t_view]
    call view_break
    lea rdi, [rip + t_view]
    call view_scroll_bottom
    call tui_stick_bottom
.Lst_hist:
    xor esi, esi
    cmp dword ptr [rip + t_histset], 0
    je 1f
    lea rsi, [rip + t_histpath]
1:  lea rdi, [rip + t_ed]
    mov rdx, r12
    mov rcx, r13
    call editor_history_append
    lea rdi, [rip + t_submit]
    call sb_clear
    lea rdi, [rip + t_submit]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    mov rdi, [rip + t_submit + SB_ptr]
    call agent_submit
    test eax, eax
    jnz 2f
    mov edi, CLOCK_MONOTONIC
    call os_now_ns
    mov rcx, 1000000
    xor edx, edx
    div rcx
    mov [rip + t_run_started_ms], rax
2:  mov dword ptr [rip + t_dirty], 1
    EPILOGUE

# tui_cmd_builtin(rdi=word, rsi=args) -> eax 1 handled | 0.
tui_cmd_builtin:
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    mov rdi, r12
    call strlen
    mov rsi, rax
    lea rdx, [rip + .Lw_clear]
    call str_eq_cstr
    test eax, eax
    jnz .Lcb_clear
    mov rdi, r12
    call strlen
    mov rsi, rax
    lea rdx, [rip + .Lw_help]
    call str_eq_cstr
    test eax, eax
    jnz .Lcb_help
    mov rdi, r12
    call strlen
    mov rsi, rax
    lea rdx, [rip + .Lw_model]
    call str_eq_cstr
    test eax, eax
    jnz .Lcb_model
    mov rdi, r12
    call strlen
    mov rsi, rax
    lea rdx, [rip + .Lw_new]
    call str_eq_cstr
    test eax, eax
    jnz .Lcb_new
    mov rdi, r12
    call strlen
    mov rsi, rax
    lea rdx, [rip + .Lw_quit]
    call str_eq_cstr
    test eax, eax
    jnz .Lcb_quit
    mov rdi, r12
    call strlen
    mov rsi, rax
    lea rdx, [rip + .Lw_thinking]
    call str_eq_cstr
    test eax, eax
    jnz .Lcb_thinking
    mov rdi, r12
    call strlen
    mov rsi, rax
    lea rdx, [rip + .Lw_compact]
    call str_eq_cstr
    test eax, eax
    jnz .Lcb_compact
    mov rdi, r12
    call strlen
    mov rsi, rax
    lea rdx, [rip + .Lw_theme]
    call str_eq_cstr
    test eax, eax
    jnz .Lcb_theme
    mov rdi, r12
    call strlen
    mov rsi, rax
    lea rdx, [rip + .Lw_resume]
    call str_eq_cstr
    test eax, eax
    jnz .Lcb_resume
    mov rdi, r12
    call strlen
    mov rsi, rax
    lea rdx, [rip + .Lw_continue]
    call str_eq_cstr
    test eax, eax
    jnz .Lcb_resume
    xor eax, eax
    EPILOGUE
.Lcb_clear:
    call tui_cmd_clear
    jmp .Lcb_yes
.Lcb_help:
    call tui_cmd_help
    jmp .Lcb_yes
.Lcb_model:
    mov rdi, r13
    call tui_cmd_model
    jmp .Lcb_yes
.Lcb_new:
    call tui_cmd_new
    jmp .Lcb_yes
.Lcb_quit:
    mov dword ptr [rip + t_quit], 1
    jmp .Lcb_yes
.Lcb_thinking:
    mov rdi, r13
    call tui_cmd_thinking
    jmp .Lcb_yes
.Lcb_compact:
    call tui_cmd_compact
.Lcb_yes:
    mov eax, 1
    EPILOGUE
.Lcb_theme:
    mov rdi, r13
    call tui_cmd_theme
    jmp .Lcb_yes
.Lcb_resume:
    call tui_cmd_resume
    jmp .Lcb_yes

# tui_cmd_skill(rdi=word, rsi=args) -> eax 1 handled (even on error) | 0.
tui_cmd_skill:
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    cmp byte ptr [r12], 's'
    jne .Lsk_no
    cmp byte ptr [r12 + 1], 'k'
    jne .Lsk_no
    cmp byte ptr [r12 + 2], 'i'
    jne .Lsk_no
    cmp byte ptr [r12 + 3], 'l'
    jne .Lsk_no
    cmp byte ptr [r12 + 4], 'l'
    jne .Lsk_no
    cmp byte ptr [r12 + 5], ':'
    jne .Lsk_no
    lea r14, [r12 + 6]
    cmp byte ptr [r14], 0
    jne .Lsk_have
    lea rdi, [rip + .Lskill_missing]
    call strlen
    mov rsi, rax
    lea rdi, [rip + .Lskill_missing]
    call tui_notice
    mov eax, 1
    EPILOGUE
.Lsk_have:
    lea rdi, [rip + t_body]
    call sb_clear
    mov rdi, r14
    lea rsi, [rip + t_body]
    call skill_body
    test eax, eax
    jz .Lsk_ok
    cmp eax, -EFBIG
    je .Lsk_big
    lea rdi, [rip + t_osb]
    call sb_clear
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lskill_unknown]
    call sb_push_cstr
    lea rdi, [rip + t_osb]
    mov rsi, r14
    call sb_push_cstr
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lquote_nl]
    call sb_push_cstr
    jmp .Lsk_emit
.Lsk_big:
    lea rdi, [rip + t_osb]
    call sb_clear
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lskill_toobig]
    call sb_push_cstr
    lea rdi, [rip + t_osb]
    mov rsi, r14
    call sb_push_cstr
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lskill_toobig2]
    call sb_push_cstr
.Lsk_emit:
    mov rdi, [rip + t_osb + SB_ptr]
    mov rsi, [rip + t_osb + SB_len]
    call tui_notice
    mov eax, 1
    EPILOGUE
.Lsk_ok:
    lea rdi, [rip + t_osb]
    call sb_clear
    lea rdi, [rip + t_osb]
    mov rsi, [rip + t_body + SB_ptr]
    mov rdx, [rip + t_body + SB_len]
    call sb_push
    cmp byte ptr [r13], 0
    je 1f
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Ldouble_nl]
    mov edx, 2
    call sb_push
    lea rdi, [rip + t_osb]
    mov rsi, r13
    call sb_push_cstr
1:  mov rdi, [rip + t_osb + SB_ptr]
    mov rsi, [rip + t_osb + SB_len]
    call tui_submit_or_queue
    mov eax, 1
    EPILOGUE
.Lsk_no:
    xor eax, eax
    EPILOGUE

# tui_cmd_prompt(rdi=word, rsi=args) -> eax 1 handled | 0.  A built-in always
# shadows a template with the same name (checked by the caller), so only the
# registry name is compared here.
tui_cmd_prompt:
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    call prompt_templates_count
    mov r14d, eax
    xor ebx, ebx
.Lpr_loop:
    cmp ebx, r14d
    jae .Lpr_no
    mov edi, ebx
    call prompt_templates_at
    test rax, rax
    jz .Lpr_next
    mov r15, rax
    mov rdi, r12
    call strlen
    mov rsi, rax
    mov rdx, r15
    call str_eq_cstr
    test eax, eax
    jz .Lpr_next
    lea rdi, [rip + t_osb]
    call sb_clear
    mov rdi, r15
    mov rsi, r13
    lea rdx, [rip + t_osb]
    call prompt_template_expand
    test eax, eax
    js .Lpr_fail
    mov rdi, [rip + t_osb + SB_ptr]
    mov rsi, [rip + t_osb + SB_len]
    call tui_submit_or_queue
    mov eax, 1
    EPILOGUE
.Lpr_fail:
    lea rdi, [rip + t_osb]
    call sb_clear
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lprompt_fail]
    call sb_push_cstr
    lea rdi, [rip + t_osb]
    mov rsi, r12
    call sb_push_cstr
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lquote_nl]
    call sb_push_cstr
    mov rdi, [rip + t_osb + SB_ptr]
    mov rsi, [rip + t_osb + SB_len]
    call tui_notice
    mov eax, 1
    EPILOGUE
.Lpr_next:
    inc ebx
    jmp .Lpr_loop
.Lpr_no:
    xor eax, eax
    EPILOGUE

# tui_cmd_ext(rdi=word, rsi=args) -> eax 1 handled | 0.  Dormant until a
# plugin registers a command through the host table.
tui_cmd_ext:
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    mov eax, [rip + opcode_host_command_count]
    test eax, eax
    jz .Lex_no
    xor ebx, ebx
.Lex_loop:
    cmp ebx, [rip + opcode_host_command_count]
    jae .Lex_no
    lea rax, [rip + opcode_host_commands]
    mov rcx, rbx
    imul rcx, rcx, 24
    add rax, rcx
    mov r15, rax
    mov rdi, r12
    call strlen
    mov rsi, rax
    mov rdx, [r15]
    call str_eq_cstr
    test eax, eax
    jz .Lex_next
    mov rdi, r13
    call qword ptr [r15 + 16]
    test rax, rax
    jz .Lex_handled
    mov r14, rax
    mov rdi, r14
    call strlen
    mov rsi, rax
    mov rdi, r14
    call tui_notice
    mov rdi, r14
    call mem_free
.Lex_handled:
    mov eax, 1
    EPILOGUE
.Lex_next:
    inc ebx
    jmp .Lex_loop
.Lex_no:
    xor eax, eax
    EPILOGUE

# tui_cmd_new(): /new - abort any run, reset the session and clear the view.
tui_cmd_new:
    PROLOGUE
    call agent_busy
    test eax, eax
    jz .Lcn_clear
    call agent_abort
.Lcn_wait:
    mov edi, 1
    call agent_step
    call agent_busy
    test eax, eax
    jnz .Lcn_wait
.Lcn_clear:
    call agent_transcript
    mov rdi, rax
    call tr_clear
    lea rdi, [rip + t_ed]
    call editor_clear
    lea rdi, [rip + t_chat]
    call chat_clear
    call tui_session_reset
    mov dword ptr [rip + t_streamed], 0
    mov dword ptr [rip + t_in_commit], 0
    cmp dword ptr [rip + t_ui_mode], 0
    jne .Lcn_grid
    lea rdi, [rip + .Lnew_msg]
    call inline_note
    jmp .Lcn_done
.Lcn_grid:
    lea rdi, [rip + t_view]
    call view_clear
.Lcn_done:
    mov dword ptr [rip + t_dirty], 1
    EPILOGUE

# tui_cmd_clear(): /clear - drop the transcript view (inline: dim notice).
tui_cmd_clear:
    PROLOGUE
    mov dword ptr [rip + t_streamed], 0
    lea rdi, [rip + t_chat]
    call chat_clear
    cmp dword ptr [rip + t_ui_mode], 0
    jne .Lcc_grid
    lea rdi, [rip + .Lcleared]
    call inline_note
    jmp .Lcc_done
.Lcc_grid:
    lea rdi, [rip + t_view]
    call view_clear
.Lcc_done:
    mov dword ptr [rip + t_dirty], 1
    EPILOGUE

# tui_cmd_help(): /help - append the readline help text.
tui_cmd_help:
    PROLOGUE
    lea rdi, [rip + .Lhelp]
    call strlen
    mov rsi, rax
    lea rdi, [rip + .Lhelp]
    call tui_notice
    EPILOGUE

# tui_streq(rdi, rsi) -> eax 1|0.  Leaf cstr comparison for the pickers.
tui_streq:
    xor eax, eax
1:  mov cl, [rdi]
    cmp cl, [rsi]
    jne 2f
    test cl, cl
    jz 3f
    inc rdi
    inc rsi
    jmp 1b
2:  ret
3:  mov eax, 1
    ret

# tui_pick_putdesc() -> rax: copy the NUL-terminated t_osb into the picker bump
# arena and return the stable pointer.  The arena is reset on every picker open.
tui_pick_putdesc:
    PROLOGUE 0
    mov r12, [rip + t_osb + SB_ptr]
    mov r13, [rip + t_osb + SB_len]
    mov rdi, [rip + t_pickbump]
    test rdi, rdi
    jnz 1f
    lea rdi, [rip + t_picktext]
1:  mov rsi, r12
    mov rdx, r13
    call memcpy
    mov byte ptr [rax + r13], 0
    lea rcx, [rax + r13 + 1]
    mov [rip + t_pickbump], rcx
    EPILOGUE

# tui_pick_putcstr(rdi=cstr) -> rax: copy a NUL-terminated string into the
# picker bump arena (reset on every picker open).
tui_pick_putcstr:
    PROLOGUE 0
    mov r12, rdi
    call strlen
    mov r13, rax
    mov rdi, [rip + t_pickbump]
    test rdi, rdi
    jnz 1f
    lea rdi, [rip + t_picktext]
1:  mov rsi, r12
    mov rdx, r13
    call memcpy
    mov byte ptr [rax + r13], 0
    lea rcx, [rax + r13 + 1]
    mov [rip + t_pickbump], rcx
    EPILOGUE

# tui_session_pick_free(): release the owned session list for the resume
# picker.  Safe to call when no picker ever opened.
tui_session_pick_free:
    PROLOGUE 0
    mov rdi, [rip + t_sessions]
    test rdi, rdi
    jz 1f
    call session_recent_free
    mov qword ptr [rip + t_sessions], 0
1:  EPILOGUE

# tui_age_label(rdi=ts_ms) -> rax: a short age label (agentc's session_age_label)
# built in the bump arena: "now", "<n>m", "<n>h" or "<n>d".
tui_age_label:
    PROLOGUE 32
    mov r12, rdi                 # ts_ms
    mov edi, CLOCK_REALTIME
    call os_now_ns
    mov rcx, 1000000
    xor edx, edx
    div rcx
    mov r13, rax                 # now_ms
    sub r13, r12                 # age_ms
    jns 1f
    xor r13d, r13d
1:  lea rdi, [rip + t_osb]
    call sb_clear
    cmp r13, 60000
    jae .Lal_min
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lage_now]
    call sb_push_cstr
    jmp .Lal_done
.Lal_min:
    cmp r13, 3600000
    jae .Lal_hour
    mov rbx, 60000
    lea r14, [rip + .Lage_m]
    jmp .Lal_num
.Lal_hour:
    cmp r13, 86400000
    jae .Lal_day
    mov rbx, 3600000
    lea r14, [rip + .Lage_h]
    jmp .Lal_num
.Lal_day:
    mov rbx, 86400000
    lea r14, [rip + .Lage_d]
.Lal_num:
    mov rax, r13
    xor edx, edx
    div rbx
    mov rsi, rax
    lea rdi, [rip + t_osb]
    call sb_push_u64
    lea rdi, [rip + t_osb]
    mov rsi, r14
    call sb_push_cstr
.Lal_done:
    call tui_pick_putdesc
    EPILOGUE

# tui_picker_open_session(): `/resume` and `/continue` with no run in flight.
# List the cwd's stored sessions newest first (session_recent already sorts by
# the header stamp), each row an age label plus the first user message preview.
# No sessions (or a read failure) reports the empty notice instead of opening.
FN tui_picker_open_session
    PROLOGUE 64
    call tui_session_pick_free
    lea rax, [rip + t_picktext]
    mov [rip + t_pickbump], rax
    mov rdi, [rip + cl_sdir]
    lea rsi, [rip + cl_cwd]
    call session_recent
    test rax, rax
    jz .Lps_none
    mov [rip + t_sessions], rax
    mov r15, rax                 # VEC*
    mov rdi, rax
    call session_recent_count
    mov r12, rax                 # session count
    test r12, r12
    jz .Lps_none
    cmp r12, 32
    jbe 1f
    mov r12d, 32
1:  xor r13d, r13d               # base (VEC) index
    xor r14d, r14d               # output row count
.Lps_loop:
    cmp r13, r12
    jae .Lps_done
    mov rdi, r15
    mov rsi, r13
    call session_recent_ts
    mov rdi, rax
    call tui_age_label
    lea rcx, [rip + t_pickname]
    mov [rcx + r14*8], rax
    mov rdi, r15
    mov rsi, r13
    call session_recent_desc
    mov [rbp - 48], rax
    mov rdi, rax
    call strlen
    test rax, rax
    jnz 2f
    lea rdi, [rip + .Lempty_session]
    call tui_pick_putcstr
    jmp 3f
2:  mov rdi, [rbp - 48]
    call tui_pick_putcstr
3:  lea rcx, [rip + t_pickdesc]
    mov [rcx + r14*8], rax
    inc r14d
    inc r13d
    jmp .Lps_loop
.Lps_done:
    mov esi, MK_SESSION
    call menu_begin
    lea rdi, [rip + t_pickname]
    lea rsi, [rip + t_pickdesc]
    mov edx, r14d
    xor ecx, ecx
    call menu_rows
    EPILOGUE
.Lps_none:
    call tui_session_pick_free
    lea rdi, [rip + .Lresume_none]
    call strlen
    mov rsi, rax
    lea rdi, [rip + .Lresume_none]
    call tui_notice
    EPILOGUE

# tui_after_resume(): a successful /resume replaced the live transcript.  Drop
# the view/chat/editor like a session swap and replay the new transcript through
# the mode's own path (scrollback streams once, the owned region re-commits).
tui_after_resume:
    PROLOGUE 0
    call tui_session_pick_free
    lea rdi, [rip + t_ed]
    call editor_clear
    lea rdi, [rip + t_chat]
    call chat_clear
    mov dword ptr [rip + t_md_live_on], 0
    mov dword ptr [rip + t_streamed], 0
    mov dword ptr [rip + t_in_commit], 0
    mov dword ptr [rip + t_in_offset], 0
    mov dword ptr [rip + t_in_base_len], 0
    mov dword ptr [rip + t_cards_dirty], 0
    mov dword ptr [rip + t_last_max], 0
    mov dword ptr [rip + t_top_pre], 0
    mov dword ptr [rip + t_was_bottom], 1
    cmp dword ptr [rip + t_ui_mode], 0
    jne .Lar_grid
    call inline_history
    jmp .Lar_done
.Lar_grid:
    call tui_render_all
.Lar_done:
    mov dword ptr [rip + t_dirty], 1
    EPILOGUE

# tui_session_accept(rdi=age label): Enter on the session picker.  Load the
# selected stored session through the frozen agent_load_session and rebuild; a
# refused/corrupt file leaves the current transcript intact and reports it.
tui_session_accept:
    PROLOGUE 32
    mov [rbp - 48], rdi          # age label (bump arena; survives the free)
    call menu_sel_base
    test eax, eax
    js .Lsa_fail
    mov rdi, [rip + t_sessions]
    test rdi, rdi
    jz .Lsa_fail
    mov rsi, rax
    call session_recent_path
    test rax, rax
    jz .Lsa_fail
    mov rdi, rax
    call agent_load_session
    test eax, eax
    jnz .Lsa_fail
    call tui_after_resume
    lea rdi, [rip + t_osb]
    call sb_clear
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lresume_prefix]
    call sb_push_cstr
    lea rdi, [rip + t_osb]
    mov rsi, [rbp - 48]
    call sb_push_cstr
    # copy the notice out of t_osb: tui_notice's scrollback path clears t_osb
    # for the footer erase before reading the message.
    call tui_pick_putdesc
    mov rdi, rax
    mov rsi, [rip + t_osb + SB_len]
    call tui_notice
    EPILOGUE
.Lsa_fail:
    call tui_session_pick_free
    lea rdi, [rip + .Lresume_fail]
    call strlen
    mov rsi, rax
    lea rdi, [rip + .Lresume_fail]
    call tui_notice
    EPILOGUE

# tui_cmd_resume(): /resume and /continue share this handler.  While a run is
# in flight the abort is requested now and the picker opens once it unwinds, so
# a swap can never race an executing tool.
FN tui_cmd_resume
    PROLOGUE 0
    call agent_busy
    test eax, eax
    jz .Lcr_open
    cmp dword ptr [rip + t_switch_pending], 0
    jne .Lcr_done
    mov dword ptr [rip + t_switch_pending], 1
    call agent_abort
    lea rdi, [rip + .Lresume_wait]
    call strlen
    mov rsi, rax
    lea rdi, [rip + .Lresume_wait]
    call tui_notice
.Lcr_done:
    EPILOGUE
.Lcr_open:
    call tui_picker_open_session
    EPILOGUE

# tui_poll_switch(): open the deferred /resume picker once the aborted run ends.
tui_poll_switch:
    cmp dword ptr [rip + t_switch_pending], 0
    je .Lpsw_ret
    PROLOGUE 0
    call agent_busy
    test eax, eax
    jnz .Lpsw_done
    mov dword ptr [rip + t_switch_pending], 0
    call tui_picker_open_session
.Lpsw_done:
    EPILOGUE
.Lpsw_ret:
    ret

# tui_picker_open_model(): `/model` with no argument.  Build the current
# provider's catalog rows (id + "(current) provider ctx= reasoning image") and
# open the MODEL modal picker.  With no catalog, report the current model.
FN tui_picker_open_model
    PROLOGUE 16
    lea rax, [rip + t_picktext]
    mov [rip + t_pickbump], rax
    call agent_model_provider
    mov r15, rax
    call agent_model_id
    mov r14, rax
    call catalog_count
    mov [rbp - 48], rax           # catalog size
    xor r13d, r13d               # output count
    xor r12d, r12d               # catalog index
    mov dword ptr [rbp - 56], -1 # initial selection
.Lpm_loop:
    cmp r12, [rbp - 48]
    jae .Lpm_done
    mov rdi, r12
    call catalog_at
    test rax, rax
    jz .Lpm_next
    mov rbx, rax
    mov rdi, [rbx + MD_provider]
    mov rsi, r15
    call tui_streq
    test eax, eax
    jz .Lpm_next
    lea rax, [rip + t_pickname]
    mov rdx, [rbx + MD_id]
    mov [rax + r13*8], rdx
    lea rdi, [rip + t_osb]
    call sb_clear
    mov rdi, [rbx + MD_id]
    mov rsi, r14
    call tui_streq
    test eax, eax
    jz 1f
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lpick_cur]
    call sb_push_cstr
    mov [rbp - 56], r13d
1:  lea rdi, [rip + t_osb]
    mov rsi, r15
    call sb_push_cstr
    mov eax, [rbx + MD_ctx_window]
    test eax, eax
    jz 2f
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lpick_ctx]
    call sb_push_cstr
    lea rdi, [rip + t_osb]
    mov esi, [rbx + MD_ctx_window]
    call sb_push_u64
2:  mov eax, [rbx + MD_flags]
    test eax, MDF_REASONING
    jz 3f
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lpick_reason]
    call sb_push_cstr
3:  mov eax, [rbx + MD_flags]
    test eax, MDF_IMAGE
    jz 4f
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lpick_image]
    call sb_push_cstr
4:  call tui_pick_putdesc
    lea rcx, [rip + t_pickdesc]
    mov [rcx + r13*8], rax
    inc r13d
.Lpm_next:
    inc r12
    jmp .Lpm_loop
.Lpm_done:
    test r13d, r13d
    jz .Lpm_none
    mov esi, MK_MODEL
    call menu_begin
    lea rdi, [rip + t_pickname]
    lea rsi, [rip + t_pickdesc]
    mov edx, r13d
    mov ecx, [rbp - 56]
    call menu_rows
    EPILOGUE
.Lpm_none:
    call tui_cmd_model_report
    EPILOGUE

# tui_picker_open_thinking(): `/thinking` with no argument.  The four levels
# as a THINKING modal picker; the active level is the initial selection.
FN tui_picker_open_thinking
    PROLOGUE 0
    call agent_thinking
    mov r12d, eax
    mov esi, MK_THINKING
    call menu_begin
    lea rdi, [rip + .Lthink_names]
    lea rsi, [rip + .Lthink_descs]
    mov edx, 4
    mov ecx, r12d
    call menu_rows
    EPILOGUE

# tui_cmd_model_report(): emit "model: <id> (<provider>)" as a dim notice.
tui_cmd_model_report:
    PROLOGUE 0
    lea rdi, [rip + t_osb]
    call sb_clear
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lmodel]
    call sb_push_cstr
    call agent_model_id
    mov r13, rax
    call agent_model_provider
    mov r14, rax
    lea rdi, [rip + t_osb]
    mov rsi, r13
    call sb_push_cstr
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lparen]
    mov edx, 1
    call sb_push
    lea rdi, [rip + t_osb]
    mov rsi, r14
    call sb_push_cstr
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lparen_close]
    mov edx, 1
    call sb_push
    mov rdi, [rip + t_osb + SB_ptr]
    mov rsi, [rip + t_osb + SB_len]
    call tui_notice
    EPILOGUE

# tui_cmd_model(rdi=args): /model - open the picker, or switch when an id is given.
tui_cmd_model:
    PROLOGUE 16
    mov r12, rdi
    call agent_busy
    test eax, eax
    jnz .Lcm_busy
    cmp byte ptr [r12], 0
    jne .Lcm_set
    call tui_picker_open_model
    EPILOGUE
.Lcm_set:
    xor edi, edi
    mov rsi, r12
    call agent_set_model
    test eax, eax
    jnz .Lcm_cannot
    lea rdi, [rip + t_osb]
    call sb_clear
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lmodel]
    call sb_push_cstr
    lea rdi, [rip + t_osb]
    mov rsi, r12
    call sb_push_cstr
    jmp .Lcm_emit
.Lcm_cannot:
    lea rdi, [rip + t_osb]
    call sb_clear
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lcannot]
    call sb_push_cstr
    lea rdi, [rip + t_osb]
    mov rsi, r12
    call sb_push_cstr
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lquote_nl]
    call sb_push_cstr
    jmp .Lcm_emit
.Lcm_busy:
    lea rdi, [rip + t_osb]
    call sb_clear
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lmodel_wait]
    call sb_push_cstr
.Lcm_emit:
    mov rdi, [rip + t_osb + SB_ptr]
    mov rsi, [rip + t_osb + SB_len]
    call tui_notice
    EPILOGUE

# tui_cmd_thinking(rdi=args): /thinking - report or set the reasoning level.
tui_cmd_thinking:
    PROLOGUE 64
    mov r12, rdi
    lea rdi, [rbp - 64]
    xor ecx, ecx
1:  mov al, [r12 + rcx]
    test al, al
    jz 2f
    cmp al, ' '
    je 2f
    cmp al, 9
    je 2f
    cmp al, 10
    je 2f
    cmp ecx, 22
    jae 2f
    mov [rdi + rcx], al
    inc ecx
    jmp 1b
2:  mov byte ptr [rdi + rcx], 0
    cmp byte ptr [rdi], 0
    jne .Lth_set
    call tui_picker_open_thinking
    EPILOGUE
.Lth_set:
    lea rdi, [rbp - 64]
    call agent_thinking_parse
    test eax, eax
    js .Lth_bad
    mov esi, eax
    call agent_set_thinking
    lea rdi, [rip + t_osb]
    call sb_clear
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lthinking]
    call sb_push_cstr
    call agent_thinking
    mov esi, eax
    call agent_thinking_name
    lea rdi, [rip + t_osb]
    mov rsi, rax
    call sb_push_cstr
    jmp .Lth_emit
.Lth_bad:
    lea rdi, [rip + t_osb]
    call sb_clear
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lthinking_bad]
    call sb_push_cstr
    lea rdi, [rip + t_osb]
    lea rsi, [rbp - 64]
    call sb_push_cstr
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lthinking_suf]
    call sb_push_cstr
.Lth_emit:
    mov rdi, [rip + t_osb + SB_ptr]
    mov rsi, [rip + t_osb + SB_len]
    call tui_notice
    EPILOGUE

# tui_cmd_theme(rdi=args): /theme - toggle dark/light, or apply a name.
# A successful apply invalidates the fullscreen frame so every resolved colour
# is repainted; inline leaves its already-committed scrollback untouched.
tui_cmd_theme:
    PROLOGUE 96
    mov r12, rdi
    lea rdi, [rbp - 64]
    xor ecx, ecx
1:  mov al, [r12 + rcx]
    test al, al
    jz 2f
    cmp al, ' '
    je 2f
    cmp al, 9
    je 2f
    cmp al, 10
    je 2f
    cmp ecx, 63
    jae 2f
    mov [rdi + rcx], al
    inc ecx
    jmp 1b
2:  mov byte ptr [rdi + rcx], 0
    cmp byte ptr [rdi], 0
    jne .Lct_named
    lea rax, [rip + t_theme]
    cmp dword ptr [rax + TH_dark], 0
    je .Lct_toggle_light
    lea rsi, [rip + .Ltgl_light]
    jmp .Lct_apply
.Lct_toggle_light:
    lea rsi, [rip + .Ltgl_dark]
    jmp .Lct_apply
.Lct_named:
    lea rsi, [rbp - 64]
.Lct_apply:
    mov r13, rsi
    lea rdi, [rip + t_theme]
    call theme_apply_named
    test eax, eax
    jz .Lct_bad
    call tui_theme_sync
    lea rdi, [rip + t_grid]
    call grid_invalidate
    lea rdi, [rip + t_osb]
    call sb_clear
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Ltheme_pre]
    call sb_push_cstr
    lea rdi, [rip + t_osb]
    mov rsi, r13
    call sb_push_cstr
    jmp .Lct_emit
.Lct_bad:
    lea rdi, [rip + t_osb]
    call sb_clear
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Ltheme_bad]
    call sb_push_cstr
    lea rdi, [rip + t_osb]
    mov rsi, r13
    call sb_push_cstr
    lea rdi, [rip + t_osb]
    lea rsi, [rip + .Lquote_nl]
    call sb_push_cstr
.Lct_emit:
    mov rdi, [rip + t_osb + SB_ptr]
    mov rsi, [rip + t_osb + SB_len]
    call tui_notice
    EPILOGUE

# tui_theme_sync(): push the fixed dark/light background via OSC 11, or reset
# it for system/named themes.  Headless runs never touch the terminal.
tui_theme_sync:
    PROLOGUE 0
    cmp qword ptr [rip + g_tui_headless], 0
    jne .Ltts_done
    lea rax, [rip + t_theme]
    cmp dword ptr [rax + TH_force_bg], 0
    je .Ltts_reset
    mov esi, TH_BG
    call theme_rgb
    mov edi, eax
    call term_set_bg
    EPILOGUE
.Ltts_reset:
    call term_reset_bg
.Ltts_done:
    xor eax, eax
    EPILOGUE

# tui_cmd_compact(): /compact - run a manual compaction and report it.
tui_cmd_compact:
    PROLOGUE 16
    call agent_busy
    test eax, eax
    jnz .Lcp_busy
    mov dword ptr [rip + t_compact_seen], 0
    call agent_compact
    test eax, eax
    jnz .Lcp_busy
    cmp dword ptr [rip + t_compact_seen], 0
    je .Lcp_none
    lea rdi, [rip + .Lcompact_done]
    jmp .Lcp_notice
.Lcp_none:
    lea rdi, [rip + .Lcompact_none]
    jmp .Lcp_notice
.Lcp_busy:
    lea rdi, [rip + .Lcompact_busy]
.Lcp_notice:
    mov r12, rdi
    call strlen
    mov rsi, rax
    mov rdi, r12
    call tui_notice
    EPILOGUE


# ---------------------------------------------------------------- script runner
# tui_type_text(cstr)
tui_type_text:
    PROLOGUE
    mov r12, rdi
    lea rdi, [rip + t_in]
    call input_init
    mov rdi, r12
    call strlen
    mov rdx, rax
    mov rsi, r12
    lea rdi, [rip + t_in]
    call input_feed
    call tui_process_keys
    mov dword ptr [rip + t_dirty], 1
    EPILOGUE

# tui_submit_line(cstr)
tui_submit_line:
    PROLOGUE
    mov r12, rdi
    lea rdi, [rip + t_ed]
    call editor_clear
    mov rdi, r12
    call tui_type_text
    call tui_submit_editor
    EPILOGUE

# tui_print_screen()
tui_print_screen:
    PROLOGUE
    call tui_draw
    lea rdi, [rip + t_dump]
    call sb_clear
    lea rdi, [rip + t_grid]
    lea rsi, [rip + t_dump]
    call render_dump
    mov edi, 1
    mov rsi, [rip + t_dump + SB_ptr]
    mov rdx, [rip + t_dump + SB_len]
    call write_all
    mov edi, 1
    lea rsi, [rip + .Lnl]
    mov edx, 1
    call write_all
    EPILOGUE

# tui_wait_ms(ms)
tui_wait_ms:
    PROLOGUE
    mov r12, rdi
    mov edi, CLOCK_MONOTONIC
    call os_now_ns
    mov r13, rax
    mov rax, r12
    imul rax, rax, 1000000
    add r13, rax
1:  mov edi, 10
    call agent_step
    call tui_poll_switch
    call tui_queue_drain
    call tui_process_keys
    cmp dword ptr [rip + t_dirty], 0
    je 2f
    mov dword ptr [rip + t_dirty], 0
    call tui_draw
2:  cmp dword ptr [rip + t_quit], 0
    jne 3f
    mov edi, CLOCK_MONOTONIC
    call os_now_ns
    cmp rax, r13
    jae 3f
    mov edi, 1000000             # 1 ms: sleep instead of busy-polling
    call os_sleep_ns
    jmp 1b
3:  EPILOGUE

# tui_script_key(cstr): synthesise the named key event and route it through
# the same precedence table as interactive input.
tui_script_key:
    PROLOGUE
    mov r12, rdi
    mov rdi, r12
    call strlen
    mov rsi, rax
    lea rdx, [rip + .Lk_enter]
    call str_eq_cstr
    test eax, eax
    jnz .Lsk_enter
    mov rdi, r12
    call strlen
    mov rsi, rax
    lea rdx, [rip + .Lk_altenter]
    call str_eq_cstr
    test eax, eax
    jnz .Lsk_altenter
    mov rdi, r12
    call strlen
    mov rsi, rax
    lea rdx, [rip + .Lk_up]
    call str_eq_cstr
    test eax, eax
    jnz .Lsk_up
    mov rdi, r12
    call strlen
    mov rsi, rax
    lea rdx, [rip + .Lk_down]
    call str_eq_cstr
    test eax, eax
    jnz .Lsk_down
    mov rdi, r12
    call strlen
    mov rsi, rax
    lea rdx, [rip + .Lk_esc]
    call str_eq_cstr
    test eax, eax
    jnz .Lsk_esc
    mov rdi, r12
    call strlen
    mov rsi, rax
    lea rdx, [rip + .Lk_ctrlc]
    call str_eq_cstr
    test eax, eax
    jnz .Lsk_ctrlc
    mov rdi, r12
    call strlen
    mov rsi, rax
    lea rdx, [rip + .Lk_ctrlo]
    call str_eq_cstr
    test eax, eax
    jnz .Lsk_ctrlo
    mov rdi, r12
    call strlen
    mov rsi, rax
    lea rdx, [rip + .Lk_bksp]
    call str_eq_cstr
    test eax, eax
    jnz .Lsk_bksp
    mov rdi, r12
    call strlen
    mov rsi, rax
    lea rdx, [rip + .Lk_tab]
    call str_eq_cstr
    test eax, eax
    jnz .Lsk_tab
    mov rdi, r12
    call strlen
    mov rsi, rax
    lea rdx, [rip + .Lk_pgup]
    call str_eq_cstr
    test eax, eax
    jnz .Lsk_pgup
    mov rdi, r12
    call strlen
    mov rsi, rax
    lea rdx, [rip + .Lk_pgdn]
    call str_eq_cstr
    test eax, eax
    jnz .Lsk_pgdn
    EPILOGUE
.Lsk_pgup:
    mov dword ptr [rip + t_scr + 0], K_PGUP
    mov dword ptr [rip + t_scr + 4], 0
    mov dword ptr [rip + t_scr + 8], 0
    jmp .Lsk_dispatch
.Lsk_pgdn:
    mov dword ptr [rip + t_scr + 0], K_PGDN
    mov dword ptr [rip + t_scr + 4], 0
    mov dword ptr [rip + t_scr + 8], 0
    jmp .Lsk_dispatch
.Lsk_enter:
    mov dword ptr [rip + t_scr + 0], K_ENTER
    mov dword ptr [rip + t_scr + 4], K_ENTER
    mov dword ptr [rip + t_scr + 8], 0
    jmp .Lsk_dispatch
.Lsk_altenter:
    mov dword ptr [rip + t_scr + 0], K_ENTER
    mov dword ptr [rip + t_scr + 4], K_ENTER
    mov dword ptr [rip + t_scr + 8], 1      # mods alt -> the editor inserts a newline
    jmp .Lsk_dispatch
.Lsk_up:
    mov dword ptr [rip + t_scr + 0], K_UP
    mov dword ptr [rip + t_scr + 4], 0
    mov dword ptr [rip + t_scr + 8], 0
    jmp .Lsk_dispatch
.Lsk_down:
    mov dword ptr [rip + t_scr + 0], K_DOWN
    mov dword ptr [rip + t_scr + 4], 0
    mov dword ptr [rip + t_scr + 8], 0
    jmp .Lsk_dispatch
.Lsk_esc:
    mov dword ptr [rip + t_scr + 0], K_ESC
    mov dword ptr [rip + t_scr + 4], 0
    mov dword ptr [rip + t_scr + 8], 0
    jmp .Lsk_dispatch
.Lsk_ctrlc:
    mov dword ptr [rip + t_scr + 0], 0x03
    mov dword ptr [rip + t_scr + 4], 0x03
    mov dword ptr [rip + t_scr + 8], 4
    jmp .Lsk_dispatch
.Lsk_ctrlo:
    mov dword ptr [rip + t_scr + 0], 0x0f
    mov dword ptr [rip + t_scr + 4], 0x0f
    mov dword ptr [rip + t_scr + 8], 4
    jmp .Lsk_dispatch
.Lsk_bksp:
    mov dword ptr [rip + t_scr + 0], 0x7f
    mov dword ptr [rip + t_scr + 4], 0x7f
    mov dword ptr [rip + t_scr + 8], 0
    jmp .Lsk_dispatch
.Lsk_tab:
    mov dword ptr [rip + t_scr + 0], K_TAB
    mov dword ptr [rip + t_scr + 4], K_TAB
    mov dword ptr [rip + t_scr + 8], 0
.Lsk_dispatch:
    mov qword ptr [rip + t_scr + 16], 0
    mov qword ptr [rip + t_scr + 24], 0
    call tui_handle_event
    mov dword ptr [rip + t_dirty], 1
    EPILOGUE

# tui_script_resize(ptr "W H")
tui_script_resize:
    PROLOGUE
    mov r12, rdi
    mov rdi, r12
    call strlen
    mov rsi, rax
    mov rdi, r12
    call parse_u64
    mov r13, rax
    add rdi, rdx                # skip the first number
1:  movzx eax, byte ptr [rdi]
    cmp al, ' '
    jne 2f
    inc rdi
    jmp 1b
2:  push rdi                # strlen returns the length in rax and may use
    call strlen             # rdi as scratch; keep our string pointer
    mov rsi, rax
    pop rdi
    call parse_u64
    mov r14, rax
    # Clamp both dimensions to the cap tui_parse_size enforces so a script
    # resize cannot request a geometry the grid/cell bookkeeping cannot hold.
    test r13, r13
    jnz 3f
    mov r13d, 1
3:  cmp r13, TUI_MAX_DIM
    jbe 4f
    mov r13d, TUI_MAX_DIM
4:  test r14, r14
    jnz 5f
    mov r14d, 1
5:  cmp r14, TUI_MAX_DIM
    jbe 6f
    mov r14d, TUI_MAX_DIM
6:  mov edi, r13d
    mov esi, r14d
    call term_set_size
    call tui_resize
    EPILOGUE

.section .rodata
.Lk_enter: .asciz "enter"
.Lk_altenter: .asciz "alt-enter"
.Lk_up:    .asciz "up"
.Lk_down:  .asciz "down"
.Lk_esc:   .asciz "esc"
.Lk_ctrlc: .asciz "ctrl-c"
.Lk_ctrlo: .asciz "ctrl-o"
.Lk_bksp:  .asciz "backspace"
.Lk_tab:   .asciz "tab"
.Lk_pgup:  .asciz "pgup"
.Lk_pgdn:  .asciz "pgdn"
.Lv_type:   .asciz "type"
.Lv_key:    .asciz "key"
.Lv_prompt: .asciz "prompt"
.Lv_wait:   .asciz "wait"
.Lv_print:  .asciz "print-screen"
.Lv_resize: .asciz "resize"
.Lv_quit:   .asciz "quit"
.text

# tui_script_verb(verb cstr, args cstr)
tui_script_verb:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov rdi, r12
    call strlen
    mov rsi, rax
    lea rdx, [rip + .Lv_type]
    call str_eq_cstr
    test eax, eax
    jnz .Lsv_type
    mov rdi, r12
    call strlen
    mov rsi, rax
    lea rdx, [rip + .Lv_key]
    call str_eq_cstr
    test eax, eax
    jnz .Lsv_key
    mov rdi, r12
    call strlen
    mov rsi, rax
    lea rdx, [rip + .Lv_prompt]
    call str_eq_cstr
    test eax, eax
    jnz .Lsv_prompt
    mov rdi, r12
    call strlen
    mov rsi, rax
    lea rdx, [rip + .Lv_wait]
    call str_eq_cstr
    test eax, eax
    jnz .Lsv_wait
    mov rdi, r12
    call strlen
    mov rsi, rax
    lea rdx, [rip + .Lv_print]
    call str_eq_cstr
    test eax, eax
    jnz .Lsv_print
    mov rdi, r12
    call strlen
    mov rsi, rax
    lea rdx, [rip + .Lv_resize]
    call str_eq_cstr
    test eax, eax
    jnz .Lsv_resize
    mov rdi, r12
    call strlen
    mov rsi, rax
    lea rdx, [rip + .Lv_quit]
    call str_eq_cstr
    test eax, eax
    jnz .Lsv_quit
    EPILOGUE
.Lsv_type:
    mov rdi, r13
    call tui_type_text
    EPILOGUE
.Lsv_key:
    mov rdi, r13
    call tui_script_key
    EPILOGUE
.Lsv_prompt:
    mov rdi, r13
    call tui_submit_line
    EPILOGUE
.Lsv_wait:
    mov rdi, r13
    call strlen
    mov rsi, rax
    mov rdi, r13
    call parse_u64
    mov rdi, rax
    call tui_wait_ms
    EPILOGUE
.Lsv_print:
    call tui_print_screen
    EPILOGUE
.Lsv_resize:
    mov rdi, r13
    call tui_script_resize
    EPILOGUE
.Lsv_quit:
    mov dword ptr [rip + t_quit], 1
    EPILOGUE

# tui_script_run(path): read the file, NUL-terminate lines in place, dispatch
tui_script_run:
    PROLOGUE 32
    mov r15, rdi
    lea rdi, [rip + t_script]
    call sb_clear
    mov rdi, r15
    lea rsi, [rip + t_script]
    call read_file
    test rax, rax
    js .Lsr_fail
    mov rax, [rip + t_script + SB_ptr]
    mov [rsp], rax              # ptr
    mov rax, [rip + t_script + SB_len]
    mov [rsp + 8], rax          # len
    mov qword ptr [rsp + 16], 0 # offset
.Lsr_line:
    mov r14, [rsp + 16]
    cmp r14, [rsp + 8]
    jae .Lsr_ok
    mov r12, [rsp]
    # find the newline and NUL it
    mov r13, r14
1:  cmp r13, [rsp + 8]
    jae 2f
    cmp byte ptr [r12 + r13], 10
    je 2f
    inc r13
    jmp 1b
2:  cmp r13, [rsp + 8]
    jae 3f
    mov byte ptr [r12 + r13], 0
3:  # trim CR
    cmp r13, r14
    jbe 4f
    cmp byte ptr [r12 + r13 - 1], 13
    jne 4f
    mov byte ptr [r12 + r13 - 1], 0
4:  # line pointer, skip spaces
    lea rbx, [r12 + r14]
5:  movzx eax, byte ptr [rbx]
    cmp al, ' '
    jne 6f
    inc rbx
    jmp 5b
6:  test al, al
    jz 8f
    cmp al, '#'
    je 8f
    # split verb/args at the first space
    mov r15, rbx
7:  movzx eax, byte ptr [r15]
    test al, al
    jz 9f
    cmp al, ' '
    je 10f
    inc r15
    jmp 7b
10: mov byte ptr [r15], 0
    inc r15
11: movzx eax, byte ptr [r15]
    cmp al, ' '
    jne 9f
    inc r15
    jmp 11b
9:  mov rdi, rbx
    mov rsi, r15
    call tui_script_verb
8:  lea r14, [r13 + 1]
    mov [rsp + 16], r14
    jmp .Lsr_line
.Lsr_ok:
    xor eax, eax
    EPILOGUE
.Lsr_fail:                      # rax = negative errno from read_file
    EPILOGUE

# ---------------------------------------------------------------- loop / entry
tui_resize:
    PROLOGUE
    mov r12d, [rip + t_w]       # previous geometry, restored if a resize fails
    mov r13d, [rip + t_h]
    call term_size
    # Clamp to the grid cap so a >4096-row terminal can never make tui_draw_region
    # index past t_in_cw (4096 u32) nor ask grid_resize for an unsupported size.
    cmp rax, 1
    jae .Ltrz_w1
    mov eax, 1
.Ltrz_w1:
    cmp rax, TUI_MAX_DIM
    jbe .Ltrz_w2
    mov eax, TUI_MAX_DIM
.Ltrz_w2:
    cmp rdx, 1
    jae .Ltrz_h1
    mov edx, 1
.Ltrz_h1:
    cmp rdx, TUI_MAX_DIM
    jbe .Ltrz_h2
    mov edx, TUI_MAX_DIM
.Ltrz_h2:
    mov [rip + t_w], eax
    mov [rip + t_h], edx
    mov ecx, [rip + t_ui_mode]
    test ecx, ecx
    je .Ltrz_inline
    cmp ecx, 2
    je .Ltrz_grid
    # Inline owned region: clear it with cursor-relative moves only (never a
    # row recomputed from the old width), then re-anchor at the new geometry.
    mov edi, [rip + t_w]
    call inline_region_erase
    lea rdi, [rip + t_grid]
    mov esi, [rip + t_w]
    mov edx, [rip + t_h]
    call grid_resize
    test eax, eax
    js .Ltrz_reject
    lea rdi, [rip + t_view]
    call view_free
    lea rdi, [rip + t_view]
    mov esi, [rip + t_w]
    call view_init
    mov dword ptr [rip + t_last_max], 0
    mov dword ptr [rip + t_top_pre], 0
    mov dword ptr [rip + t_was_bottom], 1
    call tui_render_all
    mov dword ptr [rip + t_resized], 0
    mov dword ptr [rip + t_dirty], 1
    EPILOGUE
.Ltrz_grid:
    lea rdi, [rip + t_grid]
    mov esi, [rip + t_w]
    mov edx, [rip + t_h]
    call grid_resize
    test eax, eax
    js .Ltrz_reject
    lea rdi, [rip + t_view]
    call view_free
    lea rdi, [rip + t_view]
    mov esi, [rip + t_w]
    call view_init
    # A resize rebuilds the view from scratch; snap to the bottom rather than
    # trying to restore a now-meaningless row offset.
    mov dword ptr [rip + t_last_max], 0
    mov dword ptr [rip + t_top_pre], 0
    mov dword ptr [rip + t_was_bottom], 1
    call tui_render_all
    mov dword ptr [rip + t_resized], 0
    mov dword ptr [rip + t_dirty], 1
    EPILOGUE
.Ltrz_inline:
    call inline_footer_clear
    lea rdi, [rip + t_grid]
    mov esi, [rip + t_w]
    mov edx, [rip + t_h]
    call grid_resize
    test eax, eax
    js .Ltrz_reject
    mov dword ptr [rip + t_resized], 0
    mov dword ptr [rip + t_dirty], 1
    EPILOGUE
.Ltrz_reject:
    # grid_resize/grid_init refused the geometry: keep the previous one so the
    # draw paths never index t_in_cw out of range.
    mov [rip + t_w], r12d
    mov [rip + t_h], r13d
    mov dword ptr [rip + t_resized], 0
    mov dword ptr [rip + t_dirty], 1
    EPILOGUE

tui_loop_interactive:
    PROLOGUE
    xor edi, edi
    mov esi, POLLIN
    lea rdx, [rip + tui_on_stdin]
    xor ecx, ecx
    call watch_add
    call os_winch_fd
    test eax, eax
    js 1f
    mov edi, eax
    mov esi, POLLIN
    lea rdx, [rip + tui_on_winch]
    xor ecx, ecx
    call watch_add
1:  mov dword ptr [rip + t_dirty], 1
.Lli_loop:
    cmp dword ptr [rip + t_quit], 0
    jne .Lli_done
    # Detect a resize through the SIGWINCH pipe AND by polling the size, so a
    # lost signal byte cannot leave stale geometry.
    call term_poll_resize
    test eax, eax
    jz .Lli_resz
    mov dword ptr [rip + t_resized], 1
.Lli_resz:
    cmp dword ptr [rip + t_resized], 0
    je 2f
    call tui_resize
2:  mov edi, 50
    call agent_step
    call tui_poll_switch
    call tui_queue_drain
    # 50 ms lone-ESC / partial-escape timeout.  Any byte consumed during the
    # poll above disarms the timer, so a real escape sequence arriving in a
    # later read is not split into K_ESC + a literal.
    mov edi, CLOCK_MONOTONIC
    call os_now_ns
    mov rcx, 1000000
    xor edx, edx
    div rcx
    lea rdi, [rip + t_in]
    mov rsi, rax
    call input_idle
    call tui_process_keys
    cmp dword ptr [rip + t_quit], 0
    jne .Lli_done
    cmp dword ptr [rip + t_dirty], 0
    jne .Lli_draw
    # No event: while a run is in flight keep the footer spinner/elapsed moving
    # at ~100 ms even when no stream data arrives (network wait).
    call agent_busy
    test eax, eax
    jz .Lli_loop
    mov edi, CLOCK_MONOTONIC
    call os_now_ns
    mov rcx, 1000000
    xor edx, edx
    div rcx
    mov rcx, rax
    sub rcx, [rip + t_frame_ms]
    cmp rcx, 100
    jb .Lli_loop
.Lli_draw:
    mov dword ptr [rip + t_dirty], 0
    mov edi, CLOCK_MONOTONIC
    call os_now_ns
    mov rcx, 1000000
    xor edx, edx
    div rcx
    mov [rip + t_frame_ms], rax
    call tui_draw
    jmp .Lli_loop
.Lli_done:
    EPILOGUE

# tui_parse_size(cstr "WxH"): set t_w/t_h
tui_parse_size:
    PROLOGUE
    mov r12, rdi
    mov rdi, r12
    call strlen
    mov rsi, rax
    mov rdi, r12
    call parse_u64
    test rdx, rdx
    jz .Lps_bad
    cmp byte ptr [r12 + rdx], 'x'
    jne .Lps_bad
    mov r13, rax
    mov r14, rdx
    lea rdi, [r12 + rdx + 1]
    mov rsi, 16
    call parse_u64
    test rdx, rdx
    jz .Lps_bad
    lea rcx, [r12 + r14 + 1]
    cmp byte ptr [rcx + rdx], 0
    jne .Lps_bad
    test r13, r13
    jz .Lps_bad
    test eax, eax
    jz .Lps_bad
    cmp r13, TUI_MAX_DIM
    ja .Lps_bad
    cmp rax, TUI_MAX_DIM
    ja .Lps_bad
    mov [rip + t_w], r13d
    mov [rip + t_h], eax
    xor eax, eax
    EPILOGUE
.Lps_bad:
    mov dword ptr [rip + t_w], 0
    mov dword ptr [rip + t_h], 0
    mov rax, -EINVAL
    EPILOGUE

# tui_run(argc, argv) -> exit code
FN tui_run
    PROLOGUE
    mov r15, rdi
    mov r14, rsi
    mov edx, CK_TUI
    call cli_parse
    test eax, eax
    jnz .Ltr_parse_err
    call config_load
    call cli_expand_prompt
    test eax, eax
    jnz .Ltr_fail
    # headless frame-capture sink: open before any writer runs so the banner
    # and every inline/fullscreen frame go to one deterministic byte stream.
    cmp qword ptr [rip + g_tui_capture], 0
    je .Ltr_no_capture
    mov rdi, [rip + g_tui_capture]
    mov esi, O_WRONLY | O_CREAT | O_TRUNC
    mov edx, 0x1A4
    call os_open
    test rax, rax
    js .Ltr_fail
    mov [rip + g_tui_capture_fd], rax
.Ltr_no_capture:
    # first-run onboarding: only for a plain `opcode` (no flags), and only when
    # no provider is resolvable anywhere -> explain or menu
    test r15, r15
    jnz .Ltr_no_onboard
    call onboard_maybe
    test eax, eax
    jnz .Ltr_onboard_exit
.Ltr_no_onboard:
    mov eax, [rip + cl_tui_mode]
    mov dword ptr [rip + t_ui_mode], eax
    cmp qword ptr [rip + g_tui_headless], 0
    je 1f
    # a capture sink keeps the requested mode (inline golden); a plain headless
    # run forces the fullscreen grid dump as before.
    cmp qword ptr [rip + g_tui_capture], 0
    jne 2f
    mov dword ptr [rip + t_ui_mode], 2
2:  mov rdi, [rip + cl_headless]
    test rdi, rdi
    jz 1f
    call tui_parse_size
    test eax, eax
    js .Ltr_usage
1:  call cli_open_session
    test eax, eax
    jnz .Ltr_fail
    # ---- theme: CLI --theme > config "theme" > system ----
    lea rdi, [rip + t_theme]
    mov esi, 1
    call theme_init
    lea rdi, [rip + t_theme]
    call theme_set_current
    lea rdi, [rip + cl_cwd]
    mov esi, 512
    call os_getcwd
    lea rdi, [rip + cl_cwd]
    call config_trusted
    mov esi, eax
    lea rdi, [rip + cl_cwd]
    call theme_set_project_root
    mov rdi, [rip + cl_theme]
    test rdi, rdi
    jnz .Ltr_theme_apply
    call config_default_theme
    mov [rip + t_theme_cfg], rax
    test rax, rax
    jnz 1f
    lea rax, [rip + .Lsystem]
1:  mov rdi, rax
.Ltr_theme_apply:
    mov rsi, rdi
    lea rdi, [rip + t_theme]
    call theme_apply_named
    # config_default_theme's owned cstr is no longer needed after the apply.
    mov rdi, [rip + t_theme_cfg]
    call mem_free
    mov qword ptr [rip + t_theme_cfg], 0

.Ltr_start:
    lea rax, [rip + tui_hook]
    mov [rip + g_agent_ui_fn], rax
    mov qword ptr [rip + g_agent_ui_ctx], 0
    call agent_init
    test eax, eax
    jnz .Ltr_agent_fail
    xor eax, eax
    cmp dword ptr [rip + t_ui_mode], 2
    setne al
    mov [rip + g_tui_inline], rax
    call tui_banner
    call term_init
    test rax, rax
    js .Ltr_init_fail
    call tui_theme_sync
    cmp qword ptr [rip + g_tui_headless], 0
    jne .Ltr_hook_skip
    call os_sig_cleanup
    test rax, rax
    js .Ltr_init_fail
.Ltr_hook_skip:
    mov eax, [rip + g_tui_headless]
    test eax, eax
    jnz 4f
    call term_size
    mov [rip + t_w], eax
    mov [rip + t_h], edx
    jmp 5f
4:  mov eax, [rip + t_w]
    test eax, eax
    jnz 5f
    mov dword ptr [rip + t_w], 80
    mov dword ptr [rip + t_h], 24
5:  lea rdi, [rip + t_grid]
    mov esi, [rip + t_w]
    mov edx, [rip + t_h]
    call grid_init
    test eax, eax
    js .Ltr_init_fail
    cmp dword ptr [rip + t_ui_mode], 0
    je .Ltr_inline_grid
    lea rdi, [rip + t_view]
    mov esi, [rip + t_w]
    call view_init
    test eax, eax
    js .Ltr_init_fail
.Ltr_inline_grid:
    lea rdi, [rip + t_ed]
    call editor_init
    # ASCII rules: TERM=dumb or OPCODE_ASCII present
    xor r15d, r15d
    lea rdi, [rip + .Ltermenv]
    call tui_env
    test rax, rax
    jz 1f
    mov rdi, rax
    call strlen
    mov rsi, rax
    lea rdx, [rip + .Ldumb]
    call str_eq_cstr
    test eax, eax
    jz 1f
    mov r15d, 1
1:  lea rdi, [rip + .Lopcode_ascii]
    call tui_env
    test rax, rax
    jz 2f
    mov r15d, 1
2:  lea rdi, [rip + t_ed]
    mov esi, r15d
    call editor_set_ascii
    call menu_init
    call status_register_builtin
    call tui_history_setup
    # load the history once (path 0 = memory only)
    xor esi, esi
    cmp dword ptr [rip + t_histset], 0
    je 3f
    lea rsi, [rip + t_histpath]
3:  lea rdi, [rip + t_ed]
    call editor_history_load
    # initial CLI prompt text
    cmp qword ptr [rip + cl_prompt + SB_len], 0
    je 4f
    lea rdi, [rip + t_ed]
    mov rsi, [rip + cl_prompt + SB_ptr]
    mov rdx, [rip + cl_prompt + SB_len]
    call editor_set
4:  lea rdi, [rip + t_in]
    call input_init
    # Scrollback and the owned inline region both replay an existing session
    # into real scrollback once; inline then marks those messages committed so
    # they are never re-shown or re-printed in the region.
    mov ecx, [rip + t_ui_mode]
    cmp ecx, 2
    je .Ltr_render_all
    call inline_history
    cmp dword ptr [rip + t_ui_mode], 0
    je .Ltr_after_render
    call agent_transcript
    mov rcx, [rax + TR_msgs]
    mov eax, [rcx + VEC_len]
    mov [rip + t_in_commit], eax
    jmp .Ltr_render_all
.Ltr_render_all:
    call tui_render_all
.Ltr_after_render:
    cmp qword ptr [rip + g_tui_script], 0
    je 6f
    mov rdi, [rip + g_tui_script]
    call tui_script_run
    test rax, rax
    js .Ltr_script_fail
    jmp 7f
6:  call tui_loop_interactive
7:  cmp dword ptr [rip + t_ui_mode], 2
    je 70f
    cmp dword ptr [rip + t_ui_mode], 0
    jne 75f
    call inline_footer_clear
    jmp 70f
75: mov edi, [rip + t_w]
    call inline_region_erase
70: call term_restore
71: mov eax, [rip + t_exit]
    test eax, eax
    jnz 8f
    call agent_exit_code
8:  EPILOGUE
.Ltr_script_fail:
    mov edi, 2
    lea rsi, [rip + .Lerr_script]
    call out_cstr
    mov edi, 2
    mov rsi, [rip + g_tui_script]
    call out_cstr
    mov edi, 2
    lea rsi, [rip + .Lnl]
    call out_cstr
    call term_restore
    mov eax, 1
    EPILOGUE
.Ltr_init_fail:
    call term_restore
    call mcp_shutdown
    mov edi, 2
    lea rsi, [rip + .Lerr_init]
    call out_cstr
    mov eax, 1
    EPILOGUE
.Ltr_agent_fail:
    call term_restore
    call mcp_shutdown
    mov edi, 2
    lea rsi, [rip + .Lhint_auth]
    call out_cstr
    mov eax, 1
    EPILOGUE
.Ltr_parse_err:
    mov eax, 2
    EPILOGUE
.Ltr_fail:
    mov eax, 1
    EPILOGUE
.Ltr_onboard_exit:
    EPILOGUE
.Ltr_usage:
    call cli_usage
    mov eax, 2
    EPILOGUE
