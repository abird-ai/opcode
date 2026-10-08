.include "opcode.inc"
.include "core/core.inc"
# read tool: numbered lines with offset/limit, head truncation at 2000 lines /
# 50 KB. Contract: src/core/API.md.

.equ READ_DEFAULT_LIMIT, 2000
.equ READ_MAX_BYTES,     51200
# Hard cap on how much of a file is slurped before line/byte truncation. Keeps
# a multi-GB file from becoming a multi-GB allocation; the output cap is far
# below this, so normal reads are unaffected.
.equ READ_SLURP_MAX,     (8 * 1024 * 1024)
.equ READ_CHUNK,         65536
.equ READ_SNIFF,         8192

.section .rodata
.Lname:    .asciz "read"
.Llabel:   .asciz "read"
.Ldesc:    .asciz "Read a text file with numbered lines. Returns up to 2000 lines or 50 KiB; use offset and limit to page through large files."
.Lparams:  .asciz "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"File path to read\"},\"offset\":{\"type\":\"integer\",\"description\":\"Zero-based line offset\"},\"limit\":{\"type\":\"integer\",\"description\":\"Maximum lines to return\"}},\"required\":[\"path\"]}"
.Lpath:    .asciz "path"
.Loffset:  .asciz "offset"
.Llimit:   .asciz "limit"
.Lerr_word: .asciz "error: "
.Lerr_open: .asciz "error: cannot open "
.Lerr_read: .asciz "error: cannot read "
.Lerr_slurp: .asciz "\n[file truncated at 8 MiB; page with a smaller offset]\n"
.Lerr_errno: .asciz " (errno "
.Lrparen:  .asciz ")"
.Lbinary:  .asciz " looks binary"
.Lbadargs: .asciz "error: invalid arguments"

.section .data
.p2align 3
read_tl:
    .quad .Lname
    .quad .Llabel
    .quad .Ldesc
    .quad .Lparams
    .long TL_READONLY | TL_SEQUENTIAL
    .long 0
    .quad read_exec
    .quad 0

.text

# read_tool_init() -> 0 | -ENOSPC
FN read_tool_init
    lea rdi, [rip + read_tl]
    jmp tools_add

# emit_lines(out SB*, data, len, offset, limit) -> kept line count
# Writes "<line_no>\t<line>\n" for the requested window. Line numbers are
# 1-based positions in the original file.
emit_lines:
    PROLOGUE 32
    mov rbx, rdi                    # out
    mov r12, rsi                    # data
    mov r13, rdx                    # len
    mov r14, rcx                    # offset
    mov r15, r8                     # limit
    mov qword ptr [rsp], 0          # pos
    mov qword ptr [rsp + 8], 1      # line_no
    mov qword ptr [rsp + 16], 0     # kept
.Lel_loop:
    mov r10, [rsp]
    cmp r10, r13
    jae .Lel_done
    mov rax, [rsp + 16]
    cmp rax, r15
    jae .Lel_done
    mov rcx, r10
.Lel_scan:
    cmp rcx, r13
    jae .Lel_eol
    cmp byte ptr [r12 + rcx], 10
    je .Lel_eol
    inc rcx
    jmp .Lel_scan
.Lel_eol:
    mov [rsp + 24], rcx             # end of the line content
    mov rax, [rsp + 8]
    cmp rax, r14
    jbe .Lel_skip
    mov rdi, rbx
    mov rsi, rax
    call sb_push_u64
    mov rdi, rbx
    mov esi, 9
    call sb_push_byte
    mov rdi, rbx
    mov rsi, r12
    add rsi, [rsp]
    mov rdx, [rsp + 24]
    sub rdx, [rsp]
    call sb_push
    mov rdi, rbx
    mov esi, 10
    call sb_push_byte
    inc qword ptr [rsp + 16]
.Lel_skip:
    mov rcx, [rsp + 24]
    lea rax, [rcx + 1]
    mov [rsp], rax
    inc qword ptr [rsp + 8]
    jmp .Lel_loop
.Lel_done:
    mov rax, [rsp + 16]
    EPILOGUE

# kept_lines(data, len, cap_lines, max_bytes) -> complete lines left after
# truncate_head's cut. Used to build a continuation hint that matches exactly
# what truncate_head keeps (including the byte cap and line-aligned snap).
kept_lines:
    # line cut: right after the cap_lines-th newline (len if there are fewer)
    mov r8, rsi
    test rdx, rdx
    jz .Lkl_lzero
    xor r9d, r9d
    xor r10d, r10d
.Lkl_lscan:
    cmp r9, rsi
    jae .Lkl_byte
    cmp byte ptr [rdi + r9], 10
    jne 1f
    inc r10
    cmp r10, rdx
    je .Lkl_lcut
1:  inc r9
    jmp .Lkl_lscan
.Lkl_lcut:
    lea r8, [r9 + 1]
    jmp .Lkl_byte
.Lkl_lzero:
    xor r8d, r8d
.Lkl_byte:
    mov r9, rsi
    cmp rsi, rcx
    jbe 2f
    mov r9, rcx
2:  cmp r8, r9
    cmova r8, r9
    # snap back to a line boundary unless the whole buffer is kept
    cmp r8, rsi
    jae .Lkl_count
    test r8, r8
    jz .Lkl_count
    cmp byte ptr [rdi + r8 - 1], 10
    je .Lkl_count
3:  dec r8
    jz .Lkl_count
    cmp byte ptr [rdi + r8 - 1], 10
    jne 3b
.Lkl_count:
    xor eax, eax
    xor r9d, r9d
4:  cmp r9, r8
    jae 5f
    cmp byte ptr [rdi + r9], 10
    jne 6f
    inc rax
6:  inc r9
    jmp 4b
5:  cmp r8, rsi
    jne 7f
    test r8, r8
    jz 7f
    cmp byte ptr [rdi + r8 - 1], 10
    je 7f
    inc rax                         # final line without a trailing newline
7:  ret

# read_exec(job) -> 0
FN read_exec
    PROLOGUE 80
    mov rbx, rdi                    # job
    mov qword ptr [rsp + 72], 0     # slurp-cap hit flag
    # ---- args ----
    mov rdi, [rbx + J_args]
    test rdi, rdi
    jz .Lre_badargs
    call strlen
    mov rsi, rax
    mov rdi, [rbx + J_args]
    call json_parse
    test rax, rax
    jz .Lre_badargs
    mov r13, rax
    mov rdi, r13
    lea rsi, [rip + .Lpath]
    call json_get_cstr
    test rax, rax
    jz .Lre_badargs
    mov r14, rax                    # path
    mov rdi, r13
    lea rsi, [rip + .Loffset]
    xor edx, edx
    call json_get_u64
    mov r15, rax                    # offset (lines)
    mov rdi, r13
    lea rsi, [rip + .Llimit]
    mov edx, READ_DEFAULT_LIMIT
    call json_get_u64
    test rax, rax                    # 0 or absent means the 2000-line default
    jnz 1f
    mov eax, READ_DEFAULT_LIMIT
1:  mov ecx, READ_DEFAULT_LIMIT
    cmp rax, rcx
    cmova rax, rcx                   # cap = min(limit, 2000)
    mov [rsp + 8], rax
    # ---- open ----
    mov rdi, r14
    xor esi, esi                    # O_RDONLY
    xor edx, edx
    call os_open
    test rax, rax
    js .Lre_openerr
    mov [rsp + 48], rax             # fd
    # ---- slurp (O(n) in the file size; cap only bounds the output) ----
    mov edi, SB_SIZE
    call mem_alloc
    mov r12, rax                    # raw SB
    mov edi, READ_CHUNK
    call mem_alloc
    mov [rsp + 56], rax             # chunk
.Lre_read:
    mov rax, [r12 + SB_len]
    cmp rax, READ_SLURP_MAX
    jae .Lre_capped                  # bounded slurp (see READ_SLURP_MAX)
    mov edi, [rsp + 48]
    mov rsi, [rsp + 56]
    mov edx, READ_CHUNK
    call os_read
    test rax, rax
    js .Lre_readerr
    jz .Lre_readdone
    mov rdi, r12
    mov rsi, [rsp + 56]
    mov rdx, rax
    call sb_push
    jmp .Lre_read
.Lre_capped:
    mov qword ptr [rsp + 72], 1
    jmp .Lre_readdone
.Lre_readerr:
    cmp rax, -EINTR                  # a signal interrupted the slurp: retry
    je .Lre_read
    mov [rsp + 64], rax
    mov edi, [rsp + 48]
    call os_close
    mov rdi, [rbx + J_out]
    call sb_clear
    mov rdi, [rbx + J_out]
    lea rsi, [rip + .Lerr_read]
    call sb_push_cstr
    mov rdi, [rbx + J_out]
    mov rsi, r14
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rsp + 64]
    call emit_errno
    mov rdi, rbx
    call tool_done
    jmp .Lre_cleanup
.Lre_readdone:
    mov edi, [rsp + 48]
    call os_close
    # ---- binary sniff over the first 8 KiB ----
    mov rdi, [r12 + SB_ptr]
    mov rsi, [r12 + SB_len]
    cmp rsi, READ_SNIFF
    jbe 1f
    mov esi, READ_SNIFF
1:  test rdi, rdi
    jz .Lre_text
    xor ecx, ecx
2:  cmp rcx, rsi
    jae .Lre_text
    cmp byte ptr [rdi + rcx], 0
    je .Lre_binary
    inc rcx
    jmp 2b
.Lre_binary:
    mov rdi, [rbx + J_out]
    call sb_clear
    mov rdi, [rbx + J_out]
    lea rsi, [rip + .Lerr_word]
    call sb_push_cstr
    mov rdi, [rbx + J_out]
    mov rsi, r14
    call sb_push_cstr
    mov rdi, [rbx + J_out]
    lea rsi, [rip + .Lbinary]
    call sb_push_cstr
    mov rdi, rbx
    call tool_done
    jmp .Lre_cleanup
    # ---- numbered lines; one extra line is used to detect truncation ----
.Lre_text:
    mov rdi, [rbx + J_out]
    call sb_clear
    mov rdi, [rbx + J_out]
    mov rsi, [r12 + SB_ptr]
    mov rdx, [r12 + SB_len]
    mov rcx, r15
    mov r8, [rsp + 8]
    inc r8                          # peek past the cap
    call emit_lines
    # continuation hint: the next page starts at offset + lines kept, computed
    # over the emitted (numbered) text so it matches the truncate_head cut
    mov rax, [rbx + J_out]
    mov rdi, [rax + SB_ptr]
    mov rsi, [rax + SB_len]
    mov rdx, [rsp + 8]
    mov ecx, READ_MAX_BYTES
    call kept_lines
    add rax, r15                     # next page = offset + lines kept
    mov rsi, rax
    lea rdi, [rsp + 16]
    mov byte ptr [rdi], 'o'
    mov byte ptr [rdi + 1], 'f'
    mov byte ptr [rdi + 2], 'f'
    mov byte ptr [rdi + 3], 's'
    mov byte ptr [rdi + 4], 'e'
    mov byte ptr [rdi + 5], 't'
    mov byte ptr [rdi + 6], '='
    add rdi, 7
    call fmt_u64
    lea rdi, [rsp + 16]
    add rdi, 7
    add rdi, rax
    mov byte ptr [rdi], 0
    mov rdi, [rbx + J_out]
    mov rsi, [rsp + 8]
    mov edx, READ_MAX_BYTES
    lea rcx, [rsp + 16]
    call truncate_head
    cmp qword ptr [rsp + 72], 0
    je 9f
    mov rdi, [rbx + J_out]
    lea rsi, [rip + .Lerr_slurp]
    call sb_push_cstr
9:  mov rdi, rbx
    call tool_done
    jmp .Lre_cleanup

.Lre_openerr:
    mov [rsp + 64], rax
    mov rdi, [rbx + J_out]
    call sb_clear
    mov rdi, [rbx + J_out]
    lea rsi, [rip + .Lerr_open]
    call sb_push_cstr
    mov rdi, [rbx + J_out]
    mov rsi, r14
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, [rsp + 64]
    call emit_errno
    mov rdi, rbx
    call tool_done
    xor eax, eax
    EPILOGUE

.Lre_badargs:
    mov rdi, rbx
    lea rsi, [rip + .Lbadargs]
    call tool_err
    xor eax, eax
    EPILOGUE

.Lre_cleanup:
    mov rdi, [rsp + 56]
    call mem_free
    mov rdi, r12
    call sb_free
    mov rdi, r12
    call mem_free
    xor eax, eax
    EPILOGUE

# emit_errno(job, err): append " (errno -N)"
emit_errno:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, [rbx + J_out]
    lea rsi, [rip + .Lerr_errno]
    call sb_push_cstr
    mov rax, r12
    test rax, rax
    jns 1f
    mov rdi, [rbx + J_out]
    mov esi, '-'
    call sb_push_byte
    neg rax
1:  mov rdi, [rbx + J_out]
    mov rsi, rax
    call sb_push_u64
    mov rdi, [rbx + J_out]
    lea rsi, [rip + .Lrparen]
    call sb_push_cstr
    EPILOGUE
