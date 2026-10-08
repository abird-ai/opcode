.include "opcode.inc"
# src/plat/mac/smoke.s — Opcode Layer-0 smoke program.
#
# Built for macOS arm64 by `make darwin-arm64-smoke`: this x86-64 GNU-as source
# is translated with tools/arm64.py and linked against the native Darwin shim.
# On a Linux host it is assembled to Mach-O but not linked (there is no Mach-O
# linker there), so on Linux it is a static check only.
#
# It walks the Layer-0 contract and prints one line per check:
#   1  os_write(1, "smoke\n", 6) == 6
#   2  the monotonic clock does not go backwards and os_sleep_ns(1ms) advances
#      it by at least 0.5ms
#   3  create/write/close/open/read/compare/close/unlink round-trip
#   4  socketpair(53) round-trip, driven through the raw SYS path
# Exit status is 0 on success, otherwise the number of the first failed check.

# Local POSIX constants; smoke does not include net/net.inc.
.equ AF_UNIX,     1
.equ SOCK_STREAM, 1

.text
CSTR .Ls_smoke, "smoke\n"
CSTR .Ls_clock, "clock ok\n"
CSTR .Ls_file,  "file ok\n"
CSTR .Ls_sock,  "socketpair ok\n"
CSTR .Ls_tmp,   "smoke.tmp"
CSTR .Ls_hello, "hello"

# _start: the translated entry the native rt.s calls.  It needs neither os_init
# nor argv for a Layer-0 check.
FN _start
    PROLOGUE 16

    # 1. stdout: exactly six bytes, exactly six written.
    mov edi, 1
    lea rsi, [rip + .Ls_smoke]
    mov edx, 6
    call os_write
    cmp rax, 6
    jne .Lfail1

    # 2. clock: monotonic before/after a 1ms sleep, never going backwards.
    mov edi, CLOCK_MONOTONIC
    call os_now_ns
    test rax, rax
    js .Lfail2
    mov r12, rax
    mov edi, 1000000
    call os_sleep_ns
    test rax, rax
    js .Lfail2
    mov edi, CLOCK_MONOTONIC
    call os_now_ns
    test rax, rax
    js .Lfail2
    mov r13, rax
    cmp r13, r12
    jb .Lfail2
    sub r13, r12
    cmp r13, 500000
    jb .Lfail2
    mov edi, 1
    lea rsi, [rip + .Ls_clock]
    mov edx, 9
    call os_write

    # 3. file: create+truncate, write "hello", close, reopen, read, compare.
    lea rdi, [rip + .Ls_tmp]
    mov esi, O_CREAT | O_WRONLY | O_TRUNC
    mov edx, 0644
    call os_open
    test rax, rax
    js .Lfail3
    mov r12, rax
    mov edi, r12d
    lea rsi, [rip + .Ls_hello]
    mov edx, 5
    call os_write
    cmp rax, 5
    jne .Lfail3
    mov edi, r12d
    call os_close

    lea rdi, [rip + .Ls_tmp]
    xor esi, esi
    xor edx, edx
    call os_open
    test rax, rax
    js .Lfail3
    mov r12, rax
    mov edi, r12d
    lea rsi, [rsp]
    mov edx, 5
    call os_read
    cmp rax, 5
    jne .Lfail3
    lea rsi, [rip + .Ls_hello]
    xor ecx, ecx
.Lcmp_file:
    movzx eax, byte ptr [rsp + rcx]
    movzx edx, byte ptr [rsi + rcx]
    cmp eax, edx
    jne .Lfail3
    inc ecx
    cmp ecx, 5
    jb .Lcmp_file
    mov edi, r12d
    call os_close
    lea rdi, [rip + .Ls_tmp]
    call os_unlink
    test rax, rax
    js .Lfail3
    mov edi, 1
    lea rsi, [rip + .Ls_file]
    mov edx, 8
    call os_write

    # 4. socketpair: Linux syscall 53, then a four-byte round-trip.  The sv[2]
    # array lives at [rsp, rsp+8); os_write/os_read work on the raw socket fds.
    mov edi, AF_UNIX
    mov esi, SOCK_STREAM
    xor edx, edx
    lea r10, [rsp]
    mov eax, 53
    XSYS
    test rax, rax
    js .Lfail4
    mov r12d, [rsp]
    mov r13d, [rsp + 4]
    mov edi, r12d
    lea rsi, [rip + .Ls_hello]
    mov edx, 4
    call os_write
    cmp rax, 4
    jne .Lfail4
    mov edi, r13d
    lea rsi, [rsp]
    mov edx, 4
    call os_read
    cmp rax, 4
    jne .Lfail4
    lea rsi, [rip + .Ls_hello]
    xor ecx, ecx
.Lcmp_sock:
    movzx eax, byte ptr [rsp + rcx]
    movzx edx, byte ptr [rsi + rcx]
    cmp eax, edx
    jne .Lfail4
    inc ecx
    cmp ecx, 4
    jb .Lcmp_sock
    mov edi, r12d
    call os_close
    mov edi, r13d
    call os_close
    mov edi, 1
    lea rsi, [rip + .Ls_sock]
    mov edx, 14
    call os_write

    # Success: exit 0.  os_exit runs the cleanup hook and ends the process, so
    # every path below leaves through it rather than EPILOGUE.
    xor edi, edi
    jmp os_exit

.Lfail1:
    mov edi, 1
    jmp os_exit
.Lfail2:
    mov edi, 2
    jmp os_exit
.Lfail3:
    mov edi, 3
    jmp os_exit
.Lfail4:
    mov edi, 4
    jmp os_exit
