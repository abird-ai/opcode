.include "opcode.inc"
.include "core/core.inc"
.include "tui/markdown.inc"
.include "tui/theme.inc"
# opcode tui: streaming markdown block model and renderer (S6).
#
# The public API is documented in src/tui/API.md.  Text is appended
# incrementally; md_append re-parses only the trailing incomplete block so
# completed blocks keep their wrapped rows, and md_set_width re-renders all of
# them once per resize/theme change.  Inline styles are stored as one style
# tag per text byte (markdown.inc); md_emit_view maps tags to the view palette
# (extended with VS_MD_ACCENT/VS_MD_THINK) and md_emit_ansi to SGR runs.
#
# Depends on view.s's utf8dec/view_wcwidth and theme.s's theme_emit_fg.

.equ VST_DIM,  2            # VS_DIM  -> TH_MUTED
.equ VST_CODE, 11           # VS_CODE -> TH_CODE

# Wrap accumulator passed to the wrapper helpers (a stack struct).
.equ WR_b,      0
.equ WR_width,  8
.equ WR_col,    12
.equ WR_indent, 16
.equ WR_row,    24
.equ WR_pend,   32
.equ WR_SIZE,   40

.section .rodata
.Lspaces:   .ascii "                                "
.Ldash:     .ascii "- "
.Lquote:    .ascii "> "
.Lsgr0:     .ascii "\033[0m"
.Lsgrbold:  .ascii "\033[1m"
.Lsgrdim:   .ascii "\033[2m"
.Lsgrital:  .ascii "\033[3m"
.Lnl:       .ascii "\n"

.text

# ------------------------------------------------------------------ helpers

# mdx_line_end(rdi=s, rsi=len, rdx=i) -> rax: index of '\n' or len (leaf)
mdx_line_end:
    mov rax, rdx
1:  cmp rax, rsi
    jae 2f
    cmp byte ptr [rdi + rax], 10
    je 2f
    inc rax
    jmp 1b
2:  ret

# mdx_line_is_blank(rdi=s, rsi=len, rdx=i) -> eax 1 iff the rest of the line
# is whitespace and is terminated by a real '\n' (buffer end is not blank).
mdx_line_is_blank:
    mov rcx, rdx
1:  cmp rcx, rsi
    jae 2f
    movzx eax, byte ptr [rdi + rcx]
    cmp al, ' '
    je 3f
    cmp al, 9
    je 3f
    cmp al, 13
    je 3f
    cmp al, 10
    je 4f
    jmp 2f
3:  inc rcx
    jmp 1b
4:  mov eax, 1
    ret
2:  xor eax, eax
    ret

# mdx_fence_start(rdi=s, rsi=len, rdx=i) -> eax 1 for >=3 ``` or ~~~ (leaf)
mdx_fence_start:
    lea rcx, [rdx + 2]
    cmp rcx, rsi
    jae .Lfs_no
    movzx eax, byte ptr [rdi + rdx]
    cmp al, '`'
    je .Lfs_yes
    cmp al, '~'
    jne .Lfs_no
.Lfs_yes:
    cmp byte ptr [rdi + rdx + 1], al
    jne .Lfs_no
    cmp byte ptr [rdi + rdx + 2], al
    jne .Lfs_no
    mov eax, 1
    ret
.Lfs_no:
    xor eax, eax
    ret

# mdx_fence_close(rdi=s, rsi=len, rdx=i, ecx=ch) -> eax 1 (leaf)
mdx_fence_close:
    lea r8, [rdx + 2]
    cmp r8, rsi
    jae .Lfc_no
    cmp byte ptr [rdi + rdx], cl
    jne .Lfc_no
    cmp byte ptr [rdi + rdx + 1], cl
    jne .Lfc_no
    cmp byte ptr [rdi + rdx + 2], cl
    jne .Lfc_no
    mov eax, 1
    ret
.Lfc_no:
    xor eax, eax
    ret

# mdx_is_rule(rdi=s, rsi=len, rdx=i) -> eax 1 for a line of >=3 -,* or _
mdx_is_rule:
    lea rax, [rdx + 2]
    cmp rax, rsi
    jae .Lir_no
    movzx eax, byte ptr [rdi + rdx]
    cmp al, '-'
    je .Lir_go
    cmp al, '*'
    je .Lir_go
    cmp al, '_'
    jne .Lir_no
.Lir_go:
    mov rcx, rdx
    add rcx, 1
.Lir_loop:
    cmp rcx, rsi
    jae .Lir_no
    cmp byte ptr [rdi + rcx], 10
    je .Lir_end
    cmp byte ptr [rdi + rcx], al
    jne .Lir_no
    inc rcx
    jmp .Lir_loop
.Lir_end:
    sub rcx, rdx
    cmp rcx, 3
    jb .Lir_no
    mov eax, 1
    ret
.Lir_no:
    xor eax, eax
    ret

# mdx_bullet_ls(rdi=s, rsi=end, rdx=i) -> rax: content start after "- "/"* "/"+ "
# or rdx when the line is not a bullet (leading blanks are skipped).
mdx_bullet_ls:
    mov rcx, rdx
1:  cmp rcx, rsi
    jae .Lbl_no
    movzx eax, byte ptr [rdi + rcx]
    cmp al, ' '
    je 2f
    cmp al, 9
    je 2f
    jmp .Lbl_chk
2:  inc rcx
    jmp 1b
.Lbl_chk:
    lea r8, [rcx + 1]
    cmp r8, rsi
    jae .Lbl_no
    movzx eax, byte ptr [rdi + rcx]
    cmp al, '-'
    je .Lbl_yes
    cmp al, '*'
    je .Lbl_yes
    cmp al, '+'
    jne .Lbl_no
.Lbl_yes:
    cmp byte ptr [rdi + rcx + 1], ' '
    jne .Lbl_no
    lea rax, [rcx + 2]
    ret
.Lbl_no:
    mov rax, rdx
    ret

# mdx_line_starts_block(rdi=s, rsi=len, rdx=i) -> eax (leaf-ish)
mdx_line_starts_block:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    cmp byte ptr [rbx + r13], '#'
    je .Lsb_yes
    cmp byte ptr [rbx + r13], '>'
    je .Lsb_yes
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call mdx_fence_start
    test eax, eax
    jnz .Lsb_yes
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call mdx_is_rule
    test eax, eax
    jnz .Lsb_yes
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call mdx_bullet_ls
    cmp rax, r13
    jne .Lsb_yes
    xor eax, eax
    EPILOGUE
.Lsb_yes:
    mov eax, 1
    EPILOGUE

# mdx_para_end(rdi=s, rsi=len, rdx=i) -> rax=end, rdx=complete
mdx_para_end:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx                # q
.Lpe_loop:
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call mdx_line_end
    mov r14, rax                # qe
    cmp r14, r12
    jae .Lpe_incomplete
    lea r15, [r14 + 1]
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r15
    call mdx_line_is_blank
    test eax, eax
    jnz .Lpe_complete
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r15
    call mdx_line_starts_block
    test eax, eax
    jnz .Lpe_complete
    mov r13, r15
    jmp .Lpe_loop
.Lpe_incomplete:
    mov rax, r14
    xor edx, edx
    EPILOGUE
.Lpe_complete:
    lea rax, [r14 + 1]
    mov edx, 1
    EPILOGUE

# mdx_find_code_end(rdi=s, rsi=len, rdx=start) -> rax=end, rdx=complete
mdx_find_code_end:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    movzx r14d, byte ptr [rbx + r13]   # fence char
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call mdx_line_end
    cmp rax, r12
    jae .Lfce_atend
    lea r15, [rax + 1]
    jmp .Lfce_scan
.Lfce_atend:
    mov r15, r12
.Lfce_scan:
    cmp r15, r12
    ja .Lfce_noclose
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r15
    call mdx_line_end
    mov r10, rax
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r15
    mov ecx, r14d
    call mdx_fence_close
    test eax, eax
    jnz .Lfce_close
    cmp r10, r12
    jae .Lfce_noclose
    lea r15, [r10 + 1]
    jmp .Lfce_scan
.Lfce_close:
    cmp r10, r12
    jae .Lfce_close_end
    lea rax, [r10 + 1]
    mov edx, 1
    EPILOGUE
.Lfce_close_end:
    mov rax, r10
    mov edx, 1
    EPILOGUE
.Lfce_noclose:
    mov rax, r12
    xor edx, edx
    EPILOGUE

# ------------------------------------------------------------------ rows

# mdx_row_put(rdi=row, rsi=ptr, rdx=len, ecx=tag): text + parallel style bytes
mdx_row_put:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14d, ecx
    test r13, r13
    jz 2f
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call sb_push
    xor r15d, r15d
1:  cmp r15, r13
    jae 2f
    lea rdi, [rbx + MR_style]
    mov esi, r14d
    call sb_push_byte
    inc r15
    jmp 1b
2:  EPILOGUE

# mdx_new_row(rdi=block) -> rax zeroed row*
mdx_new_row:
    PROLOGUE 0
    mov rbx, rdi
    lea rdi, [rbx + MB_rows]
    mov esi, MR_SIZE
    call vec_push
    EPILOGUE

# mdx_block_free_rows(rdi=block): free row SBs and the rows VEC backing.
mdx_block_free_rows:
    PROLOGUE 16
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12, [rbx + MB_rows + 8]
    jae 2f
    mov rax, r12
    imul rax, rax, MR_SIZE
    add rax, [rbx + MB_rows]
    mov rdi, rax
    call sb_free
    mov rax, r12
    imul rax, rax, MR_SIZE
    add rax, [rbx + MB_rows]
    lea rdi, [rax + MR_style]
    call sb_free
    inc r12
    jmp 1b
2:  lea rdi, [rbx + MB_rows]
    call vec_free
    EPILOGUE

# mdx_new_block(rdi=m, esi=kind, rdx=start, rcx=end, r8d=complete) -> rax
mdx_new_block:
    PROLOGUE 16
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    mov r15d, r8d
    lea rdi, [rbx + MDK_blocks]
    mov esi, MB_SIZE
    call vec_push
    mov [rax + MB_kind], r12d
    mov [rax + MB_complete], r15d
    mov [rax + MB_start], r13
    mov [rax + MB_end], r14
    EPILOGUE

# mdx_block_at(rdi=m, rsi=i) -> rax (leaf)
mdx_block_at:
    mov rax, rsi
    imul rax, rax, MB_SIZE
    add rax, [rdi + MDK_blocks]
    ret

# mdx_row_at(rdi=block, rsi=i) -> rax (leaf)
mdx_row_at:
    mov rax, rsi
    imul rax, rax, MR_SIZE
    add rax, [rdi + MB_rows]
    ret

# ------------------------------------------------------------------ inline

# parse_inline(rdi=s, rsi=n, rdx=segs, ecx=max) -> eax=count
# Seg = { u64 ptr; u64 len; u64 tag } (24 bytes).  Keeps one slot for the
# unstyled tail, so an over-long line never loses its remainder.
FN parse_inline
    PROLOGUE 16
    mov rbx, rdi                # s
    mov r12, rsi                # n
    mov r13, rdx                # out
    mov r14d, ecx               # max
    xor r15d, r15d              # ns
    mov ecx, r14d
    test ecx, ecx
    jz .Lpi_limit0
    dec ecx
    jmp .Lpi_have
.Lpi_limit0:
    xor ecx, ecx
.Lpi_have:
    mov [rsp], rcx              # limit
    xor r8d, r8d                # i
.Lpi_loop:
    cmp r8, r12
    jae .Lpi_tail
    cmp r15d, [rsp]
    jae .Lpi_tail
    movzx eax, byte ptr [rbx + r8]
    # bold **x**
    cmp al, '*'
    jne .Lpi_try_code
    lea r9, [r8 + 1]
    cmp r9, r12
    jae .Lpi_try_ital
    cmp byte ptr [rbx + r9], '*'
    jne .Lpi_try_ital
    # search closing **
    lea rcx, [r8 + 2]           # e
.Lpi_bold_scan:
    lea rdx, [rcx + 1]
    cmp rdx, r12
    jae .Lpi_lit
    cmp byte ptr [rbx + rcx], '*'
    jne .Lpi_bold_next
    cmp byte ptr [rbx + rcx + 1], '*'
    je .Lpi_bold_found
.Lpi_bold_next:
    inc rcx
    jmp .Lpi_bold_scan
.Lpi_bold_found:
    # out[ns] = { s+i+2, e-(i+2), MDF_BOLD }
    mov rax, r15
    imul rax, rax, 24
    add rax, r13
    lea rdx, [rbx + r8 + 2]
    mov [rax], rdx
    mov rdx, rcx
    sub rdx, r8
    sub rdx, 2
    mov [rax + 8], rdx
    mov qword ptr [rax + 16], MDF_BOLD
    inc r15d
    lea r8, [rcx + 2]
    jmp .Lpi_loop
    # code `x`
.Lpi_try_code:
    cmp al, '`'
    jne .Lpi_try_ital
    lea rcx, [r8 + 1]
.Lpi_code_scan:
    cmp rcx, r12
    jae .Lpi_lit
    cmp byte ptr [rbx + rcx], '`'
    je .Lpi_code_found
    inc rcx
    jmp .Lpi_code_scan
.Lpi_code_found:
    mov rax, r15
    imul rax, rax, 24
    add rax, r13
    lea rdx, [rbx + r8 + 1]
    mov [rax], rdx
    mov rdx, rcx
    sub rdx, r8
    sub rdx, 1
    mov [rax + 8], rdx
    mov qword ptr [rax + 16], MDC_CODE
    inc r15d
    lea r8, [rcx + 1]
    jmp .Lpi_loop
    # italic *x* or _x_
.Lpi_try_ital:
    cmp al, '*'
    je .Lpi_ital_go
    cmp al, '_'
    jne .Lpi_lit
.Lpi_ital_go:
    lea r9, [r8 + 1]
    cmp r9, r12
    jae .Lpi_lit
    movzx r10d, byte ptr [rbx + r8]     # marker
    lea rcx, [r8 + 1]
.Lpi_ital_scan:
    cmp rcx, r12
    jae .Lpi_lit
    movzx eax, byte ptr [rbx + rcx]
    cmp al, r10b
    je .Lpi_ital_maybe
    inc rcx
    jmp .Lpi_ital_scan
.Lpi_ital_maybe:
    lea rax, [r8 + 1]
    cmp rcx, rax
    jbe .Lpi_ital_adv
    # out[ns] = { s+i+1, e-(i+1), MDF_ITALIC }
    mov rax, r15
    imul rax, rax, 24
    add rax, r13
    lea rdx, [rbx + r8 + 1]
    mov [rax], rdx
    mov rdx, rcx
    sub rdx, r8
    sub rdx, 1
    mov [rax + 8], rdx
    mov qword ptr [rax + 16], MDF_ITALIC
    inc r15d
    lea r8, [rcx + 1]
    jmp .Lpi_loop
.Lpi_ital_adv:
    inc rcx
    jmp .Lpi_ital_scan
    # literal run up to the next potential marker
.Lpi_lit:
    mov r9, r8                  # j
.Lpi_lit_loop:
    cmp r9, r12
    jae .Lpi_lit_done
    movzx eax, byte ptr [rbx + r9]
    cmp al, '`'
    je .Lpi_lit_done
    cmp al, '*'
    je .Lpi_lit_marker
    cmp al, '_'
    jne .Lpi_lit_next
.Lpi_lit_marker:
    lea rax, [r9 + 1]
    cmp rax, r12
    jae .Lpi_lit_next
    jmp .Lpi_lit_done
.Lpi_lit_next:
    inc r9
    jmp .Lpi_lit_loop
.Lpi_lit_done:
    cmp r9, r8
    jne 1f
    inc r9
1:  mov rax, r15
    imul rax, rax, 24
    add rax, r13
    lea rdx, [rbx + r8]
    mov [rax], rdx
    mov rdx, r9
    sub rdx, r8
    mov [rax + 8], rdx
    mov qword ptr [rax + 16], MDC_BASE
    inc r15d
    mov r8, r9
    jmp .Lpi_loop
.Lpi_tail:
    cmp r8, r12
    jae .Lpi_done
    cmp r15d, r14d
    jae .Lpi_done
    mov rax, r15
    imul rax, rax, 24
    add rax, r13
    lea rdx, [rbx + r8]
    mov [rax], rdx
    mov rdx, r12
    sub rdx, r8
    mov [rax + 8], rdx
    mov qword ptr [rax + 16], MDC_BASE
    inc r15d
.Lpi_done:
    mov eax, r15d
    EPILOGUE

# mdx_combine(edi=base, esi=seg) -> eax: overlay a heading/quote base style
mdx_combine:
    mov eax, edi
    mov ecx, esi
    and ecx, MDC_MASK
    cmp ecx, MDC_CODE
    jne 1f
    and eax, 0xFFFFFFF0
    or eax, esi
    ret
1:  test esi, MDF_BOLD
    jz 2f
    or eax, MDF_BOLD
    ret
2:  test esi, MDF_ITALIC
    jz 3f
    or eax, MDF_ITALIC
3:  ret

# ------------------------------------------------------------------ wrapping

# mdx_wrap_new_row(rdi=w)
mdx_wrap_new_row:
    PROLOGUE 0
    mov rbx, rdi
    mov rdi, [rbx + WR_b]
    call mdx_new_row
    mov [rbx + WR_row], rax
    mov dword ptr [rbx + WR_col], 0
    mov ecx, [rbx + WR_indent]
    test ecx, ecx
    jle 1f
    mov rdi, rax
    lea rsi, [rip + .Lspaces]
    mov edx, ecx
    mov ecx, MDC_BASE
    call mdx_row_put
    mov eax, [rbx + WR_indent]
    mov [rbx + WR_col], eax
1:  EPILOGUE

# mdx_wrap_put(rdi=w, rsi=ptr, rdx=len, ecx=tag, r8d=cw, r9d=clip)
mdx_wrap_put:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14d, ecx
    mov r15d, r8d
    mov [rsp], r9d
    test r15d, r15d
    jle .Lwp_nofit
    mov eax, [rbx + WR_col]
    add eax, r15d
    cmp eax, [rbx + WR_width]
    jle .Lwp_nofit
    cmp dword ptr [rsp], 0
    jne .Lwp_done
    mov rdi, rbx
    call mdx_wrap_new_row
    cmp byte ptr [r12], ' '
    je .Lwp_done
.Lwp_nofit:
    cmp qword ptr [rbx + WR_row], 0
    jne 1f
    mov rdi, rbx
    call mdx_wrap_new_row
1:  cmp byte ptr [r12], ' '
    jne 2f
    cmp dword ptr [rbx + WR_col], 0
    je .Lwp_done
2:  mov rdi, [rbx + WR_row]
    mov rsi, r12
    mov rdx, r13
    mov ecx, r14d
    call mdx_row_put
    add [rbx + WR_col], r15d
.Lwp_done:
    EPILOGUE

# mdx_wrap_text(rdi=w, rsi=ptr, rdx=len, ecx=tag, r8d=clip): word wrap
mdx_wrap_text:
    PROLOGUE 48
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14d, ecx
    mov r15d, r8d
    mov qword ptr [rsp], 0        # i
.Lwt_loop:
    mov rax, [rsp]
    cmp rax, r13
    jae .Lwt_done
    movzx ecx, byte ptr [r12 + rax]
    cmp ecx, 10
    je .Lwt_adv
    cmp ecx, 13
    je .Lwt_adv
    cmp ecx, ' '
    jne .Lwt_word
    cmp dword ptr [rbx + WR_col], 0
    jle .Lwt_adv
    mov dword ptr [rbx + WR_pend], 1
.Lwt_adv:
    inc qword ptr [rsp]
    jmp .Lwt_loop
.Lwt_word:
    mov rax, [rsp]
    mov [rsp + 8], rax            # j
    mov dword ptr [rsp + 16], 0   # wlen
.Lwt_meas:
    mov rax, [rsp + 8]
    cmp rax, r13
    jae .Lwt_meased
    movzx ecx, byte ptr [r12 + rax]
    cmp ecx, ' '
    je .Lwt_meased
    cmp ecx, 10
    je .Lwt_meased
    cmp ecx, 13
    je .Lwt_meased
    lea rdi, [r12 + rax]
    mov rsi, r13
    sub rsi, rax
    call utf8dec
    mov [rsp + 24], rdx
    mov edi, eax
    call view_wcwidth
    add [rsp + 16], eax
    mov rax, [rsp + 24]
    add [rsp + 8], rax
    jmp .Lwt_meas
.Lwt_meased:
    mov dword ptr [rsp + 32], 0
    cmp dword ptr [rbx + WR_pend], 0
    je 1f
    mov dword ptr [rsp + 32], 1
1:  test r15d, r15d
    jnz .Lwt_pend
    cmp dword ptr [rbx + WR_col], 0
    jle .Lwt_pend
    mov eax, [rbx + WR_col]
    add eax, [rsp + 32]
    add eax, [rsp + 16]
    cmp eax, [rbx + WR_width]
    jle .Lwt_pend
    mov rdi, rbx
    call mdx_wrap_new_row
    mov dword ptr [rbx + WR_pend], 0
    jmp .Lwt_emit
.Lwt_pend:
    cmp dword ptr [rbx + WR_pend], 0
    je .Lwt_emit
    lea rdi, [rbx]
    lea rsi, [rip + .Lspaces]
    mov edx, 1
    mov ecx, MDC_BASE
    mov r8d, 1
    mov r9d, r15d
    call mdx_wrap_put
    mov dword ptr [rbx + WR_pend], 0
.Lwt_emit:
    mov rax, [rsp]
    cmp rax, [rsp + 8]
    jae .Lwt_loop
    lea rdi, [r12 + rax]
    mov rsi, r13
    sub rsi, rax
    call utf8dec
    mov [rsp + 24], rdx
    mov edi, eax
    call view_wcwidth
    mov [rsp + 20], eax
    test eax, eax
    jne .Lwt_put
    # combining mark: attach to the current row, no column cost
    mov rax, [rbx + WR_row]
    test rax, rax
    jz .Lwt_eadv
    mov rcx, [rax + MR_text + 8]
    test rcx, rcx
    jz .Lwt_eadv
    mov rdi, rax
    mov rsi, r12
    add rsi, [rsp]
    mov rdx, [rsp + 24]
    mov ecx, r14d
    call mdx_row_put
    jmp .Lwt_eadv
.Lwt_put:
    lea rdi, [rbx]
    mov rsi, r12
    add rsi, [rsp]
    mov rdx, [rsp + 24]
    mov ecx, r14d
    mov r8d, [rsp + 20]
    mov r9d, r15d
    call mdx_wrap_put
.Lwt_eadv:
    mov rax, [rsp + 24]
    add [rsp], rax
    jmp .Lwt_emit
.Lwt_done:
    EPILOGUE

# ------------------------------------------------------------------ renderers

# mdx_render_flow(rdi=m, rsi=b, edx=kind): paragraphs and bullets
mdx_render_flow:
    PROLOGUE 1616
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov r14, [rbx + MDK_text]
    add r14, [r12 + MB_start]     # base
    mov r15, [r12 + MB_end]
    sub r15, [r12 + MB_start]     # len
    lea rdi, [rsp]
    mov [rdi + WR_b], r12
    mov eax, [rbx + MDK_width]
    mov [rdi + WR_width], eax
    mov dword ptr [rdi + WR_col], 0
    mov dword ptr [rdi + WR_indent], 0
    mov qword ptr [rdi + WR_row], 0
    mov dword ptr [rdi + WR_pend], 0
    mov qword ptr [rsp + 40], 0   # i
    mov dword ptr [rsp + 48], 1   # first
.Lrf_loop:
    mov rax, [rsp + 40]
    cmp rax, r15
    jae .Lrf_end
    mov rdi, r14
    mov rsi, r15
    mov rdx, rax
    call mdx_line_end
    mov [rsp + 56], rax           # le
    mov rax, [rsp + 40]
    mov [rsp + 64], rax           # ls
    cmp r13d, MD_BULLET
    jne .Lrf_para
    # bullet: strip marker, prefix "- " in accent, continuation indent 2
    mov rdi, r14
    mov rsi, [rsp + 56]
    mov rdx, [rsp + 40]
    call mdx_bullet_ls
    mov [rsp + 64], rax
    lea rdi, [rsp]
    call mdx_wrap_new_row
    mov rdi, [rsp + WR_row]
    lea rsi, [rip + .Ldash]
    mov edx, 2
    mov ecx, MDC_ACCENT
    call mdx_row_put
    mov dword ptr [rsp + WR_col], 2
    mov dword ptr [rsp + WR_indent], 2
    jmp .Lrf_inline
.Lrf_para:
    cmp dword ptr [rsp + 48], 0
    jne .Lrf_inline
    cmp dword ptr [rsp + WR_col], 0
    jle .Lrf_inline
    lea rdi, [rsp]
    lea rsi, [rip + .Lspaces]
    mov edx, 1
    mov ecx, MDC_BASE
    xor r8d, r8d
    call mdx_wrap_text
.Lrf_inline:
    mov rdi, r14
    add rdi, [rsp + 64]
    mov rsi, [rsp + 56]
    sub rsi, [rsp + 64]
    lea rdx, [rsp + 80]
    mov ecx, 64
    call parse_inline
    mov [rsp + 72], eax
    mov dword ptr [rsp + 76], 0
.Lrf_seg:
    mov eax, [rsp + 76]
    cmp eax, [rsp + 72]
    jae .Lrf_next
    imul rdx, rax, 24
    lea rax, [rsp + 80]
    add rax, rdx
    lea rdi, [rsp]
    mov rsi, [rax]
    mov rdx, [rax + 8]
    mov ecx, [rax + 16]
    xor r8d, r8d
    call mdx_wrap_text
    inc dword ptr [rsp + 76]
    jmp .Lrf_seg
.Lrf_next:
    mov rax, [rsp + 56]
    cmp rax, r15
    jae 1f
    inc rax
1:  mov [rsp + 40], rax
    mov dword ptr [rsp + 48], 0
    jmp .Lrf_loop
.Lrf_end:
    mov rax, [r12 + MB_rows + 8]
    test rax, rax
    jnz 1f
    lea rdi, [rsp]
    call mdx_wrap_new_row
1:  EPILOGUE

# mdx_render_heading(rdi=m, rsi=b)
mdx_render_heading:
    PROLOGUE 1616
    mov rbx, rdi
    mov r12, rsi
    mov r14, [rbx + MDK_text]
    add r14, [r12 + MB_start]
    mov r15, [r12 + MB_end]
    sub r15, [r12 + MB_start]
    # level = leading '#', <= 6, then skip spaces
    xor r13d, r13d
1:  cmp r13, r15
    jae 2f
    cmp r13, 6
    jae 2f
    cmp byte ptr [r14 + r13], '#'
    jne 2f
    inc r13
    jmp 1b
2:  # content start = r13, skip spaces
    mov rax, r13
3:  cmp rax, r15
    jae 4f
    cmp byte ptr [r14 + rax], ' '
    jne 4f
    inc rax
    jmp 3b
4:  mov [rsp + 40], rax           # content start
    # base style tag
    xor ecx, ecx
    cmp r13, 1
    ja 5f
    mov ecx, MDC_ACCENT
5:  or ecx, MDF_BOLD
    cmp r13, 3
    jb 6f
    or ecx, MDF_DIM
6:  mov [rsp + 48], ecx           # base tag
    lea rdi, [rsp]
    mov [rdi + WR_b], r12
    mov eax, [rbx + MDK_width]
    mov [rdi + WR_width], eax
    mov dword ptr [rdi + WR_col], 0
    mov dword ptr [rdi + WR_indent], 0
    mov qword ptr [rdi + WR_row], 0
    mov dword ptr [rdi + WR_pend], 0
    call mdx_wrap_new_row
    mov rdi, r14
    add rdi, [rsp + 40]
    mov rsi, r15
    sub rsi, [rsp + 40]
    lea rdx, [rsp + 80]
    mov ecx, 64
    call parse_inline
    mov [rsp + 56], eax
    mov dword ptr [rsp + 60], 0
.Lrh_seg:
    mov eax, [rsp + 60]
    cmp eax, [rsp + 56]
    jae .Lrh_done
    imul rdx, rax, 24
    lea rax, [rsp + 80]
    add rax, rdx
    mov [rsp + 64], rax           # seg pointer
    mov edi, [rsp + 48]
    mov esi, [rax + 16]
    call mdx_combine
    mov ecx, eax
    lea rdi, [rsp]
    mov rax, [rsp + 64]
    mov rsi, [rax + 0]
    mov rdx, [rax + 8]
    xor r8d, r8d
    call mdx_wrap_text
    inc dword ptr [rsp + 60]
    jmp .Lrh_seg
.Lrh_done:
    mov rax, [r12 + MB_rows + 8]
    test rax, rax
    jnz 1f
    lea rdi, [rsp]
    call mdx_wrap_new_row
1:  EPILOGUE

# mdx_render_quote(rdi=m, rsi=b)
mdx_render_quote:
    PROLOGUE 1616
    mov rbx, rdi
    mov r12, rsi
    mov r14, [rbx + MDK_text]
    add r14, [r12 + MB_start]
    mov r15, [r12 + MB_end]
    sub r15, [r12 + MB_start]
    # skip leading blanks, then '>', then one space
    xor eax, eax
1:  cmp rax, r15
    jae 2f
    movzx ecx, byte ptr [r14 + rax]
    cmp ecx, ' '
    je 3f
    cmp ecx, 9
    jne 2f
3:  inc rax
    jmp 1b
2:  cmp rax, r15
    jae 4f
    cmp byte ptr [r14 + rax], '>'
    jne 4f
    inc rax
    cmp rax, r15
    jae 4f
    cmp byte ptr [r14 + rax], ' '
    jne 4f
    inc rax
4:  mov [rsp + 40], rax
    lea rdi, [rsp]
    mov [rdi + WR_b], r12
    mov eax, [rbx + MDK_width]
    mov [rdi + WR_width], eax
    mov dword ptr [rdi + WR_col], 0
    mov dword ptr [rdi + WR_indent], 0
    mov qword ptr [rdi + WR_row], 0
    mov dword ptr [rdi + WR_pend], 0
    call mdx_wrap_new_row
    mov rdi, [rsp + WR_row]
    lea rsi, [rip + .Lquote]
    mov edx, 2
    mov ecx, MDC_ACCENT
    call mdx_row_put
    mov dword ptr [rsp + WR_col], 2
    mov dword ptr [rsp + WR_indent], 2
    mov rdi, r14
    add rdi, [rsp + 40]
    mov rsi, r15
    sub rsi, [rsp + 40]
    lea rdx, [rsp + 80]
    mov ecx, 64
    call parse_inline
    mov [rsp + 56], eax
    mov dword ptr [rsp + 60], 0
.Lrq_seg:
    mov eax, [rsp + 60]
    cmp eax, [rsp + 56]
    jae .Lrq_done
    imul rdx, rax, 24
    lea rax, [rsp + 80]
    add rax, rdx
    mov [rsp + 64], rax           # seg pointer
    mov edi, MDC_BASE
    mov esi, [rax + 16]
    call mdx_combine
    mov ecx, eax
    lea rdi, [rsp]
    mov rax, [rsp + 64]
    mov rsi, [rax + 0]
    mov rdx, [rax + 8]
    xor r8d, r8d
    call mdx_wrap_text
    inc dword ptr [rsp + 60]
    jmp .Lrq_seg
.Lrq_done:
    mov rax, [r12 + MB_rows + 8]
    test rax, rax
    jnz 1f
    lea rdi, [rsp]
    call mdx_wrap_new_row
1:  EPILOGUE

# mdx_render_rule(rdi=m, rsi=b)
mdx_render_rule:
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    mov r14, [rbx + MDK_text]
    add r14, [r12 + MB_start]
    mov r15, [r12 + MB_end]
    sub r15, [r12 + MB_start]
    # trim trailing spaces and CR
    mov rax, r15
1:  test rax, rax
    jz 2f
    movzx ecx, byte ptr [r14 + rax - 1]
    cmp ecx, ' '
    je 3f
    cmp ecx, 13
    jne 2f
3:  dec rax
    jmp 1b
2:  mov r13, rax                # trimmed length
    mov rdi, r12
    call mdx_new_row
    mov rdi, rax
    mov rsi, r14
    mov rdx, r13
    mov ecx, MDC_MUTED
    call mdx_row_put
    mov rax, [r12 + MB_rows + 8]
    test rax, rax
    jnz 1f
    mov rdi, r12
    call mdx_new_row
1:  EPILOGUE

# mdx_render_code(rdi=m, rsi=b)
mdx_render_code:
    PROLOGUE 64
    mov rbx, rdi
    mov r12, rsi
    mov r14, [rbx + MDK_text]
    add r14, [r12 + MB_start]
    mov r15, [r12 + MB_end]
    sub r15, [r12 + MB_start]
    movzx r13d, byte ptr [r14]      # fence char
    lea rdi, [rsp]
    mov [rdi + WR_b], r12
    mov eax, [rbx + MDK_width]
    mov [rdi + WR_width], eax
    mov dword ptr [rdi + WR_col], 0
    mov dword ptr [rdi + WR_indent], 0
    mov qword ptr [rdi + WR_row], 0
    mov dword ptr [rdi + WR_pend], 0
    mov qword ptr [rsp + 40], 0     # i
    mov dword ptr [rsp + 48], 1     # first
.Lrc_loop:
    mov rax, [rsp + 40]
    cmp rax, r15
    jae .Lrc_done
    mov rdi, r14
    mov rsi, r15
    mov rdx, rax
    call mdx_line_end
    mov [rsp + 56], rax             # le
    cmp dword ptr [rsp + 48], 0
    jne .Lrc_skipfirst
    # closing fence of the same char?
    mov rcx, [rsp + 56]
    sub rcx, [rsp + 40]
    cmp rcx, 3
    jb .Lrc_line
    mov rdi, r14
    mov rsi, r15
    mov rdx, [rsp + 40]
    mov ecx, r13d
    call mdx_fence_close
    test eax, eax
    jnz .Lrc_done
.Lrc_line:
    lea rdi, [rsp]
    call mdx_wrap_new_row
    lea rdi, [rsp]
    mov rsi, r14
    add rsi, [rsp + 40]
    mov rdx, [rsp + 56]
    sub rdx, [rsp + 40]
    mov ecx, MDC_THINK | MDF_DIM
    mov r8d, 1
    call mdx_wrap_text
.Lrc_skipfirst:
    mov dword ptr [rsp + 48], 0
    mov rax, [rsp + 56]
    cmp rax, r15
    jae 1f
    inc rax
1:  mov [rsp + 40], rax
    jmp .Lrc_loop
.Lrc_done:
    mov rax, [r12 + MB_rows + 8]
    test rax, rax
    jnz 1f
    lea rdi, [rsp]
    call mdx_wrap_new_row
1:  EPILOGUE

# mdx_render_block(rdi=m, rsi=b)
mdx_render_block:
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    mov rdi, r12
    call mdx_block_free_rows
    mov eax, [r12 + MB_kind]
    cmp eax, MD_HEAD
    je 1f
    cmp eax, MD_CODE
    je 2f
    cmp eax, MD_BULLET
    je 3f
    cmp eax, MD_QUOTE
    je 4f
    cmp eax, MD_RULE
    je 5f
    mov rdi, rbx
    mov rsi, r12
    xor edx, edx
    call mdx_render_flow
    EPILOGUE
1:  mov rdi, rbx
    mov rsi, r12
    call mdx_render_heading
    EPILOGUE
2:  mov rdi, rbx
    mov rsi, r12
    call mdx_render_code
    EPILOGUE
3:  mov rdi, rbx
    mov rsi, r12
    mov edx, MD_BULLET
    call mdx_render_flow
    EPILOGUE
4:  mov rdi, rbx
    mov rsi, r12
    call mdx_render_quote
    EPILOGUE
5:  mov rdi, rbx
    mov rsi, r12
    call mdx_render_rule
    EPILOGUE

# ------------------------------------------------------------------ parser

# mdx_parse(rdi=m, rsi=from)
mdx_parse:
    PROLOGUE 32
    mov rbx, rdi
    mov r12, [rbx + MDK_text]
    mov r13, [rbx + MDK_text + 8]
    mov r14, rsi
.Lmp_top:
    cmp r14, r13
    jae .Lmp_done
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    call mdx_line_is_blank
    test eax, eax
    jz .Lmp_classify
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    call mdx_line_end
    mov r14, rax
    cmp r14, r13
    jae .Lmp_done
    inc r14
    jmp .Lmp_top
.Lmp_classify:
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    call mdx_fence_start
    test eax, eax
    jnz .Lmp_code
    cmp byte ptr [r12 + r14], '#'
    je .Lmp_head
    cmp byte ptr [r12 + r14], '>'
    je .Lmp_quote
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    call mdx_is_rule
    test eax, eax
    jnz .Lmp_rule
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    call mdx_bullet_ls
    cmp rax, r14
    jne .Lmp_bullet
    # paragraph
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    call mdx_para_end
    mov [rsp], rax              # end
    mov [rsp + 8], rdx          # complete
    mov rdi, rbx
    mov esi, MD_PARA
    mov rdx, r14
    mov rcx, [rsp]
    mov r8d, [rsp + 8]
    call mdx_new_block
    mov rdi, rbx
    mov rsi, rax
    call mdx_render_block
    mov r14, [rsp]
    jmp .Lmp_top
.Lmp_bullet:
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    call mdx_para_end
    mov [rsp], rax
    mov [rsp + 8], rdx
    mov rdi, rbx
    mov esi, MD_BULLET
    mov rdx, r14
    mov rcx, [rsp]
    mov r8d, [rsp + 8]
    call mdx_new_block
    mov rdi, rbx
    mov rsi, rax
    call mdx_render_block
    mov r14, [rsp]
    jmp .Lmp_top
.Lmp_head:
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    call mdx_line_end
    mov [rsp], rax
    lea rcx, [rax + 1]
    cmp rax, r13
    cmovae rcx, rax
    mov rdi, rbx
    mov esi, MD_HEAD
    mov rdx, r14
    mov r8d, 1
    call mdx_new_block
    mov rdi, rbx
    mov rsi, rax
    call mdx_render_block
    mov rax, [rsp]
    cmp rax, r13
    jae 1f
    inc rax
1:  mov r14, rax
    jmp .Lmp_top
.Lmp_quote:
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    call mdx_line_end
    mov [rsp], rax
    mov rdi, rbx
    mov esi, MD_QUOTE
    mov rdx, r14
    lea rcx, [rax + 1]
    cmp rax, r13
    cmovae rcx, rax
    mov r8d, 1
    call mdx_new_block
    mov rdi, rbx
    mov rsi, rax
    call mdx_render_block
    mov rax, [rsp]
    cmp rax, r13
    jae 1f
    inc rax
1:  mov r14, rax
    jmp .Lmp_top
.Lmp_rule:
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    call mdx_line_end
    mov [rsp], rax
    mov rdi, rbx
    mov esi, MD_RULE
    mov rdx, r14
    lea rcx, [rax + 1]
    cmp rax, r13
    cmovae rcx, rax
    mov r8d, 1
    call mdx_new_block
    mov rdi, rbx
    mov rsi, rax
    call mdx_render_block
    mov rax, [rsp]
    cmp rax, r13
    jae 1f
    inc rax
1:  mov r14, rax
    jmp .Lmp_top
.Lmp_code:
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    call mdx_find_code_end
    mov [rsp], rax
    mov [rsp + 8], rdx
    mov rdi, rbx
    mov esi, MD_CODE
    mov rdx, r14
    mov rcx, [rsp]
    mov r8d, [rsp + 8]
    call mdx_new_block
    mov rdi, rbx
    mov rsi, rax
    call mdx_render_block
    mov r14, [rsp]
    jmp .Lmp_top
.Lmp_done:
    EPILOGUE

# ------------------------------------------------------------------ public

FN md_init
    PROLOGUE 0
    mov rbx, rdi
    mov r12d, esi
    mov rdi, rbx
    xor esi, esi
    mov edx, MDK_SIZE
    call memset
    cmp r12d, 1
    jge 1f
    mov r12d, 80
1:  mov [rbx + MDK_width], r12d
    EPILOGUE

FN md_free
    PROLOGUE 16
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12, [rbx + MDK_blocks + 8]
    jae 2f
    mov rax, r12
    imul rax, rax, MB_SIZE
    add rax, [rbx + MDK_blocks]
    mov rdi, rax
    call mdx_block_free_rows
    inc r12
    jmp 1b
2:  mov rdi, [rbx + MDK_blocks]
    call mem_free
    mov qword ptr [rbx + MDK_blocks], 0
    mov qword ptr [rbx + MDK_blocks + 8], 0
    mov qword ptr [rbx + MDK_blocks + 16], 0
    lea rdi, [rbx + MDK_text]
    call sb_free
    EPILOGUE

FN md_reset
    PROLOGUE 0
    mov rbx, rdi
    mov r12d, [rbx + MDK_width]
    call md_free
    test r12d, r12d
    jnz 1f
    mov r12d, 80
1:  mov [rbx + MDK_width], r12d
    EPILOGUE

FN md_set_width
    PROLOGUE 16
    mov rbx, rdi
    mov r12d, esi
    cmp r12d, 1
    jge 1f
    mov r12d, 1
1:  cmp r12d, [rbx + MDK_width]
    je .Lsw_done
    mov [rbx + MDK_width], r12d
    xor r13d, r13d
2:  cmp r13, [rbx + MDK_blocks + 8]
    jae .Lsw_done
    mov rdi, rbx
    mov rsi, r13
    call mdx_block_at
    mov rdi, rbx
    mov rsi, rax
    call mdx_render_block
    inc r13
    jmp 2b
.Lsw_done:
    EPILOGUE

FN md_append
    PROLOGUE 16
    test rsi, rsi
    jz .Lap_done
    test rdx, rdx
    jz .Lap_done
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    lea rdi, [rbx + MDK_text]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    mov rcx, [rbx + MDK_blocks + 8]
    test rcx, rcx
    jz .Lap_from0
    mov rdi, rbx
    lea rsi, [rcx - 1]
    call mdx_block_at
    cmp dword ptr [rax + MB_complete], 0
    jne .Lap_lastend
    mov rsi, [rax + MB_start]
    mov [rsp], rsi
    mov rdi, rax
    call mdx_block_free_rows
    dec qword ptr [rbx + MDK_blocks + 8]
    jmp .Lap_parse
.Lap_lastend:
    mov rsi, [rax + MB_end]
    mov [rsp], rsi
    jmp .Lap_parse
.Lap_from0:
    mov qword ptr [rsp], 0
.Lap_parse:
    mov rdi, rbx
    mov rsi, [rsp]
    call mdx_parse
.Lap_done:
    EPILOGUE

FN md_height
    xor eax, eax
    xor ecx, ecx
    mov rdx, [rdi + MDK_blocks]
1:  cmp rcx, [rdi + MDK_blocks + 8]
    jae 2f
    mov r8, rcx
    imul r8, r8, MB_SIZE
    add r8, rdx
    add rax, [r8 + MB_rows + 8]
    inc rcx
    jmp 1b
2:  ret

FN md_nblocks
    mov rax, [rdi + MDK_blocks + 8]
    ret

FN md_blocks
    mov rax, [rdi + MDK_blocks]
    test rsi, rsi
    jz 1f
    mov rcx, [rdi + MDK_blocks + 8]
    mov [rsi], rcx
1:  ret

FN md_rows_before
    xor eax, eax
    xor ecx, ecx
    mov rdx, [rdi + MDK_blocks]
1:  cmp rcx, rsi
    jae 2f
    mov r8, rcx
    imul r8, r8, MB_SIZE
    add r8, rdx
    add rax, [r8 + MB_rows + 8]
    inc rcx
    jmp 1b
2:  ret

# mdx_tag_view(edi=tag, esi=base_style) -> eax view style byte (leaf)
mdx_tag_view:
    mov eax, edi
    and eax, MDC_MASK
    cmp eax, MDC_ACCENT
    je .Ltv_acc
    cmp eax, MDC_CODE
    je .Ltv_code
    cmp eax, MDC_MUTED
    je .Ltv_muted
    cmp eax, MDC_THINK
    je .Ltv_think
    mov eax, esi
    jmp .Ltv_attrs
.Ltv_acc:
    mov eax, VS_MD_ACCENT
    jmp .Ltv_attrs
.Ltv_code:
    mov eax, VST_CODE
    jmp .Ltv_attrs
.Ltv_muted:
    mov eax, VST_DIM
    jmp .Ltv_attrs
.Ltv_think:
    mov eax, VS_MD_THINK
.Ltv_attrs:
    test edi, MDF_BOLD
    jz 1f
    or eax, VSA_BOLD
1:  test edi, MDF_DIM
    jz 2f
    or eax, VSA_DIM
2:  test edi, MDF_ITALIC
    jz 3f
    or eax, VSA_ITALIC
3:  ret

# mdx_tag_slot(edi=tag, esi=base_slot) -> eax theme slot (leaf)
mdx_tag_slot:
    mov eax, edi
    and eax, MDC_MASK
    cmp eax, MDC_ACCENT
    je .Lts_acc
    cmp eax, MDC_CODE
    je .Lts_code
    cmp eax, MDC_MUTED
    je .Lts_muted
    cmp eax, MDC_THINK
    je .Lts_think
    mov eax, esi
    ret
.Lts_acc:
    mov eax, TH_ACCENT
    ret
.Lts_code:
    mov eax, TH_CODE
    ret
.Lts_muted:
    mov eax, TH_MUTED
    ret
.Lts_think:
    mov eax, TH_THINKING
    ret

# mdx_tag_attrs(edi=tag) -> eax: bit0 bold, bit1 dim, bit2 italic (leaf)
mdx_tag_attrs:
    xor eax, eax
    test edi, MDF_BOLD
    jz 1f
    or eax, 1
1:  test edi, MDF_DIM
    jz 2f
    or eax, 2
2:  test edi, MDF_ITALIC
    jz 3f
    or eax, 4
3:  ret

# mdx_sb_run(rdi=sb, esi=tag, edx=base_slot, rcx=ptr, r8=len)
mdx_sb_run:
    PROLOGUE 16
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov r14, rcx
    mov r15, r8
    mov rdi, rbx
    lea rsi, [rip + .Lsgr0]
    mov edx, 4
    call sb_push
    mov edi, r12d
    mov esi, r13d
    call mdx_tag_slot
    mov rdi, rbx
    mov esi, eax
    call theme_emit_fg
    mov edi, r12d
    call mdx_tag_attrs
    mov [rsp], eax
    test eax, 1
    jz 1f
    mov rdi, rbx
    lea rsi, [rip + .Lsgrbold]
    mov edx, 4
    call sb_push
1:  mov eax, [rsp]
    test eax, 2
    jz 2f
    mov rdi, rbx
    lea rsi, [rip + .Lsgrdim]
    mov edx, 4
    call sb_push
2:  mov eax, [rsp]
    test eax, 4
    jz 3f
    mov rdi, rbx
    lea rsi, [rip + .Lsgrital]
    mov edx, 4
    call sb_push
3:  mov rdi, rbx
    mov rsi, r14
    mov rdx, r15
    call sb_push
    EPILOGUE

# md_emit_view_from(rdi=m, rsi=view, edx=base_style, ecx=from)
FN md_emit_view_from
    PROLOGUE 64
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov r14, rcx
.Lve_block:
    cmp r14, [rbx + MDK_blocks + 8]
    jae .Lve_done
    mov rdi, rbx
    mov rsi, r14
    call mdx_block_at
    mov [rsp], rax
    mov qword ptr [rsp + 8], 0     # row index
.Lve_row:
    mov rax, [rsp]
    mov rcx, [rsp + 8]
    cmp rcx, [rax + MB_rows + 8]
    jae .Lve_nextblock
    mov rdi, [rsp]
    mov rsi, rcx
    call mdx_row_at
    mov [rsp + 16], rax
    mov rax, [rax + MR_text + 8]
    test rax, rax
    jnz .Lve_runs
    mov rdi, r12
    mov esi, r13d
    lea rdx, [rip + .Lspaces]
    mov ecx, 1
    call view_append_span
    mov rdi, r12
    call view_break
    jmp .Lve_nextrow
.Lve_runs:
    mov [rsp + 24], rax            # tlen
    mov rcx, [rsp + 16]
    mov rax, [rcx + MR_text]
    mov [rsp + 32], rax            # text ptr
    mov rax, [rcx + MR_style]
    mov [rsp + 40], rax            # style ptr
    mov qword ptr [rsp + 48], 0    # j
.Lve_run:
    mov rcx, [rsp + 48]
    cmp rcx, [rsp + 24]
    jae .Lve_rowdone
    mov rax, [rsp + 40]
    movzx edi, byte ptr [rax + rcx]
    mov esi, r13d
    call mdx_tag_view
    mov [rsp + 56], eax            # vs
    mov ecx, [rsp + 48]
    mov [rsp + 60], ecx            # k
.Lve_kloop:
    mov ecx, [rsp + 60]
    cmp rcx, [rsp + 24]
    jae .Lve_emit
    mov rax, [rsp + 40]
    movzx edi, byte ptr [rax + rcx]
    mov esi, r13d
    call mdx_tag_view
    cmp eax, [rsp + 56]
    jne .Lve_emit
    inc dword ptr [rsp + 60]
    jmp .Lve_kloop
.Lve_emit:
    mov rdi, r12
    mov esi, [rsp + 56]
    mov rax, [rsp + 32]
    mov rcx, [rsp + 48]
    lea rdx, [rax + rcx]
    mov ecx, [rsp + 60]
    sub ecx, [rsp + 48]
    call view_append_span
    mov eax, [rsp + 60]
    mov [rsp + 48], rax
    jmp .Lve_run
.Lve_rowdone:
    mov rdi, r12
    call view_break
.Lve_nextrow:
    inc qword ptr [rsp + 8]
    jmp .Lve_row
.Lve_nextblock:
    inc r14
    jmp .Lve_block
.Lve_done:
    EPILOGUE

FN md_emit_view
    xor ecx, ecx
    jmp md_emit_view_from

# md_emit_ansi(rdi=m, rsi=sb, edx=base_slot)
FN md_emit_ansi
    PROLOGUE 64
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov r14, 0
.Lva_block:
    cmp r14, [rbx + MDK_blocks + 8]
    jae .Lva_done
    mov rdi, rbx
    mov rsi, r14
    call mdx_block_at
    mov [rsp], rax
    mov qword ptr [rsp + 8], 0
.Lva_row:
    mov rax, [rsp]
    mov rcx, [rsp + 8]
    cmp rcx, [rax + MB_rows + 8]
    jae .Lva_nextblock
    mov rdi, [rsp]
    mov rsi, rcx
    call mdx_row_at
    mov [rsp + 16], rax
    mov rax, [rax + MR_text + 8]
    mov [rsp + 24], rax
    mov rcx, [rsp + 16]
    mov rax, [rcx + MR_text]
    mov [rsp + 32], rax
    mov rax, [rcx + MR_style]
    mov [rsp + 40], rax
    mov qword ptr [rsp + 48], 0
.Lva_run:
    mov rcx, [rsp + 48]
    cmp rcx, [rsp + 24]
    jae .Lva_rowdone
    mov rax, [rsp + 40]
    movzx edi, byte ptr [rax + rcx]
    mov esi, r13d
    call mdx_tag_slot
    mov [rsp + 56], eax
    mov rcx, [rsp + 48]
    mov [rsp + 60], ecx
.Lva_kloop:
    mov ecx, [rsp + 60]
    cmp rcx, [rsp + 24]
    jae .Lva_emit
    mov rax, [rsp + 40]
    movzx edi, byte ptr [rax + rcx]
    mov esi, r13d
    call mdx_tag_slot
    cmp eax, [rsp + 56]
    jne .Lva_emit
    inc dword ptr [rsp + 60]
    jmp .Lva_kloop
.Lva_emit:
    mov rdi, r12
    mov rax, [rsp + 40]
    mov rcx, [rsp + 48]
    movzx esi, byte ptr [rax + rcx]
    mov edx, r13d
    mov rax, [rsp + 32]
    mov rcx, [rsp + 48]
    lea rcx, [rax + rcx]
    mov r8d, [rsp + 60]
    sub r8d, [rsp + 48]
    call mdx_sb_run
    mov eax, [rsp + 60]
    mov [rsp + 48], rax
    jmp .Lva_run
.Lva_rowdone:
    mov rdi, r12
    lea rsi, [rip + .Lnl]
    mov edx, 1
    call sb_push
.Lva_nextrow:
    inc qword ptr [rsp + 8]
    jmp .Lva_row
.Lva_nextblock:
    inc r14
    jmp .Lva_block
.Lva_done:
    EPILOGUE
