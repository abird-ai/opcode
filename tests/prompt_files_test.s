.include "opcode.inc"
.include "core/core.inc"
# prompt_files_test: M3 prompt sections (SYSTEM/APPEND_SYSTEM, project context,
# skills) and prompt templates. Builds a fake tree under build/pf_tree.
# Golden output: tests/data/prompt_files_test.expected

.bss
.p2align 3
t_sb:  .zero SB_SIZE
t_out: .zero SB_SIZE

.data
.p2align 3
# 1-tool VEC (of TL*) for prompt_build.
t_tool0:
    .quad .Ltname
    .quad 0
    .quad .Ltdesc
    .quad 0
    .long 0
    .long 0
    .quad 0
    .quad 0
t_tool_items:
    .quad t_tool0
t_tools_vec:
    .quad t_tool_items
    .quad 1
    .quad 1

.section .rodata
.Ld_build:  .asciz "build"
.Ld_root:   .asciz "build/pf_tree"
.Ld_cfg:    .asciz "build/pf_tree/config"
.Ld_prompts: .asciz "build/pf_tree/config/prompts"
.Ld_skills: .asciz "build/pf_tree/config/skills"
.Ld_one:    .asciz "build/pf_tree/config/skills/one"
.Ld_proj:   .asciz "build/pf_tree/proj"
.Ld_opcode: .asciz "build/pf_tree/proj/.opcode"
.Ld_pskills: .asciz "build/pf_tree/proj/.opcode/skills"
.Ld_three:  .asciz "build/pf_tree/proj/.opcode/skills/three"

.Lc_cfg:    .asciz "build/pf_tree/config"
.Lc_proj:   .asciz "build/pf_tree/proj"
.Lc_plat:   .asciz "testplat"
.Lc_date:   .asciz "2000-02-29"

.Lf_system: .asciz "build/pf_tree/config/SYSTEM.md"
.Lc_system: .asciz "You are Test Opcode.\n"
.Lf_append: .asciz "build/pf_tree/config/APPEND_SYSTEM.md"
.Lc_append: .asciz "Config addendum.\n"
.Lf_hello:  .asciz "build/pf_tree/config/prompts/hello.md"
.Lc_hello:  .asciz "---\ndescription: Greet someone\n---\nHello $1 and ${2:-world} from $@\n"
.Lf_one:    .asciz "build/pf_tree/config/skills/one/SKILL.md"
.Lc_one:    .asciz "---\nname: one\ndescription: First skill\n---\nBody one.\n"
.Lf_two:    .asciz "build/pf_tree/config/skills/two.md"
.Lc_two:    .asciz "---\ndescription: Second skill\nname: two\n---\nBody two.\n"
.Lf_agents: .asciz "build/pf_tree/proj/AGENTS.md"
.Lc_agents: .asciz "Project instruction A.\nProject instruction B.\n"
.Lf_three:  .asciz "build/pf_tree/proj/.opcode/skills/three/SKILL.md"
.Lc_three:  .asciz "---\nname: three\ndescription: Third skill from project\n---\nBody three.\n"

.Ltname:    .asciz "read"
.Ltdesc:    .asciz "Read a file"

.Ltmpl_name: .asciz "hello"
.Ltmpl_args: .asciz "there"
.Ltmpl_nope: .asciz "nope"
.Lm_begin:   .asciz "---- prompt begin ----\n"
.Lm_end:     .asciz "---- prompt end ----\n"
.Lm_tpl:     .asciz "template: "
.Lm_ok:      .asciz "prompt files ok\n"
.Lm_fail:    .asciz "FAIL prompt_files_test\n"

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

# t_mkdir(path): create the directory, an existing one is fine
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

FN opcode_main
    PROLOGUE

    # ---- fake tree -------------------------------------------------------
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
    lea rdi, [rip + .Ld_one]
    call t_mkdir
    lea rdi, [rip + .Ld_proj]
    call t_mkdir
    lea rdi, [rip + .Ld_opcode]
    call t_mkdir
    lea rdi, [rip + .Ld_pskills]
    call t_mkdir
    lea rdi, [rip + .Ld_three]
    call t_mkdir

    lea rdi, [rip + .Lf_system]
    lea rsi, [rip + .Lc_system]
    call t_write
    lea rdi, [rip + .Lf_append]
    lea rsi, [rip + .Lc_append]
    call t_write
    lea rdi, [rip + .Lf_hello]
    lea rsi, [rip + .Lc_hello]
    call t_write
    lea rdi, [rip + .Lf_one]
    lea rsi, [rip + .Lc_one]
    call t_write
    lea rdi, [rip + .Lf_two]
    lea rsi, [rip + .Lc_two]
    call t_write
    lea rdi, [rip + .Lf_agents]
    lea rsi, [rip + .Lc_agents]
    call t_write
    lea rdi, [rip + .Lf_three]
    lea rsi, [rip + .Lc_three]
    call t_write

    # ---- config + trusted project ---------------------------------------
    lea rax, [rip + .Lc_cfg]
    mov [rip + g_config_home], rax
    mov qword ptr [rip + g_config_approve], 1
    # fixed platform and date so one golden fixture serves every target
    lea rax, [rip + .Lc_plat]
    mov [rip + g_prompt_platform], rax
    lea rax, [rip + .Lc_date]
    mov [rip + g_prompt_date], rax

    # ---- 1. full prompt --------------------------------------------------
    lea rdi, [rip + t_sb]
    lea rsi, [rip + t_tools_vec]
    lea rdx, [rip + .Lc_proj]
    call prompt_build
    test eax, eax
    jnz .Lfail

    lea rdi, [rip + .Lm_begin]
    call print
    mov rdi, [rip + t_sb + SB_ptr]
    test rdi, rdi
    jz .Lfail
    call print
    lea rdi, [rip + .Lm_end]
    call print

    # ---- 2. template init + expand --------------------------------------
    call prompt_templates_init
    lea rdi, [rip + .Ltmpl_name]
    lea rsi, [rip + .Ltmpl_args]
    lea rdx, [rip + t_out]
    call prompt_template_expand
    test eax, eax
    jnz .Lfail

    lea rdi, [rip + .Lm_tpl]
    call print
    mov rdi, [rip + t_out + SB_ptr]
    test rdi, rdi
    jz .Lfail
    call print

    # an unknown template name is reported as -ENOENT
    lea rdi, [rip + .Ltmpl_nope]
    lea rsi, [rip + .Ltmpl_args]
    lea rdx, [rip + t_out]
    call prompt_template_expand
    cmp eax, -ENOENT
    jne .Lfail

    lea rdi, [rip + .Lm_ok]
    call print

    lea rdi, [rip + t_sb]
    call sb_free
    lea rdi, [rip + t_out]
    call sb_free
    xor eax, eax
    EPILOGUE

.Lfail:
    lea rdi, [rip + .Lm_fail]
    call print
    mov eax, 1
    EPILOGUE
