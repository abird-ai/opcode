# card: tool-card state machine and renderer.  See src/tui/API.md.
#
# A card is created on SE_TOOL_START, accumulates its argument preview from
# SE_TOOL_DELTA, and finishes on SE_TOOL_EXEC.  A finished card is rendered
# from the transcript by call id; a running card that has no tool-call block
# yet is rendered by chat_render_unmatched().  Rendering is deterministic: the
# app recomputes the whole viewport (tui_render_all) while a card is running.
.include "opcode.inc"
.include "core/core.inc"
.include "tui/card.inc"
.include "tui/theme.inc"

.equ CARD_ARGS_PREVIEW, 48
.equ CARD_COLLAPSED, 3
.equ CARD_EXPANDED, 10

.section .rodata
card_q:       .asciz "?"
card_p_edit:  .asciz "edit"
card_sp:      .ascii " "
card_nl:      .ascii "\n"
card_lb:      .ascii "["
card_rb:      .ascii "] "
card_ok:      .asciz "ok "
card_err:     .asciz "err "
card_ms:      .asciz "ms"
card_dots:    .asciz "... (+"
card_lines:   .asciz " lines)"
card_spin:    .ascii "|/-\\"
card_cr:      .ascii "\r"
card_el:      .ascii "\033[2K"
card_semi:    .ascii ";"
card_m:       .ascii "m"
card_reset:   .ascii "\033[0m"
card_bgp:     .ascii "\033[48;2;"
card_fgp:     .ascii "\033[38;2;"

.section .bss
.p2align 3
card_sb:  .zero SB_SIZE          # current line text
card_sty: .zero SB_SIZE          # parallel per-byte style
card_st:  .zero SB_SIZE          # status / marker scratch
card_osb: .zero SB_SIZE          # inline ANSI output
card_ch:  .zero 1                # one-byte scratch
card_col: .zero 4                # display column of the line being built
# card_inline_rows: terminal rows the last inline card emission occupies
# (card_line_flush_inline rows plus the trailing gap row).  The app zeroes it
# before/after any non-card inline output so Ctrl+O can erase the exact region.
.globl card_inline_rows
card_inline_rows: .zero 4
# card_last_index: chat index of the card chat_emit_last_inline printed last, so
# a scrollback Ctrl+O only erases/reprints when no newer card has appeared.
.globl card_last_index
card_last_index: .zero 4

.text

# --------------------------------------------------------------- line builder
# card_line_reset()
FN card_line_reset
    lea rdi, [rip + card_sb]
    call sb_clear
    lea rdi, [rip + card_sty]
    call sb_clear
    mov dword ptr [rip + card_col], 0
    xor eax, eax
    ret

# card_sanitize_cp(cp edi) -> eax: alias of render.s:grid_sanitize (single
# implementation); card header/args are untrusted, so C0/DEL/C1 -> U+FFFD.
card_sanitize_cp:
    jmp grid_sanitize

# card_line_push_cp(cp edi, style esi): append one codepoint as UTF-8 with one
# style byte per output byte and advance card_col by its display width.
card_line_push_cp:
    PROLOGUE 16
    mov r12d, edi
    mov r13d, esi
    mov r14, [rip + card_sb + SB_len]
    lea rdi, [rip + card_sb]
    mov esi, r12d
    call sb_push_utf8
    mov r15, [rip + card_sb + SB_len]
    sub r15, r14               # bytes appended
1:  test r15, r15
    jz 2f
    lea rdi, [rip + card_sty]
    mov esi, r13d
    call sb_push_byte
    dec r15
    jmp 1b
2:  mov edi, r12d
    call view_wcwidth
    add [rip + card_col], eax
    EPILOGUE

# card_line_add(ptr, len, style): append text to the current card line.  Untrusted
# bytes are decoded strictly: C0/DEL/C1 controls become U+FFFD, CR/LF become a
# space and a tab expands to the next 4-column stop.  This is the single choke
# point for tool names, argument previews and body text, so the inline writer
# can never emit a raw escape introduced by model/tool output.
FN card_line_add
    PROLOGUE 32
    mov r12, rdi
    mov r13, rsi
    mov r14d, edx
    test r12, r12
    jz .Lcla_done
.Lcla_loop:
    test r13, r13
    jz .Lcla_done
    mov rdi, r12
    mov rsi, r13
    call utf8dec
    mov r15, rdx               # bytes consumed
    add r12, r15
    sub r13, r15
    cmp eax, 9
    je .Lcla_tab
    cmp eax, 10
    je .Lcla_space
    cmp eax, 13
    je .Lcla_space
    mov edi, eax
    call card_sanitize_cp
    mov edi, eax
    mov esi, r14d
    call card_line_push_cp
    jmp .Lcla_loop
.Lcla_tab:
    mov ecx, [rip + card_col]
    and ecx, 3
    mov eax, 4
    sub eax, ecx
    mov [rsp], eax
.Lcla_tab_loop:
    cmp dword ptr [rsp], 0
    jle .Lcla_loop
    mov edi, ' '
    mov esi, r14d
    call card_line_push_cp
    dec dword ptr [rsp]
    jmp .Lcla_tab_loop
.Lcla_space:
    mov edi, ' '
    mov esi, r14d
    call card_line_push_cp
    jmp .Lcla_loop
.Lcla_done:
    EPILOGUE

# card_line_pad(n, style): append n spaces
FN card_line_pad
    PROLOGUE 16
    mov r12d, edi
    mov r13d, esi
1:  test r12d, r12d
    jz 2f
    lea rdi, [rip + card_sp]
    mov esi, 1
    mov edx, r13d
    call card_line_add
    dec r12d
    jmp 1b
2:  EPILOGUE

# card_clip_line(maxw): truncate the built line to maxw display columns
FN card_clip_line
    PROLOGUE 32
    mov r12d, edi
    mov r13, [rip + card_sb + SB_ptr]
    mov r14, [rip + card_sb + SB_len]
    xor ebx, ebx
    xor r15d, r15d
1:  cmp rbx, r14
    jae 2f
    lea rdi, [r13 + rbx]
    mov rsi, r14
    sub rsi, rbx
    call utf8dec
    mov [rsp], rdx
    mov edi, eax
    call view_wcwidth
    add r15d, eax
    cmp r15d, r12d
    ja 2f
    add rbx, [rsp]
    jmp 1b
2:  mov [rip + card_sb + SB_len], rbx
    mov [rip + card_sty + SB_len], rbx
    mov rax, [rip + card_sb + SB_ptr]
    mov byte ptr [rax + rbx], 0
    mov rax, [rip + card_sty + SB_ptr]
    mov byte ptr [rax + rbx], 0
    EPILOGUE

# card_line_flush_view(view, bg): commit the built line to the view + newline
FN card_line_flush_view
    PROLOGUE 32
    mov r12, rdi
    mov r13d, esi
    mov rdi, r12
    mov esi, r13d
    call view_set_bg
    mov r14, [rip + card_sb + SB_ptr]
    mov r15, [rip + card_sty + SB_ptr]
    mov rbx, [rip + card_sb + SB_len]
    mov qword ptr [rsp + 0], 0
    mov qword ptr [rsp + 8], 0
.Lfv_outer:
    mov rcx, [rsp + 0]
    cmp rcx, rbx
    jae .Lfv_nl
    movzx eax, byte ptr [r15 + rcx]
    mov [rsp + 16], rax
    mov [rsp + 8], rcx
.Lfv_inner:
    inc rcx
    cmp rcx, rbx
    jae .Lfv_emit
    movzx eax, byte ptr [r15 + rcx]
    cmp eax, [rsp + 16]
    je .Lfv_inner
.Lfv_emit:
    mov [rsp + 24], rcx
    mov rax, rcx
    sub rax, [rsp + 8]
    mov rdi, r12
    mov esi, [rsp + 16]
    mov rdx, r14
    add rdx, [rsp + 8]
    mov rcx, rax
    call view_append_span
    mov rcx, [rsp + 24]
    mov [rsp + 0], rcx
    jmp .Lfv_outer
.Lfv_nl:
    mov rdi, r12
    xor esi, esi
    lea rdx, [rip + card_nl]
    mov ecx, 1
    call view_append_span
    EPILOGUE

# card_sgr(sb, color, prefix, prefix_len): append an absolute truecolor SGR
FN card_sgr
    PROLOGUE 16
    mov rbx, rdi
    mov r12d, esi
    test r12d, r12d
    jz .Lsgr_done
    mov rdi, rbx
    mov rsi, rdx
    mov edx, ecx
    call sb_push
    mov esi, r12d
    shr esi, 16
    and esi, 0xff
    mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + card_semi]
    mov edx, 1
    call sb_push
    mov esi, r12d
    shr esi, 8
    and esi, 0xff
    mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + card_semi]
    mov edx, 1
    call sb_push
    mov esi, r12d
    and esi, 0xff
    mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + card_m]
    mov edx, 1
    call sb_push
.Lsgr_done:
    EPILOGUE

# card_line_flush_inline(width, bg): emit the built line as one ANSI row.
# Trailing spaces pad to the terminal width so the band reaches the edge; a
# reset ends the row so the next line cannot inherit it.
FN card_line_flush_inline
    PROLOGUE 32
    mov r12d, edi
    mov r13d, esi
    lea rdi, [rip + card_osb]
    call sb_clear
    lea rdi, [rip + card_osb]
    lea rsi, [rip + card_cr]
    mov edx, 1
    call sb_push
    lea rdi, [rip + card_osb]
    lea rsi, [rip + card_el]
    mov edx, 4
    call sb_push
    lea rdi, [rip + card_osb]
    mov esi, r13d
    call theme_emit_bg
    mov r14, [rip + card_sb + SB_ptr]
    mov r15, [rip + card_sty + SB_ptr]
    mov rbx, [rip + card_sb + SB_len]
    mov qword ptr [rsp + 0], 0
    mov qword ptr [rsp + 8], -1
.Lfi_loop:
    mov rcx, [rsp + 0]
    cmp rcx, rbx
    jae .Lfi_pad
    movzx edi, byte ptr [r15 + rcx]
    call view_style_color
    cmp eax, [rsp + 8]
    je .Lfi_byte
    mov [rsp + 8], eax
    lea rdi, [rip + card_osb]
    mov esi, eax
    call theme_emit_fg
.Lfi_byte:
    mov rcx, [rsp + 0]
    lea rdi, [rip + card_osb]
    movzx esi, byte ptr [r14 + rcx]
    call sb_push_byte
    inc qword ptr [rsp + 0]
    jmp .Lfi_loop
.Lfi_pad:
    mov rdi, r14
    mov rsi, rbx
    call view_text_width
    mov r13d, r12d
    sub r13d, eax
    jle .Lfi_reset
.Lfi_padloop:
    lea rdi, [rip + card_osb]
    mov esi, ' '
    call sb_push_byte
    dec r13d
    jnz .Lfi_padloop
.Lfi_reset:
    lea rdi, [rip + card_osb]
    lea rsi, [rip + card_reset]
    mov edx, 4
    call sb_push
    lea rdi, [rip + card_osb]
    lea rsi, [rip + card_nl]
    mov edx, 1
    call sb_push
    mov edi, 1
    mov rsi, [rip + card_osb + SB_ptr]
    mov rdx, [rip + card_osb + SB_len]
    call card_write_all
    inc dword ptr [rip + card_inline_rows]
    EPILOGUE

# card_write_all(fd, ptr, len): write_all, except fd 1 goes to the headless
# frame-capture sink when one is active, so inline card bytes reach the golden.
card_write_all:
    cmp edi, 1
    jne write_all
    mov rax, [rip + g_tui_capture_fd]
    test rax, rax
    js write_all
    mov edi, eax
    jmp write_all

# card_clip_bytes(ptr, len, maxw) -> rax bytes kept (display width <= maxw)
card_clip_bytes:
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    mov r14d, edx
    xor r15d, r15d
    xor ebx, ebx
1:  cmp r15, r13
    jae 2f
    lea rdi, [r12 + r15]
    mov rsi, r13
    sub rsi, r15
    call utf8dec
    mov [rsp], rdx
    mov edi, eax
    call view_wcwidth
    add ebx, eax
    cmp ebx, r14d
    ja 2f
    add r15, [rsp]
    jmp 1b
2:  mov rax, r15
    EPILOGUE

# card_flush_line(view, width, bg, mode)
FN card_flush_line
    cmp ecx, 0
    jne 1f
    mov esi, edx
    jmp card_line_flush_view
1:  mov edi, esi
    mov esi, edx
    jmp card_line_flush_inline

# ------------------------------------------------------------------ helpers
card_eq:
1:  mov al, [rdi]
    cmp al, [rsi]
    jne 2f
    test al, al
    jz 3f
    inc rdi
    inc rsi
    jmp 1b
2:  xor eax, eax
    ret
3:  mov eax, 1
    ret

# card_is_edit(rdi=name) -> eax 1|0
card_is_edit:
    test rdi, rdi
    jz 1f
    lea rsi, [rip + card_p_edit]
    jmp card_eq
1:  xor eax, eax
    ret

# card_count_lines(ptr, len) -> eax
card_count_lines:
    mov rax, rsi
    test rax, rax
    jz .Lcl_zero
    xor ecx, ecx
    xor edx, edx
1:  cmp rdx, rax
    jae 2f
    cmp byte ptr [rdi + rdx], 10
    jne 3f
    inc ecx
3:  inc rdx
    jmp 1b
2:  cmp byte ptr [rdi + rax - 1], 10
    je 4f
    inc ecx
4:  mov eax, ecx
    ret
.Lcl_zero:
    xor eax, eax
    ret

# chat_count(chat) -> eax
.globl chat_count
chat_count:
    mov rax, [rdi + CH_cards]
    test rax, rax
    jz 1f
    mov eax, [rax + VEC_len]
    ret
1:  xor eax, eax
    ret

# chat_card(chat, index) -> card*
chat_card:
    mov rax, [rdi + CH_cards]
    mov rax, [rax + VEC_ptr]
    imul rsi, rsi, CD_SIZE
    add rax, rsi
    ret

# chat_last(chat) -> card*|0
chat_last:
    PROLOGUE 0
    call chat_count
    test eax, eax
    jz 1f
    dec eax
    mov esi, eax
    call chat_card
    EPILOGUE
1:  xor eax, eax
    EPILOGUE

# chat_find(chat, id) -> card*|0
.globl chat_find
chat_find:
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    xor r14d, r14d
1:  mov rdi, r12
    call chat_count
    cmp r14d, eax
    jae 3f
    mov rdi, r12
    mov esi, r14d
    call chat_card
    mov rdi, [rax + CD_id]
    mov rsi, r13
    test rdi, rdi
    jz 2f
    test rsi, rsi
    jz 2f
    call card_eq
    test eax, eax
    jnz 4f
2:  inc r14d
    jmp 1b
3:  xor eax, eax
    EPILOGUE
4:  mov rdi, r12
    mov esi, r14d
    call chat_card
    EPILOGUE

# chat_find_running(chat, name) -> card*|0
chat_find_running:
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    xor r14d, r14d
1:  mov rdi, r12
    call chat_count
    cmp r14d, eax
    jae 3f
    mov rdi, r12
    mov esi, r14d
    call chat_card
    cmp dword ptr [rax + CD_running], 0
    je 2f
    mov rdi, [rax + CD_name]
    mov rsi, r13
    test rdi, rdi
    jz 4f
    test rsi, rsi
    jz 4f
    call card_eq
    test eax, eax
    jnz 4f
2:  inc r14d
    jmp 1b
3:  xor eax, eax
    EPILOGUE
4:  mov rdi, r12
    mov esi, r14d
    call chat_card
    EPILOGUE

# --------------------------------------------------------------- public model
# chat_init(chat)
FN chat_init
    mov qword ptr [rdi + CH_cards], 0
    xor eax, eax
    ret

# chat_free_card(card)
chat_free_card:
    PROLOGUE 0
    mov rbx, rdi
    mov rdi, [rbx + CD_id]
    call mem_free
    mov rdi, [rbx + CD_name]
    call mem_free
    mov rdi, [rbx + CD_args]
    call sb_free
    mov rdi, [rbx + CD_args]
    call mem_free
    mov rdi, [rbx + CD_out]
    call sb_free
    mov rdi, [rbx + CD_out]
    call mem_free
    xor eax, eax
    mov [rbx + CD_id], rax
    mov [rbx + CD_name], rax
    mov [rbx + CD_args], rax
    mov [rbx + CD_out], rax
    EPILOGUE

# chat_clear(chat): drop all cards, keep the vector
FN chat_clear
    PROLOGUE 16
    mov r12, rdi
    xor r13d, r13d
1:  mov rdi, r12
    call chat_count
    cmp r13d, eax
    jae 2f
    mov rdi, r12
    mov esi, r13d
    call chat_card
    mov rdi, rax
    call chat_free_card
    inc r13d
    jmp 1b
2:  mov rax, [r12 + CH_cards]
    test rax, rax
    jz 3f
    mov qword ptr [rax + VEC_len], 0
3:  EPILOGUE

# chat_free(chat)
FN chat_free
    PROLOGUE 16
    mov r12, rdi
    call chat_clear
    mov rdi, [r12 + CH_cards]
    call mem_free
    mov qword ptr [r12 + CH_cards], 0
    EPILOGUE

# chat_tool_start(chat, id, name, now_ms) -> card*
FN chat_tool_start
    PROLOGUE 32
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    cmp qword ptr [r12 + CH_cards], 0
    jne 1f
    mov edi, VEC_SIZE
    call mem_alloc
    mov [r12 + CH_cards], rax
1:  mov rdi, [r12 + CH_cards]
    mov esi, CD_SIZE
    call vec_push
    mov rbx, rax
    mov rdi, r13
    test rdi, rdi
    jnz 2f
    lea rdi, [rip + card_q]
2:  mov r13, rdi
    call strlen
    mov rsi, rax
    mov rdi, r13
    call mem_dup
    mov [rbx + CD_id], rax
    mov rdi, r14
    test rdi, rdi
    jnz 3f
    lea rdi, [rip + card_q]
3:  mov r14, rdi
    call strlen
    mov rsi, rax
    mov rdi, r14
    call mem_dup
    mov [rbx + CD_name], rax
    mov edi, SB_SIZE
    call mem_alloc
    mov [rbx + CD_args], rax
    mov edi, SB_SIZE
    call mem_alloc
    mov [rbx + CD_out], rax
    mov [rbx + CD_started_ms], r15
    mov dword ptr [rbx + CD_running], 1
    mov dword ptr [rbx + CD_expanded], 0
    mov rax, rbx
    EPILOGUE

# chat_tool_delta(chat, ptr, len)
FN chat_tool_delta
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    xor esi, esi
    call chat_find_running
    test rax, rax
    jz 1f
    mov rdi, [rax + CD_args]
    mov rsi, r13
    mov rdx, r14
    call sb_push
1:  EPILOGUE

# chat_tool_exec(chat, TE*)
FN chat_tool_exec
    PROLOGUE 32
    mov r12, rdi
    mov r13, rsi
    mov rsi, [r13 + TE_name]
    call chat_find_running
    test rax, rax
    jnz .Lce_found
    mov rdi, r12
    mov rsi, [r13 + TE_id]
    call chat_find
    test rax, rax
    jnz .Lce_found
    mov rdi, r12
    mov rsi, [r13 + TE_id]
    mov rdx, [r13 + TE_name]
    xor ecx, ecx
    call chat_tool_start
.Lce_found:
    mov rbx, rax
    mov rdi, [rbx + CD_args]
    call sb_clear
    mov rsi, [r13 + TE_args]
    test rsi, rsi
    jz 1f
    mov rdi, [rbx + CD_args]
    call sb_push_cstr
1:  mov rdi, [rbx + CD_out]
    call sb_clear
    mov rdi, [r13 + TE_result]
    mov rsi, [r13 + TE_result_len]
    test rdi, rdi
    jz 2f
    mov rdx, [rbx + CD_out]
    call grid_sanitize_bytes
    mov rdi, [rbx + CD_out]
    mov rsi, [rdi + SB_ptr]
    mov rcx, [rdi + SB_len]
    xor eax, eax
3:  cmp rax, rcx
    jae 2f
    cmp byte ptr [rsi + rax], 9
    jne 4f
    mov byte ptr [rsi + rax], ' '
4:  inc rax
    jmp 3b
2:  mov eax, [r13 + TE_duration_ms]
    mov [rbx + CD_duration_ms], rax
    mov eax, [r13 + TE_error]
    mov [rbx + CD_error], eax
    mov dword ptr [rbx + CD_running], 0
    mov rax, rbx
    EPILOGUE

# chat_toggle_last(chat)
FN chat_toggle_last
    PROLOGUE 0
    call chat_last
    test rax, rax
    jz 1f
    xor dword ptr [rax + CD_expanded], 1
1:  EPILOGUE

# chat_has_running(chat) -> eax
FN chat_has_running
    PROLOGUE 16
    mov r12, rdi
    xor r13d, r13d
1:  mov rdi, r12
    call chat_count
    cmp r13d, eax
    jae 3f
    mov rdi, r12
    mov esi, r13d
    call chat_card
    cmp dword ptr [rax + CD_running], 0
    jne 2f
    inc r13d
    jmp 1b
2:  mov eax, 1
    EPILOGUE
3:  xor eax, eax
    EPILOGUE

# chat_reset_marks(chat): clear the per-rebuild rendered flags
FN chat_reset_marks
    PROLOGUE 16
    mov r12, rdi
    xor r13d, r13d
1:  mov rdi, r12
    call chat_count
    cmp r13d, eax
    jae 2f
    mov rdi, r12
    mov esi, r13d
    call chat_card
    mov dword ptr [rax + CD_rendered], 0
    inc r13d
    jmp 1b
2:  EPILOGUE

# ------------------------------------------------------------------ renderer
# card_render(card, view, width, now_ms, mode) -> card*
#   mode 0: append rows to `view`; mode 1: write ANSI card rows to stdout.
FN card_render
    PROLOGUE 144
    mov r12, rdi
    mov r13, rsi
    mov r14d, edx
    mov r15, rcx
    mov [rsp + 128], rcx        # now_ms
    mov [rsp + 104], r8d        # mode
    # outcome band slot + status colour
    mov eax, TH_TOOL_OK_BG
    mov ecx, VS_CARD_OK
    cmp dword ptr [r12 + CD_running], 0
    je 1f
    mov eax, TH_TOOL_BG
    mov ecx, VS_CARD_WARN
    jmp 2f
1:  cmp dword ptr [r12 + CD_error], 0
    je 2f
    mov eax, TH_TOOL_ERR_BG
    mov ecx, VS_CARD_ERR
2:  mov [rsp + 56], ecx        # status style
    mov esi, eax
    call theme_rgb
    mov [rsp + 0], eax          # bg (resolved ARGB)
    # header left: "[name] " + argument preview (48 display columns, clipped
    # on a codepoint boundary; controls -> U+FFFD, tabs -> 4-column stops)
    call card_line_reset
    lea rdi, [rip + card_lb]
    mov esi, 1
    mov edx, VS_CARD_TOOL
    call card_line_add
    mov rdi, [r12 + CD_name]
    test rdi, rdi
    jnz 3f
    lea rdi, [rip + card_q]
3:  mov rbx, rdi
    call strlen
    mov rsi, rax
    mov rdi, rbx
    mov edx, VS_CARD_TOOL
    call card_line_add
    lea rdi, [rip + card_rb]
    mov esi, 2
    mov edx, VS_CARD_TOOL
    call card_line_add
    # Argument preview: clip to CARD_ARGS_PREVIEW display columns without ever
    # splitting a UTF-8 sequence, then let card_line_add sanitize controls.
    mov rdi, [r12 + CD_args]
    test rdi, rdi
    jz .Lhdr_args_done
    mov rsi, [rdi + SB_len]
    test rsi, rsi
    jz .Lhdr_args_done
    mov rdi, [rdi + SB_ptr]
    mov edx, CARD_ARGS_PREVIEW
    call card_clip_bytes
    mov rsi, rax
    mov rdi, [r12 + CD_args]
    mov rdi, [rdi + SB_ptr]
    mov edx, VS_CARD_TOOL
    call card_line_add
.Lhdr_args_done:
    mov rdi, [rip + card_sb + SB_ptr]
    mov rsi, [rip + card_sb + SB_len]
    call view_text_width
    mov [rsp + 8], rax         # lw
    # status text
    lea rdi, [rip + card_st]
    call sb_clear
    cmp dword ptr [r12 + CD_running], 0
    je .Lstat_fin
    cmp qword ptr [rip + g_tui_headless], 0
    jne .Lstat_frozen
    mov rax, [rsp + 128]
    mov rcx, 100
    xor edx, edx
    div rcx
    and eax, 3
    mov [rsp + 112], eax
    mov rax, [rsp + 128]
    sub rax, [r12 + CD_started_ms]
    jns 7f
    xor eax, eax
7:  mov [rsp + 120], rax
    jmp .Lstat_run
.Lstat_frozen:
    mov dword ptr [rsp + 112], 0
    mov qword ptr [rsp + 120], 0
.Lstat_run:
    mov eax, [rsp + 112]
    lea rcx, [rip + card_spin]
    movzx esi, byte ptr [rcx + rax]
    lea rdi, [rip + card_st]
    call sb_push_byte
    lea rdi, [rip + card_st]
    lea rsi, [rip + card_sp]
    mov edx, 1
    call sb_push
    lea rdi, [rip + card_st]
    mov rsi, [rsp + 120]
    call sb_push_u64
    lea rdi, [rip + card_st]
    lea rsi, [rip + card_ms]
    call sb_push_cstr
    jmp .Lstat_done
.Lstat_fin:
    lea rdi, [rip + card_st]
    lea rsi, [rip + card_ok]
    cmp dword ptr [r12 + CD_error], 0
    je 8f
    lea rsi, [rip + card_err]
8:  call sb_push_cstr
    lea rdi, [rip + card_st]
    xor esi, esi
    cmp qword ptr [rip + g_tui_headless], 0
    jne 81f
    mov rsi, [r12 + CD_duration_ms]
81: call sb_push_u64
    lea rdi, [rip + card_st]
    lea rsi, [rip + card_ms]
    call sb_push_cstr
.Lstat_done:
    mov rax, [rip + card_st + SB_len]
    mov [rsp + 16], rax        # sw
    # right-align status within width-1
    mov eax, r14d
    cmp eax, 2
    jge 9f
    mov eax, 2
9:  dec eax
    mov [rsp + 96], eax        # avail
    # clip the header so the status always fits right-aligned with >=1 space
    mov rcx, [rsp + 8]
    add rcx, 1
    add rcx, [rsp + 16]
    cmp rcx, rax
    jbe 10f
    mov edi, eax
    sub edi, 1
    sub edi, [rsp + 16]
    jns 91f
    xor edi, edi
91: call card_clip_line
    mov rdi, [rip + card_sb + SB_ptr]
    mov rsi, [rip + card_sb + SB_len]
    call view_text_width
    mov [rsp + 8], rax
10: mov rax, [rsp + 96]
    sub rax, [rsp + 16]
    sub rax, [rsp + 8]
    jns 11f
    xor eax, eax
11: mov [rsp + 24], rax
.Lpad_done:
    mov rdi, [rsp + 24]
    mov esi, VS_CARD_TOOL
    call card_line_pad
    mov rdi, [rip + card_st + SB_ptr]
    mov rsi, [rip + card_st + SB_len]
    mov edx, [rsp + 56]
    call card_line_add
    mov rdi, r13
    mov esi, r14d
    mov edx, [rsp + 0]
    mov ecx, [rsp + 104]
    call card_flush_line
    # body
    mov rdi, [r12 + CD_out]
    test rdi, rdi
    jz .Lbody_gap
    mov rdi, [rdi + SB_ptr]
    mov rsi, [r12 + CD_out]
    mov rsi, [rsi + SB_len]
    call card_count_lines
    mov [rsp + 32], eax        # total
    mov eax, CARD_EXPANDED
    cmp dword ptr [r12 + CD_expanded], 0
    jne 11f
    mov eax, CARD_COLLAPSED
11: cmp eax, [rsp + 32]
    jbe 12f
    mov eax, [rsp + 32]
12: mov [rsp + 40], eax        # show
    test eax, eax
    jz .Lbody_gap
    # marker when collapsed and more lines exist
    cmp dword ptr [r12 + CD_expanded], 0
    jne .Lbody_lines
    mov eax, [rsp + 32]
    sub eax, [rsp + 40]
    test eax, eax
    jle .Lbody_lines
    call card_line_reset
    lea rdi, [rip + card_sp]
    mov esi, 1
    mov edx, VS_CARD_BODY
    call card_line_add
    lea rdi, [rip + card_dots]
    call strlen
    mov rsi, rax
    lea rdi, [rip + card_dots]
    mov edx, VS_CARD_DIM
    call card_line_add
    mov eax, [rsp + 32]
    sub eax, [rsp + 40]
    mov [rsp + 24], rax
    lea rdi, [rip + card_st]
    call sb_clear
    lea rdi, [rip + card_st]
    mov rsi, [rsp + 24]
    call sb_push_u64
    mov rdi, [rip + card_st + SB_ptr]
    mov rsi, [rip + card_st + SB_len]
    mov edx, VS_CARD_DIM
    call card_line_add
    lea rdi, [rip + card_lines]
    call strlen
    mov rsi, rax
    lea rdi, [rip + card_lines]
    mov edx, VS_CARD_DIM
    call card_line_add
    mov rdi, r13
    mov esi, r14d
    mov edx, [rsp + 0]
    mov ecx, [rsp + 104]
    call card_flush_line
.Lbody_lines:
    mov rdi, [r12 + CD_out]
    mov rax, [rdi + SB_len]
    mov [rsp + 48], rax        # L
    test rax, rax
    jz .Lbody_gap
    mov rsi, [rdi + SB_ptr]
    cmp byte ptr [rsi + rax - 1], 10
    jne 13f
    dec qword ptr [rsp + 48]
13: mov eax, [rsp + 32]
    sub eax, [rsp + 40]
    mov [rsp + 88], eax        # target
    mov qword ptr [rsp + 64], 0
    mov qword ptr [rsp + 72], 0
    mov dword ptr [rsp + 80], 0
.Lbody_scan:
    mov rcx, [rsp + 64]
    mov rax, [rsp + 48]
    cmp rcx, rax
    ja .Lbody_done
    je .Lbody_boundary
    mov rdi, [r12 + CD_out]
    mov r8, [rdi + SB_ptr]
    cmp byte ptr [r8 + rcx], 10
    jne .Lbody_advance
.Lbody_boundary:
    mov eax, [rsp + 80]
    cmp eax, [rsp + 88]
    jb .Lbody_skip
    call card_line_reset
    lea rdi, [rip + card_sp]
    mov esi, 1
    mov edx, VS_CARD_BODY
    call card_line_add
    mov edx, VS_CARD_BODY
    mov rdi, [r12 + CD_name]
    call card_is_edit
    test eax, eax
    jz .Lbody_style
    mov rax, [rsp + 64]
    sub rax, [rsp + 72]
    jz .Lbody_style
    mov rdi, [r12 + CD_out]
    mov rsi, [rdi + SB_ptr]
    mov rcx, [rsp + 72]
    movzx eax, byte ptr [rsi + rcx]
    cmp al, '+'
    jne 14f
    mov edx, VS_CARD_ADD
    jmp .Lbody_style
14: cmp al, '-'
    jne 15f
    mov edx, VS_CARD_DEL
    jmp .Lbody_style
15: cmp al, '@'
    jne .Lbody_style
    mov edx, VS_CARD_HUNK
.Lbody_style:
    mov [rsp + 24], edx
    mov rdi, [r12 + CD_out]
    mov rdi, [rdi + SB_ptr]
    add rdi, [rsp + 72]
    mov rsi, [rsp + 64]
    sub rsi, [rsp + 72]
    mov edx, r14d
    dec edx
    jns 16f
    xor edx, edx
16: call card_clip_bytes
    mov rsi, rax
    mov rdi, [r12 + CD_out]
    mov rdi, [rdi + SB_ptr]
    add rdi, [rsp + 72]
    mov edx, [rsp + 24]
    call card_line_add
    mov rdi, r13
    mov esi, r14d
    mov edx, [rsp + 0]
    mov ecx, [rsp + 104]
    call card_flush_line
    inc dword ptr [rsp + 80]
    mov eax, [rsp + 80]
    cmp eax, [rsp + 32]
    jae .Lbody_done
    jmp .Lbody_after
.Lbody_skip:
    inc dword ptr [rsp + 80]
.Lbody_after:
    mov rax, [rsp + 64]
    inc rax
    mov [rsp + 72], rax
.Lbody_advance:
    inc qword ptr [rsp + 64]
    jmp .Lbody_scan
.Lbody_done:
.Lbody_gap:
    cmp dword ptr [rsp + 104], 0
    jne .Lgap_inline
    mov rdi, r13
    xor esi, esi
    call view_set_bg
    mov rdi, r13
    xor esi, esi
    lea rdx, [rip + card_nl]
    mov ecx, 1
    call view_append_span
    jmp .Lgap_done
.Lgap_inline:
    mov edi, 1
    lea rsi, [rip + card_cr]
    mov edx, 1
    call card_write_all
    mov edi, 1
    lea rsi, [rip + card_el]
    mov edx, 4
    call card_write_all
    mov edi, 1
    lea rsi, [rip + card_nl]
    mov edx, 1
    call card_write_all
    inc dword ptr [rip + card_inline_rows]
.Lgap_done:
    mov rax, r12
    EPILOGUE

# chat_render_by_id(view, chat, id, width, now_ms) -> eax found
FN chat_render_by_id
    PROLOGUE 32
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15d, ecx
    mov [rsp], r8
    mov rdi, r13
    mov rsi, r14
    call chat_find
    test rax, rax
    jz 1f
    mov rdi, rax
    mov rsi, r12
    mov edx, r15d
    mov rcx, [rsp]
    xor r8d, r8d
    call card_render
    mov dword ptr [rax + CD_rendered], 1
    mov eax, 1
    EPILOGUE
1:  xor eax, eax
    EPILOGUE

# chat_render_unmatched(view, chat, width, now_ms): render cards no transcript
# block referenced (a running card before its SE_TOOL_END).
FN chat_render_unmatched
    PROLOGUE 32
    mov r12, rdi
    mov r13, rsi
    mov r14d, edx
    mov r15, rcx
    xor ebx, ebx
1:  mov rdi, r13
    call chat_count
    cmp ebx, eax
    jae 2f
    mov rdi, r13
    mov esi, ebx
    call chat_card
    cmp dword ptr [rax + CD_rendered], 0
    jne 3f
    mov rdi, rax
    mov rsi, r12
    mov edx, r14d
    mov rcx, r15
    xor r8d, r8d
    call card_render
    mov dword ptr [rax + CD_rendered], 1
3:  inc ebx
    jmp 1b
2:  xor eax, eax
    EPILOGUE

# chat_emit_last_inline(chat, width, now_ms): emit the last card as ANSI rows
FN chat_emit_last_inline
    PROLOGUE 16
    mov r12, rdi
    mov r13d, esi
    mov r14, rdx
    call chat_last
    test rax, rax
    jz 1f
    mov r15, rax
    mov rdi, r12
    call chat_count
    dec eax
    mov [rip + card_last_index], eax
    mov rdi, r15
    xor esi, esi
    mov edx, r13d
    mov rcx, r14
    mov r8d, 1
    call card_render
1:  EPILOGUE
