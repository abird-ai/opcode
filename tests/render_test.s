.include "opcode.inc"
# render_test: headless cell grid, ANSI diff to a real fd, term size checks.

.equ SYS_dup, 32
.equ SYS_dup2, 33

.bss
.p2align 4
g:            .zero 64
sb:           .zero SB_SIZE
recvbuf:      .zero 4096
saved_stdout: .zero 8

.section .rodata
.s_hello:  .asciz "hello"
.s_opcode: .asciz "opcode"
.s_m1:     .asciz "---- frame 1 ----\n"
.s_m2:     .asciz "---- frame 2 ----\n"
.s_ok_r:   .asciz "render ok\n"
.s_ok_t:   .asciz "term ok\n"
.s_done:   .asciz "render done\n"
.s_fail:   .asciz "FAIL render\n"
.s_ansi:   .asciz "build/render_test.ansi"
.s_sync_h: .ascii "\033[?2026h"
.s_nl:     .asciz "\n"

.text

# print(cstr): write_all to stdout.
print:
    push rdi
    call strlen
    pop rdi
    mov rdx, rax
    mov rsi, rdi
    mov edi, 1
    jmp write_all

# draw_box(g, fg, bg): 20x5 border of '-' and '|'.
draw_box:
    PROLOGUE 0
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    # top
    mov rdi, rbx
    xor esi, esi
    xor edx, edx
    mov ecx, 20
    mov r8d, 1
    mov r9d, '-'
    sub rsp, 16
    mov [rsp], r12d
    mov [rsp + 8], r13d
    call grid_fill
    add rsp, 16
    # bottom
    mov rdi, rbx
    xor esi, esi
    mov edx, 4
    mov ecx, 20
    mov r8d, 1
    mov r9d, '-'
    sub rsp, 16
    mov [rsp], r12d
    mov [rsp + 8], r13d
    call grid_fill
    add rsp, 16
    # left
    mov rdi, rbx
    xor esi, esi
    mov edx, 1
    mov ecx, 1
    mov r8d, 3
    mov r9d, '|'
    sub rsp, 16
    mov [rsp], r12d
    mov [rsp + 8], r13d
    call grid_fill
    add rsp, 16
    # right
    mov rdi, rbx
    mov esi, 19
    mov edx, 1
    mov ecx, 1
    mov r8d, 3
    mov r9d, '|'
    sub rsp, 16
    mov [rsp], r12d
    mov [rsp + 8], r13d
    call grid_fill
    add rsp, 16
    xor eax, eax
    EPILOGUE

# dump(): render_dump into sb, print it plus a newline.
dump:
    PROLOGUE 0
    lea rdi, [rip + sb]
    call sb_clear
    lea rdi, [rip + g]
    lea rsi, [rip + sb]
    call render_dump
    lea rax, [rip + sb]
    mov rsi, [rax + SB_ptr]
    mov rdx, [rax + SB_len]
    mov edi, 1
    call write_all
    lea rdi, [rip + .s_nl]
    call print
    EPILOGUE

FN opcode_main
    PROLOGUE 0
    # headless mode with a fixed 20x5 size
    mov qword ptr [rip + g_tui_headless], 1
    mov edi, 20
    mov esi, 5
    call term_set_size
    call term_init
    test rax, rax
    jnz .Lfail
    # zero + init the grid
    lea rdi, [rip + g]
    xor esi, esi
    mov rdx, [rip + grid_size]
    call memset
    lea rdi, [rip + g]
    mov esi, 20
    mov edx, 5
    call grid_init
    test rax, rax
    jnz .Lfail

    # ---- frame 1: box + "hello" at (1,1) --------------------------------
    lea rdi, [rip + g]
    mov esi, 0xFF000000
    mov edx, 0xFF101010
    call grid_clear
    lea rdi, [rip + g]
    mov esi, 0xFF888888
    mov edx, 0xFF101010
    call draw_box
    lea rdi, [rip + g]
    mov esi, 1
    mov edx, 1
    mov ecx, 0xFF00FF00
    mov r8d, 0xFF101010
    xor r9d, r9d
    sub rsp, 16
    lea rax, [rip + .s_hello]
    mov [rsp], rax
    mov qword ptr [rsp + 8], 5
    call grid_text
    add rsp, 16
    lea rdi, [rip + .s_m1]
    call print
    call dump

    # ---- render_flush/term_flush output goes to build/render_test.ansi ---
    # Temporarily point fd 1 at the ansi file (term_flush writes to fd 1).
    mov edi, 1
    mov eax, SYS_dup
    syscall
    test rax, rax
    js .Lfail
    mov [rip + saved_stdout], rax
    mov edi, 1
    mov eax, SYS_close
    syscall
    lea rdi, [rip + .s_ansi]
    mov esi, O_WRONLY | O_CREAT | O_TRUNC
    mov edx, 0644
    call os_open
    mov r12, rax                    # expected to be fd 1
    lea rdi, [rip + g]
    xor esi, esi
    xor edx, edx
    mov ecx, 1
    call term_flush
    mov r13, rax
    # restore stdout unconditionally
    test r12, r12
    js 1f
    mov edi, r12d
    mov eax, SYS_close
    syscall
1:  mov edi, dword ptr [rip + saved_stdout]
    mov esi, 1
    mov eax, SYS_dup2
    syscall
    mov edi, dword ptr [rip + saved_stdout]
    mov eax, SYS_close
    syscall
    cmp r12, 1
    jne .Lfail
    test r13, r13
    jnz .Lfail
    # read the ansi file back: it must contain sync-begin and "hello"
    lea rdi, [rip + .s_ansi]
    mov esi, O_RDONLY
    xor edx, edx
    call os_open
    test rax, rax
    js .Lfail
    mov r12, rax
    mov edi, r12d
    lea rsi, [rip + recvbuf]
    mov edx, 4096
    call os_read
    mov r13, rax
    mov edi, r12d
    call os_close
    test r13, r13
    jle .Lfail
    lea rdi, [rip + recvbuf]
    mov rsi, r13
    lea rdx, [rip + .s_sync_h]
    mov ecx, 8
    call str_find
    test rax, rax
    js .Lfail
    lea rdi, [rip + recvbuf]
    mov rsi, r13
    lea rdx, [rip + .s_hello]
    mov ecx, 5
    call str_find
    test rax, rax
    js .Lfail

    # ---- frame 2: box + "opcode" at (6,2) --------------------------------
    lea rdi, [rip + g]
    mov esi, 0xFF000000
    mov edx, 0xFF101010
    call grid_clear
    lea rdi, [rip + g]
    mov esi, 0xFF888888
    mov edx, 0xFF101010
    call draw_box
    lea rdi, [rip + g]
    mov esi, 6
    mov edx, 2
    mov ecx, 0xFFFF00FF
    mov r8d, 0xFF101010
    xor r9d, r9d
    sub rsp, 16
    lea rax, [rip + .s_opcode]
    mov [rsp], rax
    mov qword ptr [rsp + 8], 6
    call grid_text
    add rsp, 16
    lea rdi, [rip + .s_m2]
    call print
    call dump

    lea rdi, [rip + .s_ok_r]
    call print

    # ---- term checks ------------------------------------------------------
    call term_size
    cmp rax, 20
    jne .Lfail
    cmp rdx, 5
    jne .Lfail
    call term_resized
    test rax, rax
    jnz .Lfail
    lea rdi, [rip + .s_ok_t]
    call print
    call term_restore
    lea rdi, [rip + .s_done]
    call print
    lea rdi, [rip + g]
    call grid_free
    xor eax, eax
    EPILOGUE
.Lfail:
    lea rdi, [rip + .s_fail]
    call print
    mov eax, 1
    EPILOGUE
