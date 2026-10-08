.include "opcode.inc"
.include "core/core.inc"
# edit tool: {path, edits:[{oldText,newText}]}. Every oldText is located in the
# ORIGINAL text, must be unique and non-overlapping; edits are applied right to
# left. A UTF-8 BOM and CRLF line endings are preserved, the file is replaced
# atomically (temp file in the same directory + os_rename) and the result text
# is "edited <path>: N replacement(s)" followed by a unified diff (400 lines).
# Contract: src/core/API.md.

.equ ED_MAX_DIFF, 400

# edit_write_atomic returns -ELOOP when the named object is a symlink.
.equ ELOOP, 40

# edit record (48 bytes)
.equ ER_OFF,  0
.equ ER_OLEN, 8
.equ ER_NPTR, 16
.equ ER_NLEN, 24
.equ ER_OSB,  32
.equ ER_NSB,  40
.equ ER_SIZE, 48

.section .rodata
.Lname:   .asciz "edit"
.Llabel:  .asciz "edit"
.Ldesc:   .asciz "Edit a file with exact string replacements. Each oldText must match exactly once; BOM/CRLF are preserved."
.Lparams: .asciz "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"File path to edit\"},\"edits\":{\"type\":\"array\",\"description\":\"List of replacements\",\"items\":{\"type\":\"object\",\"properties\":{\"oldText\":{\"type\":\"string\",\"description\":\"Exact text to replace\"},\"newText\":{\"type\":\"string\",\"description\":\"Replacement text\"}},\"required\":[\"oldText\",\"newText\"]}}},\"required\":[\"path\",\"edits\"]}"
.Lpath:      .asciz "path"
.Ledits:     .asciz "edits"
.Loldtext:   .asciz "oldText"
.Lnewtext:   .asciz "newText"
.Lerr_args:  .asciz "error: invalid arguments"
.Lerr_open:  .asciz "error: cannot open "
.Lerr_read:  .asciz "error: cannot read "
.Lerr_nf:    .asciz "error: oldText not found in "
.Lerr_uniq:  .asciz "error: oldText not unique in "
.Lerr_ov:    .asciz "error: overlapping edits in "
.Lerr_write: .asciz "error: cannot write "
.Lerr_symlink: .asciz "error: refusing to replace symlink "
.Ledited:    .asciz "edited "
.Lcolon:     .asciz ": "
.Lrepl:      .asciz " replacement(s)\n"
.Lcrlf:      .ascii "\r\n"

.section .data
.p2align 3
edit_tl:
    .quad .Lname
    .quad .Llabel
    .quad .Ldesc
    .quad .Lparams
    .long TL_DESTRUCTIVE
    .long 0
    .quad edit_exec
    .quad 0

.section .bss
.p2align 3

.text

# edit_tool_init() -> 0 | -ENOSPC
FN edit_tool_init
    lea rdi, [rip + edit_tl]
    jmp tools_add

# ------------------------------------------------------------------ helpers
# ed_fail(job, msg, path) -> 0: error result + tool_done
ed_fail:
    PROLOGUE 16
    mov rbx, rdi
    mov [rsp], rsi
    mov r12, rdx
    mov rdi, [rbx + J_out]
    call sb_clear
    mov rdi, [rbx + J_out]
    mov rsi, [rsp]
    call sb_push_cstr
    test r12, r12
    jz 1f
    mov rdi, [rbx + J_out]
    mov rsi, r12
    call sb_push_cstr
1:  mov rdi, rbx
    call tool_done
    xor eax, eax
    EPILOGUE

# ed_slurp(path) -> SB* | 0
ed_slurp:
    PROLOGUE 48
    mov [rsp], rdi
    xor esi, esi
    xor edx, edx
    call os_open
    test rax, rax
    js .Les_fail
    mov [rsp + 8], rax
    mov edi, SB_SIZE
    call mem_alloc
    mov r12, rax
    mov edi, 65536
    call mem_alloc
    mov r13, rax
.Les_loop:
    mov edi, [rsp + 8]
    mov rsi, r13
    mov edx, 65536
    call os_read
    test rax, rax
    js .Les_readerr
    jz .Les_done
    mov rdi, r12
    mov rsi, r13
    mov rdx, rax
    call sb_push
    jmp .Les_loop
.Les_done:
    mov edi, [rsp + 8]
    call os_close
    mov rdi, r13
    call mem_free
    mov rax, r12
    EPILOGUE
.Les_readerr:
    cmp rax, -EINTR
    je .Les_loop
    mov edi, [rsp + 8]
    call os_close
    mov rdi, r13
    call mem_free
    mov rdi, r12
    call sb_free
    mov rdi, r12
    call mem_free
.Les_fail:
    xor eax, eax
    EPILOGUE

# ed_norm(src, len) -> SB* : copy with \r\n folded to \n
ed_norm:
    PROLOGUE 32
    mov [rsp], rdi
    mov [rsp + 8], rsi
    mov edi, SB_SIZE
    call mem_alloc
    mov r12, rax
    mov qword ptr [rsp + 16], 0
.Len_loop:
    mov rax, [rsp + 16]
    cmp rax, [rsp + 8]
    jae .Len_done
    mov rcx, [rsp]
    movzx edx, byte ptr [rcx + rax]
    cmp edx, 13
    jne .Len_plain
    lea rcx, [rax + 1]
    cmp rcx, [rsp + 8]
    jae .Len_plain
    mov rcx, [rsp]
    cmp byte ptr [rcx + rax + 1], 10
    jne .Len_plain
    add qword ptr [rsp + 16], 2
    mov rdi, r12
    mov esi, 10
    call sb_push_byte
    jmp .Len_loop
.Len_plain:
    inc qword ptr [rsp + 16]
    mov rdi, r12
    mov esi, edx
    call sb_push_byte
    jmp .Len_loop
.Len_done:
    mov rax, r12
    EPILOGUE

# ------------------------------------------------------------------ exec
# local frame
.equ ED_JOB,     0
.equ ED_PATH,    8
.equ ED_EDITS,   16
.equ ED_EN,      24
.equ ED_RECS,    32
.equ ED_RAW,     40
.equ ED_TEXT,    48
.equ ED_TEXTLEN, 56
.equ ED_BOM,     64
.equ ED_CRLF,    72
.equ ED_NORM,    80
.equ ED_RES,     88
.equ ED_FINAL,   96
.equ ED_NLEN,    104
.equ ED_K,       112
.equ ED_POS,     120
.equ ED_KEY,     128

FN edit_exec
    PROLOGUE 256
    mov [rsp + ED_JOB], rdi
    mov qword ptr [rsp + ED_PATH], 0
    mov qword ptr [rsp + ED_EDITS], 0
    mov qword ptr [rsp + ED_EN], 0
    mov qword ptr [rsp + ED_RECS], 0
    mov qword ptr [rsp + ED_RAW], 0
    mov qword ptr [rsp + ED_TEXT], 0
    mov qword ptr [rsp + ED_TEXTLEN], 0
    mov qword ptr [rsp + ED_BOM], 0
    mov qword ptr [rsp + ED_CRLF], 0
    mov qword ptr [rsp + ED_NORM], 0
    mov qword ptr [rsp + ED_RES], 0
    mov qword ptr [rsp + ED_FINAL], 0
    # ---- parse args ----
    mov rdi, [rdi + J_args]
    test rdi, rdi
    jz .Lee_badargs
    call strlen
    mov rsi, rax
    mov rdi, [rsp + ED_JOB]
    mov rdi, [rdi + J_args]
    call json_parse
    test rax, rax
    jz .Lee_badargs
    mov r12, rax
    mov rdi, r12
    lea rsi, [rip + .Lpath]
    call json_get_cstr
    test rax, rax
    jz .Lee_badargs
    mov [rsp + ED_PATH], rax
    mov rdi, r12
    lea rsi, [rip + .Ledits]
    call json_get
    test rax, rax
    jz .Lee_badargs
    cmp dword ptr [rax + JV_type], JT_ARR
    jne .Lee_badargs
    mov [rsp + ED_EDITS], rax
    mov rdi, rax
    call json_len
    test rax, rax
    jz .Lee_badargs
    mov [rsp + ED_EN], rax
    # ---- read the file ----
    mov rdi, [rsp + ED_PATH]
    call ed_slurp
    test rax, rax
    jz .Lee_openerr
    mov [rsp + ED_RAW], rax
    mov rdi, [rax + SB_ptr]
    mov rsi, [rax + SB_len]
    mov [rsp + ED_TEXT], rdi
    mov [rsp + ED_TEXTLEN], rsi
    # BOM
    cmp rsi, 3
    jb .Lee_nobom
    cmp byte ptr [rdi], 0xef
    jne .Lee_nobom
    cmp byte ptr [rdi + 1], 0xbb
    jne .Lee_nobom
    cmp byte ptr [rdi + 2], 0xbf
    jne .Lee_nobom
    mov qword ptr [rsp + ED_BOM], 1
    add qword ptr [rsp + ED_TEXT], 3
    sub qword ptr [rsp + ED_TEXTLEN], 3
.Lee_nobom:
    # CRLF?
    mov rdi, [rsp + ED_TEXT]
    mov rsi, [rsp + ED_TEXTLEN]
    lea rdx, [rip + .Lcrlf]
    mov ecx, 2
    call str_find
    cmp rax, -1
    je .Lee_nocrlf
    mov qword ptr [rsp + ED_CRLF], 1
    mov rdi, [rsp + ED_TEXT]
    mov rsi, [rsp + ED_TEXTLEN]
    call ed_norm
    mov [rsp + ED_NORM], rax
    mov rcx, [rax + SB_ptr]
    mov [rsp + ED_TEXT], rcx
    mov rcx, [rax + SB_len]
    mov [rsp + ED_TEXTLEN], rcx
.Lee_nocrlf:
    # ---- locate every edit in the original text ----
    mov rdi, [rsp + ED_EN]
    imul rdi, ER_SIZE
    add rdi, ER_SIZE
    call mem_alloc
    mov [rsp + ED_RECS], rax
    mov qword ptr [rsp + ED_K], 0
.Lee_loop:
    mov rax, [rsp + ED_K]
    cmp rax, [rsp + ED_EN]
    jae .Lee_located
    mov rdi, [rsp + ED_EDITS]
    mov rsi, rax
    call json_at
    test rax, rax
    jz .Lee_bad
    cmp dword ptr [rax + JV_type], JT_OBJ
    jne .Lee_bad
    mov r12, rax
    mov rdi, r12
    lea rsi, [rip + .Loldtext]
    call json_get
    test rax, rax
    jz .Lee_bad
    cmp dword ptr [rax + JV_type], JT_STR
    jne .Lee_bad
    mov rdi, rax
    call json_str
    mov r13, rax
    mov r15, rdx
    test r15, r15
    jz .Lee_bad
    mov rdi, r12
    lea rsi, [rip + .Lnewtext]
    call json_get
    test rax, rax
    jz .Lee_bad
    cmp dword ptr [rax + JV_type], JT_STR
    jne .Lee_bad
    mov rdi, rax
    call json_str
    mov r14, rax
    mov [rsp + ED_NLEN], rdx
    mov rax, [rsp + ED_K]
    imul rax, ER_SIZE
    add rax, [rsp + ED_RECS]
    mov rbx, rax
    # normalize the strings for CRLF files
    cmp qword ptr [rsp + ED_CRLF], 0
    je .Lee_nonorm
    mov rdi, r13
    mov rsi, r15
    call ed_norm
    mov [rbx + ER_OSB], rax
    mov r13, [rax + SB_ptr]
    mov r15, [rax + SB_len]
    mov rdi, r14
    mov rsi, [rsp + ED_NLEN]
    call ed_norm
    mov [rbx + ER_NSB], rax
    mov r14, [rax + SB_ptr]
    mov rcx, [rax + SB_len]
    mov [rsp + ED_NLEN], rcx
.Lee_nonorm:
    # first occurrence
    mov rdi, [rsp + ED_TEXT]
    mov rsi, [rsp + ED_TEXTLEN]
    mov rdx, r13
    mov rcx, r15
    call str_find
    cmp rax, -1
    je .Lee_notfound
    mov [rbx + ER_OFF], rax
    mov [rbx + ER_OLEN], r15
    mov [rbx + ER_NPTR], r14
    mov rcx, [rsp + ED_NLEN]
    mov [rbx + ER_NLEN], rcx
    # uniqueness: no second occurrence
    mov rax, [rbx + ER_OFF]
    mov rdi, [rsp + ED_TEXT]
    add rdi, rax
    inc rdi
    mov rsi, [rsp + ED_TEXTLEN]
    sub rsi, rax
    dec rsi
    mov rdx, r13
    mov rcx, r15
    call str_find
    cmp rax, -1
    jne .Lee_notunique
    # overlap with already accepted edits
    xor r8d, r8d
.Lee_ov:
    cmp r8, [rsp + ED_K]
    jae .Lee_ov_done
    mov r9, r8
    imul r9, ER_SIZE
    add r9, [rsp + ED_RECS]
    mov rax, [r9 + ER_OFF]
    mov rcx, [r9 + ER_OLEN]
    add rcx, rax
    mov rax, [rbx + ER_OFF]
    cmp rax, rcx
    jae .Lee_ov_next
    mov rcx, [r9 + ER_OFF]
    mov rax, [rbx + ER_OFF]
    add rax, [rbx + ER_OLEN]
    cmp rcx, rax
    jae .Lee_ov_next
    jmp .Lee_overlap
.Lee_ov_next:
    inc r8
    jmp .Lee_ov
.Lee_ov_done:
    inc qword ptr [rsp + ED_K]
    jmp .Lee_loop

.Lee_notfound:
    mov rdi, [rsp + ED_JOB]
    lea rsi, [rip + .Lerr_nf]
    mov rdx, [rsp + ED_PATH]
    call ed_fail
    jmp .Lee_cleanup
.Lee_notunique:
    mov rdi, [rsp + ED_JOB]
    lea rsi, [rip + .Lerr_uniq]
    mov rdx, [rsp + ED_PATH]
    call ed_fail
    jmp .Lee_cleanup
.Lee_overlap:
    mov rdi, [rsp + ED_JOB]
    lea rsi, [rip + .Lerr_ov]
    mov rdx, [rsp + ED_PATH]
    call ed_fail
    jmp .Lee_cleanup
.Lee_bad:
    mov rdi, [rsp + ED_JOB]
    lea rsi, [rip + .Lerr_args]
    xor edx, edx
    call ed_fail
    jmp .Lee_cleanup
.Lee_openerr:
    mov rdi, [rsp + ED_JOB]
    lea rsi, [rip + .Lerr_open]
    mov rdx, [rsp + ED_PATH]
    call ed_fail
    jmp .Lee_cleanup

.Lee_located:
    # ---- insertion sort by offset (ascending) ----
    mov r12, 1
.Lsort_outer:
    cmp r12, [rsp + ED_EN]
    jae .Lsort_done
    mov rsi, r12
    imul rsi, ER_SIZE
    add rsi, [rsp + ED_RECS]
    lea rdi, [rsp + ED_KEY]
    mov edx, ER_SIZE
    call memcpy
    mov r13, r12
.Lsort_inner:
    test r13, r13
    jz .Lsort_place
    mov rsi, r13
    dec rsi
    imul rsi, ER_SIZE
    add rsi, [rsp + ED_RECS]
    mov rax, [rsi + ER_OFF]
    cmp rax, [rsp + ED_KEY]
    jbe .Lsort_place
    mov rdi, r13
    imul rdi, ER_SIZE
    add rdi, [rsp + ED_RECS]
    mov edx, ER_SIZE
    call memcpy
    dec r13
    jmp .Lsort_inner
.Lsort_place:
    mov rdi, r13
    imul rdi, ER_SIZE
    add rdi, [rsp + ED_RECS]
    lea rsi, [rsp + ED_KEY]
    mov edx, ER_SIZE
    call memcpy
    inc r12
    jmp .Lsort_outer
.Lsort_done:
    # ---- apply into the result buffer, left to right ----
    mov edi, SB_SIZE
    call mem_alloc
    mov [rsp + ED_RES], rax
    mov qword ptr [rsp + ED_POS], 0
    mov qword ptr [rsp + ED_K], 0
.Lbuild_loop:
    mov rax, [rsp + ED_K]
    cmp rax, [rsp + ED_EN]
    jae .Lbuild_tail
    mov r12, rax
    imul r12, ER_SIZE
    add r12, [rsp + ED_RECS]
    mov rdi, [rsp + ED_RES]
    mov rsi, [rsp + ED_TEXT]
    add rsi, [rsp + ED_POS]
    mov rdx, [r12 + ER_OFF]
    sub rdx, [rsp + ED_POS]
    call sb_push
    mov rdi, [rsp + ED_RES]
    mov rsi, [r12 + ER_NPTR]
    mov rdx, [r12 + ER_NLEN]
    call sb_push
    mov rax, [r12 + ER_OFF]
    add rax, [r12 + ER_OLEN]
    mov [rsp + ED_POS], rax
    inc qword ptr [rsp + ED_K]
    jmp .Lbuild_loop
.Lbuild_tail:
    mov rdi, [rsp + ED_RES]
    mov rsi, [rsp + ED_TEXT]
    add rsi, [rsp + ED_POS]
    mov rdx, [rsp + ED_TEXTLEN]
    sub rdx, [rsp + ED_POS]
    call sb_push
    # ---- final bytes: BOM + EOL translation ----
    mov edi, SB_SIZE
    call mem_alloc
    mov [rsp + ED_FINAL], rax
    mov r12, rax
    cmp qword ptr [rsp + ED_BOM], 0
    je .Lfin_nobom
    mov rdi, r12
    mov esi, 0xef
    call sb_push_byte
    mov rdi, r12
    mov esi, 0xbb
    call sb_push_byte
    mov rdi, r12
    mov esi, 0xbf
    call sb_push_byte
.Lfin_nobom:
    cmp qword ptr [rsp + ED_CRLF], 0
    jne .Lfin_crlf
    mov rdi, r12
    mov rsi, [rsp + ED_RES]
    mov rsi, [rsi + SB_ptr]
    mov rdx, [rsp + ED_RES]
    mov rdx, [rdx + SB_len]
    call sb_push
    jmp .Lfin_done
.Lfin_crlf:
    mov r13, [rsp + ED_RES]
    mov r14, [r13 + SB_ptr]
    mov r15, [r13 + SB_len]
    mov qword ptr [rsp + ED_POS], 0
.Lfin_loop:
    mov rax, [rsp + ED_POS]
    cmp rax, r15
    jae .Lfin_done
    movzx esi, byte ptr [r14 + rax]
    cmp esi, 10
    jne .Lfin_byte
    mov rdi, r12
    mov esi, 13
    call sb_push_byte
    mov esi, 10
.Lfin_byte:
    mov rdi, r12
    call sb_push_byte
    inc qword ptr [rsp + ED_POS]
    jmp .Lfin_loop
.Lfin_done:
    # ---- atomic replace ----
    mov rdi, [rsp + ED_PATH]
    mov rcx, [rsp + ED_FINAL]
    mov rsi, [rcx + SB_ptr]
    mov rdx, [rcx + SB_len]
    call tool_write_atomic
    test rax, rax
    js .Lee_writeerr
    # ---- result text ----
    mov rbx, [rsp + ED_JOB]
    mov rdi, [rbx + J_out]
    call sb_clear
    mov rdi, [rbx + J_out]
    lea rsi, [rip + .Ledited]
    call sb_push_cstr
    mov rdi, [rbx + J_out]
    mov rsi, [rsp + ED_PATH]
    call sb_push_cstr
    mov rdi, [rbx + J_out]
    lea rsi, [rip + .Lcolon]
    call sb_push_cstr
    mov rdi, [rbx + J_out]
    mov rsi, [rsp + ED_EN]
    call sb_push_u64
    mov rdi, [rbx + J_out]
    lea rsi, [rip + .Lrepl]
    call sb_push_cstr
    mov rax, [rsp + ED_RAW]
    mov rsi, [rax + SB_ptr]
    mov rdx, [rax + SB_len]
    mov rcx, [rsp + ED_FINAL]
    mov rcx, [rcx + SB_ptr]
    mov r8, [rsp + ED_FINAL]
    mov r8, [r8 + SB_len]
    mov rdi, [rsp + ED_PATH]
    mov r9, [rbx + J_out]
    sub rsp, 16
    mov qword ptr [rsp], ED_MAX_DIFF
    call diff_unified
    add rsp, 16
    mov rdi, rbx
    call tool_done
    jmp .Lee_cleanup
.Lee_writeerr:
    cmp rax, -ELOOP
    je .Lee_symlink
    mov rdi, [rsp + ED_JOB]
    lea rsi, [rip + .Lerr_write]
    mov rdx, [rsp + ED_PATH]
    call ed_fail
    jmp .Lee_cleanup
.Lee_symlink:
    mov rdi, [rsp + ED_JOB]
    lea rsi, [rip + .Lerr_symlink]
    mov rdx, [rsp + ED_PATH]
    call ed_fail
    jmp .Lee_cleanup
.Lee_badargs:
    mov rdi, [rsp + ED_JOB]
    lea rsi, [rip + .Lerr_args]
    xor edx, edx
    call ed_fail

# ---- cleanup: free every allocation ----
.Lee_cleanup:
    mov rax, [rsp + ED_RECS]
    test rax, rax
    jz .Lfree_more
    xor r12, r12
.Lfree_loop:
    cmp r12, [rsp + ED_EN]
    jae .Lfree_more
    mov r13, r12
    imul r13, ER_SIZE
    add r13, [rsp + ED_RECS]
    mov rdi, [r13 + ER_OSB]
    test rdi, rdi
    jz 1f
    call sb_free
    mov rdi, [r13 + ER_OSB]
    call mem_free
1:  mov rdi, [r13 + ER_NSB]
    test rdi, rdi
    jz 2f
    call sb_free
    mov rdi, [r13 + ER_NSB]
    call mem_free
2:  inc r12
    jmp .Lfree_loop
.Lfree_more:
    mov rdi, [rsp + ED_RECS]
    call mem_free
    mov rdi, [rsp + ED_NORM]
    test rdi, rdi
    jz 3f
    call sb_free
    mov rdi, [rsp + ED_NORM]
    call mem_free
3:  mov rdi, [rsp + ED_RAW]
    test rdi, rdi
    jz 4f
    call sb_free
    mov rdi, [rsp + ED_RAW]
    call mem_free
4:  mov rdi, [rsp + ED_RES]
    test rdi, rdi
    jz 5f
    call sb_free
    mov rdi, [rsp + ED_RES]
    call mem_free
5:  mov rdi, [rsp + ED_FINAL]
    test rdi, rdi
    jz 6f
    call sb_free
    mov rdi, [rsp + ED_FINAL]
    call mem_free
6:  xor eax, eax
    EPILOGUE
