.include "opcode.inc"
.include "core/core.inc"
.include "tui/card.inc"
# card_test: the tool-card state machine and renderer.  Checks the running
# header with spinner/elapsed, the outcome bands, the collapsed tail + marker,
# Ctrl+O expansion and edit diff styling.  Golden: tests/data/card_test.expected

.bss
.p2align 4
view:  .zero 256
chat:  .zero CH_SIZE
chat2: .zero CH_SIZE
chat3: .zero CH_SIZE
te:    .zero TE_SIZE

.section .rodata
args_bash:   .ascii "{\"command\": \"echo hi\"}"
.Largs_end:
.equ ARGS_BASH_LEN, .Largs_end - args_bash
res6:        .ascii "line1\nline2\nline3\nline4\nline5\n[exit 0]\n"
.Lres6_end:
.equ RES6_LEN, .Lres6_end - res6
res_edit:    .ascii "+add\n-del\n@@ hunk"
.Lres_edit_end:
.equ RES_EDIT_LEN, .Lres_edit_end - res_edit
err_txt:     .ascii "error: boom"
.Lerr_end:
.equ ERR_LEN, .Lerr_end - err_txt

te_id1:      .asciz "toolu_1"
te_id_e:     .asciz "toolu_e"
te_id_x:     .asciz "toolu_x"
nm_bash:     .asciz "bash"
nm_missing:  .asciz "missing"
nm_edit:     .asciz "edit"
empty_obj:   .asciz "{}"

m_running: .ascii "| 234ms"
.Lm_running_end:
.equ M_RUNNING_LEN, .Lm_running_end - m_running
m_ok:      .ascii "ok 42ms"
.Lm_ok_end:
.equ M_OK_LEN, .Lm_ok_end - m_ok
m_err:     .ascii "err 7ms"
.Lm_err_end:
.equ M_ERR_LEN, .Lm_err_end - m_err
m_marker:  .ascii "... (+3 lines)"
.Lm_marker_end:
.equ M_MARKER_LEN, .Lm_marker_end - m_marker
m_line1:   .ascii "line1"
m_line4:   .ascii "line4"
m_bash:    .ascii "[bash]"
.Lm_bash_end:
.equ M_BASH_LEN, .Lm_bash_end - m_bash

.s_running_bg: .asciz "card running band ok\n"
.s_running:    .asciz "card running header ok\n"
.s_collapsed:  .asciz "card collapsed marker ok\n"
.s_ok_bg:      .asciz "card ok band ok\n"
.s_expanded:   .asciz "card expanded ok\n"
.s_err:        .asciz "card err band ok\n"
.s_diff:       .asciz "card edit diff ok\n"
.s_done:       .asciz "card done\n"
.s_fail:       .asciz "FAIL card\n"

.text
print:
    push rdi
    call strlen
    pop rdi
    mov rdx, rax
    mov rsi, rdi
    mov edi, 1
    jmp write_all

# find_row(view, needle, nlen) -> eax row index | -1
find_row:
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    xor ebx, ebx
1:  mov rdi, r12
    call view_rows
    cmp ebx, eax
    jae 3f
    mov rdi, r12
    mov esi, ebx
    call view_row_len
    mov r15, rax
    mov rdi, r12
    mov esi, ebx
    call view_row_text
    mov rdi, rax
    mov rsi, r15
    mov rdx, r13
    mov rcx, r14
    call str_find
    test rax, rax
    jns 2f
    inc ebx
    jmp 1b
2:  mov eax, ebx
    EPILOGUE
3:  mov eax, -1
    EPILOGUE

# row_style(view, row) -> ptr to the row's style bytes
row_style:
    call view_row_text
    add rax, 256
    ret

FN opcode_main
    PROLOGUE 16
    lea rdi, [rip + view]
    mov esi, 60
    call view_init
    lea rdi, [rip + chat]
    call chat_init

    # 1. running card: header spinner/elapsed + running band
    lea rdi, [rip + chat]
    lea rsi, [rip + te_id1]
    lea rdx, [rip + nm_bash]
    mov rcx, 1000
    call chat_tool_start
    lea rdi, [rip + chat]
    lea rsi, [rip + args_bash]
    mov edx, ARGS_BASH_LEN
    call chat_tool_delta
    lea rdi, [rip + view]
    lea rsi, [rip + chat]
    mov edx, 60
    mov rcx, 1234
    call chat_render_unmatched
    lea rdi, [rip + view]
    lea rsi, [rip + m_running]
    mov edx, M_RUNNING_LEN
    call find_row
    test eax, eax
    js .Lfail
    lea rdi, [rip + view]
    xor esi, esi
    call view_row_bg
    cmp eax, CARD_BG_RUN
    jne .Lfail
    lea rdi, [rip + .s_running]
    call print

    # 2. finished ok card: collapsed tail + "... (+3 lines)" + ok band
    lea rax, [rip + te_id1]
    mov [rip + te + TE_id], rax
    lea rax, [rip + nm_bash]
    mov [rip + te + TE_name], rax
    lea rax, [rip + empty_obj]
    mov [rip + te + TE_args], rax
    lea rax, [rip + res6]
    mov [rip + te + TE_result], rax
    mov qword ptr [rip + te + TE_result_len], RES6_LEN
    mov dword ptr [rip + te + TE_error], 0
    mov dword ptr [rip + te + TE_duration_ms], 42
    lea rdi, [rip + chat]
    lea rsi, [rip + te]
    call chat_tool_exec
    lea rdi, [rip + view]
    call view_clear
    lea rdi, [rip + chat]
    call chat_reset_marks
    lea rdi, [rip + view]
    lea rsi, [rip + chat]
    mov edx, 60
    mov rcx, 9999
    call chat_render_unmatched
    lea rdi, [rip + view]
    lea rsi, [rip + m_ok]
    mov edx, M_OK_LEN
    call find_row
    test eax, eax
    js .Lfail
    lea rdi, [rip + view]
    lea rsi, [rip + m_marker]
    mov edx, M_MARKER_LEN
    call find_row
    test eax, eax
    js .Lfail
    lea rdi, [rip + view]
    lea rsi, [rip + m_line4]
    mov edx, 5
    call find_row
    test eax, eax
    js .Lfail
    lea rdi, [rip + view]
    xor esi, esi
    call view_row_bg
    cmp eax, CARD_BG_OK
    jne .Lfail
    lea rdi, [rip + .s_collapsed]
    call print

    # 3. Ctrl+O toggle: expanded shows line1 and drops the marker
    lea rdi, [rip + chat]
    call chat_toggle_last
    lea rdi, [rip + view]
    call view_clear
    lea rdi, [rip + chat]
    call chat_reset_marks
    lea rdi, [rip + view]
    lea rsi, [rip + chat]
    mov edx, 60
    mov rcx, 9999
    call chat_render_unmatched
    lea rdi, [rip + view]
    lea rsi, [rip + m_line1]
    mov edx, 5
    call find_row
    test eax, eax
    js .Lfail
    lea rdi, [rip + view]
    lea rsi, [rip + m_marker]
    mov edx, M_MARKER_LEN
    call find_row
    test eax, eax
    jns .Lfail
    lea rdi, [rip + .s_expanded]
    call print

    # 4. error card created from SE_TOOL_EXEC with no running card
    lea rdi, [rip + chat2]
    call chat_init
    lea rax, [rip + te_id_e]
    mov [rip + te + TE_id], rax
    lea rax, [rip + nm_missing]
    mov [rip + te + TE_name], rax
    lea rax, [rip + empty_obj]
    mov [rip + te + TE_args], rax
    lea rax, [rip + err_txt]
    mov [rip + te + TE_result], rax
    mov qword ptr [rip + te + TE_result_len], ERR_LEN
    mov dword ptr [rip + te + TE_error], 1
    mov dword ptr [rip + te + TE_duration_ms], 7
    lea rdi, [rip + chat2]
    lea rsi, [rip + te]
    call chat_tool_exec
    lea rdi, [rip + view]
    call view_clear
    lea rdi, [rip + chat2]
    call chat_reset_marks
    lea rdi, [rip + view]
    lea rsi, [rip + chat2]
    mov edx, 60
    mov rcx, 9999
    call chat_render_unmatched
    lea rdi, [rip + view]
    lea rsi, [rip + m_err]
    mov edx, M_ERR_LEN
    call find_row
    test eax, eax
    js .Lfail
    lea rdi, [rip + view]
    xor esi, esi
    call view_row_bg
    cmp eax, CARD_BG_ERR
    jne .Lfail
    lea rdi, [rip + .s_err]
    call print

    # 5. edit card: '+', '-' and '@' body lines carry diff styles
    lea rdi, [rip + chat3]
    call chat_init
    lea rdi, [rip + chat3]
    lea rsi, [rip + te_id_x]
    lea rdx, [rip + nm_edit]
    mov rcx, 0
    call chat_tool_start
    lea rax, [rip + te_id_x]
    mov [rip + te + TE_id], rax
    lea rax, [rip + nm_edit]
    mov [rip + te + TE_name], rax
    lea rax, [rip + empty_obj]
    mov [rip + te + TE_args], rax
    lea rax, [rip + res_edit]
    mov [rip + te + TE_result], rax
    mov qword ptr [rip + te + TE_result_len], RES_EDIT_LEN
    mov dword ptr [rip + te + TE_error], 0
    mov dword ptr [rip + te + TE_duration_ms], 1
    lea rdi, [rip + chat3]
    lea rsi, [rip + te]
    call chat_tool_exec
    lea rdi, [rip + view]
    call view_clear
    lea rdi, [rip + chat3]
    call chat_reset_marks
    lea rdi, [rip + view]
    lea rsi, [rip + chat3]
    mov edx, 60
    mov rcx, 9999
    call chat_render_unmatched
    # row 0 header, rows 1..3 the three body lines (indented one column)
    lea rdi, [rip + view]
    mov esi, 1
    call row_style
    movzx eax, byte ptr [rax + 1]
    cmp eax, VS_CARD_ADD
    jne .Lfail
    lea rdi, [rip + view]
    mov esi, 2
    call row_style
    movzx eax, byte ptr [rax + 1]
    cmp eax, VS_CARD_DEL
    jne .Lfail
    lea rdi, [rip + view]
    mov esi, 3
    call row_style
    movzx eax, byte ptr [rax + 1]
    cmp eax, VS_CARD_HUNK
    jne .Lfail
    lea rdi, [rip + .s_diff]
    call print

    lea rdi, [rip + .s_done]
    call print
    xor eax, eax
    EPILOGUE
.Lfail:
    lea rdi, [rip + .s_fail]
    call print
    mov eax, 1
    EPILOGUE
