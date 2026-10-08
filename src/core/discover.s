.include "opcode.inc"
.include "core/core.inc"
.include "net/net.inc"
# HC transport state and HCR_* error policy flags
.include "wire/http_client.inc"
# Url struct layout: single-sourced in src/wire/url.inc (see src/wire/API.md)
.include "wire/url.inc"
# discover.s: runtime model discovery for the catalog.
#
#   discover_models(provider cstr, verbose u32) -> count | -errno
#
# Resolves the provider api/base (g_discover_base override > config
# providers.<p>.base_url > built-in catalog), GETs the provider's model list,
# merges the ids with the built-in catalog for that provider and atomically
# rewrites <config dir>/models.jsonc (tmp + rename).  catalog_load_user()
# (src/core/catalog.s) reads that file at startup.
#
# Endpoints:
#   ollama / ollama-cloud : <base>/models first (OpenAI shape, Bearer only
#                           when a key exists), falling back to the native
#                           <scheme://host[:port]>/api/tags
#   api == openai-chat    : <base>/models                    (Bearer)
#   api == anthropic-*    : <base>/v1/models                 (x-api-key)
#
# The transport mirrors src/app/fetch.s: non-blocking connect, poll loop, TLS
# handshake driven by tls_want, 8 s deadline, body capped at 4 MiB.

.equ DISC_TIMEOUT_MS, 8000
.equ DISC_TIMEOUT_NS, 8000000000
.equ DISC_CONNECT_MS, 8000
.equ DISC_RECV_BUF,   65536
.equ DISC_RESP_SIZE,  2048
.equ DISC_BODY_MAX,   4194304
.equ DISC_HOST_CAP,   512
.equ DISC_PATH_CAP,   512

.equ DK_OLLAMA,    1
.equ DK_OPENAI,    2
.equ DK_ANTHROPIC, 3

.ifndef E2BIG
.equ E2BIG, 7
.endif

.bss
.p2align 3
.globl g_discover_base
g_discover_base: .quad 0       # test/dev override: effective base URL cstr
d_kind:        .zero 4
d_parse_kind:  .zero 4
d_verbose:     .zero 4
d_overflow:    .zero 4
d_flags:       .zero 4
d_provider:    .zero 8
d_api:         .zero 8
d_effective:   .zero 8
d_canon:       .zero 8
d_owned_base:  .zero 8
d_hc:          .zero HC_SIZE
d_pathbuf:     .zero DISC_PATH_CAP
d_pathptr:     .zero 8
d_pathlen:     .zero 8
d_req:         .zero SB_SIZE
d_resp:        .zero DISC_RESP_SIZE
d_body:        .zero SB_SIZE
d_out:         .zero SB_SIZE
d_authbuf:     .zero 512
d_recbuf:      .zero DISC_RECV_BUF
d_idkey:       .zero 8
d_namekey:     .zero 8
d_cur_id:      .zero 8
d_cur_idlen:   .zero 8
d_cur_name:    .zero 8
d_cur_namelen: .zero 8
d_cur_api:     .zero 8
d_cur_base:    .zero 8
d_cur_flags:   .zero 4
d_scan_arr:    .zero 8
d_scan_upto:   .zero 8
d_scan_id:     .zero 8
d_scan_idlen:  .zero 8
.globl g_discover_force
g_discover_force: .zero 4        # --refresh-models: ignore a fresh cache
d_cache_fetched:  .zero 8        # newest "fetched" seen by disc_cache_load
d_cache_count:    .zero 8        # cached model count for that entry

.section .rodata
.Ld_tags:        .asciz "/api/tags"
.Ld_models:      .asciz "/models"
.Ld_v1models:    .asciz "/v1/models"
.Lh_ua:          .asciz "user-agent"
.Lua:            .asciz "opcode/0.1"
.Lh_accept:      .asciz "accept"
.Laccept:        .asciz "application/json"
.Lh_auth:        .asciz "authorization"
.Lh_xkey:        .asciz "x-api-key"
.Lh_ver:         .asciz "anthropic-version"
.Lver:           .asciz "2023-06-01"
.Lbearer:        .asciz "Bearer "
.Lm_get:         .asciz "GET"
.Lprov_ollama:   .asciz "ollama"
.Lprov_cloud:    .asciz "ollama-cloud"
.Lapi_anthropic: .asciz "anthropic-messages"
.Lapi_openai:    .asciz "openai-chat"
.Lk_models:      .asciz "models"
.Lk_data:        .asciz "data"
.Lk_name:        .asciz "name"
.Lk_id:          .asciz "id"
.Lk_display:     .asciz "display_name"
.Lk_provider:    .asciz "provider"
.Lk_api:         .asciz "api"
.Lk_base:        .asciz "base"
.Lk_ctx:         .asciz "context_window"
.Lk_max:         .asciz "max_tokens"
.Lk_reasoning:   .asciz "reasoning"
.Lk_image:       .asciz "image"
.Lk_no_key:      .asciz "no_key"
.Lk_at:          .asciz "discovered_at"
.Lumodels:       .asciz "/models.jsonc"
.Lumodelscache:  .asciz "/models-cache.jsonc"
.Lk_fetched:     .asciz "fetched"
.Lk_count:       .asciz "count"

# Discovered-model cache entries stay fresh for 24 h (DISC_TTL_MS).
.equ DISC_TTL_MS, 86400000
.Ltmp_suffix:    .asciz ".tmp"
.Lempty:         .asciz ""
.Ldiscovered:    .asciz "opcode: discovered "
.Lfor:           .asciz " models for "
.Lnl:            .byte 10
.text

# disc_streq(a cstr, b cstr) -> 1|0 (leaf)
disc_streq:
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

# disc_on_body(ctx, ptr, len): append to d_body, cap at DISC_BODY_MAX
disc_on_body:
    mov rax, [rip + d_body + SB_len]
    add rax, rdx
    cmp rax, DISC_BODY_MAX
    ja 1f
    lea rdi, [rip + d_body]
    jmp sb_push
1:  mov dword ptr [rip + d_overflow], 1
    ret

# disc_strcpy512(dst, src) -> dst (leaf, NUL-terminated, hard 511-byte cap)
disc_strcpy512:
    xor ecx, ecx
1:  cmp ecx, 511
    jae 2f
    mov al, [rsi + rcx]
    mov [rdi + rcx], al
    test al, al
    jz 3f
    inc ecx
    jmp 1b
2:  mov byte ptr [rdi + 511], 0
3:  mov rax, rdi
    ret

# disc_strcat512(dst, src) -> dst (leaf)
disc_strcat512:
    push rdi
    call strlen
    pop rdi
    mov rcx, rax
    cmp rcx, 511
    jb 1f
    mov byte ptr [rdi + 511], 0
    mov rax, rdi
    ret
1:  xor edx, edx
2:  mov al, [rsi + rdx]
    mov [rdi + rcx], al
    test al, al
    jz 4f
    inc rcx
    inc rdx
    cmp rcx, 511
    jb 2b
    mov byte ptr [rdi + 511], 0
4:  mov rax, rdi
    ret

# disc_bearer(key cstr) -> rax ptr, rdx len ("Bearer " + key in d_authbuf)
disc_bearer:
    PROLOGUE 0
    mov r12, rdi
    lea rdi, [rip + d_authbuf]
    lea rsi, [rip + .Lbearer]
    call disc_strcpy512
    lea rdi, [rip + d_authbuf]
    mov rsi, r12
    call disc_strcat512
    lea rdi, [rip + d_authbuf]
    call strlen
    mov rdx, rax
    lea rax, [rip + d_authbuf]
    EPILOGUE

# disc_join_path(base ptr, base len, suffix cstr): d_pathptr/d_pathlen
disc_join_path:
    PROLOGUE 0
    mov r8, rdi
    mov r9, rsi
    lea r10, [rip + d_pathbuf]
    xor ebx, ebx
1:  cmp rbx, r9
    jae 3f
    cmp rbx, 511
    jae 3f
    mov al, [r8 + rbx]
    mov [r10 + rbx], al
    inc rbx
    jmp 1b
3:  test rbx, rbx
    jz 4f
    cmp byte ptr [r10 + rbx - 1], '/'
    jne 4f
    dec rbx
4:  xor ecx, ecx
5:  cmp rbx, 511
    jae 6f
    mov al, [rdx + rcx]
    test al, al
    jz 6f
    mov [r10 + rbx], al
    inc rbx
    inc rcx
    jmp 5b
6:  mov byte ptr [r10 + rbx], 0
    mov [rip + d_pathlen], rbx
    mov [rip + d_pathptr], r10
    EPILOGUE

# disc_close(): close whatever the transport opened (idempotent)
disc_close:
    lea rdi, [rip + d_hc]
    jmp hc_close

# disc_connect() -> 0 | -errno: transport on the d_hc filled by hc_setup.
# Every failure maps to -EIO, exactly like the old inline connect.
disc_connect:
    PROLOGUE
    lea rdi, [rip + d_hc]
    mov esi, DISC_CONNECT_MS
    mov rdx, DISC_TIMEOUT_NS
    xor ecx, ecx
    call hc_connect_started
    test rax, rax
    jns .Ldc_ok
    mov rax, -EIO
    EPILOGUE
.Ldc_ok:
    xor eax, eax
    EPILOGUE

# disc_build_request() -> 0 | -errno (-EACCES when a key is required)
disc_build_request:
    PROLOGUE 0
    lea rdi, [rip + d_req]
    call sb_clear
    lea rdi, [rip + d_req]
    lea rsi, [rip + .Lm_get]
    lea rdx, [rip + d_hc + HC_authority]
    mov ecx, [rip + d_hc + HC_authlen]
    mov r8, [rip + d_pathptr]
    mov r9d, [rip + d_pathlen]
    call http_req_begin
    lea rdi, [rip + d_req]
    lea rsi, [rip + .Lh_ua]
    lea rdx, [rip + .Lua]
    call http_req_header_cstr
    lea rdi, [rip + d_req]
    lea rsi, [rip + .Lh_accept]
    lea rdx, [rip + .Laccept]
    call http_req_header_cstr
    cmp dword ptr [rip + d_kind], DK_ANTHROPIC
    je .Lbr_anthropic
    cmp dword ptr [rip + d_kind], DK_OLLAMA
    je .Lbr_ollama
    # openai-chat: Bearer when a key exists; required unless MDF_NO_KEY
    mov rdi, [rip + d_provider]
    call auth_key
    test rax, rax
    jnz .Lbr_bearer
    test dword ptr [rip + d_flags], MDF_NO_KEY
    jnz .Lbr_done
.Lbr_nokey:
    mov rax, -EACCES
    EPILOGUE
.Lbr_ollama:
    # ollama / ollama-cloud: optional Bearer when a key exists; local never
    # requires one and falls back to native discovery on any failure
    mov rdi, [rip + d_provider]
    call auth_key
    test rax, rax
    jz .Lbr_done
    jmp .Lbr_bearer
.Lbr_anthropic:
    mov rdi, [rip + d_provider]
    call auth_key
    test rax, rax
    jz .Lbr_nokey
    mov r12, rax
    lea rdi, [rip + d_req]
    lea rsi, [rip + .Lh_xkey]
    mov rdx, r12
    call http_req_header_cstr
    lea rdi, [rip + d_req]
    lea rsi, [rip + .Lh_ver]
    lea rdx, [rip + .Lver]
    call http_req_header_cstr
    mov rdi, r12
    call mem_free
    jmp .Lbr_done
.Lbr_bearer:
    mov r12, rax
    mov rdi, rax
    call disc_bearer
    mov rcx, rdx
    mov rdx, rax
    lea rdi, [rip + d_req]
    lea rsi, [rip + .Lh_auth]
    call http_req_header
    mov rdi, r12
    call mem_free
.Lbr_done:
    lea rdi, [rip + d_req]
    call http_req_end
    xor eax, eax
    EPILOGUE

# disc_send_all() -> 0 | -errno
disc_send_all:
    PROLOGUE
    mov edi, CLOCK_MONOTONIC
    call os_now_ns
    mov r8, rax
    mov rax, DISC_TIMEOUT_NS
    add r8, rax
    mov edi, [rip + d_hc + HC_fd]
    mov rsi, [rip + d_hc + HC_conn]
    mov rdx, [rip + d_req + SB_ptr]
    mov rcx, [rip + d_req + SB_len]
    call hc_send_all
    EPILOGUE

# disc_recv_loop() -> 0 | -errno
# Discover checked http_resp_error after every chunk and after the parser
# completed, but never after http_resp_eof: keep that exact policy.
disc_recv_loop:
    PROLOGUE
    mov edi, CLOCK_MONOTONIC
    call os_now_ns
    mov r9, rax
    mov rax, DISC_TIMEOUT_NS
    add r9, rax
    lea rdi, [rip + d_hc]
    lea rsi, [rip + d_resp]
    mov edx, HCR_CHECK_FEED | HCR_CHECK_DONE
    xor ecx, ecx
    xor r8d, r8d
    call hc_recv_loop
    EPILOGUE

# disc_emit(out SB*): write one model record from d_cur_id/d_cur_name/...
disc_emit:
    PROLOGUE 0
    mov rbx, rdi
    mov r12d, [rip + d_cur_flags]
    call jsonw_obj
    mov rdi, rbx
    lea rsi, [rip + .Lk_id]
    call jsonw_key
    mov rdi, rbx
    mov rsi, [rip + d_cur_id]
    mov rdx, [rip + d_cur_idlen]
    call jsonw_str
    mov rdi, rbx
    lea rsi, [rip + .Lk_name]
    call jsonw_key
    mov rdi, rbx
    mov rsi, [rip + d_cur_name]
    mov rdx, [rip + d_cur_namelen]
    call jsonw_str
    mov rdi, rbx
    lea rsi, [rip + .Lk_api]
    call jsonw_key
    mov rdi, rbx
    mov rsi, [rip + d_cur_api]
    test rsi, rsi
    jnz 1f
    lea rsi, [rip + .Lempty]
1:  call jsonw_str_cstr
    mov rdi, rbx
    lea rsi, [rip + .Lk_provider]
    call jsonw_key
    mov rdi, rbx
    mov rsi, [rip + d_provider]
    test rsi, rsi
    jnz 2f
    lea rsi, [rip + .Lempty]
2:  call jsonw_str_cstr
    mov rdi, rbx
    lea rsi, [rip + .Lk_base]
    call jsonw_key
    mov rdi, rbx
    mov rsi, [rip + d_cur_base]
    test rsi, rsi
    jnz 3f
    lea rsi, [rip + .Lempty]
3:  call jsonw_str_cstr
    mov rdi, rbx
    lea rsi, [rip + .Lk_ctx]
    call jsonw_key
    mov rdi, rbx
    xor esi, esi
    call jsonw_u64
    mov rdi, rbx
    lea rsi, [rip + .Lk_max]
    call jsonw_key
    mov rdi, rbx
    xor esi, esi
    call jsonw_u64
    mov rdi, rbx
    lea rsi, [rip + .Lk_reasoning]
    call jsonw_key
    mov rdi, rbx
    mov esi, r12d
    and esi, MDF_REASONING
    call jsonw_bool
    mov rdi, rbx
    lea rsi, [rip + .Lk_image]
    call jsonw_key
    mov rdi, rbx
    mov esi, r12d
    and esi, MDF_IMAGE
    call jsonw_bool
    mov rdi, rbx
    lea rsi, [rip + .Lk_no_key]
    call jsonw_key
    mov rdi, rbx
    mov esi, r12d
    and esi, MDF_NO_KEY
    call jsonw_bool
    mov rdi, rbx
    call jsonw_obj_end
    EPILOGUE

# disc_write() -> 0 | -errno: atomic <config dir>/models.jsonc rewrite
disc_write:
    PROLOGUE 48
    mov qword ptr [rsp], -1         # fd
    mov qword ptr [rsp + 8], 0      # final path
    mov qword ptr [rsp + 16], 0     # tmp path
    mov qword ptr [rsp + 24], 0     # result
    call config_user_dir
    test rax, rax
    jz .Ldw_noent
    mov rbx, rax
    mov rdi, rbx
    mov esi, 0700
    call os_mkdir                  # best effort
    mov rdi, rbx
    lea rsi, [rip + .Lumodels]
    call config_path_join
    test rax, rax
    jz .Ldw_noent
    mov [rsp + 8], rax
    mov rdi, rax
    lea rsi, [rip + .Ltmp_suffix]
    call config_path_join
    test rax, rax
    jz .Ldw_out
    mov [rsp + 16], rax
    mov rdi, rax
    mov esi, O_WRONLY | O_CREAT | O_TRUNC
    mov edx, 0600
    call os_open
    test rax, rax
    js .Ldw_err
    mov [rsp], rax
    mov edi, eax
    mov rsi, [rip + d_out + SB_ptr]
    mov rdx, [rip + d_out + SB_len]
    call write_all
    test rax, rax
    js .Ldw_err
    mov edi, [rsp]
    call os_fsync
    mov edi, [rsp]
    call os_close
    mov qword ptr [rsp], -1
    mov rdi, [rsp + 16]
    mov rsi, [rsp + 8]
    call os_rename
    test rax, rax
    jz .Ldw_ok
.Ldw_err:
    mov [rsp + 24], rax
    mov edi, [rsp]
    cmp edi, 0
    jl 1f
    call os_close
    mov qword ptr [rsp], -1
1:  mov rdi, [rsp + 16]
    test rdi, rdi
    jz .Ldw_out
    call os_unlink
    jmp .Ldw_out
.Ldw_ok:
    mov qword ptr [rsp + 24], 0
.Ldw_out:
    mov rdi, [rsp + 16]
    call mem_free
    mov rdi, [rsp + 8]
    call mem_free
    mov rax, [rsp + 24]
    EPILOGUE
.Ldw_noent:
    mov rax, -ENOENT
    EPILOGUE

# .Ldp_in_builtins(): 1 when d_scan_id appears in the built-in catalog for
# d_provider.  Preserves r12-r15 (PROLOGUE).
.Ldp_in_builtins:
    PROLOGUE 16
    call catalog_count
    mov r12, rax
    xor r13d, r13d
1:  cmp r13, r12
    jae 3f
    mov rdi, r13
    call catalog_at
    test rax, rax
    jz 2f
    mov r14, rax
    mov rdi, [r14 + MD_provider]
    mov rsi, [rip + d_provider]
    call disc_streq
    test eax, eax
    jz 2f
    mov rdi, [r14 + MD_id]
    call strlen
    mov rsi, rax
    mov rdi, [r14 + MD_id]
    mov rdx, [rip + d_scan_id]
    mov rcx, [rip + d_scan_idlen]
    call str_eq
    test eax, eax
    jnz 4f
2:  inc r13
    jmp 1b
3:  xor eax, eax
    EPILOGUE
4:  mov eax, 1
    EPILOGUE

# .Ldp_in_earlier(): 1 when d_scan_id already appears before d_scan_upto in
# the d_scan_arr discovery array.
.Ldp_in_earlier:
    PROLOGUE 16
    xor r13d, r13d
1:  cmp r13, [rip + d_scan_upto]
    jae 3f
    mov rdi, [rip + d_scan_arr]
    mov esi, r13d
    call json_at
    test rax, rax
    jz 2f
    mov rdi, rax
    mov rsi, [rip + d_idkey]
    call json_get
    test rax, rax
    jz 2f
    mov rdi, rax
    call json_str
    test rax, rax
    jz 2f
    mov rdi, rax
    mov rsi, rdx
    mov rdx, [rip + d_scan_id]
    mov rcx, [rip + d_scan_idlen]
    call str_eq
    test eax, eax
    jnz 4f
2:  inc r13
    jmp 1b
3:  xor eax, eax
    EPILOGUE
4:  mov eax, 1
    EPILOGUE

# disc_parse() -> discovered count | -errno: parse d_body, merge with the
# built-in catalog and write models.jsonc.
disc_parse:
    PROLOGUE 32
    mov rdi, [rip + d_body + SB_ptr]
    mov rsi, [rip + d_body + SB_len]
    test rdi, rdi
    jz .Ldp_bad
    test rsi, rsi
    jz .Ldp_bad
    call json_parse
    test rax, rax
    jz .Ldp_bad
    mov rbx, rax
    mov rdi, rbx
    cmp dword ptr [rip + d_parse_kind], DK_OLLAMA
    jne 1f
    lea rsi, [rip + .Lk_models]
    jmp 2f
1:  lea rsi, [rip + .Lk_data]
2:  call json_get
    test rax, rax
    jz .Ldp_bad
    mov [rsp], rax              # discovered array
    mov rdi, rax
    call json_len
    mov [rsp + 8], rax          # n
    # ---- output header + built-in records for this provider ----
    lea rdi, [rip + d_out]
    call sb_clear
    lea rdi, [rip + d_out]
    call jsonw_obj
    lea rdi, [rip + d_out]
    lea rsi, [rip + .Lk_at]
    call jsonw_key
    mov edi, CLOCK_REALTIME
    call os_now_ns
    mov rcx, 1000000
    xor edx, edx
    div rcx
    mov rsi, rax
    lea rdi, [rip + d_out]
    call jsonw_u64
    lea rdi, [rip + d_out]
    lea rsi, [rip + .Lk_models]
    call jsonw_key
    lea rdi, [rip + d_out]
    call jsonw_arr
    call catalog_count
    mov r12, rax
    xor r13d, r13d
.Ldp_bloop:
    cmp r13, r12
    jae .Ldp_bdone
    mov rdi, r13
    call catalog_at
    test rax, rax
    jz .Ldp_bnext
    mov r14, rax
    mov rdi, [r14 + MD_provider]
    mov rsi, [rip + d_provider]
    call disc_streq
    test eax, eax
    jz .Ldp_bnext
    mov rax, [r14 + MD_id]
    mov [rip + d_cur_id], rax
    mov rdi, rax
    call strlen
    mov [rip + d_cur_idlen], rax
    mov rax, [r14 + MD_name]
    test rax, rax
    jnz 3f
    mov rax, [r14 + MD_id]
3:  mov [rip + d_cur_name], rax
    mov rdi, rax
    call strlen
    mov [rip + d_cur_namelen], rax
    mov rax, [r14 + MD_api]
    mov [rip + d_cur_api], rax
    mov rax, [r14 + MD_base]
    mov [rip + d_cur_base], rax
    mov eax, [r14 + MD_flags]
    mov [rip + d_cur_flags], eax
    lea rdi, [rip + d_out]
    call disc_emit
.Ldp_bnext:
    inc r13
    jmp .Ldp_bloop
.Ldp_bdone:
    # ---- discovered records not already in the built-in catalog ----
    xor r13d, r13d              # array index
    xor r15d, r15d              # emitted
.Ldp_dloop:
    cmp r13, [rsp + 8]
    jae .Ldp_ddone
    mov rdi, [rsp]
    mov esi, r13d
    call json_at
    test rax, rax
    jz .Ldp_dnext
    mov r14, rax
    mov rdi, r14
    mov rsi, [rip + d_idkey]
    call json_get
    test rax, rax
    jz .Ldp_dnext
    mov rdi, rax
    call json_str
    test rax, rax
    jz .Ldp_dnext
    test rdx, rdx
    jz .Ldp_dnext
    mov [rsp + 16], rax
    mov [rsp + 24], rdx
    mov [rip + d_scan_id], rax
    mov [rip + d_scan_idlen], rdx
    mov rax, [rsp]
    mov [rip + d_scan_arr], rax
    mov [rip + d_scan_upto], r13
    call .Ldp_in_builtins
    test eax, eax
    jnz .Ldp_dnext
    call .Ldp_in_earlier
    test eax, eax
    jnz .Ldp_dnext
    # name: namekey | id
    mov rdi, r14
    mov rsi, [rip + d_namekey]
    call json_get
    test rax, rax
    jz 5f
    mov rdi, rax
    call json_str
    test rax, rax
    jz 5f
    test rdx, rdx
    jz 5f
    jmp 6f
5:  mov rax, [rsp + 16]
    mov rdx, [rsp + 24]
6:  mov [rip + d_cur_name], rax
    mov [rip + d_cur_namelen], rdx
    mov rax, [rsp + 16]
    mov [rip + d_cur_id], rax
    mov rax, [rsp + 24]
    mov [rip + d_cur_idlen], rax
    mov rax, [rip + d_api]
    mov [rip + d_cur_api], rax
    mov rax, [rip + d_canon]
    test rax, rax
    jnz 7f
    mov rax, [rip + d_effective]
7:  mov [rip + d_cur_base], rax
    mov eax, [rip + d_flags]
    mov [rip + d_cur_flags], eax
    lea rdi, [rip + d_out]
    call disc_emit
    inc r15
.Ldp_dnext:
    inc r13
    jmp .Ldp_dloop
.Ldp_ddone:
    lea rdi, [rip + d_out]
    call jsonw_arr_end
    lea rdi, [rip + d_out]
    call jsonw_obj_end
    call disc_write
    test rax, rax
    js .Ldp_ret
    mov rax, r15
    EPILOGUE
.Ldp_bad:
    mov rax, -EINVAL
.Ldp_ret:
    EPILOGUE

# disc_attempt() -> count | -errno: one discovery request using d_pathptr/
# d_pathlen and the parser shape in d_parse_kind/d_idkey/d_namekey. Resets
# the body/response state and closes any prior connection so it can be
# retried for the native fallback.
disc_attempt:
    PROLOGUE 0
    call disc_close
    lea rdi, [rip + d_body]
    call sb_clear
    lea rdi, [rip + d_out]
    call sb_clear
    lea rdi, [rip + d_resp]
    call http_resp_free
    lea rdi, [rip + d_resp]
    lea rsi, [rip + disc_on_body]
    xor edx, edx
    call http_resp_init
    mov dword ptr [rip + d_overflow], 0
    call disc_connect
    test rax, rax
    js .Lda_ret
    call disc_build_request
    test rax, rax
    js .Lda_ret
    call disc_send_all
    test rax, rax
    js .Lda_ret
    call disc_recv_loop
    test rax, rax
    js .Lda_ret
    cmp dword ptr [rip + d_overflow], 0
    jne .Lda_ebig
    lea rdi, [rip + d_resp]
    call http_resp_status
    cmp eax, 200
    je .Lda_parse
    cmp eax, 401
    je .Lda_eacces
    cmp eax, 403
    je .Lda_eacces
    mov rax, -EIO
    jmp .Lda_ret
.Lda_eacces:
    mov rax, -EACCES
    jmp .Lda_ret
.Lda_ebig:
    mov rax, -E2BIG
    jmp .Lda_ret
.Lda_parse:
    call disc_parse
.Lda_ret:
    EPILOGUE

# disc_discover_ollama() -> count | -errno: ollama / ollama-cloud discovery.
# Primary path is the OpenAI-compatible <base>/models (data[].id) with a
# Bearer header only when a key exists; on any failure fall back to the
# native <scheme>://<host[:port]>/api/tags (models[].name) parser.
disc_discover_ollama:
    PROLOGUE 0
    mov dword ptr [rip + d_parse_kind], DK_OPENAI
    lea rax, [rip + .Lk_id]
    mov [rip + d_idkey], rax
    mov [rip + d_namekey], rax
    mov rdi, [rip + d_hc + HC_url + U_path]
    mov esi, [rip + d_hc + HC_url + U_path_len]
    lea rdx, [rip + .Ld_models]
    call disc_join_path
    call disc_attempt
    test rax, rax
    jns .Ldo_ret
    mov dword ptr [rip + d_parse_kind], DK_OLLAMA
    lea rax, [rip + .Lk_name]
    mov [rip + d_idkey], rax
    mov [rip + d_namekey], rax
    lea rax, [rip + .Ld_tags]
    mov [rip + d_pathptr], rax
    mov qword ptr [rip + d_pathlen], 9
    call disc_attempt
.Ldo_ret:
    EPILOGUE

# discover_models(provider cstr, verbose u32) -> discovered count | -errno
FN discover_models
    PROLOGUE 64
    mov [rsp], rdi              # provider
    mov [rsp + 8], rsi          # verbose
    mov [rip + d_provider], rdi
    mov [rip + d_verbose], esi
    mov qword ptr [rip + d_owned_base], 0
    mov qword ptr [rip + d_effective], 0
    mov qword ptr [rip + d_canon], 0
    mov qword ptr [rip + d_api], 0
    lea rdi, [rip + d_hc]
    call hc_init
    mov dword ptr [rip + d_flags], 0
    mov dword ptr [rip + d_overflow], 0
    lea rdi, [rip + d_body]
    call sb_clear
    lea rdi, [rip + d_out]
    call sb_clear
    lea rdi, [rip + d_resp]
    call http_resp_free
    lea rdi, [rip + d_resp]
    lea rsi, [rip + disc_on_body]
    xor edx, edx
    call http_resp_init
    # built-in provider record: api, canonical base, flags
    mov rdi, [rsp]
    call catalog_default
    test rax, rax
    jz .Ldm_nobuiltin
    mov rcx, [rax + MD_api]
    mov [rip + d_api], rcx
    mov rcx, [rax + MD_base]
    mov [rip + d_canon], rcx
    mov ecx, [rax + MD_flags]
    mov [rip + d_flags], ecx
.Ldm_nobuiltin:
    # effective base = g_discover_base > config base > catalog base
    mov rax, [rip + g_discover_base]
    test rax, rax
    jnz .Ldm_eff
    mov rdi, [rsp]
    call config_provider_base
    test rax, rax
    jz .Ldm_cat
    mov [rip + d_owned_base], rax
    mov [rip + d_canon], rax
    mov [rip + d_effective], rax
    jmp .Ldm_eff_done
.Ldm_cat:
    mov rax, [rip + d_canon]
    test rax, rax
    jz .Ldm_nobase
    mov [rip + d_effective], rax
    jmp .Ldm_eff_done
.Ldm_eff:
    mov [rip + d_effective], rax
.Ldm_eff_done:
    cmp qword ptr [rip + d_api], 0
    jne 1f
    lea rax, [rip + .Lapi_openai]
    mov [rip + d_api], rax
1:  # provider kind + parse keys
    mov rdi, [rsp]
    lea rsi, [rip + .Lprov_ollama]
    call disc_streq
    test eax, eax
    jnz .Ldm_kind_ollama
    mov rdi, [rsp]
    lea rsi, [rip + .Lprov_cloud]
    call disc_streq
    test eax, eax
    jnz .Ldm_kind_ollama
    mov rdi, [rip + d_api]
    lea rsi, [rip + .Lapi_anthropic]
    call disc_streq
    test eax, eax
    jnz .Ldm_kind_anthropic
    mov dword ptr [rip + d_kind], DK_OPENAI
    lea rax, [rip + .Lk_id]
    mov [rip + d_idkey], rax
    mov [rip + d_namekey], rax
    jmp .Ldm_kind_done
.Ldm_kind_ollama:
    mov dword ptr [rip + d_kind], DK_OLLAMA
    lea rax, [rip + .Lk_name]
    mov [rip + d_idkey], rax
    mov [rip + d_namekey], rax
    jmp .Ldm_kind_done
.Ldm_kind_anthropic:
    mov dword ptr [rip + d_kind], DK_ANTHROPIC
    lea rax, [rip + .Lk_id]
    mov [rip + d_idkey], rax
    lea rax, [rip + .Lk_display]
    mov [rip + d_namekey], rax
.Ldm_kind_done:
    lea rdi, [rip + d_hc]
    mov rsi, [rip + d_effective]
    xor edx, edx
    call hc_setup
    test rax, rax
    js .Ldm_cleanup
    lea rdi, [rip + d_hc]
    lea rsi, [rip + d_recbuf]
    mov edx, DISC_RECV_BUF
    call hc_set_recbuf
    cmp dword ptr [rip + d_kind], DK_OLLAMA
    jne .Ldm_path_api
    call disc_discover_ollama
    jmp .Ldm_cleanup
.Ldm_path_api:
    mov eax, [rip + d_kind]
    mov [rip + d_parse_kind], eax
    mov rdi, [rip + d_hc + HC_url + U_path]
    mov esi, [rip + d_hc + HC_url + U_path_len]
    cmp dword ptr [rip + d_kind], DK_ANTHROPIC
    jne 2f
    lea rdx, [rip + .Ld_v1models]
    jmp 3f
2:  lea rdx, [rip + .Ld_models]
3:  call disc_join_path
    call disc_attempt
.Ldm_cleanup:
    mov r12, rax
    lea rdi, [rip + d_resp]
    call http_resp_free
    call disc_close
    mov rdi, [rip + d_owned_base]
    call mem_free
    mov rax, r12
    test rax, rax
    js .Ldm_ret
    cmp dword ptr [rip + d_verbose], 0
    je .Ldm_ret
    mov r12, rax
    lea rdi, [rip + .Ldiscovered]
    call log_cstr
    mov rdi, r12
    call log_u64
    lea rdi, [rip + .Lfor]
    call log_cstr
    mov rdi, [rsp]
    call log_cstr
    call log_nl
    mov rax, r12
.Ldm_ret:
    EPILOGUE
.Ldm_nobase:
    mov rax, -ENOENT
    jmp .Ldm_cleanup

# ============================================================ discovery cache
#
# A successful discovery records {provider, base, fetched, count} in
# models-cache.jsonc so a later run can skip the network while the entry is
# younger than DISC_TTL_MS.  The file is JSON Lines (one object per line);
# disc_cache_load keeps the newest matching entry, so appending on save is safe
# and a changed base URL invalidates the entry (a stale entry for another
# endpoint must not surface models that may not exist there).  The loaded
# catalog itself is still models.jsonc, written by discover_models.

# disc_cache_path() -> mem_alloc'd <config dir>/models-cache.jsonc | 0
FN disc_cache_path
    PROLOGUE
    call config_user_dir
    test rax, rax
    jz .Ldcp_none
    mov rdi, rax
    lea rsi, [rip + .Lumodelscache]
    call config_path_join
    EPILOGUE
.Ldcp_none:
    xor eax, eax
    EPILOGUE

# disc_cache_load(provider rdi, base rsi|0, fetched_out rdx|0) -> cached count
# Sets d_cache_fetched/d_cache_count for the newest matching entry.
FN disc_cache_load
    PROLOGUE 96
    mov [rsp], rdi              # provider
    mov [rsp + 8], rsi          # base
    mov [rsp + 16], rdx         # fetched_out
    test rdx, rdx
    jz 0f
    mov qword ptr [rdx], 0
0:  mov qword ptr [rip + d_cache_fetched], 0
    mov qword ptr [rip + d_cache_count], 0
    mov qword ptr [rsp + 88], 0
    call disc_cache_path
    test rax, rax
    jz .Ldcl_zero
    mov [rsp + 24], rax         # path
    mov qword ptr [rsp + 32 + SB_ptr], 0
    mov qword ptr [rsp + 32 + SB_len], 0
    mov qword ptr [rsp + 32 + SB_cap], 0
    mov rdi, rax
    lea rsi, [rsp + 32]
    call config_read_file
    test eax, eax
    jz .Ldcl_freepath
    mov rdi, [rsp + 32 + SB_ptr]
    mov [rsp + 64], rdi         # cursor
    add rdi, [rsp + 32 + SB_len]
    mov [rsp + 72], rdi         # end
.Ldcl_line:
    mov rax, [rsp + 64]
    cmp rax, [rsp + 72]
    jae .Ldcl_done
    mov rcx, rax
.Ldcl_findnl:
    cmp rcx, [rsp + 72]
    jae .Ldcl_have
    cmp byte ptr [rcx], 10
    je .Ldcl_have
    inc rcx
    jmp .Ldcl_findnl
.Ldcl_have:
    mov [rsp + 80], rcx         # line end
    mov rdi, [rsp + 64]
    mov rsi, rcx
    sub rsi, rdi
    test rsi, rsi
    jz .Ldcl_next
    call json_parse
    test rax, rax
    jz .Ldcl_next
    mov rbx, rax
    mov rdi, rbx
    lea rsi, [rip + .Lk_provider]
    call json_get_cstr
    test rax, rax
    jz .Ldcl_next
    mov rdi, rax
    mov rsi, [rsp]
    call disc_streq
    test eax, eax
    jz .Ldcl_next
    mov rax, [rsp + 8]
    test rax, rax
    jz .Ldcl_basedone
    mov rdi, rbx
    lea rsi, [rip + .Lk_base]
    call json_get_cstr
    test rax, rax
    jz .Ldcl_basedone
    cmp byte ptr [rax], 0
    je .Ldcl_basedone
    mov rdi, rax
    mov rsi, [rsp + 8]
    call disc_streq
    test eax, eax
    jz .Ldcl_next
.Ldcl_basedone:
    mov rdi, rbx
    lea rsi, [rip + .Lk_fetched]
    xor edx, edx
    call json_get_u64
    cmp rax, [rip + d_cache_fetched]
    jbe .Ldcl_next
    mov [rip + d_cache_fetched], rax
    mov rdi, rbx
    lea rsi, [rip + .Lk_count]
    xor edx, edx
    call json_get_u64
    mov [rip + d_cache_count], rax
.Ldcl_next:
    mov rax, [rsp + 80]
    cmp rax, [rsp + 72]
    jae .Ldcl_setend
    inc rax
.Ldcl_setend:
    mov [rsp + 64], rax
    jmp .Ldcl_line
.Ldcl_done:
    mov rax, [rip + d_cache_count]
    mov rdx, [rsp + 16]
    test rdx, rdx
    jz 1f
    mov rcx, [rip + d_cache_fetched]
    mov [rdx], rcx
1:  mov [rsp + 88], rax
    lea rdi, [rsp + 32]
    call sb_free
.Ldcl_freepath:
    mov rdi, [rsp + 24]
    call mem_free
    mov rax, [rsp + 88]
    EPILOGUE
.Ldcl_zero:
    xor eax, eax
    EPILOGUE

# disc_cache_save(provider rdi, base rsi|0, count rdx): append one JSONL entry.
# Best effort: any failure is ignored (discovery must never become fatal).
FN disc_cache_save
    PROLOGUE 96
    mov [rsp], rdi
    mov [rsp + 8], rsi
    mov [rsp + 16], rdx
    call disc_cache_path
    test rax, rax
    jz .Ldcs_done
    mov [rsp + 24], rax
    mov qword ptr [rsp + 32 + SB_ptr], 0
    mov qword ptr [rsp + 32 + SB_len], 0
    mov qword ptr [rsp + 32 + SB_cap], 0
    lea rdi, [rsp + 32]
    call jsonw_obj
    lea rdi, [rsp + 32]
    lea rsi, [rip + .Lk_provider]
    call jsonw_key
    lea rdi, [rsp + 32]
    mov rsi, [rsp]
    call jsonw_str_cstr
    lea rdi, [rsp + 32]
    lea rsi, [rip + .Lk_base]
    call jsonw_key
    mov rsi, [rsp + 8]
    test rsi, rsi
    jnz 1f
    lea rsi, [rip + .Lempty]
1:  lea rdi, [rsp + 32]
    call jsonw_str_cstr
    lea rdi, [rsp + 32]
    lea rsi, [rip + .Lk_fetched]
    call jsonw_key
    mov edi, CLOCK_REALTIME
    call os_now_ns
    xor edx, edx
    mov ecx, 1000000
    div rcx
    mov rsi, rax
    lea rdi, [rsp + 32]
    call jsonw_u64
    lea rdi, [rsp + 32]
    lea rsi, [rip + .Lk_count]
    call jsonw_key
    mov rsi, [rsp + 16]
    lea rdi, [rsp + 32]
    call jsonw_u64
    lea rdi, [rsp + 32]
    call jsonw_obj_end
    lea rdi, [rsp + 32]
    mov esi, 10
    call sb_push_byte
    mov rdi, [rsp + 24]
    mov esi, O_WRONLY | O_CREAT | O_APPEND
    mov edx, 0600
    call os_open
    test rax, rax
    js .Ldcs_free
    mov [rsp + 80], rax
    mov edi, eax
    mov rsi, [rsp + 32 + SB_ptr]
    mov rdx, [rsp + 32 + SB_len]
    call write_all
    mov edi, [rsp + 80]
    call os_close
.Ldcs_free:
    lea rdi, [rsp + 32]
    call sb_free
    mov rdi, [rsp + 24]
    call mem_free
.Ldcs_done:
    EPILOGUE

# disc_eff_base(provider rdi) -> rax base | 0, rdx owned base to free | 0
# Same precedence discover_models uses: g_discover_base > config base > catalog.
FN disc_eff_base
    PROLOGUE 16
    mov r12, rdi
    mov rax, [rip + g_discover_base]
    test rax, rax
    jnz .Ldeb_borrow
    mov rdi, r12
    call config_provider_base
    test rax, rax
    jz .Ldeb_cat
    mov rdx, rax
    EPILOGUE
.Ldeb_cat:
    mov rdi, r12
    call catalog_default
    test rax, rax
    jz .Ldeb_none
    mov rax, [rax + MD_base]
    test rax, rax
    jz .Ldeb_none
    xor edx, edx
    EPILOGUE
.Ldeb_borrow:
    xor edx, edx
    EPILOGUE
.Ldeb_none:
    xor eax, eax
    xor edx, edx
    EPILOGUE

# discover_models_cached(provider rdi, verbose esi, force edx) -> count | -errno
# Reuses a fresh (< 24 h) cache unless forced; --offline never probes and a
# probe failure falls back to the cached count, so the caller is never forced
# to treat a miss as fatal.  discover_models itself still writes models.jsonc.
FN discover_models_cached
    PROLOGUE 64
    mov [rsp], rdi
    mov [rsp + 8], rsi
    mov [rsp + 16], rdx
    call disc_eff_base
    mov [rsp + 24], rax         # base
    mov [rsp + 32], rdx         # owned base
    mov rdi, [rsp]
    mov rsi, [rsp + 24]
    lea rdx, [rsp + 40]
    call disc_cache_load
    mov [rsp + 48], rax         # cached count
    cmp qword ptr [rsp + 16], 0
    jne .Ldmc_offline          # forced: skip the fresh-cache return
    test rax, rax
    jle .Ldmc_offline
    mov rcx, [rsp + 40]
    test rcx, rcx
    jz .Ldmc_offline
    mov edi, CLOCK_REALTIME
    call os_now_ns
    xor edx, edx
    mov ecx, 1000000
    div rcx
    sub rax, [rsp + 40]
    cmp rax, DISC_TTL_MS
    jb .Ldmc_cached
.Ldmc_offline:
    cmp qword ptr [rip + g_offline], 0
    jne .Ldmc_cached
    mov rdi, [rsp]
    mov esi, [rsp + 8]
    call discover_models
    test rax, rax
    js .Ldmc_cached
    mov [rsp + 56], rax
    mov rdi, [rsp]
    mov rsi, [rsp + 24]
    mov rdx, rax
    call disc_cache_save
    mov rax, [rsp + 56]
    jmp .Ldmc_free
.Ldmc_cached:
    mov rax, [rsp + 48]
.Ldmc_free:
    mov [rsp + 56], rax
    mov rdi, [rsp + 32]
    call mem_free
    mov rax, [rsp + 56]
    EPILOGUE
