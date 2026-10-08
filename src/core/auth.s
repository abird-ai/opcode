.include "opcode.inc"
.include "core/core.inc"
# API key resolution chain (M3):
#   1. the --api-key flag (auth_set_flag)
#   2. auth.jsonc in the user config dir: {"<provider>":{"api_key":"..."}}
#   3. the provider environment variable, e.g. ANTHROPIC_API_KEY,
#      OPENAI_API_KEY, or the generic <UPPER(provider)>_API_KEY
#   4. config.jsonc api_keys.<provider>
# auth_set_flag() borrows the caller's --api-key pointer.  auth_key() has a
# single ownership contract: every non-NULL result is a fresh mem_alloc'd copy
# owned by the caller (the flag and environment hits are duplicated too); NULL
# means no key was found.

.bss
.p2align 3
auth_flag: .quad 0

.section .rodata
.Lname_anthropic: .asciz "anthropic"
.Lname_openai:    .asciz "openai"
.Lname_ollama_cloud: .asciz "ollama-cloud"
.Lname_google:    .asciz "google"
.Lenv_anthropic:  .asciz "ANTHROPIC_API_KEY"
.Lenv_openai:     .asciz "OPENAI_API_KEY"
.Lenv_ollama:     .asciz "OLLAMA_API_KEY"
.Lenv_gemini:     .asciz "GEMINI_API_KEY"
.Lenv_google:     .asciz "GOOGLE_API_KEY"
.Lapi_suffix:     .asciz "_API_KEY"
.Lauth_name:      .asciz "/auth.jsonc"
.Lapi_key:        .asciz "api_key"
.text

# env_get(name cstr) -> cstr | 0.  Case-sensitive walk of the NULL-terminated
# g_envp array looking for "name=" and returning the value pointer.
.Lenv_get:
    PROLOGUE 0
    mov r8, [rip + g_envp]
    test r8, r8
    jz .Leg_none
    mov r9, rdi
.Leg_next:
    mov rsi, [r8]
    test rsi, rsi
    jz .Leg_none
    mov rdi, r9
    mov rdx, rsi
.Leg_cmp:
    mov al, [rdi]
    test al, al
    jz .Leg_name_end
    cmp al, [rdx]
    jne .Leg_skip
    inc rdi
    inc rdx
    jmp .Leg_cmp
.Leg_name_end:
    cmp byte ptr [rdx], '='
    jne .Leg_skip
    lea rax, [rdx + 1]
    EPILOGUE
.Leg_skip:
    add r8, 8
    jmp .Leg_next
.Leg_none:
    xor eax, eax
    EPILOGUE

# auth_set_flag(key cstr): remember the --api-key value (borrowed pointer)
FN auth_set_flag
    PROLOGUE 0
    mov [rip + auth_flag], rdi
    EPILOGUE

# auth_file_key(provider cstr) -> mem_alloc'd cstr | 0.  Reads
# {"<provider>":{"api_key":"..."}} from <config dir>/auth.jsonc.
.Lauth_file_key:
    PROLOGUE 48
    mov rbx, rdi
    call config_user_dir
    test rax, rax
    jz .Lafk_none
    mov rdi, rax
    lea rsi, [rip + .Lauth_name]
    call config_path_join
    test rax, rax
    jz .Lafk_none
    mov r12, rax
    xor eax, eax
    mov [rsp], rax
    mov [rsp + 8], rax
    mov [rsp + 16], rax
    mov rdi, r12
    lea rsi, [rsp]
    call config_read_file
    test eax, eax
    jz .Lafk_free
    mov rdi, [rsp + SB_ptr]
    mov rsi, [rsp + SB_len]
    call json_parse
    test rax, rax
    jz .Lafk_free
    mov rdi, rax
    mov rsi, rbx
    call json_get
    test rax, rax
    jz .Lafk_free
    mov rdi, rax
    lea rsi, [rip + .Lapi_key]
    call json_get
    test rax, rax
    jz .Lafk_free
    mov rdi, rax
    call json_str_cstr
    test rax, rax
    jz .Lafk_free
    mov r13, rax                # arena bytes (no embedded NUL)
    mov r14, rdx                # length
    lea rdi, [rsp]
    call sb_free
    mov rdi, r13
    mov rsi, r14
    call mem_dup
    mov r13, rax
    mov rdi, r12
    call mem_free
    mov rax, r13
    EPILOGUE
.Lafk_free:
    lea rdi, [rsp]
    call sb_free
    mov rdi, r12
    call mem_free
.Lafk_none:
    xor eax, eax
    EPILOGUE

# auth_key(provider cstr) -> cstr | 0.  Flag, OAuth store, auth.jsonc,
# environment, config.  auth_last_was_oauth() reports whether the result came
# from the OAuth store.
FN auth_key
    PROLOGUE 144
    mov qword ptr [rip + oauth_last], 0
    mov qword ptr [rip + oauth_present], 0
    mov rax, [rip + auth_flag]
    test rax, rax
    jnz .Lak_dup
    mov rbx, rdi
    mov rdi, rbx
    call oauth_access_token
    test rax, rax
    jnz .Lak_out
    # a stored OAuth credential owns the provider: an expired/unrefreshable
    # token is an error, never a silent fallback to an ambient key
    cmp qword ptr [rip + oauth_present], 0
    jne .Lak_oauth_stale
    mov rdi, rbx
    call .Lauth_file_key
    test rax, rax
    jnz .Lak_out
    mov rdi, rbx
    call strlen
    mov r12, rax
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lname_anthropic]
    mov ecx, 9
    call str_eq
    test eax, eax
    jnz .Lak_anthropic
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lname_openai]
    mov ecx, 6
    call str_eq
    test eax, eax
    jnz .Lak_openai
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lname_ollama_cloud]
    mov ecx, 12
    call str_eq
    test eax, eax
    jnz .Lak_ollama
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lname_google]
    mov ecx, 6
    call str_eq
    test eax, eax
    jnz .Lak_google

    # generic provider: UPPER(provider) + "_API_KEY" on the stack
    cmp r12, 128 - 9
    ja .Lak_config
    xor ecx, ecx
.Lak_upper:
    mov al, [rbx + rcx]
    test al, al
    jz .Lak_suffix
    cmp al, 'a'
    jb .Lak_store
    cmp al, 'z'
    ja .Lak_store
    sub al, 32
.Lak_store:
    mov [rsp + rcx], al
    inc rcx
    jmp .Lak_upper
.Lak_suffix:
    lea rsi, [rip + .Lapi_suffix]
    lea rdx, [rsp + rcx]
    mov r13d, 9
.Lak_copy:
    mov al, [rsi]
    mov [rdx], al
    inc rsi
    inc rdx
    dec r13d
    jnz .Lak_copy
    lea rdi, [rsp]
    call .Lenv_get
    test rax, rax
    jnz .Lak_dup
    jmp .Lak_config

.Lak_anthropic:
    lea rdi, [rip + .Lenv_anthropic]
    call .Lenv_get
    test rax, rax
    jnz .Lak_dup
    jmp .Lak_config
.Lak_openai:
    lea rdi, [rip + .Lenv_openai]
    call .Lenv_get
    test rax, rax
    jnz .Lak_dup
    jmp .Lak_config
.Lak_ollama:
    lea rdi, [rip + .Lenv_ollama]
    call .Lenv_get
    test rax, rax
    jnz .Lak_dup
    jmp .Lak_config
.Lak_google:
    # Gemini is usually set as GEMINI_API_KEY; accept GOOGLE_API_KEY too
    lea rdi, [rip + .Lenv_gemini]
    call .Lenv_get
    test rax, rax
    jnz .Lak_dup
    lea rdi, [rip + .Lenv_google]
    call .Lenv_get
    test rax, rax
    jnz .Lak_dup
    jmp .Lak_config
.Lak_config:
    mov rdi, rbx
    call config_api_key
    jmp .Lak_out
.Lak_oauth_stale:
    xor eax, eax
    jmp .Lak_out

# .Lak_dup: rax is a borrowed flag/environment cstr; return an owned copy so
# every auth_key() success has exactly one owner (the caller).
.Lak_dup:
    mov [rsp + 128], rax
    mov rdi, rax
    call strlen
    mov rdi, [rsp + 128]
    mov rsi, rax
    call mem_dup
.Lak_out:
    EPILOGUE

# auth_last_was_oauth() -> 1|0: set by the oauth_access_token() call inside
# auth_key(); 0 after the flag path or any non-OAuth hit.
FN auth_last_was_oauth
    mov rax, [rip + oauth_last]
    ret
