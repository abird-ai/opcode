.include "opcode.inc"
# Cell / grid layout (src/tui/render.s)
.equ S_CELL,    24
.equ S_cp,      0
.equ S_comb,    4
.equ CELL_CONT, 0xFFFFFFFF
.equ G_cells,   8
# sanitizer_test: grid_sanitize_bytes must strip terminal control sequences from
# untrusted inline-mode text.  Golden output: tests/data/sanitizer_test.expected
#
# The hostile payload mixes an OSC introducer (\x1b]0;x\x07), a CSI clear
# (\x1b[2J), a C1 control encoded as UTF-8 (\xc2\x9b), DEL and a raw C0 byte with
# printable text and a newline.  The test asserts the sanitized bytes are exactly
# the expected string, contain no raw ESC and no control codepoint other than
# '\n'/'\t', keep the printable text and newline, and drop both introducers.

.bss
.p2align 4
sb: .zero SB_SIZE
.p2align 4
g:  .zero 64

.section .rodata
.hostile:
    .ascii "hi"
    .byte 0x1b
    .ascii "]0;x"
    .byte 0x07
    .ascii "ok"
    .byte 0x1b
    .ascii "[2J"
    .byte 0xc2, 0x9b
    .ascii "Z"
    .byte 0x7f
    .ascii "!"
    .byte 0x01
    .ascii "end\nnext"
.Lhostile_end:
.equ HOSTILE_LEN, .Lhostile_end - .hostile

# The same payload with each disallowed codepoint replaced by U+FFFD.
.expected:
    .ascii "hi"
    .byte 0xef, 0xbf, 0xbd
    .ascii "]0;x"
    .byte 0xef, 0xbf, 0xbd
    .ascii "ok"
    .byte 0xef, 0xbf, 0xbd
    .ascii "[2J"
    .byte 0xef, 0xbf, 0xbd
    .ascii "Z"
    .byte 0xef, 0xbf, 0xbd
    .ascii "!"
    .byte 0xef, 0xbf, 0xbd
    .ascii "end\nnext"
.Lexpected_end:
.equ EXPECTED_LEN, .Lexpected_end - .expected

.s_hi:    .asciz "hi"
.s_next:  .asciz "next"
.s_osc:   .ascii "\033]0;"
.s_csi:   .ascii "\033[2J"
.s_nl:    .byte 10

# tab expansion fixture: every tab lands on the next 4-column stop; the
# newline resets the column, and no raw 0x09 survives.
.tabin:
    .ascii "a"
    .byte 9
    .ascii "b"
    .byte 10
    .ascii "cd"
    .byte 9
    .ascii "e"
.Ltabin_end:
.equ TABIN_LEN, .Ltabin_end - .tabin
.tabout: .ascii "a   b\ncd  e"
.Ltabout_end:
.equ TABOUT_LEN, .Ltabout_end - .tabout

.s_exact: .asciz "sanitize exact ok\n"
.s_esc:   .asciz "sanitize esc ok\n"
.s_ctrl:  .asciz "sanitize controls ok\n"
.s_text:  .asciz "sanitize text ok\n"
.s_intro: .asciz "sanitize introducer ok\n"
.s_grid:  .asciz "sanitize grid ok\n"
.s_emit:  .asciz "sanitize emit ok\n"
.s_attach:.asciz "sanitize attach ok\n"
.s_tab:   .asciz "sanitize tab ok\n"
.s_done:  .asciz "sanitize done\n"
.s_fail:  .asciz "FAIL sanitizer\n"

.text
# print(cstr): write_all to stdout.  Leaf tail call.
print:
    push rdi
    call strlen
    pop rdi
    mov rdx, rax
    mov rsi, rdi
    mov edi, 1
    jmp write_all

FN opcode_main
    PROLOGUE 16
    # sanitize the hostile payload
    lea rdi, [rip + sb]
    call sb_clear
    lea rdi, [rip + .hostile]
    mov esi, HOSTILE_LEN
    lea rdx, [rip + sb]
    call grid_sanitize_bytes
    mov r12, [rip + sb + SB_ptr]
    mov r13, [rip + sb + SB_len]

    # 1. exact expected byte string
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .expected]
    mov ecx, EXPECTED_LEN
    call str_eq
    test eax, eax
    jz .Lfail
    lea rdi, [rip + .s_exact]
    call print

    # 2. no raw ESC byte anywhere
    xor r14d, r14d
1:  cmp r14, r13
    jae 2f
    cmp byte ptr [r12 + r14], 0x1b
    je .Lfail
    inc r14
    jmp 1b
2:  lea rdi, [rip + .s_esc]
    call print

    # 3. no control codepoint other than '\n'/'\t' survives
    xor r14d, r14d
3:  cmp r14, r13
    jae 4f
    lea rdi, [r12 + r14]
    mov rsi, r13
    sub rsi, r14
    call utf8_decode
    add r14, rdx
    cmp eax, 0x0a
    je 3b
    cmp eax, 0x09
    je 3b
    cmp eax, 0x20
    jb .Lfail
    cmp eax, 0x7f
    je .Lfail
    cmp eax, 0x80
    jb 3b
    cmp eax, 0x9f
    jbe .Lfail
    jmp 3b
4:  lea rdi, [rip + .s_ctrl]
    call print

    # 4. printable text and the newline survive
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .s_hi]
    mov ecx, 2
    call str_find
    test rax, rax
    js .Lfail
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .s_next]
    mov ecx, 4
    call str_find
    test rax, rax
    js .Lfail
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .s_nl]
    mov ecx, 1
    call str_find
    test rax, rax
    js .Lfail
    lea rdi, [rip + .s_text]
    call print

    # 5. OSC and CSI introducers did not survive
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .s_osc]
    mov ecx, 4
    call str_find
    test rax, rax
    jns .Lfail
    mov rdi, r12
    mov rsi, r13
    lea rdx, [rip + .s_csi]
    mov ecx, 4
    call str_find
    test rax, rax
    jns .Lfail
    lea rdi, [rip + .s_intro]
    call print

    # 6. grid cells never carry C1/OSC/raw C0, and only genuine combining
    # marks attach.  Draw the hostile payload into a 16-wide grid and scan.
    lea rdi, [rip + g]
    xor esi, esi
    mov rdx, [rip + grid_size]
    call memset
    lea rdi, [rip + g]
    mov esi, 16
    mov edx, 2
    call grid_init
    test eax, eax
    jnz .Lfail
    lea rdi, [rip + g]
    xor esi, esi
    xor edx, edx
    call grid_clear
    lea rdi, [rip + g]
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    xor r9d, r9d
    sub rsp, 16
    lea rax, [rip + .hostile]
    mov [rsp], rax
    mov rax, HOSTILE_LEN
    mov [rsp + 8], rax
    call grid_text
    add rsp, 16
    xor r14d, r14d
.Lsg_cells:
    cmp r14d, 16
    jae .Lsg_cells_ok
    mov rdi, [rip + g + G_cells]
    mov eax, r14d
    imul rax, rax, S_CELL
    add rax, rdi
    mov ecx, dword ptr [rax + S_cp]
    cmp ecx, CELL_CONT
    je .Lsg_next
    cmp ecx, 0x20
    jb .Lfail
    cmp ecx, 0x7f
    je .Lfail
    cmp ecx, 0x80
    jb .Lsg_comb
    cmp ecx, 0x9f
    jbe .Lfail
.Lsg_comb:
    mov ecx, dword ptr [rax + S_comb]
    test ecx, ecx
    jz .Lsg_next
    cmp ecx, 0x20
    jb .Lfail
    cmp ecx, 0x7f
    je .Lfail
.Lsg_next:
    inc r14d
    jmp .Lsg_cells
.Lsg_cells_ok:
    lea rdi, [rip + .s_grid]
    call print

    # 7. the emitted frame escapes only via CSI; no OSC, no C1, no raw C0.
    lea rdi, [rip + g]
    call render_build
    mov r12, rax
    mov r13, rdx
    xor r14d, r14d
.Lse_scan:
    cmp r14, r13
    jae .Lse_ok
    movzx eax, byte ptr [r12 + r14]
    cmp eax, 0x1b
    je .Lse_esc
    test eax, eax
    jz .Lfail
    cmp eax, 0x20
    jb .Lfail
    cmp eax, 0x7f
    je .Lfail
    cmp eax, 0x80
    jb .Lse_next
    cmp eax, 0x9f
    jbe .Lfail
    jmp .Lse_next
.Lse_esc:
    lea rcx, [r14 + 1]
    cmp rcx, r13
    jae .Lfail
    cmp byte ptr [r12 + rcx], '['
    jne .Lfail
    inc r14
.Lse_next:
    inc r14
    jmp .Lse_scan
.Lse_ok:
    lea rdi, [rip + .s_emit]
    call print

    # 8. only genuine combining marks attach to a base cell.
    lea rdi, [rip + g]
    xor esi, esi
    xor edx, edx
    call grid_clear
    lea rdi, [rip + g]
    xor esi, esi
    xor edx, edx
    mov ecx, 0x65
    xor r8d, r8d
    xor r9d, r9d
    sub rsp, 16
    mov qword ptr [rsp], 0
    call grid_put
    add rsp, 16
    lea rdi, [rip + g]
    mov esi, 1
    xor edx, edx
    mov ecx, 0x200B              # ZWSP: dropped, must not attach
    xor r8d, r8d
    xor r9d, r9d
    sub rsp, 16
    mov qword ptr [rsp], 0
    call grid_put
    add rsp, 16
    mov rax, [rip + g + G_cells]
    cmp dword ptr [rax + S_cp], 0x65
    jne .Lfail
    cmp dword ptr [rax + S_comb], 0
    jne .Lfail
    lea rdi, [rip + g]
    mov esi, 2
    xor edx, edx
    mov ecx, 0x65
    xor r8d, r8d
    xor r9d, r9d
    sub rsp, 16
    mov qword ptr [rsp], 0
    call grid_put
    add rsp, 16
    lea rdi, [rip + g]
    mov esi, 3
    xor edx, edx
    mov ecx, 0x0301              # combining acute: attaches
    xor r8d, r8d
    xor r9d, r9d
    sub rsp, 16
    mov qword ptr [rsp], 0
    call grid_put
    add rsp, 16
    mov rax, [rip + g + G_cells]
    add rax, 2 * S_CELL
    cmp dword ptr [rax + S_cp], 0x65
    jne .Lfail
    cmp dword ptr [rax + S_comb], 0x0301
    jne .Lfail
    lea rdi, [rip + .s_attach]
    call print

    # 9. a tab expands to the next 4-column stop and never survives raw
    lea rdi, [rip + sb]
    call sb_clear
    lea rdi, [rip + .tabin]
    mov esi, TABIN_LEN
    lea rdx, [rip + sb]
    call grid_sanitize_bytes
    mov rdi, [rip + sb + SB_ptr]
    mov rsi, [rip + sb + SB_len]
    lea rdx, [rip + .tabout]
    mov ecx, TABOUT_LEN
    call str_eq
    test eax, eax
    jz .Lfail
    mov r12, [rip + sb + SB_ptr]
    mov r13, [rip + sb + SB_len]
    xor r14d, r14d
.Lstab_scan:
    cmp r14, r13
    jae .Lstab_ok
    cmp byte ptr [r12 + r14], 9
    je .Lfail
    inc r14
    jmp .Lstab_scan
.Lstab_ok:
    lea rdi, [rip + .s_tab]
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
