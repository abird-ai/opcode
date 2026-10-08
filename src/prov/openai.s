.include "opcode.inc"
.include "core/core.inc"
# prov/openai.s: OpenAI Chat Completions provider adapter. Contract: src/core/API.md.
#
# ctx layout (first two fields are public, everything past them is private):
#   0    MD*    model
#   8    u32    max_tokens      (the agent may overwrite this directly)
#   12   u32    done            (SE_DONE/SE_ERROR emitted)
#   16   u32    open_tool_index (0..15, -1 none)
#   24   u32    stop_reason     (SR_PENDING until finish_reason)
#   28   u32    ntools          (tool-call indices seen)
#   32   u32    nended
#   36   u32    flags           (bit0 text seen, bit1 thinking seen)
#   40   u32[16] tool_status    (0 unseen, 1 started, 2 ended)
#   104  SB     scratch         (joined text for the build)
#   128  SB[16] abuf            (per-index accumulated tool arguments)
#   512  char[16][48] id        (per-index call id)
#   1280 char[16][48] name      (per-index tool name)
#   2048

.equ O_CTX_MD,      0
.equ O_CTX_MAX,     8
.equ O_CTX_DONE,    12
.equ O_CTX_OPEN,    16
.equ O_CTX_STOP,    24
.equ O_CTX_NTOOLS,  28
.equ O_CTX_NEND,    32
.equ O_CTX_FLAGS,   36
.equ O_CTX_ST,      40          # u32[16] tool-call status
.equ O_CTX_SCRATCH, 104         # SB: joined text for the build
.equ O_CTX_ABUF,    128         # SB[16]: per-index argument buffers
.equ O_CTX_ID,      512         # char[16][48]: per-index call id
.equ O_CTX_NAME,    1280        # char[16][48]: per-index tool name
.equ O_CTX_SIZE,    2048

.equ OF_TEXT,       1
.equ OF_THINK,      2

.equ OS_UNSEEN,     0
.equ OS_STARTED,    1
.equ OS_ENDED,      2

.section .rodata
.Lempty:          .asciz ""
.Lnewline:        .ascii "\n"
.Lpath:           .asciz "/chat/completions"
.Ltruncated:      .asciz "stream ended unexpectedly"

# JSON keys / values
.K_model:          .asciz "model"
.K_messages:       .asciz "messages"
.K_stream:         .asciz "stream"
.K_stream_options: .asciz "stream_options"
.K_include_usage:  .asciz "include_usage"
.K_max_tokens:     .asciz "max_completion_tokens"
.K_max_tokens_ollama: .asciz "max_tokens"
.Lprov_ollama:      .asciz "ollama"
.Lprov_cloud:       .asciz "ollama-cloud"
.K_tools:          .asciz "tools"
.K_role:           .asciz "role"
.K_content:        .asciz "content"
.K_name:           .asciz "name"
.K_description:    .asciz "description"
.K_parameters:     .asciz "parameters"
.K_type:           .asciz "type"
.K_function:       .asciz "function"
.K_tool_calls:     .asciz "tool_calls"
.K_id:             .asciz "id"
.K_arguments:      .asciz "arguments"
.K_tool_call_id:   .asciz "tool_call_id"
.K_index:          .asciz "index"
.K_delta:          .asciz "delta"
.K_finish_reason:  .asciz "finish_reason"
.K_choices:        .asciz "choices"
.K_usage:          .asciz "usage"
.K_prompt_tokens:  .asciz "prompt_tokens"
.K_completion_tokens: .asciz "completion_tokens"
.K_details:        .asciz "prompt_tokens_details"
.K_cached_tokens:  .asciz "cached_tokens"
.K_cache_hit:      .asciz "prompt_cache_hit_tokens"
.K_cache_write:    .asciz "cache_write_tokens"
.K_reasoning_content: .asciz "reasoning_content"
.K_reasoning:      .asciz "reasoning"
.K_reasoning_text: .asciz "reasoning_text"

.V_system:    .asciz "system"
.V_user:      .asciz "user"
.V_assistant: .asciz "assistant"
.V_tool:      .asciz "tool"
.V_function:  .asciz "function"

# finish reasons
.Fr_stop:      .asciz "stop"
.Fr_end:       .asciz "end"
.Fr_length:    .asciz "length"
.Fr_tools:     .asciz "tool_calls"
.Fr_function:  .asciz "function_call"
.Fr_content_filter: .asciz "content_filter"

# SSE sentinel
.Ldone_marker: .ascii "[DONE]"

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
# .Loai_join(Msg*, SB*, sep ptr, sep len) -> rax ptr, rdx len in SB.
# Concatenates BT_TEXT blocks with the separator between them.
.Loai_join:
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
    jz .Loj_done
    mov r13, [rax + VEC_ptr]
    mov r14, [rax + VEC_len]
    xor r15d, r15d
.Loj_loop:
    cmp r15, r14
    jae .Loj_done
    lea rax, [r15 + r15*2]
    lea rax, [r13 + rax*8]
    cmp dword ptr [rax + B_type], BT_TEXT
    jne .Loj_next
    mov [rsp + 24], rax
    cmp qword ptr [rsp + 16], 0
    je .Loj_nosep
    mov rdi, r12
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    call sb_push
.Loj_nosep:
    mov rax, [rsp + 24]
    mov rdi, r12
    mov rsi, [rax + B_ptr]
    mov rdx, [rax + B_len]
    call sb_push
    mov qword ptr [rsp + 16], 1
.Loj_next:
    inc r15
    jmp .Loj_loop
.Loj_done:
    mov rax, [r12 + SB_ptr]
    mov rdx, [r12 + SB_len]
    test rax, rax
    jnz .Loj_ret
    lea rax, [rip + .Lempty]
    xor edx, edx
.Loj_ret:
    EPILOGUE

# .Loai_stop_map(cstr) -> eax SR_*
.Loai_stop_map:
    PROLOGUE 0
    mov rbx, rdi
    mov rdi, rbx
    mov esi, 4
    lea rdx, [rip + .Fr_stop]
    call str_eq_cstr
    test eax, eax
    jnz .Lom_stop
    mov rdi, rbx
    mov esi, 3
    lea rdx, [rip + .Fr_end]
    call str_eq_cstr
    test eax, eax
    jnz .Lom_stop
    mov rdi, rbx
    mov esi, 6
    lea rdx, [rip + .Fr_length]
    call str_eq_cstr
    test eax, eax
    jnz .Lom_length
    mov rdi, rbx
    mov esi, 10
    lea rdx, [rip + .Fr_tools]
    call str_eq_cstr
    test eax, eax
    jnz .Lom_tool
    mov rdi, rbx
    mov esi, 13
    lea rdx, [rip + .Fr_function]
    call str_eq_cstr
    test eax, eax
    jnz .Lom_tool
    mov rdi, rbx
    mov esi, 14
    lea rdx, [rip + .Fr_content_filter]
    call str_eq_cstr
    test eax, eax
    jnz .Lom_error
    # Unknown/absent finish_reason -> SR_STOP (shared policy across adapters;
    # anthropic maps its unknowns to SR_STOP too). content_filter is an error.
    mov eax, SR_STOP
    EPILOGUE
.Lom_error:
    mov eax, SR_ERROR
    EPILOGUE
.Lom_stop:
    mov eax, SR_STOP
    EPILOGUE
.Lom_length:
    mov eax, SR_LENGTH
    EPILOGUE
.Lom_tool:
    mov eax, SR_TOOL_USE
    EPILOGUE

# .Loai_close_tools(ctx, SS*): emit each started tool call as a contiguous
# START / DELTA / END group. Streaming the groups here (rather than in arrival
# order) lets the agent keep a single pending slot even when OpenAI interleaves
# indices, and guarantees every started call is closed exactly once.
.Loai_close_tools:
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    xor r13d, r13d
.Lct_loop:
    cmp r13d, 16
    jae .Lct_ret
    cmp dword ptr [rbx + O_CTX_ST + r13*4], OS_STARTED
    jne .Lct_next
    mov dword ptr [rbx + O_CTX_ST + r13*4], OS_ENDED
    inc dword ptr [rbx + O_CTX_NEND]
    mov rcx, r13
    imul rcx, rcx, 48
    lea r14, [rbx + O_CTX_NAME]
    add r14, rcx
    lea rdx, [rbx + O_CTX_ID]
    add rdx, rcx
    mov rdi, r12
    mov esi, SE_TOOL_START
    mov rcx, r14
    call .Lsink_emit
    mov rcx, r13
    imul rcx, rcx, SB_SIZE
    lea r14, [rbx + O_CTX_ABUF]
    add r14, rcx
    mov rdx, [r14 + SB_ptr]
    test rdx, rdx
    jz .Lct_end
    mov rcx, [r14 + SB_len]
    test rcx, rcx
    jz .Lct_end
    mov rdi, r12
    mov esi, SE_TOOL_DELTA
    call .Lsink_emit
.Lct_end:
    mov rdi, r12
    mov esi, SE_TOOL_END
    xor edx, edx
    xor ecx, ecx
    call .Lsink_emit
    mov rdi, r14
    call sb_clear
.Lct_next:
    inc r13d
    jmp .Lct_loop
.Lct_ret:
    mov dword ptr [rbx + O_CTX_OPEN], -1
    EPILOGUE

# .Lcopy48(dst, src): bounded cstring copy (47 bytes + NUL)
.Lcopy48:
    xor ecx, ecx
1:  cmp ecx, 47
    jae 2f
    mov al, [rsi + rcx]
    test al, al
    jz 2f
    mov [rdi + rcx], al
    inc ecx
    jmp 1b
2:  mov byte ptr [rdi + rcx], 0
    ret

# .Loai_flush_text(ctx, SS*): finish an open text/thinking block.
.Loai_flush_text:
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    mov eax, [rbx + O_CTX_FLAGS]
    test eax, OF_TEXT
    jz .Lft_think
    and dword ptr [rbx + O_CTX_FLAGS], ~OF_TEXT
    mov rdi, r12
    mov esi, SE_TEXT_END
    xor edx, edx
    xor ecx, ecx
    call .Lsink_emit
.Lft_think:
    mov eax, [rbx + O_CTX_FLAGS]
    test eax, OF_THINK
    jz .Lft_ret
    and dword ptr [rbx + O_CTX_FLAGS], ~OF_THINK
    mov rdi, r12
    mov esi, SE_THINK_END
    xor edx, edx
    xor ecx, ecx
    call .Lsink_emit
.Lft_ret:
    EPILOGUE

# .Loai_usage(usage JV*, SS*): parse one usage chunk and emit SE_USAGE.
.Loai_usage:
    PROLOGUE 64
    mov rbx, rdi
    mov r12, rsi
    # prompt_tokens / completion_tokens
    mov rdi, rbx
    lea rsi, [rip + .K_prompt_tokens]
    xor edx, edx
    call json_get_u64
    mov [rsp], rax
    mov rdi, rbx
    lea rsi, [rip + .K_completion_tokens]
    xor edx, edx
    call json_get_u64
    mov [rsp + 8], rax
    # cached_tokens: prompt_tokens_details.cached_tokens, then
    # prompt_cache_hit_tokens, then top-level cached_tokens
    mov qword ptr [rsp + 16], 0
    mov qword ptr [rsp + 24], 0
    mov rdi, rbx
    lea rsi, [rip + .K_details]
    call json_get
    mov r13, rax
    test r13, r13
    jz .Lus_hit
    mov rdi, r13
    lea rsi, [rip + .K_cached_tokens]
    call json_get
    test rax, rax
    jz .Lus_hit
    mov rdi, r13
    lea rsi, [rip + .K_cached_tokens]
    xor edx, edx
    call json_get_u64
    mov [rsp + 16], rax
    jmp .Lus_write
.Lus_hit:
    mov rdi, rbx
    lea rsi, [rip + .K_cache_hit]
    call json_get
    test rax, rax
    jz .Lus_top
    mov rdi, rbx
    lea rsi, [rip + .K_cache_hit]
    xor edx, edx
    call json_get_u64
    mov [rsp + 16], rax
    jmp .Lus_write
.Lus_top:
    mov rdi, rbx
    lea rsi, [rip + .K_cached_tokens]
    call json_get
    test rax, rax
    jz .Lus_write
    mov rdi, rbx
    lea rsi, [rip + .K_cached_tokens]
    xor edx, edx
    call json_get_u64
    mov [rsp + 16], rax
.Lus_write:
    test r13, r13
    jz .Lus_sum
    mov rdi, r13
    lea rsi, [rip + .K_cache_write]
    call json_get
    test rax, rax
    jz .Lus_sum
    mov rdi, r13
    lea rsi, [rip + .K_cache_write]
    xor edx, edx
    call json_get_u64
    mov [rsp + 24], rax
.Lus_sum:
    # input = max(0, prompt - cache_read - cache_write)
    mov rax, [rsp]
    mov rcx, [rsp + 16]
    add rcx, [rsp + 24]
    xor edx, edx
    cmp rax, rcx
    jae .Lus_sub
    xor eax, eax
    jmp .Lus_have
.Lus_sub:
    sub rax, rcx
.Lus_have:
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

# ---------------------------------------------------------------- build helpers
# .Loai_user(ctx, sb, Msg*): {"role":"user","content":"<joined>"}
.Loai_user:
    PROLOGUE 0
    mov r12, rdi
    mov rbx, rsi
    mov r13, rdx
    test r13, r13
    jz .Lou_ret
    mov rdi, r13
    lea rsi, [r12 + O_CTX_SCRATCH]
    lea rdx, [rip + .Lempty]
    xor ecx, ecx
    call .Loai_join
    test rdx, rdx
    jz .Lou_ret
    mov r14, rax
    mov r15, rdx
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
    mov rsi, r14
    mov rdx, r15
    call jsonw_str
    mov rdi, rbx
    call jsonw_obj_end
.Lou_ret:
    EPILOGUE

# .Loai_toolresult(ctx, sb, Msg*): one {"role":"tool",...} message.
.Loai_toolresult:
    PROLOGUE 0
    mov r12, rdi
    mov rbx, rsi
    mov r13, rdx
    test r13, r13
    jz .Ltr_ret
    mov rdi, r13
    lea rsi, [r12 + O_CTX_SCRATCH]
    lea rdx, [rip + .Lnewline]
    mov ecx, 1
    call .Loai_join
    mov r14, rax
    mov r15, rdx
    mov rdi, rbx
    call jsonw_obj
    mov rdi, rbx
    lea rsi, [rip + .K_role]
    call jsonw_key
    mov rdi, rbx
    lea rsi, [rip + .V_tool]
    call jsonw_str_cstr
    mov rdi, rbx
    lea rsi, [rip + .K_tool_call_id]
    call jsonw_key
    mov rsi, [r13 + M_call_id]
    test rsi, rsi
    jnz .Ltr_id
    lea rsi, [rip + .Lempty]
.Ltr_id:
    mov rdi, rbx
    call jsonw_str_cstr
    mov rdi, rbx
    lea rsi, [rip + .K_content]
    call jsonw_key
    mov rdi, rbx
    mov rsi, r14
    mov rdx, r15
    call jsonw_str
    mov rdi, rbx
    call jsonw_obj_end
.Ltr_ret:
    EPILOGUE

# .Loai_assistant(ctx, sb, Msg*): string content + tool_calls[].
.Loai_assistant:
    PROLOGUE 32
    mov r12, rdi
    mov rbx, rsi
    mov r13, rdx
    test r13, r13
    jz .Loa_ret
    mov rdi, r13
    lea rsi, [r12 + O_CTX_SCRATCH]
    lea rdx, [rip + .Lempty]
    xor ecx, ecx
    call .Loai_join
    mov r14, rax                    # text ptr
    mov r15, rdx                    # text len
    # count tool calls
    mov qword ptr [rsp], 0
    mov rax, [r13 + M_blocks]
    test rax, rax
    jz .Loa_counted
    mov r10, [rax + VEC_ptr]
    mov r11, [rax + VEC_len]
    xor r9d, r9d
.Loa_count:
    cmp r9, r11
    jae .Loa_counted
    lea rax, [r9 + r9*2]
    cmp dword ptr [r10 + rax*8 + B_type], BT_TOOLCALL
    jne .Loa_count_next
    inc qword ptr [rsp]
.Loa_count_next:
    inc r9
    jmp .Loa_count
.Loa_counted:
    test r15, r15
    jnz .Loa_emit
    cmp qword ptr [rsp], 0
    je .Loa_ret
.Loa_emit:
    mov rdi, rbx
    call jsonw_obj
    mov rdi, rbx
    lea rsi, [rip + .K_role]
    call jsonw_key
    mov rdi, rbx
    lea rsi, [rip + .V_assistant]
    call jsonw_str_cstr
    test r15, r15
    jz .Loa_tools
    mov rdi, rbx
    lea rsi, [rip + .K_content]
    call jsonw_key
    mov rdi, rbx
    mov rsi, r14
    mov rdx, r15
    call jsonw_str
.Loa_tools:
    cmp qword ptr [rsp], 0
    je .Loa_close
    mov rdi, rbx
    lea rsi, [rip + .K_tool_calls]
    call jsonw_key
    mov rdi, rbx
    call jsonw_arr
    xor r15d, r15d
.Loa_tc_loop:
    mov rax, [r13 + M_blocks]
    test rax, rax
    jz .Loa_tools_end
    mov r10, [rax + VEC_len]
    cmp r15, r10
    jae .Loa_tools_end
    mov r10, [rax + VEC_ptr]
    lea rax, [r15 + r15*2]
    lea rax, [r10 + rax*8]
    cmp dword ptr [rax + B_type], BT_TOOLCALL
    jne .Loa_tc_next
    mov r14, [rax + B_ptr]          # TC*
    mov rdi, rbx
    call jsonw_obj
    mov rdi, rbx
    lea rsi, [rip + .K_id]
    call jsonw_key
    mov rdi, rbx
    mov rsi, [r14 + TC_id]
    call jsonw_str_cstr
    mov rdi, rbx
    lea rsi, [rip + .K_type]
    call jsonw_key
    mov rdi, rbx
    lea rsi, [rip + .V_function]
    call jsonw_str_cstr
    mov rdi, rbx
    lea rsi, [rip + .K_function]
    call jsonw_key
    mov rdi, rbx
    call jsonw_obj
    mov rdi, rbx
    lea rsi, [rip + .K_name]
    call jsonw_key
    mov rdi, rbx
    mov rsi, [r14 + TC_name]
    call jsonw_str_cstr
    mov rdi, rbx
    lea rsi, [rip + .K_arguments]
    call jsonw_key
    mov rdi, rbx
    mov rsi, [r14 + TC_args]
    call jsonw_str_cstr
    mov rdi, rbx
    call jsonw_obj_end
    mov rdi, rbx
    call jsonw_obj_end
.Loa_tc_next:
    inc r15
    jmp .Loa_tc_loop
.Loa_tools_end:
    mov rdi, rbx
    call jsonw_arr_end
.Loa_close:
    mov rdi, rbx
    call jsonw_obj_end
.Loa_ret:
    EPILOGUE

# .Loai_max_key(ctx) -> cstr: the output-cap field name for this provider.
# Ollama's OpenAI compatibility layer maps max_tokens -> num_predict and
# ignores max_completion_tokens (docs.ollama.com/api/openai-compatibility),
# so the name is provider-gated (ADR-4).
.Loai_max_key:
    PROLOGUE 0
    mov rdi, [rdi + O_CTX_MD]
    test rdi, rdi
    jz .Lomk_default
    mov rdi, [rdi + MD_provider]
    test rdi, rdi
    jz .Lomk_default
    mov r12, rdi
    lea rsi, [rip + .Lprov_ollama]
    call .Loai_cstr_eq
    test eax, eax
    jnz .Lomk_ollama
    mov rdi, r12
    lea rsi, [rip + .Lprov_cloud]
    call .Loai_cstr_eq
    test eax, eax
    jnz .Lomk_ollama
.Lomk_default:
    lea rax, [rip + .K_max_tokens]
    EPILOGUE
.Lomk_ollama:
    lea rax, [rip + .K_max_tokens_ollama]
    EPILOGUE

# .Loai_cstr_eq(a, b) -> 1 | 0 (leaf)
.Loai_cstr_eq:
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

# ---------------------------------------------------------------- vtable members
# .Lprov_new(MD*) -> ctx
.Lprov_new:
    PROLOGUE 0
    mov r12, rdi
    mov edi, O_CTX_SIZE
    call mem_alloc
    mov rbx, rax
    mov [rbx + O_CTX_MD], r12
    mov eax, 4096
    test r12, r12
    jz .Lon_store
    mov ecx, [r12 + MD_max_tokens]
    test ecx, ecx
    jz .Lon_store
    mov eax, ecx
.Lon_store:
    mov [rbx + O_CTX_MAX], eax
    mov rax, rbx
    EPILOGUE

# .Lprov_path(ctx) -> "/chat/completions"
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
    mov dword ptr [r12 + O_CTX_DONE], 0
    mov dword ptr [r12 + O_CTX_STOP], 0
    mov dword ptr [r12 + O_CTX_NTOOLS], 0
    mov dword ptr [r12 + O_CTX_NEND], 0
    mov dword ptr [r12 + O_CTX_FLAGS], 0
    mov dword ptr [r12 + O_CTX_OPEN], -1
    mov qword ptr [r12 + O_CTX_ST], 0
    mov qword ptr [r12 + O_CTX_ST + 8], 0
    mov qword ptr [r12 + O_CTX_ST + 16], 0
    mov qword ptr [r12 + O_CTX_ST + 24], 0
    mov qword ptr [r12 + O_CTX_ST + 32], 0
    mov qword ptr [r12 + O_CTX_ST + 40], 0
    mov qword ptr [r12 + O_CTX_ST + 48], 0
    mov qword ptr [r12 + O_CTX_ST + 56], 0
    # clear the per-index argument buffers from any previous (interrupted) turn
    xor r10d, r10d
.Lob_abuf_clear:
    cmp r10d, 16
    jae .Lob_abuf_done
    mov rcx, r10
    imul rcx, rcx, SB_SIZE
    lea rdi, [r12 + O_CTX_ABUF]
    add rdi, rcx
    call sb_clear
    inc r10d
    jmp .Lob_abuf_clear
.Lob_abuf_done:

    mov rdi, rbx
    call jsonw_obj

    # model
    mov rdi, rbx
    lea rsi, [rip + .K_model]
    call jsonw_key
    mov rsi, [r12 + O_CTX_MD]
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

    # messages
    mov rdi, rbx
    lea rsi, [rip + .K_messages]
    call jsonw_key
    mov rdi, rbx
    call jsonw_arr
    test r13, r13
    jz .Lob_no_sys
    mov rdi, rbx
    call jsonw_obj
    mov rdi, rbx
    lea rsi, [rip + .K_role]
    call jsonw_key
    mov rdi, rbx
    lea rsi, [rip + .V_system]
    call jsonw_str_cstr
    mov rdi, rbx
    lea rsi, [rip + .K_content]
    call jsonw_key
    mov rdi, rbx
    mov rsi, r13
    call jsonw_str_cstr
    mov rdi, rbx
    call jsonw_obj_end
.Lob_no_sys:
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
    call .Loai_user
    jmp .Lob_msg_next
.Lob_msg_asst:
    cmp eax, MR_ASSISTANT
    jne .Lob_msg_tool
    mov rdi, r12
    mov rsi, rbx
    mov rdx, r13
    call .Loai_assistant
    jmp .Lob_msg_next
.Lob_msg_tool:
    cmp eax, MR_TOOL_RESULT
    jne .Lob_msg_next
    mov rdi, r12
    mov rsi, rbx
    mov rdx, r13
    call .Loai_toolresult
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

    # stream_options: {"include_usage":true}
    mov rdi, rbx
    lea rsi, [rip + .K_stream_options]
    call jsonw_key
    mov rdi, rbx
    call jsonw_obj
    mov rdi, rbx
    lea rsi, [rip + .K_include_usage]
    call jsonw_key
    mov rdi, rbx
    mov esi, 1
    call jsonw_bool
    mov rdi, rbx
    call jsonw_obj_end

    # max_completion_tokens / max_tokens (provider-gated; only when > 0)
    mov eax, [r12 + O_CTX_MAX]
    test eax, eax
    jz .Lob_no_max
    mov rdi, r12
    call .Loai_max_key
    mov rdi, rbx
    mov rsi, rax
    call jsonw_key
    mov rdi, rbx
    mov esi, [r12 + O_CTX_MAX]
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
    mov r12, [rax + r15*8]          # TL*
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
    lea rsi, [rip + .K_function]
    call jsonw_key
    mov rdi, rbx
    call jsonw_obj
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
    mov rdi, rbx
    call jsonw_obj_end
    mov rdi, rbx
    call jsonw_obj_end
.Lob_tool_next:
    inc r15
    jmp .Lob_tool_loop
.Lob_tools_end:
    mov rdi, rbx
    call jsonw_arr_end
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
    # [DONE] sentinel (accept trailing whitespace)
    mov rdi, r8
    mov rsi, r9
    lea rdx, [rip + .Ldone_marker]
    mov ecx, 6
    call str_starts
    test eax, eax
    jnz .Los_done
.Los_parse:
    mov rdi, r8
    mov rsi, r9
    call json_parse
    test rax, rax
    jz .Los_ret
    mov rbx, rax

    # usage chunk (may arrive with an empty choices array)
    mov rdi, rbx
    lea rsi, [rip + .K_usage]
    call json_get
    test rax, rax
    jz .Los_choices
    mov rdi, rax
    mov rsi, r13
    call .Loai_usage
.Los_choices:
    mov rdi, rbx
    lea rsi, [rip + .K_choices]
    call json_get
    test rax, rax
    jz .Los_ret
    mov rdi, rax
    xor esi, esi
    call json_at
    test rax, rax
    jz .Los_ret
    mov r14, rax

    # finish_reason
    mov rdi, r14
    lea rsi, [rip + .K_finish_reason]
    call json_get_cstr
    test rax, rax
    jz .Los_no_finish
    mov rdi, rax
    call .Loai_stop_map
    mov [r12 + O_CTX_STOP], eax
    mov rdi, r12
    mov rsi, r13
    call .Loai_flush_text
    mov rdi, r12
    mov rsi, r13
    call .Loai_close_tools
.Los_no_finish:

    # delta
    mov rdi, r14
    lea rsi, [rip + .K_delta]
    call json_get
    test rax, rax
    jz .Los_ret
    mov r14, rax

    # content
    mov rdi, r14
    lea rsi, [rip + .K_content]
    call json_get
    test rax, rax
    jz .Los_no_content
    mov rdi, rax
    call json_str
    test rax, rax
    jz .Los_no_content
    test rdx, rdx
    jz .Los_no_content
    mov rcx, rdx
    mov rdx, rax
    mov rdi, r13
    mov esi, SE_TEXT
    call .Lsink_emit
    or dword ptr [r12 + O_CTX_FLAGS], OF_TEXT
.Los_no_content:

    # reasoning_content | reasoning (| reasoning_text)
    mov rdi, r14
    lea rsi, [rip + .K_reasoning_content]
    call json_get
    test rax, rax
    jnz .Los_reason
    mov rdi, r14
    lea rsi, [rip + .K_reasoning]
    call json_get
    test rax, rax
    jnz .Los_reason
    mov rdi, r14
    lea rsi, [rip + .K_reasoning_text]
    call json_get
    test rax, rax
    jz .Los_no_think
.Los_reason:
    mov rdi, rax
    call json_str
    test rax, rax
    jz .Los_no_think
    test rdx, rdx
    jz .Los_no_think
    mov rcx, rdx
    mov rdx, rax
    mov rdi, r13
    mov esi, SE_THINK
    call .Lsink_emit
    or dword ptr [r12 + O_CTX_FLAGS], OF_THINK
.Los_no_think:

    # tool_calls[]
    mov rdi, r14
    lea rsi, [rip + .K_tool_calls]
    call json_get
    test rax, rax
    jz .Los_ret
    mov r14, rax
    xor r15d, r15d
.Los_tc_loop:
    mov rdi, r14
    call json_len
    cmp r15, rax
    jae .Los_ret
    mov rdi, r14
    mov esi, r15d
    call json_at
    mov [rsp], rax
    mov rdi, rax
    lea rsi, [rip + .K_index]
    mov rdx, r15
    call json_get_u64
    cmp rax, 16
    jae .Los_tc_next
    mov [rsp + 8], rax
    mov rcx, rax
    cmp dword ptr [r12 + O_CTX_ST + rcx*4], OS_UNSEEN
    jne .Los_tc_args
    # First sight of this index: record id + name and mark it started. The
    # events are emitted later by .Loai_close_tools so one call's
    # start/deltas/end stay contiguous (the agent keeps a single pending
    # slot, and OpenAI may interleave indices).
    mov dword ptr [r12 + O_CTX_ST + rcx*4], OS_STARTED
    inc dword ptr [r12 + O_CTX_NTOOLS]
    mov rdi, [rsp]
    lea rsi, [rip + .K_id]
    call json_get_cstr
    test rax, rax
    jnz .Los_id_ok
    mov dword ptr [rsp + 24], 0x6c6c6163   # "call"
    mov byte ptr [rsp + 28], '_'
    lea rdi, [rsp + 29]
    mov rsi, [rsp + 8]
    call fmt_u64
    mov byte ptr [rsp + 29 + rax], 0
    lea rax, [rsp + 24]
.Los_id_ok:
    mov rsi, rax
    mov rcx, [rsp + 8]
    imul rcx, rcx, 48
    lea rdi, [r12 + O_CTX_ID]
    add rdi, rcx
    call .Lcopy48
    mov rdi, [rsp]
    lea rsi, [rip + .K_function]
    call json_get
    test rax, rax
    jz .Los_no_name
    mov rdi, rax
    lea rsi, [rip + .K_name]
    call json_get_cstr
    test rax, rax
    jnz .Los_name_ok
.Los_no_name:
    lea rax, [rip + .Lempty]
.Los_name_ok:
    mov rsi, rax
    mov rcx, [rsp + 8]
    imul rcx, rcx, 48
    lea rdi, [r12 + O_CTX_NAME]
    add rdi, rcx
    call .Lcopy48
.Los_tc_args:
    # a fragment for a finalized call must not leak into another index's slot
    mov rcx, [rsp + 8]
    cmp dword ptr [r12 + O_CTX_ST + rcx*4], OS_ENDED
    je .Los_tc_next
    mov rdi, [rsp]
    lea rsi, [rip + .K_function]
    call json_get
    test rax, rax
    jz .Los_tc_next
    mov rdi, rax
    lea rsi, [rip + .K_arguments]
    call json_get
    test rax, rax
    jz .Los_tc_next
    mov rdi, rax
    call json_str
    test rax, rax
    jz .Los_tc_next
    test rdx, rdx
    jz .Los_tc_next
    mov rsi, rax
    mov rcx, [rsp + 8]
    imul rcx, rcx, SB_SIZE
    lea rdi, [r12 + O_CTX_ABUF]
    add rdi, rcx
    call sb_push
.Los_tc_next:
    inc r15
    jmp .Los_tc_loop

.Los_done:
    cmp dword ptr [r12 + O_CTX_DONE], 0
    jne .Los_ret
    mov dword ptr [r12 + O_CTX_DONE], 1
    mov rdi, r12
    mov rsi, r13
    call .Loai_flush_text
    mov rdi, r12
    mov rsi, r13
    call .Loai_close_tools
    mov eax, [r12 + O_CTX_STOP]
    test eax, eax
    jnz .Los_done_reason
    cmp dword ptr [r12 + O_CTX_NTOOLS], 0
    je .Los_done_stop
    mov eax, SR_TOOL_USE
    jmp .Los_done_reason
.Los_done_stop:
    mov eax, SR_STOP
.Los_done_reason:
    mov rdi, r13
    mov esi, SE_DONE
    mov edx, eax
    xor ecx, ecx
    call .Lsink_emit
.Los_ret:
    xor eax, eax
    EPILOGUE

# .Lprov_finish(ctx, SS*) -> 0
.Lprov_finish:
    PROLOGUE 0
    mov r12, rdi
    mov r13, rsi
    cmp dword ptr [r12 + O_CTX_DONE], 0
    jne .Lof_ret
    mov dword ptr [r12 + O_CTX_DONE], 1
    mov eax, [r12 + O_CTX_STOP]
    test eax, eax
    jz .Lof_trunc
    # finish_reason captured before the transport ended: finalize any open
    # blocks and report the real reason instead of a spurious error.
    mov rdi, r12
    mov rsi, r13
    call .Loai_flush_text
    mov rdi, r12
    mov rsi, r13
    call .Loai_close_tools
    mov eax, [r12 + O_CTX_STOP]
    mov rdi, r13
    mov esi, SE_DONE
    mov edx, eax
    xor ecx, ecx
    call .Lsink_emit
    jmp .Lof_ret
.Lof_trunc:
    mov rdi, r13
    mov esi, SE_ERROR
    lea rdx, [rip + .Ltruncated]
    xor ecx, ecx
    call .Lsink_emit
.Lof_ret:
    xor eax, eax
    EPILOGUE

# .Lprov_free(ctx): release the embedded build scratch SB, then the context.
.Lprov_free:
    PROLOGUE 0
    mov rbx, rdi
    lea rdi, [rbx + O_CTX_SCRATCH]
    call sb_free
    xor r12d, r12d
1:  cmp r12d, 16
    jae 2f
    mov rcx, r12
    imul rcx, rcx, SB_SIZE
    lea rdi, [rbx + O_CTX_ABUF]
    add rdi, rcx
    call sb_free
    inc r12d
    jmp 1b
2:  mov rdi, rbx
    call mem_free
    EPILOGUE

.section .rodata
.Lempty_obj: .asciz "{}"

.section .data
.p2align 3
.globl prov_openai
GTYPE prov_openai, @object
prov_openai:
    .quad .Lprov_new
    .quad .Lprov_build
    .quad .Lprov_path
    .quad .Lprov_sse
    .quad .Lprov_finish
    .quad .Lprov_free
GSIZE prov_openai, PV_SIZE
