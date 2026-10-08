# login.s: opcode login|logout [provider] [--oauth-* flags]
.include "opcode.inc"

.section .rodata
.Lopt_auth:    .asciz "--oauth-auth-url"
.Lopt_token:   .asciz "--oauth-token-url"
.Lopt_client:  .asciz "--oauth-client-id"
.Lopt_scope:   .asciz "--oauth-scope"
.Lopt_nobrow:  .asciz "--no-browser"
.Ldef_prov:    .asciz "openai"
.Lcmd_login:   .asciz "login"
.Lerr_usage:   .asciz "usage: opcode login|logout [provider] [--oauth-auth-url URL] [--oauth-token-url URL] [--oauth-client-id ID] [--oauth-scope S] [--no-browser]"
.Lnl:          .asciz "\n"

.bss
.p2align 3
l_provider: .zero 8
l_cmd:      .zero 8

.text

# cstr_eq (leaf)
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

out_cstr:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rsi
    call strlen
    mov edi, ebx
    mov rsi, r12
    mov rdx, rax
    call write_all
    EPILOGUE

# opcode_login_main(argc, argv) -> exit code; argv[0] is "login" or "logout"
FN opcode_login_main
    PROLOGUE
    mov r15, rdi
    mov r14, rsi
    mov r13, [r14]              # command cstr
    lea rax, [rip + .Ldef_prov]
    mov [rip + l_provider], rax
    mov r12, 0
.Lll_loop:
    inc r12
    cmp r12, r15
    jae .Lll_parsed
    mov rbx, [r14 + r12*8]
    cmp byte ptr [rbx], '-'
    jne .Lll_provider
    mov rdi, rbx
    lea rsi, [rip + .Lopt_auth]
    call cstr_eq
    test eax, eax
    jnz .Lll_auth
    mov rdi, rbx
    lea rsi, [rip + .Lopt_token]
    call cstr_eq
    test eax, eax
    jnz .Lll_token
    mov rdi, rbx
    lea rsi, [rip + .Lopt_client]
    call cstr_eq
    test eax, eax
    jnz .Lll_client
    mov rdi, rbx
    lea rsi, [rip + .Lopt_scope]
    call cstr_eq
    test eax, eax
    jnz .Lll_scope
    mov rdi, rbx
    lea rsi, [rip + .Lopt_nobrow]
    call cstr_eq
    test eax, eax
    jnz .Lll_nobrow
    jmp .Lll_usage
.Lll_auth:
    inc r12
    cmp r12, r15
    jae .Lll_usage
    mov rax, [r14 + r12*8]
    mov [rip + g_oauth_auth_url], rax
    jmp .Lll_next
.Lll_token:
    inc r12
    cmp r12, r15
    jae .Lll_usage
    mov rax, [r14 + r12*8]
    mov [rip + g_oauth_token_url], rax
    jmp .Lll_next
.Lll_client:
    inc r12
    cmp r12, r15
    jae .Lll_usage
    mov rax, [r14 + r12*8]
    mov [rip + g_oauth_client_id], rax
    jmp .Lll_next
.Lll_scope:
    inc r12
    cmp r12, r15
    jae .Lll_usage
    mov rax, [r14 + r12*8]
    mov [rip + g_oauth_scope], rax
    jmp .Lll_next
.Lll_nobrow:
    mov qword ptr [rip + g_oauth_no_browser], 1
    jmp .Lll_next
.Lll_provider:
    mov [rip + l_provider], rbx
.Lll_next:
    jmp .Lll_loop
.Lll_parsed:
    call config_load
    mov rdi, r13
    lea rsi, [rip + .Lcmd_login]
    call cstr_eq
    test eax, eax
    jz 1f
    mov rdi, [rip + l_provider]
    call oauth_login
    jmp 2f
1:  mov rdi, [rip + l_provider]
    call oauth_logout
2:  test rax, rax
    js 3f
    xor eax, eax
    EPILOGUE
3:  mov eax, 1
    EPILOGUE
.Lll_usage:
    mov edi, 2
    lea rsi, [rip + .Lerr_usage]
    call out_cstr
    mov edi, 2
    lea rsi, [rip + .Lnl]
    call out_cstr
    mov eax, 2
    EPILOGUE
