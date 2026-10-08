# jsonw_test: streaming JSON writer (escape rules, numbers, nesting, keys).
.include "opcode.inc"

.bss
.p2align 3
jsb: .zero SB_SIZE

.section .rodata
# expected documents
.E_obj:    .asciz "{}"
.E_escape: .asciz "{\"k\":\"a\\\"b\\n\"}"        # {"k":"a\"b\n"}
.E_nums:   .asciz "{\"n\":-42,\"u\":42}"
.E_array:  .asciz "[1,true,null,\"x\"]"
.E_nested: .asciz "{\"a\":{\"b\":[1,2]}}"
.E_key:    .asciz "{\"abc\":[]}"
.E_i64min: .asciz "-9223372036854775808"
.E_u64max: .asciz "18446744073709551615"
.E_ctrl:   .byte '"', 0x5c, 'u', '0', '0', '0', '1', '"', 0
.E_utf8:   .byte '"', 0xc3, 0xa9, '"', 0
.E_empty:  .byte '"', '"', 0
.E_x:      .asciz "\"x\""

# inputs
.K_k:      .asciz "k"
.K_n:      .asciz "n"
.K_u:      .asciz "u"
.K_a:      .asciz "a"
.K_b:      .asciz "b"
.K_abc:    .asciz "abc"
.S_esc:    .ascii "a\"b\n"                       # a, quote, b, LF
.S_x:      .asciz "x"
.S_utf8:   .byte 0xc3, 0xa9
.S_ctrl:   .byte 1

# messages
.M_obj:    .asciz "jsonw ok obj\n"
.M_escape: .asciz "jsonw ok escape\n"
.M_nums:   .asciz "jsonw ok nums\n"
.M_array:  .asciz "jsonw ok array\n"
.M_nested: .asciz "jsonw ok nested\n"
.M_key:    .asciz "jsonw ok key\n"
.M_done:   .asciz "jsonw done\n"
.M_fail:   .asciz "FAIL jsonw\n"
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

# sb_equals(sb, cstr) -> 1 | 0
sb_equals:
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rsi
    call strlen
    mov r13, rax
    cmp [rbx + SB_len], rax
    jne .Lse_no
    mov rdi, [rbx + SB_ptr]
    mov rsi, r12
    mov rdx, r13
    call memeq
    EPILOGUE
.Lse_no:
    xor eax, eax
    EPILOGUE

# check(sb, cstr): print FAIL and exit on mismatch
check:
    PROLOGUE 0
    call sb_equals
    test eax, eax
    jnz .Lchk_ok
    lea rdi, [rip + .M_fail]
    call print
    mov edi, 1
    call os_exit
    ud2
.Lchk_ok:
    EPILOGUE

FN opcode_main
    PROLOGUE 0
    lea r14, [rip + jsb]

    # 1. {}
    mov rdi, r14
    call jsonw_obj
    mov rdi, r14
    call jsonw_obj_end
    mov rdi, r14
    lea rsi, [rip + .E_obj]
    call check
    lea rdi, [rip + .M_obj]
    call print

    # 2. {"k":"a\"b\n"} - escaping
    mov rdi, r14
    call sb_clear
    mov rdi, r14
    call jsonw_obj
    mov rdi, r14
    lea rsi, [rip + .K_k]
    call jsonw_key
    mov rdi, r14
    lea rsi, [rip + .S_esc]
    mov edx, 4
    call jsonw_str
    mov rdi, r14
    call jsonw_obj_end
    mov rdi, r14
    lea rsi, [rip + .E_escape]
    call check
    lea rdi, [rip + .M_escape]
    call print

    # 3. {"n":-42,"u":42"} - i64 negative, u64
    mov rdi, r14
    call sb_clear
    mov rdi, r14
    call jsonw_obj
    mov rdi, r14
    lea rsi, [rip + .K_n]
    call jsonw_key
    mov rdi, r14
    mov rsi, -42
    call jsonw_i64
    mov rdi, r14
    lea rsi, [rip + .K_u]
    call jsonw_key
    mov rdi, r14
    mov esi, 42
    call jsonw_u64
    mov rdi, r14
    call jsonw_obj_end
    mov rdi, r14
    lea rsi, [rip + .E_nums]
    call check
    # numeric edges: INT64_MIN and UINT64_MAX
    mov rdi, r14
    call sb_clear
    mov rdi, r14
    movabs rsi, 0x8000000000000000
    call jsonw_i64
    mov rdi, r14
    lea rsi, [rip + .E_i64min]
    call check
    mov rdi, r14
    call sb_clear
    mov rdi, r14
    mov rsi, -1
    call jsonw_u64
    mov rdi, r14
    lea rsi, [rip + .E_u64max]
    call check
    lea rdi, [rip + .M_nums]
    call print

    # 4. [1,true,null,"x"]
    mov rdi, r14
    call sb_clear
    mov rdi, r14
    call jsonw_arr
    mov rdi, r14
    mov esi, 1
    call jsonw_i64
    mov rdi, r14
    mov esi, 1
    call jsonw_bool
    mov rdi, r14
    call jsonw_null
    mov rdi, r14
    lea rsi, [rip + .S_x]
    mov edx, 1
    call jsonw_str
    mov rdi, r14
    call jsonw_arr_end
    mov rdi, r14
    lea rsi, [rip + .E_array]
    call check
    lea rdi, [rip + .M_array]
    call print

    # 5. {"a":{"b":[1,2]}}
    mov rdi, r14
    call sb_clear
    mov rdi, r14
    call jsonw_obj
    mov rdi, r14
    lea rsi, [rip + .K_a]
    call jsonw_key
    mov rdi, r14
    call jsonw_obj
    mov rdi, r14
    lea rsi, [rip + .K_b]
    call jsonw_key
    mov rdi, r14
    call jsonw_arr
    mov rdi, r14
    mov esi, 1
    call jsonw_i64
    mov rdi, r14
    mov esi, 2
    call jsonw_i64
    mov rdi, r14
    call jsonw_arr_end
    mov rdi, r14
    call jsonw_obj_end
    mov rdi, r14
    call jsonw_obj_end
    mov rdi, r14
    lea rsi, [rip + .E_nested]
    call check
    lea rdi, [rip + .M_nested]
    call print

    # 6. jsonw_key_n("abc",3) + empty array
    mov rdi, r14
    call sb_clear
    mov rdi, r14
    call jsonw_obj
    mov rdi, r14
    lea rsi, [rip + .K_abc]
    mov edx, 3
    call jsonw_key_n
    mov rdi, r14
    call jsonw_arr
    mov rdi, r14
    call jsonw_arr_end
    mov rdi, r14
    call jsonw_obj_end
    mov rdi, r14
    lea rsi, [rip + .E_key]
    call check
    lea rdi, [rip + .M_key]
    call print

    # extras (no output of their own): \u00xx, UTF-8 passthrough, empty string,
    # jsonw_str_cstr and jsonw_raw verbatim.
    mov rdi, r14
    call sb_clear
    mov rdi, r14
    lea rsi, [rip + .S_ctrl]
    mov edx, 1
    call jsonw_str
    mov rdi, r14
    lea rsi, [rip + .E_ctrl]
    call check

    mov rdi, r14
    call sb_clear
    mov rdi, r14
    lea rsi, [rip + .S_utf8]
    mov edx, 2
    call jsonw_str
    mov rdi, r14
    lea rsi, [rip + .E_utf8]
    call check

    mov rdi, r14
    call sb_clear
    mov rdi, r14
    lea rsi, [rip + .S_x]
    xor edx, edx
    call jsonw_str
    mov rdi, r14
    lea rsi, [rip + .E_empty]
    call check

    mov rdi, r14
    call sb_clear
    mov rdi, r14
    lea rsi, [rip + .S_x]
    call jsonw_str_cstr
    mov rdi, r14
    lea rsi, [rip + .E_x]
    call check

    mov rdi, r14
    call sb_clear
    mov rdi, r14
    lea rsi, [rip + .K_abc]
    mov edx, 3
    call jsonw_raw
    mov rdi, r14
    lea rsi, [rip + .K_abc]
    call check

    lea rdi, [rip + .M_done]
    call print
    xor eax, eax
    EPILOGUE
.Lfail:
    lea rdi, [rip + .M_fail]
    call print
    mov eax, 1
    EPILOGUE
