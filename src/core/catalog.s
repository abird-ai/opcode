.include "opcode.inc"
.include "core/core.inc"
# model catalog accessors over the generated table (build/catalog.s) plus the
# user-discovered overlay (<config dir>/models.jsonc, written by discover.s).
# Built-ins win on id conflicts: lookups scan the generated table first, then
# the runtime table loaded by catalog_load_user().

.extern opcode_catalog
.extern opcode_catalog_count

.bss
.p2align 3
.globl cat_user
.globl cat_user_len
cat_user:     .quad 0           # MD[] of user entries (process lifetime)
cat_user_len: .quad 0

.section .rodata
.Lumodels:     .asciz "/models.jsonc"
.K_models:     .asciz "models"
.K_id:         .asciz "id"
.K_name:       .asciz "name"
.K_api:        .asciz "api"
.K_provider:   .asciz "provider"
.K_base:       .asciz "base"
.K_ctx:        .asciz "context_window"
.K_max:        .asciz "max_tokens"
.K_reasoning:  .asciz "reasoning"
.K_image:      .asciz "image"
.K_no_key:     .asciz "no_key"
.K_default:    .asciz "default"
.Lapi_default: .asciz "openai-chat"
.Lempty:       .asciz ""
.text

# catalog_find(provider cstr, id cstr) -> MD* | 0
FN catalog_find
    PROLOGUE 32
    mov [rsp + 16], rsi         # id argument
    mov rbx, rdi                # provider argument
    mov rdi, rbx
    call strlen
    mov [rsp], rax              # provider length
    mov rdi, [rsp + 16]
    call strlen
    mov [rsp + 8], rax          # id length
    xor r13d, r13d              # index
.Lcf_loop:
    mov rax, [rip + opcode_catalog_count]
    cmp r13, rax
    jae .Lcf_user
    imul rax, r13, MD_SIZE
    lea r14, [rip + opcode_catalog]
    add r14, rax
    mov rdi, [r14 + MD_provider]
    mov rsi, [rsp]
    mov rdx, rbx
    mov rcx, [rsp]
    call str_eq
    test eax, eax
    jz .Lcf_next
    mov rdi, [r14 + MD_id]
    call strlen
    mov rsi, rax
    mov rdi, [r14 + MD_id]
    mov rdx, [rsp + 16]
    mov rcx, [rsp + 8]
    call str_eq
    test eax, eax
    jnz .Lcf_hit
.Lcf_next:
    inc r13
    jmp .Lcf_loop
.Lcf_user:
    xor r13d, r13d
.Lcf_uloop:
    cmp r13, [rip + cat_user_len]
    jae .Lcf_none
    mov rax, r13
    imul rax, rax, MD_SIZE
    add rax, [rip + cat_user]
    mov r14, rax
    mov rdi, [r14 + MD_provider]
    mov rsi, [rsp]
    mov rdx, rbx
    mov rcx, [rsp]
    call str_eq
    test eax, eax
    jz .Lcf_unext
    mov rdi, [r14 + MD_id]
    call strlen
    mov rsi, rax
    mov rdi, [r14 + MD_id]
    mov rdx, [rsp + 16]
    mov rcx, [rsp + 8]
    call str_eq
    test eax, eax
    jnz .Lcf_hit
.Lcf_unext:
    inc r13
    jmp .Lcf_uloop
.Lcf_hit:
    mov rax, r14
    EPILOGUE
.Lcf_none:
    xor eax, eax
    EPILOGUE

# catalog_default(provider cstr) -> MD* | 0
# Prefers the model flagged MDF_DEFAULT for the provider (built-in, then
# discovered), then falls back to the first model of the provider.
FN catalog_default
    PROLOGUE 16
    mov rbx, rdi                # provider argument
    mov rdi, rbx
    call strlen
    mov [rsp], rax              # provider length
    mov qword ptr [rsp + 8], 0  # first built-in match
    xor r13d, r13d              # index
.Lcd_loop:
    mov rax, [rip + opcode_catalog_count]
    cmp r13, rax
    jae .Lcd_user
    imul rax, r13, MD_SIZE
    lea r14, [rip + opcode_catalog]
    add r14, rax
    mov rdi, [r14 + MD_provider]
    mov rsi, [rsp]
    mov rdx, rbx
    mov rcx, [rsp]
    call str_eq
    test eax, eax
    jz .Lcd_next
    test dword ptr [r14 + MD_flags], MDF_DEFAULT
    jnz .Lcd_hit
    cmp qword ptr [rsp + 8], 0
    jne .Lcd_next
    mov [rsp + 8], r14
.Lcd_next:
    inc r13
    jmp .Lcd_loop
.Lcd_user:
    xor r13d, r13d
.Lcd_uloop:
    cmp r13, [rip + cat_user_len]
    jae .Lcd_user_done
    mov rax, r13
    imul rax, rax, MD_SIZE
    add rax, [rip + cat_user]
    mov r14, rax
    mov rdi, [r14 + MD_provider]
    mov rsi, [rsp]
    mov rdx, rbx
    mov rcx, [rsp]
    call str_eq
    test eax, eax
    jz .Lcd_unext
    test dword ptr [r14 + MD_flags], MDF_DEFAULT
    jnz .Lcd_hit
    cmp qword ptr [rsp + 8], 0
    jne .Lcd_unext
    mov [rsp + 8], r14
.Lcd_unext:
    inc r13
    jmp .Lcd_uloop
.Lcd_user_done:
    mov rax, [rsp + 8]
    EPILOGUE
.Lcd_hit:
    mov rax, r14
    EPILOGUE

# catalog_count() -> n (generated + user-discovered)
FN catalog_count
    PROLOGUE 0
    mov rax, [rip + opcode_catalog_count]
    add rax, [rip + cat_user_len]
    EPILOGUE

# catalog_at(i) -> MD* (0 when i is out of range)
FN catalog_at
    mov rax, [rip + opcode_catalog_count]
    cmp rdi, rax
    jb .Lca_builtin
    sub rdi, rax
    cmp rdi, [rip + cat_user_len]
    jae .Lca_none
    imul rdi, rdi, MD_SIZE
    add rdi, [rip + cat_user]
    mov rax, rdi
    ret
.Lca_builtin:
    imul rdi, rdi, MD_SIZE
    lea rax, [rip + opcode_catalog]
    add rax, rdi
    ret
.Lca_none:
    xor eax, eax
    ret

# .Lcu_true(el JV*, key cstr) -> 1 when the key is a JSON true literal
.Lcu_true:
    PROLOGUE 0
    call json_get
    test rax, rax
    jz 1f
    cmp dword ptr [rax + JV_type], JT_TRUE
    jne 1f
    mov eax, 1
    EPILOGUE
1:  xor eax, eax
    EPILOGUE

# catalog_load_user() -> n.  Reads <config dir>/models.jsonc and appends its
# entries to the runtime lookup table.  Built-ins are not touched; idempotent.
# Missing or malformed files are a no-op returning 0.
FN catalog_load_user
    PROLOGUE 128
    mov rax, [rip + cat_user_len]
    test rax, rax
    jnz .Lcu_ret
    call config_user_dir
    test rax, rax
    jz .Lcu_zero
    mov rdi, rax
    lea rsi, [rip + .Lumodels]
    call config_path_join
    test rax, rax
    jz .Lcu_zero
    mov [rsp], rax              # path
    xor eax, eax
    mov [rsp + 8], rax          # SB
    mov [rsp + 16], rax
    mov [rsp + 24], rax
    mov rdi, [rsp]
    lea rsi, [rsp + 8]
    call config_read_file
    test eax, eax
    jz .Lcu_free_path
    mov rdi, [rsp + 8 + SB_ptr]
    mov rsi, [rsp + 8 + SB_len]
    call json_parse
    test rax, rax
    jz .Lcu_free_all
    mov rdi, rax
    lea rsi, [rip + .K_models]
    call json_get
    test rax, rax
    jz .Lcu_free_all
    mov [rsp + 40], rax         # models array
    mov rdi, rax
    call json_len
    test rax, rax
    jz .Lcu_free_all
    mov [rsp + 48], rax         # capacity
    imul rdi, rax, MD_SIZE
    call mem_alloc
    mov [rsp + 56], rax         # table
    xor r12d, r12d              # i
    xor r13d, r13d              # count
.Lcu_loop:
    cmp r12, [rsp + 48]
    jae .Lcu_done
    mov rdi, [rsp + 40]
    mov esi, r12d
    call json_at
    test rax, rax
    jz .Lcu_next
    cmp dword ptr [rax + JV_type], JT_OBJ
    jne .Lcu_next
    mov [rsp + 64], rax         # el
    mov rdi, rax
    lea rsi, [rip + .K_id]
    call json_get_cstr
    test rax, rax
    jz .Lcu_next                # id is required
    mov [rsp + 72], rax
    mov rdi, [rsp + 64]
    lea rsi, [rip + .K_provider]
    call json_get_cstr
    test rax, rax
    jz .Lcu_next                # provider is required
    mov [rsp + 80], rax
    mov rdi, rax
    call catalog_default        # built-in defaults for the provider, if any
    mov [rsp + 96], rax
    # flags: reasoning / image literals
    mov dword ptr [rsp + 88], 0
    mov rdi, [rsp + 64]
    lea rsi, [rip + .K_reasoning]
    call .Lcu_true
    test eax, eax
    jz 1f
    or dword ptr [rsp + 88], MDF_REASONING
1:  mov rdi, [rsp + 64]
    lea rsi, [rip + .K_image]
    call .Lcu_true
    test eax, eax
    jz 2f
    or dword ptr [rsp + 88], MDF_IMAGE
2:  # no_key: explicit literal wins, else inherit the provider's built-in flag
    mov rdi, [rsp + 64]
    lea rsi, [rip + .K_no_key]
    call json_get
    test rax, rax
    jz .Lcu_nokey_inherit
    cmp dword ptr [rax + JV_type], JT_TRUE
    jne .Lcu_flags_done
    or dword ptr [rsp + 88], MDF_NO_KEY
    jmp .Lcu_flags_done
.Lcu_nokey_inherit:
    mov rax, [rsp + 96]
    test rax, rax
    jz .Lcu_flags_done
    mov eax, [rax + MD_flags]
    and eax, MDF_NO_KEY
    or [rsp + 88], eax
.Lcu_flags_done:
    # explicit default literal only: inherited flags would make every
    # discovered model a default
    mov rdi, [rsp + 64]
    lea rsi, [rip + .K_default]
    call .Lcu_true
    test eax, eax
    jz 8f
    or dword ptr [rsp + 88], MDF_DEFAULT
8:
    # name = name | id
    mov rdi, [rsp + 64]
    lea rsi, [rip + .K_name]
    call json_get_cstr
    test rax, rax
    jnz 3f
    mov rax, [rsp + 72]
3:  mov [rsp + 104], rax
    # api = api | built-in api | "openai-chat"
    mov rdi, [rsp + 64]
    lea rsi, [rip + .K_api]
    call json_get_cstr
    test rax, rax
    jnz 5f
    mov rcx, [rsp + 96]
    test rcx, rcx
    jz 4f
    mov rax, [rcx + MD_api]
    test rax, rax
    jnz 5f
4:  lea rax, [rip + .Lapi_default]
5:  mov [rsp + 112], rax
    # base = base | built-in base | ""
    mov rdi, [rsp + 64]
    lea rsi, [rip + .K_base]
    call json_get_cstr
    test rax, rax
    jnz 7f
    mov rcx, [rsp + 96]
    test rcx, rcx
    jz 6f
    mov rax, [rcx + MD_base]
    test rax, rax
    jnz 7f
6:  lea rax, [rip + .Lempty]
7:  mov [rsp + 120], rax
    # fill the record at table + count * MD_SIZE
    mov r14, r13
    imul r14, r14, MD_SIZE
    add r14, [rsp + 56]
    mov rdi, [rsp + 72]
    call strlen
    mov rsi, rax
    mov rdi, [rsp + 72]
    call mem_dup
    mov [r14 + MD_id], rax
    mov rdi, [rsp + 104]
    call strlen
    mov rsi, rax
    mov rdi, [rsp + 104]
    call mem_dup
    mov [r14 + MD_name], rax
    mov rdi, [rsp + 112]
    call strlen
    mov rsi, rax
    mov rdi, [rsp + 112]
    call mem_dup
    mov [r14 + MD_api], rax
    mov rdi, [rsp + 80]
    call strlen
    mov rsi, rax
    mov rdi, [rsp + 80]
    call mem_dup
    mov [r14 + MD_provider], rax
    mov rdi, [rsp + 120]
    call strlen
    mov rsi, rax
    mov rdi, [rsp + 120]
    call mem_dup
    mov [r14 + MD_base], rax
    mov rdi, [rsp + 64]
    lea rsi, [rip + .K_ctx]
    xor edx, edx
    call json_get_u64
    mov [r14 + MD_ctx_window], eax
    mov rdi, [rsp + 64]
    lea rsi, [rip + .K_max]
    xor edx, edx
    call json_get_u64
    mov [r14 + MD_max_tokens], eax
    mov eax, [rsp + 88]
    mov [r14 + MD_flags], eax
    inc r13
.Lcu_next:
    inc r12
    jmp .Lcu_loop
.Lcu_done:
    mov rax, [rsp + 56]
    mov [rip + cat_user], rax
    mov [rip + cat_user_len], r13
    lea rdi, [rsp + 8]
    call sb_free
    mov rdi, [rsp]
    call mem_free
    mov rax, r13
.Lcu_ret:
    EPILOGUE
.Lcu_free_all:
    lea rdi, [rsp + 8]
    call sb_free
.Lcu_free_path:
    mov rdi, [rsp]
    call mem_free
.Lcu_zero:
    xor eax, eax
    EPILOGUE
