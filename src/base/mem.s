.include "opcode.inc"
# opcode base: allocator, growable byte buffer (SB) and vector (VEC).
# adapted from rhun (MIT), see THIRD_PARTY.md
#
# Every block has a 16-byte header:
#   [0] class index (< 64) for small blocks, or mapping size (>= 4096) for large
#   [8] requested size
# Small classes are 32 B .. 64 KiB (12 power-of-two classes) carved from 1 MiB
# chunks obtained through os_map; each class keeps a LIFO free list. Large blocks
# get their own mapping and are released with os_unmap.

.equ MEM_LARGE_MAX, 1 << 40

.bss
.p2align 3
free_lists: .zero 8 * MEM_CLASSES
chunk_ptr:  .quad 0
chunk_end:  .quad 0
.globl g_mem_live
g_mem_live: .quad 0

.text

# mem_alloc(size) -> zeroed ptr (dies on OOM)
FN mem_alloc
    mov rax, MEM_LARGE_MAX
    cmp rdi, rax
    jae .Lma_die
    PROLOGUE 0
    mov r12, rdi                # requested size
    lea rbx, [rdi + 16]         # total with header
    cmp rbx, MEM_MAXSMALL
    ja .Lma_large
    # class = ceil(log2(total)) - 5
    lea rax, [rbx - 1]
    or rax, 31
    bsr rcx, rax
    inc ecx
    sub ecx, 5
    mov r13d, ecx
    # pop the per-class free list
    lea rdx, [rip + free_lists]
    mov rax, [rdx + rcx*8]
    test rax, rax
    jz .Lma_bump
    mov r8, [rax + 16]          # next free lives in the payload
    mov [rdx + rcx*8], r8
    jmp .Lma_init
.Lma_bump:
    mov ebx, 32
    shl rbx, cl                 # power-of-two block size
    mov rax, [rip + chunk_ptr]
    lea r8, [rax + rbx]
    cmp r8, [rip + chunk_end]
    jbe .Lma_take
    mov edi, MEM_CHUNK
    call os_map
    mov [rip + chunk_ptr], rax
    lea r8, [rax + MEM_CHUNK]
    mov [rip + chunk_end], r8
    lea r8, [rax + rbx]
.Lma_take:
    mov [rip + chunk_ptr], r8
.Lma_init:
    mov [rax], r13
    mov [rax + 8], r12
    mov r8, rax
    lea rdi, [rax + 16]
    mov ecx, r13d
    mov edx, 32
    shl rdx, cl
    lea rcx, [rdx - 16]
    xor eax, eax
    rep stosb                   # return zeroed payloads, even after free/reuse
    lea rax, [r8 + 16]
    inc qword ptr [rip + g_mem_live]
    EPILOGUE
.Lma_large:
    add rbx, 4095
    and rbx, -4096
    mov rdi, rbx
    call os_map                 # anonymous mappings are zeroed
    mov [rax], rbx
    mov [rax + 8], r12
    add rax, 16
    inc qword ptr [rip + g_mem_live]
    EPILOGUE
.Lma_die:
    lea rdi, [rip + .Loom]
    jmp die

# mem_alloc_try(size) -> ptr | 0 (small sizes still die on OOM, large ones return 0)
FN mem_alloc_try
    mov rax, MEM_LARGE_MAX
    cmp rdi, rax
    jae .Lmt_zero
    lea rax, [rdi + 16]
    cmp rax, MEM_MAXSMALL
    jbe mem_alloc
    PROLOGUE 0
    mov r12, rdi
    lea rbx, [rdi + 16 + 4095]
    and rbx, -4096
    mov rdi, rbx
    call os_map_try
    test rax, rax
    jz .Lmt_out
    mov [rax], rbx
    mov [rax + 8], r12
    add rax, 16
    inc qword ptr [rip + g_mem_live]
.Lmt_out:
    EPILOGUE
.Lmt_zero:
    xor eax, eax
    ret

# mem_free(ptr): NULL-safe
FN mem_free
    test rdi, rdi
    jz .Lmf_ret
    dec qword ptr [rip + g_mem_live]
    lea rax, [rdi - 16]
    mov rcx, [rax]
    cmp rcx, 64
    jae .Lmf_large
    lea rdx, [rip + free_lists]
    mov r8, [rdx + rcx*8]
    mov [rax + 16], r8          # store next pointer in the payload
    mov [rdx + rcx*8], rax
    xor eax, eax
.Lmf_ret:
    ret
.Lmf_large:
    mov rdi, rax
    mov rsi, rcx
    jmp os_unmap

# mem_capacity(ptr) -> usable bytes
FN mem_capacity
    mov rcx, [rdi - 16]
    cmp rcx, 64
    jae 1f
    mov eax, 32
    shl rax, cl
    sub rax, 16
    ret
1:  lea rax, [rcx - 16]
    ret

# mem_realloc(ptr, size) -> ptr; contents preserved up to min(old, new).
# Portable copy version: no mremap.
FN mem_realloc
    test rdi, rdi
    jnz 1f
    mov rdi, rsi
    jmp mem_alloc
1:  PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    call mem_capacity
    cmp r12, rax
    ja .Lmr_grow
    mov [rbx - 8], r12          # shrink / fit in place
    mov rax, rbx
    EPILOGUE
.Lmr_grow:
    mov rdi, r12
    call mem_alloc
    mov r13, rax
    mov rdi, rax
    mov rsi, rbx
    mov rcx, [rbx - 8]
    cmp rcx, r12
    cmova rcx, r12              # min(old requested, new)
    rep movsb
    mov rdi, rbx
    call mem_free
    mov rax, r13
    EPILOGUE

# mem_dup(ptr, len) -> NUL-terminated copy
FN mem_dup
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rsi
    add rdi, 1                  # len + 1 (for the NUL)
    jc .Lmd_oom                 # len == SIZE_MAX: len + 1 wraps to 0
    call mem_alloc
    mov rdi, rax
    mov rsi, rbx
    mov rcx, r12
    rep movsb
    mov byte ptr [rdi], 0       # mem_alloc zeroed it; explicit for clarity
    EPILOGUE
.Lmd_oom:
    lea rdi, [rip + .Loom]
    jmp die

# ---- growable byte buffer -------------------------------------------------
# sb_reserve(sb, extra) -> write pointer; len is NOT bumped
FN sb_reserve
    PROLOGUE 0
    mov rbx, rdi
    mov rax, [rbx + SB_len]
    add rax, rsi
    jc .Lsr_die                 # len + extra overflowed 64 bits
    inc rax                     # keep room for the NUL
    jz .Lsr_die                 # len + extra + 1 overflowed (SIZE_MAX)
    cmp rax, [rbx + SB_cap]
    jbe .Lsr_out
    mov rcx, [rbx + SB_cap]
    add rcx, rcx
    cmp rax, rcx
    cmovb rax, rcx
    mov ecx, 64
    cmp rax, rcx
    cmovb rax, rcx
    mov [rbx + SB_cap], rax
    mov rsi, rax
    mov rdi, [rbx + SB_ptr]
    call mem_realloc
    mov [rbx + SB_ptr], rax
.Lsr_out:
    mov rax, [rbx + SB_ptr]
    add rax, [rbx + SB_len]
    EPILOGUE
.Lsr_die:
    lea rdi, [rip + .Loom]
    jmp die

# sb_push(sb, ptr, len). `ptr` may alias the SB's own buffer: when it does we
# record the offset, let sb_reserve grow/realloc, then re-derive the source and
# use memmove so the append is safe even when source and destination overlap.
FN sb_push
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rax, r12
    sub rax, [rbx + SB_ptr]
    cmp rax, [rbx + SB_cap]
    jae .Lsp_fast               # src outside [ptr, ptr+cap): no aliasing
    mov r14, rax                # offset of src within the buffer
    mov rsi, r13
    call sb_reserve
    mov rdi, rax
    mov rsi, [rbx + SB_ptr]
    add rsi, r14                # re-derive src after a possible realloc
    mov rdx, r13
    call memmove
    mov byte ptr [rax + r13], 0 # NUL-terminate at dst+len
    add qword ptr [rbx + SB_len], r13
    EPILOGUE
.Lsp_fast:
    mov rsi, r13
    call sb_reserve
    mov rdi, rax
    mov rsi, r12
    mov rcx, r13
    rep movsb
    mov byte ptr [rdi], 0       # NUL-terminate at ptr+len
    add qword ptr [rbx + SB_len], r13
    EPILOGUE

# sb_push_cstr(sb, cstr)
FN sb_push_cstr
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rsi
    call strlen
    mov rdi, rbx
    mov rsi, r12
    mov rdx, rax
    call sb_push
    EPILOGUE

# sb_push_byte(sb, byte)
FN sb_push_byte
    PROLOGUE 0
    mov rbx, rdi
    mov r12d, esi
    mov esi, 1
    call sb_reserve
    mov [rax], r12b
    mov byte ptr [rax + 1], 0
    inc qword ptr [rbx + SB_len]
    EPILOGUE

# sb_push_u64(sb, value)
FN sb_push_u64
    PROLOGUE 32
    mov rbx, rdi
    mov rsi, rsi
    mov rdi, rsp
    call fmt_u64
    mov rdi, rbx
    mov rsi, rsp
    mov rdx, rax
    call sb_push
    EPILOGUE

# sb_push_utf8(sb, codepoint)
FN sb_push_utf8
    PROLOGUE 16
    mov rbx, rdi
    mov edi, esi
    mov rsi, rsp
    call utf8_encode
    mov rdi, rbx
    mov rsi, rsp
    mov rdx, rax
    call sb_push
    EPILOGUE

# sb_clear(sb)
FN sb_clear
    mov qword ptr [rdi + SB_len], 0
    mov rax, [rdi + SB_ptr]
    test rax, rax
    jz 1f
    mov byte ptr [rax], 0
1:  ret

# sb_free(sb)
FN sb_free
    PROLOGUE 0
    mov rbx, rdi
    mov rdi, [rbx + SB_ptr]
    call mem_free
    xor eax, eax
    mov [rbx + SB_ptr], rax
    mov [rbx + SB_len], rax
    mov [rbx + SB_cap], rax
    EPILOGUE

# ---- growable array of fixed-size items -----------------------------------
# vec_push(vec, item_size) -> ptr to the new zeroed slot
FN vec_push
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    mov rax, [rbx + VEC_len]
    cmp rax, [rbx + VEC_cap]
    jb .Lvp_slot
    mov rax, [rbx + VEC_cap]
    add rax, rax
    jc .Lvp_die                 # capacity doubling overflowed
    mov ecx, 8
    cmp rax, rcx
    cmovb rax, rcx
    mov [rbx + VEC_cap], rax
    mul r12                     # rdx:rax = cap * item_size
    test rdx, rdx
    jnz .Lvp_die                # cap * item_size overflowed
    mov rsi, rax
    mov rdi, [rbx + VEC_ptr]
    call mem_realloc
    mov [rbx + VEC_ptr], rax
.Lvp_slot:
    mov rax, [rbx + VEC_len]
    imul rax, r12
    add rax, [rbx + VEC_ptr]
    inc qword ptr [rbx + VEC_len]
    mov r13, rax
    mov rdi, rax
    mov rcx, r12
    xor eax, eax
    rep stosb
    mov rax, r13
    EPILOGUE
.Lvp_die:
    lea rdi, [rip + .Loom]
    jmp die

# vec_free(vec)
FN vec_free
    PROLOGUE 0
    mov rbx, rdi
    mov rdi, [rbx + VEC_ptr]
    call mem_free
    xor eax, eax
    mov [rbx + VEC_ptr], rax
    mov [rbx + VEC_len], rax
    mov [rbx + VEC_cap], rax
    EPILOGUE

CSTR .Loom, "opcode: out of memory"
