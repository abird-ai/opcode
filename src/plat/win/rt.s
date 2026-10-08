.include "opcode.inc"
.include "plat/win/win.inc"
# win: PE entry point and the startup vector.
#
# Win32 hands the process a command line, not a POSIX initial stack.  win_start
# parses GetCommandLineW with CommandLineToArgvW, converts argv and
# GetEnvironmentStringsW to UTF-8 arenas, builds a Linux-shaped initial stack
# (argc, argv[], NULL, envp[], NULL) at the top of a fresh 16 MiB stack and
# jumps to the portable `_start`.  From there os_init/opcode_main run unchanged,
# which is why no core source learns about Win32.

.equ ARENA_SIZE, 4 << 20
.equ VEC_RESERVE, 256 << 10         # room for argc+envp pointers on the stack

.text

# win_wc_put(arena_end, cursor, srcW) -> new cursor | 0
FN win_wc_put
    push rbx
    push r12
    sub rsp, 72
    mov rbx, rsi                    # cursor
    mov r12, rdi
    sub r12, rsi                    # cbMultiByte
    mov r8, rdx                     # lpWideCharStr
    mov r9d, -1                     # cchWideChar
    mov rcx, CP_UTF8
    xor edx, edx
    mov [rsp + 32], rbx
    mov [rsp + 40], r12d
    mov qword ptr [rsp + 48], 0
    mov qword ptr [rsp + 56], 0
    call WideCharToMultiByte
    test eax, eax
    jz .Lwp_fail
    lea rax, [rbx + rax]
    add rsp, 72
    pop r12
    pop rbx
    ret
.Lwp_fail:
    xor eax, eax
    add rsp, 72
    pop r12
    pop rbx
    ret

# win_build_stack(rdi = reserved vector base) -> initial rsp | 0
# The vector is built in the caller-reserved area on the *real* thread stack
# (the helper's frame sits below the base), so Windows SEH/unwinding and the
# TEB stack limits stay intact.
# Frame: [32]=argc, [40]=loop index, [48]=env cursor, [56]=env base,
# [64]=string start across the win_wc_put call, [72]=vector base.
# 72 bytes keeps [rsp+72] inside the frame's 8-byte pad instead of aliasing
# the saved r15 at [rbp-40].
FN win_build_stack
    PROLOGUE 72
    mov [rsp + 72], rdi             # vector base
    # ---- argv arena: [0..(argc+1)*8) pointers, strings after
    xor ecx, ecx
    mov edx, ARENA_SIZE
    mov r8d, MEM_COMMIT | MEM_RESERVE
    mov r9d, PAGE_READWRITE
    call VirtualAlloc
    test rax, rax
    jz .Lbs_fail
    mov r12, rax                    # arena
    lea rbx, [r12 + ARENA_SIZE]
    call GetCommandLineW
    mov rcx, rax
    lea rdx, [rsp + 32]
    call CommandLineToArgvW
    test rax, rax
    jz .Lbs_fail
    mov r13, rax                    # argvW
    movsxd rax, dword ptr [rsp + 32]
    lea r15, [r12 + rax * 8 + 24]   # strings after argc+1 pointers + 16
    mov qword ptr [rsp + 40], 0
.Lbs_argv:
    mov rcx, [rsp + 40]
    movsxd rax, dword ptr [rsp + 32]
    cmp rcx, rax
    jae .Lbs_argv_done
    mov rdx, [r13 + rcx * 8]
    mov rdi, rbx
    mov rsi, r15
    mov [rsp + 64], rsi
    call win_wc_put
    test rax, rax
    jz .Lbs_fail
    mov r15, rax
    mov rcx, [rsp + 40]
    mov rdx, [rsp + 64]
    mov [r12 + rcx * 8], rdx
    inc qword ptr [rsp + 40]
    jmp .Lbs_argv
.Lbs_argv_done:
    mov rcx, [rsp + 40]
    mov qword ptr [r12 + rcx * 8], 0
    mov rcx, r13
    call LocalFree
    # ---- environment arena
    xor ecx, ecx
    mov edx, ARENA_SIZE
    mov r8d, MEM_COMMIT | MEM_RESERVE
    mov r9d, PAGE_READWRITE
    call VirtualAlloc
    test rax, rax
    jz .Lbs_fail
    mov r13, rax                    # env arena
    lea rbx, [r13 + ARENA_SIZE]
    call GetEnvironmentStringsW
    test rax, rax
    jz .Lbs_fail
    mov [rsp + 48], rax             # source cursor
    mov [rsp + 56], rax             # base (freed later)
    xor ecx, ecx
    mov rdx, rax
.Lbs_count:
    cmp word ptr [rdx], 0
    je .Lbs_count_end
1:  cmp word ptr [rdx], 0
    je 2f
    add rdx, 2
    jmp 1b
2:  inc ecx
    add rdx, 2
    cmp word ptr [rdx], 0
    jne .Lbs_count
.Lbs_count_end:
    movsxd r14, ecx
    lea r15, [r13 + r14 * 8 + 24]
    mov qword ptr [rsp + 40], 0
.Lbs_env:
    mov rcx, [rsp + 40]
    cmp rcx, r14
    jae .Lbs_env_done
    mov rdi, rbx
    mov rsi, r15
    mov [rsp + 64], rsi
    mov rdx, [rsp + 48]
    test rdx, rdx
    jnz 3f
    mov rdx, [rsp + 56]
3:  call win_wc_put
    test rax, rax
    jz .Lbs_fail
    mov r15, rax
    mov rcx, [rsp + 40]
    mov rdx, [rsp + 64]
    mov [r13 + rcx * 8], rdx
    # advance past this entry
    mov rdx, [rsp + 48]
    test rdx, rdx
    jnz 4f
    mov rdx, [rsp + 56]
4:  cmp word ptr [rdx], 0
    je 5f
6:  cmp word ptr [rdx], 0
    je 7f
    add rdx, 2
    jmp 6b
7:  add rdx, 2
5:  mov [rsp + 48], rdx
    inc qword ptr [rsp + 40]
    jmp .Lbs_env
.Lbs_env_done:
    mov rcx, [rsp + 40]
    mov qword ptr [r13 + rcx * 8], 0
    mov rcx, [rsp + 56]
    call FreeEnvironmentStringsW
    # ---- initial vector at the top of the caller-reserved area
    movsxd rax, dword ptr [rsp + 32]
    lea rcx, [rax + r14 + 3]
    imul rcx, rcx, 8                # argc + env + 3 words
    mov rax, [rsp + 72]
    add rax, VEC_RESERVE
    sub rax, rcx
    and rax, -16
    movsxd rcx, dword ptr [rsp + 32]
    mov [rax], rcx                  # argc
    lea rdi, [rax + 8]
    mov rsi, r12
    movsxd rcx, dword ptr [rsp + 32]
    rep movsq                       # argv pointers
    mov qword ptr [rdi], 0
    add rdi, 8
    mov rsi, r13
    mov rcx, r14
    rep movsq                       # envp pointers
    mov qword ptr [rdi], 0
    EPILOGUE
.Lbs_fail:
    xor eax, eax
    EPILOGUE

# win_start: PE entry point (linked with -e win_start)
FN win_start
    and rsp, -16
    call win_fd_init
    call win_env_compat
    sub rsp, VEC_RESERVE
    mov rdi, rsp
    call win_build_stack
    test rax, rax
    jz .Lws_fail
    mov rsp, rax
    jmp _start
.Lws_fail:
    sub rsp, 48
    mov ecx, 1
    call ExitProcess
    ud2

# os_platform() -> "windows": the name the system prompt reports to the model.
# The Linux wrappers carry a weak "linux" definition; this strong one wins.
CSTR .Lwin_plat, "windows"
FN os_platform
    lea rax, [rip + .Lwin_plat]
    ret

# win_env_compat(): Windows has no HOME/XDG_*; Wine hides host XDG_* behind
# WINE_HOST_* names.  Synthesize the POSIX names the portable config/session
# code reads, so both real Windows (USERPROFILE/APPDATA) and Wine (the host
# values) resolve the same directories.  Runs before win_build_stack so the
# added entries are part of the process environment block.
.section .rdata
.p2align 2
.Lenv_home:      .asciz "HOME"
.Lenv_xdg_data:  .asciz "XDG_DATA_HOME"
.Lenv_xdg_cfg:   .asciz "XDG_CONFIG_HOME"
.Lenv_wh_home:   .asciz "WINE_HOST_HOME"
.Lenv_wh_data:   .asciz "WINE_HOST_XDG_DATA_HOME"
.Lenv_wh_cfg:    .asciz "WINE_HOST_XDG_CONFIG_HOME"
.Lenv_userprof:  .asciz "USERPROFILE"
.Lenv_sub_data:  .asciz "/.local/share"
.Lenv_sub_cfg:   .asciz "/.config"
# { target, source1, source2 | 0 } terminated by a zero word; the XDG entries
# only carry the explicit Wine host variables, the HOME-derived fallbacks are
# applied afterwards by win_env_from_home.
.Lenv_map:
    .quad .Lenv_home,     .Lenv_wh_home, .Lenv_userprof
    .quad .Lenv_xdg_data, .Lenv_wh_data, 0
    .quad .Lenv_xdg_cfg,  .Lenv_wh_cfg,  0
    .quad 0, 0, 0
.text

# win_env_set_if_absent(target ascii, source ascii): set target from source
# when target is absent and source present.  Buffers: win_scratch8 = target
# name, win_scratch16 = source name, win_scratch8+32768 = value.
win_env_set_if_absent:
    PROLOGUE 32
    mov r12, rdi
    mov r13, rsi
    mov rdi, r12
    lea rsi, [rip + win_scratch8]
    call win_utf8_to_utf16
    test rax, rax
    js .Les_out
    lea rcx, [rip + win_scratch8]
    xor edx, edx
    xor r8d, r8d
    call GetEnvironmentVariableW
    test eax, eax
    jnz .Les_out
    mov rdi, r13
    lea rsi, [rip + win_scratch16]
    call win_utf8_to_utf16
    test rax, rax
    js .Les_out
    lea rcx, [rip + win_scratch16]
    lea rdx, [rip + win_scratch8 + 32768]
    mov r8d, 16384
    call GetEnvironmentVariableW
    test eax, eax
    jz .Les_out
    lea rcx, [rip + win_scratch8]
    lea rdx, [rip + win_scratch8 + 32768]
    call SetEnvironmentVariableW
.Les_out:
    EPILOGUE

# win_env_from_home(target ascii, suffix ascii): set target to
# $HOME + suffix when both HOME and target are absent.  Buffers: win_scratch8
# = target name, win_scratch8+32768 = value, win_scratch16 = converted suffix.
win_env_from_home:
    PROLOGUE 32
    mov r12, rdi
    mov r13, rsi
    mov rdi, r12
    lea rsi, [rip + win_scratch8]
    call win_utf8_to_utf16
    test rax, rax
    js .Leh_out
    lea rcx, [rip + win_scratch8]
    xor edx, edx
    xor r8d, r8d
    call GetEnvironmentVariableW
    test eax, eax
    jnz .Leh_out
    lea rdi, [rip + .Lenv_home]
    lea rsi, [rip + win_scratch8 + 16384]
    call win_utf8_to_utf16
    test rax, rax
    js .Leh_out
    lea rcx, [rip + win_scratch8 + 16384]
    lea rdx, [rip + win_scratch8 + 32768]
    mov r8d, 8000
    call GetEnvironmentVariableW
    test eax, eax
    jz .Leh_out
    mov rdi, r13
    lea rsi, [rip + win_scratch16]
    call win_utf8_to_utf16
    test rax, rax
    js .Leh_out
    lea rdi, [rip + win_scratch8 + 32768]
    xor eax, eax
    mov ecx, 8000
.Leh_find:
    cmp word ptr [rdi], 0
    je .Leh_append
    add rdi, 2
    dec ecx
    jnz .Leh_find
    jmp .Leh_out
.Leh_append:
    lea rsi, [rip + win_scratch16]
.Leh_copy:
    mov ax, [rsi]
    mov [rdi], ax
    add rsi, 2
    add rdi, 2
    test ax, ax
    jnz .Leh_copy
    lea rcx, [rip + win_scratch8]
    lea rdx, [rip + win_scratch8 + 32768]
    call SetEnvironmentVariableW
.Leh_out:
    EPILOGUE

FN win_env_compat
    PROLOGUE 32
    lea rbx, [rip + .Lenv_map]
.Lec_loop:
    mov rdi, [rbx]
    test rdi, rdi
    jz .Lec_done
    mov rsi, [rbx + 8]
    call win_env_set_if_absent
    mov rdi, [rbx]
    mov rsi, [rbx + 16]
    call win_env_set_if_absent
    add rbx, 24
    jmp .Lec_loop
.Lec_done:
    lea rdi, [rip + .Lenv_xdg_data]
    lea rsi, [rip + .Lenv_sub_data]
    call win_env_from_home
    lea rdi, [rip + .Lenv_xdg_cfg]
    lea rsi, [rip + .Lenv_sub_cfg]
    call win_env_from_home
    EPILOGUE
