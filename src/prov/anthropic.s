.include "opcode.inc"
.include "core/core.inc"
# prov/anthropic.s: Anthropic Messages provider adapter. Contract: src/core/API.md.
#
# ctx layout (first two fields are public, everything past them is private):
#   0   MD*    model
#   8   u32    max_tokens    (the agent may overwrite this directly)
#   12  u32    done           (SE_DONE/SE_ERROR emitted)
#   16  cstr   err            (reserved)
#   24  u32    stop_reason    (SR_PENDING until message_delta)
#   28  u32    nblocks
#   32  Usage  usage          (merged across message_start / message_delta)
#   56  u8[16] block_types    (per content-block index)

.equ A_CTX_MD,      0
.equ A_CTX_MAX,     8
.equ A_CTX_DONE,    12
.equ A_CTX_ERR,     16
.equ A_CTX_STOP,    24
.equ A_CTX_NBLK,    28
.equ A_CTX_USAGE,   32
.equ A_CTX_TYPES,   56
.equ A_CTX_SIZE,    72

.equ AB_NONE,       0
.equ AB_TEXT,       1
.equ AB_THINK,      2
.equ AB_TOOL,       3

.section .rodata
.Lempty:        .asciz ""
.Lempty_obj:    .asciz "{}"
.Lpath:         .asciz "/v1/messages"
.Lprovider_err: .asciz "provider error"
.Ltruncated:    .asciz "stream ended without message_stop"

# JSON keys / values
.K_model:        .asciz "model"
.K_max_tokens:   .asciz "max_tokens"
.K_stream:       .asciz "stream"
.K_thinking:     .asciz "thinking"
.K_budget:       .asciz "budget_tokens"
.K_system:       .asciz "system"
.K_messages:     .asciz "messages"
.K_tools:        .asciz "tools"
.K_type:         .asciz "type"
.K_text:         .asciz "text"
.K_role:         .asciz "role"
.K_content:      .asciz "content"
.K_name:         .asciz "name"
.K_description:  .asciz "description"
.K_input_schema: .asciz "input_schema"
.K_id:           .asciz "id"
.K_tool_use_id:  .asciz "tool_use_id"
.K_input:        .asciz "input"
.K_message:      .asciz "message"
.K_usage:        .asciz "usage"
.K_index:        .asciz "index"
.K_content_block: .asciz "content_block"
.K_delta:        .asciz "delta"
.K_stop_reason:  .asciz "stop_reason"
.K_error:        .asciz "error"
.K_partial_json: .asciz "partial_json"
.K_input_tokens:       .asciz "input_tokens"
.K_output_tokens:      .asciz "output_tokens"
.K_cache_read:         .asciz "cache_read_input_tokens"
.K_cache_write:        .asciz "cache_creation_input_tokens"

# Thinking budget by level (index 0..3): off/low/medium/high.
.p2align 2
.Lbudget_tab:
    .long 0
    .long 1024
    .long 4096
    .long 8192

.V_enabled:      .asciz "enabled"
.V_text:         .asciz "text"
.V_thinking:     .asciz "thinking"
.V_tool_use:     .asciz "tool_use"
.V_user:         .asciz "user"
.V_assistant:    .asciz "assistant"
.V_tool_result:  .asciz "tool_result"

# event type names
.Ev_message_start:  .asciz "message_start"
.Ev_cb_start:       .asciz "content_block_start"
.Ev_cb_delta:       .asciz "content_block_delta"
.Ev_cb_stop:        .asciz "content_block_stop"
.Ev_message_delta:  .asciz "message_delta"
.Ev_message_stop:   .asciz "message_stop"
.Ev_error:          .asciz "error"

# delta type names
.Dv_text_delta:     .asciz "text_delta"
.Dv_thinking_delta: .asciz "thinking_delta"
.Dv_input_delta:    .asciz "input_json_delta"

# stop reasons
.Sr_end_turn:      .asciz "end_turn"
.Sr_max_tokens:    .asciz "max_tokens"
.Sr_stop_sequence: .asciz "stop_sequence"
.Sr_tool_use:      .asciz "tool_use"
.Sr_pause_turn:    .asciz "pause_turn"
.Sr_refusal:       .asciz "refusal"

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
# .Lanth_usage(usage JV*, Usage*): merge present numeric fields, recompute total.
.Lanth_usage:
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rbx
    lea rsi, [rip + .K_input_tokens]
    mov edx, [r12 + USG_input]
    call json_get_u64
    mov [r12 + USG_input], eax
    mov rdi, rbx
    lea rsi, [rip + .K_output_tokens]
    mov edx, [r12 + USG_output]
    call json_get_u64
    mov [r12 + USG_output], eax
    mov rdi, rbx
    lea rsi, [rip + .K_cache_read]
    mov edx, [r12 + USG_cache_read]
    call json_get_u64
    mov [r12 + USG_cache_read], eax
    mov rdi, rbx
    lea rsi, [rip + .K_cache_write]
    mov edx, [r12 + USG_cache_write]
    call json_get_u64
    mov [r12 + USG_cache_write], eax
    mov eax, [r12 + USG_input]
    add eax, [r12 + USG_output]
    add eax, [r12 + USG_cache_read]
    add eax, [r12 + USG_cache_write]
    mov [r12 + USG_total], eax
    EPILOGUE

# .Lanth_stop_map(cstr) -> eax SR_*
.Lanth_stop_map:
    PROLOGUE 0
    mov rbx, rdi
    mov rdi, rbx
    mov esi, 8
    lea rdx, [rip + .Sr_end_turn]
    call str_eq_cstr
    test eax, eax
    jnz .Lsm_stop
    mov rdi, rbx
    mov esi, 10
    lea rdx, [rip + .Sr_max_tokens]
    call str_eq_cstr
    test eax, eax
    jnz .Lsm_length
    mov rdi, rbx
    mov esi, 13
    lea rdx, [rip + .Sr_stop_sequence]
    call str_eq_cstr
    test eax, eax
    jnz .Lsm_stop
    mov rdi, rbx
    mov esi, 8
    lea rdx, [rip + .Sr_tool_use]
    call str_eq_cstr
    test eax, eax
    jnz .Lsm_tool
    mov rdi, rbx
    mov esi, 10
    lea rdx, [rip + .Sr_pause_turn]
    call str_eq_cstr
    test eax, eax
    jnz .Lsm_stop
    mov rdi, rbx
    mov esi, 7
    lea rdx, [rip + .Sr_refusal]
    call str_eq_cstr
    test eax, eax
    jnz .Lsm_error
    # Unknown/absent stop_reason maps to SR_STOP: the policy shared by all
    # three adapters (see openai.s / openai_responses.s).
    mov eax, SR_STOP
    EPILOGUE
.Lsm_stop:
    mov eax, SR_STOP
    EPILOGUE
.Lsm_length:
    mov eax, SR_LENGTH
    EPILOGUE
.Lsm_tool:
    mov eax, SR_TOOL_USE
    EPILOGUE
.Lsm_error:
    mov eax, SR_ERROR
    EPILOGUE

# .Lanth_text(sb, Block*): {"type":"text","text":<ptr,len>}
.Lanth_text:
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rbx
    call jsonw_obj
    mov rdi, rbx
    lea rsi, [rip + .K_type]
    call jsonw_key
    mov rdi, rbx
    lea rsi, [rip + .V_text]
    call jsonw_str_cstr
    mov rdi, rbx
    lea rsi, [rip + .K_text]
    call jsonw_key
    mov rdi, rbx
    mov rsi, [r12 + B_ptr]
    mov rdx, [r12 + B_len]
    call jsonw_str
    mov rdi, rbx
    call jsonw_obj_end
    EPILOGUE

# .Lanth_assistant(sb, Msg*): content blocks in stream order.
.Lanth_assistant:
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi
    mov rax, [r12 + M_blocks]
    test rax, rax
    jz .Lpa_ret
    mov r13, [rax + VEC_ptr]
    mov r14, [rax + VEC_len]
    test r14, r14
    jz .Lpa_ret
    mov [rsp], r13
    mov [rsp + 8], r14
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
    xor r15d, r15d
.Lpa_loop:
    cmp r15, [rsp + 8]
    jae .Lpa_close
    mov r13, [rsp]
    lea rax, [r15 + r15*2]
    lea r13, [r13 + rax*8]          # Block*
    mov eax, [r13 + B_type]
    cmp eax, BT_TEXT
    jne .Lpa_think
    mov rdi, rbx
    mov rsi, r13
    call .Lanth_text
    jmp .Lpa_next
.Lpa_think:
    cmp eax, BT_THINK
    jne .Lpa_tool
    # Anthropic rejects a replayed thinking block without its signature, and
    # the agent does not retain signatures across turns. Omitting prior
    # thinking is the only safe replay; emitting it unsigned would 400.
    jmp .Lpa_next
.Lpa_tool:
    cmp eax, BT_TOOLCALL
    jne .Lpa_next
    mov r13, [r13 + B_ptr]          # TC*
    mov rdi, rbx
    call jsonw_obj
    mov rdi, rbx
    lea rsi, [rip + .K_type]
    call jsonw_key
    mov rdi, rbx
    lea rsi, [rip + .V_tool_use]
    call jsonw_str_cstr
    mov rdi, rbx
    lea rsi, [rip + .K_id]
    call jsonw_key
    mov rdi, rbx
    mov rsi, [r13 + TC_id]
    call jsonw_str_cstr
    mov rdi, rbx
    lea rsi, [rip + .K_name]
    call jsonw_key
    mov rdi, rbx
    mov rsi, [r13 + TC_name]
    call jsonw_str_cstr
    mov rdi, rbx
    lea rsi, [rip + .K_input]
    call jsonw_key
    mov rdi, [r13 + TC_args]
    test rdi, rdi
    jz .Lpa_tool_empty
    # A streamed/truncated args string that does not parse (or is not an
    # object) would make the next request body invalid; emit {} instead.
    # json_parse resets the arena, which is safe here: transcript strings are
    # copies and no parsed JV survives from one turn to the next.
    call strlen
    mov rsi, rax
    mov rdi, [r13 + TC_args]
    call json_parse
    test rax, rax
    jz .Lpa_tool_empty
    cmp dword ptr [rax + JV_type], JT_OBJ
    jne .Lpa_tool_empty
    mov rdi, [r13 + TC_args]
    call strlen
    mov rdx, rax
    mov rsi, [r13 + TC_args]
    mov rdi, rbx
    call jsonw_raw
    jmp .Lpa_tool_end
.Lpa_tool_empty:
    mov rdi, rbx
    lea rsi, [rip + .Lempty_obj]
    mov edx, 2
    call jsonw_raw
.Lpa_tool_end:
    mov rdi, rbx
    call jsonw_obj_end
.Lpa_next:
    inc r15
    jmp .Lpa_loop
.Lpa_close:
    mov rdi, rbx
    call jsonw_arr_end
    mov rdi, rbx
    call jsonw_obj_end
.Lpa_ret:
    EPILOGUE

# .Lanth_user(sb, Msg*): text blocks only; empty user messages are skipped.
.Lanth_user:
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi
    mov rax, [r12 + M_blocks]
    test rax, rax
    jz .Lpu_ret
    mov r13, [rax + VEC_ptr]
    mov r14, [rax + VEC_len]
    test r14, r14
    jz .Lpu_ret
    mov [rsp], r13
    mov [rsp + 8], r14
    mov dword ptr [rsp + 16], 0
    xor r15d, r15d
.Lpu_count:
    cmp r15, [rsp + 8]
    jae .Lpu_counted
    mov r13, [rsp]
    lea rax, [r15 + r15*2]
    cmp dword ptr [r13 + rax*8 + B_type], BT_TEXT
    jne .Lpu_count_next
    inc dword ptr [rsp + 16]
.Lpu_count_next:
    inc r15
    jmp .Lpu_count
.Lpu_counted:
    cmp dword ptr [rsp + 16], 0
    je .Lpu_ret
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
.Lpu_loop:
    cmp r15, [rsp + 8]
    jae .Lpu_close
    mov r13, [rsp]
    lea rax, [r15 + r15*2]
    lea r13, [r13 + rax*8]
    cmp dword ptr [r13 + B_type], BT_TEXT
    jne .Lpu_next
    mov rdi, rbx
    mov rsi, r13
    call .Lanth_text
.Lpu_next:
    inc r15
    jmp .Lpu_loop
.Lpu_close:
    mov rdi, rbx
    call jsonw_arr_end
    mov rdi, rbx
    call jsonw_obj_end
.Lpu_ret:
    EPILOGUE

# .Lanth_toolresult(sb, Msg*): one user message with a tool_result block.
.Lanth_toolresult:
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi
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
    mov rdi, rbx
    call jsonw_obj
    mov rdi, rbx
    lea rsi, [rip + .K_type]
    call jsonw_key
    mov rdi, rbx
    lea rsi, [rip + .V_tool_result]
    call jsonw_str_cstr
    mov rdi, rbx
    lea rsi, [rip + .K_tool_use_id]
    call jsonw_key
    mov rsi, [r12 + M_call_id]
    test rsi, rsi
    jnz .Lptr_id
    lea rsi, [rip + .Lempty]
.Lptr_id:
    mov rdi, rbx
    call jsonw_str_cstr
    mov rdi, rbx
    lea rsi, [rip + .K_content]
    call jsonw_key
    mov rdi, rbx
    call jsonw_arr
    mov rax, [r12 + M_blocks]
    test rax, rax
    jz .Lptr_close
    mov r13, [rax + VEC_ptr]
    mov r14, [rax + VEC_len]
    mov [rsp], r13
    mov [rsp + 8], r14
    xor r15d, r15d
.Lptr_loop:
    cmp r15, [rsp + 8]
    jae .Lptr_close
    mov r13, [rsp]
    lea rax, [r15 + r15*2]
    lea r13, [r13 + rax*8]
    cmp dword ptr [r13 + B_type], BT_TEXT
    jne .Lptr_next
    mov rdi, rbx
    mov rsi, r13
    call .Lanth_text
.Lptr_next:
    inc r15
    jmp .Lptr_loop
.Lptr_close:
    mov rdi, rbx
    call jsonw_arr_end
    mov rdi, rbx
    call jsonw_obj_end
    mov rdi, rbx
    call jsonw_arr_end
    mov rdi, rbx
    call jsonw_obj_end
    EPILOGUE

# ---------------------------------------------------------------- vtable members
# .Lprov_new(MD*) -> ctx
.Lprov_new:
    PROLOGUE 0
    mov r12, rdi
    mov edi, A_CTX_SIZE
    call mem_alloc
    mov rbx, rax
    mov [rbx + A_CTX_MD], r12
    mov eax, 4096
    test r12, r12
    jz .Lpn_store
    mov ecx, [r12 + MD_max_tokens]
    test ecx, ecx
    jz .Lpn_store
    mov eax, ecx
.Lpn_store:
    mov [rbx + A_CTX_MAX], eax
    mov rax, rbx
    EPILOGUE

# .Lprov_path(ctx) -> "/v1/messages"
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
    mov dword ptr [r12 + A_CTX_DONE], 0
    mov dword ptr [r12 + A_CTX_STOP], 0
    mov dword ptr [r12 + A_CTX_NBLK], 0
    mov qword ptr [r12 + A_CTX_USAGE], 0
    mov qword ptr [r12 + A_CTX_USAGE + 8], 0
    mov qword ptr [r12 + A_CTX_USAGE + 16], 0
    mov qword ptr [r12 + A_CTX_TYPES], 0
    mov qword ptr [r12 + A_CTX_TYPES + 8], 0

    mov rdi, rbx
    call jsonw_obj

    # model
    mov rdi, rbx
    lea rsi, [rip + .K_model]
    call jsonw_key
    mov rsi, [r12 + A_CTX_MD]
    test rsi, rsi
    jz .Lpb_model_empty
    mov rsi, [rsi + MD_id]
    test rsi, rsi
    jnz .Lpb_model_go
.Lpb_model_empty:
    lea rsi, [rip + .Lempty]
.Lpb_model_go:
    mov rdi, rbx
    call jsonw_str_cstr

    # max_tokens
    mov rdi, rbx
    lea rsi, [rip + .K_max_tokens]
    call jsonw_key
    mov esi, [r12 + A_CTX_MAX]
    test esi, esi
    jnz .Lpb_max_go
    mov esi, 4096
.Lpb_max_go:
    mov rdi, rbx
    call jsonw_u64

    # stream
    mov rdi, rbx
    lea rsi, [rip + .K_stream]
    call jsonw_key
    mov rdi, rbx
    mov esi, 1
    call jsonw_bool

    # thinking (reasoning models only): level-driven.  `off`, to a
    # non-reasoning model, or too small a max_tokens emits no object.  Budget
    # low=1024 / medium=4096 / high=8192, clamped to max_tokens-1024 so the API
    # invariant budget < max_tokens always holds; omit when it falls under 1024.
    mov rax, [r12 + A_CTX_MD]
    test rax, rax
    jz .Lpb_no_think
    test dword ptr [rax + MD_flags], MDF_REASONING
    jz .Lpb_no_think
    mov r15d, [rip + g_agent_thinking]
    test r15d, r15d
    jle .Lpb_no_think
    cmp r15d, TH_HIGH
    jbe 11f
    mov r15d, TH_HIGH
11: lea rax, [rip + .Lbudget_tab]
    mov r15d, [rax + r15*4]
    mov eax, [r12 + A_CTX_MAX]
    test eax, eax
    jnz 12f
    mov eax, 4096
12: cmp eax, 2048
    jb .Lpb_no_think
    sub eax, 1024
    cmp r15d, eax
    jbe 13f
    mov r15d, eax
13: cmp r15d, 1024
    jb .Lpb_no_think
    mov rdi, rbx
    lea rsi, [rip + .K_thinking]
    call jsonw_key
    mov rdi, rbx
    call jsonw_obj
    mov rdi, rbx
    lea rsi, [rip + .K_type]
    call jsonw_key
    mov rdi, rbx
    lea rsi, [rip + .V_enabled]
    call jsonw_str_cstr
    mov rdi, rbx
    lea rsi, [rip + .K_budget]
    call jsonw_key
    mov rdi, rbx
    mov esi, r15d
    call jsonw_u64
    mov rdi, rbx
    call jsonw_obj_end
.Lpb_no_think:

    # system
    test r13, r13
    jz .Lpb_no_sys
    mov rdi, rbx
    lea rsi, [rip + .K_system]
    call jsonw_key
    mov rdi, rbx
    call jsonw_arr
    mov rdi, rbx
    call jsonw_obj
    mov rdi, rbx
    lea rsi, [rip + .K_type]
    call jsonw_key
    mov rdi, rbx
    lea rsi, [rip + .V_text]
    call jsonw_str_cstr
    mov rdi, rbx
    lea rsi, [rip + .K_text]
    call jsonw_key
    mov rdi, rbx
    mov rsi, r13
    call jsonw_str_cstr
    mov rdi, rbx
    call jsonw_obj_end
    mov rdi, rbx
    call jsonw_arr_end
.Lpb_no_sys:

    # messages
    mov rdi, rbx
    lea rsi, [rip + .K_messages]
    call jsonw_key
    mov rdi, rbx
    call jsonw_arr
    xor r15d, r15d
.Lpb_msg_loop:
    mov rdi, r14
    call tr_len
    cmp r15, rax
    jae .Lpb_msgs_done
    mov rdi, r14
    mov rsi, r15
    call tr_msg
    test rax, rax
    jz .Lpb_msg_next
    mov r13, rax
    mov eax, [r13 + M_role]
    cmp eax, MR_USER
    jne .Lpb_msg_asst
    mov rdi, rbx
    mov rsi, r13
    call .Lanth_user
    jmp .Lpb_msg_next
.Lpb_msg_asst:
    cmp eax, MR_ASSISTANT
    jne .Lpb_msg_tool
    mov rdi, rbx
    mov rsi, r13
    call .Lanth_assistant
    jmp .Lpb_msg_next
.Lpb_msg_tool:
    cmp eax, MR_TOOL_RESULT
    jne .Lpb_msg_next
    mov rdi, rbx
    mov rsi, r13
    call .Lanth_toolresult
.Lpb_msg_next:
    inc r15
    jmp .Lpb_msg_loop
.Lpb_msgs_done:
    mov rdi, rbx
    call jsonw_arr_end

    # tools
    call tools_active
    mov r13, rax
    test r13, r13
    jz .Lpb_obj_end
    cmp qword ptr [r13 + VEC_len], 0
    je .Lpb_obj_end
    mov rdi, rbx
    lea rsi, [rip + .K_tools]
    call jsonw_key
    mov rdi, rbx
    call jsonw_arr
    xor r15d, r15d
.Lpb_tool_loop:
    cmp r15, [r13 + VEC_len]
    jae .Lpb_tools_end
    mov rax, [r13 + VEC_ptr]
    mov r12, [rax + r15*8]          # TL*
    test r12, r12
    jz .Lpb_tool_next
    mov rdi, rbx
    call jsonw_obj
    mov rdi, rbx
    lea rsi, [rip + .K_name]
    call jsonw_key
    mov rsi, [r12 + TL_name]
    test rsi, rsi
    jnz .Lpb_tool_name
    lea rsi, [rip + .Lempty]
.Lpb_tool_name:
    mov rdi, rbx
    call jsonw_str_cstr
    mov rdi, rbx
    lea rsi, [rip + .K_description]
    call jsonw_key
    mov rsi, [r12 + TL_desc]
    test rsi, rsi
    jnz .Lpb_tool_desc
    lea rsi, [rip + .Lempty]
.Lpb_tool_desc:
    mov rdi, rbx
    call jsonw_str_cstr
    mov rdi, rbx
    lea rsi, [rip + .K_input_schema]
    call jsonw_key
    mov rdi, [r12 + TL_params]
    test rdi, rdi
    jz .Lpb_tool_schema_empty
    call strlen
    mov rdx, rax
    mov rsi, [r12 + TL_params]
    mov rdi, rbx
    call jsonw_raw
    jmp .Lpb_tool_obj_end
.Lpb_tool_schema_empty:
    mov rdi, rbx
    lea rsi, [rip + .Lempty_obj]
    mov edx, 2
    call jsonw_raw
.Lpb_tool_obj_end:
    mov rdi, rbx
    call jsonw_obj_end
.Lpb_tool_next:
    inc r15
    jmp .Lpb_tool_loop
.Lpb_tools_end:
    mov rdi, rbx
    call jsonw_arr_end
.Lpb_obj_end:
    mov rdi, rbx
    call jsonw_obj_end
    xor eax, eax
    EPILOGUE

# .Lprov_sse(ctx, SS*, event ptr, event len, data ptr, data len) -> 0
.Lprov_sse:
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    mov rdi, r8
    mov rsi, r9
    call json_parse
    test rax, rax
    jz .Lps_ret
    mov rbx, rax
    mov rdi, rbx
    lea rsi, [rip + .K_type]
    call json_get_cstr
    test rax, rax
    jz .Lps_ret
    mov r14, rax

    # message_start
    mov rdi, r14
    mov esi, 13
    lea rdx, [rip + .Ev_message_start]
    call str_eq_cstr
    test eax, eax
    jnz .Lps_msg_start
    # content_block_start
    mov rdi, r14
    mov esi, 19
    lea rdx, [rip + .Ev_cb_start]
    call str_eq_cstr
    test eax, eax
    jnz .Lps_cb_start
    # content_block_delta
    mov rdi, r14
    mov esi, 19
    lea rdx, [rip + .Ev_cb_delta]
    call str_eq_cstr
    test eax, eax
    jnz .Lps_cb_delta
    # content_block_stop
    mov rdi, r14
    mov esi, 18
    lea rdx, [rip + .Ev_cb_stop]
    call str_eq_cstr
    test eax, eax
    jnz .Lps_cb_stop
    # message_delta
    mov rdi, r14
    mov esi, 13
    lea rdx, [rip + .Ev_message_delta]
    call str_eq_cstr
    test eax, eax
    jnz .Lps_msg_delta
    # message_stop
    mov rdi, r14
    mov esi, 12
    lea rdx, [rip + .Ev_message_stop]
    call str_eq_cstr
    test eax, eax
    jnz .Lps_msg_stop
    # error
    mov rdi, r14
    mov esi, 5
    lea rdx, [rip + .Ev_error]
    call str_eq_cstr
    test eax, eax
    jnz .Lps_error
    jmp .Lps_ret

.Lps_msg_start:
    mov rdi, rbx
    lea rsi, [rip + .K_message]
    call json_get
    test rax, rax
    jz .Lps_ret
    mov rdi, rax
    lea rsi, [rip + .K_usage]
    call json_get
    test rax, rax
    jz .Lps_ret
    mov rdi, rax
    lea rsi, [r12 + A_CTX_USAGE]
    call .Lanth_usage
    mov rdi, r13
    mov esi, SE_USAGE
    lea rdx, [r12 + A_CTX_USAGE]
    xor ecx, ecx
    call .Lsink_emit
    jmp .Lps_ret

.Lps_cb_start:
    mov rdi, rbx
    lea rsi, [rip + .K_index]
    xor edx, edx
    call json_get_u64
    cmp rax, 16
    jae .Lps_ret
    mov r15, rax
    mov rdi, rbx
    lea rsi, [rip + .K_content_block]
    call json_get
    test rax, rax
    jz .Lps_ret
    mov [rsp], rax
    mov rdi, rax
    lea rsi, [rip + .K_type]
    call json_get_cstr
    test rax, rax
    jz .Lps_ret
    mov r14, rax
    mov rdi, r14
    mov esi, 4
    lea rdx, [rip + .V_text]
    call str_eq_cstr
    test eax, eax
    jz .Lps_cbs_think
    mov byte ptr [r12 + A_CTX_TYPES + r15], AB_TEXT
    jmp .Lps_ret
.Lps_cbs_think:
    mov rdi, r14
    mov esi, 8
    lea rdx, [rip + .V_thinking]
    call str_eq_cstr
    test eax, eax
    jz .Lps_cbs_tool
    mov byte ptr [r12 + A_CTX_TYPES + r15], AB_THINK
    jmp .Lps_ret
.Lps_cbs_tool:
    mov rdi, r14
    mov esi, 8
    lea rdx, [rip + .V_tool_use]
    call str_eq_cstr
    test eax, eax
    jz .Lps_ret
    mov byte ptr [r12 + A_CTX_TYPES + r15], AB_TOOL
    mov rdi, [rsp]
    lea rsi, [rip + .K_id]
    call json_get_cstr
    mov [rsp + 8], rax
    mov rdi, [rsp]
    lea rsi, [rip + .K_name]
    call json_get_cstr
    mov rcx, rax
    mov rdx, [rsp + 8]
    test rdx, rdx
    jnz .Lps_cbs_id
    lea rdx, [rip + .Lempty]
.Lps_cbs_id:
    test rcx, rcx
    jnz .Lps_cbs_name
    lea rcx, [rip + .Lempty]
.Lps_cbs_name:
    mov rdi, r13
    mov esi, SE_TOOL_START
    call .Lsink_emit
    jmp .Lps_ret

.Lps_cb_delta:
    mov rdi, rbx
    lea rsi, [rip + .K_delta]
    call json_get
    test rax, rax
    jz .Lps_ret
    mov [rsp], rax
    mov rdi, rax
    lea rsi, [rip + .K_type]
    call json_get_cstr
    test rax, rax
    jz .Lps_ret
    mov r14, rax
    mov rdi, r14
    mov esi, 10
    lea rdx, [rip + .Dv_text_delta]
    call str_eq_cstr
    test eax, eax
    jnz .Lps_cbd_text
    mov rdi, r14
    mov esi, 14
    lea rdx, [rip + .Dv_thinking_delta]
    call str_eq_cstr
    test eax, eax
    jnz .Lps_cbd_think
    mov rdi, r14
    mov esi, 16
    lea rdx, [rip + .Dv_input_delta]
    call str_eq_cstr
    test eax, eax
    jnz .Lps_cbd_input
    jmp .Lps_ret
.Lps_cbd_text:
    mov r15d, SE_TEXT
    lea rsi, [rip + .K_text]
    jmp .Lps_cbd_field
.Lps_cbd_think:
    mov r15d, SE_THINK
    lea rsi, [rip + .K_thinking]
    jmp .Lps_cbd_field
.Lps_cbd_input:
    mov r15d, SE_TOOL_DELTA
    lea rsi, [rip + .K_partial_json]
.Lps_cbd_field:
    mov rdi, [rsp]
    call json_get
    test rax, rax
    jz .Lps_ret
    mov rdi, rax
    call json_str
    test rax, rax
    jz .Lps_ret
    test rdx, rdx
    jz .Lps_ret
    mov rcx, rdx
    mov rdx, rax
    mov rdi, r13
    mov esi, r15d
    call .Lsink_emit
    jmp .Lps_ret

.Lps_cb_stop:
    mov rdi, rbx
    lea rsi, [rip + .K_index]
    xor edx, edx
    call json_get_u64
    cmp rax, 16
    jae .Lps_ret
    mov r15, rax
    movzx eax, byte ptr [r12 + A_CTX_TYPES + r15]
    test eax, eax
    jz .Lps_ret
    mov byte ptr [r12 + A_CTX_TYPES + r15], AB_NONE
    cmp eax, AB_TEXT
    je .Lps_stop_text
    cmp eax, AB_THINK
    je .Lps_stop_think
    mov esi, SE_TOOL_END
    jmp .Lps_stop_emit
.Lps_stop_text:
    mov esi, SE_TEXT_END
    jmp .Lps_stop_emit
.Lps_stop_think:
    mov esi, SE_THINK_END
.Lps_stop_emit:
    mov rdi, r13
    xor edx, edx
    xor ecx, ecx
    call .Lsink_emit
    jmp .Lps_ret

.Lps_msg_delta:
    mov rdi, rbx
    lea rsi, [rip + .K_delta]
    call json_get
    test rax, rax
    jz .Lps_md_usage
    mov rdi, rax
    lea rsi, [rip + .K_stop_reason]
    call json_get_cstr
    test rax, rax
    jz .Lps_md_usage
    mov rdi, rax
    call .Lanth_stop_map
    mov [r12 + A_CTX_STOP], eax
.Lps_md_usage:
    mov rdi, rbx
    lea rsi, [rip + .K_usage]
    call json_get
    test rax, rax
    jz .Lps_ret
    mov rdi, rax
    lea rsi, [r12 + A_CTX_USAGE]
    call .Lanth_usage
    mov rdi, r13
    mov esi, SE_USAGE
    lea rdx, [r12 + A_CTX_USAGE]
    xor ecx, ecx
    call .Lsink_emit
    jmp .Lps_ret

.Lps_msg_stop:
    cmp dword ptr [r12 + A_CTX_DONE], 0
    jne .Lps_ret
    mov dword ptr [r12 + A_CTX_DONE], 1
    mov eax, [r12 + A_CTX_STOP]
    test eax, eax
    jnz .Lps_stop_reason
    mov eax, SR_STOP
.Lps_stop_reason:
    mov rdi, r13
    mov esi, SE_DONE
    mov edx, eax
    xor ecx, ecx
    call .Lsink_emit
    jmp .Lps_ret

.Lps_error:
    mov rdi, rbx
    lea rsi, [rip + .K_error]
    call json_get
    test rax, rax
    jz .Lps_err_root
    mov rdi, rax
    lea rsi, [rip + .K_message]
    call json_get_cstr
    test rax, rax
    jnz .Lps_err_have
.Lps_err_root:
    mov rdi, rbx
    lea rsi, [rip + .K_message]
    call json_get_cstr
    test rax, rax
    jnz .Lps_err_have
    lea rax, [rip + .Lprovider_err]
.Lps_err_have:
    mov dword ptr [r12 + A_CTX_DONE], 1
    mov rdi, r13
    mov esi, SE_ERROR
    mov rdx, rax
    xor ecx, ecx
    call .Lsink_emit
.Lps_ret:
    xor eax, eax
    EPILOGUE

# .Lprov_finish(ctx, SS*) -> 0
.Lprov_finish:
    PROLOGUE 0
    mov r12, rdi
    mov r13, rsi
    cmp dword ptr [r12 + A_CTX_DONE], 0
    jne .Lpf_ret
    mov dword ptr [r12 + A_CTX_DONE], 1
    mov eax, [r12 + A_CTX_STOP]
    test eax, eax
    jz .Lpf_trunc
    # message_delta already gave us a stop reason: report it rather than a
    # spurious truncation when the transport ends before message_stop.
    mov rdi, r13
    mov esi, SE_DONE
    mov edx, eax
    xor ecx, ecx
    call .Lsink_emit
    jmp .Lpf_ret
.Lpf_trunc:
    mov rdi, r13
    mov esi, SE_ERROR
    lea rdx, [rip + .Ltruncated]
    xor ecx, ecx
    call .Lsink_emit
.Lpf_ret:
    xor eax, eax
    EPILOGUE

# .Lprov_free(ctx)
.Lprov_free:
    jmp mem_free

.section .data
.p2align 3
.globl prov_anthropic
GTYPE prov_anthropic, @object
prov_anthropic:
    .quad .Lprov_new
    .quad .Lprov_build
    .quad .Lprov_path
    .quad .Lprov_sse
    .quad .Lprov_finish
    .quad .Lprov_free
GSIZE prov_anthropic, PV_SIZE
