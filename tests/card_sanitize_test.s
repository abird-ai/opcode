.include "opcode.inc"
.include "core/core.inc"
.include "tui/card.inc"
# card_sanitize_test: the card line builder is the single choke point for
# untrusted tool names/arguments, so the inline/scrollback card writer can
# never emit a raw escape.
#   * P0: a hostile tool name and argument preview render with U+FFFD and no
#     raw ESC/BEL/C1 byte anywhere in the card rows.
#   * P2 #5: a tab in the header expands to the next 4-column stop.
#   * P2 #6: the 48-column argument preview clip never splits a UTF-8 sequence.
# Golden: tests/data/card_sanitize_test.expected

.bss
.p2align 4
view: .zero 256
chat: .zero CH_SIZE

.section .rodata
.Lid1: .asciz "id1"
.Lid2: .asciz "id2"
.Lid3: .asciz "id3"

h_name:
    .ascii "missing"
    .byte 0x1b
    .ascii "tool"
    .byte 0
h_args:
    .ascii "{\"x\":\""
    .byte 0x1b
    .ascii "[2K"
    .byte 0x1b
    .ascii "]0;PWNED"
    .byte 0x07
    .ascii "\"}"
.Lh_args_end:
.equ H_ARGS_LEN, .Lh_args_end - h_args

t_name: .asciz "x"
t_args: .ascii "a"
        .byte 9
        .ascii "b"
.Lt_args_end:
.equ T_ARGS_LEN, .Lt_args_end - t_args

mb_name: .asciz "m"
mb_args:
    .fill 47, 1, 0x61
    .byte 0xc3, 0xa9
    .ascii "ZZ"
.Lmb_args_end:
.equ MB_ARGS_LEN, .Lmb_args_end - mb_args

n_fffd: .byte 0xef, 0xbf, 0xbd
n_tab:  .byte 9
n_e:    .byte 0xc3, 0xa9
n_ab:   .ascii "a   b"
n_zz:   .ascii "ZZ"

s_esc:  .asciz "card hostile sanitized ok\n"
s_tab:  .asciz "card tab expanded ok\n"
s_clip: .asciz "card utf8 clip ok\n"
s_done: .asciz "card sanitize done\n"
s_fail: .asciz "FAIL card sanitize\n"

.text
# print(cstr)
print:
    push rdi
    call strlen
    pop rdi
    mov rdx, rax
    mov rsi, rdi
    mov edi, 1
    jmp write_all

# bytes_has(ptr rdi, len rsi, needle rdx, nlen rcx) -> eax 1|0
bytes_has:
    PROLOGUE 32
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    xor ebx, ebx
1:  mov rax, r13
    sub rax, rbx
    cmp rax, r15
    jb .Lbh_no
    xor r10d, r10d
2:  cmp r10, r15
    jae .Lbh_yes
    mov rax, rbx
    add rax, r10
    movzx eax, byte ptr [r12 + rax]
    movzx ecx, byte ptr [r14 + r10]
    cmp eax, ecx
    jne 3f
    inc r10
    jmp 2b
3:  inc rbx
    jmp 1b
.Lbh_yes:
    mov eax, 1
    EPILOGUE
.Lbh_no:
    xor eax, eax
    EPILOGUE

# view_has_seq(view rdi, needle rsi, nlen rdx) -> eax 1|0
view_has_seq:
    PROLOGUE 32
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    xor r15d, r15d
1:  mov rdi, r12
    call view_rows
    cmp r15d, eax
    jae .Lvhs_no
    mov rdi, r12
    mov esi, r15d
    call view_row_len
    mov rbx, rax
    mov rdi, r12
    mov esi, r15d
    call view_row_text
    mov rdi, rax
    mov rsi, rbx
    mov rdx, r13
    mov rcx, r14
    call bytes_has
    test eax, eax
    jnz .Lvhs_yes
    inc r15d
    jmp 1b
.Lvhs_yes:
    mov eax, 1
    EPILOGUE
.Lvhs_no:
    xor eax, eax
    EPILOGUE

# view_has_byte(view rdi, byte esi) -> eax 1|0
view_has_byte:
    PROLOGUE 32
    mov r12, rdi
    mov r13d, esi
    xor r14d, r14d
1:  mov rdi, r12
    call view_rows
    cmp r14d, eax
    jae .Lvhb_no
    mov rdi, r12
    mov esi, r14d
    call view_row_len
    mov r15, rax
    mov rdi, r12
    mov esi, r14d
    call view_row_text
    mov rbx, rax
    xor ecx, ecx
2:  cmp rcx, r15
    jae 3f
    movzx eax, byte ptr [rbx + rcx]
    cmp eax, r13d
    je .Lvhb_yes
    inc rcx
    jmp 2b
3:  inc r14d
    jmp 1b
.Lvhb_yes:
    mov eax, 1
    EPILOGUE
.Lvhb_no:
    xor eax, eax
    EPILOGUE

# render_card(chat rdi, name rsi, args rdx, argslen rcx, id r8)
render_card:
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    mov rbx, r8
    lea rdi, [rip + view]
    call view_clear
    mov rdi, r12
    mov rsi, rbx
    mov rdx, r13
    xor ecx, ecx
    call chat_tool_start
    test r15, r15
    jz 1f
    mov rdi, r12
    mov rsi, r14
    mov rdx, r15
    call chat_tool_delta
1:  lea rdi, [rip + view]
    mov rsi, r12
    mov edx, 80
    xor ecx, ecx
    call chat_render_unmatched
    EPILOGUE

FN opcode_main
    PROLOGUE 16
    lea rdi, [rip + view]
    mov esi, 80
    call view_init
    lea rdi, [rip + chat]
    call chat_init

    # ---- P0: hostile name and args never yield a raw escape ----
    lea rdi, [rip + chat]
    lea rsi, [rip + h_name]
    lea rdx, [rip + h_args]
    mov ecx, H_ARGS_LEN
    lea r8, [rip + .Lid1]
    call render_card
    lea rdi, [rip + view]
    mov esi, 0x1b
    call view_has_byte
    test eax, eax
    jnz .Lfail
    lea rdi, [rip + view]
    mov esi, 0x07
    call view_has_byte
    test eax, eax
    jnz .Lfail
    lea rdi, [rip + view]
    lea rsi, [rip + n_fffd]
    mov edx, 3
    call view_has_seq
    test eax, eax
    jz .Lfail
    lea rdi, [rip + s_esc]
    call print

    # ---- P2 #5: a header tab expands to the next 4-column stop ----
    lea rdi, [rip + chat]
    call chat_clear
    lea rdi, [rip + chat]
    lea rsi, [rip + t_name]
    lea rdx, [rip + t_args]
    mov ecx, T_ARGS_LEN
    lea r8, [rip + .Lid2]
    call render_card
    lea rdi, [rip + view]
    mov esi, 9
    call view_has_byte
    test eax, eax
    jnz .Lfail
    lea rdi, [rip + view]
    lea rsi, [rip + n_ab]
    mov edx, 5
    call view_has_seq
    test eax, eax
    jz .Lfail
    lea rdi, [rip + s_tab]
    call print

    # ---- P2 #6: 48-column clip keeps a multibyte char whole ----
    lea rdi, [rip + chat]
    call chat_clear
    lea rdi, [rip + chat]
    lea rsi, [rip + mb_name]
    lea rdx, [rip + mb_args]
    mov ecx, MB_ARGS_LEN
    lea r8, [rip + .Lid3]
    call render_card
    lea rdi, [rip + view]
    lea rsi, [rip + n_fffd]
    mov edx, 3
    call view_has_seq
    test eax, eax
    jnz .Lfail
    lea rdi, [rip + view]
    lea rsi, [rip + n_e]
    mov edx, 2
    call view_has_seq
    test eax, eax
    jz .Lfail
    lea rdi, [rip + view]
    lea rsi, [rip + n_zz]
    mov edx, 2
    call view_has_seq
    test eax, eax
    jnz .Lfail
    lea rdi, [rip + s_clip]
    call print

    lea rdi, [rip + s_done]
    call print
    xor eax, eax
    EPILOGUE
.Lfail:
    lea rdi, [rip + s_fail]
    call print
    mov eax, 1
    EPILOGUE
