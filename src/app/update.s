# update: `opcode update [--check] [--url URL] [--json] [--offline]`
# Fetches the latest release JSON over the same connect/TLS/poll path as fetch.s
# (this file is self-contained; fetch.s is left untouched) and compares the
# release `tag_name` with the build version, ignoring a leading 'v'.
.include "opcode.inc"
.include "net/net.inc"
# HC transport state and HCR_* error policy flags
.include "wire/http_client.inc"
# Url struct offsets: single-sourced in src/wire/url.inc
.include "wire/url.inc"

.equ UPD_TIMEOUT_MS, 30000
.equ UPD_TIMEOUT_NS, 30000000000
.equ UPD_CONNECT_TIMEOUT_NS, 3000000000
.equ UPD_RECV_BUF, 65536
.equ UPD_RESP_SIZE, 2048
.equ UPD_BODY_MAX, 1048576      # cap the release JSON body at 1 MiB
.equ UPD_HOST_CAP, 512

.section .rodata
.Ldef_url:      .asciz "https://api.github.com/repos/abird-ai/opcode/releases/latest"
.Lopt_url:      .asciz "--url"
.Lopt_json:     .asciz "--json"
.Lopt_check:    .asciz "--check"
.Lopt_offline:  .asciz "--offline"
.Lm_get:        .asciz "GET"
.Lh_user_agent: .asciz "opcode/0.1"
.Lua_name:      .asciz "user-agent"
.Ltag_name:     .asciz "tag_name"
.Lhtml_url:     .asciz "html_url"
.Lprefix:       .asciz "opcode "
.Luptodate:     .asciz " is up to date\n"
.Larrow:        .asciz " -> "
.Lavailable:    .asciz " is available\n"
.Ldownload:     .asciz "download: "
.Lnl:           .asciz "\n"
.Lerr_offline:  .asciz "opcode: offline\n"
.Lerr_failed:   .asciz "opcode: update check failed\n"
.Lerr_usage:    .asciz "usage: opcode update [--check] [--url URL] [--json] [--offline]\n"

.bss
.p2align 3
u_hc:       .zero HC_SIZE
u_req:      .zero SB_SIZE
u_body:     .zero SB_SIZE
u_resp:     .zero UPD_RESP_SIZE
u_recbuf:   .zero 8
u_url_str:  .zero 8
u_json:     .zero 8

.text

# cstr_eq(a, b) -> 1|0 (leaf)
upd_cstr_eq:
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
upd_out_cstr:
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

# body callback: append every chunk to u_body, capped to avoid unbounded growth.
upd_on_body:
    PROLOGUE
    mov rax, UPD_BODY_MAX
    sub rax, [rip + u_body + SB_len]
    jbe 1f
    cmp rdx, rax
    cmova rdx, rax
    lea rdi, [rip + u_body]
    call sb_push
1:  xor eax, eax
    EPILOGUE

# feed_response(ptr in rsi, len in rdx) -> 0 | -EINVAL
upd_feed_response:
    PROLOGUE
    lea rdi, [rip + u_resp]
    call http_resp_feed
    test rax, rax
    jg 1f
    lea rdi, [rip + u_resp]
    call http_resp_done
    test eax, eax
    jnz 1f
    mov rax, -EINVAL
    EPILOGUE
1:  xor eax, eax
    EPILOGUE

# build_request() -> 0
upd_build_request:
    PROLOGUE
    lea rdi, [rip + u_req]
    call sb_clear
    lea rdi, [rip + u_req]
    lea rsi, [rip + .Lm_get]
    lea rdx, [rip + u_hc + HC_authority]
    mov ecx, [rip + u_hc + HC_authlen]
    mov r8, [rip + u_hc + HC_url + U_path]
    mov r9d, [rip + u_hc + HC_url + U_path_len]
    call http_req_begin
    lea rdi, [rip + u_req]
    lea rsi, [rip + .Lua_name]
    lea rdx, [rip + .Lh_user_agent]
    call http_req_header_cstr
    lea rdi, [rip + u_req]
    call http_req_end
    xor eax, eax
    EPILOGUE

# upd_recv_loop() -> 0 | -errno
# Update historically ignored a parser error that only http_resp_eof raises,
# so HCR_PROGRESS (not HCR_STRICT) keeps the exact error surface.
upd_recv_loop:
    PROLOGUE
    mov edi, CLOCK_MONOTONIC
    call os_now_ns
    mov r9, rax
    mov rax, UPD_TIMEOUT_NS
    add r9, rax
    lea rdi, [rip + u_hc]
    lea rsi, [rip + u_resp]
    mov edx, HCR_PROGRESS
    xor ecx, ecx
    xor r8d, r8d
    call hc_recv_loop
    EPILOGUE

# upd_fetch(url cstr) -> 0 | -errno
upd_fetch:
    PROLOGUE 16
    mov r12, rdi
    lea rdi, [rip + u_hc]
    mov rsi, r12
    xor edx, edx
    mov ecx, UPD_TIMEOUT_MS
    mov r8, UPD_CONNECT_TIMEOUT_NS
    xor r9d, r9d
    call hc_connect
    test rax, rax
    js .Luf_err
    call upd_build_request
    mov edi, CLOCK_MONOTONIC
    call os_now_ns
    mov r8, rax
    mov rax, UPD_TIMEOUT_NS
    add r8, rax
    mov edi, [rip + u_hc + HC_fd]
    mov rsi, [rip + u_hc + HC_conn]
    mov rdx, [rip + u_req + SB_ptr]
    mov rcx, [rip + u_req + SB_len]
    call hc_send_all
    test rax, rax
    js .Luf_err
    call upd_recv_loop
    test rax, rax
    js .Luf_err
    xor eax, eax
    EPILOGUE
.Luf_err:
    # Preserve the real errno from the failing call (0/positive -> -EINVAL),
    # then close whatever the attempt opened.
    test rax, rax
    js 1f
    mov rax, -EINVAL
1:  mov r15, rax
    lea rdi, [rip + u_hc]
    call hc_close
    mov rax, r15
    EPILOGUE

# opcode_update_main(argc, argv) -> exit code; argv[0] is "update"
FN opcode_update_main
    PROLOGUE
    mov r12, rdi                # argc
    mov r13, rsi                # argv
    lea rax, [rip + .Ldef_url]
    mov [rip + u_url_str], rax
    mov qword ptr [rip + u_json], 0
    mov r14, 1                  # arg index
.Lum_loop:
    cmp r14, r12
    jae .Lum_parsed
    mov r15, [r13 + r14*8]
    cmp byte ptr [r15], '-'
    jne .Lum_usage
    mov rdi, r15
    lea rsi, [rip + .Lopt_check]
    call upd_cstr_eq
    test eax, eax
    jnz .Lum_next
    mov rdi, r15
    lea rsi, [rip + .Lopt_json]
    call upd_cstr_eq
    test eax, eax
    jnz .Lum_json
    mov rdi, r15
    lea rsi, [rip + .Lopt_offline]
    call upd_cstr_eq
    test eax, eax
    jnz .Lum_offline
    mov rdi, r15
    lea rsi, [rip + .Lopt_url]
    call upd_cstr_eq
    test eax, eax
    jnz .Lum_url
    jmp .Lum_usage
.Lum_json:
    mov qword ptr [rip + u_json], 1
    jmp .Lum_next
.Lum_offline:
    mov qword ptr [rip + g_offline], 1
    jmp .Lum_next
.Lum_url:
    inc r14
    cmp r14, r12
    jae .Lum_usage
    mov rax, [r13 + r14*8]
    mov [rip + u_url_str], rax
.Lum_next:
    inc r14
    jmp .Lum_loop
.Lum_parsed:
    cmp qword ptr [rip + g_offline], 0
    jne .Lum_offline_out
    lea rdi, [rip + u_hc]
    call hc_init
    mov edi, UPD_RECV_BUF
    call mem_alloc
    mov [rip + u_recbuf], rax
    lea rdi, [rip + u_hc]
    mov rsi, [rip + u_recbuf]
    mov edx, UPD_RECV_BUF
    call hc_set_recbuf
    lea rdi, [rip + u_body]
    call sb_clear
    lea rdi, [rip + u_resp]
    lea rsi, [rip + upd_on_body]
    xor edx, edx
    call http_resp_init
    mov rdi, [rip + u_url_str]
    call upd_fetch
    test rax, rax
    js .Lum_failed
    mov rdi, [rip + u_body + SB_ptr]
    mov rsi, [rip + u_body + SB_len]
    call json_parse
    test rax, rax
    jz .Lum_failed
    cmp qword ptr [rip + u_json], 0
    jne .Lum_json_out
    mov r12, rax                # root JV
    mov rdi, r12
    lea rsi, [rip + .Ltag_name]
    call json_get_cstr
    test rax, rax
    jz .Lum_failed
    mov r13, rax                # tag_name
    mov edi, 1
    lea rsi, [rip + .Lprefix]
    call upd_out_cstr
    mov edi, 1
    lea rsi, [rip + opcode_version]
    call upd_out_cstr
    mov rcx, r13
    cmp byte ptr [rcx], 'v'
    jne 1f
    inc rcx
1:  mov rdi, rcx
    lea rsi, [rip + opcode_version]
    call upd_cstr_eq
    test eax, eax
    jz .Lum_avail
    mov edi, 1
    lea rsi, [rip + .Luptodate]
    call upd_out_cstr
    xor eax, eax
    EPILOGUE
.Lum_avail:
    mov edi, 1
    lea rsi, [rip + .Larrow]
    call upd_out_cstr
    mov edi, 1
    mov rsi, r13
    call upd_out_cstr
    mov edi, 1
    lea rsi, [rip + .Lavailable]
    call upd_out_cstr
    mov rdi, r12
    lea rsi, [rip + .Lhtml_url]
    call json_get_cstr
    test rax, rax
    jz .Lum_ok
    mov r14, rax
    mov edi, 1
    lea rsi, [rip + .Ldownload]
    call upd_out_cstr
    mov edi, 1
    mov rsi, r14
    call upd_out_cstr
    mov edi, 1
    lea rsi, [rip + .Lnl]
    call upd_out_cstr
.Lum_ok:
    xor eax, eax
    EPILOGUE
.Lum_json_out:
    mov edi, 1
    mov rsi, [rip + u_body + SB_ptr]
    mov rdx, [rip + u_body + SB_len]
    call write_all
    xor eax, eax
    EPILOGUE
.Lum_offline_out:
    mov edi, 2
    lea rsi, [rip + .Lerr_offline]
    call upd_out_cstr
    xor eax, eax
    EPILOGUE
.Lum_failed:
    mov edi, 2
    lea rsi, [rip + .Lerr_failed]
    call upd_out_cstr
    mov eax, 1
    EPILOGUE
.Lum_usage:
    mov edi, 2
    lea rsi, [rip + .Lerr_usage]
    call upd_out_cstr
    mov eax, 2
    EPILOGUE
