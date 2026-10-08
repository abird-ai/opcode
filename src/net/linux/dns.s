.include "opcode.inc"
# opcode net: linux Layer 1 - hand-rolled DNS A resolver (contract: src/net/net.inc).
#
# Resolution order:
#   1. /etc/hosts, first IPv4 address whose (case-insensitive) name list contains
#      the host.
#   2. up to three nameserver lines from /etc/resolv.conf; when the file is
#      missing or has none, 1.1.1.1 then 8.8.8.8.
#   3. one non-blocking connected UDP socket per server, hand-built query
#      (RD, QTYPE A, QCLASS IN), poll(2) bounded by min(1s, deadline), then a
#      strict response walk: id, QR, TC, RCODE, question skip, answer scan.
#      CNAMEs are simply skipped over while scanning for the first A record.
#   4. -ENOENT when no server yields an A record, -ETIMEDOUT when the overall
#      deadline runs out, -EINVAL for a malformed host.
#
# Returned addresses keep the byte order of the A record RDATA: out_ip4[0] is
# the first dotted octet, so the 4 bytes can be copied verbatim into sockaddr_in.
.include "net/net.inc"

.equ SYS_socket,     41
.equ SYS_connect,    42
.equ SYS_send,       44
.equ SYS_recv,       45
# SYS_close (3) and SYS_poll (7) come from opcode.inc.

.equ SOCK_DGRAM,    2
.equ SOCK_NONBLOCK, 0x800
.equ SOCK_CLOEXEC,  0x80000
.equ MSG_NOSIGNAL,  0x4000

.equ DNS_PORT_BE,     0x3500        # port 53; little-endian word -> bytes 00 35
.equ DNS_ATTEMPT_MS,  1000          # per-nameserver poll budget
.equ DNS_RESP_MAX,    1500
.equ DNS_FILE_MAX,    4095          # /etc/hosts + /etc/resolv.conf scratch
.equ DNS_MAX_SERVERS, 3

# net_dns stack frame (6176 bytes = 386 * 16)
.equ DNS_QBUF,     0                # 512  query
.equ DNS_RBUF,     512              # 1500 response
.equ DNS_ADDR,     2016             # 16   sockaddr_in
.equ DNS_POLL,     2032             # 8    pollfd
.equ DNS_SERVERS,  2048             # 3*4  nameserver addresses
.equ DNS_NSERV,    2060             # 4    count
.equ DNS_QLEN,     2064             # 4    query length
.equ DNS_HOSTLEN,  2068             # 4    host length (trailing dot stripped)
.equ DNS_DLNS,     2072             # 8    deadline duration
.equ DNS_FILEBUF,  2080             # 4096 file scratch
.equ DNS_FRAME,    6176

.text

CSTR .Lpath_hosts, "/etc/hosts"
CSTR .Lpath_resolv, "/etc/resolv.conf"
CSTR .Lk_nameserver, "nameserver"

# ---------------------------------------------------------------- public API
# net_dns(host cstr, out_ip4 /*4 bytes*/, deadline_ms) -> 0 | -errno
FN net_dns
    PROLOGUE DNS_FRAME
    mov rbx, rdi                        # host
    mov r12, rsi                        # out_ip4
    movsxd rax, edx
    imul rax, rax, 1000000
    mov [rsp + DNS_DLNS], rax
    mov edi, CLOCK_MONOTONIC
    call os_now_ns
    add rax, [rsp + DNS_DLNS]
    mov r13, rax                        # absolute monotonic deadline (ns)

    # --- host validation: non-empty, <= 254 chars, one optional trailing dot
    mov rdi, rbx
    call strlen
    test rax, rax
    jz .Ld_einval
    cmp rax, 254
    ja .Ld_einval
    cmp byte ptr [rbx + rax - 1], '.'
    jne .Ld_val_start
    dec rax
.Ld_val_start:
    test rax, rax
    jz .Ld_einval
    mov [rsp + DNS_HOSTLEN], eax
    # labels: 1..63 bytes, printable (no space/control), total encoded <= 254
    xor r8, r8
    xor r9, r9
.Ld_val_label:
    cmp r8, rax
    jae .Ld_hosts
    mov r10, r8
.Ld_val_scan:
    cmp r8, rax
    jae .Ld_val_lend
    movzx ecx, byte ptr [rbx + r8]
    cmp ecx, '.'
    je .Ld_val_lend
    cmp ecx, ' '
    jbe .Ld_einval
    cmp ecx, 127
    je .Ld_einval
    inc r8
    jmp .Ld_val_scan
.Ld_val_lend:
    mov r11, r8
    sub r11, r10
    test r11, r11
    jz .Ld_einval
    cmp r11, 63
    ja .Ld_einval
    lea r9, [r9 + r11 + 1]
    cmp r9, 254
    ja .Ld_einval
    cmp r8, rax
    jae .Ld_hosts
    inc r8
    jmp .Ld_val_label

    # --- 1. /etc/hosts
.Ld_hosts:
    lea rdi, [rip + .Lpath_hosts]
    mov esi, O_RDONLY | O_CLOEXEC
    xor edx, edx
    call os_open
    test rax, rax
    js .Ld_resolv
    mov r14d, eax
    mov edi, r14d
    lea rsi, [rsp + DNS_FILEBUF]
    mov edx, DNS_FILE_MAX
    call .Lread_fd
    mov r15d, eax
    mov edi, r14d
    call os_close
    test r15d, r15d
    jle .Ld_resolv
    lea rdi, [rsp + DNS_FILEBUF]
    mov byte ptr [rdi + r15], 0         # NUL-terminate the last line
    mov esi, r15d
    mov rdx, rbx
    mov ecx, [rsp + DNS_HOSTLEN]
    call .Lhosts_scan
    test eax, eax
    jz .Ld_resolv
    mov dword ptr [r12], edx
    xor eax, eax
    EPILOGUE

    # --- 2. nameservers
.Ld_resolv:
    lea rdi, [rip + .Lpath_resolv]
    mov esi, O_RDONLY | O_CLOEXEC
    xor edx, edx
    call os_open
    test rax, rax
    js .Ld_fallback
    mov r14d, eax
    mov edi, r14d
    lea rsi, [rsp + DNS_FILEBUF]
    mov edx, DNS_FILE_MAX
    call .Lread_fd
    mov r15d, eax
    mov edi, r14d
    call os_close
    test r15d, r15d
    jle .Ld_fallback
    lea rdi, [rsp + DNS_FILEBUF]
    mov byte ptr [rdi + r15], 0
    mov esi, r15d
    lea rdx, [rsp + DNS_SERVERS]
    call .Lresolv_scan
    test eax, eax
    jnz .Ld_have_servers
.Ld_fallback:
    mov dword ptr [rsp + DNS_SERVERS], 0x01010101       # 1.1.1.1 (bytes 01 01 01 01)
    mov dword ptr [rsp + DNS_SERVERS + 4], 0x08080808   # 8.8.8.8 (bytes 08 08 08 08)
    mov eax, 2
.Ld_have_servers:
    mov [rsp + DNS_NSERV], eax

    # --- 3. build the query
    lea rdi, [rsp + DNS_QBUF]
    mov esi, 2
    call os_random
    mov word ptr [rsp + DNS_QBUF + 2], 0x0001     # flags 0x0100 (RD): bytes 01 00
    mov word ptr [rsp + DNS_QBUF + 4], 0x0100     # QDCOUNT 1: bytes 00 01
    mov word ptr [rsp + DNS_QBUF + 6], 0          # ANCOUNT
    mov dword ptr [rsp + DNS_QBUF + 8], 0         # NSCOUNT + ARCOUNT
    lea rdi, [rsp + DNS_QBUF + 12]
    xor r8, r8
    mov r9d, [rsp + DNS_HOSTLEN]
.Ld_qb_label:
    cmp r8, r9
    jae .Ld_qb_done
    mov r10, r8
.Ld_qb_scan:
    cmp r8, r9
    jae .Ld_qb_lend
    cmp byte ptr [rbx + r8], '.'
    je .Ld_qb_lend
    inc r8
    jmp .Ld_qb_scan
.Ld_qb_lend:
    mov r11, r8
    sub r11, r10
    mov byte ptr [rdi], r11b
    inc rdi
    lea rax, [rbx + r10]
    xor ecx, ecx
.Ld_qb_copy:
    cmp rcx, r11
    jae .Ld_qb_copied
    mov dl, [rax + rcx]
    mov [rdi + rcx], dl
    inc rcx
    jmp .Ld_qb_copy
.Ld_qb_copied:
    add rdi, r11
    inc r8
    jmp .Ld_qb_label
.Ld_qb_done:
    mov byte ptr [rdi], 0                         # root label
    mov word ptr [rdi + 1], 0x0100                # QTYPE A: bytes 00 01
    mov word ptr [rdi + 3], 0x0100                # QCLASS IN: bytes 00 01
    add rdi, 5
    lea rax, [rsp + DNS_QBUF]
    sub rdi, rax
    mov [rsp + DNS_QLEN], edi

    # --- 4. try each nameserver in order
    xor r15d, r15d
.Ld_server:
    cmp r15d, [rsp + DNS_NSERV]
    jae .Ld_noanswer
    mov edi, CLOCK_MONOTONIC
    call os_now_ns
    cmp rax, r13
    jae .Ld_timeout
    mov eax, dword ptr [rsp + DNS_SERVERS + r15*4]
    mov edi, eax
    lea rsi, [rsp + DNS_QBUF]
    mov edx, [rsp + DNS_QLEN]
    lea rcx, [rsp + DNS_RBUF]
    mov r8, r13
    mov r9, r12
    call .Lquery_server
    test rax, rax
    jz .Ld_ok
    cmp rax, -ENOENT
    je .Ld_done
    inc r15d
    jmp .Ld_server
.Ld_noanswer:
    mov edi, CLOCK_MONOTONIC
    call os_now_ns
    cmp rax, r13
    jae .Ld_timeout
    mov rax, -ENOENT
    jmp .Ld_done
.Ld_timeout:
    mov rax, -ETIMEDOUT
    jmp .Ld_done
.Ld_einval:
    mov rax, -EINVAL
    jmp .Ld_done
.Ld_ok:
    xor eax, eax
.Ld_done:
    EPILOGUE

# ---------------------------------------------------------------- file reader
# .Lread_fd(fd edi, buf rsi, cap edx) -> total bytes read | -errno
.Lread_fd:
    PROLOGUE 16
    mov r12d, edi
    mov r13, rsi
    mov r14d, edx
    xor ebx, ebx
.Lrf_loop:
    test r14d, r14d
    jz .Lrf_done
    mov edi, r12d
    lea rsi, [r13 + rbx]
    mov edx, r14d
    call os_read
    cmp rax, -EINTR
    je .Lrf_loop
    test rax, rax
    js .Lrf_err
    jz .Lrf_done
    add rbx, rax
    sub r14d, eax
    jmp .Lrf_loop
.Lrf_done:
    mov eax, ebx
.Lrf_err:
    EPILOGUE

# ---------------------------------------------------------------- ip parsing
# .Lparse_ip4(cstr rdi) -> eax = address bytes (memory order), edx = 1 | 0.
# Strict dotted quad, 1..3 digits per octet, 0..255, no trailing junk. Leaf.
.Lparse_ip4:
    xor r8d, r8d
    xor r9d, r9d
    xor r10d, r10d
    xor eax, eax
.Lpi_loop:
    movzx ecx, byte ptr [rdi]
    sub ecx, '0'
    cmp ecx, 9
    ja .Lpi_sep
    imul eax, eax, 10
    add eax, ecx
    inc r10d
    inc rdi
    cmp r10d, 3
    ja .Lpi_bad
    jmp .Lpi_loop
.Lpi_sep:
    test r10d, r10d
    jz .Lpi_bad
    cmp eax, 255
    ja .Lpi_bad
    mov ecx, r9d
    shl ecx, 3
    shl eax, cl
    or r8d, eax
    xor eax, eax
    xor r10d, r10d
    cmp r9d, 3
    je .Lpi_end
    cmp byte ptr [rdi], '.'
    jne .Lpi_bad
    inc rdi
    inc r9d
    jmp .Lpi_loop
.Lpi_end:
    cmp byte ptr [rdi], 0
    jne .Lpi_bad
    mov eax, r8d
    mov edx, 1
    ret
.Lpi_bad:
    xor eax, eax
    xor edx, edx
    ret

# .Lci_eq(host rdi, token rsi, len rdx) -> eax 1 | 0. Case-insensitive, the
# token is a length-delimited slice of a file, the host is NUL-terminated.
.Lci_eq:
    xor ecx, ecx
.Lce_loop:
    cmp rcx, rdx
    jae .Lce_end
    movzx eax, byte ptr [rdi + rcx]
    test al, al
    jz .Lce_no
    movzx r8d, byte ptr [rsi + rcx]
    lea r9d, [rax - 65]                 # 'A'
    cmp r9d, 25
    ja .Lce_a
    add eax, 32
.Lce_a:
    lea r9d, [r8 - 65]
    cmp r9d, 25
    ja .Lce_b
    add r8d, 32
.Lce_b:
    cmp eax, r8d
    jne .Lce_no
    inc rcx
    jmp .Lce_loop
.Lce_end:
    cmp byte ptr [rdi + rcx], 0
    jne .Lce_no
    mov eax, 1
    ret
.Lce_no:
    xor eax, eax
    ret

# ---------------------------------------------------------------- /etc/hosts
# .Lhosts_scan(buf rdi, len rsi, host rdx, hostlen ecx) -> eax found, edx ip.
# Only lines whose first whitespace-delimited token is an IPv4 address are
# considered; every following token is compared to the host.
.Lhosts_scan:
    PROLOGUE 64
    mov rbx, rdi
    mov r12, rdx
    mov r13d, ecx
    mov r14, rdi
    lea r15, [rdi + rsi]
.Lhs_line:
    cmp r14, r15
    jae .Lhs_no
    movzx eax, byte ptr [r14]
    test al, al
    jz .Lhs_no
    cmp al, ' '
    je .Lhs_line_ws
    cmp al, 9
    je .Lhs_line_ws
    cmp al, 13
    je .Lhs_line_adv
    cmp al, 10
    je .Lhs_line_adv
    cmp al, '#'
    je .Lhs_to_nl
    # first token: candidate IPv4 address
    mov r8, r14
.Lhs_ip_scan:
    cmp r14, r15
    jae .Lhs_ip_end
    movzx eax, byte ptr [r14]
    test al, al
    jz .Lhs_ip_end
    cmp al, ' '
    je .Lhs_ip_end
    cmp al, 9
    je .Lhs_ip_end
    cmp al, 13
    je .Lhs_ip_end
    cmp al, 10
    je .Lhs_ip_end
    inc r14
    jmp .Lhs_ip_scan
.Lhs_ip_end:
    mov rax, r14
    sub rax, r8
    test rax, rax
    jz .Lhs_to_nl
    cmp rax, 15
    ja .Lhs_to_nl                       # IPv6 or junk: ignore the whole line
    xor ecx, ecx
.Lhs_ip_copy:
    cmp rcx, rax
    jae .Lhs_ip_copied
    mov dl, [r8 + rcx]
    mov [rsp + rcx], dl
    inc rcx
    jmp .Lhs_ip_copy
.Lhs_ip_copied:
    mov byte ptr [rsp + rcx], 0
    lea rdi, [rsp]
    call .Lparse_ip4
    test edx, edx
    jz .Lhs_to_nl
    mov [rsp + 48], eax                 # candidate address
    # remaining tokens: aliases
.Lhs_alias:
    cmp r14, r15
    jae .Lhs_no
    movzx eax, byte ptr [r14]
    test al, al
    jz .Lhs_no
    cmp al, ' '
    je .Lhs_alias_ws
    cmp al, 9
    je .Lhs_alias_ws
    cmp al, 13
    je .Lhs_line_adv
    cmp al, 10
    je .Lhs_line_adv
    cmp al, '#'
    je .Lhs_to_nl
    mov r8, r14
.Lhs_alias_scan:
    cmp r14, r15
    jae .Lhs_alias_end
    movzx eax, byte ptr [r14]
    test al, al
    jz .Lhs_alias_end
    cmp al, ' '
    je .Lhs_alias_end
    cmp al, 9
    je .Lhs_alias_end
    cmp al, 13
    je .Lhs_alias_end
    cmp al, 10
    je .Lhs_alias_end
    inc r14
    jmp .Lhs_alias_scan
.Lhs_alias_end:
    mov rax, r14
    sub rax, r8
    cmp eax, r13d
    jne .Lhs_alias
    mov rdi, r12
    mov rsi, r8
    mov rdx, rax
    call .Lci_eq
    test eax, eax
    jz .Lhs_alias
    mov eax, 1
    mov edx, [rsp + 48]
    EPILOGUE
.Lhs_line_ws:
    inc r14
    jmp .Lhs_line
.Lhs_line_adv:
    inc r14
    jmp .Lhs_line
.Lhs_alias_ws:
    inc r14
    jmp .Lhs_alias
.Lhs_to_nl:
    cmp r14, r15
    jae .Lhs_no
    movzx eax, byte ptr [r14]
    test al, al
    jz .Lhs_no
    cmp al, 10
    je .Lhs_line_adv
    inc r14
    jmp .Lhs_to_nl
.Lhs_no:
    xor eax, eax
    EPILOGUE

# ---------------------------------------------------------------- resolv.conf
# .Lresolv_scan(buf rdi, len rsi, servers rdx) -> eax = count (0..3).
# First three `nameserver <ip>` lines; '#' and ';' start comments.
.Lresolv_scan:
    PROLOGUE 64
    mov rbx, rdx
    xor r12d, r12d
    mov r13, rdi
    lea r14, [rdi + rsi]
.Lrs_line:
    cmp r13, r14
    jae .Lrs_done
    movzx eax, byte ptr [r13]
    test al, al
    jz .Lrs_done
    cmp al, ' '
    je .Lrs_line_ws
    cmp al, 9
    je .Lrs_line_ws
    cmp al, 10
    je .Lrs_nl_adv
    cmp al, 13
    je .Lrs_nl_adv
    cmp al, '#'
    je .Lrs_skip
    cmp al, ';'
    je .Lrs_skip
    mov r15, r13
.Lrs_tok:
    cmp r13, r14
    jae .Lrs_tok_end
    movzx eax, byte ptr [r13]
    test al, al
    jz .Lrs_tok_end
    cmp al, ' '
    je .Lrs_tok_end
    cmp al, 9
    je .Lrs_tok_end
    cmp al, 10
    je .Lrs_tok_end
    cmp al, 13
    je .Lrs_tok_end
    inc r13
    jmp .Lrs_tok
.Lrs_tok_end:
    mov rax, r13
    sub rax, r15
    cmp rax, 10
    jne .Lrs_skip
    mov rdi, r15
    lea rsi, [rip + .Lk_nameserver]
    mov edx, 10
    call memeq
    test eax, eax
    jz .Lrs_skip
.Lrs_addr_ws:
    cmp r13, r14
    jae .Lrs_done
    movzx eax, byte ptr [r13]
    test al, al
    jz .Lrs_done
    cmp al, ' '
    je .Lrs_addr_ws_adv
    cmp al, 9
    je .Lrs_addr_ws_adv
    jmp .Lrs_addr
.Lrs_addr_ws_adv:
    inc r13
    jmp .Lrs_addr_ws
.Lrs_addr:
    mov r15, r13
.Lrs_addr_scan:
    cmp r13, r14
    jae .Lrs_addr_end
    movzx eax, byte ptr [r13]
    test al, al
    jz .Lrs_addr_end
    cmp al, ' '
    je .Lrs_addr_end
    cmp al, 9
    je .Lrs_addr_end
    cmp al, 10
    je .Lrs_addr_end
    cmp al, 13
    je .Lrs_addr_end
    inc r13
    jmp .Lrs_addr_scan
.Lrs_addr_end:
    mov rax, r13
    sub rax, r15
    test rax, rax
    jz .Lrs_skip
    cmp rax, 15
    ja .Lrs_skip
    cmp r12d, DNS_MAX_SERVERS
    jae .Lrs_skip
    xor ecx, ecx
.Lrs_addr_copy:
    cmp rcx, rax
    jae .Lrs_addr_copied
    mov dl, [r15 + rcx]
    mov [rsp + rcx], dl
    inc rcx
    jmp .Lrs_addr_copy
.Lrs_addr_copied:
    mov byte ptr [rsp + rcx], 0
    lea rdi, [rsp]
    call .Lparse_ip4
    test edx, edx
    jz .Lrs_skip
    mov [rbx + r12*4], eax
    inc r12d
.Lrs_skip:
.Lrs_nl:
    cmp r13, r14
    jae .Lrs_done
    movzx eax, byte ptr [r13]
    test al, al
    jz .Lrs_done
    cmp al, 10
    je .Lrs_nl_adv
    inc r13
    jmp .Lrs_nl
.Lrs_nl_adv:
    inc r13
    jmp .Lrs_line
.Lrs_line_ws:
    inc r13
    jmp .Lrs_line
.Lrs_done:
    mov eax, r12d
    EPILOGUE

# ---------------------------------------------------------------- name skip
# .Lskip_name(cursor rdi, end rsi) -> rax = cursor after the name | 0.
# Handles label sequences and stops after a 0xC0 compression pointer. Leaf.
.Lskip_name:
.Lsn_loop:
    cmp rdi, rsi
    jae .Lsn_bad
    movzx eax, byte ptr [rdi]
    inc rdi
    test eax, eax
    jz .Lsn_ok
    mov ecx, eax
    and ecx, 0xC0
    cmp ecx, 0xC0
    je .Lsn_ptr
    test ecx, ecx
    jnz .Lsn_bad                       # reserved label type
    add rdi, rax
    cmp rdi, rsi
    ja .Lsn_bad
    jmp .Lsn_loop
.Lsn_ptr:
    cmp rdi, rsi
    jae .Lsn_bad
    inc rdi
.Lsn_ok:
    mov rax, rdi
    ret
.Lsn_bad:
    xor eax, eax
    ret

# ---------------------------------------------------------------- response
# .Lparse_response(buf rdi, len rsi, out rdx, id ecx) -> eax 0 | -ENOENT | -EAGAIN
# -EAGAIN means "malformed or no A answer, try the next server".
.Lparse_response:
    PROLOGUE 0
    cmp rsi, 12
    jb .Lpr_bad
    movzx eax, word ptr [rdi]
    cmp ax, cx
    jne .Lpr_bad
    movzx eax, byte ptr [rdi + 2]
    test al, 0x80                      # QR
    jz .Lpr_bad
    test al, 0x02                      # TC: ignore truncated answers
    jnz .Lpr_bad
    movzx eax, byte ptr [rdi + 3]
    and eax, 0x0F                      # RCODE
    cmp eax, 3
    je .Lpr_nx
    test eax, eax
    jnz .Lpr_bad
    movzx r10d, word ptr [rdi + 6]     # ANCOUNT (big-endian)
    rol r10w, 8
    movzx r11d, word ptr [rdi + 4]     # QDCOUNT
    rol r11w, 8
    mov r8, rdi
    add r8, 12
    mov r9, rdi
    add r9, rsi
.Lpr_qloop:
    test r11d, r11d
    jz .Lpr_aloop
    mov rdi, r8
    mov rsi, r9
    call .Lskip_name
    test rax, rax
    jz .Lpr_bad
    mov r8, rax
    add r8, 4                          # QTYPE + QCLASS
    cmp r8, r9
    ja .Lpr_bad
    dec r11d
    jmp .Lpr_qloop
.Lpr_aloop:
    test r10d, r10d
    jz .Lpr_bad
    mov rdi, r8
    mov rsi, r9
    call .Lskip_name
    test rax, rax
    jz .Lpr_bad
    mov r8, rax
    lea rcx, [r8 + 10]                 # TYPE+CLASS+TTL+RDLENGTH
    cmp rcx, r9
    ja .Lpr_bad
    movzx eax, word ptr [r8]
    rol ax, 8
    cmp eax, 1                         # TYPE A
    jne .Lpr_anext
    movzx eax, word ptr [r8 + 2]
    rol ax, 8
    cmp eax, 1                         # CLASS IN
    jne .Lpr_anext
    movzx eax, word ptr [r8 + 8]
    rol ax, 8
    cmp eax, 4                         # RDLENGTH
    jne .Lpr_anext
    lea rcx, [r8 + 14]
    cmp rcx, r9
    ja .Lpr_bad
    mov eax, dword ptr [r8 + 10]
    mov dword ptr [rdx], eax
    xor eax, eax
    EPILOGUE
.Lpr_anext:
    movzx eax, word ptr [r8 + 8]
    rol ax, 8
    lea r8, [r8 + 10]
    add r8, rax
    cmp r8, r9
    ja .Lpr_bad
    dec r10d
    jmp .Lpr_aloop
.Lpr_nx:
    mov rax, -ENOENT
    EPILOGUE
.Lpr_bad:
    mov rax, -EAGAIN
    EPILOGUE

# ---------------------------------------------------------------- exchange
# .Lquery_server(ip edi, query rsi, qlen edx, resp rcx, deadline r8, out r9)
#   -> 0 | -ENOENT | -ETIMEDOUT | -EAGAIN | -errno
# One non-blocking connected UDP socket. ip carries the address bytes in
# memory order, so it is stored verbatim into sockaddr_in.
.Lquery_server:
    PROLOGUE 48
    mov [rsp], rsi                      # query
    mov [rsp + 8], edx                  # qlen
    mov r13, rcx                        # response buffer
    mov r14, r8                         # deadline
    mov r15, r9                         # out_ip4
    mov r12d, edi
    mov edi, AF_INET
    mov esi, SOCK_DGRAM | SOCK_NONBLOCK | SOCK_CLOEXEC
    xor edx, edx
    SYS SYS_socket
    test rax, rax
    js .Lqs_ret
    mov rbx, rax                        # fd
    mov word ptr [rsp + 24], AF_INET
    mov word ptr [rsp + 26], DNS_PORT_BE
    mov dword ptr [rsp + 28], r12d
    mov qword ptr [rsp + 32], 0
    mov edi, ebx
    lea rsi, [rsp + 24]
    mov edx, 16
    SYS SYS_connect
    test rax, rax
    js .Lqs_finish
    mov edi, ebx
    mov rsi, [rsp]
    mov edx, [rsp + 8]
    mov r10d, MSG_NOSIGNAL
    xor r8d, r8d                        # syscall 44 is sendto: dest_addr = 0
    xor r9d, r9d                        # addrlen = 0
    SYS SYS_send
    test rax, rax
    js .Lqs_finish
.Lqs_poll:
    mov edi, CLOCK_MONOTONIC
    call os_now_ns
    mov rcx, r14
    sub rcx, rax
    jbe .Lqs_timeout
    mov rax, rcx
    add rax, 999999
    xor edx, edx
    mov ecx, 1000000
    div rcx
    cmp rax, DNS_ATTEMPT_MS
    jbe .Lqs_ms
    mov eax, DNS_ATTEMPT_MS
.Lqs_ms:
    mov dword ptr [rsp + 16], ebx
    mov word ptr [rsp + 20], POLLIN
    mov word ptr [rsp + 22], 0
    lea rdi, [rsp + 16]
    mov esi, 1
    mov rdx, rax
    SYS SYS_poll
    test rax, rax
    js .Lqs_poll_err
    jz .Lqs_timeout
    mov edi, ebx
    mov rsi, r13
    mov edx, DNS_RESP_MAX
    xor r10d, r10d
    xor r8d, r8d                        # syscall 45 is recvfrom: src_addr = 0
    xor r9d, r9d                        # addrlen = 0
    SYS SYS_recv
    test rax, rax
    js .Lqs_recv_err
    test rax, rax
    jz .Lqs_bad
    mov rdi, r13
    mov rsi, rax
    mov rdx, r15
    mov rcx, [rsp]
    movzx ecx, word ptr [rcx]           # query id
    call .Lparse_response
    test rax, rax
    jz .Lqs_ok
    cmp rax, -ENOENT
    je .Lqs_finish
    jmp .Lqs_bad
.Lqs_poll_err:
    cmp rax, -EINTR
    je .Lqs_poll
    jmp .Lqs_finish
.Lqs_recv_err:
    cmp rax, -EINTR
    je .Lqs_poll
    cmp rax, -EAGAIN
    je .Lqs_poll
    jmp .Lqs_finish
.Lqs_bad:
    mov rax, -EAGAIN
    jmp .Lqs_finish
.Lqs_timeout:
    mov rax, -ETIMEDOUT
.Lqs_finish:
    mov r12, rax
    mov edi, ebx
    call os_close
    mov rax, r12
    EPILOGUE
.Lqs_ok:
    xor eax, eax
    jmp .Lqs_finish
.Lqs_ret:
    EPILOGUE
