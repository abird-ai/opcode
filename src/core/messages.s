.include "opcode.inc"
.include "core/core.inc"
# messages.s: Transcript / Msg / Block / ToolCall model for the agent loop.
# Contract: src/core/API.md.
#
# Ownership
# ---------
# Every string passed to a msg_* function is copied with mem_dup (mem_alloc +
# copy, NUL-terminated) and owned by the transcript; tr_free releases all of
# it. Because msg_new/msg_add_* receive no Transcript*, a file-global
# "current transcript" (g_tr_cur, set by tr_init/tr_push) receives every
# allocation in its TR_owned VEC. tr_free walks TR_owned, mem_free()s each
# tracked pointer, then frees the VEC containers themselves:
#   * leaf allocations (text copies, TC structs + their 3 strings, Usage
#     copies, call ids, Msg structs) live in TR_owned;
#   * the growable VEC item arrays (TR_msgs/TR_owned/msg M_blocks) cannot be
#     tracked this way because vec_push may realloc them, so tr_free frees
#     them structurally: each Msg's M_blocks VEC first, then the two
#     transcript VEC containers.
# This assumes one transcript is built at a time (the agent keeps exactly one);
# tr_free clears g_tr_cur so a fresh tr_init restarts cleanly.

.bss
.p2align 3
# Transcript whose msg_* copies are currently appended to TR_owned.
g_tr_cur: .quad 0

.section .rodata
.Lempty: .asciz ""

.text

# ---------------------------------------------------------------- internal
# .Lown_push(ptr): append a heap allocation to g_tr_cur->TR_owned (NULL-safe).
.Lown_push:
    PROLOGUE
    mov r12, rdi
    test r12, r12
    jz .Lop_ret
    mov rax, [rip + g_tr_cur]
    test rax, rax
    jz .Lop_ret
    mov rdi, [rax + TR_owned]
    test rdi, rdi
    jz .Lop_ret
    mov esi, 8
    call vec_push
    mov [rax], r12
.Lop_ret:
    EPILOGUE

# .Ldup_str(cstr) -> owned NUL-terminated copy; NULL becomes an owned "".
.Ldup_str:
    PROLOGUE
    test rdi, rdi
    jnz .Lds_go
    lea rdi, [rip + .Lempty]
.Lds_go:
    mov rbx, rdi
    call strlen
    mov rsi, rax
    mov rdi, rbx
    call mem_dup
    mov rbx, rax
    mov rdi, rax
    call .Lown_push
    mov rax, rbx
    EPILOGUE

# ---------------------------------------------------------------- transcript
# tr_init(tr): zero the Transcript, allocate its VEC containers, make it
# current for subsequent msg_* allocations.
FN tr_init
    PROLOGUE
    test rdi, rdi
    jz .Lti_ret
    mov r12, rdi
    mov qword ptr [r12 + TR_msgs], 0
    mov qword ptr [r12 + TR_owned], 0
    mov edi, VEC_SIZE
    call mem_alloc
    mov [r12 + TR_msgs], rax
    mov edi, VEC_SIZE
    call mem_alloc
    mov [r12 + TR_owned], rax
    mov [rip + g_tr_cur], r12
.Lti_ret:
    xor eax, eax
    EPILOGUE

# tr_free(tr): free every tracked allocation plus the block VECs and the two
# Transcript VECs; the Transcript is left zeroed and g_tr_cur cleared.
FN tr_free
    PROLOGUE
    test rdi, rdi
    jz .Ltf_ret
    mov r12, rdi

    # Each Msg's M_blocks VEC is an untracked container: free its item array
    # and its struct. Msg structs themselves are freed through TR_owned below.
    mov r13, [r12 + TR_msgs]
    test r13, r13
    jz .Ltf_owned
    mov r14, [r13 + VEC_ptr]
    xor r15d, r15d
.Ltf_msg:
    cmp r15, [r13 + VEC_len]
    jae .Ltf_msgvec
    mov rbx, [r14 + r15*8]
    test rbx, rbx
    jz .Ltf_msgnext
    mov rdi, [rbx + M_blocks]
    test rdi, rdi
    jz .Ltf_msgnext
    call vec_free
    mov rdi, [rbx + M_blocks]
    call mem_free
.Ltf_msgnext:
    inc r15
    jmp .Ltf_msg
.Ltf_msgvec:
    mov rdi, r13
    call vec_free
    mov rdi, r13
    call mem_free

    # Leaf allocations: text copies, TC structs + strings, Usage copies, call
    # ids, Msg structs.
.Ltf_owned:
    mov r13, [r12 + TR_owned]
    test r13, r13
    jz .Ltf_fin
    mov r14, [r13 + VEC_ptr]
    xor r15d, r15d
.Ltf_own:
    cmp r15, [r13 + VEC_len]
    jae .Ltf_ownvec
    mov rdi, [r14 + r15*8]
    call mem_free
    inc r15
    jmp .Ltf_own
.Ltf_ownvec:
    mov rdi, r13
    call vec_free
    mov rdi, r13
    call mem_free

.Ltf_fin:
    cmp qword ptr [rip + g_tr_cur], r12
    jne .Ltf_zero
    mov qword ptr [rip + g_tr_cur], 0
.Ltf_zero:
    mov qword ptr [r12 + TR_msgs], 0
    mov qword ptr [r12 + TR_owned], 0
.Ltf_ret:
    EPILOGUE

# tr_push(tr, Msg*) -> Msg* (0 on NULL/uninitialised)
FN tr_push
    PROLOGUE
    test rdi, rdi
    jz .Ltp_zero
    test rsi, rsi
    jz .Ltp_zero
    mov r12, rdi
    mov r13, rsi
    mov [rip + g_tr_cur], r12
    mov rdi, [r12 + TR_msgs]
    test rdi, rdi
    jz .Ltp_zero
    mov esi, 8
    call vec_push
    mov [rax], r13
    mov rax, r13
    EPILOGUE
.Ltp_zero:
    xor eax, eax
    EPILOGUE

# tr_len(tr) -> n
FN tr_len
    xor eax, eax
    test rdi, rdi
    jz .Ltl_ret
    mov rdi, [rdi + TR_msgs]
    test rdi, rdi
    jz .Ltl_ret
    mov rax, [rdi + VEC_len]
.Ltl_ret:
    ret

# tr_msg(tr, i) -> Msg* | 0
FN tr_msg
    xor eax, eax
    test rdi, rdi
    jz .Ltm_ret
    mov rdi, [rdi + TR_msgs]
    test rdi, rdi
    jz .Ltm_ret
    cmp rsi, [rdi + VEC_len]
    jae .Ltm_ret
    mov rax, [rdi + VEC_ptr]
    mov rax, [rax + rsi*8]
.Ltm_ret:
    ret

# tr_clear(tr): tr_free + tr_init; the transcript stays usable.
FN tr_clear
    PROLOGUE
    test rdi, rdi
    jz .Ltc_ret
    mov r12, rdi
    call tr_free
    mov rdi, r12
    call tr_init
.Ltc_ret:
    EPILOGUE

# ---------------------------------------------------------------- messages
# msg_new(role) -> Msg*; blocks VEC allocated, stop = SR_PENDING.
FN msg_new
    PROLOGUE
    mov r12d, edi
    mov edi, M_SIZE
    call mem_alloc
    mov rbx, rax
    mov dword ptr [rbx + M_role], r12d
    mov dword ptr [rbx + M_stop], SR_PENDING
    mov edi, VEC_SIZE
    call mem_alloc
    mov [rbx + M_blocks], rax
    mov rdi, rbx
    call .Lown_push
    mov rax, rbx
    EPILOGUE

# msg_add_block(msg, type, ptr, len) -> Block*
# BT_TEXT/BT_THINK: copy ptr/len (NUL-terminated), set B_len. Other types get
# a zeroed block with B_type set.
FN msg_add_block
    PROLOGUE
    test rdi, rdi
    jz .Lab_zero
    cmp esi, BT_TEXT
    je .Lab_text
    cmp esi, BT_THINK
    je .Lab_text
    mov r12, rdi
    mov r13d, esi
    mov rdi, [r12 + M_blocks]
    mov esi, B_SIZE
    call vec_push
    mov dword ptr [rax + B_type], r13d
    EPILOGUE
.Lab_text:
    mov r12, rdi
    mov r13d, esi
    mov r14, rdx
    mov r15, rcx
    test r14, r14
    jnz .Lab_copy
    lea r14, [rip + .Lempty]
    xor r15d, r15d
.Lab_copy:
    mov rdi, r14
    mov rsi, r15
    call mem_dup
    mov r14, rax
    mov rdi, rax
    call .Lown_push
    mov rdi, [r12 + M_blocks]
    mov esi, B_SIZE
    call vec_push
    mov dword ptr [rax + B_type], r13d
    mov [rax + B_ptr], r14
    mov [rax + B_len], r15
    EPILOGUE
.Lab_zero:
    xor eax, eax
    EPILOGUE

# msg_add_toolcall(msg, id cstr, name cstr, args cstr) -> Block*
# Allocates a TC struct, copies the three strings (NULL -> ""), appends a
# BT_TOOLCALL block whose B_ptr is the TC.
FN msg_add_toolcall
    PROLOGUE
    test rdi, rdi
    jz .Lat_zero
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    mov edi, TC_SIZE
    call mem_alloc
    mov rbx, rax
    mov rdi, r13
    call .Ldup_str
    mov [rbx + TC_id], rax
    mov rdi, r14
    call .Ldup_str
    mov [rbx + TC_name], rax
    mov rdi, r15
    call .Ldup_str
    mov [rbx + TC_args], rax
    mov rdi, rbx
    call .Lown_push
    mov rdi, [r12 + M_blocks]
    mov esi, B_SIZE
    call vec_push
    mov dword ptr [rax + B_type], BT_TOOLCALL
    mov [rax + B_ptr], rbx
    EPILOGUE
.Lat_zero:
    xor eax, eax
    EPILOGUE

# msg_set_usage(msg, Usage*): copy the struct; NULL clears the pointer.
FN msg_set_usage
    PROLOGUE
    test rdi, rdi
    jz .Lsu_ret
    mov r12, rdi
    test rsi, rsi
    jz .Lsu_clear
    mov r13, rsi
    mov edi, USAGE_SIZE
    call mem_alloc
    mov rbx, rax
    mov rax, [r13]
    mov [rbx], rax
    mov rax, [r13 + 8]
    mov [rbx + 8], rax
    mov rax, [r13 + 16]
    mov [rbx + 16], rax
    mov rdi, rbx
    call .Lown_push
    mov [r12 + M_usage], rbx
    EPILOGUE
.Lsu_clear:
    mov qword ptr [r12 + M_usage], 0
.Lsu_ret:
    EPILOGUE

# msg_set_call_id(msg, id cstr): copy the tool_call id; NULL clears it.
FN msg_set_call_id
    PROLOGUE
    test rdi, rdi
    jz .Lsc_ret
    mov r12, rdi
    test rsi, rsi
    jz .Lsc_clear
    mov rdi, rsi
    call .Ldup_str
    mov [r12 + M_call_id], rax
    EPILOGUE
.Lsc_clear:
    mov qword ptr [r12 + M_call_id], 0
.Lsc_ret:
    EPILOGUE

# msg_call_id(msg) -> cstr | 0
FN msg_call_id
    xor eax, eax
    test rdi, rdi
    jz .Lmci_ret
    mov rax, [rdi + M_call_id]
.Lmci_ret:
    ret

# msg_toolcalls(msg) -> count of BT_TOOLCALL blocks
FN msg_toolcalls
    xor eax, eax
    test rdi, rdi
    jz .Lmtc_ret
    mov rdi, [rdi + M_blocks]
    test rdi, rdi
    jz .Lmtc_ret
    mov r8, [rdi + VEC_ptr]
    mov rcx, [rdi + VEC_len]
    xor edx, edx
.Lmtc_loop:
    cmp rdx, rcx
    jae .Lmtc_ret
    mov r9, rdx
    imul r9, r9, B_SIZE
    cmp dword ptr [r8 + r9 + B_type], BT_TOOLCALL
    jne .Lmtc_next
    inc eax
.Lmtc_next:
    inc rdx
    jmp .Lmtc_loop
.Lmtc_ret:
    ret

# msg_toolcall(msg, i) -> TC* of the i-th tool call | 0
FN msg_toolcall
    xor eax, eax
    test rdi, rdi
    jz .Lmt_ret
    mov rdi, [rdi + M_blocks]
    test rdi, rdi
    jz .Lmt_ret
    mov r8, [rdi + VEC_ptr]
    mov rcx, [rdi + VEC_len]
    xor edx, edx
    xor r9d, r9d
.Lmt_loop:
    cmp rdx, rcx
    jae .Lmt_ret
    mov r10, rdx
    imul r10, r10, B_SIZE
    cmp dword ptr [r8 + r10 + B_type], BT_TOOLCALL
    jne .Lmt_next
    cmp r9d, esi
    je .Lmt_hit
    inc r9d
.Lmt_next:
    inc rdx
    jmp .Lmt_loop
.Lmt_hit:
    mov rax, [r8 + r10 + B_ptr]
.Lmt_ret:
    ret
