.include "opcode.inc"
.include "wire/url.inc"
# opcode wire: http/https URL splitter.
#
# The Url layout is single-sourced in src/wire/url.inc. url_parse never copies
# or modifies the input: every pointer references either the input string or
# the static "/" path. Missing path -> "/" len 1. Scheme, host, path and query
# reject C0 controls and DEL (< 0x20 or 0x7f).

.section .rodata
.Lslash: .asciz "/"
.text

# url_parse(url cstr, out *Url) -> 0 | -EINVAL
FN url_parse
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    # scheme, case-insensitive; check byte by byte so short strings are safe
    movzx eax, byte ptr [rbx]
    or eax, 0x20
    cmp eax, 'h'
    jne .Lup_bad
    movzx eax, byte ptr [rbx + 1]
    or eax, 0x20
    cmp eax, 't'
    jne .Lup_bad
    movzx eax, byte ptr [rbx + 2]
    or eax, 0x20
    cmp eax, 't'
    jne .Lup_bad
    movzx eax, byte ptr [rbx + 3]
    or eax, 0x20
    cmp eax, 'p'
    jne .Lup_bad
    movzx eax, byte ptr [rbx + 4]
    or eax, 0x20
    cmp eax, 's'
    jne .Lup_http
    cmp byte ptr [rbx + 5], ':'
    jne .Lup_bad
    cmp byte ptr [rbx + 6], '/'
    jne .Lup_bad
    cmp byte ptr [rbx + 7], '/'
    jne .Lup_bad
    mov [r12 + U_scheme], rbx
    mov dword ptr [r12 + U_scheme_len], 5
    mov word ptr [r12 + U_port], 443
    mov word ptr [r12 + U_flags], UF_TLS
    lea r13, [rbx + 8]
    jmp .Lup_auth
.Lup_http:
    cmp byte ptr [rbx + 4], ':'
    jne .Lup_bad
    cmp byte ptr [rbx + 5], '/'
    jne .Lup_bad
    cmp byte ptr [rbx + 6], '/'
    jne .Lup_bad
    mov [r12 + U_scheme], rbx
    mov dword ptr [r12 + U_scheme_len], 4
    mov word ptr [r12 + U_port], 80
    mov word ptr [r12 + U_flags], 0
    lea r13, [rbx + 7]
.Lup_auth:
    # authority ends at NUL, '/', '?' or '#'
    mov r14, r13
.Lup_ascan:
    movzx eax, byte ptr [r14]
    test eax, eax
    jz .Lup_auth_end
    cmp eax, '/'
    je .Lup_auth_end
    cmp eax, '?'
    je .Lup_auth_end
    cmp eax, '#'
    je .Lup_auth_end
    inc r14
    jmp .Lup_ascan
.Lup_auth_end:
    # Host starts after the LAST '@' in the authority (an unencoded userinfo
    # may itself contain '@', so the first one is not the separator).
    mov r15, r13
.Lup_at:
    cmp r15, r14
    jae .Lup_host
    cmp byte ptr [r15], '@'
    jne .Lup_at_next
    lea r13, [r15 + 1]
.Lup_at_next:
    inc r15
    jmp .Lup_at
.Lup_host:
    cmp r13, r14
    jae .Lup_bad                 # empty authority/host
    cmp byte ptr [r13], '['
    je .Lup_v6
    mov r15, r13
.Lup_hscan:
    cmp r15, r14
    jae .Lup_host_end
    movzx eax, byte ptr [r15]
    cmp eax, 0x20
    jb .Lup_bad
    cmp eax, 0x7f
    je .Lup_bad
    cmp eax, ':'
    je .Lup_host_end
    inc r15
    jmp .Lup_hscan
.Lup_host_end:
    mov [r12 + U_host], r13
    mov rax, r15
    sub rax, r13
    mov [r12 + U_host_len], eax
    test eax, eax
    jz .Lup_bad                  # empty host before ':'
    cmp r15, r14
    jae .Lup_noport
    inc r15                      # skip ':'
    jmp .Lup_port
.Lup_v6:
    # Bracketed IPv6 literal: '[' ... ']' is one host, then an optional :port.
    lea r15, [r13 + 1]
.Lup_v6_scan:
    cmp r15, r14
    jae .Lup_bad                 # unterminated '['
    movzx eax, byte ptr [r15]
    cmp eax, 0x20
    jb .Lup_bad
    cmp eax, 0x7f
    je .Lup_bad
    cmp eax, ']'
    je .Lup_v6_end
    inc r15
    jmp .Lup_v6_scan
.Lup_v6_end:
    lea rax, [r13 + 1]           # host excludes the brackets (for SNI/copy)
    mov [r12 + U_host], rax
    mov rax, r15
    sub rax, r13
    dec rax
    mov [r12 + U_host_len], eax
    test eax, eax
    jz .Lup_bad                  # "[]"
    inc r15                      # past ']'
    cmp r15, r14
    jae .Lup_noport
    cmp byte ptr [r15], ':'
    jne .Lup_bad                 # garbage between ']' and the authority end
    inc r15
.Lup_port:
    xor eax, eax
    xor ecx, ecx
.Lup_port_loop:
    cmp r15, r14
    jae .Lup_port_done
    movzx edx, byte ptr [r15]
    sub edx, '0'
    cmp edx, 9
    ja .Lup_bad                  # non-digit inside :port
    cmp eax, 6553
    ja .Lup_bad
    imul eax, eax, 10
    add eax, edx
    cmp eax, 65535
    ja .Lup_bad
    inc ecx
    inc r15
    jmp .Lup_port_loop
.Lup_port_done:
    test ecx, ecx
    jz .Lup_bad                  # "host:" with no digits
    mov [r12 + U_port], ax
.Lup_noport:
    mov qword ptr [r12 + U_query], 0
    mov dword ptr [r12 + U_query_len], 0
    movzx eax, byte ptr [r15]
    cmp eax, '/'
    je .Lup_path
    cmp eax, '?'
    je .Lup_path_short
    # NUL or '#' -> default path, fragment dropped
    lea rax, [rip + .Lslash]
    mov [r12 + U_path], rax
    mov dword ptr [r12 + U_path_len], 1
    jmp .Lup_ok
.Lup_path:
    mov [r12 + U_path], r15
    mov r14, r15
.Lup_pscan:
    movzx eax, byte ptr [r14]
    test eax, eax
    jz .Lup_path_end
    cmp eax, 0x20
    jb .Lup_bad
    cmp eax, 0x7f
    je .Lup_bad
    cmp eax, '?'
    je .Lup_path_end
    cmp eax, '#'
    je .Lup_path_end
    inc r14
    jmp .Lup_pscan
.Lup_path_end:
    mov rax, r14
    sub rax, r15
    mov [r12 + U_path_len], eax
    cmp byte ptr [r14], '?'
    jne .Lup_ok
    inc r14
    jmp .Lup_query
.Lup_path_short:
    lea rax, [rip + .Lslash]
    mov [r12 + U_path], rax
    mov dword ptr [r12 + U_path_len], 1
    lea r14, [r15 + 1]
.Lup_query:
    mov r15, r14
.Lup_qscan:
    movzx eax, byte ptr [r14]
    test eax, eax
    jz .Lup_qend
    cmp eax, 0x20
    jb .Lup_bad
    cmp eax, 0x7f
    je .Lup_bad
    cmp eax, '#'
    je .Lup_qend
    inc r14
    jmp .Lup_qscan
.Lup_qend:
    mov [r12 + U_query], r15
    mov rax, r14
    sub rax, r15
    mov [r12 + U_query_len], eax
.Lup_ok:
    xor eax, eax
    EPILOGUE
.Lup_bad:
    mov rax, -EINVAL
    EPILOGUE

# url_copy_host(url, buf, cap) -> len | -ERANGE (NUL-terminated)
FN url_copy_host
    mov r9d, [rdi + U_host_len]
    lea r8, [r9 + 1]
    cmp rdx, r8
    jb .Lch_range
    mov r10, rsi
    mov rsi, [rdi + U_host]
    mov rdi, r10
    mov rcx, r9
    rep movsb
    mov byte ptr [rdi], 0
    mov eax, r9d
    ret
.Lch_range:
    mov rax, -ERANGE
    ret

# url_authority(url, buf, cap) -> len | -ERANGE (NUL-terminated)
# "host[:port]" for the HTTP Host header: the port is omitted only when it is
# the scheme default. url_copy_host stays host-only for TLS SNI.  An IPv6
# literal (url_parse stripped the brackets for SNI) is re-bracketed here so
# the Host header stays a valid authority.
FN url_authority
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    # a literal host slice with ':' can only be IPv6: the authority grammar
    # reserves ':' for the port after a reg-name
    mov rdi, [rbx + U_host]
    mov ecx, [rbx + U_host_len]
    xor r15d, r15d
.Lua_v6scan:
    test ecx, ecx
    jz .Lua_v6done
    cmp byte ptr [rdi], ':'
    je .Lua_v6
    inc rdi
    dec ecx
    jmp .Lua_v6scan
.Lua_v6:
    mov r15d, 1
.Lua_v6done:
    mov eax, [rbx + U_host_len]
    add rax, r15
    add rax, r15
    add rax, 1                      # NUL
    cmp r13, rax
    jb .Lua_range
    mov r14, r12                    # output cursor
    test r15d, r15d
    jz .Lua_nobracket
    mov byte ptr [r14], '['
    inc r14
.Lua_nobracket:
    mov rsi, [rbx + U_host]
    mov ecx, [rbx + U_host_len]
    mov rdi, r14
    rep movsb
    mov r14, rdi
    test r15d, r15d
    jz .Lua_copied
    mov byte ptr [r14], ']'
    inc r14
.Lua_copied:
    mov byte ptr [r14], 0
    sub r14, r12                    # host length (brackets included)
    movzx ecx, word ptr [rbx + U_port]
    test word ptr [rbx + U_flags], UF_TLS
    jz .Lua_http
    cmp ecx, 443
    je .Lua_done
    jmp .Lua_port
.Lua_http:
    cmp ecx, 80
    je .Lua_done
.Lua_port:
    mov rax, r13
    sub rax, r14
    cmp rax, 7                      # ':' + up to 5 digits + NUL
    jb .Lua_range
    mov rdi, r12
    add rdi, r14
    mov byte ptr [rdi], ':'
    inc rdi
    movzx esi, word ptr [rbx + U_port]
    call fmt_u64
    add r14, 1
    add r14, rax
    mov byte ptr [r12 + r14], 0
.Lua_done:
    mov eax, r14d
.Lua_ret:
    EPILOGUE
.Lua_range:
    mov rax, -ERANGE
    EPILOGUE
