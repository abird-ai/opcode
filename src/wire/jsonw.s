.include "opcode.inc"
# opcode wire: streaming JSON writer (RFC 8259), no whitespace.
#
# Every function appends to the SB passed in rdi and keeps no state of its
# own; separators are derived from the last byte written, so callers only
# write keys and values:
#   - ", " is appended unless the buffer is empty or ends with one of { [ , :
#   - jsonw_raw is verbatim and never inserts anything
#   - jsonw_key/jsonw_key_n emit "escaped-key":
# Strings escape '"' '\' and all bytes < 0x20 using \b \f \n \r \t and
# \u00xx (lowercase hex); bytes >= 0x80 (UTF-8) pass through unchanged.

.section .rodata
.Ljw_comma:   .byte ','
.Ljw_quote:   .byte '"'
.Ljw_colon:   .byte ':'
.Ljw_lbrace:  .byte '{'
.Ljw_rbrace:  .byte '}'
.Ljw_lbrack:  .byte '['
.Ljw_rbrack:  .byte ']'
.Ljw_minus:   .byte '-'
.Ljw_e_q:     .byte 0x5c, '"'          # \"
.Ljw_e_bs:    .byte 0x5c, 0x5c        # \\
.Ljw_e_b:     .byte 0x5c, 'b'
.Ljw_e_f:     .byte 0x5c, 'f'
.Ljw_e_n:     .byte 0x5c, 'n'
.Ljw_e_r:     .byte 0x5c, 'r'
.Ljw_e_t:     .byte 0x5c, 't'
.Ljw_hex:     .ascii "0123456789abcdef"
.Ljw_true:    .ascii "true"
.Ljw_false:   .ascii "false"
.Ljw_null:    .ascii "null"
.text

# jw_sep(sb): append ',' unless the buffer is empty or already punctuated.
# Leaf on the common path; the comma path tail-calls sb_push.
.Ljw_sep:
    mov rax, [rdi + SB_len]
    test rax, rax
    jz .Ljw_sep_done
    mov rcx, [rdi + SB_ptr]
    movzx ecx, byte ptr [rcx + rax - 1]
    cmp cl, '{'
    je .Ljw_sep_done
    cmp cl, '['
    je .Ljw_sep_done
    cmp cl, ','
    je .Ljw_sep_done
    cmp cl, ':'
    je .Ljw_sep_done
    lea rsi, [rip + .Ljw_comma]
    mov edx, 1
    jmp sb_push
.Ljw_sep_done:
    ret

# jw_escape(sb, ptr, len): append escaped string content, no surrounding quotes.
.Ljw_escape:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
.Ljw_esc_scan:
    test r13, r13
    jz .Ljw_esc_done
    xor eax, eax                       # run of ordinary bytes
.Ljw_esc_run:
    cmp rax, r13
    jae .Ljw_esc_flush
    movzx ecx, byte ptr [r12 + rax]
    cmp ecx, 0x20
    jb .Ljw_esc_flush
    cmp ecx, '"'
    je .Ljw_esc_flush
    cmp ecx, 0x5c
    je .Ljw_esc_flush
    inc rax
    jmp .Ljw_esc_run
.Ljw_esc_flush:
    test rax, rax
    jz .Ljw_esc_special
    mov rdi, rbx
    mov rsi, r12
    mov rdx, rax
    mov r14, rax
    call sb_push
    add r12, r14
    sub r13, r14
.Ljw_esc_special:
    test r13, r13
    jz .Ljw_esc_done
    movzx eax, byte ptr [r12]
    inc r12
    dec r13
    cmp al, '"'
    je .Ljw_esc_do_q
    cmp al, 0x5c
    je .Ljw_esc_do_bs
    cmp al, 8
    je .Ljw_esc_do_b
    cmp al, 12
    je .Ljw_esc_do_f
    cmp al, 10
    je .Ljw_esc_do_n
    cmp al, 13
    je .Ljw_esc_do_r
    cmp al, 9
    je .Ljw_esc_do_t
    # \u00xx for every other control byte
    mov ecx, eax
    shr ecx, 4
    and eax, 15
    lea rdx, [rip + .Ljw_hex]
    movzx ecx, byte ptr [rdx + rcx]
    movzx eax, byte ptr [rdx + rax]
    mov byte ptr [rsp], 0x5c
    mov byte ptr [rsp + 1], 'u'
    mov byte ptr [rsp + 2], '0'
    mov byte ptr [rsp + 3], '0'
    mov byte ptr [rsp + 4], cl
    mov byte ptr [rsp + 5], al
    mov rdi, rbx
    mov rsi, rsp
    mov edx, 6
    call sb_push
    jmp .Ljw_esc_scan
.Ljw_esc_do_q:
    lea rsi, [rip + .Ljw_e_q]
    jmp .Ljw_esc_pair
.Ljw_esc_do_bs:
    lea rsi, [rip + .Ljw_e_bs]
    jmp .Ljw_esc_pair
.Ljw_esc_do_b:
    lea rsi, [rip + .Ljw_e_b]
    jmp .Ljw_esc_pair
.Ljw_esc_do_f:
    lea rsi, [rip + .Ljw_e_f]
    jmp .Ljw_esc_pair
.Ljw_esc_do_n:
    lea rsi, [rip + .Ljw_e_n]
    jmp .Ljw_esc_pair
.Ljw_esc_do_r:
    lea rsi, [rip + .Ljw_e_r]
    jmp .Ljw_esc_pair
.Ljw_esc_do_t:
    lea rsi, [rip + .Ljw_e_t]
.Ljw_esc_pair:
    mov rdi, rbx
    mov edx, 2
    call sb_push
    jmp .Ljw_esc_scan
.Ljw_esc_done:
    EPILOGUE

# jsonw_obj(sb) / jsonw_obj_end(sb)
FN jsonw_obj
    PROLOGUE 0
    mov rbx, rdi
    call .Ljw_sep
    mov rdi, rbx
    lea rsi, [rip + .Ljw_lbrace]
    mov edx, 1
    call sb_push
    EPILOGUE

FN jsonw_obj_end
    lea rsi, [rip + .Ljw_rbrace]
    mov edx, 1
    jmp sb_push

# jsonw_arr(sb) / jsonw_arr_end(sb)
FN jsonw_arr
    PROLOGUE 0
    mov rbx, rdi
    call .Ljw_sep
    mov rdi, rbx
    lea rsi, [rip + .Ljw_lbrack]
    mov edx, 1
    call sb_push
    EPILOGUE

FN jsonw_arr_end
    lea rsi, [rip + .Ljw_rbrack]
    mov edx, 1
    jmp sb_push

# jsonw_key(sb, cstr) / jsonw_key_n(sb, ptr, len)
FN jsonw_key
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rsi
    call strlen
    mov rdi, rbx
    mov rsi, r12
    mov rdx, rax
    call jsonw_key_n
    EPILOGUE

FN jsonw_key_n
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    call .Ljw_sep
    mov rdi, rbx
    lea rsi, [rip + .Ljw_quote]
    mov edx, 1
    call sb_push
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call .Ljw_escape
    mov rdi, rbx
    lea rsi, [rip + .Ljw_quote]
    mov edx, 1
    call sb_push
    mov rdi, rbx
    lea rsi, [rip + .Ljw_colon]
    mov edx, 1
    call sb_push
    EPILOGUE

# jsonw_str(sb, ptr, len) / jsonw_str_cstr(sb, cstr)
FN jsonw_str
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    call .Ljw_sep
    mov rdi, rbx
    lea rsi, [rip + .Ljw_quote]
    mov edx, 1
    call sb_push
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call .Ljw_escape
    mov rdi, rbx
    lea rsi, [rip + .Ljw_quote]
    mov edx, 1
    call sb_push
    EPILOGUE

FN jsonw_str_cstr
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rsi
    call strlen
    mov rdi, rbx
    mov rsi, r12
    mov rdx, rax
    call jsonw_str
    EPILOGUE

# jsonw_i64(sb, value) / jsonw_u64(sb, value)
FN jsonw_i64
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    call .Ljw_sep
    test r12, r12
    jns .Ljw_i64_abs
    mov rdi, rbx
    lea rsi, [rip + .Ljw_minus]
    mov edx, 1
    call sb_push
    neg r12                            # INT64_MIN maps to 2^63
.Ljw_i64_abs:
    mov rdi, rbx
    mov rsi, r12
    call sb_push_u64
    EPILOGUE

FN jsonw_u64
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    call .Ljw_sep
    mov rdi, rbx
    mov rsi, r12
    call sb_push_u64
    EPILOGUE

# jsonw_bool(sb, b) / jsonw_null(sb)
FN jsonw_bool
    PROLOGUE 0
    mov rbx, rdi
    test esi, esi
    jz .Ljw_bool_false
    lea r12, [rip + .Ljw_true]
    mov r13d, 4
    jmp .Ljw_bool_emit
.Ljw_bool_false:
    lea r12, [rip + .Ljw_false]
    mov r13d, 5
.Ljw_bool_emit:
    call .Ljw_sep
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call sb_push
    EPILOGUE

FN jsonw_null
    PROLOGUE 0
    mov rbx, rdi
    call .Ljw_sep
    mov rdi, rbx
    lea rsi, [rip + .Ljw_null]
    mov edx, 4
    call sb_push
    EPILOGUE

# jsonw_raw(sb, ptr, len): pre-encoded bytes, appended verbatim.
FN jsonw_raw
    jmp sb_push
