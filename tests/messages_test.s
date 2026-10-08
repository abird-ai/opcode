.include "opcode.inc"
.include "core/core.inc"
# messages_test: transcript ownership/model and prompt builder golden bytes.
# Prints exactly: messages ok / prompt ok / messages done.

.bss
.p2align 3
tr:  .zero TR_SIZE
sb:  .zero SB_SIZE

.data
.p2align 3
# 1-tool VEC (of TL*) for prompt_build.
tools_items:
    .quad tool0
tools_vec:
    .quad tools_items
    .quad 1
    .quad 1
usage:
    .long 11
    .long 22
    .long 33
    .long 44
    .long 110
    .long 0

.section .rodata
.Lhello:  .asciz "hello"
.Lworld:  .asciz "world"
.Lthink:  .asciz "thinking"
.Lid:     .asciz "call_1"
.Lrname:  .asciz "read"
.Largs:   .asciz "{\"path\":\"x\"}"
.Lresult: .asciz "result text"
.Lcwd:    .asciz "/work"
.Lnocfg:  .asciz "build/no_such_cfg"
.Ltname:  .asciz "read"
.Ltdesc:  .asciz "Read a file"
.Ltestplat: .asciz "testplat"
.Ltestdate: .asciz "2000-02-29"
.Lgolden: .asciz "You are Opcode, a minimal coding agent working directly in the user's environment.\nUse the provided tools to inspect and modify files; keep changes focused and verify your work.\n\n# Tools\nread: Read a file\n\n# Rules\n- Prefer the provided tools over guessing; never invent tool output.\n- Read a file before editing it; edit with exact, unique old text.\n- Prefer small, targeted commands; report failures instead of guessing, and say what the next step is.\n- Keep answers short and direct.\n\n# Environment\n- cwd: /work\n- platform: testplat\n- date: 2000-02-29\n"
.Lm_msg:  .asciz "messages ok\n"
.Lm_pr:   .asciz "prompt ok\n"
.Lm_done: .asciz "messages done\n"
.Lm_fail: .asciz "FAIL messages\n"

.p2align 3
# TL literal: name, label, desc, params, flags/pad, exec, finish.
tool0:
    .quad .Ltname
    .quad 0
    .quad .Ltdesc
    .quad 0
    .long 0
    .long 0
    .quad 0
    .quad 0

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

FN opcode_main
    PROLOGUE

    # ---- tr_init + NULL safety ------------------------------------------
    lea rdi, [rip + tr]
    call tr_init
    cmp qword ptr [rip + tr + TR_msgs], 0
    je .Lfail
    cmp qword ptr [rip + tr + TR_owned], 0
    je .Lfail
    lea rdi, [rip + tr]
    call tr_len
    test rax, rax
    jnz .Lfail
    xor edi, edi
    call tr_len
    test rax, rax
    jnz .Lfail
    xor edi, edi
    xor esi, esi
    call tr_msg
    test rax, rax
    jnz .Lfail
    xor edi, edi
    call msg_call_id
    test rax, rax
    jnz .Lfail

    # ---- user message: two text blocks ---------------------------------
    mov edi, MR_USER
    call msg_new
    mov r12, rax
    test r12, r12
    jz .Lfail
    cmp dword ptr [r12 + M_role], MR_USER
    jne .Lfail
    cmp dword ptr [r12 + M_stop], SR_PENDING
    jne .Lfail

    mov rdi, r12
    mov esi, BT_TEXT
    lea rdx, [rip + .Lhello]
    mov ecx, 5
    call msg_add_block
    mov rbx, rax
    test rbx, rbx
    jz .Lfail
    cmp dword ptr [rbx + B_type], BT_TEXT
    jne .Lfail
    cmp qword ptr [rbx + B_len], 5
    jne .Lfail
    lea rcx, [rip + .Lhello]
    cmp qword ptr [rbx + B_ptr], rcx
    je .Lfail                       # must be a heap copy, not the literal
    mov rdi, [rbx + B_ptr]
    lea rsi, [rip + .Lhello]
    mov edx, 5
    call memeq
    cmp eax, 1
    jne .Lfail

    mov rdi, r12
    mov esi, BT_TEXT
    lea rdx, [rip + .Lworld]
    mov ecx, 5
    call msg_add_block
    mov rdi, [rax + B_ptr]
    lea rsi, [rip + .Lworld]
    mov edx, 5
    call memeq
    cmp eax, 1
    jne .Lfail

    mov rax, [r12 + M_blocks]
    cmp qword ptr [rax + VEC_len], 2
    jne .Lfail
    lea rdi, [rip + tr]
    mov rsi, r12
    call tr_push
    cmp rax, r12
    jne .Lfail

    # ---- assistant message: text + toolcall + usage --------------------
    mov edi, MR_ASSISTANT
    call msg_new
    mov r13, rax
    mov rdi, r13
    mov esi, BT_TEXT
    lea rdx, [rip + .Lthink]
    mov ecx, 8
    call msg_add_block

    mov rdi, r13
    lea rsi, [rip + .Lid]
    lea rdx, [rip + .Lrname]
    lea rcx, [rip + .Largs]
    call msg_add_toolcall
    mov r14, rax
    test r14, r14
    jz .Lfail
    cmp dword ptr [r14 + B_type], BT_TOOLCALL
    jne .Lfail
    cmp qword ptr [r14 + B_len], 0
    jne .Lfail
    mov rbx, [r14 + B_ptr]
    test rbx, rbx
    jz .Lfail
    mov rdi, [rbx + TC_id]
    lea rsi, [rip + .Lid]
    mov edx, 6
    call memeq
    cmp eax, 1
    jne .Lfail
    mov rdi, [rbx + TC_name]
    lea rsi, [rip + .Lrname]
    mov edx, 4
    call memeq
    cmp eax, 1
    jne .Lfail
    mov rdi, [rbx + TC_args]
    lea rsi, [rip + .Largs]
    mov edx, 12
    call memeq
    cmp eax, 1
    jne .Lfail

    mov rdi, r13
    call msg_toolcalls
    cmp eax, 1
    jne .Lfail
    mov rdi, r13
    xor esi, esi
    call msg_toolcall
    cmp rax, rbx
    jne .Lfail
    mov rdi, r13
    mov esi, 1
    call msg_toolcall
    test rax, rax
    jnz .Lfail

    mov rdi, r13
    lea rsi, [rip + usage]
    call msg_set_usage
    mov rax, [r13 + M_usage]
    test rax, rax
    jz .Lfail
    lea rcx, [rip + usage]
    cmp rax, rcx
    je .Lfail                       # must be a copy
    cmp dword ptr [rax + USG_input], 11
    jne .Lfail
    cmp dword ptr [rax + USG_output], 22
    jne .Lfail
    cmp dword ptr [rax + USG_cache_read], 33
    jne .Lfail
    cmp dword ptr [rax + USG_cache_write], 44
    jne .Lfail
    cmp dword ptr [rax + USG_total], 110
    jne .Lfail
    lea rdi, [rip + tr]
    mov rsi, r13
    call tr_push

    # ---- tool result: call id + text block ------------------------------
    mov edi, MR_TOOL_RESULT
    call msg_new
    mov r14, rax
    mov rdi, r14
    lea rsi, [rip + .Lid]
    call msg_set_call_id
    mov rdi, r14
    mov esi, BT_TEXT
    lea rdx, [rip + .Lresult]
    mov ecx, 11
    call msg_add_block
    mov rdi, r14
    call msg_call_id
    test rax, rax
    jz .Lfail
    mov rdi, rax
    lea rsi, [rip + .Lid]
    mov edx, 6
    call memeq
    cmp eax, 1
    jne .Lfail
    lea rdi, [rip + tr]
    mov rsi, r14
    call tr_push

    # ---- transcript checks ----------------------------------------------
    lea rdi, [rip + tr]
    call tr_len
    cmp rax, 3
    jne .Lfail

    lea rdi, [rip + tr]
    mov esi, 3
    call tr_msg
    test rax, rax
    jnz .Lfail                      # out of range

    lea rdi, [rip + tr]
    xor esi, esi
    call tr_msg
    mov r12, rax
    test r12, r12
    jz .Lfail
    cmp dword ptr [r12 + M_role], MR_USER
    jne .Lfail
    mov rbx, [r12 + M_blocks]
    cmp qword ptr [rbx + VEC_len], 2
    jne .Lfail
    mov rbx, [rbx + VEC_ptr]
    cmp dword ptr [rbx + B_type], BT_TEXT
    jne .Lfail
    cmp qword ptr [rbx + B_len], 5
    jne .Lfail
    mov rdi, [rbx + B_ptr]
    lea rsi, [rip + .Lhello]
    mov edx, 5
    call memeq
    cmp eax, 1
    jne .Lfail
    cmp dword ptr [rbx + B_SIZE + B_type], BT_TEXT
    jne .Lfail
    cmp qword ptr [rbx + B_SIZE + B_len], 5
    jne .Lfail
    mov rdi, [rbx + B_SIZE + B_ptr]
    lea rsi, [rip + .Lworld]
    mov edx, 5
    call memeq
    cmp eax, 1
    jne .Lfail

    lea rdi, [rip + tr]
    mov esi, 1
    call tr_msg
    mov r12, rax
    test r12, r12
    jz .Lfail
    cmp dword ptr [r12 + M_role], MR_ASSISTANT
    jne .Lfail
    mov rbx, [r12 + M_blocks]
    cmp qword ptr [rbx + VEC_len], 2
    jne .Lfail
    mov rdi, r12
    call msg_toolcalls
    cmp eax, 1
    jne .Lfail
    mov rdi, r12
    xor esi, esi
    call msg_toolcall
    mov rbx, rax
    test rbx, rbx
    jz .Lfail
    mov rdi, [rbx + TC_id]
    lea rsi, [rip + .Lid]
    mov edx, 6
    call memeq
    cmp eax, 1
    jne .Lfail
    mov rdi, [rbx + TC_name]
    lea rsi, [rip + .Lrname]
    mov edx, 4
    call memeq
    cmp eax, 1
    jne .Lfail
    mov rdi, [rbx + TC_args]
    lea rsi, [rip + .Largs]
    mov edx, 12
    call memeq
    cmp eax, 1
    jne .Lfail
    mov rax, [r12 + M_usage]
    test rax, rax
    jz .Lfail
    cmp dword ptr [rax + USG_total], 110
    jne .Lfail

    lea rdi, [rip + tr]
    mov esi, 2
    call tr_msg
    mov r12, rax
    test r12, r12
    jz .Lfail
    cmp dword ptr [r12 + M_role], MR_TOOL_RESULT
    jne .Lfail
    mov rdi, r12
    call msg_call_id
    test rax, rax
    jz .Lfail
    mov rdi, rax
    lea rsi, [rip + .Lid]
    mov edx, 6
    call memeq
    cmp eax, 1
    jne .Lfail
    mov rbx, [r12 + M_blocks]
    cmp qword ptr [rbx + VEC_len], 1
    jne .Lfail
    mov rbx, [rbx + VEC_ptr]
    mov rdi, [rbx + B_ptr]
    lea rsi, [rip + .Lresult]
    mov edx, 11
    call memeq
    cmp eax, 1
    jne .Lfail

    lea rdi, [rip + .Lm_msg]
    call print

    # ---- prompt golden bytes ---------------------------------------------
    lea rax, [rip + .Lnocfg]
    mov [rip + g_config_home], rax
    lea rax, [rip + .Ltestplat]
    mov [rip + g_prompt_platform], rax
    lea rax, [rip + .Ltestdate]
    mov [rip + g_prompt_date], rax
    lea rdi, [rip + sb]
    lea rsi, [rip + tools_vec]
    lea rdx, [rip + .Lcwd]
    call prompt_build
    test eax, eax
    jnz .Lfail
    lea rdi, [rip + .Lgolden]
    call strlen
    mov r12, rax
    cmp qword ptr [rip + sb + SB_len], r12
    jne .Lfail
    mov rdi, [rip + sb + SB_ptr]
    lea rsi, [rip + .Lgolden]
    mov rdx, r12
    call memeq
    cmp eax, 1
    jne .Lfail
    # NULL tools VEC is accepted and yields a non-empty prompt
    lea rdi, [rip + sb]
    call sb_clear
    lea rdi, [rip + sb]
    xor esi, esi
    lea rdx, [rip + .Lcwd]
    call prompt_build
    test eax, eax
    jnz .Lfail
    cmp qword ptr [rip + sb + SB_len], 0
    je .Lfail
    lea rdi, [rip + sb]
    call sb_free
    lea rdi, [rip + .Lm_pr]
    call print

    # ---- tr_free / re-init / tr_clear ------------------------------------
    lea rdi, [rip + tr]
    call tr_free
    cmp qword ptr [rip + tr + TR_msgs], 0
    jne .Lfail
    cmp qword ptr [rip + tr + TR_owned], 0
    jne .Lfail
    cmp qword ptr [rip + g_mem_live], 0
    jne .Lfail                      # no leaks: owned + containers + sb freed

    lea rdi, [rip + tr]
    call tr_init
    mov edi, MR_USER
    call msg_new
    mov r12, rax
    mov rdi, r12
    mov esi, BT_TEXT
    lea rdx, [rip + .Lhello]
    mov ecx, 5
    call msg_add_block
    lea rdi, [rip + tr]
    mov rsi, r12
    call tr_push
    lea rdi, [rip + tr]
    call tr_len
    cmp rax, 1
    jne .Lfail

    lea rdi, [rip + tr]
    call tr_clear
    lea rdi, [rip + tr]
    call tr_len
    test rax, rax
    jnz .Lfail
    lea rdi, [rip + tr]
    xor esi, esi
    call tr_msg
    test rax, rax
    jnz .Lfail
    lea rdi, [rip + tr]
    call tr_free
    cmp qword ptr [rip + g_mem_live], 0
    jne .Lfail

    lea rdi, [rip + .Lm_done]
    call print
    xor eax, eax
    EPILOGUE

.Lfail:
    lea rdi, [rip + .Lm_fail]
    call print
    mov eax, 1
    EPILOGUE
