.include "opcode.inc"
.include "core/core.inc"
# compact.s: context compaction primitives (M5).
#
# Public API (contract: src/core/API.md, .agents/docs/core-agent.md §9.2):
#   g_compact_reserve               u64 token headroom, default 16384
#   compact_estimate(tr)         -> estimated tokens
#   compact_needed(tokens, md)   -> 1|0
#   compact_cut(tr, keep_tokens) -> first kept index (>= 1)
#   compact_prompt(sb, tr, cut)  -> 0
#   compact_apply(tr, cut, summary cstr) -> 0
#
# Driver (integrator adds this to agent_init after session_load and provider /
# model setup, before the first turn; compact.s only exposes the pieces):
#   if (a_md && compact_needed(compact_estimate(&a_tr), a_md)) {
#       cut = compact_cut(&a_tr, KEEP);          # KEEP e.g. 20000
#       compact_prompt(prompt_sb, &a_tr, cut);  # instructions + transcript dump
#       tmp = tr_init; m = msg_new(MR_USER);
#       msg_add_block(m, BT_TEXT, prompt_sb.ptr, prompt_sb.len); tr_push(tmp, m);
#       PV_build(a_pvctx, body_sb, "", &tmp);   # one blocking summary request
#                                               # (streamed wire, parsed)
#       send/collect like a normal turn but with a local sink that appends
#       SE_TEXT deltas to sum_sb and sets done=1 on SE_DONE/SE_ERROR; on done:
#           compact_apply(&a_tr, cut, sum_sb.ptr);
#       tr_free(tmp); sb_free(&prompt_sb); sb_free(&sum_sb);
#       session_append_custom(g_agent_session, "compaction",
#                             "{\"first_kept\":<cut>}");   # optional
#   }
#
# Ownership: compact_apply frees each removed message completely - its leaf
# allocations (Msg/TC/text/usage/call_id) are untracked from TR_owned and freed
# along with the Msg, its M_blocks VEC and the block item array - so repeated
# compaction does not retain dropped text.  When a session is active the new
# summary is also appended to it as a real MR_USER message (session_load honors
# the matching "compaction" custom entry and drops the covered prefix).

.equ COMPACT_DUMP_CAP, 100000
.equ COMPACT_TOOL_CAP, 200

.section .rodata
.Lcp_instr:
    .ascii "You are compressing an agent conversation so that its transcript can be replaced by a summary.\n"
    .ascii "Write a concise checkpoint with these sections: Goal, Constraints, Progress (files and paths read or changed), Decisions, Open Questions, Errors, Next Steps, Critical Context.\n"
    .ascii "Preserve exact file paths, commands, tool call ids, and unfinished work.\n"
    .ascii "Do not invent new tasks.\n"
    .asciz "Output only the summary, with no preamble. Conversation to summarize:\n"
.Lp_user:   .asciz "user: "
.Lp_asst:   .asciz "assistant: "
.Lp_tool:   .asciz "tool: "
.Lp_tc:     .asciz " [tool_call "
.Lcp_trunc: .asciz "[... earlier messages omitted ...]\n"
.Lca_open:  .asciz "<conversation_summary>\n"
.Lca_close: .asciz "\n</conversation_summary>"

.section .data
.p2align 3
.globl g_compact_reserve
GTYPE g_compact_reserve, @object
g_compact_reserve:
    .quad 16384
GSIZE g_compact_reserve, 8

.text

# ---------------------------------------------------------------- helpers
# .Lc_msg_chars(msg) -> text/toolcall-args characters (leaf)
.Lc_msg_chars:
    xor eax, eax
    test rdi, rdi
    jz .Lmc_ret
    mov rdi, [rdi + M_blocks]
    test rdi, rdi
    jz .Lmc_ret
    mov r8, [rdi + VEC_ptr]
    mov r9, [rdi + VEC_len]
    xor ecx, ecx
.Lmc_loop:
    cmp rcx, r9
    jae .Lmc_ret
    lea rdx, [rcx + rcx*2]
    lea rdx, [r8 + rdx*8]           # Block*
    mov esi, [rdx + B_type]
    cmp esi, BT_TEXT
    je .Lmc_text
    cmp esi, BT_THINK
    je .Lmc_text
    cmp esi, BT_TOOLCALL
    je .Lmc_tc
    jmp .Lmc_next
.Lmc_text:
    add rax, [rdx + B_len]
    jmp .Lmc_next
.Lmc_tc:
    mov rdx, [rdx + B_ptr]          # TC*
    test rdx, rdx
    jz .Lmc_next
    mov rsi, [rdx + TC_args]
    test rsi, rsi
    jz .Lmc_next
    xor r10d, r10d
.Lmc_tc_len:
    cmp byte ptr [rsi + r10], 0
    je .Lmc_tc_done
    inc r10
    jmp .Lmc_tc_len
.Lmc_tc_done:
    add rax, r10
.Lmc_next:
    inc rcx
    jmp .Lmc_loop
.Lmc_ret:
    ret

# .Lc_dump_text(msg rdi, sb rsi): append every BT_TEXT block body
.Lc_dump_text:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    test r12, r12
    jz .Ldt_ret
    mov rax, [r12 + M_blocks]
    test rax, rax
    jz .Ldt_ret
    mov r14, [rax + VEC_ptr]
    mov r15, [rax + VEC_len]
    xor ebx, ebx
.Ldt_loop:
    cmp rbx, r15
    jae .Ldt_ret
    lea rax, [rbx + rbx*2]
    lea rax, [r14 + rax*8]
    cmp dword ptr [rax + B_type], BT_TEXT
    jne .Ldt_next
    mov rdi, r13
    mov rsi, [rax + B_ptr]
    mov rdx, [rax + B_len]
    call sb_push
.Ldt_next:
    inc rbx
    jmp .Ldt_loop
.Ldt_ret:
    EPILOGUE

# .Lc_dump_tool_result(msg rdi, sb rsi): first BT_TEXT block, capped
.Lc_dump_tool_result:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    test r12, r12
    jz .Ldr_ret
    mov rax, [r12 + M_blocks]
    test rax, rax
    jz .Ldr_ret
    mov r14, [rax + VEC_ptr]
    mov r15, [rax + VEC_len]
    xor ebx, ebx
.Ldr_loop:
    cmp rbx, r15
    jae .Ldr_ret
    lea rax, [rbx + rbx*2]
    lea rax, [r14 + rax*8]
    cmp dword ptr [rax + B_type], BT_TEXT
    jne .Ldr_next
    mov rdx, [rax + B_len]
    cmp rdx, COMPACT_TOOL_CAP
    jbe .Ldr_push
    mov edx, COMPACT_TOOL_CAP
.Ldr_push:
    mov rdi, r13
    mov rsi, [rax + B_ptr]
    call sb_push
    jmp .Ldr_ret
.Ldr_next:
    inc rbx
    jmp .Ldr_loop
.Ldr_ret:
    EPILOGUE

# .Lc_dump_toolcall(tc rdi, sb rsi): " [tool_call <name> <args>]"
.Lc_dump_toolcall:
    PROLOGUE
    test rdi, rdi
    jz .Ltc_ret
    mov r12, rdi
    mov r13, rsi
    mov rdi, r13
    lea rsi, [rip + .Lp_tc]
    call sb_push_cstr
    mov rsi, [r12 + TC_name]
    test rsi, rsi
    jz .Ltc_args
    mov rdi, r13
    call sb_push_cstr
.Ltc_args:
    mov rdi, r13
    mov esi, 32
    call sb_push_byte
    mov rsi, [r12 + TC_args]
    test rsi, rsi
    jz .Ltc_close
    mov rdi, r13
    call sb_push_cstr
.Ltc_close:
    mov rdi, r13
    mov esi, 93
    call sb_push_byte
.Ltc_ret:
    EPILOGUE

# ---------------------------------------------------------------- API
# compact_estimate(tr) -> tokens
# Last assistant usage with total > 0 (if any) + chars/4 of the messages after
# it; otherwise chars/4 over the whole transcript's text and toolcall args.
FN compact_estimate
    PROLOGUE
    test rdi, rdi
    jz .Lce_zero
    mov r12, rdi
    call tr_len
    mov r13, rax                    # n
    mov r14, -1                     # last usage index
    xor r15d, r15d
.Lce_scan:
    cmp r15, r13
    jae .Lce_scan_done
    mov rdi, r12
    mov rsi, r15
    call tr_msg
    test rax, rax
    jz .Lce_scan_next
    cmp dword ptr [rax + M_role], MR_ASSISTANT
    jne .Lce_scan_next
    mov rdx, [rax + M_usage]
    test rdx, rdx
    jz .Lce_scan_next
    cmp dword ptr [rdx + USG_total], 0
    jbe .Lce_scan_next
    mov r14, r15
.Lce_scan_next:
    inc r15
    jmp .Lce_scan
.Lce_scan_done:
    cmp r14, -1
    je .Lce_all
    lea r15, [r14 + 1]
    xor ebx, ebx
.Lce_sum:
    cmp r15, r13
    jae .Lce_sum_done
    mov rdi, r12
    mov rsi, r15
    call tr_msg
    mov rdi, rax
    call .Lc_msg_chars
    add rbx, rax
    inc r15
    jmp .Lce_sum
.Lce_sum_done:
    mov rdi, r12
    mov rsi, r14
    call tr_msg
    mov rax, [rax + M_usage]
    mov eax, [rax + USG_total]
    mov rdx, rbx
    shr rdx, 2
    add rax, rdx
    EPILOGUE
.Lce_all:
    xor r15d, r15d
    xor ebx, ebx
.Lce_all_loop:
    cmp r15, r13
    jae .Lce_all_done
    mov rdi, r12
    mov rsi, r15
    call tr_msg
    mov rdi, rax
    call .Lc_msg_chars
    add rbx, rax
    inc r15
    jmp .Lce_all_loop
.Lce_all_done:
    mov rax, rbx
    shr rax, 2
    EPILOGUE
.Lce_zero:
    xor eax, eax
    EPILOGUE

# compact_needed(tokens rdi, md rsi) -> 1|0
# tokens > md->MD_ctx_window - *g_compact_reserve; MD_ctx_window <= 0 -> 0.
FN compact_needed
    test rsi, rsi
    jz .Lcn_zero
    mov eax, [rsi + MD_ctx_window]
    test eax, eax
    jle .Lcn_zero
    mov rcx, [rip + g_compact_reserve]
    sub rax, rcx                    # threshold, may go negative
    cmp rdi, rax
    jle .Lcn_zero
    mov eax, 1
    ret
.Lcn_zero:
    xor eax, eax
    ret

# compact_cut(tr rdi, keep_tokens rsi) -> first kept index (>= 1)
# Walk back accumulating per-message chars/4 until >= keep_tokens, then move
# the cut back off tool results and off an assistant whose tool calls would be
# separated from their results. The final message is never removed.
FN compact_cut
    PROLOGUE
    test rdi, rdi
    jz .Lcc_zero
    mov r12, rdi
    mov r13, rsi
    call tr_len
    mov r14, rax                    # n
    cmp r14, 1
    jbe .Lcc_small
    xor ebx, ebx
    lea r15, [r14 - 1]
.Lcc_loop:
    mov rdi, r12
    mov rsi, r15
    call tr_msg
    mov rdi, rax
    call .Lc_msg_chars
    shr rax, 2
    add rbx, rax
    cmp rbx, r13
    jae .Lcc_have
    dec r15
    cmp r15, 1
    jae .Lcc_loop
.Lcc_have:
    cmp r15, 1
    jae .Lcc_adj_loop
    mov r15, 1
.Lcc_adj_loop:
    lea rax, [r14 - 1]
    cmp r15, rax
    jbe .Lcc_adj_role
    mov r15, rax
.Lcc_adj_role:
    mov rdi, r12
    mov rsi, r15
    call tr_msg
    test rax, rax
    jz .Lcc_adj_done
    cmp dword ptr [rax + M_role], MR_TOOL_RESULT
    jne .Lcc_adj_prev
    dec r15
    cmp r15, 1
    jae .Lcc_adj_loop
    mov r15, 1
    jmp .Lcc_adj_done
.Lcc_adj_prev:
    cmp r15, 1
    jbe .Lcc_adj_done
    mov rdi, r12
    lea rsi, [r15 - 1]
    call tr_msg
    test rax, rax
    jz .Lcc_adj_done
    cmp dword ptr [rax + M_role], MR_ASSISTANT
    jne .Lcc_adj_done
    mov rdi, rax
    call msg_toolcalls
    test eax, eax
    jz .Lcc_adj_done
    dec r15
    jmp .Lcc_adj_loop
.Lcc_adj_done:
    mov rax, r15
    EPILOGUE
.Lcc_small:
    mov rax, r14
    EPILOGUE
.Lcc_zero:
    xor eax, eax
    EPILOGUE

# compact_prompt(sb rdi, tr rsi, cut rdx) -> 0
# Fixed summarization instructions followed by a compact dump of messages
# [0, cut): "user: <text>", "assistant: <text> [tool_call ...]", "tool: <first
# 200 chars>" lines, capped at ~100k chars keeping the most recent part.
FN compact_prompt
    PROLOGUE 32
    mov r12, rdi                    # sb
    mov r13, rsi                    # tr
    mov r14, rdx                    # cut
    test r12, r12
    jz .Lcp_ret
    mov rdi, r12
    lea rsi, [rip + .Lcp_instr]
    call sb_push_cstr
    test r13, r13
    jz .Lcp_ret
    test r14, r14
    jz .Lcp_ret
    mov rdi, r13
    call tr_len
    cmp r14, rax
    jbe .Lcp_clamped
    mov r14, rax
.Lcp_clamped:
    lea rdi, [rsp]
    mov qword ptr [rdi + SB_ptr], 0
    mov qword ptr [rdi + SB_len], 0
    mov qword ptr [rdi + SB_cap], 0
    mov qword ptr [rsp + 24], 0
    xor ebx, ebx
.Lcp_msg:
    cmp rbx, r14
    jae .Lcp_dump_done
    mov rdi, r13
    mov rsi, rbx
    call tr_msg
    test rax, rax
    jz .Lcp_msg_next
    mov r15, rax
    mov eax, [r15 + M_role]
    cmp eax, MR_USER
    je .Lcp_user
    cmp eax, MR_ASSISTANT
    je .Lcp_asst
    cmp eax, MR_TOOL_RESULT
    je .Lcp_tool
    jmp .Lcp_msg_next
.Lcp_user:
    lea rdi, [rsp]
    lea rsi, [rip + .Lp_user]
    call sb_push_cstr
    mov rdi, r15
    lea rsi, [rsp]
    call .Lc_dump_text
    lea rdi, [rsp]
    mov esi, 10
    call sb_push_byte
    jmp .Lcp_msg_next
.Lcp_asst:
    lea rdi, [rsp]
    lea rsi, [rip + .Lp_asst]
    call sb_push_cstr
    mov rdi, r15
    lea rsi, [rsp]
    call .Lc_dump_text
    mov rdi, r15
    call msg_toolcalls
    test eax, eax
    jz .Lcp_asst_nl
    mov qword ptr [rsp + 24], 0
.Lcp_asst_tc:
    mov rdi, r15
    mov esi, dword ptr [rsp + 24]
    call msg_toolcall
    test rax, rax
    jz .Lcp_asst_nl
    mov rdi, rax
    lea rsi, [rsp]
    call .Lc_dump_toolcall
    inc qword ptr [rsp + 24]
    jmp .Lcp_asst_tc
.Lcp_asst_nl:
    lea rdi, [rsp]
    mov esi, 10
    call sb_push_byte
    jmp .Lcp_msg_next
.Lcp_tool:
    lea rdi, [rsp]
    lea rsi, [rip + .Lp_tool]
    call sb_push_cstr
    mov rdi, r15
    lea rsi, [rsp]
    call .Lc_dump_tool_result
    lea rdi, [rsp]
    mov esi, 10
    call sb_push_byte
.Lcp_msg_next:
    inc rbx
    jmp .Lcp_msg
.Lcp_dump_done:
    mov rbx, [rsp + SB_len]
    cmp rbx, COMPACT_DUMP_CAP
    jbe .Lcp_push_all
    lea rdi, [rip + .Lcp_trunc]
    call strlen
    mov r15, rax
    mov eax, COMPACT_DUMP_CAP
    sub rax, r15                    # bytes available for the recent tail
    mov rcx, rbx
    sub rcx, rax
    jns .Lcp_tail_go
    xor ecx, ecx
.Lcp_tail_go:
    mov r14, [rsp + SB_ptr]
    add r14, rcx
    mov rbx, [rsp + SB_ptr]
    add rbx, [rsp + SB_len]
.Lcp_tail_emit:
    mov rdi, r12
    lea rsi, [rip + .Lcp_trunc]
    call sb_push_cstr
    mov rdi, r12
    mov rsi, r14
    mov rdx, rbx
    sub rdx, r14
    call sb_push
    jmp .Lcp_dump_free
.Lcp_push_all:
    mov rdi, r12
    mov rsi, [rsp + SB_ptr]
    mov rdx, rbx
    call sb_push
.Lcp_dump_free:
    lea rdi, [rsp]
    call sb_free
.Lcp_ret:
    xor eax, eax
    EPILOGUE

# .Lca_untrack_free(tr rdi, ptr rsi): drop ptr from tr->TR_owned and free it.
# Swap-removes from the owner VEC so tr_free cannot double-free; NULL is ignored.
.Lca_untrack_free:
    PROLOGUE
    test rsi, rsi
    jz .Luf_ret
    mov r12, rdi
    mov r13, rsi
    mov rax, [r12 + TR_owned]
    test rax, rax
    jz .Luf_free
    mov r8, [rax + VEC_ptr]
    mov r9, [rax + VEC_len]
    xor ecx, ecx
1:  cmp rcx, r9
    jae .Luf_free
    cmp qword ptr [r8 + rcx*8], r13
    je 2f
    inc rcx
    jmp 1b
2:  dec r9
    mov rdx, [r8 + r9*8]
    mov [r8 + rcx*8], rdx
    mov [rax + VEC_len], r9
.Luf_free:
    mov rdi, r13
    call mem_free
.Luf_ret:
    EPILOGUE

# .Lca_free_msg(tr rdi, msg rsi): free one removed message completely: every
# leaf (text, TC + its 3 strings, Usage, call_id) and the Msg struct are
# untracked from TR_owned and freed, and the M_blocks VEC container is freed.
# This keeps repeated compaction from retaining every dropped leaf until
# tr_free.
.Lca_free_msg:
    PROLOGUE 32
    mov r12, rdi
    mov r13, rsi
    test r13, r13
    jz .Lfm_ret
    mov r14, [r13 + M_blocks]
    test r14, r14
    jz .Lfm_usage
    mov r15, [r14 + VEC_ptr]
    mov qword ptr [rsp], 0          # block index
.Lfm_blk:
    mov rcx, [rsp]
    cmp rcx, [r14 + VEC_len]
    jae .Lfm_blkvec
    lea rax, [rcx + rcx*2]
    lea rax, [r15 + rax*8]
    mov edx, [rax + B_type]
    mov rsi, [rax + B_ptr]
    cmp edx, BT_TOOLCALL
    je .Lfm_tc
    cmp edx, BT_TEXT
    je .Lfm_text
    cmp edx, BT_THINK
    jne .Lfm_blknext
.Lfm_text:
    mov rdi, r12
    call .Lca_untrack_free
    jmp .Lfm_blknext
.Lfm_tc:
    mov [rsp + 8], rsi
    test rsi, rsi
    jz .Lfm_blknext
    mov rdi, r12
    mov rsi, [rsi + TC_id]
    call .Lca_untrack_free
    mov rax, [rsp + 8]
    mov rdi, r12
    mov rsi, [rax + TC_name]
    call .Lca_untrack_free
    mov rax, [rsp + 8]
    mov rdi, r12
    mov rsi, [rax + TC_args]
    call .Lca_untrack_free
    mov rdi, r12
    mov rsi, [rsp + 8]
    call .Lca_untrack_free
.Lfm_blknext:
    inc qword ptr [rsp]
    jmp .Lfm_blk
.Lfm_blkvec:
    mov rdi, r14
    call vec_free
    mov rdi, r14
    call mem_free
    mov qword ptr [r13 + M_blocks], 0
.Lfm_usage:
    mov rdi, r12
    mov rsi, [r13 + M_usage]
    call .Lca_untrack_free
    mov qword ptr [r13 + M_usage], 0
    mov rdi, r12
    mov rsi, [r13 + M_call_id]
    call .Lca_untrack_free
    mov qword ptr [r13 + M_call_id], 0
    mov rdi, r12
    mov rsi, r13
    call .Lca_untrack_free
.Lfm_ret:
    EPILOGUE

# compact_apply(tr rdi, cut rsi, summary rdx) -> 0
# Replace messages [0, cut) with one MR_USER message whose text is the summary
# wrapped in <conversation_summary>...</conversation_summary>.
FN compact_apply
    PROLOGUE 32
    test rdi, rdi
    jz .Lca_ret
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    cmp qword ptr [r12 + TR_msgs], 0
    je .Lca_ret
    cmp qword ptr [r12 + TR_owned], 0
    je .Lca_ret
    test r13, r13
    jle .Lca_ret
    call tr_len
    mov r15, rax                    # n
    test r15, r15
    jz .Lca_ret
    cmp r13, r15
    jbe .Lca_free
    mov r13, r15
.Lca_free:
    xor ebx, ebx
.Lca_free_loop:
    cmp rbx, r13
    jae .Lca_build
    mov rdi, r12
    mov rsi, rbx
    call tr_msg
    mov rdi, r12
    mov rsi, rax
    call .Lca_free_msg
    inc rbx
    jmp .Lca_free_loop
.Lca_build:
    mov edi, M_SIZE
    call mem_alloc
    mov rbx, rax                    # summary Msg*
    mov dword ptr [rbx + M_role], MR_USER
    mov dword ptr [rbx + M_stop], SR_PENDING
    mov edi, VEC_SIZE
    call mem_alloc
    mov [rbx + M_blocks], rax
    mov rdi, [r12 + TR_owned]
    mov esi, 8
    call vec_push
    mov [rax], rbx
    # wrapped text
    lea rdi, [rsp]
    mov qword ptr [rdi + SB_ptr], 0
    mov qword ptr [rdi + SB_len], 0
    mov qword ptr [rdi + SB_cap], 0
    lea rdi, [rsp]
    lea rsi, [rip + .Lca_open]
    call sb_push_cstr
    test r14, r14
    jz .Lca_no_sum
    lea rdi, [rsp]
    mov rsi, r14
    call sb_push_cstr
.Lca_no_sum:
    lea rdi, [rsp]
    lea rsi, [rip + .Lca_close]
    call sb_push_cstr
    mov rdi, [rsp + SB_ptr]
    mov rsi, [rsp + SB_len]
    call mem_dup
    mov r14, rax                    # owned text
    mov rdi, [r12 + TR_owned]
    mov esi, 8
    call vec_push
    mov [rax], r14
    mov rax, [rsp + SB_len]
    mov [rsp + 24], rax
    mov rdi, [rbx + M_blocks]
    mov esi, B_SIZE
    call vec_push
    mov dword ptr [rax + B_type], BT_TEXT
    mov [rax + B_ptr], r14
    mov rdx, [rsp + 24]
    mov [rax + B_len], rdx
    # Persist the summary as a real message so --continue/--resume loads the
    # compacted transcript instead of re-summarizing the covered prefix.
    # session_load drops that prefix when it reads the matching "compaction"
    # custom entry.  No active session (unit tests) -> no-op.
    mov rdi, [rip + g_agent_session]
    test rdi, rdi
    jz .Lca_no_persist
    mov rsi, rbx
    call session_append_msg
.Lca_no_persist:
    lea rdi, [rsp]
    call sb_free
    # rebuild TR_msgs: [summary, old cut..n-1]
    mov r8, [r12 + TR_msgs]
    mov r9, [r8 + VEC_ptr]
    mov r10, r15
    sub r10, r13
    inc r10                         # new length
    mov [r9], rbx
    mov rcx, 1
.Lca_shift:
    cmp rcx, r10
    jae .Lca_shift_done
    lea rax, [r13 - 1]
    add rax, rcx
    mov rdx, [r9 + rax*8]
    mov [r9 + rcx*8], rdx
    inc rcx
    jmp .Lca_shift
.Lca_shift_done:
    mov [r8 + VEC_len], r10
.Lca_ret:
    xor eax, eax
    EPILOGUE
