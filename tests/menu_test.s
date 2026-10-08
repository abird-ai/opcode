.include "opcode.inc"
.include "core/core.inc"
# menu_test: the slash-command menu's Esc dismissal and reopen policy.
#
# Esc closes the menu and remembers the dismissal so the same word does not pop
# back up while the composer text is unchanged.  A non-menu word (for example
# clearing the composer) must clear that dismissal, so retyping the same word
# reopens the menu instead of staying permanently suppressed.
# Golden: tests/data/menu_test.expected

.bss
.p2align 3
fail: .zero 4

.section .rodata
.Lok:      .asciz " ok\n"
.Lbad:     .asciz " FAIL\n"
.Lslash:   .asciz "/"
.Lx:       .asciz "x"
.Lc_open:  .asciz "menu.open"
.Lc_esc:   .asciz "menu.esc-consumed"
.Lc_close: .asciz "menu.esc-closed"
.Lc_same:  .asciz "menu.same-word-dismissed"
.Lc_non:   .asciz "menu.nonmenu-closed"
.Lc_re:    .asciz "menu.reopen-same-word"

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

# case(name cstr, cond esi)
case:
    PROLOGUE 0
    mov r12, rdi
    mov r13d, esi
    mov rdi, r12
    call print
    test r13d, r13d
    jz .Lcase_bad
    lea rdi, [rip + .Lok]
    call print
    EPILOGUE
.Lcase_bad:
    lea rdi, [rip + .Lbad]
    call print
    mov dword ptr [rip + fail], 1
    EPILOGUE

FN opcode_main
    PROLOGUE
    call menu_init

    # "/" opens the menu
    lea rdi, [rip + .Lslash]
    mov esi, 1
    call menu_update
    call menu_open
    mov r12d, eax
    lea rdi, [rip + .Lc_open]
    mov esi, r12d
    call case

    # Esc is consumed and closes it
    mov esi, 0x1b
    xor edx, edx
    xor ecx, ecx
    call menu_key
    mov r12d, eax
    lea rdi, [rip + .Lc_esc]
    mov esi, r12d
    call case
    call menu_open
    xor eax, 1
    mov r12d, eax
    lea rdi, [rip + .Lc_close]
    mov esi, r12d
    call case

    # the same word, unchanged, stays dismissed
    lea rdi, [rip + .Lslash]
    mov esi, 1
    call menu_update
    call menu_open
    xor eax, 1
    mov r12d, eax
    lea rdi, [rip + .Lc_same]
    mov esi, r12d
    call case

    # a non-menu word closes the menu and clears the dismissal
    lea rdi, [rip + .Lx]
    mov esi, 1
    call menu_update
    call menu_open
    xor eax, 1
    mov r12d, eax
    lea rdi, [rip + .Lc_non]
    mov esi, r12d
    call case

    # retyping the same word reopens it
    lea rdi, [rip + .Lslash]
    mov esi, 1
    call menu_update
    call menu_open
    mov r12d, eax
    lea rdi, [rip + .Lc_re]
    mov esi, r12d
    call case

    mov eax, [rip + fail]
    EPILOGUE
