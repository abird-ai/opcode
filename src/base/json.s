.include "opcode.inc"
# json: recursive-descent JSON/JSONC parser into a chained arena (one document at a time)
# adapted from rhun (MIT), see THIRD_PARTY.md
#
# JSONC dialect: // line comments, /* */ block comments (an unterminated block
# comment is a parse failure), trailing commas in arrays and objects, and an
# optional UTF-8 BOM at the very start. Missing commas are rejected. Strings are
# decoded (\" \\ \/ \b \f \n \r \t and \uXXXX with surrogate pairs) and
# NUL-terminated in the arena; JV_n is the decoded length. Numbers keep their raw
# text pointer and length. The arena chains 1 MiB blocks: old blocks stay alive
# across growth, json_reset frees every block but the newest.

.bss
.p2align 3
arena:      .quad 0             # newest block; [block] links to the older one
arena_cap:  .quad 0
arena_top:  .quad 0
stk:        .zero VEC_SIZE      # pending child pointers
jp:         .quad 0             # cursor
jend:       .quad 0             # end of the input
jstart:     .quad 0             # start of the input (for the BOM check)
jdepth:     .long 0
jfail:      .long 0

CSTR lit_true, "true"
CSTR lit_false, "false"
CSTR lit_null, "null"

.text

# aalloc(n) -> 8-byte aligned pointer in the arena. Keeps old blocks alive and
# chains a new one when the current block fills up. PROLOGUE keeps rsp aligned
# for mem_alloc.
aalloc:
    PROLOGUE
    add rdi, 7
    and rdi, -8
    mov rbx, rdi                # requested size
.Laa_retry:
    mov rax, [rip + arena_top]
    lea rcx, [rax + rbx]
    cmp rcx, [rip + arena_cap]
    jbe .Laa_take
    # out of space: keep the old blocks (pointers into them stay valid), start a new one
    mov rax, [rip + arena_cap]
    add rax, rax
    cmp rax, rbx
    jae .Laa_cap
    lea rax, [rbx + rbx]
.Laa_cap:
    mov ecx, MEM_CHUNK
    cmp rax, rcx
    cmovb rax, rcx
    mov [rip + arena_cap], rax
    mov rdi, rax
    call mem_alloc
    mov rcx, [rip + arena]
    mov [rax], rcx              # link the previous block
    mov [rip + arena], rax
    mov qword ptr [rip + arena_top], 8
    jmp .Laa_retry
.Laa_take:
    mov [rip + arena_top], rcx
    add rax, [rip + arena]
    EPILOGUE

# json_reset(): free every arena block but the newest; reuse the newest one.
FN json_reset
    PROLOGUE
    mov rax, [rip + arena]
    test rax, rax
    jz .Ljr_done
    mov rbx, [rax]
    mov qword ptr [rax], 0
.Ljr_loop:
    test rbx, rbx
    jz .Ljr_done
    mov rdi, rbx
    mov rbx, [rbx]
    call mem_free
    jmp .Ljr_loop
.Ljr_done:
    mov qword ptr [rip + arena_top], 8
    mov qword ptr [rip + stk + VEC_len], 0
    EPILOGUE

# skip_ws(): advance jp over spaces/tabs/newlines/CR, // line comments,
# /* */ block comments and the document-leading UTF-8 BOM.
# An unterminated block comment fails the parse. On return rsi = jp, rdi = jend.
skip_ws:
    mov rsi, [rip + jp]
.Lws_loop:
    mov rdi, [rip + jend]
    cmp rsi, rdi
    jae .Lws_done
    movzx eax, byte ptr [rsi]
    cmp al, ' '
    je .Lws_adv
    cmp al, 9
    je .Lws_adv
    cmp al, 10
    je .Lws_adv
    cmp al, 13
    je .Lws_adv
    cmp al, '/'
    je .Lws_slash
    cmp al, 0xef                # UTF-8 BOM EF BB BF, only at the very start
    jne .Lws_done
    cmp rsi, [rip + jstart]
    jne .Lws_done
    lea rcx, [rsi + 2]
    cmp rcx, rdi
    jae .Lws_done
    cmp byte ptr [rsi + 1], 0xbb
    jne .Lws_done
    cmp byte ptr [rsi + 2], 0xbf
    jne .Lws_done
    add rsi, 3
    jmp .Lws_loop
.Lws_slash:
    lea rcx, [rsi + 1]
    cmp rcx, rdi
    jae .Lws_done               # a lone '/' is not whitespace
    cmp byte ptr [rcx], '/'
    je .Lws_line
    cmp byte ptr [rcx], '*'
    jne .Lws_done
    lea rsi, [rsi + 2]          # skip "/*"
.Lws_block:
    lea rcx, [rsi + 1]
    cmp rcx, rdi
    jae .Lws_fail               # unterminated block comment
    cmp byte ptr [rsi], '*'
    jne .Lws_block_next
    cmp byte ptr [rsi + 1], '/'
    je .Lws_block_end
.Lws_block_next:
    inc rsi
    jmp .Lws_block
.Lws_block_end:
    add rsi, 2
    jmp .Lws_loop
.Lws_line:
    add rsi, 2
.Lws_line_loop:
    cmp rsi, rdi
    jae .Lws_done
    cmp byte ptr [rsi], 10
    je .Lws_adv
    inc rsi
    jmp .Lws_line_loop
.Lws_adv:
    inc rsi
    jmp .Lws_loop
.Lws_done:
    mov [rip + jp], rsi
    ret
.Lws_fail:
    mov dword ptr [rip + jfail], 1
    mov rdi, [rip + jend]
    mov rsi, rdi
    mov [rip + jp], rsi
    ret

# json_parse(ptr, len) -> JV* or 0. Resets the arena, parses one document and
# requires the whole input to be consumed (trailing ws/comments are fine).
FN json_parse
    PROLOGUE
    mov [rip + jstart], rdi
    mov [rip + jp], rdi
    add rdi, rsi
    mov [rip + jend], rdi
    mov dword ptr [rip + jdepth], 0
    mov dword ptr [rip + jfail], 0
    call json_reset
    call parse_value
    test rax, rax
    jz .Ljp_fail
    mov rbx, rax
    call skip_ws
    cmp rsi, rdi
    jb .Ljp_fail                # trailing garbage
    cmp dword ptr [rip + jfail], 0
    jne .Ljp_fail
    mov rax, rbx
    EPILOGUE
.Ljp_fail:
    xor eax, eax
    EPILOGUE

# push_child(jv): append a pending child pointer to the stack
push_child:
    PROLOGUE
    mov rbx, rdi
    lea rdi, [rip + stk]
    mov esi, 8
    call vec_push
    mov [rax], rbx
    EPILOGUE

# parse_value() -> JV* or 0, advancing jp
parse_value:
    PROLOGUE
    call skip_ws
    cmp rsi, rdi
    jae .Lpv_fail
    inc dword ptr [rip + jdepth]
    cmp dword ptr [rip + jdepth], 200
    ja .Lpv_fail
    mov edi, JV_SIZE
    call aalloc
    mov rbx, rax
    mov rsi, [rip + jp]
    movzx eax, byte ptr [rsi]
    cmp al, '{'
    je .Lpv_obj
    cmp al, '['
    je .Lpv_arr
    cmp al, '"'
    je .Lpv_str
    cmp al, 't'
    je .Lpv_true
    cmp al, 'f'
    je .Lpv_false
    cmp al, 'n'
    je .Lpv_null
    cmp al, '-'
    je .Lpv_num
    sub al, '0'
    cmp al, 9
    jbe .Lpv_num
    jmp .Lpv_fail
.Lpv_num:
    mov dword ptr [rbx + JV_type], JT_NUM
    mov [rbx + JV_ptr], rsi
    mov rdi, [rip + jend]
    mov rcx, rsi
    cmp byte ptr [rcx], '-'
    jne .Lpv_num_int
    inc rcx
.Lpv_num_int:
    cmp rcx, rdi
    jae .Lpv_fail
    movzx eax, byte ptr [rcx]
    cmp al, '0'
    jne .Lpv_num_nz
    inc rcx
    jmp .Lpv_num_frac
.Lpv_num_nz:
    sub eax, '1'
    cmp eax, 8
    ja .Lpv_fail
    inc rcx
.Lpv_num_digits:
    cmp rcx, rdi
    jae .Lpv_num_frac
    movzx eax, byte ptr [rcx]
    sub eax, '0'
    cmp eax, 9
    ja .Lpv_num_frac
    inc rcx
    jmp .Lpv_num_digits
.Lpv_num_frac:
    cmp rcx, rdi
    jae .Lpv_num_exp
    cmp byte ptr [rcx], '.'
    jne .Lpv_num_exp
    inc rcx
    cmp rcx, rdi
    jae .Lpv_fail
    movzx eax, byte ptr [rcx]
    sub eax, '0'
    cmp eax, 9
    ja .Lpv_fail
    inc rcx
.Lpv_num_fracdig:
    cmp rcx, rdi
    jae .Lpv_num_exp
    movzx eax, byte ptr [rcx]
    sub eax, '0'
    cmp eax, 9
    ja .Lpv_num_exp
    inc rcx
    jmp .Lpv_num_fracdig
.Lpv_num_exp:
    cmp rcx, rdi
    jae .Lpv_num_done
    movzx eax, byte ptr [rcx]
    or al, 0x20
    cmp al, 'e'
    jne .Lpv_num_done
    inc rcx
    cmp rcx, rdi
    jae .Lpv_fail
    movzx eax, byte ptr [rcx]
    cmp al, '+'
    je .Lpv_num_expsign
    cmp al, '-'
    jne .Lpv_num_expdig0
.Lpv_num_expsign:
    inc rcx
    cmp rcx, rdi
    jae .Lpv_fail
.Lpv_num_expdig0:
    movzx eax, byte ptr [rcx]
    sub eax, '0'
    cmp eax, 9
    ja .Lpv_fail
    inc rcx
.Lpv_num_expdig:
    cmp rcx, rdi
    jae .Lpv_num_done
    movzx eax, byte ptr [rcx]
    sub eax, '0'
    cmp eax, 9
    ja .Lpv_num_done
    inc rcx
    jmp .Lpv_num_expdig
.Lpv_num_done:
    mov rax, rcx
    sub rax, rsi
    mov [rbx + JV_n], eax
    mov [rip + jp], rcx
    jmp .Lpv_done
.Lpv_true:
    mov dword ptr [rbx + JV_type], JT_TRUE
    mov edi, 4
    lea rcx, [rip + lit_true]
    jmp .Lpv_lit
.Lpv_false:
    mov dword ptr [rbx + JV_type], JT_FALSE
    mov edi, 5
    lea rcx, [rip + lit_false]
    jmp .Lpv_lit
.Lpv_null:
    mov dword ptr [rbx + JV_type], JT_NULL
    mov edi, 4
    lea rcx, [rip + lit_null]
.Lpv_lit:
    mov rax, [rip + jend]
    sub rax, rsi
    cmp rax, rdi
    jb .Lpv_fail
    xor edx, edx
.Lpv_lit_loop:
    movzx eax, byte ptr [rsi + rdx]
    cmp al, [rcx + rdx]
    jne .Lpv_fail
    inc rdx
    cmp rdx, rdi
    jb .Lpv_lit_loop
    add qword ptr [rip + jp], rdi
    jmp .Lpv_done
.Lpv_str:
    mov dword ptr [rbx + JV_type], JT_STR
    call parse_string
    test rax, rax
    jz .Lpv_fail
    mov [rbx + JV_ptr], rax
    mov [rbx + JV_n], edx
    jmp .Lpv_done
.Lpv_arr:
    mov dword ptr [rbx + JV_type], JT_ARR
    inc qword ptr [rip + jp]
    mov r12, [rip + stk + VEC_len]      # stack base
.Lpv_arr_loop:
    call skip_ws
    cmp rsi, rdi
    jae .Lpv_fail
    cmp byte ptr [rsi], ']'
    je .Lpv_arr_end
    call parse_value
    test rax, rax
    jz .Lpv_fail
    mov rdi, rax
    call push_child
    call skip_ws
    cmp rsi, rdi
    jae .Lpv_fail
    cmp byte ptr [rsi], ','
    je .Lpv_arr_comma
    cmp byte ptr [rsi], ']'
    jne .Lpv_fail               # missing comma
    jmp .Lpv_arr_end
.Lpv_arr_comma:
    inc qword ptr [rip + jp]     # trailing comma: the loop re-checks for ']'
    jmp .Lpv_arr_loop
.Lpv_arr_end:
    inc qword ptr [rip + jp]
    call pop_children
    jmp .Lpv_done
.Lpv_obj:
    mov dword ptr [rbx + JV_type], JT_OBJ
    inc qword ptr [rip + jp]
    mov r12, [rip + stk + VEC_len]
.Lpv_obj_loop:
    call skip_ws
    cmp rsi, rdi
    jae .Lpv_fail
    cmp byte ptr [rsi], '}'
    je .Lpv_obj_end
    cmp byte ptr [rsi], '"'
    jne .Lpv_fail
    call parse_value            # key (string)
    test rax, rax
    jz .Lpv_fail
    mov rdi, rax
    call push_child
    call skip_ws
    cmp rsi, rdi
    jae .Lpv_fail
    cmp byte ptr [rsi], ':'
    jne .Lpv_fail
    inc qword ptr [rip + jp]
    call parse_value            # value
    test rax, rax
    jz .Lpv_fail
    mov rdi, rax
    call push_child
    call skip_ws
    cmp rsi, rdi
    jae .Lpv_fail
    cmp byte ptr [rsi], ','
    je .Lpv_obj_comma
    cmp byte ptr [rsi], '}'
    jne .Lpv_fail               # missing comma
    jmp .Lpv_obj_end
.Lpv_obj_comma:
    inc qword ptr [rip + jp]     # trailing comma: the loop re-checks for '}'
    jmp .Lpv_obj_loop
.Lpv_obj_end:
    inc qword ptr [rip + jp]
    call pop_children
    shr dword ptr [rbx + JV_n], 1
    jmp .Lpv_done
.Lpv_done:
    dec dword ptr [rip + jdepth]
    mov rax, rbx
    EPILOGUE
.Lpv_fail:
    mov dword ptr [rip + jfail], 1
    xor eax, eax
    EPILOGUE

# pop_children(): move the stack entries above r12 into the node rbx
pop_children:
    PROLOGUE
    mov r13, [rip + stk + VEC_len]
    sub r13, r12
    mov [rbx + JV_n], r13d
    lea rdi, [r13*8]
    call aalloc
    mov [rbx + JV_ptr], rax
    mov rsi, [rip + stk + VEC_ptr]
    lea rsi, [rsi + r12*8]
    mov rdi, rax
    mov rcx, r13
    shl rcx, 3
    rep movsb
    mov [rip + stk + VEC_len], r12
    EPILOGUE

# parse_string() -> rax bytes in the arena (NUL-terminated), rdx decoded length;
# jp is at the opening quote.
parse_string:
    PROLOGUE
    mov rbx, [rip + jp]         # opening quote
    inc rbx
    mov rdi, [rip + jend]
    mov rcx, rbx
.Lps_scan:
    cmp rcx, rdi
    jae .Lps_fail
    movzx eax, byte ptr [rcx]
    cmp al, '"'
    je .Lps_scan_end
    cmp al, '\\'
    jne .Lps_scan_next
    inc rcx
.Lps_scan_next:
    inc rcx
    jmp .Lps_scan
.Lps_scan_end:
    mov r12, rcx                # closing quote
    # allocate an upper bound for the decoded bytes plus the NUL
    mov rdi, r12
    sub rdi, rbx
    inc rdi
    call aalloc
    mov r13, rax                # out
    xor r14d, r14d              # out length
.Lps_loop:
    cmp rbx, r12
    jae .Lps_end
    movzx eax, byte ptr [rbx]
    cmp al, '\\'
    je .Lps_esc
    cmp al, 0x20
    jb .Lps_fail                # raw control bytes are not allowed in strings
    mov [r13 + r14], al
    inc r14
    inc rbx
    jmp .Lps_loop
.Lps_esc:
    movzx eax, byte ptr [rbx + 1]
    add rbx, 2
    mov ecx, 10
    cmp al, 'n'
    je .Lps_put
    mov ecx, 9
    cmp al, 't'
    je .Lps_put
    mov ecx, 13
    cmp al, 'r'
    je .Lps_put
    mov ecx, 8
    cmp al, 'b'
    je .Lps_put
    mov ecx, 12
    cmp al, 'f'
    je .Lps_put
    cmp al, 'u'
    je .Lps_u
    mov ecx, eax                # \" \\ \/ and anything else literally
.Lps_put:
    mov [r13 + r14], cl
    inc r14
    jmp .Lps_loop
.Lps_u:
    mov rdi, rbx
    mov esi, 4
    call parse_hex
    cmp rdx, 4
    jne .Lps_fail               # not \uXXXX
    add rbx, 4
    mov r15d, eax
    lea ecx, [rax - 0xd800]
    cmp ecx, 0x7ff              # 0xd800..0xdfff?
    ja .Lps_emit                # not a surrogate
    cmp ecx, 0x3ff
    ja .Lps_fail                # lone low surrogate
    lea rcx, [rbx + 6]          # high surrogate: require a \uDC00..\uDFFF pair
    cmp rcx, r12
    ja .Lps_fail                # nothing left to pair with
    cmp byte ptr [rbx], '\\'
    jne .Lps_fail
    cmp byte ptr [rbx + 1], 'u'
    jne .Lps_fail
    lea rdi, [rbx + 2]
    mov esi, 4
    call parse_hex
    cmp rdx, 4
    jne .Lps_fail
    lea ecx, [rax - 0xdc00]     # low surrogate?
    cmp ecx, 0x3ff
    ja .Lps_fail                # not a low surrogate
    add rbx, 6
    mov eax, r15d
    sub eax, 0xd800
    shl eax, 10
    add eax, ecx
    add eax, 0x10000
    mov r15d, eax
.Lps_emit:
    mov edi, r15d
    lea rsi, [r13 + r14]
    call utf8_encode
    add r14, rax
    jmp .Lps_loop
.Lps_end:
    lea rax, [r12 + 1]
    mov [rip + jp], rax
    mov byte ptr [r13 + r14], 0
    mov rax, r13
    mov rdx, r14
    EPILOGUE
.Lps_fail:
    xor eax, eax
    EPILOGUE

# json_get(obj, key cstr) -> JV* or 0
FN json_get
    PROLOGUE
    xor eax, eax
    test rdi, rdi
    jz .Ljg_out
    cmp dword ptr [rdi + JV_type], JT_OBJ
    jne .Ljg_out
    mov rbx, rdi
    mov r12, rsi
    xor r13d, r13d
.Ljg_loop:
    cmp r13d, [rbx + JV_n]
    jae .Ljg_out
    mov rax, [rbx + JV_ptr]
    mov rcx, r13
    shl rcx, 4
    mov r14, [rax + rcx]        # key JV*
    mov rdi, [r14 + JV_ptr]
    mov esi, [r14 + JV_n]
    mov rdx, r12
    call str_eq_cstr
    test eax, eax
    jnz .Ljg_found
    inc r13d
    jmp .Ljg_loop
.Ljg_found:
    mov rax, [rbx + JV_ptr]
    mov rcx, r13
    shl rcx, 4
    mov rax, [rax + rcx + 8]
    EPILOGUE
.Ljg_out:
    xor eax, eax
    EPILOGUE

# json_get_cstr(obj, key cstr) -> cstr or 0
FN json_get_cstr
    PROLOGUE
    call json_get
    mov rdi, rax
    call json_str_cstr
    EPILOGUE

# json_get_u64(obj, key cstr, dflt) -> u64; dflt on a missing or non-number
# value, or on a numeric token that overflows u64 (parse_u64 then yields rdx=0).
FN json_get_u64
    PROLOGUE
    mov rbx, rdx                # default
    call json_get
    test rax, rax
    jz .Lgu_dflt
    cmp dword ptr [rax + JV_type], JT_NUM
    jne .Lgu_dflt
    mov rdi, [rax + JV_ptr]
    mov r12d, [rax + JV_n]
    mov esi, r12d
    call parse_u64
    test rdx, rdx
    jz .Lgu_dflt
    cmp rdx, r12                # the whole raw text must be digits
    jne .Lgu_dflt
    EPILOGUE
.Lgu_dflt:
    mov rax, rbx
    EPILOGUE

# json_str(jv) -> rax ptr, rdx len (0,0 unless a string)
FN json_str
    xor eax, eax
    xor edx, edx
    test rdi, rdi
    jz .Ljs_out
    cmp dword ptr [rdi + JV_type], JT_STR
    jne .Ljs_out
    mov rax, [rdi + JV_ptr]
    mov edx, [rdi + JV_n]
.Ljs_out:
    ret

# json_str_cstr(jv) -> cstr or 0 (0 if the value is not a string or the
# decoded string contains an embedded NUL, e.g. from \u0000)
FN json_str_cstr
    PROLOGUE
    call json_str
    test rax, rax
    jz .Lsc_out
    mov rbx, rax                # ptr
    mov r12, rdx                # len
    xor ecx, ecx
.Lsc_scan:
    cmp rcx, r12
    jae .Lsc_ok
    cmp byte ptr [rbx + rcx], 0
    je .Lsc_nul
    inc rcx
    jmp .Lsc_scan
.Lsc_nul:
    xor eax, eax                # embedded NUL: refuse to truncate silently
    xor edx, edx
.Lsc_out:
    EPILOGUE
.Lsc_ok:
    mov rax, rbx
    mov rdx, r12
    EPILOGUE

# json_is(jv, cstr) -> 1 if jv is a string equal to cstr
FN json_is
    PROLOGUE
    mov rbx, rsi
    call json_str
    test rax, rax
    jz .Lji_no
    mov rdi, rax
    mov rsi, rdx
    mov rdx, rbx
    call str_eq_cstr
    EPILOGUE
.Lji_no:
    xor eax, eax
    EPILOGUE

# json_at(arr, i) -> JV* or 0
FN json_at
    xor eax, eax
    test rdi, rdi
    jz .Lja_out
    cmp dword ptr [rdi + JV_type], JT_ARR
    jne .Lja_out
    mov ecx, esi
    cmp ecx, [rdi + JV_n]
    jae .Lja_out
    mov rax, [rdi + JV_ptr]
    mov rax, [rax + rcx*8]
.Lja_out:
    ret

# json_len(jv) -> element count (JT_ARR elements, JT_OBJ pairs; else 0)
FN json_len
    xor eax, eax
    test rdi, rdi
    jz .Ljl_out
    mov ecx, [rdi + JV_type]
    cmp ecx, JT_ARR
    je .Ljl_n
    cmp ecx, JT_OBJ
    jne .Ljl_out
.Ljl_n:
    mov eax, [rdi + JV_n]
.Ljl_out:
    ret

# json_type(jv) -> JT_* (-1 for a NULL pointer)
FN json_type
    mov rax, -1
    test rdi, rdi
    jz .Ljt_out
    mov eax, [rdi + JV_type]
.Ljt_out:
    ret
