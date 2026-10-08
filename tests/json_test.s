# json_test: JSONC parsing and accessors
.include "opcode.inc"

.section .rodata
.doc:
    .ascii "{\"a\": 1, \"b\": \"two\", /* c */ \"c\": [1,2,3,], \"d\": {\"e\": true}}"
.dlen = . - .doc
.bad1:   .ascii "{"
.bad2:   .ascii "[1 2]"
.two:    .asciz "two"
.m_parse:  .asciz "json parse ok\n"
.m_get:    .asciz "json get ok\n"
.m_arr:    .asciz "json arr ok\n"
.m_nested: .asciz "json nested ok\n"
.m_bad:    .asciz "json bad ok\n"
.m_strict: .asciz "json strict ok\n"
.m_fail:   .asciz "FAIL json\n"
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

# cstr_eq(a, b) -> 1|0 (leaf)
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
    # root = json_parse(doc, len)
    lea rdi, [rip + .doc]
    mov esi, .dlen
    call json_parse
    mov r12, rax
    test r12, r12
    jz .Lfail
    lea rdi, [rip + .m_parse]
    call print

    # json_get_u64(root, "a", 0) == 1
    mov rdi, r12
    lea rsi, [rip + .key_a]
    xor edx, edx
    call json_get_u64
    cmp rax, 1
    jne .Lfail

    # json_get_cstr(root, "b") == "two"
    mov rdi, r12
    lea rsi, [rip + .key_b]
    call json_get_cstr
    test rax, rax
    jz .Lfail
    mov rdi, rax
    lea rsi, [rip + .two]
    call cstr_eq
    cmp eax, 1
    jne .Lfail

    # json_is(json_get(root,"b"), "two")
    mov rdi, r12
    lea rsi, [rip + .key_b]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .two]
    call json_is
    cmp eax, 1
    jne .Lfail
    lea rdi, [rip + .m_get]
    call print

    # json_len(json_get(root,"c")) == 3  (trailing comma accepted)
    mov rdi, r12
    lea rsi, [rip + .key_c]
    call json_get
    mov rdi, rax
    call json_len
    cmp eax, 3
    jne .Lfail
    lea rdi, [rip + .m_arr]
    call print

    # json_type(json_get(json_get(root,"d"),"e")) == JT_TRUE
    mov rdi, r12
    lea rsi, [rip + .key_d]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .key_e]
    call json_get
    mov rdi, rax
    call json_type
    cmp eax, JT_TRUE
    jne .Lfail
    lea rdi, [rip + .m_nested]
    call print

    # json_parse("{",1) == 0
    lea rdi, [rip + .bad1]
    mov esi, 1
    call json_parse
    test rax, rax
    jnz .Lfail
    lea rdi, [rip + .m_bad]
    call print

    # json_parse("[1 2]",5) == 0 (missing comma rejected)
    lea rdi, [rip + .bad2]
    mov esi, 5
    call json_parse
    test rax, rax
    jnz .Lfail
    lea rdi, [rip + .m_strict]
    call print

    xor eax, eax
    EPILOGUE
.Lfail:
    lea rdi, [rip + .m_fail]
    call print
    mov eax, 1
    EPILOGUE

.section .rodata
.key_a: .asciz "a"
.key_b: .asciz "b"
.key_c: .asciz "c"
.key_d: .asciz "d"
.key_e: .asciz "e"
