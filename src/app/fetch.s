# fetch: minimal HTTP(S) client CLI - the M1 integration tool.
#   opcode fetch [--insecure] [--dump-wire] [--record FILE] [--replay FILE]
#                [--method M] [--header "Name: Value"] [--data BODY] URL
# Prints the status line, headers and body; SSE responses print one "[event] data" line.
# --replay reads an FWIR1 file (see src/wire/API.md) and performs no network I/O.
.include "opcode.inc"
# net constants (AF_INET, TLS_VERIFY, ...) from the Layer 1 contract
.include "net/net.inc"
# HC transport state and HCR_* error policy flags
.include "wire/http_client.inc"
# Url struct offsets: single-sourced in src/wire/url.inc
.include "wire/url.inc"

.equ FETCH_TIMEOUT_MS, 30000
.equ FETCH_TIMEOUT_NS, 30000000000
.equ CONNECT_TIMEOUT_NS, 3000000000
.equ RECV_BUF, 65536
.equ RESP_SIZE, 2048
.equ HOST_CAP, 512
.equ NAME_CAP, 128

.section .rodata
.Lm_get:        .asciz "GET"
.Lm_post:       .asciz "POST"
.Lm_head:       .asciz "HEAD"
.Lh_user_agent: .asciz "opcode/0.1"
.Lh_accept:     .asciz "*/*"
.Lua_name:      .asciz "user-agent"
.Laccept_name:  .asciz "accept"
.Lct_name:      .asciz "content-type"
.Lctype_json:   .asciz "application/json"
.Lctype_text:   .asciz "text/plain"
.Lsse_type:     .asciz "text/event-stream"
.Lstatus:       .asciz "status "
.Lmagic:        .asciz "FWIR1\n"
.Lsp_name_val:  .asciz ": "
.Lnl:           .asciz "\n"
.Lbr_open:      .asciz "["
.Lbr_close:     .asciz "] "
.Lerr_prefix:   .asciz "opcode: "
.Lerr_url:      .asciz "invalid URL"
.Lerr_net:      .asciz "network error"
.Lerr_tls:      .asciz "TLS error"
.Lerr_parse:    .asciz "malformed response"
.Lerr_replay:   .asciz "bad replay file"
.Lerr_usage:    .asciz "usage: opcode fetch [--insecure] [--dump-wire] [--record FILE] [--replay FILE] [--method M] [--header \"Name: Value\"] [--data BODY] URL"
.Lopt_insecure: .asciz "--insecure"
.Lopt_dump:     .asciz "--dump-wire"
.Lopt_record:   .asciz "--record"
.Lopt_replay:   .asciz "--replay"
.Lopt_method:   .asciz "--method"
.Lopt_header:   .asciz "--header"
.Lopt_data:     .asciz "--data"
.Ldump_in:      .asciz "<<< "
.Ldump_out:     .asciz ">>> "

.bss
.p2align 3
f_hc:           .zero HC_SIZE
f_req:          .zero SB_SIZE
f_file:         .zero SB_SIZE
f_headers:      .zero VEC_SIZE
f_resp:         .zero RESP_SIZE
f_sse:          .zero 1200
f_state:        .zero 32           # [0] mode: 0 undetermined, 1 sse, 2 raw
f_recbuf:       .zero 8
f_flags:        .zero 8            # bit0 insecure, bit1 dump
f_record_path:  .zero 8
f_replay_path:  .zero 8
f_method:       .zero 8
f_data:         .zero 8
f_datalen:      .zero 8
f_printed:      .zero 4
f_method_set:   .zero 4

.text

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

# out_cstr(fd, cstr)
FN f_out_cstr
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rsi
    call strlen
    mov edi, ebx
    mov rsi, r12
    mov rdx, rax
    call write_all
    EPILOGUE

# ferr(cstr): "opcode: <msg>\n" on stderr
ferr:
    PROLOGUE
    mov r12, rdi
    mov edi, 2
    lea rsi, [rip + .Lerr_prefix]
    call f_out_cstr
    mov edi, 2
    mov rsi, r12
    call f_out_cstr
    mov edi, 2
    lea rsi, [rip + .Lnl]
    call f_out_cstr
    EPILOGUE

# read_file(path cstr, sb) -> 0 | -errno
read_file:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov rdi, r12
    mov esi, O_RDONLY
    xor edx, edx
    call os_open
    test rax, rax
    js .Lrf_ret
    mov r12d, eax
    mov edi, RECV_BUF
    call mem_alloc
    mov rbx, rax
1:  mov edi, r12d
    mov rsi, rbx
    mov edx, RECV_BUF
    call os_read
    test rax, rax
    js .Lrf_err
    jz 2f
    mov rdi, r13
    mov rsi, rbx
    mov rdx, rax
    call sb_push
    jmp 1b
2:  mov edi, r12d
    call os_close
    mov rdi, rbx
    call mem_free
    xor eax, eax
    EPILOGUE
.Lrf_err:
    mov r14, rax
    mov edi, r12d
    call os_close
    mov rdi, rbx
    call mem_free
    mov rax, r14
.Lrf_ret:
    EPILOGUE

# record_add2(dir, ptr, len)
record_add2:
    PROLOGUE 16
    cmp qword ptr [rip + f_record_path], 0
    je 1f
    mov r14, rdi
    mov r12, rsi
    mov r13, rdx
    mov dword ptr [rsp], r13d
    lea rdi, [rip + f_file]
    mov esi, r14d
    call sb_push_byte
    lea rdi, [rip + f_file]
    mov rsi, rsp
    mov edx, 4
    call sb_push
    lea rdi, [rip + f_file]
    mov rsi, r12
    mov rdx, r13
    call sb_push
1:  EPILOGUE

# dump_chunk(marker cstr, ptr, len) to stderr when --dump-wire
dump_chunk:
    PROLOGUE
    test dword ptr [rip + f_flags], 2
    jz 1f
    mov rbx, rdi                # marker
    mov r12, rsi
    mov r13, rdx
    mov edi, 2
    mov rsi, rbx
    call f_out_cstr
    mov edi, 2
    mov rsi, r12
    mov rdx, r13
    call write_all
    mov edi, 2
    lea rsi, [rip + .Lnl]
    call f_out_cstr
1:  EPILOGUE

# print status + headers once
fetch_print_headers:
    PROLOGUE 48
    lea rdi, [rip + f_resp]
    call http_resp_status
    mov r12d, eax
    mov edi, 1
    lea rsi, [rip + .Lstatus]
    call f_out_cstr
    lea rdi, [rsp]
    mov esi, r12d
    call fmt_u64
    mov edi, 1
    lea rsi, [rsp]
    mov rdx, rax
    call write_all
    mov edi, 1
    lea rsi, [rip + .Lnl]
    call f_out_cstr
    lea rdi, [rip + f_resp]
    call http_resp_header_count
    mov r12d, eax
    xor r13d, r13d
1:  cmp r13d, r12d
    jae 2f
    lea rdi, [rip + f_resp]
    mov esi, r13d
    call http_resp_header_at
    mov r14, rax                # name
    mov r15, rdx                # name len
    mov rbx, rcx                # value
    mov [rsp + 8], r8           # value len
    mov edi, 1
    mov rsi, r14
    mov rdx, r15
    call write_all
    mov edi, 1
    lea rsi, [rip + .Lsp_name_val]
    mov edx, 2
    call write_all
    mov edi, 1
    mov rsi, rbx
    mov rdx, [rsp + 8]
    call write_all
    mov edi, 1
    lea rsi, [rip + .Lnl]
    call f_out_cstr
    inc r13d
    jmp 1b
2:  mov edi, 1
    lea rsi, [rip + .Lnl]
    call f_out_cstr
    EPILOGUE

# HTTP body callback
fetch_on_body:
    PROLOGUE
    mov r12, rsi
    mov r13, rdx
    cmp dword ptr [rip + f_state], 0
    jne 4f
    lea rdi, [rip + f_resp]
    lea rsi, [rip + .Lct_name]
    call http_resp_header
    test rax, rax
    jz 3f
    mov rdi, rax
    mov rsi, rdx
    lea rdx, [rip + .Lsse_type]
    mov ecx, 17
    call str_find
    test eax, eax
    js 3f
    mov dword ptr [rip + f_state], 1
    jmp 4f
3:  mov dword ptr [rip + f_state], 2
4:  cmp dword ptr [rip + f_printed], 0
    jne 5f
    call fetch_print_headers
    mov dword ptr [rip + f_printed], 1
5:  cmp dword ptr [rip + f_state], 1
    jne 6f
    lea rdi, [rip + f_sse]
    mov rsi, r12
    mov rdx, r13
    call sse_feed
    jmp 7f
6:  mov edi, 1
    mov rsi, r12
    mov rdx, r13
    call write_all
7:  EPILOGUE

# SSE event callback: "[event] data\n"
fetch_on_sse:
    PROLOGUE
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov r15, r8
    mov edi, 1
    lea rsi, [rip + .Lbr_open]
    call f_out_cstr
    mov edi, 1
    mov rsi, r12
    mov rdx, r13
    call write_all
    mov edi, 1
    lea rsi, [rip + .Lbr_close]
    call f_out_cstr
    mov edi, 1
    mov rsi, r14
    mov rdx, r15
    call write_all
    mov edi, 1
    lea rsi, [rip + .Lnl]
    call f_out_cstr
    EPILOGUE

# feed_response(ptr, len) -> 0 | -EINVAL
feed_response:
    PROLOGUE
    lea rdi, [rip + f_resp]
    # rsi/rdx pass through
    call http_resp_feed
    test rax, rax
    jg 1f
    lea rdi, [rip + f_resp]
    call http_resp_done
    test eax, eax
    jnz 1f
    mov rax, -EINVAL
    EPILOGUE
1:  xor eax, eax
    EPILOGUE

# build_request() -> 0 | -errno
build_request:
    PROLOGUE 160
    lea rdi, [rip + f_req]
    call sb_clear
    lea rdi, [rip + f_req]
    mov rsi, [rip + f_method]
    lea rdx, [rip + f_hc + HC_authority]
    mov ecx, [rip + f_hc + HC_authlen]
    mov r8, [rip + f_hc + HC_url + U_path]
    mov r9d, [rip + f_hc + HC_url + U_path_len]
    call http_req_begin
    lea rdi, [rip + f_req]
    lea rsi, [rip + .Lua_name]
    lea rdx, [rip + .Lh_user_agent]
    call http_req_header_cstr
    lea rdi, [rip + f_req]
    lea rsi, [rip + .Laccept_name]
    lea rdx, [rip + .Lh_accept]
    call http_req_header_cstr
    # user headers "Name: Value"
    xor r12d, r12d
1:  cmp r12, [rip + f_headers + VEC_len]
    jae 4f
    mov rax, [rip + f_headers + VEC_ptr]
    mov r13, [rax + r12*8]      # cstr
    mov rdi, r13
    call strlen
    mov r14, rax                # total len
    mov rdi, r13
    mov rsi, r14
    lea rdx, [rip + .Lsp_name_val]
    mov ecx, 2
    call str_find
    test eax, eax
    js 3f
    movsxd r15, eax             # colon index
    # copy name into [rsp, NAME_CAP) with NUL
    xor ecx, ecx
2:  cmp rcx, r15
    jae .Lhdr_name_done
    cmp rcx, NAME_CAP - 1
    jae .Lhdr_name_done
    mov al, [r13 + rcx]
    mov [rsp + rcx], al
    inc rcx
    jmp 2b
.Lhdr_name_done:
    mov byte ptr [rsp + rcx], 0
    # value slice
    lea rbx, [r13 + r15 + 2]
    mov rcx, r14
    sub rcx, r15
    sub rcx, 2
    jle 3f
22: cmp byte ptr [rbx], ' '
    jne 23f
    inc rbx
    dec rcx
    jmp 22b
23: lea rdi, [rip + f_req]
    mov rsi, rsp
    mov rdx, rbx
    call http_req_header
    test rax, rax
    js .Lhdr_bad
3:  inc r12
    jmp 1b
4:  cmp qword ptr [rip + f_data], 0
    je 5f
    lea rdi, [rip + f_req]
    lea rsi, [rip + .Lct_name]
    mov rax, [rip + f_data]
    lea rdx, [rip + .Lctype_text]
    lea rcx, [rip + .Lctype_json]
    cmp byte ptr [rax], '{'
    cmove rdx, rcx
    call http_req_header_cstr
    lea rdi, [rip + f_req]
    mov rsi, [rip + f_data]
    mov rdx, [rip + f_datalen]
    call http_req_body
    jmp 6f
5:  lea rdi, [rip + f_req]
    call http_req_end
6:  xor eax, eax
    EPILOGUE
.Lhdr_bad:
    EPILOGUE

# fetch_on_data(ctx, ptr, len): record + dump every raw chunk before parsing
fetch_on_data:
    PROLOGUE
    mov r12, rsi
    mov r13, rdx
    mov edi, 1
    mov rsi, r12
    mov rdx, r13
    call record_add2
    lea rdi, [rip + .Ldump_in]
    mov rsi, r12
    mov rdx, r13
    call dump_chunk
    EPILOGUE

# fetch_recv_loop() -> 0 | -errno; prints the parser message on -EINVAL
fetch_recv_loop:
    PROLOGUE
    mov edi, CLOCK_MONOTONIC
    call os_now_ns
    mov r9, rax
    mov rax, FETCH_TIMEOUT_NS
    add r9, rax
    lea rdi, [rip + f_hc]
    lea rsi, [rip + f_resp]
    mov edx, HCR_STRICT
    lea rcx, [rip + fetch_on_data]
    xor r8d, r8d
    call hc_recv_loop
    test rax, rax
    js .Lfrl_err
    cmp dword ptr [rip + f_printed], 0
    jne 1f
    call fetch_print_headers
    mov dword ptr [rip + f_printed], 1
1:  xor eax, eax
    EPILOGUE
.Lfrl_err:
    mov r15, rax
    cmp rax, -EINVAL
    jne .Lfrl_ret
    lea rdi, [rip + f_resp]
    call http_resp_error
    test rax, rax
    jz .Lfrl_parse
    mov rdi, rax
    call ferr
    jmp .Lfrl_ret
.Lfrl_parse:
    lea rdi, [rip + .Lerr_parse]
    call ferr
.Lfrl_ret:
    mov rax, r15
    EPILOGUE

# write_record_file() -> 0|-errno
write_record_file:
    PROLOGUE
    mov rdi, [rip + f_record_path]
    mov esi, O_WRONLY | O_CREAT | O_TRUNC
    mov edx, 0644
    call os_open
    test rax, rax
    js 1f
    mov rbx, rax
    mov edi, ebx
    lea rsi, [rip + .Lmagic]
    mov edx, 6
    call write_all
    mov edi, ebx
    mov rsi, [rip + f_file + SB_ptr]
    mov rdx, [rip + f_file + SB_len]
    call write_all
    mov edi, ebx
    call os_close
1:  xor eax, eax
    EPILOGUE

# fetch_live(url cstr) -> exit code
fetch_live:
    PROLOGUE
    mov r12, rdi
    lea rdi, [rip + f_hc]
    mov rsi, r12
    xor edx, edx
    test dword ptr [rip + f_flags], 1
    jz 1f
    mov edx, HC_F_INSECURE
1:  mov ecx, FETCH_TIMEOUT_MS
    mov r8, CONNECT_TIMEOUT_NS
    xor r9d, r9d
    call hc_connect
    test rax, rax
    js .Lfl_connect_err
    call build_request
    test rax, rax
    js .Lfl_parse_err
    xor edi, edi
    mov rsi, [rip + f_req + SB_ptr]
    mov rdx, [rip + f_req + SB_len]
    call record_add2
    lea rdi, [rip + .Ldump_out]
    mov rsi, [rip + f_req + SB_ptr]
    mov rdx, [rip + f_req + SB_len]
    call dump_chunk
    mov edi, CLOCK_MONOTONIC
    call os_now_ns
    mov r8, rax
    mov rax, FETCH_TIMEOUT_NS
    add r8, rax
    mov edi, [rip + f_hc + HC_fd]
    mov rsi, [rip + f_hc + HC_conn]
    mov rdx, [rip + f_req + SB_ptr]
    mov rcx, [rip + f_req + SB_len]
    call hc_send_all
    test rax, rax
    js .Lfl_net_err
    call fetch_recv_loop
    test rax, rax
    js .Lfl_recv_err
    cmp qword ptr [rip + f_record_path], 0
    je 4f
    call write_record_file
4:  xor eax, eax
    EPILOGUE
.Lfl_connect_err:
    # hc_connect leaves the stage: classify URL vs TLS detail vs network the
    # way the old inline connect did.
    mov ecx, [rip + f_hc + HC_stage]
    cmp ecx, HC_STAGE_URL
    je .Lfl_url_err
    cmp ecx, HC_STAGE_TLS
    je .Lfl_tls_err
    cmp ecx, HC_STAGE_HANDSHAKE
    je .Lfl_tls_err
    cmp ecx, HC_STAGE_RESOLVE
    jne .Lfl_net_err
    cmp rax, -EINVAL
    jne .Lfl_net_err
    lea rdi, [rip + f_hc + HC_host]
    call net_is_ip4
    test eax, eax
    jnz .Lfl_url_err
    jmp .Lfl_net_err
.Lfl_url_err:
    lea rdi, [rip + .Lerr_url]
    call ferr
    mov eax, 1
    EPILOGUE
.Lfl_net_err:
    lea rdi, [rip + .Lerr_net]
    call ferr
    mov eax, 1
    EPILOGUE
.Lfl_recv_err:
    # fetch_recv_loop prints the specific parser/body error before returning
    # -EINVAL; anything else is an ordinary network error.
    cmp rax, -EINVAL
    jne .Lfl_net_err
    mov eax, 1
    EPILOGUE
.Lfl_parse_err:
    lea rdi, [rip + .Lerr_parse]
    call ferr
    mov eax, 1
    EPILOGUE
.Lfl_tls_err:
    lea rdi, [rip + .Lerr_tls]
    call ferr
    mov rdi, [rip + f_hc + HC_conn]
    test rdi, rdi
    jz 5f
    call tls_last_error
    test rax, rax
    jz 5f
    mov rdi, rax
    call ferr
5:  mov eax, 1
    EPILOGUE

# fetch_replay(path cstr) -> exit code
fetch_replay:
    PROLOGUE 16
    lea rsi, [rip + f_file]
    call read_file
    test rax, rax
    js .Lfe_err
    mov r14, [rip + f_file + SB_ptr]
    mov r13, [rip + f_file + SB_len]
    cmp r13, 6
    jb .Lfe_err
    mov rdi, r14
    lea rsi, [rip + .Lmagic]
    mov edx, 6
    call memeq
    test eax, eax
    jz .Lfe_err
    mov r12, 6                  # offset
.Lfe_loop:
    lea rax, [r12 + 5]
    cmp rax, r13
    ja .Lfe_end
    movzx r15d, byte ptr [r14 + r12]
    mov eax, [r14 + r12 + 1]    # u32 length (little-endian on x86)
    add r12, 5
    mov rbx, r13
    sub rbx, r12
    cmp rbx, rax
    jb .Lfe_err
    test r15d, r15d
    jz .Lfe_skip
    mov [rsp], rax
    lea rsi, [r14 + r12]
    mov rdx, rax
    call feed_response
    test rax, rax
    js .Lfe_err
    mov rax, [rsp]
.Lfe_skip:
    add r12, rax
    jmp .Lfe_loop
.Lfe_end:
    # The recording stops at the peer's last byte, never at a synthetic EOF:
    # tell the parser the body ended (catching a truncated close-delimited or
    # length-framed body), then fail on any error it recorded.
    lea rdi, [rip + f_resp]
    call http_resp_eof
    lea rdi, [rip + f_resp]
    call http_resp_error
    test rax, rax
    jnz .Lfe_rerr
    cmp dword ptr [rip + f_printed], 0
    jne 1f
    call fetch_print_headers
    mov dword ptr [rip + f_printed], 1
1:  xor eax, eax
    EPILOGUE
.Lfe_rerr:
    mov rdi, rax
    call ferr
    mov eax, 1
    EPILOGUE
.Lfe_err:
    lea rdi, [rip + .Lerr_replay]
    call ferr
    mov eax, 1
    EPILOGUE

# fetch_main(argc, argv) -> exit code
FN fetch_main
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    lea rax, [rip + .Lm_get]
    mov [rip + f_method], rax
    xor r14, r14
    xor rbx, rbx
.Lfm_loop:
    inc rbx
    cmp rbx, r12
    jae .Lfm_parsed
    mov r15, [r13 + rbx*8]
    cmp byte ptr [r15], '-'
    jne .Lfm_url
    mov rdi, r15
    lea rsi, [rip + .Lopt_insecure]
    call cstr_eq
    test eax, eax
    jnz .Lfm_insecure
    mov rdi, r15
    lea rsi, [rip + .Lopt_dump]
    call cstr_eq
    test eax, eax
    jnz .Lfm_dump
    mov rdi, r15
    lea rsi, [rip + .Lopt_record]
    call cstr_eq
    test eax, eax
    jnz .Lfm_record
    mov rdi, r15
    lea rsi, [rip + .Lopt_replay]
    call cstr_eq
    test eax, eax
    jnz .Lfm_replay
    mov rdi, r15
    lea rsi, [rip + .Lopt_method]
    call cstr_eq
    test eax, eax
    jnz .Lfm_method
    mov rdi, r15
    lea rsi, [rip + .Lopt_header]
    call cstr_eq
    test eax, eax
    jnz .Lfm_header
    mov rdi, r15
    lea rsi, [rip + .Lopt_data]
    call cstr_eq
    test eax, eax
    jnz .Lfm_data
    jmp .Lfm_usage
.Lfm_insecure:
    or dword ptr [rip + f_flags], 1
    jmp .Lfm_loop
.Lfm_dump:
    or dword ptr [rip + f_flags], 2
    jmp .Lfm_loop
.Lfm_record:
    inc rbx
    cmp rbx, r12
    jae .Lfm_usage
    mov rax, [r13 + rbx*8]
    mov [rip + f_record_path], rax
    jmp .Lfm_loop
.Lfm_replay:
    inc rbx
    cmp rbx, r12
    jae .Lfm_usage
    mov rax, [r13 + rbx*8]
    mov [rip + f_replay_path], rax
    jmp .Lfm_loop
.Lfm_method:
    inc rbx
    cmp rbx, r12
    jae .Lfm_usage
    mov rax, [r13 + rbx*8]
    mov [rip + f_method], rax
    mov dword ptr [rip + f_method_set], 1
    jmp .Lfm_loop
.Lfm_header:
    inc rbx
    cmp rbx, r12
    jae .Lfm_usage
    lea rdi, [rip + f_headers]
    mov esi, 8
    call vec_push
    mov rcx, [r13 + rbx*8]
    mov [rax], rcx
    jmp .Lfm_loop
.Lfm_data:
    inc rbx
    cmp rbx, r12
    jae .Lfm_usage
    mov rax, [r13 + rbx*8]
    mov [rip + f_data], rax
    mov rdi, rax
    call strlen
    mov [rip + f_datalen], rax
    cmp dword ptr [rip + f_method_set], 0
    jne .Lfm_loop
    lea rax, [rip + .Lm_post]
    mov [rip + f_method], rax
    jmp .Lfm_loop
.Lfm_url:
    test r14, r14
    jnz .Lfm_usage
    mov r14, r15
    jmp .Lfm_loop
.Lfm_parsed:
    test r14, r14
    jz .Lfm_usage
    lea rdi, [rip + f_hc]
    call hc_init
    mov edi, RECV_BUF
    call mem_alloc
    mov [rip + f_recbuf], rax
    lea rdi, [rip + f_hc]
    mov rsi, [rip + f_recbuf]
    mov edx, RECV_BUF
    call hc_set_recbuf
    lea rdi, [rip + f_resp]
    xor esi, esi
    mov edx, RESP_SIZE
    call memset
    lea rdi, [rip + f_resp]
    lea rsi, [rip + fetch_on_body]
    xor edx, edx
    call http_resp_init
    # HEAD responses carry headers only (RFC 9110 9.3.2): tell the parser
    # before any body bytes are read so it completes after the header block.
    mov rdi, [rip + f_method]
    lea rsi, [rip + .Lm_head]
    call cstr_eq
    test eax, eax
    jz .Lfm_not_head
    lea rdi, [rip + f_resp]
    call http_resp_no_body
.Lfm_not_head:
    lea rdi, [rip + f_sse]
    lea rsi, [rip + fetch_on_sse]
    xor edx, edx
    call sse_init
    cmp qword ptr [rip + f_replay_path], 0
    je 1f
    mov rdi, [rip + f_replay_path]
    call fetch_replay
    EPILOGUE
1:  mov rdi, r14
    call fetch_live
    EPILOGUE
.Lfm_usage:
    mov edi, 2
    lea rsi, [rip + .Lerr_usage]
    call f_out_cstr
    mov edi, 2
    lea rsi, [rip + .Lnl]
    call f_out_cstr
    mov eax, 2
    EPILOGUE
