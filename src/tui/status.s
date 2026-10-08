# status.s — the one provider table behind the TUI status line.  Built-in and
# future extension
# providers take exactly the same route: register a callback, get called when
# the version changes, have the output validated and copied, then sorted by
# (slot, priority, registration order).
#
#   status_register(rdi=provider, rsi=ud)
#   status_remove(rdi=provider, rsi=ud)
#   status_reset()
#   status_version() -> rax u64
#   status_invalidate()
#   status_snapshot(rdi out SV*, rsi max) -> rax count
#   status_register_builtin()
#   status_builtin_set(rdi ST*)
#   status_render(rdi grid, esi row, edx width) -> eax 0   (rcx reserved: S5 theme)
#
# A provider over the 2 ms budget is disabled for the rest of the process; a
# malformed segment (short struct, bad slot/style, empty text, embedded control
# byte) is dropped individually so one bad segment cannot hide a good one.
.include "opcode.inc"
.include "tui/status.inc"
.include "tui/theme.inc"

.set SS_raw,   -240          # 8 * SEG_SIZE scratch segments
.set SS_arena, -1264         # 1024-byte provider arena
.set SS_i,     -1272
.set SS_out,   -1280
.set SS_max,   -1288
.set SS_n,     -1296
.set SS_seq,   -1304
.set SS_drop,  -1308
.set SS_t0,    -1316

.section .rodata
.Lst_think_prefix: .asciz "think:"
.Lst_ready:        .asciz "ready"
.Lst_sep:          .asciz " | "
.Lst_spin:         .ascii "|/-\\"
.Lst_empty:        .asciz ""

.section .bss
.p2align 4
st_providers: .zero SP_SIZE * STATUS_MAX_PROVIDERS
st_nprov:     .zero 8
st_version:   .zero 8
st_next_id:   .zero 8
st_state:     .zero ST_SIZE
st_cache:     .zero SV_SIZE * STATUS_MAX_SEGMENTS
st_cache_n:   .zero 8
st_cache_ver: .zero 8
st_swap_tmp:  .zero SV_SIZE
st_buf_think: .zero 64
st_buf_tok:   .zero 64
st_buf_cost:  .zero 48
st_buf_state: .zero 32
st_rgrid:     .zero 8
st_rrow:      .zero 8

.text

# st_streq(rdi, rsi) -> eax 1|0 (local copy of the TUI's cstr_eq).
st_streq:
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

# ---------------------------------------------------------------- registry
# status_register(rdi=provider, rsi=ud)
FN status_register
    PROLOGUE 0
    test rdi, rdi
    jz .Lreg_done
    xor rcx, rcx
.Lreg_find:
    cmp rcx, [rip + st_nprov]
    jae .Lreg_add
    mov rax, rcx
    imul rax, rax, SP_SIZE
    lea r8, [rip + st_providers]
    add r8, rax
    cmp [r8 + SP_fn], rdi
    jne .Lreg_next
    cmp [r8 + SP_ud], rsi
    je .Lreg_done
.Lreg_next:
    inc rcx
    jmp .Lreg_find
.Lreg_add:
    mov rax, [rip + st_nprov]
    cmp rax, STATUS_MAX_PROVIDERS
    jae .Lreg_done
    imul rax, rax, SP_SIZE
    lea r8, [rip + st_providers]
    add r8, rax
    mov [r8 + SP_fn], rdi
    mov [r8 + SP_ud], rsi
    mov rax, [rip + st_next_id]
    inc rax
    mov [rip + st_next_id], rax
    mov [r8 + SP_id], rax
    mov dword ptr [r8 + SP_disabled], 0
    inc qword ptr [rip + st_nprov]
    call status_invalidate
.Lreg_done:
    EPILOGUE

# status_remove(rdi=provider, rsi=ud): shift the tail down, preserving order.
FN status_remove
    PROLOGUE 0
    xor rcx, rcx
.Lrem_find:
    cmp rcx, [rip + st_nprov]
    jae .Lrem_done
    mov rax, rcx
    imul rax, rax, SP_SIZE
    lea r8, [rip + st_providers]
    add r8, rax
    cmp [r8 + SP_fn], rdi
    jne .Lrem_next
    cmp [r8 + SP_ud], rsi
    je .Lrem_shift
.Lrem_next:
    inc rcx
    jmp .Lrem_find
.Lrem_shift:
    mov r12, rcx
.Lrem_shift_loop:
    lea rax, [r12 + 1]
    cmp rax, [rip + st_nprov]
    jae .Lrem_zero
    mov rdx, r12
    imul rdx, rdx, SP_SIZE
    lea rdi, [rip + st_providers]
    add rdi, rdx
    mov rdx, rax
    imul rdx, rdx, SP_SIZE
    lea rsi, [rip + st_providers]
    add rsi, rdx
    mov edx, SP_SIZE
    call memcpy
    inc r12
    jmp .Lrem_shift_loop
.Lrem_zero:
    mov rax, [rip + st_nprov]
    dec rax
    imul rax, rax, SP_SIZE
    lea rdi, [rip + st_providers]
    add rdi, rax
    xor esi, esi
    mov edx, SP_SIZE
    call memset
    dec qword ptr [rip + st_nprov]
    call status_invalidate
.Lrem_done:
    EPILOGUE

# status_reset(): drop every provider and bump the version.
FN status_reset
    PROLOGUE 0
    lea rdi, [rip + st_providers]
    xor esi, esi
    mov edx, SP_SIZE * STATUS_MAX_PROVIDERS
    call memset
    mov qword ptr [rip + st_nprov], 0
    mov qword ptr [rip + st_next_id], 0
    call status_invalidate
    xor eax, eax
    EPILOGUE

FN status_version
    mov rax, [rip + st_version]
    ret

FN status_invalidate
    inc qword ptr [rip + st_version]
    xor eax, eax
    ret

# ---------------------------------------------------------------- snapshot
# status_value_less(rdi=a, rsi=b) -> eax 1 when a sorts before b.
status_value_less:
    mov eax, [rdi + SV_slot]
    cmp eax, [rsi + SV_slot]
    jne .Lvl_cmp
    mov eax, [rdi + SV_priority]
    cmp eax, [rsi + SV_priority]
    jne .Lvl_cmp
    mov rax, [rdi + SV_seq]
    cmp rax, [rsi + SV_seq]
    jb .Lvl_yes
    jmp .Lvl_no
.Lvl_cmp:
    jb .Lvl_yes
.Lvl_no:
    xor eax, eax
    ret
.Lvl_yes:
    mov eax, 1
    ret

# status_sort(rdi=arr, rsi=n): insertion sort by (slot, priority, seq).
status_sort:
    PROLOGUE 0
    mov r12, rdi
    mov r13, rsi
    mov r14, 1
.Lsort_i:
    cmp r14, r13
    jae .Lsort_done
    mov rax, r14
    imul rax, rax, SV_SIZE
    lea rsi, [r12 + rax]
    lea rdi, [rip + st_swap_tmp]
    mov edx, SV_SIZE
    call memcpy
    mov r15, r14
.Lsort_j:
    test r15, r15
    jz .Lsort_place
    lea rdi, [rip + st_swap_tmp]
    lea rax, [r15 - 1]
    imul rax, rax, SV_SIZE
    lea rsi, [r12 + rax]
    call status_value_less
    test eax, eax
    jz .Lsort_place
    mov rax, r15
    imul rax, rax, SV_SIZE
    lea rdi, [r12 + rax]
    lea rax, [r15 - 1]
    imul rax, rax, SV_SIZE
    lea rsi, [r12 + rax]
    mov edx, SV_SIZE
    call memcpy
    dec r15
    jmp .Lsort_j
.Lsort_place:
    mov rax, r15
    imul rax, rax, SV_SIZE
    lea rdi, [r12 + rax]
    lea rsi, [rip + st_swap_tmp]
    mov edx, SV_SIZE
    call memcpy
    inc r14
    jmp .Lsort_i
.Lsort_done:
    EPILOGUE

# status_copy(rdi=SEG*, rsi=SV*, rdx=seq) -> eax text length, 0 when dropped.
# The provider text is strictly UTF-8 validated on copy (src/base/uni.s:
# utf8_decode); a C0/DEL/C1 control codepoint drops the segment and a malformed
# sequence becomes U+FFFD, so the footer can only ever hold well-formed text.
status_copy:
    PROLOGUE 32
    mov rbx, rdi                   # SEG*
    mov r12, rsi                   # SV*
    mov r13, rdx                   # seq
    cmp dword ptr [rbx + SEG_struct_size], SEG_SIZE
    jb .Lcp_drop
    mov eax, [rbx + SEG_slot]
    cmp eax, SLOT_RIGHT
    ja .Lcp_drop
    mov eax, [rbx + SEG_style]
    test eax, 0xFFFFFFC0
    jnz .Lcp_drop
    mov r14, [rbx + SEG_text]
    test r14, r14
    jz .Lcp_drop
    cmp byte ptr [r14], 0
    je .Lcp_drop
    mov rdi, r14
    call strlen
    mov r15, rax                   # remaining input bytes
    mov qword ptr [rsp], 0         # output byte length
.Lcp_loop:
    test r15, r15
    jz .Lcp_done
    mov rdi, r14
    mov rsi, r15                   # real remaining length, never fabricated
    call utf8_decode
    add r14, rdx
    sub r15, rdx
    # C0/DEL/C1 controls drop the segment (the old byte-level check extended to
    # the C1 range the old loop silently let through).
    cmp eax, 0x20
    jb .Lcp_drop
    cmp eax, 0x7f
    je .Lcp_drop
    cmp eax, 0x80
    jb .Lcp_ok
    cmp eax, 0x9f
    jbe .Lcp_drop
.Lcp_ok:
    mov edi, eax
    lea rsi, [rsp + 8]
    call utf8_encode
    mov rdx, rax                   # encoded bytes
    mov rax, [rsp]
    add rax, rdx
    cmp rax, STATUS_TEXT_MAX - 1
    ja .Lcp_done                   # keep the prefix that fits
    lea rdi, [r12 + SV_text]
    add rdi, [rsp]                 # old length
    mov [rsp], rax                 # commit the new length before the call
    lea rsi, [rsp + 8]
    call memcpy
    jmp .Lcp_loop
.Lcp_done:
    mov r11, [rsp]
    mov byte ptr [r12 + SV_text + r11], 0
    mov eax, [rbx + SEG_slot]
    mov [r12 + SV_slot], eax
    mov eax, [rbx + SEG_priority]
    mov [r12 + SV_priority], eax
    mov eax, [rbx + SEG_style]
    mov [r12 + SV_style], eax
    mov [r12 + SV_seq], r13
    mov eax, r11d
    test eax, eax
    jnz 1f
    mov eax, 1
1:  EPILOGUE
.Lcp_drop:
    xor eax, eax
    EPILOGUE

FN status_snapshot
    PROLOGUE 1280
    mov [rbp + SS_out], rdi
    mov [rbp + SS_max], rsi
    test rdi, rdi
    jz .Lsnap_zero
    test rsi, rsi
    jz .Lsnap_zero
    mov qword ptr [rbp + SS_n], 0
    mov qword ptr [rbp + SS_seq], 0
    mov dword ptr [rbp + SS_drop], 0
    mov qword ptr [rbp + SS_i], 0
.Lsnap_prov:
    mov rax, [rbp + SS_i]
    cmp rax, [rip + st_nprov]
    jae .Lsnap_prov_done
    imul rax, rax, SP_SIZE
    lea r15, [rip + st_providers]
    add r15, rax
    cmp dword ptr [r15 + SP_disabled], 0
    jne .Lsnap_prov_next
    mov edi, CLOCK_MONOTONIC
    call os_now_ns
    mov [rbp + SS_t0], rax
    mov rdi, [r15 + SP_ud]
    lea rsi, [rbp + SS_raw]
    mov edx, STATUS_MAX_PROVIDER_SEGMENTS
    lea rcx, [rbp + SS_arena]
    mov r8d, STATUS_ARENA_CAP
    call qword ptr [r15 + SP_fn]
    mov r14, rax
    mov edi, CLOCK_MONOTONIC
    call os_now_ns
    sub rax, [rbp + SS_t0]
    cmp rax, STATUS_BUDGET_NS
    jbe .Lsnap_ok
    mov dword ptr [r15 + SP_disabled], 1
    mov dword ptr [rbp + SS_drop], 1
    jmp .Lsnap_prov_next
.Lsnap_ok:
    cmp r14, STATUS_MAX_PROVIDER_SEGMENTS
    jbe 1f
    mov r14d, STATUS_MAX_PROVIDER_SEGMENTS
1:  xor r13d, r13d
.Lsnap_seg:
    cmp r13, r14
    jae .Lsnap_prov_next
    mov rax, [rbp + SS_n]
    cmp rax, [rbp + SS_max]
    jae .Lsnap_prov_next
    mov rax, r13
    imul rax, rax, SEG_SIZE
    lea rdi, [rbp + SS_raw]
    add rdi, rax
    mov rax, [rbp + SS_n]
    imul rax, rax, SV_SIZE
    add rax, [rbp + SS_out]
    mov rsi, rax
    mov rdx, [rbp + SS_seq]
    call status_copy
    test eax, eax
    jz .Lsnap_seg_next
    inc qword ptr [rbp + SS_seq]
    inc qword ptr [rbp + SS_n]
.Lsnap_seg_next:
    inc r13
    jmp .Lsnap_seg
.Lsnap_prov_next:
    inc qword ptr [rbp + SS_i]
    jmp .Lsnap_prov
.Lsnap_prov_done:
    cmp dword ptr [rbp + SS_drop], 0
    je 1f
    call status_invalidate
1:  mov rdi, [rbp + SS_out]
    mov rsi, [rbp + SS_n]
    call status_sort
    mov rax, [rbp + SS_n]
    EPILOGUE
.Lsnap_zero:
    xor eax, eax
    EPILOGUE

# ---------------------------------------------------------------- built-in
# status_register_builtin(): register the model/thinking/tokens/cost/state
# provider.  Idempotent through status_register.
FN status_register_builtin
    lea rdi, [rip + status_builtin_provider]
    xor esi, esi
    jmp status_register

# status_builtin_set(rdi=ST*): copy a changed snapshot and invalidate.
FN status_builtin_set
    PROLOGUE 0
    test rdi, rdi
    jz .Lbs_done
    mov rbx, rdi
    lea rdi, [rbx + ST_model]
    lea rsi, [rip + st_state + ST_model]
    call st_streq
    test eax, eax
    jz .Lbs_changed
    lea rdi, [rbx + ST_thinking]
    lea rsi, [rip + st_state + ST_thinking]
    call st_streq
    test eax, eax
    jz .Lbs_changed
    mov rax, [rbx + ST_tok_in]
    cmp rax, [rip + st_state + ST_tok_in]
    jne .Lbs_changed
    mov rax, [rbx + ST_tok_out]
    cmp rax, [rip + st_state + ST_tok_out]
    jne .Lbs_changed
    mov rax, [rbx + ST_cost_micro]
    cmp rax, [rip + st_state + ST_cost_micro]
    jne .Lbs_changed
    mov eax, [rbx + ST_spinner]
    cmp eax, [rip + st_state + ST_spinner]
    jne .Lbs_changed
    mov rax, [rbx + ST_elapsed_ms]
    cmp rax, [rip + st_state + ST_elapsed_ms]
    jne .Lbs_changed
    mov eax, [rbx + ST_running]
    cmp eax, [rip + st_state + ST_running]
    jne .Lbs_changed
    EPILOGUE
.Lbs_changed:
    lea rdi, [rip + st_state]
    mov rsi, rbx
    mov edx, ST_SIZE
    call memcpy
    call status_invalidate
.Lbs_done:
    EPILOGUE

# st_emit(rdi=text, esi=slot, edx=priority, ecx=style).  Consumes the provider's
# r12=out, r13=max, rbx=count (kept by the built-in provider).
st_emit:
    cmp rbx, r13
    jae .Lemit_done
    mov rax, rbx
    imul rax, rax, SEG_SIZE
    add rax, r12
    mov r8d, SEG_SIZE
    mov [rax + SEG_struct_size], r8d
    mov [rax + SEG_slot], esi
    mov [rax + SEG_priority], edx
    mov [rax + SEG_style], ecx
    mov [rax + SEG_text], rdi
    inc rbx
.Lemit_done:
    ret

# st_u64(rdi=dst, rsi=value) -> rax = dst after the decimal (no NUL written).
st_u64:
    PROLOGUE 32
    mov rbx, rdi
    mov rdi, rsp
    call fmt_u64
    mov r12, rax
    mov rdi, rbx
    mov rsi, rsp
    mov rdx, r12
    call memcpy
    lea rax, [rbx + r12]
    EPILOGUE

# st_u64_pad6(rdi=dst, rsi=value): six zero-padded digits + NUL.
st_u64_pad6:
    PROLOGUE 16
    mov rbx, rdi
    mov r8, rsi
    mov r9, 100000
    mov r10, 6
    mov r11, rbx
1:  mov rax, r8
    xor edx, edx
    div r9
    mov r8, rdx
    add al, '0'
    mov [r11], al
    inc r11
    mov rax, r9
    xor edx, edx
    mov rcx, 10
    div rcx
    mov r9, rax
    dec r10
    jnz 1b
    mov byte ptr [r11], 0
    mov rax, r11
    EPILOGUE

# st_fmt_think(rdi=buf): "think:" + ST_thinking.
st_fmt_think:
    PROLOGUE 0
    mov rbx, rdi
    # copy the 6 literal bytes through the rodata cstr
    lea rsi, [rip + .Lst_think_prefix]
    mov eax, [rsi]
    mov [rbx], eax
    mov ax, [rsi + 4]
    mov [rbx + 4], ax
    lea rsi, [rip + st_state + ST_thinking]
    xor ecx, ecx
1:  mov al, [rsi + rcx]
    test al, al
    jz 2f
    cmp ecx, 23
    jae 2f
    mov [rbx + 6 + rcx], al
    inc ecx
    jmp 1b
2:  mov byte ptr [rbx + 6 + rcx], 0
    EPILOGUE

# st_fmt_tok(rdi=buf): "tok:" + in + "/" + out.
st_fmt_tok:
    PROLOGUE 16
    mov rbx, rdi
    mov eax, 0x3a6b6f74          # "tok:"
    mov [rbx], eax
    lea rdi, [rbx + 4]
    mov rsi, [rip + st_state + ST_tok_in]
    call st_u64
    mov byte ptr [rax], '/'
    inc rax
    mov rdi, rax
    mov rsi, [rip + st_state + ST_tok_out]
    call st_u64
    mov byte ptr [rax], 0
    EPILOGUE

# st_fmt_cost(rdi=buf): "$<whole>.<frac 6>" for a known non-negative cost.
st_fmt_cost:
    PROLOGUE 16
    mov rbx, rdi
    mov rax, [rip + st_state + ST_cost_micro]
    mov rcx, 1000000
    xor edx, edx
    div rcx
    mov r12, rdx
    mov byte ptr [rbx], '$'
    lea rdi, [rbx + 1]
    mov rsi, rax
    call st_u64
    mov byte ptr [rax], '.'
    inc rax
    mov rdi, rax
    mov rsi, r12
    call st_u64_pad6
    EPILOGUE

# st_fmt_run(rdi=buf): spinner + elapsed.
st_fmt_run:
    PROLOGUE 32
    mov rbx, rdi
    mov eax, [rip + st_state + ST_spinner]
    and eax, 3
    lea rcx, [rip + .Lst_spin]
    mov al, [rcx + rax]
    mov [rbx], al
    mov byte ptr [rbx + 1], ' '
    lea r12, [rbx + 2]
    mov rax, [rip + st_state + ST_elapsed_ms]
    cmp rax, 1000
    jb .Lrun_ms
    mov rcx, 1000
    xor edx, edx
    div rcx
    mov r13, rdx
    mov rdi, r12
    mov rsi, rax
    call st_u64
    mov byte ptr [rax], '.'
    inc rax
    mov rdi, rax
    mov rax, r13
    xor edx, edx
    mov rcx, 100
    div rcx
    add al, '0'
    mov [rdi], al
    mov byte ptr [rdi + 1], 's'
    mov byte ptr [rdi + 2], 0
    EPILOGUE
.Lrun_ms:
    mov rdi, r12
    mov rsi, [rip + st_state + ST_elapsed_ms]
    call st_u64
    mov byte ptr [rax], 'm'
    mov byte ptr [rax + 1], 's'
    mov byte ptr [rax + 2], 0
    EPILOGUE

# The built-in provider: an ordinary provider, no privileged path.  Like every
# provider it follows the normal function ABI and preserves the callee-saved
# registers (rbx/rbp/r12-r15) across the callback.
FN status_builtin_provider
    PROLOGUE 16
    mov r12, rsi
    mov r13, rdx
    xor ebx, ebx
    lea rdi, [rip + st_state + ST_model]
    mov esi, SLOT_LEFT
    xor edx, edx
    xor ecx, ecx
    call st_emit
    lea rdi, [rip + st_buf_think]
    call st_fmt_think
    lea rdi, [rip + st_buf_think]
    mov esi, SLOT_LEFT
    mov edx, 10
    xor ecx, ecx
    call st_emit
    lea rdi, [rip + st_buf_tok]
    call st_fmt_tok
    lea rdi, [rip + st_buf_tok]
    mov esi, SLOT_LEFT
    mov edx, 20
    xor ecx, ecx
    call st_emit
    cmp qword ptr [rip + st_state + ST_cost_micro], 0
    jl 1f
    lea rdi, [rip + st_buf_cost]
    call st_fmt_cost
    lea rdi, [rip + st_buf_cost]
    mov esi, SLOT_LEFT
    mov edx, 30
    xor ecx, ecx
    call st_emit
1:  cmp dword ptr [rip + st_state + ST_running], 0
    je 2f
    lea rdi, [rip + st_buf_state]
    call st_fmt_run
    lea rdi, [rip + st_buf_state]
    mov esi, SLOT_RIGHT
    xor edx, edx
    mov ecx, STYLE_ACCENT
    call st_emit
    jmp 3f
2:  lea rdi, [rip + .Lst_ready]
    mov esi, SLOT_RIGHT
    xor edx, edx
    xor ecx, ecx
    call st_emit
3:  mov rax, rbx
    EPILOGUE

# ---------------------------------------------------------------- render
st_style_fg:
    test edi, STYLE_ACCENT
    jnz .Lsf_accent
    test edi, STYLE_ERROR
    jnz .Lsf_err
    test edi, STYLE_WARN
    jnz .Lsf_warn
    test edi, STYLE_OK
    jnz .Lsf_ok
    mov esi, TH_MUTED
    jmp theme_rgb
.Lsf_accent:
    mov esi, TH_ACCENT
    jmp theme_rgb
.Lsf_err:
    mov esi, TH_ERR
    jmp theme_rgb
.Lsf_warn:
    mov esi, TH_WARN
    jmp theme_rgb
.Lsf_ok:
    mov esi, TH_OK
    jmp theme_rgb

st_style_attrs:
    xor eax, eax
    test edi, STYLE_BOLD
    jz 1f
    or eax, 1
1:  test edi, STYLE_DIM
    jz 2f
    or eax, 4
2:  ret

# status_text_width(rdi=cstr) -> eax display columns.  The text has already
# been validated by status_copy, so pass the decoder the real remaining length.
status_text_width:
    PROLOGUE 16
    mov rbx, rdi
    xor r12d, r12d
    call strlen
    mov r13, rax                   # real remaining length
1:  test r13, r13
    jz 2f
    mov rdi, rbx
    mov rsi, r13
    call utf8_decode
    add rbx, rdx
    sub r13, rdx
    mov edi, eax
    call utf8_wcwidth
    add r12d, eax
    jmp 1b
2:  mov eax, r12d
    EPILOGUE

# status_slot_len(rdi=cache, esi=n, edx=slot) -> eax display width with " | ".
status_slot_len:
    PROLOGUE 32
    mov r12, rdi
    mov r13d, esi
    mov r14d, edx
    xor r15d, r15d
    mov dword ptr [rbp - 56], 0
    xor ebx, ebx
1:  cmp ebx, r13d
    jae 9f
    mov rax, rbx
    imul rax, rax, SV_SIZE
    add rax, r12
    cmp dword ptr [rax + SV_slot], r14d
    jne 2f
    lea rdi, [rax + SV_text]
    cmp byte ptr [rdi], 0
    je 2f
    cmp dword ptr [rbp - 56], 0
    je 3f
    add r15d, 3
3:  mov dword ptr [rbp - 56], 1
    call status_text_width
    add r15d, eax
2:  inc ebx
    jmp 1b
9:  mov eax, r15d
    EPILOGUE

# status_draw_text(rdi=grid, esi=x, edx=y, ecx=end, r8d=style, r9=text cstr)
# -> eax new x.  Draws sanitized, registry-validated UTF-8 one codepoint at a
# time and clips at `end` columns.
.set SD_text,   -56
.set SD_cp,     -64
.set SD_cons,   -72
.set SD_w,      -76
.set SD_fg,     -80
.set SD_attrs,  -84
.set SD_bg,     -88
.set SD_rem,    -96
status_draw_text:
    PROLOGUE 64
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    mov r15d, r8d
    mov [rbp + SD_text], r9
    mov rdi, r9
    call strlen
    mov [rbp + SD_rem], rax       # real remaining length
    mov edi, r15d
    call st_style_fg
    mov [rbp + SD_fg], eax
    mov edi, r15d
    call st_style_attrs
    mov [rbp + SD_attrs], eax
    mov esi, TH_BG
    call theme_rgb
    mov [rbp + SD_bg], eax
1:  cmp r12d, r14d
    jae 9f
    cmp qword ptr [rbp + SD_rem], 0
    jbe 9f
    mov rdi, [rbp + SD_text]
    mov rsi, [rbp + SD_rem]
    call utf8_decode
    test eax, eax
    jz 9f
    mov [rbp + SD_cp], eax
    mov [rbp + SD_cons], rdx
    mov edi, eax
    call utf8_wcwidth
    test eax, eax
    jnz 2f
    mov eax, 1
2:  mov [rbp + SD_w], eax
    mov rax, [rbp + SD_cons]
    add [rbp + SD_text], rax
    sub [rbp + SD_rem], rax
    mov rdi, rbx
    mov esi, r12d
    mov edx, r13d
    mov ecx, [rbp + SD_cp]
    mov r8d, [rbp + SD_fg]
    mov r9d, [rbp + SD_bg]
    sub rsp, 16
    mov eax, [rbp + SD_attrs]
    mov [rsp], eax
    call grid_put
    add rsp, 16
    mov eax, [rbp + SD_w]
    add r12d, eax
    jmp 1b
9:  mov eax, r12d
    EPILOGUE

# status_draw_slot(rdi=cache, esi=n, edx=slot, ecx=x, r8d=limit) -> eax new x.
# st_rgrid/st_rrow carry the target set by status_render.
.set DS_entry, -56
.set DS_end,   -64
.set DS_first, -68
.set DS_style, -72
status_draw_slot:
    PROLOGUE 32
    mov r12, rdi
    mov r13d, esi
    mov r14d, edx
    mov r15d, ecx
    mov eax, ecx
    add eax, r8d
    mov [rbp + DS_end], eax
    mov dword ptr [rbp + DS_first], 0
    xor ebx, ebx
1:  cmp ebx, r13d
    jae 9f
    mov rax, rbx
    imul rax, rax, SV_SIZE
    add rax, r12
    mov [rbp + DS_entry], rax
    cmp dword ptr [rax + SV_slot], r14d
    jne 2f
    lea rdi, [rax + SV_text]
    cmp byte ptr [rdi], 0
    je 2f
    mov eax, [rax + SV_style]
    mov [rbp + DS_style], eax
    cmp dword ptr [rbp + DS_first], 0
    je 3f
    mov rdi, [rip + st_rgrid]
    mov esi, r15d
    mov edx, [rip + st_rrow]
    mov ecx, [rbp + DS_end]
    xor r8d, r8d
    lea r9, [rip + .Lst_sep]
    call status_draw_text
    mov r15d, eax
3:  mov dword ptr [rbp + DS_first], 1
    mov rax, [rbp + DS_entry]
    lea r9, [rax + SV_text]
    mov rdi, [rip + st_rgrid]
    mov esi, r15d
    mov edx, [rip + st_rrow]
    mov ecx, [rbp + DS_end]
    mov r8d, [rbp + DS_style]
    call status_draw_text
    mov r15d, eax
2:  inc ebx
    jmp 1b
9:  mov eax, r15d
    EPILOGUE

# status_render(rdi=grid, esi=row, edx=width): fill the footer band, join LEFT
# with " | ", right-align RIGHT; the right slot wins a full row and LEFT is
# clipped first.  Rebuilds the cached snapshot only when the version changes.
FN status_render
    PROLOGUE 64
    mov [rip + st_rgrid], rdi
    mov [rip + st_rrow], esi
    mov [rbp - 56], edx
    call status_version
    cmp rax, [rip + st_cache_ver]
    je 1f
    mov [rip + st_cache_ver], rax
    lea rdi, [rip + st_cache]
    mov esi, STATUS_MAX_SEGMENTS
    call status_snapshot
    mov [rip + st_cache_n], rax
1:  mov esi, TH_MUTED
    call theme_rgb
    mov r12d, eax
    mov esi, TH_BG
    call theme_rgb
    mov r13d, eax
    mov rdi, [rip + st_rgrid]
    xor esi, esi
    mov edx, [rip + st_rrow]
    mov ecx, [rbp - 56]
    mov r8d, 1
    mov r9d, 0x20
    sub rsp, 16
    mov [rsp], r12d
    mov [rsp + 8], r13d
    call grid_fill
    add rsp, 16
    lea rdi, [rip + st_cache]
    mov esi, [rip + st_cache_n]
    mov edx, SLOT_RIGHT
    call status_slot_len
    mov r12d, eax
    mov r13d, [rbp - 56]
    cmp r12d, r13d
    jl 2f
    lea rdi, [rip + st_cache]
    mov esi, [rip + st_cache_n]
    mov edx, SLOT_RIGHT
    xor ecx, ecx
    mov r8d, r13d
    call status_draw_slot
    xor eax, eax
    EPILOGUE
2:  mov r14d, r13d
    sub r14d, r12d
    dec r14d
    jle 3f
    lea rdi, [rip + st_cache]
    mov esi, [rip + st_cache_n]
    mov edx, SLOT_LEFT
    xor ecx, ecx
    mov r8d, r14d
    call status_draw_slot
3:  lea rdi, [rip + st_cache]
    mov esi, [rip + st_cache_n]
    mov edx, SLOT_RIGHT
    mov ecx, r13d
    sub ecx, r12d
    mov r8d, r12d
    call status_draw_slot
    xor eax, eax
    EPILOGUE
