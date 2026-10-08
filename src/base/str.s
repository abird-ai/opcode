.include "opcode.inc"
# opcode base: memory and string primitives.
# adapted from rhun (MIT), see THIRD_PARTY.md

# memcpy(dst, src, n) -> dst
FN memcpy
    mov rax, rdi
    mov rcx, rdx
    rep movsb
    ret

# memmove(dst, src, n) -> dst
FN memmove
    mov rax, rdi
    mov rcx, rdx
    cmp rdi, rsi
    jbe .Lmm_fwd
    lea r8, [rsi + rdx]
    cmp rdi, r8
    jae .Lmm_fwd
    lea rsi, [rsi + rdx - 1]
    lea rdi, [rdi + rdx - 1]
    std
    rep movsb
    cld
    ret
.Lmm_fwd:
    rep movsb
    ret

# memset(dst, byte, n) -> dst
FN memset
    mov r8, rdi
    mov rcx, rdx
    mov eax, esi
    rep stosb
    mov rax, r8
    ret

# memset32(dst, u32, count) -> dst
FN memset32
    mov r8, rdi
    mov rcx, rdx
    mov eax, esi
    rep stosd
    mov rax, r8
    ret

# memeq(a, b, n) -> 1 | 0
FN memeq
    mov rcx, rdx
    test rcx, rcx
    jz .Lme_eq
    xor eax, eax
    repe cmpsb
    sete al
    ret
.Lme_eq:
    mov eax, 1
    ret

# strlen(s) -> n
FN strlen
    xor eax, eax
1:  cmp byte ptr [rdi + rax], 0
    je 2f
    inc rax
    jmp 1b
2:  ret

# str_eq(a, alen, b, blen) -> 1 | 0
FN str_eq
    xor eax, eax
    cmp rsi, rcx
    jne 1f
    test rsi, rsi
    jz 2f
    mov rcx, rsi
    mov rsi, rdx
    repe cmpsb
    sete al
1:  ret
2:  mov eax, 1
    ret

# str_eq_cstr(a, alen, cstr) -> 1 | 0
FN str_eq_cstr
    xor eax, eax
1:  test rsi, rsi
    jz 2f
    mov cl, [rdx]
    test cl, cl
    jz 3f
    cmp cl, [rdi]
    jne 3f
    inc rdi
    inc rdx
    dec rsi
    jmp 1b
2:  cmp byte ptr [rdx], 0
    sete al
3:  ret

# str_starts(a, alen, prefix, plen) -> 1 | 0
FN str_starts
    xor eax, eax
    cmp rsi, rcx
    jb 1f
    test rcx, rcx
    jz 2f
    mov rsi, rdx
    repe cmpsb
    jne 1f
2:  mov eax, 1
1:  ret

# str_find(hay, hlen, needle, nlen) -> index | -1 (empty needle -> 0)
FN str_find
    test rcx, rcx
    jz .Lsf_zero
    cmp rcx, rsi
    ja .Lsf_none
    sub rsi, rcx                # last candidate start
    xor r8d, r8d
.Lsf_outer:
    cmp r8, rsi
    ja .Lsf_none
    lea r9, [rdi + r8]
    xor r10d, r10d
.Lsf_inner:
    mov al, [r9 + r10]
    cmp al, [rdx + r10]
    jne .Lsf_next
    inc r10
    cmp r10, rcx
    jb .Lsf_inner
    mov rax, r8
    ret
.Lsf_next:
    inc r8
    jmp .Lsf_outer
.Lsf_zero:
    xor eax, eax
    ret
.Lsf_none:
    mov rax, -1
    ret

# parse_u64(ptr, len) -> rax value, rdx digits consumed (0 if none)
# On 64-bit overflow the parse fails: rax = 0, rdx = 0 (no digits consumed).
FN parse_u64
    xor eax, eax
    xor edx, edx
1:  cmp rdx, rsi
    jae 2f
    movzx ecx, byte ptr [rdi + rdx]
    sub ecx, '0'
    cmp ecx, 9
    ja 2f
    # reject acc * 10 + digit > UINT64_MAX before it wraps
    cmp rax, [rip + .Lpu_maxdiv10]
    ja 3f                       # acc > floor(UINT64_MAX/10)
    jb 4f                       # acc < floor(UINT64_MAX/10): safe
    cmp ecx, 5                  # acc == floor(...) and digit > UINT64_MAX%10
    ja 3f
4:  imul rax, rax, 10
    add rax, rcx
    inc rdx
    jmp 1b
2:  ret
3:  xor eax, eax               # overflow: report no digits consumed
    xor edx, edx
    ret

.section .rodata
.p2align 3
.Lpu_maxdiv10: .quad 0x1999999999999999
.text

# parse_hex(ptr, len) -> rax value, rdx digits consumed (0 if none)
FN parse_hex
    xor eax, eax
    xor edx, edx
1:  cmp rdx, rsi
    jae 3f
    movzx ecx, byte ptr [rdi + rdx]
    lea r8d, [rcx - '0']
    cmp r8d, 9
    jbe 2f
    or ecx, 0x20
    lea r8d, [rcx - 'a']
    cmp r8d, 5
    ja 3f
    add r8d, 10
2:  shl rax, 4
    add rax, r8
    inc rdx
    jmp 1b
3:  ret

# fmt_u64(buf, value) -> rax length (no NUL terminator)
FN fmt_u64
    sub rsp, 32
    mov rax, rsi
    mov r8, rdi
    lea rsi, [rsp + 32]
    mov rcx, rsi
    mov r9d, 10
1:  xor edx, edx
    div r9
    add dl, '0'
    dec rcx
    mov [rcx], dl
    test rax, rax
    jnz 1b
    mov rdx, rsi
    sub rdx, rcx
    mov rax, rdx
    mov rsi, rcx
    mov rdi, r8
    mov rcx, rdx
    rep movsb
    add rsp, 32
    ret

# utf8_encode(codepoint, buf) -> rax length 1..4
FN utf8_encode
    cmp edi, 0x80
    jb .Lue_1
    cmp edi, 0x800
    jb .Lue_2
    cmp edi, 0x10000
    jb .Lue_3
    mov eax, edi
    shr eax, 18
    or al, 0xf0
    mov [rsi], al
    mov eax, edi
    shr eax, 12
    and al, 0x3f
    or al, 0x80
    mov [rsi + 1], al
    mov eax, edi
    shr eax, 6
    and al, 0x3f
    or al, 0x80
    mov [rsi + 2], al
    mov eax, edi
    and al, 0x3f
    or al, 0x80
    mov [rsi + 3], al
    mov eax, 4
    ret
.Lue_1:
    mov [rsi], dil
    mov eax, 1
    ret
.Lue_2:
    mov eax, edi
    shr eax, 6
    or al, 0xc0
    mov [rsi], al
    mov eax, edi
    and al, 0x3f
    or al, 0x80
    mov [rsi + 1], al
    mov eax, 2
    ret
.Lue_3:
    mov eax, edi
    shr eax, 12
    or al, 0xe0
    mov [rsi], al
    mov eax, edi
    shr eax, 6
    and al, 0x3f
    or al, 0x80
    mov [rsi + 1], al
    mov eax, edi
    and al, 0x3f
    or al, 0x80
    mov [rsi + 2], al
    mov eax, 3
    ret
