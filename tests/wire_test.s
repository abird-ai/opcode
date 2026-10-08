.include "opcode.inc"
.include "wire/url.inc"
# wire_test: url_parse/url_copy_host and the HTTP response parser.
#
# The Url layout comes from wire/url.inc, the single source of truth shared
# with url.s/http_client.s.

.bss
.p2align 3
url:    .zero 64
urlbuf: .zero 64
resp:   .zero 2048
bodyst: .zero 264             # [0]=len, [8..]=body bytes
reqsb:  .zero SB_SIZE
req2sb: .zero SB_SIZE

.section .rodata
# ---- url inputs
url_https:  .asciz "https://api.example.com/v1/messages"
url_http:   .asciz "http://example.com"
url_port:   .asciz "http://localhost:8080/a/b?q=1"
url_user:   .asciz "https://user:pw@h.example.com/z"
url_bad:    .asciz "not a url"
url_bigport:.asciz "https://h.example.com:70000/x"
url_badport:.asciz "http://h.example.com:abc/"
url_nohost: .asciz "http://"
url_frag:   .asciz "http://h.example.com/p#f?q"
url_upper:  .asciz "HTTP://EXAMPLE.COM/"
url_v6:     .asciz "https://[::1]:8443/x"
url_v6_def: .asciz "https://[::1]/x"

# ---- expected url pieces
.c_https:   .asciz "https"
.c_api:     .asciz "api.example.com"
.c_v1:      .asciz "/v1/messages"
.c_example: .asciz "example.com"
.c_localhost: .asciz "localhost"
.c_localhost_port: .asciz "localhost:8080"
.c_ab:      .asciz "/a/b"
.c_q1:      .asciz "q=1"
.c_hez:     .asciz "h.example.com"
.c_z:       .asciz "/z"
.c_p:       .asciz "/p"
.c_upper:   .asciz "EXAMPLE.COM"
.c_v6_host:.asciz "::1"
.c_v6_authority: .asciz "[::1]:8443"
.c_v6_default:   .asciz "[::1]"
.s_post:    .asciz "POST"
.s_v1x:     .asciz "/v1/x"
.s_xtest:   .asciz "X-Test"
.s_yes:     .asciz "yes"
.s_get:     .asciz "GET"
.s_slash:   .asciz "/"
.s_accept:  .asciz "Accept"
.s_star:    .asciz "*/*"

# ---- expected http pieces
.c_hello:   .asciz "hello"
.c_abcde:   .asciz "abcde"
.c_cl_lc:   .asciz "content-length"
.c_cl:      .asciz "Content-Length"
.c_xfoo:    .asciz "x-foo"
.c_five:    .asciz "5"

# ---- canned responses
resp_simple:
    .ascii "HTTP/1.1 200 OK\r\n"
    .ascii "Content-Length: 5\r\n"
    .ascii "X-Foo: Bar\r\n"
    .ascii "\r\n"
    .ascii "hello"
resp_simple_end:
    .ascii "XYZ"
resp_simple_total_end:
.equ SIMPLE_LEN, resp_simple_end - resp_simple
.equ SIMPLE_TOTAL, resp_simple_total_end - resp_simple

resp_chunked:
    .ascii "HTTP/1.1 200 OK\r\n"
    .ascii "Transfer-Encoding: chunked\r\n"
    .ascii "\r\n"
    .ascii "3;ext=1\r\nabc\r\n"
    .ascii "2\r\nde\r\n"
    .ascii "0\r\n"
    .ascii "X-Trailer: t\r\n"
    .ascii "\r\n"
resp_chunked_end:
    .ascii "TAIL"
resp_chunked_total_end:
.equ CHUNKED_LEN, resp_chunked_end - resp_chunked
.equ CHUNKED_TOTAL, resp_chunked_total_end - resp_chunked

resp_close:
    .ascii "HTTP/1.0 200 OK\r\n"
    .ascii "Content-Length: 0\r\n"
    .ascii "\r\n"
resp_close_end:
.equ CLOSE_LEN, resp_close_end - resp_close

resp_204:
    .ascii "HTTP/1.1 204 No Content\r\n"
    .ascii "\r\n"
resp_204_end:
.equ R204_LEN, resp_204_end - resp_204

resp_badchunk:
    .ascii "HTTP/1.1 200 OK\r\n"
    .ascii "Transfer-Encoding: chunked\r\n"
    .ascii "\r\n"
    .ascii "Z\r\n"
resp_badchunk_end:
.equ BADCHUNK_LEN, resp_badchunk_end - resp_badchunk

resp_toolong:
    .ascii "HTTP/1.1 200 OK\r\n"
    .ascii "X-Long: "
    .rept 9000
    .byte 'a'
    .endr
    .ascii "\r\n\r\n"
resp_toolong_end:
.equ TOOLONG_LEN, resp_toolong_end - resp_toolong

# duplicate Content-Length: must be rejected, not last-win
resp_dupcl:
    .ascii "HTTP/1.1 200 OK\r\n"
    .ascii "Content-Length: 5\r\n"
    .ascii "Content-Length: 5\r\n"
    .ascii "\r\n"
    .ascii "hello"
resp_dupcl_end:
.equ DUPCL_LEN, resp_dupcl_end - resp_dupcl

# Transfer-Encoding: xchunked is not the chunked token (no substring match)
resp_xchunked:
    .ascii "HTTP/1.1 200 OK\r\n"
    .ascii "Transfer-Encoding: xchunked\r\n"
    .ascii "\r\n"
    .ascii "hello"
resp_xchunked_end:
.equ XCHUNKED_LEN, resp_xchunked_end - resp_xchunked

# ---- expected requests
req_expected:
    .ascii "POST /v1/x HTTP/1.1\r\n"
    .ascii "Host: api.example.com\r\n"
    .ascii "X-Test: yes\r\n"
    .ascii "Content-Length: 5\r\n"
    .ascii "\r\n"
    .ascii "hello"
req_expected_end:
req2_expected:
    .ascii "GET / HTTP/1.1\r\n"
    .ascii "Host: api.example.com\r\n"
    .ascii "Accept: */*\r\n"
    .ascii "\r\n"
req2_expected_end:

# ---- output lines
.m_url_https_ok:    .asciz "url ok https\n"
.m_url_https_fail:  .asciz "url FAIL https\n"
.m_url_http_ok:     .asciz "url ok http\n"
.m_url_http_fail:   .asciz "url FAIL http\n"
.m_url_port_ok:     .asciz "url ok port\n"
.m_url_port_fail:   .asciz "url FAIL port\n"
.m_url_v6_ok:       .asciz "url ok ipv6\n"
.m_url_v6_fail:     .asciz "url FAIL ipv6\n"
.m_url_user_ok:     .asciz "url ok userinfo\n"
.m_url_user_fail:   .asciz "url FAIL userinfo\n"
.m_url_invalid_ok:  .asciz "url ok invalid\n"
.m_url_invalid_fail:.asciz "url FAIL invalid\n"
.m_http_simple_ok:  .asciz "http ok simple\n"
.m_http_simple_fail:.asciz "http FAIL simple\n"
.m_http_chunked_ok: .asciz "http ok chunked\n"
.m_http_chunked_fail:.asciz "http FAIL chunked\n"
.m_http_split_ok:   .asciz "http ok split\n"
.m_http_split_fail: .asciz "http FAIL split\n"
.m_http_close_ok:   .asciz "http ok close\n"
.m_http_close_fail: .asciz "http FAIL close\n"
.m_http_204_ok:     .asciz "http ok 204\n"
.m_http_204_fail:   .asciz "http FAIL 204\n"
.m_http_badchunk_ok:.asciz "http ok badchunk\n"
.m_http_badchunk_fail:.asciz "http FAIL badchunk\n"
.m_http_toolong_ok: .asciz "http ok toolong\n"
.m_http_toolong_fail:.asciz "http FAIL toolong\n"
.m_http_dupcl_ok:   .asciz "http ok duplicate-cl\n"
.m_http_dupcl_fail: .asciz "http FAIL duplicate-cl\n"
.m_http_xchunk_ok:  .asciz "http ok xchunked\n"
.m_http_xchunk_fail:.asciz "http FAIL xchunked\n"
.m_http_request_fail:.asciz "http FAIL request\n"
.m_wire_done:       .asciz "wire done\n"

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

# body_cb(ctx, ptr, len): append to ctx->buf
FN body_cb
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rcx, [rbx]
    lea rdi, [rbx + rcx + 8]
    mov rsi, r12
    mov rdx, r13
    call memcpy
    add [rbx], r13
    EPILOGUE

# init_parser(): reset resp + body state and call http_resp_init
init_parser:
    PROLOGUE 0
    lea rdi, [rip + resp]
    xor esi, esi
    mov edx, 2048
    call memset
    lea rdi, [rip + resp]
    lea rsi, [rip + body_cb]
    lea rdx, [rip + bodyst]
    call http_resp_init
    mov qword ptr [rip + bodyst], 0
    EPILOGUE

FN opcode_main
    PROLOGUE 0
    xor r13d, r13d                  # failure flag

    # ============================== url https
    lea rdi, [rip + url_https]
    lea rsi, [rip + url]
    call url_parse
    test eax, eax
    jnz .Lfail_https
    movzx eax, word ptr [rip + url + U_flags]
    and eax, UF_TLS
    cmp eax, UF_TLS
    jne .Lfail_https
    movzx eax, word ptr [rip + url + U_port]
    cmp eax, 443
    jne .Lfail_https
    mov rdi, [rip + url + U_scheme]
    mov esi, [rip + url + U_scheme_len]
    lea rdx, [rip + .c_https]
    call str_eq_cstr
    test eax, eax
    jz .Lfail_https
    mov rdi, [rip + url + U_host]
    mov esi, [rip + url + U_host_len]
    lea rdx, [rip + .c_api]
    call str_eq_cstr
    test eax, eax
    jz .Lfail_https
    mov rdi, [rip + url + U_path]
    mov esi, [rip + url + U_path_len]
    lea rdx, [rip + .c_v1]
    call str_eq_cstr
    test eax, eax
    jz .Lfail_https
    # url_copy_host success
    lea rdi, [rip + url]
    lea rsi, [rip + urlbuf]
    mov edx, 32
    call url_copy_host
    cmp eax, 15
    jne .Lfail_https
    cmp byte ptr [rip + urlbuf + 15], 0
    jne .Lfail_https
    lea rdi, [rip + urlbuf]
    mov esi, 15
    lea rdx, [rip + .c_api]
    call str_eq_cstr
    test eax, eax
    jz .Lfail_https
    # url_authority omits the scheme-default https port
    lea rdi, [rip + url]
    lea rsi, [rip + urlbuf]
    mov edx, 32
    call url_authority
    cmp eax, 15
    jne .Lfail_https
    # url_copy_host ERANGE
    lea rdi, [rip + url]
    lea rsi, [rip + urlbuf]
    mov edx, 4
    call url_copy_host
    cmp eax, -ERANGE
    jne .Lfail_https
    lea rdi, [rip + .m_url_https_ok]
    call print
    jmp .Lnext_https
.Lfail_https:
    mov r13d, 1
    lea rdi, [rip + .m_url_https_fail]
    call print
.Lnext_https:

    # ============================== url http
    lea rdi, [rip + url_http]
    lea rsi, [rip + url]
    call url_parse
    test eax, eax
    jnz .Lfail_http
    movzx eax, word ptr [rip + url + U_flags]
    test eax, UF_TLS
    jnz .Lfail_http
    movzx eax, word ptr [rip + url + U_port]
    cmp eax, 80
    jne .Lfail_http
    mov rdi, [rip + url + U_host]
    mov esi, [rip + url + U_host_len]
    lea rdx, [rip + .c_example]
    call str_eq_cstr
    test eax, eax
    jz .Lfail_http
    mov eax, [rip + url + U_path_len]
    cmp eax, 1
    jne .Lfail_http
    mov rax, [rip + url + U_path]
    cmp byte ptr [rax], '/'
    jne .Lfail_http
    cmp qword ptr [rip + url + U_query], 0
    jne .Lfail_http
    lea rdi, [rip + .m_url_http_ok]
    call print
    jmp .Lnext_http
.Lfail_http:
    mov r13d, 1
    lea rdi, [rip + .m_url_http_fail]
    call print
.Lnext_http:

    # ============================== url port + query
    lea rdi, [rip + url_port]
    lea rsi, [rip + url]
    call url_parse
    test eax, eax
    jnz .Lfail_port
    movzx eax, word ptr [rip + url + U_port]
    cmp eax, 8080
    jne .Lfail_port
    mov rdi, [rip + url + U_host]
    mov esi, [rip + url + U_host_len]
    lea rdx, [rip + .c_localhost]
    call str_eq_cstr
    test eax, eax
    jz .Lfail_port
    mov rdi, [rip + url + U_path]
    mov esi, [rip + url + U_path_len]
    lea rdx, [rip + .c_ab]
    call str_eq_cstr
    test eax, eax
    jz .Lfail_port
    cmp dword ptr [rip + url + U_query_len], 3
    jne .Lfail_port
    # url_authority includes the non-default port
    lea rdi, [rip + url]
    lea rsi, [rip + urlbuf]
    mov edx, 32
    call url_authority
    cmp eax, 14
    jne .Lfail_port
    lea rdi, [rip + urlbuf]
    mov esi, 14
    lea rdx, [rip + .c_localhost_port]
    call str_eq_cstr
    test eax, eax
    jz .Lfail_port
    mov rdi, [rip + url + U_query]
    mov esi, [rip + url + U_query_len]
    lea rdx, [rip + .c_q1]
    call str_eq_cstr
    test eax, eax
    jz .Lfail_port
    lea rdi, [rip + .m_url_port_ok]
    call print
    jmp .Lnext_port
.Lfail_port:
    mov r13d, 1
    lea rdi, [rip + .m_url_port_fail]
    call print
.Lnext_port:

    # ============================== url ipv6 authority
    lea rdi, [rip + url_v6]
    lea rsi, [rip + url]
    call url_parse
    test eax, eax
    jnz .Lfail_v6
    # SNI/copy still sees the literal without brackets
    mov rdi, [rip + url + U_host]
    mov esi, [rip + url + U_host_len]
    lea rdx, [rip + .c_v6_host]
    call str_eq_cstr
    test eax, eax
    jz .Lfail_v6
    # Host authority must re-bracket and keep the non-default port
    lea rdi, [rip + url]
    lea rsi, [rip + urlbuf]
    mov edx, 32
    call url_authority
    cmp eax, 10
    jne .Lfail_v6
    lea rdi, [rip + urlbuf]
    mov esi, 10
    lea rdx, [rip + .c_v6_authority]
    call str_eq_cstr
    test eax, eax
    jz .Lfail_v6
    # default port: brackets stay, the port is dropped
    lea rdi, [rip + url_v6_def]
    lea rsi, [rip + url]
    call url_parse
    test eax, eax
    jnz .Lfail_v6
    lea rdi, [rip + url]
    lea rsi, [rip + urlbuf]
    mov edx, 32
    call url_authority
    cmp eax, 5
    jne .Lfail_v6
    lea rdi, [rip + urlbuf]
    mov esi, 5
    lea rdx, [rip + .c_v6_default]
    call str_eq_cstr
    test eax, eax
    jz .Lfail_v6
    lea rdi, [rip + .m_url_v6_ok]
    call print
    jmp .Lnext_v6
.Lfail_v6:
    mov r13d, 1
    lea rdi, [rip + .m_url_v6_fail]
    call print
.Lnext_v6:

    # ============================== url userinfo
    lea rdi, [rip + url_user]
    lea rsi, [rip + url]
    call url_parse
    test eax, eax
    jnz .Lfail_user
    mov rdi, [rip + url + U_host]
    mov esi, [rip + url + U_host_len]
    lea rdx, [rip + .c_hez]
    call str_eq_cstr
    test eax, eax
    jz .Lfail_user
    mov rdi, [rip + url + U_path]
    mov esi, [rip + url + U_path_len]
    lea rdx, [rip + .c_z]
    call str_eq_cstr
    test eax, eax
    jz .Lfail_user
    lea rdi, [rip + .m_url_user_ok]
    call print
    jmp .Lnext_user
.Lfail_user:
    mov r13d, 1
    lea rdi, [rip + .m_url_user_fail]
    call print
.Lnext_user:

    # ============================== url invalid
    lea rdi, [rip + url_bad]
    lea rsi, [rip + url]
    call url_parse
    cmp eax, -EINVAL
    jne .Lfail_invalid
    # port > 65535
    lea rdi, [rip + url_bigport]
    lea rsi, [rip + url]
    call url_parse
    cmp eax, -EINVAL
    jne .Lfail_invalid
    # non-digit port
    lea rdi, [rip + url_badport]
    lea rsi, [rip + url]
    call url_parse
    cmp eax, -EINVAL
    jne .Lfail_invalid
    # empty host
    lea rdi, [rip + url_nohost]
    lea rsi, [rip + url]
    call url_parse
    cmp eax, -EINVAL
    jne .Lfail_invalid
    # fragment dropped from path, query untouched
    lea rdi, [rip + url_frag]
    lea rsi, [rip + url]
    call url_parse
    test eax, eax
    jnz .Lfail_invalid
    mov rdi, [rip + url + U_path]
    mov esi, [rip + url + U_path_len]
    lea rdx, [rip + .c_p]
    call str_eq_cstr
    test eax, eax
    jz .Lfail_invalid
    cmp qword ptr [rip + url + U_query], 0
    jne .Lfail_invalid
    lea rdi, [rip + url_upper]
    lea rsi, [rip + url]
    call url_parse
    test eax, eax
    jnz .Lfail_invalid
    mov rdi, [rip + url + U_host]
    mov esi, [rip + url + U_host_len]
    lea rdx, [rip + .c_upper]
    call str_eq_cstr
    test eax, eax
    jz .Lfail_invalid
    lea rdi, [rip + .m_url_invalid_ok]
    call print
    jmp .Lnext_invalid
.Lfail_invalid:
    mov r13d, 1
    lea rdi, [rip + .m_url_invalid_fail]
    call print
.Lnext_invalid:

    # ============================== http simple
    call init_parser
    lea rdi, [rip + resp]
    lea rsi, [rip + resp_simple]
    mov edx, SIMPLE_TOTAL
    call http_resp_feed
    cmp rax, SIMPLE_LEN
    jne .Lfail_simple
    lea rdi, [rip + resp]
    call http_resp_status
    cmp eax, 200
    jne .Lfail_simple
    lea rdi, [rip + resp]
    call http_resp_done
    cmp eax, 1
    jne .Lfail_simple
    lea rdi, [rip + resp]
    call http_resp_error
    test rax, rax
    jnz .Lfail_simple
    cmp qword ptr [rip + bodyst], 5
    jne .Lfail_simple
    lea rdi, [rip + bodyst + 8]
    mov esi, 5
    lea rdx, [rip + .c_hello]
    call str_eq_cstr
    test eax, eax
    jz .Lfail_simple
    lea rdi, [rip + resp]
    call http_resp_header_count
    cmp eax, 2
    jne .Lfail_simple
    lea rdi, [rip + resp]
    xor esi, esi
    call http_resp_header_at
    mov r12, rcx
    mov r15d, r8d
    mov rdi, rax
    mov esi, edx
    lea rdx, [rip + .c_cl]
    call str_eq_cstr
    test eax, eax
    jz .Lfail_simple
    mov rdi, r12
    mov esi, r15d
    lea rdx, [rip + .c_five]
    call str_eq_cstr
    test eax, eax
    jz .Lfail_simple
    # case-insensitive lookup
    lea rdi, [rip + resp]
    lea rsi, [rip + .c_cl_lc]
    call http_resp_header
    cmp rdx, 1
    jne .Lfail_simple
    cmp byte ptr [rax], '5'
    jne .Lfail_simple
    lea rdi, [rip + resp]
    lea rsi, [rip + .c_xfoo]
    call http_resp_header
    cmp rdx, 3
    jne .Lfail_simple
    cmp byte ptr [rax], 'B'
    jne .Lfail_simple
    lea rdi, [rip + .m_http_simple_ok]
    call print
    jmp .Lnext_simple
.Lfail_simple:
    mov r13d, 1
    lea rdi, [rip + .m_http_simple_fail]
    call print
.Lnext_simple:

    # ============================== http chunked
    call init_parser
    lea rdi, [rip + resp]
    lea rsi, [rip + resp_chunked]
    mov edx, CHUNKED_TOTAL
    call http_resp_feed
    cmp rax, CHUNKED_LEN
    jne .Lfail_chunked
    lea rdi, [rip + resp]
    call http_resp_status
    cmp eax, 200
    jne .Lfail_chunked
    lea rdi, [rip + resp]
    call http_resp_done
    cmp eax, 1
    jne .Lfail_chunked
    lea rdi, [rip + resp]
    call http_resp_chunked
    cmp eax, 1
    jne .Lfail_chunked
    cmp qword ptr [rip + bodyst], 5
    jne .Lfail_chunked
    lea rdi, [rip + bodyst + 8]
    mov esi, 5
    lea rdx, [rip + .c_abcde]
    call str_eq_cstr
    test eax, eax
    jz .Lfail_chunked
    # chunked, replayed one byte per feed
    call init_parser
    xor r12d, r12d
.Lcsplit_loop:
    cmp r12, CHUNKED_LEN
    jae .Lcsplit_done
    lea rdi, [rip + resp]
    lea rsi, [rip + resp_chunked]
    add rsi, r12
    mov edx, 1
    call http_resp_feed
    cmp rax, 1
    jne .Lfail_chunked
    inc r12
    jmp .Lcsplit_loop
.Lcsplit_done:
    lea rdi, [rip + resp]
    call http_resp_status
    cmp eax, 200
    jne .Lfail_chunked
    lea rdi, [rip + resp]
    call http_resp_done
    cmp eax, 1
    jne .Lfail_chunked
    lea rdi, [rip + resp]
    call http_resp_chunked
    cmp eax, 1
    jne .Lfail_chunked
    cmp qword ptr [rip + bodyst], 5
    jne .Lfail_chunked
    lea rdi, [rip + bodyst + 8]
    mov esi, 5
    lea rdx, [rip + .c_abcde]
    call str_eq_cstr
    test eax, eax
    jz .Lfail_chunked
    lea rdi, [rip + .m_http_chunked_ok]
    call print
    jmp .Lnext_chunked
.Lfail_chunked:
    mov r13d, 1
    lea rdi, [rip + .m_http_chunked_fail]
    call print
.Lnext_chunked:

    # ============================== http split (one byte per feed)
    call init_parser
    xor r12d, r12d
.Lsplit_loop:
    cmp r12, SIMPLE_LEN
    jae .Lsplit_done
    lea rdi, [rip + resp]
    lea rsi, [rip + resp_simple]
    add rsi, r12
    mov edx, 1
    call http_resp_feed
    cmp rax, 1
    jne .Lfail_split
    inc r12
    jmp .Lsplit_loop
.Lsplit_done:
    lea rdi, [rip + resp]
    call http_resp_status
    cmp eax, 200
    jne .Lfail_split
    lea rdi, [rip + resp]
    call http_resp_done
    cmp eax, 1
    jne .Lfail_split
    cmp qword ptr [rip + bodyst], 5
    jne .Lfail_split
    lea rdi, [rip + bodyst + 8]
    mov esi, 5
    lea rdx, [rip + .c_hello]
    call str_eq_cstr
    test eax, eax
    jz .Lfail_split
    lea rdi, [rip + .m_http_split_ok]
    call print
    jmp .Lnext_split
.Lfail_split:
    mov r13d, 1
    lea rdi, [rip + .m_http_split_fail]
    call print
.Lnext_split:

    # ============================== http close (HTTP/1.0)
    call init_parser
    lea rdi, [rip + resp]
    lea rsi, [rip + resp_close]
    mov edx, CLOSE_LEN
    call http_resp_feed
    cmp rax, CLOSE_LEN
    jne .Lfail_close
    lea rdi, [rip + resp]
    call http_resp_status
    cmp eax, 200
    jne .Lfail_close
    lea rdi, [rip + resp]
    call http_resp_close
    cmp eax, 1
    jne .Lfail_close
    lea rdi, [rip + resp]
    call http_resp_done
    cmp eax, 1
    jne .Lfail_close
    lea rdi, [rip + .m_http_close_ok]
    call print
    jmp .Lnext_close
.Lfail_close:
    mov r13d, 1
    lea rdi, [rip + .m_http_close_fail]
    call print
.Lnext_close:

    # ============================== http 204 + no_body
    call init_parser
    lea rdi, [rip + resp]
    call http_resp_no_body
    lea rdi, [rip + resp]
    lea rsi, [rip + resp_204]
    mov edx, R204_LEN
    call http_resp_feed
    cmp rax, R204_LEN
    jne .Lfail_204
    lea rdi, [rip + resp]
    call http_resp_status
    cmp eax, 204
    jne .Lfail_204
    lea rdi, [rip + resp]
    call http_resp_done
    cmp eax, 1
    jne .Lfail_204
    lea rdi, [rip + resp]
    call http_resp_error
    test rax, rax
    jnz .Lfail_204
    lea rdi, [rip + .m_http_204_ok]
    call print
    jmp .Lnext_204
.Lfail_204:
    mov r13d, 1
    lea rdi, [rip + .m_http_204_fail]
    call print
.Lnext_204:

    # ============================== http bad chunk size
    call init_parser
    lea rdi, [rip + resp]
    lea rsi, [rip + resp_badchunk]
    mov edx, BADCHUNK_LEN
    call http_resp_feed
    lea rdi, [rip + resp]
    call http_resp_error
    test rax, rax
    jz .Lfail_badchunk
    lea rdi, [rip + .m_http_badchunk_ok]
    call print
    jmp .Lnext_badchunk
.Lfail_badchunk:
    mov r13d, 1
    lea rdi, [rip + .m_http_badchunk_fail]
    call print
.Lnext_badchunk:

    # ============================== http line too long
    call init_parser
    lea rdi, [rip + resp]
    lea rsi, [rip + resp_toolong]
    mov edx, TOOLONG_LEN
    call http_resp_feed
    lea rdi, [rip + resp]
    call http_resp_error
    test rax, rax
    jz .Lfail_toolong
    lea rdi, [rip + .m_http_toolong_ok]
    call print
    jmp .Lnext_toolong
.Lfail_toolong:
    mov r13d, 1
    lea rdi, [rip + .m_http_toolong_fail]
    call print
.Lnext_toolong:

    # ============================== http duplicate Content-Length
    call init_parser
    lea rdi, [rip + resp]
    lea rsi, [rip + resp_dupcl]
    mov edx, DUPCL_LEN
    call http_resp_feed
    lea rdi, [rip + resp]
    call http_resp_error
    test rax, rax
    jz .Lfail_dupcl
    lea rdi, [rip + .m_http_dupcl_ok]
    call print
    jmp .Lnext_dupcl
.Lfail_dupcl:
    mov r13d, 1
    lea rdi, [rip + .m_http_dupcl_fail]
    call print
.Lnext_dupcl:

    # ============================== http TE: xchunked is not chunked
    call init_parser
    lea rdi, [rip + resp]
    lea rsi, [rip + resp_xchunked]
    mov edx, XCHUNKED_LEN
    call http_resp_feed
    lea rdi, [rip + resp]
    call http_resp_error
    test rax, rax
    jnz .Lfail_xchunk
    lea rdi, [rip + resp]
    call http_resp_chunked
    cmp eax, 0
    jne .Lfail_xchunk
    # no Content-Length and not chunked: the body runs until EOF, so close is set
    lea rdi, [rip + resp]
    call http_resp_close
    cmp eax, 1
    jne .Lfail_xchunk
    lea rdi, [rip + .m_http_xchunk_ok]
    call print
    jmp .Lnext_xchunk
.Lfail_xchunk:
    mov r13d, 1
    lea rdi, [rip + .m_http_xchunk_fail]
    call print
.Lnext_xchunk:

    # ============================== request builder (silent)
    lea rdi, [rip + reqsb]
    lea rsi, [rip + .s_post]
    lea rdx, [rip + .c_api]
    mov ecx, 15
    lea r8, [rip + .s_v1x]
    mov r9d, 5
    call http_req_begin
    lea rdi, [rip + reqsb]
    lea rsi, [rip + .s_xtest]
    lea rdx, [rip + .s_yes]
    call http_req_header_cstr
    lea rdi, [rip + reqsb]
    lea rsi, [rip + .c_hello]
    mov edx, 5
    call http_req_body
    mov rax, [rip + reqsb + SB_len]
    cmp rax, req_expected_end - req_expected
    jne .Lfail_request
    mov rdi, [rip + reqsb + SB_ptr]
    lea rsi, [rip + req_expected]
    mov rdx, req_expected_end - req_expected
    call memeq
    cmp eax, 1
    jne .Lfail_request
    # GET with http_req_end
    lea rdi, [rip + req2sb]
    lea rsi, [rip + .s_get]
    lea rdx, [rip + .c_api]
    mov ecx, 15
    lea r8, [rip + .s_slash]
    mov r9d, 1
    call http_req_begin
    lea rdi, [rip + req2sb]
    lea rsi, [rip + .s_accept]
    lea rdx, [rip + .s_star]
    call http_req_header_cstr
    lea rdi, [rip + req2sb]
    call http_req_end
    mov rax, [rip + req2sb + SB_len]
    cmp rax, req2_expected_end - req2_expected
    jne .Lfail_request
    mov rdi, [rip + req2sb + SB_ptr]
    lea rsi, [rip + req2_expected]
    mov rdx, req2_expected_end - req2_expected
    call memeq
    cmp eax, 1
    jne .Lfail_request
    jmp .Lnext_request
.Lfail_request:
    mov r13d, 1
    lea rdi, [rip + .m_http_request_fail]
    call print
.Lnext_request:

    lea rdi, [rip + .m_wire_done]
    call print
    mov eax, r13d
    EPILOGUE
