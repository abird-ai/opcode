.include "opcode.inc"
.include "core/core.inc"
# session_version_test: session_load schema_version policy.
#   current (1)          -> loads
#   missing / legacy     -> treated as 1, loads
#   newer (2)            -> refused with the version pair and the reason
# The JSONL truncation tolerance itself stays covered by session_test.

.bss
.p2align 3
tr: .zero TR_SIZE

.section .rodata
.Lpath_cur:  .asciz "build/sv_unit_current.jsonl"
.Lpath_leg:  .asciz "build/sv_unit_legacy.jsonl"
.Lpath_new:  .asciz "build/sv_unit_newer.jsonl"
.Lpath_num:  .asciz "build/sv_unit_nonnumeric.jsonl"

.Lcur:
    .ascii "{\"type\":\"session\",\"schema_version\":1,\"id\":\"deadbeef\",\"cwd\":\"/tmp\"}\n"
    .ascii "{\"type\":\"message\",\"id\":\"1\",\"parent_id\":null,\"message\":{\"role\":\"user\",\"timestamp\":2,\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}}\n"
.set LEN_CUR, . - .Lcur
.Lleg:
    .ascii "{\"type\":\"session\",\"id\":\"deadbeef\",\"cwd\":\"/tmp\"}\n"
    .ascii "{\"type\":\"message\",\"id\":\"1\",\"parent_id\":null,\"message\":{\"role\":\"user\",\"timestamp\":2,\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}}\n"
.set LEN_LEG, . - .Lleg
.Lnew:
    .ascii "{\"type\":\"session\",\"schema_version\":2,\"id\":\"deadbeef\",\"cwd\":\"/tmp\"}\n"
    .ascii "{\"type\":\"message\",\"id\":\"1\",\"parent_id\":null,\"message\":{\"role\":\"user\",\"timestamp\":2,\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}}\n"
.set LEN_NEW, . - .Lnew
.Lnum:
    .ascii "{\"type\":\"session\",\"schema_version\":\"999\",\"id\":\"deadbeef\",\"cwd\":\"/tmp\"}\n"
    .ascii "{\"type\":\"message\",\"id\":\"1\",\"parent_id\":null,\"message\":{\"role\":\"user\",\"timestamp\":2,\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}}\n"
.set LEN_NUM, . - .Lnum

.M_cur:  .asciz "session version current ok\n"
.M_leg:  .asciz "session version legacy ok\n"
.M_new:  .asciz "session version newer ok\n"
.M_num:  .asciz "session version nonnumeric ok\n"
.M_done: .asciz "session version done\n"
.M_fail: .asciz "FAIL session version\n"

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

# write_file(path, ptr, len) -> 0 | -1
write_file:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov rdi, r12
    mov esi, O_WRONLY | O_CREAT | O_TRUNC
    mov edx, 0644
    call os_open
    test rax, rax
    js .Lwf_bad
    mov rbx, rax
    mov edi, ebx
    mov rsi, r13
    mov rdx, r14
    call write_all
    mov edi, ebx
    call os_close
    xor eax, eax
    EPILOGUE
.Lwf_bad:
    mov rax, -1
    EPILOGUE

# load_case(path) -> session_load result | -1 on open failure
load_case:
    PROLOGUE
    call session_open
    test rax, rax
    jz .Llc_bad
    mov r12, rax
    lea rdi, [rip + tr]
    call tr_init
    mov rdi, r12
    lea rsi, [rip + tr]
    call session_load
    mov r13, rax
    mov rdi, r12
    call session_close
    mov rax, r13
    EPILOGUE
.Llc_bad:
    mov rax, -1
    EPILOGUE

# tr_len_is(n) -> 1 | 0
tr_len_is:
    PROLOGUE
    mov r12, rdi
    lea rdi, [rip + tr]
    call tr_len
    cmp rax, r12
    jne .Ltl_no
    mov eax, 1
    EPILOGUE
.Ltl_no:
    xor eax, eax
    EPILOGUE

FN opcode_main
    PROLOGUE
    lea rdi, [rip + .Lpath_cur]
    lea rsi, [rip + .Lcur]
    mov edx, LEN_CUR
    call write_file
    test rax, rax
    js .Lfail
    lea rdi, [rip + .Lpath_cur]
    call load_case
    test rax, rax
    jnz .Lfail
    mov edi, 1
    call tr_len_is
    cmp eax, 1
    jne .Lfail
    lea rdi, [rip + .M_cur]
    call print

    lea rdi, [rip + .Lpath_leg]
    lea rsi, [rip + .Lleg]
    mov edx, LEN_LEG
    call write_file
    test rax, rax
    js .Lfail
    lea rdi, [rip + .Lpath_leg]
    call load_case
    test rax, rax
    jnz .Lfail
    mov edi, 1
    call tr_len_is
    cmp eax, 1
    jne .Lfail
    lea rdi, [rip + .M_leg]
    call print

    lea rdi, [rip + .Lpath_new]
    lea rsi, [rip + .Lnew]
    mov edx, LEN_NEW
    call write_file
    test rax, rax
    js .Lfail
    lea rdi, [rip + .Lpath_new]
    call load_case
    test rax, rax
    jns .Lfail
    xor edi, edi
    call tr_len_is
    cmp eax, 1
    jne .Lfail
    lea rdi, [rip + .M_new]
    call print

    # non-numeric schema_version (for example a quoted "999") must be refused
    lea rdi, [rip + .Lpath_num]
    lea rsi, [rip + .Lnum]
    mov edx, LEN_NUM
    call write_file
    test rax, rax
    js .Lfail
    lea rdi, [rip + .Lpath_num]
    call load_case
    test rax, rax
    jns .Lfail
    xor edi, edi
    call tr_len_is
    cmp eax, 1
    jne .Lfail
    lea rdi, [rip + .M_num]
    call print

    lea rdi, [rip + .M_done]
    call print
    xor eax, eax
    EPILOGUE
.Lfail:
    lea rdi, [rip + .M_fail]
    call print
    mov eax, 1
    EPILOGUE
