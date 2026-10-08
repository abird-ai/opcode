.include "opcode.inc"
.include "tui/status.inc"
# status_test: S2 status segment registry.
#   - validation/drop of malformed segments (slot/style/empty/control)
#   - sort by (slot, priority, registration order)
#   - text clip to STATUS_TEXT_MAX-1
#   - version changes on register/invalidate/reset
#   - built-in cost omitted when unknown, rendered when known
#   - footer join + right-align + clip via status_render
# Golden: status_test.expected

.bss
.p2align 4
t_grid:  .zero 256
t_dump:  .zero SB_SIZE
t_snap:  .zero SV_SIZE * STATUS_MAX_SEGMENTS
t_state: .zero ST_SIZE
t_pout:  .quad 0
t_pmax:  .quad 0
t_pcount: .quad 0

.section .rodata
.Lnl:        .asciz "\n"
.Lm_model:   .asciz "M"
.Lm_think:   .asciz "off"
.La5:        .asciz "a5"
.La0:        .asciz "a0"
.Lra:        .asciz "right-a"
.Lb0:        .asciz "b0"
.Lrb:        .asciz "right-b"
.Lbadslot:   .asciz "bad-slot"
.Lbadstyle:  .asciz "bad-style"
.lempty:     .asciz ""
.Lctrl:      .byte 'a', 1, 'b', 0
.Llong:      .fill 200, 1, 0x78
             .byte 0
.Lp_count:   .asciz "count: "
.Lp_seg:     .asciz "seg "
.Lsp:        .asciz " "
.Lp_text:    .asciz "text: "
.Lp_len:     .asciz " len: "
.Lp_ver:     .asciz "version: "
.Lp_cost:    .asciz "cost: "
.Lp_dump20:  .asciz "dump20: "
.Lp_dump4:   .asciz "dump4: "
.Lm_ok:      .asciz "status ok\n"
.Lm_fail:    .asciz "status FAIL\n"

.text

print:
    push rdi
    call strlen
    pop rdi
    mov rdx, rax
    mov rsi, rdi
    mov edi, 1
    jmp write_all

print_n:
    mov rdx, rsi
    mov rsi, rdi
    mov edi, 1
    jmp write_all

# p_snum(label, value)
p_snum:
    push rbx
    push r12
    sub rsp, 40
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rbx
    call print
    mov rax, r12
    test rax, rax
    jns 1f
    mov byte ptr [rsp], '-'
    mov edi, 1
    lea rsi, [rsp]
    mov edx, 1
    call write_all
    mov rax, r12
    neg rax
1:  lea rdi, [rsp]
    mov rsi, rax
    call fmt_u64
    lea rdi, [rsp]
    mov rsi, rax
    call print_n
    lea rdi, [rip + .Lnl]
    call print
    add rsp, 40
    pop r12
    pop rbx
    ret

# t_add(rdi=text, esi=slot, edx=prio, ecx=style): append to the provider output.
t_add:
    mov r8, [rip + t_pcount]
    cmp r8, [rip + t_pmax]
    jae 9f
    mov rax, r8
    imul rax, rax, SEG_SIZE
    add rax, [rip + t_pout]
    mov dword ptr [rax + SEG_struct_size], SEG_SIZE
    mov [rax + SEG_slot], esi
    mov [rax + SEG_priority], edx
    mov [rax + SEG_style], ecx
    mov [rax + SEG_text], rdi
    inc r8
    mov [rip + t_pcount], r8
9:  ret

# provider A: LEFT 5 "a5", LEFT 0 "a0", RIGHT 0 "right-a"
prov_a:
    PROLOGUE 0
    mov [rip + t_pout], rsi
    mov [rip + t_pmax], rdx
    mov qword ptr [rip + t_pcount], 0
    lea rdi, [rip + .La5]
    mov esi, SLOT_LEFT
    mov edx, 5
    xor ecx, ecx
    call t_add
    lea rdi, [rip + .La0]
    mov esi, SLOT_LEFT
    xor edx, edx
    xor ecx, ecx
    call t_add
    lea rdi, [rip + .Lra]
    mov esi, SLOT_RIGHT
    xor edx, edx
    xor ecx, ecx
    call t_add
    mov rax, [rip + t_pcount]
    EPILOGUE

# provider B: LEFT 0 "b0", malformed (slot/style/empty/control), RIGHT "right-b",
# LEFT 50 long text.
prov_b:
    PROLOGUE 0
    mov [rip + t_pout], rsi
    mov [rip + t_pmax], rdx
    mov qword ptr [rip + t_pcount], 0
    lea rdi, [rip + .Lb0]
    mov esi, SLOT_LEFT
    xor edx, edx
    xor ecx, ecx
    call t_add
    lea rdi, [rip + .Lbadslot]
    mov esi, 2
    xor edx, edx
    xor ecx, ecx
    call t_add
    lea rdi, [rip + .Lbadstyle]
    mov esi, SLOT_LEFT
    xor edx, edx
    mov ecx, 0x40
    call t_add
    lea rdi, [rip + .lempty]
    mov esi, SLOT_LEFT
    xor edx, edx
    xor ecx, ecx
    call t_add
    lea rdi, [rip + .Lctrl]
    mov esi, SLOT_LEFT
    xor edx, edx
    xor ecx, ecx
    call t_add
    lea rdi, [rip + .Lrb]
    mov esi, SLOT_RIGHT
    xor edx, edx
    xor ecx, ecx
    call t_add
    lea rdi, [rip + .Llong]
    mov esi, SLOT_LEFT
    mov edx, 50
    xor ecx, ecx
    call t_add
    mov rax, [rip + t_pcount]
    EPILOGUE

# p_num(rdi=value): print a signed decimal with no label or newline.
p_num:
    PROLOGUE 40
    test rdi, rdi
    jns 1f
    mov byte ptr [rsp], '-'
    mov edi, 1
    lea rsi, [rsp]
    mov edx, 1
    call write_all
    mov rax, rdi
    neg rax
    jmp 2f
1:  mov rax, rdi
2:  lea rdi, [rsp]
    mov rsi, rax
    call fmt_u64
    lea rdi, [rsp]
    mov rsi, rax
    call print_n
    EPILOGUE

# p_seg(rdi=SV*): "seg <slot> <prio> <seq> len <len> <text>\n"
p_seg:
    PROLOGUE 16
    mov rbx, rdi
    lea rdi, [rip + .Lp_seg]
    call print
    movsxd rdi, dword ptr [rbx + SV_slot]
    call p_num
    lea rdi, [rip + .Lsp]
    call print
    movsxd rdi, dword ptr [rbx + SV_priority]
    call p_num
    lea rdi, [rip + .Lsp]
    call print
    mov rdi, [rbx + SV_seq]
    call p_num
    lea rdi, [rip + .Lp_len]
    call print
    lea rdi, [rbx + SV_text]
    call strlen
    mov r12, rax
    mov rdi, r12
    call p_num
    lea rdi, [rip + .Lsp]
    call print
    lea rdi, [rbx + SV_text]
    mov rsi, r12
    call print_n
    lea rdi, [rip + .Lnl]
    call print
    EPILOGUE

# p_seg_find(rdi=cache, esi=count, edx=slot, ecx=prio) -> rax SV*|0
p_seg_find:
    xor eax, eax
1:  cmp eax, esi
    jae 3f
    mov r8, rax
    imul r8, r8, SV_SIZE
    add r8, rdi
    cmp dword ptr [r8 + SV_slot], edx
    jne 2f
    cmp dword ptr [r8 + SV_priority], ecx
    je 4f
2:  inc eax
    jmp 1b
3:  xor eax, eax
    ret
4:  mov rax, r8
    ret

FN opcode_main
    PROLOGUE 16
    # ---- built-in: cost unknown -> omitted -------------------------------
    call status_reset
    call status_register_builtin
    lea rdi, [rip + t_state]
    xor esi, esi
    mov edx, ST_SIZE
    call memset
    mov byte ptr [rip + t_state + ST_model], 'M'
    mov dword ptr [rip + t_state + ST_thinking], 0x0066666f   # "off"
    mov qword ptr [rip + t_state + ST_tok_in], 1
    mov qword ptr [rip + t_state + ST_tok_out], 2
    mov qword ptr [rip + t_state + ST_cost_micro], -1
    lea rdi, [rip + t_state]
    call status_builtin_set
    lea rdi, [rip + t_snap]
    mov esi, STATUS_MAX_SEGMENTS
    call status_snapshot
    mov r12, rax
    mov rsi, r12
    lea rdi, [rip + .Lp_count]
    call p_snum
    cmp r12, 4
    jne .Lfail
    # cost segment must be absent
    lea rdi, [rip + t_snap]
    mov esi, r12d
    mov edx, SLOT_LEFT
    mov ecx, 30
    call p_seg_find
    test rax, rax
    jnz .Lfail

    # ---- cost known -> "$1.234567" ---------------------------------------
    mov qword ptr [rip + t_state + ST_cost_micro], 1234567
    lea rdi, [rip + t_state]
    call status_builtin_set
    lea rdi, [rip + t_snap]
    mov esi, STATUS_MAX_SEGMENTS
    call status_snapshot
    mov r12, rax
    cmp r12, 5
    jne .Lfail
    lea rdi, [rip + t_snap]
    mov esi, r12d
    mov edx, SLOT_LEFT
    mov ecx, 30
    call p_seg_find
    test rax, rax
    jz .Lfail
    mov r13, rax
    lea rdi, [rip + .Lp_cost]
    call print
    lea rdi, [r13 + SV_text]
    call print
    lea rdi, [rip + .Lnl]
    call print

    # ---- render: join + right-align + clip -------------------------------
    mov qword ptr [rip + t_state + ST_cost_micro], -1
    lea rdi, [rip + t_state]
    call status_builtin_set
    lea rdi, [rip + t_grid]
    mov esi, 20
    mov edx, 1
    call grid_init
    lea rdi, [rip + t_grid]
    xor esi, esi
    mov edx, 20
    call status_render
    lea rdi, [rip + t_dump]
    call sb_clear
    lea rdi, [rip + t_grid]
    lea rsi, [rip + t_dump]
    call render_dump
    lea rdi, [rip + .Lp_dump20]
    call print
    mov rsi, [rip + t_dump + SB_len]
    mov rdi, [rip + t_dump + SB_ptr]
    call print_n
    lea rdi, [rip + .Lnl]
    call print
    lea rdi, [rip + t_grid]
    call grid_free
    # width 4: right slot alone owns/ is clipped
    lea rdi, [rip + t_grid]
    mov esi, 4
    mov edx, 1
    call grid_init
    lea rdi, [rip + t_grid]
    xor esi, esi
    mov edx, 4
    call status_render
    lea rdi, [rip + t_dump]
    call sb_clear
    lea rdi, [rip + t_grid]
    lea rsi, [rip + t_dump]
    call render_dump
    lea rdi, [rip + .Lp_dump4]
    call print
    mov rsi, [rip + t_dump + SB_len]
    mov rdi, [rip + t_dump + SB_ptr]
    call print_n
    lea rdi, [rip + .Lnl]
    call print

    # ---- registry ordering + malformed drops -----------------------------
    call status_reset
    call status_version
    mov r12, rax
    lea rdi, [rip + prov_a]
    xor esi, esi
    call status_register
    lea rdi, [rip + prov_b]
    xor esi, esi
    call status_register
    call status_version
    mov r13, rax
    cmp r13, r12
    jbe .Lfail
    lea rdi, [rip + t_snap]
    mov esi, STATUS_MAX_SEGMENTS
    call status_snapshot
    mov r12, rax
    cmp r12, 6
    jne .Lfail
    mov rsi, r12
    lea rdi, [rip + .Lp_count]
    call p_snum
    xor ebx, ebx
1:  cmp ebx, r12d
    jae 2f
    mov rax, rbx
    imul rax, rax, SV_SIZE
    lea rdi, [rip + t_snap]
    add rdi, rax
    call p_seg
    inc ebx
    jmp 1b
2:  # long text clipped to 191 bytes
    lea rdi, [rip + t_snap]
    mov esi, r12d
    mov edx, SLOT_LEFT
    mov ecx, 50
    call p_seg_find
    test rax, rax
    jz .Lfail
    lea rdi, [rax + SV_text]
    call strlen
    cmp rax, 191
    jne .Lfail

    # ---- version: invalidate / reset -------------------------------------
    call status_version
    mov r13, rax
    call status_invalidate
    call status_version
    cmp rax, r13
    jle .Lfail
    mov r13, rax
    call status_reset
    call status_version
    cmp rax, r13
    jle .Lfail
    mov rsi, rax
    lea rdi, [rip + .Lp_ver]
    call p_snum

    lea rdi, [rip + .Lm_ok]
    call print
    xor eax, eax
    EPILOGUE

.Lfail:
    lea rdi, [rip + .Lm_fail]
    call print
    mov eax, 1
    EPILOGUE
