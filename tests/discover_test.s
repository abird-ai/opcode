.include "opcode.inc"
.include "core/core.inc"
# discover_test: exercise discover_models + catalog_load_user end to end.
#
# Mock build (run.sh): replays tests/data/discover_models.wire through the mock
# net backend and writes into build/discover_test_cfg/ (never the user's real
# config dir).  Live build (tests/ollama.sh assembles this file with
# --defsym OPCODE_LIVE=1): argv[1] is the base URL, g_discover_base overrides
# it and the real network stack is used.
#
# Prints "discover tags ok" then "discover cache ok"; exits 1 on any failure.

.section .rodata
.Lprov:     .asciz "ollama"
.Lmid:      .asciz "qwen2.5:7b"
.Lapi:      .asciz "openai-chat"
.Lok_tags:  .asciz "discover tags ok\n"
.Lok_cache: .asciz "discover cache ok\n"
.Lfailmsg:  .asciz "FAIL discover\n"
.Lwire:     .asciz "tests/data/discover_models.wire"
.Lcfgdir:   .asciz "build/discover_test_cfg"
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

FN opcode_main
    PROLOGUE
.ifdef OPCODE_LIVE
    # base URL comes from argv[1]; XDG_CONFIG_HOME selects the config dir
    mov rax, [rip + g_argc]
    cmp rax, 2
    jb .Lfail
    mov rax, [rip + g_argv]
    mov rax, [rax + 8]
    mov [rip + g_discover_base], rax
    mov esi, 1                  # verbose
.else
    # deterministic mock backend: replay the recorded /v1/models response
    lea rdi, [rip + .Lwire]
    call mock_open
    test rax, rax
    js .Lfail
    lea rax, [rip + .Lcfgdir]
    mov [rip + g_config_home], rax
    lea rdi, [rip + .Lcfgdir]
    mov esi, 0755
    call os_mkdir
    xor esi, esi                # quiet: run.sh compares stderr too
.endif
    lea rdi, [rip + .Lprov]
    call discover_models
    test rax, rax
    js .Lfail
    cmp rax, 2
    jne .Lfail
    lea rdi, [rip + .Lok_tags]
    call print

    # models.jsonc must now be loadable and findable through the catalog
    call catalog_load_user
    test rax, rax
    jz .Lfail
    lea rdi, [rip + .Lprov]
    lea rsi, [rip + .Lmid]
    call catalog_find
    test rax, rax
    jz .Lfail
    test dword ptr [rax + MD_flags], MDF_NO_KEY
    jz .Lfail
    mov rbx, rax
    mov rdi, [rbx + MD_api]
    call strlen
    mov rsi, rax
    mov rdi, [rbx + MD_api]
    lea rdx, [rip + .Lapi]
    mov ecx, 11
    call str_eq
    cmp eax, 1
    jne .Lfail
    lea rdi, [rip + .Lok_cache]
    call print
    xor eax, eax
    EPILOGUE
.Lfail:
    lea rdi, [rip + .Lfailmsg]
    call print
    mov eax, 1
    EPILOGUE
