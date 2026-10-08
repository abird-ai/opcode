# models.s: `opcode models [--refresh] [--provider P]` and the top-level
# `--list-models [FILTER]`.  Prints the available models as provider/id lines
# sorted by provider then id, each tagged (builtin) for the generated catalogue
# or (discovered) for entries loaded from the user/discovered cache.  --refresh
# and --refresh-models force discovery (ignoring the 24 h cache); a plain
# --list-models reuses a fresh cache and can be filtered by a substring of the
# provider, id or name.
.include "opcode.inc"
.include "core/core.inc"

.extern opcode_catalog, opcode_catalog_count
.extern catalog_count, catalog_at, catalog_load_user
.extern discover_models, discover_models_cached
.extern config_provider_at
.extern g_offline, g_discover_base

.equ ME_md,    0                # MD*
.equ ME_flags, 8               # 0 builtin, 1 discovered
.equ ME_SIZE,  16

.section .rodata
.Lopt_refresh:  .asciz "--refresh"
.Lopt_refreshm: .asciz "--refresh-models"
.Lopt_offline:  .asciz "--offline"
.Lopt_provider: .asciz "--provider"
.Lopt_base:     .asciz "--base-url"
.Lusage:
    .asciz "usage: opcode models [--refresh] [--provider P]\n"
.Llist_usage:
    .asciz "usage: opcode --list-models [--refresh-models] [--offline] [--provider P] [--base-url U] [FILTER]\n"
.Lkey_dp:       .asciz "default_provider"
.Ltag_builtin:  .asciz " (builtin)"
.Ltag_disc:     .asciz " (discovered)"
.Lnone:         .asciz "opcode: no models available\n"
.Lerr_prefix:   .asciz "opcode: discovery failed for "
.Lerr_colon:    .asciz ": "
.Lnl:           .asciz "\n"
.Lslash:        .asciz "/"
.Lempty:        .asciz ""
.Lr_timeout:    .asciz "timed out"
.Lr_connref:    .asciz "connection refused"
.Lr_netunr:     .asciz "network unreachable"
.Lr_hostunr:    .asciz "no route to host"
.Lr_refused:    .asciz "permission denied"
.Lr_notfound:   .asciz "not found"
.Lr_nomem:      .asciz "out of memory"
.Lr_io:         .asciz "i/o error"
.Lr_sys:        .asciz "not supported"
.Lr_error:      .asciz "error "

.text

# out_cstr(fd, cstr)
out_cstr:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rsi
    call strlen
    mov edi, ebx
    mov rsi, r12
    mov rdx, rax
    call write_all
    EPILOGUE

# eq(a, b) -> 1|0 (leaf)
strq_eq:
1:  mov al, [rdi]
    cmp al, [rsi]
    jne 2f
    test al, al
    jz 3f
    inc rdi
    inc rsi
    jmp 1b
2:  xor eax, eax
    ret
3:  mov eax, 1
    ret

# cstr_cmp(a, b) -> <0 | 0 | >0 (leaf, byte order)
cstr_cmp:
1:  movzx eax, byte ptr [rdi]
    movzx ecx, byte ptr [rsi]
    sub eax, ecx
    jne 2f
    cmp byte ptr [rdi], 0
    je 2f
    inc rdi
    inc rsi
    jmp 1b
2:  ret

# md_eq(a, b) -> 1|0: same provider and id
md_eq:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov rdi, [rbx + MD_provider]
    call strlen
    mov r13, rax
    mov rdi, [r12 + MD_provider]
    call strlen
    mov rdi, [rbx + MD_provider]
    mov rsi, r13
    mov rdx, [r12 + MD_provider]
    mov rcx, rax
    call str_eq
    test eax, eax
    jz .Lmdeq_no
    mov rdi, [rbx + MD_id]
    call strlen
    mov r13, rax
    mov rdi, [r12 + MD_id]
    call strlen
    mov rdi, [rbx + MD_id]
    mov rsi, r13
    mov rdx, [r12 + MD_id]
    mov rcx, rax
    call str_eq
    EPILOGUE
.Lmdeq_no:
    xor eax, eax
    EPILOGUE

# md_cmp(a, b) -> provider then id lexicographic (leaf; uses r8/r9)
md_cmp:
    mov r8, rdi
    mov r9, rsi
    mov rdi, [r8 + MD_provider]
    mov rsi, [r9 + MD_provider]
    call cstr_cmp
    test eax, eax
    jnz .Lmdcmp_out
    mov rdi, [r8 + MD_id]
    mov rsi, [r9 + MD_id]
    jmp cstr_cmp
.Lmdcmp_out:
    ret

# models_is_builtin(md) -> 1|0: is it one of the generated catalogue records?
models_is_builtin:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, [rip + opcode_catalog_count]
    xor r13d, r13d
    xor r14d, r14d
.Lmib_loop:
    cmp r13, r12
    jae .Lmib_out
    imul rax, r13, MD_SIZE
    lea rdi, [rip + opcode_catalog]
    add rdi, rax
    mov rsi, rbx
    call md_eq
    test eax, eax
    jnz .Lmib_yes
    inc r13
    jmp .Lmib_loop
.Lmib_yes:
    mov r14d, 1
.Lmib_out:
    mov eax, r14d
    EPILOGUE

# models_in_vec(vec VEC*, md) -> 1|0 (linear scan of 16-byte entries)
models_in_vec:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, [rbx + VEC_len]
    mov r14, [rbx + VEC_ptr]
    xor r15d, r15d
.Lmiv_loop:
    cmp r15, r13
    jae .Lmiv_no
    mov rax, r15
    shl rax, 4
    mov rdi, [r14 + rax]
    mov rsi, r12
    call md_eq
    test eax, eax
    jnz .Lmiv_yes
    inc r15
    jmp .Lmiv_loop
.Lmiv_yes:
    mov eax, 1
    EPILOGUE
.Lmiv_no:
    xor eax, eax
    EPILOGUE

# models_reason(err negative) -> static cstr (never 0)
models_reason:
    cmp rdi, -ETIMEDOUT
    je .Lmr_timeout
    cmp rdi, -111
    je .Lmr_connref
    cmp rdi, -101
    je .Lmr_netunr
    cmp rdi, -113
    je .Lmr_hostunr
    cmp rdi, -EACCES
    je .Lmr_refused
    cmp rdi, -ENOENT
    je .Lmr_notfound
    cmp rdi, -ENOMEM
    je .Lmr_nomem
    cmp rdi, -EIO
    je .Lmr_io
    cmp rdi, -ENOSYS
    je .Lmr_sys
    lea rax, [rip + .Lempty]
    ret
.Lmr_timeout:
    lea rax, [rip + .Lr_timeout]
    ret
.Lmr_connref:
    lea rax, [rip + .Lr_connref]
    ret
.Lmr_netunr:
    lea rax, [rip + .Lr_netunr]
    ret
.Lmr_hostunr:
    lea rax, [rip + .Lr_hostunr]
    ret
.Lmr_refused:
    lea rax, [rip + .Lr_refused]
    ret
.Lmr_notfound:
    lea rax, [rip + .Lr_notfound]
    ret
.Lmr_nomem:
    lea rax, [rip + .Lr_nomem]
    ret
.Lmr_io:
    lea rax, [rip + .Lr_io]
    ret
.Lmr_sys:
    lea rax, [rip + .Lr_sys]
    ret

# models_discover_one(provider cstr) -> 0 ok | 1 error (a one-line reason on stderr)
models_discover_one:
    PROLOGUE 128
    mov rbx, rdi
    xor esi, esi
    mov edx, 1                  # models --refresh always ignores the cache
    call discover_models_cached
    test rax, rax
    js .Lmdo_err
    xor eax, eax
    EPILOGUE
.Lmdo_err:
    mov r12, rax
    xor eax, eax
    mov [rsp + 0], rax
    mov [rsp + 8], rax
    mov [rsp + 16], rax
    mov rdi, rsp
    lea rsi, [rip + .Lerr_prefix]
    call sb_push_cstr
    mov rdi, rsp
    mov rsi, rbx
    call sb_push_cstr
    mov rdi, rsp
    lea rsi, [rip + .Lerr_colon]
    call sb_push_cstr
    mov rdi, r12
    call models_reason
    cmp byte ptr [rax], 0
    jne .Lmdo_reason
    mov rdi, rsp
    lea rsi, [rip + .Lr_error]
    call sb_push_cstr
    mov rdi, r12
    neg rdi
    mov rsi, rdi
    mov rdi, rsp
    call sb_push_u64
    jmp .Lmdo_reasoned
.Lmdo_reason:
    mov rsi, rax
    mov rdi, rsp
    call sb_push_cstr
.Lmdo_reasoned:
    mov rdi, rsp
    lea rsi, [rip + .Lnl]
    call sb_push_cstr
    mov edi, 2
    mov rsi, [rsp + SB_ptr]
    mov rdx, [rsp + SB_len]
    call write_all
    mov rdi, rsp
    call sb_free
    mov eax, 1
    EPILOGUE

# models_add(vec*, md, flags)
models_add:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, rbx
    mov esi, ME_SIZE
    call vec_push
    mov [rax + ME_md], r12
    mov [rax + ME_flags], r13
    EPILOGUE

# models_collect(entries VEC*, filter cstr|0): builtins + user/discovered dedup.
models_collect:
    PROLOGUE 48
    mov rbx, rdi
    mov r12, rsi
    mov r13, [rip + opcode_catalog_count]
    xor r14d, r14d
.Lmc_builtin:
    cmp r14, r13
    jae .Lmc_user
    imul rax, r14, MD_SIZE
    lea r15, [rip + opcode_catalog]
    add r15, rax
    test r12, r12
    jz .Lmc_add_builtin
    mov rdi, [r15 + MD_provider]
    mov rsi, r12
    call strq_eq
    test eax, eax
    jz .Lmc_next_builtin
.Lmc_add_builtin:
    mov rdi, rbx
    mov rsi, r15
    xor edx, edx
    call models_add
.Lmc_next_builtin:
    inc r14
    jmp .Lmc_builtin
.Lmc_user:
    call catalog_count
    mov r13, rax
    xor r14d, r14d
.Lmc_user_loop:
    cmp r14, r13
    jae .Lmc_done
    mov rdi, r14
    call catalog_at
    test rax, rax
    jz .Lmc_next_user
    mov r15, rax
    mov rdi, r15
    call models_is_builtin
    test eax, eax
    jnz .Lmc_next_user
    test r12, r12
    jz .Lmc_user_filter
    mov rdi, [r15 + MD_provider]
    mov rsi, r12
    call strq_eq
    test eax, eax
    jz .Lmc_next_user
.Lmc_user_filter:
    mov rdi, rbx
    mov rsi, r15
    call models_in_vec
    test eax, eax
    jnz .Lmc_next_user
    mov rdi, rbx
    mov rsi, r15
    mov edx, 1
    call models_add
.Lmc_next_user:
    inc r14
    jmp .Lmc_user_loop
.Lmc_done:
    EPILOGUE

# models_sort(entries VEC*): bubble sort by provider then id.
models_sort:
    PROLOGUE 32
    mov rbx, rdi
    mov r13, [rbx + VEC_len]
    mov r12, [rbx + VEC_ptr]
    cmp r13, 2
    jb .Lms_done
    mov r15, r13
    dec r15                     # compare limit for this pass
.Lms_outer:
    test r15, r15
    jz .Lms_done
    xor r14d, r14d              # i
.Lms_inner:
    cmp r14, r15
    jae .Lms_next_pass
    mov rax, r14
    shl rax, 4
    lea rdi, [r12 + rax]
    mov rcx, [rdi + 16 + ME_md]
    mov rdx, [rdi + 16 + ME_flags]
    mov [rsp], rcx
    mov [rsp + 8], rdx
    mov rdi, [rdi + ME_md]
    mov rsi, rcx
    call md_cmp
    test eax, eax
    jle .Lms_no_swap
    mov rax, r14
    shl rax, 4
    lea rdi, [r12 + rax]
    mov rcx, [rdi + ME_md]
    mov rdx, [rdi + ME_flags]
    mov [rdi + 16 + ME_md], rcx
    mov [rdi + 16 + ME_flags], rdx
    mov rcx, [rsp]
    mov rdx, [rsp + 8]
    mov [rdi + ME_md], rcx
    mov [rdi + ME_flags], rdx
.Lms_no_swap:
    inc r14
    jmp .Lms_inner
.Lms_next_pass:
    dec r15
    jmp .Lms_outer
.Lms_done:
    EPILOGUE

# opcode_models_main(argc, argv) -> exit code
FN opcode_models_main
    PROLOGUE 192
    mov r15, rdi
    mov r14, rsi
    mov qword ptr [rsp + 0], 0      # out SB
    mov qword ptr [rsp + 8], 0
    mov qword ptr [rsp + 16], 0
    mov qword ptr [rsp + 32], 0     # entries VEC
    mov qword ptr [rsp + 40], 0
    mov qword ptr [rsp + 48], 0
    mov qword ptr [rsp + 64], 0     # providers VEC
    mov qword ptr [rsp + 72], 0
    mov qword ptr [rsp + 80], 0
    mov dword ptr [rsp + 96], 0     # refresh
    mov qword ptr [rsp + 104], 0    # provider filter
    mov r12, 0
.Lfm_loop:
    inc r12
    cmp r12, r15
    jae .Lfm_parsed
    mov r13, [r14 + r12*8]
    cmp byte ptr [r13], '-'
    jne .Lfm_usage
    mov rdi, r13
    lea rsi, [rip + .Lopt_refresh]
    call strq_eq
    test eax, eax
    jnz .Lfm_refresh
    mov rdi, r13
    lea rsi, [rip + .Lopt_provider]
    call strq_eq
    test eax, eax
    jnz .Lfm_provider
    jmp .Lfm_usage
.Lfm_refresh:
    mov dword ptr [rsp + 96], 1
    jmp .Lfm_next
.Lfm_provider:
    inc r12
    cmp r12, r15
    jae .Lfm_usage
    mov rax, [r14 + r12*8]
    mov [rsp + 104], rax
    jmp .Lfm_next
.Lfm_next:
    jmp .Lfm_loop
.Lfm_parsed:
    call config_load
    cmp dword ptr [rsp + 96], 0
    je .Lfm_list
    # collect the providers to refresh
    mov rdi, [rsp + 104]
    test rdi, rdi
    jnz .Lfm_refresh_flagged
    lea rdi, [rip + .Lkey_dp]
    call config_str
    test rax, rax
    jz .Lfm_refresh_scan
    mov r13, rax
    lea rdi, [rsp + 64]
    mov rsi, r13
    call models_prov_add
    mov rdi, r13
    call mem_free
.Lfm_refresh_scan:
    xor r12d, r12d
.Lfm_refresh_scan_loop:
    mov edi, r12d
    call config_provider_at
    test rax, rax
    jz .Lfm_refresh_go
    mov r13, rax
    lea rdi, [rsp + 64]
    mov rsi, r13
    call models_prov_add
    mov rdi, r13
    call mem_free
    inc r12d
    jmp .Lfm_refresh_scan_loop
.Lfm_refresh_go:
    mov r13, [rsp + 64 + VEC_len]
    mov r14, [rsp + 64 + VEC_ptr]
    xor r12d, r12d
.Lfm_refresh_loop:
    cmp r12, r13
    jae .Lfm_list
    mov rdi, [r14 + r12*8]
    call models_discover_one
    test eax, eax
    jnz .Lfm_fail
    inc r12
    jmp .Lfm_refresh_loop
.Lfm_refresh_flagged:
    call models_discover_one
    test eax, eax
    jnz .Lfm_fail
.Lfm_list:
    call catalog_load_user
    lea rdi, [rsp + 32]
    mov rsi, [rsp + 104]
    call models_collect
    lea rdi, [rsp + 32]
    call models_sort
    # print provider/id (builtin|discovered)
    lea rdi, [rsp]
    call sb_clear
    mov r13, [rsp + 32 + VEC_len]
    mov r14, [rsp + 32 + VEC_ptr]
    xor r12d, r12d
.Lfm_print_loop:
    cmp r12, r13
    jae .Lfm_print_end
    mov rax, r12
    shl rax, 4
    lea r15, [r14 + rax]
    mov rbx, [r15 + ME_md]
    lea rdi, [rsp]
    mov rsi, [rbx + MD_provider]
    call sb_push_cstr
    lea rdi, [rsp]
    lea rsi, [rip + .Lslash]
    call sb_push_cstr
    lea rdi, [rsp]
    mov rsi, [rbx + MD_id]
    call sb_push_cstr
    lea rdi, [rsp]
    cmp qword ptr [r15 + ME_flags], 0
    jne .Lfm_note_disc
    lea rsi, [rip + .Ltag_builtin]
    jmp .Lfm_note
.Lfm_note_disc:
    lea rsi, [rip + .Ltag_disc]
.Lfm_note:
    call sb_push_cstr
    lea rdi, [rsp]
    lea rsi, [rip + .Lnl]
    call sb_push_cstr
    inc r12
    jmp .Lfm_print_loop
.Lfm_print_end:
    cmp qword ptr [rsp + SB_len], 0
    jne .Lfm_emit
    lea rdi, [rsp]
    lea rsi, [rip + .Lnone]
    call sb_push_cstr
.Lfm_emit:
    mov edi, 1
    mov rsi, [rsp + SB_ptr]
    mov rdx, [rsp + SB_len]
    call write_all
    xor eax, eax
    jmp .Lfm_cleanup
.Lfm_fail:
    mov eax, 1
.Lfm_cleanup:
    mov [rsp + 112], eax
    lea rdi, [rsp]
    call sb_free
    lea rdi, [rsp + 32]
    call vec_free
    lea rdi, [rsp + 64]
    call models_prov_free
    mov eax, [rsp + 112]
    EPILOGUE
.Lfm_usage:
    mov edi, 2
    lea rsi, [rip + .Lusage]
    call out_cstr
    mov eax, 2
    EPILOGUE

# models_prov_add(provs VEC*, cstr): append when not present.
models_prov_add:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, [rbx + VEC_len]
    mov r14, [rbx + VEC_ptr]
    xor r15d, r15d
.Lmpa_loop:
    cmp r15, r13
    jae .Lmpa_add
    mov rdi, [r14 + r15*8]
    mov rsi, r12
    call strq_eq
    test eax, eax
    jnz .Lmpa_done
    inc r15
    jmp .Lmpa_loop
.Lmpa_add:
    mov rdi, r12
    call strlen
    mov rdi, r12
    mov rsi, rax
    call mem_dup
    mov r12, rax
    mov rdi, rbx
    mov esi, 8
    call vec_push
    mov [rax], r12
.Lmpa_done:
    EPILOGUE

# models_prov_free(provs VEC*): free the strings and the vector.
models_prov_free:
    PROLOGUE 16
    mov rbx, rdi
    mov r13, [rbx + VEC_len]
    mov r14, [rbx + VEC_ptr]
    xor r12d, r12d
.Lmpf_loop:
    cmp r12, r13
    jae .Lmpf_done
    mov rdi, [r14 + r12*8]
    call mem_free
    inc r12
    jmp .Lmpf_loop
.Lmpf_done:
    mov rdi, rbx
    call vec_free
    EPILOGUE

# ============================================================ --list-models
# cstr_contains(hay cstr, needle cstr) -> 1|0
cstr_contains:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rsi
    call strlen
    mov r13, rax
    mov rdi, rbx
    call strlen
    mov rdi, rbx
    mov rsi, rax
    mov rdx, r12
    mov rcx, r13
    call str_find
    test rax, rax
    js .Lcc_no
    mov eax, 1
    EPILOGUE
.Lcc_no:
    xor eax, eax
    EPILOGUE

# models_match(md rdi, provider rsi|0, sub rdx|0) -> 1|0
models_match:
    PROLOGUE 32
    mov [rsp], rdi
    mov [rsp + 8], rsi
    mov [rsp + 16], rdx
    test rsi, rsi
    jz .Lmm_sub
    mov rdi, [rdi + MD_provider]
    mov rsi, [rsp + 8]
    call strq_eq
    test eax, eax
    jz .Lmm_no
.Lmm_sub:
    cmp qword ptr [rsp + 16], 0
    je .Lmm_yes
    mov rbx, [rsp]
    mov rdi, [rbx + MD_id]
    mov rsi, [rsp + 16]
    call cstr_contains
    test eax, eax
    jnz .Lmm_yes
    mov rdi, [rbx + MD_name]
    test rdi, rdi
    jz .Lmm_no
    mov rsi, [rsp + 16]
    call cstr_contains
    test eax, eax
    jnz .Lmm_yes
.Lmm_no:
    xor eax, eax
    EPILOGUE
.Lmm_yes:
    mov eax, 1
    EPILOGUE

# models_collect_sub(entries VEC*, sub cstr|0, provider cstr|0): builtins +
# user/discovered, keeping provider==provider (when set) and sub matching the
# id/name; deduplicated against the builtins.
models_collect_sub:
    PROLOGUE 64
    mov [rsp], rdi
    mov [rsp + 8], rsi
    mov [rsp + 16], rdx
    mov r13, [rip + opcode_catalog_count]
    xor r14d, r14d
.Lmcs_bloop:
    cmp r14, r13
    jae .Lmcs_user
    imul rax, r14, MD_SIZE
    lea r15, [rip + opcode_catalog]
    add r15, rax
    mov rdi, r15
    mov rsi, [rsp + 16]
    mov rdx, [rsp + 8]
    call models_match
    test eax, eax
    jz .Lmcs_bnext
    mov rdi, [rsp]
    mov rsi, r15
    xor edx, edx
    call models_add
.Lmcs_bnext:
    inc r14
    jmp .Lmcs_bloop
.Lmcs_user:
    call catalog_count
    mov r13, rax
    xor r14d, r14d
.Lmcs_uloop:
    cmp r14, r13
    jae .Lmcs_done
    mov rdi, r14
    call catalog_at
    test rax, rax
    jz .Lmcs_unext
    mov r15, rax
    mov rdi, r15
    call models_is_builtin
    test eax, eax
    jnz .Lmcs_unext
    mov rdi, r15
    mov rsi, [rsp + 16]
    mov rdx, [rsp + 8]
    call models_match
    test eax, eax
    jz .Lmcs_unext
    mov rdi, [rsp]
    mov rsi, r15
    call models_in_vec
    test eax, eax
    jnz .Lmcs_unext
    mov rdi, [rsp]
    mov rsi, r15
    mov edx, 1
    call models_add
.Lmcs_unext:
    inc r14
    jmp .Lmcs_uloop
.Lmcs_done:
    EPILOGUE

# models_print_vec(entries VEC*): "provider/id (builtin|discovered)" on stdout
models_print_vec:
    PROLOGUE 48
    mov [rsp], rdi
    mov qword ptr [rsp + 8 + SB_ptr], 0
    mov qword ptr [rsp + 8 + SB_len], 0
    mov qword ptr [rsp + 8 + SB_cap], 0
    mov r13, [rdi + VEC_len]
    mov r14, [rdi + VEC_ptr]
    xor r12d, r12d
.Lmpv_loop:
    cmp r12, r13
    jae .Lmpv_end
    mov rax, r12
    shl rax, 4
    lea r15, [r14 + rax]
    mov rbx, [r15 + ME_md]
    lea rdi, [rsp + 8]
    mov rsi, [rbx + MD_provider]
    call sb_push_cstr
    lea rdi, [rsp + 8]
    lea rsi, [rip + .Lslash]
    call sb_push_cstr
    lea rdi, [rsp + 8]
    mov rsi, [rbx + MD_id]
    call sb_push_cstr
    lea rdi, [rsp + 8]
    cmp qword ptr [r15 + ME_flags], 0
    jne .Lmpv_disc
    lea rsi, [rip + .Ltag_builtin]
    jmp .Lmpv_note
.Lmpv_disc:
    lea rsi, [rip + .Ltag_disc]
.Lmpv_note:
    call sb_push_cstr
    lea rdi, [rsp + 8]
    lea rsi, [rip + .Lnl]
    call sb_push_cstr
    inc r12
    jmp .Lmpv_loop
.Lmpv_end:
    cmp qword ptr [rsp + 8 + SB_len], 0
    jne .Lmpv_emit
    lea rdi, [rsp + 8]
    lea rsi, [rip + .Lnone]
    call sb_push_cstr
.Lmpv_emit:
    mov edi, 1
    mov rsi, [rsp + 8 + SB_ptr]
    mov rdx, [rsp + 8 + SB_len]
    call write_all
    lea rdi, [rsp + 8]
    call sb_free
    EPILOGUE

# opcode_list_models_main(argc, argv) -> exit code
# argv[0] is "--list-models".  Discovers the resolved or all configured
# providers (cache first unless --refresh-models), loads the catalog and
# prints it, optionally filtered, without starting the agent.
FN opcode_list_models_main
    PROLOGUE 128
    mov r15, rdi
    mov r14, rsi
    mov qword ptr [rsp], 0          # entries VEC
    mov qword ptr [rsp + 8], 0
    mov qword ptr [rsp + 16], 0
    mov qword ptr [rsp + 24], 0     # providers VEC
    mov qword ptr [rsp + 32], 0
    mov qword ptr [rsp + 40], 0
    mov qword ptr [rsp + 48], 0     # filter
    mov qword ptr [rsp + 56], 0     # provider
    mov dword ptr [rsp + 64], 0     # refresh
    mov r12, 0
.Llm_loop:
    inc r12
    cmp r12, r15
    jae .Llm_parsed
    mov r13, [r14 + r12*8]
    cmp byte ptr [r13], '-'
    jne .Llm_filter
    mov rdi, r13
    lea rsi, [rip + .Lopt_offline]
    call strq_eq
    test eax, eax
    jnz .Llm_offline
    mov rdi, r13
    lea rsi, [rip + .Lopt_refreshm]
    call strq_eq
    test eax, eax
    jnz .Llm_refresh
    mov rdi, r13
    lea rsi, [rip + .Lopt_provider]
    call strq_eq
    test eax, eax
    jnz .Llm_provider
    mov rdi, r13
    lea rsi, [rip + .Lopt_base]
    call strq_eq
    test eax, eax
    jnz .Llm_base
    jmp .Llm_usage
.Llm_offline:
    mov qword ptr [rip + g_offline], 1
    jmp .Llm_next
.Llm_refresh:
    mov dword ptr [rsp + 64], 1
    jmp .Llm_next
.Llm_provider:
    inc r12
    cmp r12, r15
    jae .Llm_usage
    mov rax, [r14 + r12*8]
    mov [rsp + 56], rax
    jmp .Llm_next
.Llm_base:
    inc r12
    cmp r12, r15
    jae .Llm_usage
    mov rax, [r14 + r12*8]
    mov [rip + g_discover_base], rax
    jmp .Llm_next
.Llm_filter:
    mov [rsp + 48], r13
.Llm_next:
    jmp .Llm_loop
.Llm_parsed:
    call config_load
    mov rdi, [rsp + 56]
    test rdi, rdi
    jnz .Llm_add_prov
    lea rdi, [rip + .Lkey_dp]
    call config_str
    test rax, rax
    jz .Llm_scan
    mov rbx, rax
    lea rdi, [rsp + 24]
    mov rsi, rbx
    call models_prov_add
    mov rdi, rbx
    call mem_free
.Llm_scan:
    xor r12d, r12d
.Llm_scan_loop:
    mov edi, r12d
    call config_provider_at
    test rax, rax
    jz .Llm_discover
    mov rbx, rax
    lea rdi, [rsp + 24]
    mov rsi, rbx
    call models_prov_add
    mov rdi, rbx
    call mem_free
    inc r12d
    jmp .Llm_scan_loop
.Llm_add_prov:
    mov rsi, [rsp + 56]
    lea rdi, [rsp + 24]
    call models_prov_add
.Llm_discover:
    mov r13, [rsp + 24 + VEC_len]
    mov r14, [rsp + 24 + VEC_ptr]
    xor r12d, r12d
.Llm_disc_loop:
    cmp r12, r13
    jae .Llm_list
    mov rdi, [r14 + r12*8]
    xor esi, esi
    mov edx, [rsp + 64]
    call discover_models_cached
    inc r12
    jmp .Llm_disc_loop
.Llm_list:
    call catalog_load_user
    lea rdi, [rsp]
    mov rsi, [rsp + 48]
    mov rdx, [rsp + 56]
    call models_collect_sub
    lea rdi, [rsp]
    call models_sort
    lea rdi, [rsp]
    call models_print_vec
    xor eax, eax
    jmp .Llm_cleanup
.Llm_usage:
    mov edi, 2
    lea rsi, [rip + .Llist_usage]
    call out_cstr
    mov eax, 2
.Llm_cleanup:
    mov [rsp + 72], eax
    lea rdi, [rsp]
    call vec_free
    lea rdi, [rsp + 24]
    call models_prov_free
    mov eax, [rsp + 72]
    EPILOGUE
