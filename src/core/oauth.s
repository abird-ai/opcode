.include "opcode.inc"
.include "core/core.inc"
# Socket option constants (SOL_SOCKET / SO_REUSEADDR / IPPROTO_IPV6 / IPV6_V6ONLY)
.include "plat/plat.inc"
# oauth.s: OAuth 2.0 authorization-code + PKCE login for subscription providers.
#
# Public API (M6):
#   g_oauth_auth_url   cstr   authorize endpoint  (CLI --oauth-auth-url)
#   g_oauth_token_url  cstr   token endpoint      (CLI --oauth-token-url)
#   g_oauth_client_id  cstr   client id           (CLI --oauth-client-id)
#   g_oauth_scope      cstr   optional scope      (CLI --oauth-scope)
#   g_oauth_no_browser quad   != 0 -> print the authorize URL instead of
#                             spawning xdg-open (CLI --no-browser / tests)
#   oauth_login(provider cstr)      -> 0 | -errno
#   oauth_login_manual(provider cstr) -> 0 | -errno
#                             paste-code login, no loopback/browser (--manual)
#   oauth_logout(provider cstr)     -> 0 | -errno
#                             removes the provider's oauth credential and its
#                             stored api_key (provider object dropped when empty)
#   oauth_access_token(provider)    -> mem_alloc'd cstr | 0
#   oauth_last (quad)               1 when the last oauth_access_token() hit
#   oauth_sha256(out32, ptr, len)   SHA-256 (exposed for tests)
#
# When a global is 0 the per-provider default below is used. The defaults are
# best-effort real endpoints so the command is usable, but real deployments
# should configure them through the CLI flags; the integrator wires those.
#
# The flow: PKCE verifier/challenge, a dual-stack loopback HTTP server (one
# AF_INET6 socket bound to :: with IPV6_V6ONLY off, so both ::1 and 127.0.0.1
# answer; AF_INET 127.0.0.1 fallback when the platform shim cannot do IPv6),
# xdg-open (or a printed URL), a token POST through
# the same connect/TLS path as app/fetch.s, and an atomic merge into
# <config dir>/auth.jsonc (mode 0600):
#   {"<provider>":{"oauth":{"access_token":..., "refresh_token":...,
#                           "expires_at":<unix ms>, "account_id":...}}}
# The accept loop serves one request per connection and survives browser
# noise (preconnect/EOF, /favicon.ico, HEAD, torn requests); it ends on the
# callback path with a matching state or the wait budget, which defaults to
# OAUTH_WAIT_NS and is overridable via OPCODE_OAUTH_WAIT_MS for tests.

.include "net/net.inc"
# HC transport state and HCR_* error policy flags
.include "wire/http_client.inc"
# Url struct layout: single-sourced in src/wire/url.inc (see src/wire/API.md)
.include "wire/url.inc"


.equ SOCK_STREAM,    1
.equ SOCK_NONBLOCK,  0x800
.equ SOCK_CLOEXEC,   0x80000

.equ OAUTH_WAIT_NS,  300000000000      # loopback accept/read budget (5 min)
.equ OAUTH_CB_NS,    30000000000       # one browser connection's read budget (30 s)
.equ OAUTH_HTTP_NS,  30000000000       # token exchange budget (30 s)
.equ OAUTH_SKEW_MS,  300000             # treat tokens expiring within 5 min as dead
.equ OAUTH_EADDRINUSE, 98               # linux EADDRINUSE
.equ OAUTH_BODY_MAX, 1048576           # token-response body cap (1 MiB)

.ifndef E2BIG
.equ E2BIG, 7
.endif

# Loopback-only callback server: bind ::1 (AF_INET6, IPV6_V6ONLY on) and
# 127.0.0.1 (AF_INET) on the same port, so a browser resolving localhost to
# either loopback answer reaches us. No wildcard address is ever bound. Both
# listeners share the same port so one redirect URI covers both. Platforms
# whose shim cannot do AF_INET6 fall back to an AF_INET 127.0.0.1 socket (see
# .Lloopback_open).
.equ AF_INET6,       10
.equ OAUTH_READ_BUF, 8192
.equ OAUTH_RECV_BUF, 65536
.equ RESP_SIZE,      1200

# oauth_login frame
.equ OL_VER,       0      # 48  base64url verifier (43)
.equ OL_CHAL,      48     # 48  base64url challenge (43)
.equ OL_STATE,     96     # 44  base64url state (Anthropic doubles as verifier)
.equ OL_DIGEST,    8656   # 32  relocated clear of the 44-byte state slot
.equ OL_FORM,      160    # 24  SB token request form body
.equ OL_BODY,      184    # 24  SB token response body
.equ OL_REQBUF,    208    # 8192 -> 8400
.equ OL_OUT,       8400   # 32  code ptr/len, err ptr/len
.equ OL_LFD,       8432
.equ OL_CFD,       8440
.equ OL_PORT,      8448
.equ OL_REDIR,     8456
.equ OL_AURL,      8464
.equ OL_ACCESS,    8472
.equ OL_ACC_LEN,   8480
.equ OL_REFRESH,   8488
.equ OL_REF_LEN,   8496
.equ OL_ACCOUNT,   8504
.equ OL_ACCT_LEN,  8512
.equ OL_ROOT,      8520
.equ OL_EXPIRES,   8528
.equ OL_AUTHURL,   8536
.equ OL_TOKENURL,  8544
.equ OL_CLIENTID,  8552
.equ OL_SCOPE,     8560
.equ OL_XTRA,      8568   # extra authorize query params (rodata)
.equ OL_SLEN,      8576   # expected state length
.equ OL_BPORT,     8584   # requested loopback port (0 = ephemeral)
.equ OL_PROF,      8592   # provider profile (rodata)
.equ OL_FLAGS,     8600   # profile OPF_* flags
.equ OL_HOST,      8608   # redirect host prefix
.equ OL_PATH,      8616   # redirect path
.equ OL_PATHLEN,   8624   # redirect path length
.equ OL_WAITNS,    8632   # overall callback wait budget (ns)
.equ OL_DUAL,      8640   # 1 -> bind the loopback dual-stack (localhost)
.equ OL_LFD2,      8648   # second loopback listener (-1 when only one bound)
.equ OL_MANUAL,    8688   # 1 -> --manual paste flow (no loopback listener)
.equ OL_PCODE,     8696   # pasted authorization code (ptr into OL_REQBUF)
.equ OL_PCODELEN,  8704
.equ OL_PSTATE,    8712   # pasted state, when the redirect URL carried one
.equ OL_PSTATELEN, 8720
.equ OL_FRAME,     8736

# oauth_logout / oauth_access_token frame (shared)
.equ OG_OLD,       0      # 24 SB
.equ OG_OUT,       24     # 24 SB
.equ OG_PATH,      56
.equ OG_ROOT,      64
.equ OG_I,         72
.equ OG_KEY,       80
.equ OG_VAL,       88
.equ OG_PROV,      96
.equ OG_TOK,       104
.equ OG_TOKLEN,    112
.equ OG_FRAME,     128

# .Lhttp_json_request frame (one HC carries url/host/authority/fd/conn)
.equ HJ_HC,        0      # HC_SIZE (1176)
.equ HJ_REQ,       1176   # 24
.equ HJ_RESP,      1200   # 1200 -> 2400
.equ HJ_OUT,       2400
.equ HJ_RECBUF,    2408
.equ HJ_STATUS,    2416
.equ HJ_FRAME,     2432

.bss
.p2align 3
.globl g_oauth_auth_url, g_oauth_token_url, g_oauth_client_id, g_oauth_scope
.globl g_oauth_no_browser, oauth_last, oauth_present
g_oauth_auth_url:  .zero 8
g_oauth_token_url: .zero 8
g_oauth_client_id: .zero 8
g_oauth_scope:     .zero 8
g_oauth_no_browser: .zero 8
oauth_last:        .zero 8
oauth_present:     .zero 8   # 1 when the provider has a stored OAuth entry
oa_manual:         .zero 8   # 1 -> oauth_login runs the paste flow (--manual)
oa_body_overflow:  .zero 8   # 1 when the token body exceeded OAUTH_BODY_MAX

.section .rodata
.p2align 3
.Lname_openai:    .asciz "openai"
.Lname_anthropic: .asciz "anthropic"
# Defaults: official subscription-provider endpoints. Overridden by g_oauth_*
# (set by the CLI flags / tests).
.Ldef_auth_anthropic:   .asciz "https://claude.ai/oauth/authorize"
.Ldef_token_anthropic:  .asciz "https://platform.claude.com/v1/oauth/token"
.Ldef_client_anthropic: .asciz "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
.Ldef_scope_anthropic:  .asciz "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
.Ldef_auth_openai:      .asciz "https://auth.openai.com/oauth/authorize"
.Ldef_token_openai:     .asciz "https://auth.openai.com/oauth/token"
.Ldef_client_openai:    .asciz "app_EMoamEEZ73f0CkXaXp7hrann"
.Ldef_scope_openai:     .asciz "openid profile email offline_access"
.Lredir_localhost:      .asciz "http://localhost:"
.Lredir_localhost_np:   .asciz "http://localhost"
.Lredir_default:        .asciz "http://127.0.0.1:"
.Lpath_callback:        .asciz "/callback"
.Lpath_auth_callback:   .asciz "/auth/callback"
# Extra query parameters the official clients send.
.Lxtra_openai:          .asciz "id_token_add_organizations=true&codex_cli_simplified_flow=true&originator=opcode"
.Lxtra_anthropic:       .asciz "code=true"
.Lbusy_openai:    .asciz "cannot bind port 1455: address already in use (OpenAI requires this fixed redirect port); free the port and retry"
.Lbusy_anthropic: .asciz "cannot bind port 53692: address already in use (Anthropic requires this fixed redirect port); free the port and retry"

# Provider profile: endpoints, fixed loopback redirect and authorize extras.
# P_PORT 0 means an ephemeral port (custom providers / overridden auth URLs).
.equ P_AUTH,  0
.equ P_TOKEN, 8
.equ P_CLIENT, 16
.equ P_SCOPE, 24
.equ P_HOST,  32
.equ P_PATH,  40
.equ P_EXTRA, 48
.equ P_PORT,  56
.equ P_FLAGS, 60
.equ P_BUSY,  64
.equ OPF_JSON, 1
.equ OPF_STATE_VERIFIER, 2
.p2align 3
.Lprof_anthropic:
    .quad .Ldef_auth_anthropic, .Ldef_token_anthropic
    .quad .Ldef_client_anthropic, .Ldef_scope_anthropic
    .quad .Lredir_localhost, .Lpath_callback, .Lxtra_anthropic
    .long 53692, OPF_JSON | OPF_STATE_VERIFIER
    .quad .Lbusy_anthropic
.Lprof_openai:
    .quad .Ldef_auth_openai, .Ldef_token_openai
    .quad .Ldef_client_openai, .Ldef_scope_openai
    .quad .Lredir_localhost, .Lpath_auth_callback, .Lxtra_openai
    .long 1455, 0
    .quad .Lbusy_openai
.Lprof_generic:
    .quad .Ldef_auth_anthropic, .Ldef_token_anthropic
    .quad .Ldef_client_anthropic, .Ldef_scope_anthropic
    .quad .Lredir_default, .Lpath_callback, 0
    .long 0, 0
    .quad 0
.p2align 3
.Lglob_table:
    .quad g_oauth_auth_url, g_oauth_token_url, g_oauth_client_id, g_oauth_scope
.Ldef_table:
    .quad .Ldef_auth_anthropic, .Ldef_token_anthropic
    .quad .Ldef_client_anthropic, .Ldef_scope_anthropic
    .quad .Ldef_auth_openai, .Ldef_token_openai
    .quad .Ldef_client_openai, .Ldef_scope_openai

.Lhttp_scheme:  .asciz "http://"
.Lhttps_scheme: .asciz "https://"
.Lauth_jsonc:   .asciz "/auth.jsonc"
.Ltmp_suffix:   .asciz ".tmp"
.Lhdr_ct:       .asciz "content-type"
.Lm_post:       .asciz "POST"
.Lct_form:      .asciz "application/x-www-form-urlencoded"
.Lct_json:      .asciz "application/json"
.Lhdr_accept:   .asciz "accept"
.Lxdg_open:     .asciz "xdg-open"
.Lkey_access:   .asciz "access_token"
.Lkey_refresh:  .asciz "refresh_token"
.Lkey_exp:      .asciz "expires_at"
.Lkey_acct:     .asciz "account_id"
.Lkey_oauth:    .asciz "oauth"
.Lkey_api:      .asciz "api_key"
.Lkey_account:  .asciz "account"
.Lkey_uuid:     .asciz "uuid"
.Lkey_expi:     .asciz "expires_in"
.Lqs_error:     .asciz "error"
.Lqs_state:     .asciz "state"
.Lqs_code:      .asciz "code"
.Lgr_type:      .asciz "grant_type"
.Lv_authcode:   .asciz "authorization_code"
.Lgr_code:      .asciz "code"
.Lgr_redirect:  .asciz "redirect_uri"
.Lgr_client:    .asciz "client_id"
.Lgr_verifier:  .asciz "code_verifier"
.Lq_response_type:     .asciz "response_type"
.Lq_client_id:         .asciz "client_id"
.Lq_redirect_uri:      .asciz "redirect_uri"
.Lq_state:             .asciz "state"
.Lq_challenge:         .asciz "code_challenge"
.Lq_challenge_method:  .asciz "code_challenge_method"
.Lq_scope:             .asciz "scope"
.Lv_code:              .asciz "code"
.Lv_s256:              .asciz "S256"
.Lb64tab: .ascii "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
.Lhexdig: .ascii "0123456789ABCDEF"
.Lnl:     .byte 10
.Lresp200:
    .ascii "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
    .ascii "Connection: close\r\nContent-Length: 65\r\n\r\n"
    .ascii "<html><body>Login complete. You can close this tab.</body></html>"
.Lresp200_end:
.equ RESP200_LEN, .Lresp200_end - .Lresp200
.Lresp400state:
    .ascii "HTTP/1.1 400 Bad Request\r\nContent-Type: text/html; charset=utf-8\r\n"
    .ascii "Connection: close\r\nContent-Length: 64\r\n\r\n"
    .ascii "<html><body>Bad Request: missing or invalid state.</body></html>"
.Lresp400state_end:
.equ RESP400STATE_LEN, .Lresp400state_end - .Lresp400state
.Lresp400nocode:
    .ascii "HTTP/1.1 400 Bad Request\r\nContent-Type: text/html; charset=utf-8\r\n"
    .ascii "Connection: close\r\nContent-Length: 66\r\n\r\n"
    .ascii "<html><body>Bad Request: missing authorization code.</body></html>"
.Lresp400nocode_end:
.equ RESP400NOCODE_LEN, .Lresp400nocode_end - .Lresp400nocode
.Lresp400req:
    .ascii "HTTP/1.1 400 Bad Request\r\nContent-Type: text/html; charset=utf-8\r\n"
    .ascii "Connection: close\r\nContent-Length: 57\r\n\r\n"
    .ascii "<html><body>Bad Request: malformed request.</body></html>"
.Lresp400req_end:
.equ RESP400REQ_LEN, .Lresp400req_end - .Lresp400req
.Lresp404:
    .ascii "HTTP/1.1 404 Not Found\r\nContent-Type: text/html; charset=utf-8\r\n"
    .ascii "Connection: close\r\nContent-Length: 35\r\n\r\n"
    .ascii "<html><body>Not Found</body></html>"
.Lresp404_end:
.equ RESP404_LEN, .Lresp404_end - .Lresp404
.Lo_logged_in:  .asciz "logged in to "
.Lo_logged_out: .asciz "logged out of "
.Lo_prefix:     .asciz "opcode: oauth: "
.Lo_nomem:      .asciz "out of memory"
.Lo_nocode:     .asciz "authorization code missing"
.Lo_badresp:    .asciz "invalid token response"
.Lo_denied:     .asciz "authorization denied"
.Lo_tokfail:    .asciz "token endpoint returned status "
.Lo_timeout:    .asciz "timed out waiting for the browser callback"
.Lo_paste_prompt:  .asciz "Paste the authorization code (or the full redirect URL from the browser's address bar): "
.Lo_paste_nostate: .asciz "the pasted code is missing its state; paste the full redirect URL"
.Lo_state_mismatch: .asciz "oauth state mismatch"
.Lenv_wait_ms:  .asciz "OPCODE_OAUTH_WAIT_MS"
.p2align 3
.Lhinit:
    .long 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
    .long 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
.Lk256:
    .long 0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5
    .long 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5
    .long 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3
    .long 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174
    .long 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc
    .long 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da
    .long 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7
    .long 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967
    .long 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13
    .long 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85
    .long 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3
    .long 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070
    .long 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5
    .long 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3
    .long 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208
    .long 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2

.text

# ------------------------------------------------------------------ printing
# oa_puts(cstr) -> stdout
oa_puts:
    PROLOGUE 0
    mov rbx, rdi
    call strlen
    mov rdx, rax
    mov rsi, rbx
    mov edi, 1
    call write_all
    EPILOGUE

# oa_eprintln(cstr) -> stderr + newline
oa_eprintln:
    PROLOGUE 0
    mov rbx, rdi
    call strlen
    mov rdx, rax
    mov rsi, rbx
    mov edi, 2
    call write_all
    mov edi, 2
    lea rsi, [rip + .Lnl]
    mov edx, 1
    call write_all
    EPILOGUE

# oa_eputsn(ptr, len) -> stderr
oa_eputsn:
    mov rdx, rsi
    mov rsi, rdi
    mov edi, 2
    jmp write_all

# oa_eputs(cstr) -> stderr, no newline
oa_eputs:
    PROLOGUE 0
    mov rbx, rdi
    call strlen
    mov rdi, rbx
    mov rsi, rax
    call oa_eputsn
    EPILOGUE

# oa_err(cstr): "opcode: oauth: <msg>\n" on stderr
oa_err:
    PROLOGUE 0
    mov rbx, rdi
    lea rdi, [rip + .Lo_prefix]
    call oa_eputs
    mov rdi, rbx
    call oa_eputs
    mov edi, 2
    lea rsi, [rip + .Lnl]
    mov edx, 1
    call write_all
    EPILOGUE

# oa_eputs_safe(ptr, len) -> stderr. Like oa_eputsn, but any byte outside
# printable ASCII is replaced with '?' so a hostile provider error value can
# never inject terminal control sequences into the user's stderr.
oa_eputs_safe:
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi
    xor eax, eax
    mov [rsp + SB_ptr], rax
    mov [rsp + SB_len], rax
    mov [rsp + SB_cap], rax
1:  test r12, r12
    jz 3f
    movzx eax, byte ptr [rbx]
    cmp al, 0x20
    jb 2f
    cmp al, 0x7e
    ja 2f
    mov esi, eax
    jmp 4f
2:  mov esi, '?'
4:  lea rdi, [rsp]
    call sb_push_byte
    inc rbx
    dec r12
    jmp 1b
3:  mov edi, 2
    mov rsi, [rsp + SB_ptr]
    mov rdx, [rsp + SB_len]
    call write_all
    lea rdi, [rsp]
    call sb_free
    EPILOGUE

# .Lurl_safe(ptr cstr) -> 1|0: a plausible http(s) URL with no control or
# space bytes. Checked before a URL is handed to xdg-open or echoed, so a
# hostile --oauth-auth-url cannot smuggle terminal escapes or an argv payload
# into the browser helper.
.Lurl_safe:
    PROLOGUE 0
    mov rbx, rdi
    mov rdi, rbx
    call strlen
    mov r12, rax
    cmp r12, 7
    jb 9f
    mov rdi, rbx
    lea rsi, [rip + .Lhttp_scheme]
    mov edx, 7
    call memeq
    test eax, eax
    jnz 1f
    cmp r12, 8
    jb 9f
    mov rdi, rbx
    lea rsi, [rip + .Lhttps_scheme]
    mov edx, 8
    call memeq
    test eax, eax
    jz 9f
    add rbx, 8
    jmp 2f
1:  add rbx, 7
2:  movzx eax, byte ptr [rbx]
    test al, al
    jz 3f
    cmp al, 0x20
    jbe 9f
    cmp al, 0x7f
    je 9f
    inc rbx
    jmp 2b
3:  mov eax, 1
    EPILOGUE
9:  xor eax, eax
    EPILOGUE

# .Loenv_get(name cstr) -> cstr | 0: case-sensitive g_envp walk (copy of the
# auth.s helper; the env override is test-only, the production default stays).
.Loenv_get:
    PROLOGUE 0
    mov r8, [rip + g_envp]
    test r8, r8
    jz .Loeg_none
    mov r9, rdi
.Loeg_next:
    mov rsi, [r8]
    test rsi, rsi
    jz .Loeg_none
    mov rdi, r9
    mov rdx, rsi
.Loeg_cmp:
    mov al, [rdi]
    test al, al
    jz .Loeg_name_end
    cmp al, [rdx]
    jne .Loeg_skip
    inc rdi
    inc rdx
    jmp .Loeg_cmp
.Loeg_name_end:
    cmp byte ptr [rdx], '='
    jne .Loeg_skip
    lea rax, [rdx + 1]
    EPILOGUE
.Loeg_skip:
    add r8, 8
    jmp .Loeg_next
.Loeg_none:
    xor eax, eax
    EPILOGUE

# .Loauth_wait_ns() -> overall callback wait in ns. OPCODE_OAUTH_WAIT_MS
# overrides the default so tests can exercise the timeout without waiting 5 min.
.Loauth_wait_ns:
    PROLOGUE 0
    lea rdi, [rip + .Lenv_wait_ms]
    call .Loenv_get
    test rax, rax
    jz 1f
    mov rbx, rax
    mov rdi, rax
    call strlen
    mov rdi, rbx
    mov rsi, rax
    call parse_u64
    test rdx, rdx
    jz 1f
    test rax, rax
    jz 1f
    mov rcx, 1000000
    imul rax, rcx
    EPILOGUE
1:  mov rax, OAUTH_WAIT_NS
    EPILOGUE

# ------------------------------------------------------------------ time/poll
# .Lnow_ms() -> unix milliseconds
.Lnow_ms:
    PROLOGUE 0
    mov edi, CLOCK_REALTIME
    call os_now_ns
    mov rcx, 1000000
    xor edx, edx
    div rcx
    EPILOGUE

# oa_wait_io2(fda, eva, fdb, evb, deadline_ns) -> eax bitmask: 1 = fda ready,
# 2 = fdb ready (3 = both), 0 = poll returned nothing (retry), -errno.
# The loopback request reader polls the accepted connection together with the
# listener: when a second (real navigation) connection arrives while a
# preconnect sits idle, the caller drops the idle connection instead of
# blocking the callback behind it.
oa_wait_io2:
    PROLOGUE 32
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov r15d, ecx
    mov [rsp + 16], r8
1:  mov edi, CLOCK_MONOTONIC
    call os_now_ns
    mov rcx, [rsp + 16]
    sub rcx, rax
    jbe 3f
    mov rax, rcx
    xor edx, edx
    mov ecx, 1000000
    div rcx
    mov dword ptr [rsp], r12d
    mov word ptr [rsp + 4], r13w
    mov word ptr [rsp + 6], 0
    mov dword ptr [rsp + 8], r14d
    mov word ptr [rsp + 12], r15w
    mov word ptr [rsp + 14], 0
    mov rdi, rsp
    mov esi, 2
    mov rdx, rax
    call os_poll
    test rax, rax
    js 2f
    jz 1b
    xor eax, eax
    cmp word ptr [rsp + 6], 0
    je 4f
    or eax, 1
4:  cmp word ptr [rsp + 14], 0
    je 5f
    or eax, 2
5:  EPILOGUE
2:  EPILOGUE
3:  mov rax, -ETIMEDOUT
    EPILOGUE

# ------------------------------------------------------------------ base64url
# .Lb64url(out, in, len) -> out length; no padding, not NUL-terminated (leaf)
.Lb64url:
    lea r10, [rip + .Lb64tab]
    xor r8d, r8d                # out
    xor ecx, ecx                # in
.Lb64_loop:
    mov rax, rdx
    sub rax, rcx
    cmp rax, 3
    jb .Lb64_tail
    movzx eax, byte ptr [rsi + rcx]
    shl eax, 16
    movzx r9d, byte ptr [rsi + rcx + 1]
    shl r9d, 8
    or eax, r9d
    movzx r9d, byte ptr [rsi + rcx + 2]
    or eax, r9d
    mov r9d, eax
    shr r9d, 18
    mov r9b, [r10 + r9]
    mov [rdi + r8], r9b
    mov r9d, eax
    shr r9d, 12
    and r9d, 63
    mov r9b, [r10 + r9]
    mov [rdi + r8 + 1], r9b
    mov r9d, eax
    shr r9d, 6
    and r9d, 63
    mov r9b, [r10 + r9]
    mov [rdi + r8 + 2], r9b
    and eax, 63
    mov al, [r10 + rax]
    mov [rdi + r8 + 3], al
    add r8, 4
    add rcx, 3
    jmp .Lb64_loop
.Lb64_tail:
    test rax, rax
    jz .Lb64_done
    movzx eax, byte ptr [rsi + rcx]
    shl eax, 16
    # rdx-rcx is 1 or 2 here
    mov r9, rdx
    sub r9, rcx
    cmp r9, 1
    je .Lb64_one
    movzx r9d, byte ptr [rsi + rcx + 1]
    shl r9d, 8
    or eax, r9d
    mov r9d, eax
    shr r9d, 18
    mov r9b, [r10 + r9]
    mov [rdi + r8], r9b
    mov r9d, eax
    shr r9d, 12
    and r9d, 63
    mov r9b, [r10 + r9]
    mov [rdi + r8 + 1], r9b
    mov r9d, eax
    shr r9d, 6
    and r9d, 63
    mov r9b, [r10 + r9]
    mov [rdi + r8 + 2], r9b
    add r8, 3
    jmp .Lb64_done
.Lb64_one:
    mov r9d, eax
    shr r9d, 18
    mov r9b, [r10 + r9]
    mov [rdi + r8], r9b
    mov r9d, eax
    shr r9d, 12
    and r9d, 63
    mov r9b, [r10 + r9]
    mov [rdi + r8 + 1], r9b
    add r8, 2
.Lb64_done:
    mov rax, r8
    ret

# .Lrand_b64(out, n) -> base64url of n random bytes, NUL-terminated
.Lrand_b64:
    PROLOGUE 32
    mov rbx, rdi
    mov r12d, esi
    mov rdi, rsp
    mov esi, r12d
    call os_random
    test rax, rax
    js .Lrb_out
    mov rdi, rbx
    mov rsi, rsp
    mov edx, r12d
    call .Lb64url
    mov byte ptr [rbx + rax], 0
.Lrb_out:
    EPILOGUE

# ------------------------------------------------------------------ SHA-256
# oauth_sha256(out32, ptr, len): exposed for the test harness (and PKCE).
FN oauth_sha256
    PROLOGUE 160
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rdx
    lea rsi, [rip + .Lhinit]
    mov rdi, rsp
    mov ecx, 8
    rep movsd
.Lsh_full:
    cmp r13, 64
    jb .Lsh_final
    mov rdi, rsp
    mov rsi, r12
    call .Lsha256_block
    add r12, 64
    sub r13, 64
    jmp .Lsh_full
.Lsh_final:
    lea r15, [rsp + 32]
    mov rdi, r15
    mov rsi, r12
    mov rdx, r13
    call memcpy
    mov byte ptr [r15 + r13], 0x80
    cmp r13, 56
    jae .Lsh_two
    lea rdi, [r15 + r13 + 1]
    xor esi, esi
    mov rdx, 56
    sub rdx, r13
    dec rdx
    call memset
    jmp .Lsh_len
.Lsh_two:
    lea rdi, [r15 + r13 + 1]
    xor esi, esi
    mov rdx, 64
    sub rdx, r13
    dec rdx
    call memset
    mov rdi, rsp
    mov rsi, r15
    call .Lsha256_block
    mov rdi, r15
    xor esi, esi
    mov edx, 56
    call memset
.Lsh_len:
    lea rax, [r14*8]
    bswap rax
    mov [r15 + 56], rax
    mov rdi, rsp
    mov rsi, r15
    call .Lsha256_block
    xor ecx, ecx
1:  mov eax, [rsp + rcx*4]
    bswap eax
    mov [rbx + rcx*4], eax
    inc ecx
    cmp ecx, 8
    jb 1b
    EPILOGUE

# .Lsha256_block(state /*8 dwords*/, block /*64 bytes*/)
.Lsha256_block:
    PROLOGUE 320
    mov rbx, rdi
    mov r12, rsi
    xor ecx, ecx
.Lsb_load:
    mov eax, [r12 + rcx*4]
    bswap eax
    mov [rsp + 32 + rcx*4], eax
    inc ecx
    cmp ecx, 16
    jb .Lsb_load
.Lsb_sched:
    cmp ecx, 64
    jae .Lsb_rounds
    mov eax, [rsp + 32 + rcx*4 - 8]
    mov edx, eax
    ror edx, 17
    mov esi, eax
    ror esi, 19
    xor edx, esi
    shr eax, 10
    xor edx, eax
    mov eax, [rsp + 32 + rcx*4 - 60]
    mov esi, eax
    ror esi, 7
    mov edi, eax
    ror edi, 18
    xor esi, edi
    shr eax, 3
    xor esi, eax
    add edx, esi
    add edx, [rsp + 32 + rcx*4 - 28]
    add edx, [rsp + 32 + rcx*4 - 64]
    mov [rsp + 32 + rcx*4], edx
    inc ecx
    jmp .Lsb_sched
.Lsb_rounds:
    xor ecx, ecx
.Lsb_init:
    mov eax, [rbx + rcx*4]
    mov [rsp + rcx*4], eax
    inc ecx
    cmp ecx, 8
    jb .Lsb_init
    xor r13d, r13d
    lea r12, [rip + .Lk256]
.Lsb_round:
    mov eax, [rsp + 16]
    mov edx, eax
    ror edx, 6
    mov esi, eax
    ror esi, 11
    xor edx, esi
    mov esi, eax
    ror esi, 25
    xor edx, esi
    mov esi, [rsp + 20]
    and esi, eax
    not eax
    and eax, [rsp + 24]
    xor esi, eax
    add edx, esi
    add edx, [rsp + 28]
    add edx, [r12 + r13*4]
    add edx, [rsp + 32 + r13*4]
    mov eax, [rsp + 0]
    mov esi, eax
    ror esi, 2
    mov edi, eax
    ror edi, 13
    xor esi, edi
    mov edi, eax
    ror edi, 22
    xor esi, edi
    mov edi, [rsp + 4]
    and edi, eax
    mov r8d, eax
    and r8d, [rsp + 8]
    xor edi, r8d
    mov r8d, [rsp + 4]
    and r8d, [rsp + 8]
    xor edi, r8d
    add esi, edi
    mov eax, [rsp + 12]
    add eax, edx
    add esi, edx
    mov r8d, [rsp + 24]
    mov [rsp + 28], r8d
    mov r8d, [rsp + 20]
    mov [rsp + 24], r8d
    mov r8d, [rsp + 16]
    mov [rsp + 20], r8d
    mov [rsp + 16], eax
    mov r8d, [rsp + 8]
    mov [rsp + 12], r8d
    mov r8d, [rsp + 4]
    mov [rsp + 8], r8d
    mov r8d, [rsp + 0]
    mov [rsp + 4], r8d
    mov [rsp + 0], esi
    inc r13d
    cmp r13d, 64
    jb .Lsb_round
    xor ecx, ecx
.Lsb_add:
    mov eax, [rsp + rcx*4]
    add [rbx + rcx*4], eax
    inc ecx
    cmp ecx, 8
    jb .Lsb_add
    EPILOGUE

# ------------------------------------------------------------------ config
# .Lprofile(provider) -> *profile; unknown providers get the generic profile
.Lprofile:
    PROLOGUE 0
    mov rbx, rdi
    call strlen
    mov r12, rax
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lname_openai]
    mov ecx, 6
    call str_eq
    test eax, eax
    jnz .Lpf_openai
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [rip + .Lname_anthropic]
    mov ecx, 9
    call str_eq
    test eax, eax
    jnz .Lpf_anthropic
    lea rax, [rip + .Lprof_generic]
    EPILOGUE
.Lpf_openai:
    lea rax, [rip + .Lprof_openai]
    EPILOGUE
.Lpf_anthropic:
    lea rax, [rip + .Lprof_anthropic]
    EPILOGUE

# .Lcfg(provider, which) -> cstr; which 0 auth 1 token 2 client 3 scope
.Lcfg:
    PROLOGUE 0
    mov rbx, rsi
    lea rax, [rip + .Lglob_table]
    mov rax, [rax + rbx*8]
    mov rax, [rax]
    test rax, rax
    jnz .Lcfg_out
    mov r12, rdi
    mov rdi, r12
    call strlen
    mov rdi, r12
    mov rsi, rax
    lea rdx, [rip + .Lname_openai]
    mov ecx, 6
    call str_eq
    test eax, eax
    jz 1f
    lea rax, [rip + .Ldef_table]
    add rax, 32
    jmp 2f
1:  lea rax, [rip + .Ldef_table]
2:  mov rax, [rax + rbx*8]
.Lcfg_out:
    EPILOGUE

# .Lauth_path() -> mem_alloc'd <config dir>/auth.jsonc | 0
.Lauth_path:
    PROLOGUE 0
    call config_user_dir
    test rax, rax
    jz 1f
    mov rdi, rax
    lea rsi, [rip + .Lauth_jsonc]
    call config_path_join
    EPILOGUE
1:  xor eax, eax
    EPILOGUE

# ------------------------------------------------------------------ json helpers
# .Ljson_dup(obj, key) -> mem_alloc'd cstr | 0
.Ljson_dup:
    PROLOGUE 0
    call json_get
    test rax, rax
    jz 1f
    mov rdi, rax
    call json_str
    test rax, rax
    jz 1f
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    EPILOGUE
1:  xor eax, eax
    EPILOGUE

# .Ljv_key_eq(jv, cstr) -> 1|0
.Ljv_key_eq:
    PROLOGUE 0
    mov rbx, rsi
    mov r12d, [rdi + JV_n]
    mov rdi, [rdi + JV_ptr]
    mov rsi, r12
    mov rdx, rbx
    call str_eq_cstr
    EPILOGUE

# .Ljsonw_key_jv(sb, jv)
.Ljsonw_key_jv:
    mov rax, rsi
    mov rsi, [rsi + JV_ptr]
    mov edx, [rax + JV_n]
    jmp jsonw_key_n

# .Ljsonw_jv(sb, jv): re-emit any parsed JSON value through jsonw
.Ljsonw_jv:
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    test r12, r12
    jz .Ljv_null
    mov eax, [r12 + JV_type]
    cmp eax, JT_OBJ
    je .Ljv_obj
    cmp eax, JT_ARR
    je .Ljv_arr
    cmp eax, JT_STR
    je .Ljv_str
    cmp eax, JT_NUM
    je .Ljv_num
    cmp eax, JT_TRUE
    je .Ljv_true
    cmp eax, JT_FALSE
    je .Ljv_false
.Ljv_null:
    mov rdi, rbx
    call jsonw_null
    EPILOGUE
.Ljv_str:
    mov rdi, rbx
    mov rsi, [r12 + JV_ptr]
    mov edx, [r12 + JV_n]
    call jsonw_str
    EPILOGUE
.Ljv_num:
    mov rdi, rbx
    mov rsi, [r12 + JV_ptr]
    mov edx, [r12 + JV_n]
    call jsonw_raw
    EPILOGUE
.Ljv_true:
    mov rdi, rbx
    mov esi, 1
    call jsonw_bool
    EPILOGUE
.Ljv_false:
    mov rdi, rbx
    xor esi, esi
    call jsonw_bool
    EPILOGUE
.Ljv_arr:
    mov rdi, rbx
    call jsonw_arr
    xor r13d, r13d
1:  cmp r13d, [r12 + JV_n]
    jae 2f
    mov rdi, r12
    mov esi, r13d
    call json_at
    mov rdi, rbx
    mov rsi, rax
    call .Ljsonw_jv
    inc r13d
    jmp 1b
2:  mov rdi, rbx
    call jsonw_arr_end
    EPILOGUE
.Ljv_obj:
    mov rdi, rbx
    call jsonw_obj
    xor r13d, r13d
1:  cmp r13d, [r12 + JV_n]
    jae 2f
    mov rax, [r12 + JV_ptr]
    mov rcx, r13
    shl rcx, 4
    mov r14, [rax + rcx]
    mov r15, [rax + rcx + 8]
    mov rdi, rbx
    mov rsi, r14
    call .Ljsonw_key_jv
    mov rdi, rbx
    mov rsi, r15
    call .Ljsonw_jv
    inc r13d
    jmp 1b
2:  mov rdi, rbx
    call jsonw_obj_end
    EPILOGUE

# ------------------------------------------------------------------ encoding
# .Lpctenc(sb, ptr, len): percent-encode form values
.Lpctenc:
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
1:  test r13, r13
    jz 9f
    movzx eax, byte ptr [r12]
    mov ecx, eax
    sub ecx, '0'
    cmp ecx, 9
    jbe 2f
    mov ecx, eax
    or ecx, 0x20
    sub ecx, 'a'
    cmp ecx, 25
    jbe 2f
    cmp al, '-'
    je 2f
    cmp al, '.'
    je 2f
    cmp al, '_'
    je 2f
    cmp al, '~'
    je 2f
    mov rdi, rbx
    mov esi, '%'
    call sb_push_byte
    movzx eax, byte ptr [r12]
    mov ecx, eax
    shr ecx, 4
    lea rdx, [rip + .Lhexdig]
    movzx ecx, byte ptr [rdx + rcx]
    mov rdi, rbx
    mov esi, ecx
    call sb_push_byte
    movzx eax, byte ptr [r12]
    and eax, 15
    lea rdx, [rip + .Lhexdig]
    movzx esi, byte ptr [rdx + rax]
    mov rdi, rbx
    call sb_push_byte
    jmp 3f
2:  mov rdi, rbx
    movzx esi, byte ptr [r12]
    call sb_push_byte
3:  inc r12
    dec r13
    jmp 1b
9:  EPILOGUE

# .Lform_kv(sb, key, val cstr): "key=<pct(val)>&"
.Lform_kv:
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, rbx
    mov rsi, r12
    call sb_push_cstr
    mov rdi, rbx
    mov esi, '='
    call sb_push_byte
    mov rdi, r13
    call strlen
    mov rdi, rbx
    mov rsi, r13
    mov rdx, rax
    call .Lpctenc
    mov rdi, rbx
    mov esi, '&'
    call sb_push_byte
    EPILOGUE

# .Lform_kv_n(sb, key, ptr, len)
.Lform_kv_n:
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov rdi, rbx
    mov rsi, r12
    call sb_push_cstr
    mov rdi, rbx
    mov esi, '='
    call sb_push_byte
    mov rdi, rbx
    mov rsi, r13
    mov rdx, r14
    call .Lpctenc
    mov rdi, rbx
    mov esi, '&'
    call sb_push_byte
    EPILOGUE

# .Lmk_redirect(host_prefix cstr, port edi, path cstr) -> mem_alloc'd cstr | 0
.Lmk_redirect:
    PROLOGUE 64
    mov r13, rdi
    mov r12d, esi
    mov r14, rdx
    xor eax, eax
    mov [rsp], rax
    mov [rsp + 8], rax
    mov [rsp + 16], rax
    lea rdi, [rsp]
    mov rsi, r13
    call sb_push_cstr
    lea rdi, [rsp + 32]
    mov esi, r12d
    call fmt_u64
    lea rdi, [rsp]
    lea rsi, [rsp + 32]
    mov rdx, rax
    call sb_push
    lea rdi, [rsp]
    mov rsi, r14
    call sb_push_cstr
    mov rdi, [rsp + SB_ptr]
    mov rsi, [rsp + SB_len]
    call mem_dup
    mov r12, rax
    lea rdi, [rsp]
    call sb_free
    mov rax, r12
    EPILOGUE

# .Lmk_redirect_np(host cstr, path cstr) -> mem_alloc'd cstr | 0
.Lmk_redirect_np:
    PROLOGUE 32
    mov r12, rdi
    mov r13, rsi
    xor eax, eax
    mov [rsp], rax
    mov [rsp + 8], rax
    mov [rsp + 16], rax
    lea rdi, [rsp]
    mov rsi, r12
    call sb_push_cstr
    lea rdi, [rsp]
    mov rsi, r13
    call sb_push_cstr
    mov rdi, [rsp + SB_ptr]
    mov rsi, [rsp + SB_len]
    call mem_dup
    mov r12, rax
    lea rdi, [rsp]
    call sb_free
    mov rax, r12
    EPILOGUE

# .Lbuild_authorize_url(auth_url, client_id, redirect, state, challenge, scope,
#                       [rbp+16] extra) -> cstr
.Lbuild_authorize_url:
    PROLOGUE 64
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov r15, r8
    mov [rsp], r9
    mov rax, [rbp + 16]
    mov [rsp + 32], rax
    xor eax, eax
    mov [rsp + 8], rax
    mov [rsp + 16], rax
    mov [rsp + 24], rax
    lea rdi, [rsp + 8]
    mov rsi, rbx
    call sb_push_cstr
    mov rdi, rbx
    call strlen
    mov rcx, rax
    mov rdi, rbx
    xor edx, edx
1:  cmp rdx, rcx
    jae 2f
    cmp byte ptr [rdi + rdx], '?'
    je 3f
    inc rdx
    jmp 1b
2:  mov esi, '?'
    jmp 4f
3:  mov esi, '&'
4:  lea rdi, [rsp + 8]
    call sb_push_byte
    lea rdi, [rsp + 8]
    lea rsi, [rip + .Lq_response_type]
    lea rdx, [rip + .Lv_code]
    call .Lform_kv
    lea rdi, [rsp + 8]
    lea rsi, [rip + .Lq_client_id]
    mov rdx, r12
    call .Lform_kv
    lea rdi, [rsp + 8]
    lea rsi, [rip + .Lq_redirect_uri]
    mov rdx, r13
    call .Lform_kv
    lea rdi, [rsp + 8]
    lea rsi, [rip + .Lq_state]
    mov rdx, r14
    call .Lform_kv
    lea rdi, [rsp + 8]
    lea rsi, [rip + .Lq_challenge]
    mov rdx, r15
    call .Lform_kv
    lea rdi, [rsp + 8]
    lea rsi, [rip + .Lq_challenge_method]
    lea rdx, [rip + .Lv_s256]
    call .Lform_kv
    mov rax, [rsp]
    test rax, rax
    jz 5f
    cmp byte ptr [rax], 0
    je 5f
    lea rdi, [rsp + 8]
    lea rsi, [rip + .Lq_scope]
    mov rdx, rax
    call .Lform_kv
5:  mov rax, [rsp + 32]
    test rax, rax
    jz 6f
    cmp byte ptr [rax], 0
    je 6f
    lea rdi, [rsp + 8]
    mov rsi, [rsp + 32]
    call sb_push_cstr
6:  mov rdi, [rsp + 8 + SB_ptr]
    mov rsi, [rsp + 8 + SB_len]
    call mem_dup
    mov r12, rax
    lea rdi, [rsp + 8]
    call sb_free
    mov rax, r12
    EPILOGUE

# ------------------------------------------------------------------ loopback
# .Lloopback_open(port edi, dual esi, out2 rdx) -> rax fd (>0), edx port | -errno
# port 0 asks the kernel for an ephemeral port; a nonzero port must bind or
# fail (the built-in providers' redirect URIs are registered for fixed ports).
# dual != 0 binds two loopback listeners on the same port: ::1 (AF_INET6 with
# IPV6_V6ONLY on) and 127.0.0.1 (AF_INET), so a browser resolving localhost to
# either answer reaches us. out2 receives the second fd, or -1 when only one
# bound. Neither path ever binds a wildcard address.
.Lloopback_open:
    PROLOGUE 64
    mov r13d, edi
    mov r12d, esi
    mov r14, rdx                     # out2
    mov [rsp + 56], edi              # requested port: 0 = ephemeral
    mov qword ptr [r14], -1
    mov qword ptr [rsp + 48], -1     # fd6 (AF_INET6), -1 when not bound
    mov qword ptr [rsp + 40], 0      # bound port (host order)
    test r12d, r12d
    jz .Llo_v4
    mov edi, AF_INET6
    mov esi, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK
    xor edx, edx
    call os_socket
    test rax, rax
    js .Llo_v4
    mov rbx, rax
    mov dword ptr [rsp + 32], 1             # IPV6_V6ONLY on: ::1 only
    mov edi, ebx
    mov esi, IPPROTO_IPV6
    mov edx, IPV6_V6ONLY
    lea rcx, [rsp + 32]
    mov r8d, 4
    call os_setsockopt
    test rax, rax
    js .Llo_v6_fail
    mov dword ptr [rsp + 32], 1             # SO_REUSEADDR
    mov edi, ebx
    mov esi, SOL_SOCKET
    mov edx, SO_REUSEADDR
    lea rcx, [rsp + 32]
    mov r8d, 4
    call os_setsockopt
    mov word ptr [rsp], AF_INET6
    test r13d, r13d
    jz .Llo_v6_eph
    mov eax, r13d
    rol ax, 8
    mov word ptr [rsp + 2], ax
    jmp .Llo_v6_addr
.Llo_v6_eph:
    mov word ptr [rsp + 2], 0
.Llo_v6_addr:
    mov dword ptr [rsp + 4], 0              # sin6_flowinfo
    mov qword ptr [rsp + 8], 0              # ::1 address
    mov qword ptr [rsp + 16], 0
    mov byte ptr [rsp + 23], 1
    mov dword ptr [rsp + 24], 0             # sin6_scope_id
    mov edi, ebx
    mov rsi, rsp
    mov edx, 28
    call os_bind
    test rax, rax
    js .Llo_v6_fail
    mov edi, ebx
    mov esi, 1
    call os_listen
    test rax, rax
    js .Llo_v6_fail
    mov dword ptr [rsp + 32], 28
    mov edi, ebx
    mov rsi, rsp
    lea rdx, [rsp + 32]
    call os_getsockname
    test rax, rax
    js .Llo_v6_fail
    mov [rsp + 48], rbx                     # keep the ::1 listener
    movzx eax, word ptr [rsp + 2]
    rol ax, 8
    mov [rsp + 40], rax
    mov r13d, eax                           # bind 127.0.0.1 on the same port
    jmp .Llo_v4
.Llo_v6_fail:
    mov r15, rax
    mov edi, ebx
    call os_socket_close
    # A fixed port that is already taken is fatal: serving only ::1 (or only
    # 127.0.0.1) would leave the registered redirect URI half reachable and
    # silently hang the login.  IPv6 being unavailable is not a bind failure
    # and still falls through to 127.0.0.1.
    cmp r15, -OAUTH_EADDRINUSE
    jne .Llo_v4
    cmp qword ptr [rsp + 56], 0
    jne .Llo_err
.Llo_v4:
    mov edi, AF_INET
    mov esi, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK
    xor edx, edx
    mov rbx, -1                         # so a socket() failure cannot close fd6
    call os_socket
    test rax, rax
    js .Llo_fail
    mov rbx, rax
    mov dword ptr [rsp + 32], 1             # SO_REUSEADDR
    mov edi, ebx
    mov esi, SOL_SOCKET
    mov edx, SO_REUSEADDR
    lea rcx, [rsp + 32]
    mov r8d, 4
    call os_setsockopt
    mov word ptr [rsp], AF_INET
    test r13d, r13d
    jz 1f
    mov eax, r13d
    rol ax, 8
    mov word ptr [rsp + 2], ax
    jmp 2f
1:  mov word ptr [rsp + 2], 0
2:  mov dword ptr [rsp + 4], 0x0100007f     # 127.0.0.1 network order
    mov qword ptr [rsp + 8], 0
    mov edi, ebx
    mov rsi, rsp
    mov edx, 16
    call os_bind
    test rax, rax
    js .Llo_fail
    mov edi, ebx
    mov esi, 1
    call os_listen
    test rax, rax
    js .Llo_fail
    mov dword ptr [rsp + 32], 16
    mov edi, ebx
    mov rsi, rsp
    lea rdx, [rsp + 32]
    call os_getsockname
    test rax, rax
    js .Llo_fail
    movzx edx, word ptr [rsp + 2]
    rol dx, 8
    cmp qword ptr [rsp + 48], -1
    je .Llo_out
    mov [r14], rbx                          # v4 is the secondary listener
    mov rax, [rsp + 48]
    EPILOGUE
.Llo_out:
    mov eax, ebx
    EPILOGUE
.Llo_fail:
    mov r15, rax
    mov edi, ebx
    call os_socket_close
    # 127.0.0.1 busy on a fixed port is fatal even when ::1 bound: see the
    # .Llo_v6_fail comment.  An ephemeral port may still serve on ::1 alone.
    cmp r15, -OAUTH_EADDRINUSE
    jne 1f
    cmp qword ptr [rsp + 56], 0
    jne .Llo_err
1:  cmp qword ptr [rsp + 48], -1
    je .Llo_err
    # fallback: the v4 socket failed but ::1 is bound; serve on it alone
    mov rax, [rsp + 48]
    mov edx, [rsp + 40]
    EPILOGUE
.Llo_err:
    mov rax, r15
    EPILOGUE

# .Lacc4(fd) -> accepted fd | -errno
.Lacc4:
    jmp os_accept

# .Lhdr_end(ptr, n) -> 1|0: "\r\n\r\n" seen
.Lhdr_end:
    xor eax, eax
    xor ecx, ecx
1:  lea rdx, [rcx + 3]
    cmp rdx, rsi
    jae 2f
    cmp byte ptr [rdi + rcx], 13
    jne 3f
    cmp byte ptr [rdi + rcx + 1], 10
    jne 3f
    cmp byte ptr [rdi + rcx + 2], 13
    jne 3f
    cmp byte ptr [rdi + rcx + 3], 10
    jne 3f
    mov eax, 1
    ret
3:  inc rcx
    jmp 1b
2:  ret

# .Lqparam(base, len, key) -> rax value ptr, rdx value len | 0,0
.Lqparam:
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    xor r14d, r14d
.Lqp_loop:
    cmp r14, r12
    jae .Lqp_none
    test r14, r14
    jz 1f
    cmp byte ptr [rbx + r14 - 1], '&'
    jne .Lqp_skip
1:  xor ecx, ecx
2:  mov al, [r13 + rcx]
    test al, al
    jz 3f
    lea rdx, [r14 + rcx]
    cmp rdx, r12
    jae .Lqp_skip
    cmp al, [rbx + rdx]
    jne .Lqp_skip
    inc rcx
    jmp 2b
3:  lea rdx, [r14 + rcx]
    cmp rdx, r12
    jae .Lqp_skip
    cmp byte ptr [rbx + rdx], '='
    jne .Lqp_skip
    inc rdx
    lea rax, [rbx + rdx]
    mov r9, rdx
4:  cmp rdx, r12
    jae 5f
    cmp byte ptr [rbx + rdx], '&'
    je 5f
    inc rdx
    jmp 4b
5:  sub rdx, r9
    EPILOGUE
.Lqp_skip:
    inc r14
6:  cmp r14, r12
    jae .Lqp_none
    cmp byte ptr [rbx + r14], '&'
    je 7f
    inc r14
    jmp 6b
7:  inc r14
    jmp .Lqp_loop
.Lqp_none:
    xor eax, eax
    xor edx, edx
    EPILOGUE

# .Lurldecode(ptr, len) -> new len (in place)
.Lurldecode:
    xor r8, r8
    xor r9, r9
1:  cmp r9, rsi
    jae 9f
    movzx edx, byte ptr [rdi + r9]
    cmp dl, '%'
    jne 8f
    lea rcx, [r9 + 2]
    cmp rcx, rsi
    jae 8f
    movzx eax, byte ptr [rdi + r9 + 1]
    sub eax, '0'
    cmp eax, 9
    jbe 2f
    add eax, '0'
    or eax, 0x20
    sub eax, 'a'
    cmp eax, 5
    ja 8f
    add eax, 10
2:  shl eax, 4
    movzx ecx, byte ptr [rdi + r9 + 2]
    sub ecx, '0'
    cmp ecx, 9
    jbe 3f
    add ecx, '0'
    or ecx, 0x20
    sub ecx, 'a'
    cmp ecx, 5
    ja 8f
    add ecx, 10
3:  or eax, ecx
    mov [rdi + r8], al
    inc r8
    add r9, 3
    jmp 1b
8:  mov [rdi + r8], dl
    inc r8
    inc r9
    jmp 1b
9:  mov rax, r8
    ret

# .Ltrim(ptr, len) -> rax ptr, rdx len.  Strips leading/trailing ASCII space,
# tab, CR and LF.  Leaf.
.Ltrim:
    test rsi, rsi
    jz .Ltrim_done
.Ltrim_lead:
    movzx eax, byte ptr [rdi]
    cmp al, ' '
    je .Ltrim_lead_adv
    cmp al, 9
    je .Ltrim_lead_adv
    cmp al, 13
    je .Ltrim_lead_adv
    cmp al, 10
    je .Ltrim_lead_adv
    jmp .Ltrim_tail
.Ltrim_lead_adv:
    inc rdi
    dec rsi
    jnz .Ltrim_lead
    jmp .Ltrim_done
.Ltrim_tail:
    movzx eax, byte ptr [rdi + rsi - 1]
    cmp al, ' '
    je .Ltrim_tail_adv
    cmp al, 9
    je .Ltrim_tail_adv
    cmp al, 13
    je .Ltrim_tail_adv
    cmp al, 10
    je .Ltrim_tail_adv
    jmp .Ltrim_done
.Ltrim_tail_adv:
    dec rsi
    jnz .Ltrim_tail
.Ltrim_done:
    mov rax, rdi
    mov rdx, rsi
    ret

# .Lread_line(buf, cap) -> rax bytes read (terminator stripped), 0 at EOF,
# -errno on failure.  Reads one byte at a time so a CR/LF is never consumed
# past the line.
.Lread_line:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    xor r13d, r13d
.Lrl_loop:
    cmp r13, r12
    jae .Lrl_done
    xor edi, edi
    lea rsi, [rbx + r13]
    mov edx, 1
    call os_read
    cmp rax, -EINTR
    je .Lrl_loop
    test rax, rax
    js .Lrl_ret
    jz .Lrl_done
    mov al, [rbx + r13]
    cmp al, 10
    je .Lrl_done
    cmp al, 13
    je .Lrl_done
    inc r13
    jmp .Lrl_loop
.Lrl_done:
    mov rax, r13
.Lrl_ret:
    EPILOGUE

# .Lparse_pasted(buf, len, &code, &codelen, &state, &statelen) -> eax 1|0.
# Accepts a full redirect URL, a bare query ("code=..&state=.."), "code#state",
# or a bare code.  Returned pointers alias buf; values are URL-decoded in place.
.Lparse_pasted:
    PROLOGUE 48
    mov [rsp + 0], rdx
    mov [rsp + 8], rcx
    mov [rsp + 16], r8
    mov [rsp + 24], r9
    xor eax, eax
    mov rdx, [rsp + 0]
    mov [rdx], rax
    mov rdx, [rsp + 8]
    mov [rdx], rax
    mov rdx, [rsp + 16]
    mov [rdx], rax
    mov rdx, [rsp + 24]
    mov [rdx], rax
    call .Ltrim
    mov rbx, rax
    mov r12, rdx
    test r12, r12
    jz .Lpp_none
    xor r13d, r13d
.Lpp_scan:
    cmp r13, r12
    jae .Lpp_noq
    mov al, [rbx + r13]
    cmp al, '?'
    je .Lpp_q
    cmp al, '#'
    je .Lpp_hash
    inc r13
    jmp .Lpp_scan
.Lpp_noq:
    cmp r12, 5
    jb .Lpp_bare
    cmp byte ptr [rbx], 'c'
    jne .Lpp_bare
    cmp byte ptr [rbx + 1], 'o'
    jne .Lpp_bare
    cmp byte ptr [rbx + 2], 'd'
    jne .Lpp_bare
    cmp byte ptr [rbx + 3], 'e'
    jne .Lpp_bare
    cmp byte ptr [rbx + 4], '='
    jne .Lpp_bare
    mov r14, rbx
    mov r15, r12
    jmp .Lpp_query
.Lpp_q:
    lea r14, [rbx + r13 + 1]
    mov r15, r12
    sub r15, r13
    dec r15
    jmp .Lpp_query
.Lpp_hash:
    mov rdi, [rsp + 0]
    mov [rdi], rbx
    mov rdi, [rsp + 8]
    mov [rdi], r13
    lea rax, [rbx + r13 + 1]
    mov rdi, [rsp + 16]
    mov [rdi], rax
    mov rcx, r12
    sub rcx, r13
    dec rcx
    mov rdi, [rsp + 24]
    mov [rdi], rcx
    mov eax, 1
    EPILOGUE
.Lpp_bare:
    mov rdi, [rsp + 0]
    mov [rdi], rbx
    mov rdi, [rsp + 8]
    mov [rdi], r12
    mov eax, 1
    EPILOGUE
.Lpp_query:
    mov [rsp + 32], r14
    mov [rsp + 40], r15
    mov rdi, r14
    mov rsi, r15
    lea rdx, [rip + .Lqs_code]
    call .Lqparam
    test rax, rax
    jz .Lpp_none
    mov r13, rax
    mov rbx, rdx
    mov rdi, r13
    mov rsi, rbx
    call .Lurldecode
    mov rdi, [rsp + 0]
    mov [rdi], r13
    mov rdi, [rsp + 8]
    mov [rdi], rax
    mov rdi, [rsp + 32]
    mov rsi, [rsp + 40]
    lea rdx, [rip + .Lqs_state]
    call .Lqparam
    test rax, rax
    jz .Lpp_ok
    mov r13, rax
    mov rbx, rdx
    mov rdi, r13
    mov rsi, rbx
    call .Lurldecode
    mov rdi, [rsp + 16]
    mov [rdi], r13
    mov rdi, [rsp + 24]
    mov [rdi], rax
.Lpp_ok:
    mov eax, 1
    EPILOGUE
.Lpp_none:
    xor eax, eax
    EPILOGUE

# .Lhandle_request(cfd, state, slen, buf, cap, out4;
#                  [rbp+16] path, [rbp+24] pathlen, [rbp+32] listen fd)
#   -> 0          callback path with a matching state handled: out4 =
#                 { code ptr, code len, provider err ptr, provider err len }
#   -> negative   per-connection outcome (a response was sent where the peer
#                 could still read one); the caller closes the connection and
#                 keeps accepting.
# Responses: 200 on a completed callback, 400 on bad/missing state, missing
# code or a malformed request, 404 for anything else. Every one says
# Connection: close, so keep-alive never wedges the server.
.Lhandle_request:
    PROLOGUE 112
    mov rbx, rdi
    mov [rsp + 24], rsi                     # expected state
    mov [rsp + 32], rdx                     # expected state length
    mov r14, rcx                            # request buffer
    mov r15, r8                             # buffer capacity
    mov [rsp], r9                           # out4
    mov rax, [rbp + 16]
    mov [rsp + 64], rax                     # callback path
    mov rax, [rbp + 24]
    mov [rsp + 72], rax                     # callback path length
    mov rax, [rbp + 32]
    mov [rsp + 80], rax                     # listener fd
    mov qword ptr [rsp + 8], 0              # bytes read
    mov rdi, r9
    xor eax, eax
    mov [rdi], rax
    mov [rdi + 8], rax
    mov [rdi + 16], rax
    mov [rdi + 24], rax
    mov edi, CLOCK_MONOTONIC
    call os_now_ns
    mov rcx, OAUTH_CB_NS
    add rax, rcx
    mov [rsp + 16], rax                     # per-connection read deadline
.Lhr_read:
    mov rdi, r14
    mov rsi, [rsp + 8]
    call .Lhdr_end
    test eax, eax
    jnz .Lhr_parse
    mov rax, [rsp + 8]
    cmp rax, r15
    jae .Lhr_badreq
    mov rdi, rbx
    mov esi, POLLIN
    mov rdx, [rsp + 80]
    mov ecx, POLLIN
    mov r8, [rsp + 16]
    call oa_wait_io2
    test rax, rax
    js .Lhr_out_rax
    test eax, 1
    jz .Lhr_newconn
    mov rsi, r14
    add rsi, [rsp + 8]
    mov rdx, r15
    sub rdx, [rsp + 8]
    mov edi, ebx
    call os_read
    cmp rax, -EINTR
    je .Lhr_read
    test rax, rax
    js .Lhr_out_rax
    jz .Lhr_conn_err
    add [rsp + 8], rax
    jmp .Lhr_read
.Lhr_conn_err:
    mov rax, -EIO                           # preconnect / partial request EOF
    EPILOGUE
.Lhr_newconn:
    # a second browser connection arrived while this one sat idle (a
    # preconnect): drop the idle connection and let the accept loop serve the
    # new one, instead of blocking the real callback behind it
    mov rax, -EAGAIN
    EPILOGUE
.Lhr_out_rax:
    EPILOGUE
.Lhr_parse:
    mov rsi, [rsp + 8]
    xor ecx, ecx
1:  cmp rcx, rsi
    jae .Lhr_badreq
    cmp byte ptr [r14 + rcx], ' '
    je 2f
    inc rcx
    jmp 1b
2:  cmp rcx, 3
    jne .Lhr_notfound
    cmp byte ptr [r14], 'G'
    jne .Lhr_notfound
    cmp byte ptr [r14 + 1], 'E'
    jne .Lhr_notfound
    cmp byte ptr [r14 + 2], 'T'
    jne .Lhr_notfound
    lea r8, [rcx + 1]                       # request target start
    mov r9, r8
3:  cmp r9, rsi
    jae 4f
    cmp byte ptr [r14 + r9], ' '
    je 4f
    inc r9
    jmp 3b
4:  mov r10, r8
5:  cmp r10, r9
    jae 6f
    cmp byte ptr [r14 + r10], '?'
    je 7f
    inc r10
    jmp 5b
6:  xor r11d, r11d                          # no query string
    xor r12d, r12d
    jmp 8f
7:  lea r11, [r14 + r10 + 1]
    mov r12, r9
    sub r12, r10
    dec r12
8:  mov rax, r10
    sub rax, r8                             # request path length
    cmp rax, [rsp + 72]
    jne .Lhr_notfound
    mov rdi, [rsp + 64]
    lea rsi, [r14 + r8]
    mov rdx, rax
    call memeq
    test eax, eax
    jz .Lhr_notfound
    mov [rsp + 40], r11                     # query base
    mov [rsp + 48], r12                     # query length
    mov rdi, r11
    mov rsi, r12
    lea rdx, [rip + .Lqs_error]
    call .Lqparam
    mov rdi, [rsp]
    mov [rdi + 16], rax
    mov [rdi + 24], rdx
    mov rdi, [rsp + 40]
    mov rsi, [rsp + 48]
    lea rdx, [rip + .Lqs_state]
    call .Lqparam
    mov [rsp + 88], rax
    mov [rsp + 96], rdx
    mov rdi, [rsp + 40]
    mov rsi, [rsp + 48]
    lea rdx, [rip + .Lqs_code]
    call .Lqparam
    mov [rsp + 56], rax
    mov r13, rdx
    # the state must match before anything else is believed
    mov rax, [rsp + 88]
    test rax, rax
    jz .Lhr_badstate
    mov rcx, [rsp + 96]
    cmp rcx, [rsp + 32]
    jne .Lhr_badstate
    mov rdi, rax
    mov rsi, [rsp + 24]
    mov rdx, rcx
    call memeq
    test eax, eax
    jz .Lhr_badstate
    # provider error with a valid state ends the flow (login prints it)
    mov rdi, [rsp]
    mov rax, [rdi + 16]
    test rax, rax
    jnz .Lhr_ok
    # a code with a valid state is the callback
    mov rax, [rsp + 56]
    test rax, rax
    jz .Lhr_nocode
    mov rdi, rax
    mov rsi, r13
    call .Lurldecode
    mov r13, rax
    mov rdi, [rsp]
    mov rax, [rsp + 56]
    mov [rdi], rax
    mov [rdi + 8], r13
.Lhr_ok:
    mov edi, ebx
    lea rsi, [rip + .Lresp200]
    mov edx, RESP200_LEN
    call write_all
    xor eax, eax
    EPILOGUE
.Lhr_badstate:
    mov edi, ebx
    lea rsi, [rip + .Lresp400state]
    mov edx, RESP400STATE_LEN
    call write_all
    mov rax, -EACCES
    EPILOGUE
.Lhr_nocode:
    mov edi, ebx
    lea rsi, [rip + .Lresp400nocode]
    mov edx, RESP400NOCODE_LEN
    call write_all
    mov rax, -EACCES
    EPILOGUE
.Lhr_notfound:
    mov edi, ebx
    lea rsi, [rip + .Lresp404]
    mov edx, RESP404_LEN
    call write_all
    mov rax, -ENOENT
    EPILOGUE
.Lhr_badreq:
    mov edi, ebx
    lea rsi, [rip + .Lresp400req]
    mov edx, RESP400REQ_LEN
    call write_all
    mov rax, -EINVAL
    EPILOGUE

# ------------------------------------------------------------------ HTTP POST
# oa_body_cb(ctx, ptr, len): append a response-body chunk, capped at
# OAUTH_BODY_MAX. A chunk that would exceed the cap is dropped and
# oa_body_overflow is set; .Lhttp_json_request turns that into -E2BIG instead
# of parsing a truncated token response.
oa_body_cb:
    mov rax, [rdi + SB_len]
    add rax, rdx
    jc 1f
    cmp rax, OAUTH_BODY_MAX
    jbe sb_push
1:  mov qword ptr [rip + oa_body_overflow], 1
    ret

# .Lhttp_json_request(method, url, ctype, body, bodylen, out_sb,
#                     [rbp+16] accept) -> rax 0|-errno, edx status
# One blocking token-endpoint request on the shared client. The absolute
# deadline covers connect, handshake, send and recv, as before.
.Lhttp_json_request:
    PROLOGUE HJ_FRAME
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov r15, r8
    mov [rsp + HJ_OUT], r9
    xor eax, eax
    mov [rsp + HJ_REQ], rax
    mov [rsp + HJ_REQ + 8], rax
    mov [rsp + HJ_REQ + 16], rax
    mov qword ptr [rsp + HJ_RECBUF], 0
    mov dword ptr [rsp + HJ_STATUS], 0
    lea rdi, [rsp + HJ_HC]
    call hc_init
    lea rdi, [rsp + HJ_HC]
    mov rsi, r12
    xor edx, edx
    mov ecx, 30000
    mov r8, OAUTH_HTTP_NS
    mov r9d, 1
    call hc_connect
    test rax, rax
    js .Lhjr_err_rax
    mov edi, OAUTH_RECV_BUF
    call mem_alloc
    mov [rsp + HJ_RECBUF], rax
    lea rdi, [rsp + HJ_HC]
    mov rsi, rax
    mov edx, OAUTH_RECV_BUF
    call hc_set_recbuf
    lea rdi, [rsp + HJ_REQ]
    mov rsi, rbx
    lea rdx, [rsp + HJ_HC + HC_authority]
    mov ecx, [rsp + HJ_HC + HC_authlen]
    mov r8, [rsp + HJ_HC + HC_url + U_path]
    mov r9d, [rsp + HJ_HC + HC_url + U_path_len]
    call http_req_begin
    test r13, r13
    jz 8f
    lea rdi, [rsp + HJ_REQ]
    lea rsi, [rip + .Lhdr_ct]
    mov rdx, r13
    call http_req_header_cstr
8:  mov rax, [rbp + 16]
    test rax, rax
    jz 9f
    lea rdi, [rsp + HJ_REQ]
    lea rsi, [rip + .Lhdr_accept]
    mov rdx, rax
    call http_req_header_cstr
9:  test r14, r14
    jz 2f
    lea rdi, [rsp + HJ_REQ]
    mov rsi, r14
    mov rdx, r15
    call http_req_body
    jmp 3f
2:  lea rdi, [rsp + HJ_REQ]
    call http_req_end
3:  mov rdi, [rsp + HJ_HC + HC_fd]
    mov rsi, [rsp + HJ_HC + HC_conn]
    mov rdx, [rsp + HJ_REQ + SB_ptr]
    mov rcx, [rsp + HJ_REQ + SB_len]
    mov r8, [rsp + HJ_HC + HC_deadline]
    call hc_send_all
    test rax, rax
    js .Lhjr_err_rax
    lea rdi, [rsp + HJ_RESP]
    lea rsi, [rip + oa_body_cb]
    mov rdx, [rsp + HJ_OUT]
    call http_resp_init
    mov qword ptr [rip + oa_body_overflow], 0
    # Parser/body errors (bad chunk framing, truncated headers, ...) are real
    # failures: use the strict policy instead of silently keeping status 0.
    lea rdi, [rsp + HJ_HC]
    lea rsi, [rsp + HJ_RESP]
    mov edx, HCR_STRICT
    xor ecx, ecx
    xor r8d, r8d
    mov r9, [rsp + HJ_HC + HC_deadline]
    call hc_recv_loop
    test rax, rax
    js .Lhjr_recv_err
    cmp qword ptr [rip + oa_body_overflow], 0
    jne .Lhjr_ebig
    lea rdi, [rsp + HJ_RESP]
    call http_resp_status
    mov [rsp + HJ_STATUS], eax
    xor r14d, r14d
    jmp .Lhjr_cleanup
.Lhjr_recv_err:
    mov r14, rax
    cmp rax, -EINVAL
    jne .Lhjr_cleanup
    lea rdi, [rsp + HJ_RESP]
    call http_resp_error
    test rax, rax
    jz .Lhjr_cleanup
    mov rdi, rax
    call oa_err
    jmp .Lhjr_cleanup
.Lhjr_ebig:
    mov r14, -E2BIG
    jmp .Lhjr_cleanup
.Lhjr_err_rax:
    mov r14, rax
.Lhjr_cleanup:
    lea rdi, [rsp + HJ_HC]
    call hc_close
    mov rdi, [rsp + HJ_RECBUF]
    test rdi, rdi
    jz 4f
    call mem_free
4:  lea rdi, [rsp + HJ_REQ]
    call sb_free
    mov rax, r14
    mov edx, [rsp + HJ_STATUS]
    EPILOGUE

# ------------------------------------------------------------------ token store
# .Lfsync_dir(path cstr): best effort; fsync the directory holding path so the
# rename that publishes an atomic write is durable. Backends that cannot open
# or fsync a directory just fail quietly.
.Lfsync_dir:
    PROLOGUE 0
    mov rbx, rdi
    call strlen
    mov rcx, rax
1:  test rcx, rcx
    jz 9f
    cmp byte ptr [rbx + rcx], '/'
    je 2f
    dec rcx
    jmp 1b
2:  test rcx, rcx
    jz 9f
    mov r13, rcx
    mov byte ptr [rbx + r13], 0
    mov rdi, rbx
    mov esi, O_RDONLY | O_DIRECTORY
    xor edx, edx
    call os_open
    mov byte ptr [rbx + r13], '/'
    test rax, rax
    js 9f
    mov r12d, eax
    mov edi, r12d
    call os_fsync
    mov edi, r12d
    call os_close
9:  EPILOGUE

# .Lwrite_atomic(path, sb) -> 0 | -errno
.Lwrite_atomic:
    PROLOGUE 48
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rbx
    lea rsi, [rip + .Ltmp_suffix]
    call config_path_join
    test rax, rax
    jz .Lwa_nomem
    mov r13, rax
    mov rdi, r13
    mov esi, O_WRONLY | O_CREAT | O_TRUNC
    mov edx, 0600
    call os_open
    test rax, rax
    js .Lwa_open_fail
    mov r14d, eax
    mov edi, r14d
    mov esi, 0600
    call os_fchmod                 # force 0600 on a pre-existing .tmp too
    mov edi, r14d
    mov rsi, [r12 + SB_ptr]
    mov rdx, [r12 + SB_len]
    call write_all
    mov r15, rax
    mov edi, r14d
    call os_fsync
    mov edi, r14d
    call os_close
    test r15, r15
    jnz .Lwa_wfail
    mov rdi, r13
    mov rsi, rbx
    call os_rename
    test rax, rax
    jz .Lwa_ok
    mov r15, rax
.Lwa_wfail:
    mov rdi, r13
    call os_unlink
    mov rax, r15
    jmp .Lwa_done
.Lwa_open_fail:
    mov r15, rax
    jmp .Lwa_wfail
.Lwa_ok:
    mov rdi, rbx
    call .Lfsync_dir
    xor eax, eax
.Lwa_done:
    mov rdi, r13
    mov r14, rax
    call mem_free
    mov rax, r14
    EPILOGUE
.Lwa_nomem:
    mov rax, -ENOMEM
    EPILOGUE

# .Lstore_tokens(provider, access, alen, refresh, rlen, expires_at,
#                 [rbp+16] account, [rbp+24] account_len) -> 0|-errno
.Lstore_tokens:
    PROLOGUE 160
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov r15, r8
    mov [rsp + 0], r9
    mov rax, [rbp + 16]
    mov [rsp + 8], rax
    mov rax, [rbp + 24]
    mov [rsp + 16], rax
    xor eax, eax
    mov [rsp + 32], rax
    mov [rsp + 40], rax
    mov [rsp + 48], rax
    mov [rsp + 56], rax
    mov [rsp + 64], rax
    mov [rsp + 72], rax
    mov [rsp + 80], rax
    mov [rsp + 88], rax
    call .Lauth_path
    test rax, rax
    jz .Lst_noent
    mov [rsp + 80], rax
    call config_user_dir
    test rax, rax
    jz 1f
    mov rdi, rax
    mov esi, 0700
    call os_mkdir
1:  mov rdi, [rsp + 80]
    lea rsi, [rsp + 56]
    call config_read_file
    test eax, eax
    jz .Lst_emit
    mov rdi, [rsp + 56 + SB_ptr]
    mov rsi, [rsp + 56 + SB_len]
    call json_parse
    test rax, rax
    jz .Lst_bad
    mov [rsp + 88], rax
.Lst_emit:
    lea rdi, [rsp + 32]
    call jsonw_obj
    mov rax, [rsp + 88]
    test rax, rax
    jz .Lst_new_provider
    mov [rsp + 96], rax
    mov qword ptr [rsp + 104], 0
.Lst_top_loop:
    mov rax, [rsp + 96]
    mov ecx, [rsp + 104]
    cmp ecx, [rax + JV_n]
    jae .Lst_new_provider
    mov rax, [rax + JV_ptr]
    mov rcx, [rsp + 104]
    shl rcx, 4
    mov rsi, [rax + rcx]
    mov rdx, [rax + rcx + 8]
    mov [rsp + 112], rsi
    mov [rsp + 120], rdx
    mov rdi, rsi
    mov rsi, rbx
    call .Ljv_key_eq
    test eax, eax
    jnz .Lst_top_next
    lea rdi, [rsp + 32]
    mov rsi, [rsp + 112]
    call .Ljsonw_key_jv
    lea rdi, [rsp + 32]
    mov rsi, [rsp + 120]
    call .Ljsonw_jv
.Lst_top_next:
    inc qword ptr [rsp + 104]
    jmp .Lst_top_loop
.Lst_new_provider:
    lea rdi, [rsp + 32]
    mov rsi, rbx
    call jsonw_key
    lea rdi, [rsp + 32]
    call jsonw_obj
    mov rax, [rsp + 88]
    test rax, rax
    jz .Lst_oauth
    mov rdi, rax
    mov rsi, rbx
    call json_get
    test rax, rax
    jz .Lst_oauth
    mov [rsp + 128], rax
    mov qword ptr [rsp + 136], 0
.Lst_prov_loop:
    mov rax, [rsp + 128]
    mov ecx, [rsp + 136]
    cmp ecx, [rax + JV_n]
    jae .Lst_oauth
    mov rax, [rax + JV_ptr]
    mov rcx, [rsp + 136]
    shl rcx, 4
    mov rsi, [rax + rcx]
    mov rdx, [rax + rcx + 8]
    mov [rsp + 112], rsi
    mov [rsp + 120], rdx
    mov rdi, rsi
    lea rsi, [rip + .Lkey_oauth]
    call .Ljv_key_eq
    test eax, eax
    jnz .Lst_prov_next
    lea rdi, [rsp + 32]
    mov rsi, [rsp + 112]
    call .Ljsonw_key_jv
    lea rdi, [rsp + 32]
    mov rsi, [rsp + 120]
    call .Ljsonw_jv
.Lst_prov_next:
    inc qword ptr [rsp + 136]
    jmp .Lst_prov_loop
.Lst_oauth:
    lea rdi, [rsp + 32]
    lea rsi, [rip + .Lkey_oauth]
    call jsonw_key
    lea rdi, [rsp + 32]
    call jsonw_obj
    lea rdi, [rsp + 32]
    lea rsi, [rip + .Lkey_access]
    call jsonw_key
    lea rdi, [rsp + 32]
    mov rsi, r12
    mov rdx, r13
    call jsonw_str
    lea rdi, [rsp + 32]
    lea rsi, [rip + .Lkey_refresh]
    call jsonw_key
    lea rdi, [rsp + 32]
    mov rsi, r14
    mov rdx, r15
    call jsonw_str
    lea rdi, [rsp + 32]
    lea rsi, [rip + .Lkey_exp]
    call jsonw_key
    lea rdi, [rsp + 32]
    mov rsi, [rsp + 0]
    call jsonw_u64
    cmp qword ptr [rsp + 8], 0
    je 2f
    lea rdi, [rsp + 32]
    lea rsi, [rip + .Lkey_acct]
    call jsonw_key
    lea rdi, [rsp + 32]
    mov rsi, [rsp + 8]
    mov rdx, [rsp + 16]
    call jsonw_str
2:  lea rdi, [rsp + 32]
    call jsonw_obj_end
    lea rdi, [rsp + 32]
    call jsonw_obj_end
    lea rdi, [rsp + 32]
    call jsonw_obj_end
    lea rdi, [rsp + 32]
    mov esi, 10
    call sb_push_byte
    mov rdi, [rsp + 80]
    lea rsi, [rsp + 32]
    call .Lwrite_atomic
    mov r14, rax
    jmp .Lst_cleanup
.Lst_bad:
    mov r14, -EINVAL
    jmp .Lst_cleanup
.Lst_noent:
    mov r14, -ENOENT
.Lst_cleanup:
    lea rdi, [rsp + 32]
    call sb_free
    lea rdi, [rsp + 56]
    call sb_free
    mov rdi, [rsp + 80]
    call mem_free
    mov rax, r14
    EPILOGUE

# ------------------------------------------------------------------ browser
# .Lopen_browser(url) -> 0; prints the URL on failure
.Lopen_browser:
    PROLOGUE 64
    mov rbx, rdi
    call .Lurl_safe
    test eax, eax
    jz .Lob_print                  # never hand a non-URL to xdg-open
    lea rax, [rip + .Lxdg_open]
    mov [rsp], rax
    mov [rsp + 8], rbx
    mov qword ptr [rsp + 16], 0
    mov rdi, rsp
    mov rsi, [rip + g_envp]
    xor edx, edx
    mov ecx, -1
    mov r8d, -1
    mov r9d, -1
    sub rsp, 16
    mov qword ptr [rsp], 0
    call os_spawn
    add rsp, 16
    test rax, rax
    js .Lob_print
    mov r12, rax
    xor r13d, r13d
1:  mov rdi, r12
    mov esi, 1
    call os_wait
    cmp rax, -1
    je 2f
    cmp rax, 127 << 8
    je .Lob_print
    jmp .Lob_ok
2:  inc r13d
    cmp r13d, 20
    jae .Lob_ok
    mov edi, 10000000
    call os_sleep_ns
    jmp 1b
.Lob_print:
    mov rdi, rbx
    call strlen
    mov rsi, rax
    mov rdi, rbx
    call oa_eputs_safe
    mov edi, 2
    lea rsi, [rip + .Lnl]
    mov edx, 1
    call write_all
.Lob_ok:
    xor eax, eax
    EPILOGUE

# ------------------------------------------------------------------ login
# oauth_login_manual(provider cstr) -> 0|-errno.  Same PKCE/state/token
# machinery as oauth_login, but never opens a loopback listener: it prints the
# authorize URL and reads the pasted authorization code (or full redirect URL)
# from stdin.  Used for remote/headless logins (--manual / --paste).
FN oauth_login_manual
    mov qword ptr [rip + oa_manual], 1
    jmp oauth_login

FN oauth_login
    PROLOGUE OL_FRAME
    mov r15, rdi
    xor eax, eax
    mov [rsp + OL_FORM], rax
    mov [rsp + OL_FORM + 8], rax
    mov [rsp + OL_FORM + 16], rax
    mov [rsp + OL_BODY], rax
    mov [rsp + OL_BODY + 8], rax
    mov [rsp + OL_BODY + 16], rax
    mov [rsp + OL_OUT], rax
    mov [rsp + OL_OUT + 8], rax
    mov [rsp + OL_OUT + 16], rax
    mov [rsp + OL_OUT + 24], rax
    mov [rsp + OL_REDIR], rax
    mov [rsp + OL_AURL], rax
    mov [rsp + OL_ACCESS], rax
    mov [rsp + OL_REFRESH], rax
    mov [rsp + OL_ACCOUNT], rax
    mov [rsp + OL_ROOT], rax
    mov [rsp + OL_XTRA], rax
    mov [rsp + OL_SLEN], rax
    mov [rsp + OL_BPORT], rax
    mov qword ptr [rsp + OL_LFD], -1
    mov qword ptr [rsp + OL_LFD2], -1
    mov qword ptr [rsp + OL_CFD], -1
    mov rax, [rip + oa_manual]
    mov qword ptr [rip + oa_manual], 0
    mov [rsp + OL_MANUAL], rax
    # resolve config
    mov rdi, r15
    xor esi, esi
    call .Lcfg
    mov [rsp + OL_AUTHURL], rax
    mov rdi, r15
    mov esi, 1
    call .Lcfg
    mov [rsp + OL_TOKENURL], rax
    mov rdi, r15
    mov esi, 2
    call .Lcfg
    mov [rsp + OL_CLIENTID], rax
    mov rdi, r15
    mov esi, 3
    call .Lcfg
    mov [rsp + OL_SCOPE], rax
    # provider profile: redirect host/path, extras, fixed port, token flags
    mov rdi, r15
    call .Lprofile
    mov [rsp + OL_PROF], rax
    mov ecx, [rax + P_FLAGS]
    mov [rsp + OL_FLAGS], rcx
    mov rdx, [rax + P_EXTRA]
    mov [rsp + OL_XTRA], rdx
    cmp qword ptr [rip + g_oauth_auth_url], 0
    jne .Lol_generic_redir
    mov rdx, [rax + P_HOST]
    mov [rsp + OL_HOST], rdx
    mov rdx, [rax + P_PATH]
    mov [rsp + OL_PATH], rdx
    mov edx, [rax + P_PORT]
    mov [rsp + OL_BPORT], rdx
    mov qword ptr [rsp + OL_DUAL], 1
    jmp .Lol_have_redir
.Lol_generic_redir:
    # auth URL overridden (tests/custom providers): ephemeral 127.0.0.1
    lea rdx, [rip + .Lredir_default]
    mov [rsp + OL_HOST], rdx
    lea rdx, [rip + .Lpath_callback]
    mov [rsp + OL_PATH], rdx
    mov qword ptr [rsp + OL_BPORT], 0
    mov qword ptr [rsp + OL_DUAL], 0
.Lol_have_redir:
    mov rdi, [rsp + OL_PATH]
    call strlen
    mov [rsp + OL_PATHLEN], rax
    call .Loauth_wait_ns
    mov [rsp + OL_WAITNS], rax
    # PKCE + state
    lea rdi, [rsp + OL_VER]
    mov esi, 32
    call .Lrand_b64
    test rax, rax
    js .Lol_err_rax
    lea rdi, [rsp + OL_DIGEST]
    lea rsi, [rsp + OL_VER]
    mov edx, 43
    call oauth_sha256
    lea rdi, [rsp + OL_CHAL]
    lea rsi, [rsp + OL_DIGEST]
    mov edx, 32
    call .Lb64url
    mov byte ptr [rsp + OL_CHAL + rax], 0
    test dword ptr [rsp + OL_FLAGS], OPF_STATE_VERIFIER
    jz .Lol_rand_state
    # Anthropic: the PKCE verifier doubles as the OAuth state
    lea rsi, [rsp + OL_VER]
    lea rdi, [rsp + OL_STATE]
    mov edx, 44
    call memcpy
    mov qword ptr [rsp + OL_SLEN], 43
    jmp .Lol_state_ok
.Lol_rand_state:
    lea rdi, [rsp + OL_STATE]
    mov esi, 16
    call .Lrand_b64
    test rax, rax
    js .Lol_err_rax
    mov qword ptr [rsp + OL_SLEN], 22
.Lol_state_ok:
    cmp qword ptr [rsp + OL_MANUAL], 0
    jne .Lol_paste_redir
    # loopback server (fixed port for built-in providers, else ephemeral)
    mov edi, [rsp + OL_BPORT]
    mov esi, [rsp + OL_DUAL]
    lea rdx, [rsp + OL_LFD2]
    call .Lloopback_open
    test rax, rax
    js .Lol_bind_fail
    mov [rsp + OL_LFD], rax
    mov [rsp + OL_PORT], rdx
    mov rdi, [rsp + OL_HOST]
    mov esi, edx
    mov rdx, [rsp + OL_PATH]
    call .Lmk_redirect
    jmp .Lol_redir_done
.Lol_paste_redir:
    # --manual: no listener.  Use the redirect URI registered for the client:
    # the fixed loopback port when there is one, else a bare http://localhost
    # path (the custom/overridden auth URL case).
    cmp qword ptr [rip + g_oauth_auth_url], 0
    jne .Lol_paste_generic
    mov rdi, [rsp + OL_HOST]
    mov esi, [rsp + OL_BPORT]
    mov rdx, [rsp + OL_PATH]
    call .Lmk_redirect
    jmp .Lol_redir_done
.Lol_paste_generic:
    lea rdi, [rip + .Lredir_localhost_np]
    mov rsi, [rsp + OL_PATH]
    call .Lmk_redirect_np
.Lol_redir_done:
    test rax, rax
    jz .Lol_nomem
    mov [rsp + OL_REDIR], rax
    # authorize URL
    mov rdi, [rsp + OL_AUTHURL]
    mov rsi, [rsp + OL_CLIENTID]
    mov rdx, [rsp + OL_REDIR]
    lea rcx, [rsp + OL_STATE]
    lea r8, [rsp + OL_CHAL]
    mov r9, [rsp + OL_SCOPE]
    sub rsp, 16
    mov rax, [rsp + 16 + OL_XTRA]
    mov [rsp], rax
    call .Lbuild_authorize_url
    add rsp, 16
    test rax, rax
    jz .Lol_nomem
    mov [rsp + OL_AURL], rax
    cmp qword ptr [rsp + OL_MANUAL], 0
    jne .Lol_do_paste
    cmp qword ptr [rip + g_oauth_no_browser], 0
    jne .Lol_print_url
    mov rdi, rax
    call .Lopen_browser
    jmp .Lol_wait
.Lol_print_url:
    mov rdi, [rsp + OL_AURL]
    call strlen
    mov rsi, rax
    mov rdi, [rsp + OL_AURL]
    call oa_eputs_safe
    mov edi, 2
    lea rsi, [rip + .Lnl]
    mov edx, 1
    call write_all
    jmp .Lol_wait
.Lol_do_paste:
    # print the authorize URL, read one pasted line, then exchange it
    mov rdi, [rsp + OL_AURL]
    call strlen
    mov rsi, rax
    mov rdi, [rsp + OL_AURL]
    call oa_eputs_safe
    mov edi, 2
    lea rsi, [rip + .Lnl]
    mov edx, 1
    call write_all
    lea rdi, [rip + .Lo_paste_prompt]
    call oa_eputs
    lea rdi, [rsp + OL_REQBUF]
    mov esi, OAUTH_READ_BUF
    call .Lread_line
    test rax, rax
    jle .Lol_paste_nocode
    lea rdi, [rsp + OL_REQBUF]
    mov rsi, rax
    lea rdx, [rsp + OL_PCODE]
    lea rcx, [rsp + OL_PCODELEN]
    lea r8, [rsp + OL_PSTATE]
    lea r9, [rsp + OL_PSTATELEN]
    call .Lparse_pasted
    test eax, eax
    jz .Lol_paste_nocode
    mov rax, [rsp + OL_PSTATELEN]
    test rax, rax
    jz .Lol_paste_no_state
    cmp rax, [rsp + OL_SLEN]
    jne .Lol_paste_state_bad
    mov rdi, [rsp + OL_PSTATE]
    lea rsi, [rsp + OL_STATE]
    mov rdx, rax
    call memeq
    test eax, eax
    jz .Lol_paste_state_bad
    jmp .Lol_paste_go
.Lol_paste_no_state:
    # Anthropic binds the code to the PKCE verifier through the state; without
    # it the full redirect URL must be pasted.
    test dword ptr [rsp + OL_FLAGS], OPF_STATE_VERIFIER
    jz .Lol_paste_go
    lea rdi, [rip + .Lo_paste_nostate]
    call oa_err
    mov r14, -EINVAL
    jmp .Lol_ret
.Lol_paste_state_bad:
    lea rdi, [rip + .Lo_state_mismatch]
    call oa_err
    mov r14, -EACCES
    jmp .Lol_ret
.Lol_paste_nocode:
    lea rdi, [rip + .Lo_nocode]
    call oa_err
    mov r14, -EINVAL
    jmp .Lol_ret
.Lol_paste_go:
    mov rax, [rsp + OL_PCODE]
    mov [rsp + OL_OUT], rax
    mov rax, [rsp + OL_PCODELEN]
    mov [rsp + OL_OUT + 8], rax
    jmp .Lol_callback
.Lol_wait:
    mov edi, CLOCK_MONOTONIC
    call os_now_ns
    add rax, [rsp + OL_WAITNS]
    mov [rsp + OL_EXPIRES], rax    # accept deadline (reused slot)
.Lol_acc_loop:
    mov edi, [rsp + OL_LFD]
    call .Lacc4
    test rax, rax
    jns .Lol_acc_got
    cmp rax, -EAGAIN
    je .Lol_acc_l2
    cmp rax, -EINTR
    je .Lol_acc_l2
    jmp .Lol_err_rax
.Lol_acc_l2:
    mov edi, [rsp + OL_LFD2]
    test edi, edi
    js .Lol_acc_wait
    call .Lacc4
    test rax, rax
    jns .Lol_acc_got
    cmp rax, -EAGAIN
    je .Lol_acc_wait
    cmp rax, -EINTR
    je .Lol_acc_wait
    jmp .Lol_err_rax
.Lol_acc_wait:
    mov edi, [rsp + OL_LFD]
    mov esi, POLLIN
    mov edx, [rsp + OL_LFD2]
    mov ecx, POLLIN
    mov r8, [rsp + OL_EXPIRES]
    call oa_wait_io2
    test rax, rax
    js .Lol_wait_err
    jmp .Lol_acc_loop
.Lol_acc_got:
    mov [rsp + OL_CFD], rax
    # serve one request per connection; preconnect EOF, /favicon.ico, HEAD and
    # malformed requests all just close this connection and loop back
    mov rdi, rax
    lea rsi, [rsp + OL_STATE]
    mov rdx, [rsp + OL_SLEN]
    lea rcx, [rsp + OL_REQBUF]
    mov r8d, OAUTH_READ_BUF
    lea r9, [rsp + OL_OUT]
    sub rsp, 32
    mov rax, [rsp + 32 + OL_PATH]
    mov [rsp], rax
    mov rax, [rsp + 32 + OL_PATHLEN]
    mov [rsp + 8], rax
    mov rax, [rsp + 32 + OL_LFD]
    mov [rsp + 16], rax
    call .Lhandle_request
    add rsp, 32
    mov r14, rax
    mov edi, [rsp + OL_CFD]
    test edi, edi
    js 1f
    call os_close
    mov qword ptr [rsp + OL_CFD], -1
1:  test r14, r14
    jz .Lol_callback
    jmp .Lol_acc_loop               # any per-connection result: keep serving
.Lol_wait_err:
    cmp rax, -ETIMEDOUT
    jne .Lol_err_rax
    lea rdi, [rip + .Lo_timeout]
    call oa_err
    mov r14, -ETIMEDOUT
    jmp .Lol_ret
.Lol_callback:
    # the callback arrived: the listeners are no longer needed
    mov edi, [rsp + OL_LFD]
    test edi, edi
    js 1f
    call os_close
    mov qword ptr [rsp + OL_LFD], -1
1:  mov edi, [rsp + OL_LFD2]
    test edi, edi
    js 2f
    call os_close
    mov qword ptr [rsp + OL_LFD2], -1
2:  mov rdi, [rsp + OL_OUT + 16]
    test rdi, rdi
    jnz .Lol_cb_err
    mov rax, [rsp + OL_OUT]
    test rax, rax
    jz .Lol_no_code
    test dword ptr [rsp + OL_FLAGS], OPF_JSON
    jnz .Lol_tok_json
    # token request form: OpenAI and custom providers
    lea rdi, [rsp + OL_FORM]
    lea rsi, [rip + .Lgr_type]
    lea rdx, [rip + .Lv_authcode]
    call .Lform_kv
    lea rdi, [rsp + OL_FORM]
    lea rsi, [rip + .Lgr_code]
    mov rdx, [rsp + OL_OUT]
    mov ecx, [rsp + OL_OUT + 8]
    call .Lform_kv_n
    lea rdi, [rsp + OL_FORM]
    lea rsi, [rip + .Lgr_redirect]
    mov rdx, [rsp + OL_REDIR]
    call .Lform_kv
    lea rdi, [rsp + OL_FORM]
    lea rsi, [rip + .Lgr_client]
    mov rdx, [rsp + OL_CLIENTID]
    call .Lform_kv
    lea rdi, [rsp + OL_FORM]
    lea rsi, [rip + .Lgr_verifier]
    lea rdx, [rsp + OL_VER]
    call .Lform_kv
    lea rdi, [rip + .Lm_post]
    mov rsi, [rsp + OL_TOKENURL]
    lea rdx, [rip + .Lct_form]
    mov rcx, [rsp + OL_FORM + SB_ptr]
    mov r8, [rsp + OL_FORM + SB_len]
    lea r9, [rsp + OL_BODY]
    sub rsp, 16
    mov qword ptr [rsp], 0
    call .Lhttp_json_request
    add rsp, 16
    jmp .Lol_tok_sent
.Lol_tok_json:
    # token request JSON: Anthropic (JSON body + Accept: application/json)
    lea rdi, [rsp + OL_FORM]
    call jsonw_obj
    lea rdi, [rsp + OL_FORM]
    lea rsi, [rip + .Lgr_type]
    call jsonw_key
    lea rdi, [rsp + OL_FORM]
    lea rsi, [rip + .Lv_authcode]
    call jsonw_str_cstr
    lea rdi, [rsp + OL_FORM]
    lea rsi, [rip + .Lgr_client]
    call jsonw_key
    lea rdi, [rsp + OL_FORM]
    mov rsi, [rsp + OL_CLIENTID]
    call jsonw_str_cstr
    lea rdi, [rsp + OL_FORM]
    lea rsi, [rip + .Lgr_code]
    call jsonw_key
    lea rdi, [rsp + OL_FORM]
    mov rsi, [rsp + OL_OUT]
    mov rdx, [rsp + OL_OUT + 8]
    call jsonw_str
    lea rdi, [rsp + OL_FORM]
    lea rsi, [rip + .Lqs_state]
    call jsonw_key
    lea rdi, [rsp + OL_FORM]
    lea rsi, [rsp + OL_STATE]
    call jsonw_str_cstr
    lea rdi, [rsp + OL_FORM]
    lea rsi, [rip + .Lgr_redirect]
    call jsonw_key
    lea rdi, [rsp + OL_FORM]
    mov rsi, [rsp + OL_REDIR]
    call jsonw_str_cstr
    lea rdi, [rsp + OL_FORM]
    lea rsi, [rip + .Lgr_verifier]
    call jsonw_key
    lea rdi, [rsp + OL_FORM]
    lea rsi, [rsp + OL_VER]
    call jsonw_str_cstr
    lea rdi, [rsp + OL_FORM]
    call jsonw_obj_end
    lea rdi, [rip + .Lm_post]
    mov rsi, [rsp + OL_TOKENURL]
    lea rdx, [rip + .Lct_json]
    mov rcx, [rsp + OL_FORM + SB_ptr]
    mov r8, [rsp + OL_FORM + SB_len]
    lea r9, [rsp + OL_BODY]
    sub rsp, 16
    lea rax, [rip + .Lct_json]
    mov [rsp], rax
    call .Lhttp_json_request
    add rsp, 16
.Lol_tok_sent:
    test rax, rax
    js .Lol_err_rax
    cmp edx, 200
    jb .Lol_status
    cmp edx, 300
    jae .Lol_status
    mov rdi, [rsp + OL_BODY + SB_ptr]
    mov rsi, [rsp + OL_BODY + SB_len]
    call json_parse
    test rax, rax
    jz .Lol_bad_json
    mov [rsp + OL_ROOT], rax
    mov rdi, rax
    lea rsi, [rip + .Lkey_access]
    call .Ljson_dup
    mov [rsp + OL_ACCESS], rax
    test rax, rax
    jz .Lol_bad_json
    mov rdi, rax
    call strlen
    mov [rsp + OL_ACC_LEN], rax
    mov rdi, [rsp + OL_ROOT]
    lea rsi, [rip + .Lkey_refresh]
    call .Ljson_dup
    mov [rsp + OL_REFRESH], rax
    mov rdi, rax
    call strlen
    mov [rsp + OL_REF_LEN], rax
    mov rdi, [rsp + OL_ROOT]
    lea rsi, [rip + .Lkey_acct]
    call .Ljson_dup
    mov [rsp + OL_ACCOUNT], rax
    test rax, rax
    jnz .Lol_acct_len
    mov rdi, [rsp + OL_ROOT]
    lea rsi, [rip + .Lkey_account]
    call json_get
    test rax, rax
    jz .Lol_acct_len
    mov rdi, rax
    lea rsi, [rip + .Lkey_uuid]
    call .Ljson_dup
    mov [rsp + OL_ACCOUNT], rax
.Lol_acct_len:
    mov rdi, [rsp + OL_ACCOUNT]
    test rdi, rdi
    jz 1f
    call strlen
    mov [rsp + OL_ACCT_LEN], rax
1:  mov rdi, [rsp + OL_ROOT]
    lea rsi, [rip + .Lkey_expi]
    call json_get
    test rax, rax
    jz .Lol_expi_default
    cmp dword ptr [rax + JV_type], JT_NUM
    jne 2f
    mov rdi, [rax + JV_ptr]
    mov esi, [rax + JV_n]
    call parse_u64
    test rdx, rdx
    jz .Lol_expi_default
    jmp .Lol_expi_have
2:  cmp dword ptr [rax + JV_type], JT_STR
    jne .Lol_expi_default
    mov rdi, rax
    call json_str
    test rax, rax
    jz .Lol_expi_default
    mov rdi, rax
    mov rsi, rdx
    call parse_u64
    test rdx, rdx
    jz .Lol_expi_default
    jmp .Lol_expi_have
.Lol_expi_default:
    mov eax, 3600
.Lol_expi_have:
    mov rcx, 1000
    imul rax, rcx
    mov r12, rax
    call .Lnow_ms
    add r12, rax
    # store
    sub rsp, 16
    mov rax, [rsp + 16 + OL_ACCOUNT]
    mov [rsp], rax
    mov rax, [rsp + 16 + OL_ACCT_LEN]
    mov [rsp + 8], rax
    mov rdi, r15
    mov rsi, [rsp + 16 + OL_ACCESS]
    mov rdx, [rsp + 16 + OL_ACC_LEN]
    mov rcx, [rsp + 16 + OL_REFRESH]
    mov r8, [rsp + 16 + OL_REF_LEN]
    mov r9, r12
    call .Lstore_tokens
    add rsp, 16
    test rax, rax
    js .Lol_err_rax
    lea rdi, [rip + .Lo_logged_in]
    call oa_puts
    mov rdi, r15
    call oa_puts
    mov edi, 1
    lea rsi, [rip + .Lnl]
    mov edx, 1
    call write_all
    xor r14d, r14d
    jmp .Lol_ret
.Lol_cb_err:
    lea rdi, [rip + .Lo_prefix]
    call oa_eputs
    mov rdi, [rsp + OL_OUT + 16]
    mov rsi, [rsp + OL_OUT + 24]
    call oa_eputs_safe            # neutralize a hostile error query value
    mov edi, 2
    lea rsi, [rip + .Lnl]
    mov edx, 1
    call write_all
    mov r14, -EACCES
    jmp .Lol_ret
.Lol_no_code:
    lea rdi, [rip + .Lo_nocode]
    call oa_err
    mov r14, -EINVAL
    jmp .Lol_ret
.Lol_bad_json:
    lea rdi, [rip + .Lo_badresp]
    call oa_err
    mov r14, -EINVAL
    jmp .Lol_ret
.Lol_status:
    mov r12d, edx
    lea rdi, [rip + .Lo_prefix]
    call oa_eputs
    lea rdi, [rip + .Lo_tokfail]
    call oa_eputs
    lea rdi, [rsp + OL_REQBUF]
    mov esi, r12d
    call fmt_u64
    lea rdi, [rsp + OL_REQBUF]
    mov rsi, rax
    call oa_eputsn
    mov edi, 2
    lea rsi, [rip + .Lnl]
    mov edx, 1
    call write_all
    mov r14, -EIO
    jmp .Lol_ret
.Lol_bind_fail:
    mov r14, rax
    cmp rax, -OAUTH_EADDRINUSE
    jne .Lol_ret
    mov rdx, [rsp + OL_PROF]
    mov rdi, [rdx + P_BUSY]
    test rdi, rdi
    jz .Lol_ret
    call oa_err
    jmp .Lol_ret
.Lol_nomem:
    mov rax, -ENOMEM
.Lol_err_rax:
    mov r14, rax
.Lol_err_r14:
.Lol_ret:
    mov edi, [rsp + OL_CFD]
    test edi, edi
    js 1f
    call os_close
1:  mov edi, [rsp + OL_LFD]
    test edi, edi
    js 2f
    call os_close
2:  mov edi, [rsp + OL_LFD2]
    test edi, edi
    js 3f
    call os_close
3:  lea rdi, [rsp + OL_FORM]
    call sb_free
    lea rdi, [rsp + OL_BODY]
    call sb_free
    mov rdi, [rsp + OL_REDIR]
    call mem_free
    mov rdi, [rsp + OL_AURL]
    call mem_free
    mov rdi, [rsp + OL_ACCESS]
    call mem_free
    mov rdi, [rsp + OL_REFRESH]
    call mem_free
    mov rdi, [rsp + OL_ACCOUNT]
    call mem_free
    mov rax, r14
    EPILOGUE

# ------------------------------------------------------------------ logout
FN oauth_logout
    PROLOGUE OG_FRAME
    mov r15, rdi
    xor eax, eax
    mov [rsp + OG_OLD], rax
    mov [rsp + OG_OLD + 8], rax
    mov [rsp + OG_OLD + 16], rax
    mov [rsp + OG_OUT], rax
    mov [rsp + OG_OUT + 8], rax
    mov [rsp + OG_OUT + 16], rax
    mov [rsp + OG_PATH], rax
    mov [rsp + OG_ROOT], rax
    mov [rsp + OG_PROV], rax
    call .Lauth_path
    test rax, rax
    jz .Lolog_print
    mov [rsp + OG_PATH], rax
    mov rdi, rax
    lea rsi, [rsp + OG_OLD]
    call config_read_file
    test eax, eax
    jz .Lolog_print
    mov rdi, [rsp + OG_OLD + SB_ptr]
    mov rsi, [rsp + OG_OLD + SB_len]
    call json_parse
    test rax, rax
    jz .Lolog_bad
    mov r13, rax                # root
    mov rdi, rax
    mov rsi, r15
    call json_get
    mov r14, rax                # provider object | 0
    lea rbx, [rsp + OG_OUT]
    mov rdi, rbx
    call jsonw_obj
    # top-level entries except the provider
    xor r12d, r12d
.Lolog_top:
    test r13, r13
    jz .Lolog_prov
    cmp r12d, [r13 + JV_n]
    jae .Lolog_prov
    mov rax, [r13 + JV_ptr]
    mov rcx, r12
    shl rcx, 4
    mov rsi, [rax + rcx]
    mov rdx, [rax + rcx + 8]
    mov [rsp + OG_KEY], rsi
    mov [rsp + OG_VAL], rdx
    mov rdi, rsi
    mov rsi, r15
    call .Ljv_key_eq
    test eax, eax
    jnz .Lolog_top_next
    mov rdi, rbx
    mov rsi, [rsp + OG_KEY]
    call .Ljsonw_key_jv
    mov rdi, rbx
    mov rsi, [rsp + OG_VAL]
    call .Ljsonw_jv
.Lolog_top_next:
    inc r12d
    jmp .Lolog_top
.Lolog_prov:
    test r14, r14
    jz .Lolog_close
    # provider keeps its non-oauth members only
    xor r12d, r12d
.Lolog_has:
    cmp r12d, [r14 + JV_n]
    jae .Lolog_close
    mov rax, [r14 + JV_ptr]
    mov rcx, r12
    shl rcx, 4
    mov rdi, [rax + rcx]
    lea rsi, [rip + .Lkey_oauth]
    call .Ljv_key_eq
    test eax, eax
    jnz .Lolog_has_next
    mov rax, [r14 + JV_ptr]
    mov rcx, r12
    shl rcx, 4
    mov rdi, [rax + rcx]
    lea rsi, [rip + .Lkey_api]
    call .Ljv_key_eq
    test eax, eax
    jnz .Lolog_has_next
    jmp .Lolog_keep_prov
.Lolog_has_next:
    inc r12d
    jmp .Lolog_has
.Lolog_keep_prov:
    mov rdi, rbx
    mov rsi, r15
    call jsonw_key
    mov rdi, rbx
    call jsonw_obj
    xor r12d, r12d
.Lolog_prov_loop:
    cmp r12d, [r14 + JV_n]
    jae .Lolog_prov_end
    mov rax, [r14 + JV_ptr]
    mov rcx, r12
    shl rcx, 4
    mov rsi, [rax + rcx]
    mov rdx, [rax + rcx + 8]
    mov [rsp + OG_KEY], rsi
    mov [rsp + OG_VAL], rdx
    mov rdi, rsi
    lea rsi, [rip + .Lkey_oauth]
    call .Ljv_key_eq
    test eax, eax
    jnz .Lolog_prov_next
    mov rdi, [rsp + OG_KEY]
    lea rsi, [rip + .Lkey_api]
    call .Ljv_key_eq
    test eax, eax
    jnz .Lolog_prov_next
    mov rdi, rbx
    mov rsi, [rsp + OG_KEY]
    call .Ljsonw_key_jv
    mov rdi, rbx
    mov rsi, [rsp + OG_VAL]
    call .Ljsonw_jv
.Lolog_prov_next:
    inc r12d
    jmp .Lolog_prov_loop
.Lolog_prov_end:
    mov rdi, rbx
    call jsonw_obj_end
.Lolog_close:
    mov rdi, rbx
    call jsonw_obj_end
    cmp qword ptr [rbx + SB_len], 2
    jne .Lolog_write
    mov rdi, [rsp + OG_PATH]
    call os_unlink
    jmp .Lolog_print
.Lolog_bad:
    mov r14, -EINVAL
    jmp .Lolog_ret
.Lolog_print:
    lea rdi, [rip + .Lo_logged_out]
    call oa_puts
    mov rdi, r15
    call oa_puts
    mov edi, 1
    lea rsi, [rip + .Lnl]
    mov edx, 1
    call write_all
    xor r14d, r14d
    jmp .Lolog_ret
.Lolog_write:
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    mov rdi, [rsp + OG_PATH]
    lea rsi, [rsp + OG_OUT]
    call .Lwrite_atomic
    mov r14, rax
    test r14, r14
    js .Lolog_ret
    jmp .Lolog_print
.Lolog_ret:
    lea rdi, [rsp + OG_OLD]
    call sb_free
    lea rdi, [rsp + OG_OUT]
    call sb_free
    mov rdi, [rsp + OG_PATH]
    call mem_free
    mov rax, r14
    EPILOGUE

# ------------------------------------------------------------------ access token
FN oauth_access_token
    PROLOGUE OG_FRAME
    mov r15, rdi
    mov qword ptr [rip + oauth_last], 0
    mov qword ptr [rip + oauth_present], 0
    xor eax, eax
    mov [rsp + OG_OLD], rax
    mov [rsp + OG_OLD + 8], rax
    mov [rsp + OG_OLD + 16], rax
    mov [rsp + OG_PATH], rax
    mov [rsp + OG_ROOT], rax
    call .Lauth_path
    test rax, rax
    jz .Loa_none
    mov [rsp + OG_PATH], rax
    mov rdi, rax
    lea rsi, [rsp + OG_OLD]
    call config_read_file
    test eax, eax
    jz .Loa_none
    mov rdi, [rsp + OG_OLD + SB_ptr]
    mov rsi, [rsp + OG_OLD + SB_len]
    call json_parse
    test rax, rax
    jz .Loa_none
    mov [rsp + OG_ROOT], rax
    mov rdi, rax
    mov rsi, r15
    call json_get
    test rax, rax
    jz .Loa_none
    mov rdi, rax
    lea rsi, [rip + .Lkey_oauth]
    call json_get
    test rax, rax
    jz .Loa_none
    mov r14, rax
    mov qword ptr [rip + oauth_present], 1   # the provider owns its OAuth store
    mov rdi, rax
    lea rsi, [rip + .Lkey_access]
    call json_get
    test rax, rax
    jz .Loa_none
    mov rdi, rax
    call json_str
    test rax, rax
    jz .Loa_none
    mov [rsp + OG_TOK], rax
    mov [rsp + OG_TOKLEN], rdx
    mov rdi, r14
    lea rsi, [rip + .Lkey_exp]
    call json_get
    test rax, rax
    jz .Loa_none
    cmp dword ptr [rax + JV_type], JT_NUM
    jne .Loa_none
    mov rdi, [rax + JV_ptr]
    mov esi, [rax + JV_n]
    call parse_u64
    test rdx, rdx
    jz .Loa_none
    mov r12, rax
    call .Lnow_ms
    mov rcx, OAUTH_SKEW_MS
    add rax, rcx
    cmp r12, rax
    jbe .Loa_none
    mov rdi, [rsp + OG_TOK]
    mov rsi, [rsp + OG_TOKLEN]
    call mem_dup
    mov qword ptr [rip + oauth_last], 1
    jmp .Loa_ret
.Loa_none:
    xor eax, eax
.Loa_ret:
    mov r12, rax
    lea rdi, [rsp + OG_OLD]
    call sb_free
    mov rdi, [rsp + OG_PATH]
    call mem_free
    mov rax, r12
    EPILOGUE
