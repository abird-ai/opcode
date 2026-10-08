.include "opcode.inc"
.include "core/core.inc"
# core tool registry: static slot array (max 32) plus the VEC handed to the
# prompt/agent. Owned by the core; tool implementations register in tools_init.
# Contract: src/core/API.md.

.equ MAX_TOOLS, 32

# Shared atomic-write helpers (used by tools/edit.s and tools/write.s).
.equ O_PATH,        0x200000
.equ O_NOFOLLOW,    0x20000
.equ ELOOP,         40

# Schema-driven tool_validate: at most this many required fields per tool.
.equ MAX_TOOL_REQ,  8
# tv_type_code sentinel: JSON boolean (JT_TRUE or JT_FALSE both accepted).
.equ TV_BOOL,       7

.section .rodata
.Lread:        .asciz "read"
.Lbash:        .asciz "bash"
.Lpath:        .asciz "path"
.Lcommand:     .asciz "command"
.Lproperties:  .asciz "properties"
.Lrequired:    .asciz "required"
.Ltype:        .asciz "type"
.Lty_string:   .asciz "string"
.Lty_array:    .asciz "array"
.Lty_object:   .asciz "object"
.Lty_integer:  .asciz "integer"
.Lty_number:   .asciz "number"
.Lty_boolean:  .asciz "boolean"
.Ldotopcode:    .asciz ".opcode-"
.Ldotmp:       .asciz ".tmp"
.Lhex:         .asciz "0123456789abcdef"
.Ltr_head:     .asciz "\n[truncated: showing the first "
.Ltr_mid:      .asciz " lines. Use "
.Ltr_end:      .asciz " to continue.]"
.Ltail_marker: .asciz "\n[output truncated]"

.bss
.p2align 3
tools_reg: .zero 8 * MAX_TOOLS
n_tools:   .quad 0
tools_vec: .zero VEC_SIZE
tools_rand_counter: .quad 0

.text

# tools_init(): reset the registry and register the built-in tools.
FN tools_init
    PROLOGUE
    mov qword ptr [rip + n_tools], 0
    mov qword ptr [rip + tools_vec + VEC_len], 0
    call read_tool_init
    call bash_tool_init
    call edit_write_tool_init
    call search_tools_init
    xor eax, eax
    EPILOGUE

# tools_add(tl) -> 0 | -ENOSPC
FN tools_add
    PROLOGUE
    mov rbx, rdi
    mov rax, [rip + n_tools]
    cmp rax, MAX_TOOLS
    jae .Lta_nospc
    lea rcx, [rip + tools_reg]
    mov [rcx + rax*8], rbx
    inc qword ptr [rip + n_tools]
    lea rdi, [rip + tools_vec]
    mov esi, 8
    call vec_push
    mov [rax], rbx
    xor eax, eax
    EPILOGUE
.Lta_nospc:
    mov rax, -ENOSPC
    EPILOGUE

# tools_count() -> n
FN tools_count
    mov rax, [rip + n_tools]
    ret

# tools_at(i) -> TL* | 0
FN tools_at
    cmp rdi, [rip + n_tools]
    jae 1f
    lea rax, [rip + tools_reg]
    mov rax, [rax + rdi*8]
    ret
1:  xor eax, eax
    ret

# tools_find(name cstr) -> TL* | 0
FN tools_find
    PROLOGUE
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12, [rip + n_tools]
    jae 3f
    lea rax, [rip + tools_reg]
    mov r13, [rax + r12*8]
    mov rdi, [r13 + TL_name]
    call strlen
    mov rsi, rax                    # alen = strlen(TL_name)
    mov rdx, rbx                    # cstr = query
    mov rdi, [r13 + TL_name]
    call str_eq_cstr
    test eax, eax
    jnz 2f
    inc r12
    jmp 1b
2:  mov rax, r13
    EPILOGUE
3:  xor eax, eax
    EPILOGUE

# tools_active() -> VEC* of TL*
FN tools_active
    lea rax, [rip + tools_vec]
    ret

# tv_type_code(type JV*) -> JT_* | TV_BOOL | 0 (unknown/absent)
# Maps a JSON-schema "type" string to the JT_* code a matching value has.
# 0 means "do not type-check" (missing schema or an unrecognised/union type).
tv_type_code:
    PROLOGUE 0
    mov rbx, rdi
    test rbx, rbx
    jz .Lttc_none
    mov rdi, rbx
    lea rsi, [rip + .Lty_string]
    call json_is
    test eax, eax
    jnz .Lttc_str
    mov rdi, rbx
    lea rsi, [rip + .Lty_array]
    call json_is
    test eax, eax
    jnz .Lttc_arr
    mov rdi, rbx
    lea rsi, [rip + .Lty_object]
    call json_is
    test eax, eax
    jnz .Lttc_obj
    mov rdi, rbx
    lea rsi, [rip + .Lty_integer]
    call json_is
    test eax, eax
    jnz .Lttc_num
    mov rdi, rbx
    lea rsi, [rip + .Lty_number]
    call json_is
    test eax, eax
    jnz .Lttc_num
    mov rdi, rbx
    lea rsi, [rip + .Lty_boolean]
    call json_is
    test eax, eax
    jnz .Lttc_bool
.Lttc_none:
    xor eax, eax
    EPILOGUE
.Lttc_str:
    mov eax, JT_STR
    EPILOGUE
.Lttc_arr:
    mov eax, JT_ARR
    EPILOGUE
.Lttc_obj:
    mov eax, JT_OBJ
    EPILOGUE
.Lttc_num:
    mov eax, JT_NUM
    EPILOGUE
.Lttc_bool:
    mov eax, TV_BOOL
    EPILOGUE

# tool_validate(name cstr, args cstr) -> 0 | -EINVAL
# Registry/schema driven: find the tool, parse its TL_params schema and require
# every name in the schema's "required" array in args, checking the declared
# "properties" type for the common JSON types. A required field that is
# missing, null, or of the wrong type is -EINVAL. A new tool only needs a
# correct JSON schema, never a validator edit. An unknown tool, a tool with no
# params schema, or a malformed schema accepts any object (its exec reports).
FN tool_validate
    PROLOGUE 400
    mov rbx, rdi                    # name
    mov r12, rsi                    # args
    mov qword ptr [rsp], 0          # required count
    test r12, r12
    jz .Ltv_bad
    mov rdi, rbx
    call tools_find
    test rax, rax
    jz .Ltv_parse_args
    mov r13, rax                    # TL*
    mov rdi, [r13 + TL_params]
    test rdi, rdi
    jz .Ltv_parse_args
    call strlen
    mov rsi, rax
    mov rdi, [r13 + TL_params]
    call json_parse                 # resets the arena; schema only lives here
    test rax, rax
    jz .Ltv_parse_args
    mov r13, rax                    # schema object
    mov rdi, r13
    lea rsi, [rip + .Lproperties]
    call json_get
    mov r15, rax                    # properties | 0
    mov rdi, r13
    lea rsi, [rip + .Lrequired]
    call json_get
    test rax, rax
    jz .Ltv_parse_args
    cmp dword ptr [rax + JV_type], JT_ARR
    jne .Ltv_parse_args
    mov r13, rax                    # required array
    mov rdi, r13
    call json_len
    cmp rax, MAX_TOOL_REQ
    jbe 1f
    mov eax, MAX_TOOL_REQ
1:  mov [rsp], rax
    xor r14d, r14d
.Ltv_names:
    cmp r14, [rsp]
    jae .Ltv_parse_args
    mov rdi, r13
    mov esi, r14d
    call json_at
    test rax, rax
    jz .Ltv_names_fail
    cmp dword ptr [rax + JV_type], JT_STR
    jne .Ltv_names_fail
    mov rdi, rax
    call json_str                  # rax ptr, rdx len
    cmp rdx, 31
    jbe 2f
    mov edx, 31
2:  mov [rsp + 8], rdx
    mov rdi, r14
    imul rdi, rdi, 48
    lea rdi, [rsp + rdi + 16]
    mov rsi, rax
    call memcpy                    # copy name+NUL into the slot
    mov rdx, [rsp + 8]
    mov byte ptr [rax + rdx], 0
    xor eax, eax                   # expected type: presence-only default
    test r15, r15
    jz 3f
    mov rcx, r14
    imul rcx, rcx, 48
    lea rsi, [rsp + rcx + 16]      # name
    mov rdi, r15
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Ltype]
    call json_get
    mov rdi, rax
    call tv_type_code
3:  mov rcx, r14
    imul rcx, rcx, 48
    mov [rsp + rcx + 48], rax      # slot expected code
    inc r14
    jmp .Ltv_names
.Ltv_names_fail:
    mov qword ptr [rsp], 0         # unusable schema: skip validation

.Ltv_parse_args:
    mov rdi, r12
    call strlen
    mov rsi, rax
    mov rdi, r12
    call json_parse
    test rax, rax
    jz .Ltv_bad
    mov r13, rax
    cmp dword ptr [r13 + JV_type], JT_OBJ
    jne .Ltv_bad
    xor r14d, r14d
.Ltv_check:
    cmp r14, [rsp]
    jae .Ltv_ok
    mov rcx, r14
    imul rcx, rcx, 48
    lea rsi, [rsp + rcx + 16]      # field name
    mov rdi, r13
    call json_get
    test rax, rax
    jz .Ltv_bad
    mov rcx, r14
    imul rcx, rcx, 48
    mov rcx, [rsp + rcx + 48]      # expected code
    test rcx, rcx
    jz .Ltv_next
    cmp rcx, TV_BOOL
    je .Ltv_bool
    mov edx, [rax + JV_type]
    cmp edx, ecx
    jne .Ltv_bad
    jmp .Ltv_next
.Ltv_bool:
    mov edx, [rax + JV_type]
    cmp edx, JT_TRUE
    je .Ltv_next
    cmp edx, JT_FALSE
    jne .Ltv_bad
.Ltv_next:
    inc r14
    jmp .Ltv_check
.Ltv_ok:
    xor eax, eax
    EPILOGUE
.Ltv_bad:
    mov rax, -EINVAL
    EPILOGUE

# tool_err(job, msg): replace the result with a plain error and complete
FN tool_err
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, [rbx + J_out]
    call sb_clear
    mov rdi, [rbx + J_out]
    mov rsi, r12
    call sb_push_cstr
    mov rdi, rbx
    call tool_done
    xor eax, eax
    EPILOGUE

# tool_done(job): mark done once (idempotent)
FN tool_done
    cmp dword ptr [rdi + J_state], JS_DONE
    je 1f
    mov dword ptr [rdi + J_state], JS_DONE
1:  xor eax, eax
    ret

# tool_temp_path(path cstr) -> cstr (mem_alloc'd): "<path>.opcode-<8hex>.tmp".
# The random 8-hex suffix (os_random, clock+counter fallback) keeps the O_EXCL
# create from colliding with a stale/foreign temp file. Shared by edit/write.
FN tool_temp_path
    PROLOGUE 48
    mov [rsp], rdi
    call strlen
    mov [rsp + 8], rax              # path length
    add rax, 24                     # room for the suffix, ".tmp" and NUL
    mov rdi, rax
    call mem_alloc
    mov r12, rax
    mov rdi, r12
    mov rsi, [rsp]
    mov rdx, [rsp + 8]
    call memcpy
    mov rax, [rsp + 8]
    lea rdi, [r12 + rax]            # prefix dest
    lea rsi, [rip + .Ldotopcode]     # ".opcode-" (8 bytes)
    mov edx, 8
    call memcpy
    lea rdi, [rsp + 16]
    mov esi, 4
    call os_random
    test rax, rax
    jns .Lttp_rand
    # os_random failed: derive the 4 name bytes from the monotonic clock and a
    # per-process counter so the name is never built from uninitialised stack
    # (and two calls still differ).
    mov edi, CLOCK_MONOTONIC
    call os_now_ns
    add rax, [rip + tools_rand_counter]
    inc qword ptr [rip + tools_rand_counter]
    mov [rsp + 16], eax
.Lttp_rand:
    mov rax, [rsp + 8]
    lea rdi, [r12 + rax + 8]        # hex dest
    lea rsi, [rsp + 16]
    lea r8, [rip + .Lhex]
    xor ecx, ecx
.Lttp_hex:
    movzx eax, byte ptr [rsi + rcx]
    mov edx, eax
    shr eax, 4
    and edx, 15
    movzx r9d, byte ptr [r8 + rax]
    mov [rdi + rcx*2], r9b
    movzx r9d, byte ptr [r8 + rdx]
    mov [rdi + rcx*2 + 1], r9b
    inc ecx
    cmp ecx, 4
    jb .Lttp_hex
    mov rax, [rsp + 8]
    lea rdi, [r12 + rax + 16]       # ".tmp" dest
    lea rsi, [rip + .Ldotmp]
    mov edx, 4
    call memcpy
    mov rax, [rsp + 8]
    mov byte ptr [r12 + rax + 20], 0
    mov rax, r12
    EPILOGUE

# tool_write_atomic(path cstr, ptr, len) -> 0 | -errno; -ELOOP on a symlink.
# The temp file inherits the target's permission bits (fchmod, best effort on
# backends without the syscall) and a symlink is refused instead of being
# silently replaced by the rename. Shared by edit/write.
FN tool_write_atomic
    PROLOGUE 224
    mov [rsp], rdi                  # path
    mov [rsp + 8], rsi              # data ptr
    mov [rsp + 16], rdx             # data len
    mov qword ptr [rsp + 48], 0644  # mode for a brand-new file
    mov qword ptr [rsp + 56], 0     # have_mode
    # stat the named object through O_PATH|O_NOFOLLOW: the rename below must
    # not turn a symlink into a regular file, and the target's mode must be
    # carried over. Linux opens the link itself (st_mode S_IFLNK); Darwin
    # rejects O_NOFOLLOW with -ELOOP. Both are refused below.
    mov rdi, [rsp]
    mov esi, O_PATH | O_NOFOLLOW
    xor edx, edx
    call os_open
    test rax, rax
    jns 1f
    cmp rax, -ELOOP
    je .Ltwa_symlink
    jmp .Ltwa_create
1:  mov [rsp + 64], rax
    mov rdi, rax
    lea rsi, [rsp + 80]             # stat struct (144 B on x86-64)
    call os_fstat
    mov r12, rax
    mov edi, [rsp + 64]
    call os_close
    test r12, r12
    js .Ltwa_create
    mov eax, [rsp + 80 + 24]        # st_mode
    mov ecx, eax
    and ecx, 0xF000
    cmp ecx, 0xA000                 # S_IFLNK
    je .Ltwa_symlink
    and eax, 0xFFF
    mov [rsp + 48], rax
    mov qword ptr [rsp + 56], 1
.Ltwa_create:
    mov rdi, [rsp]
    call tool_temp_path
    mov [rsp + 24], rax
    mov rdi, rax
    mov esi, O_WRONLY | O_CREAT | O_EXCL
    mov edx, [rsp + 48]
    call os_open
    test rax, rax
    js .Ltwa_openfail
    mov [rsp + 32], rax
    mov edi, eax
    mov rsi, [rsp + 8]
    mov rdx, [rsp + 16]
    call write_all
    test rax, rax
    js .Ltwa_err_fd
    # copy the exact mode back: the O_CREAT above is still subject to umask
    cmp qword ptr [rsp + 56], 0
    je .Ltwa_nofchmod
    mov edi, [rsp + 32]
    mov rsi, [rsp + 48]
    call os_fchmod
    cmp rax, -ENOSYS                # shim without fchmod: keep the O_CREAT mode
    je .Ltwa_nofchmod
    test rax, rax
    js .Ltwa_err_fd
.Ltwa_nofchmod:
    mov edi, [rsp + 32]
    call os_fsync
    test rax, rax
    js .Ltwa_err_fd
    mov edi, [rsp + 32]
    call os_close
    mov qword ptr [rsp + 32], -1
    mov rdi, [rsp + 24]
    mov rsi, [rsp]
    call os_rename
    test rax, rax
    js .Ltwa_err_ren
    mov rdi, [rsp + 24]
    call mem_free
    xor eax, eax
    EPILOGUE
.Ltwa_symlink:
    mov rax, -ELOOP
    EPILOGUE
.Ltwa_err_fd:
    mov [rsp + 40], rax
    mov edi, [rsp + 32]
    call os_close
    jmp .Ltwa_unlink
.Ltwa_err_ren:
    mov [rsp + 40], rax
    jmp .Ltwa_unlink
.Ltwa_openfail:
    mov [rsp + 40], rax
    jmp .Ltwa_free
.Ltwa_unlink:
    mov rdi, [rsp + 24]
    call os_unlink
.Ltwa_free:
    mov rdi, [rsp + 24]
    call mem_free
    mov rax, [rsp + 40]
    EPILOGUE

# truncate_head(sb, max_lines, max_bytes, hint cstr)
# Keep the first max_lines complete lines / max_bytes, never a partial line,
# then append "\n[truncated: showing the first <max_lines> lines. Use <hint>
# to continue.]". The hint is the caller's continuation payload ("offset=N").
FN truncate_head
    PROLOGUE
    mov rbx, rdi                    # sb
    mov r12, rsi                    # max_lines
    mov r13, rdx                    # max_bytes
    mov r14, rcx                    # hint
    mov r15, [rbx + SB_len]
    test r15, r15
    jz .Lth_done
    mov rdi, [rbx + SB_ptr]
    # line cut: right after the max_lines-th newline
    test r12, r12
    jz .Lth_cut
    xor ecx, ecx
    xor r8d, r8d
.Lth_scan:
    cmp rcx, r15
    jae .Lth_nolines
    cmp byte ptr [rdi + rcx], 10
    jne 1f
    inc r8
    cmp r8, r12
    je .Lth_linecut
1:  inc rcx
    jmp .Lth_scan
.Lth_linecut:
    lea r9, [rcx + 1]
    jmp .Lth_min
.Lth_nolines:
    mov r9, r15
.Lth_min:
    # byte cut
    mov r10, r15
    cmp r15, r13
    jbe 2f
    mov r10, r13
2:  cmp r9, r10
    cmova r9, r10
    # snap back to the start of a line unless we are exactly at a boundary
    cmp r9, r15
    jae .Lth_done
    test r9, r9
    jz .Lth_cut
    cmp byte ptr [rdi + r9 - 1], 10
    je .Lth_cut
.Lth_back:
    dec r9
    jz .Lth_cut
    cmp byte ptr [rdi + r9 - 1], 10
    jne .Lth_back
.Lth_cut:
    # truncate at r9 and append the marker
    mov [rbx + SB_len], r9
    mov rax, [rbx + SB_ptr]
    mov byte ptr [rax + r9], 0
    mov rdi, rbx
    lea rsi, [rip + .Ltr_head]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, r12
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ltr_mid]
    call sb_push_cstr
    mov rdi, rbx
    mov rsi, r14
    call sb_push_cstr
    mov rdi, rbx
    lea rsi, [rip + .Ltr_end]
    call sb_push_cstr
.Lth_done:
    xor eax, eax
    EPILOGUE

# truncate_tail(sb, max_lines, max_bytes)
# Drop whole lines from the front until the tail fits both limits, then append
# "\n[output truncated]". Nothing is prepended; the remaining text starts at a
# line boundary.
FN truncate_tail
    PROLOGUE
    mov rbx, rdi                    # sb
    mov r12, rsi                    # max_lines
    mov r13, rdx                    # max_bytes
    mov r15, [rbx + SB_len]
    test r15, r15
    jz .Ltt_done
    mov rdi, [rbx + SB_ptr]
    # candidate start from the byte limit
    xor r9d, r9d
    cmp r15, r13
    jbe .Ltt_lines
    mov r9, r15
    sub r9, r13
    test r9, r9
    jz .Ltt_lines
    cmp byte ptr [rdi + r9 - 1], 10
    je .Ltt_lines
    # not on a boundary: prefer the next full line, else the previous one
    mov rcx, r9
1:  cmp rcx, r15
    jae 2f
    cmp byte ptr [rdi + rcx], 10
    je 3f
    inc rcx
    jmp 1b
3:  lea r9, [rcx + 1]
    jmp .Ltt_lines
2:  mov rcx, r9
4:  test rcx, rcx
    jz .Ltt_zero
    cmp byte ptr [rdi + rcx - 1], 10
    je 5f
    dec rcx
    jmp 4b
5:  mov r9, rcx
    jmp .Ltt_lines
.Ltt_zero:
    xor r9d, r9d
.Ltt_lines:
    # count the lines in [r9, len)
    xor ecx, ecx
    mov rax, r9
6:  cmp rax, r15
    jae 7f
    cmp byte ptr [rdi + rax], 10
    jne 8f
    inc rcx
8:  inc rax
    jmp 6b
7:  mov rax, rcx
    cmp byte ptr [rdi + r15 - 1], 10
    je 9f
    inc rax                         # last line has no trailing newline
9:  cmp rax, r12
    jbe .Ltt_move
    # too many lines: drop one from the front
10: cmp r9, r15
    jae .Ltt_move
    inc r9
    cmp byte ptr [rdi + r9 - 1], 10
    jne 10b
    dec rax
    jmp 9b
.Ltt_move:
    test r9, r9
    jz .Ltt_done
    mov r14, r15
    sub r14, r9
    mov rdi, [rbx + SB_ptr]
    mov rsi, rdi
    add rsi, r9
    mov rdx, r14
    call memmove
    mov [rbx + SB_len], r14
    mov rax, [rbx + SB_ptr]
    mov byte ptr [rax + r14], 0
    mov rdi, rbx
    lea rsi, [rip + .Ltail_marker]
    call sb_push_cstr
.Ltt_done:
    xor eax, eax
    EPILOGUE
