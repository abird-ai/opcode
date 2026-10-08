.include "opcode.inc"
.include "core/core.inc"
# prompt.s: system prompt builder, project context, skills and prompt templates.
# Contract: core/API.md (M3).
#
# prompt_build(sb, tools VEC* of TL*, cwd cstr) -> 0|-EINVAL
#   Sections, in order: preamble (SYSTEM.md or the built-in), "# Tools" lines,
#   "# Rules", addendum (APPEND_SYSTEM.md), project_context (context files from
#   the config dir and every cwd ancestor, nearest last), skills
#   (<available_skills>), "# Environment" (cwd + platform + date). Output ends
#   with "\n".  The environment block stays last because cwd, platform and the
#   UTC date are the turn-varying facts (ADR-8/T3, ADR-12).
# prompt_templates_init() -> 0
# prompt_template_expand(name cstr, args cstr, out SB*) -> 0|-ENOENT
#
# Project resources under <cwd>/.opcode load only when config_trusted(cwd);
# context files (AGENTS.override.md, AGENTS.md, OPCODE.md, CLAUDE.md) are not
# trust-gated. Unknown/unreadable files are skipped silently. Single-threaded:
# scan tables and scratch paths are static and reused per call.

.equ PC_PATHMAX,    8192
.equ PC_FMMAX,      8192
.equ PC_MAX_SKILLS, 64
.equ PC_SK_ENTRY,   24
.equ PC_MAX_TPLS,   64
.equ PC_TP_ENTRY,   24
.equ PC_SKILL_MAX,  262144      # 256 KiB: opcode's skill-submit cap
.equ DT_UNKNOWN,    0
.equ DT_DIR,        4
.equ DT_REG,        8

# local (non-exported) function: same body as FN, no .globl
.macro LFN name
    .text
    GTYPE \name, @function
    .p2align 4
\name:
.endm

.bss
.p2align 3
pc_home_buf:  .zero PC_PATHMAX
pc_path_buf:  .zero PC_PATHMAX
pc_dir_buf:   .zero PC_PATHMAX
pc_cwd_buf:   .zero PC_PATHMAX
pc_fm_buf:    .zero PC_FMMAX
pc_sk_count:  .zero 8
pc_sk_tab:    .zero PC_MAX_SKILLS * PC_SK_ENTRY
pc_tp_count:  .zero 8
pc_tp_tab:    .zero PC_MAX_TPLS * PC_TP_ENTRY

.section .data
.p2align 3
# Test seam: when non-zero, prompt_build uses this cstr as the platform name
# instead of os_platform(), so one golden fixture serves every target.
.globl g_prompt_platform
GTYPE g_prompt_platform, @object
g_prompt_platform:
    .quad 0
GSIZE g_prompt_platform, 8

# Test seam: when non-zero, prompt_build uses this cstr as the date instead of
# the real UTC clock, so one golden fixture serves every target and every day.
.globl g_prompt_date
GTYPE g_prompt_date, @object
g_prompt_date:
    .quad 0
GSIZE g_prompt_date, 8

.section .rodata
.LS_system:      .asciz "SYSTEM.md"
.LS_append:      .asciz "APPEND_SYSTEM.md"
.LS_opcode_append: .asciz ".opcode/APPEND_SYSTEM.md"
.LS_opcode_skills: .asciz ".opcode/skills"
.LS_opcode_prompts: .asciz ".opcode/prompts"
.LS_skills:      .asciz "skills"
.LS_prompts:     .asciz "prompts"
.LS_skill_md:    .asciz "SKILL.md"
.LS_c_agents_override: .asciz "AGENTS.override.md"
.LS_c_agents:    .asciz "AGENTS.md"
.LS_c_opcode:    .asciz "OPCODE.md"
.LS_c_claude:    .asciz "CLAUDE.md"
.p2align 3
.LS_ctx_names:
    .quad .LS_c_agents_override
    .quad .LS_c_agents
    .quad .LS_c_opcode
    .quad .LS_c_claude
.LS_builtin:
    .ascii "You are Opcode, a minimal coding agent working directly in the user's environment.\n"
    .asciz "Use the provided tools to inspect and modify files; keep changes focused and verify your work.\n"
.LS_tools:       .asciz "\n# Tools\n"
.LS_colon:       .asciz ": "
.LS_nl:          .asciz "\n"
.LS_rules:
    .ascii "\n# Rules\n"
    .ascii "- Prefer the provided tools over guessing; never invent tool output.\n"
    .ascii "- Read a file before editing it; edit with exact, unique old text.\n"
    .ascii "- Prefer small, targeted commands; report failures instead of guessing, and say what the next step is.\n"
    .asciz "- Keep answers short and direct.\n"
.LS_env:         .asciz "\n# Environment\n- cwd: "
.LS_env_plat:    .asciz "\n- platform: "
.LS_env_date:    .asciz "\n- date: "
.LS_add_pre:     .asciz "\n<addendum>\n"
.LS_add_suf:     .asciz "</addendum>\n"
.LS_ctx_pre:     .asciz "\n<project_instructions path=\""
.LS_ctx_mid:     .asciz "\">\n"
.LS_ctx_suf:     .asciz "</project_instructions>\n"
.LS_sk_open:     .asciz "\n<available_skills>\n"
.LS_sk_instr:    .asciz "The following skills provide specialized instructions. Read a skill's file when its description matches the task.\n"
.LS_sk_close:    .asciz "</available_skills>\n"
.LS_sk_lt:       .asciz "<skill name=\""
.LS_sk_lt2:      .asciz "\" location=\""
.LS_sk_gt:       .asciz "\">"
.LS_sk_end:      .asciz "</skill>\n"
.LS_empty:       .asciz ""
.LS_dollar:      .asciz "$"
.LS_arguments:   .asciz "ARGUMENTS"
.LS_k_name:      .asciz "name"
.LS_k_desc:      .asciz "description"
.LS_xdg:         .asciz "XDG_CONFIG_HOME"
.LS_home:        .asciz "HOME"
.LS_dotcfg:      .asciz ".config"
.LS_opcode:      .asciz "opcode"

.text

# ------------------------------------------------------------------ small helpers

# pc_getenv(name cstr) -> value cstr | 0
LFN pc_getenv
    test rdi, rdi
    jz .Lge_none
    PROLOGUE
    mov rbx, rdi
    call strlen
    mov r12, rax
    mov r13, [rip + g_envp]
    test r13, r13
    jz .Lge_no
.Lge_loop:
    mov r14, [r13]
    test r14, r14
    jz .Lge_no
    xor ecx, ecx
.Lge_cmp:
    cmp rcx, r12
    jae .Lge_prefix
    mov al, [r14 + rcx]
    cmp al, [rbx + rcx]
    jne .Lge_next
    test al, al
    jz .Lge_next
    inc rcx
    jmp .Lge_cmp
.Lge_prefix:
    cmp byte ptr [r14 + r12], '='
    jne .Lge_next
    lea rax, [r14 + r12 + 1]
    EPILOGUE
.Lge_next:
    add r13, 8
    jmp .Lge_loop
.Lge_no:
    xor eax, eax
    EPILOGUE
.Lge_none:
    xor eax, eax
    ret

# pc_config_home() -> cstr | 0: g_config_home, else $XDG_CONFIG_HOME/opcode,
# else $HOME/.config/opcode. The computed path lives in pc_home_buf.
LFN pc_config_home
    mov rax, [rip + g_config_home]
    test rax, rax
    jnz .Lch_leaf
    PROLOGUE
    lea rdi, [rip + .LS_xdg]
    call pc_getenv
    test rax, rax
    jz .Lch_home
    cmp byte ptr [rax], 0
    je .Lch_home
    mov rsi, rax
    lea rdi, [rip + pc_home_buf]
    lea rdx, [rip + .LS_opcode]
    call pc_join_cstr
    test rax, rax
    jnz .Lch_out
.Lch_home:
    lea rdi, [rip + .LS_home]
    call pc_getenv
    test rax, rax
    jz .Lch_zero
    cmp byte ptr [rax], 0
    je .Lch_zero
    mov rsi, rax
    lea rdi, [rip + pc_home_buf]
    lea rdx, [rip + .LS_dotcfg]
    call pc_join_cstr
    test rax, rax
    jz .Lch_zero
    lea rdi, [rip + pc_home_buf]
    mov rsi, rdi
    lea rdx, [rip + .LS_opcode]
    call pc_join_cstr
    test rax, rax
    jnz .Lch_out
.Lch_zero:
    xor eax, eax
.Lch_out:
    EPILOGUE
.Lch_leaf:
    ret

# pc_join_cstr(dst, dir cstr, name cstr) -> dst | 0
LFN pc_join_cstr
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, r12
    call strlen
    mov r14, rax
    mov rdi, r13
    call strlen
    mov r15, rax
    lea rax, [r14 + r15 + 2]
    cmp rax, PC_PATHMAX
    ja .Ljc_fail
    mov rdi, rbx
    mov rsi, r12
    mov rcx, r14
    rep movsb
    test r14, r14
    jz .Ljc_nosep
    cmp byte ptr [rdi - 1], '/'
    je .Ljc_nosep
    mov byte ptr [rdi], '/'
    inc rdi
.Ljc_nosep:
    mov rsi, r13
    mov rcx, r15
    rep movsb
    mov byte ptr [rdi], 0
    mov rax, rbx
    EPILOGUE
.Ljc_fail:
    xor eax, eax
    EPILOGUE

# pc_join_n(dst, dir ptr, dirlen, name cstr) -> dst | 0
LFN pc_join_n
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov rdi, r14
    call strlen
    mov r15, rax
    lea rax, [r13 + r15 + 2]
    cmp rax, PC_PATHMAX
    ja .Ljn_fail
    mov rdi, rbx
    mov rsi, r12
    mov rcx, r13
    rep movsb
    test r13, r13
    jz .Ljn_nosep
    cmp byte ptr [rdi - 1], '/'
    je .Ljn_nosep
    mov byte ptr [rdi], '/'
    inc rdi
.Ljn_nosep:
    mov rsi, r14
    mov rcx, r15
    rep movsb
    mov byte ptr [rdi], 0
    mov rax, rbx
    EPILOGUE
.Ljn_fail:
    xor eax, eax
    EPILOGUE

# pc_open(path cstr, flags) -> fd | -errno
LFN pc_open
    xor edx, edx
    jmp os_open

# pc_stream(fd, sb, max) -> 0|-errno: append up to max bytes (0 = EOF)
LFN pc_stream
    PROLOGUE PC_FMMAX
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    xor r15d, r15d
.Lst_loop:
    test r14, r14
    jz .Lst_full
    cmp r15, r14
    jae .Lst_done
    mov rbx, r14
    sub rbx, r15
    cmp rbx, PC_FMMAX
    jbe .Lst_read
    mov ebx, PC_FMMAX
    jmp .Lst_read
.Lst_full:
    mov ebx, PC_FMMAX
.Lst_read:
    mov edi, r12d
    mov rsi, rsp
    mov rdx, rbx
    call os_read
    test rax, rax
    js .Lst_err
    jz .Lst_done
    mov rbx, rax
    mov rdi, r13
    mov rsi, rsp
    mov rdx, rbx
    call sb_push
    add r15, rbx
    jmp .Lst_loop
.Lst_err:
    cmp rax, -EINTR
    je .Lst_loop
    EPILOGUE
.Lst_done:
    xor eax, eax
    EPILOGUE

# pc_read_file_sb(path cstr, sb, max) -> 0|-errno
LFN pc_read_file_sb
    PROLOGUE
    mov r12, rsi
    mov r13, rdx
    mov esi, O_RDONLY | O_CLOEXEC
    call pc_open
    test rax, rax
    js .Lrf_err
    mov rbx, rax
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call pc_stream
    mov r14, rax
    mov edi, ebx
    call os_close
    mov rax, r14
    EPILOGUE
.Lrf_err:
    EPILOGUE

# pc_read_prefix(path cstr, buf, max) -> len | -errno; NUL-terminated
LFN pc_read_prefix
    PROLOGUE
    mov r12, rsi
    mov r13, rdx
    mov esi, O_RDONLY | O_CLOEXEC
    call pc_open
    test rax, rax
    js .Lrp_err
    mov rbx, rax
    xor r14d, r14d
.Lrp_loop:
    cmp r14, r13
    jae .Lrp_done
    mov edi, ebx
    lea rsi, [r12 + r14]
    mov rdx, r13
    sub rdx, r14
    call os_read
    test rax, rax
    js .Lrp_err2
    jz .Lrp_done
    add r14, rax
    jmp .Lrp_loop
.Lrp_done:
    test r13, r13
    jz 2f                       # zero-size buffer: nothing to terminate
    cmp r14, r13
    jne 1f
    dec r14                     # keep room for the NUL inside the buffer
1:  mov byte ptr [r12 + r14], 0
2:  mov edi, ebx
    call os_close
    mov rax, r14
    EPILOGUE
.Lrp_err2:
    cmp rax, -EINTR
    je .Lrp_loop
    mov r14, rax
    mov edi, ebx
    call os_close
    mov rax, r14
    EPILOGUE
.Lrp_err:
    EPILOGUE

# pc_fm_field(buf, len, key cstr) -> rax=value ptr, rdx=value len | rax=0
# Parses the first "---\n...\n---" frontmatter block; a missing closing
# delimiter means "no frontmatter".
LFN pc_fm_field
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    cmp r13, 4
    jb .Lff_none
    cmp byte ptr [r12], '-'
    jne .Lff_none
    cmp byte ptr [r12 + 1], '-'
    jne .Lff_none
    cmp byte ptr [r12 + 2], '-'
    jne .Lff_none
    cmp byte ptr [r12 + 3], 10
    jne .Lff_none
    mov r15, 4
.Lff_close:
    mov rcx, r15
.Lff_c_nl:
    cmp rcx, r13
    jae .Lff_none
    cmp byte ptr [r12 + rcx], 10
    je .Lff_c_eol
    inc rcx
    jmp .Lff_c_nl
.Lff_c_eol:
    mov r8, rcx
    cmp r8, r15
    jbe .Lff_c_chk
    cmp byte ptr [r12 + r8 - 1], 13
    jne .Lff_c_chk
    dec r8
.Lff_c_chk:
    mov rax, r8
    sub rax, r15
    cmp rax, 3
    jne .Lff_c_next
    cmp byte ptr [r12 + r15], '-'
    jne .Lff_c_next
    cmp byte ptr [r12 + r15 + 1], '-'
    jne .Lff_c_next
    cmp byte ptr [r12 + r15 + 2], '-'
    jne .Lff_c_next
    jmp .Lff_parse
.Lff_c_next:
    lea r15, [rcx + 1]
    jmp .Lff_close
.Lff_parse:
    mov r8, 4
.Lff_line:
    cmp r8, r15
    jae .Lff_none
    mov rcx, r8
.Lff_l_nl:
    cmp rcx, r15
    jae .Lff_none
    cmp byte ptr [r12 + rcx], 10
    je .Lff_l_eol
    inc rcx
    jmp .Lff_l_nl
.Lff_l_eol:
    mov [rsp], rcx
    mov r9, rcx
    cmp r9, r8
    jbe .Lff_l_colon
    cmp byte ptr [r12 + r9 - 1], 13
    jne .Lff_l_colon
    dec r9
.Lff_l_colon:
    mov r10, r8
.Lff_l_c:
    cmp r10, r9
    jae .Lff_l_next
    cmp byte ptr [r12 + r10], ':'
    je .Lff_l_found
    inc r10
    jmp .Lff_l_c
.Lff_l_found:
    mov r11, r10
.Lff_k_trim:
    cmp r11, r8
    jbe .Lff_k_cmp
    movzx eax, byte ptr [r12 + r11 - 1]
    cmp al, ' '
    je .Lff_k_dec
    cmp al, 9
    jne .Lff_k_cmp
.Lff_k_dec:
    dec r11
    jmp .Lff_k_trim
.Lff_k_cmp:
    mov rdi, r12
    add rdi, r8
    mov rsi, r11
    sub rsi, r8
    mov rdx, r14
    call str_eq_cstr
    test eax, eax
    jz .Lff_l_next
    lea r11, [r10 + 1]
.Lff_v_skip:
    cmp r11, r9
    jae .Lff_v_trim
    movzx eax, byte ptr [r12 + r11]
    cmp al, ' '
    je .Lff_v_inc
    cmp al, 9
    jne .Lff_v_trim
.Lff_v_inc:
    inc r11
    jmp .Lff_v_skip
.Lff_v_trim:
    mov r10, r9
.Lff_v_t:
    cmp r10, r11
    jbe .Lff_v_ret
    movzx eax, byte ptr [r12 + r10 - 1]
    cmp al, ' '
    je .Lff_v_dec
    cmp al, 9
    jne .Lff_v_ret
.Lff_v_dec:
    dec r10
    jmp .Lff_v_t
.Lff_v_ret:
    lea rax, [r12 + r11]
    mov rdx, r10
    sub rdx, r11
    EPILOGUE
.Lff_l_next:
    mov r8, [rsp]
    inc r8
    jmp .Lff_line
.Lff_none:
    xor eax, eax
    xor edx, edx
    EPILOGUE

# pc_skip_fm(buf, len) -> rax=body ptr, rdx=body len
LFN pc_skip_fm
    cmp rsi, 4
    jb .Lsf_whole
    cmp byte ptr [rdi], '-'
    jne .Lsf_whole
    cmp byte ptr [rdi + 1], '-'
    jne .Lsf_whole
    cmp byte ptr [rdi + 2], '-'
    jne .Lsf_whole
    cmp byte ptr [rdi + 3], 10
    jne .Lsf_whole
    mov r8, 4
.Lsf_scan:
    mov rcx, r8
.Lsf_nl:
    cmp rcx, rsi
    jae .Lsf_whole
    cmp byte ptr [rdi + rcx], 10
    je .Lsf_eol
    inc rcx
    jmp .Lsf_nl
.Lsf_eol:
    mov r9, rcx
    cmp r9, r8
    jbe .Lsf_chk
    cmp byte ptr [rdi + r9 - 1], 13
    jne .Lsf_chk
    dec r9
.Lsf_chk:
    mov r10, r9
    sub r10, r8
    cmp r10, 3
    jne .Lsf_next
    cmp byte ptr [rdi + r8], '-'
    jne .Lsf_next
    cmp byte ptr [rdi + r8 + 1], '-'
    jne .Lsf_next
    cmp byte ptr [rdi + r8 + 2], '-'
    jne .Lsf_next
    lea rax, [rdi + rcx + 1]
    mov rdx, rsi
    sub rdx, rcx
    dec rdx
    ret
.Lsf_next:
    lea r8, [rcx + 1]
    jmp .Lsf_scan
.Lsf_whole:
    mov rax, rdi
    mov rdx, rsi
    ret

# pc_cstr_eq(a cstr, b cstr) -> 1 | 0
LFN pc_cstr_eq
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

# pc_cstr_cmp(a cstr, b cstr) -> -1 | 0 | 1
LFN pc_cstr_cmp
1:  movzx eax, byte ptr [rdi]
    movzx ecx, byte ptr [rsi]
    cmp eax, ecx
    jb 2f
    ja 3f
    test eax, eax
    jz 4f
    inc rdi
    inc rsi
    jmp 1b
2:  mov eax, -1
    ret
3:  mov eax, 1
    ret
4:  xor eax, eax
    ret

# pc_ensure_nl(sb): add "\n" unless the buffer already ends with one
LFN pc_ensure_nl
    mov rax, [rdi + SB_len]
    test rax, rax
    jz 1f
    mov rcx, [rdi + SB_ptr]
    cmp byte ptr [rcx + rax - 1], 10
    je 1f
    mov esi, 10
    jmp sb_push_byte
1:  xor eax, eax
    ret

# ------------------------------------------------------------------ file loading

# pc_try_preamble(sb, config cstr|0) -> 1 | 0. Reads <config>/SYSTEM.md; on
# failure the buffer is rolled back to its previous length.
LFN pc_try_preamble
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    test r13, r13
    jz .Lpr_no
    lea rdi, [rip + pc_path_buf]
    mov rsi, r13
    lea rdx, [rip + .LS_system]
    call pc_join_cstr
    test rax, rax
    jz .Lpr_no
    mov r14, [r12 + SB_len]
    mov rdi, rax
    mov rsi, r12
    xor edx, edx
    call pc_read_file_sb
    test rax, rax
    jz .Lpr_ok
    mov [r12 + SB_len], r14
    mov rax, [r12 + SB_ptr]
    test rax, rax
    jz .Lpr_no
    mov byte ptr [rax + r14], 0
.Lpr_no:
    xor eax, eax
    EPILOGUE
.Lpr_ok:
    mov eax, 1
    EPILOGUE

# pc_try_addendum(sb, path cstr) -> 1 | 0
LFN pc_try_addendum
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov rdi, r13
    mov esi, O_RDONLY | O_CLOEXEC
    call pc_open
    test rax, rax
    js .Lta_no
    mov rbx, rax
    mov r14, [r12 + SB_len]
    mov rdi, r12
    lea rsi, [rip + .LS_add_pre]
    call sb_push_cstr
    mov edi, ebx
    mov rsi, r12
    xor edx, edx
    call pc_stream
    mov r15, rax
    mov edi, ebx
    call os_close
    test r15, r15
    js .Lta_rb
    mov rdi, r12
    call pc_ensure_nl
    mov rdi, r12
    lea rsi, [rip + .LS_add_suf]
    call sb_push_cstr
    mov eax, 1
    EPILOGUE
.Lta_rb:
    mov [r12 + SB_len], r14
    mov rax, [r12 + SB_ptr]
    test rax, rax
    jz .Lta_no
    mov byte ptr [rax + r14], 0
.Lta_no:
    xor eax, eax
    EPILOGUE

# pc_try_context(sb, prefix ptr, prefixlen, filename cstr) -> 1 | 0
LFN pc_try_context
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    lea rdi, [rip + pc_path_buf]
    mov rsi, r13
    mov rdx, r14
    mov rcx, r15
    call pc_join_n
    test rax, rax
    jz .Lctx_no
    mov rdi, rax
    mov esi, O_RDONLY | O_CLOEXEC
    call pc_open
    test rax, rax
    js .Lctx_no
    mov rbx, rax
    mov r14, [r12 + SB_len]
    mov rdi, r12
    lea rsi, [rip + .LS_ctx_pre]
    call sb_push_cstr
    mov rdi, r12
    lea rsi, [rip + pc_path_buf]
    call sb_push_cstr
    mov rdi, r12
    lea rsi, [rip + .LS_ctx_mid]
    call sb_push_cstr
    mov edi, ebx
    mov rsi, r12
    xor edx, edx
    call pc_stream
    mov r15, rax
    mov edi, ebx
    call os_close
    test r15, r15
    js .Lctx_rb
    mov rdi, r12
    call pc_ensure_nl
    mov rdi, r12
    lea rsi, [rip + .LS_ctx_suf]
    call sb_push_cstr
    mov eax, 1
    EPILOGUE
.Lctx_rb:
    mov [r12 + SB_len], r14
    mov rax, [r12 + SB_ptr]
    test rax, rax
    jz .Lctx_no
    mov byte ptr [rax + r14], 0
.Lctx_no:
    xor eax, eax
    EPILOGUE

# pc_check_dir(sb, prefix ptr, prefixlen): first of the four context files
# found in the directory is appended.
LFN pc_check_dir
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    lea r15, [rip + .LS_ctx_names]
    xor ebx, ebx
.Lcd_loop:
    cmp rbx, 4
    jae .Lcd_done
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    mov rcx, [r15 + rbx*8]
    call pc_try_context
    test eax, eax
    jnz .Lcd_done
    inc rbx
    jmp .Lcd_loop
.Lcd_done:
    xor eax, eax
    EPILOGUE

# pc_context_ancestors(sb, cwd cstr): project context files from every cwd
# ancestor, root first, cwd last. A relative cwd counts as a single directory.
LFN pc_context_ancestors
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    test r13, r13
    jz .Lca_done
    mov rdi, r13
    call strlen
    mov r14, rax
    test r14, r14
    jz .Lca_done
    cmp byte ptr [r13], '/'
    jne .Lca_single
    mov rbx, 1
.Lca_loop:
    mov rdi, r12
    mov rsi, r13
    mov rdx, rbx
    call pc_check_dir
    cmp rbx, r14
    jae .Lca_done
    lea rcx, [rbx + 1]
.Lca_scan:
    cmp rcx, r14
    jae .Lca_full
    cmp byte ptr [r13 + rcx], '/'
    je .Lca_slash
    inc rcx
    jmp .Lca_scan
.Lca_slash:
    mov rbx, rcx
    jmp .Lca_loop
.Lca_full:
    mov rbx, r14
    jmp .Lca_loop
.Lca_single:
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    call pc_check_dir
.Lca_done:
    xor eax, eax
    EPILOGUE

# ------------------------------------------------------------------ skills

# pc_add_skill(name ptr, namelen, desc ptr, desclen, loc cstr)
# Skips entries without a description; an existing name is replaced.
LFN pc_add_skill
    PROLOGUE 16
    mov [rsp], r8
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    test r14, r14
    jz .Lsk_skip
    test r15, r15
    jz .Lsk_skip
    xor ebx, ebx
.Lsk_find:
    cmp rbx, [rip + pc_sk_count]
    jae .Lsk_append
    mov rax, rbx
    imul rax, rax, PC_SK_ENTRY
    lea r9, [rip + pc_sk_tab]
    add r9, rax
    mov [rsp + 8], r9
    mov rdi, [r9]
    call strlen
    mov rdi, [rsp + 8]
    mov rsi, rax
    mov rdx, r12
    mov rcx, r13
    call str_eq
    test eax, eax
    jnz .Lsk_replace
    inc rbx
    jmp .Lsk_find
.Lsk_replace:
    mov r9, [rsp + 8]
    mov rdi, [r9]
    call mem_free
    mov r9, [rsp + 8]
    mov rdi, [r9 + 8]
    call mem_free
    mov r9, [rsp + 8]
    mov rdi, [r9 + 16]
    call mem_free
    mov rbx, [rsp + 8]
    jmp .Lsk_store
.Lsk_append:
    mov rax, [rip + pc_sk_count]
    cmp rax, PC_MAX_SKILLS
    jae .Lsk_skip
    inc qword ptr [rip + pc_sk_count]
    imul rax, rax, PC_SK_ENTRY
    lea rbx, [rip + pc_sk_tab]
    add rbx, rax
.Lsk_store:
    mov rdi, r12
    mov rsi, r13
    call mem_dup
    mov [rbx], rax
    mov rdi, r14
    mov rsi, r15
    call mem_dup
    mov [rbx + 8], rax
    mov rdi, [rsp]
    call strlen
    mov rsi, rax
    mov rdi, [rsp]
    call mem_dup
    mov [rbx + 16], rax
.Lsk_skip:
    xor eax, eax
    EPILOGUE

# pc_skill_cb(ctx=dir cstr, name cstr, dtype)
# A directory containing SKILL.md is a skill; a direct *.md child is a skill.
LFN pc_skill_cb
    PROLOGUE 32
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    cmp r14, DT_DIR
    je .Lcb_dir
    cmp r14, DT_REG
    je .Lcb_file
    cmp r14, DT_UNKNOWN
    je .Lcb_file
    jmp .Lcb_done
.Lcb_file:
    mov rdi, r13
    call strlen
    cmp rax, 3
    jb .Lcb_done
    lea rcx, [r13 + rax - 3]
    cmp byte ptr [rcx], '.'
    jne .Lcb_done
    cmp byte ptr [rcx + 1], 'm'
    jne .Lcb_done
    cmp byte ptr [rcx + 2], 'd'
    jne .Lcb_done
    mov r14, r13
    lea r15, [rax - 3]
    lea rdi, [rip + pc_path_buf]
    mov rsi, r12
    mov rdx, r13
    call pc_join_cstr
    test rax, rax
    jz .Lcb_done
    jmp .Lcb_read
.Lcb_dir:
    lea rdi, [rip + pc_path_buf]
    mov rsi, r12
    mov rdx, r13
    call pc_join_cstr
    test rax, rax
    jz .Lcb_done
    lea rdi, [rip + pc_path_buf]
    mov rsi, rdi
    lea rdx, [rip + .LS_skill_md]
    call pc_join_cstr
    test rax, rax
    jz .Lcb_done
    mov r14, r13
    mov rdi, r13
    call strlen
    mov r15, rax
.Lcb_read:
    lea rdi, [rip + pc_path_buf]
    lea rsi, [rip + pc_fm_buf]
    mov edx, PC_FMMAX
    call pc_read_prefix
    test rax, rax
    js .Lcb_done
    mov [rsp + 8], rax
    lea rdi, [rip + pc_fm_buf]
    mov rsi, rax
    lea rdx, [rip + .LS_k_name]
    call pc_fm_field
    test rax, rax
    jz .Lcb_fb_name
    test rdx, rdx
    jnz .Lcb_name_ok
.Lcb_fb_name:
    mov rax, r14
    mov rdx, r15
.Lcb_name_ok:
    mov [rsp], rax
    mov [rsp + 16], rdx
    lea rdi, [rip + pc_fm_buf]
    mov rsi, [rsp + 8]
    lea rdx, [rip + .LS_k_desc]
    call pc_fm_field
    test rax, rax
    jz .Lcb_done
    test rdx, rdx
    jz .Lcb_done
    mov rcx, rdx
    mov rdx, rax
    mov rdi, [rsp]
    mov rsi, [rsp + 16]
    lea r8, [rip + pc_path_buf]
    call pc_add_skill
.Lcb_done:
    xor eax, eax
    EPILOGUE

# pc_scan_dir(path cstr, cb, ctx) -> 0|-errno; calls cb(ctx, name, dtype) for
# each entry except "." and "..".
LFN pc_scan_dir
    PROLOGUE PC_FMMAX
    mov r12, rsi
    mov r13, rdx
    mov esi, O_RDONLY | O_DIRECTORY | O_CLOEXEC
    call pc_open
    test rax, rax
    js .Lsd_err
    mov rbx, rax
.Lsd_loop:
    mov edi, ebx
    mov rsi, rsp
    mov edx, PC_FMMAX
    call os_getdents
    test rax, rax
    js .Lsd_errno
    jz .Lsd_done
    mov r15, rax
    xor r14d, r14d
.Lsd_rec:
    cmp r14, r15
    jae .Lsd_loop
    movzx edx, byte ptr [rsp + r14 + 18]
    lea rsi, [rsp + r14 + 19]
    cmp byte ptr [rsi], '.'
    jne .Lsd_call
    cmp byte ptr [rsi + 1], 0
    je .Lsd_next
    cmp byte ptr [rsi + 1], '.'
    jne .Lsd_call
    cmp byte ptr [rsi + 2], 0
    je .Lsd_next
.Lsd_call:
    mov rdi, r13
    call r12
.Lsd_next:
    movzx eax, word ptr [rsp + r14 + 16]
    add r14, rax
    jmp .Lsd_rec
.Lsd_done:
    mov edi, ebx
    call os_close
    xor eax, eax
    EPILOGUE
.Lsd_errno:
    cmp rax, -EINTR
    je .Lsd_loop
    mov r14, rax
    mov edi, ebx
    call os_close
    mov rax, r14
    EPILOGUE
.Lsd_err:
    EPILOGUE

# pc_skills_reset(): free every cached skill entry and clear the table.
LFN pc_skills_reset
    PROLOGUE
    xor ebx, ebx
.Lsr_loop:
    cmp rbx, [rip + pc_sk_count]
    jae .Lsr_done
    mov rax, rbx
    imul rax, rax, PC_SK_ENTRY
    lea r14, [rip + pc_sk_tab]
    add r14, rax
    mov rdi, [r14]
    call mem_free
    mov rdi, [r14 + 8]
    call mem_free
    mov rdi, [r14 + 16]
    call mem_free
    inc rbx
    jmp .Lsr_loop
.Lsr_done:
    mov qword ptr [rip + pc_sk_count], 0
    EPILOGUE

# pc_skills_sort(): insertion-sort pc_sk_tab by name (no-op for <2 entries).
LFN pc_skills_sort
    PROLOGUE 32
    mov rbx, [rip + pc_sk_count]
    cmp rbx, 2
    jb .Lss_ret
    mov r13, 1
.Lss_sort_i:
    cmp r13, rbx
    jae .Lss_ret
    mov rax, r13
    imul rax, rax, PC_SK_ENTRY
    lea r14, [rip + pc_sk_tab]
    add r14, rax
    mov r15, [r14]
    mov r8, [r14 + 8]
    mov [rsp + 16], r8
    mov r8, [r14 + 16]
    mov [rsp + 24], r8
    lea rax, [r13 - 1]
    mov [rsp], rax
.Lss_inner:
    mov rax, [rsp]
    test rax, rax
    js .Lss_place
    mov rcx, rax
    imul rcx, rcx, PC_SK_ENTRY
    lea rdx, [rip + pc_sk_tab]
    add rdx, rcx
    mov [rsp + 8], rdx
    mov rdi, [rdx]
    mov rsi, r15
    call pc_cstr_cmp
    test eax, eax
    jle .Lss_place
    mov rdx, [rsp + 8]
    mov rax, [rsp]
    inc rax
    imul rax, rax, PC_SK_ENTRY
    lea rcx, [rip + pc_sk_tab]
    add rcx, rax
    mov r8, [rdx]
    mov [rcx], r8
    mov r8, [rdx + 8]
    mov [rcx + 8], r8
    mov r8, [rdx + 16]
    mov [rcx + 16], r8
    dec qword ptr [rsp]
    jmp .Lss_inner
.Lss_place:
    mov rax, [rsp]
    inc rax
    imul rax, rax, PC_SK_ENTRY
    lea rcx, [rip + pc_sk_tab]
    add rcx, rax
    mov [rcx], r15
    mov r8, [rsp + 16]
    mov [rcx + 8], r8
    mov r8, [rsp + 24]
    mov [rcx + 16], r8
    inc r13
    jmp .Lss_sort_i
.Lss_ret:
    EPILOGUE

# pc_skills_emit(sb): sort skills by name, write the <available_skills> block
# and free every entry.
LFN pc_skills_emit
    PROLOGUE 32
    mov r12, rdi
    call pc_skills_sort
    mov rbx, [rip + pc_sk_count]
    test rbx, rbx
    jz .Lse_out
.Lse_emit:
    mov rdi, r12
    lea rsi, [rip + .LS_sk_open]
    call sb_push_cstr
    mov rdi, r12
    lea rsi, [rip + .LS_sk_instr]
    call sb_push_cstr
    xor r13d, r13d
.Lse_eloop:
    cmp r13, rbx
    jae .Lse_eclose
    mov rax, r13
    imul rax, rax, PC_SK_ENTRY
    lea r14, [rip + pc_sk_tab]
    add r14, rax
    mov rdi, r12
    lea rsi, [rip + .LS_sk_lt]
    call sb_push_cstr
    mov rdi, r12
    mov rsi, [r14]
    call sb_push_cstr
    mov rdi, r12
    lea rsi, [rip + .LS_sk_lt2]
    call sb_push_cstr
    mov rdi, r12
    mov rsi, [r14 + 16]
    call sb_push_cstr
    mov rdi, r12
    lea rsi, [rip + .LS_sk_gt]
    call sb_push_cstr
    mov rdi, r12
    mov rsi, [r14 + 8]
    call sb_push_cstr
    mov rdi, r12
    lea rsi, [rip + .LS_sk_end]
    call sb_push_cstr
    inc r13
    jmp .Lse_eloop
.Lse_eclose:
    mov rdi, r12
    lea rsi, [rip + .LS_sk_close]
    call sb_push_cstr
    call pc_skills_reset
.Lse_out:
    xor eax, eax
    EPILOGUE

# ------------------------------------------------------------------ templates

# pc_tpl_add(name, path, desc|0): replace an existing name or append.
LFN pc_tpl_add
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    xor ebx, ebx
.Ltpa_find:
    cmp rbx, [rip + pc_tp_count]
    jae .Ltpa_append
    mov rax, rbx
    imul rax, rax, PC_TP_ENTRY
    lea r15, [rip + pc_tp_tab]
    add r15, rax
    mov rdi, [r15]
    mov rsi, r12
    call pc_cstr_eq
    test eax, eax
    jnz .Ltpa_replace
    inc rbx
    jmp .Ltpa_find
.Ltpa_replace:
    mov rdi, [r15]
    call mem_free
    mov rdi, [r15 + 8]
    call mem_free
    mov rdi, [r15 + 16]
    call mem_free
    jmp .Ltpa_store
.Ltpa_append:
    mov rax, [rip + pc_tp_count]
    cmp rax, PC_MAX_TPLS
    jae .Ltpa_drop
    inc qword ptr [rip + pc_tp_count]
    imul rax, rax, PC_TP_ENTRY
    lea r15, [rip + pc_tp_tab]
    add r15, rax
.Ltpa_store:
    mov [r15], r12
    mov [r15 + 8], r13
    mov [r15 + 16], r14
    xor eax, eax
    EPILOGUE
.Ltpa_drop:
    mov rdi, r12
    call mem_free
    mov rdi, r13
    call mem_free
    mov rdi, r14
    call mem_free
    xor eax, eax
    EPILOGUE

# pc_tpl_cb(ctx=dir cstr, name cstr, dtype): direct *.md children only.
LFN pc_tpl_cb
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    cmp rdx, DT_REG
    je .Ltb_file
    cmp rdx, DT_UNKNOWN
    je .Ltb_file
    jmp .Ltb_done
.Ltb_file:
    mov rdi, r13
    call strlen
    cmp rax, 3
    jb .Ltb_done
    lea rcx, [r13 + rax - 3]
    cmp byte ptr [rcx], '.'
    jne .Ltb_done
    cmp byte ptr [rcx + 1], 'm'
    jne .Ltb_done
    cmp byte ptr [rcx + 2], 'd'
    jne .Ltb_done
    mov r14, rax
    lea rdi, [rip + pc_path_buf]
    mov rsi, r12
    mov rdx, r13
    call pc_join_cstr
    test rax, rax
    jz .Ltb_done
    mov r15, rax
    mov rdi, r15
    lea rsi, [rip + pc_fm_buf]
    mov edx, PC_FMMAX
    call pc_read_prefix
    test rax, rax
    js .Ltb_done
    lea rdi, [rip + pc_fm_buf]
    mov rsi, rax
    lea rdx, [rip + .LS_k_desc]
    call pc_fm_field
    mov [rsp], rax
    mov [rsp + 8], rdx
    mov rdi, r13
    lea rsi, [r14 - 3]
    call mem_dup
    mov rbx, rax
    mov rdi, r15
    call strlen
    mov rsi, rax
    mov rdi, r15
    call mem_dup
    mov r12, rax
    mov rax, [rsp]
    test rax, rax
    jz .Ltb_nodesc
    mov rdi, rax
    mov rsi, [rsp + 8]
    call mem_dup
.Ltb_nodesc:
    mov rdx, rax
    mov rdi, rbx
    mov rsi, r12
    call pc_tpl_add
.Ltb_done:
    xor eax, eax
    EPILOGUE

# pc_arg_nth(args cstr|0, n) -> rax=arg ptr|0, rdx=len
LFN pc_arg_nth
    test rdi, rdi
    jz .Lan_none
    xor eax, eax
    test rsi, rsi
    jz .Lan_none
    mov r8, rdi
    mov r9d, 1
.Lan_loop:
    mov rcx, r8
.Lan_scan:
    movzx eax, byte ptr [rcx]
    test al, al
    jz .Lan_endtok
    cmp al, ' '
    je .Lan_endtok
    inc rcx
    jmp .Lan_scan
.Lan_endtok:
    cmp r9, rsi
    je .Lan_found
    cmp byte ptr [rcx], 0
    je .Lan_none
    lea r8, [rcx + 1]
    inc r9
    jmp .Lan_loop
.Lan_found:
    mov rax, r8
    mov rdx, rcx
    sub rdx, r8
    ret
.Lan_none:
    xor eax, eax
    xor edx, edx
    ret

# pc_at_slice(out, args cstr|0, n, limit): append args n.. joined by spaces;
# limit < 0 means "to the end", limit 0 emits nothing.
LFN pc_at_slice
    PROLOGUE 32
    mov [rsp], rcx
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    test r13, r13
    jz .Las_done
    cmp byte ptr [r13], 0
    je .Las_done
    mov r15, r13
    mov ebx, 1
    mov qword ptr [rsp + 8], 0
.Las_tok:
    mov rcx, r15
.Las_scan:
    movzx eax, byte ptr [rcx]
    test al, al
    jz .Las_endtok
    cmp al, ' '
    je .Las_endtok
    inc rcx
    jmp .Las_scan
.Las_endtok:
    cmp rbx, r14
    jb .Las_skip
    mov rax, [rsp]
    cmp rax, 0
    jl .Las_emit
    jz .Las_done
    mov rdx, rbx
    sub rdx, r14
    cmp rdx, rax
    jae .Las_done
.Las_emit:
    cmp qword ptr [rsp + 8], 0
    je .Las_nosep
    mov [rsp + 16], rcx
    mov rdi, r12
    mov esi, 32
    call sb_push_byte
    mov rcx, [rsp + 16]
.Las_nosep:
    mov qword ptr [rsp + 8], 1
    mov [rsp + 16], rcx
    mov rdi, r12
    mov rsi, r15
    mov rdx, rcx
    sub rdx, r15
    call sb_push
    mov rcx, [rsp + 16]
.Las_skip:
    cmp byte ptr [rcx], 0
    jz .Las_done
    lea r15, [rcx + 1]
    inc rbx
    jmp .Las_tok
.Las_done:
    xor eax, eax
    EPILOGUE

# pc_expand(out, body, bodylen, args cstr|0)
# $1..$9, ${N}, ${N:-default}, $@/$ARGUMENTS, ${@:N}, ${@:N:L}; unknown $N is
# empty, an unrecognized ${...} is copied verbatim.
LFN pc_expand
    PROLOGUE 32
    mov r12, rdi
    mov r13, rsi
    lea r15, [rsi + rdx]
    mov rbx, rcx
.Le_loop:
    cmp r13, r15
    jae .Le_done
    mov rdi, r13
    mov rsi, r15
    sub rsi, r13
    lea rdx, [rip + .LS_dollar]
    mov ecx, 1
    call str_find
    cmp rax, -1
    je .Le_pushrest
    test rax, rax
    jz .Le_dollar
    mov [rsp], rax
    mov rdi, r12
    mov rsi, r13
    mov rdx, rax
    call sb_push
    mov rax, [rsp]
    add r13, rax
.Le_dollar:
    lea rcx, [r13 + 1]
    cmp rcx, r15
    jae .Le_lit
    movzx eax, byte ptr [rcx]
    cmp al, '@'
    je .Le_at
    cmp al, 'A'
    je .Le_args
    cmp al, '1'
    jb .Le_maybe_brace
    cmp al, '9'
    jbe .Le_digit
.Le_maybe_brace:
    cmp al, '{'
    je .Le_brace
    jmp .Le_lit
.Le_at:
    mov rsi, rbx
    test rsi, rsi
    jnz .Le_at_push
    lea rsi, [rip + .LS_empty]
.Le_at_push:
    mov rdi, r12
    call sb_push_cstr
    add r13, 2
    jmp .Le_loop
.Le_args:
    mov rax, r15
    sub rax, rcx
    cmp rax, 9
    jb .Le_lit
    mov rdi, rcx
    lea rsi, [rip + .LS_arguments]
    mov edx, 9
    call memeq
    test eax, eax
    jz .Le_lit
    mov rsi, rbx
    test rsi, rsi
    jnz .Le_args_push
    lea rsi, [rip + .LS_empty]
.Le_args_push:
    mov rdi, r12
    call sb_push_cstr
    add r13, 10
    jmp .Le_loop
.Le_digit:
    movzx esi, byte ptr [rcx]
    sub esi, '0'
    mov rdi, rbx
    call pc_arg_nth
    test rax, rax
    jz .Le_digit_next
    mov rsi, rax
    mov rdi, r12
    call sb_push
.Le_digit_next:
    add r13, 2
    jmp .Le_loop
.Le_lit:
    mov rdi, r12
    mov esi, '$'
    call sb_push_byte
    inc r13
    jmp .Le_loop
.Le_pushrest:
    mov rdi, r12
    mov rsi, r13
    mov rdx, r15
    sub rdx, r13
    call sb_push
.Le_done:
    xor eax, eax
    EPILOGUE
.Le_brace:
    lea r8, [rcx + 1]
    cmp r8, r15
    jae .Le_blit
    cmp byte ptr [r8], '@'
    jne .Le_bpos
    lea r9, [r8 + 1]
    cmp r9, r15
    jae .Le_blit
    cmp byte ptr [r9], ':'
    jne .Le_blit
    lea r9, [r8 + 2]
    mov r10, r9
    xor eax, eax
.Le_pn:
    cmp r10, r15
    jae .Le_blit
    movzx edx, byte ptr [r10]
    sub edx, '0'
    cmp edx, 9
    ja .Le_pnd
    imul rax, rax, 10
    add rax, rdx
    inc r10
    jmp .Le_pn
.Le_pnd:
    cmp r10, r9
    je .Le_blit
    test rax, rax
    jz .Le_blit
    mov r11, rax
    mov rcx, -1
    cmp byte ptr [r10], ':'
    jne .Le_ldone
    lea r10, [r10 + 1]
    xor ecx, ecx
.Le_pl:
    cmp r10, r15
    jae .Le_blit
    movzx eax, byte ptr [r10]
    sub eax, '0'
    cmp eax, 9
    ja .Le_ldone
    imul rcx, rcx, 10
    add rcx, rax
    inc r10
    jmp .Le_pl
.Le_ldone:
    cmp r10, r15
    jae .Le_blit
    cmp byte ptr [r10], '}'
    jne .Le_blit
    mov [rsp + 8], r10
    mov rdi, r12
    mov rsi, rbx
    mov rdx, r11
    call pc_at_slice
    mov r10, [rsp + 8]
    lea r13, [r10 + 1]
    jmp .Le_loop
.Le_bpos:
    mov r9, r8
    xor r10d, r10d
.Le_pd:
    cmp r9, r15
    jae .Le_blit
    movzx eax, byte ptr [r9]
    sub eax, '0'
    cmp eax, 9
    ja .Le_pdd
    imul r10, r10, 10
    add r10, rax
    inc r9
    jmp .Le_pd
.Le_pdd:
    cmp r9, r8
    je .Le_blit
    cmp byte ptr [r9], '}'
    jne .Le_pdef
    mov r14, r9
    mov rdi, rbx
    mov rsi, r10
    call pc_arg_nth
    test rax, rax
    jz .Le_pdnext
    mov rsi, rax
    mov rdi, r12
    call sb_push
.Le_pdnext:
    lea r13, [r14 + 1]
    jmp .Le_loop
.Le_pdef:
    cmp byte ptr [r9], ':'
    jne .Le_blit
    lea rax, [r9 + 1]
    cmp rax, r15
    jae .Le_blit
    cmp byte ptr [rax], '-'
    jne .Le_blit
    lea r11, [r9 + 2]
    mov rcx, r11
.Le_fclose:
    cmp rcx, r15
    jae .Le_blit
    cmp byte ptr [rcx], '}'
    je .Le_haveclose
    inc rcx
    jmp .Le_fclose
.Le_haveclose:
    mov r14, rcx
    mov [rsp + 24], r11
    mov rdi, rbx
    mov rsi, r10
    call pc_arg_nth
    test rax, rax
    jz .Le_usedef
    test rdx, rdx
    jz .Le_usedef
    mov rsi, rax
    mov rdi, r12
    call sb_push
    jmp .Le_defdone
.Le_usedef:
    mov rdi, r12
    mov rsi, [rsp + 24]
    mov rdx, r14
    sub rdx, rsi
    call sb_push
.Le_defdone:
    lea r13, [r14 + 1]
    jmp .Le_loop
.Le_blit:
    mov rcx, r13
.Le_blfind:
    cmp rcx, r15
    jae .Le_blnone
    cmp byte ptr [rcx], '}'
    je .Le_blcopy
    inc rcx
    jmp .Le_blfind
.Le_blcopy:
    lea rdx, [rcx + 1]
    sub rdx, r13
    mov rdi, r12
    mov rsi, r13
    mov [rsp + 16], rcx
    call sb_push
    mov rcx, [rsp + 16]
    lea r13, [rcx + 1]
    jmp .Le_loop
.Le_blnone:
    mov rdi, r12
    mov rsi, r13
    mov rdx, r15
    sub rdx, r13
    call sb_push
    jmp .Le_done

# pc_date_from_secs(secs, sb) -> void
# Append the UTC civil date "YYYY-MM-DD" (10 bytes) for `secs` seconds since the
# Unix epoch.  Howard Hinnant's days->civil algorithm (shift the epoch to
# 0000-03-01, then a 400-year era division); integer only, no floating point, no
# libc.  `secs` is clamped to 0 when negative (the realtime clock never yields
# one).  UTC, not local time: a local-zone conversion would need tz data.
FN pc_date_from_secs
    PROLOGUE 16
    mov rbx, rsi                       # sb
    test rdi, rdi
    jns 1f
    xor edi, edi
1:  mov rax, rdi                       # days = secs / 86400
    xor edx, edx
    mov rcx, 86400
    div rcx
    add rax, 719468                    # z: days since 0000-03-01
    mov r12, rax
    mov rax, r12                       # era = z / 146097
    xor edx, edx
    mov rcx, 146097
    div rcx
    mov r13, rax                       # era
    imul rax, r13, 146097              # doe = z - era*146097
    mov r14, r12
    sub r14, rax                       # doe
    mov rax, r14                       # yoe = (doe - doe/1460 + doe/36524 - doe/146096)/365
    xor edx, edx
    mov rcx, 1460
    div rcx
    mov r15, r14
    sub r15, rax
    mov rax, r14
    xor edx, edx
    mov rcx, 36524
    div rcx
    add r15, rax
    mov rax, r14
    xor edx, edx
    mov rcx, 146096
    div rcx
    sub r15, rax
    mov rax, r15
    xor edx, edx
    mov rcx, 365
    div rcx
    mov r15, rax                       # yoe
    imul rax, r13, 400                 # y = yoe + era*400
    add rax, r15
    mov r8, rax                        # y (shifted-calendar year)
    imul r9, r15, 365                  # doy = doe - (365*yoe + yoe/4 - yoe/100)
    mov rax, r15
    shr rax, 2
    add r9, rax
    mov rax, r15
    xor edx, edx
    mov rcx, 100
    div rcx
    sub r9, rax                        # 365*yoe + yoe/4 - yoe/100
    mov r10, r14
    sub r10, r9                        # doy
    lea rax, [r10 + r10*4]             # mp = (5*doy + 2) / 153
    add rax, 2
    xor edx, edx
    mov rcx, 153
    div rcx
    mov r11, rax                       # mp
    imul rax, r11, 153                 # d = doy - (153*mp + 2)/5 + 1
    add rax, 2
    xor edx, edx
    mov rcx, 5
    div rcx
    mov r9, r10
    sub r9, rax
    inc r9                             # d
    cmp r11, 10                        # m = mp < 10 ? mp + 3 : mp - 9
    jae 2f
    lea r10, [r11 + 3]
    jmp 3f
2:  lea r10, [r11 - 9]
3:  cmp r10, 2                         # year = y + (m <= 2)
    ja 4f
    inc r8
4:  mov rax, r8                        # format "YYYY-MM-DD" at [rsp]
    xor edx, edx
    mov rcx, 1000
    div rcx
    add al, '0'
    mov [rsp], al
    mov rax, rdx
    xor edx, edx
    mov rcx, 100
    div rcx
    add al, '0'
    mov [rsp + 1], al
    mov rax, rdx
    xor edx, edx
    mov rcx, 10
    div rcx
    add al, '0'
    mov [rsp + 2], al
    add dl, '0'
    mov [rsp + 3], dl
    mov byte ptr [rsp + 4], '-'
    mov rax, r10
    xor edx, edx
    mov rcx, 10
    div rcx
    add al, '0'
    mov [rsp + 5], al
    add dl, '0'
    mov [rsp + 6], dl
    mov byte ptr [rsp + 7], '-'
    mov rax, r9
    xor edx, edx
    mov rcx, 10
    div rcx
    add al, '0'
    mov [rsp + 8], al
    add dl, '0'
    mov [rsp + 9], dl
    mov rdi, rbx
    mov rsi, rsp
    mov edx, 10
    call sb_push
    EPILOGUE

# ------------------------------------------------------------------ prompt_build

FN prompt_build
    PROLOGUE 64
    test rdi, rdi
    jz .Lpb_err
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    test r14, r14
    jnz .Lpb_cwd
    lea r14, [rip + .LS_empty]
.Lpb_cwd:
    call pc_config_home
    mov [rsp + 8], rax
    mov rdi, r14
    call config_trusted
    mov [rsp], rax
    # 1. preamble
    mov rdi, r12
    mov rsi, [rsp + 8]
    call pc_try_preamble
    test eax, eax
    jnz .Lpb_pre_done
    mov rdi, r12
    lea rsi, [rip + .LS_builtin]
    call sb_push_cstr
.Lpb_pre_done:
    mov rdi, r12
    call pc_ensure_nl
    # 2. tools
    mov rdi, r12
    lea rsi, [rip + .LS_tools]
    call sb_push_cstr
    test r13, r13
    jnz .Lpb_have
    call tools_active
    mov r13, rax
    test r13, r13
    jz .Lpb_rules
.Lpb_have:
    mov r15, [r13 + VEC_ptr]
    test r15, r15
    jz .Lpb_rules
    xor ebx, ebx
.Lpb_loop:
    cmp rbx, [r13 + VEC_len]
    jae .Lpb_rules
    mov rax, [r15 + rbx*8]
    test rax, rax
    jz .Lpb_next
    mov rsi, [rax + TL_name]
    test rsi, rsi
    jnz .Lpb_name
    lea rsi, [rip + .LS_empty]
.Lpb_name:
    mov rdi, r12
    call sb_push_cstr
    mov rdi, r12
    lea rsi, [rip + .LS_colon]
    call sb_push_cstr
    mov rax, [r15 + rbx*8]
    mov rsi, [rax + TL_desc]
    test rsi, rsi
    jnz .Lpb_desc
    lea rsi, [rip + .LS_empty]
.Lpb_desc:
    mov rdi, r12
    call sb_push_cstr
    mov rdi, r12
    lea rsi, [rip + .LS_nl]
    call sb_push_cstr
.Lpb_next:
    inc rbx
    jmp .Lpb_loop
    # 3. rules
.Lpb_rules:
    mov rdi, r12
    lea rsi, [rip + .LS_rules]
    call sb_push_cstr
    # 4. addendum: config first, then the trusted project copy
    mov rax, [rsp + 8]
    test rax, rax
    jz .Lpb_add2
    lea rdi, [rip + pc_path_buf]
    mov rsi, rax
    lea rdx, [rip + .LS_append]
    call pc_join_cstr
    test rax, rax
    jz .Lpb_add2
    mov rdi, r12
    mov rsi, rax
    call pc_try_addendum
.Lpb_add2:
    cmp qword ptr [rsp], 0
    je .Lpb_ctx
    lea rdi, [rip + pc_path_buf]
    mov rsi, r14
    lea rdx, [rip + .LS_opcode_append]
    call pc_join_cstr
    test rax, rax
    jz .Lpb_ctx
    mov rdi, r12
    mov rsi, rax
    call pc_try_addendum
    # 5. project_context: config dir then cwd ancestors root-first
.Lpb_ctx:
    mov rsi, [rsp + 8]
    test rsi, rsi
    jz .Lpb_anc
    mov rdi, rsi
    mov [rsp + 16], rsi
    call strlen
    mov rdi, r12
    mov rsi, [rsp + 16]
    mov rdx, rax
    call pc_check_dir
.Lpb_anc:
    mov rdi, r12
    mov rsi, r14
    call pc_context_ancestors
    # 6. skills
    call pc_skills_reset
    mov rax, [rsp + 8]
    test rax, rax
    jz .Lpb_sk2
    lea rdi, [rip + pc_dir_buf]
    mov rsi, rax
    lea rdx, [rip + .LS_skills]
    call pc_join_cstr
    test rax, rax
    jz .Lpb_sk2
    mov rdi, rax
    lea rsi, [rip + pc_skill_cb]
    lea rdx, [rip + pc_dir_buf]
    call pc_scan_dir
.Lpb_sk2:
    cmp qword ptr [rsp], 0
    je .Lpb_sk_emit
    lea rdi, [rip + pc_dir_buf]
    mov rsi, r14
    lea rdx, [rip + .LS_opcode_skills]
    call pc_join_cstr
    test rax, rax
    jz .Lpb_sk_emit
    mov rdi, rax
    lea rsi, [rip + pc_skill_cb]
    lea rdx, [rip + pc_dir_buf]
    call pc_scan_dir
.Lpb_sk_emit:
    mov rdi, r12
    call pc_skills_emit
    # 7. environment (kept last: cwd and platform are the turn-varying facts)
    mov rdi, r12
    lea rsi, [rip + .LS_env]
    call sb_push_cstr
    mov rdi, r12
    mov rsi, r14
    call sb_push_cstr
    mov rdi, r12
    lea rsi, [rip + .LS_env_plat]
    call sb_push_cstr
    mov rax, [rip + g_prompt_platform]
    test rax, rax
    jnz .Lpb_plat_go
    call os_platform
.Lpb_plat_go:
    mov rdi, r12
    mov rsi, rax
    call sb_push_cstr
    # date: the UTC civil date, computed from the realtime clock (or the seam)
    mov rdi, r12
    lea rsi, [rip + .LS_env_date]
    call sb_push_cstr
    mov rax, [rip + g_prompt_date]
    test rax, rax
    jnz .Lpb_date_go
    xor edi, edi                       # os_now_ns(CLOCK_REALTIME)
    call os_now_ns
    test rax, rax
    jns .Lpb_date_sec
    xor eax, eax
.Lpb_date_sec:
    xor edx, edx
    mov rcx, 1000000000
    div rcx                            # ns -> s
    mov rdi, rax
    mov rsi, r12
    call pc_date_from_secs
    jmp .Lpb_date_done
.Lpb_date_go:
    mov rdi, r12
    mov rsi, rax
    call sb_push_cstr
.Lpb_date_done:
    mov rdi, r12
    lea rsi, [rip + .LS_nl]
    call sb_push_cstr
    xor eax, eax
    EPILOGUE
.Lpb_err:
    mov rax, -EINVAL
    EPILOGUE

# ------------------------------------------------------------------ template API

FN prompt_templates_init
    PROLOGUE
    # release a previously built table
    xor ebx, ebx
.Lti_free:
    cmp rbx, [rip + pc_tp_count]
    jae .Lti_reset
    mov rax, rbx
    imul rax, rax, PC_TP_ENTRY
    lea r15, [rip + pc_tp_tab]
    add r15, rax
    mov rdi, [r15]
    call mem_free
    mov rdi, [r15 + 8]
    call mem_free
    mov rdi, [r15 + 16]
    call mem_free
    inc rbx
    jmp .Lti_free
.Lti_reset:
    mov qword ptr [rip + pc_tp_count], 0
    call pc_config_home
    mov r12, rax
    test r12, r12
    jz .Lti_proj
    lea rdi, [rip + pc_dir_buf]
    mov rsi, r12
    lea rdx, [rip + .LS_prompts]
    call pc_join_cstr
    test rax, rax
    jz .Lti_proj
    mov rdi, rax
    lea rsi, [rip + pc_tpl_cb]
    lea rdx, [rip + pc_dir_buf]
    call pc_scan_dir
.Lti_proj:
    lea rdi, [rip + pc_cwd_buf]
    mov esi, PC_PATHMAX
    call os_getcwd
    test rax, rax
    js .Lti_done
    lea rdi, [rip + pc_cwd_buf]
    call config_trusted
    test eax, eax
    jz .Lti_done
    lea rdi, [rip + pc_dir_buf]
    lea rsi, [rip + pc_cwd_buf]
    lea rdx, [rip + .LS_opcode_prompts]
    call pc_join_cstr
    test rax, rax
    jz .Lti_done
    mov rdi, rax
    lea rsi, [rip + pc_tpl_cb]
    lea rdx, [rip + pc_dir_buf]
    call pc_scan_dir
.Lti_done:
    xor eax, eax
    EPILOGUE

FN prompt_template_expand
    PROLOGUE 64
    test rdi, rdi
    jz .Lte_noent
    test rdx, rdx
    jz .Lte_noent
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    xor ebx, ebx
.Lte_find:
    cmp rbx, [rip + pc_tp_count]
    jae .Lte_noent
    mov rax, rbx
    imul rax, rax, PC_TP_ENTRY
    lea r15, [rip + pc_tp_tab]
    add r15, rax
    mov rdi, [r15]
    mov rsi, r12
    call pc_cstr_eq
    test eax, eax
    jnz .Lte_found
    inc rbx
    jmp .Lte_find
.Lte_found:
    mov qword ptr [rsp + SB_ptr], 0
    mov qword ptr [rsp + SB_len], 0
    mov qword ptr [rsp + SB_cap], 0
    mov rdi, [r15 + 8]
    lea rsi, [rsp]
    xor edx, edx
    call pc_read_file_sb
    test rax, rax
    js .Lte_free_noent
    mov rdi, [rsp + SB_ptr]
    mov rsi, [rsp + SB_len]
    call pc_skip_fm
    mov rdi, r14
    mov rsi, rax
    mov rcx, r13
    call pc_expand
    lea rdi, [rsp]
    call sb_free
    xor eax, eax
    EPILOGUE
.Lte_free_noent:
    lea rdi, [rsp]
    call sb_free
.Lte_noent:
    mov rax, -ENOENT
    EPILOGUE

# ------------------------------------------------------------------ registry API
# Public enumeration used by the TUI menu.  Both tables are process-wide and
# rebuilt in place; returned name pointers are borrowed until the next scan.

# skills_list() -> rax count.  Scans <config>/skills and, when the cwd is
# trusted, <cwd>/.opcode/skills into pc_sk_tab with the same callback as
# prompt_build (pc_skill_cb); any previous table is freed first.
FN skills_list
    PROLOGUE 16
    call pc_skills_reset
    call pc_config_home
    mov r12, rax
    test r12, r12
    jz .Lsl_proj
    lea rdi, [rip + pc_dir_buf]
    mov rsi, r12
    lea rdx, [rip + .LS_skills]
    call pc_join_cstr
    test rax, rax
    jz .Lsl_proj
    mov rdi, rax
    lea rsi, [rip + pc_skill_cb]
    lea rdx, [rip + pc_dir_buf]
    call pc_scan_dir
.Lsl_proj:
    lea rdi, [rip + pc_cwd_buf]
    mov esi, PC_PATHMAX
    call os_getcwd
    test rax, rax
    js .Lsl_done
    lea rdi, [rip + pc_cwd_buf]
    call config_trusted
    test eax, eax
    jz .Lsl_done
    lea rdi, [rip + pc_dir_buf]
    lea rsi, [rip + pc_cwd_buf]
    lea rdx, [rip + .LS_opcode_skills]
    call pc_join_cstr
    test rax, rax
    jz .Lsl_done
    mov rdi, rax
    lea rsi, [rip + pc_skill_cb]
    lea rdx, [rip + pc_dir_buf]
    call pc_scan_dir
.Lsl_done:
    call pc_skills_sort
    mov rax, [rip + pc_sk_count]
    EPILOGUE

# skills_at(edi i) -> rax name cstr | 0
FN skills_at
    test edi, edi
    js 1f
    mov eax, edi
    cmp rax, [rip + pc_sk_count]
    jae 1f
    imul rax, rax, PC_SK_ENTRY
    lea rcx, [rip + pc_sk_tab]
    mov rax, [rcx + rax]
    ret
1:  xor eax, eax
    ret

# skill_body(name rdi, out SB* rsi) -> 0 | -ENOENT | -EFBIG | -errno
# Looks the name up in the table populated by skills_list(), reads the skill
# file and appends the frontmatter-stripped body to out.  A body larger than
# 256 KiB is refused (-EFBIG) and out is left untouched.
FN skill_body
    PROLOGUE 32
    mov r12, rdi
    mov r13, rsi
    test r12, r12
    jz .Lsbd_einval
    test r13, r13
    jz .Lsbd_einval
    xor ebx, ebx
.Lsbd_find:
    cmp rbx, [rip + pc_sk_count]
    jae .Lsbd_noent
    mov rax, rbx
    imul rax, rax, PC_SK_ENTRY
    lea r14, [rip + pc_sk_tab]
    add r14, rax
    mov rdi, [r14]
    mov rsi, r12
    call pc_cstr_eq
    test eax, eax
    jnz .Lsbd_found
    inc rbx
    jmp .Lsbd_find
.Lsbd_found:
    mov qword ptr [rsp + SB_ptr], 0
    mov qword ptr [rsp + SB_len], 0
    mov qword ptr [rsp + SB_cap], 0
    mov rdi, [r14 + 16]
    lea rsi, [rsp]
    xor edx, edx
    call pc_read_file_sb
    test rax, rax
    js .Lsbd_drain
    mov rdi, [rsp + SB_ptr]
    mov rsi, [rsp + SB_len]
    call pc_skip_fm
    cmp rdx, PC_SKILL_MAX
    ja .Lsbd_toobig
    test rdx, rdx
    jz .Lsbd_ok
    mov rsi, rax
    mov rdi, r13
    call sb_push
.Lsbd_ok:
    lea rdi, [rsp]
    call sb_free
    xor eax, eax
    EPILOGUE
.Lsbd_toobig:
    lea rdi, [rsp]
    call sb_free
    mov rax, -EFBIG
    EPILOGUE
.Lsbd_drain:
    mov rbx, rax
    lea rdi, [rsp]
    call sb_free
    mov rax, rbx
    EPILOGUE
.Lsbd_noent:
    mov rax, -ENOENT
    EPILOGUE
.Lsbd_einval:
    mov rax, -EINVAL
    EPILOGUE

# prompt_templates_count() -> eax number of registered file templates
FN prompt_templates_count
    mov eax, [rip + pc_tp_count]
    ret

# prompt_templates_at(edi i) -> rax template name cstr | 0
FN prompt_templates_at
    test edi, edi
    js 1f
    mov eax, edi
    cmp rax, [rip + pc_tp_count]
    jae 1f
    imul rax, rax, PC_TP_ENTRY
    lea rcx, [rip + pc_tp_tab]
    mov rax, [rcx + rax]
    ret
1:  xor eax, eax
    ret
