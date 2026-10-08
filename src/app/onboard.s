# onboard.s: first-run provider onboarding for `opcode` (TUI) and `opcode -p`.
#
#   onboard_maybe() -> 0 proceed | 2 skip/no-tty (caller exits 2)
#
# Trigger rule: never run when a provider+model is resolvable from --provider /
# --model, config.jsonc (default_provider / default_model), env keys
# (ANTHROPIC_API_KEY, OPENAI_API_KEY, OLLAMA_API_KEY), a stored credential
# (auth.jsonc / OAuth store / config api_keys), a discovered cache, or a quick
# local Ollama probe.  With a TTY the provider and model choices are presented
# through the modal picker (opcode_pick_tty); without a TTY it prints the
# options and the caller exits 2.
.include "opcode.inc"
.include "core/core.inc"

.extern opcode_catalog, opcode_catalog_count
.extern catalog_count, catalog_at, catalog_default, catalog_load_user
.extern discover_models, config_provider_at
.extern config_save, config_str, auth_key, g_discover_base
.extern g_agent_provider, g_agent_model
.extern opcode_pick_tty

.section .rodata
.Lkey_dp:       .asciz "default_provider"
.Lkey_dm:       .asciz "default_model"
.Lenv_anthropic: .asciz "ANTHROPIC_API_KEY"
.Lenv_openai:    .asciz "OPENAI_API_KEY"
.Lenv_ollama:    .asciz "OLLAMA_API_KEY"
.Lenv_gemini:    .asciz "GEMINI_API_KEY"
.Lenv_google:    .asciz "GOOGLE_API_KEY"
.Lp_ollama:      .asciz "ollama"
.Lp_ollama_cloud: .asciz "ollama-cloud"
.Lp_anthropic:   .asciz "anthropic"
.Lp_openai:      .asciz "openai"
.Lp_google:      .asciz "google"
.Lollama_local:  .asciz "http://127.0.0.1:11434"
.Lslash:         .asciz "/"
.Lnl:            .asciz "\n"
.Lprovider_title: .asciz "Choose a provider"
.Lmodel_title:    .asciz "Choose a model"
.Lpn_ollama:      .asciz "Ollama local"
.Lpn_cloud:       .asciz "Ollama Cloud"
.Lpn_anthropic:   .asciz "Anthropic"
.Lpn_openai:      .asciz "OpenAI"
.Lpn_google:      .asciz "Google"
.Lpn_skip:        .asciz "Skip for now"
.Lpd_ollama:      .asciz "no API key; http://127.0.0.1:11434"
.Lpd_cloud:       .asciz "opcode login ollama-cloud"
.Lpd_anthropic:   .asciz "opcode login anthropic (or --api-key / ANTHROPIC_API_KEY)"
.Lpd_openai:      .asciz "opcode login openai (or --api-key / OPENAI_API_KEY)"
.Lpd_google:      .asciz "set GEMINI_API_KEY (or --api-key)"
.Lpd_skip:        .asciz "pass --provider/--model, or set a key and re-run"
.Ldefault_mark:   .asciz "(default) "
.Lctx_mark:       .asciz " ctx="
.Lreason_mark:    .asciz " reasoning"
.Limage_mark:     .asciz " image"
.p2align 3
.Lprov_names:
    .quad .Lpn_ollama, .Lpn_cloud, .Lpn_anthropic, .Lpn_openai, .Lpn_google, .Lpn_skip
.Lprov_descs:
    .quad .Lpd_ollama, .Lpd_cloud, .Lpd_anthropic, .Lpd_openai, .Lpd_google, .Lpd_skip
.Lno_tty:
    .ascii "opcode: no provider is configured.\n"
    .ascii "  Ollama (local): no API key needed (http://127.0.0.1:11434)\n"
    .ascii "  Ollama Cloud:   opcode login ollama-cloud\n"
    .ascii "  Anthropic:      opcode login anthropic  (or --api-key / ANTHROPIC_API_KEY)\n"
    .ascii "  OpenAI:         opcode login openai     (or --api-key / OPENAI_API_KEY)\n"
    .ascii "  Google:         set GEMINI_API_KEY (or --api-key; OpenAI-compatible endpoint)\n"
    .ascii "  Skip:           pass --provider/--model, or set a key and re-run\n"
    .asciz ""
.Lconfigured:    .asciz "opcode: configured "
.Lauth_hint:     .asciz "opcode: authenticate with: opcode login "
.Lauth_hint_key: .asciz "opcode: set GEMINI_API_KEY or pass --api-key\n"
.Lno_models:     .asciz "opcode: no models available for "
.Lcancelled:     .asciz "opcode: onboarding cancelled\n"

.bss
.p2align 3
onboard_term: .zero 64

.text

# onboard_env(name cstr) -> cstr | 0 (leaf; walks g_envp)
onboard_env:
    mov r8, [rip + g_envp]
    test r8, r8
    jz .Loe_none
    mov r9, rdi
.Loe_next:
    mov rsi, [r8]
    test rsi, rsi
    jz .Loe_none
    mov rdi, r9
    mov rdx, rsi
.Loe_cmp:
    mov al, [rdi]
    test al, al
    jz .Loe_name_end
    cmp al, [rdx]
    jne .Loe_skip
    inc rdi
    inc rdx
    jmp .Loe_cmp
.Loe_name_end:
    cmp byte ptr [rdx], '='
    jne .Loe_skip
    lea rax, [rdx + 1]
    ret
.Loe_skip:
    add r8, 8
    jmp .Loe_next
.Loe_none:
    xor eax, eax
    ret

# onboard_is_tty() -> 1|0: os_tty_raw succeeds only on a terminal.  Restores
# the exact original settings before returning.
onboard_is_tty:
    PROLOGUE 96
    lea rdi, [rsp]
    call os_tty_raw
    test rax, rax
    js .Loit_no
    lea rdi, [rsp]
    call os_tty_restore
    mov eax, 1
    EPILOGUE
.Loit_no:
    xor eax, eax
    EPILOGUE

# onboard_md_eq(a, b) -> 1|0: same provider and id.
onboard_md_eq:
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
    jz .Lome_no
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
.Lome_no:
    xor eax, eax
    EPILOGUE

# onboard_is_builtin(md) -> 1|0
onboard_is_builtin:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, [rip + opcode_catalog_count]
    xor r13d, r13d
    xor r14d, r14d
.Loib_loop:
    cmp r13, r12
    jae .Loib_out
    imul rax, r13, MD_SIZE
    lea rdi, [rip + opcode_catalog]
    add rdi, rax
    mov rsi, rbx
    call onboard_md_eq
    test eax, eax
    jnz .Loib_yes
    inc r13
    jmp .Loib_loop
.Loib_yes:
    mov r14d, 1
.Loib_out:
    mov eax, r14d
    EPILOGUE

# onboard_pick_model(provider) -> MD* | 0: catalog_default, else the first
# catalogue/discovered entry for the provider.
onboard_pick_model:
    PROLOGUE 16
    mov rbx, rdi
    call catalog_default
    test rax, rax
    jnz .Lopm_out
    call catalog_count
    mov r12, rax
    xor r13d, r13d
.Lopm_loop:
    cmp r13, r12
    jae .Lopm_none
    mov rdi, r13
    call catalog_at
    test rax, rax
    jz .Lopm_none
    mov r14, rax
    mov rdi, [r14 + MD_provider]
    call strlen
    mov rsi, rax
    mov rdi, [r14 + MD_provider]
    mov rdx, rbx
    call str_eq_cstr
    test eax, eax
    jnz .Lopm_hit
    inc r13
    jmp .Lopm_loop
.Lopm_hit:
    mov rax, r14
    EPILOGUE
.Lopm_none:
    xor eax, eax
    EPILOGUE
.Lopm_out:
    EPILOGUE

# onboard_first_discovered() -> MD* | 0: first non-generated entry.
onboard_first_discovered:
    PROLOGUE 16
    call catalog_count
    mov r12, rax
    xor r13d, r13d
.Lofd_loop:
    cmp r13, r12
    jae .Lofd_none
    mov rdi, r13
    call catalog_at
    test rax, rax
    jz .Lofd_none
    mov r14, rax
    mov rdi, r14
    call onboard_is_builtin
    test eax, eax
    jz .Lofd_hit
    inc r13
    jmp .Lofd_loop
.Lofd_hit:
    mov rax, r14
    EPILOGUE
.Lofd_none:
    xor eax, eax
    EPILOGUE

# onboard_resolve() -> 1 when a provider (and usually a model) is resolvable,
# 0 when onboarding is needed.  Sets g_agent_provider/g_agent_model on success.
onboard_resolve:
    PROLOGUE 144
    mov qword ptr [rsp], 0          # saved g_discover_base
    call catalog_load_user
    # 1. explicit --provider (and --model)
    mov rdi, [rip + g_agent_provider]
    test rdi, rdi
    jz .Lor_config
    cmp qword ptr [rip + g_agent_model], 0
    jne .Lor_yes
    call onboard_pick_model
    test rax, rax
    jz .Lor_yes
    mov rax, [rax + MD_id]
    mov [rip + g_agent_model], rax
    jmp .Lor_yes
.Lor_config:
    # 2. config default_provider / default_model
    lea rdi, [rip + .Lkey_dp]
    call config_str
    test rax, rax
    jz .Lor_env
    mov [rip + g_agent_provider], rax
    lea rdi, [rip + .Lkey_dm]
    call config_str
    test rax, rax
    jz .Lor_cfg_model
    mov [rip + g_agent_model], rax
    jmp .Lor_yes
.Lor_cfg_model:
    mov rdi, [rip + g_agent_provider]
    call onboard_pick_model
    test rax, rax
    jz .Lor_yes
    mov rax, [rax + MD_id]
    mov [rip + g_agent_model], rax
    jmp .Lor_yes
.Lor_env:
    # 3. env keys (OpenAI is the documented default preference)
    lea rdi, [rip + .Lenv_openai]
    call onboard_env
    test rax, rax
    jz .Lor_env_anthropic
    lea rdi, [rip + .Lp_openai]
    call onboard_set_provider
    jmp .Lor_yes
.Lor_env_anthropic:
    lea rdi, [rip + .Lenv_anthropic]
    call onboard_env
    test rax, rax
    jz .Lor_env_google
    lea rdi, [rip + .Lp_anthropic]
    call onboard_set_provider
    jmp .Lor_yes
.Lor_env_google:
    lea rdi, [rip + .Lenv_gemini]
    call onboard_env
    test rax, rax
    jz .Lor_env_google2
    lea rdi, [rip + .Lp_google]
    call onboard_set_provider
    jmp .Lor_yes
.Lor_env_google2:
    lea rdi, [rip + .Lenv_google]
    call onboard_env
    test rax, rax
    jz .Lor_env_ollama
    lea rdi, [rip + .Lp_google]
    call onboard_set_provider
    jmp .Lor_yes
.Lor_env_ollama:
    lea rdi, [rip + .Lenv_ollama]
    call onboard_env
    test rax, rax
    jz .Lor_auth
    lea rdi, [rip + .Lp_ollama_cloud]
    call onboard_set_provider
    jmp .Lor_yes
.Lor_auth:
    # 4. stored credential (auth.jsonc / OAuth store / config api_keys)
    lea rdi, [rip + .Lp_openai]
    call auth_key
    test rax, rax
    jz .Lor_auth_anthropic
    mov rdi, rax
    call mem_free
    lea rdi, [rip + .Lp_openai]
    call onboard_set_provider
    jmp .Lor_yes
.Lor_auth_anthropic:
    lea rdi, [rip + .Lp_anthropic]
    call auth_key
    test rax, rax
    jz .Lor_auth_google
    mov rdi, rax
    call mem_free
    lea rdi, [rip + .Lp_anthropic]
    call onboard_set_provider
    jmp .Lor_yes
.Lor_auth_google:
    lea rdi, [rip + .Lp_google]
    call auth_key
    test rax, rax
    jz .Lor_auth_ollama
    mov rdi, rax
    call mem_free
    lea rdi, [rip + .Lp_google]
    call onboard_set_provider
    jmp .Lor_yes
.Lor_auth_ollama:
    lea rdi, [rip + .Lp_ollama_cloud]
    call auth_key
    test rax, rax
    jz .Lor_discovered
    mov rdi, rax
    call mem_free
    lea rdi, [rip + .Lp_ollama_cloud]
    call onboard_set_provider
    jmp .Lor_yes
.Lor_discovered:
    # 5. discovered cache
    call onboard_first_discovered
    test rax, rax
    jz .Lor_probe
    mov rdx, [rax + MD_provider]
    mov [rip + g_agent_provider], rdx
    mov rdx, [rax + MD_id]
    mov [rip + g_agent_model], rdx
    jmp .Lor_yes
.Lor_probe:
    # 6. local Ollama quick probe (bounded by discover_models)
    mov rax, [rip + g_discover_base]
    mov [rsp], rax
    test rax, rax
    jnz .Lor_probe_go
    lea rax, [rip + .Lollama_local]
    mov [rip + g_discover_base], rax
.Lor_probe_go:
    lea rdi, [rip + .Lp_ollama]
    xor esi, esi
    call discover_models
    mov r12, rax
    mov rax, [rsp]
    mov [rip + g_discover_base], rax
    test r12, r12
    jle .Lor_no
    call catalog_load_user
    lea rdi, [rip + .Lp_ollama]
    call onboard_pick_model
    test rax, rax
    jz .Lor_no
    mov rdx, [rax + MD_id]
    mov [rip + g_agent_model], rdx
    lea rdx, [rip + .Lp_ollama]
    mov [rip + g_agent_provider], rdx
    jmp .Lor_yes
.Lor_no:
    xor eax, eax
    EPILOGUE
.Lor_yes:
    mov eax, 1
    EPILOGUE

# onboard_set_provider(provider cstr): set the provider global and pick a model.
onboard_set_provider:
    PROLOGUE 16
    mov rbx, rdi
    mov [rip + g_agent_provider], rbx
    call onboard_pick_model
    test rax, rax
    jz .Losp_done
    mov rax, [rax + MD_id]
    mov [rip + g_agent_model], rax
.Losp_done:
    mov eax, 1
    EPILOGUE

# onboard_out(fd, cstr): write_all wrapper.
onboard_out:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rsi
    call strlen
    mov edi, ebx
    mov rsi, r12
    mov rdx, rax
    call write_all
    EPILOGUE

# onboard_notty(): the no-TTY explanation block (stdout).
onboard_notty:
    mov edi, 1
    lea rsi, [rip + .Lno_tty]
    jmp onboard_out

# onboard_apply(provider, need_auth) -> 0 proceed | 2 no model / cancelled.
# Runs discovery, offers the provider's catalog + discovered models in the modal
# picker, saves the choice with config_save and prints the login command for
# cloud providers.  Esc cancels onboarding; no models keeps the old message.
onboard_apply:
    PROLOGUE 176
    mov rbx, rdi                    # provider
    mov r12d, esi                   # need_auth
    mov qword ptr [rsp], 0          # saved discover base
    mov qword ptr [rsp + 8], 0      # names array
    mov qword ptr [rsp + 16], 0     # descs array
    mov qword ptr [rsp + 24], 0     # model pointer array
    mov qword ptr [rsp + 32], 0     # nmatch
    mov qword ptr [rsp + 40], 0     # initial index
    mov qword ptr [rsp + 48], 0     # catalog count
    mov qword ptr [rsp + 72], 0     # result
    mov qword ptr [rsp + 104], 0    # default MD*
    # row-building SB at [rsp + 80]
    mov qword ptr [rsp + 80 + SB_ptr], 0
    mov qword ptr [rsp + 80 + SB_len], 0
    mov qword ptr [rsp + 80 + SB_cap], 0
    mov rax, [rip + g_discover_base]
    mov [rsp], rax
    test rax, rax
    jnz .Loa_go
    mov rdi, rbx
    lea rsi, [rip + .Lp_ollama]
    call strq_eq
    test eax, eax
    jz .Loa_go
    lea rax, [rip + .Lollama_local]
    mov [rip + g_discover_base], rax
.Loa_go:
    mov rdi, rbx
    xor esi, esi
    call discover_models
    mov rax, [rsp]
    mov [rip + g_discover_base], rax
    call catalog_load_user
    # first pass: count the provider's models
    call catalog_count
    mov [rsp + 48], rax
    xor r13d, r13d
    xor r14d, r14d
.Loa_count:
    cmp r13, [rsp + 48]
    jae .Loa_counted
    mov rdi, r13
    call catalog_at
    test rax, rax
    jz .Loa_count_next
    mov r15, rax
    mov rdi, [r15 + MD_provider]
    call strlen
    mov rsi, rax
    mov rdi, [r15 + MD_provider]
    mov rdx, rbx
    call str_eq_cstr
    test eax, eax
    jz .Loa_count_next
    inc r14
.Loa_count_next:
    inc r13
    jmp .Loa_count
.Loa_counted:
    test r14, r14
    jz .Loa_nomodel
    mov [rsp + 32], r14
    mov rdi, r14
    shl rdi, 3
    call mem_alloc
    mov [rsp + 8], rax
    mov rdi, [rsp + 32]
    shl rdi, 3
    call mem_alloc
    mov [rsp + 16], rax
    mov rdi, [rsp + 32]
    shl rdi, 3
    call mem_alloc
    mov [rsp + 24], rax
    # the catalog default is the initial selection
    mov rdi, rbx
    call catalog_default
    mov [rsp + 104], rax
    xor r13d, r13d
    xor r14d, r14d
.Loa_fill:
    cmp r13, [rsp + 48]
    jae .Loa_filled
    mov rdi, r13
    call catalog_at
    test rax, rax
    jz .Loa_fill_next
    mov r15, rax
    mov rdi, [r15 + MD_provider]
    call strlen
    mov rsi, rax
    mov rdi, [r15 + MD_provider]
    mov rdx, rbx
    call str_eq_cstr
    test eax, eax
    jz .Loa_fill_next
    mov rax, [rsp + 8]
    mov rdx, [r15 + MD_id]
    mov [rax + r14*8], rdx
    mov rax, [rsp + 24]
    mov [rax + r14*8], r15
    cmp r15, [rsp + 104]
    jne 1f
    mov [rsp + 40], r14
1:  lea rdi, [rsp + 80]
    call sb_clear
    cmp r15, [rsp + 104]
    jne 2f
    lea rdi, [rsp + 80]
    lea rsi, [rip + .Ldefault_mark]
    call sb_push_cstr
2:  lea rdi, [rsp + 80]
    mov rsi, [r15 + MD_provider]
    call sb_push_cstr
    mov eax, [r15 + MD_ctx_window]
    test eax, eax
    jz 3f
    lea rdi, [rsp + 80]
    lea rsi, [rip + .Lctx_mark]
    call sb_push_cstr
    lea rdi, [rsp + 80]
    mov esi, [r15 + MD_ctx_window]
    call sb_push_u64
3:  test dword ptr [r15 + MD_flags], MDF_REASONING
    jz 4f
    lea rdi, [rsp + 80]
    lea rsi, [rip + .Lreason_mark]
    call sb_push_cstr
4:  test dword ptr [r15 + MD_flags], MDF_IMAGE
    jz 5f
    lea rdi, [rsp + 80]
    lea rsi, [rip + .Limage_mark]
    call sb_push_cstr
5:  mov rdi, [rsp + 80 + SB_len]
    inc rdi
    call mem_alloc
    mov [rsp + 112], rax
    mov rdi, rax
    mov rsi, [rsp + 80 + SB_ptr]
    mov rdx, [rsp + 80 + SB_len]
    call memcpy
    mov rcx, [rsp + 112]
    mov rdx, [rsp + 80 + SB_len]
    mov byte ptr [rcx + rdx], 0
    mov rax, [rsp + 16]
    mov [rax + r14*8], rcx
    inc r14
.Loa_fill_next:
    inc r13
    jmp .Loa_fill
.Loa_filled:
    # the picker stores at most 32 rows; keep the initial index in range
    cmp qword ptr [rsp + 40], 32
    jb 6f
    mov qword ptr [rsp + 40], 0
6:  lea rdi, [rip + .Lmodel_title]
    mov rsi, [rsp + 8]
    mov rdx, [rsp + 16]
    mov rcx, r14
    mov r8, [rsp + 40]
    call opcode_pick_tty
    mov r13, rax                    # selection
    xor r15d, r15d                  # selected MD*
    test r13, r13
    js .Loa_free
    cmp r13, r14
    jae .Loa_free
    mov rcx, [rsp + 24]
    mov r15, [rcx + r13*8]
.Loa_free:
    xor r13d, r13d
.Loa_free_desc:
    cmp r13, r14
    jae .Loa_free_arrays
    mov rax, [rsp + 16]
    mov rdi, [rax + r13*8]
    call mem_free
    inc r13
    jmp .Loa_free_desc
.Loa_free_arrays:
    mov rdi, [rsp + 8]
    call mem_free
    mov rdi, [rsp + 16]
    call mem_free
    mov rdi, [rsp + 24]
    call mem_free
    lea rdi, [rsp + 80]
    call sb_free
    test r15, r15
    jz .Loa_cancel
    mov [rip + g_agent_provider], rbx
    mov rax, [r15 + MD_id]
    mov [rip + g_agent_model], rax
    mov rdi, rbx
    mov rsi, [r15 + MD_id]
    xor edx, edx
    call config_save
    mov edi, 1
    lea rsi, [rip + .Lconfigured]
    call onboard_out
    mov edi, 1
    mov rsi, rbx
    call onboard_out
    mov edi, 1
    lea rsi, [rip + .Lslash]
    call onboard_out
    mov edi, 1
    mov rsi, [r15 + MD_id]
    call onboard_out
    mov edi, 1
    lea rsi, [rip + .Lnl]
    call onboard_out
    cmp r12d, 2
    je .Loa_hint_key
    test r12d, r12d
    jz .Loa_ok
    mov edi, 1
    lea rsi, [rip + .Lauth_hint]
    call onboard_out
    mov edi, 1
    mov rsi, rbx
    call onboard_out
    mov edi, 1
    lea rsi, [rip + .Lnl]
    call onboard_out
    jmp .Loa_ok
.Loa_hint_key:
    mov edi, 1
    lea rsi, [rip + .Lauth_hint_key]
    call onboard_out
.Loa_ok:
    xor eax, eax
    EPILOGUE
.Loa_cancel:
    mov edi, 1
    lea rsi, [rip + .Lcancelled]
    call onboard_out
    mov eax, 2
    EPILOGUE
.Loa_nomodel:
    mov edi, 2
    lea rsi, [rip + .Lno_models]
    call onboard_out
    mov edi, 2
    mov rsi, rbx
    call onboard_out
    mov edi, 2
    lea rsi, [rip + .Lnl]
    call onboard_out
    mov eax, 2
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

# onboard_menu() -> 0 proceed | 2 skip (Esc or Skip for now)
onboard_menu:
    PROLOGUE 0
    lea rdi, [rip + .Lprovider_title]
    lea rsi, [rip + .Lprov_names]
    lea rdx, [rip + .Lprov_descs]
    mov ecx, 6
    xor r8d, r8d
    call opcode_pick_tty
    cmp rax, 0
    je .Lom_c1
    cmp rax, 1
    je .Lom_c2
    cmp rax, 2
    je .Lom_c3
    cmp rax, 3
    je .Lom_c4
    cmp rax, 4
    je .Lom_c5
    # index 5 (Skip for now) or -1 (Esc) -> skip
    mov eax, 2
    EPILOGUE
.Lom_c5:
    # 5) Google: API key, served over Google's OpenAI-compatible endpoint
    lea rdi, [rip + .Lp_google]
    mov esi, 2
    call onboard_apply
    EPILOGUE
.Lom_c4:
    lea rdi, [rip + .Lp_openai]
    mov esi, 1
    call onboard_apply
    EPILOGUE
.Lom_c1:
    lea rdi, [rip + .Lp_ollama]
    xor esi, esi
    call onboard_apply
    EPILOGUE
.Lom_c2:
    lea rdi, [rip + .Lp_ollama_cloud]
    mov esi, 1
    call onboard_apply
    EPILOGUE
.Lom_c3:
    lea rdi, [rip + .Lp_anthropic]
    mov esi, 1
    call onboard_apply
    EPILOGUE

# onboard_maybe() -> 0 proceed | 2 stop (message already printed)
FN onboard_maybe
    PROLOGUE 0
    call onboard_resolve
    test eax, eax
    jnz .Lomb_ok
    call onboard_is_tty
    test eax, eax
    jz .Lomb_notty
    call onboard_menu
    EPILOGUE
.Lomb_notty:
    call onboard_notty
    mov eax, 2
    EPILOGUE
.Lomb_ok:
    xor eax, eax
    EPILOGUE
