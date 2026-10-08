.include "opcode.inc"
.include "tui/theme.inc"
# opcode tui: multiline composer editor.
#
# Display-width wrapping, readline keymap, a single kill slot, disk-backed
# history, bracketed-paste collapsing and editor_take, built on opcode's SB/VEC
# containers.
#
# API (System V, second return in rdx):
#   editor_init(e)                         zero the caller struct (ED_SIZE)
#   editor_free(e)                         free text/kill/live, hist, pastes
#   editor_set(e, ptr, len)                replace text (expand tabs), cur at end
#   editor_text(e) -> rax ptr, rdx len
#   editor_empty(e) -> eax 0|1
#   editor_clear(e)                        clear text+pastes, keep history/ascii
#   editor_take(e) -> rax owned cstr       expand paste markers, then clear
#   editor_set_prompt(e, cstr); editor_prompt(e) -> cstr
#   editor_set_ascii(e, esi flag)
#   editor_key(e, esi key, edx cp, ecx mods) -> eax 1 submit | 0
#   editor_paste(e, rsi ptr, rdx len) -> eax 0
#   editor_history_add(e, rsi ptr, rdx len) -> eax 1|0
#   editor_history_append(e, rsi path|0, rdx ptr, rcx len) -> eax 1|0
#   editor_history_load(e, rsi path)
#   editor_complete(e, rsi dir|0) -> eax 0
#   editor_lines(e, esi width) -> rax rows, rdx cur_row, rcx cur_col
#   editor_visual_rows(e, esi width) -> rax rows + 2
#   editor_render(e, grid, x, y, w, h, [bg],[muted],[cursor_visible],[placeholder])
#       -> rax cursor_x, rdx cursor_y   (negative => hidden)
#
# History browsing is the internal .Lhistory_browse driven by Up/Down.

.equ K_UP,        0x110001
.equ K_DOWN,      0x110002
.equ K_LEFT,      0x110003
.equ K_RIGHT,     0x110004
.equ K_HOME,      0x110005
.equ K_END,       0x110006
.equ K_PGUP,      0x110007
.equ K_PGDN,      0x110008
.equ K_DEL,       0x110009
.equ K_BACKSPACE, 0x7f
.equ K_ENTER,     0x0a
.equ K_TAB,       0x09
.equ K_ESC,       0x1b
.equ K_PASTE,     0x110010

.equ MOD_ALT,    1
.equ MOD_SHIFT,  2
.equ MOD_CTRL,   4

.equ HISTORY_MAX,      1000
.equ HISTORY_FILE_MAX, 16777216      # 16 MiB
.equ PASTE_LINE_LIMIT, 10

STRUCT
F ED_text,      SB_SIZE      # 0
F ED_kill,      SB_SIZE      # 24   killed text (single slot)
F ED_live,      SB_SIZE      # 48   live buffer saved while browsing
F ED_hist,      VEC_SIZE     # 72   VEC of char* (oldest .. newest)
F ED_pastes,    VEC_SIZE     # 96   VEC of char* collapsed paste bodies
F ED_prompt,    8            # 120  retained, not drawn
F ED_cur,       4            # 128
F ED_anchor,    4            # 132
F ED_hist_pos,  4            # 136  len == live
F ED_goal_col,  4            # 140  0 = unset; stored column+1
F ED_width,     4            # 144
F ED_flags,     4            # 148  bit0 ascii, bit1 browsing
F ED_paste_count,4           # 152
F ED_scroll,    4            # 156
ENDSTRUCT ED_SIZE

.equ EF_ASCII,    1
.equ EF_BROWSING, 2

# Renderer-local cell/grid constants (render.s keeps its own file-local copies).
.equ ED_A_DIM,    4
.equ ED_A_REVERSE,8
.equ ED_CELL_SIZE,24
.equ ED_C_cp,     0
.equ ED_C_comb,   4
.equ ED_C_fg,     8
.equ ED_C_bg,     12
.equ ED_C_attrs,  16
.equ ED_G_w,      0
.equ ED_G_h,      4
.equ ED_G_cells,  8

# editor_render locals, addressed relative to rbp.
.set ER_h,        -76
.set ER_inner,    -80
.set ER_top,      -84
.set ER_bottom,   -88
.set ER_inph,     -92
.set ER_inpy,     -96
.set ER_bg,       -100
.set ER_muted,    -104
.set ER_curvis,   -108
.set ER_x,        -112
.set ER_y,        -116
.set ER_w,        -120
.set ER_total,    -124
.set ER_currow,   -128
.set ER_curcol,   -132
.set ER_start,    -136
.set ER_row,      -140
.set ER_col,      -144
.set ER_cp,       -148
.set ER_cw,       -152
.set ER_atc,      -156
.set ER_yy,       -160
.set ER_ruley,    -164
.set ER_rulei,    -168
.set ER_rulecp,   -172
.set ER_caretcol, -176
.set ER_cx,       -180
.set ER_cy,       -184
.set ER_curset,   -188
.set ER_ph,       -200
.set ER_k,        -208
.set ER_pos,      -216
.set ER_phptr,    -224
.set ER_phlen,    -232
.set ER_phcol,    -236
.set ER_fg,       -240

# editor_complete frame locals (rsp-relative).
.set EC_namepart,   0
.set EC_full,       256
.set EC_dbuf,       4352
.set EC_best,       12544
.set EC_tok,        13056
.set EC_name_start, 13060
.set EC_slash,      13064
.set EC_pl,         13068
.set EC_nl,         13072
.set EC_fd,         13076
.set EC_have,       13080
.set EC_bestscore,  13084
.set EC_bestdir,    13088
.set EC_n,          13092
.set EC_reclen,     13096
.set EC_score,      13100
.set EC_inslen,     13104
.set EC_removed,    13108
.set EC_newlen,     13112
.set EC_bl,         13116
.set EC_tail,       13120
.set EC_fp,         13128
.set EC_dllen,      13136
.set EC_nameptr,    13144

.data
.p2align 3
.globl editor_ed_size
GTYPE editor_ed_size, @object
editor_ed_size: .quad ED_SIZE

.section .rodata
.Lnl:       .byte 10
.Lempty:    .asciz ""
.Lmarker:   .ascii "[Pasted text #"
.Lmarker_tail: .ascii " lines]"

.text

# ---------------------------------------------------------------- primitives
# .Lword_byte(edi=byte) -> eax 1|0 : [A-Za-z0-9_] or byte >= 0x80
.Lword_byte:
    cmp edi, '_'
    je .Lwb_yes
    cmp edi, '0'
    jb .Lwb_no
    cmp edi, '9'
    jbe .Lwb_yes
    cmp edi, 'A'
    jb .Lwb_no
    cmp edi, 'Z'
    jbe .Lwb_yes
    cmp edi, 'a'
    jb .Lwb_no
    cmp edi, 'z'
    jbe .Lwb_yes
    cmp edi, 0x80
    jae .Lwb_yes
.Lwb_no:
    xor eax, eax
    ret
.Lwb_yes:
    mov eax, 1
    ret

# .Lebase(edi=value) -> eax: lowercase base letter for a ctrl chord, else 0.
.Lebase:
    mov eax, edi
    cmp eax, 1
    jb .Lb_no
    cmp eax, 26
    jbe .Lb_ctrl
    cmp eax, 0x61
    jb .Lb_no
    cmp eax, 0x7a
    jbe .Lb_ret
    cmp eax, 0x41
    jb .Lb_no
    cmp eax, 0x5a
    ja .Lb_no
    add eax, 32
.Lb_ret:
    ret
.Lb_ctrl:
    add eax, 0x60
    ret
.Lb_no:
    xor eax, eax
    ret

# .Lprev_cp(rdi=e, esi=pos) -> eax = previous codepoint boundary
.Lprev_cp:
    mov rax, [rdi + ED_text + SB_ptr]
    mov ecx, esi
    test ecx, ecx
    jz .Lpc_ret
    dec ecx
.Lpc_loop:
    test ecx, ecx
    jz .Lpc_ret
    movzx edx, byte ptr [rax + rcx]
    and edx, 0xc0
    cmp edx, 0x80
    jne .Lpc_ret
    dec ecx
    jmp .Lpc_loop
.Lpc_ret:
    mov eax, ecx
    ret

# .Lnext_cp(rdi=e, esi=pos) -> eax = next codepoint boundary (<= len)
.Lnext_cp:
    mov r8, [rdi + ED_text + SB_ptr]
    mov r9, [rdi + ED_text + SB_len]
    cmp rsi, r9
    jae .Lnc_end
    lea ecx, [rsi + 1]
.Lnc_loop:
    cmp rcx, r9
    jae .Lnc_ret
    movzx edx, byte ptr [r8 + rcx]
    and edx, 0xc0
    cmp edx, 0x80
    jne .Lnc_ret
    inc ecx
    jmp .Lnc_loop
.Lnc_end:
    mov ecx, r9d
.Lnc_ret:
    mov eax, ecx
    ret

# .Lsb_zero(rdi=sb): zero a stack-local SB before first use.
.Lsb_zero:
    xor eax, eax
    mov [rdi + SB_ptr], rax
    mov [rdi + SB_len], rax
    mov [rdi + SB_cap], rax
    ret

# .Lexpand_tabs(rdi=dst_sb, rsi=ptr, rdx=len): append tab-expanded bytes.
# Tabs advance to the next 4-column stop measured in display width; a '\n'
# resets the column.  The source may alias dst's storage (dst is only appended
# to, never re-read from).
.Lexpand_tabs:
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    xor r14d, r14d               # col
    xor r15d, r15d               # i
.Lxt_loop:
    cmp r15, r13
    jae .Lxt_done
    movzx eax, byte ptr [r12 + r15]
    cmp eax, 0x09
    jne .Lxt_char
    mov eax, r14d
    and eax, 3
    mov ecx, 4
    sub ecx, eax
    mov [rsp], ecx
.Lxt_sp:
    cmp dword ptr [rsp], 0
    jle .Lxt_sp_done
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    inc r14d
    dec dword ptr [rsp]
    jmp .Lxt_sp
.Lxt_sp_done:
    inc r15
    jmp .Lxt_loop
.Lxt_char:
    lea rdi, [r12 + r15]
    mov rsi, r13
    sub rsi, r15
    call utf8_decode
    mov [rsp + 4], eax           # cp
    mov [rsp + 8], rdx           # k
    mov rdi, rbx
    lea rsi, [r12 + r15]
    mov rdx, [rsp + 8]
    call sb_push
    mov rdx, [rsp + 8]
    add r15, rdx
    mov eax, [rsp + 4]
    cmp eax, 0x0a
    jne .Lxt_col
    xor r14d, r14d
    jmp .Lxt_loop
.Lxt_col:
    mov edi, eax
    call utf8_wcwidth
    add r14d, eax
    jmp .Lxt_loop
.Lxt_done:
    EPILOGUE

# .Lset_text(rdi=e, rsi=ptr, rdx=len): replace text (expand tabs), cur=anchor=len.
# The tab expansion runs before ED_text is cleared, so a source pointer that
# aliases ED_text (editor_set(e, editor_text(e), n)) reads valid bytes.
.Lset_text:
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    test r12, r12
    jz .Lst_clear
    test r13, r13
    jz .Lst_clear
    lea rdi, [rsp]
    call .Lsb_zero
    lea rdi, [rsp]
    mov rsi, r12
    mov rdx, r13
    call .Lexpand_tabs
    lea rdi, [rbx + ED_text]
    call sb_clear
    lea rdi, [rbx + ED_text]
    mov rsi, [rsp + SB_ptr]
    mov rdx, [rsp + SB_len]
    call sb_push
    lea rdi, [rsp]
    call sb_free
    jmp .Lst_none
.Lst_clear:
    lea rdi, [rbx + ED_text]
    call sb_clear
.Lst_none:
    mov eax, [rbx + ED_text + SB_len]
    mov [rbx + ED_cur], eax
    mov [rbx + ED_anchor], eax
    mov dword ptr [rbx + ED_goal_col], 0
    xor eax, eax
    EPILOGUE

# .Ldelete(rdi=e, esi=from, edx=to) -> eax 1 if bytes were removed.
# Does not touch the kill buffer or goal column.
.Ldelete:
    PROLOGUE 0
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    cmp r12d, r13d
    jbe 1f
    xchg r12d, r13d
1:  mov r14, [rbx + ED_text + SB_len]
    cmp r13, r14
    jbe 2f
    mov r13, r14
2:  cmp r12, r13
    jae .Ld_none
    mov rdi, [rbx + ED_text + SB_ptr]
    mov rax, r14
    sub rax, r13
    mov rsi, rdi
    add rsi, r13
    add rdi, r12
    mov rdx, rax
    call memmove
    mov rax, r13
    sub rax, r12
    sub [rbx + ED_text + SB_len], rax
    mov rdi, [rbx + ED_text + SB_ptr]
    mov rax, [rbx + ED_text + SB_len]
    mov byte ptr [rdi + rax], 0
    mov [rbx + ED_cur], r12d
    mov [rbx + ED_anchor], r12d
    mov eax, 1
    EPILOGUE
.Ld_none:
    xor eax, eax
    EPILOGUE

# .Linsert_bytes(rdi=e, rsi=ptr, rdx=len): replace selection, insert bytes.
.Linsert_bytes:
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov eax, [rbx + ED_cur]
    mov ecx, [rbx + ED_anchor]
    cmp eax, ecx
    je .Lib_nosel
    mov esi, eax
    mov edx, ecx
    cmp esi, edx
    jbe 1f
    xchg esi, edx
1:  mov rdi, rbx
    call .Ldelete
.Lib_nosel:
    lea rdi, [rbx + ED_text]
    mov rsi, r13
    call sb_reserve
    mov rdi, [rbx + ED_text + SB_ptr]
    mov rcx, [rbx + ED_text + SB_len]
    mov r14d, [rbx + ED_cur]
    mov rdx, rcx
    sub rdx, r14                 # tail length
    mov rsi, rdi
    add rsi, r14
    lea rdi, [rdi + r14]
    add rdi, r13
    call memmove
    mov rdi, [rbx + ED_text + SB_ptr]
    add rdi, r14
    mov rsi, r12
    mov rdx, r13
    call memcpy
    add [rbx + ED_text + SB_len], r13
    mov rdi, [rbx + ED_text + SB_ptr]
    mov rax, [rbx + ED_text + SB_len]
    mov byte ptr [rdi + rax], 0
    mov eax, r14d
    add eax, r13d
    mov [rbx + ED_cur], eax
    mov [rbx + ED_anchor], eax
    mov dword ptr [rbx + ED_goal_col], 0
    mov eax, 1
    EPILOGUE

# .Linsert_cp(rdi=e, esi=cp)
.Linsert_cp:
    PROLOGUE 16
    mov rbx, rdi
    mov edi, esi
    mov rsi, rsp
    call utf8_encode
    mov rdi, rbx
    mov rsi, rsp
    mov rdx, rax
    call .Linsert_bytes
    mov eax, 1
    EPILOGUE

# .Lcopy_to_kill(rdi=e, esi=a, edx=b): clear then copy text[a,b) into ED_kill.
.Lcopy_to_kill:
    PROLOGUE 0
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    lea rdi, [rbx + ED_kill]
    call sb_clear
    cmp r12d, r13d
    jae .Lck_done
    lea rdi, [rbx + ED_kill]
    mov rsi, [rbx + ED_text + SB_ptr]
    add rsi, r12
    mov rdx, r13
    sub rdx, r12
    call sb_push
.Lck_done:
    EPILOGUE

# .Lkill_sel(rdi=e) -> eax 1 if a selection was copied+killed, 0 if none.
.Lkill_sel:
    PROLOGUE 0
    mov rbx, rdi
    mov eax, [rbx + ED_cur]
    mov ecx, [rbx + ED_anchor]
    cmp eax, ecx
    je .Lks_no
    mov r12d, eax
    mov r13d, ecx
    cmp r12d, r13d
    jbe 1f
    xchg r12d, r13d
1:  mov rdi, rbx
    mov esi, r12d
    mov edx, r13d
    call .Lcopy_to_kill
    mov rdi, rbx
    mov esi, r12d
    mov edx, r13d
    call .Ldelete
    mov eax, 1
    EPILOGUE
.Lks_no:
    xor eax, eax
    EPILOGUE

# ---------------------------------------------------------------- measure
# .Lmeasure(rdi=e, esi=width) -> rax text rows, rdx cur row, rcx cur col.
# inner = max(width-1,1).  Newline breaks; a codepoint wraps when
# col+wcwidth > inner (strict).  The codepoint at the caret is processed
# (including its wrap) before the cursor is recorded.
# locals: 0 row, 4 col, 8 pos(8), 16 k(8), 24 at_cursor, 28 rec
.set LM_row,   0
.set LM_col,   4
.set LM_pos,   8
.set LM_k,     16
.set LM_atc,   24
.set LM_rec,   28
.set LM_currow,32
.set LM_curcol,36
.Lmeasure:
    PROLOGUE 64
    mov rbx, rdi
    mov r12, [rbx + ED_text + SB_ptr]
    mov r13, [rbx + ED_text + SB_len]
    mov r15d, [rbx + ED_cur]
    mov r14d, esi
    dec r14d
    cmp r14d, 1
    jae 1f
    mov r14d, 1
1:  mov dword ptr [rsp + LM_row], 0
    mov dword ptr [rsp + LM_col], 0
    mov qword ptr [rsp + LM_pos], 0
    mov dword ptr [rsp + LM_rec], 0
    mov dword ptr [rsp + LM_atc], 0
.Lm_loop:
    mov r10, [rsp + LM_pos]
    cmp r10, r13
    jae .Lm_end
    lea rdi, [r12 + r10]
    mov rsi, r13
    sub rsi, r10
    call utf8_decode
    mov [rsp + LM_k], rdx
    mov r11d, eax                # cp
    mov edx, [rsp + LM_pos]
    cmp edx, r15d
    jne .Lm_notcur
    mov dword ptr [rsp + LM_atc], 1
    jmp .Lm_haveatc
.Lm_notcur:
    mov dword ptr [rsp + LM_atc], 0
.Lm_haveatc:
    cmp r11d, 0x0a
    jne .Lm_char
    cmp dword ptr [rsp + LM_atc], 0
    je .Lm_nl_adv
    mov eax, [rsp + LM_row]
    mov [rsp + LM_currow], eax
    mov eax, [rsp + LM_col]
    mov [rsp + LM_curcol], eax
    mov dword ptr [rsp + LM_rec], 1
.Lm_nl_adv:
    inc dword ptr [rsp + LM_row]
    mov dword ptr [rsp + LM_col], 0
    mov rdx, [rsp + LM_k]
    add [rsp + LM_pos], rdx
    jmp .Lm_loop
.Lm_char:
    mov edi, r11d
    call utf8_wcwidth
    mov ecx, [rsp + LM_col]
    add ecx, eax
    cmp ecx, r14d
    jle .Lm_nowrap
    inc dword ptr [rsp + LM_row]
    mov dword ptr [rsp + LM_col], 0
.Lm_nowrap:
    cmp dword ptr [rsp + LM_atc], 0
    je .Lm_char_add
    mov ecx, [rsp + LM_row]
    mov [rsp + LM_currow], ecx
    mov ecx, [rsp + LM_col]
    mov [rsp + LM_curcol], ecx
    mov dword ptr [rsp + LM_rec], 1
.Lm_char_add:
    add [rsp + LM_col], eax
    mov rdx, [rsp + LM_k]
    add [rsp + LM_pos], rdx
    jmp .Lm_loop
.Lm_end:
    cmp dword ptr [rsp + LM_rec], 0
    jne .Lm_done
    mov eax, [rsp + LM_row]
    mov [rsp + LM_currow], eax
    mov eax, [rsp + LM_col]
    mov [rsp + LM_curcol], eax
.Lm_done:
    mov eax, [rsp + LM_row]
    inc eax
    mov edx, [rsp + LM_currow]
    mov ecx, [rsp + LM_curcol]
    EPILOGUE

# ---------------------------------------------------------------- motion
# .Lmove_left(rdi=e, esi=mods)
.Lmove_left:
    PROLOGUE 0
    mov rbx, rdi
    mov r12d, esi
    mov dword ptr [rbx + ED_goal_col], 0
    test r12d, MOD_SHIFT
    jnz .Lml_shift
    mov eax, [rbx + ED_cur]
    mov ecx, [rbx + ED_anchor]
    cmp eax, ecx
    je .Lml_plain
    cmova eax, ecx
    mov [rbx + ED_cur], eax
    mov [rbx + ED_anchor], eax
    EPILOGUE
.Lml_plain:
    test eax, eax
    jz .Lml_done
    mov rdi, rbx
    mov esi, eax
    call .Lprev_cp
    mov [rbx + ED_cur], eax
    mov [rbx + ED_anchor], eax
    EPILOGUE
.Lml_shift:
    mov eax, [rbx + ED_cur]
    test eax, eax
    jz .Lml_done
    mov rdi, rbx
    mov esi, eax
    call .Lprev_cp
    mov [rbx + ED_cur], eax
.Lml_done:
    EPILOGUE

# .Lmove_right(rdi=e, esi=mods)
.Lmove_right:
    PROLOGUE 0
    mov rbx, rdi
    mov r12d, esi
    mov dword ptr [rbx + ED_goal_col], 0
    test r12d, MOD_SHIFT
    jnz .Lmr_shift
    mov eax, [rbx + ED_cur]
    mov ecx, [rbx + ED_anchor]
    cmp eax, ecx
    je .Lmr_plain
    cmovb eax, ecx
    mov [rbx + ED_cur], eax
    mov [rbx + ED_anchor], eax
    EPILOGUE
.Lmr_plain:
    mov r15d, [rbx + ED_text + SB_len]
    cmp eax, r15d
    jae .Lmr_done
    mov rdi, rbx
    mov esi, eax
    call .Lnext_cp
    mov [rbx + ED_cur], eax
    mov [rbx + ED_anchor], eax
    EPILOGUE
.Lmr_shift:
    mov eax, [rbx + ED_cur]
    mov r15d, [rbx + ED_text + SB_len]
    cmp eax, r15d
    jae .Lmr_done
    mov rdi, rbx
    mov esi, eax
    call .Lnext_cp
    mov [rbx + ED_cur], eax
.Lmr_done:
    EPILOGUE

# .Lword_left(rdi=e)
.Lword_left:
    PROLOGUE 0
    mov rbx, rdi
    mov dword ptr [rbx + ED_goal_col], 0
    mov eax, [rbx + ED_cur]
    mov ecx, [rbx + ED_anchor]
    cmp eax, ecx
    je .Lwl_plain
    cmova eax, ecx
    mov [rbx + ED_cur], eax
    mov [rbx + ED_anchor], eax
    EPILOGUE
.Lwl_plain:
    mov r12, [rbx + ED_text + SB_ptr]
    mov r13d, [rbx + ED_cur]
.Lwl_nw:
    test r13d, r13d
    jz .Lwl_set
    mov rdi, rbx
    mov esi, r13d
    call .Lprev_cp
    mov r14d, eax
    movzx edi, byte ptr [r12 + rax]
    call .Lword_byte
    test eax, eax
    jnz .Lwl_take
    mov r13d, r14d
    jmp .Lwl_nw
.Lwl_take:
    mov r13d, r14d
.Lwl_wloop:
    test r13d, r13d
    jz .Lwl_set
    mov rdi, rbx
    mov esi, r13d
    call .Lprev_cp
    mov r14d, eax
    movzx edi, byte ptr [r12 + rax]
    call .Lword_byte
    test eax, eax
    jz .Lwl_set
    mov r13d, r14d
    jmp .Lwl_wloop
.Lwl_set:
    mov [rbx + ED_cur], r13d
    mov [rbx + ED_anchor], r13d
    EPILOGUE

# .Lword_right(rdi=e)
.Lword_right:
    PROLOGUE 0
    mov rbx, rdi
    mov dword ptr [rbx + ED_goal_col], 0
    mov eax, [rbx + ED_cur]
    mov ecx, [rbx + ED_anchor]
    cmp eax, ecx
    je .Lwr_plain
    cmovb eax, ecx
    mov [rbx + ED_cur], eax
    mov [rbx + ED_anchor], eax
    EPILOGUE
.Lwr_plain:
    mov r12, [rbx + ED_text + SB_ptr]
    mov r13, [rbx + ED_text + SB_len]
    mov r14d, [rbx + ED_cur]
.Lwr_nw:
    cmp r14, r13
    jae .Lwr_set
    movzx edi, byte ptr [r12 + r14]
    call .Lword_byte
    test eax, eax
    jnz .Lwr_wloop
    mov rdi, rbx
    mov esi, r14d
    call .Lnext_cp
    mov r14d, eax
    jmp .Lwr_nw
.Lwr_wloop:
    cmp r14, r13
    jae .Lwr_set
    movzx edi, byte ptr [r12 + r14]
    call .Lword_byte
    test eax, eax
    jz .Lwr_set
    mov rdi, rbx
    mov esi, r14d
    call .Lnext_cp
    mov r14d, eax
    jmp .Lwr_wloop
.Lwr_set:
    mov [rbx + ED_cur], r14d
    mov [rbx + ED_anchor], r14d
    EPILOGUE

# .Lline_start(rdi=e, esi=pos) -> eax start of line containing pos
.Lline_start:
    mov rax, [rdi + ED_text + SB_ptr]
    mov ecx, esi
1:  test ecx, ecx
    jz 2f
    dec ecx
    cmp byte ptr [rax + rcx], 0x0a
    jne 1b
    inc ecx
2:  mov eax, ecx
    ret

# .Lline_end(rdi=e, esi=pos) -> eax end of line containing pos
.Lline_end:
    mov r8, [rdi + ED_text + SB_ptr]
    mov r9, [rdi + ED_text + SB_len]
    mov eax, esi
1:  cmp eax, r9d
    jae 2f
    cmp byte ptr [r8 + rax], 0x0a
    je 2f
    inc eax
    jmp 1b
2:  ret

# .Lmove_home(rdi=e, esi=absolute, edx=mods)
.Lmove_home:
    PROLOGUE 0
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov dword ptr [rbx + ED_goal_col], 0
    test r12d, r12d
    jz .Lmh_line
    xor eax, eax
    jmp .Lmh_set
.Lmh_line:
    mov rdi, rbx
    mov esi, [rbx + ED_cur]
    call .Lline_start
.Lmh_set:
    test r13d, MOD_SHIFT
    jnz .Lmh_shift
    mov [rbx + ED_anchor], eax
.Lmh_shift:
    mov [rbx + ED_cur], eax
    EPILOGUE

# .Lmove_end(rdi=e, esi=absolute, edx=mods)
.Lmove_end:
    PROLOGUE 0
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov dword ptr [rbx + ED_goal_col], 0
    test r12d, r12d
    jz .Lme_line
    mov eax, [rbx + ED_text + SB_len]
    jmp .Lme_set
.Lme_line:
    mov rdi, rbx
    mov esi, [rbx + ED_cur]
    call .Lline_end
.Lme_set:
    test r13d, MOD_SHIFT
    jnz .Lme_shift
    mov [rbx + ED_anchor], eax
.Lme_shift:
    mov [rbx + ED_cur], eax
    EPILOGUE

# .Lmove_vertical(rdi=e, esi=dir, edx=mods)
# The goal column is a byte offset from the current logical line
# start (`cur - line_start`); Up/Down land on the previous/next logical line and
# clamp the target to a codepoint boundary by byte offset, advancing over
# 0b10xxxxxx continuation bytes and never past the line end.  ED_goal_col keeps
# byte-column+1; horizontal motion still clears it.
# locals: 0 cur, 4 ls, 8 le, 12 goal, 16 nls, 20 tls, 24 tle
.Lmove_vertical:
    PROLOGUE 48
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov eax, [rbx + ED_cur]
    mov [rsp + 0], eax
    # current logical line bounds
    mov rdi, rbx
    mov esi, eax
    call .Lline_start
    mov [rsp + 4], eax
    mov rdi, rbx
    mov esi, [rsp + 0]
    call .Lline_end
    mov [rsp + 8], eax
    # goal = ED_goal_col ? ED_goal_col-1 : cur - ls
    mov eax, [rbx + ED_goal_col]
    test eax, eax
    jz 1f
    dec eax
    jmp 2f
1:  mov eax, [rsp + 0]
    sub eax, [rsp + 4]
2:  mov [rsp + 12], eax
    test r12d, r12d
    jns .Lmv_down
    # up: no previous line when already at the buffer start
    mov eax, [rsp + 4]
    test eax, eax
    jz .Lmv_giveup
    lea esi, [rax - 1]
    mov rdi, rbx
    call .Lline_start
    mov [rsp + 20], eax
    mov rdi, rbx
    mov esi, eax
    call .Lline_end
    mov [rsp + 24], eax
    jmp .Lmv_land
.Lmv_down:
    # down: no next line when already at the buffer end
    mov eax, [rsp + 8]
    cmp eax, [rbx + ED_text + SB_len]
    jae .Lmv_giveup
    lea esi, [rax + 1]
    mov [rsp + 16], esi
    mov rdi, rbx
    call .Lline_end
    mov [rsp + 24], eax
    mov eax, [rsp + 16]
    mov [rsp + 20], eax
.Lmv_land:
    # pos = tls + goal, clamped to tle, then advance over continuation bytes
    mov eax, [rsp + 20]
    add eax, [rsp + 12]
    cmp eax, [rsp + 24]
    jbe 3f
    mov eax, [rsp + 24]
3:  mov r14d, eax
    mov r8, [rbx + ED_text + SB_ptr]
    mov r9d, [rsp + 24]
.Lmv_cont:
    cmp r14d, r9d
    jae .Lmv_set
    movzx ecx, byte ptr [r8 + r14]
    and ecx, 0xc0
    cmp ecx, 0x80
    jne .Lmv_set
    inc r14d
    jmp .Lmv_cont
.Lmv_set:
    test r13d, MOD_SHIFT
    jnz 4f
    mov [rbx + ED_anchor], r14d
4:  mov [rbx + ED_cur], r14d
    mov eax, [rsp + 12]
    inc eax
    mov [rbx + ED_goal_col], eax
    EPILOGUE
.Lmv_giveup:
    mov dword ptr [rbx + ED_goal_col], 0
    EPILOGUE

# ---------------------------------------------------------------- kills
# .Lkill_to_end(rdi=e): kill to end of line, eating one newline at EOL.
.Lkill_to_end:
    PROLOGUE 0
    mov rbx, rdi
    mov rdi, rbx
    call .Lkill_sel
    test eax, eax
    jnz .Lke_done
    mov r12, [rbx + ED_text + SB_ptr]
    mov r13, [rbx + ED_text + SB_len]
    mov r14d, [rbx + ED_cur]
    mov eax, r14d
1:  cmp eax, r13d
    jae 2f
    cmp byte ptr [r12 + rax], 0x0a
    je 2f
    inc eax
    jmp 1b
2:  mov r15d, eax
    cmp eax, r14d
    jne 3f
    cmp eax, r13d
    jae 3f
    inc r15d                     # eat the newline too
3:  mov rdi, rbx
    mov esi, r14d
    mov edx, r15d
    call .Lcopy_to_kill
    mov rdi, rbx
    mov esi, r14d
    mov edx, r15d
    call .Ldelete
.Lke_done:
    EPILOGUE

# .Lkill_to_start(rdi=e)
.Lkill_to_start:
    PROLOGUE 0
    mov rbx, rdi
    mov rdi, rbx
    call .Lkill_sel
    test eax, eax
    jnz .Lku_done
    mov rdi, rbx
    mov esi, [rbx + ED_cur]
    call .Lline_start
    mov r12d, eax
    mov rdi, rbx
    mov esi, r12d
    mov edx, [rbx + ED_cur]
    call .Lcopy_to_kill
    mov rdi, rbx
    mov esi, r12d
    mov edx, [rbx + ED_cur]
    call .Ldelete
.Lku_done:
    EPILOGUE

# .Lkill_word(rdi=e): kill the word before the caret.
.Lkill_word:
    PROLOGUE 0
    mov rbx, rdi
    mov rdi, rbx
    call .Lkill_sel
    test eax, eax
    jnz .Lkw_done
    mov r12, [rbx + ED_text + SB_ptr]
    mov r13d, [rbx + ED_cur]
.Lkw_nw:
    test r13d, r13d
    jz .Lkw_set
    mov rdi, rbx
    mov esi, r13d
    call .Lprev_cp
    mov r14d, eax
    movzx edi, byte ptr [r12 + rax]
    call .Lword_byte
    test eax, eax
    jnz .Lkw_wloop
    mov r13d, r14d
    jmp .Lkw_nw
.Lkw_wloop:
    test r13d, r13d
    jz .Lkw_set
    mov rdi, rbx
    mov esi, r13d
    call .Lprev_cp
    mov r14d, eax
    movzx edi, byte ptr [r12 + rax]
    call .Lword_byte
    test eax, eax
    jz .Lkw_set
    mov r13d, r14d
    jmp .Lkw_wloop
.Lkw_set:
    mov rsi, [rbx + ED_text + SB_ptr]
    mov rdi, rbx
    mov esi, r13d
    mov edx, [rbx + ED_cur]
    call .Lcopy_to_kill
    mov rdi, rbx
    mov esi, r13d
    mov edx, [rbx + ED_cur]
    call .Ldelete
.Lkw_done:
    EPILOGUE

# .Lkill_word_forward(rdi=e): kill the word after the caret.
.Lkill_word_forward:
    PROLOGUE 0
    mov rbx, rdi
    mov rdi, rbx
    call .Lkill_sel
    test eax, eax
    jnz .Lkf_done
    mov r12, [rbx + ED_text + SB_ptr]
    mov r13, [rbx + ED_text + SB_len]
    mov r14d, [rbx + ED_cur]
    mov r15d, r14d
.Lkf_nw:
    cmp r15, r13
    jae .Lkf_set
    movzx edi, byte ptr [r12 + r15]
    call .Lword_byte
    test eax, eax
    jnz .Lkf_wloop
    mov rdi, rbx
    mov esi, r15d
    call .Lnext_cp
    mov r15d, eax
    jmp .Lkf_nw
.Lkf_wloop:
    cmp r15, r13
    jae .Lkf_set
    movzx edi, byte ptr [r12 + r15]
    call .Lword_byte
    test eax, eax
    jz .Lkf_set
    mov rdi, rbx
    mov esi, r15d
    call .Lnext_cp
    mov r15d, eax
    jmp .Lkf_wloop
.Lkf_set:
    mov rdi, rbx
    mov esi, r14d
    mov edx, r15d
    call .Lcopy_to_kill
    mov rdi, rbx
    mov esi, r14d
    mov edx, r15d
    call .Ldelete
.Lkf_done:
    EPILOGUE

# .Ldelete_forward(rdi=e)
.Ldelete_forward:
    PROLOGUE 0
    mov rbx, rdi
    mov eax, [rbx + ED_cur]
    mov ecx, [rbx + ED_anchor]
    cmp eax, ecx
    je .Ldf_plain
    mov esi, eax
    mov edx, ecx
    cmp esi, edx
    jbe 1f
    xchg esi, edx
1:  mov rdi, rbx
    call .Ldelete
    EPILOGUE
.Ldf_plain:
    mov r15d, [rbx + ED_text + SB_len]
    cmp eax, r15d
    jae .Ldf_done
    mov rdi, rbx
    mov esi, eax
    call .Lnext_cp
    mov edx, eax
    mov rdi, rbx
    mov esi, [rbx + ED_cur]
    call .Ldelete
.Ldf_done:
    EPILOGUE

# .Ltranspose(rdi=e): Emacs Ctrl+T over whole codepoints.
.Ltranspose:
    PROLOGUE 32
    mov rbx, rdi
    mov eax, [rbx + ED_cur]
    mov ecx, [rbx + ED_anchor]
    cmp eax, ecx
    jne .Lt_done
    test eax, eax
    jz .Lt_done
    mov r12, [rbx + ED_text + SB_ptr]
    mov r13, [rbx + ED_text + SB_len]
    cmp eax, r13d
    jne .Lt_mid
    mov r15d, eax                # c = cur
    mov rdi, rbx
    mov esi, r15d
    call .Lprev_cp
    mov r15d, eax                # b
    test r15d, r15d
    jz .Lt_done
    mov rdi, rbx
    mov esi, r15d
    call .Lprev_cp               # a
    mov r14d, eax
    mov r13d, [rbx + ED_text + SB_len]
    jmp .Lt_have
.Lt_mid:
    mov r15d, eax                # b = cur
    mov rdi, rbx
    mov esi, r15d
    call .Lprev_cp
    mov r14d, eax                # a
    mov rdi, rbx
    mov esi, r15d
    call .Lnext_cp
    mov r13d, eax                # c
.Lt_have:
    mov eax, r15d
    sub eax, r14d                # n1
    mov ecx, r13d
    sub ecx, r15d                # n2
    add eax, ecx
    cmp eax, 8
    ja .Lt_done
    lea rdi, [rsp + 8]
    lea rsi, [r12 + r14]
    mov edx, r15d
    sub edx, r14d
    call memcpy
    lea rdi, [rsp + 8]
    mov eax, r15d
    sub eax, r14d
    add rdi, rax
    lea rsi, [r12 + r15]
    mov edx, r13d
    sub edx, r15d
    call memcpy
    mov ecx, r13d
    sub ecx, r15d
    mov [rsp + 0], ecx           # n2
    lea rdi, [r12 + r14]
    lea rsi, [rsp + 8]
    mov eax, r15d
    sub eax, r14d
    add rsi, rax
    mov edx, ecx
    call memcpy
    mov edx, [rsp + 0]
    lea rdi, [r12 + r14]
    add rdi, rdx
    lea rsi, [rsp + 8]
    mov edx, r15d
    sub edx, r14d
    call memcpy
    mov [rbx + ED_cur], r13d
    mov [rbx + ED_anchor], r13d
    mov dword ptr [rbx + ED_goal_col], 0
.Lt_done:
    EPILOGUE

# .Lyank(rdi=e)
.Lyank:
    PROLOGUE 0
    mov rbx, rdi
    mov rdx, [rbx + ED_kill + SB_len]
    test rdx, rdx
    jz .Lyk_done
    mov rsi, [rbx + ED_kill + SB_ptr]
    mov rdi, rbx
    call .Linsert_bytes
.Lyk_done:
    EPILOGUE

# ---------------------------------------------------------------- history
# .Lhistory_browse(rdi=e, esi=dir) -> eax 1 if the text changed, else 0.
# dir < 0: older, dir > 0: newer.  hist_pos == hist.len is the live buffer.
.Lhistory_browse:
    PROLOGUE 32
    mov rbx, rdi
    mov r12d, esi
    mov eax, [rbx + ED_flags]
    and eax, EF_BROWSING
    mov [rsp + 0], eax
    mov rax, [rbx + ED_hist + VEC_len]
    test rax, rax
    jz .Lhb_no
    test dword ptr [rbx + ED_flags], EF_BROWSING
    jnz .Lhb_cont
    or dword ptr [rbx + ED_flags], EF_BROWSING
    lea rdi, [rbx + ED_live]
    call sb_clear
    lea rdi, [rbx + ED_live]
    mov rsi, [rbx + ED_text + SB_ptr]
    mov rdx, [rbx + ED_text + SB_len]
    call sb_push
    mov rax, [rbx + ED_hist + VEC_len]
    mov [rbx + ED_hist_pos], eax
.Lhb_cont:
    test r12d, r12d
    jns .Lhb_down
    mov eax, [rbx + ED_hist_pos]
    test eax, eax
    jz .Lhb_no
    dec eax
    mov [rbx + ED_hist_pos], eax
    jmp .Lhb_load
.Lhb_down:
    mov eax, [rbx + ED_hist_pos]
    mov rcx, [rbx + ED_hist + VEC_len]
    inc eax
    cmp rax, rcx
    jb .Lhb_store
    # past the newest: restore the live buffer
    mov rdi, rbx
    mov rsi, [rbx + ED_live + SB_ptr]
    mov rdx, [rbx + ED_live + SB_len]
    call .Lset_text
    and dword ptr [rbx + ED_flags], 0xfffffffd
    mov eax, [rsp + 0]           # changed only if we were browsing
    EPILOGUE
.Lhb_store:
    mov [rbx + ED_hist_pos], eax
.Lhb_load:
    mov eax, [rbx + ED_hist_pos]
    mov rcx, [rbx + ED_hist + VEC_ptr]
    mov r13, [rcx + rax*8]
    mov rdi, r13
    call strlen
    mov rdi, rbx
    mov rsi, r13
    mov rdx, rax
    call .Lset_text
    mov eax, 1
    EPILOGUE
.Lhb_no:
    xor eax, eax
    EPILOGUE

# ---------------------------------------------------------------- API
# editor_init(e)
FN editor_init
    xor eax, eax
    mov ecx, ED_SIZE
    rep stosb
    ret

# editor_free(e)
FN editor_free
    PROLOGUE 0
    mov rbx, rdi
    mov r13, [rbx + ED_hist + VEC_len]
    mov r12, [rbx + ED_hist + VEC_ptr]
    xor r14d, r14d
1:  cmp r14, r13
    jae 2f
    mov rdi, [r12 + r14*8]
    call mem_free
    inc r14
    jmp 1b
2:  lea rdi, [rbx + ED_hist]
    call vec_free
    mov r13, [rbx + ED_pastes + VEC_len]
    mov r12, [rbx + ED_pastes + VEC_ptr]
    xor r14d, r14d
3:  cmp r14, r13
    jae 4f
    mov rdi, [r12 + r14*8]
    call mem_free
    inc r14
    jmp 3b
4:  lea rdi, [rbx + ED_pastes]
    call vec_free
    lea rdi, [rbx + ED_text]
    call sb_free
    lea rdi, [rbx + ED_kill]
    call sb_free
    lea rdi, [rbx + ED_live]
    call sb_free
    xor eax, eax
    EPILOGUE

# editor_set(e, ptr, len)
FN editor_set
    PROLOGUE 0
    mov rbx, rdi
    call .Lset_text
    mov rax, [rbx + ED_hist + VEC_len]
    mov [rbx + ED_hist_pos], eax
    xor eax, eax
    EPILOGUE

# editor_text(e) -> rax ptr, rdx len
FN editor_text
    mov rax, [rdi + ED_text + SB_ptr]
    mov rdx, [rdi + ED_text + SB_len]
    ret

# editor_empty(e) -> eax 0|1
FN editor_empty
    xor eax, eax
    cmp qword ptr [rdi + ED_text + SB_len], 0
    sete al
    ret

# editor_clear(e): clear text + pastes, keep history and ascii.
FN editor_clear
    PROLOGUE 0
    mov rbx, rdi
    lea rdi, [rbx + ED_text]
    call sb_clear
    mov r13, [rbx + ED_pastes + VEC_len]
    mov r12, [rbx + ED_pastes + VEC_ptr]
    xor r14d, r14d
1:  cmp r14, r13
    jae 2f
    mov rdi, [r12 + r14*8]
    call mem_free
    inc r14
    jmp 1b
2:  lea rdi, [rbx + ED_pastes]
    call vec_free
    mov dword ptr [rbx + ED_paste_count], 0
    mov dword ptr [rbx + ED_cur], 0
    mov dword ptr [rbx + ED_anchor], 0
    mov dword ptr [rbx + ED_goal_col], 0
    mov dword ptr [rbx + ED_scroll], 0
    and dword ptr [rbx + ED_flags], 0xfffffffd
    xor eax, eax
    EPILOGUE

# editor_set_prompt(e, cstr)
FN editor_set_prompt
    mov [rdi + ED_prompt], rsi
    xor eax, eax
    ret

# editor_prompt(e) -> cstr
FN editor_prompt
    mov rax, [rdi + ED_prompt]
    ret

# editor_set_ascii(e, esi flag)
FN editor_set_ascii
    mov eax, [rdi + ED_flags]
    and eax, 0xfffffffe
    test esi, esi
    jz 1f
    or eax, EF_ASCII
1:  mov [rdi + ED_flags], eax
    xor eax, eax
    ret

# .Lec_prefix(rdi=cand, rsi=needle, edx=nlen) -> eax 1 if cand starts with
# needle, case-insensitively.  A zero nlen is a prefix of everything.
.Lec_prefix:
    xor ecx, ecx
1:  cmp ecx, edx
    jae .Lpf_yes
    movzx eax, byte ptr [rdi + rcx]
    test eax, eax
    jz .Lpf_no
    movzx r8d, byte ptr [rsi + rcx]
    cmp eax, 'A'
    jb 2f
    cmp eax, 'Z'
    ja 2f
    add eax, 32
2:  cmp r8d, 'A'
    jb 3f
    cmp r8d, 'Z'
    ja 3f
    add r8d, 32
3:  cmp eax, r8d
    jne .Lpf_no
    inc ecx
    jmp 1b
.Lpf_yes:
    mov eax, 1
    ret
.Lpf_no:
    xor eax, eax
    ret

# .Lec_subseq(rdi=cand, rsi=needle) -> eax 1 when needle is a subsequence of
# cand, lowercasing the candidate bytes only.
.Lec_subseq:
    xor ecx, ecx
    xor r8d, r8d
1:  movzx eax, byte ptr [rdi + rcx]
    test eax, eax
    jz .Lsq_end
    cmp eax, 'A'
    jb 2f
    cmp eax, 'Z'
    ja 2f
    add eax, 32
2:  movzx r9d, byte ptr [rsi + r8]
    cmp r9d, eax
    jne 3f
    inc r8d
    cmp byte ptr [rsi + r8], 0
    je .Lsq_yes
3:  inc ecx
    jmp 1b
.Lsq_end:
    cmp byte ptr [rsi + r8], 0
    je .Lsq_yes
    xor eax, eax
    ret
.Lsq_yes:
    mov eax, 1
    ret

# editor_complete(e, dir) -> eax 0.  @file completion.
FN editor_complete
    PROLOGUE 13152
    mov rbx, rdi
    mov r13, rsi
    mov r12, [rbx + ED_text + SB_ptr]
    # clamp cur to len if a caller left it past the end
    mov eax, [rbx + ED_cur]
    mov ecx, [rbx + ED_text + SB_len]
    cmp eax, ecx
    jbe 1f
    mov eax, ecx
    mov [rbx + ED_cur], eax
1:  mov [rsp + EC_tok], eax
    # tok: walk back to the last space/tab/newline
.Lec_tokloop:
    mov ecx, [rsp + EC_tok]
    test ecx, ecx
    jz .Lec_tokdone
    movzx edx, byte ptr [r12 + rcx - 1]
    cmp edx, ' '
    je .Lec_tokdone
    cmp edx, 0x09
    je .Lec_tokdone
    cmp edx, 0x0a
    je .Lec_tokdone
    dec ecx
    mov [rsp + EC_tok], ecx
    jmp .Lec_tokloop
.Lec_tokdone:
    mov ecx, [rsp + EC_tok]
    cmp ecx, [rbx + ED_cur]
    jae .Lec_ret
    movzx edx, byte ptr [r12 + rcx]
    cmp edx, '@'
    jne .Lec_ret
    # name_start = tok + 1; slash = one past the last '/' before cur
    lea eax, [rcx + 1]
    mov [rsp + EC_name_start], eax
    mov r8d, -1
    mov ecx, eax
.Lec_slashloop:
    cmp ecx, [rbx + ED_cur]
    jae .Lec_slashdone
    cmp byte ptr [r12 + rcx], '/'
    jne 2f
    mov r8d, ecx
2:  inc ecx
    jmp .Lec_slashloop
.Lec_slashdone:
    mov edx, [rsp + EC_name_start]
    cmp r8d, -1
    je 3f
    lea edx, [r8 + 1]
3:  mov [rsp + EC_slash], edx
    # name_part = bytes [slash, cur), capped at 255
    mov ecx, [rbx + ED_cur]
    sub ecx, edx
    jns 4f
    xor ecx, ecx
4:  cmp ecx, 255
    jbe 5f
    mov ecx, 255
5:  mov [rsp + EC_nl], ecx
    lea rdi, [rsp + EC_namepart]
    mov rsi, r12
    mov eax, [rsp + EC_slash]
    add rsi, rax
    mov edx, ecx
    call memcpy
    mov ecx, [rsp + EC_nl]
    lea rdi, [rsp + EC_namepart]
    mov byte ptr [rdi + rcx], 0
    # resolve dir, defaulting to the cwd
    test r13, r13
    jnz .Lec_have_dir
    lea rdi, [rsp + EC_full]
    mov esi, 4096
    call os_getcwd
    test eax, eax
    jle .Lec_ret
    lea r13, [rsp + EC_full]
.Lec_have_dir:
    mov rdi, r13
    call strlen
    mov [rsp + EC_dllen], rax
    mov ecx, [rsp + EC_slash]
    sub ecx, [rsp + EC_name_start]
    mov [rsp + EC_pl], ecx
    # full = dir + '/' + [name_start, slash) ; bounds-check first
    mov rax, [rsp + EC_dllen]
    add rax, 1
    mov ecx, [rsp + EC_pl]
    add rax, rcx
    add rax, 1
    cmp rax, 4096
    jae .Lec_ret
    lea rdi, [rsp + EC_full]
    mov rsi, r13
    mov rdx, [rsp + EC_dllen]
    call memcpy
    mov rax, [rsp + EC_dllen]
    test rax, rax
    jz 6f
    lea rdi, [rsp + EC_full]
    cmp byte ptr [rdi + rax - 1], '/'
    je 6f
    mov byte ptr [rdi + rax], '/'
    inc rax
6:  mov [rsp + EC_fp], rax
    mov ecx, [rsp + EC_pl]
    test ecx, ecx
    jz 7f
    lea rdi, [rsp + EC_full]
    add rdi, rax
    mov rsi, r12
    mov eax, [rsp + EC_name_start]
    add rsi, rax
    mov edx, ecx
    call memcpy
    mov eax, [rsp + EC_pl]
    add [rsp + EC_fp], rax
7:  mov rax, [rsp + EC_fp]
    lea rdi, [rsp + EC_full]
    mov byte ptr [rdi + rax], 0
    # open the resolved directory
    lea rdi, [rsp + EC_full]
    mov esi, O_RDONLY | O_DIRECTORY
    xor edx, edx
    call os_open
    test eax, eax
    js .Lec_ret
    mov [rsp + EC_fd], eax
    mov dword ptr [rsp + EC_have], 0
    mov dword ptr [rsp + EC_bestscore], 3
    mov dword ptr [rsp + EC_bestdir], 0
    xor r14d, r14d
    xor r15d, r15d
.Lec_dloop:
    mov edi, [rsp + EC_fd]
    lea rsi, [rsp + EC_dbuf]
    mov edx, 8192
    call os_getdents
    test rax, rax
    js .Lec_dend
    jz .Lec_dend
    mov [rsp + EC_n], eax
    xor r15d, r15d
.Lec_rloop:
    mov eax, r15d
    cmp eax, [rsp + EC_n]
    jae .Lec_dloop
    lea rcx, [rsp + EC_dbuf]
    add rcx, rax
    movzx edx, word ptr [rcx + 16]
    mov [rsp + EC_reclen], edx
    test edx, edx
    jz .Lec_dend
    lea r9, [rcx + 19]
    cmp byte ptr [r9], '.'
    jne .Lec_check
    cmp byte ptr [r9 + 1], 0
    je .Lec_rnext
    cmp byte ptr [r9 + 1], '.'
    jne .Lec_check
    cmp byte ptr [r9 + 2], 0
    je .Lec_rnext
.Lec_check:
    mov [rsp + EC_nameptr], r9
    mov rdi, r9
    lea rsi, [rsp + EC_namepart]
    mov edx, [rsp + EC_nl]
    call .Lec_prefix
    test eax, eax
    jnz .Lec_prefix_yes
    cmp dword ptr [rsp + EC_nl], 0
    je .Lec_rnext
    mov rdi, [rsp + EC_nameptr]
    lea rsi, [rsp + EC_namepart]
    call .Lec_subseq
    test eax, eax
    jz .Lec_rnext
    mov dword ptr [rsp + EC_score], 1
    jmp .Lec_scored
.Lec_prefix_yes:
    mov dword ptr [rsp + EC_score], 0
.Lec_scored:
    cmp r14d, 512
    jae .Lec_rnext
    cmp dword ptr [rsp + EC_have], 0
    je .Lec_take
    mov eax, [rsp + EC_score]
    cmp eax, [rsp + EC_bestscore]
    jl .Lec_take
    jg .Lec_rnext
    mov rdi, [rsp + EC_nameptr]
    call strlen
    mov [rsp + EC_bl], eax
    lea rdi, [rsp + EC_best]
    call strlen
    mov ecx, [rsp + EC_bl]
    cmp rcx, rax
    jb .Lec_take
    ja .Lec_rnext
    mov rdi, [rsp + EC_nameptr]
    lea rsi, [rsp + EC_best]
    xor ecx, ecx
.Lec_lex:
    movzx eax, byte ptr [rdi + rcx]
    movzx edx, byte ptr [rsi + rcx]
    cmp eax, edx
    jb .Lec_take
    ja .Lec_rnext
    test eax, eax
    jz .Lec_rnext
    inc ecx
    jmp .Lec_lex
.Lec_take:
    mov rdi, [rsp + EC_nameptr]
    call strlen
    cmp rax, 511
    jbe 1f
    mov eax, 511
1:  mov [rsp + EC_bl], eax
    mov rdx, rax
    mov rsi, [rsp + EC_nameptr]
    lea rdi, [rsp + EC_best]
    call memcpy
    lea rdi, [rsp + EC_best]
    mov ecx, [rsp + EC_bl]
    mov byte ptr [rdi + rcx], 0
    mov eax, r15d
    lea rcx, [rsp + EC_dbuf]
    movzx edx, byte ptr [rcx + rax + 18]
    xor eax, eax
    cmp edx, 4
    sete al
    mov [rsp + EC_bestdir], eax
    mov eax, [rsp + EC_score]
    mov [rsp + EC_bestscore], eax
    mov dword ptr [rsp + EC_have], 1
.Lec_rnext:
    inc r14d
    mov eax, [rsp + EC_reclen]
    add r15d, eax
    cmp r14d, 512
    jae .Lec_dend
    jmp .Lec_rloop
.Lec_dend:
    mov edi, [rsp + EC_fd]
    call os_close
    cmp dword ptr [rsp + EC_have], 0
    je .Lec_ret
    # inslen = 1 + pl + bl + (dir ? 1 : 0)
    mov eax, [rbx + ED_cur]
    sub eax, [rsp + EC_tok]
    mov [rsp + EC_removed], eax
    mov ecx, [rsp + EC_slash]
    sub ecx, [rsp + EC_name_start]
    mov [rsp + EC_pl], ecx
    lea rdi, [rsp + EC_best]
    call strlen
    mov [rsp + EC_bl], eax
    mov eax, 1
    add eax, [rsp + EC_pl]
    add eax, [rsp + EC_bl]
    add eax, [rsp + EC_bestdir]
    mov [rsp + EC_inslen], eax
    mov ecx, [rbx + ED_text + SB_len]
    sub ecx, [rsp + EC_removed]
    add ecx, eax
    mov [rsp + EC_newlen], ecx
    mov eax, [rsp + EC_inslen]
    sub eax, [rsp + EC_removed]
    jbe 8f
    lea rdi, [rbx + ED_text]
    mov esi, eax
    call sb_reserve
8:  mov r12, [rbx + ED_text + SB_ptr]
    mov eax, [rbx + ED_cur]
    mov [rsp + EC_tail], eax
    # shift the tail right/left, then splice '@' + name_part + best + '/'
    mov rdi, r12
    mov ecx, [rsp + EC_tok]
    add rdi, rcx
    mov ecx, [rsp + EC_inslen]
    add rdi, rcx
    mov rsi, r12
    mov ecx, [rsp + EC_tail]
    add rsi, rcx
    mov edx, [rbx + ED_text + SB_len]
    sub edx, [rsp + EC_tail]
    call memmove
    mov r12, [rbx + ED_text + SB_ptr]
    mov ecx, [rsp + EC_tok]
    mov byte ptr [r12 + rcx], '@'
    mov ecx, [rsp + EC_bl]
    test ecx, ecx
    jz 9f
    mov rdi, r12
    mov eax, [rsp + EC_tok]
    add rdi, rax
    inc rdi
    mov eax, [rsp + EC_pl]
    add rdi, rax
    lea rsi, [rsp + EC_best]
    mov edx, ecx
    call memcpy
9:  cmp dword ptr [rsp + EC_bestdir], 0
    je 10f
    mov rdi, r12
    mov eax, [rsp + EC_tok]
    add rdi, rax
    inc rdi
    mov eax, [rsp + EC_pl]
    add rdi, rax
    mov eax, [rsp + EC_bl]
    add rdi, rax
    mov byte ptr [rdi], '/'
10: mov eax, [rsp + EC_newlen]
    mov [rbx + ED_text + SB_len], rax
    mov byte ptr [r12 + rax], 0
    mov eax, [rsp + EC_tok]
    add eax, [rsp + EC_inslen]
    mov [rbx + ED_cur], eax
    mov [rbx + ED_anchor], eax
    mov dword ptr [rbx + ED_goal_col], 0
.Lec_ret:
    xor eax, eax
    EPILOGUE

# editor_visual_rows(e, width) -> rax text rows + 2
FN editor_visual_rows
    PROLOGUE 0
    call .Lmeasure
    add eax, 2
    EPILOGUE

# editor_lines(e, width) -> rax rows, rdx cur row, rcx cur col
FN editor_lines
    PROLOGUE 0
    mov rbx, rdi
    mov [rbx + ED_width], esi
    call .Lmeasure
    EPILOGUE

# editor_history_add(e, ptr, len) -> 1 appended, 0 duplicate/empty
FN editor_history_add
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    test r12, r12
    jz .Lha_zero
    test r13, r13
    jz .Lha_zero
    mov rax, [rbx + ED_hist + VEC_len]
    test rax, rax
    jz .Lha_room
    dec rax
    mov rcx, [rbx + ED_hist + VEC_ptr]
    mov r14, [rcx + rax*8]
    mov rdi, r14
    call strlen
    cmp rax, r13
    jne .Lha_room
    mov rdi, r14
    mov rsi, r12
    mov rdx, r13
    call memeq
    test eax, eax
    jz .Lha_room
    xor eax, eax
    EPILOGUE
.Lha_room:
    mov rax, [rbx + ED_hist + VEC_len]
    cmp rax, HISTORY_MAX
    jb .Lha_push
    mov rcx, [rbx + ED_hist + VEC_ptr]
    mov rdi, [rcx]
    call mem_free
    mov rdi, [rbx + ED_hist + VEC_ptr]
    mov rsi, rdi
    add rsi, 8
    mov edx, (HISTORY_MAX - 1) * 8
    call memmove
    dec qword ptr [rbx + ED_hist + VEC_len]
.Lha_push:
    mov rdi, r12
    mov rsi, r13
    call mem_dup
    mov r14, rax
    lea rdi, [rbx + ED_hist]
    mov esi, 8
    call vec_push
    mov [rax], r14
    mov rax, [rbx + ED_hist + VEC_len]
    mov [rbx + ED_hist_pos], eax
    mov eax, 1
    EPILOGUE
.Lha_zero:
    xor eax, eax
    EPILOGUE

# editor_history_append(e, path|0, ptr, len) -> eax 1|0
FN editor_history_append
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    test r13, r13
    jz .Lhp_zero
    test r14, r14
    jz .Lhp_zero
    mov rdi, r13
    mov rsi, r14
    lea rdx, [rip + .Lnl]
    mov ecx, 1
    call str_find
    test eax, eax
    jns .Lhp_zero                # multi-line submissions are not persisted
    mov rdi, rbx
    mov rsi, r13
    mov rdx, r14
    call editor_history_add
    test r12, r12
    jz .Lhp_one
    mov rdi, r12
    mov esi, O_WRONLY | O_CREAT | O_APPEND
    mov edx, 0600
    call os_open
    test eax, eax
    js .Lhp_one
    mov r15d, eax
    mov edi, r15d
    mov rsi, r13
    mov rdx, r14
    call os_write
    mov edi, r15d
    lea rsi, [rip + .Lnl]
    mov edx, 1
    call os_write
    mov edi, r15d
    call os_close
.Lhp_one:
    mov eax, 1
    EPILOGUE
.Lhp_zero:
    xor eax, eax
    EPILOGUE

# editor_history_load(e, path)
# locals: 0..23 scratch SB, 24 start(8), 32 read buffer (4096)
.set LHL_start, 24
.set LHL_buf,   32
FN editor_history_load
    PROLOGUE 4128
    mov rbx, rdi
    mov r12, rsi
    test r12, r12
    jz .Lhl_done
    mov rdi, r12
    xor esi, esi
    xor edx, edx
    call os_open
    test eax, eax
    js .Lhl_done
    mov r13d, eax
    lea rdi, [rsp]
    call .Lsb_zero
.Lhl_read:
    mov rax, [rsp + SB_len]
    cmp rax, HISTORY_FILE_MAX
    ja .Lhl_abort
    mov edi, r13d
    lea rsi, [rsp + LHL_buf]
    mov edx, 4096
    call os_read
    test eax, eax
    jle .Lhl_read_done
    lea rdi, [rsp]
    lea rsi, [rsp + LHL_buf]
    mov edx, eax
    call sb_push
    jmp .Lhl_read
.Lhl_read_done:
    mov edi, r13d
    call os_close
    mov r14, [rsp + SB_ptr]
    mov r15, [rsp + SB_len]
    mov qword ptr [rsp + LHL_start], 0
    xor r13d, r13d
.Lhl_loop:
    cmp r13, r15
    ja .Lhl_lines_done
    cmp r13, r15
    je .Lhl_proc
    cmp byte ptr [r14 + r13], 0x0a
    jne .Lhl_next
.Lhl_proc:
    mov rsi, [rsp + LHL_start]
    mov rdx, r13
    sub rdx, rsi
    test rdx, rdx
    jz .Lhl_skip
    lea rax, [r14 + rsi]
    add rax, rdx
    cmp byte ptr [rax - 1], 0x0d
    jne .Lhl_nocr
    dec rdx
.Lhl_nocr:
    test rdx, rdx
    jz .Lhl_skip
    mov rax, [rbx + ED_hist + VEC_len]
    cmp rax, HISTORY_MAX
    jae .Lhl_skip
    lea rsi, [r14 + rsi]
    mov rdi, rbx
    call editor_history_add
.Lhl_skip:
    lea rsi, [r13 + 1]
    mov [rsp + LHL_start], rsi
    inc r13
    jmp .Lhl_loop
.Lhl_next:
    inc r13
    jmp .Lhl_loop
.Lhl_lines_done:
    mov rax, [rbx + ED_hist + VEC_len]
    mov [rbx + ED_hist_pos], eax
    lea rdi, [rsp]
    call sb_free
    EPILOGUE
.Lhl_abort:
    mov edi, r13d
    call os_close
    lea rdi, [rsp]
    call sb_free
.Lhl_done:
    EPILOGUE

# ---------------------------------------------------------------- paste
# editor_paste(e, ptr, len) -> eax 0
# locals: 0..23 norm SB, 24 lines, 32..55 exp SB, 56 body(8),
#         64..127 marker scratch
.set LEP_lines, 24
.set LEP_body,  56
.set LEP_mark,  64
FN editor_paste
    PROLOGUE 160
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    test r12, r12
    jz .Lep_done
    lea rdi, [rsp]
    call .Lsb_zero
    mov dword ptr [rsp + LEP_lines], 1
    xor r14d, r14d
.Lep_norm:
    cmp r14, r13
    jae .Lep_norm_done
    movzx eax, byte ptr [r12 + r14]
    cmp eax, 0x0d
    jne .Lep_plain
    lea rdi, [rsp]
    mov esi, 0x0a
    call sb_push_byte
    inc dword ptr [rsp + LEP_lines]
    lea rax, [r14 + 1]
    cmp rax, r13
    jae .Lep_cr_next
    cmp byte ptr [r12 + r14 + 1], 0x0a
    jne .Lep_cr_next
    inc r14
.Lep_cr_next:
    inc r14
    jmp .Lep_norm
.Lep_plain:
    mov r15d, eax
    lea rdi, [rsp]
    mov esi, eax
    call sb_push_byte
    cmp r15d, 0x0a
    jne .Lep_plain_next
    inc dword ptr [rsp + LEP_lines]
.Lep_plain_next:
    inc r14
    jmp .Lep_norm
.Lep_norm_done:
    lea rdi, [rsp + 32]
    call .Lsb_zero
    lea rdi, [rsp + 32]
    mov rsi, [rsp + SB_ptr]
    mov rdx, [rsp + SB_len]
    call .Lexpand_tabs
    mov eax, [rsp + LEP_lines]
    cmp eax, PASTE_LINE_LIMIT
    jle .Lep_insert
    # collapse: store the body and insert a marker
    mov rdi, [rsp + 32 + SB_ptr]
    mov rsi, [rsp + 32 + SB_len]
    call mem_dup
    mov [rsp + LEP_body], rax
    lea rdi, [rbx + ED_pastes]
    mov esi, 8
    call vec_push
    mov rcx, [rsp + LEP_body]
    mov [rax], rcx
    inc dword ptr [rbx + ED_paste_count]
    lea r14, [rsp + LEP_mark]
    lea rsi, [rip + .Lmarker]
    mov ecx, 14
    mov rdi, r14
    rep movsb
    add r14, 14
    mov esi, [rbx + ED_paste_count]
    mov rdi, r14
    call fmt_u64
    add r14, rax
    mov byte ptr [r14], ' '
    inc r14
    mov byte ptr [r14], '+'
    inc r14
    mov esi, [rsp + LEP_lines]
    mov rdi, r14
    call fmt_u64
    add r14, rax
    lea rsi, [rip + .Lmarker_tail]
    mov ecx, 7
    mov rdi, r14
    rep movsb
    lea rdx, [r14 + 7]
    lea rax, [rsp + LEP_mark]
    sub rdx, rax
    mov rdi, rbx
    lea rsi, [rsp + LEP_mark]
    call .Linsert_bytes
    jmp .Lep_cleanup
.Lep_insert:
    mov rdi, rbx
    mov rsi, [rsp + 32 + SB_ptr]
    mov rdx, [rsp + 32 + SB_len]
    call .Linsert_bytes
.Lep_cleanup:
    lea rdi, [rsp + 32]
    call sb_free
    lea rdi, [rsp]
    call sb_free
.Lep_done:
    xor eax, eax
    EPILOGUE

# editor_take(e) -> rax owned cstr (paste markers expanded, then clear)
# locals: 0..23 out SB, 24 j(8), 32 idx(4), 40 body(8)
.set LTK_j,   24
.set LTK_idx, 32
.set LTK_body,40
FN editor_take
    PROLOGUE 96
    mov rbx, rdi
    lea rdi, [rsp]
    call .Lsb_zero
    mov r12, [rbx + ED_text + SB_ptr]
    mov r13, [rbx + ED_text + SB_len]
    xor r14d, r14d
.Ltk_scan:
    cmp r14, r13
    jae .Ltk_done
    mov rax, r13
    sub rax, r14
    cmp rax, 14
    jbe .Ltk_emit
    cmp byte ptr [r12 + r14], '['
    jne .Ltk_emit
    lea rdi, [r12 + r14]
    lea rsi, [rip + .Lmarker]
    mov edx, 14
    call memeq
    test eax, eax
    jz .Ltk_emit
    lea r15, [r14 + 14]
    xor ecx, ecx
.Ltk_digits:
    cmp r15, r13
    jae .Ltk_emit
    movzx eax, byte ptr [r12 + r15]
    cmp eax, '0'
    jb .Ltk_digits_done
    cmp eax, '9'
    ja .Ltk_digits_done
    cmp ecx, (1 << 20)
    jae .Ltk_digit_skip
    imul ecx, ecx, 10
    sub eax, '0'
    add ecx, eax
.Ltk_digit_skip:
    inc r15
    jmp .Ltk_digits
.Ltk_digits_done:
    cmp r15, r13
    jae .Ltk_emit
    cmp byte ptr [r12 + r15], ' '
    jne .Ltk_emit
    test ecx, ecx
    jz .Ltk_emit
    mov rax, [rbx + ED_pastes + VEC_len]
    cmp rcx, rax
    ja .Ltk_emit
    mov [rsp + LTK_idx], ecx
.Ltk_findend:
    cmp r15, r13
    jae .Ltk_emit
    cmp byte ptr [r12 + r15], ']'
    je .Ltk_expand
    inc r15
    jmp .Ltk_findend
.Ltk_expand:
    mov [rsp + LTK_j], r15
    mov ecx, [rsp + LTK_idx]
    mov rax, [rbx + ED_pastes + VEC_ptr]
    mov rdi, [rax + rcx*8 - 8]
    mov [rsp + LTK_body], rdi
    call strlen
    lea rdi, [rsp]
    mov rsi, [rsp + LTK_body]
    mov rdx, rax
    call sb_push
    mov r14, [rsp + LTK_j]
    inc r14
    jmp .Ltk_scan
.Ltk_emit:
    lea rdi, [rsp]
    movzx esi, byte ptr [r12 + r14]
    call sb_push_byte
    inc r14
    jmp .Ltk_scan
.Ltk_done:
    mov rdi, rbx
    call editor_clear
    mov rax, [rsp + SB_ptr]
    test rax, rax
    jnz .Ltk_ret
    lea rdi, [rip + .Lempty]
    xor esi, esi
    call mem_dup
.Ltk_ret:
    EPILOGUE

# ---------------------------------------------------------------- keymap
# editor_key(e, key, cp, mods) -> eax 1 submit | 0
FN editor_key
    PROLOGUE 0
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    cmp r12d, K_BACKSPACE
    je .Lek_bs
    cmp r12d, K_DEL
    je .Lek_del
    cmp r12d, K_ENTER
    je .Lek_enter
    cmp r12d, K_TAB
    je .Lek_tab
    cmp r12d, K_LEFT
    je .Lek_left
    cmp r12d, K_RIGHT
    je .Lek_right
    cmp r12d, K_UP
    je .Lek_up
    cmp r12d, K_DOWN
    je .Lek_down
    cmp r12d, K_HOME
    je .Lek_home
    cmp r12d, K_END
    je .Lek_end
    cmp r12d, K_PASTE
    je .Lek_ret0
    test r14d, MOD_CTRL
    jnz .Lek_ctrl
    test r14d, MOD_ALT
    jnz .Lek_alt
    cmp r12d, r13d
    jne .Lek_ret0
    cmp r13d, 0x20
    jb .Lek_ret0
    cmp r13d, 0x110000
    jae .Lek_ret0
    mov rdi, rbx
    mov esi, r13d
    call .Linsert_cp
    jmp .Lek_ret0
.Lek_ctrl:
    mov edi, r12d
    call .Lebase
    test eax, eax
    jnz 1f
    mov edi, r13d
    call .Lebase
1:  test eax, eax
    jz .Lek_ret0
    cmp eax, 'a'
    je .Lek_ctrl_a
    cmp eax, 'b'
    je .Lek_ctrl_b
    cmp eax, 'd'
    je .Lek_ctrl_d
    cmp eax, 'e'
    je .Lek_ctrl_e
    cmp eax, 'f'
    je .Lek_ctrl_f
    cmp eax, 'k'
    je .Lek_ctrl_k
    cmp eax, 't'
    je .Lek_ctrl_t
    cmp eax, 'u'
    je .Lek_ctrl_u
    cmp eax, 'w'
    je .Lek_ctrl_w
    cmp eax, 'y'
    je .Lek_ctrl_y
    jmp .Lek_ret0
.Lek_alt:
    cmp r12d, r13d
    jne .Lek_ret0
    cmp r13d, 'b'
    je .Lek_alt_b
    cmp r13d, 'f'
    je .Lek_alt_f
    cmp r13d, 'd'
    je .Lek_alt_d
    cmp r13d, 8
    je .Lek_alt_bs
    cmp r13d, 127
    je .Lek_alt_bs
    cmp r13d, 0x20
    jb .Lek_ret0
    cmp r13d, 0x110000
    jae .Lek_ret0
    mov rdi, rbx
    mov esi, r13d
    call .Linsert_cp
    jmp .Lek_ret0
.Lek_ctrl_a:
    mov rdi, rbx
    xor esi, esi
    mov edx, r14d
    call .Lmove_home
    jmp .Lek_ret0
.Lek_ctrl_e:
    mov rdi, rbx
    xor esi, esi
    mov edx, r14d
    call .Lmove_end
    jmp .Lek_ret0
.Lek_ctrl_b:
    mov rdi, rbx
    mov esi, r14d
    call .Lmove_left
    jmp .Lek_ret0
.Lek_ctrl_f:
    mov rdi, rbx
    mov esi, r14d
    call .Lmove_right
    jmp .Lek_ret0
.Lek_ctrl_d:
    mov rdi, rbx
    call .Ldelete_forward
    jmp .Lek_ret0
.Lek_ctrl_k:
    mov rdi, rbx
    call .Lkill_to_end
    jmp .Lek_ret0
.Lek_ctrl_t:
    mov rdi, rbx
    call .Ltranspose
    jmp .Lek_ret0
.Lek_ctrl_u:
    mov rdi, rbx
    call .Lkill_to_start
    jmp .Lek_ret0
.Lek_ctrl_w:
    mov rdi, rbx
    call .Lkill_word
    jmp .Lek_ret0
.Lek_ctrl_y:
    mov rdi, rbx
    call .Lyank
    jmp .Lek_ret0
.Lek_alt_b:
    mov rdi, rbx
    call .Lword_left
    jmp .Lek_ret0
.Lek_alt_f:
    mov rdi, rbx
    call .Lword_right
    jmp .Lek_ret0
.Lek_alt_d:
    mov rdi, rbx
    call .Lkill_word_forward
    jmp .Lek_ret0
.Lek_alt_bs:
    mov rdi, rbx
    call .Lkill_word
    jmp .Lek_ret0
.Lek_bs:
    test r14d, MOD_ALT
    jz 1f
    mov rdi, rbx
    call .Lkill_word
    jmp .Lek_ret0
1:  mov eax, [rbx + ED_cur]
    mov ecx, [rbx + ED_anchor]
    cmp eax, ecx
    je 2f
    mov esi, eax
    mov edx, ecx
    cmp esi, edx
    jbe 3f
    xchg esi, edx
3:  mov rdi, rbx
    call .Ldelete
    jmp .Lek_ret0
2:  test eax, eax
    jz .Lek_ret0
    mov rdi, rbx
    mov esi, eax
    call .Lprev_cp
    mov esi, eax
    mov edx, [rbx + ED_cur]
    mov rdi, rbx
    call .Ldelete
    jmp .Lek_ret0
.Lek_del:
    test r14d, MOD_CTRL
    jz 1f
    mov rdi, rbx
    call .Lkill_word_forward
    jmp .Lek_ret0
1:  mov rdi, rbx
    call .Ldelete_forward
    jmp .Lek_ret0
.Lek_enter:
    test r14d, MOD_ALT
    jz .Lek_submit
    mov rdi, rbx
    mov esi, 0x0a
    call .Linsert_cp
    jmp .Lek_ret0
.Lek_submit:
    mov eax, 1
    EPILOGUE
.Lek_tab:
    mov rdi, rbx
    xor esi, esi
    call editor_complete
    jmp .Lek_ret0
.Lek_left:
    mov rdi, rbx
    test r14d, MOD_ALT | MOD_CTRL
    jz 1f
    call .Lword_left
    jmp .Lek_ret0
1:  mov esi, r14d
    call .Lmove_left
    jmp .Lek_ret0
.Lek_right:
    mov rdi, rbx
    test r14d, MOD_ALT | MOD_CTRL
    jz 1f
    call .Lword_right
    jmp .Lek_ret0
1:  mov esi, r14d
    call .Lmove_right
    jmp .Lek_ret0
.Lek_up:
    mov rdi, rbx
    mov esi, -1
    mov edx, r14d
    call .Lek_hist_or_vert
    jmp .Lek_ret0
.Lek_down:
    mov rdi, rbx
    mov esi, 1
    mov edx, r14d
    call .Lek_hist_or_vert
    jmp .Lek_ret0
.Lek_home:
    xor esi, esi
    test r14d, MOD_CTRL
    jz 1f
    mov esi, 1
1:  mov rdi, rbx
    mov edx, r14d
    call .Lmove_home
    jmp .Lek_ret0
.Lek_end:
    xor esi, esi
    test r14d, MOD_CTRL
    jz 1f
    mov esi, 1
1:  mov rdi, rbx
    mov edx, r14d
    call .Lmove_end
    jmp .Lek_ret0
.Lek_ret0:
    xor eax, eax
    EPILOGUE

# .Lek_hist_or_vert(rdi=e, esi=dir, edx=mods): browse when the buffer has no
# newline and history exists, else move vertically.
.Lek_hist_or_vert:
    PROLOGUE 0
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov rax, [rbx + ED_hist + VEC_len]
    test rax, rax
    jz .Lhv_vert
    mov r8, [rbx + ED_text + SB_ptr]
    mov r9, [rbx + ED_text + SB_len]
    xor ecx, ecx
1:  cmp rcx, r9
    jae .Lhv_hist
    cmp byte ptr [r8 + rcx], 0x0a
    je .Lhv_vert
    inc rcx
    jmp 1b
.Lhv_hist:
    mov rdi, rbx
    mov esi, r12d
    call .Lhistory_browse
    EPILOGUE
.Lhv_vert:
    mov rdi, rbx
    mov esi, r12d
    mov edx, r13d
    call .Lmove_vertical
    EPILOGUE

# ---------------------------------------------------------------- renderer
# editor_render(e, grid, x, y, w, h,
#   [rbp+16]=bg, [rbp+24]=muted, [rbp+32]=cursor_visible,
#   [rbp+40]=placeholder) -> rax=cursor_x, rdx=cursor_y
# Composer geometry: full-width rules, the last column reserved for the caret,
# display-width wrapping and internal scroll.  Text fg is fixed at 0xFFE6E6E6.
# Returns (-1,-1) when the caret is hidden.

# .Ler_rule(edx=y): one full-width dim rule (U+2500, or '-' in ascii mode).
.Ler_rule:
    sub rsp, 8
    mov [rbp + ER_ruley], edx
    mov dword ptr [rbp + ER_rulei], 0
    mov eax, 0x2500
    test dword ptr [rbx + ED_flags], EF_ASCII
    jz 1f
    mov eax, 0x2D
1:  mov [rbp + ER_rulecp], eax
.Ler_rule_loop:
    mov eax, [rbp + ER_rulei]
    cmp eax, r15d
    jae .Ler_rule_done
    mov rdi, r12
    mov esi, r13d
    add esi, eax
    mov edx, [rbp + ER_ruley]
    mov ecx, [rbp + ER_rulecp]
    mov r8d, [rbp + ER_muted]
    mov r9d, [rbp + ER_bg]
    sub rsp, 16
    mov qword ptr [rsp], ED_A_DIM
    call grid_put
    add rsp, 16
    inc dword ptr [rbp + ER_rulei]
    jmp .Ler_rule_loop
.Ler_rule_done:
    add rsp, 8
    ret

# .Ler_caret_cell(edi=x, esi=y, edx=bg): reverse the cell under the caret,
# materialising a space only when the cell is empty so the empty-state
# placeholder keeps its glyph and dim styling.
.Ler_caret_cell:
    test edi, edi
    js .Lcc_ret
    test esi, esi
    js .Lcc_ret
    mov eax, [r12 + ED_G_w]
    cmp edi, eax
    jae .Lcc_ret
    mov eax, [r12 + ED_G_h]
    cmp esi, eax
    jae .Lcc_ret
    mov eax, [r12 + ED_G_w]
    mov r8d, esi
    imul r8, rax
    mov eax, edi
    add r8, rax
    imul r8, r8, ED_CELL_SIZE
    add r8, [r12 + ED_G_cells]
    mov eax, [r8 + ED_C_cp]
    test eax, eax
    jnz .Lcc_pres
    mov dword ptr [r8 + ED_C_cp], 0x20
    mov dword ptr [r8 + ED_C_comb], 0
    mov eax, [rbp + ER_fg]
    mov [r8 + ED_C_fg], eax
    mov [r8 + ED_C_bg], edx
    mov word ptr [r8 + ED_C_attrs], ED_A_REVERSE
    mov word ptr [r8 + ED_C_attrs + 2], 0
    ret
.Lcc_pres:
    or word ptr [r8 + ED_C_attrs], ED_A_REVERSE
.Lcc_ret:
    ret

FN editor_render
    PROLOGUE 256
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov r14d, ecx
    mov r15d, r8d
    mov [rbp + ER_h], r9d
    mov eax, [rbp + 16]
    mov [rbp + ER_bg], eax
    mov eax, [rbp + 24]
    mov [rbp + ER_muted], eax
    mov eax, [rbp + 32]
    mov [rbp + ER_curvis], eax
    mov rax, [rbp + 40]
    mov [rbp + ER_ph], rax
    mov esi, TH_FG
    call theme_rgb
    mov [rbp + ER_fg], eax
    mov [rbp + ER_x], r13d
    mov [rbp + ER_y], r14d
    mov [rbp + ER_w], r15d
    mov dword ptr [rbp + ER_curset], 0
    test r15d, r15d
    jz .Ler_hidden
    cmp dword ptr [rbp + ER_h], 0
    je .Ler_hidden
    mov [rbx + ED_width], r15d
    # inner = max(w - 1, 1); the last column is reserved for the caret
    mov eax, r15d
    dec eax
    cmp eax, 1
    jge 1f
    mov eax, 1
1:  mov [rbp + ER_inner], eax
    # h = max(h, 1); top = h >= 3 ; bottom = h >= 2
    mov eax, [rbp + ER_h]
    cmp eax, 1
    jge 2f
    mov eax, 1
2:  mov [rbp + ER_h], eax
    xor ecx, ecx
    cmp eax, 3
    setge cl
    mov [rbp + ER_top], ecx
    xor edx, edx
    cmp eax, 2
    setge dl
    mov [rbp + ER_bottom], edx
    # input_h = max(h - top - bottom, 1) ; input_y = y + top
    mov eax, [rbp + ER_h]
    sub eax, ecx
    sub eax, edx
    cmp eax, 1
    jge 3f
    mov eax, 1
3:  mov [rbp + ER_inph], eax
    mov eax, r14d
    add eax, [rbp + ER_top]
    mov [rbp + ER_inpy], eax
    # rules
    cmp dword ptr [rbp + ER_top], 0
    je .Ler_no_top
    mov edx, r14d
    call .Ler_rule
.Ler_no_top:
    cmp dword ptr [rbp + ER_bottom], 0
    je .Ler_no_bottom
    mov edx, [rbp + ER_inpy]
    add edx, [rbp + ER_inph]
    call .Ler_rule
.Ler_no_bottom:
    # placeholder on the first input row, clipped, before the caret pass
    mov rax, [rbp + ER_ph]
    test rax, rax
    jz .Ler_no_ph
    cmp qword ptr [rbx + ED_text + SB_len], 0
    jne .Ler_no_ph
    cmp byte ptr [rax], 0
    je .Ler_no_ph
    mov [rbp + ER_phptr], rax
    mov rdi, rax
    call strlen
    mov [rbp + ER_phlen], rax
    mov dword ptr [rbp + ER_phcol], 0
.Ler_ph_loop:
    cmp qword ptr [rbp + ER_phlen], 0
    jle .Ler_no_ph
    mov rdi, [rbp + ER_phptr]
    mov rsi, [rbp + ER_phlen]
    call utf8_decode
    mov [rbp + ER_k], rdx
    mov [rbp + ER_cp], eax
    mov edi, eax
    call utf8_wcwidth
    mov [rbp + ER_cw], eax
    mov ecx, [rbp + ER_phcol]
    add ecx, eax
    cmp ecx, [rbp + ER_inner]
    jg .Ler_no_ph
    mov rdi, r12
    mov esi, r13d
    add esi, [rbp + ER_phcol]
    mov edx, [rbp + ER_inpy]
    mov ecx, [rbp + ER_cp]
    mov r8d, [rbp + ER_muted]
    mov r9d, [rbp + ER_bg]
    sub rsp, 16
    mov qword ptr [rsp], ED_A_DIM
    call grid_put
    add rsp, 16
    mov eax, [rbp + ER_cw]
    add [rbp + ER_phcol], eax
    mov rdx, [rbp + ER_k]
    add [rbp + ER_phptr], rdx
    sub [rbp + ER_phlen], rdx
    jmp .Ler_ph_loop
.Ler_no_ph:
    # caret row / total text rows
    mov rdi, rbx
    mov esi, r15d
    call .Lmeasure
    mov [rbp + ER_total], eax
    mov [rbp + ER_currow], edx
    mov [rbp + ER_curcol], ecx
    # start = cur_row >= input_h ? cur_row - input_h + 1 : 0
    xor eax, eax
    mov ecx, [rbp + ER_currow]
    cmp ecx, [rbp + ER_inph]
    jl 4f
    mov eax, ecx
    sub eax, [rbp + ER_inph]
    inc eax
4:  mov [rbp + ER_start], eax
    mov [rbx + ED_scroll], eax
    # draw the visible text rows
    mov dword ptr [rbp + ER_row], 0
    mov dword ptr [rbp + ER_col], 0
    mov qword ptr [rbp + ER_pos], 0
.Ler_draw_loop:
    mov r10, [rbp + ER_pos]
    mov rcx, [rbx + ED_text + SB_len]
    cmp r10, rcx
    jae .Ler_after_loop
    mov rdi, [rbx + ED_text + SB_ptr]
    add rdi, r10
    mov rsi, rcx
    sub rsi, r10
    call utf8_decode
    mov [rbp + ER_k], rdx
    mov [rbp + ER_cp], eax
    cmp eax, 0x0a
    je .Ler_cw0
    mov edi, eax
    call utf8_wcwidth
    jmp .Ler_cw1
.Ler_cw0:
    xor eax, eax
.Ler_cw1:
    mov [rbp + ER_cw], eax
    # wrap first, then place
    mov ecx, [rbp + ER_col]
    add ecx, eax
    cmp ecx, [rbp + ER_inner]
    jle .Ler_dl_nowrap
    inc dword ptr [rbp + ER_row]
    mov dword ptr [rbp + ER_col], 0
.Ler_dl_nowrap:
    mov r10, [rbp + ER_pos]
    mov r11d, [rbx + ED_cur]
    xor eax, eax
    cmp r10d, r11d
    sete al
    mov [rbp + ER_atc], eax
    # visible?
    mov eax, [rbp + ER_row]
    cmp eax, [rbp + ER_start]
    jl .Ler_dl_adv
    mov ecx, [rbp + ER_start]
    add ecx, [rbp + ER_inph]
    cmp eax, ecx
    jge .Ler_dl_adv
    sub eax, [rbp + ER_start]
    add eax, [rbp + ER_inpy]
    mov [rbp + ER_yy], eax
    # caret column (a zero-width mark points at the previous cell)
    mov ecx, [rbp + ER_col]
    cmp dword ptr [rbp + ER_atc], 0
    je .Ler_dl_cc
    cmp dword ptr [rbp + ER_cw], 0
    jne .Ler_dl_cc
    test ecx, ecx
    jz .Ler_dl_cc
    cmp dword ptr [rbp + ER_cp], 0x0a
    je .Ler_dl_cc
    dec ecx
.Ler_dl_cc:
    mov [rbp + ER_caretcol], ecx
    cmp dword ptr [rbp + ER_atc], 0
    je .Ler_dl_draw
    mov eax, r13d
    add eax, [rbp + ER_caretcol]
    mov [rbp + ER_cx], eax
    mov eax, [rbp + ER_yy]
    mov [rbp + ER_cy], eax
    mov dword ptr [rbp + ER_curset], 1
.Ler_dl_draw:
    cmp dword ptr [rbp + ER_cp], 0x0a
    je .Ler_dl_nl
    mov rdi, r12
    mov esi, r13d
    add esi, [rbp + ER_col]
    mov edx, [rbp + ER_yy]
    mov ecx, [rbp + ER_cp]
    mov r8d, [rbp + ER_fg]
    mov r9d, [rbp + ER_bg]
    xor r10d, r10d
    cmp dword ptr [rbp + ER_atc], 0
    je .Ler_dl_put
    mov r10d, ED_A_REVERSE
.Ler_dl_put:
    sub rsp, 16
    mov [rsp], r10
    call grid_put
    add rsp, 16
    jmp .Ler_dl_adv
.Ler_dl_nl:
    cmp dword ptr [rbp + ER_atc], 0
    je .Ler_dl_adv
    mov edi, r13d
    add edi, [rbp + ER_col]
    mov esi, [rbp + ER_yy]
    mov edx, [rbp + ER_bg]
    call .Ler_caret_cell
.Ler_dl_adv:
    mov rdx, [rbp + ER_k]
    add [rbp + ER_pos], rdx
    cmp dword ptr [rbp + ER_cp], 0x0a
    jne .Ler_dl_coladv
    inc dword ptr [rbp + ER_row]
    mov dword ptr [rbp + ER_col], 0
    jmp .Ler_draw_loop
.Ler_dl_coladv:
    mov eax, [rbp + ER_cw]
    add [rbp + ER_col], eax
    jmp .Ler_draw_loop
.Ler_after_loop:
    # caret past the last character
    mov eax, [rbx + ED_cur]
    cmp eax, [rbx + ED_text + SB_len]
    jl .Ler_finalize
    mov eax, [rbp + ER_row]
    cmp eax, [rbp + ER_start]
    jl .Ler_finalize
    mov ecx, [rbp + ER_start]
    add ecx, [rbp + ER_inph]
    cmp eax, ecx
    jge .Ler_finalize
    mov eax, r13d
    add eax, [rbp + ER_col]
    mov [rbp + ER_cx], eax
    mov eax, [rbp + ER_row]
    sub eax, [rbp + ER_start]
    add eax, [rbp + ER_inpy]
    mov [rbp + ER_cy], eax
    mov edi, [rbp + ER_cx]
    mov esi, [rbp + ER_cy]
    mov edx, [rbp + ER_bg]
    call .Ler_caret_cell
    mov dword ptr [rbp + ER_curset], 1
.Ler_finalize:
    cmp dword ptr [rbp + ER_curvis], 0
    je .Ler_hidden
    cmp dword ptr [rbp + ER_curset], 0
    je .Ler_hidden
    mov eax, [rbp + ER_cx]
    mov edx, [rbp + ER_cy]
    EPILOGUE
.Ler_hidden:
    mov eax, -1
    mov edx, -1
    EPILOGUE
