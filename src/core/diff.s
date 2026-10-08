.include "opcode.inc"
# core diff: line-based unified diff with 3 lines of context, LCS edit script,
# @@ -a,b +c,d @@ hunks and "\ No newline at end of file" markers.
# Contract: src/core/API.md.
#
# diff_unified(label, old_ptr, old_len, new_ptr, new_len, out SB*, max_lines)
# max_lines is the 7th argument: [rbp+16] after PROLOGUE. Output line budget
# counts the two header lines and every hunk/body line; on overflow the engine
# stops and appends "[diff truncated]".
#
# Line records are {ptr, len (raw bytes, newline included when present),
# fnv1a-64 hash} at 24 bytes. d_line prints exactly len bytes and only adds a
# synthetic newline when the raw line had none (followed by the marker).
# The LCS suffix table needs only one direction bit per (i,j) cell: equal lines
# always take the diagonal, unequal cells store "chose the new side" (otherwise
# the old side). The DP values are two rolling u16 rows.

.equ DIFF_MAX_LINES, 20000

.equ OP_KIND,  0
.equ OP_OLD,   4
.equ OP_NEW,   8
.equ OP_FLAGS, 12
.equ OP_PTR,   16
.equ OP_LEN,   24
.equ OP_SIZE,  32

.equ LR_PTR,  0
.equ LR_LEN,  8
.equ LR_HASH, 16
.equ LR_SIZE, 24

.section .rodata
.Ld_oldhdr: .asciz "--- "
.Ld_newhdr: .asciz "+++ "
.Ld_hunk:   .asciz "@@ -"
.Ld_comma:  .asciz ","
.Ld_plus:   .asciz " +"
.Ld_end:    .asciz " @@\n"
.Ld_nonl:   .asciz "\\ No newline at end of file\n"
.Ld_trunc:  .asciz "[diff truncated]\n"
.Ld_empty:  .asciz ""

.text

# ---------------------------------------------------------------- line split
# d_count_lines(ptr, len) -> rax=count, rdx=no trailing newline (0/1)
d_count_lines:
    xor eax, eax
    xor edx, edx
    test rsi, rsi
    jz .Ldcl_ret
    xor ecx, ecx
.Ldcl_loop:
    cmp rcx, rsi
    jae .Ldcl_end
    cmp byte ptr [rdi + rcx], 10
    jne .Ldcl_next
    inc rax
.Ldcl_next:
    inc rcx
    jmp .Ldcl_loop
.Ldcl_end:
    cmp byte ptr [rdi + rsi - 1], 10
    je .Ldcl_ret
    mov edx, 1
    inc rax
.Ldcl_ret:
    ret

# d_fill_lines(ptr, len, recs): fill {ptr, raw-len, fnv1a64}.
d_fill_lines:
    PROLOGUE 0
    mov rbx, rdi
    add rbx, rsi                # end
    mov r12, rdi                # p
    mov r13, rdx                # rec
.Lfl_next:
    cmp r12, rbx
    jae .Lfl_done
    mov r14, r12                # start
    mov rcx, r12                # scan
.Lfl_scan:
    cmp rcx, rbx
    jae .Lfl_eol
    cmp byte ptr [rcx], 10
    je .Lfl_eol
    inc rcx
    jmp .Lfl_scan
.Lfl_eol:
    mov r15, rcx
    sub r15, r14                # content length
    cmp rcx, rbx
    jae .Lfl_hashinit
    inc r15                     # include the terminating newline
.Lfl_hashinit:
    mov rsi, 0xcbf29ce484222325
    mov rdi, 0x100000001b3
    xor r8, r8
.Lfl_hash:
    cmp r8, r15
    jae .Lfl_store
    movzx eax, byte ptr [r14 + r8]
    xor rsi, rax
    imul rsi, rdi
    inc r8
    jmp .Lfl_hash
.Lfl_store:
    mov [r13 + LR_PTR], r14
    mov [r13 + LR_LEN], r15
    mov [r13 + LR_HASH], rsi
    add r13, LR_SIZE
    lea r12, [r14 + r15]
    jmp .Lfl_next
.Lfl_done:
    EPILOGUE

# ---------------------------------------------------------------- output state
# d_begin(state) -> 0 ok | 1 over budget (sets the truncation flag)
d_begin:
    mov rax, [rdi]
    cmp rax, [rdi + 8]
    jae .Ldb_over
    xor eax, eax
    ret
.Ldb_over:
    mov dword ptr [rdi + 24], 1
    mov eax, 1
    ret

# d_end(state): count one emitted line
d_end:
    inc qword ptr [rdi]
    xor eax, eax
    ret

# d_line(state, prefix, ptr, len, flags) -> 0 ok | 1 truncated
# flags bit0: line ends with a newline; bit1: emit no-newline marker.
d_line:
    PROLOGUE 32
    mov rbx, rdi
    mov [rsp], rdx
    mov [rsp + 8], rcx
    mov [rsp + 16], r8d
    mov r12d, esi
    mov rax, [rbx]
    cmp rax, [rbx + 8]
    jae .Ldl_trunc
    mov rdi, [rbx + 16]
    test r12d, r12d
    jz 1f
    mov esi, r12d
    call sb_push_byte
1:  mov rdi, [rbx + 16]
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    test rdx, rdx
    jz 2f
    call sb_push
2:  test dword ptr [rsp + 16], 1
    jnz 3f
    mov rdi, [rbx + 16]
    mov esi, 10
    call sb_push_byte
3:  test dword ptr [rsp + 16], 2
    jz 4f
    mov rdi, [rbx + 16]
    lea rsi, [rip + .Ld_nonl]
    call sb_push_cstr
4:  inc qword ptr [rbx]
    xor eax, eax
    EPILOGUE
.Ldl_trunc:
    mov dword ptr [rbx + 24], 1
    mov eax, 1
    EPILOGUE

# d_headers(state, label) -> 0 ok | 1 truncated
d_headers:
    PROLOGUE 16
    mov rbx, rdi
    mov [rsp], rsi
    call d_begin
    test eax, eax
    jnz .Ldh_fail
    mov rdi, [rbx + 16]
    lea rsi, [rip + .Ld_oldhdr]
    call sb_push_cstr
    mov rdi, [rbx + 16]
    mov rsi, [rsp]
    call sb_push_cstr
    mov rdi, [rbx + 16]
    mov esi, 10
    call sb_push_byte
    mov rdi, rbx
    call d_end
    mov rdi, rbx
    call d_begin
    test eax, eax
    jnz .Ldh_fail
    mov rdi, [rbx + 16]
    lea rsi, [rip + .Ld_newhdr]
    call sb_push_cstr
    mov rdi, [rbx + 16]
    mov rsi, [rsp]
    call sb_push_cstr
    mov rdi, [rbx + 16]
    mov esi, 10
    call sb_push_byte
    mov rdi, rbx
    call d_end
    xor eax, eax
    EPILOGUE
.Ldh_fail:
    mov eax, 1
    EPILOGUE

# d_cstr_u64(sb, cstr, value)
d_cstr_u64:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov [rsp], rdx
    mov rsi, r12
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rsp]
    call sb_push_u64
    EPILOGUE

# d_hunk_header(state, old0, oldc, new0, newc) -> 0 ok | 1 truncated
d_hunk_header:
    PROLOGUE 48
    mov rbx, rdi
    mov [rsp], rsi
    mov [rsp + 8], rdx
    mov [rsp + 16], rcx
    mov [rsp + 24], r8
    call d_begin
    test eax, eax
    jnz .Ldhh_fail
    mov rdi, [rbx + 16]
    lea rsi, [rip + .Ld_hunk]
    mov rdx, [rsp]
    call d_cstr_u64
    mov rdi, [rbx + 16]
    lea rsi, [rip + .Ld_comma]
    mov rdx, [rsp + 8]
    call d_cstr_u64
    mov rdi, [rbx + 16]
    lea rsi, [rip + .Ld_plus]
    mov rdx, [rsp + 16]
    call d_cstr_u64
    mov rdi, [rbx + 16]
    lea rsi, [rip + .Ld_comma]
    mov rdx, [rsp + 24]
    call d_cstr_u64
    mov rdi, [rbx + 16]
    lea rsi, [rip + .Ld_end]
    call sb_push_cstr
    mov rdi, rbx
    call d_end
    xor eax, eax
    EPILOGUE
.Ldhh_fail:
    mov eax, 1
    EPILOGUE

# d_emit_all(state, prefix, ptr, len, no_nl) -> 0 ok | 1 truncated
d_emit_all:
    PROLOGUE 48
    mov rbx, rdi
    mov [rsp], rsi
    mov [rsp + 8], rdx
    mov [rsp + 16], rcx
    mov [rsp + 24], r8
.Lde_loop:
    cmp qword ptr [rsp + 16], 0
    jbe .Lde_ok
    mov rsi, [rsp + 8]
    mov rcx, [rsp + 16]
    xor edx, edx
.Lde_scan:
    cmp rdx, rcx
    jae .Lde_eol
    cmp byte ptr [rsi + rdx], 10
    je .Lde_eol
    inc rdx
    jmp .Lde_scan
.Lde_eol:
    mov [rsp + 32], rdx
    xor r8d, r8d
    cmp rdx, rcx
    jae .Lde_nonl
    or r8d, 1
    inc rdx
    jmp .Lde_call
.Lde_nonl:
    cmp qword ptr [rsp + 24], 0
    je .Lde_call
    or r8d, 2
.Lde_call:
    mov rdi, rbx
    mov rcx, rdx
    mov rdx, rsi
    mov esi, [rsp]
    call d_line
    test eax, eax
    jnz .Lde_trunc
    mov rax, [rsp + 32]
    cmp rax, [rsp + 16]
    jae .Lde_last
    add [rsp + 8], rax
    inc qword ptr [rsp + 8]
    sub [rsp + 16], rax
    dec qword ptr [rsp + 16]
    jmp .Lde_loop
.Lde_last:
    mov qword ptr [rsp + 16], 0
    jmp .Lde_loop
.Lde_ok:
    xor eax, eax
    EPILOGUE
.Lde_trunc:
    mov eax, 1
    EPILOGUE

# ------------------------------------------------------------------ lcs fill
# d_lcs_fill(n, m, oldrecs, newrecs, table, nextrow, [rbp+16]=currow)
# Fills the suffix-LCS bit table: bit (i*m+j) = 1 when old[i] != new[j] and the
# optimal move consumes the new side (addition); 0 otherwise.
d_lcs_fill:
    PROLOGUE 16
    mov rbx, rdi
    mov r15, rsi
    mov r12, rdx
    mov r13, rcx
    mov r14, r8
    mov r8, r9
    mov r9, [rbp + 16]
    mov [rsp], rbx              # i = n
.Llf_nexti:
    cmp qword ptr [rsp], 0
    je .Llf_done
    dec qword ptr [rsp]
    mov r11, [rsp]
    imul r11, r15
    mov [rsp + 8], r11          # im = i*m
    mov word ptr [r9 + r15*2], 0
    mov r11, [rsp]
    lea r11, [r11 + r11*2]
    lea r11, [r12 + r11*8]      # oldrec
    mov r10, r15                # j = m
    test r10, r10
    jz .Llf_rowdone
.Llf_nextj:
    dec r10
    lea rdx, [r10 + r10*2]
    lea rdx, [r13 + rdx*8]      # newrec
    mov rax, [r11 + LR_HASH]
    cmp rax, [rdx + LR_HASH]
    jne .Llf_diff
    mov rcx, [r11 + LR_LEN]
    cmp rcx, [rdx + LR_LEN]
    jne .Llf_diff
    mov rsi, [r11 + LR_PTR]
    mov rdi, [rdx + LR_PTR]
    test rcx, rcx
    jz .Llf_same
    repe cmpsb
    jne .Llf_diff
.Llf_same:
    movzx eax, word ptr [r8 + r10*2 + 2]
    inc eax
    mov [r9 + r10*2], ax
    jmp .Llf_nextj_check
.Llf_diff:
    movzx eax, word ptr [r8 + r10*2]
    movzx ecx, word ptr [r9 + r10*2 + 2]
    cmp eax, ecx
    jae .Llf_take_a
    mov [r9 + r10*2], cx
    mov rax, [rsp + 8]
    add rax, r10
    mov rdx, rax
    shr rdx, 3
    and eax, 7
    mov cl, al
    mov eax, 1
    shl eax, cl
    or byte ptr [r14 + rdx], al
    jmp .Llf_nextj_check
.Llf_take_a:
    mov [r9 + r10*2], ax
.Llf_nextj_check:
    test r10, r10
    jnz .Llf_nextj
.Llf_rowdone:
    xchg r8, r9
    jmp .Llf_nexti
.Llf_done:
    EPILOGUE

# d_put_op(ops, k, kind, old_ln, new_ln, rec, flags) -> k+1
d_put_op:
    mov rax, rsi
    shl rax, 5
    add rax, rdi
    mov [rax + OP_KIND], edx
    mov [rax + OP_OLD], ecx
    mov [rax + OP_NEW], r8d
    mov [rax + OP_FLAGS], r10d
    mov rcx, [r9]
    mov [rax + OP_PTR], rcx
    mov rcx, [r9 + 8]
    mov [rax + OP_LEN], rcx
    lea rax, [rsi + 1]
    ret

# d_backtrack(n, m, oldrecs, newrecs, table, ops,
#             [rbp+16]=old_no_nl, [rbp+24]=new_no_nl) -> nops
d_backtrack:
    PROLOGUE 64
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov r15, r8
    mov [rsp], r9               # ops
    mov rax, [rbp + 16]
    mov [rsp + 32], rax         # old_no_nl
    mov rax, [rbp + 24]
    mov [rsp + 40], rax         # new_no_nl
    mov qword ptr [rsp + 8], 0  # i
    mov qword ptr [rsp + 16], 0 # j
    mov qword ptr [rsp + 24], 0 # k
.Lb_loop:
    mov r8, [rsp + 8]
    mov r9, [rsp + 16]
    cmp r8, rbx
    jb .Lb_has_i
    cmp r9, r12
    jae .Lb_done
    jmp .Lb_add_only
.Lb_has_i:
    cmp r9, r12
    jae .Lb_rem_only
    lea r10, [r8 + r8*2]
    lea r10, [r13 + r10*8]      # oldrec
    lea r11, [r9 + r9*2]
    lea r11, [r14 + r11*8]      # newrec
    mov rax, [r10 + LR_HASH]
    cmp rax, [r11 + LR_HASH]
    jne .Lb_bit
    mov rax, [r10 + LR_LEN]
    cmp rax, [r11 + LR_LEN]
    jne .Lb_bit
    mov rcx, rax
    mov rsi, [r10 + LR_PTR]
    mov rdi, [r11 + LR_PTR]
    test rcx, rcx
    jz .Lb_context
    repe cmpsb
    jne .Lb_bit
.Lb_context:
    mov r11, r10                # rec
    mov edx, 0                  # kind = context
    mov r8, [rsp + 8]
    mov r9, [rsp + 16]
    lea ecx, [r8 + 1]
    lea r8d, [r9 + 1]
    xor r10d, r10d
    mov rax, [rsp + 8]
    inc rax
    cmp rax, rbx
    jne 1f
    cmp qword ptr [rsp + 32], 0
    je 1f
    or r10d, 2
    jmp 2f
1:  or r10d, 1
2:  mov rax, [rsp + 16]
    inc rax
    cmp rax, r12
    jne 3f
    cmp qword ptr [rsp + 40], 0
    je 3f
    or r10d, 2
3:  mov r9, r11
    mov rdi, [rsp]
    mov rsi, [rsp + 24]
    call d_put_op
    mov [rsp + 24], rax
    inc qword ptr [rsp + 8]
    inc qword ptr [rsp + 16]
    jmp .Lb_loop
.Lb_bit:
    mov r8, [rsp + 8]
    mov r9, [rsp + 16]
    mov rax, r8
    imul rax, r12
    add rax, r9
    mov rcx, rax
    shr rcx, 3
    and eax, 7
    movzx edx, byte ptr [r15 + rcx]
    bt edx, eax
    jc .Lb_add_only
    jmp .Lb_rem_only
.Lb_rem_only:
    mov r8, [rsp + 8]
    mov r9, [rsp + 16]
    lea r10, [r8 + r8*2]
    lea r10, [r13 + r10*8]      # oldrec
    mov r11, r10
    mov edx, 1                  # kind = removal
    lea ecx, [r8 + 1]
    lea r8d, [r9 + 1]
    xor r10d, r10d
    mov rax, [rsp + 8]
    inc rax
    cmp rax, rbx
    jne 1f
    cmp qword ptr [rsp + 32], 0
    je 1f
    or r10d, 2
    jmp 2f
1:  or r10d, 1
2:  mov r9, r11
    mov rdi, [rsp]
    mov rsi, [rsp + 24]
    call d_put_op
    mov [rsp + 24], rax
    inc qword ptr [rsp + 8]
    jmp .Lb_loop
.Lb_add_only:
    mov r8, [rsp + 8]
    mov r9, [rsp + 16]
    lea r10, [r9 + r9*2]
    lea r10, [r14 + r10*8]      # newrec
    mov r11, r10
    mov edx, 2                  # kind = addition
    lea ecx, [r8 + 1]
    lea r8d, [r9 + 1]
    xor r10d, r10d
    mov rax, [rsp + 16]
    inc rax
    cmp rax, r12
    jne 1f
    cmp qword ptr [rsp + 40], 0
    je 1f
    or r10d, 2
    jmp 2f
1:  or r10d, 1
2:  mov r9, r11
    mov rdi, [rsp]
    mov rsi, [rsp + 24]
    call d_put_op
    mov [rsp + 24], rax
    inc qword ptr [rsp + 16]
    jmp .Lb_loop
.Lb_done:
    mov rax, [rsp + 24]
    EPILOGUE

# ------------------------------------------------------------------- main
FN diff_unified
    PROLOGUE 256
    mov [rsp], rdi              # label
    mov [rsp + 8], rsi          # old_ptr
    mov [rsp + 16], rdx         # old_len
    mov [rsp + 24], rcx         # new_ptr
    mov [rsp + 32], r8          # new_len
    mov [rsp + 40], r9          # out
    mov rax, [rbp + 16]
    mov [rsp + 48], rax         # max_lines
    mov qword ptr [rsp + 56], 0
    mov qword ptr [rsp + 64], 0
    mov qword ptr [rsp + 72], 0
    mov qword ptr [rsp + 80], 0
    mov qword ptr [rsp + 88], 0
    mov qword ptr [rsp + 96], 0
    mov qword ptr [rsp + 104], 0
    mov qword ptr [rsp + 112], 0
    mov qword ptr [rsp + 120], 0
    # output state at [rsp+144]: count, max, out, trunc
    mov qword ptr [rsp + 144], 0
    mov [rsp + 152], rax
    mov [rsp + 160], r9
    mov dword ptr [rsp + 168], 0
    test rdi, rdi
    jnz 1f
    lea rdi, [rip + .Ld_empty]
    mov [rsp], rdi
1:
    # identical bytes: headers only
    mov rsi, [rsp + 16]
    cmp rsi, [rsp + 32]
    jne .Ld_count
    mov rdi, [rsp + 8]
    mov rsi, [rsp + 24]
    mov rdx, [rsp + 16]
    test rdx, rdx
    jz .Ld_identical
    call memeq
    test eax, eax
    jnz .Ld_identical
.Ld_count:
    mov rdi, [rsp + 8]
    mov rsi, [rsp + 16]
    call d_count_lines
    mov [rsp + 56], rax
    mov [rsp + 128], rdx
    mov rdi, [rsp + 24]
    mov rsi, [rsp + 32]
    call d_count_lines
    mov [rsp + 64], rax
    mov [rsp + 136], rdx
    # headers first
    lea rdi, [rsp + 144]
    mov rsi, [rsp]
    call d_headers
    test eax, eax
    jnz .Ld_truncated
    # huge inputs: whole-file replace fallback
    cmp qword ptr [rsp + 56], DIFF_MAX_LINES
    ja .Ld_fallback
    cmp qword ptr [rsp + 64], DIFF_MAX_LINES
    ja .Ld_fallback
    # ---- normal path: line records ----
    mov rdi, [rsp + 56]
    imul rdi, LR_SIZE
    add rdi, LR_SIZE
    call mem_alloc
    mov [rsp + 72], rax
    mov rdi, [rsp + 8]
    mov rsi, [rsp + 16]
    mov rdx, rax
    call d_fill_lines
    mov rdi, [rsp + 64]
    imul rdi, LR_SIZE
    add rdi, LR_SIZE
    call mem_alloc
    mov [rsp + 80], rax
    mov rdi, [rsp + 24]
    mov rsi, [rsp + 32]
    mov rdx, rax
    call d_fill_lines
    # two rolling u16 LCS rows
    mov rdi, [rsp + 64]
    inc rdi
    shl rdi, 1
    call mem_alloc
    mov [rsp + 96], rax
    mov rdi, [rsp + 64]
    inc rdi
    shl rdi, 1
    call mem_alloc
    mov [rsp + 104], rax
    # direction bits: one per cell, zeroed by mem_alloc
    mov rax, [rsp + 56]
    test rax, rax
    jz .Ld_no_table
    mov rcx, [rsp + 64]
    test rcx, rcx
    jz .Ld_no_table
    imul rax, rcx
    add rax, 7
    shr rax, 3
    mov rdi, rax
    call mem_alloc
    mov [rsp + 88], rax
.Ld_no_table:
    # LCS
    cmp qword ptr [rsp + 56], 0
    je .Ld_after_dp
    cmp qword ptr [rsp + 64], 0
    je .Ld_after_dp
    mov rdi, [rsp + 56]
    mov rsi, [rsp + 64]
    mov rdx, [rsp + 72]
    mov rcx, [rsp + 80]
    mov r8, [rsp + 88]
    mov r9, [rsp + 96]
    mov rax, [rsp + 104]
    sub rsp, 16
    mov [rsp], rax
    call d_lcs_fill
    add rsp, 16
.Ld_after_dp:
    # ops array (n+m+1) * 32
    mov rdi, [rsp + 56]
    add rdi, [rsp + 64]
    inc rdi
    shl rdi, 5
    call mem_alloc
    mov [rsp + 112], rax
    # backtrack into ops
    mov rdi, [rsp + 56]
    mov rsi, [rsp + 64]
    mov rdx, [rsp + 72]
    mov rcx, [rsp + 80]
    mov r8, [rsp + 88]
    mov r9, [rsp + 112]
    mov rax, [rsp + 128]
    sub rsp, 16
    mov [rsp], rax
    mov rax, [rsp + 16 + 136]
    mov [rsp + 8], rax
    call d_backtrack
    add rsp, 16
    mov [rsp + 120], rax
    # ---- hunk loop ----
    mov qword ptr [rsp + 232], 0
.Lh_outer:
    mov rax, [rsp + 232]
    cmp rax, [rsp + 120]
    jae .Ld_free
    mov rcx, rax
    shl rcx, 5
    add rcx, [rsp + 112]
    cmp dword ptr [rcx + OP_KIND], 0
    jne .Lh_found
    inc qword ptr [rsp + 232]
    jmp .Lh_outer
.Lh_found:
    mov rcx, rax
    xor edx, edx
.Lh_back:
    test rcx, rcx
    jz .Lh_back_done
    cmp edx, 3
    jae .Lh_back_done
    mov r8, rcx
    dec r8
    shl r8, 5
    add r8, [rsp + 112]
    cmp dword ptr [r8 + OP_KIND], 0
    jne .Lh_back_done
    dec rcx
    inc edx
    jmp .Lh_back
.Lh_back_done:
    mov [rsp + 176], rcx        # hunk start op index
    mov r10, rax                # last change index
    lea r11, [rax + 1]          # scan cursor
.Lh_scan:
    cmp r11, [rsp + 120]
    jae .Lh_scan_done
    mov r8, r11
    shl r8, 5
    add r8, [rsp + 112]
    cmp dword ptr [r8 + OP_KIND], 0
    jne .Lh_change
    mov r9, r11
.Lh_runloop:
    cmp r9, [rsp + 120]
    jae .Lh_run_end
    mov r8, r9
    shl r8, 5
    add r8, [rsp + 112]
    cmp dword ptr [r8 + OP_KIND], 0
    jne .Lh_run_end
    inc r9
    jmp .Lh_runloop
.Lh_run_end:
    mov r8, r9
    sub r8, r11
    cmp r9, [rsp + 120]
    jae .Lh_scan_done
    cmp r8, 6
    ja .Lh_scan_done
    mov r11, r9
    jmp .Lh_scan
.Lh_change:
    mov r10, r11
    inc r11
    jmp .Lh_scan
.Lh_scan_done:
    lea r8, [r10 + 4]
    cmp r8, [rsp + 120]
    cmova r8, [rsp + 120]
    mov [rsp + 184], r8         # hunk end op index (exclusive)
    # counts
    xor eax, eax                # old_count
    xor edx, edx                # new_count
    mov rcx, [rsp + 176]
    mov r8, [rsp + 184]
.Lh_count:
    cmp rcx, r8
    jae .Lh_count_done
    mov r9, rcx
    shl r9, 5
    add r9, [rsp + 112]
    mov r10d, [r9 + OP_KIND]
    test r10d, r10d
    jnz .Lh_count_not_ctx
    inc rax
    inc rdx
    jmp .Lh_count_next
.Lh_count_not_ctx:
    cmp r10d, 1
    jne .Lh_count_add
    inc rax
    jmp .Lh_count_next
.Lh_count_add:
    inc rdx
.Lh_count_next:
    inc rcx
    jmp .Lh_count
.Lh_count_done:
    mov [rsp + 208], rax
    mov [rsp + 216], rdx
    # starts: first op line number, minus one when the range is empty
    mov rcx, [rsp + 176]
    shl rcx, 5
    add rcx, [rsp + 112]
    mov eax, [rcx + OP_OLD]
    mov edx, [rcx + OP_NEW]
    cmp qword ptr [rsp + 208], 0
    jne 1f
    dec eax
1:  cmp qword ptr [rsp + 216], 0
    jne 2f
    dec edx
2:  mov [rsp + 192], rax
    mov [rsp + 200], rdx
    lea rdi, [rsp + 144]
    mov rsi, [rsp + 192]
    mov rdx, [rsp + 208]
    mov rcx, [rsp + 200]
    mov r8, [rsp + 216]
    call d_hunk_header
    test eax, eax
    jnz .Ld_truncated
    mov rax, [rsp + 176]
    mov [rsp + 224], rax
.Lh_emit:
    mov rax, [rsp + 224]
    cmp rax, [rsp + 184]
    jae .Lh_next
    mov rcx, rax
    shl rcx, 5
    add rcx, [rsp + 112]
    mov r8d, [rcx + OP_FLAGS]
    mov rdx, [rcx + OP_PTR]
    mov r9, [rcx + OP_LEN]
    mov r10d, [rcx + OP_KIND]
    mov esi, 32
    test r10d, r10d
    jz 1f
    mov esi, 45
    cmp r10d, 1
    je 1f
    mov esi, 43
1:  mov rcx, r9
    lea rdi, [rsp + 144]
    call d_line
    test eax, eax
    jnz .Ld_truncated
    inc qword ptr [rsp + 224]
    jmp .Lh_emit
.Lh_next:
    mov rax, [rsp + 184]
    mov [rsp + 232], rax
    jmp .Lh_outer

# ---- fallback: whole file replaced (@@ -1,N +1,M @@), straight from bytes ----
.Ld_fallback:
    xor esi, esi
    cmp qword ptr [rsp + 56], 0
    je 1f
    mov esi, 1
1:  mov rdx, [rsp + 56]
    xor ecx, ecx
    cmp qword ptr [rsp + 64], 0
    je 2f
    mov ecx, 1
2:  mov r8, [rsp + 64]
    lea rdi, [rsp + 144]
    call d_hunk_header
    test eax, eax
    jnz .Ld_truncated
    lea rdi, [rsp + 144]
    mov esi, 45
    mov rdx, [rsp + 8]
    mov rcx, [rsp + 16]
    mov r8, [rsp + 128]
    call d_emit_all
    test eax, eax
    jnz .Ld_truncated
    lea rdi, [rsp + 144]
    mov esi, 43
    mov rdx, [rsp + 24]
    mov rcx, [rsp + 32]
    mov r8, [rsp + 136]
    call d_emit_all
    test eax, eax
    jnz .Ld_truncated
    jmp .Ld_free

# ---- identical inputs: just the two header lines ----
.Ld_identical:
    lea rdi, [rsp + 144]
    mov rsi, [rsp]
    call d_headers
    test eax, eax
    jnz .Ld_truncated
    xor eax, eax
    EPILOGUE

.Ld_truncated:
    mov rdi, [rsp + 160]
    lea rsi, [rip + .Ld_trunc]
    call sb_push_cstr
    jmp .Ld_free

.Ld_free:
    mov rdi, [rsp + 72]
    call mem_free
    mov rdi, [rsp + 80]
    call mem_free
    mov rdi, [rsp + 88]
    call mem_free
    mov rdi, [rsp + 96]
    call mem_free
    mov rdi, [rsp + 104]
    call mem_free
    mov rdi, [rsp + 112]
    call mem_free
    xor eax, eax
    EPILOGUE
