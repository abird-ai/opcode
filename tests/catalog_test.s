.include "opcode.inc"
.include "core/core.inc"
# catalog_test: model catalog lookups (count/find/default/missing) and the
# API key flag-vs-environment precedence.

.section .rodata
.p_anthropic: .asciz "anthropic"
.p_openai:    .asciz "openai"
.p_google:    .asciz "google"
.p_nope:      .asciz "nope"
.p_zzz:       .asciz "zzz"
.m_id:        .asciz "claude-haiku-4-5"
.m_gemini:    .asciz "gemini-2.5-pro"
.m_oai_api:   .asciz "openai-chat"
.m_api:       .asciz "anthropic-messages"
.m_base:      .asciz "https://api.anthropic.com"
.m_key:       .asciz "KEY123"

.m_count:   .asciz "catalog count ok\n"
.m_find:    .asciz "catalog find ok\n"
.m_default: .asciz "catalog default ok\n"
.m_missing: .asciz "catalog missing ok\n"
.m_auth:    .asciz "auth env ok\n"
.m_done:    .asciz "catalog done\n"
.m_fail:    .asciz "FAIL catalog\n"
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

    # catalog_count() > 0, catalog_at(0) valid, catalog_at(count) == 0
    call catalog_count
    test rax, rax
    jz .Lfail
    mov rbx, rax
    xor edi, edi
    call catalog_at
    test rax, rax
    jz .Lfail
    mov rdi, rbx
    call catalog_at
    test rax, rax
    jnz .Lfail
    lea rdi, [rip + .m_count]
    call print

    # catalog_find("anthropic", "claude-haiku-4-5") -> matching api and base
    lea rdi, [rip + .p_anthropic]
    lea rsi, [rip + .m_id]
    call catalog_find
    test rax, rax
    jz .Lfail
    mov rbx, rax
    mov rdi, [rbx + MD_api]
    call strlen
    mov rsi, rax
    mov rdi, [rbx + MD_api]
    lea rdx, [rip + .m_api]
    mov ecx, 18
    call str_eq
    cmp eax, 1
    jne .Lfail
    mov rdi, [rbx + MD_base]
    call strlen
    mov rsi, rax
    mov rdi, [rbx + MD_base]
    lea rdx, [rip + .m_base]
    mov ecx, 25
    call str_eq
    cmp eax, 1
    jne .Lfail
    mov eax, [rbx + MD_flags]
    and eax, MDF_REASONING | MDF_IMAGE
    cmp eax, MDF_REASONING | MDF_IMAGE
    jne .Lfail
    lea rdi, [rip + .m_find]
    call print

    # catalog_find("google", "gemini-2.5-pro") -> openai-chat api
    lea rdi, [rip + .p_google]
    lea rsi, [rip + .m_gemini]
    call catalog_find
    test rax, rax
    jz .Lfail
    mov rbx, rax
    mov rdi, [rbx + MD_api]
    call strlen
    mov rsi, rax
    mov rdi, [rbx + MD_api]
    lea rdx, [rip + .m_oai_api]
    mov ecx, 11
    call str_eq
    cmp eax, 1
    jne .Lfail
    mov eax, [rbx + MD_flags]
    and eax, MDF_REASONING | MDF_IMAGE
    cmp eax, MDF_REASONING | MDF_IMAGE
    jne .Lfail

    # catalog_default("openai") is the MDF_DEFAULT model
    lea rdi, [rip + .p_openai]
    call catalog_default
    test rax, rax
    jz .Lfail
    test dword ptr [rax + MD_flags], MDF_DEFAULT
    jz .Lfail
    lea rdi, [rip + .m_default]
    call print

    # catalog_find("nope", "nope") == 0
    lea rdi, [rip + .p_nope]
    lea rsi, [rip + .p_nope]
    call catalog_find
    test rax, rax
    jnz .Lfail
    lea rdi, [rip + .m_missing]
    call print

    # no flag yet: provider "zzz" cannot resolve (no ZZZ_API_KEY here)
    lea rdi, [rip + .p_zzz]
    call auth_key
    test rax, rax
    jnz .Lfail
    lea rdi, [rip + .m_auth]
    call print

    # flag wins: auth_key("anthropic") == "KEY123"
    lea rdi, [rip + .m_key]
    call auth_set_flag
    lea rdi, [rip + .p_anthropic]
    call auth_key
    test rax, rax
    jz .Lfail
    mov rdi, rax
    mov rsi, 6
    lea rdx, [rip + .m_key]
    mov ecx, 6
    call str_eq
    cmp eax, 1
    jne .Lfail
    lea rdi, [rip + .m_done]
    call print

    xor eax, eax
    EPILOGUE
.Lfail:
    lea rdi, [rip + .m_fail]
    call print
    mov eax, 1
    EPILOGUE
