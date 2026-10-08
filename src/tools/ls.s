.include "opcode.inc"
.include "core/core.inc"
# ls tool + shared search helpers for ls/find/grep.
# Contract: src/core/API.md.  Shared path-table layout (24 bytes per record):
#   +0 ptr (mem_dup'd name/path), +8 byte length, +16 is_dir flag.
# The helpers are internal but must be global so find.s/grep.s can link to
# them; only the *_tool_init / *_exec / search_tools_init names are API.

.equ LS_DEFAULT_LIMIT, 200
.equ LS_ENTRY_CAP,     20000        # per-directory read cap (sorted prefix stays correct)
.equ SEARCH_CHUNK,     32768
.equ SEARCH_REC,       24
.equ SR_PTR,           0
.equ SR_LEN,           8
.equ SR_DIR,           16

.section .rodata
.Lname:    .asciz "ls"
.Llabel:   .asciz "ls"
.Ldesc:    .asciz "List one directory, sorted by name, directories with a trailing /; hidden files are included; the listing is capped by limit."
.Lparams:  .asciz "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"Directory to list (default .)\"},\"limit\":{\"type\":\"integer\",\"description\":\"Maximum entries to return\"}},\"required\":[]}"
.Ltool_path:  .asciz "path"
.Ltool_limit: .asciz "limit"
.Ldot:        .asciz "."
.Lcolon_nl:   .asciz ":\n"
.Lerr_errno:  .asciz " (errno "
.Lrparen:     .asciz ")"
.Lerr_open:   .asciz "error: cannot open "
.Lbadargs:    .asciz "error: invalid arguments"

.section .data
.p2align 3
ls_tl:
    .quad .Lname
    .quad .Llabel
    .quad .Ldesc
    .quad .Lparams
    .long TL_READONLY | TL_SEQUENTIAL
    .long 0
    .quad ls_exec
    .quad 0

.text

# ------------------------------------------------------------------ exports
# ls_tool_init() -> 0 | -ENOSPC
FN ls_tool_init
    lea rdi, [rip + ls_tl]
    jmp tools_add

# search_tools_init() -> 0 | -ENOSPC: registers ls, find and grep.
FN search_tools_init
    PROLOGUE
    call ls_tool_init
    test eax, eax
    js 1f
    call find_tool_init
    test eax, eax
    js 1f
    call grep_tool_init
1:  EPILOGUE

# ------------------------------------------------------------- shared helpers
# search_vec_new() -> VEC* (zeroed, 24-byte records)
FN search_vec_new
    PROLOGUE 0
    mov edi, VEC_SIZE
    call mem_alloc
    EPILOGUE

# search_vec_free(v): frees every record name plus the vector storage.
FN search_vec_free
    PROLOGUE 0
    mov rbx, rdi
    test rbx, rbx
    jz .Lsvf_done
    mov r12, [rbx + VEC_ptr]
    mov r13, [rbx + VEC_len]
    xor r14d, r14d
.Lsvf_loop:
    cmp r14, r13
    jae .Lsvf_vec
    mov rax, r14
    imul rax, SEARCH_REC
    mov rdi, [r12 + rax]
    call mem_free
    inc r14
    jmp .Lsvf_loop
.Lsvf_vec:
    mov rdi, rbx
    call vec_free
    mov rdi, rbx
    call mem_free
.Lsvf_done:
    xor eax, eax
    EPILOGUE

# search_rec_cmp(r1, r2) -> -1 | 0 | 1 (unsigned bytes, shorter prefix first)
search_rec_cmp:
    mov r10, [rdi + SR_PTR]
    mov r11, [rsi + SR_PTR]
    mov r8, [rdi + SR_LEN]
    mov r9, [rsi + SR_LEN]
    mov rax, r8
    cmp rax, r9
    cmova rax, r9
    xor ecx, ecx
.Lsrc_loop:
    cmp rcx, rax
    jae .Lsrc_pref
    movzx edx, byte ptr [r10 + rcx]
    movzx edi, byte ptr [r11 + rcx]
    cmp edx, edi
    jb .Lsrc_less
    ja .Lsrc_greater
    inc rcx
    jmp .Lsrc_loop
.Lsrc_pref:
    cmp r8, r9
    jb .Lsrc_less
    ja .Lsrc_greater
    xor eax, eax
    ret
.Lsrc_less:
    mov eax, -1
    ret
.Lsrc_greater:
    mov eax, 1
    ret

# search_sort(v): bottom-up merge sort of 24-byte records by name bytes.
.equ SS_TMP, 0
.equ SS_N, 8
.equ SS_W, 16
.equ SS_I, 24
.equ SS_MID, 32
.equ SS_END, 40
.equ SS_A, 48
.equ SS_B, 56
.equ SS_K, 64
FN search_sort
    PROLOGUE 96
    mov rbx, rdi
    mov r12, [rbx + VEC_len]
    cmp r12, 2
    jb .Lss_ret
    mov rax, r12
    imul rdi, rax, SEARCH_REC
    call mem_alloc
    mov [rsp + SS_TMP], rax
    mov [rsp + SS_N], r12
    mov qword ptr [rsp + SS_W], 1
.Lss_w:
    mov rax, [rsp + SS_W]
    cmp rax, [rsp + SS_N]
    jae .Lss_done
    mov qword ptr [rsp + SS_I], 0
.Lss_i:
    mov rax, [rsp + SS_I]
    cmp rax, [rsp + SS_N]
    jae .Lss_nextw
    add rax, [rsp + SS_W]
    cmp rax, [rsp + SS_N]
    cmova rax, [rsp + SS_N]
    mov [rsp + SS_MID], rax
    mov rax, [rsp + SS_I]
    mov rcx, [rsp + SS_W]
    lea rax, [rax + rcx*2]
    cmp rax, [rsp + SS_N]
    cmova rax, [rsp + SS_N]
    mov [rsp + SS_END], rax
    mov rax, [rsp + SS_I]
    mov [rsp + SS_A], rax
    mov [rsp + SS_K], rax
    mov rax, [rsp + SS_MID]
    mov [rsp + SS_B], rax
.Lss_merge:
    mov rax, [rsp + SS_A]
    cmp rax, [rsp + SS_MID]
    jae .Lss_remb
    mov rcx, [rsp + SS_B]
    cmp rcx, [rsp + SS_END]
    jae .Lss_rema
    mov r13, [rbx + VEC_ptr]
    imul rax, SEARCH_REC
    add r13, rax
    mov r14, [rbx + VEC_ptr]
    imul rcx, SEARCH_REC
    add r14, rcx
    mov rdi, r13
    mov rsi, r14
    call search_rec_cmp
    test eax, eax
    jg .Lss_takeb
    mov r15, [rsp + SS_K]
    imul r15, SEARCH_REC
    add r15, [rsp + SS_TMP]
    mov rax, [r13]
    mov [r15], rax
    mov rax, [r13 + 8]
    mov [r15 + 8], rax
    mov rax, [r13 + 16]
    mov [r15 + 16], rax
    inc qword ptr [rsp + SS_A]
    inc qword ptr [rsp + SS_K]
    jmp .Lss_merge
.Lss_takeb:
    mov r15, [rsp + SS_K]
    imul r15, SEARCH_REC
    add r15, [rsp + SS_TMP]
    mov rax, [r14]
    mov [r15], rax
    mov rax, [r14 + 8]
    mov [r15 + 8], rax
    mov rax, [r14 + 16]
    mov [r15 + 16], rax
    inc qword ptr [rsp + SS_B]
    inc qword ptr [rsp + SS_K]
    jmp .Lss_merge
.Lss_rema:
    mov rax, [rsp + SS_A]
    cmp rax, [rsp + SS_MID]
    jae .Lss_after
    mov r13, [rbx + VEC_ptr]
    imul rax, SEARCH_REC
    add r13, rax
    mov r15, [rsp + SS_K]
    imul r15, SEARCH_REC
    add r15, [rsp + SS_TMP]
    mov rax, [r13]
    mov [r15], rax
    mov rax, [r13 + 8]
    mov [r15 + 8], rax
    mov rax, [r13 + 16]
    mov [r15 + 16], rax
    inc qword ptr [rsp + SS_A]
    inc qword ptr [rsp + SS_K]
    jmp .Lss_rema
.Lss_remb:
    mov rax, [rsp + SS_B]
    mov rcx, [rsp + SS_END]
    cmp rax, rcx
    jae .Lss_after
    mov r14, [rbx + VEC_ptr]
    imul rax, SEARCH_REC
    add r14, rax
    mov r15, [rsp + SS_K]
    imul r15, SEARCH_REC
    add r15, [rsp + SS_TMP]
    mov rax, [r14]
    mov [r15], rax
    mov rax, [r14 + 8]
    mov [r15 + 8], rax
    mov rax, [r14 + 16]
    mov [r15 + 16], rax
    inc qword ptr [rsp + SS_B]
    inc qword ptr [rsp + SS_K]
    jmp .Lss_remb
.Lss_after:
    mov rax, [rsp + SS_END]
    mov [rsp + SS_I], rax
    jmp .Lss_i
.Lss_nextw:
    mov rdi, [rbx + VEC_ptr]
    mov rsi, [rsp + SS_TMP]
    mov rdx, [rsp + SS_N]
    imul rdx, SEARCH_REC
    call memcpy
    shl qword ptr [rsp + SS_W], 1
    jmp .Lss_w
.Lss_done:
    mov rdi, [rsp + SS_TMP]
    call mem_free
.Lss_ret:
    xor eax, eax
    EPILOGUE

# search_child_is_dir(dirpath, name, namelen, sb) -> 1 | 0
# Used only for dirents whose d_type is unknown (0); opens the child and
# looks at st_mode.  sb is a caller-owned scratch SB.
FN search_child_is_dir
    PROLOGUE 176
    mov [rsp], rdi
    mov [rsp + 8], rsi
    mov [rsp + 16], rdx
    mov rbx, rcx
    mov rdi, rbx
    call sb_clear
    mov rdi, rbx
    mov rsi, [rsp]
    call sb_push_cstr
    mov rax, [rbx + SB_len]
    test rax, rax
    jz 1f
    mov rcx, [rbx + SB_ptr]
    cmp byte ptr [rcx + rax - 1], '/'
    je 2f
1:  mov rdi, rbx
    mov esi, '/'
    call sb_push_byte
2:  mov rdi, rbx
    mov rsi, [rsp + 8]
    mov rdx, [rsp + 16]
    call sb_push
    mov rdi, [rbx + SB_ptr]
    mov esi, O_CLOEXEC | O_NONBLOCK
    xor edx, edx
    call os_open
    test rax, rax
    js .Lscid_no
    mov r12, rax
    mov rdi, r12
    lea rsi, [rsp + 32]
    call os_fstat
    mov r13, rax
    mov rdi, r12
    call os_close
    test r13, r13
    js .Lscid_no
    mov eax, [rsp + 32 + 24]
    and eax, 0xF000
    cmp eax, 0x4000
    sete al
    movzx eax, al
    EPILOGUE
.Lscid_no:
    xor eax, eax
    EPILOGUE

# search_dir_read(path, VEC*, cap) -> 0 | -errno
# Appends {name, len, is_dir} records for one directory; skips "." and "..",
# and stops once cap records have been collected so a huge directory is never
# materialised in full.  The caller sorts the collected records afterwards.
.equ DR_PATH, 0
.equ DR_VEC, 8
.equ DR_FD, 16
.equ DR_BUF, 24
.equ DR_NEXT, 32
.equ DR_NAMELEN, 40
.equ DR_ISDIR, 48
.equ DR_ERR, 56
.equ DR_SB, 64
.equ DR_NAME, 72
.equ DR_RECLEN, 80
.equ DR_CAP, 88
FN search_dir_read
    PROLOGUE 96
    mov [rsp + DR_PATH], rdi
    mov [rsp + DR_VEC], rsi
    mov [rsp + DR_CAP], rdx
    mov esi, O_CLOEXEC | O_NONBLOCK
    xor edx, edx
    call os_open
    test rax, rax
    js .Ldr_ret
    mov [rsp + DR_FD], rax
    mov edi, SEARCH_CHUNK
    call mem_alloc
    mov [rsp + DR_BUF], rax
    mov edi, SB_SIZE
    call mem_alloc
    mov [rsp + DR_SB], rax
.Ldr_read:
    mov edi, [rsp + DR_FD]
    mov rsi, [rsp + DR_BUF]
    mov edx, SEARCH_CHUNK
    call os_getdents
    test rax, rax
    js .Ldr_readerr
    jz .Ldr_eof
    mov r13, rax
    xor r14d, r14d
.Ldr_rec:
    cmp r14, r13
    jae .Ldr_read
    mov rbx, [rsp + DR_BUF]
    add rbx, r14
    movzx eax, word ptr [rbx + 16]
    test eax, eax
    jz .Ldr_eof
    mov [rsp + DR_RECLEN], rax
    add rax, r14
    mov [rsp + DR_NEXT], rax
    cmp qword ptr [rsp + DR_RECLEN], 19
    jb .Ldr_skip                     # short record: advance, never underflow
    lea r15, [rbx + 19]
    mov rcx, [rsp + DR_RECLEN]
    sub rcx, 19
    xor eax, eax
.Ldr_namelen:
    cmp rax, rcx
    jae .Ldr_namedone
    cmp byte ptr [r15 + rax], 0
    je .Ldr_namedone
    inc rax
    jmp .Ldr_namelen
.Ldr_namedone:
    mov [rsp + DR_NAMELEN], rax
    mov [rsp + DR_NAME], r15
    cmp rax, 1
    jne 1f
    cmp byte ptr [r15], '.'
    je .Ldr_skip
1:  cmp rax, 2
    jne 2f
    cmp byte ptr [r15], '.'
    jne 2f
    cmp byte ptr [r15 + 1], '.'
    je .Ldr_skip
2:  movzx eax, byte ptr [rbx + 18]
    mov qword ptr [rsp + DR_ISDIR], 0
    cmp eax, 4
    jne 3f
    mov qword ptr [rsp + DR_ISDIR], 1
    jmp .Ldr_add
3:  cmp eax, 0
    jne .Ldr_add
    mov rdi, [rsp + DR_PATH]
    mov rsi, [rsp + DR_NAME]
    mov rdx, [rsp + DR_NAMELEN]
    mov rcx, [rsp + DR_SB]
    call search_child_is_dir
    mov [rsp + DR_ISDIR], rax
.Ldr_add:
    mov rax, [rsp + DR_VEC]
    mov rax, [rax + VEC_len]
    cmp rax, [rsp + DR_CAP]
    jae .Ldr_capped                  # cap reached: stop materializing, report it
    mov rdi, [rsp + DR_NAME]
    mov rsi, [rsp + DR_NAMELEN]
    call mem_dup
    mov r15, rax
    mov rdi, [rsp + DR_VEC]
    mov esi, SEARCH_REC
    call vec_push
    mov [rax], r15
    mov rcx, [rsp + DR_NAMELEN]
    mov [rax + 8], rcx
    mov rcx, [rsp + DR_ISDIR]
    mov [rax + 16], rcx
.Ldr_skip:
    mov r14, [rsp + DR_NEXT]
    jmp .Ldr_rec
.Ldr_eof:
    xor r15d, r15d
    jmp .Ldr_cleanup
.Ldr_capped:
    mov r15, 1                       # signal "per-directory cap hit" to the walker
    jmp .Ldr_cleanup
.Ldr_readerr:
    cmp rax, -EINTR
    je .Ldr_read
    mov r15, rax
.Ldr_cleanup:
    mov [rsp + DR_ERR], r15
    mov edi, [rsp + DR_FD]
    call os_close
    mov rdi, [rsp + DR_BUF]
    call mem_free
    mov rdi, [rsp + DR_SB]
    call mem_free
    mov rax, [rsp + DR_ERR]
    EPILOGUE
.Ldr_ret:
    EPILOGUE

# search_norm_root(path) -> cstr copy with trailing slashes stripped
FN search_norm_root
    PROLOGUE 16
    mov [rsp], rdi
    call strlen
    mov [rsp + 8], rax
    lea rdi, [rax + 1]
    call mem_alloc
    mov r12, rax
    mov rdi, r12
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    call memcpy
    mov rax, [rsp + 8]
.Lsnr_loop:
    cmp rax, 1
    jbe .Lsnr_done
    cmp byte ptr [r12 + rax - 1], '/'
    jne .Lsnr_done
    dec rax
    mov byte ptr [r12 + rax], 0
    jmp .Lsnr_loop
.Lsnr_done:
    mov rax, r12
    EPILOGUE

# search_has_slash(cstr) -> 1 | 0
FN search_has_slash
1:  mov al, [rdi]
    test al, al
    jz 2f
    cmp al, '/'
    je 3f
    inc rdi
    jmp 1b
2:  xor eax, eax
    ret
3:  mov eax, 1
    ret

# search_json_bool(obj, key) -> 1 | 0 (JT_TRUE, or a nonzero number)
FN search_json_bool
    PROLOGUE 0
    call json_get
    test rax, rax
    jz .Lsjb_no
    mov ecx, [rax + JV_type]
    cmp ecx, JT_TRUE
    je .Lsjb_yes
    cmp ecx, JT_FALSE
    je .Lsjb_no
    cmp ecx, JT_NUM
    jne .Lsjb_no
    mov rdi, [rax + JV_ptr]
    mov esi, [rax + JV_n]
    call parse_u64
    test rdx, rdx
    jz .Lsjb_no
    test rax, rax
    setne al
    movzx eax, al
    EPILOGUE
.Lsjb_yes:
    mov eax, 1
    EPILOGUE
.Lsjb_no:
    xor eax, eax
    EPILOGUE

# search_err(job, msg, path | 0, err | 0): error result + tool_done.
FN search_err
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov rdi, [rbx + J_out]
    call sb_clear
    mov rdi, [rbx + J_out]
    mov rsi, r12
    call sb_push_cstr
    test r13, r13
    jz 1f
    mov rdi, [rbx + J_out]
    mov rsi, r13
    call sb_push_cstr
1:  test r14, r14
    jz 2f
    mov rdi, [rbx + J_out]
    lea rsi, [rip + .Lerr_errno]
    call sb_push_cstr
    mov r15, r14
    test r15, r15
    jns 3f
    mov rdi, [rbx + J_out]
    mov esi, '-'
    call sb_push_byte
    neg r15
3:  mov rdi, [rbx + J_out]
    mov rsi, r15
    call sb_push_u64
    mov rdi, [rbx + J_out]
    lea rsi, [rip + .Lrparen]
    call sb_push_cstr
2:  mov rdi, rbx
    call tool_done
    xor eax, eax
    EPILOGUE

# ------------------------------------------------------------------ ls_exec
.equ LE_JOB, 0
.equ LE_PATH, 8
.equ LE_LIMIT, 16
.equ LE_VEC, 24
.equ LE_N, 32
.equ LE_I, 40
.equ LE_ERR, 48
FN ls_exec
    PROLOGUE 64
    mov [rsp + LE_JOB], rdi
    mov rdi, [rdi + J_args]
    test rdi, rdi
    jz .Lls_bad
    call strlen
    mov rsi, rax
    mov rdi, [rsp + LE_JOB]
    mov rdi, [rdi + J_args]
    call json_parse
    test rax, rax
    jz .Lls_bad
    mov rbx, rax
    mov rdi, rbx
    lea rsi, [rip + .Ltool_path]
    call json_get_cstr
    test rax, rax
    jnz 1f
    lea rax, [rip + .Ldot]
1:  mov [rsp + LE_PATH], rax
    mov rdi, rbx
    lea rsi, [rip + .Ltool_limit]
    mov edx, LS_DEFAULT_LIMIT
    call json_get_u64
    mov [rsp + LE_LIMIT], rax
    call search_vec_new
    mov [rsp + LE_VEC], rax
    mov rdi, [rsp + LE_PATH]
    mov rsi, rax
    mov rdx, [rsp + LE_LIMIT]
    mov edx, LS_ENTRY_CAP            # read enough to sort correctly; caps memory
    call search_dir_read
    test rax, rax
    js .Lls_err
    mov rdi, [rsp + LE_VEC]
    call search_sort
    mov rbx, [rsp + LE_JOB]
    mov rdi, [rbx + J_out]
    call sb_clear
    mov rdi, [rbx + J_out]
    mov rsi, [rsp + LE_PATH]
    call sb_push_cstr
    mov rdi, [rbx + J_out]
    lea rsi, [rip + .Lcolon_nl]
    call sb_push_cstr
    mov rax, [rsp + LE_VEC]
    mov rax, [rax + VEC_len]
    mov rcx, [rsp + LE_LIMIT]
    cmp rax, rcx
    cmova rax, rcx
    mov [rsp + LE_N], rax
    mov qword ptr [rsp + LE_I], 0
.Lls_loop:
    mov rax, [rsp + LE_I]
    cmp rax, [rsp + LE_N]
    jae .Lls_done
    mov rcx, [rsp + LE_VEC]
    mov rcx, [rcx + VEC_ptr]
    imul rax, SEARCH_REC
    add rcx, rax
    mov rbx, rcx
    mov rdi, [rsp + LE_JOB]
    mov rdi, [rdi + J_out]
    mov rsi, [rbx + SR_PTR]
    mov rdx, [rbx + SR_LEN]
    call sb_push
    cmp qword ptr [rbx + SR_DIR], 0
    je 1f
    mov rdi, [rsp + LE_JOB]
    mov rdi, [rdi + J_out]
    mov esi, '/'
    call sb_push_byte
1:  mov rdi, [rsp + LE_JOB]
    mov rdi, [rdi + J_out]
    mov esi, 10
    call sb_push_byte
    inc qword ptr [rsp + LE_I]
    jmp .Lls_loop
.Lls_done:
    mov rdi, [rsp + LE_VEC]
    call search_vec_free
    mov rdi, [rsp + LE_JOB]
    call tool_done
    xor eax, eax
    EPILOGUE
.Lls_err:
    mov [rsp + LE_ERR], rax
    mov rdi, [rsp + LE_JOB]
    lea rsi, [rip + .Lerr_open]
    mov rdx, [rsp + LE_PATH]
    mov rcx, [rsp + LE_ERR]
    call search_err
    mov rdi, [rsp + LE_VEC]
    call search_vec_free
    xor eax, eax
    EPILOGUE
.Lls_bad:
    mov rdi, [rsp + LE_JOB]
    lea rsi, [rip + .Lbadargs]
    xor edx, edx
    xor ecx, ecx
    call search_err
    xor eax, eax
    EPILOGUE
