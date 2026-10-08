.include "opcode.inc"
.include "core/core.inc"
# write tool: {path, content}. Parent directories are created recursively and
# the file is replaced atomically (temp file in the same directory + rename),
# with no BOM/EOL translation. Contract: src/core/API.md.

# tool_write_atomic returns -ELOOP when the named object is a symlink.
.equ ELOOP, 40

.section .rodata
.Lname:   .asciz "write"
.Llabel:  .asciz "write"
.Ldesc:   .asciz "Write a file, creating parent directories. The replacement is atomic and does not translate line endings."
.Lparams: .asciz "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"File path to write\"},\"content\":{\"type\":\"string\",\"description\":\"Full file content\"}},\"required\":[\"path\",\"content\"]}"
.Lpath:    .asciz "path"
.Lcontent: .asciz "content"
.Lwrote:   .asciz "wrote "
.Lopen:    .asciz " ("
.Lbytes:   .asciz " bytes)"
.Lnl:      .asciz "\n"
.Lerr_args:  .asciz "error: invalid arguments"
.Lerr_write: .asciz "error: cannot write "
.Lerr_symlink: .asciz "error: refusing to replace symlink "

.section .data
.p2align 3
write_tl:
    .quad .Lname
    .quad .Llabel
    .quad .Ldesc
    .quad .Lparams
    .long TL_DESTRUCTIVE
    .long 0
    .quad write_exec
    .quad 0

.section .bss
.p2align 3

.text

# write_tool_init() -> 0 | -ENOSPC
FN write_tool_init
    lea rdi, [rip + write_tl]
    jmp tools_add

# edit_write_tool_init() -> 0 | -ENOSPC
# Registers edit and write; the integrator adds this call to tools_init().
FN edit_write_tool_init
    PROLOGUE
    call edit_tool_init
    test eax, eax
    js 1f
    call write_tool_init
1:  EPILOGUE

# wr_fail(job, msg, path) -> 0: error result + tool_done
wr_fail:
    PROLOGUE 16
    mov rbx, rdi
    mov [rsp], rsi
    mov r12, rdx
    mov rdi, [rbx + J_out]
    call sb_clear
    mov rdi, [rbx + J_out]
    mov rsi, [rsp]
    call sb_push_cstr
    test r12, r12
    jz 1f
    mov rdi, [rbx + J_out]
    mov rsi, r12
    call sb_push_cstr
1:  mov rdi, rbx
    call tool_done
    xor eax, eax
    EPILOGUE

# wr_write_atomic is the shared tool_write_atomic (src/core/tools.s).

# local frame
.equ W_JOB,     0
.equ W_PATH,    8
.equ W_CONTENT, 16
.equ W_CLEN,    24

# write_exec(job) -> 0
FN write_exec
    PROLOGUE 64
    mov [rsp + W_JOB], rdi
    mov qword ptr [rsp + W_PATH], 0
    mov qword ptr [rsp + W_CONTENT], 0
    mov qword ptr [rsp + W_CLEN], 0
    # ---- parse args ----
    mov rdi, [rdi + J_args]
    test rdi, rdi
    jz .Lwe_badargs
    call strlen
    mov rsi, rax
    mov rdi, [rsp + W_JOB]
    mov rdi, [rdi + J_args]
    call json_parse
    test rax, rax
    jz .Lwe_badargs
    mov r12, rax
    mov rdi, r12
    lea rsi, [rip + .Lpath]
    call json_get_cstr
    test rax, rax
    jz .Lwe_badargs
    mov [rsp + W_PATH], rax
    mov rdi, r12
    lea rsi, [rip + .Lcontent]
    call json_get
    test rax, rax
    jz .Lwe_badargs
    cmp dword ptr [rax + JV_type], JT_STR
    jne .Lwe_badargs
    mov rdi, rax
    call json_str
    mov [rsp + W_CONTENT], rax
    mov [rsp + W_CLEN], rdx
    # ---- create parent directories ----
    mov r12, [rsp + W_PATH]
    xor r13d, r13d
.Lwe_mkdir:
    movzx eax, byte ptr [r12 + r13]
    test al, al
    jz .Lwe_write
    cmp al, '/'
    jne .Lwe_mknext
    test r13, r13
    jz .Lwe_mknext
    mov byte ptr [r12 + r13], 0
    mov rdi, r12
    mov esi, 0755
    call os_mkdir
    mov byte ptr [r12 + r13], '/'
    cmp rax, -EEXIST
    je .Lwe_mknext
    test rax, rax
    js .Lwe_writeerr
.Lwe_mknext:
    inc r13
    jmp .Lwe_mkdir
.Lwe_write:
    # ---- atomic replace ----
    mov rdi, [rsp + W_PATH]
    mov rsi, [rsp + W_CONTENT]
    mov rdx, [rsp + W_CLEN]
    call tool_write_atomic
    test rax, rax
    js .Lwe_writeerr
    # ---- result ----
    mov rbx, [rsp + W_JOB]
    mov rdi, [rbx + J_out]
    call sb_clear
    mov rdi, [rbx + J_out]
    lea rsi, [rip + .Lwrote]
    call sb_push_cstr
    mov rdi, [rbx + J_out]
    mov rsi, [rsp + W_PATH]
    call sb_push_cstr
    mov rdi, [rbx + J_out]
    lea rsi, [rip + .Lopen]
    call sb_push_cstr
    mov rdi, [rbx + J_out]
    mov rsi, [rsp + W_CLEN]
    call sb_push_u64
    mov rdi, [rbx + J_out]
    lea rsi, [rip + .Lbytes]
    call sb_push_cstr
    mov rdi, [rbx + J_out]
    lea rsi, [rip + .Lnl]
    call sb_push_cstr
    mov rdi, rbx
    call tool_done
    xor eax, eax
    EPILOGUE
.Lwe_writeerr:
    cmp rax, -ELOOP
    je .Lwe_symlink
    mov rdi, [rsp + W_JOB]
    lea rsi, [rip + .Lerr_write]
    mov rdx, [rsp + W_PATH]
    call wr_fail
    xor eax, eax
    EPILOGUE
.Lwe_symlink:
    mov rdi, [rsp + W_JOB]
    lea rsi, [rip + .Lerr_symlink]
    mov rdx, [rsp + W_PATH]
    call wr_fail
    xor eax, eax
    EPILOGUE
.Lwe_badargs:
    mov rdi, [rsp + W_JOB]
    lea rsi, [rip + .Lerr_args]
    xor edx, edx
    call wr_fail
    xor eax, eax
    EPILOGUE
