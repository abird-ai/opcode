.include "opcode.inc"
# opcode wire: incremental Server-Sent Events (SSE) parser.
#
#   sse_init(s, on_event, ctx)
#   sse_feed(s, ptr, len)
#   sse_reset(s)
#   sse_last_id(s) -> rax ptr, rdx len
#   sse_error(s) -> 0 | cstr
#
# on_event(ctx, event ptr, event len, data ptr, data len) is called on every
# blank line that follows at least one "data:" line. The event name defaults
# to "message", multiple data lines are joined with '\n', and the most recent
# "id:" value survives dispatches and sse_reset (last-event-id semantics).
#
# The caller provides a zeroed buffer of at least 432 bytes (SSE_SIZE); 1024
# bytes is a safe allocation. The struct embeds two mem_alloc-backed SBs (the
# joined event data and the current line) plus a 64-byte event-name buffer and
# a 256-byte last-id buffer.
#
# Lines end with LF, CRLF, or a lone CR and may be split at any byte boundary,
# including between CR and LF. Limits are 512 KiB per line and 1 MiB of data
# per event: the first overflow wins, is reported by sse_error, and discards
# the affected event up to the next blank line; parsing then continues and the
# error stays set until sse_reset/sse_init.

.equ SSE_LINE_MAX, 512 * 1024
.equ SSE_DATA_MAX, 1 << 20

# ------------------------------------------------------------------ struct
STRUCT
F SSE_on_event, 8      # on_event callback (0 = none)
F SSE_ctx, 8           # opaque callback context
F SSE_err, 8           # static error cstr, 0 = none
F SSE_id_len, 8        # last "id:" value length
F SSE_ev_len, 8        # current event-name length
F SSE_line_len, 8      # content bytes seen in the current line
F SSE_data, 24         # SB: joined event data
F SSE_line, 24         # SB: current line content
F SSE_data_lines, 4    # "data:" lines seen for the current event
F SSE_pending_cr, 4    # last byte was CR; swallow a following LF
F SSE_discard, 4       # discard lines until the next blank line
F SSE_pad, 4
F SSE_ev, 64           # current event name
F SSE_id, 256          # most recent "id:" value
ENDSTRUCT SSE_SIZE     # 432 bytes

.section .rodata
.Lmessage:  .ascii "message"
.Lnewline:  .ascii "\n"
.Lf_data:   .ascii "data"
.Lf_event:  .ascii "event"
CSTR .Lerr_data, "event data too large"
CSTR .Lerr_line, "line too long"

.text

# .Lreset_event(s): set the event name back to the "message" default.
# Leaf; clobbers rax, rcx, rsi, rdi.
.Lreset_event:
    mov rax, rdi
    lea rsi, [rip + .Lmessage]
    lea rdi, [rdi + SSE_ev]
    mov ecx, 7
    rep movsb
    mov byte ptr [rdi], 0
    mov dword ptr [rax + SSE_ev_len], 7
    ret

# .Ldispatch(s): if at least one data line arrived, invoke on_event and then
# clear the data buffer and the event name. The id is left untouched.
.Ldispatch:
    mov eax, [rdi + SSE_data_lines]
    test eax, eax
    jz .Ldispatch_ret
    PROLOGUE 0
    mov rbx, rdi
    mov rax, [rbx + SSE_on_event]
    test rax, rax
    jz .Ldispatch_reset
    mov rdi, [rbx + SSE_ctx]
    lea rsi, [rbx + SSE_ev]
    mov edx, [rbx + SSE_ev_len]
    test edx, edx
    jnz 1f
    lea rsi, [rip + .Lmessage]  # empty "event:" value -> default
    mov edx, 7
1:  mov rcx, [rbx + SSE_data + SB_ptr]
    mov r8, [rbx + SSE_data + SB_len]
    call rax
.Ldispatch_reset:
    mov rdi, rbx
    add rdi, SSE_data
    call sb_clear
    mov dword ptr [rbx + SSE_data_lines], 0
    mov rdi, rbx
    call .Lreset_event
    EPILOGUE
.Ldispatch_ret:
    ret

# .Lparse_line(s, line, len): handle one complete non-empty, non-comment line.
.Lparse_line:
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    xor r14d, r14d
.Lpl_scan:
    cmp r14, r13
    jae .Lpl_nocolon
    cmp byte ptr [r12 + r14], ':'
    je .Lpl_colon
    inc r14
    jmp .Lpl_scan
.Lpl_colon:
    lea r15, [r12 + r14 + 1]    # value pointer
    sub r13, r14
    dec r13                     # value length
    test r13, r13
    jz .Lpl_have
    cmp byte ptr [r15], ' '
    jne .Lpl_have
    inc r15                     # strip one leading space
    dec r13
    jmp .Lpl_have
.Lpl_nocolon:
    # Per the SSE spec a line with no colon is a field with an empty value;
    # keep the whole line as the name and an empty value (so a bare "data"
    # line is an empty data line rather than being dropped).
    lea r15, [r12 + r13]
    xor r13d, r13d
.Lpl_have:
    cmp r14, 4                  # "data"
    jne .Lpl_event
    mov rdi, r12
    lea rsi, [rip + .Lf_data]
    mov edx, 4
    call memeq
    test eax, eax
    jz .Lpl_event
    # data value: check the 1 MiB event total before appending
    mov eax, [rbx + SSE_data_lines]
    mov rcx, [rbx + SSE_data + SB_len]
    test eax, eax
    jz 2f
    inc rcx                     # '\n' separator
2:  add rcx, r13
    cmp rcx, SSE_DATA_MAX
    ja .Lpl_data_over
    test eax, eax
    jz 3f
    mov rdi, rbx
    add rdi, SSE_data
    lea rsi, [rip + .Lnewline]
    mov edx, 1
    call sb_push
3:  mov rdi, rbx
    add rdi, SSE_data
    mov rsi, r15
    mov rdx, r13
    call sb_push
    inc dword ptr [rbx + SSE_data_lines]
    jmp .Lpl_done
.Lpl_data_over:
    cmp qword ptr [rbx + SSE_err], 0
    jne 4f
    lea rax, [rip + .Lerr_data]
    mov [rbx + SSE_err], rax
4:  mov dword ptr [rbx + SSE_discard], 1
    mov rdi, rbx
    add rdi, SSE_data
    call sb_clear
    mov dword ptr [rbx + SSE_data_lines], 0
    jmp .Lpl_done
.Lpl_event:
    cmp r14, 5                  # "event"
    jne .Lpl_id
    mov rdi, r12
    lea rsi, [rip + .Lf_event]
    mov edx, 5
    call memeq
    test eax, eax
    jz .Lpl_id
    mov rcx, r13                # copy at most 64 bytes
    cmp rcx, 64
    jbe 5f
    mov ecx, 64
5:  lea rdi, [rbx + SSE_ev]
    mov rsi, r15
    mov rax, rcx
    rep movsb
    mov [rbx + SSE_ev_len], rax
    cmp rax, 64
    jae .Lpl_done
    mov byte ptr [rbx + SSE_ev + rax], 0
    jmp .Lpl_done
.Lpl_id:
    cmp r14, 2                  # "id"
    jne .Lpl_done
    cmp byte ptr [r12], 'i'
    jne .Lpl_done
    cmp byte ptr [r12 + 1], 'd'
    jne .Lpl_done
    mov rcx, r13                # copy at most 256 bytes
    cmp rcx, 256
    jbe 6f
    mov ecx, 256
6:  lea rdi, [rbx + SSE_id]
    mov rsi, r15
    mov rax, rcx
    rep movsb
    mov [rbx + SSE_id_len], rax
    cmp rax, 256
    jae .Lpl_done
    mov byte ptr [rbx + SSE_id + rax], 0
.Lpl_done:
    EPILOGUE

# .Lend_line(s): finish the line accumulated in s->line.
.Lend_line:
    PROLOGUE 0
    mov rbx, rdi
    cmp dword ptr [rbx + SSE_discard], 0
    jne .Lel_discard
    mov rsi, [rbx + SSE_line + SB_ptr]
    mov rdx, [rbx + SSE_line + SB_len]
    test rdx, rdx
    jz .Lel_blank
    cmp byte ptr [rsi], ':'
    je .Lel_fin                  # comment
    mov rdi, rbx
    call .Lparse_line
    jmp .Lel_fin
.Lel_blank:
    mov rdi, rbx
    call .Ldispatch
    mov rdi, rbx
    call .Lreset_event
    jmp .Lel_fin
.Lel_discard:
    cmp qword ptr [rbx + SSE_line_len], 0
    jne .Lel_fin                # keep discarding until a blank line
    mov dword ptr [rbx + SSE_discard], 0
    mov rdi, rbx
    call .Lreset_event
.Lel_fin:
    mov rdi, rbx
    add rdi, SSE_line
    call sb_clear
    mov qword ptr [rbx + SSE_line_len], 0
    EPILOGUE

# .Lreset_state(s): clear buffers, parser state and error; id is preserved.
.Lreset_state:
    PROLOGUE 0
    mov rbx, rdi
    mov qword ptr [rbx + SSE_err], 0
    mov qword ptr [rbx + SSE_line_len], 0
    mov dword ptr [rbx + SSE_data_lines], 0
    mov dword ptr [rbx + SSE_pending_cr], 0
    mov dword ptr [rbx + SSE_discard], 0
    mov rdi, rbx
    add rdi, SSE_data
    call sb_clear
    mov rdi, rbx
    add rdi, SSE_line
    call sb_clear
    mov rdi, rbx
    call .Lreset_event
    EPILOGUE

# ---------------------------------------------------------------- interface

# sse_init(s, on_event, ctx)
FN sse_init
    PROLOGUE 0
    mov rbx, rdi
    mov [rbx + SSE_on_event], rsi
    mov [rbx + SSE_ctx], rdx
    mov qword ptr [rbx + SSE_id_len], 0
    mov rdi, rbx
    call .Lreset_state
    EPILOGUE

# sse_feed(s, ptr, len)
FN sse_feed
    test rdx, rdx
    jz .Lfeed_ret
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    # a CR at the end of the previous feed eats an LF here
    cmp dword ptr [rbx + SSE_pending_cr], 0
    je .Lfeed_loop
    mov dword ptr [rbx + SSE_pending_cr], 0
    cmp byte ptr [r12], '\n'
    jne .Lfeed_loop
    inc r12
    dec r13
.Lfeed_loop:
    test r13, r13
    jz .Lfeed_out
    # scan for the next LF or CR
    xor r14d, r14d
.Lfeed_find:
    cmp r14, r13
    jae .Lfeed_seg_all
    movzx eax, byte ptr [r12 + r14]
    cmp al, '\n'
    je .Lfeed_seg
    cmp al, '\r'
    je .Lfeed_seg
    inc r14
    jmp .Lfeed_find
.Lfeed_seg_all:
    mov r14, r13
.Lfeed_seg:
    mov rax, [rbx + SSE_line_len]
    add rax, r14
    mov [rbx + SSE_line_len], rax
    cmp rax, SSE_LINE_MAX
    ja .Lfeed_overflow
    cmp dword ptr [rbx + SSE_discard], 0
    jne .Lfeed_advance
    test r14, r14
    jz .Lfeed_advance
    mov rdi, rbx
    add rdi, SSE_line
    mov rsi, r12
    mov rdx, r14
    call sb_push
.Lfeed_advance:
    add r12, r14
    sub r13, r14
    test r13, r13
    jz .Lfeed_out
    movzx r15d, byte ptr [r12]   # line terminator
    inc r12
    dec r13
    mov rdi, rbx
    call .Lend_line
    cmp r15b, '\r'
    jne .Lfeed_loop
    test r13, r13
    jz .Lfeed_pending
    cmp byte ptr [r12], '\n'     # CRLF: swallow the LF
    jne .Lfeed_loop
    inc r12
    dec r13
    jmp .Lfeed_loop
.Lfeed_pending:
    mov dword ptr [rbx + SSE_pending_cr], 1
    jmp .Lfeed_out
.Lfeed_overflow:
    cmp qword ptr [rbx + SSE_err], 0
    jne 1f
    lea rax, [rip + .Lerr_line]
    mov [rbx + SSE_err], rax
1:  mov dword ptr [rbx + SSE_discard], 1
    mov rdi, rbx
    add rdi, SSE_line
    call sb_clear
    mov rdi, rbx
    add rdi, SSE_data
    call sb_clear
    mov dword ptr [rbx + SSE_data_lines], 0
    jmp .Lfeed_advance
.Lfeed_out:
    EPILOGUE
.Lfeed_ret:
    ret

# sse_reset(s)
FN sse_reset
    jmp .Lreset_state

# sse_last_id(s) -> rax ptr, rdx len (0,0 if none)
FN sse_last_id
    mov rdx, [rdi + SSE_id_len]
    test rdx, rdx
    jz .Llast_id_none
    lea rax, [rdi + SSE_id]
    ret
.Llast_id_none:
    xor eax, eax
    xor edx, edx
    ret

# sse_error(s) -> 0 | cstr (first error stays until reset)
FN sse_error
    mov rax, [rdi + SSE_err]
    ret
