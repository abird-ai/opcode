.include "opcode.inc"
.include "core/core.inc"
# session_test: JSONL session persistence round-trip.
# Prints exactly: session write ok / session load ok / session file ok /
# session meta ok / session find ok / session done (see tests/data/session_test.expected).
#
# The session dir is build/session_test_dir_<pid> so repeated runs never see
# stale files. Session path/id offsets mirror the private struct in session.s.

.equ T_S_PATH, 8
.equ T_S_ID, 16

.bss
.p2align 3
tr:  .zero TR_SIZE
tr2: .zero TR_SIZE
sb:  .zero SB_SIZE
fsb: .zero SB_SIZE
path_owned: .quad 0

.data
.p2align 3
usage:
    .long 10
    .long 25
    .long 0
    .long 0
    .long 35
    .long 0

.section .rodata
.Ldirpre:  .asciz "build/session_test_dir_"
.Lcwd:     .asciz "/tmp/proj"
.Lprov:    .asciz "anthropic"
.Lmodel:   .asciz "claude-sonnet-4-5"
.Lhello:   .asciz "hello"
.Lworld:   .asciz "world"
.Lanswer:  .asciz "answer"
.Ltoolid:  .asciz "toolu_1"
.Lbash:    .asciz "bash"
.Largs:    .asciz "{\"command\":\"echo hi\"}"
.Lresult:  .asciz "hi\n[exit 0]"
.Lprefix:  .asciz "{\"type\":\"session\",\"schema_version\":1,"
.Lwrite_ok: .asciz "session write ok\n"
.Lload_ok:  .asciz "session load ok\n"
.Lfile_ok:  .asciz "session file ok\n"
.Lmeta_ok:  .asciz "session meta ok\n"
.Lid_ok:    .asciz "session accessors ok\n"
.Lfind_ok:  .asciz "session find ok\n"
.Ldone:     .asciz "session done\n"
.Lfailmsg:  .asciz "FAIL session_test\n"

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

# streq(a cstr, b cstr) -> 1|0
streq:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    call strlen
    mov rdi, rbx
    mov rsi, rax
    mov rdx, r12
    call str_eq_cstr
    EPILOGUE

# read_all(path cstr, sb) -> 0 | -errno
read_all:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov rdi, rsi
    call sb_clear
    mov rdi, r12
    mov esi, O_RDONLY | O_CLOEXEC
    xor edx, edx
    call os_open
    test rax, rax
    js .Lra_err
    mov r14, rax
.Lra_loop:
    mov rdi, r13
    mov esi, 4096
    call sb_reserve
    mov rsi, rax
    mov edi, r14d
    mov edx, 4096
    call os_read
    test rax, rax
    js .Lra_fail
    jz .Lra_done
    add [r13 + SB_len], rax
    mov rcx, [r13 + SB_len]
    mov rdx, [r13 + SB_ptr]
    mov byte ptr [rdx + rcx], 0
    jmp .Lra_loop
.Lra_done:
    mov edi, r14d
    call os_close
    xor eax, eax
    EPILOGUE
.Lra_fail:
    mov rbx, rax
    mov edi, r14d
    call os_close
    mov rax, rbx
    EPILOGUE
.Lra_err:
    EPILOGUE

FN opcode_main
    PROLOGUE

    # ---- unique session dir: build/session_test_dir_<pid> ----------------
    lea rdi, [rip + sb]
    lea rsi, [rip + .Ldirpre]
    call sb_push_cstr
    mov eax, 39
    syscall
    mov rsi, rax
    lea rdi, [rip + sb]
    call sb_push_u64

    # ---- write phase ------------------------------------------------------
    lea rdi, [rip + tr]
    call tr_init
    mov rdi, [rip + sb + SB_ptr]
    lea rsi, [rip + .Lcwd]
    call session_new
    test rax, rax
    jz .Lfail
    mov r12, rax
    mov rdi, [r12 + T_S_PATH]
    call strlen
    mov rsi, rax
    mov rdi, [r12 + T_S_PATH]
    call mem_dup
    mov [rip + path_owned], rax

    mov rdi, r12
    lea rsi, [rip + .Lprov]
    lea rdx, [rip + .Lmodel]
    call session_append_model
    test eax, eax
    jnz .Lfail

    mov edi, MR_USER
    call msg_new
    mov r13, rax
    mov rdi, r13
    mov esi, BT_TEXT
    lea rdx, [rip + .Lhello]
    mov ecx, 5
    call msg_add_block
    mov rdi, r13
    mov esi, BT_TEXT
    lea rdx, [rip + .Lworld]
    mov ecx, 5
    call msg_add_block
    lea rdi, [rip + tr]
    mov rsi, r13
    call tr_push
    mov rdi, r12
    mov rsi, r13
    call session_append_msg
    test eax, eax
    jnz .Lfail

    mov edi, MR_ASSISTANT
    call msg_new
    mov r13, rax
    mov rdi, r13
    mov esi, BT_TEXT
    lea rdx, [rip + .Lanswer]
    mov ecx, 6
    call msg_add_block
    mov rdi, r13
    lea rsi, [rip + .Ltoolid]
    lea rdx, [rip + .Lbash]
    lea rcx, [rip + .Largs]
    call msg_add_toolcall
    mov rdi, r13
    lea rsi, [rip + usage]
    call msg_set_usage
    mov dword ptr [r13 + M_stop], SR_TOOL_USE
    lea rdi, [rip + tr]
    mov rsi, r13
    call tr_push
    mov rdi, r12
    mov rsi, r13
    call session_append_msg
    test eax, eax
    jnz .Lfail

    mov edi, MR_TOOL_RESULT
    call msg_new
    mov r13, rax
    mov rdi, r13
    lea rsi, [rip + .Ltoolid]
    call msg_set_call_id
    or dword ptr [r13 + M_flags], MF_ERROR
    mov rdi, r13
    mov esi, BT_TEXT
    lea rdx, [rip + .Lresult]
    mov ecx, 11
    call msg_add_block
    lea rdi, [rip + tr]
    mov rsi, r13
    call tr_push
    mov rdi, r12
    mov rsi, r13
    call session_append_msg
    test eax, eax
    jnz .Lfail

    mov rdi, r12
    call session_close
    xor r12d, r12d
    lea rdi, [rip + .Lwrite_ok]
    call print

    # ---- load phase -------------------------------------------------------
    mov rdi, [rip + path_owned]
    call session_open
    test rax, rax
    jz .Lfail
    mov r12, rax
    lea rdi, [rip + tr2]
    call tr_init
    mov rdi, r12
    lea rsi, [rip + tr2]
    call session_load
    test eax, eax
    jnz .Lfail

    lea rdi, [rip + tr2]
    call tr_len
    cmp rax, 3
    jne .Lfail

    # user message: two text blocks
    lea rdi, [rip + tr2]
    xor esi, esi
    call tr_msg
    mov r13, rax
    test r13, r13
    jz .Lfail
    cmp dword ptr [r13 + M_role], MR_USER
    jne .Lfail
    mov rbx, [r13 + M_blocks]
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
    mov rdi, [rbx + B_SIZE + B_ptr]
    lea rsi, [rip + .Lworld]
    mov edx, 5
    call memeq
    cmp eax, 1
    jne .Lfail

    # assistant message: text + toolcall + usage + stop_reason
    lea rdi, [rip + tr2]
    mov esi, 1
    call tr_msg
    mov r13, rax
    test r13, r13
    jz .Lfail
    cmp dword ptr [r13 + M_role], MR_ASSISTANT
    jne .Lfail
    cmp dword ptr [r13 + M_stop], SR_TOOL_USE
    jne .Lfail
    mov rbx, [r13 + M_blocks]
    cmp qword ptr [rbx + VEC_len], 2
    jne .Lfail
    mov rax, [r13 + M_usage]
    test rax, rax
    jz .Lfail
    cmp dword ptr [rax + USG_input], 10
    jne .Lfail
    cmp dword ptr [rax + USG_output], 25
    jne .Lfail
    cmp dword ptr [rax + USG_cache_read], 0
    jne .Lfail
    cmp dword ptr [rax + USG_cache_write], 0
    jne .Lfail
    cmp dword ptr [rax + USG_total], 35
    jne .Lfail
    mov rdi, r13
    call msg_toolcalls
    cmp eax, 1
    jne .Lfail
    mov rdi, r13
    xor esi, esi
    call msg_toolcall
    mov rbx, rax
    test rbx, rbx
    jz .Lfail
    mov rdi, [rbx + TC_id]
    lea rsi, [rip + .Ltoolid]
    mov edx, 7
    call memeq
    cmp eax, 1
    jne .Lfail
    mov rdi, [rbx + TC_name]
    lea rsi, [rip + .Lbash]
    mov edx, 4
    call memeq
    cmp eax, 1
    jne .Lfail
    mov rdi, [rbx + TC_args]
    lea rsi, [rip + .Largs]
    mov edx, 21
    call memeq
    cmp eax, 1
    jne .Lfail

    # tool result: call id + error flag + one text block
    lea rdi, [rip + tr2]
    mov esi, 2
    call tr_msg
    mov r13, rax
    test r13, r13
    jz .Lfail
    cmp dword ptr [r13 + M_role], MR_TOOL_RESULT
    jne .Lfail
    test dword ptr [r13 + M_flags], MF_ERROR
    jz .Lfail
    mov rdi, r13
    call msg_call_id
    test rax, rax
    jz .Lfail
    mov rdi, rax
    lea rsi, [rip + .Ltoolid]
    mov edx, 7
    call memeq
    cmp eax, 1
    jne .Lfail
    mov rbx, [r13 + M_blocks]
    cmp qword ptr [rbx + VEC_len], 1
    jne .Lfail
    mov rbx, [rbx + VEC_ptr]
    cmp qword ptr [rbx + B_len], 11
    jne .Lfail
    mov rdi, [rbx + B_ptr]
    lea rsi, [rip + .Lresult]
    mov edx, 11
    call memeq
    cmp eax, 1
    jne .Lfail

    lea rdi, [rip + .Lload_ok]
    call print

    # ---- file shape -------------------------------------------------------
    mov rdi, [rip + path_owned]
    lea rsi, [rip + fsb]
    call read_all
    test eax, eax
    js .Lfail
    mov rcx, [rip + fsb + SB_len]
    mov rdx, [rip + fsb + SB_ptr]
    xor eax, eax
    xor esi, esi
.Lcnt:
    cmp rsi, rcx
    jae .Lcntdone
    cmp byte ptr [rdx + rsi], 10
    jne .Lcntnext
    inc eax
.Lcntnext:
    inc rsi
    jmp .Lcnt
.Lcntdone:
    cmp eax, 5
    jne .Lfail
    lea rdi, [rip + .Lprefix]
    call strlen
    mov r13, rax
    mov rdi, [rip + fsb + SB_ptr]
    lea rsi, [rip + .Lprefix]
    mov rdx, r13
    call memeq
    cmp eax, 1
    jne .Lfail
    lea rdi, [rip + .Lfile_ok]
    call print

    # ---- provider/model recovered ----------------------------------------
    mov rdi, r12
    call session_provider
    mov rdi, rax
    lea rsi, [rip + .Lprov]
    call streq
    test eax, eax
    jz .Lfail
    mov rdi, r12
    call session_model
    mov rdi, rax
    lea rsi, [rip + .Lmodel]
    call streq
    test eax, eax
    jz .Lfail
    lea rdi, [rip + .Lmeta_ok]
    call print

    # ---- read-only id/path accessors --------------------------------------
    mov rdi, r12
    call session_id
    test rax, rax
    jz .Lfail
    mov rdi, rax
    mov rsi, [r12 + T_S_ID]
    call streq
    test eax, eax
    jz .Lfail
    mov rdi, r12
    call session_path
    test rax, rax
    jz .Lfail
    mov rdi, rax
    mov rsi, [r12 + T_S_PATH]
    call streq
    test eax, eax
    jz .Lfail
    lea rdi, [rip + .Lid_ok]
    call print

    # ---- directory lookup -------------------------------------------------
    mov rdi, [rip + sb + SB_ptr]
    lea rsi, [rip + .Lcwd]
    call session_find_latest
    test rax, rax
    jz .Lfail
    mov r13, rax
    mov rdi, r13
    mov rsi, [r12 + T_S_PATH]
    call streq
    test eax, eax
    jz .Lfail
    mov rdi, r13
    call mem_free

    mov rdi, [rip + sb + SB_ptr]
    mov rsi, [r12 + T_S_ID]
    call session_find_id
    test rax, rax
    jz .Lfail
    mov r13, rax
    mov rdi, r13
    mov rsi, [r12 + T_S_PATH]
    call streq
    test eax, eax
    jz .Lfail
    mov rdi, r13
    call mem_free
    lea rdi, [rip + .Lfind_ok]
    call print

    # ---- cleanup ----------------------------------------------------------
    mov rdi, r12
    call session_close
    lea rdi, [rip + tr]
    call tr_free
    lea rdi, [rip + tr2]
    call tr_free
    lea rdi, [rip + sb]
    call sb_free
    lea rdi, [rip + fsb]
    call sb_free
    mov rdi, [rip + path_owned]
    call mem_free
    lea rdi, [rip + .Ldone]
    call print
    xor eax, eax
    EPILOGUE

.Lfail:
    lea rdi, [rip + .Lfailmsg]
    call print
    mov eax, 1
    EPILOGUE
