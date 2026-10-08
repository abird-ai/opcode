.include "opcode.inc"
.include "core/core.inc"
# prov/openai_responses.s: OpenAI Responses API provider adapter. Contract: src/core/API.md.
#
# ctx layout (first two fields are public, everything past them is private):
#   0    MD*    model
#   8    u32    max_tokens      (the agent may overwrite this directly)
#   12   u32    done            (SE_DONE/SE_ERROR emitted)
#   16   cstr   err             (reserved)
#   24   u32    stop_reason     (reserved; kept for layout stability)
#   28   u32    ntools          (function calls seen)
#   32   u32    nended
#   36   u32    flags           (bit0 text open, bit1 thinking open, bit2 tool seen)
#   40   u32[16] tool_status    (0 unseen, 1 started, 2 ended), keyed by output_index
#   104  u32    args_seen       (bit i: a function_call_arguments.delta was seen)
#   108  u32    pad
#   112  SB     scratch         (joined tool-result text)
#   136

.equ OR_CTX_MD,      0
.equ OR_CTX_MAX,     8
.equ OR_CTX_DONE,    12
.equ OR_CTX_ERR,     16
.equ OR_CTX_STOP,    24
.equ OR_CTX_NTOOLS,  28
.equ OR_CTX_NEND,    32
.equ OR_CTX_FLAGS,   36
.equ OR_CTX_ST,      40
.equ OR_CTX_DSEEN,   104
.equ OR_CTX_SCRATCH, 112
.equ OR_CTX_SIZE,    136
.equ OR_TABLE,       16

.equ OF_TEXT,        1
.equ OF_THINK,       2
.equ OF_TOOL,        4

.equ OS_UNSEEN,      0
.equ OS_STARTED,     1
.equ OS_ENDED,       2

.section .rodata
.Lempty:            .asciz ""
.Lempty_obj:        .asciz "{}"
.Lpath:             .asciz "/responses"
.Lprovider_err:     .asciz "provider error"
.Ltruncated:        .asciz "stream ended unexpectedly"

# JSON keys / values
.K_model:           .asciz "model"
.K_instructions:    .asciz "instructions"
.K_input:           .asciz "input"
.K_stream:          .asciz "stream"
.K_store:           .asciz "store"
.K_max_output:      .asciz "max_output_tokens"
.K_tools:           .asciz "tools"
.K_type:            .asciz "type"
.K_name:            .asciz "name"
.K_description:     .asciz "description"
.K_parameters:      .asciz "parameters"
.K_strict:          .asciz "strict"
.K_role:            .asciz "role"
.K_content:         .asciz "content"
.K_text:            .asciz "text"
.K_output:          .asciz "output"
.K_call_id:         .asciz "call_id"
.K_id:              .asciz "id"
.K_arguments:       .asciz "arguments"
.K_output_index:    .asciz "output_index"
.K_item:            .asciz "item"
.K_delta:           .asciz "delta"
.K_response:        .asciz "response"
.K_usage:           .asciz "usage"
.K_input_tokens:    .asciz "input_tokens"
.K_output_tokens:   .asciz "output_tokens"
.K_input_details:   .asciz "input_tokens_details"
.K_cached_tokens:   .asciz "cached_tokens"
.K_cache_write:     .asciz "cache_write_tokens"
.K_message:         .asciz "message"
.K_error:           .asciz "error"
.K_incomplete:      .asciz "incomplete_details"
.K_reason:          .asciz "reason"
.K_tool_choice:     .asciz "tool_choice"
.K_parallel_tool_calls: .asciz "parallel_tool_calls"
.V_user:            .asciz "user"
.V_assistant:       .asciz "assistant"
.V_function:        .asciz "function"
.V_function_call:   .asciz "function_call"
.V_function_output: .asciz "function_call_output"
.V_message:         .asciz "message"
.V_reasoning:       .asciz "reasoning"
.V_auto:            .asciz "auto"
.V_input_text:      .asciz "input_text"
.V_output_text:     .asciz "output_text"

# SSE event type names
.Ev_created:        .asciz "response.created"
.Ev_item_added:     .asciz "response.output_item.added"
.Ev_item_done:      .asciz "response.output_item.done"
.Ev_text_delta:     .asciz "response.output_text.delta"
.Ev_summary_delta:  .asciz "response.reasoning_summary_text.delta"
.Ev_reason_delta:   .asciz "response.reasoning_text.delta"
.Ev_fc_delta:       .asciz "response.function_call_arguments.delta"
.Ev_fc_done:        .asciz "response.function_call_arguments.done"
.Ev_completed:      .asciz "response.completed"
.Ev_incomplete:     .asciz "response.incomplete"
.Ev_failed:         .asciz "response.failed"
.Ev_error:          .asciz "error"

.text

# .Lsink_emit(SS*, event esi, a rdx, b rcx): dispatch to SS_fn when set.
.Lsink_emit:
    mov rax, [rdi + SS_fn]
    test rax, rax
    jz .Lemit_ret
    jmp rax
.Lemit_ret:
    ret

# ---------------------------------------------------------------- helpers
# .Lres_join(Msg*, SB*, sep ptr, sep len) -> rax ptr, rdx len in SB.
# Concatenates BT_TEXT blocks with the separator between them.
.Lres_join:
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi
    mov [rsp], rdx
    mov [rsp + 8], rcx
    mov qword ptr [rsp + 16], 0
    mov rdi, r12
    call sb_clear
    mov rax, [rbx + M_blocks]
    test rax, rax
    jz .Lrj_done
    mov r13, [rax + VEC_ptr]
    mov r14, [rax + VEC_len]
    xor r15d, r15d
.Lrj_loop:
    cmp r15, r14
    jae .Lrj_done
    lea rax, [r15 + r15*2]
    lea rax, [r13 + rax*8]
    cmp dword ptr [rax + B_type], BT_TEXT
    jne .Lrj_next
    mov [rsp + 24], rax
    cmp qword ptr [rsp + 16], 0
    je .Lrj_nosep
    mov rdi, r12
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    call sb_push
.Lrj_nosep:
    mov rax, [rsp + 24]
    mov rdi, r12
    mov rsi, [rax + B_ptr]
    mov rdx, [rax + B_len]
    call sb_push
    mov qword ptr [rsp + 16], 1
.Lrj_next:
    inc r15
    jmp .Lrj_loop
.Lrj_done:
    mov rax, [r12 + SB_ptr]
    mov rdx, [r12 + SB_len]
    test rax, rax
    jnz .Lrj_ret
    lea rax, [rip + .Lempty]
    xor edx, edx
.Lrj_ret:
    EPILOGUE

# .Lres_usage(usage JV*, SS*): parse a Responses usage object and emit SE_USAGE.
.Lres_usage:
    PROLOGUE 64
    mov rbx, rdi
    mov r12, rsi
    # input_tokens / output_tokens
    mov rdi, rbx
    lea rsi, [rip + .K_input_tokens]
    xor edx, edx
    call json_get_u64
    mov [rsp], rax
    mov rdi, rbx
    lea rsi, [rip + .K_output_tokens]
    xor edx, edx
    call json_get_u64
    mov [rsp + 8], rax
    # input_tokens_details.{cached_tokens, cache_write_tokens}
    mov qword ptr [rsp + 16], 0
    mov qword ptr [rsp + 24], 0
    mov rdi, rbx
    lea rsi, [rip + .K_input_details]
    call json_get
    test rax, rax
    jz .Lru_sum
    mov r13, rax
    mov rdi, r13
    lea rsi, [rip + .K_cached_tokens]
    call json_get
    test rax, rax
    jz .Lru_write
    mov rdi, r13
    lea rsi, [rip + .K_cached_tokens]
    xor edx, edx
    call json_get_u64
    mov [rsp + 16], rax
.Lru_write:
    mov rdi, r13
    lea rsi, [rip + .K_cache_write]
    call json_get
    test rax, rax
    jz .Lru_sum
    mov rdi, r13
    lea rsi, [rip + .K_cache_write]
    xor edx, edx
    call json_get_u64
    mov [rsp + 24], rax
.Lru_sum:
    # input = max(0, input_tokens - cache_read - cache_write)
    mov rax, [rsp]
    mov rcx, [rsp + 16]
    add rcx, [rsp + 24]
    xor edx, edx
    cmp rax, rcx
    jae .Lru_sub
    xor eax, eax
    jmp .Lru_have
.Lru_sub:
    sub rax, rcx
.Lru_have:
    mov [rsp + 32], eax
    mov rax, [rsp + 8]
    mov [rsp + 36], eax
    mov rax, [rsp + 16]
    mov [rsp + 40], eax
    mov rax, [rsp + 24]
    mov [rsp + 44], eax
    mov eax, [rsp + 32]
    add eax, [rsp + 36]
    add eax, [rsp + 40]
    add eax, [rsp + 44]
    mov [rsp + 48], eax
    mov rdi, r12
    mov esi, SE_USAGE
    lea rdx, [rsp + 32]
    xor ecx, ecx
    call .Lsink_emit
    EPILOGUE

# .Lres_flush_text(ctx, SS*): close open text/thinking blocks.
.Lres_flush_text:
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    mov eax, [rbx + OR_CTX_FLAGS]
    test eax, OF_TEXT
    jz .Lrf_think
    and dword ptr [rbx + OR_CTX_FLAGS], ~OF_TEXT
    mov rdi, r12
    mov esi, SE_TEXT_END
    xor edx, edx
    xor ecx, ecx
    call .Lsink_emit
.Lrf_think:
    mov eax, [rbx + OR_CTX_FLAGS]
    test eax, OF_THINK
    jz .Lrf_ret
    and dword ptr [rbx + OR_CTX_FLAGS], ~OF_THINK
    mov rdi, r12
    mov esi, SE_THINK_END
    xor edx, edx
    xor ecx, ecx
    call .Lsink_emit
.Lrf_ret:
    EPILOGUE

# .Lres_end_tool(ctx, SS*, output index): close one started tool call.
.Lres_end_tool:
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    cmp r13, OR_TABLE
    jae .Let_ret
    cmp dword ptr [rbx + OR_CTX_ST + r13*4], OS_STARTED
    jne .Let_ret
    mov dword ptr [rbx + OR_CTX_ST + r13*4], OS_ENDED
    inc dword ptr [rbx + OR_CTX_NEND]
    mov rdi, r12
    mov esi, SE_TOOL_END
    xor edx, edx
    xor ecx, ecx
    call .Lsink_emit
.Let_ret:
    EPILOGUE

# .Lres_close_tools(ctx, SS*): emit SE_TOOL_END for every open call.
.Lres_close_tools:
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    xor r13d, r13d
.Lct_loop:
    cmp r13d, OR_TABLE
    jae .Lct_ret
    cmp dword ptr [rbx + OR_CTX_ST + r13*4], OS_STARTED
    jne .Lct_next
    mov dword ptr [rbx + OR_CTX_ST + r13*4], OS_ENDED
    inc dword ptr [rbx + OR_CTX_NEND]
    mov rdi, r12
    mov esi, SE_TOOL_END
    xor edx, edx
    xor ecx, ecx
    call .Lsink_emit
.Lct_next:
    inc r13d
    jmp .Lct_loop
.Lct_ret:
    EPILOGUE

# .Lres_args(ctx, SS*, item JV*, output index): if no
# function_call_arguments.delta was streamed for this index, emit the item's
# "arguments" as one SE_TOOL_DELTA. Idempotent via the OR_CTX_DSEEN bit.
.Lres_args:
    PROLOGUE 32
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    cmp r15, OR_TABLE
    jae .Lada_ret
    cmp dword ptr [r12 + OR_CTX_ST + r15*4], OS_STARTED
    jne .Lada_ret                 # never emit a delta without its start
    mov eax, 1
    mov ecx, r15d
    shl eax, cl
    test dword ptr [r12 + OR_CTX_DSEEN], eax
    jnz .Lada_ret
    mov rdi, r14
    lea rsi, [rip + .K_arguments]
    call json_get
    test rax, rax
    jz .Lada_mark
    mov rdi, rax
    call json_str
    test rax, rax
    jz .Lada_mark
    test rdx, rdx
    jz .Lada_mark
    mov rcx, rdx
    mov rdx, rax
    mov rdi, r13
    mov esi, SE_TOOL_DELTA
    call .Lsink_emit
.Lada_mark:
    mov eax, 1
    mov ecx, r15d
    shl eax, cl
    or dword ptr [r12 + OR_CTX_DSEEN], eax
.Lada_ret:
    EPILOGUE

# .Lres_start_tool(ctx, SS*, item JV*, output index): SE_TOOL_START + table mark.
.Lres_start_tool:
    PROLOGUE 32
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    cmp r15, OR_TABLE
    jae .Lst_ret
    cmp dword ptr [r12 + OR_CTX_ST + r15*4], OS_UNSEEN
    jne .Lst_ret
.Lst_emit:
    mov rdi, r14
    lea rsi, [rip + .K_call_id]
    call json_get_cstr
    test rax, rax
    jnz .Lst_id_ok
    mov rdi, r14
    lea rsi, [rip + .K_id]
    call json_get_cstr
    test rax, rax
    jnz .Lst_id_ok
    lea rax, [rip + .Lempty]
.Lst_id_ok:
    mov [rsp], rax
    mov rdi, r14
    lea rsi, [rip + .K_name]
    call json_get_cstr
    test rax, rax
    jnz .Lst_name_ok
    lea rax, [rip + .Lempty]
.Lst_name_ok:
    mov rcx, rax
    mov rdx, [rsp]
    mov rdi, r13
    mov esi, SE_TOOL_START
    call .Lsink_emit
    cmp r15, OR_TABLE
    jae .Lst_seen
    mov dword ptr [r12 + OR_CTX_ST + r15*4], OS_STARTED
.Lst_seen:
    inc dword ptr [r12 + OR_CTX_NTOOLS]
    or dword ptr [r12 + OR_CTX_FLAGS], OF_TOOL
.Lst_ret:
    EPILOGUE

# ---------------------------------------------------------------- build helpers
# .Lres_user(ctx, sb, Msg*): {"role":"user","content":[{input_text}...]}.
.Lres_user:
    PROLOGUE 32
    mov rbx, rsi
    mov r12, rdx
    test r12, r12
    jz .Lru_ret
    mov rax, [r12 + M_blocks]
    test rax, rax
    jz .Lru_ret
    mov r13, [rax + VEC_ptr]
    mov r14, [rax + VEC_len]
    test r14, r14
    jz .Lru_ret
    # count text blocks: skip empty user messages
    xor r15d, r15d
    xor ecx, ecx
.Lru_count:
    cmp rcx, r14
    jae .Lru_counted
    lea rax, [rcx + rcx*2]
    cmp dword ptr [r13 + rax*8 + B_type], BT_TEXT
    jne .Lru_count_next
    inc r15d
.Lru_count_next:
    inc rcx
    jmp .Lru_count
.Lru_counted:
    test r15d, r15d
    jz .Lru_ret
    mov rdi, rbx
    call jsonw_obj
    mov rdi, rbx
    lea rsi, [rip + .K_role]
    call jsonw_key
    mov rdi, rbx
    lea rsi, [rip + .V_user]
    call jsonw_str_cstr
    mov rdi, rbx
    lea rsi, [rip + .K_content]
    call jsonw_key
    mov rdi, rbx
    call jsonw_arr
    xor r15d, r15d
.Lru_loop:
    cmp r15, r14
    jae .Lru_close
    lea rax, [r15 + r15*2]
    lea rax, [r13 + rax*8]
    cmp dword ptr [rax + B_type], BT_TEXT
    jne .Lru_next
    mov [rsp], rax
    mov rdi, rbx
    call jsonw_obj
    mov rdi, rbx
    lea rsi, [rip + .K_type]
    call jsonw_key
    mov rdi, rbx
    lea rsi, [rip + .V_input_text]
    call jsonw_str_cstr
    mov rdi, rbx
    lea rsi, [rip + .K_text]
    call jsonw_key
    mov rax, [rsp]
    mov rdi, rbx
    mov rsi, [rax + B_ptr]
    mov rdx, [rax + B_len]
    call jsonw_str
    mov rdi, rbx
    call jsonw_obj_end
.Lru_next:
    inc r15
    jmp .Lru_loop
.Lru_close:
    mov rdi, rbx
    call jsonw_arr_end
    mov rdi, rbx
    call jsonw_obj_end
.Lru_ret:
    EPILOGUE

# .Lres_assistant(ctx, sb, Msg*): one input item per text / tool-call block.
.Lres_assistant:
    PROLOGUE 32
    mov rbx, rsi
    mov rax, rdx
    test rax, rax
    jz .Lra_ret
    mov rax, [rax + M_blocks]
    test rax, rax
    jz .Lra_ret
    mov r13, [rax + VEC_ptr]
    mov r14, [rax + VEC_len]
    test r14, r14
    jz .Lra_ret
    xor r15d, r15d
.Lra_loop:
    cmp r15, r14
    jae .Lra_ret
    lea rax, [r15 + r15*2]
    lea rax, [r13 + rax*8]
    mov ecx, [rax + B_type]
    cmp ecx, BT_TEXT
    je .Lra_text
    cmp ecx, BT_TOOLCALL
    je .Lra_tool
    jmp .Lra_next
.Lra_text:
    mov [rsp], rax
    mov rdi, rbx
    call jsonw_obj
    mov rdi, rbx
    lea rsi, [rip + .K_role]
    call jsonw_key
    mov rdi, rbx
    lea rsi, [rip + .V_assistant]
    call jsonw_str_cstr
    mov rdi, rbx
    lea rsi, [rip + .K_content]
    call jsonw_key
    mov rdi, rbx
    call jsonw_arr
    mov rdi, rbx
    call jsonw_obj
    mov rdi, rbx
    lea rsi, [rip + .K_type]
    call jsonw_key
    mov rdi, rbx
    lea rsi, [rip + .V_output_text]
    call jsonw_str_cstr
    mov rdi, rbx
    lea rsi, [rip + .K_text]
    call jsonw_key
    mov rax, [rsp]
    mov rdi, rbx
    mov rsi, [rax + B_ptr]
    mov rdx, [rax + B_len]
    call jsonw_str
    mov rdi, rbx
    call jsonw_obj_end
    mov rdi, rbx
    call jsonw_arr_end
    mov rdi, rbx
    call jsonw_obj_end
    jmp .Lra_next
.Lra_tool:
    mov r12, [rax + B_ptr]
    mov rdi, rbx
    call jsonw_obj
    mov rdi, rbx
    lea rsi, [rip + .K_type]
    call jsonw_key
    mov rdi, rbx
    lea rsi, [rip + .V_function_call]
    call jsonw_str_cstr
    mov rdi, rbx
    lea rsi, [rip + .K_call_id]
    call jsonw_key
    mov rsi, [r12 + TC_id]
    test rsi, rsi
    jnz .Lra_tool_id
    lea rsi, [rip + .Lempty]
.Lra_tool_id:
    mov rdi, rbx
    call jsonw_str_cstr
    mov rdi, rbx
    lea rsi, [rip + .K_name]
    call jsonw_key
    mov rsi, [r12 + TC_name]
    test rsi, rsi
    jnz .Lra_tool_name
    lea rsi, [rip + .Lempty]
.Lra_tool_name:
    mov rdi, rbx
    call jsonw_str_cstr
    mov rdi, rbx
    lea rsi, [rip + .K_arguments]
    call jsonw_key
    mov rsi, [r12 + TC_args]
    test rsi, rsi
    jnz .Lra_tool_args
    lea rsi, [rip + .Lempty]
.Lra_tool_args:
    mov rdi, rbx
    call jsonw_str_cstr
    mov rdi, rbx
    call jsonw_obj_end
.Lra_next:
    inc r15
    jmp .Lra_loop
.Lra_ret:
    EPILOGUE

# .Lres_toolresult(ctx, sb, Msg*): {"type":"function_call_output",...}.
.Lres_toolresult:
    PROLOGUE 0
    mov r12, rdi
    mov rbx, rsi
    mov r13, rdx
    test r13, r13
    jz .Lrt_ret
    mov rdi, r13
    lea rsi, [r12 + OR_CTX_SCRATCH]
    lea rdx, [rip + .Lnewline]
    mov ecx, 1
    call .Lres_join
    mov r14, rax
    mov r15, rdx
    mov rdi, rbx
    call jsonw_obj
    mov rdi, rbx
    lea rsi, [rip + .K_type]
    call jsonw_key
    mov rdi, rbx
    lea rsi, [rip + .V_function_output]
    call jsonw_str_cstr
    mov rdi, rbx
    lea rsi, [rip + .K_call_id]
    call jsonw_key
    mov rsi, [r13 + M_call_id]
    test rsi, rsi
    jnz .Lrt_id
    lea rsi, [rip + .Lempty]
.Lrt_id:
    mov rdi, rbx
    call jsonw_str_cstr
    mov rdi, rbx
    lea rsi, [rip + .K_output]
    call jsonw_key
    mov rdi, rbx
    mov rsi, r14
    mov rdx, r15
    call jsonw_str
    mov rdi, rbx
    call jsonw_obj_end
.Lrt_ret:
    EPILOGUE

# ---------------------------------------------------------------- vtable members
# .Lprov_new(MD*) -> ctx
.Lprov_new:
    PROLOGUE 0
    mov r12, rdi
    mov edi, OR_CTX_SIZE
    call mem_alloc
    mov rbx, rax
    mov [rbx + OR_CTX_MD], r12
    mov eax, 4096
    test r12, r12
    jz .Lon_store
    mov ecx, [r12 + MD_max_tokens]
    test ecx, ecx
    jz .Lon_store
    mov eax, ecx
.Lon_store:
    mov [rbx + OR_CTX_MAX], eax
    mov rax, rbx
    EPILOGUE

# .Lprov_path(ctx) -> "/responses"
.Lprov_path:
    lea rax, [rip + .Lpath]
    ret

# .Lprov_build(ctx, SB*, sys cstr, Transcript*) -> 0
.Lprov_build:
    PROLOGUE 16
    mov r12, rdi
    mov rbx, rsi
    mov r13, rdx
    mov r14, rcx
    # reset per-stream state: the same ctx is reused for every turn
    mov dword ptr [r12 + OR_CTX_DONE], 0
    mov dword ptr [r12 + OR_CTX_STOP], 0
    mov dword ptr [r12 + OR_CTX_NTOOLS], 0
    mov dword ptr [r12 + OR_CTX_NEND], 0
    mov dword ptr [r12 + OR_CTX_FLAGS], 0
    mov qword ptr [r12 + OR_CTX_ST], 0
    mov qword ptr [r12 + OR_CTX_ST + 8], 0
    mov qword ptr [r12 + OR_CTX_ST + 16], 0
    mov qword ptr [r12 + OR_CTX_ST + 24], 0
    mov qword ptr [r12 + OR_CTX_ST + 32], 0
    mov qword ptr [r12 + OR_CTX_ST + 40], 0
    mov qword ptr [r12 + OR_CTX_ST + 48], 0
    mov qword ptr [r12 + OR_CTX_ST + 56], 0
    mov dword ptr [r12 + OR_CTX_DSEEN], 0

    mov rdi, rbx
    call jsonw_obj

    # model
    mov rdi, rbx
    lea rsi, [rip + .K_model]
    call jsonw_key
    mov rsi, [r12 + OR_CTX_MD]
    test rsi, rsi
    jz .Lob_model_empty
    mov rsi, [rsi + MD_id]
    test rsi, rsi
    jnz .Lob_model_go
.Lob_model_empty:
    lea rsi, [rip + .Lempty]
.Lob_model_go:
    mov rdi, rbx
    call jsonw_str_cstr

    # instructions: the composed system prompt is a top-level string, not a
    # role:system item inside input (ADR-3)
    mov rdi, rbx
    lea rsi, [rip + .K_instructions]
    call jsonw_key
    test r13, r13
    jnz .Lob_instr_go
    lea rsi, [rip + .Lempty]
    jmp .Lob_instr_emit
.Lob_instr_go:
    mov rsi, r13
.Lob_instr_emit:
    mov rdi, rbx
    call jsonw_str_cstr
    # input[]
    mov rdi, rbx
    lea rsi, [rip + .K_input]
    call jsonw_key
    mov rdi, rbx
    call jsonw_arr

    # transcript
    xor r15d, r15d
.Lob_msg_loop:
    mov rdi, r14
    call tr_len
    cmp r15, rax
    jae .Lob_msgs_done
    mov rdi, r14
    mov rsi, r15
    call tr_msg
    test rax, rax
    jz .Lob_msg_next
    mov r13, rax
    mov eax, [r13 + M_role]
    cmp eax, MR_USER
    jne .Lob_msg_asst
    mov rdi, r12
    mov rsi, rbx
    mov rdx, r13
    call .Lres_user
    jmp .Lob_msg_next
.Lob_msg_asst:
    cmp eax, MR_ASSISTANT
    jne .Lob_msg_tool
    mov rdi, r12
    mov rsi, rbx
    mov rdx, r13
    call .Lres_assistant
    jmp .Lob_msg_next
.Lob_msg_tool:
    cmp eax, MR_TOOL_RESULT
    jne .Lob_msg_next
    mov rdi, r12
    mov rsi, rbx
    mov rdx, r13
    call .Lres_toolresult
.Lob_msg_next:
    inc r15
    jmp .Lob_msg_loop
.Lob_msgs_done:
    mov rdi, rbx
    call jsonw_arr_end

    # stream
    mov rdi, rbx
    lea rsi, [rip + .K_stream]
    call jsonw_key
    mov rdi, rbx
    mov esi, 1
    call jsonw_bool

    # store
    mov rdi, rbx
    lea rsi, [rip + .K_store]
    call jsonw_key
    mov rdi, rbx
    xor esi, esi
    call jsonw_bool

    # max_output_tokens (only when > 0)
    mov eax, [r12 + OR_CTX_MAX]
    test eax, eax
    jz .Lob_no_max
    mov rdi, rbx
    lea rsi, [rip + .K_max_output]
    call jsonw_key
    mov rdi, rbx
    mov esi, [r12 + OR_CTX_MAX]
    call jsonw_u64
.Lob_no_max:

    # tools
    call tools_active
    mov r13, rax
    test r13, r13
    jz .Lob_obj_end
    cmp qword ptr [r13 + VEC_len], 0
    je .Lob_obj_end
    mov rdi, rbx
    lea rsi, [rip + .K_tools]
    call jsonw_key
    mov rdi, rbx
    call jsonw_arr
    xor r15d, r15d
.Lob_tool_loop:
    cmp r15, [r13 + VEC_len]
    jae .Lob_tools_end
    mov rax, [r13 + VEC_ptr]
    mov r12, [rax + r15*8]
    test r12, r12
    jz .Lob_tool_next
    mov rdi, rbx
    call jsonw_obj
    mov rdi, rbx
    lea rsi, [rip + .K_type]
    call jsonw_key
    mov rdi, rbx
    lea rsi, [rip + .V_function]
    call jsonw_str_cstr
    mov rdi, rbx
    lea rsi, [rip + .K_name]
    call jsonw_key
    mov rsi, [r12 + TL_name]
    test rsi, rsi
    jnz .Lob_tool_name
    lea rsi, [rip + .Lempty]
.Lob_tool_name:
    mov rdi, rbx
    call jsonw_str_cstr
    mov rdi, rbx
    lea rsi, [rip + .K_description]
    call jsonw_key
    mov rsi, [r12 + TL_desc]
    test rsi, rsi
    jnz .Lob_tool_desc
    lea rsi, [rip + .Lempty]
.Lob_tool_desc:
    mov rdi, rbx
    call jsonw_str_cstr
    mov rdi, rbx
    lea rsi, [rip + .K_parameters]
    call jsonw_key
    mov rdi, [r12 + TL_params]
    test rdi, rdi
    jz .Lob_tool_schema_empty
    call strlen
    mov rdx, rax
    mov rsi, [r12 + TL_params]
    mov rdi, rbx
    call jsonw_raw
    jmp .Lob_tool_obj_end
.Lob_tool_schema_empty:
    mov rdi, rbx
    lea rsi, [rip + .Lempty_obj]
    mov edx, 2
    call jsonw_raw
.Lob_tool_obj_end:
    # "strict":false is emitted after parameters, as the Responses schema expects
    mov rdi, rbx
    lea rsi, [rip + .K_strict]
    call jsonw_key
    mov rdi, rbx
    xor esi, esi
    call jsonw_bool
    mov rdi, rbx
    call jsonw_obj_end
.Lob_tool_next:
    inc r15
    jmp .Lob_tool_loop
.Lob_tools_end:
    mov rdi, rbx
    call jsonw_arr_end
    # Responses-only tool-choice flags (G11); both are gated on ntools, so the
    # no-tools path skips them here.
    mov rdi, rbx
    lea rsi, [rip + .K_tool_choice]
    call jsonw_key
    mov rdi, rbx
    lea rsi, [rip + .V_auto]
    call jsonw_str_cstr
    mov rdi, rbx
    lea rsi, [rip + .K_parallel_tool_calls]
    call jsonw_key
    mov rdi, rbx
    mov esi, 1
    call jsonw_bool
.Lob_obj_end:
    mov rdi, rbx
    call jsonw_obj_end
    xor eax, eax
    EPILOGUE

# .Lprov_sse(ctx, SS*, event ptr, event len, data ptr, data len) -> 0
.Lprov_sse:
    PROLOGUE 64
    mov r12, rdi
    mov r13, rsi
    mov rdi, r8
    mov rsi, r9
    call json_parse
    test rax, rax
    jz .Lrs_ret
    mov rbx, rax
    mov rdi, rbx
    lea rsi, [rip + .K_type]
    call json_get_cstr
    test rax, rax
    jz .Lrs_ret
    mov r14, rax

    # response.created (ignored)
    mov rdi, r14
    mov esi, 16
    lea rdx, [rip + .Ev_created]
    call str_eq_cstr
    test eax, eax
    jnz .Lrs_ret
    # response.output_item.added
    mov rdi, r14
    mov esi, 26
    lea rdx, [rip + .Ev_item_added]
    call str_eq_cstr
    test eax, eax
    jnz .Lrs_item_added
    # response.output_item.done
    mov rdi, r14
    mov esi, 25
    lea rdx, [rip + .Ev_item_done]
    call str_eq_cstr
    test eax, eax
    jnz .Lrs_item_done
    # response.output_text.delta
    mov rdi, r14
    mov esi, 26
    lea rdx, [rip + .Ev_text_delta]
    call str_eq_cstr
    test eax, eax
    jnz .Lrs_text_delta
    # response.reasoning_summary_text.delta
    mov rdi, r14
    mov esi, 37
    lea rdx, [rip + .Ev_summary_delta]
    call str_eq_cstr
    test eax, eax
    jnz .Lrs_think_delta
    # response.reasoning_text.delta
    mov rdi, r14
    mov esi, 29
    lea rdx, [rip + .Ev_reason_delta]
    call str_eq_cstr
    test eax, eax
    jnz .Lrs_think_delta
    # response.function_call_arguments.delta
    mov rdi, r14
    mov esi, 38
    lea rdx, [rip + .Ev_fc_delta]
    call str_eq_cstr
    test eax, eax
    jnz .Lrs_fc_delta
    # response.function_call_arguments.done
    mov rdi, r14
    mov esi, 37
    lea rdx, [rip + .Ev_fc_done]
    call str_eq_cstr
    test eax, eax
    jnz .Lrs_fc_done
    # response.completed
    mov rdi, r14
    mov esi, 18
    lea rdx, [rip + .Ev_completed]
    call str_eq_cstr
    test eax, eax
    jnz .Lrs_completed
    # response.incomplete
    mov rdi, r14
    mov esi, 19
    lea rdx, [rip + .Ev_incomplete]
    call str_eq_cstr
    test eax, eax
    jnz .Lrs_incomplete
    # response.failed
    mov rdi, r14
    mov esi, 15
    lea rdx, [rip + .Ev_failed]
    call str_eq_cstr
    test eax, eax
    jnz .Lrs_failed
    # error
    mov rdi, r14
    mov esi, 5
    lea rdx, [rip + .Ev_error]
    call str_eq_cstr
    test eax, eax
    jnz .Lrs_error
    jmp .Lrs_ret

.Lrs_item_added:
    mov rdi, rbx
    lea rsi, [rip + .K_output_index]
    xor edx, edx
    call json_get_u64
    mov r15, rax
    mov rdi, rbx
    lea rsi, [rip + .K_item]
    call json_get
    test rax, rax
    jz .Lrs_ret
    mov [rsp], rax
    mov rdi, rax
    lea rsi, [rip + .K_type]
    call json_get_cstr
    test rax, rax
    jz .Lrs_ret
    mov r14, rax
    mov rdi, r14
    mov esi, 13
    lea rdx, [rip + .V_function_call]
    call str_eq_cstr
    test eax, eax
    jz .Lrs_ret
    mov rdi, r12
    mov rsi, r13
    mov rdx, [rsp]
    mov rcx, r15
    call .Lres_start_tool
    jmp .Lrs_ret

.Lrs_text_delta:
    mov rdi, rbx
    lea rsi, [rip + .K_delta]
    call json_get
    test rax, rax
    jz .Lrs_ret
    mov rdi, rax
    call json_str
    test rax, rax
    jz .Lrs_ret
    test rdx, rdx
    jz .Lrs_ret
    mov rcx, rdx
    mov rdx, rax
    mov rdi, r13
    mov esi, SE_TEXT
    call .Lsink_emit
    or dword ptr [r12 + OR_CTX_FLAGS], OF_TEXT
    jmp .Lrs_ret

.Lrs_think_delta:
    mov rdi, rbx
    lea rsi, [rip + .K_delta]
    call json_get
    test rax, rax
    jz .Lrs_ret
    mov rdi, rax
    call json_str
    test rax, rax
    jz .Lrs_ret
    test rdx, rdx
    jz .Lrs_ret
    mov rcx, rdx
    mov rdx, rax
    mov rdi, r13
    mov esi, SE_THINK
    call .Lsink_emit
    or dword ptr [r12 + OR_CTX_FLAGS], OF_THINK
    jmp .Lrs_ret

.Lrs_fc_delta:
    mov rdi, rbx
    lea rsi, [rip + .K_output_index]
    xor edx, edx
    call json_get_u64
    cmp rax, OR_TABLE
    jae .Lrs_ret
    mov r15, rax
    cmp dword ptr [r12 + OR_CTX_ST + r15*4], OS_STARTED
    jne .Lrs_ret
    mov rdi, rbx
    lea rsi, [rip + .K_delta]
    call json_get
    test rax, rax
    jz .Lrs_ret
    mov rdi, rax
    call json_str
    test rax, rax
    jz .Lrs_ret
    test rdx, rdx
    jz .Lrs_ret
    mov rcx, rdx
    mov rdx, rax
    mov rdi, r13
    mov esi, SE_TOOL_DELTA
    call .Lsink_emit
    mov eax, 1
    mov ecx, r15d
    shl eax, cl
    or dword ptr [r12 + OR_CTX_DSEEN], eax
    jmp .Lrs_ret

.Lrs_fc_done:
    mov rdi, rbx
    lea rsi, [rip + .K_output_index]
    xor edx, edx
    call json_get_u64
    mov r15, rax
    # the .done event carries the full arguments: emit them when the streamed
    # delta never arrived, so the agent never sees an empty tool call.
    mov rdi, r12
    mov rsi, r13
    mov rdx, rbx
    mov rcx, r15
    call .Lres_args
    mov rdi, r12
    mov rsi, r13
    mov rdx, r15
    call .Lres_end_tool
    jmp .Lrs_ret

.Lrs_item_done:
    mov rdi, rbx
    lea rsi, [rip + .K_output_index]
    xor edx, edx
    call json_get_u64
    mov r15, rax
    mov rdi, rbx
    lea rsi, [rip + .K_item]
    call json_get
    test rax, rax
    jz .Lrs_ret
    mov [rsp], rax
    mov rdi, rax
    lea rsi, [rip + .K_type]
    call json_get_cstr
    test rax, rax
    jz .Lrs_ret
    mov r14, rax
    # function_call
    mov rdi, r14
    mov esi, 13
    lea rdx, [rip + .V_function_call]
    call str_eq_cstr
    test eax, eax
    jz .Lrs_id_other
    cmp r15, OR_TABLE
    jae .Lrs_id_fc_end
    cmp dword ptr [r12 + OR_CTX_ST + r15*4], OS_UNSEEN
    jne .Lrs_id_fc_end
    mov rdi, r12
    mov rsi, r13
    mov rdx, [rsp]
    mov rcx, r15
    call .Lres_start_tool
.Lrs_id_fc_end:
    mov rdi, r12
    mov rsi, r13
    mov rdx, [rsp]
    mov rcx, r15
    call .Lres_args
    mov rdi, r12
    mov rsi, r13
    mov rdx, r15
    call .Lres_end_tool
    jmp .Lrs_ret
.Lrs_id_other:
    # message -> close text
    mov rdi, r14
    mov esi, 7
    lea rdx, [rip + .V_message]
    call str_eq_cstr
    test eax, eax
    jz .Lrs_id_reason
    mov eax, [r12 + OR_CTX_FLAGS]
    test eax, OF_TEXT
    jz .Lrs_ret
    and dword ptr [r12 + OR_CTX_FLAGS], ~OF_TEXT
    mov rdi, r13
    mov esi, SE_TEXT_END
    xor edx, edx
    xor ecx, ecx
    call .Lsink_emit
    jmp .Lrs_ret
.Lrs_id_reason:
    # reasoning -> close thinking
    mov rdi, r14
    mov esi, 9
    lea rdx, [rip + .V_reasoning]
    call str_eq_cstr
    test eax, eax
    jz .Lrs_ret
    mov eax, [r12 + OR_CTX_FLAGS]
    test eax, OF_THINK
    jz .Lrs_ret
    and dword ptr [r12 + OR_CTX_FLAGS], ~OF_THINK
    mov rdi, r13
    mov esi, SE_THINK_END
    xor edx, edx
    xor ecx, ecx
    call .Lsink_emit
    jmp .Lrs_ret

.Lrs_completed:
    cmp dword ptr [r12 + OR_CTX_DONE], 0
    jne .Lrs_ret
    mov dword ptr [r12 + OR_CTX_DONE], 1
    mov rdi, r12
    mov rsi, r13
    call .Lres_flush_text
    mov rdi, r12
    mov rsi, r13
    call .Lres_close_tools
    # usage
    mov rdi, rbx
    lea rsi, [rip + .K_response]
    call json_get
    test rax, rax
    jz .Lrs_comp_done
    mov r14, rax
    mov rdi, r14
    lea rsi, [rip + .K_usage]
    call json_get
    test rax, rax
    jz .Lrs_comp_done
    mov rdi, rax
    mov rsi, r13
    call .Lres_usage
.Lrs_comp_done:
    # response.completed maps to STOP/TOOL_USE; any unrecognised reason is
    # treated as STOP (shared stop-reason policy across the three adapters).
    mov eax, SR_STOP
    test dword ptr [r12 + OR_CTX_FLAGS], OF_TOOL
    jz .Lrs_comp_emit
    mov eax, SR_TOOL_USE
.Lrs_comp_emit:
    mov rdi, r13
    mov esi, SE_DONE
    mov edx, eax
    xor ecx, ecx
    call .Lsink_emit
    jmp .Lrs_ret

.Lrs_incomplete:
    cmp dword ptr [r12 + OR_CTX_DONE], 0
    jne .Lrs_ret
    mov dword ptr [r12 + OR_CTX_DONE], 1
    mov rdi, r12
    mov rsi, r13
    call .Lres_flush_text
    mov rdi, r12
    mov rsi, r13
    call .Lres_close_tools
    mov rdi, r13
    mov esi, SE_DONE
    mov edx, SR_LENGTH
    xor ecx, ecx
    call .Lsink_emit
    jmp .Lrs_ret

.Lrs_error:
    mov rdi, rbx
    lea rsi, [rip + .K_message]
    call json_get_cstr
    test rax, rax
    jnz .Lrs_err_have
    lea rax, [rip + .Lprovider_err]
.Lrs_err_have:
    mov dword ptr [r12 + OR_CTX_DONE], 1
    mov rdi, r13
    mov esi, SE_ERROR
    mov rdx, rax
    xor ecx, ecx
    call .Lsink_emit
    jmp .Lrs_ret

.Lrs_failed:
    mov rdi, rbx
    lea rsi, [rip + .K_response]
    call json_get
    mov r14, rax
    test r14, r14
    jz .Lrs_fail_default
    mov rdi, r14
    lea rsi, [rip + .K_error]
    call json_get
    test rax, rax
    jz .Lrs_fail_reason
    mov rdi, rax
    lea rsi, [rip + .K_message]
    call json_get_cstr
    test rax, rax
    jnz .Lrs_fail_have
.Lrs_fail_reason:
    mov rdi, r14
    lea rsi, [rip + .K_incomplete]
    call json_get
    test rax, rax
    jz .Lrs_fail_default
    mov rdi, rax
    lea rsi, [rip + .K_reason]
    call json_get_cstr
    test rax, rax
    jnz .Lrs_fail_have
.Lrs_fail_default:
    lea rax, [rip + .Lprovider_err]
.Lrs_fail_have:
    mov dword ptr [r12 + OR_CTX_DONE], 1
    mov rdi, r13
    mov esi, SE_ERROR
    mov rdx, rax
    xor ecx, ecx
    call .Lsink_emit
.Lrs_ret:
    xor eax, eax
    EPILOGUE

# .Lprov_finish(ctx, SS*) -> 0
.Lprov_finish:
    PROLOGUE 0
    mov r12, rdi
    mov r13, rsi
    cmp dword ptr [r12 + OR_CTX_DONE], 0
    jne .Lof_ret
    mov dword ptr [r12 + OR_CTX_DONE], 1
    mov rdi, r13
    mov esi, SE_ERROR
    lea rdx, [rip + .Ltruncated]
    xor ecx, ecx
    call .Lsink_emit
.Lof_ret:
    xor eax, eax
    EPILOGUE

# .Lprov_free(ctx): release the embedded scratch SB, then the context.
.Lprov_free:
    PROLOGUE 0
    mov rbx, rdi
    lea rdi, [rbx + OR_CTX_SCRATCH]
    call sb_free
    mov rdi, rbx
    call mem_free
    EPILOGUE

.section .rodata
.Lnewline: .ascii "\n"

.section .data
.p2align 3
.globl prov_openai_responses
GTYPE prov_openai_responses, @object
prov_openai_responses:
    .quad .Lprov_new
    .quad .Lprov_build
    .quad .Lprov_path
    .quad .Lprov_sse
    .quad .Lprov_finish
    .quad .Lprov_free
GSIZE prov_openai_responses, PV_SIZE
