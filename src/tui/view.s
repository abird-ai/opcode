# view: styled transcript row buffer with wrapping and a viewport.
# Rows are fixed 512 bytes: 256 text bytes + 256 style bytes. Max 20000 rows.
.include "opcode.inc"
.include "core/core.inc"
.include "tui/card.inc"
.include "tui/theme.inc"

.equ V_MAX,      20000
.equ V_STRIDE,   512
.equ V_TEXT,     0
.equ V_STYLE,    256
.equ V_HARDCOLS, 256

.equ VS_TEXT,     1
.equ VS_DIM,      2
.equ VS_ASSIST,   3
.equ VS_USER,     4
.equ VS_TOOL,     5
.equ VS_TOOL_OUT, 6
.equ VS_DIFF_ADD, 7
.equ VS_DIFF_DEL, 8
.equ VS_DIFF_HUNK,9
.equ VS_ERR,      10
.equ VS_CODE,     11

STRUCT
F Vw, 4
F Vrows, 4
F Vtop, 4
F Vmark, 4
F Vvx, 4
F Vvy, 4
F Vvw, 4
F Vvh, 4
F Vlast, 4
F Vcol, 4                    # display columns in the in-progress row
F Vdata, 8
F Vlen, 8
F Vrowbg, 8                  # u32 background per committed row (0 = none)
F Vbg, 4                    # band for the in-progress row
F Vpad, 4
ENDSTRUCT V_SIZE

.section .rodata
.p2align 3
.globl view_size
view_size: .quad V_SIZE
.p2align 3
# style id -> theme slot; view_style_color resolves the slot through the
# current theme every frame.
.v_style_slot:
    .long TH_FG                  # 0 unused
    .long TH_FG                  # TEXT
    .long TH_MUTED               # DIM
    .long TH_ASSISTANT           # ASSIST
    .long TH_USER                # USER
    .long TH_TOOL                # TOOL
    .long TH_OK                  # TOOL_OUT
    .long TH_DIFF_ADD            # DIFF_ADD
    .long TH_DIFF_DEL            # DIFF_DEL
    .long TH_ACCENT              # DIFF_HUNK
    .long TH_ERR                 # ERR
    .long TH_CODE                # CODE
    .long TH_TOOL                # CARD_TOOL
    .long TH_WARN                # CARD_WARN
    .long TH_OK                  # CARD_OK
    .long TH_ERR                 # CARD_ERR
    .long TH_FG                  # CARD_BODY
    .long TH_MUTED               # CARD_DIM
    .long TH_DIFF_ADD            # CARD_ADD
    .long TH_DIFF_DEL            # CARD_DEL
    .long TH_ACCENT              # CARD_HUNK
    .long TH_ACCENT              # MD_ACCENT (markdown heading/bullet)
    .long TH_THINKING            # MD_THINK  (fenced code body)

# View style-byte attribute bits: the high three bits carry A_BOLD/A_DIM and a
# private italic flag; the id is the low 5 bits (VS_MAX <= 31).
.equ VSA_BOLD,   0x20
.equ VSA_DIM,    0x40
.equ VSA_ITALIC, 0x80
.equ VS_ID_MASK, 0x1F

.text

# utf8dec(ptr, len) -> rax=cp, rdx=bytes (1 with U+FFFD on invalid/empty)
# Thin alias for the shared decoder src/base/uni.s:utf8_decode, so the view
# layer and the composer cannot disagree on strict UTF-8 handling.
.globl utf8dec
utf8dec:
    jmp utf8_decode

# view_new_row(v): advance to a fresh row (leaf)
view_new_row:
    mov eax, [rdi + Vrows]
    cmp eax, V_MAX
    jae .Lnr_cap
    inc eax
    mov [rdi + Vrows], eax
    mov dword ptr [rdi + Vlast], 0
    mov dword ptr [rdi + Vcol], 0
    mov dword ptr [rdi + Vbg], 0
    ret
.Lnr_cap:
    # saturate: view_append_span stops once Vrows == V_MAX, so the row buffer
    # can never be written past V_MAX * V_STRIDE
    mov dword ptr [rdi + Vrows], V_MAX
    mov dword ptr [rdi + Vlast], 0
    mov dword ptr [rdi + Vcol], 0
    mov dword ptr [rdi + Vbg], 0
    ret

# view_finish_row(v): commit the in-progress row's byte length and advance.
# Every row-ending path (newline, width wrap, full row, break) records the
# length here so a wrapped row is never left reporting 0 bytes.
view_finish_row:
    mov eax, [rdi + Vrows]
    cmp eax, V_MAX
    jae 1f
    mov rcx, [rdi + Vlen]
    mov edx, [rdi + Vlast]
    mov [rcx + rax*2], dx
    mov rcx, [rdi + Vrowbg]
    mov edx, [rdi + Vbg]
    mov [rcx + rax*4], edx
1:  jmp view_new_row

# view_init(v, width) -> 0
FN view_init
    PROLOGUE
    mov r12, rdi
    mov r13d, esi
    cmp r13d, V_HARDCOLS
    jbe 1f
    mov r13d, V_HARDCOLS
1:  mov qword ptr [rdi + Vdata], 0
    mov qword ptr [rdi + Vlen], 0
    mov qword ptr [rdi + Vrowbg], 0
    xor eax, eax
    mov ecx, V_SIZE / 4
    mov rdi, r12
2:  mov [rdi], eax
    add rdi, 4
    dec ecx
    jnz 2b
    mov [r12 + Vw], r13d
    mov edi, V_MAX * V_STRIDE
    call mem_alloc
    mov [r12 + Vdata], rax
    mov edi, V_MAX * 2
    call mem_alloc
    mov [r12 + Vlen], rax
    mov edi, V_MAX * 4
    call mem_alloc
    mov [r12 + Vrowbg], rax
    xor eax, eax
    EPILOGUE

FN view_free
    PROLOGUE
    mov r12, rdi
    mov rdi, [r12 + Vdata]
    call mem_free
    mov rdi, [r12 + Vlen]
    call mem_free
    mov rdi, [r12 + Vrowbg]
    call mem_free
    mov qword ptr [r12 + Vdata], 0
    mov qword ptr [r12 + Vlen], 0
    mov qword ptr [r12 + Vrowbg], 0
    EPILOGUE

FN view_clear
    mov dword ptr [rdi + Vrows], 0
    mov dword ptr [rdi + Vlast], 0
    mov dword ptr [rdi + Vcol], 0
    mov dword ptr [rdi + Vtop], 0
    mov dword ptr [rdi + Vmark], 0
    ret

# view_total(v) -> visible row count including the partial last row (leaf)
FN view_total
    mov eax, [rdi + Vrows]
    cmp dword ptr [rdi + Vlast], 0
    je 1f
    inc eax
1:  ret

# view_append_span(v rdi, style esi, ptr rdx, len rcx)
FN view_append_span
    PROLOGUE
    mov r12, rdi                # v
    mov r13d, esi               # style
    mov r14, rdx                # ptr
    mov r15, rcx                # len
    xor ebx, ebx                # i
.Lva_loop:
    cmp rbx, r15
    jae .Lva_done
    movzx eax, byte ptr [r14 + rbx]
    cmp al, 10
    jne .Lva_cp
    # newline: commit the row even when it is empty, so consecutive newlines
    # produce real blank rows instead of collapsing together
    inc rbx
    mov rdi, r12
    call view_finish_row
    jmp .Lva_loop
.Lva_cp:
    lea rdi, [r14 + rbx]
    mov rsi, r15
    sub rsi, rbx
    call utf8dec
    mov r8, rax                 # cp
    mov r9, rdx                 # byte length
    mov edi, r8d
    call view_wcwidth
    mov r8d, eax                # display width
    # wrap before placing a codepoint that would exceed the display width, or
    # the 256-byte hard row capacity (multibyte text can hit it first)
    mov eax, [r12 + Vcol]
    add eax, r8d
    cmp eax, [r12 + Vw]
    ja .Lva_wrap
    mov eax, [r12 + Vlast]
    add eax, r9d
    cmp eax, V_HARDCOLS
    jbe .Lva_place
.Lva_wrap:
    cmp dword ptr [r12 + Vlast], 0
    je .Lva_place
    mov rdi, r12
    call view_finish_row
.Lva_place:
    mov eax, [r12 + Vrows]
    cmp eax, V_MAX
    jae .Lva_done
    mov rcx, V_STRIDE
    imul rcx, rax
    add rcx, [r12 + Vdata]
    mov edx, [r12 + Vlast]
    cmp edx, V_HARDCOLS      # defence in depth: never write into V_STYLE
    jae .Lva_done
    # copy the bytes, per-byte style
    xor r10d, r10d
.Lva_copy:
    cmp r10, r9
    jae .Lva_copied
    mov al, [r14 + rbx]
    mov [rcx + rdx], al
    mov byte ptr [rcx + V_STYLE + rdx], r13b
    inc rbx
    inc r10
    inc edx
    jmp .Lva_copy
.Lva_copied:
    mov [r12 + Vlast], edx
    add [r12 + Vcol], r8d
    # store the finished row length when the row is full by display width
    mov eax, [r12 + Vcol]
    cmp eax, [r12 + Vw]
    jb .Lva_loop
    mov rdi, r12
    call view_finish_row
    jmp .Lva_loop
.Lva_done:
    EPILOGUE

# view_break(v): end the current row if it has content. A row already empty
# because a newline just committed it must not gain a second blank row; blank
# lines in span text come from the newline branch in view_append_span.
FN view_break
    cmp dword ptr [rdi + Vlast], 0
    je 1f
    jmp view_finish_row
1:  xor eax, eax
    ret

# view_mark(v) -> mark
FN view_mark
    call view_total
    mov [rdi + Vmark], eax
    mov dword ptr [rdi + Vlast], 0
    mov dword ptr [rdi + Vcol], 0
    ret

# view_truncate(v, mark)
FN view_truncate
    cmp esi, [rdi + Vrows]
    ja 1f
    mov [rdi + Vrows], esi
1:  mov dword ptr [rdi + Vlast], 0
    mov dword ptr [rdi + Vcol], 0
    ret

# view_rows(v) -> total rows (text)
FN view_rows
    jmp view_total

# view_row_text(v, i) -> ptr
FN view_row_text
    mov rax, V_STRIDE
    mov ecx, esi
    imul rax, rcx
    add rax, [rdi + Vdata]
    ret

# view_row_len(v, i) -> len (partial last row uses Vlast)
FN view_row_len
    cmp esi, [rdi + Vrows]
    jne 1f
    mov eax, [rdi + Vlast]
    ret
1:  mov rax, [rdi + Vlen]
    movzx eax, word ptr [rax + rsi*2]
    ret

# view_row_bg(v, i) -> eax: band colour of a committed row (0 = terminal bg)
FN view_row_bg
    mov rax, [rdi + Vrowbg]
    mov eax, [rax + rsi*4]
    ret

# view_set_bg(v, bg): band colour applied to rows finished from now on
FN view_set_bg
    mov [rdi + Vbg], esi
    xor eax, eax
    ret

# view_text_width(ptr, len) -> rax: display columns (wcwidth sum)
FN view_text_width
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    xor r14d, r14d
1:  test r13, r13
    jz 2f
    mov rdi, r12
    mov rsi, r13
    call utf8dec
    mov r15, rdx
    mov edi, eax
    call view_wcwidth
    add r14d, eax
    add r12, r15
    sub r13, r15
    jmp 1b
2:  mov eax, r14d
    EPILOGUE

# view_set_vp(v, x, y, w, h)
FN view_set_vp
    mov [rdi + Vvx], esi
    mov [rdi + Vvy], edx
    mov [rdi + Vvw], ecx
    mov [rdi + Vvh], r8d
    xor eax, eax
    ret

# view_scroll(v, delta)
FN view_scroll
    call view_total
    mov rcx, rax
    mov eax, [rdi + Vvh]
    sub rcx, rax
    jns 1f
    xor ecx, ecx
1:  mov eax, [rdi + Vtop]
    add eax, esi
    jns 2f
    xor eax, eax
2:  cmp rax, rcx
    jbe 3f
    mov eax, ecx
3:  mov [rdi + Vtop], eax
    xor eax, eax
    ret

# view_scroll_bottom(v)
FN view_scroll_bottom
    call view_total
    mov rcx, rax
    mov eax, [rdi + Vvh]
    sub rcx, rax
    jns 1f
    xor ecx, ecx
1:  mov [rdi + Vtop], ecx
    xor eax, eax
    ret

# view_style_color(style) -> u32 ARGB resolved from the active theme (leaf-ish)
.globl view_style_color
view_style_color:
    mov edi, edi
    and edi, VS_ID_MASK
    xor eax, eax
    test edi, edi
    jz .Lvsc_default
    cmp edi, VS_MAX
    ja .Lvsc_default
    lea rax, [rip + .v_style_slot]
    mov esi, [rax + rdi*4]
    jmp theme_rgb
.Lvsc_default:
    mov esi, TH_FG
    jmp theme_rgb

# view_style_attrs(style) -> eax: A_BOLD/A_DIM from the high bits (leaf)
.globl view_style_attrs
view_style_attrs:
    xor eax, eax
    test edi, VSA_BOLD
    jz 1f
    or eax, 1
1:  test edi, VSA_DIM
    jz 2f
    or eax, 4
2:  test edi, VSA_ITALIC
    jz 3f
    or eax, 16
3:  ret

# view_wcwidth(cp edi) -> eax: 0 combining/zero-width, 2 wide/emoji, else 1.
# Defer to the shared src/base/uni.s table so the composer measure pass, the
# transcript wrap and the grid emitter can never disagree.  Leaf tail call.
.globl view_wcwidth
view_wcwidth:
    jmp utf8_wcwidth

# view_draw(v, grid, fg, bg): draw the viewport
FN view_draw
    PROLOGUE 80
    mov r12, rdi                # v
    mov r13, rsi                # grid
    mov r14d, edx               # fg (unused; styles carry colors)
    mov r15d, ecx               # bg
    xor ebx, ebx                # screen row
.Lvd_row:
    cmp ebx, [r12 + Vvh]
    jae .Lvd_done
    mov eax, [r12 + Vtop]
    add eax, ebx
    mov [rsp + 0], rax          # row index
    # Per-row background band. A card row is filled edge to edge with its
    # band first; text then draws on top with the same bg so the SGR the
    # tail erase uses carries the band to the terminal's right edge.
    mov rcx, [r12 + Vrowbg]
    mov eax, [rcx + rax*4]      # row band (0 = none)
    mov [rsp + 64], eax
    test eax, eax
    jnz 1f
    mov eax, r15d
1:  mov [rsp + 68], eax         # effective bg
    mov eax, [rsp + 64]
    test eax, eax
    jz 2f
    sub rsp, 16
    mov eax, [rsp + 16 + 64]
    mov [rsp + 8], eax          # bg
    mov dword ptr [rsp], 0      # fg
    mov rdi, r13
    mov esi, [r12 + Vvx]
    mov edx, [r12 + Vvy]
    add edx, ebx
    mov ecx, [r12 + Vvw]
    mov r8d, 1
    mov r9d, ' '
    call grid_fill
    add rsp, 16
2:  mov rdi, r12
    mov esi, [rsp + 0]
    call view_row_len
    mov [rsp + 16], rax         # byte length
    mov rdi, r12
    mov esi, [rsp + 0]
    call view_row_text
    mov [rsp + 24], rax         # text ptr
    mov qword ptr [rsp + 40], 0 # byte cursor
    mov qword ptr [rsp + 48], 0 # display column
.Lvd_cell:
    mov r10, [rsp + 40]
    cmp r10, [rsp + 16]
    jae .Lvd_next
    mov r8, [rsp + 24]
    lea rdi, [r8 + r10]
    mov rsi, [rsp + 16]
    sub rsi, r10
    call utf8dec
    mov [rsp + 8], rax          # cp
    mov [rsp + 32], rdx         # byte length
    mov edi, eax
    call view_wcwidth
    mov [rsp + 56], rax         # display width
    mov rax, V_STRIDE
    mov rcx, [rsp + 0]
    imul rax, rcx
    add rax, [r12 + Vdata]
    mov rcx, [rsp + 40]
    movzx edi, byte ptr [rax + V_STYLE + rcx]
    mov [rsp + 72], edi
    call view_style_color
    mov r9d, eax                # fg
    mov edi, [rsp + 72]
    call view_style_attrs
    mov [rsp + 72], rax         # attrs
    sub rsp, 16
    mov rax, [rsp + 72 + 16]
    mov [rsp], rax              # attrs
    mov rdi, r13
    mov esi, [r12 + Vvx]
    add esi, dword ptr [rsp + 48 + 16]
    mov edx, [r12 + Vvy]
    add edx, ebx
    mov ecx, dword ptr [rsp + 8 + 16]
    mov r8d, r9d
    mov r9d, [rsp + 16 + 68]
    call grid_put
    add rsp, 16
    mov rax, [rsp + 32]
    add [rsp + 40], rax         # advance one UTF-8 sequence
    mov rax, [rsp + 56]
    add [rsp + 48], rax         # advance by display width
    jmp .Lvd_cell
.Lvd_next:
    inc ebx
    jmp .Lvd_row
.Lvd_done:
    xor eax, eax
    EPILOGUE
