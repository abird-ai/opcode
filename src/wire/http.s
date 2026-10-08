.include "opcode.inc"
# opcode wire: HTTP/1.1 request builder and incremental response parser.
# See src/wire/API.md for the frozen API.
#
# Request builder: append-only, never resets the SB.
#   http_req_begin  -> "METHOD path HTTP/1.1\r\nHost: host\r\n"
#   http_req_header -> "Name: value\r\n"
#   http_req_body   -> "Content-Length: N\r\n\r\n" + body
#   http_req_end    -> "\r\n"
#
# Response parser: `r` must point to writable memory of at least
# HTTP_RESP_SIZE bytes; the size is exported as the data symbol
# `http_resp_size`. http_resp_init initializes every field, so zeroing the
# buffer before init is not required.
#
# Limits: 8192-byte status/header/chunk/trailer lines, 64 headers.
# Header pointers returned by http_resp_header* are offsets into an internal
# growable buffer and remain valid while the same parser instance is in use.
# Body bytes are passed straight through as (ptr,len) views into the feed
# buffer; excess bytes after the body are never consumed.

.equ S_HEADERS,    0
.equ S_BODY_CL,    1
.equ S_CHUNK_SIZE, 2
.equ S_CHUNK_DATA, 3
.equ S_CHUNK_CR,   4
.equ S_CHUNK_LF,   5
.equ S_CHUNK_EXT,  6
.equ S_TRAILERS,   7
.equ S_DONE,       8
.equ S_CHUNK_SIZE_LF, 9
.equ S_BODY_EOF,    10

.equ RF_NO_BODY,   1
.equ RF_CHUNKED,   2
.equ RF_DONE,      4
.equ RF_CLOSE,     8
.equ RF_KEEPALIVE, 16
.equ RF_HTTP10,    32
.equ RF_HAS_CL,    64
.equ RF_ERROR,     128

STRUCT
F R_on_body, 8
F R_ctx, 8
F R_sb_ptr, 8
F R_sb_len, 8
F R_sb_cap, 8
F R_line_start, 8
F R_state, 8
F R_cl_left, 8
F R_chunk_left, 8
F R_chunk_acc, 8
F R_errmsg, 8
F R_hdr_n, 4
F R_status, 4
F R_flags, 4
F R_ver_minor, 4
F R_hex_digits, 4
F R_trailer_len, 4
F R_hdrs, 1024
ENDSTRUCT R_SIZE

.section .rodata
.globl http_resp_size
http_resp_size:
    .quad R_SIZE
.Lcrlf:          .ascii "\r\n"
.Lcolon_sp:      .ascii ": "
.Lreq_ver:       .ascii " HTTP/1.1\r\nHost: "
.Lcl_prefix:     .ascii "Content-Length: "
.Lcrlfcrlf:      .ascii "\r\n\r\n"
.Lte_name:       .asciz "Transfer-Encoding"
.Lcl_name:       .asciz "Content-Length"
.Lconn_name:     .asciz "Connection"
.Lchunked_tok:   .asciz "chunked"
.Lclose_tok:     .asciz "close"
.Lkeepalive_tok: .asciz "keep-alive"
.Lerr_bad_status: .asciz "bad status line"
.Lerr_line_long:  .asciz "line too long"
.Lerr_too_many:   .asciz "too many headers"
.Lerr_bad_chunk:  .asciz "bad chunk size"
.Lerr_bad_header: .asciz "bad header"
.Lerr_too_large:  .asciz "response too large"
.Lerr_truncated:  .asciz "truncated response"
.text

# ------------------------------------------------------------ request builder
# http_req_begin(sb, method cstr, host ptr, host_len, path ptr, path_len) -> 0
FN http_req_begin
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov r15, r8
    mov [rsp], r9
    mov rdi, rbx
    mov rsi, r12
    call sb_push_cstr
    mov rdi, rbx
    mov esi, ' '
    call sb_push_byte
    mov rdi, rbx
    mov rsi, r15
    mov rdx, [rsp]
    call sb_push
    mov rdi, rbx
    lea rsi, [rip + .Lreq_ver]
    mov edx, 17
    call sb_push
    mov rdi, rbx
    mov rsi, r13
    mov rdx, r14
    call sb_push
    mov rdi, rbx
    lea rsi, [rip + .Lcrlf]
    mov edx, 2
    call sb_push
    xor eax, eax
    EPILOGUE

# http_req_header(sb, name cstr, value ptr, value_len) -> 0 | -EINVAL
# The value is rejected (nothing is appended) if it contains CR or LF: either
# would terminate the line and have the remainder parsed as a new header.
FN http_req_header
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    xor eax, eax
.Lrh_scan:
    cmp rax, r14
    jae .Lrh_push
    movzx ecx, byte ptr [r13 + rax]
    cmp ecx, 13
    je .Lrh_bad
    cmp ecx, 10
    je .Lrh_bad
    inc rax
    jmp .Lrh_scan
.Lrh_push:
    mov rdi, rbx
    mov rsi, r12
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Lcolon_sp]
    mov edx, 2
    call sb_push
    mov rdi, rbx
    mov rsi, r13
    mov rdx, r14
    call sb_push
    mov rdi, rbx
    lea rsi, [rip + .Lcrlf]
    mov edx, 2
    call sb_push
    xor eax, eax
    EPILOGUE
.Lrh_bad:
    mov rax, -EINVAL
    EPILOGUE

# http_req_header_cstr(sb, name cstr, value cstr) -> 0 | -EINVAL
FN http_req_header_cstr
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, r13
    call strlen
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    mov rcx, rax
    call http_req_header
    EPILOGUE

# http_req_end(sb) -> 0
FN http_req_end
    PROLOGUE 0
    lea rsi, [rip + .Lcrlf]
    mov edx, 2
    call sb_push
    xor eax, eax
    EPILOGUE

# http_req_body(sb, ptr, len) -> 0
FN http_req_body
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, rbx
    lea rsi, [rip + .Lcl_prefix]
    mov edx, 16
    call sb_push
    mov rdi, rbx
    mov rsi, r13
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Lcrlfcrlf]
    mov edx, 4
    call sb_push
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call sb_push
    xor eax, eax
    EPILOGUE

# ------------------------------------------------------------- response parser
# http_resp_init(r, on_body, ctx)
FN http_resp_init
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, rbx
    xor esi, esi
    mov edx, R_SIZE
    call memset
    mov [rbx + R_on_body], r12
    mov [rbx + R_ctx], r13
    EPILOGUE

# http_resp_free(r): release the parser's growable line buffer (init keeps no
# heap on its own). Safe on a zeroed/exhausted parser.
FN http_resp_free
    PROLOGUE 0
    test rdi, rdi
    jz 1f
    mov rbx, rdi
    lea rdi, [rbx + R_sb_ptr]
    call sb_free
1:  EPILOGUE

# http_resp_feed(r, ptr, len) -> consumed bytes
FN http_resp_feed
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    xor r14d, r14d
    cmp qword ptr [rbx + R_errmsg], 0
    jne .Lfeed_ret
.Lfeed_loop:
    mov rax, [rbx + R_state]
    cmp rax, S_HEADERS
    je .Lfeed_headers
    cmp rax, S_BODY_CL
    je .Lfeed_cl
    cmp rax, S_CHUNK_SIZE
    je .Lfeed_chunk_size
    cmp rax, S_CHUNK_DATA
    je .Lfeed_chunk_data
    cmp rax, S_CHUNK_EXT
    je .Lfeed_chunk_ext
    cmp rax, S_CHUNK_CR
    je .Lfeed_chunk_cr
    cmp rax, S_CHUNK_LF
    je .Lfeed_chunk_lf
    cmp rax, S_CHUNK_SIZE_LF
    je .Lfeed_chunk_size_lf
    cmp rax, S_TRAILERS
    je .Lfeed_trailers
    cmp rax, S_BODY_EOF
    je .Lfeed_body_eof
    jmp .Lfeed_ret

# --- header block collection (status line + headers, up to the blank line)
.Lfeed_headers:
    test r13, r13
    jz .Lfeed_ret
    mov r8, r12
    mov rcx, r13
1:  test rcx, rcx
    jz .Lfh_none
    cmp byte ptr [r8], 10
    je .Lfh_found
    inc r8
    dec rcx
    jmp 1b
.Lfh_none:
    lea rdi, [rbx + R_sb_ptr]
    mov rsi, r12
    mov rdx, r13
    call sb_push
    add r12, r13
    add r14, r13
    xor r13d, r13d
    mov rax, [rbx + R_sb_len]
    sub rax, [rbx + R_line_start]
    cmp rax, 8194
    ja .Lfeed_err_long
    jmp .Lfeed_ret
.Lfh_found:
    mov r15, r8
    sub r15, r12
    inc r15
    lea rdi, [rbx + R_sb_ptr]
    mov rsi, r12
    mov rdx, r15
    call sb_push
    add r12, r15
    sub r13, r15
    add r14, r15
    # line content length excluding LF, then strip an optional CR
    mov rax, [rbx + R_sb_len]
    sub rax, [rbx + R_line_start]
    dec rax
    mov rcx, [rbx + R_sb_ptr]
    mov rdx, [rbx + R_line_start]
    test rax, rax
    jz 2f
    add rcx, rdx
    cmp byte ptr [rcx + rax - 1], 13
    jne 2f
    dec rax
2:  cmp rax, 8192
    ja .Lfeed_err_long
    test rax, rax
    jz .Lfh_done
    mov rax, [rbx + R_sb_len]
    mov [rbx + R_line_start], rax
    jmp .Lfeed_headers
.Lfh_done:
    mov rdi, rbx
    call .Lparse_headers
    test eax, eax
    jnz .Lfeed_ret
    jmp .Lfeed_loop

# --- close-delimited body: deliver everything, completion comes from http_resp_eof
.Lfeed_body_eof:
    test r13, r13
    jz .Lfeed_ret
    mov r15, r13
    mov rdi, [rbx + R_ctx]
    mov rsi, r12
    mov rdx, r15
    mov rax, [rbx + R_on_body]
    call rax
    add r12, r15
    add r14, r15
    xor r13d, r13d
    jmp .Lfeed_ret

# --- Content-Length body
.Lfeed_cl:
    mov rax, [rbx + R_cl_left]
    test rax, rax
    jz .Lfeed_set_done
    test r13, r13
    jz .Lfeed_ret
    cmp r13, rax
    cmovb rax, r13
    mov r15, rax
    mov rdi, [rbx + R_ctx]
    mov rsi, r12
    mov rdx, r15
    mov rax, [rbx + R_on_body]
    call rax
    add r12, r15
    sub r13, r15
    add r14, r15
    sub qword ptr [rbx + R_cl_left], r15
    jne .Lfeed_ret
    jmp .Lfeed_set_done

# --- chunked: size line (hex, optional ;ext) --------------------------------
.Lfeed_chunk_size:
    test r13, r13
    jz .Lfeed_ret
    movzx eax, byte ptr [r12]
    mov ecx, eax
    sub ecx, '0'
    cmp ecx, 9
    jbe .Lcs_hex
    mov ecx, eax
    or ecx, 0x20
    sub ecx, 'a'
    cmp ecx, 5
    ja .Lcs_oth
    add ecx, 10
.Lcs_hex:
    cmp dword ptr [rbx + R_hex_digits], 16
    jae .Lfeed_err_chunk
    mov rdx, [rbx + R_chunk_acc]
    shl rdx, 4
    movzx ecx, cl
    add rdx, rcx
    test rdx, rdx                # reject sizes above 2^63-1 (SF = bit 63)
    js .Lfeed_err_chunk
    mov [rbx + R_chunk_acc], rdx
    inc dword ptr [rbx + R_hex_digits]
    inc r12
    dec r13
    inc r14
    jmp .Lfeed_chunk_size
.Lcs_oth:
    cmp al, ';'
    je .Lcs_semi
    cmp al, 13
    je .Lcs_cr
    cmp al, 10
    je .Lcs_lf
    jmp .Lfeed_err_chunk
.Lcs_semi:
    cmp dword ptr [rbx + R_hex_digits], 0
    je .Lfeed_err_chunk
    mov qword ptr [rbx + R_state], S_CHUNK_EXT
    inc r12
    dec r13
    inc r14
    jmp .Lfeed_loop
.Lcs_cr:
    cmp dword ptr [rbx + R_hex_digits], 0
    je .Lfeed_err_chunk
    mov qword ptr [rbx + R_state], S_CHUNK_SIZE_LF
    inc r12
    dec r13
    inc r14
    jmp .Lfeed_loop
.Lcs_lf:
    cmp dword ptr [rbx + R_hex_digits], 0
    je .Lfeed_err_chunk
    inc r12
    dec r13
    inc r14
    jmp .Lfinish_chunk

.Lfeed_chunk_ext:
    test r13, r13
    jz .Lfeed_ret
    cmp byte ptr [r12], 10
    je .Lce_lf
    inc r12
    dec r13
    inc r14
    jmp .Lfeed_chunk_ext
.Lce_lf:
    inc r12
    dec r13
    inc r14
.Lfinish_chunk:
    mov rax, [rbx + R_chunk_acc]
    mov qword ptr [rbx + R_chunk_acc], 0
    mov dword ptr [rbx + R_hex_digits], 0
    test rax, rax
    jz .Lchunk_last
    mov [rbx + R_chunk_left], rax
    mov qword ptr [rbx + R_state], S_CHUNK_DATA
    jmp .Lfeed_loop
.Lchunk_last:
    mov qword ptr [rbx + R_state], S_TRAILERS
    mov dword ptr [rbx + R_trailer_len], 0
    jmp .Lfeed_loop

# --- chunked: chunk data and its CRLF ---------------------------------------
.Lfeed_chunk_data:
    test r13, r13
    jz .Lfeed_ret
    mov rax, [rbx + R_chunk_left]
    test rax, rax
    jz .Lcd_next
    cmp r13, rax
    cmovb rax, r13
    mov r15, rax
    mov rdi, [rbx + R_ctx]
    mov rsi, r12
    mov rdx, r15
    mov rax, [rbx + R_on_body]
    call rax
    add r12, r15
    sub r13, r15
    add r14, r15
    sub qword ptr [rbx + R_chunk_left], r15
    jne .Lfeed_ret
.Lcd_next:
    mov qword ptr [rbx + R_state], S_CHUNK_CR
    jmp .Lfeed_loop

.Lfeed_chunk_cr:
    test r13, r13
    jz .Lfeed_ret
    mov al, [r12]
    cmp al, 13
    je .Lcc_cr
    cmp al, 10
    je .Lcc_lf
    jmp .Lfeed_err_chunk
.Lcc_cr:
    mov qword ptr [rbx + R_state], S_CHUNK_LF
    inc r12
    dec r13
    inc r14
    jmp .Lfeed_loop
.Lcc_lf:
    mov qword ptr [rbx + R_state], S_CHUNK_SIZE
    inc r12
    dec r13
    inc r14
    jmp .Lfeed_loop

.Lfeed_chunk_lf:
    test r13, r13
    jz .Lfeed_ret
    cmp byte ptr [r12], 10
    jne .Lfeed_err_chunk
    mov qword ptr [rbx + R_state], S_CHUNK_SIZE
    inc r12
    dec r13
    inc r14
    jmp .Lfeed_loop

# CRLF after the chunk-size line: the size is already in R_chunk_acc
.Lfeed_chunk_size_lf:
    test r13, r13
    jz .Lfeed_ret
    cmp byte ptr [r12], 10
    jne .Lfeed_err_chunk
    inc r12
    dec r13
    inc r14
    jmp .Lfinish_chunk

# --- chunked: trailer lines until the blank line ----------------------------
.Lfeed_trailers:
    test r13, r13
    jz .Lfeed_ret
    movzx eax, byte ptr [r12]
    inc r12
    dec r13
    inc r14
    cmp al, 13
    je .Lfeed_trailers
    cmp al, 10
    je .Ltr_lf
    inc dword ptr [rbx + R_trailer_len]
    cmp dword ptr [rbx + R_trailer_len], 8192
    ja .Lfeed_err_long
    jmp .Lfeed_trailers
.Ltr_lf:
    cmp dword ptr [rbx + R_trailer_len], 0
    je .Lfeed_set_done
    mov dword ptr [rbx + R_trailer_len], 0
    jmp .Lfeed_trailers

.Lfeed_set_done:
    mov qword ptr [rbx + R_state], S_DONE
    or dword ptr [rbx + R_flags], RF_DONE

.Lfeed_ret:
    mov rax, r14
    EPILOGUE

# --- errors -----------------------------------------------------------------
.Lfeed_err_long:
    mov rdi, rbx
    lea rsi, [rip + .Lerr_line_long]
    call .Lseterr
    jmp .Lfeed_ret
.Lfeed_err_chunk:
    mov rdi, rbx
    lea rsi, [rip + .Lerr_bad_chunk]
    call .Lseterr
    jmp .Lfeed_ret

# .Lseterr(r, msg): first error wins
.Lseterr:
    cmp qword ptr [rdi + R_errmsg], 0
    jne 1f
    mov [rdi + R_errmsg], rsi
    or dword ptr [rdi + R_flags], RF_ERROR
1:  ret

# .Lparse_headers(r) -> 0 ok | 1 error
# Parses the complete status line + header block already in r's SB.
.Lparse_headers:
    PROLOGUE 0
    mov rbx, rdi
    mov r12, [rbx + R_sb_ptr]
    mov r13, [rbx + R_sb_len]
    # status line: find LF
    xor ecx, ecx
.Lph0:
    cmp rcx, r13
    jae .Lph_bad_status
    cmp byte ptr [r12 + rcx], 10
    je .Lph1
    inc rcx
    jmp .Lph0
.Lph1:
    mov rdx, rcx
    test rdx, rdx
    jz .Lph_bad_status
    cmp byte ptr [r12 + rdx - 1], 13
    jne 1f
    dec rdx
1:  cmp rdx, 12
    jb .Lph_bad_status
    mov eax, [r12]
    cmp eax, 0x50545448              # "HTTP"
    jne .Lph_bad_status
    mov eax, [r12 + 4]
    and eax, 0x00ffffff
    cmp eax, 0x002e312f              # "/1."
    jne .Lph_bad_status
    movzx eax, byte ptr [r12 + 7]
    sub eax, '0'
    cmp eax, 9
    ja .Lph_bad_status
    mov [rbx + R_ver_minor], eax
    cmp eax, 0
    jne 2f
    or dword ptr [rbx + R_flags], RF_HTTP10
2:  cmp byte ptr [r12 + 8], ' '
    jne .Lph_bad_status
    movzx eax, byte ptr [r12 + 9]
    sub eax, '0'
    cmp eax, 9
    ja .Lph_bad_status
    imul eax, eax, 100
    movzx esi, byte ptr [r12 + 10]
    sub esi, '0'
    cmp esi, 9
    ja .Lph_bad_status
    imul esi, esi, 10
    add eax, esi
    movzx esi, byte ptr [r12 + 11]
    sub esi, '0'
    cmp esi, 9
    ja .Lph_bad_status
    add eax, esi
    cmp rdx, 12
    jbe 3f
    cmp byte ptr [r12 + 12], ' '
    jne .Lph_bad_status
3:  mov [rbx + R_status], eax
    # headers
    lea rsi, [rcx + 1]
    xor r15d, r15d
.Lph_hdr_loop:
    cmp rsi, r13
    jae .Lph_hdr_done
    mov rcx, rsi
4:  cmp rcx, r13
    jae .Lph_bad_header
    cmp byte ptr [r12 + rcx], 10
    je 5f
    inc rcx
    jmp 4b
5:  mov rdx, rcx
    cmp rdx, rsi
    jbe 6f
    cmp byte ptr [r12 + rdx - 1], 13
    jne 6f
    dec rdx
6:  cmp rdx, rsi
    je .Lph_hdr_done
    mov rdi, rsi
7:  cmp rdi, rdx
    jae .Lph_bad_header
    cmp byte ptr [r12 + rdi], ':'
    je 8f
    inc rdi
    jmp 7b
8:  cmp rdi, rsi
    je .Lph_bad_header
    lea r8, [rdi + 1]
9:  cmp r8, rdx
    jae 10f
    movzx eax, byte ptr [r12 + r8]
    cmp eax, ' '
    je 11f
    cmp eax, 9
    jne 10f
11: inc r8
    jmp 9b
10: cmp r15d, 64
    jae .Lph_too_many
    mov rax, r15
    shl rax, 4
    mov r10, rbx
    add r10, R_hdrs
    add r10, rax
    mov eax, esi
    mov [r10], eax
    mov rax, rdi
    sub rax, rsi
    mov [r10 + 4], eax
    mov eax, r8d
    mov [r10 + 8], eax
    mov rax, rdx
    sub rax, r8
    mov [r10 + 12], eax
    inc r15d
    lea rsi, [rcx + 1]
    jmp .Lph_hdr_loop
.Lph_hdr_done:
    mov [rbx + R_hdr_n], r15d
    # interpret the interesting headers
    xor r14d, r14d
.Lph_proc_loop:
    cmp r14d, r15d
    jae .Lph_proc_done
    mov rax, r14
    shl rax, 4
    mov rdi, [rbx + R_sb_ptr]
    mov ecx, [rbx + rax + R_hdrs]
    add rdi, rcx
    mov esi, [rbx + rax + R_hdrs + 4]
    lea rdx, [rip + .Lte_name]
    call .Lci_eq
    test eax, eax
    jnz .Lph_te
    mov rax, r14
    shl rax, 4
    mov rdi, [rbx + R_sb_ptr]
    mov ecx, [rbx + rax + R_hdrs]
    add rdi, rcx
    mov esi, [rbx + rax + R_hdrs + 4]
    lea rdx, [rip + .Lcl_name]
    call .Lci_eq
    test eax, eax
    jnz .Lph_cl
    mov rax, r14
    shl rax, 4
    mov rdi, [rbx + R_sb_ptr]
    mov ecx, [rbx + rax + R_hdrs]
    add rdi, rcx
    mov esi, [rbx + rax + R_hdrs + 4]
    lea rdx, [rip + .Lconn_name]
    call .Lci_eq
    test eax, eax
    jnz .Lph_conn
.Lph_next:
    inc r14d
    jmp .Lph_proc_loop

.Lph_te:
    mov rax, r14
    shl rax, 4
    mov rdi, [rbx + R_sb_ptr]
    mov ecx, [rbx + rax + R_hdrs + 8]
    add rdi, rcx
    mov esi, [rbx + rax + R_hdrs + 12]
    lea rdx, [rip + .Lchunked_tok]
    mov ecx, 7
    call .Lci_has_token
    test eax, eax
    jz .Lph_next
    or dword ptr [rbx + R_flags], RF_CHUNKED
    jmp .Lph_next

.Lph_cl:
    test dword ptr [rbx + R_flags], RF_HAS_CL
    jnz .Lph_bad_header             # duplicate Content-Length: reject, do not last-win
    mov rax, r14
    shl rax, 4
    mov rdi, [rbx + R_sb_ptr]
    mov ecx, [rbx + rax + R_hdrs + 8]
    add rdi, rcx
    mov esi, [rbx + rax + R_hdrs + 12]
    call .Lparse_sz
    test rdx, rdx
    jz .Lph_bad_header
    test r8d, r8d
    jnz .Lph_cl_too_big
    add rdi, rdx
    sub rsi, rdx
12: test rsi, rsi
    jz 14f
    movzx ecx, byte ptr [rdi]
    cmp ecx, ' '
    je 13f
    cmp ecx, 9
    jne .Lph_bad_header
13: inc rdi
    dec rsi
    jmp 12b
14: mov [rbx + R_cl_left], rax
    or dword ptr [rbx + R_flags], RF_HAS_CL
    jmp .Lph_next

.Lph_conn:
    mov rax, r14
    shl rax, 4
    mov rdi, [rbx + R_sb_ptr]
    mov ecx, [rbx + rax + R_hdrs + 8]
    add rdi, rcx
    mov esi, [rbx + rax + R_hdrs + 12]
    lea rdx, [rip + .Lclose_tok]
    mov ecx, 5
    call .Lci_has_token
    test eax, eax
    jnz .Lph_conn_close
    mov rax, r14
    shl rax, 4
    mov rdi, [rbx + R_sb_ptr]
    mov ecx, [rbx + rax + R_hdrs + 8]
    add rdi, rcx
    mov esi, [rbx + rax + R_hdrs + 12]
    lea rdx, [rip + .Lkeepalive_tok]
    mov ecx, 10
    call .Lci_has_token
    test eax, eax
    jz .Lph_next
    or dword ptr [rbx + R_flags], RF_KEEPALIVE
    jmp .Lph_next
.Lph_conn_close:
    or dword ptr [rbx + R_flags], RF_CLOSE
    jmp .Lph_next

.Lph_proc_done:
    test dword ptr [rbx + R_flags], RF_HTTP10
    jz 15f
    test dword ptr [rbx + R_flags], RF_KEEPALIVE
    jnz 15f
    or dword ptr [rbx + R_flags], RF_CLOSE
15: # 1xx/204/304 are defined to carry no body (RFC 9110 6.4.1); auto-complete
    # them before the explicit RF_NO_BODY check so HEAD/204/304 share one path.
    mov eax, [rbx + R_status]
    cmp eax, 100
    jb .Lph_body_check
    cmp eax, 200
    jb .Lph_interim              # 1xx: interim, final response follows
    cmp eax, 204
    je .Lph_no_body
    cmp eax, 304
    je .Lph_no_body
.Lph_body_check:
    test dword ptr [rbx + R_flags], RF_NO_BODY
    jnz .Lph_no_body
    test dword ptr [rbx + R_flags], RF_CHUNKED
    jnz .Lph_chunked
    test dword ptr [rbx + R_flags], RF_HAS_CL
    jnz .Lph_body
    # no Content-Length, no chunked: the body runs until EOF
    mov qword ptr [rbx + R_state], S_BODY_EOF
    or dword ptr [rbx + R_flags], RF_CLOSE
    xor eax, eax
    EPILOGUE
.Lph_chunked:
    mov qword ptr [rbx + R_state], S_CHUNK_SIZE
    mov qword ptr [rbx + R_chunk_acc], 0
    mov dword ptr [rbx + R_hex_digits], 0
    xor eax, eax
    EPILOGUE
.Lph_body:
    mov qword ptr [rbx + R_state], S_BODY_CL
    xor eax, eax
    EPILOGUE
.Lph_no_body:
    mov qword ptr [rbx + R_state], S_DONE
    or dword ptr [rbx + R_flags], RF_DONE
    xor eax, eax
    EPILOGUE
.Lph_interim:
    # 1xx (100 Continue / 103 Early Hints) carries no body but does not end
    # the exchange: discard it and keep parsing the final response on the
    # same connection.
    mov qword ptr [rbx + R_sb_len], 0
    mov qword ptr [rbx + R_line_start], 0
    mov dword ptr [rbx + R_hdr_n], 0
    mov dword ptr [rbx + R_status], 0
    mov qword ptr [rbx + R_cl_left], 0
    mov qword ptr [rbx + R_chunk_acc], 0
    mov dword ptr [rbx + R_hex_digits], 0
    and dword ptr [rbx + R_flags], ~(RF_CHUNKED | RF_HAS_CL | RF_CLOSE | RF_KEEPALIVE | RF_HTTP10)
    mov qword ptr [rbx + R_state], S_HEADERS
    xor eax, eax
    EPILOGUE

.Lph_cl_too_big:
    lea rsi, [rip + .Lerr_too_large]
    jmp .Lph_err
.Lph_bad_status:
    lea rsi, [rip + .Lerr_bad_status]
    jmp .Lph_err
.Lph_bad_header:
    lea rsi, [rip + .Lerr_bad_header]
    jmp .Lph_err
.Lph_too_many:
    lea rsi, [rip + .Lerr_too_many]
.Lph_err:
    mov rdi, rbx
    call .Lseterr
    mov eax, 1
    EPILOGUE

# .Lparse_sz(ptr, len) -> rax value, rdx digits consumed, r8=1 on overflow.
# A bounded decimal parser for Content-Length: parse_u64 silently wraps at
# 2^64, so an absurd length could masquerade as a small one. This refuses any
# value above 2^63-1 while still consuming every digit (so the trailing-space
# check in .Lph_cl stays correct).
.Lparse_sz:
    xor eax, eax
    xor edx, edx
    xor r8d, r8d
1:  cmp rdx, rsi
    jae 2f
    movzx ecx, byte ptr [rdi + rdx]
    sub ecx, '0'
    cmp ecx, 9
    ja 2f
    test r8d, r8d
    jnz 3f
    movabs r9, 922337203685477580  # (2^63-1)/10
    cmp rax, r9
    ja 4f
    jb 5f
    cmp ecx, 7                     # (2^63-1)%10
    ja 4f
5:  imul rax, rax, 10
    add rax, rcx
    inc rdx
    jmp 1b
3:  inc rdx
    jmp 1b
4:  mov r8d, 1
    inc rdx
    jmp 1b
2:  ret

# .Lci_eq(ptr, len, cstr) -> 1 | 0, ASCII case-insensitive
.Lci_eq:
    xor eax, eax
1:  test rsi, rsi
    jz .Leq_done
    mov cl, [rdx]
    test cl, cl
    jz .Leq_no
    movzx r8d, byte ptr [rdi]
    cmp cl, 'A'
    jb 2f
    cmp cl, 'Z'
    ja 2f
    add cl, 32
2:  cmp r8b, 'A'
    jb 3f
    cmp r8b, 'Z'
    ja 3f
    add r8b, 32
3:  cmp cl, r8b
    jne .Leq_no
    inc rdi
    inc rdx
    dec rsi
    jmp 1b
.Leq_done:
    cmp byte ptr [rdx], 0
    jne .Leq_no
    mov eax, 1
    ret
.Leq_no:
    xor eax, eax
    ret

# .Lci_has_token(hay, hlen, token, tlen) -> 1 | 0, ASCII case-insensitive
# Matches one exact comma-separated list element (after trimming optional SP or
# HTAB). Transfer-Encoding and Connection are #token lists, so a substring match
# would accept "xchunked" or "close-me".
.Lci_has_token:
    test rsi, rsi
    jz .Lht_none
.Lht_outer:
    xor r9d, r9d                     # offset of the next ',' or the end
.Lht_scan:
    cmp r9, rsi
    jae .Lht_elem
    cmp byte ptr [rdi + r9], ','
    je .Lht_elem
    inc r9
    jmp .Lht_scan
.Lht_elem:
    lea r8, [rdi + r9]               # element end (exclusive)
    mov r10, rdi                     # element start
.Lht_ltrim:
    cmp r10, r8
    jae .Lht_advance
    movzx eax, byte ptr [r10]
    cmp eax, ' '
    je .Lht_ltrim_inc
    cmp eax, 9
    jne .Lht_rtrim
.Lht_ltrim_inc:
    inc r10
    jmp .Lht_ltrim
.Lht_rtrim:
    cmp r8, r10
    jbe .Lht_advance
    movzx eax, byte ptr [r8 - 1]
    cmp eax, ' '
    je .Lht_rtrim_dec
    cmp eax, 9
    jne .Lht_cmp
.Lht_rtrim_dec:
    dec r8
    jmp .Lht_rtrim
.Lht_cmp:
    mov rax, r8
    sub rax, r10
    cmp rax, rcx
    jne .Lht_advance
    xor r11d, r11d
.Lht_cmp_loop:
    cmp r11, rcx
    jae .Lht_yes
    movzx eax, byte ptr [r10 + r11]
    movzx r8d, byte ptr [rdx + r11]
    cmp al, 'A'
    jb 1f
    cmp al, 'Z'
    ja 1f
    add al, 32
1:  cmp r8b, 'A'
    jb 2f
    cmp r8b, 'Z'
    ja 2f
    add r8b, 32
2:  cmp al, r8b
    jne .Lht_advance
    inc r11
    jmp .Lht_cmp_loop
.Lht_advance:
    cmp r9, rsi
    jae .Lht_none
    lea rdi, [rdi + r9 + 1]
    sub rsi, r9
    dec rsi
    jmp .Lht_outer
.Lht_yes:
    mov eax, 1
    ret
.Lht_none:
    xor eax, eax
    ret

# ------------------------------------------------------------- accessors
# http_resp_status(r) -> int (0 until parsed)
FN http_resp_status
    mov eax, [rdi + R_status]
    ret

# http_resp_header(r, name cstr) -> rax ptr, rdx len | 0,0
FN http_resp_header
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    xor r13d, r13d
.Lh_loop:
    cmp r13d, [rbx + R_hdr_n]
    jae .Lh_none
    mov rax, r13
    shl rax, 4
    mov rdi, [rbx + R_sb_ptr]
    mov ecx, [rbx + rax + R_hdrs]
    add rdi, rcx
    mov esi, [rbx + rax + R_hdrs + 4]
    mov rdx, r12
    call .Lci_eq
    test eax, eax
    jnz .Lh_found
    inc r13d
    jmp .Lh_loop
.Lh_found:
    mov rax, r13
    shl rax, 4
    mov r10d, [rbx + rax + R_hdrs + 12]  # value len
    mov rcx, [rbx + R_sb_ptr]
    mov eax, [rbx + rax + R_hdrs + 8]    # value offset
    add rcx, rax
    mov rax, rcx
    mov edx, r10d
    EPILOGUE
.Lh_none:
    xor eax, eax
    xor edx, edx
    EPILOGUE

# http_resp_header_count(r) -> n
FN http_resp_header_count
    mov eax, [rdi + R_hdr_n]
    ret

# http_resp_header_at(r, i) -> rax name ptr, rdx name len, rcx value ptr, r8 value len
FN http_resp_header_at
    cmp esi, [rdi + R_hdr_n]
    jae .Lha_none
    mov rax, rsi
    shl rax, 4
    lea r10, [rdi + rax + R_hdrs]
    mov r9, [rdi + R_sb_ptr]
    mov ecx, [r10]
    lea rax, [r9 + rcx]
    mov edx, [r10 + 4]
    mov ecx, [r10 + 8]
    add r9, rcx
    mov rcx, r9
    mov r8d, [r10 + 12]
    ret
.Lha_none:
    xor eax, eax
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    ret

# http_resp_eof(r): tell a close-delimited body that the peer closed. Marks
# S_BODY_EOF done as before; a close that lands inside a length- or
# chunk-framed body or the trailers is a truncation error, not a completion.
FN http_resp_eof
    cmp qword ptr [rdi + R_errmsg], 0
    jne .Leof_ret
    test dword ptr [rdi + R_flags], RF_DONE
    jnz .Leof_ret
    mov rax, [rdi + R_state]
    cmp rax, S_HEADERS
    je .Leof_trunc               # closed before a complete header block
    cmp rax, S_BODY_EOF
    je .Leof_complete
    cmp rax, S_BODY_CL
    je .Leof_trunc
    cmp rax, S_CHUNK_SIZE
    je .Leof_trunc
    cmp rax, S_CHUNK_DATA
    je .Leof_trunc
    cmp rax, S_CHUNK_CR
    je .Leof_trunc
    cmp rax, S_CHUNK_LF
    je .Leof_trunc
    cmp rax, S_CHUNK_EXT
    je .Leof_trunc
    cmp rax, S_CHUNK_SIZE_LF
    je .Leof_trunc
    cmp rax, S_TRAILERS
    je .Leof_trunc
    jmp .Leof_ret
.Leof_complete:
    mov qword ptr [rdi + R_state], S_DONE
    or dword ptr [rdi + R_flags], RF_DONE
    jmp .Leof_ret
.Leof_trunc:
    lea rsi, [rip + .Lerr_truncated]
    call .Lseterr
.Leof_ret:
    xor eax, eax
    ret

# http_resp_done(r) -> 1 | 0
FN http_resp_done
    xor eax, eax
    test dword ptr [rdi + R_flags], RF_DONE
    setnz al
    ret

# http_resp_close(r) -> 1 | 0
FN http_resp_close
    xor eax, eax
    test dword ptr [rdi + R_flags], RF_CLOSE
    setnz al
    ret

# http_resp_chunked(r) -> 1 | 0
FN http_resp_chunked
    xor eax, eax
    test dword ptr [rdi + R_flags], RF_CHUNKED
    setnz al
    ret

# http_resp_error(r) -> 0 | cstr message
FN http_resp_error
    mov rax, [rdi + R_errmsg]
    ret

# http_resp_no_body(r)
FN http_resp_no_body
    or dword ptr [rdi + R_flags], RF_NO_BODY
    mov rax, [rdi + R_state]
    cmp rax, S_HEADERS
    je 1f
    cmp rax, S_DONE
    je 1f
    mov qword ptr [rdi + R_state], S_DONE
    or dword ptr [rdi + R_flags], RF_DONE
1:  ret
