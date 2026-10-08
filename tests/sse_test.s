# sse_test: incremental SSE parser and sse_last_id
.include "opcode.inc"

.bss
.p2align 3
ssebuf:   .zero 1024
cap:      .zero 1024
cap_len:  .zero 8
cb_count: .zero 8

.section .rodata
.d_basic:     .ascii "data: hello\n\n"
.d_basic_len = . - .d_basic
.d_multiline: .ascii "data: a\ndata: b\n\n"
.d_multiline_len = . - .d_multiline
.d_event:     .ascii "event: delta\ndata: x\n\n"
.d_event_len = . - .d_event
.d_crlf:      .ascii "data: x\r\n\r\n"
.d_crlf_len = . - .d_crlf
.d_cr:        .ascii "data: x\r\r"
.d_cr_len = . - .d_cr
.d_batch:     .ascii "data: one\n\ndata: two\n\n"
.d_batch_len = . - .d_batch
.d_comment:   .ascii ": keepalive\ndata: y\n\n"
.d_comment_len = . - .d_comment
.d_id:        .ascii "id: 42\ndata: z\n\n"
.d_id_len = . - .d_id
.d_nospace:   .ascii "data:no-space\n\n"
.d_nospace_len = . - .d_nospace
.d_done:      .ascii "data: [DONE]\n\n"
.d_done_len = . - .d_done
.d_empty:     .ascii "event: ping\n\n"
.d_empty_len = . - .d_empty
.id42:        .ascii "42"

# captured callback output: "event\x1fdata\n" per event
.c_basic:     .ascii "message\037hello\n"
.c_basic_len = . - .c_basic
.c_multiline: .ascii "message\037a\nb\n"
.c_multiline_len = . - .c_multiline
.c_event:     .ascii "delta\037x\n"
.c_event_len = . - .c_event
.c_crlf:      .ascii "message\037x\n"
.c_crlf_len = . - .c_crlf
.c_cr:        .ascii "message\037x\n"
.c_cr_len = . - .c_cr
.c_batch:     .ascii "message\037one\nmessage\037two\n"
.c_batch_len = . - .c_batch
.c_comment:   .ascii "message\037y\n"
.c_comment_len = . - .c_comment
.c_id:        .ascii "message\037z\n"
.c_id_len = . - .c_id
.c_nospace:   .ascii "message\037no-space\n"
.c_nospace_len = . - .c_nospace
.c_done:      .ascii "message\037[DONE]\n"
.c_done_len = . - .c_done

.m_basic:     .asciz "sse ok basic\n"
.m_multiline: .asciz "sse ok multiline\n"
.m_event:     .asciz "sse ok event\n"
.m_crlf:      .asciz "sse ok crlf\n"
.m_cr:        .asciz "sse ok cr\n"
.m_split:     .asciz "sse ok split\n"
.m_batch:     .asciz "sse ok batch\n"
.m_comment:   .asciz "sse ok comment\n"
.m_id:        .asciz "sse ok id\n"
.m_nospace:   .asciz "sse ok nospace\n"
.m_done:      .asciz "sse ok done\n"
.m_empty:     .asciz "sse ok empty\n"
.m_finish:    .asciz "sse done\n"
.m_fail:      .asciz "FAIL sse\n"

.text

# print(cstr)
print:
    push rdi
    call strlen
    pop rdi
    mov rdx, rax
    mov rsi, rdi
    mov edi, 1
    jmp write_all

# on_event(ctx, ev ptr, ev len, data ptr, data len)
# appends "ev\x1fdata\n" to cap and bumps cb_count.
on_event:
    PROLOGUE 0
    mov rbx, rsi
    mov r12, rdx
    mov r13, rcx
    mov r14, r8
    lea r15, [rip + cap]
    add r15, [rip + cap_len]
    mov rdi, r15
    mov rsi, rbx
    mov rdx, r12
    call memcpy
    add r15, r12
    mov byte ptr [r15], 0x1f
    inc r15
    mov rdi, r15
    mov rsi, r13
    mov rdx, r14
    call memcpy
    add r15, r14
    mov byte ptr [r15], '\n'
    inc r15
    lea rax, [rip + cap]
    sub r15, rax
    mov [rip + cap_len], r15
    inc qword ptr [rip + cb_count]
    EPILOGUE

reset_harness:
    mov qword ptr [rip + cap_len], 0
    mov qword ptr [rip + cb_count], 0
    ret

# expect(exp cap ptr, exp cap len, exp count) -> eax 1|0
expect:
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    cmp qword ptr [rip + cb_count], r13
    jne .Lexp_bad
    cmp qword ptr [rip + cap_len], r12
    jne .Lexp_bad
    lea rdi, [rip + cap]
    mov rsi, rbx
    mov rdx, r12
    call memeq
    test eax, eax
    jz .Lexp_bad
    mov eax, 1
    EPILOGUE
.Lexp_bad:
    xor eax, eax
    EPILOGUE

# run_case(payload ptr, len, exp cap ptr, exp cap len, exp count) -> eax 1|0
run_case:
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov r15, r8
    call reset_harness
    lea rdi, [rip + ssebuf]
    lea rsi, [rip + on_event]
    xor edx, edx
    call sse_init
    lea rdi, [rip + ssebuf]
    mov rsi, rbx
    mov rdx, r12
    call sse_feed
    mov rdi, r13
    mov rsi, r14
    mov rdx, r15
    call expect
    EPILOGUE

# one full-feed case, then print its ok line
.macro SSE_CASE d, dl, c, cl, n, m
    lea rdi, [rip + \d]
    mov esi, \dl
    lea rdx, [rip + \c]
    mov ecx, \cl
    mov r8d, \n
    call run_case
    test eax, eax
    jz .Lfail
    lea rdi, [rip + \m]
    call print
.endm

FN opcode_main
    PROLOGUE 0

    SSE_CASE .d_basic, .d_basic_len, .c_basic, .c_basic_len, 1, .m_basic
    SSE_CASE .d_multiline, .d_multiline_len, .c_multiline, .c_multiline_len, 1, .m_multiline
    SSE_CASE .d_event, .d_event_len, .c_event, .c_event_len, 1, .m_event
    SSE_CASE .d_crlf, .d_crlf_len, .c_crlf, .c_crlf_len, 1, .m_crlf
    SSE_CASE .d_cr, .d_cr_len, .c_cr, .c_cr_len, 1, .m_cr

    # split: feed the basic payload one byte at a time
    call reset_harness
    lea rdi, [rip + ssebuf]
    lea rsi, [rip + on_event]
    xor edx, edx
    call sse_init
    lea rbx, [rip + .d_basic]
    mov r12d, .d_basic_len
.Lsplit_loop:
    test r12d, r12d
    jz .Lsplit_done
    lea rdi, [rip + ssebuf]
    mov rsi, rbx
    mov edx, 1
    call sse_feed
    inc rbx
    dec r12d
    jmp .Lsplit_loop
.Lsplit_done:
    lea rdi, [rip + .c_basic]
    mov esi, .c_basic_len
    mov edx, 1
    call expect
    test eax, eax
    jz .Lfail
    lea rdi, [rip + .m_split]
    call print

    SSE_CASE .d_batch, .d_batch_len, .c_batch, .c_batch_len, 2, .m_batch
    SSE_CASE .d_comment, .d_comment_len, .c_comment, .c_comment_len, 1, .m_comment

    # id: feed and dispatch, then check sse_last_id
    lea rdi, [rip + .d_id]
    mov esi, .d_id_len
    lea rdx, [rip + .c_id]
    mov ecx, .c_id_len
    mov r8d, 1
    call run_case
    test eax, eax
    jz .Lfail
    lea rdi, [rip + ssebuf]
    call sse_last_id
    test rax, rax
    jz .Lfail
    cmp rdx, 2
    jne .Lfail
    mov rdi, rax
    lea rsi, [rip + .id42]
    mov edx, 2
    call memeq
    test eax, eax
    jz .Lfail
    lea rdi, [rip + .m_id]
    call print

    SSE_CASE .d_nospace, .d_nospace_len, .c_nospace, .c_nospace_len, 1, .m_nospace
    SSE_CASE .d_done, .d_done_len, .c_done, .c_done_len, 1, .m_done
    SSE_CASE .d_empty, .d_empty_len, .c_basic, 0, 0, .m_empty

    lea rdi, [rip + .m_finish]
    call print
    xor eax, eax
    EPILOGUE
.Lfail:
    lea rdi, [rip + .m_fail]
    call print
    mov eax, 1
    EPILOGUE
