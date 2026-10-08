.include "opcode.inc"
.include "core/core.inc"
# edit tool integration test.
# Golden output: tests/data/edit_test.expected

.bss
.p2align 3
t_job:   .zero J_SIZE
t_out:   .zero SB_SIZE
readbuf: .zero 8192

.section .rodata
.Lnl:       .asciz "\n"
.Ledit:     .asciz "edit"
.Lfail_msg: .asciz "FAIL: edit_test"
.Lok:       .asciz "edit ok"
.Lok_crlf:  .asciz "edit crlf ok"
.Lok_bom:   .asciz "edit bom ok"
.Lok_uniq:  .asciz "edit unique ok"
.Lok_ov:    .asciz "edit overlap ok"
.Lok_diff:  .asciz "diff ok"
.Ldone:     .asciz "edit done"

# case 1: two replacements
.Lf1:      .asciz "build/edit_test.tmp"
.Lc1:      .ascii "alpha\nold\nomega\n"
.Lc1e:
.La1:      .asciz "{\"path\":\"build/edit_test.tmp\",\"edits\":[{\"oldText\":\"alpha\",\"newText\":\"ALPHA\"},{\"oldText\":\"omega\",\"newText\":\"OMEGA\"}]}"
.Lc1new:   .ascii "ALPHA\nold\nOMEGA\n"
.Lc1newe:
.Lneed_repl: .asciz "2 replacement(s)"

# case 2: CRLF
.Lf2:      .asciz "build/edit_test_crlf.tmp"
.Lc2:      .ascii "one\r\ntwo\r\n"
.Lc2e:
.La2:      .asciz "{\"path\":\"build/edit_test_crlf.tmp\",\"edits\":[{\"oldText\":\"two\",\"newText\":\"TWO\"}]}"
.Lc2new:   .ascii "one\r\nTWO\r\n"
.Lc2newe:

# case 3: BOM
.Lf3:      .asciz "build/edit_test_bom.tmp"
.Lc3:      .byte 0xef, 0xbb, 0xbf
           .ascii "hello\n"
.Lc3e:
.La3:      .asciz "{\"path\":\"build/edit_test_bom.tmp\",\"edits\":[{\"oldText\":\"hello\",\"newText\":\"HELLO\"}]}"
.Lc3new:   .byte 0xef, 0xbb, 0xbf
           .ascii "HELLO\n"
.Lc3newe:

# case 4: duplicate oldText
.Lf4:      .asciz "build/edit_test_dup.tmp"
.Lc4:      .ascii "dup\ndup\n"
.Lc4e:
.La4:      .asciz "{\"path\":\"build/edit_test_dup.tmp\",\"edits\":[{\"oldText\":\"dup\",\"newText\":\"x\"}]}"
.Lneed_uniq: .asciz "not unique"

# case 5: overlapping edits
.Lf5:      .asciz "build/edit_test_ov.tmp"
.Lc5:      .ascii "abcde"
.Lc5e:
.La5:      .asciz "{\"path\":\"build/edit_test_ov.tmp\",\"edits\":[{\"oldText\":\"abc\",\"newText\":\"x\"},{\"oldText\":\"bcd\",\"newText\":\"y\"}]}"
.Lneed_ov: .asciz "overlapping edits"

# case 6: unified diff
.Lf6:      .asciz "build/edit_test_diff.tmp"
.Lc6:      .ascii "old\n"
.Lc6e:
.La6:      .asciz "{\"path\":\"build/edit_test_diff.tmp\",\"edits\":[{\"oldText\":\"old\",\"newText\":\"new\"}]}"
.Lneed_hunk: .asciz "@@ -1,"
.Lneed_minus: .asciz "-old"
.Lneed_plus: .asciz "+new"

.text

# print_line(cstr)
print_line:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov rdi, rbx
    call strlen
    mov rdx, rax
    mov rsi, rbx
    mov edi, 1
    call write_all
    lea rsi, [rip + .Lnl]
    mov edx, 1
    mov edi, 1
    call write_all
    add rsp, 8
    pop r12
    pop rbx
    ret

# sb_has(sb, needle cstr) -> 1 | 0
sb_has:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
    mov r12, rsi
    mov rdi, r12
    call strlen
    mov rcx, rax
    mov rdi, [rbx + SB_ptr]
    test rdi, rdi
    jz 1f
    mov rsi, [rbx + SB_len]
    mov rdx, r12
    call str_find
    cmp rax, -1
    setne al
    movzx eax, al
    jmp 2f
1:  xor eax, eax
2:  add rsp, 8
    pop r12
    pop rbx
    ret

# write_file(path, ptr, len) -> 0 | -errno
write_file:
    PROLOGUE 32
    mov [rsp], rsi
    mov [rsp + 8], rdx
    mov esi, O_WRONLY | O_CREAT | O_TRUNC
    mov edx, 0644
    call os_open
    test rax, rax
    js .Lwf_out
    mov [rsp + 16], rax
    mov edi, eax
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    call write_all
    mov r12, rax
    mov edi, [rsp + 16]
    call os_close
    mov rax, r12
.Lwf_out:
    EPILOGUE

# file_eq(path, ptr, len) -> 1 | 0
file_eq:
    PROLOGUE 32
    mov [rsp], rsi
    mov [rsp + 8], rdx
    xor esi, esi
    xor edx, edx
    call os_open
    test rax, rax
    js .Lfe_fail
    mov [rsp + 16], rax
    mov edi, eax
    lea rsi, [rip + readbuf]
    mov edx, 8192
    call os_read
    mov r12, rax
    mov edi, [rsp + 16]
    call os_close
    test r12, r12
    js .Lfe_fail
    cmp r12, [rsp + 8]
    jne .Lfe_fail
    lea rdi, [rip + readbuf]
    mov rsi, [rsp]
    mov rdx, r12
    call memeq
    EPILOGUE
.Lfe_fail:
    xor eax, eax
    EPILOGUE

# run_edit(args cstr) -> 0
run_edit:
    PROLOGUE
    mov r12, rdi
    lea rdi, [rip + t_job]
    xor esi, esi
    mov edx, J_SIZE
    call memset
    lea rdi, [rip + t_out]
    call sb_clear
    lea rax, [rip + t_out]
    lea rcx, [rip + t_job]
    mov [rcx + J_out], rax
    mov [rcx + J_args], r12
    mov qword ptr [rcx + J_fd], -1
    mov dword ptr [rcx + J_state], JS_NEW
    lea rdi, [rip + .Ledit]
    call tools_find
    test rax, rax
    jz .Lre_fail
    lea rcx, [rip + t_job]
    mov [rcx + J_tool], rax
    mov rdi, rcx
    call [rax + TL_exec]
    xor eax, eax
    EPILOGUE
.Lre_fail:
    mov eax, 1
    EPILOGUE

FN opcode_main
    PROLOGUE
    call edit_write_tool_init

    # ---- case 1: two replacements ----
    lea rdi, [rip + .Lf1]
    lea rsi, [rip + .Lc1]
    mov edx, .Lc1e - .Lc1
    call write_file
    lea rdi, [rip + .La1]
    call run_edit
    lea rdi, [rip + .Lf1]
    lea rsi, [rip + .Lc1new]
    mov edx, .Lc1newe - .Lc1new
    call file_eq
    test eax, eax
    jz .Lfail
    lea rdi, [rip + t_out]
    lea rsi, [rip + .Lneed_repl]
    call sb_has
    test eax, eax
    jz .Lfail
    lea rdi, [rip + .Lok]
    call print_line

    # ---- case 2: CRLF preserved ----
    lea rdi, [rip + .Lf2]
    lea rsi, [rip + .Lc2]
    mov edx, .Lc2e - .Lc2
    call write_file
    lea rdi, [rip + .La2]
    call run_edit
    lea rdi, [rip + .Lf2]
    lea rsi, [rip + .Lc2new]
    mov edx, .Lc2newe - .Lc2new
    call file_eq
    test eax, eax
    jz .Lfail
    lea rdi, [rip + .Lok_crlf]
    call print_line

    # ---- case 3: BOM preserved ----
    lea rdi, [rip + .Lf3]
    lea rsi, [rip + .Lc3]
    mov edx, .Lc3e - .Lc3
    call write_file
    lea rdi, [rip + .La3]
    call run_edit
    lea rdi, [rip + .Lf3]
    lea rsi, [rip + .Lc3new]
    mov edx, .Lc3newe - .Lc3new
    call file_eq
    test eax, eax
    jz .Lfail
    lea rdi, [rip + .Lok_bom]
    call print_line

    # ---- case 4: non-unique oldText ----
    lea rdi, [rip + .Lf4]
    lea rsi, [rip + .Lc4]
    mov edx, .Lc4e - .Lc4
    call write_file
    lea rdi, [rip + .La4]
    call run_edit
    lea rdi, [rip + t_out]
    lea rsi, [rip + .Lneed_uniq]
    call sb_has
    test eax, eax
    jz .Lfail
    lea rdi, [rip + .Lok_uniq]
    call print_line

    # ---- case 5: overlapping edits ----
    lea rdi, [rip + .Lf5]
    lea rsi, [rip + .Lc5]
    mov edx, .Lc5e - .Lc5
    call write_file
    lea rdi, [rip + .La5]
    call run_edit
    lea rdi, [rip + t_out]
    lea rsi, [rip + .Lneed_ov]
    call sb_has
    test eax, eax
    jz .Lfail
    lea rdi, [rip + .Lok_ov]
    call print_line

    # ---- case 6: unified diff ----
    lea rdi, [rip + .Lf6]
    lea rsi, [rip + .Lc6]
    mov edx, .Lc6e - .Lc6
    call write_file
    lea rdi, [rip + .La6]
    call run_edit
    lea rdi, [rip + t_out]
    lea rsi, [rip + .Lneed_hunk]
    call sb_has
    test eax, eax
    jz .Lfail
    lea rdi, [rip + t_out]
    lea rsi, [rip + .Lneed_minus]
    call sb_has
    test eax, eax
    jz .Lfail
    lea rdi, [rip + t_out]
    lea rsi, [rip + .Lneed_plus]
    call sb_has
    test eax, eax
    jz .Lfail
    lea rdi, [rip + .Lok_diff]
    call print_line

    lea rdi, [rip + .Ldone]
    call print_line
    xor eax, eax
    EPILOGUE
.Lfail:
    lea rdi, [rip + .Lfail_msg]
    call print_line
    mov eax, 1
    EPILOGUE
