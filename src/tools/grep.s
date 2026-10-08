.include "opcode.inc"
.include "core/core.inc"
# grep tool: recursive content search. Args {pattern, path?, glob?,
# ignore_case?, literal?, context?, limit?}.  Walking matches find (depth 32,
# entry cap 20000, sorted directories) and additionally skips .git,
# node_modules and build.  Files <= 2 MB are scanned; a NUL in the first 8 KiB
# marks a binary and skips it.  A literal substring is used when "literal" is
# true, otherwise the pattern is a small regex: '.', '*', '^', '$', [sets] and
# '\\' escapes.  Output: path:line:text, 500-byte line cap, context lines
# before/after, limit 100 matches.  Contract: src/core/API.md.

.equ GR_DEFAULT_LIMIT, 100
.equ GR_MAX_FILE,      2097152
.equ GR_MAX_LINE,      500
.equ TOK_CHAR, 1
.equ TOK_ANY,  2
.equ TOK_SET,  3
.equ TOK_BOL,  4
.equ TOK_EOL,  5
.equ TOK_STAR, 6

# execution context, also handed to search_walk as the callback context
.equ GC_JOB,        0
.equ GC_GLOB,       8
.equ GC_GLOB_SLASH, 16
.equ GC_PATTERN,    24
.equ GC_PATLEN,     32
.equ GC_ICASE,      40
.equ GC_LITERAL,    48
.equ GC_CONTEXT,    56
.equ GC_LIMIT,      64
.equ GC_FOUND,      72
.equ GC_BUF,        80
.equ GC_CHUNK,      88
.equ GC_MLINES,     96
.equ GC_TOKENS,     104
.equ GC_SETS,       112
.equ GC_NTOK,       120
.equ GC_LINE,       128
.equ GC_LINELEN,    136
.equ GC_GLOB_ROOTLEN, 144

.section .rodata
.Lname:    .asciz "grep"
.Llabel:   .asciz "grep"
.Ldesc:    .asciz "Search file contents with a literal or small regex; returns path:line:text with optional context lines; each output line is truncated to 500 bytes."
.Lparams:  .asciz "{\"type\":\"object\",\"properties\":{\"pattern\":{\"type\":\"string\",\"description\":\"Text or regex to search for\"},\"path\":{\"type\":\"string\",\"description\":\"File or directory (default .)\"},\"glob\":{\"type\":\"string\",\"description\":\"Only search files matching this glob\"},\"ignore_case\":{\"type\":\"boolean\",\"description\":\"Case-insensitive search\"},\"literal\":{\"type\":\"boolean\",\"description\":\"Treat pattern as plain text\"},\"context\":{\"type\":\"integer\",\"description\":\"Lines of context around matches\"},\"limit\":{\"type\":\"integer\",\"description\":\"Maximum matches to return\"}},\"required\":[\"pattern\"]}"
.Lpattern:  .asciz "pattern"
.Lpath:     .asciz "path"
.Lglob:     .asciz "glob"
.Licase:    .asciz "ignore_case"
.Lliteral:  .asciz "literal"
.Lcontext:  .asciz "context"
.Llimit:    .asciz "limit"
.Ldot:      .asciz "."
.Lgit:      .asciz ".git"
.Lnode:     .asciz "node_modules"
.Lbuild:    .asciz "build"
.Lerr_open: .asciz "error: cannot open "
.Lbadargs:  .asciz "error: invalid arguments"

.section .data
.p2align 3
grep_tl:
    .quad .Lname
    .quad .Llabel
    .quad .Ldesc
    .quad .Lparams
    .long TL_READONLY | TL_SEQUENTIAL
    .long 0
    .quad grep_exec
    .quad 0

.text

# grep_tool_init() -> 0 | -ENOSPC
FN grep_tool_init
    lea rdi, [rip + grep_tl]
    jmp tools_add

# ------------------------------------------------------------- local helpers
# g_basename(cstr) -> ptr to the last path component
g_basename:
    mov rax, rdi
1:  mov cl, [rdi]
    test cl, cl
    jz 2f
    cmp cl, '/'
    jne 3f
    lea rax, [rdi + 1]
3:  inc rdi
    jmp 1b
2:  ret

# g_cstr_eq(a, b) -> 1 | 0
g_cstr_eq:
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

# grep_tok_push(sb, type, val)
FN grep_tok_push
    PROLOGUE 16
    mov dword ptr [rsp], esi
    mov dword ptr [rsp + 4], 0
    mov [rsp + 8], rdx
    mov rsi, rsp
    mov edx, 16
    call sb_push
    EPILOGUE

# grep_set_test(bitmap, ch) -> 1 | 0
FN grep_set_test
    mov ecx, esi
    bt qword ptr [rdi], rcx
    setc al
    movzx eax, al
    ret

# ------------------------------------------------------------------ compile
.equ CMP_NEG, 0
.equ CMP_FIRST, 8
.equ CMP_VALID, 16
.equ CMP_LO, 24
.equ CMP_HI, 32
.equ CMP_OFF, 40
.equ CMP_BITMAP, 48

FN grep_compile
    PROLOGUE 96
    mov rbx, rdi
    mov r12, [rbx + GC_PATTERN]
    mov rdi, r12
    call strlen
    lea r13, [r12 + rax]
    mov r14, [rbx + GC_ICASE]
    mov qword ptr [rbx + GC_NTOK], 0
.Lgc_loop:
    cmp r12, r13
    jae .Lgc_done
    movzx eax, byte ptr [r12]
    inc r12
    cmp eax, '*'
    je .Lgc_star
    cmp eax, '.'
    je .Lgc_any
    cmp eax, '^'
    je .Lgc_bol
    cmp eax, '$'
    je .Lgc_eol
    cmp eax, '\\'
    je .Lgc_esc
    cmp eax, '['
    je .Lgc_set
.Lgc_char:
    mov rdi, [rbx + GC_TOKENS]
    mov esi, TOK_CHAR
    mov edx, eax
    call grep_tok_push
    inc qword ptr [rbx + GC_NTOK]
    jmp .Lgc_loop
.Lgc_any:
    mov rdi, [rbx + GC_TOKENS]
    mov esi, TOK_ANY
    xor edx, edx
    call grep_tok_push
    inc qword ptr [rbx + GC_NTOK]
    jmp .Lgc_loop
.Lgc_bol:
    mov rdi, [rbx + GC_TOKENS]
    mov esi, TOK_BOL
    xor edx, edx
    call grep_tok_push
    inc qword ptr [rbx + GC_NTOK]
    jmp .Lgc_loop
.Lgc_eol:
    mov rdi, [rbx + GC_TOKENS]
    mov esi, TOK_EOL
    xor edx, edx
    call grep_tok_push
    inc qword ptr [rbx + GC_NTOK]
    jmp .Lgc_loop
.Lgc_esc:
    cmp r12, r13
    jae .Lgc_char
    movzx eax, byte ptr [r12]
    inc r12
    jmp .Lgc_char
.Lgc_star:
    mov rax, [rbx + GC_NTOK]
    test rax, rax
    jz .Lgc_loop
    mov rcx, [rbx + GC_TOKENS]
    mov rcx, [rcx + SB_ptr]
    dec rax
    shl rax, 4
    add rcx, rax
    mov eax, [rcx]
    cmp eax, TOK_STAR
    je .Lgc_loop
    cmp eax, TOK_BOL
    je .Lgc_loop
    cmp eax, TOK_EOL
    je .Lgc_loop
    mov rdi, [rbx + GC_TOKENS]
    mov esi, TOK_STAR
    xor edx, edx
    call grep_tok_push
    inc qword ptr [rbx + GC_NTOK]
    jmp .Lgc_loop

.Lgc_set:
    mov r15, r12
    mov qword ptr [rsp + CMP_NEG], 0
    cmp r15, r13
    jae .Lgc_set_bad
    cmp byte ptr [r15], '^'
    jne 1f
    mov qword ptr [rsp + CMP_NEG], 1
    inc r15
1:  lea rdi, [rsp + CMP_BITMAP]
    xor eax, eax
    mov ecx, 4
    rep stosq
    mov qword ptr [rsp + CMP_FIRST], 1
    xor r9d, r9d
.Lgc_setloop:
    cmp r15, r13
    jae .Lgc_setend
    movzx eax, byte ptr [r15]
    cmp eax, ']'
    jne .Lgc_setitem
    cmp qword ptr [rsp + CMP_FIRST], 0
    je .Lgc_setclose
    jmp .Lgc_setitem
.Lgc_setclose:
    inc r15
    mov r9d, 1
    jmp .Lgc_setend
.Lgc_setitem:
    inc r15
    mov qword ptr [rsp + CMP_FIRST], 0
    cmp eax, '\\'
    jne 1f
    cmp r15, r13
    jae 2f
    movzx eax, byte ptr [r15]
    inc r15
1:  cmp r15, r13
    jae .Lgc_setone
    cmp byte ptr [r15], '-'
    jne .Lgc_setone
    lea rcx, [r15 + 1]
    cmp rcx, r13
    jae .Lgc_setone
    movzx edx, byte ptr [r15 + 1]
    cmp edx, ']'
    je .Lgc_setone
    add r15, 2
    mov [rsp + CMP_LO], eax
    mov [rsp + CMP_HI], edx
.Lgc_rangefill:
    mov ecx, [rsp + CMP_LO]
    cmp ecx, [rsp + CMP_HI]
    ja .Lgc_setloop
    bts qword ptr [rsp + CMP_BITMAP], rcx
    inc dword ptr [rsp + CMP_LO]
    jmp .Lgc_rangefill
.Lgc_setone:
    mov ecx, eax
    bts qword ptr [rsp + CMP_BITMAP], rcx
    jmp .Lgc_setloop
2:  jmp .Lgc_setloop
.Lgc_setend:
    test r9d, r9d
    jz .Lgc_set_bad
    test r14, r14
    jz .Lgc_setneg
    xor ecx, ecx
.Lgc_fold:
    cmp ecx, 256
    jae .Lgc_setneg
    bt qword ptr [rsp + CMP_BITMAP], rcx
    jnc .Lgc_foldnext
    mov eax, ecx
    mov edx, eax
    sub edx, 65
    cmp edx, 25
    ja 1f
    add eax, 32
1:  bts qword ptr [rsp + CMP_BITMAP], rax
    mov eax, ecx
    mov edx, eax
    sub edx, 97
    cmp edx, 25
    ja 2f
    sub eax, 32
2:  bts qword ptr [rsp + CMP_BITMAP], rax
.Lgc_foldnext:
    inc ecx
    jmp .Lgc_fold
.Lgc_setneg:
    cmp qword ptr [rsp + CMP_NEG], 0
    je 1f
    mov rax, [rsp + CMP_BITMAP]
    not rax
    mov [rsp + CMP_BITMAP], rax
    mov rax, [rsp + CMP_BITMAP + 8]
    not rax
    mov [rsp + CMP_BITMAP + 8], rax
    mov rax, [rsp + CMP_BITMAP + 16]
    not rax
    mov [rsp + CMP_BITMAP + 16], rax
    mov rax, [rsp + CMP_BITMAP + 24]
    not rax
    mov [rsp + CMP_BITMAP + 24], rax
1:  mov rdi, [rbx + GC_SETS]
    mov rax, [rdi + SB_len]
    mov [rsp + CMP_OFF], rax
    mov rsi, rsp
    add rsi, CMP_BITMAP
    mov edx, 32
    call sb_push
    mov rdi, [rbx + GC_TOKENS]
    mov esi, TOK_SET
    mov rdx, [rsp + CMP_OFF]
    call grep_tok_push
    inc qword ptr [rbx + GC_NTOK]
    mov r12, r15
    jmp .Lgc_loop
.Lgc_set_bad:
    mov rdi, [rbx + GC_TOKENS]
    mov esi, TOK_CHAR
    mov edx, '['
    call grep_tok_push
    inc qword ptr [rbx + GC_NTOK]
    jmp .Lgc_loop
.Lgc_done:
    xor eax, eax
    EPILOGUE

# --------------------------------------------------------------- matchers
# grep_atom_char(ctx, tokptr, ch) -> 1 | 0 (single consuming atom)
FN grep_atom_char
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov eax, [r12]
    cmp eax, TOK_ANY
    je .Lgac_yes
    cmp eax, TOK_CHAR
    je .Lgac_char
    cmp eax, TOK_SET
    je .Lgac_set
    xor eax, eax
    EPILOGUE
.Lgac_char:
    mov eax, [r12 + 8]
    cmp qword ptr [rbx + GC_ICASE], 0
    je .Lgac_cmp
    mov ecx, eax
    sub ecx, 65
    cmp ecx, 25
    ja 1f
    add eax, 32
1:  mov ecx, r13d
    sub ecx, 65
    cmp ecx, 25
    ja 2f
    add r13d, 32
2:
.Lgac_cmp:
    cmp eax, r13d
    sete al
    movzx eax, al
    EPILOGUE
.Lgac_set:
    mov rdi, [rbx + GC_SETS]
    mov rdi, [rdi + SB_ptr]
    add rdi, [r12 + 8]
    mov esi, r13d
    call grep_set_test
    EPILOGUE
.Lgac_yes:
    mov eax, 1
    EPILOGUE

# grep_re_at(ctx, ti, pos) -> 1 | 0: pattern matches a prefix at pos
.equ RA_TOK, 0
.equ RA_TYPE, 8
.equ RA_STAR, 16
.equ RA_POS2, 24
.equ RA_CNT, 32
FN grep_re_at
    PROLOGUE 64
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rax, [rbx + GC_NTOK]
    cmp r12, rax
    jae .Lra_yes
    mov rcx, [rbx + GC_TOKENS]
    mov rcx, [rcx + SB_ptr]
    mov rax, r12
    shl rax, 4
    add rcx, rax
    mov [rsp + RA_TOK], rcx
    mov eax, [rcx]
    mov [rsp + RA_TYPE], rax
    cmp eax, TOK_STAR
    jne 1f
    mov rdi, rbx
    lea rsi, [r12 + 1]
    mov rdx, r13
    call grep_re_at
    EPILOGUE
1:  mov qword ptr [rsp + RA_STAR], 0
    lea rax, [r12 + 1]
    cmp rax, [rbx + GC_NTOK]
    jae 2f
    mov rdx, [rbx + GC_TOKENS]
    mov rdx, [rdx + SB_ptr]
    shl rax, 4
    mov edx, [rdx + rax]
    cmp edx, TOK_STAR
    jne 2f
    mov qword ptr [rsp + RA_STAR], 1
2:  cmp qword ptr [rsp + RA_STAR], 0
    jne .Lra_star
    mov eax, [rsp + RA_TYPE]
    cmp eax, TOK_BOL
    je .Lra_bol
    cmp eax, TOK_EOL
    je .Lra_eol
    mov rax, [rbx + GC_LINELEN]
    cmp r13, rax
    jae .Lra_no
    mov rdi, rbx
    mov rsi, [rsp + RA_TOK]
    mov rdx, [rbx + GC_LINE]
    movzx edx, byte ptr [rdx + r13]
    call grep_atom_char
    test eax, eax
    jz .Lra_no
    mov rdi, rbx
    lea rsi, [r12 + 1]
    lea rdx, [r13 + 1]
    call grep_re_at
    EPILOGUE
.Lra_bol:
    test r13, r13
    jnz .Lra_no
    mov rdi, rbx
    lea rsi, [r12 + 1]
    mov rdx, r13
    call grep_re_at
    EPILOGUE
.Lra_eol:
    mov rax, [rbx + GC_LINELEN]
    cmp r13, rax
    jne .Lra_no
    mov rdi, rbx
    lea rsi, [r12 + 1]
    mov rdx, r13
    call grep_re_at
    EPILOGUE
.Lra_star:
    mov [rsp + RA_POS2], r13
.Lra_starcount:
    mov rax, [rsp + RA_POS2]
    mov rcx, [rbx + GC_LINELEN]
    cmp rax, rcx
    jae .Lra_starback_init
    mov rdi, rbx
    mov rsi, [rsp + RA_TOK]
    mov rdx, [rbx + GC_LINE]
    movzx edx, byte ptr [rdx + rax]
    call grep_atom_char
    test eax, eax
    jz .Lra_starback_init
    inc qword ptr [rsp + RA_POS2]
    jmp .Lra_starcount
.Lra_starback_init:
    mov rax, [rsp + RA_POS2]
    sub rax, r13
    mov [rsp + RA_CNT], rax
.Lra_starback:
    mov rdx, r13
    add rdx, [rsp + RA_CNT]
    mov rdi, rbx
    lea rsi, [r12 + 2]
    call grep_re_at
    test eax, eax
    jnz .Lra_yes
    cmp qword ptr [rsp + RA_CNT], 0
    je .Lra_no
    dec qword ptr [rsp + RA_CNT]
    jmp .Lra_starback
.Lra_yes:
    mov eax, 1
    EPILOGUE
.Lra_no:
    xor eax, eax
    EPILOGUE

# grep_lit_find(hay, hlen, needle, nlen, icase) -> index | -1
FN grep_lit_find
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov r15, r8
    test r14, r14
    jz .Llf_zero
    cmp r14, r12
    ja .Llf_no
    sub r12, r14
    mov [rsp], r12
    xor r8d, r8d
.Llf_outer:
    cmp r8, [rsp]
    ja .Llf_no
    xor r9d, r9d
.Llf_inner:
    cmp r9, r14
    jae .Llf_found
    lea r10, [r8 + r9]
    movzx eax, byte ptr [rbx + r10]
    movzx edx, byte ptr [r13 + r9]
    test r15, r15
    jz .Llf_cmp
    mov ecx, eax
    sub ecx, 65
    cmp ecx, 25
    ja 1f
    add eax, 32
1:  mov ecx, edx
    sub ecx, 65
    cmp ecx, 25
    ja 2f
    add edx, 32
2:
.Llf_cmp:
    cmp eax, edx
    jne .Llf_next
    inc r9
    jmp .Llf_inner
.Llf_next:
    inc r8
    jmp .Llf_outer
.Llf_found:
    mov rax, r8
    EPILOGUE
.Llf_zero:
    xor eax, eax
    EPILOGUE
.Llf_no:
    mov rax, -1
    EPILOGUE

# grep_line_match(ctx, lineptr, linelen) -> 1 | 0
FN grep_line_match
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    cmp qword ptr [rbx + GC_LITERAL], 0
    je .Llm_re
    mov rdi, r12
    mov rsi, r13
    mov rdx, [rbx + GC_PATTERN]
    mov rcx, [rbx + GC_PATLEN]
    mov r8, [rbx + GC_ICASE]
    call grep_lit_find
    cmp rax, -1
    setne al
    movzx eax, al
    EPILOGUE
.Llm_re:
    mov [rbx + GC_LINE], r12
    mov [rbx + GC_LINELEN], r13
    xor r12d, r12d
.Llm_try:
    cmp r12, r13
    ja .Llm_no
    mov rdi, rbx
    xor esi, esi
    mov rdx, r12
    call grep_re_at
    test eax, eax
    jnz .Llm_yes
    mov rax, [rbx + GC_NTOK]
    test rax, rax
    jz .Llm_no
    mov rax, [rbx + GC_TOKENS]
    mov rax, [rax + SB_ptr]
    cmp dword ptr [rax], TOK_BOL
    je .Llm_no
    inc r12
    jmp .Llm_try
.Llm_yes:
    mov eax, 1
    EPILOGUE
.Llm_no:
    xor eax, eax
    EPILOGUE

# ------------------------------------------------------------------ scan one file
.equ GF_FD, 0
.equ GF_STAT, 16
.equ GF_E, 160
.equ GF_NM, 168
.equ GF_MI, 176
.equ GF_LN, 184
.equ GF_POS, 192
.equ GF_FROM, 200
.equ GF_TO, 208

FN grep_file
    PROLOGUE 224
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rsi
    mov esi, O_CLOEXEC | O_NONBLOCK
    xor edx, edx
    call os_open
    test rax, rax
    js .Lgf_ret
    mov [rsp + GF_FD], rax
    mov rdi, rax
    lea rsi, [rsp + GF_STAT]
    call os_fstat
    test rax, rax
    js .Lgf_close
    mov eax, [rsp + GF_STAT + 24]
    and eax, 0xF000
    cmp eax, 0x8000
    jne .Lgf_close
    mov rax, [rsp + GF_STAT + 48]
    cmp rax, GR_MAX_FILE
    ja .Lgf_close
    mov rdi, [rbx + GC_BUF]
    call sb_clear
.Lgf_read:
    mov edi, [rsp + GF_FD]
    mov rsi, [rbx + GC_CHUNK]
    mov edx, 65536
    call os_read
    test rax, rax
    js .Lgf_readerr
    jz .Lgf_readdone
    mov rdi, [rbx + GC_BUF]
    mov rsi, [rbx + GC_CHUNK]
    mov rdx, rax
    call sb_push
    mov rax, [rbx + GC_BUF]
    mov rax, [rax + SB_len]
    cmp rax, GR_MAX_FILE
    ja .Lgf_close
    jmp .Lgf_read
.Lgf_readerr:
    cmp rax, -EINTR
    je .Lgf_read
    jmp .Lgf_close
.Lgf_readdone:
    mov rdi, [rsp + GF_FD]
    call os_close
    mov qword ptr [rsp + GF_FD], -1
    mov rax, [rbx + GC_BUF]
    mov rdi, [rax + SB_ptr]
    mov rsi, [rax + SB_len]
    test rsi, rsi
    jz .Lgf_ret
    cmp rsi, 8192
    jbe 1f
    mov esi, 8192
1:  xor ecx, ecx
.Lgf_sniff:
    cmp rcx, rsi
    jae .Lgf_text
    cmp byte ptr [rdi + rcx], 0
    je .Lgf_ret
    inc rcx
    jmp .Lgf_sniff
.Lgf_text:
    mov rax, [rbx + GC_MLINES]
    mov qword ptr [rax + VEC_len], 0
    xor r13d, r13d
    mov r14, 1
.Lgf_scan:
    mov rax, [rbx + GC_BUF]
    mov rcx, [rax + SB_len]
    cmp r13, rcx
    jae .Lgf_emit
    mov rdi, [rax + SB_ptr]
    mov r15, r13
.Lgf_eol:
    cmp r15, rcx
    jae .Lgf_eoldone
    cmp byte ptr [rdi + r15], 10
    je .Lgf_eoldone
    inc r15
    jmp .Lgf_eol
.Lgf_eoldone:
    mov [rsp + GF_E], r15
    mov rdi, rbx
    mov rsi, [rbx + GC_BUF]
    mov rsi, [rsi + SB_ptr]
    add rsi, r13
    mov rdx, r15
    sub rdx, r13
    call grep_line_match
    test eax, eax
    jz .Lgf_scannext
    mov rdi, [rbx + GC_MLINES]
    mov esi, 8
    call vec_push
    mov [rax], r14
    inc qword ptr [rbx + GC_FOUND]
    mov rax, [rbx + GC_FOUND]
    cmp rax, [rbx + GC_LIMIT]
    jae .Lgf_emit
.Lgf_scannext:
    mov r13, [rsp + GF_E]
    inc r13
    inc r14
    jmp .Lgf_scan
.Lgf_emit:
    mov rax, [rbx + GC_MLINES]
    mov rax, [rax + VEC_len]
    test rax, rax
    jz .Lgf_ret
    mov qword ptr [rsp + GF_MI], 0
    mov qword ptr [rsp + GF_LN], 1
    mov qword ptr [rsp + GF_POS], 0
.Lgf_emit_loop:
    mov rcx, [rbx + GC_MLINES]
    mov rax, [rsp + GF_MI]
    cmp rax, [rcx + VEC_len]
    jae .Lgf_ret
    mov rcx, [rcx + VEC_ptr]
    mov rcx, [rcx + rax*8]
    mov [rsp + GF_NM], rcx
    mov rdx, [rbx + GC_CONTEXT]
    mov rax, rcx
    sub rax, rdx
    cmp rax, 1
    jg 1f
    mov eax, 1
1:  mov [rsp + GF_FROM], rax
    add rcx, rdx
    mov [rsp + GF_TO], rcx
.Lgf_skip:
    mov rax, [rsp + GF_LN]
    cmp rax, [rsp + GF_FROM]
    jae .Lgf_print
    mov rax, [rbx + GC_BUF]
    mov rcx, [rax + SB_len]
    mov rdx, [rsp + GF_POS]
    cmp rdx, rcx
    jae .Lgf_ret
    mov rdi, [rax + SB_ptr]
    mov rsi, rdx
2:  cmp rsi, rcx
    jae 3f
    cmp byte ptr [rdi + rsi], 10
    je 3f
    inc rsi
    jmp 2b
3:  inc rsi
    mov [rsp + GF_POS], rsi
    inc qword ptr [rsp + GF_LN]
    jmp .Lgf_skip
.Lgf_print:
    mov rax, [rsp + GF_LN]
    cmp rax, [rsp + GF_TO]
    ja .Lgf_nextmatch
    mov rax, [rbx + GC_BUF]
    mov rcx, [rax + SB_len]
    mov rdx, [rsp + GF_POS]
    cmp rdx, rcx
    jae .Lgf_nextmatch
    mov rdi, [rax + SB_ptr]
    mov rsi, rdx
4:  cmp rsi, rcx
    jae 5f
    cmp byte ptr [rdi + rsi], 10
    je 5f
    inc rsi
    jmp 4b
5:  mov [rsp + GF_E], rsi
    mov rdi, [rbx + GC_JOB]
    mov rdi, [rdi + J_out]
    mov rsi, r12
    call sb_push_cstr
    mov rdi, [rbx + GC_JOB]
    mov rdi, [rdi + J_out]
    mov esi, ':'
    call sb_push_byte
    mov rdi, [rbx + GC_JOB]
    mov rdi, [rdi + J_out]
    mov rsi, [rsp + GF_LN]
    call sb_push_u64
    mov rdi, [rbx + GC_JOB]
    mov rdi, [rdi + J_out]
    mov esi, ':'
    call sb_push_byte
    mov rax, [rbx + GC_BUF]
    mov rsi, [rax + SB_ptr]
    add rsi, [rsp + GF_POS]
    mov rdx, [rsp + GF_E]
    sub rdx, [rsp + GF_POS]
    cmp rdx, GR_MAX_LINE
    jbe 6f
    mov edx, GR_MAX_LINE
6:  mov rdi, [rbx + GC_JOB]
    mov rdi, [rdi + J_out]
    call sb_push
    mov rdi, [rbx + GC_JOB]
    mov rdi, [rdi + J_out]
    mov esi, 10
    call sb_push_byte
    mov rsi, [rsp + GF_E]
    inc rsi
    mov [rsp + GF_POS], rsi
    inc qword ptr [rsp + GF_LN]
    jmp .Lgf_print
.Lgf_nextmatch:
    inc qword ptr [rsp + GF_MI]
    jmp .Lgf_emit_loop
.Lgf_close:
    mov rdi, [rsp + GF_FD]
    cmp rdi, -1
    je .Lgf_ret
    call os_close
    mov qword ptr [rsp + GF_FD], -1
.Lgf_ret:
    EPILOGUE

# ------------------------------------------------------------------ callback
FN grep_cb
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rdx
    test esi, esi
    jz .Lgcb_file
    mov rdi, rbx
    call g_basename
    mov r13, rax
    mov rdi, r13
    lea rsi, [rip + .Lgit]
    call g_cstr_eq
    test eax, eax
    jnz .Lgcb_skip
    mov rdi, r13
    lea rsi, [rip + .Lnode]
    call g_cstr_eq
    test eax, eax
    jnz .Lgcb_skip
    mov rdi, r13
    lea rsi, [rip + .Lbuild]
    call g_cstr_eq
    test eax, eax
    jnz .Lgcb_skip
    xor eax, eax
    EPILOGUE
.Lgcb_skip:
    mov eax, 1
    EPILOGUE
.Lgcb_file:
    mov rax, [r12 + GC_GLOB]
    test rax, rax
    jz .Lgcb_scan
    cmp qword ptr [r12 + GC_GLOB_SLASH], 0
    je 1f
    mov rdi, rbx
    call strlen
    mov rcx, [r12 + GC_GLOB_ROOTLEN]
    lea rdx, [rbx + rcx]            # prefix already includes the separator
    lea rax, [rbx + rax]
    cmp rdx, rax
    ja .Lgcb_ret0
    mov r13, rdx
    jmp 2f
1:  mov rdi, rbx
    call g_basename
    mov r13, rax
2:  mov rdi, r13
    call strlen
    mov rdx, rax
    mov rdi, [r12 + GC_GLOB]
    mov rsi, r13
    call search_glob
    test eax, eax
    jz .Lgcb_ret0
.Lgcb_scan:
    mov rdi, r12
    mov rsi, rbx
    call grep_file
    mov rax, [r12 + GC_FOUND]
    cmp rax, [r12 + GC_LIMIT]
    jae .Lgcb_abort
.Lgcb_ret0:
    xor eax, eax
    EPILOGUE
.Lgcb_abort:
    mov eax, -1
    EPILOGUE

# ------------------------------------------------------------------ grep_exec
.equ GE_JOB, 160
.equ GE_OBJ, 168
.equ GE_NORM, 176
.equ GE_STATUS, 184
.equ GE_ERR, 192

FN grep_exec
    PROLOGUE 256
    mov [rsp + GE_JOB], rdi
    mov qword ptr [rsp + GE_NORM], 0
    mov qword ptr [rsp + GC_BUF], 0
    mov qword ptr [rsp + GC_CHUNK], 0
    mov qword ptr [rsp + GC_MLINES], 0
    mov qword ptr [rsp + GC_TOKENS], 0
    mov qword ptr [rsp + GC_SETS], 0
    mov qword ptr [rsp + GE_ERR], 0
    mov rax, rdi
    mov [rsp + GC_JOB], rax
    mov rdi, [rdi + J_args]
    test rdi, rdi
    jz .Lge_bad
    call strlen
    mov rsi, rax
    mov rdi, [rsp + GE_JOB]
    mov rdi, [rdi + J_args]
    call json_parse
    test rax, rax
    jz .Lge_bad
    mov rbx, rax
    mov rdi, rbx
    lea rsi, [rip + .Lpattern]
    call json_get_cstr
    test rax, rax
    jz .Lge_bad
    mov [rsp + GC_PATTERN], rax
    mov rdi, rax
    call strlen
    mov [rsp + GC_PATLEN], rax
    mov rdi, rbx
    lea rsi, [rip + .Lpath]
    call json_get_cstr
    test rax, rax
    jnz 1f
    lea rax, [rip + .Ldot]
1:  mov [rsp + GE_NORM], rax
    mov rdi, rbx
    lea rsi, [rip + .Lglob]
    call json_get_cstr
    test rax, rax
    jz .Lge_noglob
    mov r13, rax
    mov rdi, rax
    call strlen
    test rax, rax
    jz .Lge_noglob
    mov [rsp + GC_GLOB], r13
    mov rdi, r13
    call search_has_slash
    mov [rsp + GC_GLOB_SLASH], rax
    jmp .Lge_afterglob
.Lge_noglob:
    mov qword ptr [rsp + GC_GLOB], 0
    mov qword ptr [rsp + GC_GLOB_SLASH], 0
.Lge_afterglob:
    mov rdi, rbx
    lea rsi, [rip + .Licase]
    call search_json_bool
    mov [rsp + GC_ICASE], rax
    mov rdi, rbx
    lea rsi, [rip + .Lliteral]
    call search_json_bool
    mov [rsp + GC_LITERAL], rax
    mov rdi, rbx
    lea rsi, [rip + .Lcontext]
    xor edx, edx
    call json_get_u64
    mov [rsp + GC_CONTEXT], rax
    mov rdi, rbx
    lea rsi, [rip + .Llimit]
    mov edx, GR_DEFAULT_LIMIT
    call json_get_u64
    mov [rsp + GC_LIMIT], rax
    mov qword ptr [rsp + GC_FOUND], 0
    mov rdi, [rsp + GE_NORM]
    call search_norm_root
    mov [rsp + GE_NORM], rax
    mov rdi, rax
    call strlen
    mov rcx, rax                    # prefix = rootlen + (root ends in '/' ? 0 : 1)
    test rcx, rcx
    jz .Lge_rootlen
    mov rdx, [rsp + GE_NORM]
    cmp byte ptr [rdx + rcx - 1], '/'
    je .Lge_rootlen
    inc rcx
.Lge_rootlen:
    mov [rsp + GC_GLOB_ROOTLEN], rcx
    mov edi, SB_SIZE
    call mem_alloc
    mov [rsp + GC_BUF], rax
    mov edi, 65536
    call mem_alloc
    mov [rsp + GC_CHUNK], rax
    mov edi, VEC_SIZE
    call mem_alloc
    mov [rsp + GC_MLINES], rax
    mov edi, SB_SIZE
    call mem_alloc
    mov [rsp + GC_TOKENS], rax
    mov edi, SB_SIZE
    call mem_alloc
    mov [rsp + GC_SETS], rax
    cmp qword ptr [rsp + GC_LITERAL], 0
    jne .Lge_nocompile
    lea rdi, [rsp]
    call grep_compile
.Lge_nocompile:
    cmp qword ptr [rsp + GC_LIMIT], 0
    je .Lge_done
    mov rdi, [rsp + GE_NORM]
    lea rsi, [rip + grep_cb]
    lea rdx, [rsp]
    call search_walk
    mov [rsp + GE_STATUS], rax
    test rax, rax
    js .Lge_err
.Lge_done:
    mov rdi, [rsp + GC_BUF]
    call sb_free
    mov rdi, [rsp + GC_BUF]
    call mem_free
    mov rdi, [rsp + GC_CHUNK]
    call mem_free
    mov rdi, [rsp + GC_MLINES]
    call vec_free
    mov rdi, [rsp + GC_MLINES]
    call mem_free
    mov rdi, [rsp + GC_TOKENS]
    call sb_free
    mov rdi, [rsp + GC_TOKENS]
    call mem_free
    mov rdi, [rsp + GC_SETS]
    call sb_free
    mov rdi, [rsp + GC_SETS]
    call mem_free
    mov rdi, [rsp + GE_NORM]
    call mem_free
    mov rdi, [rsp + GE_JOB]
    call tool_done
    xor eax, eax
    EPILOGUE
.Lge_err:
    mov [rsp + GE_ERR], rax
    mov rdi, [rsp + GE_JOB]
    lea rsi, [rip + .Lerr_open]
    mov rdx, [rsp + GE_NORM]
    mov rcx, [rsp + GE_ERR]
    call search_err
    jmp .Lge_done
.Lge_bad:
    mov rdi, [rsp + GE_JOB]
    lea rsi, [rip + .Lbadargs]
    xor edx, edx
    xor ecx, ecx
    call search_err
    xor eax, eax
    EPILOGUE
