.include "opcode.inc"
# opcode base: static watch table + poll dispatch.
#
# No allocation and no syscalls other than os_poll. Handlers run on the main
# thread as handler(fd, revents, ctx) and may add/remove watches; loop_poll
# dispatches from the highest pollfd index down and re-locates each fd in the
# live table before calling, so a swap-with-last watch_remove cannot make it
# call a stale or already-removed entry.

.equ LOOP_MAX_WATCH, 96

# watch entry: fd, events | pad, handler, ctx (32 bytes).
STRUCT
F WE_fd, 8
F WE_events, 2
F WE_pad, 2
F WE_pad2, 4
F WE_handler, 8
F WE_ctx, 8
ENDSTRUCT WE_SIZE

# pollfd: { i32 fd; i16 events; i16 revents } (8 bytes, see src/plat/plat.inc).
STRUCT
F PFD_fd, 4
F PFD_events, 2
F PFD_revents, 2
ENDSTRUCT PFD_SIZE

.bss
.p2align 4
watch_tab: .zero WE_SIZE * LOOP_MAX_WATCH
pollfds:   .zero PFD_SIZE * LOOP_MAX_WATCH
.p2align 3
watch_n:   .quad 0

.text

# watch_add(fd, events, handler, ctx) -> 0 | -ENOSPC
FN watch_add
    mov r9, [rip + watch_n]
    lea r10, [rip + watch_tab]
    xor r11d, r11d
.Lwa_scan:
    cmp r11, r9
    jae .Lwa_room
    cmp edi, dword ptr [r10 + WE_fd]
    je .Lwa_exists              # loop_poll re-matches by fd: duplicates break it
    add r10, WE_SIZE
    inc r11
    jmp .Lwa_scan
.Lwa_room:
    mov rax, [rip + watch_n]
    cmp rax, LOOP_MAX_WATCH
    jae .Lwa_full
    shl rax, 5                  # WE_SIZE == 32
    lea r8, [rip + watch_tab]
    add rax, r8
    mov [rax + WE_fd], rdi
    mov [rax + WE_events], si
    mov word ptr [rax + WE_pad], 0
    mov [rax + WE_handler], rdx
    mov [rax + WE_ctx], rcx
    inc qword ptr [rip + watch_n]
    xor eax, eax
    ret
.Lwa_exists:
    mov rax, -EEXIST
    ret
.Lwa_full:
    mov rax, -ENOSPC
    ret

# watch_remove(fd) -> 0 | -ENOENT; the last entry is swapped into the hole.
FN watch_remove
    mov rcx, [rip + watch_n]
    lea r8, [rip + watch_tab]
    xor edx, edx
.Lwr_find:
    cmp rdx, rcx
    jae .Lwr_missing
    cmp edi, dword ptr [r8 + WE_fd]
    je .Lwr_found
    add r8, WE_SIZE
    inc rdx
    jmp .Lwr_find
.Lwr_found:
    dec rcx                     # index of the last live entry
    cmp rdx, rcx
    je .Lwr_done                # removing the last entry needs no move
    mov rax, rcx
    shl rax, 5
    lea r9, [rip + watch_tab]
    add r9, rax
    mov rax, [r9]
    mov [r8], rax
    mov rax, [r9 + 8]
    mov [r8 + 8], rax
    mov rax, [r9 + 16]
    mov [r8 + 16], rax
    mov rax, [r9 + 24]
    mov [r8 + 24], rax
.Lwr_done:
    mov [rip + watch_n], rcx
    xor eax, eax
    ret
.Lwr_missing:
    mov rax, -ENOENT
    ret

# watch_set_events(fd, events) -> 0 | -ENOENT
FN watch_set_events
    mov rcx, [rip + watch_n]
    lea r8, [rip + watch_tab]
    xor edx, edx
.Lwse_find:
    cmp rdx, rcx
    jae .Lwse_missing
    cmp edi, dword ptr [r8 + WE_fd]
    je .Lwse_found
    add r8, WE_SIZE
    inc rdx
    jmp .Lwse_find
.Lwse_found:
    mov [r8 + WE_events], si
    xor eax, eax
    ret
.Lwse_missing:
    mov rax, -ENOENT
    ret

# watch_count() -> n
FN watch_count
    mov rax, [rip + watch_n]
    ret

# watch_clear() -> 0
FN watch_clear
    mov qword ptr [rip + watch_n], 0
    xor eax, eax
    ret

# loop_poll(timeout_ms) -> number of handlers called.
# Snapshot the watch table into pollfds, poll once, then walk the snapshot from
# the highest index down. Each nonzero revents is re-matched against the live
# table by fd; an entry removed mid-dispatch is skipped.
FN loop_poll
    PROLOGUE 0
    mov r15d, edi               # timeout_ms
    lea r12, [rip + pollfds]
    lea r14, [rip + watch_tab]
    mov r13, [rip + watch_n]    # n
    # build the pollfd snapshot
    mov rax, r14
    mov rdx, r12
    xor ecx, ecx
.Lp_build:
    cmp rcx, r13
    jae .Lp_poll
    mov r8, [rax + WE_fd]
    mov [rdx + PFD_fd], r8d
    mov r8w, [rax + WE_events]
    mov [rdx + PFD_events], r8w
    mov word ptr [rdx + PFD_revents], 0
    add rax, WE_SIZE
    add rdx, PFD_SIZE
    inc rcx
    jmp .Lp_build
.Lp_poll:
    mov rdi, r12
    mov rsi, r13
    mov edx, r15d
    call os_poll
    test rax, rax
    jle .Lp_none
    xor r15d, r15d              # handlers called
    mov rbx, r13
    dec rbx                     # i = n - 1
.Lp_loop:
    test rbx, rbx
    js .Lp_done
    mov r10, rbx
    shl r10, 3
    add r10, r12                # &pollfds[i]
    movzx r11d, word ptr [r10 + PFD_revents]
    test r11d, r11d
    jz .Lp_next
    mov edx, [r10 + PFD_fd]
    mov rcx, [rip + watch_n]    # live count (handlers may have changed it)
    mov r8, r14
    xor r9d, r9d
.Lp_find:
    cmp r9, rcx
    jae .Lp_next                # fd was removed mid-dispatch: skip
    cmp edx, dword ptr [r8 + WE_fd]
    je .Lp_found
    add r8, WE_SIZE
    inc r9
    jmp .Lp_find
.Lp_found:
    mov rdi, [r8 + WE_fd]
    mov esi, r11d
    mov rdx, [r8 + WE_ctx]
    mov rax, [r8 + WE_handler]
    call rax
    inc r15
.Lp_next:
    dec rbx
    jmp .Lp_loop
.Lp_done:
    mov rax, r15
    EPILOGUE
.Lp_none:
    xor eax, eax
    EPILOGUE
