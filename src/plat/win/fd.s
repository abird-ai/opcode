.include "opcode.inc"
.include "plat/win/win.inc"
# win: descriptor table and text/error helpers shared by the Windows layer.
#
# The portable corpus and the reused src/plat/linux wrappers pass 32-bit
# descriptors (pollfd.fd is an i32) but Win32 speaks 64-bit HANDLEs and
# SOCKETs; win_fd_* is the small table that bridges the two.  fd 0/1/2 are
# the process standard handles.  This file is Layer 0 internal: only
# src/plat/win sources and win_syscall use it.
#
# All helpers return in rax, failures are negative Linux errno.

.bss
.p2align 4
.globl win_fd_table
win_fd_table: .zero FD_MAX * FD_SIZE
.globl win_wsa_started
win_wsa_started: .zero 8
.globl win_wsa_data
win_wsa_data: .zero WSADATA_SIZE

.text

# win_fd_new(kind, handle, flags) -> fd | -EMFILE
FN win_fd_new
    push rbx
    push r12
    push r13
    mov ebx, edi                    # kind
    mov r12, rsi                    # handle
    mov r13, rdx                    # flags
    lea rax, [rip + win_fd_table]
    mov ecx, 0
.Lfn_scan:
    cmp ecx, FD_MAX
    jae .Lfn_full
    cmp dword ptr [rax + FD_KIND], FK_NONE
    je .Lfn_take
    add rax, FD_SIZE
    inc ecx
    jmp .Lfn_scan
.Lfn_take:
    mov [rax + FD_HANDLE], r12
    mov dword ptr [rax + FD_KIND], ebx
    mov [rax + FD_FLAGS], r13
    mov qword ptr [rax + FD_AUX], 0
    mov eax, ecx
    pop r13
    pop r12
    pop rbx
    ret
.Lfn_full:
    mov rax, -EMFILE
    pop r13
    pop r12
    pop rbx
    ret

# win_fd_entry(fd) -> entry pointer | 0 when unused/out of range
FN win_fd_entry
    test rdi, rdi
    js .Lfe_none
    cmp rdi, FD_MAX
    jae .Lfe_none
    lea rax, [rip + win_fd_table]
    imul rcx, rdi, FD_SIZE
    add rax, rcx
    cmp dword ptr [rax + FD_KIND], FK_NONE
    je .Lfe_none
    ret
.Lfe_none:
    xor eax, eax
    ret

# win_fd_init(): classify the three standard handles.  Console, pipe and disk
# handles are told apart by GetFileType; a redirect through a Unix pipe or
# pty under Wine lands in the FILE_TYPE_PIPE/CHAR branches.
FN win_fd_init
    PROLOGUE 0
    xor r12d, r12d
.Lfi_loop:
    mov ecx, -10
    sub ecx, r12d                   # -10/-11/-12
    call GetStdHandle
    test rax, rax
    jz .Lfi_next
    cmp rax, INVALID_HANDLE
    je .Lfi_next
    mov r13, rax
    mov rcx, rax
    call GetFileType
    lea rbx, [rip + win_fd_table]
    imul rcx, r12, FD_SIZE
    add rbx, rcx
    mov [rbx + FD_HANDLE], r13
    mov qword ptr [rbx + FD_FLAGS], 0
    mov qword ptr [rbx + FD_AUX], 0
    cmp eax, FILE_TYPE_CHAR
    je .Lfi_char
    cmp eax, FILE_TYPE_PIPE
    je .Lfi_pipe
    mov dword ptr [rbx + FD_KIND], FK_FILE
    jmp .Lfi_next
.Lfi_char:
    mov dword ptr [rbx + FD_KIND], FK_CONSOLE
    jmp .Lfi_next
.Lfi_pipe:
    test r12d, r12d
    jnz .Lfi_wpipe
    mov dword ptr [rbx + FD_KIND], FK_PIPE_R
    jmp .Lfi_next
.Lfi_wpipe:
    mov dword ptr [rbx + FD_KIND], FK_PIPE_W
.Lfi_next:
    inc r12d
    cmp r12d, 3
    jb .Lfi_loop
    xor eax, eax
    EPILOGUE

# win_fd_close(fd) -> 0 | -EBADF.  fd 0/1/2 are the process standard handles:
# the table slot is released but the OS handle is left alone.
FN win_fd_close
    push rbx
    push r12
    sub rsp, 40
    mov r12d, edi
    call win_fd_entry
    test rax, rax
    jz .Lfc_bad
    mov rbx, rax
    cmp r12d, 3
    jb .Lfc_mark
    cmp qword ptr [rbx + FD_HANDLE], 0
    je .Lfc_mark
    mov eax, dword ptr [rbx + FD_KIND]
    cmp eax, FK_SOCKET
    je .Lfc_sock
    cmp eax, FK_DIR
    je .Lfc_dir
    mov rcx, [rbx + FD_HANDLE]
    call CloseHandle
    jmp .Lfc_mark
.Lfc_sock:
    mov rcx, [rbx + FD_HANDLE]
    call closesocket
    jmp .Lfc_mark
.Lfc_dir:
    mov rcx, [rbx + FD_AUX]
    test rcx, rcx
    jz .Lfc_dir_h
    mov rcx, [rcx]                  # find handle lives at aux[0]
    call FindClose
    mov rcx, [rbx + FD_AUX]
    xor edx, edx
    mov r8d, MEM_RELEASE
    call VirtualFree
.Lfc_dir_h:
    mov rcx, [rbx + FD_HANDLE]
    call CloseHandle
.Lfc_mark:
    mov dword ptr [rbx + FD_KIND], FK_NONE
    mov qword ptr [rbx + FD_HANDLE], 0
    mov qword ptr [rbx + FD_AUX], 0
    xor eax, eax
    add rsp, 40
    pop r12
    pop rbx
    ret
.Lfc_bad:
    mov rax, -EBADF
    add rsp, 40
    pop r12
    pop rbx
    ret

# ---------------------------------------------------------------- strings
# win_utf8_to_utf16(src, dst) -> chars incl NUL | -errno
# dst must hold UTF16_MAX code units.
FN win_utf8_to_utf16
    sub rsp, 56
    mov r10, rsi                    # dst
    mov r11, rdi                    # src
    mov ecx, CP_UTF8
    mov edx, MB_ERR_INVALID_CHARS
    mov r8, r11
    mov r9d, -1                     # cbMultiByte: NUL-terminated
    mov [rsp + 32], r10             # lpWideCharStr
    mov qword ptr [rsp + 40], UTF16_MAX
    call MultiByteToWideChar
    add rsp, 56
    test eax, eax
    jz .Lutf8_bad
    ret
.Lutf8_bad:
    mov rax, -EINVAL
    ret

# win_utf16_to_utf8(src, dst, dstbytes) -> bytes incl NUL | -errno
FN win_utf16_to_utf8
    test rdx, rdx
    jz .Lu16_bad
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 72
    mov rbx, rdi                    # src
    mov r12, rsi                    # dst
    mov r13, rdx                    # dstbytes
    mov ecx, CP_UTF8
    xor edx, edx
    mov r8, rbx
    mov r9d, -1                     # cchWideChar: NUL-terminated
    mov [rsp + 32], r12             # lpMultiByteStr
    mov [rsp + 40], r13             # cbMultiByte
    mov qword ptr [rsp + 48], 0     # lpDefaultChar
    mov qword ptr [rsp + 56], 0     # lpUsedDefaultChar
    call WideCharToMultiByte
    add rsp, 72
    pop r14
    pop r13
    pop r12
    pop rbx
    test eax, eax
    jz .Lu16_bad
    ret
.Lu16_bad:
    mov rax, -EINVAL
    ret

# ---------------------------------------------------------------- errors
# win_errno_from_code(code) -> negative Linux errno
FN win_errno_from_code
    lea rdx, [rip + win_errno_map]
.Lwe_loop:
    movzx eax, word ptr [rdx]
    test eax, eax
    jz .Lwe_unknown
    cmp eax, edi
    je .Lwe_found
    add rdx, 4
    jmp .Lwe_loop
.Lwe_found:
    movzx eax, word ptr [rdx + 2]
    neg rax
    ret
.Lwe_unknown:
    mov rax, -EIO
    ret

# win_last_error() -> negative Linux errno from GetLastError
FN win_last_error
    call GetLastError
    mov edi, eax
    jmp win_errno_from_code

# win_wsa_error() -> negative Linux errno from WSAGetLastError
FN win_wsa_error
    call WSAGetLastError
    mov edi, eax
    jmp win_errno_from_code

.section .rdata
.p2align 2
# { u16 win/wsa code, u16 linux errno }, terminated by 0
win_errno_map:
    .short ERROR_FILE_NOT_FOUND, ENOENT
    .short ERROR_PATH_NOT_FOUND, ENOENT
    .short ERROR_ACCESS_DENIED, EACCES
    .short ERROR_INVALID_HANDLE, EBADF
    .short ERROR_NOT_ENOUGH_MEMORY, ENOMEM
    .short ERROR_WRITE_PROTECT, EACCES
    .short ERROR_SHARING_VIOLATION, EBUSY
    .short ERROR_LOCK_VIOLATION, EBUSY
    .short ERROR_HANDLE_EOF, EPIPE
    .short ERROR_NOT_SAME_DEVICE, EXDEV
    .short ERROR_FILE_EXISTS, EEXIST
    .short ERROR_INVALID_PARAMETER, EINVAL
    .short ERROR_BROKEN_PIPE, EPIPE
    .short ERROR_DISK_FULL, ENOSPC
    .short ERROR_NEGATIVE_SEEK, EINVAL
    .short ERROR_ALREADY_EXISTS, EEXIST
    .short ERROR_FILENAME_EXCED_RANGE, ENAMETOOLONG
    .short ERROR_DIRECTORY_NOT_EMPTY, ENOTEMPTY
    .short ERROR_NO_DATA, EPIPE
    .short ERROR_OPERATION_ABORTED, EINTR
    .short 267, ENOTDIR
    .short 1168, ENOENT
    .short WSAEACCES, EACCES
    .short WSAEINVAL, EINVAL
    .short WSAEMFILE, EMFILE
    .short WSAEWOULDBLOCK, EAGAIN
    .short WSAEINPROGRESS, EINPROGRESS
    .short WSAEALREADY, EALREADY
    .short WSAENOTSOCK, EBADF
    .short WSAEMSGSIZE, EMSGSIZE
    .short WSAEPROTONOSUPPORT, EPROTONOSUPPORT
    .short WSAEAFNOSUPPORT, EAFNOSUPPORT
    .short WSAEADDRINUSE, EADDRINUSE
    .short WSAEADDRNOTAVAIL, EADDRNOTAVAIL
    .short WSAENETUNREACH, ENETUNREACH
    .short WSAECONNABORTED, ECONNABORTED
    .short WSAECONNRESET, ECONNRESET
    .short WSAENOBUFS, ENOBUFS
    .short WSAETIMEDOUT, ETIMEDOUT
    .short WSAECONNREFUSED, ECONNREFUSED
    .short WSAEHOSTUNREACH, EHOSTUNREACH
    .short 0, 0
.text
