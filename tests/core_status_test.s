.include "opcode.inc"
.include "core/core.inc"
# core_status_test: S2 core accessors.
#   - thinking level setter/name/parse
#   - agent_usage_totals over a transcript
#   - agent_model_ctx_window + agent_set_model accept/reject
#   - skills_list/skills_at/skill_body and prompt_templates_count/at
# Builds a fake config tree under build/cs_tree.  Golden: core_status_test.expected

.bss
.p2align 3
t_out:  .zero SB_SIZE
t_out2: .zero SB_SIZE
t_usage: .zero USAGE_SIZE

.section .rodata
.Ld_build:  .asciz "build"
.Ld_root:   .asciz "build/cs_tree"
.Ld_cfg:    .asciz "build/cs_tree/config"
.Ld_prompts: .asciz "build/cs_tree/config/prompts"
.Ld_skills: .asciz "build/cs_tree/config/skills"
.Ld_alpha:  .asciz "build/cs_tree/config/skills/alpha"
.Lf_alpha:  .asciz "build/cs_tree/config/skills/alpha/SKILL.md"
.Lc_alpha:  .asciz "---\nname: alpha\ndescription: Alpha skill\n---\nBody alpha.\n"
.Lf_beta:   .asciz "build/cs_tree/config/skills/beta.md"
.Lc_beta:   .asciz "---\nname: beta\ndescription: Beta skill\n---\nBody beta.\n"
.Lf_hello:  .asciz "build/cs_tree/config/prompts/hello.md"
.Lc_hello:  .asciz "---\ndescription: Greet\n---\nHello $1\n"

.Lcfg:      .asciz "build/cs_tree/config"
.Lid_slash: .asciz "anthropic/claude-sonnet-4-5"
.Lid_bare:  .asciz "claude-haiku-4-5"
.Lid_bad:   .asciz "definitely-not-a-real-model"
.Lname_medium: .asciz "medium"
.Lname_high:   .asciz "high"
.Lname_off:    .asciz "off"
.Lname_low:    .asciz "low"
.Lname_bogus:  .asciz "bogus"
.Lname_alpha:  .asciz "alpha"
.Lname_beta:   .asciz "beta"
.Lname_nope:   .asciz "nope"
.Lname_hello:  .asciz "hello"
.Lbody_alpha:  .asciz "Body alpha.\n"
.Lbody_beta:   .asciz "Body beta.\n"
.Lempty:       .asciz ""
.Lnl:          .asciz "\n"

.Lp_think0:  .asciz "think initial: "
.Lp_think1:  .asciz "think medium: "
.Lp_think2:  .asciz "think high: "
.Lp_used:    .asciz "usage total: "
.Lp_ctx:     .asciz "ctx window: "
.Lp_model:   .asciz "model: "
.Lp_bare:    .asciz "model bare: "
.Lp_reject:  .asciz "model reject: "
.Lp_skcount: .asciz "skills count: "
.Lp_sk0:     .asciz "skill 0: "
.Lp_sk1:     .asciz "skill 1: "
.Lp_body0:   .asciz "body 0: "
.Lp_body1:   .asciz "body 1: "
.Lp_skmiss:  .asciz "skill missing: "
.Lp_tplcount: .asciz "templates: "
.Lp_tpl0:    .asciz "template 0: "
.Lm_ok:      .asciz "core_status ok\n"
.Lm_fail:    .asciz "core_status FAIL\n"

.section .data
.p2align 3
t_u1:
    .long 10, 5, 2, 3, 0, 0
t_u2:
    .long 3, 4, 1, 1, 0, 0

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

# print_n(ptr, len)
print_n:
    mov rdx, rsi
    mov rsi, rdi
    mov edi, 1
    jmp write_all

# p_snum(label cstr rdi, value rsi): "label<decimal>\n"
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

# p_str(label cstr rdi, value cstr rsi): "label<value>\n"
p_str:
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rbx
    call print
    mov rdi, r12
    call print
    lea rdi, [rip + .Lnl]
    call print
    pop r12
    pop rbx
    ret

# t_mkdir(path)
t_mkdir:
    mov esi, 0755
    jmp os_mkdir

# t_write(path cstr, content cstr)
t_write:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rsi
    mov esi, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC
    mov edx, 0644
    call os_open
    test rax, rax
    js .Ltw_done
    mov r12d, eax
    mov rdi, rbx
    call strlen
    mov rdx, rax
    mov rsi, rbx
    mov edi, r12d
    call write_all
    mov edi, r12d
    call os_close
.Ltw_done:
    add rsp, 8
    pop r12
    pop rbx
    ret

# cstr_eq(a, b) -> 1|0
cstr_eq:
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

FN opcode_main
    PROLOGUE

    # ---- fake config tree ------------------------------------------------
    lea rdi, [rip + .Ld_build]
    call t_mkdir
    lea rdi, [rip + .Ld_root]
    call t_mkdir
    lea rdi, [rip + .Ld_cfg]
    call t_mkdir
    lea rdi, [rip + .Ld_prompts]
    call t_mkdir
    lea rdi, [rip + .Ld_skills]
    call t_mkdir
    lea rdi, [rip + .Ld_alpha]
    call t_mkdir
    lea rdi, [rip + .Lf_alpha]
    lea rsi, [rip + .Lc_alpha]
    call t_write
    lea rdi, [rip + .Lf_beta]
    lea rsi, [rip + .Lc_beta]
    call t_write
    lea rdi, [rip + .Lf_hello]
    lea rsi, [rip + .Lc_hello]
    call t_write
    lea rax, [rip + .Lcfg]
    mov [rip + g_config_home], rax
    mov qword ptr [rip + g_config_approve], 1

    # ---- thinking --------------------------------------------------------
    call agent_thinking
    mov esi, eax
    call agent_thinking_name
    mov rsi, rax
    lea rdi, [rip + .Lp_think0]
    call p_str

    mov esi, TH_MEDIUM
    call agent_set_thinking
    call agent_thinking
    cmp eax, TH_MEDIUM
    jne .Lfail
    mov esi, eax
    call agent_thinking_name
    mov rsi, rax
    lea rdi, [rip + .Lp_think1]
    call p_str

    mov esi, TH_HIGH
    call agent_thinking_name
    mov rsi, rax
    lea rdi, [rip + .Lp_think2]
    call p_str

    lea rdi, [rip + .Lname_low]
    call agent_thinking_parse
    cmp eax, TH_LOW
    jne .Lfail
    lea rdi, [rip + .Lname_bogus]
    call agent_thinking_parse
    cmp eax, -1
    jne .Lfail

    # ---- usage totals ----------------------------------------------------
    call agent_transcript
    mov rdi, rax
    call tr_init
    mov edi, MR_ASSISTANT
    call msg_new
    mov rbx, rax
    mov rdi, rbx
    lea rsi, [rip + t_u1]
    call msg_set_usage
    call agent_transcript
    mov rdi, rax
    mov rsi, rbx
    call tr_push
    mov edi, MR_ASSISTANT
    call msg_new
    mov rbx, rax
    mov rdi, rbx
    lea rsi, [rip + t_u2]
    call msg_set_usage
    call agent_transcript
    mov rdi, rax
    mov rsi, rbx
    call tr_push
    lea rdi, [rip + t_usage]
    call agent_usage_totals
    mov esi, [rip + t_usage + USG_total]
    lea rdi, [rip + .Lp_used]
    call p_snum
    cmp dword ptr [rip + t_usage + USG_input], 13
    jne .Lfail
    cmp dword ptr [rip + t_usage + USG_output], 9
    jne .Lfail
    cmp dword ptr [rip + t_usage + USG_cache_read], 3
    jne .Lfail
    cmp dword ptr [rip + t_usage + USG_cache_write], 4
    jne .Lfail

    # ---- model switch + context window -----------------------------------
    xor edi, edi
    lea rsi, [rip + .Lid_slash]
    call agent_set_model
    test eax, eax
    jnz .Lfail
    call agent_model_ctx_window
    cmp eax, 200000
    jne .Lfail
    mov esi, eax
    lea rdi, [rip + .Lp_ctx]
    call p_snum
    call agent_model_id
    mov rsi, rax
    lea rdi, [rip + .Lp_model]
    call p_str

    xor edi, edi
    lea rsi, [rip + .Lid_bare]
    call agent_set_model
    test eax, eax
    jnz .Lfail
    call agent_model_id
    mov rsi, rax
    lea rdi, [rip + .Lp_bare]
    call p_str

    xor edi, edi
    lea rsi, [rip + .Lid_bad]
    call agent_set_model
    cmp eax, -EINVAL
    jne .Lfail
    movsxd rsi, eax
    lea rdi, [rip + .Lp_reject]
    call p_snum
    call agent_model_id
    mov rdi, rax
    lea rsi, [rip + .Lid_bare]     # unchanged after the rejected switch
    call cstr_eq
    test eax, eax
    jz .Lfail

    # ---- skills ----------------------------------------------------------
    call skills_list
    cmp eax, 2
    jne .Lfail
    mov esi, eax
    lea rdi, [rip + .Lp_skcount]
    call p_snum

    mov edi, 0
    call skills_at
    mov rbx, rax
    mov rsi, rbx
    lea rdi, [rip + .Lp_sk0]
    call p_str
    mov rdi, rbx
    lea rsi, [rip + .Lname_alpha]
    call cstr_eq
    test eax, eax
    jz .Lfail

    mov edi, 1
    call skills_at
    mov rbx, rax
    mov rsi, rbx
    lea rdi, [rip + .Lp_sk1]
    call p_str
    mov rdi, rbx
    lea rsi, [rip + .Lname_beta]
    call cstr_eq
    test eax, eax
    jz .Lfail

    mov edi, 2
    call skills_at
    test rax, rax
    jnz .Lfail

    lea rdi, [rip + .Lname_alpha]
    lea rsi, [rip + t_out]
    call skill_body
    test eax, eax
    jnz .Lfail
    lea rdi, [rip + .Lp_body0]
    call print
    mov rdi, [rip + t_out + SB_ptr]
    call print
    mov rdi, [rip + t_out + SB_ptr]
    lea rsi, [rip + .Lbody_alpha]
    call cstr_eq
    test eax, eax
    jz .Lfail

    lea rdi, [rip + .Lname_beta]
    lea rsi, [rip + t_out2]
    call skill_body
    test eax, eax
    jnz .Lfail
    lea rdi, [rip + .Lp_body1]
    call print
    mov rdi, [rip + t_out2 + SB_ptr]
    call print
    mov rdi, [rip + t_out2 + SB_ptr]
    lea rsi, [rip + .Lbody_beta]
    call cstr_eq
    test eax, eax
    jz .Lfail

    lea rdi, [rip + .Lname_nope]
    lea rsi, [rip + t_out]
    call skill_body
    cmp eax, -ENOENT
    jne .Lfail
    movsxd rsi, eax
    lea rdi, [rip + .Lp_skmiss]
    call p_snum

    # ---- prompt templates ------------------------------------------------
    call prompt_templates_init
    call prompt_templates_count
    cmp eax, 1
    jne .Lfail
    mov esi, eax
    lea rdi, [rip + .Lp_tplcount]
    call p_snum
    mov edi, 0
    call prompt_templates_at
    mov rbx, rax
    mov rsi, rbx
    lea rdi, [rip + .Lp_tpl0]
    call p_str
    mov rdi, rbx
    lea rsi, [rip + .Lname_hello]
    call cstr_eq
    test eax, eax
    jz .Lfail

    lea rdi, [rip + .Lm_ok]
    call print
    xor eax, eax
    EPILOGUE

.Lfail:
    lea rdi, [rip + .Lm_fail]
    call print
    mov eax, 1
    EPILOGUE
