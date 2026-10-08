.include "opcode.inc"
.include "core/core.inc"
# prov_test: provider wire-format golden tests.
#
# Checks, byte for byte:
#   1. the Anthropic request body for a one-message transcript + one tool,
#   2. the OpenAI request body for the same transcript,
#   3. the SE_* event log for a canned Anthropic SSE sequence,
#   4. the SE_* event log for a canned OpenAI SSE sequence (two tool calls).
#
# The transcript is built with core/messages.s. The tool registry is exercised
# with tools_add() directly (no tools_init): the golden request then contains
# exactly one tool and does not depend on the descriptions of the built-ins.

.section .rodata
.Lhi:       .asciz "hi"
.Lsys:      .asciz "SYS"
.Lempty:    .asciz ""
.Lnl:       .asciz "\n"
.Lpipe:     .asciz "|"
.Lcomma:    .asciz ","

.Lmd_id_a:   .asciz "claude-test"
.Lmd_id_o:   .asciz "gpt-test"
.Lmd_name:   .asciz "Test Model"
.Lmd_api_a:  .asciz "anthropic-messages"
.Lmd_api_o:  .asciz "openai-chat"
.Lmd_prov:   .asciz "test"
.Lmd_prov_ollama: .asciz "ollama"
.Lmd_prov_cloud:  .asciz "ollama-cloud"
.Lmd_base:   .asciz "https://example.invalid"

# fake tool
.Lt_name:   .asciz "fake"
.Lt_label:  .asciz "Fake"
.Lt_desc:   .asciz "A fake tool"
.Lt_params: .asciz "{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"string\"}},\"required\":[\"x\"]}"

# ---- golden request bodies ----
.E_anth_req: .asciz "{\"model\":\"claude-test\",\"max_tokens\":8192,\"stream\":true,\"thinking\":{\"type\":\"enabled\",\"budget_tokens\":4096},\"system\":[{\"type\":\"text\",\"text\":\"SYS\"}],\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}],\"tools\":[{\"name\":\"fake\",\"description\":\"A fake tool\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"string\"}},\"required\":[\"x\"]}}]}"
# Same transcript and max_tokens with --thinking off: no thinking object.
.E_anth_req_off: .asciz "{\"model\":\"claude-test\",\"max_tokens\":8192,\"stream\":true,\"system\":[{\"type\":\"text\",\"text\":\"SYS\"}],\"messages\":[{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"hi\"}]}],\"tools\":[{\"name\":\"fake\",\"description\":\"A fake tool\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"string\"}},\"required\":[\"x\"]}}]}"
.E_oai_req:  .asciz "{\"model\":\"gpt-test\",\"messages\":[{\"role\":\"system\",\"content\":\"SYS\"},{\"role\":\"user\",\"content\":\"hi\"}],\"stream\":true,\"stream_options\":{\"include_usage\":true},\"max_completion_tokens\":4096,\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"fake\",\"description\":\"A fake tool\",\"parameters\":{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"string\"}},\"required\":[\"x\"]}}}]}"
# Ollama / ollama-cloud use max_tokens; their compat layer ignores
# max_completion_tokens (ADR-4). Same body otherwise.
.E_ollama_req: .asciz "{\"model\":\"gpt-test\",\"messages\":[{\"role\":\"system\",\"content\":\"SYS\"},{\"role\":\"user\",\"content\":\"hi\"}],\"stream\":true,\"stream_options\":{\"include_usage\":true},\"max_tokens\":4096,\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"fake\",\"description\":\"A fake tool\",\"parameters\":{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"string\"}},\"required\":[\"x\"]}}}]}"
.E_ollama_cloud_req: .asciz "{\"model\":\"gpt-test\",\"messages\":[{\"role\":\"system\",\"content\":\"SYS\"},{\"role\":\"user\",\"content\":\"hi\"}],\"stream\":true,\"stream_options\":{\"include_usage\":true},\"max_tokens\":4096,\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"fake\",\"description\":\"A fake tool\",\"parameters\":{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"string\"}},\"required\":[\"x\"]}}}]}"

# ---- canned Anthropic SSE ----
.Le_mstart:  .asciz "message_start"
.Ld_mstart:  .asciz "{\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"claude-test\",\"content\":[],\"stop_reason\":null,\"usage\":{\"input_tokens\":10,\"output_tokens\":1,\"cache_read_input_tokens\":2,\"cache_creation_input_tokens\":3}}}"
.Le_cbs:     .asciz "content_block_start"
.Ld_cbs0:    .asciz "{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}"
.Ld_cbs1:    .asciz "{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"fake\",\"input\":{}}}"
.Le_cbd:     .asciz "content_block_delta"
.Ld_cbd0:    .asciz "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"He\"}}"
.Ld_cbd1:    .asciz "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"llo\"}}"
.Ld_cbd2:    .asciz "{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"x\\\":\"}}"
.Ld_cbd3:    .asciz "{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\\\"y\\\"}\"}}"
.Le_stop:    .asciz "content_block_stop"
.Ld_stop0:   .asciz "{\"type\":\"content_block_stop\",\"index\":0}"
.Ld_stop1:   .asciz "{\"type\":\"content_block_stop\",\"index\":1}"
.Le_mdelta:  .asciz "message_delta"
.Ld_mdelta:  .asciz "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":7}}"
.Le_mstop:   .asciz "message_stop"
.Ld_mstop:   .asciz "{\"type\":\"message_stop\"}"
.E_anth_sse: .asciz "U:10,1,2,3,16\nT:He\nT:llo\nTEND\nS:toolu_1|fake\nD:{\"x\":\nD:\"y\"}\nE\nU:10,7,2,3,22\nDONE:3\n"

# ---- canned OpenAI SSE ----
.Le_msg:     .asciz "message"
.Ld_o1:      .asciz "{\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"Hi\"},\"finish_reason\":null}]}"
.Ld_o2:      .asciz "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_a\",\"type\":\"function\",\"function\":{\"name\":\"alpha\",\"arguments\":\"\"}}]},\"finish_reason\":null}]}"
.Ld_o3:      .asciz "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"x\\\":\"}}]},\"finish_reason\":null}]}"
.Ld_o4:      .asciz "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":1,\"id\":\"call_b\",\"type\":\"function\",\"function\":{\"name\":\"beta\",\"arguments\":\"{}\"}}]},\"finish_reason\":null}]}"
.Ld_o5:      .asciz "{\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"1}\"}}]},\"finish_reason\":null}]}"
.Ld_o6:      .asciz "{\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}]}"
.Ld_o7:      .asciz "{\"choices\":[],\"usage\":{\"prompt_tokens\":20,\"completion_tokens\":5,\"prompt_tokens_details\":{\"cached_tokens\":4}}}"
.Ld_done:    .asciz "[DONE]"
.E_oai_sse:  .asciz "T:Hi\nTEND\nS:call_a|alpha\nD:{\"x\":1}\nE\nS:call_b|beta\nD:{}\nE\nU:16,5,4,0,25\nDONE:3\n"

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
.M_ok_anth_req: .asciz "prov ok anth-req\n"
.M_ok_anth_off: .asciz "prov ok anth-off\n"
.M_ok_oai_req:  .asciz "prov ok oai-req\n"
.M_ok_ollama_req: .asciz "prov ok ollama-req\n"
.M_ok_cloud_req:  .asciz "prov ok ollama-cloud-req\n"
.M_ok_anth_sse: .asciz "prov ok anth-sse\n"
.M_ok_oai_sse:  .asciz "prov ok oai-sse\n"
.M_done:        .asciz "prov done\n"
.M_fail:        .asciz "prov FAIL\n"

.section .data
.p2align 3
md_anth:
    .quad .Lmd_id_a
    .quad .Lmd_name
    .quad .Lmd_api_a
    .quad .Lmd_prov
    .quad .Lmd_base
    .long 200000
    .long 8192
    .long MDF_REASONING
    .long 0
md_oai:
    .quad .Lmd_id_o
    .quad .Lmd_name
    .quad .Lmd_api_o
    .quad .Lmd_prov
    .quad .Lmd_base
    .long 128000
    .long 4096
    .long 0
    .long 0
md_ollama:
    .quad .Lmd_id_o
    .quad .Lmd_name
    .quad .Lmd_api_o
    .quad .Lmd_prov_ollama
    .quad .Lmd_base
    .long 128000
    .long 4096
    .long MDF_NO_KEY
    .long 0
md_ollama_cloud:
    .quad .Lmd_id_o
    .quad .Lmd_name
    .quad .Lmd_api_o
    .quad .Lmd_prov_cloud
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

# feed_anth(ctx, event cstr, data cstr)
feed_anth:
    PROLOGUE 0
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov rdi, r13
    call strlen
    mov r15, rax
    mov rdi, r14
    call strlen
    mov r9, rax
    mov r8, r14
    mov rcx, r15
    mov rdx, r13
    lea rsi, [rip + t_sink]
    mov rdi, r12
    lea rax, [rip + prov_anthropic]
    call [rax + PV_sse]
    EPILOGUE

# feed_oai(ctx, data cstr)
feed_oai:
    PROLOGUE 0
    mov r12, rdi
    mov r14, rdx
    mov rdi, r14
    call strlen
    mov r9, rax
    mov r8, r14
    lea rdx, [rip + .Le_msg]
    mov ecx, 7
    lea rsi, [rip + t_sink]
    mov rdi, r12
    lea rax, [rip + prov_openai]
    call [rax + PV_sse]
    EPILOGUE

FN opcode_main
    PROLOGUE 0

    # reasoning models emit a thinking object only when a level is set
    mov esi, TH_MEDIUM
    call agent_set_thinking

    # transcript: one user message "hi"
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

    # tool registry: one fake tool (no tools_init so the golden request is
    # independent of the built-in read/bash schemas)
    lea rdi, [rip + fake_tool]
    call tools_add

    # ---- 1. Anthropic request ----
    lea rdi, [rip + md_anth]
    lea rax, [rip + prov_anthropic]
    call [rax + PV_new]
    mov r14, rax
    lea rdi, [rip + t_sb]
    call sb_clear
    mov rdi, r14
    lea rsi, [rip + t_sb]
    lea rdx, [rip + .Lsys]
    lea rcx, [rip + t_tr]
    lea rax, [rip + prov_anthropic]
    call [rax + PV_build]
    lea rdi, [rip + t_sb]
    lea rsi, [rip + .E_anth_req]
    call check_sb
    lea rdi, [rip + .M_ok_anth_req]
    call print_cstr

    # ---- 1b. thinking off -> no thinking object ----
    xor esi, esi
    call agent_set_thinking
    lea rdi, [rip + t_sb]
    call sb_clear
    mov rdi, r14
    lea rsi, [rip + t_sb]
    lea rdx, [rip + .Lsys]
    lea rcx, [rip + t_tr]
    lea rax, [rip + prov_anthropic]
    call [rax + PV_build]
    lea rdi, [rip + t_sb]
    lea rsi, [rip + .E_anth_req_off]
    call check_sb
    lea rdi, [rip + .M_ok_anth_off]
    call print_cstr
    mov rdi, r14
    lea rax, [rip + prov_anthropic]
    call [rax + PV_free]

    # ---- 2. OpenAI request ----
    lea rdi, [rip + md_oai]
    lea rax, [rip + prov_openai]
    call [rax + PV_new]
    mov r15, rax
    lea rdi, [rip + t_sb]
    call sb_clear
    mov rdi, r15
    lea rsi, [rip + t_sb]
    lea rdx, [rip + .Lsys]
    lea rcx, [rip + t_tr]
    lea rax, [rip + prov_openai]
    call [rax + PV_build]
    lea rdi, [rip + t_sb]
    lea rsi, [rip + .E_oai_req]
    call check_sb
    lea rdi, [rip + .M_ok_oai_req]
    call print_cstr
    mov rdi, r15
    lea rax, [rip + prov_openai]
    call [rax + PV_free]

    # ---- 2b. OpenAI request, provider "ollama" -> max_tokens ----
    lea rdi, [rip + md_ollama]
    lea rax, [rip + prov_openai]
    call [rax + PV_new]
    mov r15, rax
    lea rdi, [rip + t_sb]
    call sb_clear
    mov rdi, r15
    lea rsi, [rip + t_sb]
    lea rdx, [rip + .Lsys]
    lea rcx, [rip + t_tr]
    lea rax, [rip + prov_openai]
    call [rax + PV_build]
    lea rdi, [rip + t_sb]
    lea rsi, [rip + .E_ollama_req]
    call check_sb
    lea rdi, [rip + .M_ok_ollama_req]
    call print_cstr
    mov rdi, r15
    lea rax, [rip + prov_openai]
    call [rax + PV_free]

    # ---- 2c. OpenAI request, provider "ollama-cloud" -> max_tokens ----
    lea rdi, [rip + md_ollama_cloud]
    lea rax, [rip + prov_openai]
    call [rax + PV_new]
    mov r15, rax
    lea rdi, [rip + t_sb]
    call sb_clear
    mov rdi, r15
    lea rsi, [rip + t_sb]
    lea rdx, [rip + .Lsys]
    lea rcx, [rip + t_tr]
    lea rax, [rip + prov_openai]
    call [rax + PV_build]
    lea rdi, [rip + t_sb]
    lea rsi, [rip + .E_ollama_cloud_req]
    call check_sb
    lea rdi, [rip + .M_ok_cloud_req]
    call print_cstr
    mov rdi, r15
    lea rax, [rip + prov_openai]
    call [rax + PV_free]

    # ---- 3. Anthropic SSE ----
    lea rax, [rip + test_sink]
    mov [rip + t_sink + SS_fn], rax
    mov qword ptr [rip + t_sink + SS_ctx], 0
    lea rdi, [rip + md_anth]
    lea rax, [rip + prov_anthropic]
    call [rax + PV_new]
    mov r14, rax
    lea rdi, [rip + t_log]
    call sb_clear
    mov rdi, r14
    lea rsi, [rip + .Le_mstart]
    lea rdx, [rip + .Ld_mstart]
    call feed_anth
    mov rdi, r14
    lea rsi, [rip + .Le_cbs]
    lea rdx, [rip + .Ld_cbs0]
    call feed_anth
    mov rdi, r14
    lea rsi, [rip + .Le_cbd]
    lea rdx, [rip + .Ld_cbd0]
    call feed_anth
    mov rdi, r14
    lea rsi, [rip + .Le_cbd]
    lea rdx, [rip + .Ld_cbd1]
    call feed_anth
    mov rdi, r14
    lea rsi, [rip + .Le_stop]
    lea rdx, [rip + .Ld_stop0]
    call feed_anth
    mov rdi, r14
    lea rsi, [rip + .Le_cbs]
    lea rdx, [rip + .Ld_cbs1]
    call feed_anth
    mov rdi, r14
    lea rsi, [rip + .Le_cbd]
    lea rdx, [rip + .Ld_cbd2]
    call feed_anth
    mov rdi, r14
    lea rsi, [rip + .Le_cbd]
    lea rdx, [rip + .Ld_cbd3]
    call feed_anth
    mov rdi, r14
    lea rsi, [rip + .Le_stop]
    lea rdx, [rip + .Ld_stop1]
    call feed_anth
    mov rdi, r14
    lea rsi, [rip + .Le_mdelta]
    lea rdx, [rip + .Ld_mdelta]
    call feed_anth
    mov rdi, r14
    lea rsi, [rip + .Le_mstop]
    lea rdx, [rip + .Ld_mstop]
    call feed_anth
    lea rdi, [rip + t_log]
    lea rsi, [rip + .E_anth_sse]
    call check_sb
    lea rdi, [rip + .M_ok_anth_sse]
    call print_cstr
    mov rdi, r14
    lea rax, [rip + prov_anthropic]
    call [rax + PV_free]

    # ---- 4. OpenAI SSE ----
    lea rdi, [rip + md_oai]
    lea rax, [rip + prov_openai]
    call [rax + PV_new]
    mov r15, rax
    lea rdi, [rip + t_log]
    call sb_clear
    mov rdi, r15
    lea rdx, [rip + .Ld_o1]
    call feed_oai
    mov rdi, r15
    lea rdx, [rip + .Ld_o2]
    call feed_oai
    mov rdi, r15
    lea rdx, [rip + .Ld_o3]
    call feed_oai
    mov rdi, r15
    lea rdx, [rip + .Ld_o4]
    call feed_oai
    mov rdi, r15
    lea rdx, [rip + .Ld_o5]
    call feed_oai
    mov rdi, r15
    lea rdx, [rip + .Ld_o6]
    call feed_oai
    mov rdi, r15
    lea rdx, [rip + .Ld_o7]
    call feed_oai
    mov rdi, r15
    lea rdx, [rip + .Ld_done]
    call feed_oai
    lea rdi, [rip + t_log]
    lea rsi, [rip + .E_oai_sse]
    call check_sb
    lea rdi, [rip + .M_ok_oai_sse]
    call print_cstr
    mov rdi, r15
    lea rax, [rip + prov_openai]
    call [rax + PV_free]

    lea rdi, [rip + .M_done]
    call print_cstr
    xor eax, eax
    EPILOGUE
