.include "opcode.inc"
# opcode tui: cell grid, ANSI diff renderer, headless dumper.
#
# Cell = 24 bytes { u32 cp; u32 comb; u32 fg; u32 bg; u16 attrs; u16 pad };
# colors are 0xAARRGGBB, `comb` holds one combining mark attached to the
# base glyph (0 = none). The grid owns the live `cells` and a `prev` copy.
# render_flush walks both, emits minimal SGR runs for changed rows and
# updates `prev`.
#
# API: src/tui/API.md. render_build is the shared frame builder, also used by
# term_flush so the synchronized-update envelope stays a single write.

.equ A_BOLD, 1
.equ A_UNDERLINE, 2
.equ A_DIM, 4
.equ A_REVERSE, 8
.equ A_ITALIC, 16

.equ CELL_SIZE, 24
.equ C_cp, 0
.equ C_comb, 4
.equ C_fg, 8
.equ C_bg, 12
.equ C_attrs, 16

# cp sentinel: CELL_CONT marks the second column of a width-2 glyph.  A wide
# glyph that would cross the right edge is blanked instead of split, so the
# emitter never sees a stray continuation cell at a row boundary.
.equ CELL_CONT, 0xFFFFFFFF

.equ GRID_MAX, 4096                 # per-dimension guard

STRUCT
F G_w, 4
F G_h, 4
F G_cells, 8
F G_prev, 8
F G_cap, 8                         # allocated cells (cells and prev)
ENDSTRUCT G_SIZE

.data
.p2align 3
.globl grid_size
grid_size: .quad G_SIZE

.bss
.p2align 3
render_sb: .zero SB_SIZE           # render_flush / render_build scratch

.text

# ------------------------------------------------------------------ helpers

# grid_sanitize(cp edi) -> eax: C0/C1 control codepoints become U+FFFD so a
# stray ESC or other control can never be re-emitted to the terminal. Leaf.
# Single-sourced: card.s's card_sanitize_cp aliases this, and the strict
# decoder is src/base/uni.s:utf8_decode (used by grid_sanitize_bytes too).
.globl grid_sanitize
grid_sanitize:
    cmp edi, 0x20
    jb .Lgs_bad
    cmp edi, 0x7f
    je .Lgs_bad
    cmp edi, 0x80
    jb .Lgs_ok
    cmp edi, 0x9f
    jbe .Lgs_bad
.Lgs_ok:
    mov eax, edi
    ret
.Lgs_bad:
    mov eax, 0xFFFD
    ret

# grid_sanitize_bytes(src, len, out_sb): decode UTF-8 strictly and append only
# sanitized codepoints to out_sb, mapping C0/DEL/C1 controls to U+FFFD.  '\n' is
# preserved for row breaks.  A tab expands to the next 4-column stop (measured
# in display width, reset at '\n') so inline transcript rows align like the
# composer and the cell grid instead of emitting a raw 0x09.  Returns 0.  This
# is the single choke point for untrusted model/tool/error/replay text in
# inline mode (render.s:grid_sanitize is the per-codepoint grid equivalent).
FN grid_sanitize_bytes
    PROLOGUE 32
    mov rbx, rdi                   # src
    mov r12, rsi                   # remaining len
    mov r13, rdx                   # out_sb
    mov dword ptr [rsp], 0         # display column
.Lgsb_loop:
    test r12, r12
    jz .Lgsb_done
    mov rdi, rbx
    mov rsi, r12
    call utf8_decode
    add rbx, rdx
    sub r12, rdx
    cmp eax, 10
    je .Lgsb_nl
    cmp eax, 9
    je .Lgsb_tab
    mov edi, eax
    call grid_sanitize
    mov [rsp + 8], eax
    mov rdi, r13
    mov esi, eax
    call sb_push_utf8
    mov edi, [rsp + 8]
    call utf8_wcwidth
    add [rsp], eax
    jmp .Lgsb_loop
.Lgsb_nl:
    mov dword ptr [rsp], 0
    jmp .Lgsb_emit
.Lgsb_tab:
    mov eax, [rsp]
    and eax, 3
    mov ecx, 4
    sub ecx, eax
.Lgsb_tabloop:
    test ecx, ecx
    jz .Lgsb_loop
    mov [rsp + 4], ecx
    mov rdi, r13
    mov esi, ' '
    call sb_push_utf8
    inc dword ptr [rsp]
    mov ecx, [rsp + 4]
    dec ecx
    jmp .Lgsb_tabloop
.Lgsb_emit:
    mov rdi, r13
    mov esi, eax
    call sb_push_utf8
    jmp .Lgsb_loop
.Lgsb_done:
    xor eax, eax
    EPILOGUE

# emit_style(sb, fg, bg, attrs): absolute colours routed through the theme
# emitter (24-bit / 256 / 16 downgrade). Zero fg is skipped; bg 0 means the
# terminal default and is emitted as SGR 49.
emit_style:
    PROLOGUE 0
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    mov rdi, rbx
    mov esi, r12d
    call theme_emit_fg
    mov rdi, rbx
    mov esi, r13d
    call theme_emit_bg
    test r14d, A_BOLD
    jz 3f
    mov rdi, rbx
    lea rsi, [rip + .Lsgr_bold]
    mov edx, 4
    call sb_push
3:  test r14d, A_DIM
    jz 4f
    mov rdi, rbx
    lea rsi, [rip + .Lsgr_dim]
    mov edx, 4
    call sb_push
4:  test r14d, A_UNDERLINE
    jz 5f
    mov rdi, rbx
    lea rsi, [rip + .Lsgr_underline]
    mov edx, 4
    call sb_push
5:  test r14d, A_REVERSE
    jz 6f
    mov rdi, rbx
    lea rsi, [rip + .Lsgr_reverse]
    mov edx, 4
    call sb_push
6:  test r14d, A_ITALIC
    jz 7f
    mov rdi, rbx
    lea rsi, [rip + .Lsgr_italic]
    mov edx, 4
    call sb_push
7:  EPILOGUE

# ------------------------------------------------------------ grid lifecycle

# grid_init(g, w, h) -> 0|-errno
FN grid_init
    PROLOGUE 32
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    test r12d, r12d
    jle .Lgi_bad
    test r13d, r13d
    jle .Lgi_bad
    cmp r12d, GRID_MAX
    ja .Lgi_bad
    cmp r13d, GRID_MAX
    ja .Lgi_bad
    mov rax, r12
    imul rax, r13
    mov [rsp], rax                 # capacity in cells
    mov rdi, rax
    imul rdi, rax, CELL_SIZE
    mov [rsp + 8], rdi             # bytes
    call mem_alloc
    mov r14, rax
    mov rdi, [rsp + 8]
    call mem_alloc
    mov r15, rax
    mov rdi, [rbx + G_cells]
    call mem_free
    mov rdi, [rbx + G_prev]
    call mem_free
    mov [rbx + G_cells], r14
    mov [rbx + G_prev], r15
    mov [rbx + G_w], r12d
    mov [rbx + G_h], r13d
    mov rax, [rsp]
    mov [rbx + G_cap], rax
    xor eax, eax
    EPILOGUE
.Lgi_bad:
    mov rax, -EINVAL
    EPILOGUE

# grid_free(g)
FN grid_free
    PROLOGUE 0
    mov rbx, rdi
    mov rdi, [rbx + G_cells]
    call mem_free
    mov rdi, [rbx + G_prev]
    call mem_free
    xor eax, eax
    mov [rbx + G_cells], rax
    mov [rbx + G_prev], rax
    mov [rbx + G_w], eax
    mov [rbx + G_h], eax
    mov [rbx + G_cap], rax
    EPILOGUE

# grid_resize(g, w, h) -> 0|-errno; overlapping content is preserved, the
# rest is zeroed and `prev` is reset to force a full repaint.
FN grid_resize
    PROLOGUE 64
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    test r12d, r12d
    jle .Lgr_bad
    test r13d, r13d
    jle .Lgr_bad
    cmp r12d, GRID_MAX
    ja .Lgr_bad
    cmp r13d, GRID_MAX
    ja .Lgr_bad
    mov rax, [rbx + G_cells]
    test rax, rax
    jz .Lgr_init
    cmp r12d, dword ptr [rbx + G_w]
    jne .Lgr_go
    cmp r13d, dword ptr [rbx + G_h]
    jne .Lgr_go
    xor eax, eax
    EPILOGUE
.Lgr_init:
    mov rdi, rbx
    mov esi, r12d
    mov edx, r13d
    call grid_init
    EPILOGUE
.Lgr_go:
    mov rax, r12
    imul rax, r13
    mov [rsp], rax                 # new capacity
    mov rdi, rax
    imul rdi, rax, CELL_SIZE
    mov [rsp + 8], rdi             # new bytes
    call mem_alloc
    mov r14, rax                   # new cells
    mov rdi, [rsp + 8]
    call mem_alloc
    mov r15, rax                   # new prev (zeroed)
    # copy min(old_h, new_h) rows of min(old_w, new_w) cells
    mov r8, [rbx + G_cells]
    mov [rsp + 16], r8
    mov eax, dword ptr [rbx + G_w]
    imul rax, rax, CELL_SIZE
    mov [rsp + 24], rax            # old stride
    mov rax, r12
    imul rax, rax, CELL_SIZE
    mov [rsp + 32], rax            # new stride
    mov r9d, dword ptr [rbx + G_h]
    cmp r9, r13
    cmova r9, r13
    mov [rsp + 56], r9d            # rows to copy
    mov r10d, dword ptr [rbx + G_w]
    cmp r10, r12
    cmova r10, r12
    imul r10, r10, CELL_SIZE
    mov [rsp + 40], r10            # bytes per row
    mov qword ptr [rsp + 48], 0    # y
.Lgr_copy:
    mov rcx, [rsp + 48]
    cmp ecx, [rsp + 56]
    jae .Lgr_swap
    mov rdi, r14
    mov rax, rcx
    imul rax, [rsp + 32]
    add rdi, rax
    mov rsi, [rsp + 16]
    mov rax, rcx
    imul rax, [rsp + 24]
    add rsi, rax
    mov rdx, [rsp + 40]
    call memcpy
    inc qword ptr [rsp + 48]
    jmp .Lgr_copy
.Lgr_swap:
    mov rdi, [rbx + G_cells]
    call mem_free
    mov rdi, [rbx + G_prev]
    call mem_free
    mov [rbx + G_cells], r14
    mov [rbx + G_prev], r15
    mov [rbx + G_w], r12d
    mov [rbx + G_h], r13d
    mov rax, [rsp]
    mov [rbx + G_cap], rax
    xor eax, eax
    EPILOGUE
.Lgr_bad:
    mov rax, -EINVAL
    EPILOGUE

# ---------------------------------------------------------------- primitives

# grid_invalidate(g): mark the whole previous frame dirty so the next flush
# repaints every row (a theme change rewrites all resolved colours).
FN grid_invalidate
    mov rax, [rdi + G_prev]
    test rax, rax
    jz 1f
    mov rcx, [rdi + G_cap]
    imul rcx, rcx, CELL_SIZE
    mov rdi, rax
    xor esi, esi
    mov rdx, rcx
    jmp memset
1:  xor eax, eax
    ret

# grid_clear(g, fg, bg)
FN grid_clear
    mov r8, [rdi + G_cells]
    mov r9, [rdi + G_cap]
    test r9, r9
    jz 2f
    mov r10d, 0x20                 # ' '
1:  mov [r8 + C_cp], r10d
    mov dword ptr [r8 + C_comb], 0
    mov [r8 + C_fg], esi
    mov [r8 + C_bg], edx
    mov qword ptr [r8 + C_attrs], 0
    add r8, CELL_SIZE
    dec r9
    jnz 1b
2:   xor eax, eax
    ret

# grid_fill(g, x, y, w, h, cp, fg, bg)   (fg, bg on the stack)
FN grid_fill
    PROLOGUE 0
    mov rbx, rdi
    movsxd rsi, esi                # x/y are signed screen coordinates
    movsxd rdx, edx
    mov r12d, r9d                  # cp
    mov r10d, dword ptr [rbp + 16] # fg
    mov r11d, dword ptr [rbp + 24] # bg
    test rcx, rcx
    jle .Lgf_done
    test r8, r8
    jle .Lgf_done
    # x1 = min(x + w, g_w) from the ORIGINAL x, then x0 = max(x, 0), and fill
    # the intersection only.  Signed compare so a window fully left of the grid
    # yields an empty range instead of wrapping around.
    mov rax, rsi
    add rax, rcx                   # x + w
    mov edi, dword ptr [rbx + G_w]
    cmp rax, rdi
    cmovg rax, rdi                 # x1
    test rsi, rsi
    jns 1f
    xor esi, esi
1:  # y1 = min(y + h, g_h) from the ORIGINAL y, then y0 = max(y, 0)
    mov rcx, rdx
    add rcx, r8                    # y + h
    mov edi, dword ptr [rbx + G_h]
    cmp rcx, rdi
    cmovg rcx, rdi                 # y1
    test rdx, rdx
    jns 2f
    xor edx, edx
2:  cmp rsi, rax                   # x0 >= x1 (signed; x1 may be negative)
    jge .Lgf_done
    cmp rdx, rcx                   # y0 >= y1
    jge .Lgf_done
    mov r9, rdx                    # y
.Lgf_row:
    cmp r9, rcx
    jge .Lgf_done
    mov rdi, r9
    mov edx, dword ptr [rbx + G_w]
    imul rdi, rdx
    add rdi, rsi
    imul rdi, rdi, CELL_SIZE
    add rdi, [rbx + G_cells]
    mov r8, rax
    sub r8, rsi                    # column count
.Lgf_col:
    mov [rdi + C_cp], r12d
    mov dword ptr [rdi + C_comb], 0
    mov [rdi + C_fg], r10d
    mov [rdi + C_bg], r11d
    mov qword ptr [rdi + C_attrs], 0
    add rdi, CELL_SIZE
    dec r8
    jnz .Lgf_col
    inc r9
    jmp .Lgf_row
.Lgf_done:
    xor eax, eax
    EPILOGUE

# grid_put(g, x, y, cp, fg, bg, attrs)   (attrs on the stack)
# One codepoint.  Width-2 codepoints occupy two cells (the second CELL_CONT)
# and a wide glyph that would cross the right edge is blanked, not split.  A
# genuine combining mark attaches to the preceding base cell (skipping a
# CELL_CONT) and takes no column; C0/DEL/C1 controls are stored as a space and
# the other zero-width format characters are dropped.
FN grid_put
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi                   # x
    mov r13, rdx                   # y
    mov r14d, ecx                  # cp
    mov [rsp], r8d                 # fg
    mov [rsp + 4], r9d             # bg
    mov eax, [rbp + 16]
    mov [rsp + 8], eax             # attrs
    test r13, r13
    js .Lgp_done
    mov eax, dword ptr [rbx + G_h]
    cmp r13, rax
    jae .Lgp_done
    cmp r14d, 0x20
    jb .Lgp_ctrl
    cmp r14d, 0x7f
    je .Lgp_ctrl
    cmp r14d, 0x80
    jb .Lgp_class
    cmp r14d, 0x9f
    jbe .Lgp_done
.Lgp_class:
    mov edi, r14d
    call utf8_is_combining
    test eax, eax
    jnz .Lgp_comb
    mov edi, r14d
    call utf8_wcwidth
    test eax, eax
    jz .Lgp_done
    test r12, r12
    js .Lgp_done
    mov ecx, dword ptr [rbx + G_w]
    cmp r12, rcx
    jae .Lgp_done
    cmp eax, 2
    je .Lgp_wide
    mov rdi, rbx
    mov rsi, r12
    mov edx, r13d
    mov ecx, r14d
    mov r8d, [rsp]
    mov r9d, [rsp + 4]
    mov eax, [rsp + 8]
    call .Lgp_store
    jmp .Lgp_done
.Lgp_wide:
    lea edx, [r12 + 1]
    cmp edx, ecx
    jae .Lgp_wideclip
    mov rdi, rbx
    mov rsi, r12
    mov edx, r13d
    mov ecx, r14d
    mov r8d, [rsp]
    mov r9d, [rsp + 4]
    mov eax, [rsp + 8]
    call .Lgp_store
    mov rdi, rbx
    lea esi, [r12 + 1]
    mov edx, r13d
    mov ecx, CELL_CONT
    mov r8d, [rsp]
    mov r9d, [rsp + 4]
    mov eax, [rsp + 8]
    call .Lgp_store
    jmp .Lgp_done
.Lgp_wideclip:
    mov rdi, rbx
    mov rsi, r12
    mov edx, r13d
    mov ecx, 0x20
    mov r8d, [rsp]
    mov r9d, [rsp + 4]
    mov eax, [rsp + 8]
    call .Lgp_store
    jmp .Lgp_done
.Lgp_ctrl:
    mov r14d, 0x20
    jmp .Lgp_class
.Lgp_comb:
    lea rsi, [r12 - 1]
.Lgp_comb_loop:
    test rsi, rsi
    js .Lgp_done
    mov r8d, dword ptr [rbx + G_w]
    cmp esi, r8d
    jae .Lgp_done
    mov rax, r13
    imul rax, r8
    add rax, rsi
    imul rax, rax, CELL_SIZE
    add rax, [rbx + G_cells]
    mov ecx, dword ptr [rax + C_cp]
    cmp ecx, CELL_CONT
    jne .Lgp_comb_try
    dec rsi
    jmp .Lgp_comb_loop
.Lgp_comb_try:
    test ecx, ecx
    jz .Lgp_done
    cmp ecx, 0x20
    je .Lgp_done
    cmp dword ptr [rax + C_comb], 0
    jne .Lgp_done
    mov [rax + C_comb], r14d
.Lgp_done:
    xor eax, eax
    EPILOGUE

# .Lgp_store(rdi=g, esi=x, edx=y, ecx=cp, r8d=fg, r9d=bg, eax=attrs)
# write one cell and clear the combining mark and the padding bytes.
.Lgp_store:
    mov r10d, dword ptr [rdi + G_w]
    mov r11, rdx
    imul r11, r10
    add r11, rsi
    imul r11, r11, CELL_SIZE
    add r11, [rdi + G_cells]
    mov [r11 + C_cp], ecx
    mov dword ptr [r11 + C_comb], 0
    mov [r11 + C_fg], r8d
    mov [r11 + C_bg], r9d
    mov [r11 + C_attrs], ax
    mov word ptr [r11 + C_attrs + 2], 0
    mov dword ptr [r11 + C_attrs + 4], 0
    ret

# grid_text(g, x, y, fg, bg, attrs, ptr, len) -> new_x
# Decodes UTF-8 and places every codepoint through grid_put, so wide glyphs,
# combining marks and control sanitisation behave exactly like the single-cell
# path.  Horizontal clipping only.
FN grid_text
    PROLOGUE 48
    mov rbx, rdi
    mov r12, rsi                   # x
    mov r13, rdx                   # y
    mov r14d, ecx                  # fg
    mov r15d, r8d                  # bg
    mov [rsp], r9d                 # attrs
    mov rax, [rbp + 16]
    mov [rsp + 8], rax             # ptr
    mov rax, [rbp + 24]
    mov [rsp + 16], rax            # len
    test r13, r13
    js .Lgt_out
    mov eax, dword ptr [rbx + G_h]
    cmp r13, rax
    jae .Lgt_out
.Lgt_loop:
    cmp qword ptr [rsp + 16], 0
    jle .Lgt_out
    mov rdi, [rsp + 8]
    mov rsi, [rsp + 16]
    call utf8_decode
    add [rsp + 8], rdx
    sub [rsp + 16], rdx
    mov [rsp + 24], eax            # cp
    mov rdi, rbx
    mov esi, r12d
    mov edx, r13d
    mov ecx, eax
    mov r8d, r14d
    mov r9d, r15d
    sub rsp, 16
    mov eax, [rsp + 16]
    mov [rsp], rax
    call grid_put
    add rsp, 16
    mov edi, [rsp + 24]
    call utf8_is_combining
    test eax, eax
    jnz .Lgt_loop
    mov edi, [rsp + 24]
    call utf8_wcwidth
    test eax, eax
    jnz .Lgt_adv
    # zero width, not combining: C0/DEL were stored as a space (one column);
    # C1 and the Cf format set were dropped entirely.
    mov ecx, [rsp + 24]
    cmp ecx, 0x20
    jb .Lgt_ctrl
    cmp ecx, 0x7f
    je .Lgt_ctrl
    jmp .Lgt_loop
.Lgt_ctrl:
    mov eax, 1
.Lgt_adv:
    add r12, rax
    jmp .Lgt_loop
.Lgt_out:
    mov rax, r12
    EPILOGUE

# ------------------------------------------------------------------ renderer

# render_build(g) -> rax = frame bytes, rdx = length. Fills render_sb with
# the ANSI diff against prev; prev is updated as rows are consumed.
FN render_build
    PROLOGUE 80
    mov rbx, rdi
    mov r12d, -1                   # current style (sentinel: always differs)
    mov r13d, -1
    mov r14d, -1
    lea rdi, [rip + render_sb]
    call sb_clear
    mov eax, dword ptr [rbx + G_w]
    mov [rsp + 16], rax            # cols
    imul rax, rax, CELL_SIZE
    mov [rsp + 24], rax            # row bytes
    mov rax, [rbx + G_cells]
    mov [rsp], rax                 # current row cursor
    mov rax, [rbx + G_prev]
    mov [rsp + 8], rax             # prev row cursor
    xor r15d, r15d                 # row
.Lrb_row:
    mov ecx, dword ptr [rbx + G_h]
    cmp r15, rcx
    jae .Lrb_done
    mov r8, [rsp]
    mov r9, [rsp + 8]
    mov rcx, [rsp + 16]
    xor r10d, r10d
.Lrb_cmp:
    cmp r10, rcx
    jae .Lrb_same
    mov rax, [r8]
    cmp rax, [r9]
    jne .Lrb_diff
    mov rax, [r8 + 8]
    cmp rax, [r9 + 8]
    jne .Lrb_diff
    mov rax, [r8 + 16]
    cmp rax, [r9 + 16]
    jne .Lrb_diff
    add r8, CELL_SIZE
    add r9, CELL_SIZE
    inc r10
    jmp .Lrb_cmp
.Lrb_same:
    mov rax, [rsp + 24]
    add [rsp], rax
    add [rsp + 8], rax
    inc r15
    jmp .Lrb_row
.Lrb_diff:
    # position: ESC [ (row+1) ; 1 H
    lea rdi, [rip + render_sb]
    lea rsi, [rip + .Lcsi]
    mov edx, 2
    call sb_push
    lea rdi, [rip + render_sb]
    lea rsi, [r15 + 1]
    call sb_push_u64
    lea rdi, [rip + render_sb]
    lea rsi, [rip + .Lcsi_row]
    mov edx, 3
    call sb_push
    # trim trailing blanks, but keep a reverse-video caret cell and a cell
    # carrying a theme background band so a status/tool band reaches the
    # right edge.
    mov r10, [rsp + 16]
.Lrb_trim:
    test r10, r10
    jz .Lrb_trim_done
    mov r8, [rsp]
    mov rax, r10
    imul rax, rax, CELL_SIZE
    lea r8, [r8 + rax - CELL_SIZE]
    mov ecx, dword ptr [r8 + C_cp]
    test ecx, ecx                  # cp == 0 is padding too
    jz .Lrb_trim_blank
    cmp ecx, 0x20
    jne .Lrb_trim_done             # content (incl. CELL_CONT)
.Lrb_trim_blank:
    test word ptr [r8 + C_attrs], A_REVERSE
    jnz .Lrb_trim_done
    cmp dword ptr [r8 + C_bg], 0
    jne .Lrb_trim_done
.Lrb_trim_dec:
    dec r10
    jmp .Lrb_trim
.Lrb_trim_done:
    mov [rsp + 40], r10            # last visible column
    mov qword ptr [rsp + 32], 0    # i
.Lrb_run:
    mov r10, [rsp + 32]
    cmp r10, [rsp + 40]
    jae .Lrb_tail
    mov r8, [rsp]
    mov rax, r10
    imul rax, rax, CELL_SIZE
    add r8, rax
    mov eax, dword ptr [r8 + C_fg]
    mov edx, dword ptr [r8 + C_bg]
    movzx ecx, word ptr [r8 + C_attrs]
    cmp eax, r12d
    jne .Lrb_style
    cmp edx, r13d
    jne .Lrb_style
    cmp ecx, r14d
    je .Lrb_emit
.Lrb_style:
    mov [rsp + 48], eax
    mov [rsp + 52], edx
    mov [rsp + 56], ecx
    lea rdi, [rip + render_sb]
    lea rsi, [rip + .Lsgr_reset]
    mov edx, 4
    call sb_push
    lea rdi, [rip + render_sb]
    mov esi, [rsp + 48]
    mov edx, [rsp + 52]
    mov ecx, [rsp + 56]
    call emit_style
    mov r12d, [rsp + 48]
    mov r13d, [rsp + 52]
    mov r14d, [rsp + 56]
.Lrb_emit:
    mov r10, [rsp + 32]
    mov r8, [rsp]
    mov rax, r10
    imul rax, rax, CELL_SIZE
    add r8, rax
    mov esi, dword ptr [r8 + C_cp]
    cmp esi, CELL_CONT
    je .Lrb_emit_next             # continuation column: no glyph of its own
    # defence in depth: the grid must never carry a raw control to the
    # terminal; emit a space instead.
    cmp esi, 0x20
    jb .Lrb_emit_sp
    cmp esi, 0x7f
    jne .Lrb_emit_cp
.Lrb_emit_sp:
    mov esi, 0x20
.Lrb_emit_cp:
    lea rdi, [rip + render_sb]
    call sb_push_utf8
    # one attached combining mark, only when it is itself printable
    mov r10, [rsp + 32]
    mov r8, [rsp]
    mov rax, r10
    imul rax, rax, CELL_SIZE
    add r8, rax
    mov esi, dword ptr [r8 + C_comb]
    test esi, esi
    jz .Lrb_emit_next
    cmp esi, 0x20
    jb .Lrb_emit_next
    cmp esi, 0x7f
    je .Lrb_emit_next
    lea rdi, [rip + render_sb]
    call sb_push_utf8
.Lrb_emit_next:
    inc qword ptr [rsp + 32]
    jmp .Lrb_run
.Lrb_tail:
    # the erase below uses the current style, so match the final column
    mov r10, [rsp + 16]
    test r10, r10
    jz .Lrb_clear
    mov r8, [rsp]
    mov rax, r10
    imul rax, rax, CELL_SIZE
    lea r8, [r8 + rax - CELL_SIZE]
    mov eax, dword ptr [r8 + C_fg]
    mov edx, dword ptr [r8 + C_bg]
    movzx ecx, word ptr [r8 + C_attrs]
    cmp eax, r12d
    jne .Lrb_tail_style
    cmp edx, r13d
    jne .Lrb_tail_style
    cmp ecx, r14d
    je .Lrb_clear
.Lrb_tail_style:
    mov [rsp + 48], eax
    mov [rsp + 52], edx
    mov [rsp + 56], ecx
    lea rdi, [rip + render_sb]
    lea rsi, [rip + .Lsgr_reset]
    mov edx, 4
    call sb_push
    lea rdi, [rip + render_sb]
    mov esi, [rsp + 48]
    mov edx, [rsp + 52]
    mov ecx, [rsp + 56]
    call emit_style
    mov r12d, [rsp + 48]
    mov r13d, [rsp + 52]
    mov r14d, [rsp + 56]
.Lrb_clear:
    lea rdi, [rip + render_sb]
    lea rsi, [rip + .Lcsi_k]
    mov edx, 3
    call sb_push
    mov rdi, [rsp + 8]
    mov rsi, [rsp]
    mov rdx, [rsp + 24]
    call memcpy
    mov rax, [rsp + 24]
    add [rsp], rax
    add [rsp + 8], rax
    inc r15
    jmp .Lrb_row
.Lrb_done:
    # if the last emitted style had attributes, reset so bold/reverse cannot
    # leak into the shell after the frame.  r14d == -1 means nothing was
    # emitted at all (no diff), so there is no style state to undo.
    cmp r14d, 0
    jle 1f
    lea rdi, [rip + render_sb]
    lea rsi, [rip + .Lsgr_reset]
    mov edx, 4
    call sb_push
1:  lea rax, [rip + render_sb]
    mov rdx, [rax + SB_len]
    mov rax, [rax + SB_ptr]
    EPILOGUE

# render_flush(g, fd) -> 0|-errno: diff, then one write_all
FN render_flush
    PROLOGUE 16
    mov [rsp], rdi
    mov [rsp + 8], rsi
    call render_build
    test rdx, rdx
    jz .Lrfl_ok
    mov edi, dword ptr [rsp + 8]
    mov rsi, rax
    call write_all
    EPILOGUE
.Lrfl_ok:
    xor eax, eax
    EPILOGUE

# render_dump(g, sb) -> 0: plain text, trailing spaces trimmed, rows joined
# with '\n' and no trailing newline.
FN render_dump
    PROLOGUE 48
    mov rbx, rdi
    mov r12, rsi
    mov eax, dword ptr [rbx + G_w]
    mov [rsp + 16], rax            # cols
    imul rax, rax, CELL_SIZE
    mov [rsp + 24], rax            # row bytes
    mov rax, [rbx + G_cells]
    mov [rsp], rax                 # row cursor
    xor r13d, r13d                 # row
.Lrd_row:
    mov ecx, dword ptr [rbx + G_h]
    cmp r13, rcx
    jae .Lrd_done
    mov r10, [rsp + 16]
.Lrd_trim:
    test r10, r10
    jz .Lrd_trim_done
    mov r8, [rsp]
    mov rax, r10
    imul rax, rax, CELL_SIZE
    lea r8, [r8 + rax - CELL_SIZE]
    mov ecx, dword ptr [r8 + C_cp]
    test ecx, ecx
    jz 1f
    cmp ecx, 0x20
    jne .Lrd_trim_done
1:  dec r10
    jmp .Lrd_trim
.Lrd_trim_done:
    mov [rsp + 32], r10            # last visible column
    mov qword ptr [rsp + 40], 0    # i
.Lrd_emit:
    mov r10, [rsp + 40]
    cmp r10, [rsp + 32]
    jae .Lrd_row_done
    mov r8, [rsp]
    mov rax, r10
    imul rax, rax, CELL_SIZE
    add r8, rax
    mov esi, dword ptr [r8 + C_cp]
    cmp esi, CELL_CONT
    je .Lrd_emit_next             # wide glyph covers this column via its base
    cmp esi, 0x20
    jb .Lrd_emit_sp
    cmp esi, 0x7f
    jne .Lrd_emit_cp
.Lrd_emit_sp:
    mov esi, 0x20
.Lrd_emit_cp:
    mov rdi, r12
    call sb_push_utf8
    mov r10, [rsp + 40]
    mov r8, [rsp]
    mov rax, r10
    imul rax, rax, CELL_SIZE
    add r8, rax
    mov esi, dword ptr [r8 + C_comb]
    test esi, esi
    jz .Lrd_emit_next
    cmp esi, 0x20
    jb .Lrd_emit_next
    cmp esi, 0x7f
    je .Lrd_emit_next
    mov rdi, r12
    call sb_push_utf8
.Lrd_emit_next:
    inc qword ptr [rsp + 40]
    jmp .Lrd_emit
.Lrd_row_done:
    inc r13
    mov ecx, dword ptr [rbx + G_h]
    cmp r13, rcx
    jae .Lrd_done
    mov rdi, r12
    mov esi, 10
    call sb_push_byte
    mov rax, [rsp + 24]
    add [rsp], rax
    jmp .Lrd_row
.Lrd_done:
    xor eax, eax
    EPILOGUE

.section .rodata
.Lcsi:          .ascii "\033["
.Lcsi_row:      .ascii ";1H"
.Lcsi_k:        .ascii "\033[K"
.Lsgr_reset:    .ascii "\033[0m"
.Lsgr_bold:     .ascii "\033[1m"
.Lsgr_dim:      .ascii "\033[2m"
.Lsgr_underline:.ascii "\033[4m"
.Lsgr_reverse:  .ascii "\033[7m"
.Lsgr_italic:   .ascii "\033[3m"
