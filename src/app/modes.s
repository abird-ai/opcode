# modes.s: machine-readable front ends for the agent.
#   opcode_json_main(argc, argv) -> exit code   (--mode json)
#   opcode_rpc_main(argc, argv)  -> exit code   (--mode rpc)
# argv[0] is "--mode" plus its value; the shared parser in src/app/cli.s skips
# the pair.  All user-visible output is one JSON object per line on stdout.
.include "opcode.inc"
.include "core/core.inc"

.section .rodata
.Lnl:           .asciz "\n"
.Lempty:        .asciz ""

# JSON keys and event/stop names
.K_type:            .asciz "type"
.K_id:              .asciz "id"
.K_name:            .asciz "name"
.K_json:            .asciz "json"
.K_text:            .asciz "text"
.K_message:         .asciz "message"
.K_stop:            .asciz "stop"
.K_input:           .asciz "input"
.K_output:          .asciz "output"
.K_cache_read:      .asciz "cache_read"
.K_cache_write:     .asciz "cache_write"
.K_exit:            .asciz "exit"
.V_text_delta:      .asciz "text_delta"
.V_thinking_delta:  .asciz "thinking_delta"
.V_tool_start:      .asciz "tool_start"
.V_tool_args:       .asciz "tool_args"
.V_tool_end:        .asciz "tool_end"
.V_tool_result:     .asciz "tool_result"
.V_usage:           .asciz "usage"
.V_done:            .asciz "done"
.V_error:           .asciz "error"
.V_agent_end:       .asciz "agent_end"
.V_ready:           .asciz "ready"
.V_ack:             .asciz "ack"
.V_prompt:          .asciz "prompt"
.V_abort:           .asciz "abort"
.V_quit:            .asciz "quit"
.V_stop:            .asciz "stop"
.V_length:          .asciz "length"
.V_tool_use:        .asciz "tool_use"
.V_aborted:         .asciz "aborted"

.bss
.p2align 3
# stdout line buffer and RPC input state
j_sb:       .zero SB_SIZE
r_inbuf:    .zero 4096
r_lines:    .zero SB_SIZE
r_running:  .zero 4
r_quit:     .zero 4
r_eof:      .zero 4
r_aborted:  .zero 4

.text

# ---------------------------------------------------------------- helpers
# mstr_eq(a cstr, b cstr) -> 1|0 (leaf)
mstr_eq:
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

# j_str0(sb, cstr): jsonw_str_cstr with a NULL guard.
j_str0:
    test rsi, rsi
    jnz 1f
    lea rsi, [rip + .Lempty]
1:  jmp jsonw_str_cstr

# j_emit(): terminate the j_sb line with '\n', write it to stdout, clear j_sb.
j_emit:
    PROLOGUE
    lea rdi, [rip + j_sb]
    lea rsi, [rip + .Lnl]
    mov edx, 1
    call sb_push
    mov edi, 1
    mov rsi, [rip + j_sb + SB_ptr]
    mov rdx, [rip + j_sb + SB_len]
    call write_all
    lea rdi, [rip + j_sb]
    call sb_clear
    EPILOGUE

# j_begin(type cstr): clear j_sb and open {"type":<type>
j_begin:
    PROLOGUE
    mov r12, rsi
    lea rdi, [rip + j_sb]
    call sb_clear
    lea rdi, [rip + j_sb]
    call jsonw_obj
    lea rdi, [rip + j_sb]
    lea rsi, [rip + .K_type]
    call jsonw_key
    lea rdi, [rip + j_sb]
    mov rsi, r12
    call jsonw_str_cstr
    EPILOGUE

# j_end(): close the object and emit the line.
j_end:
    PROLOGUE
    lea rdi, [rip + j_sb]
    call jsonw_obj_end
    call j_emit
    EPILOGUE

# agent_end exit=<reg>
j_agent_end:
    PROLOGUE
    mov r12d, edi
    lea rsi, [rip + .V_agent_end]
    call j_begin
    lea rdi, [rip + j_sb]
    lea rsi, [rip + .K_exit]
    call jsonw_key
    lea rdi, [rip + j_sb]
    mov esi, r12d
    call jsonw_u64
    call j_end
    EPILOGUE

# ---------------------------------------------------------------- UI hook
# j_hook(ctx, event, a, b): one JSONL event per SE_* callback.
j_hook:
    PROLOGUE
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    cmp r12d, SE_TEXT
    je .Lh_text
    cmp r12d, SE_THINK
    je .Lh_think
    cmp r12d, SE_TOOL_START
    je .Lh_tool_start
    cmp r12d, SE_TOOL_DELTA
    je .Lh_tool_delta
    cmp r12d, SE_TOOL_END
    je .Lh_tool_end
    cmp r12d, SE_TOOL_RESULT
    je .Lh_tool_result
    cmp r12d, SE_USAGE
    je .Lh_usage
    cmp r12d, SE_DONE
    je .Lh_done
    cmp r12d, SE_ERROR
    je .Lh_error
    EPILOGUE
.Lh_text:
    lea rsi, [rip + .V_text_delta]
    call j_begin
    lea rdi, [rip + j_sb]
    lea rsi, [rip + .K_text]
    call jsonw_key
    lea rdi, [rip + j_sb]
    mov rsi, r13
    mov rdx, r14
    call jsonw_str
    call j_end
    EPILOGUE
.Lh_think:
    lea rsi, [rip + .V_thinking_delta]
    call j_begin
    lea rdi, [rip + j_sb]
    lea rsi, [rip + .K_text]
    call jsonw_key
    lea rdi, [rip + j_sb]
    mov rsi, r13
    mov rdx, r14
    call jsonw_str
    call j_end
    EPILOGUE
.Lh_tool_start:
    lea rsi, [rip + .V_tool_start]
    call j_begin
    lea rdi, [rip + j_sb]
    lea rsi, [rip + .K_id]
    call jsonw_key
    lea rdi, [rip + j_sb]
    mov rsi, r13
    call j_str0
    lea rdi, [rip + j_sb]
    lea rsi, [rip + .K_name]
    call jsonw_key
    lea rdi, [rip + j_sb]
    mov rsi, r14
    call j_str0
    call j_end
    EPILOGUE
.Lh_tool_delta:
    lea rsi, [rip + .V_tool_args]
    call j_begin
    lea rdi, [rip + j_sb]
    lea rsi, [rip + .K_json]
    call jsonw_key
    lea rdi, [rip + j_sb]
    mov rsi, r13
    mov rdx, r14
    call jsonw_str
    call j_end
    EPILOGUE
.Lh_tool_end:
    lea rsi, [rip + .V_tool_end]
    call j_begin
    call j_end
    EPILOGUE
.Lh_tool_result:
    lea rsi, [rip + .V_tool_result]
    call j_begin
    lea rdi, [rip + j_sb]
    lea rsi, [rip + .K_text]
    call jsonw_key
    lea rdi, [rip + j_sb]
    mov rsi, r13
    mov rdx, r14
    call jsonw_str
    call j_end
    EPILOGUE
.Lh_usage:
    lea rsi, [rip + .V_usage]
    call j_begin
    lea rdi, [rip + j_sb]
    lea rsi, [rip + .K_input]
    call jsonw_key
    lea rdi, [rip + j_sb]
    mov esi, dword ptr [r13 + USG_input]
    call jsonw_u64
    lea rdi, [rip + j_sb]
    lea rsi, [rip + .K_output]
    call jsonw_key
    lea rdi, [rip + j_sb]
    mov esi, dword ptr [r13 + USG_output]
    call jsonw_u64
    lea rdi, [rip + j_sb]
    lea rsi, [rip + .K_cache_read]
    call jsonw_key
    lea rdi, [rip + j_sb]
    mov esi, dword ptr [r13 + USG_cache_read]
    call jsonw_u64
    lea rdi, [rip + j_sb]
    lea rsi, [rip + .K_cache_write]
    call jsonw_key
    lea rdi, [rip + j_sb]
    mov esi, dword ptr [r13 + USG_cache_write]
    call jsonw_u64
    call j_end
    EPILOGUE
.Lh_done:
    lea rsi, [rip + .V_done]
    call j_begin
    lea rdi, [rip + j_sb]
    lea rsi, [rip + .K_stop]
    call jsonw_key
    lea r12, [rip + .V_stop]
    cmp r13d, SR_STOP
    je 1f
    lea r12, [rip + .V_length]
    cmp r13d, SR_LENGTH
    je 1f
    lea r12, [rip + .V_tool_use]
    cmp r13d, SR_TOOL_USE
    je 1f
    lea r12, [rip + .V_error]
    cmp r13d, SR_ERROR
    je 1f
    lea r12, [rip + .V_aborted]
    cmp r13d, SR_ABORTED
    je 1f
    lea r12, [rip + .V_stop]
1:  lea rdi, [rip + j_sb]
    mov rsi, r12
    call jsonw_str_cstr
    call j_end
    EPILOGUE
.Lh_error:
    lea rsi, [rip + .V_error]
    call j_begin
    lea rdi, [rip + j_sb]
    lea rsi, [rip + .K_message]
    call jsonw_key
    lea rdi, [rip + j_sb]
    mov rsi, r13
    call j_str0
    call j_end
    EPILOGUE

# ---------------------------------------------------------------- flags/session
# modes_setup(argc rdi, argv rsi, want_prompt edx) -> 0 ok | 1 error | 2 usage
modes_setup:
    PROLOGUE
    mov r15d, edx
    mov edx, CK_JSON
    call cli_parse
    test eax, eax
    jnz .Lms_ret
    call config_load
    call cli_expand_prompt
    test eax, eax
    jnz .Lms_fail
    test r15d, r15d
    jz .Lms_resolve
    call cli_require_prompt
    test eax, eax
    jnz .Lms_ret
.Lms_resolve:
    call cli_open_session
    test eax, eax
    jnz .Lms_fail
    xor eax, eax
    EPILOGUE
.Lms_fail:
    mov eax, 1
.Lms_ret:
    EPILOGUE

# ---------------------------------------------------------------- json mode
# opcode_json_main(argc, argv) -> exit code
FN opcode_json_main
    PROLOGUE
    mov edx, 1
    call modes_setup
    test eax, eax
    jnz .Ljm_ret
    lea rax, [rip + j_hook]
    mov [rip + g_agent_ui_fn], rax
    mov qword ptr [rip + g_agent_ui_ctx], 0
    call agent_init
    test eax, eax
    jnz .Ljm_fail
    mov rdi, [rip + cl_prompt + SB_ptr]
    call agent_submit
    test eax, eax
    jnz .Ljm_fail
.Ljm_loop:
    call agent_busy
    test eax, eax
    jz .Ljm_done
    mov edi, 200
    call agent_step
    jmp .Ljm_loop
.Ljm_done:
    call agent_exit_code
    mov r12d, eax
    mov edi, r12d
    call j_agent_end
    call mcp_shutdown
    mov eax, r12d
    EPILOGUE
.Ljm_fail:
    mov edi, 1
    call j_agent_end
    call mcp_shutdown
    mov eax, 1
.Ljm_ret:
    EPILOGUE

# ---------------------------------------------------------------- rpc mode
# rpc_handle_line(ptr, len): parse one command and apply it.
rpc_handle_line:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov rdi, r12
    mov rsi, r13
    call json_parse
    test rax, rax
    jz .Lrh_bad
    mov rbx, rax
    mov rdi, rbx
    lea rsi, [rip + .K_type]
    call json_get_cstr
    test rax, rax
    jz .Lrh_bad
    mov r14, rax
    mov rdi, r14
    lea rsi, [rip + .V_prompt]
    call mstr_eq
    test eax, eax
    jnz .Lrh_prompt
    mov rdi, r14
    lea rsi, [rip + .V_abort]
    call mstr_eq
    test eax, eax
    jnz .Lrh_abort
    mov rdi, r14
    lea rsi, [rip + .V_quit]
    call mstr_eq
    test eax, eax
    jnz .Lrh_quit
    EPILOGUE
.Lrh_prompt:
    cmp dword ptr [rip + r_running], 0
    jne .Lrh_busy
    mov rdi, rbx
    lea rsi, [rip + .K_text]
    call json_get_cstr
    test rax, rax
    jz .Lrh_bad
    mov r15, rax
    lea rsi, [rip + .V_ack]
    call j_begin
    call j_end
    mov dword ptr [rip + r_running], 1
    mov dword ptr [rip + r_aborted], 0
    mov rdi, r15
    call agent_submit
    EPILOGUE
.Lrh_busy:
    lea rsi, [rip + .V_error]
    call j_begin
    lea rdi, [rip + j_sb]
    lea rsi, [rip + .K_message]
    call jsonw_key
    lea rdi, [rip + j_sb]
    lea rsi, [rip + .Lmsg_busy]
    call jsonw_str_cstr
    call j_end
    EPILOGUE
.Lrh_abort:
    call agent_busy
    test eax, eax
    jz .Lrh_ignore
    mov dword ptr [rip + r_aborted], 1
    call agent_abort
.Lrh_ignore:
    EPILOGUE
.Lrh_quit:
    mov dword ptr [rip + r_quit], 1
    EPILOGUE
.Lrh_bad:
    lea rsi, [rip + .V_error]
    call j_begin
    lea rdi, [rip + j_sb]
    lea rsi, [rip + .K_message]
    call jsonw_key
    lea rdi, [rip + j_sb]
    lea rsi, [rip + .Lmsg_badcmd]
    call jsonw_str_cstr
    call j_end
    EPILOGUE

# rpc_process_lines(): dispatch every complete '\n'-terminated line, keep tail.
rpc_process_lines:
    PROLOGUE
    mov r12, [rip + r_lines + SB_ptr]
    mov r13, [rip + r_lines + SB_len]
    xor r14d, r14d
    xor r15d, r15d
.Lpl_scan:
    cmp r15, r13
    jae .Lpl_tail
    cmp byte ptr [r12 + r15], 10
    je .Lpl_line
    inc r15
    jmp .Lpl_scan
.Lpl_line:
    mov rbx, r15
    sub rbx, r14
    test rbx, rbx
    jz .Lpl_advance
    cmp byte ptr [r12 + r15 - 1], 13
    jne 1f
    dec rbx
1:  test rbx, rbx
    jz .Lpl_advance
    lea rdi, [r12 + r14]
    mov rsi, rbx
    call rpc_handle_line
.Lpl_advance:
    lea r14, [r15 + 1]
    inc r15
    jmp .Lpl_scan
.Lpl_tail:
    mov rax, r13
    sub rax, r14
    test rax, rax
    jz .Lpl_clear
    mov rbx, rax
    mov rdi, r12
    lea rsi, [r12 + r14]
    mov rdx, rax
    call memmove
    mov byte ptr [r12 + rbx], 0
    mov [rip + r_lines + SB_len], rbx
    EPILOGUE
.Lpl_clear:
    mov qword ptr [rip + r_lines + SB_len], 0
    mov byte ptr [r12], 0
    EPILOGUE

# rpc_on_stdin(fd, revents, ctx)
rpc_on_stdin:
    PROLOGUE
    xor edi, edi
    lea rsi, [rip + r_inbuf]
    mov edx, 4096
    call os_read
    test rax, rax
    js .Lro_ret
    jz .Lro_eof
    lea rdi, [rip + r_lines]
    lea rsi, [rip + r_inbuf]
    mov rdx, rax
    call sb_push
    call rpc_process_lines
    EPILOGUE
.Lro_eof:
    mov dword ptr [rip + r_eof], 1
.Lro_ret:
    EPILOGUE

# rpc_run_end(): emit a synthesized done on abort, then agent_end.
rpc_run_end:
    PROLOGUE
    cmp dword ptr [rip + r_aborted], 0
    je 1f
    mov dword ptr [rip + r_aborted], 0
    lea rsi, [rip + .V_done]
    call j_begin
    lea rdi, [rip + j_sb]
    lea rsi, [rip + .K_stop]
    call jsonw_key
    lea rdi, [rip + j_sb]
    lea rsi, [rip + .V_aborted]
    call jsonw_str_cstr
    call j_end
1:  call agent_exit_code
    mov edi, eax
    call j_agent_end
    mov dword ptr [rip + r_running], 0
    EPILOGUE

# opcode_rpc_main(argc, argv) -> exit code
FN opcode_rpc_main
    PROLOGUE
    xor edx, edx
    call modes_setup
    test eax, eax
    jnz .Lrm_ret
    lea rax, [rip + j_hook]
    mov [rip + g_agent_ui_fn], rax
    mov qword ptr [rip + g_agent_ui_ctx], 0
    call agent_init
    test eax, eax
    jnz .Lrm_fail
    lea rsi, [rip + .V_ready]
    call j_begin
    call j_end
    xor edi, edi
    mov esi, POLLIN
    lea rdx, [rip + rpc_on_stdin]
    xor ecx, ecx
    call watch_add
.Lrm_loop:
    mov edi, 200
    call agent_step
    # a submitted run that went idle emits its agent_end
    cmp dword ptr [rip + r_running], 0
    je 1f
    call agent_busy
    test eax, eax
    jnz 1f
    call rpc_run_end
1:  cmp dword ptr [rip + r_running], 0
    jne .Lrm_loop
    cmp dword ptr [rip + r_quit], 0
    jne .Lrm_done
    cmp dword ptr [rip + r_eof], 0
    jne .Lrm_done
    jmp .Lrm_loop
.Lrm_done:
    call mcp_shutdown
    xor eax, eax
    EPILOGUE
.Lrm_fail:
    mov edi, 1
    call j_agent_end
    call mcp_shutdown
    mov eax, 1
.Lrm_ret:
    EPILOGUE

.section .rodata
.Lmsg_busy:   .asciz "agent is busy"
.Lmsg_badcmd: .asciz "invalid command"
