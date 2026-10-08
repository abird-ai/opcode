.include "opcode.inc"
.include "core/core.inc"
# compact_test: context compaction primitives.
# Prints exactly: compact estimate ok / compact needed ok / compact cut ok /
# compact prompt ok / compact apply ok / compact done.

.equ COMPACT_DUMP_CAP, 100000

.bss
.p2align 3
tr:        .zero TR_SIZE
tr2:       .zero TR_SIZE
sb:        .zero SB_SIZE
md:        .zero 64
instr_len: .quad 0
saved3:    .quad 0
saved4:    .quad 0

.data
.p2align 3
usage100:
    .long 100
    .long 0
    .long 0
    .long 0
    .long 100
    .long 0

.section .rodata
.Lhello:    .asciz "hello"
.Lthink:    .asciz "thinking"
.Ltid:      .asciz "toolu_1"
.Ltname:    .asciz "bash"
.Largs:     .asciz "{\"command\":\"echo hi\"}"
.Lresult:   .asciz "result"
.Lmore:     .asciz "more"
.Lanswer:   .asciz "answer text"
.Ltail:     .asciz "tail"
.Leight:    .asciz "abcdefgh"
.Lsummary:  .asciz "SUM-TEXT"
.Luserline: .asciz "user: hello"
.Lasstline: .asciz "assistant: thinking"
.Ltoolline: .asciz "tool: result"
.Lmoreline: .asciz "user: more"
.Ltcline:   .asciz "tool_call"
.Lhead:     .asciz "HEADMARK"
.Ltailmark: .asciz "TAILMARK"
.Ltrunc:    .asciz "earlier messages omitted"
.Lcsum:     .asciz "<conversation_summary>"
.Lsumline:  .asciz "SUM-TEXT"
.Lrbegin:   .asciz "BEGIN"
.Lrx:       .fill 250, 1, 120
.Lrend:     .asciz "ENDMARK"

.Lm_est:  .asciz "compact estimate ok\n"
.Lm_need: .asciz "compact needed ok\n"
.Lm_cut:  .asciz "compact cut ok\n"
.Lm_pr:   .asciz "compact prompt ok\n"
.Lm_ap:   .asciz "compact apply ok\n"
.Lm_done: .asciz "compact done\n"
.Lm_fail: .asciz "FAIL compact_test\n"

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

# sb_contains(sb rdi, cstr rsi) -> 1|0
sb_contains:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov rdi, r13
    call strlen
    mov rcx, rax
    mov rdi, [r12 + SB_ptr]
    mov rsi, [r12 + SB_len]
    mov rdx, r13
    call str_find
    cmp rax, -1
    setne al
    movzx eax, al
    EPILOGUE

# text_contains(msg rdi, cstr rsi) -> 1|0 over BT_TEXT blocks
text_contains:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    test r12, r12
    jz .Ltc_no
    mov rdi, r13
    call strlen
    mov r14, rax
    mov rax, [r12 + M_blocks]
    test rax, rax
    jz .Ltc_no
    mov r15, [rax + VEC_ptr]
    mov rbx, [rax + VEC_len]
.Ltc_loop:
    test rbx, rbx
    jz .Ltc_no
    cmp dword ptr [r15 + B_type], BT_TEXT
    jne .Ltc_next
    mov rdi, [r15 + B_ptr]
    mov rsi, [r15 + B_len]
    mov rdx, r13
    mov rcx, r14
    call str_find
    cmp rax, -1
    jne .Ltc_yes
.Ltc_next:
    add r15, B_SIZE
    dec rbx
    jmp .Ltc_loop
.Ltc_yes:
    mov eax, 1
    EPILOGUE
.Ltc_no:
    xor eax, eax
    EPILOGUE

# add_msg(role edi, text rsi, len rdx): append a text message to `tr`
add_msg:
    PROLOGUE
    mov r12d, edi
    mov r13, rsi
    mov r14, rdx
    mov edi, r12d
    call msg_new
    mov rbx, rax
    mov rdi, rbx
    mov esi, BT_TEXT
    mov rdx, r13
    mov rcx, r14
    call msg_add_block
    lea rdi, [rip + tr]
    mov rsi, rbx
    call tr_push
    mov rax, rbx
    EPILOGUE

FN opcode_main
    PROLOGUE

    # ---- estimate -------------------------------------------------------
    lea rdi, [rip + tr]
    call tr_init

    mov edi, MR_USER
    lea rsi, [rip + .Lhello]
    mov edx, 5
    call add_msg
    lea rdi, [rip + tr]
    call compact_estimate
    test rax, rax
    jz .Lfail
    mov r12, rax

    mov edi, MR_ASSISTANT
    call msg_new
    mov rbx, rax
    mov rdi, rbx
    mov esi, BT_TEXT
    lea rdx, [rip + .Lthink]
    mov ecx, 8
    call msg_add_block
    mov rdi, rbx
    lea rsi, [rip + .Ltid]
    lea rdx, [rip + .Ltname]
    lea rcx, [rip + .Largs]
    call msg_add_toolcall
    lea rdi, [rip + tr]
    mov rsi, rbx
    call tr_push
    lea rdi, [rip + tr]
    call compact_estimate
    cmp rax, r12
    jb .Lfail
    mov r12, rax

    mov edi, MR_TOOL_RESULT
    call msg_new
    mov rbx, rax
    mov rdi, rbx
    lea rsi, [rip + .Ltid]
    call msg_set_call_id
    mov rdi, rbx
    mov esi, BT_TEXT
    lea rdx, [rip + .Lresult]
    mov ecx, 6
    call msg_add_block
    lea rdi, [rip + tr]
    mov rsi, rbx
    call tr_push
    lea rdi, [rip + tr]
    call compact_estimate
    cmp rax, r12
    jb .Lfail
    mov r12, rax

    mov edi, MR_USER
    lea rsi, [rip + .Lmore]
    mov edx, 4
    call add_msg
    lea rdi, [rip + tr]
    call compact_estimate
    cmp rax, r12
    jb .Lfail
    mov r12, rax

    mov edi, MR_ASSISTANT
    lea rsi, [rip + .Lanswer]
    mov edx, 11
    call add_msg
    lea rdi, [rip + tr]
    call compact_estimate
    cmp rax, r12
    jb .Lfail
    cmp rax, 13
    jne .Lfail

    # usage wins over chars: 100, then 100 + 8/4
    mov edi, MR_ASSISTANT
    call msg_new
    mov rbx, rax
    mov rdi, rbx
    mov esi, BT_TEXT
    lea rdx, [rip + .Ltail]
    mov ecx, 4
    call msg_add_block
    mov rdi, rbx
    lea rsi, [rip + usage100]
    call msg_set_usage
    lea rdi, [rip + tr]
    mov rsi, rbx
    call tr_push
    lea rdi, [rip + tr]
    call compact_estimate
    cmp rax, 100
    jne .Lfail

    mov edi, MR_USER
    lea rsi, [rip + .Leight]
    mov edx, 8
    call add_msg
    lea rdi, [rip + tr]
    call compact_estimate
    cmp rax, 102
    jne .Lfail

    lea rdi, [rip + .Lm_est]
    call print

    # ---- needed ---------------------------------------------------------
    mov dword ptr [rip + md + MD_ctx_window], 20000
    mov edi, 1
    lea rsi, [rip + md]
    call compact_needed
    test eax, eax
    jnz .Lfail
    mov edi, 4000
    lea rsi, [rip + md]
    call compact_needed
    cmp eax, 1
    jne .Lfail

    mov qword ptr [rip + g_compact_reserve], 100
    mov dword ptr [rip + md + MD_ctx_window], 1000
    mov edi, 900
    lea rsi, [rip + md]
    call compact_needed
    test eax, eax
    jnz .Lfail
    mov edi, 901
    lea rsi, [rip + md]
    call compact_needed
    cmp eax, 1
    jne .Lfail

    mov dword ptr [rip + md + MD_ctx_window], 0
    mov edi, 100000
    lea rsi, [rip + md]
    call compact_needed
    test eax, eax
    jnz .Lfail

    mov dword ptr [rip + md + MD_ctx_window], 50
    mov edi, 1
    lea rsi, [rip + md]
    call compact_needed
    cmp eax, 1
    jne .Lfail

    lea rdi, [rip + .Lm_need]
    call print

    # ---- cut ------------------------------------------------------------
    # keep=7 lands on the tool result, must move back onto its assistant.
    lea rdi, [rip + tr]
    mov esi, 7
    call compact_cut
    cmp rax, 1
    jne .Lfail
    lea rdi, [rip + tr]
    mov esi, 1
    call tr_msg
    test rax, rax
    jz .Lfail
    cmp dword ptr [rax + M_role], MR_ASSISTANT
    jne .Lfail
    mov rdi, rax
    call msg_toolcalls
    cmp eax, 1
    jne .Lfail
    lea rdi, [rip + tr]
    mov esi, 2
    call tr_msg
    cmp dword ptr [rax + M_role], MR_TOOL_RESULT
    jne .Lfail

    lea rdi, [rip + tr]
    mov esi, 3
    call compact_cut
    cmp rax, 5
    jne .Lfail
    lea rdi, [rip + tr]
    mov esi, 6
    call compact_cut
    cmp rax, 3
    jne .Lfail
    lea rdi, [rip + tr]
    mov esi, 100
    call compact_cut
    cmp rax, 1
    jne .Lfail
    # keep=0 keeps the final user message only (cut = n-1)
    lea rdi, [rip + tr]
    xor esi, esi
    call compact_cut
    cmp rax, 6
    jne .Lfail

    lea rdi, [rip + .Lm_cut]
    call print

    # ---- prompt ---------------------------------------------------------
    lea rdi, [rip + sb]
    call sb_clear
    lea rdi, [rip + sb]
    xor esi, esi
    xor edx, edx
    call compact_prompt
    test eax, eax
    jnz .Lfail
    mov rax, [rip + sb + SB_len]
    test rax, rax
    jz .Lfail
    mov [rip + instr_len], rax

    lea rdi, [rip + sb]
    call sb_clear
    lea rdi, [rip + sb]
    lea rsi, [rip + tr]
    mov edx, 3
    call compact_prompt
    test eax, eax
    jnz .Lfail
    lea rdi, [rip + sb]
    lea rsi, [rip + .Luserline]
    call sb_contains
    cmp eax, 1
    jne .Lfail
    lea rdi, [rip + sb]
    lea rsi, [rip + .Lasstline]
    call sb_contains
    cmp eax, 1
    jne .Lfail
    lea rdi, [rip + sb]
    lea rsi, [rip + .Ltoolline]
    call sb_contains
    cmp eax, 1
    jne .Lfail
    lea rdi, [rip + sb]
    lea rsi, [rip + .Ltcline]
    call sb_contains
    cmp eax, 1
    jne .Lfail
    lea rdi, [rip + sb]
    lea rsi, [rip + .Lmoreline]
    call sb_contains
    cmp eax, 1
    je .Lfail

    # tool results are cut at 200 chars
    lea rdi, [rip + tr2]
    call tr_init
    mov edi, MR_TOOL_RESULT
    call msg_new
    mov rbx, rax
    mov rdi, rbx
    mov esi, BT_TEXT
    lea rdx, [rip + .Lrbegin]
    mov ecx, 262
    call msg_add_block
    lea rdi, [rip + tr2]
    mov rsi, rbx
    call tr_push
    lea rdi, [rip + sb]
    call sb_clear
    lea rdi, [rip + sb]
    lea rsi, [rip + tr2]
    mov edx, 1
    call compact_prompt
    lea rdi, [rip + sb]
    lea rsi, [rip + .Lrbegin]
    call sb_contains
    cmp eax, 1
    jne .Lfail
    lea rdi, [rip + sb]
    lea rsi, [rip + .Lrend]
    call sb_contains
    cmp eax, 1
    je .Lfail

    # dump cap keeps the most recent part
    lea rdi, [rip + tr2]
    call tr_free
    lea rdi, [rip + tr2]
    call tr_init
    mov edi, 120000
    call mem_alloc
    mov r15, rax
    mov rdi, r15
    lea rsi, [rip + .Lhead]
    mov edx, 8
    call memcpy
    lea rdi, [r15 + 8]
    mov esi, 120
    mov edx, 119984
    call memset
    lea rdi, [r15 + 119992]
    lea rsi, [rip + .Ltailmark]
    mov edx, 8
    call memcpy
    mov edi, MR_USER
    call msg_new
    mov rbx, rax
    mov rdi, rbx
    mov esi, BT_TEXT
    mov rdx, r15
    mov ecx, 120000
    call msg_add_block
    lea rdi, [rip + tr2]
    mov rsi, rbx
    call tr_push
    mov rdi, r15
    call mem_free
    mov edi, MR_USER
    call msg_new
    mov rbx, rax
    mov rdi, rbx
    mov esi, BT_TEXT
    lea rdx, [rip + .Ltail]
    mov ecx, 4
    call msg_add_block
    lea rdi, [rip + tr2]
    mov rsi, rbx
    call tr_push

    lea rdi, [rip + sb]
    call sb_clear
    lea rdi, [rip + sb]
    lea rsi, [rip + tr2]
    mov edx, 2
    call compact_prompt
    mov rax, [rip + sb + SB_len]
    sub rax, [rip + instr_len]
    cmp rax, COMPACT_DUMP_CAP
    ja .Lfail
    lea rdi, [rip + sb]
    lea rsi, [rip + .Ltailmark]
    call sb_contains
    cmp eax, 1
    jne .Lfail
    lea rdi, [rip + sb]
    lea rsi, [rip + .Lhead]
    call sb_contains
    cmp eax, 1
    je .Lfail
    lea rdi, [rip + sb]
    lea rsi, [rip + .Ltrunc]
    call sb_contains
    cmp eax, 1
    jne .Lfail

    lea rdi, [rip + tr2]
    call tr_free
    lea rdi, [rip + .Lm_pr]
    call print

    # ---- apply ----------------------------------------------------------
    lea rdi, [rip + tr]
    mov esi, 3
    call tr_msg
    mov [rip + saved3], rax
    lea rdi, [rip + tr]
    mov esi, 4
    call tr_msg
    mov [rip + saved4], rax
    lea rdi, [rip + tr]
    mov esi, 3
    lea rdx, [rip + .Lsummary]
    call compact_apply
    test eax, eax
    jnz .Lfail
    lea rdi, [rip + tr]
    call tr_len
    cmp rax, 5
    jne .Lfail
    lea rdi, [rip + tr]
    xor esi, esi
    call tr_msg
    test rax, rax
    jz .Lfail
    cmp dword ptr [rax + M_role], MR_USER
    jne .Lfail
    mov rdi, rax
    lea rsi, [rip + .Lcsum]
    call text_contains
    cmp eax, 1
    jne .Lfail
    lea rdi, [rip + tr]
    xor esi, esi
    call tr_msg
    mov rdi, rax
    lea rsi, [rip + .Lsumline]
    call text_contains
    cmp eax, 1
    jne .Lfail
    lea rdi, [rip + tr]
    mov esi, 1
    call tr_msg
    cmp rax, [rip + saved3]
    jne .Lfail
    lea rdi, [rip + tr]
    mov esi, 2
    call tr_msg
    cmp rax, [rip + saved4]
    jne .Lfail
    lea rdi, [rip + tr]
    mov esi, 5
    call tr_msg
    test rax, rax
    jnz .Lfail
    # cut <= 0 is a safe no-op
    lea rdi, [rip + tr]
    xor esi, esi
    lea rdx, [rip + .Lsummary]
    call compact_apply
    test eax, eax
    jnz .Lfail
    lea rdi, [rip + tr]
    call tr_len
    cmp rax, 5
    jne .Lfail

    lea rdi, [rip + tr]
    call tr_free
    lea rdi, [rip + sb]
    call sb_free
    cmp qword ptr [rip + g_mem_live], 0
    jne .Lfail
    lea rdi, [rip + .Lm_ap]
    call print

    lea rdi, [rip + .Lm_done]
    call print
    xor eax, eax
    EPILOGUE

.Lfail:
    lea rdi, [rip + .Lm_fail]
    call print
    mov eax, 1
    EPILOGUE
