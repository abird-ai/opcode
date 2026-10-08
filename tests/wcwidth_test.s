.include "opcode.inc"
# wcwidth_test: the shared width/combining table and the wide/combining grid
# cell model.   Golden output: tests/data/wcwidth_test.expected
#
# Covers combining marks (width 0, attach), the Cf zero-width set
# (ZWSP/ZWNJ/ZWJ/BOM, soft hyphen, Mongolian vowel separator), emoji and
# enclosed-ideograph width 2, wide+combining attachment that skips the
# CELL_CONT continuation cell, and a wide glyph clipped at the right edge.

# Cell layout (src/tui/render.s).
.equ CELL_SIZE, 24
.equ C_cp,      0
.equ C_comb,    4
.equ C_fg,      8
.equ C_bg,      12
.equ C_attrs,   16
.equ CELL_CONT, 0xFFFFFFFF

# Grid struct offsets.
.equ G_w,     0
.equ G_h,     4
.equ G_cells, 8

.bss
.p2align 4
g:    .zero 64
sb:   .zero SB_SIZE

.section .rodata
.p2align 3
.Lwidths:
    .long 0x41,   1
    .long 0x00AD, 0        # soft hyphen
    .long 0x0301, 0        # combining acute
    .long 0x180E, 0        # Mongolian vowel separator
    .long 0x200B, 0        # ZWSP
    .long 0x200C, 0        # ZWNJ
    .long 0x200D, 0        # ZWJ
    .long 0xFEFF, 0        # BOM / ZWNBSP
    .long 0x7F,   0        # DEL
    .long 0x01,   0        # C0
    .long 0x1F000, 2       # Mahjong tile
    .long 0x1F300, 2       # emoji
    .long 0x1F600, 2       # emoji
    .long 0x1F680, 2       # transport emoji
    .long 0x1F7E0, 2       # geometric emoji (new range)
    .long 0x1F7F0, 2       # new singleton range
    .long 0x1F900, 2       # supplemental symbols
    .long 0x1FA70, 2       # symbols extended
    .long 0x3231, 2        # enclosed ideograph
    .long 0x4E00, 2        # CJK
    .long 0xFF21, 2        # fullwidth latin
    .long 0x0301, 0
    .long -1, -1

.p2align 3
.Lcomb:
    .long 0x0301, 1        # genuine combining mark
    .long 0xFE20, 1        # combining half mark
    .long 0x20D0, 1        # combining diacritical for symbols
    .long 0x180B, 1        # Mongolian free variation selector (Mn)
    .long 0x180E, 0        # Mongolian vowel separator (Cf)
    .long 0x00AD, 0        # Cf: soft hyphen is not combining
    .long 0x200B, 0        # Cf
    .long 0x200D, 0        # Cf
    .long 0xFEFF, 0        # Cf
    .long 0x41,   0
    .long 0x1B,   0
    .long -1, -1

# "A" + U+0301 + "B"
.Lrow0:       .byte 0x41, 0xcc, 0x81, 0x42
.Lrow0e:
# U+4F60 (CJK) + U+0301
.Lrow1:       .byte 0xe4, 0xbd, 0xa0, 0xcc, 0x81
.Lrow1e:
# "e" + U+200B (dropped)
.Lfmt:        .byte 0x65, 0xe2, 0x80, 0x8b
.Lfmte:
# "e" + U+0301
.Lbase:       .byte 0x65, 0xcc, 0x81
.Lbasee:
# expected dump bytes
.Lexp0:       .byte 0x41, 0xcc, 0x81, 0x42
.Lexp0e:
.Lexp1:       .byte 0xe4, 0xbd, 0xa0, 0xcc, 0x81
.Lexp1e:

.s_w_ok:   .asciz "wcwidth widths ok\n"
.s_c_ok:   .asciz "wcwidth combining ok\n"
.s_g_ok:   .asciz "wcwidth grid ok\n"
.s_d_ok:   .asciz "wcwidth dump ok\n"
.s_done:   .asciz "wcwidth done\n"
.s_fail:   .asciz "FAIL wcwidth\n"
.s_nl:     .byte 10

.text
# print(cstr): write_all to stdout.
print:
    push rdi
    call strlen
    pop rdi
    mov rdx, rax
    mov rsi, rdi
    mov edi, 1
    jmp write_all

# cellp(rdi=g, esi=x, edx=y) -> rax = &cells[y*w + x]
cellp:
    mov eax, edx
    mov ecx, dword ptr [rdi + G_w]
    imul rax, rcx
    movsxd rsi, esi
    add rax, rsi
    imul rax, rax, CELL_SIZE
    add rax, [rdi + G_cells]
    ret

FN opcode_main
    PROLOGUE 0
    mov qword ptr [rip + g_tui_headless], 1

    # ---- 1: width table -------------------------------------------------
    lea rbx, [rip + .Lwidths]
.Lw_loop:
    mov edi, dword ptr [rbx]
    cmp edi, -1
    je .Lw_ok
    mov r12d, dword ptr [rbx + 4]
    call utf8_wcwidth
    cmp eax, r12d
    jne .Lfail
    add rbx, 8
    jmp .Lw_loop
.Lw_ok:
    lea rdi, [rip + .s_w_ok]
    call print

    # ---- 2: combining classifier ---------------------------------------
    lea rbx, [rip + .Lcomb]
.Lc_loop:
    mov edi, dword ptr [rbx]
    cmp edi, -1
    je .Lc_ok
    mov r12d, dword ptr [rbx + 4]
    call utf8_is_combining
    cmp eax, r12d
    jne .Lfail
    add rbx, 8
    jmp .Lc_loop
.Lc_ok:
    lea rdi, [rip + .s_c_ok]
    call print

    # ---- 3: grid wide / combining / edge --------------------------------
    lea rdi, [rip + g]
    xor esi, esi
    mov rdx, [rip + grid_size]
    call memset
    lea rdi, [rip + g]
    mov esi, 8
    mov edx, 4
    call grid_init
    test eax, eax
    jnz .Lfail
    lea rdi, [rip + g]
    xor esi, esi
    xor edx, edx
    call grid_clear

    # row 0: "A" + combining acute + "B": mark attaches to A, B follows.
    lea rdi, [rip + g]
    xor esi, esi
    xor edx, edx
    mov ecx, 0xFFCCCCCC
    xor r8d, r8d
    xor r9d, r9d
    sub rsp, 16
    lea rax, [rip + .Lrow0]
    mov [rsp], rax
    mov rax, .Lrow0e - .Lrow0
    mov [rsp + 8], rax
    call grid_text
    add rsp, 16
    lea rdi, [rip + g]
    xor esi, esi
    xor edx, edx
    call cellp
    cmp dword ptr [rax + C_cp], 0x41
    jne .Lfail
    cmp dword ptr [rax + C_comb], 0x0301
    jne .Lfail
    lea rdi, [rip + g]
    mov esi, 1
    xor edx, edx
    call cellp
    cmp dword ptr [rax + C_cp], 0x42
    jne .Lfail
    cmp dword ptr [rax + C_comb], 0
    jne .Lfail

    # row 1: wide CJK + combining acute: base holds the mark, second cell is
    # the continuation sentinel.
    lea rdi, [rip + g]
    xor esi, esi
    mov edx, 1
    mov ecx, 0xFFCCCCCC
    xor r8d, r8d
    xor r9d, r9d
    sub rsp, 16
    lea rax, [rip + .Lrow1]
    mov [rsp], rax
    mov rax, .Lrow1e - .Lrow1
    mov [rsp + 8], rax
    call grid_text
    add rsp, 16
    lea rdi, [rip + g]
    xor esi, esi
    mov edx, 1
    call cellp
    cmp dword ptr [rax + C_cp], 0x4F60
    jne .Lfail
    cmp dword ptr [rax + C_comb], 0x0301
    jne .Lfail
    lea rdi, [rip + g]
    mov esi, 1
    mov edx, 1
    call cellp
    cmp dword ptr [rax + C_cp], CELL_CONT
    jne .Lfail

    # row 2: a wide glyph that would cross the right edge is blanked, not
    # split, and never leaves a stray continuation cell.
    lea rdi, [rip + g]
    mov esi, 5
    mov edx, 2
    mov ecx, 0x4F60
    mov r8d, 0xFFCCCCCC
    xor r9d, r9d
    sub rsp, 16
    mov qword ptr [rsp], 0
    call grid_put
    add rsp, 16
    lea rdi, [rip + g]
    mov esi, 6
    mov edx, 2
    call cellp
    cmp dword ptr [rax + C_cp], CELL_CONT
    jne .Lfail
    lea rdi, [rip + g]
    mov esi, 7
    mov edx, 2
    mov ecx, 0x4F60
    mov r8d, 0xFFCCCCCC
    xor r9d, r9d
    sub rsp, 16
    mov qword ptr [rsp], 0
    call grid_put
    add rsp, 16
    lea rdi, [rip + g]
    mov esi, 7
    mov edx, 2
    call cellp
    cmp dword ptr [rax + C_cp], 0x20
    jne .Lfail
    cmp dword ptr [rax + C_cp], CELL_CONT
    je .Lfail

    # row 3: a non-combining zero-width format codepoint is dropped, while a
    # genuine combining mark attaches and a raw control becomes a space.
    lea rdi, [rip + g]
    xor esi, esi
    mov edx, 3
    mov ecx, 0xFFCCCCCC
    xor r8d, r8d
    xor r9d, r9d
    sub rsp, 16
    lea rax, [rip + .Lfmt]
    mov [rsp], rax
    mov rax, .Lfmte - .Lfmt
    mov [rsp + 8], rax
    call grid_text
    add rsp, 16
    lea rdi, [rip + g]
    xor esi, esi
    mov edx, 3
    call cellp
    cmp dword ptr [rax + C_cp], 0x65
    jne .Lfail
    cmp dword ptr [rax + C_comb], 0
    jne .Lfail
    lea rdi, [rip + g]
    mov esi, 1
    mov edx, 3
    mov ecx, 0x1b
    mov r8d, 0xFFCCCCCC
    xor r9d, r9d
    sub rsp, 16
    mov qword ptr [rsp], 0
    call grid_put
    add rsp, 16
    lea rdi, [rip + g]
    mov esi, 1
    mov edx, 3
    call cellp
    cmp dword ptr [rax + C_cp], 0x20
    jne .Lfail
    lea rdi, [rip + g]
    mov esi, 2
    mov edx, 3
    mov ecx, 0xFFCCCCCC
    xor r8d, r8d
    xor r9d, r9d
    sub rsp, 16
    lea rax, [rip + .Lbase]
    mov [rsp], rax
    mov rax, .Lbasee - .Lbase
    mov [rsp + 8], rax
    call grid_text
    add rsp, 16
    lea rdi, [rip + g]
    mov esi, 2
    mov edx, 3
    call cellp
    cmp dword ptr [rax + C_cp], 0x65
    jne .Lfail
    cmp dword ptr [rax + C_comb], 0x0301
    jne .Lfail

    lea rdi, [rip + .s_g_ok]
    call print

    # ---- 4: render_dump round-trips wide + combining --------------------
    lea rdi, [rip + sb]
    call sb_clear
    lea rdi, [rip + g]
    lea rsi, [rip + sb]
    call render_dump
    mov rax, [rip + sb + SB_ptr]
    mov rsi, [rip + sb + SB_len]
    lea rdx, [rip + .Lexp0]
    mov rcx, .Lexp0e - .Lexp0
    mov rdi, rax
    call str_find
    test rax, rax
    js .Lfail
    mov rax, [rip + sb + SB_ptr]
    mov rsi, [rip + sb + SB_len]
    lea rdx, [rip + .Lexp1]
    mov rcx, .Lexp1e - .Lexp1
    mov rdi, rax
    call str_find
    test rax, rax
    js .Lfail
    lea rdi, [rip + .s_d_ok]
    call print

    # 5: the ANSI emitter writes the base glyph then its combining mark and
    # skips the continuation column.
    lea rdi, [rip + g]
    call render_build
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + .Lexp0]
    mov rcx, .Lexp0e - .Lexp0
    call str_find
    test rax, rax
    js .Lfail

    lea rdi, [rip + g]
    call grid_free
    lea rdi, [rip + .s_done]
    call print
    xor eax, eax
    EPILOGUE
.Lfail:
    lea rdi, [rip + .s_fail]
    call print
    mov eax, 1
    EPILOGUE
