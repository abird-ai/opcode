.include "opcode.inc"
.include "core/core.inc"
# search tools integration test: creates a small tree under build/search_tree,
# runs ls, find and grep, and checks deterministic results.
# Golden output: tests/data/search_test.expected

.bss
.p2align 3
t_job: .zero J_SIZE
t_out: .zero SB_SIZE

.section .rodata
.Lnl:        .asciz "\n"
.Lfail_msg:  .asciz "FAIL: search_test"
.Lok_ls:     .asciz "ls ok"
.Lok_find:   .asciz "find ok"
.Lok_grep:   .asciz "grep ok"
.Ldone:      .asciz "search done"

.Ltool_ls:   .asciz "ls"
.Ltool_find: .asciz "find"
.Ltool_grep: .asciz "grep"

.Ldir:       .asciz "build"
.Ldir_st:    .asciz "build/search_tree"
.Ldir_sub:   .asciz "build/search_tree/sub"

.Lfa:        .asciz "build/search_tree/a.txt"
.Lca:        .ascii "hello world\nsecond line\n"
.Lca_end:
.Lfb:        .asciz "build/search_tree/b.txt"
.Lcb:        .ascii "HELLO\nthird line\n"
.Lcb_end:
.Lfc:        .asciz "build/search_tree/sub/c.txt"
.Lcc:        .ascii "hello from sub\n"
.Lcc_end:
.Lfd:        .asciz "build/search_tree/sub/d.bin"
.Lcd:        .ascii "hello\0binary\n"
.Lcd_end:

.Largs_ls:     .asciz "{\"path\":\"build/search_tree\"}"
.Largs_find:   .asciz "{\"pattern\":\"*.txt\",\"path\":\"build/search_tree\"}"
.Largs_grep:   .asciz "{\"pattern\":\"hello\",\"path\":\"build/search_tree\"}"
.Largs_grepdot: .asciz "{\"pattern\":\"hello.\",\"path\":\"build/search_tree\"}"
.Largs_icase:  .asciz "{\"pattern\":\"hello\",\"path\":\"build/search_tree\",\"ignore_case\":true}"
.Largs_lit:    .asciz "{\"pattern\":\"hello.\",\"path\":\"build/search_tree\",\"literal\":true}"

.Lexp_ls:   .ascii "build/search_tree:\na.txt\nb.txt\nsub/\n"
.Lexp_ls_end:
.Lexp_find: .ascii "build/search_tree/a.txt\nbuild/search_tree/b.txt\nbuild/search_tree/sub/c.txt\n"
.Lexp_find_end:
.Lexp_grep: .ascii "build/search_tree/a.txt:1:hello world\nbuild/search_tree/sub/c.txt:1:hello from sub\n"
.Lexp_grep_end:

.Lneed_icase: .asciz "build/search_tree/b.txt:1:HELLO"
.Lneed_dot:   .asciz "build/search_tree/a.txt:1:hello world"

.text

# print_line(cstr)
print_line:
    push rbx
    push r12
    sub rsp, 8
    mov rbx, rdi
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

# sb_eq(sb, ptr, len) -> 1 | 0
sb_eq:
    mov rax, [rdi + SB_len]
    cmp rax, rdx
    jne 1f
    test rdx, rdx
    jz 2f
    mov rdi, [rdi + SB_ptr]
    test rdi, rdi
    jz 1f
    jmp memeq
1:  xor eax, eax
    ret
2:  mov eax, 1
    ret

# make_dir(path): mkdir, ignoring EEXIST
make_dir:
    push rbx
    sub rsp, 16
    mov rdi, rdi
    mov esi, 0755
    call os_mkdir
    cmp rax, -EEXIST
    je 1f
    test rax, rax
1:  add rsp, 16
    pop rbx
    ret

# write_file(path, ptr, len) -> 0 | -errno
write_file:
    PROLOGUE 16
    mov [rsp], rdi
    mov r12, rsi
    mov r13, rdx
    mov esi, O_WRONLY | O_CREAT | O_TRUNC
    mov edx, 0644
    call os_open
    test rax, rax
    js .Lwf_out
    mov rbx, rax
    mov edi, ebx
    mov rsi, r12
    mov rdx, r13
    call write_all
    mov r12, rax
    mov edi, ebx
    call os_close
    mov rax, r12
.Lwf_out:
    EPILOGUE

# run_tool(name cstr, args cstr): fills t_job / t_out
run_tool:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
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
    mov rdi, rbx
    call tools_find
    lea rcx, [rip + t_job]
    mov [rcx + J_tool], rax
    mov rdi, rcx
    call [rax + TL_exec]
    EPILOGUE

FN opcode_main
    PROLOGUE 16
    call search_tools_init
    test eax, eax
    js .Lfail
    call tools_count
    cmp rax, 3
    jne .Lfail
    # ---- tree ----
    lea rdi, [rip + .Ldir]
    call make_dir
    lea rdi, [rip + .Ldir_st]
    call make_dir
    lea rdi, [rip + .Ldir_sub]
    call make_dir
    lea rdi, [rip + .Lfa]
    lea rsi, [rip + .Lca]
    mov edx, .Lca_end - .Lca
    call write_file
    test rax, rax
    js .Lfail
    lea rdi, [rip + .Lfb]
    lea rsi, [rip + .Lcb]
    mov edx, .Lcb_end - .Lcb
    call write_file
    test rax, rax
    js .Lfail
    lea rdi, [rip + .Lfc]
    lea rsi, [rip + .Lcc]
    mov edx, .Lcc_end - .Lcc
    call write_file
    test rax, rax
    js .Lfail
    lea rdi, [rip + .Lfd]
    lea rsi, [rip + .Lcd]
    mov edx, .Lcd_end - .Lcd
    call write_file
    test rax, rax
    js .Lfail

    # ---- ls ----
    lea rdi, [rip + .Ltool_ls]
    lea rsi, [rip + .Largs_ls]
    call run_tool
    lea rdi, [rip + t_out]
    lea rsi, [rip + .Lexp_ls]
    mov edx, .Lexp_ls_end - .Lexp_ls
    call sb_eq
    test eax, eax
    jz .Lfail
    lea rdi, [rip + .Lok_ls]
    call print_line

    # ---- find ----
    lea rdi, [rip + .Ltool_find]
    lea rsi, [rip + .Largs_find]
    call run_tool
    lea rdi, [rip + t_out]
    lea rsi, [rip + .Lexp_find]
    mov edx, .Lexp_find_end - .Lexp_find
    call sb_eq
    test eax, eax
    jz .Lfail
    lea rdi, [rip + .Lok_find]
    call print_line

    # ---- grep (case-sensitive regex, binary skipped) ----
    lea rdi, [rip + .Ltool_grep]
    lea rsi, [rip + .Largs_grep]
    call run_tool
    lea rdi, [rip + t_out]
    lea rsi, [rip + .Lexp_grep]
    mov edx, .Lexp_grep_end - .Lexp_grep
    call sb_eq
    test eax, eax
    jz .Lfail
    # regex '.' matches a space: a.txt:1
    lea rdi, [rip + .Ltool_grep]
    lea rsi, [rip + .Largs_grepdot]
    call run_tool
    lea rdi, [rip + t_out]
    lea rsi, [rip + .Lneed_dot]
    call sb_has
    test eax, eax
    jz .Lfail
    # ignore_case picks up the uppercase match
    lea rdi, [rip + .Ltool_grep]
    lea rsi, [rip + .Largs_icase]
    call run_tool
    lea rdi, [rip + t_out]
    lea rsi, [rip + .Lneed_icase]
    call sb_has
    test eax, eax
    jz .Lfail
    # literal 'hello.' matches nothing
    lea rdi, [rip + .Ltool_grep]
    lea rsi, [rip + .Largs_lit]
    call run_tool
    cmp qword ptr [rip + t_out + SB_len], 0
    jne .Lfail
    lea rdi, [rip + .Lok_grep]
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
