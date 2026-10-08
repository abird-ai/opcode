.include "opcode.inc"
.include "core/core.inc"
# tool_temp_test: the shared atomic-write temp naming and collision safety.
#
# tool_temp_path must return "<path>.opcode-<8 hex>.tmp" with a fresh suffix on
# every call.  A stale file literally named "<path>.opcode-" (the broken name an
# older build produced when it copied the trailing NUL of ".opcode-" before the
# hex digits) must not block an edit: the real create is O_EXCL on a suffixed
# name, so it can never collide with the bare prefix.
# Golden: tests/data/tool_temp_test.expected

.bss
.p2align 3
t_job:   .zero J_SIZE
t_out:   .zero SB_SIZE
readbuf: .zero 4096

.section .rodata
.Lpath:    .asciz "build/ttmp_x.tmp"
.Lopcode:   .asciz ".opcode-"
.Ltmp:     .asciz ".tmp"
.Ledit:    .asciz "edit"
.Ltarget:  .asciz "build/ttmp_edit.tmp"
.Lstale:   .asciz "build/ttmp_edit.tmp.opcode-"
.Lcontent: .ascii "alpha\n"
.Lcontent_end:
.Lnew:     .ascii "ALPHA\n"
.Lnew_end:
.Leditargs: .asciz "{\"path\":\"build/ttmp_edit.tmp\",\"edits\":[{\"oldText\":\"alpha\",\"newText\":\"ALPHA\"}]}"
.Lneed_edited: .asciz "edited "
.Lok_fmt:   .asciz "temp format ok\n"
.Lok_uniq:  .asciz "temp unique ok\n"
.Lok_stale: .asciz "temp stale-collision ok\n"
.Lfail:     .asciz "FAIL temp\n"
.Lfail_fmt: .asciz "FAIL temp format\n"
.Lfail_uniq:.asciz "FAIL temp unique\n"
.Lfail_stale_msg:.asciz "FAIL temp stale-collision\n"

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

# hex8_ok(ptr) -> 1 | 0
hex8_ok:
    xor ecx, ecx
.Lh8_loop:
    cmp ecx, 8
    jae .Lh8_yes
    movzx eax, byte ptr [rdi + rcx]
    cmp eax, '0'
    jb .Lh8_no
    cmp eax, '9'
    jbe .Lh8_next
    cmp eax, 'a'
    jb .Lh8_no
    cmp eax, 'f'
    ja .Lh8_no
.Lh8_next:
    inc ecx
    jmp .Lh8_loop
.Lh8_yes:
    mov eax, 1
    ret
.Lh8_no:
    xor eax, eax
    ret

# temp_ok(path) -> 1 | 0: the full "<path>.opcode-<hex8>.tmp" shape.
temp_ok:
    PROLOGUE
    mov r12, rdi
    mov rdi, r12
    call tool_temp_path
    mov r13, rax
    mov rdi, r12
    call strlen
    mov r14, rax                  # prefix length
    mov rdi, r13
    call strlen
    mov rcx, r14
    add rcx, 20
    cmp rax, rcx
    jne .Lto_no
    # prefix
    mov rdi, r13
    mov esi, r14d
    mov rdx, r12
    call str_eq_cstr
    test eax, eax
    jz .Lto_no
    # ".opcode-"
    lea rdi, [r13 + r14]
    mov esi, 8
    lea rdx, [rip + .Lopcode]
    call str_eq_cstr
    test eax, eax
    jz .Lto_no
    # hex8
    lea rdi, [r13 + r14 + 8]
    call hex8_ok
    test eax, eax
    jz .Lto_no
    # ".tmp"
    lea rdi, [r13 + r14 + 16]
    mov esi, 4
    lea rdx, [rip + .Ltmp]
    call str_eq_cstr
    test eax, eax
    jz .Lto_no
    # NUL terminator
    cmp byte ptr [r13 + r14 + 20], 0
    jne .Lto_no
    mov rdi, r13
    call mem_free
    mov eax, 1
    EPILOGUE
.Lto_no:
    mov rdi, r13
    call mem_free
    xor eax, eax
    EPILOGUE

# temp_uniq(path) -> 1 | 0: two calls differ in the 8 hex digits.
temp_uniq:
    PROLOGUE
    mov r12, rdi
    mov rdi, r12
    call tool_temp_path
    mov r13, rax
    mov rdi, r12
    call tool_temp_path
    mov r14, rax
    mov rdi, r12
    call strlen
    lea rdi, [r13 + rax + 7]
    lea rsi, [r14 + rax + 7]
    mov edx, 8
    call memeq
    mov r15d, eax
    mov rdi, r13
    call mem_free
    mov rdi, r14
    call mem_free
    xor eax, eax
    test r15d, r15d
    setz al
    EPILOGUE

# write_file(path, ptr, len) -> 0 | -errno
write_file:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov rdi, r12
    mov esi, O_WRONLY | O_CREAT | O_TRUNC
    mov edx, 0644
    call os_open
    test rax, rax
    js .Lwf_bad
    mov rbx, rax
    mov edi, ebx
    mov rsi, r13
    mov rdx, r14
    call write_all
    mov edi, ebx
    call os_close
    xor eax, eax
    EPILOGUE
.Lwf_bad:
    mov rax, -1
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
    js .Lfe_no
    mov [rsp + 16], rax
    mov edi, eax
    lea rsi, [rip + readbuf]
    mov edx, 4096
    call os_read
    mov r12, rax
    mov edi, [rsp + 16]
    call os_close
    test r12, r12
    js .Lfe_no
    cmp r12, [rsp + 8]
    jne .Lfe_no
    lea rdi, [rip + readbuf]
    mov rsi, [rsp]
    mov rdx, r12
    call memeq
    EPILOGUE
.Lfe_no:
    xor eax, eax
    EPILOGUE

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

# run_edit(args cstr) -> 0 | 1
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
    jz .Lre_bad
    lea rcx, [rip + t_job]
    mov [rcx + J_tool], rax
    mov rdi, rcx
    call [rax + TL_exec]
    xor eax, eax
    EPILOGUE
.Lre_bad:
    mov eax, 1
    EPILOGUE

FN opcode_main
    PROLOGUE
    call edit_write_tool_init

    # ---- name shape
    lea rdi, [rip + .Lpath]
    call temp_ok
    test eax, eax
    jz .Lfail_format
    lea rdi, [rip + .Lok_fmt]
    call print

    # ---- a fresh suffix per call
    lea rdi, [rip + .Lpath]
    call temp_uniq
    test eax, eax
    jz .Lfail_unique
    lea rdi, [rip + .Lok_uniq]
    call print

    # ---- stale bare-prefix temp must not block an edit
    lea rdi, [rip + .Ltarget]
    lea rsi, [rip + .Lcontent]
    mov edx, .Lcontent_end - .Lcontent
    call write_file
    test rax, rax
    js .Lfail_stale
    lea rdi, [rip + .Lstale]
    lea rsi, [rip + .Lcontent]
    mov edx, 1
    call write_file
    test rax, rax
    js .Lfail_stale
    lea rdi, [rip + .Leditargs]
    call run_edit
    test eax, eax
    jnz .Lfail_stale
    lea rdi, [rip + .Ltarget]
    lea rsi, [rip + .Lnew]
    mov edx, .Lnew_end - .Lnew
    call file_eq
    cmp eax, 1
    jne .Lfail_stale
    lea rdi, [rip + t_out]
    lea rsi, [rip + .Lneed_edited]
    call sb_has
    test eax, eax
    jz .Lfail_stale
    lea rdi, [rip + .Lok_stale]
    call print

    xor eax, eax
    EPILOGUE
.Lfail_format:
    lea rdi, [rip + .Lfail_fmt]
    call print
    mov eax, 1
    EPILOGUE
.Lfail_unique:
    lea rdi, [rip + .Lfail_uniq]
    call print
    mov eax, 1
    EPILOGUE
.Lfail_stale:
    lea rdi, [rip + .Lfail_stale_msg]
    call print
    mov eax, 1
    EPILOGUE
