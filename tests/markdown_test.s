.include "opcode.inc"
.include "tui/markdown.inc"
# markdown_test: block model, inline parsing, wrapping and incremental append.
# Prints one "name ok"/"name FAIL" line per property; any FAIL sets the exit code.

.bss
.p2align 3
m:        .zero MDK_SIZE
m2:       .zero MDK_SIZE
segs:     .zero 64*24
outsb:    .zero SB_SIZE
fail:     .zero 4

.section .rodata
.Lok:      .asciz " ok\n"
.Lbad:     .asciz " FAIL\n"
.inl:      .ascii "a **b** `c` *d*"
.inl_len = . - .inl
.doc1:     .ascii "# H1\n## H2\n### H3\n"
.doc1_len = . - .doc1
.bul:      .ascii "- item\n"
.bul_len = . - .bul
.qr:       .ascii "> q\n---\n"
.qr_len = . - .qr
.fence1:   .ascii "```\ncode\n```\ntail\n"
.fence1_len = . - .fence1
.fence2:   .ascii "~~~\nfoo\n```\nbar\n~~~\n"
.fence2_len = . - .fence2
.wrap:     .ascii "the quick brown fox\n"
.wrap_len = . - .wrap
.longw:    .ascii "abcdefghij\n"
.longw_len = . - .longw
.inc1:     .ascii "first para\n"
.inc1_len = . - .inc1
.inc2:     .ascii "\nsecond"
.inc2_len = . - .inc2
.wtest:    .ascii "hello world\n"
.wtest_len = . - .wtest
.ansi_doc: .ascii "a `c` z\n"
.ansi_doc_len = . - .ansi_doc
.ansi_needle: .asciz "c"
.texth1:   .asciz "H1"
.textitem: .asciz "- item"
.textq:    .asciz "> q"
.textcode: .asciz "code"
.texttail: .asciz "tail"
.textfence:.asciz "```"
.textrow0: .asciz "the quick"
.textrow1: .asciz "brown fox"
.textlong0:.asciz "abcdefgh"
.textlong1:.asciz "ij"
.ni_count: .asciz "inline.count"
.ni_bold:  .asciz "inline.bold"
.ni_code:  .asciz "inline.code"
.ni_ital:  .asciz "inline.italic"
.nh_count: .asciz "heading.count"
.nh_kind:  .asciz "heading.kind"
.nh_h1:    .asciz "heading.h1"
.nh_h3:    .asciz "heading.h3.dim"
.nh_text:  .asciz "heading.text"
.nb_count: .asciz "bullet.count"
.nb_acc:   .asciz "bullet.accent"
.nb_base:  .asciz "bullet.base"
.nb_text:  .asciz "bullet.text"
.nqr_count: .asciz "qr.count"
.nqr_quote: .asciz "qr.quote"
.nqr_rule:  .asciz "qr.rule"
.nqr_acc:   .asciz "qr.quote.accent"
.nqr_mut:   .asciz "qr.rule.muted"
.nqr_qtext: .asciz "qr.text"
.nf_count: .asciz "fence.count"
.nf_code:  .asciz "fence.code.complete"
.nf_body:  .asciz "fence.body"
.nf_tail:  .asciz "fence.after"
.nf2_count:.asciz "fence2.count"
.nf2_mid:  .asciz "fence2.embedded"
.nw_r0:    .asciz "wrap.row0"
.nw_r1:    .asciz "wrap.row1"
.nl_r0:    .asciz "long.row0"
.nl_r1:    .asciz "long.row1"
.nin_open: .asciz "inc.open"
.nin_inc:  .asciz "inc.incomplete"
.nin_two:  .asciz "inc.two"
.nin_done: .asciz "inc.complete"
.nsw_h:    .asciz "setwidth.height"
.nansi:    .asciz "ansi.text"

.text

print:
    push rbx
    mov rbx, rdi
    call strlen
    mov rdx, rax
    mov rsi, rbx
    mov edi, 1
    pop rbx
    jmp write_all

# expect(rdi=name, esi=cond)
expect:
    PROLOGUE 0
    mov r12, rdi
    mov r13d, esi
    mov rdi, r12
    call print
    test r13d, r13d
    jz 1f
    lea rdi, [rip + .Lok]
    call print
    EPILOGUE
1:  lea rdi, [rip + .Lbad]
    call print
    mov dword ptr [rip + fail], 1
    EPILOGUE

# blk(rdi=m, esi=i) -> rax block*
blk:
    mov eax, esi
    imul rax, rax, MB_SIZE
    add rax, [rdi + MDK_blocks]
    ret

# row(rdi=m, esi=bi, edx=ri) -> rax row*
row:
    mov eax, esi
    imul rax, rax, MB_SIZE
    add rax, [rdi + MDK_blocks]
    mov ecx, edx
    imul rcx, rcx, MR_SIZE
    add rcx, [rax + MB_rows]
    mov rax, rcx
    ret

# style_at(rdi=m, esi=bi, edx=ri, ecx=off) -> eax style byte
style_at:
    PROLOGUE 0
    mov r12d, ecx
    call row
    mov rcx, [rax + MR_style]
    movzx eax, byte ptr [rcx + r12]
    EPILOGUE

# text_eq(rdi=m, esi=bi, rdx=ri, rcx=cstr) -> eax
text_eq:
    PROLOGUE 16
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    mov rdi, r14
    call strlen
    mov [rsp], rax
    mov rdi, rbx
    mov esi, r12d
    mov rdx, r13
    call row
    mov rdi, [rax + MR_text]
    mov rsi, [rax + MR_text + 8]
    mov rdx, r14
    mov rcx, [rsp]
    call str_eq
    EPILOGUE

# build(rdi=m, esi=width, rdx=ptr, rcx=len): md_init + md_append
build:
    PROLOGUE 16
    mov r12, rdi
    mov r13, rdx
    mov r14, rcx
    mov rdi, r12
    call md_init
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    call md_append
    EPILOGUE

FN opcode_main
    PROLOGUE 16
    mov dword ptr [rip + fail], 0

    # 1. inline parse: "a **b** `c` *d*"
    lea rdi, [rip + .inl]
    mov esi, .inl_len
    lea rdx, [rip + segs]
    mov ecx, 64
    call parse_inline
    cmp eax, 6
    sete al
    movzx esi, al
    lea rdi, [rip + .ni_count]
    call expect
    cmp qword ptr [rip + segs + 1*24 + 16], MDF_BOLD
    sete al
    movzx esi, al
    lea rdi, [rip + .ni_bold]
    call expect
    cmp qword ptr [rip + segs + 3*24 + 16], MDC_CODE
    sete al
    movzx esi, al
    lea rdi, [rip + .ni_code]
    call expect
    cmp qword ptr [rip + segs + 5*24 + 16], MDF_ITALIC
    sete al
    movzx esi, al
    lea rdi, [rip + .ni_ital]
    call expect

    # 2. headings 80 cols
    lea rdi, [rip + m]
    mov esi, 80
    lea rdx, [rip + .doc1]
    mov ecx, .doc1_len
    call build
    lea rdi, [rip + m]
    call md_nblocks
    cmp rax, 3
    sete al
    movzx esi, al
    lea rdi, [rip + .nh_count]
    call expect
    lea rdi, [rip + m]
    xor esi, esi
    call blk
    cmp dword ptr [rax + MB_kind], MD_HEAD
    sete al
    movzx esi, al
    lea rdi, [rip + .nh_kind]
    call expect
    lea rdi, [rip + m]
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
    call style_at
    cmp eax, MDF_BOLD | MDC_ACCENT
    sete al
    movzx esi, al
    lea rdi, [rip + .nh_h1]
    call expect
    lea rdi, [rip + m]
    mov esi, 2
    xor edx, edx
    xor ecx, ecx
    call style_at
    cmp eax, MDF_BOLD | MDF_DIM | MDC_BASE
    sete al
    movzx esi, al
    lea rdi, [rip + .nh_h3]
    call expect
    lea rdi, [rip + m]
    xor esi, esi
    xor edx, edx
    lea rcx, [rip + .texth1]
    call text_eq
    movzx esi, al
    lea rdi, [rip + .nh_text]
    call expect

    # 3. bullet
    lea rdi, [rip + m2]
    mov esi, 80
    lea rdx, [rip + .bul]
    mov ecx, .bul_len
    call build
    lea rdi, [rip + m2]
    call md_nblocks
    cmp rax, 1
    sete al
    movzx esi, al
    lea rdi, [rip + .nb_count]
    call expect
    lea rdi, [rip + m2]
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
    call style_at
    cmp eax, MDC_ACCENT
    sete al
    movzx esi, al
    lea rdi, [rip + .nb_acc]
    call expect
    lea rdi, [rip + m2]
    xor esi, esi
    xor edx, edx
    mov ecx, 2
    call style_at
    cmp eax, MDC_BASE
    sete al
    movzx esi, al
    lea rdi, [rip + .nb_base]
    call expect
    lea rdi, [rip + m2]
    xor esi, esi
    xor edx, edx
    lea rcx, [rip + .textitem]
    call text_eq
    movzx esi, al
    lea rdi, [rip + .nb_text]
    call expect

    # 4. quote + rule
    lea rdi, [rip + m]
    mov esi, 80
    lea rdx, [rip + .qr]
    mov ecx, .qr_len
    call build
    lea rdi, [rip + m]
    call md_nblocks
    cmp rax, 2
    sete al
    movzx esi, al
    lea rdi, [rip + .nqr_count]
    call expect
    lea rdi, [rip + m]
    xor esi, esi
    call blk
    cmp dword ptr [rax + MB_kind], MD_QUOTE
    sete al
    movzx esi, al
    lea rdi, [rip + .nqr_quote]
    call expect
    lea rdi, [rip + m]
    mov esi, 1
    call blk
    cmp dword ptr [rax + MB_kind], MD_RULE
    sete al
    movzx esi, al
    lea rdi, [rip + .nqr_rule]
    call expect
    lea rdi, [rip + m]
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
    call style_at
    cmp eax, MDC_ACCENT
    sete al
    movzx esi, al
    lea rdi, [rip + .nqr_acc]
    call expect
    lea rdi, [rip + m]
    mov esi, 1
    xor edx, edx
    xor ecx, ecx
    call style_at
    cmp eax, MDC_MUTED
    sete al
    movzx esi, al
    lea rdi, [rip + .nqr_mut]
    call expect
    lea rdi, [rip + m]
    xor esi, esi
    xor edx, edx
    lea rcx, [rip + .textq]
    call text_eq
    movzx esi, al
    lea rdi, [rip + .nqr_qtext]
    call expect

    # 5. backtick fence closes and a following paragraph starts
    lea rdi, [rip + m]
    mov esi, 80
    lea rdx, [rip + .fence1]
    mov ecx, .fence1_len
    call build
    lea rdi, [rip + m]
    call md_nblocks
    cmp rax, 2
    sete al
    movzx esi, al
    lea rdi, [rip + .nf_count]
    call expect
    lea rdi, [rip + m]
    xor esi, esi
    call blk
    cmp dword ptr [rax + MB_kind], MD_CODE
    jne 1f
    cmp dword ptr [rax + MB_complete], 0
    setne al
    jmp 2f
1:  xor eax, eax
2:  movzx esi, al
    lea rdi, [rip + .nf_code]
    call expect
    lea rdi, [rip + m]
    xor esi, esi
    xor edx, edx
    lea rcx, [rip + .textcode]
    call text_eq
    movzx esi, al
    lea rdi, [rip + .nf_body]
    call expect
    lea rdi, [rip + m]
    mov esi, 1
    xor edx, edx
    lea rcx, [rip + .texttail]
    call text_eq
    movzx esi, al
    lea rdi, [rip + .nf_tail]
    call expect

    # 6. tilde fence ignores an embedded ``` and closes on ~~~
    lea rdi, [rip + m]
    mov esi, 80
    lea rdx, [rip + .fence2]
    mov ecx, .fence2_len
    call build
    lea rdi, [rip + m]
    call md_nblocks
    cmp rax, 1
    sete al
    movzx esi, al
    lea rdi, [rip + .nf2_count]
    call expect
    lea rdi, [rip + m]
    xor esi, esi
    mov edx, 1
    lea rcx, [rip + .textfence]
    call text_eq
    movzx esi, al
    lea rdi, [rip + .nf2_mid]
    call expect

    # 7. word wrap (12 cols) and long-word split (8 cols)
    lea rdi, [rip + m]
    mov esi, 12
    lea rdx, [rip + .wrap]
    mov ecx, .wrap_len
    call build
    lea rdi, [rip + m]
    xor esi, esi
    xor edx, edx
    lea rcx, [rip + .textrow0]
    call text_eq
    movzx esi, al
    lea rdi, [rip + .nw_r0]
    call expect
    lea rdi, [rip + m]
    xor esi, esi
    mov edx, 1
    lea rcx, [rip + .textrow1]
    call text_eq
    movzx esi, al
    lea rdi, [rip + .nw_r1]
    call expect

    lea rdi, [rip + m]
    mov esi, 8
    lea rdx, [rip + .longw]
    mov ecx, .longw_len
    call build
    lea rdi, [rip + m]
    xor esi, esi
    xor edx, edx
    lea rcx, [rip + .textlong0]
    call text_eq
    movzx esi, al
    lea rdi, [rip + .nl_r0]
    call expect
    lea rdi, [rip + m]
    xor esi, esi
    mov edx, 1
    lea rcx, [rip + .textlong1]
    call text_eq
    movzx esi, al
    lea rdi, [rip + .nl_r1]
    call expect

    # 8. incremental: open paragraph, then complete it with a blank line
    lea rdi, [rip + m]
    mov esi, 80
    call md_init
    lea rdi, [rip + m]
    lea rsi, [rip + .inc1]
    mov edx, .inc1_len
    call md_append
    lea rdi, [rip + m]
    call md_nblocks
    cmp rax, 1
    sete al
    movzx esi, al
    lea rdi, [rip + .nin_open]
    call expect
    lea rdi, [rip + m]
    xor esi, esi
    call blk
    cmp dword ptr [rax + MB_complete], 0
    sete al
    movzx esi, al
    lea rdi, [rip + .nin_inc]
    call expect
    lea rdi, [rip + m]
    lea rsi, [rip + .inc2]
    mov edx, .inc2_len
    call md_append
    lea rdi, [rip + m]
    call md_nblocks
    cmp rax, 2
    sete al
    movzx esi, al
    lea rdi, [rip + .nin_two]
    call expect
    lea rdi, [rip + m]
    xor esi, esi
    call blk
    cmp dword ptr [rax + MB_complete], 0
    setne al
    movzx esi, al
    lea rdi, [rip + .nin_done]
    call expect

    # 9. width change re-renders all blocks: "hello world" wraps at 5 -> 2 rows
    lea rdi, [rip + m2]
    mov esi, 80
    lea rdx, [rip + .wtest]
    mov ecx, .wtest_len
    call build
    lea rdi, [rip + m2]
    mov esi, 5
    call md_set_width
    lea rdi, [rip + m2]
    call md_height
    cmp rax, 2
    sete al
    movzx esi, al
    lea rdi, [rip + .nsw_h]
    call expect

    # 10. md_emit_ansi smoke test: the SGR-wrapped stream still contains the text
    lea rdi, [rip + m2]
    mov esi, 80
    lea rdx, [rip + .ansi_doc]
    mov ecx, .ansi_doc_len
    call build
    lea rdi, [rip + outsb]
    call sb_clear
    lea rdi, [rip + m2]
    lea rsi, [rip + outsb]
    xor edx, edx
    call md_emit_ansi
    lea rax, [rip + outsb]
    mov rdi, [rax + SB_ptr]
    mov rsi, [rax + SB_len]
    lea rdx, [rip + .ansi_needle]
    mov ecx, 1
    call str_find
    cmp rax, 0
    setge al
    movzx esi, al
    lea rdi, [rip + .nansi]
    call expect

    mov eax, [rip + fail]
    EPILOGUE
