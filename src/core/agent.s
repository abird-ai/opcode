# agent: the M2 state machine. Drives connect -> request -> SSE -> tools -> next turn,
# streaming assistant text to stdout (print mode). See src/core/API.md.
#
# Config globals set by the app before agent_run:
#   g_agent_provider, g_agent_model, g_agent_base, g_agent_system, g_agent_replay,
#   g_agent_max_tokens, g_agent_verbose
.include "opcode.inc"
.include "core/core.inc"
.include "net/net.inc"
# HC transport state and HCR_* error policy flags
.include "wire/http_client.inc"

# Url layout: src/wire/url.inc (single source of truth; see src/wire/API.md)
.include "wire/url.inc"

.equ TURN_TIMEOUT_MS, 120000
.equ CONNECT_TIMEOUT_MS, 30000
.equ RECV_CHUNK, 65536
.equ COMPACT_KEEP_TOKENS, 20000
.equ CMP_CONNECT_TIMEOUT_MS, 30000
.equ CMP_CONNECT_TIMEOUT_NS, 30000000000
.equ CMP_TURN_TIMEOUT_NS, 120000000000

.equ AS_IDLE,      0
.equ AS_CONNECT,   1
.equ AS_HANDSHAKE, 2
.equ AS_SEND,      3
.equ AS_RECV,      4
.equ AS_TOOLS,     5
.equ AS_TURN,      6
.equ AS_DONE,      7
.equ AS_ERROR,     8

.section .rodata
.Lm_post:      .asciz "POST"
.Lct_json:     .asciz "application/json"
.Laccept_sse:  .asciz "text/event-stream"
.Lua:          .asciz "opcode/0.1"
.Lh_ctype:     .asciz "content-type"
.Lh_accept:    .asciz "accept"
.Lh_ua:        .asciz "user-agent"
.Lh_auth:      .asciz "authorization"
.Lh_xkey:      .asciz "x-api-key"
.Lh_ver:       .asciz "anthropic-version"
.Lver:         .asciz "2023-06-01"
.Lh_beta:      .asciz "anthropic-beta"
.Lbeta_oauth:  .asciz "oauth-2025-04-20"
.Lbearer:      .asciz "Bearer "
.Lapi_anthropic: .asciz "anthropic-messages"
.Lapi_responses: .asciz "openai-responses"
.Lanon:        .asciz "openai"
.Lcfg_provider: .asciz "default_provider"
.Lcfg_model:    .asciz "default_model"
.Lth_off:     .asciz "off"
.Lth_low:     .asciz "low"
.Lth_medium:  .asciz "medium"
.Lth_high:    .asciz "high"
.Lmagic:       .asciz "FWIR1\n"
.Lerr_net:     .asciz "network error"
.Lerr_tls:     .asciz "TLS error"
.Lerr_timeout: .asciz "request timed out"
.Lerr_offline: .asciz "offline: network access disabled"
.Lerr_nokey:   .asciz "no API key: run 'opcode login <provider>', pass --api-key, or set the provider env var"
.Lerr_model:   .asciz "unknown model; check --provider/--model or the catalog"
.Lerr_replay:  .asciz "bad replay file"
.Lhttp_err_pre: .asciz "http error "
.Lhttp_err_mid: .asciz ": "
.Lprefix:      .asciz "opcode: "
.Lnl:          .asciz "\n"
.Ltool_err:    .asciz "error: "
.Ltool_err_len = 7
.Laborted:     .asciz "[aborted]"
.Laborted_len = 9
.Lbad_args:    .asciz "error: invalid arguments"
.Lbad_exec:    .asciz "error: cannot run tool"
.Lbad_watch:   .asciz "error: cannot watch tool process"
.Lunknown_tool: .asciz "error: unknown tool: "
.Lempty:       .asciz ""
.Lunknown_name: .asciz "?"
.Lempty_obj:   .asciz "{}"
.Lcompacted:   .asciz "compacted "
.Ltokens:      .asciz " tokens\n"
.Lcfail:       .asciz "compaction failed"
.Lcustom_compaction: .asciz "compaction"
.K_first_kept: .asciz "first_kept"
.K_tokens_before: .asciz "tokens_before"

.bss
.p2align 3
.globl g_agent_provider, g_agent_model, g_agent_base, g_agent_system, g_agent_replay
.globl g_agent_max_tokens, g_agent_verbose, g_offline
g_agent_provider:   .quad 0
g_agent_model:      .quad 0
g_agent_base:       .quad 0
g_agent_system:     .quad 0
g_agent_replay:     .quad 0
g_agent_max_tokens: .quad 0
g_agent_verbose:    .quad 0
.globl g_offline
g_offline:          .quad 0
.globl g_agent_session
g_agent_session:    .quad 0
.globl g_agent_ui_fn, g_agent_ui_ctx
g_agent_ui_fn:      .quad 0
g_agent_ui_ctx:     .quad 0

.section .data
.p2align 2
# Active thinking level: 0 off .. 3 high.  -1 means "not set yet": agent_init
# then applies the config default_thinking (the --thinking flag stores 0..3
# here before init).  Read by prov/anthropic.s when building the request.
.globl g_agent_thinking
GTYPE g_agent_thinking, @object
g_agent_thinking:   .long -1
GSIZE g_agent_thinking, 4

.p2align 3
# api string -> PV* dispatch table (ADR-7): one row per wire API, plus a NULL
# terminator whose vtable is the default.  Consumed only by prov_for_api().
prov_table:
    .quad .Lapi_anthropic, prov_anthropic
    .quad .Lapi_responses, prov_openai_responses
    .quad 0,               prov_openai

.section .bss

.p2align 3
a_tr:        .zero TR_SIZE
a_sys_sb:    .zero SB_SIZE
a_body_sb:   .zero SB_SIZE
a_req_sb:    .zero SB_SIZE
a_file_sb:   .zero SB_SIZE
a_url:       .zero 64
a_hostbuf:   .zero 512
a_authority: .zero 528
a_authlen:   .zero 8
a_pathbuf:   .zero 512
a_authbuf:   .zero 512
a_cwdbuf:    .zero 512
a_resp:      .zero 2048
a_sse:       .zero 1200
a_http_status: .zero 4
a_pad2:      .zero 4
a_errbody:   .zero SB_SIZE
a_errmsg:    .zero SB_SIZE
a_sink:      .zero SS_SIZE
a_recbuf:    .zero 8
a_hostlen:   .zero 8
a_pathlen:   .zero 8
a_ip:        .zero 8
a_msg:       .zero 8
a_text:      .zero SB_SIZE
a_think:     .zero SB_SIZE
a_targs:     .zero SB_SIZE
a_tool_id:   .zero 8
a_tool_name: .zero 8
a_state:     .zero 4
a_done:      .zero 4
a_exit:      .zero 4
a_printed:   .zero 4
a_tls:       .zero 4
a_pad:       .zero 4
a_fd:        .zero 8
a_conn:      .zero 8
a_hc:        .zero HC_SIZE
a_pv:        .zero 8
a_pvctx:     .zero 8
a_md:        .zero 8
a_key:       .zero 8
a_send_off:  .zero 8
a_send_len:  .zero 8
a_deadline:  .zero 8
a_turn:      .zero 8
a_jobs:      .zero VEC_SIZE
a_pending:   .zero 4
a_abort:     .zero 4
a_te:        .zero TE_SIZE
a_finish_ms: .zero 8
a_rep_ptr:   .zero 8
a_rep_len:   .zero 8
a_rep_off:   .zero 8
# compaction scratch state (compact_maybe_run / agent_request_blocking)
a_cprompt_sb: .zero SB_SIZE
a_csum_sb:   .zero SB_SIZE
a_cjson_sb:  .zero SB_SIZE
a_ctmp:      .zero TR_SIZE
a_cresp:     .zero 2048
a_csse:      .zero 1200
a_csink:     .zero SS_SIZE
a_cdone:     .zero 4
a_cerr:      .zero 8

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

# prov_for_api(api cstr rdi) -> PV*: the one <api> -> provider mapping site
# (ADR-7).  Unknown/missing api falls back to prov_openai, matching the former
# two-chain dispatch.
prov_for_api:
    PROLOGUE
    mov r12, rdi
    lea r13, [rip + prov_table]
1:  mov rdi, [r13]
    test rdi, rdi
    jz 2f
    mov rsi, r12
    call cstr_eq
    test eax, eax
    jnz 3f
    add r13, 16
    jmp 1b
2:  lea rax, [rip + prov_openai]
    EPILOGUE
3:  mov rax, [r13 + 8]
    EPILOGUE

# ag_find_slash(cstr rdi) -> rax pointer to '/' | 0 (leaf)
ag_find_slash:
    mov rax, rdi
1:  mov cl, [rax]
    test cl, cl
    jz 2f
    cmp cl, '/'
    je 3f
    inc rax
    jmp 1b
2:  xor eax, eax
    ret
3:  ret

# out_cstr(fd, cstr)
out_cstr:
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

# err(cstr): "opcode: <msg>\n" to stderr
err:
    PROLOGUE
    mov r12, rdi
    mov edi, 2
    lea rsi, [rip + .Lprefix]
    call out_cstr
    mov edi, 2
    mov rsi, r12
    call out_cstr
    mov edi, 2
    lea rsi, [rip + .Lnl]
    call out_cstr
    EPILOGUE

# mem_dup_cstr(cstr) -> copy | 0
mem_dup_cstr:
    test rdi, rdi
    jz 1f
    push rdi
    call strlen
    pop rdi
    mov rsi, rax
    jmp mem_dup
1:  xor eax, eax
    ret

# read_file(path cstr, sb) -> 0|-errno
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
    mov edi, RECV_CHUNK
    call mem_alloc
    mov rbx, rax
1:  mov edi, r12d
    mov rsi, rbx
    mov edx, RECV_CHUNK
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

# agent_kill_job(job*): stop a running job, reap the child and close its pipe.
agent_kill_job:
    PROLOGUE
    mov rbx, rdi
    cmp dword ptr [rbx + J_state], JS_RUNNING
    jne .Lkj_ret
    mov edi, [rbx + J_fd]
    call watch_remove
    mov rdi, [rbx + J_pid]
    mov esi, 9                  # SIGKILL
    call os_kill_group
    mov rax, [rbx + J_tool]
    test rax, rax
    jz 1f
    mov rax, [rax + TL_finish]
    test rax, rax
    jz 1f
    mov rdi, rbx
    call rax
    jmp 2f
1:  mov rdi, [rbx + J_pid]
    xor esi, esi                # blocking wait: reap the child
    call os_wait
    mov edi, [rbx + J_fd]
    call os_close
2:  mov dword ptr [rbx + J_state], JS_DONE
.Lkj_ret:
    EPILOGUE

# agent_fail(cstr msg): print, tear down the transport and jobs, stop with exit 1
agent_fail:
    PROLOGUE
    mov r12, rdi
    mov rdi, r12
    call err
    xor ebx, ebx
1:  cmp rbx, [rip + a_jobs + VEC_len]
    jae 2f
    mov rax, [rip + a_jobs + VEC_ptr]
    mov r12, [rax + rbx*8]
    test r12, r12
    jz 11f
    mov rdi, r12
    call agent_kill_job
    # release the job and its result buffer; nothing else owns them once the
    # run has failed (J_call_id/J_args are borrowed from the transcript)
    mov rdi, [r12 + J_out]
    test rdi, rdi
    jz 10f
    call sb_free
10: mov rdi, r12
    call mem_free
11: inc rbx
    jmp 1b
2:  mov qword ptr [rip + a_jobs + VEC_len], 0
    mov dword ptr [rip + a_pending], 0
    # release the replay file buffer, if agent_init loaded one
    lea rdi, [rip + a_file_sb]
    call sb_free
    mov edi, [rip + a_fd]
    cmp edi, 0
    jl 4f
    call watch_remove
    cmp qword ptr [rip + a_conn], 0
    je 3f
    mov rdi, [rip + a_conn]
    call tls_close
    mov qword ptr [rip + a_conn], 0
3:  mov edi, [rip + a_fd]
    call net_close
    mov qword ptr [rip + a_fd], -1
4:  mov dword ptr [rip + a_exit], 1
    mov dword ptr [rip + a_state], AS_ERROR
    EPILOGUE

# agent_sig_cleanup(): async-signal-safe fatal-signal/exit hook installed for
# print/JSON/RPC runs (main.s points g_exit_hook at it, then calls
# os_sig_cleanup).  Sets the abort flag, then SIGKILLs and reaps every running
# tool child and closes its read fd, so a Ctrl-C leaves no orphan and no pipe
# leak.  No allocation: safe from a signal handler, and safe to call from
# os_exit on a normal exit (a_jobs/a_fd are then already idle).
FN agent_sig_cleanup
    PROLOGUE
    mov dword ptr [rip + a_abort], 1
    xor ebx, ebx
1:  cmp rbx, [rip + a_jobs + VEC_len]
    jae 5f
    mov rax, [rip + a_jobs + VEC_ptr]
    mov r12, [rax + rbx*8]
    test r12, r12
    jz 4f
    cmp dword ptr [r12 + J_state], JS_RUNNING
    jne 4f
    mov rdi, [r12 + J_pid]
    test rdi, rdi
    jz 2f
    mov esi, 9                  # SIGKILL the whole group
    call os_kill_group
2:  mov edi, [r12 + J_fd]
    cmp edi, 0
    jl 3f
    call os_close
    mov qword ptr [r12 + J_fd], -1
3:  mov rdi, [r12 + J_pid]
    test rdi, rdi
    jz 31f
    xor esi, esi                # blocking reap
    call os_wait
    mov qword ptr [r12 + J_pid], 0
31: mov dword ptr [r12 + J_state], JS_DONE
4:  inc rbx
    jmp 1b
5:  mov edi, [rip + a_fd]
    cmp edi, 0
    jl 6f
    call os_close
    mov qword ptr [rip + a_fd], -1
6:  EPILOGUE

# agent_http_error() -> 1 when a 4xx/5xx response was seen: fail the turn with
# the provider's body (bounded, captured by agent_on_body), else 0.
agent_http_error:
    PROLOGUE
    # read the status from the parser directly: a 4xx/5xx with an empty body
    # never invokes agent_on_body, so a_http_status alone is not enough
    lea rdi, [rip + a_resp]
    call http_resp_status
    mov [rip + a_http_status], eax
    cmp eax, 400
    jb .Lhe_ok
    lea rdi, [rip + a_errmsg]
    call sb_clear
    lea rdi, [rip + a_errmsg]
    lea rsi, [rip + .Lhttp_err_pre]
    call sb_push_cstr
    lea rdi, [rip + a_errmsg]
    mov esi, [rip + a_http_status]
    call sb_push_u64
    lea rdi, [rip + a_errmsg]
    lea rsi, [rip + .Lhttp_err_mid]
    call sb_push_cstr
    mov rsi, [rip + a_errbody + SB_ptr]
    test rsi, rsi
    jz 1f
    lea rdi, [rip + a_errmsg]
    call sb_push_cstr
1:  mov rdi, [rip + a_errmsg + SB_ptr]
    call agent_fail
    mov eax, 1
    EPILOGUE
.Lhe_ok:
    xor eax, eax
    EPILOGUE

# job_error_text(job, msg): write "error: <msg>" into the job's out
job_error_text:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov rdi, [r12 + J_out]
    lea rsi, [rip + .Ltool_err]
    mov edx, .Ltool_err_len
    call sb_push
    mov rdi, [r12 + J_out]
    mov rsi, r13
    call sb_push_cstr
    mov dword ptr [r12 + J_flags], JF_ERROR
    EPILOGUE

# ---- sink -----------------------------------------------------------------
# agent_sink(&sink, event, a, b)
agent_sink:
    PROLOGUE
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    cmp r12d, SE_TEXT
    je .Ls_text
    cmp r12d, SE_TEXT_END
    je .Ls_text_end
    cmp r12d, SE_THINK
    je .Ls_think
    cmp r12d, SE_THINK_END
    je .Ls_think_end
    cmp r12d, SE_TOOL_START
    je .Ls_tool_start
    cmp r12d, SE_TOOL_DELTA
    je .Ls_tool_delta
    cmp r12d, SE_TOOL_END
    je .Ls_tool_end
    cmp r12d, SE_USAGE
    je .Ls_usage
    cmp r12d, SE_DONE
    je .Ls_done
    cmp r12d, SE_ERROR
    je .Ls_error
    jmp .Ls_ret
.Ls_text:
    lea rdi, [rip + a_text]
    mov rsi, r13
    mov rdx, r14
    call sb_push
    mov dword ptr [rip + a_printed], 1
    cmp qword ptr [rip + g_agent_ui_fn], 0
    jne .Ls_ret
    mov edi, 1
    mov rsi, r13
    mov rdx, r14
    call write_all
    jmp .Ls_ret
.Ls_text_end:
    cmp qword ptr [rip + a_text + SB_len], 0
    je .Ls_clear_text
    mov rdi, [rip + a_msg]
    mov esi, BT_TEXT
    mov rdx, [rip + a_text + SB_ptr]
    mov rcx, [rip + a_text + SB_len]
    call msg_add_block
.Ls_clear_text:
    lea rdi, [rip + a_text]
    call sb_clear
    jmp .Ls_ret
.Ls_think:
    lea rdi, [rip + a_think]
    mov rsi, r13
    mov rdx, r14
    call sb_push
    jmp .Ls_ret
.Ls_think_end:
    cmp qword ptr [rip + a_think + SB_len], 0
    je .Ls_clear_think
    mov rdi, [rip + a_msg]
    mov esi, BT_THINK
    mov rdx, [rip + a_think + SB_ptr]
    mov rcx, [rip + a_think + SB_len]
    call msg_add_block
.Ls_clear_think:
    lea rdi, [rip + a_think]
    call sb_clear
    jmp .Ls_ret
.Ls_tool_start:
    # a provider that starts another call without ending the previous one
    # must not leak (or inherit) the pending slot
    mov rdi, [rip + a_tool_id]
    call mem_free
    mov rdi, [rip + a_tool_name]
    call mem_free
    mov qword ptr [rip + a_tool_id], 0
    mov qword ptr [rip + a_tool_name], 0
    mov rdi, r13
    call mem_dup_cstr
    mov [rip + a_tool_id], rax
    mov rdi, r14
    call mem_dup_cstr
    mov [rip + a_tool_name], rax
    lea rdi, [rip + a_targs]
    call sb_clear
    jmp .Ls_ret
.Ls_tool_delta:
    lea rdi, [rip + a_targs]
    mov rsi, r13
    mov rdx, r14
    call sb_push
    jmp .Ls_ret
.Ls_tool_end:
    mov rcx, [rip + a_targs + SB_ptr]
    test rcx, rcx
    jnz 1f
    lea rcx, [rip + .Lempty_obj]
1:  mov rdi, [rip + a_msg]
    mov rsi, [rip + a_tool_id]
    mov rdx, [rip + a_tool_name]
    call msg_add_toolcall
    mov rdi, [rip + a_tool_id]
    call mem_free
    mov rdi, [rip + a_tool_name]
    call mem_free
    mov qword ptr [rip + a_tool_id], 0
    mov qword ptr [rip + a_tool_name], 0
    lea rdi, [rip + a_targs]
    call sb_clear
    jmp .Ls_ret
.Ls_usage:
    mov rdi, [rip + a_msg]
    mov rsi, r13
    call msg_set_usage
    jmp .Ls_ret
.Ls_done:
    mov rax, [rip + a_msg]
    mov [rax + M_stop], r13d
    mov dword ptr [rip + a_done], 1
    jmp .Ls_ret
.Ls_error:
    mov rdi, r13
    call err
    mov rax, [rip + a_msg]
    mov dword ptr [rax + M_stop], SR_ERROR
    mov dword ptr [rip + a_done], 1
    mov dword ptr [rip + a_exit], 1
.Ls_ret:
    mov rax, [rip + g_agent_ui_fn]
    test rax, rax
    jz 8f
    mov rdi, [rip + g_agent_ui_ctx]
    mov esi, r12d
    mov rdx, r13
    mov rcx, r14
    call rax
8:  EPILOGUE

# ---- parser glue -----------------------------------------------------------
# agent_on_body(ctx, ptr, len) -> sse parser, or the HTTP error body buffer
# when the response status is 4xx/5xx. Provider error responses are JSON, not
# SSE, so feeding them to the SSE parser would lose the provider's message.
agent_on_body:
    PROLOGUE
    mov r12, rsi
    mov r13, rdx
    lea rdi, [rip + a_resp]
    call http_resp_status
    mov [rip + a_http_status], eax
    cmp eax, 400
    jb .Lob_sse
    mov rax, [rip + a_errbody + SB_len]
    cmp rax, 4096
    jae .Lob_ret                    # keep the report bounded
    mov rdx, 4096
    sub rdx, rax
    cmp rdx, r13
    jbe 1f
    mov rdx, r13
1:  lea rdi, [rip + a_errbody]
    mov rsi, r12
    call sb_push
    jmp .Lob_ret
.Lob_sse:
    lea rdi, [rip + a_sse]
    mov rsi, r12
    mov rdx, r13
    call sse_feed
.Lob_ret:
    EPILOGUE

# agent_sse_sink(sink SS*, event ptr/len, data ptr/len) -> provider
# Generic dispatch used by the main loop (sink=a_sink) and by the blocking
# compaction request (sink=a_csink).
agent_sse_sink:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    mov rbx, r8
    mov rdi, [rip + a_pvctx]
    mov rsi, r12
    mov rdx, r13
    mov rcx, r14
    mov r8, r15
    mov r9, rbx
    mov rax, [rip + a_pv]
    call [rax + PV_sse]
    EPILOGUE

# agent_sse(ctx, event ptr/len, data ptr/len) -> provider (a_sink)
agent_sse:
    lea rdi, [rip + a_sink]
    jmp agent_sse_sink

# ---- transport handlers ----------------------------------------------------
# agent_recv_more()
agent_recv_more:
    PROLOGUE
1:  test dword ptr [rip + a_done], 1
    jnz .Lrm_finish
    mov rdi, [rip + a_conn]
    mov esi, [rip + a_fd]
    mov rdx, [rip + a_recbuf]
    mov ecx, RECV_CHUNK
    call hc_recv_some
    test rax, rax
    jg .Lrm_data
    jz .Lrm_eof
    cmp rax, -EAGAIN
    je .Lrm_ret
    jmp .Lrm_fail
.Lrm_data:
    mov rbx, rax
    lea rdi, [rip + a_resp]
    mov rsi, [rip + a_recbuf]
    mov rdx, rbx
    call http_resp_feed
    # a malformed response must fail the turn now, not after the 120 s timeout
    lea rdi, [rip + a_resp]
    call http_resp_error
    test rax, rax
    jz .Lrm_pok
    mov rdi, rax
    call agent_fail
    EPILOGUE
.Lrm_pok:
    # an oversized SSE event is dropped by the parser; surface it now rather
    # than letting the turn end with a misleading "stream ended" error
    lea rdi, [rip + a_sse]
    call sse_error
    test rax, rax
    jz .Lrm_ssok
    mov rdi, rax
    call agent_fail
    EPILOGUE
.Lrm_ssok:
    # the response may be complete (Content-Length / last chunk) while the
    # connection stays open: finish the turn as soon as the parser is done
    lea rdi, [rip + a_resp]
    call http_resp_done
    test eax, eax
    jz 1b
    cmp dword ptr [rip + a_done], 0
    jne .Lrm_finish
    call agent_http_error
    test eax, eax
    jnz .Lrm_ret
    mov rdi, [rip + a_pvctx]
    lea rsi, [rip + a_sink]
    mov rax, [rip + a_pv]
    call [rax + PV_finish]
    jmp .Lrm_finish
.Lrm_eof:
    lea rdi, [rip + a_resp]
    call http_resp_eof
    call agent_http_error
    test eax, eax
    jnz .Lrm_ret
    mov rdi, [rip + a_pvctx]
    lea rsi, [rip + a_sink]
    mov rax, [rip + a_pv]
    call [rax + PV_finish]
    jmp .Lrm_finish
.Lrm_ret:
    EPILOGUE
.Lrm_fail:
    lea rdi, [rip + .Lerr_net]
    call agent_fail
    EPILOGUE
.Lrm_finish:
    call agent_finish_turn
    EPILOGUE

# agent_send_more()
agent_send_more:
    PROLOGUE
1:  mov r12, [rip + a_send_off]
    mov r13, [rip + a_send_len]
    cmp r12, r13
    jae .Lsm_done
    mov edi, [rip + a_fd]
    mov rsi, [rip + a_conn]
    mov rdx, [rip + a_req_sb + SB_ptr]
    add rdx, r12
    mov rcx, r13
    sub rcx, r12
    call hc_send_some
    test rax, rax
    jg .Lsm_sent
    cmp rax, -EAGAIN
    je .Lsm_wait
    lea rdi, [rip + .Lerr_net]
    call agent_fail
    EPILOGUE
.Lsm_sent:
    add [rip + a_send_off], rax
    jmp 1b
.Lsm_wait:
    mov esi, POLLOUT
    cmp qword ptr [rip + a_conn], 0
    je 4f
    mov rdi, [rip + a_conn]
    call hc_tls_events
    mov esi, eax
4:  mov edi, [rip + a_fd]
    call watch_set_events
    EPILOGUE
.Lsm_done:
    mov dword ptr [rip + a_state], AS_RECV
    mov edi, [rip + a_fd]
    mov esi, POLLIN
    call watch_set_events
    EPILOGUE

# agent_send_begin()
agent_send_begin:
    mov qword ptr [rip + a_send_off], 0
    mov rax, [rip + a_req_sb + SB_len]
    mov [rip + a_send_len], rax
    mov dword ptr [rip + a_state], AS_SEND
    jmp agent_send_more

# agent_handshake()
agent_handshake:
    PROLOGUE
    mov rdi, [rip + a_conn]
    call tls_handshake
    movsxd rax, eax                 # the shim returns C int: sign-extend
    test rax, rax
    jz .Lhs_done
    cmp rax, -EAGAIN
    jne .Lhs_fail
    mov rdi, [rip + a_conn]
    call hc_tls_events
    mov edi, [rip + a_fd]
    mov esi, eax
    call watch_set_events
    EPILOGUE
.Lhs_done:
    call agent_send_begin
    EPILOGUE
.Lhs_fail:
    mov rdi, [rip + a_conn]
    call tls_last_error
    mov r12, rax
    lea rdi, [rip + .Lerr_tls]
    call agent_fail
    test r12, r12
    jz 1f
    mov rdi, r12
    call err
1:  EPILOGUE

# agent_fd(fd, revents, ctx)
agent_fd:
    PROLOGUE
    mov eax, [rip + a_state]
    cmp eax, AS_CONNECT
    je .Lfd_connect
    cmp eax, AS_HANDSHAKE
    je .Lfd_handshake
    cmp eax, AS_SEND
    je .Lfd_send
    cmp eax, AS_RECV
    je .Lfd_recv
    EPILOGUE
.Lfd_connect:
    mov edi, [rip + a_fd]
    call net_connect_result
    test rax, rax
    js .Lfd_netfail
    cmp qword ptr [rip + a_conn], 0
    je 1f
    mov dword ptr [rip + a_state], AS_HANDSHAKE
    mov edi, [rip + a_fd]
    mov esi, POLLOUT
    call watch_set_events
    call agent_handshake
    EPILOGUE
1:  call agent_send_begin
    EPILOGUE
.Lfd_handshake:
    call agent_handshake
    EPILOGUE
.Lfd_send:
    call agent_send_more
    EPILOGUE
.Lfd_recv:
    call agent_recv_more
    EPILOGUE
.Lfd_netfail:
    lea rdi, [rip + .Lerr_net]
    call agent_fail
    EPILOGUE

# ---- jobs ------------------------------------------------------------------
# agent_job_read(fd, revents, job*)
agent_job_read:
    PROLOGUE
    mov r12, rdx
1:  mov edi, [r12 + J_fd]
    mov rsi, [rip + a_recbuf]
    mov edx, RECV_CHUNK
    call os_read
    test rax, rax
    jg 2f
    js 3f
    jmp 4f
2:  mov rdi, [r12 + J_out]
    mov rsi, [rip + a_recbuf]
    mov rdx, rax
    call sb_push
    jmp 1b
3:  cmp rax, -EAGAIN
    je .Ljr_ret
    cmp rax, -EINTR
    je 1b                       # a signal must not look like EOF
4:  mov edi, [r12 + J_fd]
    call watch_remove
    mov rax, [r12 + J_tool]
    mov rax, [rax + TL_finish]
    test rax, rax
    jz 5f
    mov rdi, r12
    call rax
    jmp 6f
5:  mov rdi, r12
    call tool_done
6:  dec dword ptr [rip + a_pending]
    jnz .Ljr_ret
    call agent_tools_finished
.Ljr_ret:
    EPILOGUE

# agent_now_ms() -> rax: CLOCK_MONOTONIC in whole milliseconds.
agent_now_ms:
    PROLOGUE
    mov edi, CLOCK_MONOTONIC
    call os_now_ns
    mov rcx, 1000000
    xor edx, edx
    div rcx
    EPILOGUE

# agent_start_tools()
agent_start_tools:
    PROLOGUE
    mov qword ptr [rip + a_jobs + VEC_len], 0
    mov dword ptr [rip + a_pending], 0
    xor r12d, r12d
.Lst_loop:
    mov rdi, [rip + a_msg]
    call msg_toolcalls
    cmp r12d, eax
    jae .Lst_done
    mov rdi, [rip + a_msg]
    mov esi, r12d
    call msg_toolcall
    mov r13, rax
    mov rdi, [r13 + TC_name]
    call tools_find
    mov r14, rax
    mov edi, J_SIZE
    call mem_alloc
    mov rbx, rax
    mov [rbx + J_tool], r14
    mov rax, [r13 + TC_id]
    mov [rbx + J_call_id], rax
    mov rax, [r13 + TC_args]
    mov [rbx + J_args], rax
    mov edi, SB_SIZE
    call mem_alloc
    mov [rbx + J_out], rax
    call agent_now_ms
    mov [rbx + J_started_ms], rax
    test r14, r14
    jnz 1f
    mov rdi, rbx
    lea rsi, [rip + .Lunknown_tool]
    call job_error_text
    mov rdi, rbx
    call tool_done
    jmp .Lst_push
1:  mov rdi, [r13 + TC_name]
    mov rsi, [r13 + TC_args]
    call tool_validate
    test eax, eax
    jz 2f
    mov rdi, rbx
    lea rsi, [rip + .Lbad_args]
    call job_error_text
    mov rdi, rbx
    call tool_done
    jmp .Lst_push
2:  mov rdi, rbx
    mov rax, [rbx + J_tool]
    call [rax + TL_exec]
    test eax, eax
    js 3f
    cmp dword ptr [rbx + J_state], JS_DONE
    je .Lst_push
    mov edi, [rbx + J_fd]
    mov esi, POLLIN
    lea rdx, [rip + agent_job_read]
    mov rcx, rbx
    call watch_add
    test eax, eax
    js 4f
    inc dword ptr [rip + a_pending]
    jmp .Lst_push
4:  mov rdi, rbx
    lea rsi, [rip + .Lbad_watch]
    call job_error_text
    # watch_add failed *after* the child launched (JS_RUNNING): route through
    # the kill/reap/close path, not tool_done, or the child is orphaned and its
    # read fd leaks.  agent_kill_job is a no-op on a synchronously finished job.
    mov rdi, rbx
    call agent_kill_job
    jmp .Lst_push
3:  mov rdi, rbx
    lea rsi, [rip + .Lbad_exec]
    call job_error_text
    mov rdi, rbx
    call tool_done
.Lst_push:
    lea rdi, [rip + a_jobs]
    mov esi, 8
    call vec_push
    mov [rax], rbx
    inc r12d
    jmp .Lst_loop
.Lst_done:
    cmp dword ptr [rip + a_pending], 0
    jne 1f
    call agent_tools_finished
    EPILOGUE
1:  mov dword ptr [rip + a_state], AS_TOOLS
    EPILOGUE

# agent_tools_finished(): append tool_result messages in order, next turn
agent_tools_finished:
    PROLOGUE
    call agent_now_ms
    mov [rip + a_finish_ms], rax
    xor r12d, r12d
1:  cmp r12, [rip + a_jobs + VEC_len]
    jae 3f
    mov rax, [rip + a_jobs + VEC_ptr]
    mov rbx, [rax + r12*8]
    mov edi, MR_TOOL_RESULT
    call msg_new
    mov r13, rax
    mov rdi, r13
    mov rsi, [rbx + J_call_id]
    call msg_set_call_id
    mov eax, [rbx + J_flags]
    and eax, JF_ERROR
    test eax, eax
    jz 2f
    mov dword ptr [r13 + M_flags], MF_ERROR
2:  mov rdx, [rbx + J_out]
    mov rcx, [rdx + SB_len]
    mov rdx, [rdx + SB_ptr]
    test rdx, rdx
    jnz 4f
    lea rdx, [rip + .Lempty]
    xor ecx, ecx
4:  mov rdi, r13
    mov esi, BT_TEXT
    call msg_add_block
    lea rdi, [rip + a_tr]
    mov rsi, r13
    call tr_push
    mov rdi, r13
    call agent_session_append
    mov rax, [rip + g_agent_ui_fn]
    test rax, rax
    jz 5f
    mov rdi, [rip + g_agent_ui_ctx]
    mov esi, SE_TOOL_RESULT
    mov rdx, [rbx + J_out]
    mov rcx, [rdx + SB_len]
    mov rdx, [rdx + SB_ptr]
    call rax
    # SE_TOOL_EXEC: the full record the tool-card UI needs (name/args/result/
    # error/duration).  SE_TOOL_RESULT stays for older hooks.
    mov rcx, [rbx + J_call_id]
    mov [rip + a_te + TE_id], rcx
    mov rcx, [rbx + J_tool]
    test rcx, rcx
    jz 6f
    mov rcx, [rcx + TL_name]
    jmp 7f
6:  lea rcx, [rip + .Lunknown_name]
7:  mov [rip + a_te + TE_name], rcx
    mov rcx, [rbx + J_args]
    test rcx, rcx
    jnz 8f
    lea rcx, [rip + .Lempty]
8:  mov [rip + a_te + TE_args], rcx
    mov rcx, [rbx + J_out]
    mov rdx, [rcx + SB_ptr]
    mov [rip + a_te + TE_result], rdx
    mov rdx, [rcx + SB_len]
    mov [rip + a_te + TE_result_len], rdx
    xor ecx, ecx
    mov edx, [rbx + J_flags]
    and edx, JF_ERROR
    test edx, edx
    jz 9f
    mov ecx, 1
9:  mov [rip + a_te + TE_error], ecx
    mov rax, [rip + a_finish_ms]
    sub rax, [rbx + J_started_ms]
    mov [rip + a_te + TE_duration_ms], eax
    mov rax, [rip + g_agent_ui_fn]
    mov rdi, [rip + g_agent_ui_ctx]
    mov esi, SE_TOOL_EXEC
    lea rdx, [rip + a_te]
    xor ecx, ecx
    call rax
5:  # the message owns copies of everything it references now
    mov rdi, [rbx + J_out]
    call sb_free
    mov rdi, [rbx + J_out]
    call mem_free
    mov rdi, rbx
    call mem_free
    inc r12d
    jmp 1b
3:  mov qword ptr [rip + a_jobs + VEC_len], 0
    mov dword ptr [rip + a_state], AS_TURN
    EPILOGUE

# agent_abort_toolcalls(msg): append one error tool_result per BT_TOOLCALL
# block. A turn aborted after a tool_use block was completed must not leave it
# unanswered; providers reject that on the next turn.
agent_abort_toolcalls:
    PROLOGUE
    mov r12, rdi
    test r12, r12
    jz .Lat_done
    mov r13, [r12 + M_blocks]
    test r13, r13
    jz .Lat_done
    xor r14d, r14d
.Lat_loop:
    cmp r14, [r13 + VEC_len]
    jae .Lat_done
    mov rax, [r13 + VEC_ptr]
    mov rcx, r14
    imul rcx, rcx, B_SIZE
    add rax, rcx
    cmp dword ptr [rax + B_type], BT_TOOLCALL
    jne .Lat_next
    mov r15, [rax + B_ptr]
    mov edi, MR_TOOL_RESULT
    call msg_new
    mov rbx, rax
    mov rdi, rbx
    mov rsi, [r15 + TC_id]
    call msg_set_call_id
    or dword ptr [rbx + M_flags], MF_ERROR
    mov rdi, rbx
    mov esi, BT_TEXT
    lea rdx, [rip + .Laborted]
    mov ecx, .Laborted_len
    call msg_add_block
    lea rdi, [rip + a_tr]
    mov rsi, rbx
    call tr_push
    mov rdi, rbx
    call agent_session_append
.Lat_next:
    inc r14d
    jmp .Lat_loop
.Lat_done:
    EPILOGUE

# agent_session_append(msg rdi): append to the session when one is set
agent_session_append:
    test rdi, rdi
    jz 1f
    mov rsi, rdi
    mov rdi, [rip + g_agent_session]
    test rdi, rdi
    jz 1f
    jmp session_append_msg
1:  xor eax, eax
    ret

# agent_check_jobs(): kill children past their deadline
agent_check_jobs:
    PROLOGUE
    mov edi, CLOCK_MONOTONIC
    call os_now_ns
    mov rcx, 1000000
    xor edx, edx
    div rcx
    mov r13, rax                # now in ms
    xor r12d, r12d
1:  cmp r12, [rip + a_jobs + VEC_len]
    jae 2f
    mov rax, [rip + a_jobs + VEC_ptr]
    mov rbx, [rax + r12*8]
    cmp dword ptr [rbx + J_state], JS_RUNNING
    jne 3f
    mov rax, [rbx + J_deadline_ms]
    test rax, rax
    jz 3f
    cmp r13, rax
    jb 3f
    or dword ptr [rbx + J_flags], JF_TIMEOUT
    mov qword ptr [rbx + J_deadline_ms], 0
    mov rdi, [rbx + J_pid]
    mov esi, 9                  # SIGKILL
    call os_kill_group
3:  inc r12d
    jmp 1b
2:  EPILOGUE

# ---- request construction ---------------------------------------------------
# path_join(base_ptr, base_len, pv_path cstr) -> a_pathbuf/a_pathlen
path_join:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    xor ebx, ebx
    lea r8, [rip + a_pathbuf]
    cmp r13, 1
    jne 1f
    cmp byte ptr [r12], '/'
    je 4f
1:  cmp rbx, 511
    jae 3f
    cmp rbx, r13
    jae 3f
    mov al, [r12 + rbx]
    mov [r8 + rbx], al
    inc rbx
    jmp 1b
3:  cmp rbx, 0
    je 4f
    cmp byte ptr [r8 + rbx - 1], '/'
    jne 4f
    dec rbx
4:  xor ecx, ecx
5:  cmp rbx, 511
    jae 6f
    mov al, [r14 + rcx]
    test al, al
    jz 6f
    mov [r8 + rbx], al
    inc rbx
    inc rcx
    jmp 5b
6:  mov byte ptr [r8 + rbx], 0
    mov [rip + a_pathlen], rbx
    EPILOGUE

# agent_build_request() -> 0|-errno
agent_build_request:
    PROLOGUE
    call agent_build_body
    call agent_build_headers
    EPILOGUE

# agent_build_body(): system prompt + provider JSON body -> 0|-errno
agent_build_body:
    PROLOGUE
    # system prompt
    lea rdi, [rip + a_sys_sb]
    call sb_clear
    cmp qword ptr [rip + g_agent_system], 0
    je 1f
    lea rdi, [rip + a_sys_sb]
    mov rsi, [rip + g_agent_system]
    call sb_push_cstr
    jmp 2f
1:  call tools_active
    mov rsi, rax
    lea rdi, [rip + a_sys_sb]
    lea rdx, [rip + a_cwdbuf]
    call prompt_build
2:  # JSON body
    lea rdi, [rip + a_body_sb]
    call sb_clear
    mov rdi, [rip + a_pvctx]
    lea rsi, [rip + a_body_sb]
    mov rdx, [rip + a_sys_sb + SB_ptr]
    lea rcx, [rip + a_tr]
    mov rax, [rip + a_pv]
    call [rax + PV_build]
    xor eax, eax
    EPILOGUE

# agent_build_headers(): parse the base URL, join the provider path and build
# the HTTP request bytes (request line, auth headers, body) from a_body_sb.
# Refactored out of agent_build_request so compaction can reuse it.
agent_build_headers:
    PROLOGUE
    # base url -> host, path
    cmp qword ptr [rip + g_agent_base], 0
    je 3f
    mov rdi, [rip + g_agent_base]
    jmp 4f
3:  mov rax, [rip + a_md]
    mov rdi, [rax + MD_base]
4:  lea rsi, [rip + a_url]
    call url_parse
    test rax, rax
    js .Lbh_bad
    lea rdi, [rip + a_url]
    lea rsi, [rip + a_hostbuf]
    mov edx, 512
    call url_copy_host
    test rax, rax
    js .Lbh_bad
    mov [rip + a_hostlen], rax
    # Host: header carries the port when it is not the scheme default; SNI
    # (tls_new) keeps the host-only a_hostbuf
    lea rdi, [rip + a_url]
    lea rsi, [rip + a_authority]
    mov edx, 528
    call url_authority
    test rax, rax
    js .Lbh_bad
    mov [rip + a_authlen], rax
    mov rdi, [rip + a_pvctx]
    mov rax, [rip + a_pv]
    call [rax + PV_path]
    mov rdx, rax
    mov rdi, [rip + a_url + U_path]
    mov esi, [rip + a_url + U_path_len]
    call path_join
    # request bytes
    lea rdi, [rip + a_req_sb]
    call sb_clear
    lea rdi, [rip + a_req_sb]
    lea rsi, [rip + .Lm_post]
    lea rdx, [rip + a_authority]
    mov ecx, [rip + a_authlen]
    lea r8, [rip + a_pathbuf]
    mov r9d, [rip + a_pathlen]
    call http_req_begin
    lea rdi, [rip + a_req_sb]
    lea rsi, [rip + .Lh_ctype]
    lea rdx, [rip + .Lct_json]
    call http_req_header_cstr
    lea rdi, [rip + a_req_sb]
    lea rsi, [rip + .Lh_accept]
    lea rdx, [rip + .Laccept_sse]
    call http_req_header_cstr
    lea rdi, [rip + a_req_sb]
    lea rsi, [rip + .Lh_ua]
    lea rdx, [rip + .Lua]
    call http_req_header_cstr
    # auth headers (MDF_NO_KEY providers send none)
    mov rax, [rip + a_md]
    test dword ptr [rax + MD_flags], MDF_NO_KEY
    jnz 6f
    mov rax, [rip + a_md]
    mov rdi, [rax + MD_api]
    lea rsi, [rip + .Lapi_anthropic]
    call cstr_eq
    test eax, eax
    jz 5f
    call auth_last_was_oauth
    test eax, eax
    jz 41f
    # OAuth subscription token: Bearer + oauth beta
    lea rdi, [rip + a_authbuf]
    lea rsi, [rip + .Lbearer]
    call strcpy_bounded
    lea rdi, [rip + a_authbuf]
    mov rsi, [rip + a_key]
    call strcat_bounded
    lea rdi, [rip + a_authbuf]
    call strlen
    mov rcx, rax
    lea rdx, [rip + a_authbuf]
    lea rdi, [rip + a_req_sb]
    lea rsi, [rip + .Lh_auth]
    call http_req_header
    lea rdi, [rip + a_req_sb]
    lea rsi, [rip + .Lh_beta]
    lea rdx, [rip + .Lbeta_oauth]
    call http_req_header_cstr
    lea rdi, [rip + a_req_sb]
    lea rsi, [rip + .Lh_ver]
    lea rdx, [rip + .Lver]
    call http_req_header_cstr
    jmp 6f
41: lea rdi, [rip + a_req_sb]
    lea rsi, [rip + .Lh_xkey]
    mov rdx, [rip + a_key]
    call http_req_header_cstr
    lea rdi, [rip + a_req_sb]
    lea rsi, [rip + .Lh_ver]
    lea rdx, [rip + .Lver]
    call http_req_header_cstr
    jmp 6f
5:  # Authorization: Bearer <key>
    lea rdi, [rip + a_authbuf]
    lea rsi, [rip + .Lbearer]
    call strcpy_bounded
    lea rdi, [rip + a_authbuf]
    mov rsi, [rip + a_key]
    call strcat_bounded
    lea rdi, [rip + a_authbuf]
    call strlen
    mov rcx, rax
    lea rdx, [rip + a_authbuf]
    lea rdi, [rip + a_req_sb]
    lea rsi, [rip + .Lh_auth]
    call http_req_header
6:  lea rdi, [rip + a_req_sb]
    mov rsi, [rip + a_body_sb + SB_ptr]
    mov rdx, [rip + a_body_sb + SB_len]
    call http_req_body
    # tls?
    mov eax, [rip + a_url + U_flags]
    and eax, UF_TLS
    mov [rip + a_tls], eax
    xor eax, eax
    EPILOGUE
.Lbh_bad:
    lea rdi, [rip + .Lerr_net]
    call agent_fail
    mov rax, -EINVAL
    EPILOGUE

# strcpy_bounded(dst, src) -> dst (512-byte domain buffers only)
strcpy_bounded:
    xor ecx, ecx
1:  mov al, [rsi + rcx]
    mov [rdi + rcx], al
    test al, al
    jz 2f
    inc ecx
    cmp ecx, 510
    jb 1b
    mov byte ptr [rdi + 511], 0
2:  mov rax, rdi
    ret

# strcat_bounded(dst, src) -> dst; dst is a 512-byte domain buffer
strcat_bounded:
    push rdi
    call strlen
    pop rdi
    mov rcx, rax                # current dst length
    cmp rcx, 511
    jb 1f
    mov byte ptr [rdi + 511], 0
    mov rax, rdi
    ret
1:  xor edx, edx                # src index
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

# ---- connection -------------------------------------------------------------
# agent_open_connection(): connect (or replay)
agent_open_connection:
    PROLOGUE
    lea rdi, [rip + a_hostbuf]
    lea rsi, [rip + a_ip]
    mov edx, CONNECT_TIMEOUT_MS
    call hc_resolve_host
    test rax, rax
    js .Loc_bad
    call net_socket
    test rax, rax
    js .Loc_bad
    mov [rip + a_fd], rax
    mov edi, eax
    mov esi, [rip + a_ip]
    movzx edx, word ptr [rip + a_url + U_port]
    rol dx, 8
    mov ecx, CONNECT_TIMEOUT_MS
    call net_connect
    cmp rax, -EINPROGRESS
    je 3f
    test rax, rax
    js .Loc_bad
3:  # TLS context (handshake runs from the fd handler)
    cmp dword ptr [rip + a_tls], 0
    je 4f
    lea rdi, [rip + a_hostbuf]
    movzx esi, word ptr [rip + a_url + U_port]
    mov edx, TLS_VERIFY
    call tls_new
    test rax, rax
    jz .Loc_bad
    mov [rip + a_conn], rax
    mov rdi, rax
    mov rsi, [rip + a_fd]
    call tls_set_fd
4:  mov dword ptr [rip + a_state], AS_CONNECT
    mov edi, [rip + a_fd]
    mov esi, POLLOUT
    lea rdx, [rip + agent_fd]
    xor ecx, ecx
    call watch_add
    EPILOGUE
.Loc_bad:
    lea rdi, [rip + .Lerr_net]
    call agent_fail
    EPILOGUE

# ---- replay ------------------------------------------------------------------
# agent_replay_next() -> rax payload ptr, rdx len; rax=0 at EOF; rax=-1 malformed
# Consumes the next dir=1 FWIR1 record, skipping dir=0 (client -> server) ones
# and advancing a_rep_off. Shared by agent_replay_turn and the blocking
# compaction request.
agent_replay_next:
    mov r8, [rip + a_rep_ptr]
    mov r9, [rip + a_rep_len]
    mov r10, [rip + a_rep_off]
.Lrn_loop:
    lea rax, [r10 + 5]
    cmp rax, r9
    ja .Lrn_end
    movzx ecx, byte ptr [r8 + r10]
    mov edx, [r8 + r10 + 1]
    add r10, 5
    mov rax, r9
    sub rax, r10
    cmp rax, rdx
    jb .Lrn_bad
    lea rax, [r8 + r10]
    add r10, rdx
    mov [rip + a_rep_off], r10
    test ecx, ecx
    jnz .Lrn_have
    jmp .Lrn_loop
.Lrn_end:
    xor eax, eax
    ret
.Lrn_bad:
    mov rax, -1
    ret
.Lrn_have:
    ret

# agent_replay_turn(): feed the next response records for one turn
agent_replay_turn:
    PROLOGUE
.Lrp_loop:
    cmp dword ptr [rip + a_done], 0
    jne .Lrp_after
    call agent_replay_next
    test rax, rax
    jz .Lrp_finish
    js .Lrp_bad
    lea rdi, [rip + a_resp]
    mov rsi, rax
    call http_resp_feed
    jmp .Lrp_loop
.Lrp_finish:
    cmp dword ptr [rip + a_done], 0
    jne .Lrp_after
    mov rdi, [rip + a_pvctx]
    lea rsi, [rip + a_sink]
    mov rax, [rip + a_pv]
    call [rax + PV_finish]
.Lrp_after:
    call agent_finish_turn
    EPILOGUE
.Lrp_bad:
    lea rdi, [rip + .Lerr_replay]
    call agent_fail
    EPILOGUE

# ---- compaction request ------------------------------------------------------
# Blocking transport used by compact_maybe_run. None of this touches a_msg or
# a_sink: the summarize response parses into a_cresp -> a_csse ->
# agent_sse_sink -> a_csink, a local sink that captures the summary text.

# agent_c_on_body(ctx=&a_csse, ptr, len): feed the local SSE parser
agent_c_on_body:
    jmp sse_feed

# agent_csink(SS*, event, a, b): collect SE_TEXT deltas, flag SE_DONE/SE_ERROR
agent_csink:
    cmp esi, SE_TEXT
    je .Lcs_text
    cmp esi, SE_DONE
    je .Lcs_done
    cmp esi, SE_ERROR
    jne .Lcs_ret
    mov dword ptr [rip + a_cdone], 1
    mov [rip + a_cerr], rdx
.Lcs_ret:
    ret
.Lcs_done:
    mov dword ptr [rip + a_cdone], 1
    ret
.Lcs_text:
    mov rsi, rdx
    mov rdx, rcx
    lea rdi, [rip + a_csum_sb]
    jmp sb_push

# log_compacted(n): "opcode: compacted N tokens\n" on stderr
log_compacted:
    PROLOGUE 32
    mov r12, rdi
    mov edi, 2
    lea rsi, [rip + .Lprefix]
    call out_cstr
    mov edi, 2
    lea rsi, [rip + .Lcompacted]
    call out_cstr
    lea rdi, [rsp]
    mov rsi, r12
    call fmt_u64
    mov edi, 2
    lea rsi, [rsp]
    mov rdx, rax
    call write_all
    mov edi, 2
    lea rsi, [rip + .Ltokens]
    call out_cstr
    EPILOGUE

# ag_restore_tr_cur(): make a_tr the current transcript again after the
# scratch tr_free cleared g_tr_cur, so later msg_* allocations stay tracked.
# tr_push sets it, then the duplicate tail entry is dropped.
ag_restore_tr_cur:
    PROLOGUE
    lea rdi, [rip + a_tr]
    call tr_len
    test rax, rax
    jz .Lrc_ret
    lea rdi, [rip + a_tr]
    lea rsi, [rax - 1]
    call tr_msg
    test rax, rax
    jz .Lrc_ret
    mov rsi, rax
    lea rdi, [rip + a_tr]
    call tr_push
    mov rax, [rip + a_tr + TR_msgs]
    test rax, rax
    jz .Lrc_ret
    mov rcx, [rax + VEC_len]
    test rcx, rcx
    jz .Lrc_ret
    dec rcx
    mov [rax + VEC_len], rcx
.Lrc_ret:
    EPILOGUE

# agent_request_blocking(on_event_fn, ctx) -> 0 | -errno
#   Sends the already-built a_req_sb over a fresh blocking connection (or
#   consumes the next FWIR1 records when g_agent_replay is set) and feeds body
#   bytes into a local a_cresp parser -> a_csse(on_event_fn, ctx). PV_finish is
#   called with a_csink before returning, so the local sink always sees
#   SE_DONE or SE_ERROR. The transport is closed on every path.
agent_request_blocking:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    lea rdi, [rip + a_cresp]
    call http_resp_free
    lea rdi, [rip + a_cresp]
    lea rsi, [rip + agent_c_on_body]
    lea rdx, [rip + a_csse]
    call http_resp_init
    lea rdi, [rip + a_csse]
    mov rsi, r12
    mov rdx, r13
    call sse_init
    cmp qword ptr [rip + g_agent_replay], 0
    jne .Lrb_replay

    # ---- live: one blocking request on a_hc ----
    lea rdi, [rip + a_hc]
    call hc_init
    lea rdi, [rip + a_hc]
    mov rsi, [rip + a_recbuf]
    mov edx, RECV_CHUNK
    call hc_set_recbuf
    mov rax, [rip + g_agent_base]
    test rax, rax
    jnz 1f
    mov rax, [rip + a_md]
    mov rax, [rax + MD_base]
1:  lea rdi, [rip + a_hc]
    mov rsi, rax
    xor edx, edx
    mov ecx, CMP_CONNECT_TIMEOUT_MS
    mov r8, CMP_CONNECT_TIMEOUT_NS
    xor r9d, r9d
    call hc_connect
    test rax, rax
    js .Lrb_connect_fail
    mov edi, CLOCK_MONOTONIC
    call os_now_ns
    mov rdx, rax
    mov rax, CMP_TURN_TIMEOUT_NS
    add rdx, rax
    mov [rip + a_deadline], rdx
    mov edi, [rip + a_hc + HC_fd]
    mov rsi, [rip + a_hc + HC_conn]
    mov rdx, [rip + a_req_sb + SB_ptr]
    mov rcx, [rip + a_req_sb + SB_len]
    mov r8, [rip + a_deadline]
    call hc_send_all
    test rax, rax
    js .Lrb_netfail
.Lrb_recv_loop:
    cmp dword ptr [rip + a_cdone], 0
    jne .Lrb_done
    lea rdi, [rip + a_cresp]
    call http_resp_done
    test eax, eax
    jnz .Lrb_done
    mov rdi, [rip + a_hc + HC_conn]
    mov esi, [rip + a_hc + HC_fd]
    mov rdx, [rip + a_recbuf]
    mov rcx, RECV_CHUNK
    call hc_recv_some
    test rax, rax
    jg .Lrb_recv_data
    jz .Lrb_recv_eof
    cmp rax, -EAGAIN
    je .Lrb_recv_wait
    jmp .Lrb_netfail
.Lrb_recv_data:
    mov r14, rax
    lea rdi, [rip + a_cresp]
    mov rsi, [rip + a_recbuf]
    mov rdx, r14
    call http_resp_feed
    jmp .Lrb_recv_loop
.Lrb_recv_eof:
    lea rdi, [rip + a_cresp]
    call http_resp_eof
    jmp .Lrb_done
.Lrb_recv_wait:
    mov eax, POLLIN
    cmp qword ptr [rip + a_hc + HC_conn], 0
    je 1f
    mov rdi, [rip + a_hc + HC_conn]
    call hc_tls_events
1:  mov r12d, eax
    mov edi, [rip + a_hc + HC_fd]
    mov esi, r12d
    mov rdx, [rip + a_deadline]
    call hc_wait_io
    test rax, rax
    js .Lrb_netfail
    jmp .Lrb_recv_loop

    # ---- replay: consume the next server -> client records ----
.Lrb_replay:
.Lrb_rp_loop:
    cmp dword ptr [rip + a_cdone], 0
    jne .Lrb_done
    call agent_replay_next
    test rax, rax
    jz .Lrb_rp_eof
    js .Lrb_replay_bad
    lea rdi, [rip + a_cresp]
    mov rsi, rax
    call http_resp_feed
    jmp .Lrb_rp_loop
.Lrb_rp_eof:
    lea rdi, [rip + a_cresp]
    call http_resp_eof
    jmp .Lrb_done
.Lrb_replay_bad:
    mov r15, -EINVAL
    jmp .Lrb_fail

.Lrb_done:
    lea rdi, [rip + a_hc]
    call hc_close
    mov rdi, [rip + a_pvctx]
    lea rsi, [rip + a_csink]
    mov rax, [rip + a_pv]
    call [rax + PV_finish]
    xor eax, eax
    EPILOGUE
.Lrb_connect_fail:
    # bad IP was -EINVAL, TLS failures -EIO, everything else the raw errno
    mov ecx, [rip + a_hc + HC_stage]
    cmp ecx, HC_STAGE_URL
    je .Lrb_badip
    cmp ecx, HC_STAGE_RESOLVE
    jne 1f
    cmp rax, -EINVAL
    jne .Lrb_netfail
    lea rdi, [rip + a_hostbuf]
    call net_is_ip4
    test eax, eax
    jnz .Lrb_badip
    jmp .Lrb_netfail
1:  cmp ecx, HC_STAGE_TLS
    je .Lrb_tlsfail
    cmp ecx, HC_STAGE_HANDSHAKE
    je .Lrb_tlsfail
    jmp .Lrb_netfail
.Lrb_badip:
    mov r15, -EINVAL
    jmp .Lrb_fail
.Lrb_tlsfail:
    mov r15, -EIO
    jmp .Lrb_fail
.Lrb_netfail:
    mov r15, rax
.Lrb_fail:
    lea rdi, [rip + a_hc]
    call hc_close
    mov rax, r15
    EPILOGUE

# compact_maybe_run(): summarize the older transcript before the first turn.
# Called from agent_init after the provider/model/ctx, replay file and session
# are resolved. No-op unless compact_needed(); on success the request summary
# replaces messages [0, cut) and a "compaction" custom entry is recorded.
FN compact_maybe_run
    xor esi, esi
    jmp ag_compact_do

# agent_compact() -> 0 | -EBUSY.  Manual /compact entry point: runs the same
# summarization path as the automatic check, ignoring the threshold.  Refuses
# while a turn is in flight (the compaction scratch shares the turn state).
FN agent_compact
    PROLOGUE
    call agent_busy
    test eax, eax
    jnz .Lac_busy
    mov esi, 1
    call ag_compact_do
    EPILOGUE
.Lac_busy:
    mov rax, -EBUSY
    EPILOGUE

# ag_compact_do(esi force) -> 0; shared body.  force=0 honours compact_needed,
# force=1 compacts unconditionally (still a no-op on an empty transcript).
ag_compact_do:
    PROLOGUE 16
    mov dword ptr [rsp], esi
    lea rdi, [rip + a_tr]
    call compact_estimate
    mov r15, rax                    # tokens_before
    test r15, r15
    jz .Lcm_ret
    cmp dword ptr [rsp], 0
    jne .Lcm_force
    mov rdi, r15
    mov rsi, [rip + a_md]
    call compact_needed
    test eax, eax
    jz .Lcm_ret
.Lcm_force:
    lea rdi, [rip + a_tr]
    mov esi, COMPACT_KEEP_TOKENS
    call compact_cut
    mov r14, rax                    # cut
    lea rdi, [rip + a_cprompt_sb]
    call sb_clear
    lea rdi, [rip + a_cprompt_sb]
    lea rsi, [rip + a_tr]
    mov rdx, r14
    call compact_prompt
    # scratch transcript with exactly one user message
    lea rdi, [rip + a_ctmp]
    call tr_init
    mov edi, MR_USER
    call msg_new
    mov r12, rax
    mov rdi, r12
    mov esi, BT_TEXT
    mov rdx, [rip + a_cprompt_sb + SB_ptr]
    mov rcx, [rip + a_cprompt_sb + SB_len]
    call msg_add_block
    lea rdi, [rip + a_ctmp]
    mov rsi, r12
    call tr_push
    # JSON body with an empty system prompt
    lea rdi, [rip + a_body_sb]
    call sb_clear
    mov rdi, [rip + a_pvctx]
    lea rsi, [rip + a_body_sb]
    lea rdx, [rip + .Lempty]
    lea rcx, [rip + a_ctmp]
    mov rax, [rip + a_pv]
    call [rax + PV_build]
    call agent_build_headers
    test eax, eax
    js .Lcm_cleanup
    # local sink state
    lea rdi, [rip + a_csum_sb]
    call sb_clear
    mov dword ptr [rip + a_cdone], 0
    mov qword ptr [rip + a_cerr], 0
    lea rax, [rip + agent_csink]
    mov [rip + a_csink + SS_fn], rax
    mov qword ptr [rip + a_csink + SS_ctx], 0
    lea rdi, [rip + agent_sse_sink]
    lea rsi, [rip + a_csink]
    call agent_request_blocking
    test rax, rax
    js .Lcm_fail
    cmp dword ptr [rip + a_cdone], 0
    je .Lcm_fail
    cmp qword ptr [rip + a_cerr], 0
    jne .Lcm_fail
    # apply and log the reduction
    lea rdi, [rip + a_tr]
    call tr_len
    sub rax, r14
    mov [rsp + 8], rax              # kept_messages = before_n - cut
    lea rdi, [rip + a_tr]
    mov rsi, r14
    mov rdx, [rip + a_csum_sb + SB_ptr]
    call compact_apply
    # notify front ends before the session record: a = tokens_before, b = kept
    lea rdi, [rip + a_sink]
    mov esi, SE_COMPACT
    mov edx, r15d
    mov ecx, [rsp + 8]
    call agent_sink
    lea rdi, [rip + a_tr]
    call compact_estimate
    mov r13, r15
    sub r13, rax
    jns 1f
    xor r13d, r13d
1:  mov rdi, r13
    call log_compacted
    # session custom entry
    mov rdi, [rip + g_agent_session]
    test rdi, rdi
    jz .Lcm_cleanup
    lea rdi, [rip + a_cjson_sb]
    call sb_clear
    lea rdi, [rip + a_cjson_sb]
    call jsonw_obj
    lea rdi, [rip + a_cjson_sb]
    lea rsi, [rip + .K_first_kept]
    call jsonw_key
    lea rdi, [rip + a_cjson_sb]
    mov rsi, r14
    call jsonw_u64
    lea rdi, [rip + a_cjson_sb]
    lea rsi, [rip + .K_tokens_before]
    call jsonw_key
    lea rdi, [rip + a_cjson_sb]
    mov rsi, r15
    call jsonw_u64
    lea rdi, [rip + a_cjson_sb]
    call jsonw_obj_end
    mov rdi, [rip + g_agent_session]
    lea rsi, [rip + .Lcustom_compaction]
    mov rdx, [rip + a_cjson_sb + SB_ptr]
    call session_append_custom
    jmp .Lcm_cleanup
.Lcm_fail:
    lea rdi, [rip + .Lcfail]
    call err
    mov rdi, [rip + a_cerr]
    test rdi, rdi
    jz .Lcm_cleanup
    call err
.Lcm_cleanup:
    call ag_restore_tr_cur
    lea rdi, [rip + a_ctmp]
    call tr_free
    lea rdi, [rip + a_cprompt_sb]
    call sb_free
    lea rdi, [rip + a_csum_sb]
    call sb_free
    lea rdi, [rip + a_cjson_sb]
    call sb_free
.Lcm_ret:
    xor eax, eax
    EPILOGUE

# ---- turn ---------------------------------------------------------------------
# agent_finish_turn(): close transport, decide tools vs next turn vs done
agent_finish_turn:
    PROLOGUE
    cmp qword ptr [rip + a_fd], 0
    jl 1f
    mov edi, [rip + a_fd]
    call watch_remove
    cmp qword ptr [rip + a_conn], 0
    je 2f
    mov rdi, [rip + a_conn]
    call tls_close
    mov qword ptr [rip + a_conn], 0
2:  mov edi, [rip + a_fd]
    mov esi, SHUT_RDWR
    call net_shutdown
    mov edi, [rip + a_fd]
    call net_close
    mov qword ptr [rip + a_fd], -1
1:  mov rbx, [rip + a_msg]
    lea rdi, [rip + a_tr]
    mov rsi, rbx
    call tr_push
    mov rdi, rbx
    call agent_session_append
    mov eax, [rbx + M_stop]
    cmp eax, SR_TOOL_USE
    jne 3f
    mov rdi, rbx
    call msg_toolcalls
    test eax, eax
    jz 3f
    call agent_start_tools
    EPILOGUE
3:  cmp eax, SR_ERROR
    je 4f
    cmp eax, SR_ABORTED
    jne 5f
4:  mov dword ptr [rip + a_exit], 1
    mov dword ptr [rip + a_state], AS_ERROR
    EPILOGUE
5:  mov dword ptr [rip + a_state], AS_DONE
    EPILOGUE

# agent_start_turn()
agent_start_turn:
    PROLOGUE
    inc qword ptr [rip + a_turn]
    mov dword ptr [rip + a_done], 0
    mov dword ptr [rip + a_exit], 0
    mov edi, CLOCK_MONOTONIC
    call os_now_ns
    mov rdx, TURN_TIMEOUT_MS
    imul rdx, rdx, 1000000
    add rax, rdx
    mov [rip + a_deadline], rax
    # defensive teardown: a submit is guarded by agent_busy, but a half-open
    # turn must never leak its fd or leave a stale watch behind
    cmp qword ptr [rip + a_fd], 0
    jl 7f
    mov edi, [rip + a_fd]
    call watch_remove
    cmp qword ptr [rip + a_conn], 0
    je 6f
    mov rdi, [rip + a_conn]
    call tls_close
    mov qword ptr [rip + a_conn], 0
6:  mov edi, [rip + a_fd]
    call net_close
7:  mov qword ptr [rip + a_fd], -1
    mov qword ptr [rip + a_conn], 0
    mov edi, MR_ASSISTANT
    call msg_new
    mov [rip + a_msg], rax
    lea rdi, [rip + a_text]
    call sb_clear
    lea rdi, [rip + a_think]
    call sb_clear
    lea rdi, [rip + a_targs]
    call sb_clear
    # release the previous turn's parser heap before re-initializing; init no
    # longer zeroes the buffer, so the first (bss-zero) turn stays safe
    lea rdi, [rip + a_resp]
    call http_resp_free
    lea rdi, [rip + a_resp]
    lea rsi, [rip + agent_on_body]
    xor edx, edx
    call http_resp_init
    lea rdi, [rip + a_sse]
    lea rsi, [rip + agent_sse]
    xor edx, edx
    call sse_init
    mov dword ptr [rip + a_http_status], 0
    lea rdi, [rip + a_errbody]
    call sb_clear
    call agent_build_request
    test eax, eax
    js .Lst_reqfail
    cmp qword ptr [rip + g_agent_replay], 0
    je 1f
    call agent_replay_turn
    EPILOGUE
1:  call agent_open_connection
    EPILOGUE
.Lst_reqfail:
    # agent_build_request already reported and closed through agent_fail;
    # make sure no half-open transport survives and stay in AS_ERROR
    mov edi, [rip + a_fd]
    cmp edi, 0
    jl 3f
    call watch_remove
    cmp qword ptr [rip + a_conn], 0
    je 2f
    mov rdi, [rip + a_conn]
    call tls_close
    mov qword ptr [rip + a_conn], 0
2:  mov edi, [rip + a_fd]
    call net_close
    mov qword ptr [rip + a_fd], -1
3:  mov dword ptr [rip + a_state], AS_ERROR
    EPILOGUE

# ---- entry ---------------------------------------------------------------------
# agent_run(prompt cstr) -> exit code
FN agent_init
    PROLOGUE
    lea rax, [rip + agent_sink]
    mov [rip + a_sink + SS_fn], rax
    mov qword ptr [rip + a_sink + SS_ctx], 0
    mov edi, RECV_CHUNK
    cmp qword ptr [rip + a_recbuf], 0
    jne 0f
    call mem_alloc
    mov [rip + a_recbuf], rax
0:  cmp qword ptr [rip + g_offline], 0
    je .Lar_notoffline
    cmp qword ptr [rip + g_agent_replay], 0
    jne .Lar_notoffline
    lea rdi, [rip + .Lerr_offline]
    call err
    mov eax, 1
    EPILOGUE
.Lar_notoffline:
    lea rdi, [rip + a_tr]
    call tr_init
    call tools_init
    call plugins_init
    call mcp_start
    mov rdi, [rip + g_agent_session]
    test rdi, rdi
    jz 0f
    lea rsi, [rip + a_tr]
    call session_load
    test rax, rax
    js .Lar_session_err
0:  mov qword ptr [rip + a_fd], -1
    mov dword ptr [rip + a_turn], 0
    lea rdi, [rip + a_cwdbuf]
    mov esi, 512
    call os_getcwd
    # discovered models must be in the lookup table before provider/model resolution
    call catalog_load_user
    # provider: flag > session > config > "openai"
    mov rdi, [rip + g_agent_provider]
    test rdi, rdi
    jnz 1f
    mov rax, [rip + g_agent_session]
    test rax, rax
    jz 11f
    mov rdi, rax
    call session_provider
    test rax, rax
    jnz 12f
11: lea rdi, [rip + .Lcfg_provider]
    call config_str
    test rax, rax
    jnz 12f
    lea rax, [rip + .Lanon]
12: mov rdi, rax
1:  mov r12, rdi
    # model: flag > session > config default_model > catalog default
    mov rsi, [rip + g_agent_model]
    test rsi, rsi
    jnz 2f
    mov rax, [rip + g_agent_session]
    test rax, rax
    jz 21f
    mov rdi, rax
    call session_model
    mov rsi, rax
    test rsi, rsi
    jnz 2f
21: lea rdi, [rip + .Lcfg_model]
    call config_str
    mov rsi, rax
    test rsi, rsi
    jnz 2f
    mov rdi, r12
    call catalog_default
    jmp 3f
2:  mov rdi, r12
    call catalog_find
3:  test rax, rax
    jz .Lar_nomodel
    mov [rip + a_md], rax
    # API key: MDF_NO_KEY models need none and agent_build_headers sends no
    # auth headers for them (e.g. local ollama)
    test dword ptr [rax + MD_flags], MDF_NO_KEY
    jnz 31f
    mov rdi, r12
    call auth_key
    test rax, rax
    jz .Lar_nokey
    mov [rsp], rax
    mov rdi, [rip + a_key]
    call mem_free
    mov rax, [rsp]
    mov [rip + a_key], rax
31: mov rax, [rip + a_md]
    mov rdi, [rax + MD_api]
    call prov_for_api
5:  mov [rip + a_pv], rax
    mov rdi, [rip + a_md]
    call [rax + PV_new]
    mov [rip + a_pvctx], rax
    # max tokens: explicit flag, catalog, 4096
    mov eax, [rip + g_agent_max_tokens]
    test eax, eax
    jnz 6f
    mov rdx, [rip + a_md]
    mov eax, [rdx + MD_max_tokens]
    test eax, eax
    jnz 6f
    mov eax, 4096
6:  mov rdx, [rip + a_pvctx]
    mov [rdx + 8], eax
7:  cmp qword ptr [rip + g_agent_session], 0
    je 10f
    mov rdi, [rip + g_agent_session]
    call session_provider
    mov r13, rax
    test rax, rax
    jz 9f
    mov rdi, r13
    mov rsi, r12
    call cstr_eq
    test eax, eax
    jz 9f
    mov rdi, [rip + g_agent_session]
    call session_model
    mov rdi, rax
    test rax, rax
    jz 9f
    mov rdx, [rip + a_md]
    mov rsi, [rdx + MD_id]
    call cstr_eq
    test eax, eax
    jnz 10f
9:  mov rdi, [rip + g_agent_session]
    mov rsi, r12
    mov rdx, [rip + a_md]
    mov rdx, [rdx + MD_id]
    call session_append_model
10:
    # replay file
    cmp qword ptr [rip + g_agent_replay], 0
    je 18f
    lea rdi, [rip + a_file_sb]
    call sb_clear
    mov rdi, [rip + g_agent_replay]
    lea rsi, [rip + a_file_sb]
    call read_file
    test rax, rax
    js .Lar_badreplay
    mov rax, [rip + a_file_sb + SB_len]
    cmp rax, 6
    jb .Lar_badreplay
    mov rdi, [rip + a_file_sb + SB_ptr]
    lea rsi, [rip + .Lmagic]
    mov edx, 6
    call memeq
    test eax, eax
    jz .Lar_badreplay
    mov rax, [rip + a_file_sb + SB_ptr]
    mov [rip + a_rep_ptr], rax
    mov rax, [rip + a_file_sb + SB_len]
    mov [rip + a_rep_len], rax
    mov qword ptr [rip + a_rep_off], 6
18: # thinking: the --thinking flag already stored 0..3; otherwise apply the
    # config default_thinking, else leave the default off
    cmp dword ptr [rip + g_agent_thinking], 0
    jge 19f
    call config_default_thinking
    test rax, rax
    jz 19f
    mov rbx, rax
    mov rdi, rax
    call agent_thinking_parse
    mov r12d, eax
    mov rdi, rbx
    call mem_free
    test r12d, r12d
    js 19f
    mov esi, r12d
    call agent_set_thinking
19:
7:  xor eax, eax
    EPILOGUE
.Lar_nokey:
    lea rdi, [rip + .Lerr_nokey]
    call agent_fail
    mov eax, 1
    EPILOGUE
.Lar_nomodel:
    lea rdi, [rip + .Lerr_model]
    call agent_fail
    mov eax, 1
    EPILOGUE
.Lar_session_err:
    # session_load already printed the schema refusal and why; the caller
    # (agent_run/TUI/modes) maps the non-zero return to exit 1.
    mov eax, 1
    EPILOGUE
.Lar_badreplay:
    lea rdi, [rip + .Lerr_replay]
    call agent_fail
    mov eax, 1
    EPILOGUE

# ---------------------------------------------------------------------------
# agent_reset_session(sdir cstr|0, cwd cstr|0) -> 0 | -EIO
# Close the active session and open a fresh one (same session dir/cwd), writing
# its header + model_change so a session resumed after `/new` keeps the
# resolved provider/model.  The old session stays active when the new one
# cannot be created, so persistence is never silently disabled.
FN agent_reset_session
    PROLOGUE 16
    mov rax, [rip + g_agent_session]
    mov [rsp], rax                       # old session (may be 0)
    call session_new                     # rdi/rsi pass through
    test rax, rax
    jz .Lars_err
    mov rbx, rax                         # new session
    # provider: agent_init recorded the resolved name in the old session;
    # the flag is the fallback when there is no old session
    mov rdi, [rsp]
    call session_provider
    test rax, rax
    jnz 1f
    mov rax, [rip + g_agent_provider]
1:  mov r12, rax
    # model: the live descriptor is the resolved model
    mov rax, [rip + a_md]
    test rax, rax
    jz 2f
    mov rdx, [rax + MD_id]
    jmp 3f
2:  mov rdi, [rsp]
    call session_model
    mov rdx, rax
3:  mov rdi, rbx
    mov rsi, r12
    call session_append_model
    test rax, rax
    js .Lars_free
    mov rdi, [rsp]
    call session_close
    mov [rip + g_agent_session], rbx
    xor eax, eax
    EPILOGUE
.Lars_free:
    mov r12, rax
    mov rdi, rbx
    call session_close
    mov rax, r12
    EPILOGUE
.Lars_err:
    mov rax, -EIO
    EPILOGUE

# ---------------------------------------------------------------------------
# Async API used by the TUI (see src/tui/API.md). agent_init must run first.

# agent_submit(prompt cstr) -> 0 accepted | 1 busy
FN agent_submit
    PROLOGUE
    call agent_busy
    test eax, eax
    jnz .Lsub_busy
    mov r15, rdi
    # Re-check compaction before every turn (not just once in agent_init) so a
    # long-lived process stays bounded.  agent_busy above guarantees no turn is
    # in flight; compact_maybe_run is a no-op below the threshold.
    call compact_maybe_run
    mov dword ptr [rip + a_abort], 0
    mov dword ptr [rip + a_printed], 0
    mov edi, MR_USER
    call msg_new
    mov r13, rax
    mov rdi, r15
    call strlen
    mov rcx, rax
    mov rdi, r13
    mov esi, BT_TEXT
    mov rdx, r15
    call msg_add_block
    lea rdi, [rip + a_tr]
    mov rsi, r13
    call tr_push
    mov rdi, r13
    call agent_session_append
    call agent_start_turn
    xor eax, eax
    EPILOGUE
.Lsub_busy:
    mov eax, 1
    EPILOGUE

# agent_step(timeout_ms): one loop iteration
FN agent_step
    PROLOGUE
    mov r12d, edi
    cmp dword ptr [rip + a_abort], 0
    je 1f
    call agent_handle_abort
1:  mov edi, r12d
    call loop_poll
    mov eax, [rip + a_state]
    cmp eax, AS_TURN
    jne 2f
    call agent_start_turn
    EPILOGUE
2:  cmp eax, AS_TOOLS
    jne 3f
    call agent_check_jobs
3:  cmp eax, AS_CONNECT
    je 4f
    cmp eax, AS_HANDSHAKE
    je 4f
    cmp eax, AS_SEND
    je 4f
    cmp eax, AS_RECV
    jne 5f
4:  mov edi, CLOCK_MONOTONIC
    call os_now_ns
    cmp rax, [rip + a_deadline]
    jb 5f
    lea rdi, [rip + .Lerr_timeout]
    call agent_fail
5:  EPILOGUE

# agent_busy() -> 1|0
FN agent_busy
    mov eax, [rip + a_state]
    cmp eax, AS_CONNECT
    je 1f
    cmp eax, AS_HANDSHAKE
    je 1f
    cmp eax, AS_SEND
    je 1f
    cmp eax, AS_RECV
    je 1f
    cmp eax, AS_TOOLS
    je 1f
    cmp eax, AS_TURN
    je 1f
    xor eax, eax
    ret
1:  mov eax, 1
    ret

# agent_exit_code() -> code
FN agent_exit_code
    mov eax, [rip + a_exit]
    ret

# agent_abort(): request cancellation; agent_step performs it
FN agent_abort
    mov dword ptr [rip + a_abort], 1
    xor eax, eax
    ret

.globl agent_handle_abort
agent_handle_abort:
    PROLOGUE
    mov dword ptr [rip + a_abort], 0
    # running jobs: remove watches, kill children
    xor r12d, r12d
1:  cmp r12, [rip + a_jobs + VEC_len]
    jae 3f
    mov rax, [rip + a_jobs + VEC_ptr]
    mov rbx, [rax + r12*8]
    cmp dword ptr [rbx + J_state], JS_RUNNING
    jne 2f
    mov rdi, rbx
    call agent_kill_job
2:  inc r12d
    jmp 1b
3:  cmp dword ptr [rip + a_state], AS_TOOLS
    jne 30f
    # a tool batch was in flight: emit the matching tool_result for every
    # call so the transcript never ends on an unanswered tool_use (providers
    # reject that on the next turn)
    call agent_tools_finished
    jmp 7f
30: mov dword ptr [rip + a_pending], 0
    # transport
    cmp qword ptr [rip + a_fd], 0
    jl 5f
    mov edi, [rip + a_fd]
    call watch_remove
    cmp qword ptr [rip + a_conn], 0
    je 4f
    mov rdi, [rip + a_conn]
    call tls_close
    mov qword ptr [rip + a_conn], 0
4:  mov edi, [rip + a_fd]
    call net_close
    mov qword ptr [rip + a_fd], -1
5:  mov eax, [rip + a_state]
    cmp eax, AS_CONNECT
    je 6f
    cmp eax, AS_HANDSHAKE
    je 6f
    cmp eax, AS_SEND
    je 6f
    cmp eax, AS_RECV
    jne 7f
6:  mov rbx, [rip + a_msg]
    test rbx, rbx
    jz 7f
    mov dword ptr [rbx + M_stop], SR_ABORTED
    lea rdi, [rip + a_tr]
    mov rsi, rbx
    call tr_push
    mov rdi, rbx
    call agent_session_append
    mov qword ptr [rip + a_msg], 0
    # a completed tool_use in the aborted message needs a tool_result
    mov rdi, rbx
    call agent_abort_toolcalls
7:  mov dword ptr [rip + a_state], AS_DONE
    mov dword ptr [rip + a_exit], 0
    # The provider's PV_finish emits SE_DONE on the normal completion paths; an
    # abort tears the transport down before it can, so emit the run end here.
    # a_done guards against a provider SE_DONE already delivered this turn.
    cmp dword ptr [rip + a_done], 0
    jne 8f
    mov dword ptr [rip + a_done], 1
    mov rax, [rip + g_agent_ui_fn]
    test rax, rax
    jz 8f
    mov rdi, [rip + g_agent_ui_ctx]
    mov esi, SE_DONE
    mov edx, SR_ABORTED
    xor ecx, ecx
    call rax
8:  EPILOGUE

# agent_run(prompt): print mode wrapper for the async API
FN agent_run
    PROLOGUE
    mov r15, rdi
    call agent_init
    test eax, eax
    jnz 2f
    mov rdi, r15
    call agent_submit
    test eax, eax
    jnz 2f
1:  call agent_busy
    test eax, eax
    jz 3f
    mov edi, 200
    call agent_step
    jmp 1b
2:  call mcp_shutdown
    mov eax, 1
    EPILOGUE
3:  cmp dword ptr [rip + a_printed], 0
    je 4f
    mov edi, 1
    lea rsi, [rip + .Lnl]
    call out_cstr
4:  call mcp_shutdown
    mov eax, [rip + a_exit]
    EPILOGUE

# ---- accessors for the TUI shell -------------------------------------------
FN agent_transcript
    lea rax, [rip + a_tr]
    ret

FN agent_current_msg
    mov rax, [rip + a_msg]
    ret

FN agent_model_id
    mov rax, [rip + a_md]
    test rax, rax
    jz 1f
    mov rax, [rax + MD_id]
    ret
1:  lea rax, [rip + .Lempty]
    ret

FN agent_model_provider
    mov rax, [rip + a_md]
    test rax, rax
    jz 1f
    mov rax, [rax + MD_provider]
    ret
1:  lea rax, [rip + .Lanon]
    ret

# ---- thinking level --------------------------------------------------------
# agent_set_thinking(esi level): clamp to 0..3, store as the active level.
# The level is the second argument (the first slot is the implicit agent).
FN agent_set_thinking
    test esi, esi
    jns 1f
    xor esi, esi
1:  cmp esi, TH_HIGH
    jle 2f
    mov esi, TH_HIGH
2:  mov [rip + g_agent_thinking], esi
    xor eax, eax
    ret

# agent_thinking() -> eax level (0 when unset)
FN agent_thinking
    mov eax, [rip + g_agent_thinking]
    test eax, eax
    jns 1f
    xor eax, eax
1:  ret

# agent_thinking_name(esi level) -> rax cstr
FN agent_thinking_name
    test esi, esi
    js .Ltn_off
    cmp esi, TH_LOW
    je .Ltn_low
    cmp esi, TH_MEDIUM
    je .Ltn_medium
    cmp esi, TH_HIGH
    je .Ltn_high
.Ltn_off:
    lea rax, [rip + .Lth_off]
    ret
.Ltn_low:
    lea rax, [rip + .Lth_low]
    ret
.Ltn_medium:
    lea rax, [rip + .Lth_medium]
    ret
.Ltn_high:
    lea rax, [rip + .Lth_high]
    ret

# agent_thinking_parse(rdi name) -> eax level | -1 when unknown
FN agent_thinking_parse
    PROLOGUE
    mov rbx, rdi
    test rbx, rbx
    jz .Ltp_bad
    mov rdi, rbx
    lea rsi, [rip + .Lth_off]
    call cstr_eq
    test eax, eax
    jnz .Ltp_off
    mov rdi, rbx
    lea rsi, [rip + .Lth_low]
    call cstr_eq
    test eax, eax
    jnz .Ltp_low
    mov rdi, rbx
    lea rsi, [rip + .Lth_medium]
    call cstr_eq
    test eax, eax
    jnz .Ltp_medium
    mov rdi, rbx
    lea rsi, [rip + .Lth_high]
    call cstr_eq
    test eax, eax
    jnz .Ltp_high
.Ltp_bad:
    mov eax, -1
    EPILOGUE
.Ltp_off:
    xor eax, eax
    EPILOGUE
.Ltp_low:
    mov eax, TH_LOW
    EPILOGUE
.Ltp_medium:
    mov eax, TH_MEDIUM
    EPILOGUE
.Ltp_high:
    mov eax, TH_HIGH
    EPILOGUE

# ---- usage / context accessors --------------------------------------------
# agent_usage_totals(rdi out Usage*) -> 0.  Sums input/output/cache over every
# assistant message in the transcript; total = input + output.
FN agent_usage_totals
    PROLOGUE 0
    mov r12, rdi
    mov qword ptr [r12], 0
    mov qword ptr [r12 + 8], 0
    mov qword ptr [r12 + 16], 0
    lea rdi, [rip + a_tr]
    call tr_len
    mov r13, rax
    xor r14d, r14d
.Lut_loop:
    cmp r14, r13
    jae .Lut_done
    lea rdi, [rip + a_tr]
    mov rsi, r14
    call tr_msg
    test rax, rax
    jz .Lut_next
    cmp dword ptr [rax + M_role], MR_ASSISTANT
    jne .Lut_next
    mov rbx, [rax + M_usage]
    test rbx, rbx
    jz .Lut_next
    mov eax, [rbx + USG_input]
    add [r12 + USG_input], eax
    mov eax, [rbx + USG_output]
    add [r12 + USG_output], eax
    mov eax, [rbx + USG_cache_read]
    add [r12 + USG_cache_read], eax
    mov eax, [rbx + USG_cache_write]
    add [r12 + USG_cache_write], eax
.Lut_next:
    inc r14
    jmp .Lut_loop
.Lut_done:
    mov eax, [r12 + USG_input]
    add eax, [r12 + USG_output]
    mov [r12 + USG_total], eax
    xor eax, eax
    EPILOGUE

# agent_model_ctx_window() -> eax context window of the active model (0 if none)
FN agent_model_ctx_window
    mov rax, [rip + a_md]
    test rax, rax
    jz 1f
    mov eax, [rax + MD_ctx_window]
    ret
1:  xor eax, eax
    ret

# agent_set_model(rsi id cstr) -> 0 | -EINVAL
#   id is the second argument (the first slot is the implicit agent).  Resolve
#   against the catalog using the current provider (a_md->MD_provider, else
#   g_agent_provider, else "openai"); a "provider/model" id overrides the
#   provider prefix.  Swaps a_md and rebuilds a_pv/a_pvctx/a_key in place; the
#   session is never touched.  Unknown models leave the agent unchanged.
FN agent_set_model
    PROLOGUE 288
    mov r12, rsi
    test r12, r12
    jz .Lsm2_einval
    cmp byte ptr [r12], 0
    je .Lsm2_einval
    mov rdi, r12
    call ag_find_slash
    test rax, rax
    jz .Lsm2_have_prov
    cmp rax, r12
    je .Lsm2_einval
    mov r11, rax
    mov rcx, r11
    sub rcx, r12
    cmp rcx, 255
    ja .Lsm2_einval
    lea r14, [r11 + 1]
    cmp byte ptr [r14], 0
    je .Lsm2_einval
    xor edx, edx
1:  cmp rdx, rcx
    jae 2f
    mov al, [r12 + rdx]
    mov [rsp + rdx], al
    inc rdx
    jmp 1b
2:  mov byte ptr [rsp + rdx], 0
    mov r13, rsp
    jmp .Lsm2_lookup
.Lsm2_have_prov:
    mov r14, r12
    mov rax, [rip + a_md]
    test rax, rax
    jz 1f
    mov r13, [rax + MD_provider]
    jmp .Lsm2_lookup
1:  mov r13, [rip + g_agent_provider]
    test r13, r13
    jnz .Lsm2_lookup
    lea r13, [rip + .Lanon]
.Lsm2_lookup:
    mov rdi, r13
    mov rsi, r14
    call catalog_find
    test rax, rax
    jz .Lsm2_einval
    mov r15, rax
    # provider vtable from the model's api (single table, ADR-7)
    mov rdi, [r15 + MD_api]
    call prov_for_api
    mov rbx, rax
5:  # release the previous provider context, then allocate a fresh one
    mov rax, [rip + a_pvctx]
    test rax, rax
    jz 6f
    mov rdi, rax
    mov rax, [rip + a_pv]
    test rax, rax
    jz 6f
    call [rax + PV_free]
6:  mov [rip + a_pv], rbx
    mov [rip + a_md], r15
    mov rdi, r15
    call [rbx + PV_new]
    mov [rip + a_pvctx], rax
    mov rcx, [rip + g_agent_max_tokens]
    test rcx, rcx
    jnz 7f
    mov ecx, [r15 + MD_max_tokens]
    test ecx, ecx
    jnz 7f
    mov ecx, 4096
7:  mov [rax + 8], ecx
    # refresh the auth token for the (possibly new) provider.  auth_key()
    # returns an owned copy, so release the previous key before replacing it.
    test dword ptr [r15 + MD_flags], MDF_NO_KEY
    jnz 8f
    mov rdi, [r15 + MD_provider]
    call auth_key
    mov [rsp + 256], rax
    mov rdi, [rip + a_key]
    call mem_free
    mov rax, [rsp + 256]
    mov [rip + a_key], rax
8:  xor eax, eax
    EPILOGUE
.Lsm2_einval:
    mov rax, -EINVAL
    EPILOGUE
