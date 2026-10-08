.include "opcode.inc"
.include "core/core.inc"
# responses_test: OpenAI Responses API provider wire-format golden tests.
#
# Checks, byte for byte:
#   1. the request body for a system+user transcript plus an assistant
#      text/tool-call turn and a tool result,
#   2. the SE_* event log for a canned Responses SSE sequence
#      (text + one function_call + usage + completed).
#
# The transcript is built with core/messages.s. The tool registry is exercised
# with tools_add() directly (no tools_init) so the golden request contains
# exactly one tool.

.section .rodata
.Lhi:      .asciz "hi"
.Lhello:   .asciz "Hello"
.Lok:      .asciz "ok"
.Lsys:     .asciz "SYS"
.Lcall_a:  .asciz "call_a"
.Lfake:    .asciz "fake"
.Largs:    .asciz "{\"x\":1}"
.Lempty:   .asciz ""
.Lnl:      .asciz "\n"
.Lpipe:    .asciz "|"
.Lcomma:   .asciz ","

.Lmd_id:   .asciz "gpt-test"
.Lmd_name: .asciz "Test Model"
.Lmd_api:  .asciz "openai-responses"
.Lmd_prov: .asciz "test"
.Lmd_base: .asciz "https://example.invalid"

# fake tool
.Lt_name:   .asciz "fake"
.Lt_label:  .asciz "Fake"
.Lt_desc:   .asciz "A fake tool"
.Lt_params: .asciz "{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"string\"}},\"required\":[\"x\"]}"

# ---- golden request body ----
.E_req: .asciz "{\"model\":\"gpt-test\",\"instructions\":\"SYS\",\"input\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"hi\"}]},{\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Hello\"}]},{\"type\":\"function_call\",\"call_id\":\"call_a\",\"name\":\"fake\",\"arguments\":\"{\\\"x\\\":1}\"},{\"type\":\"function_call_output\",\"call_id\":\"call_a\",\"output\":\"ok\"}],\"stream\":true,\"store\":false,\"max_output_tokens\":4096,\"tools\":[{\"type\":\"function\",\"name\":\"fake\",\"description\":\"A fake tool\",\"parameters\":{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"string\"}},\"required\":[\"x\"]},\"strict\":false}],\"tool_choice\":\"auto\",\"parallel_tool_calls\":true}"
# the old placement must be gone: no role:system item inside input[]
.Lneg_sys: .asciz "\"role\":\"system\""
# O1 negative needles for the no-tools body (O2)
.Ln_tool_choice: .asciz "\"tool_choice\""
.Ln_parallel:    .asciz "parallel_tool_calls"
# empty-system form the adapter must emit
.Ln_instr_empty: .asciz "\"instructions\":\"\""

# ---- golden request body, tools present, system = "" (empty-sys path) ----
.E_req_nosys: .asciz "{\"model\":\"gpt-test\",\"instructions\":\"\",\"input\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"hi\"}]},{\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Hello\"}]},{\"type\":\"function_call\",\"call_id\":\"call_a\",\"name\":\"fake\",\"arguments\":\"{\\\"x\\\":1}\"},{\"type\":\"function_call_output\",\"call_id\":\"call_a\",\"output\":\"ok\"}],\"stream\":true,\"store\":false,\"max_output_tokens\":4096,\"tools\":[{\"type\":\"function\",\"name\":\"fake\",\"description\":\"A fake tool\",\"parameters\":{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"string\"}},\"required\":[\"x\"]},\"strict\":false}],\"tool_choice\":\"auto\",\"parallel_tool_calls\":true}"

# ---- golden request body, no tools registered (O2) ----
.E_req_notools: .asciz "{\"model\":\"gpt-test\",\"instructions\":\"SYS\",\"input\":[{\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"hi\"}]},{\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Hello\"}]},{\"type\":\"function_call\",\"call_id\":\"call_a\",\"name\":\"fake\",\"arguments\":\"{\\\"x\\\":1}\"},{\"type\":\"function_call_output\",\"call_id\":\"call_a\",\"output\":\"ok\"}],\"stream\":true,\"store\":false,\"max_output_tokens\":4096}"

# ---- canned Responses SSE ----
.Ld_created:  .asciz "{\"type\":\"response.created\",\"response\":{\"id\":\"resp_1\",\"status\":\"in_progress\"}}"
.Ld_add_msg:  .asciz "{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"status\":\"in_progress\",\"role\":\"assistant\",\"content\":[]}}"
.Ld_txt_he:   .asciz "{\"type\":\"response.output_text.delta\",\"output_index\":0,\"content_index\":0,\"delta\":\"He\"}"
.Ld_txt_llo:  .asciz "{\"type\":\"response.output_text.delta\",\"output_index\":0,\"content_index\":0,\"delta\":\"llo\"}"
.Ld_done_msg: .asciz "{\"type\":\"response.output_item.done\",\"output_index\":0,\"item\":{\"type\":\"message\",\"id\":\"msg_1\",\"status\":\"completed\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"Hello\",\"annotations\":[]}]}}"
.Ld_add_fc:   .asciz "{\"type\":\"response.output_item.added\",\"output_index\":1,\"item\":{\"type\":\"function_call\",\"id\":\"fc_1\",\"call_id\":\"call_a\",\"name\":\"fake\",\"arguments\":\"\"}}"
.Ld_fc_d:     .asciz "{\"type\":\"response.function_call_arguments.delta\",\"output_index\":1,\"delta\":\"{\\\"x\\\":\"}"
.Ld_fc_end:   .asciz "{\"type\":\"response.function_call_arguments.done\",\"output_index\":1,\"arguments\":\"{\\\"x\\\":1}\"}"
.Ld_done_fc:  .asciz "{\"type\":\"response.output_item.done\",\"output_index\":1,\"item\":{\"type\":\"function_call\",\"id\":\"fc_1\",\"call_id\":\"call_a\",\"name\":\"fake\",\"arguments\":\"{\\\"x\\\":1}\"}}"
.Ld_complete: .asciz "{\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"status\":\"completed\",\"usage\":{\"input_tokens\":10,\"output_tokens\":5,\"total_tokens\":15,\"input_tokens_details\":{\"cached_tokens\":2,\"cache_write_tokens\":1}}}}"

.E_sse: .asciz "T:He\nT:llo\nTEND\nS:call_a|fake\nD:{\"x\":\nE\nU:7,5,2,1,15\nDONE:3\n"

# ---- sink tags / messages ----
.Ltag_t:    .asciz "T:"
.Ltag_k:    .asciz "K:"
.Ltag_s:    .asciz "S:"
.Ltag_d:    .asciz "D:"
.Ltag_e:    .asciz "E\n"
.Ltag_tend: .asciz "TEND\n"
.Ltag_kend: .asciz "KEND\n"
.Ltag_u:    .asciz "U:"
.Ltag_done: .asciz "DONE:"
.Ltag_err:  .asciz "ERR:"
.M_ok_req:  .asciz "responses ok req\n"
.M_ok_notools: .asciz "responses ok notools\n"
.M_ok_nosys:   .asciz "responses ok nosys\n"
.M_ok_sse:  .asciz "responses ok sse\n"
.M_done:    .asciz "responses done\n"
.M_fail:    .asciz "responses FAIL\n"

.section .data
.p2align 3
md_oai:
    .quad .Lmd_id
    .quad .Lmd_name
    .quad .Lmd_api
    .quad .Lmd_prov
    .quad .Lmd_base
    .long 128000
    .long 4096
    .long 0
    .long 0
.p2align 3
fake_tool:
    .quad .Lt_name
    .quad .Lt_label
    .quad .Lt_desc
    .quad .Lt_params
    .long 0
    .long 0
    .quad 0
    .quad 0

.section .bss
.p2align 3
t_tr:   .zero TR_SIZE
t_sb:   .zero SB_SIZE
t_log:  .zero SB_SIZE
t_sink: .zero SS_SIZE

.text

# print_cstr(cstr)
print_cstr:
    push rdi
    call strlen
    pop rdi
    mov rdx, rax
    mov rsi, rdi
    mov edi, 1
    jmp write_all

# print_n(ptr, len)
print_n:
    mov rdx, rsi
    mov rsi, rdi
    mov edi, 1
    jmp write_all

# dump_sb(sb): print the body followed by a newline. The printed bytes are the
# exact PV_build output, so the expected file doubles as JSON well-formedness
# evidence for every asserted request body (checked with python3 in CI docs).
dump_sb:
    PROLOGUE 0
    mov r12, rdi
    mov rdi, [r12 + SB_ptr]
    mov rsi, [r12 + SB_len]
    call print_n
    lea rdi, [rip + .Lnl]
    call print_cstr
    EPILOGUE

# check_sb(sb, expected cstr): print the actual body and exit 1 on mismatch.
check_sb:
    PROLOGUE 0
    mov r12, rdi
    mov r13, rsi
    mov rdi, r13
    call strlen
    cmp [r12 + SB_len], rax
    jne .Lck_fail
    mov rdi, [r12 + SB_ptr]
    mov rsi, r13
    mov rdx, rax
    call memeq
    test eax, eax
    jz .Lck_fail
    EPILOGUE
.Lck_fail:
    lea rdi, [rip + .M_fail]
    call print_cstr
    mov rdi, [r12 + SB_ptr]
    test rdi, rdi
    jz .Lck_exit
    mov rsi, [r12 + SB_len]
    call print_n
    lea rdi, [rip + .Lnl]
    call print_cstr
.Lck_exit:
    mov edi, 1
    call os_exit
    ud2

# sb_has(sb, needle cstr) -> 1 | 0
sb_has:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    mov rdi, r12
    call strlen
    mov rcx, rax
    mov rdi, [rbx + SB_ptr]
    test rdi, rdi
    jz 1f
    mov rsi, [rbx + SB_len]
    mov rdx, r12
    call str_find
    cmp rax, -1
    setne al
    movzx eax, al
    jmp 2f
1:  xor eax, eax
2:  add rsp, 8
    pop r12
    pop rbx
    ret

# lg_cstr(cstr)
lg_cstr:
    PROLOGUE 0
    test rdi, rdi
    jnz .Llg_go
    lea rdi, [rip + .Lempty]
.Llg_go:
    mov rsi, rdi
    lea rdi, [rip + t_log]
    call sb_push_cstr
    EPILOGUE

# lg_n(ptr, len)
lg_n:
    PROLOGUE 0
    mov rdx, rsi
    mov rsi, rdi
    lea rdi, [rip + t_log]
    call sb_push
    EPILOGUE

# lg_u64(value)
lg_u64:
    PROLOGUE 0
    mov rsi, rdi
    lea rdi, [rip + t_log]
    call sb_push_u64
    EPILOGUE

# lg_nl()
lg_nl:
    lea rdi, [rip + .Lnl]
    jmp lg_cstr

# test_sink(&SS, esi=event, rdx=a, rcx=b): append a text line to t_log.
test_sink:
    PROLOGUE 0
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    cmp r12d, SE_TEXT
    je .Lsk_text
    cmp r12d, SE_TEXT_END
    je .Lsk_tend
    cmp r12d, SE_THINK
    je .Lsk_think
    cmp r12d, SE_THINK_END
    je .Lsk_kend
    cmp r12d, SE_TOOL_START
    je .Lsk_tstart
    cmp r12d, SE_TOOL_DELTA
    je .Lsk_tdelta
    cmp r12d, SE_TOOL_END
    je .Lsk_toolend
    cmp r12d, SE_USAGE
    je .Lsk_usage
    cmp r12d, SE_DONE
    je .Lsk_done
    cmp r12d, SE_ERROR
    je .Lsk_error
    jmp .Lsk_ret
.Lsk_text:
    lea rdi, [rip + .Ltag_t]
    call lg_cstr
    mov rdi, r13
    mov rsi, r14
    call lg_n
    call lg_nl
    jmp .Lsk_ret
.Lsk_think:
    lea rdi, [rip + .Ltag_k]
    call lg_cstr
    mov rdi, r13
    mov rsi, r14
    call lg_n
    call lg_nl
    jmp .Lsk_ret
.Lsk_tend:
    lea rdi, [rip + .Ltag_tend]
    call lg_cstr
    jmp .Lsk_ret
.Lsk_kend:
    lea rdi, [rip + .Ltag_kend]
    call lg_cstr
    jmp .Lsk_ret
.Lsk_tstart:
    lea rdi, [rip + .Ltag_s]
    call lg_cstr
    mov rdi, r13
    call lg_cstr
    lea rdi, [rip + .Lpipe]
    call lg_cstr
    mov rdi, r14
    call lg_cstr
    call lg_nl
    jmp .Lsk_ret
.Lsk_tdelta:
    lea rdi, [rip + .Ltag_d]
    call lg_cstr
    mov rdi, r13
    mov rsi, r14
    call lg_n
    call lg_nl
    jmp .Lsk_ret
.Lsk_toolend:
    lea rdi, [rip + .Ltag_e]
    call lg_cstr
    jmp .Lsk_ret
.Lsk_usage:
    lea rdi, [rip + .Ltag_u]
    call lg_cstr
    mov edi, [r13 + USG_input]
    call lg_u64
    lea rdi, [rip + .Lcomma]
    call lg_cstr
    mov edi, [r13 + USG_output]
    call lg_u64
    lea rdi, [rip + .Lcomma]
    call lg_cstr
    mov edi, [r13 + USG_cache_read]
    call lg_u64
    lea rdi, [rip + .Lcomma]
    call lg_cstr
    mov edi, [r13 + USG_cache_write]
    call lg_u64
    lea rdi, [rip + .Lcomma]
    call lg_cstr
    mov edi, [r13 + USG_total]
    call lg_u64
    call lg_nl
    jmp .Lsk_ret
.Lsk_done:
    lea rdi, [rip + .Ltag_done]
    call lg_cstr
    mov edi, r13d
    call lg_u64
    call lg_nl
    jmp .Lsk_ret
.Lsk_error:
    lea rdi, [rip + .Ltag_err]
    call lg_cstr
    mov rdi, r13
    call lg_cstr
    call lg_nl
.Lsk_ret:
    EPILOGUE

# feed_resp(ctx, data cstr)
feed_resp:
    PROLOGUE 0
    mov r12, rdi
    mov r14, rsi
    mov rdi, r14
    call strlen
    mov r9, rax
    mov r8, r14
    xor edx, edx
    xor ecx, ecx
    lea rsi, [rip + t_sink]
    mov rdi, r12
    lea rax, [rip + prov_openai_responses]
    call [rax + PV_sse]
    EPILOGUE

FN opcode_main
    PROLOGUE 0

    # transcript: user "hi", assistant "Hello" + call_a, tool result "ok"
    lea rdi, [rip + t_tr]
    call tr_init
    mov edi, MR_USER
    call msg_new
    mov rbx, rax
    mov rdi, rbx
    mov esi, BT_TEXT
    lea rdx, [rip + .Lhi]
    mov ecx, 2
    call msg_add_block
    lea rdi, [rip + t_tr]
    mov rsi, rbx
    call tr_push
    mov edi, MR_ASSISTANT
    call msg_new
    mov rbx, rax
    mov rdi, rbx
    mov esi, BT_TEXT
    lea rdx, [rip + .Lhello]
    mov ecx, 5
    call msg_add_block
    mov rdi, rbx
    lea rsi, [rip + .Lcall_a]
    lea rdx, [rip + .Lfake]
    lea rcx, [rip + .Largs]
    call msg_add_toolcall
    lea rdi, [rip + t_tr]
    mov rsi, rbx
    call tr_push
    mov edi, MR_TOOL_RESULT
    call msg_new
    mov rbx, rax
    mov rdi, rbx
    lea rsi, [rip + .Lcall_a]
    call msg_set_call_id
    mov rdi, rbx
    mov esi, BT_TEXT
    lea rdx, [rip + .Lok]
    mov ecx, 2
    call msg_add_block
    lea rdi, [rip + t_tr]
    mov rsi, rbx
    call tr_push

    # tool registry is empty here: this build exercises the no-tools path (O2)
    lea rdi, [rip + md_oai]
    lea rax, [rip + prov_openai_responses]
    call [rax + PV_new]
    mov r14, rax
    lea rdi, [rip + t_sb]
    call sb_clear
    mov rdi, r14
    lea rsi, [rip + t_sb]
    lea rdx, [rip + .Lsys]
    lea rcx, [rip + t_tr]
    lea rax, [rip + prov_openai_responses]
    call [rax + PV_build]
    lea rdi, [rip + t_sb]
    lea rsi, [rip + .E_req_notools]
    call check_sb
    lea rdi, [rip + t_sb]
    lea rsi, [rip + .Ln_tool_choice]
    call sb_has
    test eax, eax
    jnz .Lneg_fail
    lea rdi, [rip + t_sb]
    lea rsi, [rip + .Ln_parallel]
    call sb_has
    test eax, eax
    jnz .Lneg_fail
    lea rdi, [rip + .M_ok_notools]
    call print_cstr
    lea rdi, [rip + t_sb]
    call dump_sb
    mov rdi, r14
    lea rax, [rip + prov_openai_responses]
    call [rax + PV_free]

    # tool registry: one fake tool
    lea rdi, [rip + fake_tool]
    call tools_add

    # ---- 1b. empty-system request body, tools present ----
    lea rdi, [rip + md_oai]
    lea rax, [rip + prov_openai_responses]
    call [rax + PV_new]
    mov r14, rax
    lea rdi, [rip + t_sb]
    call sb_clear
    mov rdi, r14
    lea rsi, [rip + t_sb]
    xor edx, edx                    # sys = NULL -> "instructions":""
    lea rcx, [rip + t_tr]
    lea rax, [rip + prov_openai_responses]
    call [rax + PV_build]
    lea rdi, [rip + t_sb]
    lea rsi, [rip + .E_req_nosys]
    call check_sb
    lea rdi, [rip + t_sb]
    lea rsi, [rip + .Ln_instr_empty]
    call sb_has
    test eax, eax
    jz .Lneg_fail
    lea rdi, [rip + .M_ok_nosys]
    call print_cstr
    lea rdi, [rip + t_sb]
    call dump_sb
    mov rdi, r14
    lea rax, [rip + prov_openai_responses]
    call [rax + PV_free]

    # ---- 1c. request body, tools present, system = SYS ----
    lea rdi, [rip + md_oai]
    lea rax, [rip + prov_openai_responses]
    call [rax + PV_new]
    mov r14, rax
    lea rdi, [rip + t_sb]
    call sb_clear
    mov rdi, r14
    lea rsi, [rip + t_sb]
    lea rdx, [rip + .Lsys]
    lea rcx, [rip + t_tr]
    lea rax, [rip + prov_openai_responses]
    call [rax + PV_build]
    lea rdi, [rip + t_sb]
    lea rsi, [rip + .E_req]
    call check_sb
    lea rdi, [rip + t_sb]
    lea rsi, [rip + .Lneg_sys]
    call sb_has
    test eax, eax
    jnz .Lneg_fail
    lea rdi, [rip + .M_ok_req]
    call print_cstr
    lea rdi, [rip + t_sb]
    call dump_sb
    mov rdi, r14
    lea rax, [rip + prov_openai_responses]
    call [rax + PV_free]

    # ---- 2. canned SSE ----
    lea rax, [rip + test_sink]
    mov [rip + t_sink + SS_fn], rax
    mov qword ptr [rip + t_sink + SS_ctx], 0
    lea rdi, [rip + md_oai]
    lea rax, [rip + prov_openai_responses]
    call [rax + PV_new]
    mov r15, rax
    lea rdi, [rip + t_log]
    call sb_clear
    mov rdi, r15
    lea rsi, [rip + .Ld_created]
    call feed_resp
    mov rdi, r15
    lea rsi, [rip + .Ld_add_msg]
    call feed_resp
    mov rdi, r15
    lea rsi, [rip + .Ld_txt_he]
    call feed_resp
    mov rdi, r15
    lea rsi, [rip + .Ld_txt_llo]
    call feed_resp
    mov rdi, r15
    lea rsi, [rip + .Ld_done_msg]
    call feed_resp
    mov rdi, r15
    lea rsi, [rip + .Ld_add_fc]
    call feed_resp
    mov rdi, r15
    lea rsi, [rip + .Ld_fc_d]
    call feed_resp
    mov rdi, r15
    lea rsi, [rip + .Ld_fc_end]
    call feed_resp
    mov rdi, r15
    lea rsi, [rip + .Ld_done_fc]
    call feed_resp
    mov rdi, r15
    lea rsi, [rip + .Ld_complete]
    call feed_resp
    lea rdi, [rip + t_log]
    lea rsi, [rip + .E_sse]
    call check_sb
    lea rdi, [rip + .M_ok_sse]
    call print_cstr
    mov rdi, r15
    lea rax, [rip + prov_openai_responses]
    call [rax + PV_free]

    lea rdi, [rip + .M_done]
    call print_cstr
    xor eax, eax
    EPILOGUE

.Lneg_fail:
    lea rdi, [rip + .M_fail]
    call print_cstr
    mov edi, 1
    call os_exit
    ud2
