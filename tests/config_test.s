.include "opcode.inc"
.include "core/core.inc"
# config_test: JSONC config loading, project trust and the extended auth chain (M3).
#
# The user config dir is build/config_test_home (absolute), exposed through the
# g_config_home override (the same global prompt.s uses); the project lives in
# build/config_test_proj.
# config_load() reads the project config from <cwd>/.opcode/config.jsonc, so
# the test chdir(2)s into the project before the trusted reload.

.equ SYS_chdir, 80

.bss
.p2align 3
t_root:       .zero 512
t_home:       .zero 512
t_usercfg:    .zero 512
t_proj:       .zero 512
t_projopcode: .zero 512
t_projcfg:    .zero 512
t_trust:      .zero 512
t_auth:       .zero 512

.section .rodata
user_doc:
    .ascii "{\n"
    .ascii "  // defaults\n"
    .ascii "  \"default_provider\": \"anthropic\",\n"
    .ascii "  \"providers\": { \"openai\": { \"base_url\": \"https://example.test/v1\", }, },\n"
    .ascii "  \"session_dir\": \"build/config_test_sessions\",\n"
    .ascii "  \"api_keys\": { \"openai\": \"key-from-config\" }\n"
    .ascii "}\n"
user_doc_len = . - user_doc

proj_doc:
    .ascii "{\"default_provider\":\"project\"}\n"
proj_doc_len = . - proj_doc

auth_doc:
    .ascii "{\"openai\":{\"api_key\":\"oauth-key\"}}\n"
auth_doc_len = . - auth_doc

s_home_sub:       .asciz "/build/config_test_home"
s_config_sub:     .asciz "/config.jsonc"
s_proj_sub:       .asciz "/build/config_test_proj"
s_dotopcode_sub:  .asciz "/.opcode"
s_trust_sub:      .asciz "/trust.jsonc"
s_auth_sub:       .asciz "/auth.jsonc"

k_default_provider: .asciz "default_provider"
v_anthropic:        .asciz "anthropic"
v_openai:           .asciz "openai"
v_base:             .asciz "https://example.test/v1"
v_sessions:         .asciz "build/config_test_sessions"
v_key:              .asciz "key-from-config"
v_flag:             .asciz "FLAGKEY"
v_oauth:            .asciz "oauth-key"
v_project:          .asciz "project"

m_user:   .asciz "config user ok\n"
m_off:    .asciz "config trust off ok\n"
m_on:     .asciz "config trust on ok\n"
m_flagok: .asciz "config auth flag ok\n"
m_fileok: .asciz "config auth file ok\n"
m_done:   .asciz "config done\n"
m_fail:   .asciz "FAIL config\n"
.text

# tprint(cstr)
tprint:
    push rdi
    call strlen
    pop rdi
    mov rdx, rax
    mov rsi, rdi
    mov edi, 1
    jmp write_all

# teq(a, b) -> 1|0 (leaf)
teq:
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

# tscat(dst, src) -> end of dst (leaf)
tscat:
    mov rax, rdi
1:  mov cl, [rsi]
    mov [rax], cl
    inc rax
    inc rsi
    test cl, cl
    jnz 1b
    dec rax
    ret

# tmkdir(path): best effort
tmkdir:
    mov esi, 0x1ed
    jmp os_mkdir

# tchdir(path) -> 0 | -errno
tchdir:
    mov eax, SYS_chdir
    syscall
    ret

# twrite(path, ptr, len) -> 0 | -errno
twrite:
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov esi, O_WRONLY | O_CREAT | O_TRUNC
    mov edx, 0x1a4
    call os_open
    test rax, rax
    js .Ltw_out
    mov r14d, eax
    mov edi, r14d
    mov rsi, r12
    mov rdx, r13
    call write_all
    mov r15, rax
    mov edi, r14d
    call os_close
    mov rax, r15
.Ltw_out:
    EPILOGUE

FN opcode_main
    PROLOGUE
    # absolute repo root
    lea rdi, [rip + t_root]
    mov esi, 512
    call os_getcwd
    test rax, rax
    js .Lfail

    # t_home = root + "/build/config_test_home"
    lea rdi, [rip + t_home]
    lea rsi, [rip + t_root]
    call tscat
    mov rdi, rax
    lea rsi, [rip + s_home_sub]
    call tscat

    # t_usercfg = t_home + "/config.jsonc"
    lea rdi, [rip + t_usercfg]
    lea rsi, [rip + t_home]
    call tscat
    mov rdi, rax
    lea rsi, [rip + s_config_sub]
    call tscat

    # t_proj = root + "/build/config_test_proj"
    lea rdi, [rip + t_proj]
    lea rsi, [rip + t_root]
    call tscat
    mov rdi, rax
    lea rsi, [rip + s_proj_sub]
    call tscat

    # t_projopcode = t_proj + "/.opcode"
    lea rdi, [rip + t_projopcode]
    lea rsi, [rip + t_proj]
    call tscat
    mov rdi, rax
    lea rsi, [rip + s_dotopcode_sub]
    call tscat

    # t_projcfg = t_projopcode + "/config.jsonc"
    lea rdi, [rip + t_projcfg]
    lea rsi, [rip + t_projopcode]
    call tscat
    mov rdi, rax
    lea rsi, [rip + s_config_sub]
    call tscat

    # t_trust = t_home + "/trust.jsonc"
    lea rdi, [rip + t_trust]
    lea rsi, [rip + t_home]
    call tscat
    mov rdi, rax
    lea rsi, [rip + s_trust_sub]
    call tscat

    # t_auth = t_home + "/auth.jsonc"
    lea rdi, [rip + t_auth]
    lea rsi, [rip + t_home]
    call tscat
    mov rdi, rax
    lea rsi, [rip + s_auth_sub]
    call tscat

    # g_config_home override + directories
    lea rax, [rip + t_home]
    mov [rip + g_config_home], rax
    lea rdi, [rip + t_home]
    call tmkdir
    lea rdi, [rip + t_proj]
    call tmkdir
    lea rdi, [rip + t_projopcode]
    call tmkdir

    # start clean so the test is idempotent
    lea rdi, [rip + t_trust]
    call os_unlink
    lea rdi, [rip + t_auth]
    call os_unlink

    # user config.jsonc (comments + trailing commas)
    lea rdi, [rip + t_usercfg]
    lea rsi, [rip + user_doc]
    mov edx, user_doc_len
    call twrite
    test rax, rax
    js .Lfail

    # ---- user config ----
    call config_load
    lea rdi, [rip + k_default_provider]
    call config_str
    test rax, rax
    jz .Lfail
    mov rdi, rax
    lea rsi, [rip + v_anthropic]
    call teq
    cmp eax, 1
    jne .Lfail

    lea rdi, [rip + v_openai]
    call config_provider_base
    test rax, rax
    jz .Lfail
    mov rdi, rax
    lea rsi, [rip + v_base]
    call teq
    cmp eax, 1
    jne .Lfail

    call config_session_dir
    test rax, rax
    jz .Lfail
    mov rdi, rax
    lea rsi, [rip + v_sessions]
    call teq
    cmp eax, 1
    jne .Lfail

    lea rdi, [rip + v_openai]
    call config_api_key
    test rax, rax
    jz .Lfail
    mov rdi, rax
    lea rsi, [rip + v_key]
    call teq
    cmp eax, 1
    jne .Lfail

    lea rdi, [rip + m_user]
    call tprint

    # ---- project config: trust off ----
    lea rdi, [rip + t_projcfg]
    lea rsi, [rip + proj_doc]
    mov edx, proj_doc_len
    call twrite
    test rax, rax
    js .Lfail

    call config_load
    lea rdi, [rip + k_default_provider]
    call config_str
    test rax, rax
    jz .Lfail
    mov rdi, rax
    lea rsi, [rip + v_anthropic]
    call teq
    cmp eax, 1
    jne .Lfail
    lea rdi, [rip + m_off]
    call tprint

    # ---- project config: --approve + cwd=project ----
    lea rdi, [rip + t_proj]
    call tchdir
    test rax, rax
    js .Lfail
    mov qword ptr [rip + g_config_approve], 1
    call config_load
    lea rdi, [rip + k_default_provider]
    call config_str
    test rax, rax
    jz .Lfail
    mov rdi, rax
    lea rsi, [rip + v_project]
    call teq
    cmp eax, 1
    jne .Lfail
    lea rdi, [rip + m_on]
    call tprint

    lea rdi, [rip + t_proj]
    call config_trusted
    cmp eax, 1
    jne .Lfail

    # ---- auth: flag ----
    lea rdi, [rip + v_flag]
    call auth_set_flag
    lea rdi, [rip + v_anthropic]
    call auth_key
    test rax, rax
    jz .Lfail
    mov rdi, rax
    lea rsi, [rip + v_flag]
    call teq
    cmp eax, 1
    jne .Lfail
    lea rdi, [rip + m_flagok]
    call tprint

    # ---- auth: auth.jsonc ----
    lea rdi, [rip + t_auth]
    lea rsi, [rip + auth_doc]
    mov edx, auth_doc_len
    call twrite
    test rax, rax
    js .Lfail
    xor edi, edi
    call auth_set_flag
    lea rdi, [rip + v_openai]
    call auth_key
    test rax, rax
    jz .Lfail
    mov rdi, rax
    lea rsi, [rip + v_oauth]
    call teq
    cmp eax, 1
    jne .Lfail
    lea rdi, [rip + m_fileok]
    call tprint

    # ---- silent roundtrip: trust_save then trust.jsonc lookup ----
    mov qword ptr [rip + g_config_approve], 0
    lea rdi, [rip + t_proj]
    call config_trust_save
    test rax, rax
    js .Lfail
    lea rdi, [rip + t_proj]
    call config_trusted
    cmp eax, 1
    jne .Lfail

    lea rdi, [rip + m_done]
    call tprint
    xor eax, eax
    EPILOGUE
.Lfail:
    lea rdi, [rip + m_fail]
    call tprint
    mov eax, 1
    EPILOGUE
