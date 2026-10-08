.include "opcode.inc"
.include "core/core.inc"
# find tool: recursive glob search. Args {pattern, path?, limit?}.
# Depth cap 32, entry cap 20000, results sorted and capped by limit (200 with
# a truncation notice).  Results keep the path argument as a prefix and are
# relative to the cwd.  The walker and glob matcher are shared with grep.s.
# Contract: src/core/API.md.

.equ FIND_DEFAULT_LIMIT, 200
.equ WALK_DEPTH_CAP,     32
.equ WALK_ENTRY_CAP,     20000
.equ SEARCH_REC,         24
.equ SR_PTR,             0
.equ SR_LEN,             8
.equ SR_DIR,             16

.section .rodata
.Lname:    .asciz "find"
.Llabel:   .asciz "find"
.Ldesc:    .asciz "Find files whose path matches a glob pattern; results are sorted and capped by limit; the walk stops once the count exceeds 20000 entries with a truncation notice."
.Lparams:  .asciz "{\"type\":\"object\",\"properties\":{\"pattern\":{\"type\":\"string\",\"description\":\"Glob pattern to match paths\"},\"path\":{\"type\":\"string\",\"description\":\"Directory to search (default .)\"},\"limit\":{\"type\":\"integer\",\"description\":\"Maximum paths to return\"}},\"required\":[\"pattern\"]}"
.Lpath:    .asciz "path"
.Lpattern: .asciz "pattern"
.Llimit:   .asciz "limit"
.Ldot:     .asciz "."
.Lnl:      .asciz "\n"
.Ltr_more: .asciz "[truncated: showing first "
.Ltr_of:   .asciz " of "
.Ltr_end:  .asciz " matches]\n"
.Ltr_cap:  .asciz "[truncated: entry limit 20000 reached]\n"
.Lerr_open: .asciz "error: cannot open "
.Lbadargs:  .asciz "error: invalid arguments"

.section .data
.p2align 3
find_tl:
    .quad .Lname
    .quad .Llabel
    .quad .Ldesc
    .quad .Lparams
    .long TL_READONLY | TL_SEQUENTIAL
    .long 0
    .quad find_exec
    .quad 0

.text

# find_tool_init() -> 0 | -ENOSPC
FN find_tool_init
    lea rdi, [rip + find_tl]
    jmp tools_add

# ------------------------------------------------------------- glob matcher
# search_glob(pat cstr, subj ptr, subjlen) -> 1 | 0
# '*' matches any run that does not cross '/', '**' matches any run (crossing
# '/'), '?' one byte, '\\' escapes the next byte.  Case-sensitive.
FN search_glob
    PROLOGUE 16
    mov rbx, rdi
    mov [rsp], rsi
    mov [rsp + 8], rdx
    mov rdi, rbx
    call strlen
    lea rsi, [rbx + rax]
    mov rdx, [rsp]
    mov rcx, [rsp + 8]
    add rcx, rdx
    mov rdi, rbx
    call glob_here
    EPILOGUE

# glob_here(p, pend, s, send) -> 1 | 0
glob_here:
    PROLOGUE 48
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
.Lgh_top:
    cmp rbx, r12
    jne 1f
    xor eax, eax
    cmp r13, r14
    sete al
    movzx eax, al
    EPILOGUE
1:  movzx eax, byte ptr [rbx]
    cmp eax, '*'
    je .Lgh_star
    cmp r13, r14
    jae .Lgh_no
    cmp eax, '?'
    je .Lgh_one
    cmp eax, '\\'
    jne .Lgh_char
    inc rbx
    cmp rbx, r12
    jae .Lgh_no
    movzx eax, byte ptr [rbx]
.Lgh_char:
    movzx ecx, byte ptr [r13]
    cmp eax, ecx
    jne .Lgh_no
    inc rbx
    inc r13
    jmp .Lgh_top
.Lgh_one:
    inc rbx
    inc r13
    jmp .Lgh_top
.Lgh_star:
    lea r15, [rbx + 1]
.Lgh_collapse:
    cmp r15, r12
    jae .Lgh_star_kind
    cmp byte ptr [r15], '*'
    jne .Lgh_star_kind
    inc r15
    jmp .Lgh_collapse
.Lgh_star_kind:
    mov rax, r15
    sub rax, rbx
    cmp rax, 2
    jb .Lgh_single
    mov [rsp], r15
    mov [rsp + 8], r13
    # '**/' also matches zero directories: try the pattern after the slash at
    # the position where '**' began (treat '**/' as '(.*/)?').  It is tried
    # only here, not at every later position, or '**/x' would match an 'x'
    # that no path separator precedes (e.g. 'barfoo' for '**/foo').
    cmp r15, r12
    jae .Lgh_double_loop
    cmp byte ptr [r15], '/'
    jne .Lgh_double_loop
    lea rdi, [r15 + 1]
    mov rsi, r12
    mov rdx, r13
    mov rcx, r14
    call glob_here
    test eax, eax
    jnz .Lgh_yes
.Lgh_double_loop:
    mov rdi, [rsp]
    mov rsi, r12
    mov rdx, [rsp + 8]
    mov rcx, r14
    call glob_here
    test eax, eax
    jnz .Lgh_yes
    mov rax, [rsp + 8]
    cmp rax, r14
    jae .Lgh_no
    inc qword ptr [rsp + 8]
    jmp .Lgh_double_loop
.Lgh_single:
    mov [rsp], r15
    mov [rsp + 8], r13
.Lgh_single_loop:
    mov rdi, [rsp]
    mov rsi, r12
    mov rdx, [rsp + 8]
    mov rcx, r14
    call glob_here
    test eax, eax
    jnz .Lgh_yes
    mov rax, [rsp + 8]
    cmp rax, r14
    jae .Lgh_no
    cmp byte ptr [rax], '/'
    je .Lgh_no
    inc qword ptr [rsp + 8]
    jmp .Lgh_single_loop
.Lgh_yes:
    mov eax, 1
    EPILOGUE
.Lgh_no:
    xor eax, eax
    EPILOGUE

# ------------------------------------------------------------------ walker
# search_walk(root, cb, ctx) -> 0 complete | 1 entry cap | 2 cb abort
#                                | -errno (root could not be opened)
# cb(path cstr, is_dir, ctx) -> 0 continue | 1 skip recursion | -1 abort.
# A file root is passed to cb once and not walked.  Directories are iterated
# in sorted name order.
.equ SW_CB, 0
.equ SW_CTX, 8
.equ SW_ENTRIES, 16
.equ SW_STATUS, 24
.equ SW_SB, 32
FN search_walk
    PROLOGUE 256
    mov [rsp + SW_CB], rsi
    mov [rsp + SW_CTX], rdx
    mov qword ptr [rsp + SW_ENTRIES], 0
    mov qword ptr [rsp + SW_STATUS], 0
    mov qword ptr [rsp + SW_SB + SB_ptr], 0
    mov qword ptr [rsp + SW_SB + SB_len], 0
    mov qword ptr [rsp + SW_SB + SB_cap], 0
    mov [rsp + 64], rdi
    mov esi, O_CLOEXEC | O_NONBLOCK
    xor edx, edx
    call os_open
    test rax, rax
    js .Lsw_ret
    mov rbx, rax
    mov rdi, rbx
    lea rsi, [rsp + 96]
    call os_fstat
    mov r12, rax
    mov rdi, rbx
    call os_close
    test r12, r12
    js .Lsw_err
    mov eax, [rsp + 96 + 24]
    and eax, 0xF000
    cmp eax, 0x4000
    je .Lsw_dir
    mov rdi, [rsp + 64]
    xor esi, esi
    mov rdx, [rsp + SW_CTX]
    call qword ptr [rsp + SW_CB]
    cmp eax, -1
    je .Lsw_abort
    xor eax, eax
    EPILOGUE
.Lsw_abort:
    mov eax, 2
    EPILOGUE
.Lsw_dir:
    lea rdi, [rsp + SW_SB]
    mov rsi, [rsp + 64]
    call sb_push_cstr
    lea rdi, [rsp]
    xor esi, esi
    call search_walk_dir
    lea rdi, [rsp + SW_SB]
    call sb_free
    mov rax, [rsp + SW_STATUS]
    EPILOGUE
.Lsw_err:
    mov rax, r12
.Lsw_ret:
    EPILOGUE

# search_walk_dir(state, depth)
.equ WD_VEC, 0
.equ WD_I, 8
.equ WD_PATHLEN, 16
.equ WD_REC, 24
.equ WD_CAPPED, 32
FN search_walk_dir
    PROLOGUE 64
    mov rbx, rdi
    mov r12, rsi
    call search_vec_new
    mov [rsp + WD_VEC], rax
    mov rdi, [rbx + SW_SB + SB_ptr]
    mov rsi, rax
    mov edx, WALK_ENTRY_CAP
    call search_dir_read
    test rax, rax
    js .Lswd_free
    mov qword ptr [rsp + WD_CAPPED], 0
    cmp rax, 1
    jne 5f
    mov qword ptr [rsp + WD_CAPPED], 1
5:
    mov rdi, [rsp + WD_VEC]
    call search_sort
    mov rax, [rbx + SW_SB + SB_len]
    mov [rsp + WD_PATHLEN], rax
    mov qword ptr [rsp + WD_I], 0
.Lswd_loop:
    cmp qword ptr [rbx + SW_STATUS], 0
    jne .Lswd_free
    mov rax, [rsp + WD_I]
    mov rcx, [rsp + WD_VEC]
    cmp rax, [rcx + VEC_len]
    jb .Lswd_body
    # a directory whose read hit the per-directory cap is a truncated walk
    cmp qword ptr [rsp + WD_CAPPED], 0
    je .Lswd_free
    mov qword ptr [rbx + SW_STATUS], 1
    jmp .Lswd_free
.Lswd_body:
    mov rcx, [rbx + SW_ENTRIES]
    inc rcx
    mov [rbx + SW_ENTRIES], rcx
    cmp rcx, WALK_ENTRY_CAP
    jbe 1f
    mov qword ptr [rbx + SW_STATUS], 1
    jmp .Lswd_free
1:  mov rcx, [rsp + WD_VEC]
    mov rcx, [rcx + VEC_ptr]
    mov rax, [rsp + WD_I]
    imul rax, SEARCH_REC
    add rcx, rax
    mov [rsp + WD_REC], rcx
    mov rax, [rbx + SW_SB + SB_len]
    test rax, rax
    jz 2f
    mov rcx, [rbx + SW_SB + SB_ptr]
    cmp byte ptr [rcx + rax - 1], '/'
    je 3f
2:  lea rdi, [rbx + SW_SB]
    mov esi, '/'
    call sb_push_byte
3:  lea rdi, [rbx + SW_SB]
    mov rcx, [rsp + WD_REC]
    mov rsi, [rcx + SR_PTR]
    mov rdx, [rcx + SR_LEN]
    call sb_push
    mov rcx, [rsp + WD_REC]
    mov rdi, [rbx + SW_SB + SB_ptr]
    mov esi, dword ptr [rcx + SR_DIR]
    mov rdx, [rbx + SW_CTX]
    call qword ptr [rbx + SW_CB]
    cmp eax, 1
    je .Lswd_skip
    test eax, eax
    js .Lswd_abort
    mov rcx, [rsp + WD_REC]
    cmp qword ptr [rcx + SR_DIR], 0
    je .Lswd_skip
    cmp r12, WALK_DEPTH_CAP
    jae .Lswd_skip
    mov rdi, rbx
    lea rsi, [r12 + 1]
    call search_walk_dir
    jmp .Lswd_skip
.Lswd_abort:
    mov qword ptr [rbx + SW_STATUS], 2
.Lswd_skip:
    mov rax, [rsp + WD_PATHLEN]
    mov [rbx + SW_SB + SB_len], rax
    mov rcx, [rbx + SW_SB + SB_ptr]
    mov byte ptr [rcx + rax], 0
    inc qword ptr [rsp + WD_I]
    jmp .Lswd_loop
.Lswd_free:
    mov rdi, [rsp + WD_VEC]
    call search_vec_free
    EPILOGUE

# ------------------------------------------------------------------ find
.equ FC_RES, 0
.equ FC_PAT, 8
.equ FC_SLASH, 16
.equ FC_ROOTLEN, 24
FN find_cb
    PROLOGUE 32
    mov rbx, rdi
    mov [rsp], rdx
    mov r12, rsi
    mov rdi, rbx
    call strlen
    mov r13, rax
    mov r14, -1
    xor ecx, ecx
.Lfc_scan:
    cmp rcx, r13
    jae .Lfc_scandone
    cmp byte ptr [rbx + rcx], '/'
    jne 1f
    mov r14, rcx
1:  inc rcx
    jmp .Lfc_scan
.Lfc_scandone:
    mov rdx, [rsp]
    cmp qword ptr [rdx + FC_SLASH], 0
    jne .Lfc_rel
    lea r15, [rbx + r14 + 1]
    mov rax, r13
    sub rax, r14
    dec rax
    mov [rsp + 8], rax
    jmp .Lfc_match
.Lfc_rel:
    mov rax, [rdx + FC_ROOTLEN]     # full prefix length (root plus separator)
    lea r15, [rbx + rax]
    mov rcx, r13
    sub rcx, rax
    js .Lfc_none
    mov [rsp + 8], rcx
.Lfc_match:
    mov rdi, [rdx + FC_PAT]
    mov rsi, r15
    mov rdx, [rsp + 8]
    call search_glob
    test eax, eax
    jz .Lfc_none
    mov rdi, rbx
    mov rsi, r13
    call mem_dup
    mov r15, rax
    mov rdx, [rsp]
    mov rdi, [rdx + FC_RES]
    mov esi, SEARCH_REC
    call vec_push
    mov [rax], r15
    mov [rax + SR_LEN], r13
    mov [rax + SR_DIR], r12
.Lfc_none:
    xor eax, eax
    EPILOGUE

.equ FE_JOB, 0
.equ FE_PAT, 8
.equ FE_LIMIT, 16
.equ FE_NORM, 24
.equ FE_RES, 32
.equ FE_STATUS, 40
.equ FE_I, 48
.equ FE_N, 56
.equ FE_ERR, 64
.equ FE_CTX, 80
FN find_exec
    PROLOGUE 128
    mov [rsp + FE_JOB], rdi
    mov qword ptr [rsp + FE_PAT], 0
    mov qword ptr [rsp + FE_LIMIT], 0
    mov qword ptr [rsp + FE_NORM], 0
    mov qword ptr [rsp + FE_RES], 0
    mov rdi, [rdi + J_args]
    test rdi, rdi
    jz .Lfe_bad
    call strlen
    mov rsi, rax
    mov rdi, [rsp + FE_JOB]
    mov rdi, [rdi + J_args]
    call json_parse
    test rax, rax
    jz .Lfe_bad
    mov rbx, rax
    mov rdi, rbx
    lea rsi, [rip + .Lpattern]
    call json_get_cstr
    test rax, rax
    jz .Lfe_bad
    mov [rsp + FE_PAT], rax
    mov rdi, rbx
    lea rsi, [rip + .Lpath]
    call json_get_cstr
    test rax, rax
    jnz 1f
    lea rax, [rip + .Ldot]
1:  mov [rsp + FE_NORM], rax
    mov rdi, rbx
    lea rsi, [rip + .Llimit]
    mov edx, FIND_DEFAULT_LIMIT
    call json_get_u64
    mov [rsp + FE_LIMIT], rax
    mov rdi, [rsp + FE_NORM]
    call search_norm_root
    mov [rsp + FE_NORM], rax
    call search_vec_new
    mov [rsp + FE_RES], rax
    # ctx
    mov [rsp + FE_CTX + FC_RES], rax
    mov rax, [rsp + FE_PAT]
    mov [rsp + FE_CTX + FC_PAT], rax
    mov rdi, rax
    call search_has_slash
    mov [rsp + FE_CTX + FC_SLASH], rax
    mov rdi, [rsp + FE_NORM]
    call strlen
    mov rcx, rax                    # prefix = rootlen + (root ends in '/' ? 0 : 1)
    test rcx, rcx
    jz 2f
    mov rdx, [rsp + FE_NORM]
    cmp byte ptr [rdx + rcx - 1], '/'
    je 2f
    inc rcx
2:  mov [rsp + FE_CTX + FC_ROOTLEN], rcx
    mov rdi, [rsp + FE_NORM]
    lea rsi, [rip + find_cb]
    lea rdx, [rsp + FE_CTX]
    call search_walk
    mov [rsp + FE_STATUS], rax
    test rax, rax
    js .Lfe_err
    mov rdi, [rsp + FE_RES]
    call search_sort
    mov rbx, [rsp + FE_JOB]
    mov rdi, [rbx + J_out]
    call sb_clear
    mov rax, [rsp + FE_RES]
    mov rax, [rax + VEC_len]
    mov rcx, [rsp + FE_LIMIT]
    cmp rax, rcx
    cmova rax, rcx
    mov [rsp + FE_N], rax
    mov qword ptr [rsp + FE_I], 0
.Lfe_emit:
    mov rax, [rsp + FE_I]
    cmp rax, [rsp + FE_N]
    jae .Lfe_notice
    mov rcx, [rsp + FE_RES]
    mov rcx, [rcx + VEC_ptr]
    imul rax, SEARCH_REC
    add rcx, rax
    mov rdi, [rbx + J_out]
    mov rsi, [rcx + SR_PTR]
    call sb_push_cstr
    mov rdi, [rbx + J_out]
    lea rsi, [rip + .Lnl]
    call sb_push_cstr
    inc qword ptr [rsp + FE_I]
    jmp .Lfe_emit
.Lfe_notice:
    mov rax, [rsp + FE_RES]
    mov rcx, [rsp + FE_LIMIT]
    cmp [rax + VEC_len], rcx
    jbe 1f
    mov rdi, [rbx + J_out]
    lea rsi, [rip + .Ltr_more]
    call sb_push_cstr
    mov rdi, [rbx + J_out]
    mov rsi, [rsp + FE_LIMIT]
    call sb_push_u64
    mov rdi, [rbx + J_out]
    lea rsi, [rip + .Ltr_of]
    call sb_push_cstr
    mov rdi, [rbx + J_out]
    mov rsi, [rsp + FE_RES]
    mov rsi, [rsi + VEC_len]
    call sb_push_u64
    mov rdi, [rbx + J_out]
    lea rsi, [rip + .Ltr_end]
    call sb_push_cstr
    jmp .Lfe_done
1:  cmp qword ptr [rsp + FE_STATUS], 1
    jne .Lfe_done
    mov rdi, [rbx + J_out]
    lea rsi, [rip + .Ltr_cap]
    call sb_push_cstr
.Lfe_done:
    mov rdi, [rsp + FE_RES]
    call search_vec_free
    mov rdi, [rsp + FE_NORM]
    call mem_free
    mov rdi, [rsp + FE_JOB]
    call tool_done
    xor eax, eax
    EPILOGUE
.Lfe_err:
    mov [rsp + FE_ERR], rax
    mov rdi, [rsp + FE_JOB]
    lea rsi, [rip + .Lerr_open]
    mov rdx, [rsp + FE_NORM]
    mov rcx, [rsp + FE_ERR]
    call search_err
    jmp .Lfe_done
.Lfe_bad:
    mov rdi, [rsp + FE_JOB]
    lea rsi, [rip + .Lbadargs]
    xor edx, edx
    xor ecx, ecx
    call search_err
    mov rdi, [rsp + FE_NORM]
    call mem_free
    mov rdi, [rsp + FE_RES]
    call search_vec_free
    xor eax, eax
    EPILOGUE
