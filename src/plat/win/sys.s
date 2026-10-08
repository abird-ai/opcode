.include "opcode.inc"
.include "plat/win/win.inc"
# win: Layer 0 syscall shim (files, memory, time, poll, misc).
#
# The portable corpus and the src/plat/linux wrappers are assembled unchanged
# with --defsym WINDOWS=1; opcode.inc's SYS macro then calls win_syscall with
# the Linux x86-64 syscall number in eax and the Linux argument registers
# (rdi rsi rdx r10 r8 r9).  This file maps the numbers opcode actually issues
# onto Win32, normalizing errors to negative Linux errno.  Numbers with no
# handler return -ENOSYS; nothing returns 0 without doing the work.
#
# proc.s, tty.s and dir.s are native Windows implementations of the three
# contracts whose Linux version is not a thin syscall wrapper (fork/exec,
# termios+signals, getdents64); the socket numbers live in sock.s.

.bss
.p2align 3
win_qpc_freq:   .zero 8
.globl win_scratch16
win_scratch16:  .zero UTF16_MAX * 2
.globl win_scratch8
win_scratch8:   .zero 65536

.text

# ---------------------------------------------------------------- bootstrap
# winwsa_init() -> 0 | -errno: WSAStartup once (lazy; net_init is a no-op)
FN winwsa_init
    cmp qword ptr [rip + win_wsa_started], 0
    jne .Lwi_ok
    sub rsp, 40
    mov ecx, 0x0202
    lea rdx, [rip + win_wsa_data]
    call WSAStartup
    add rsp, 40
    test eax, eax
    jnz .Lwi_fail
    mov qword ptr [rip + win_wsa_started], 1
    xor eax, eax
    ret
.Lwi_ok:
    xor eax, eax
    ret
.Lwi_fail:
    mov rax, -EIO
    ret

# winqpc_init() -> QPC frequency in rax (cached)
FN winqpc_init
    mov rax, [rip + win_qpc_freq]
    test rax, rax
    jnz .Lqi_ret
    sub rsp, 40
    lea rcx, [rip + win_qpc_freq]
    call QueryPerformanceFrequency
    add rsp, 40
    mov rax, [rip + win_qpc_freq]
.Lqi_ret:
    ret

# ---------------------------------------------------------------- read/write
# read(fd, buf, len) -> n | 0 (eof) | -errno
FN winh_read
    PROLOGUE 64
    mov r12d, edi
    mov r13, rsi
    mov r14, rdx
    call win_fd_entry
    test rax, rax
    jz .Lrd_bad
    mov rbx, rax
    mov eax, [rbx + FD_KIND]
    cmp eax, FK_SOCKET
    je .Lrd_sock
    cmp eax, FK_DIR
    je .Lrd_isdir
    cmp eax, FK_PIPE_R
    je .Lrd_pipe
    # file or console
    mov rcx, [rbx + FD_HANDLE]
    mov rdx, r13
    mov r8, r14
    lea r9, [rsp + 64]
    mov qword ptr [rsp + 32], 0     # lpOverlapped
    call ReadFile
    test eax, eax
    jz .Lrd_err
    mov eax, [rsp + 64]
    EPILOGUE
.Lrd_sock:
    mov rcx, [rbx + FD_HANDLE]
    mov rdx, r13
    mov r8, r14
    xor r9d, r9d
    call recv
    cmp eax, -1
    je .Lrd_wsa
    cdqe
    EPILOGUE
.Lrd_pipe:
    mov rcx, [rbx + FD_HANDLE]
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    lea rax, [rsp + 56]
    mov [rsp + 32], rax             # lpTotalBytesAvail
    mov qword ptr [rsp + 40], 0
    call PeekNamedPipe
    test eax, eax
    jz .Lrd_pipe_err
    mov eax, [rsp + 56]
    test eax, eax
    jz .Lrd_pipe_wait
    cmp rax, r14
    jbe 1f
    mov rax, r14
1:  test rax, rax
    jz .Lrd_zero
    mov r8, rax
    mov rcx, [rbx + FD_HANDLE]
    mov rdx, r13
    lea r9, [rsp + 60]
    mov qword ptr [rsp + 32], 0
    call ReadFile
    test eax, eax
    jz .Lrd_err
    mov eax, [rsp + 60]
    EPILOGUE
.Lrd_pipe_wait:
    test qword ptr [rbx + FD_FLAGS], O_NONBLOCK
    jnz .Lrd_eagain
    mov rcx, [rbx + FD_HANDLE]
    mov rdx, r13
    mov r8, r14
    lea r9, [rsp + 64]
    mov qword ptr [rsp + 32], 0
    call ReadFile
    test eax, eax
    jz .Lrd_err
    mov eax, [rsp + 64]
    EPILOGUE
.Lrd_pipe_err:
    call GetLastError
    cmp eax, ERROR_BROKEN_PIPE
    je .Lrd_zero
    cmp eax, ERROR_HANDLE_EOF
    je .Lrd_zero
    # Wine does not implement PeekNamedPipe for the anonymous Unix pipes it
    # maps to std handles; a blocking fd can just read (the caller wanted to
    # block anyway), a non-blocking one reports -EAGAIN.
    cmp eax, ERROR_NOT_SUPPORTED
    je .Lrd_pipe_wait
    cmp eax, ERROR_INVALID_FUNCTION
    je .Lrd_pipe_wait
    call win_last_error
    EPILOGUE
.Lrd_wsa:
    call win_wsa_error
    EPILOGUE
.Lrd_err:
    call win_last_error
    EPILOGUE
.Lrd_bad:
    mov rax, -EBADF
    EPILOGUE
.Lrd_isdir:
    mov rax, -EISDIR
    EPILOGUE
.Lrd_eagain:
    mov rax, -EAGAIN
    EPILOGUE
.Lrd_zero:
    xor eax, eax
    EPILOGUE

# write(fd, buf, len) -> n | -errno
FN winh_write
    PROLOGUE 64
    mov r12d, edi
    mov r13, rsi
    mov r14, rdx
    call win_fd_entry
    test rax, rax
    jz .Lwr_bad
    mov rbx, rax
    mov eax, [rbx + FD_KIND]
    cmp eax, FK_SOCKET
    je .Lwr_sock
    cmp eax, FK_DIR
    je .Lwr_isdir
    mov rcx, [rbx + FD_HANDLE]
    mov rdx, r13
    mov r8, r14
    lea r9, [rsp + 64]
    mov qword ptr [rsp + 32], 0
    call WriteFile
    test eax, eax
    jz .Lwr_err
    mov eax, [rsp + 64]
    EPILOGUE
.Lwr_sock:
    mov rcx, [rbx + FD_HANDLE]
    mov rdx, r13
    mov r8, r14
    xor r9d, r9d
    call send
    cmp eax, -1
    je .Lwr_wsa
    cdqe
    EPILOGUE
.Lwr_wsa:
    call win_wsa_error
    EPILOGUE
.Lwr_err:
    call win_last_error
    EPILOGUE
.Lwr_bad:
    mov rax, -EBADF
    EPILOGUE
.Lwr_isdir:
    mov rax, -EISDIR
    EPILOGUE

# ---------------------------------------------------------------- files
# openat(dirfd, path, flags, mode) -> fd | -errno
FN winh_openat
    PROLOGUE 64
    mov r12, rsi                    # path
    mov r13d, edx                   # flags
    xor r14d, r14d                  # access
    mov eax, r13d
    and eax, 3
    cmp eax, 2
    je .Lop_rdwr
    cmp eax, 1
    je .Lop_wr
    mov r14d, GENERIC_READ
    jmp .Lop_acc
.Lop_rdwr:
    mov r14d, GENERIC_READ | GENERIC_WRITE
    jmp .Lop_acc
.Lop_wr:
    mov r14d, GENERIC_WRITE
.Lop_acc:
    test r13d, O_APPEND
    jz .Lop_creat
    # FILE_APPEND_DATA alone forces every write to the end; keeping
    # GENERIC_WRITE as well makes Wine/Windows write at the file pointer.
    and r14d, 0xBFFFFFFF
    or r14d, FILE_APPEND_DATA
.Lop_creat:
    mov r15d, OPEN_EXISTING
    test r13d, O_CREAT
    jz .Lop_notc
    test r13d, O_EXCL
    jnz .Lop_new
    test r13d, O_TRUNC
    jnz .Lop_always
    mov r15d, OPEN_ALWAYS
    jmp .Lop_notc
.Lop_new:
    mov r15d, CREATE_NEW
    jmp .Lop_notc
.Lop_always:
    mov r15d, CREATE_ALWAYS
    jmp .Lop_notc
.Lop_notc:
    test r13d, O_CREAT
    jnz .Lop_go
    test r13d, O_TRUNC
    jz .Lop_go
    mov r15d, TRUNCATE_EXISTING
.Lop_go:
    mov rdi, r12
    lea rsi, [rip + win_scratch16]
    call win_utf8_to_utf16
    test rax, rax
    js .Lop_out
    lea rcx, [rip + win_scratch16]
    mov edx, r14d
    mov r8d, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE
    xor r9d, r9d
    mov [rsp + 32], r15d
    mov eax, FILE_ATTRIBUTE_NORMAL | FILE_FLAG_BACKUP_SEMANTICS
    mov [rsp + 40], eax
    mov qword ptr [rsp + 48], 0
    call CreateFileW
    cmp rax, INVALID_HANDLE
    je .Lop_err
    mov rbx, rax
    # directory check: GetFileAttributesW never needs a struct
    lea rcx, [rip + win_scratch16]
    call GetFileAttributesW
    mov edi, FK_FILE
    cmp eax, INVALID_FILE_ATTRIBUTES
    je .Lop_mkfd
    test eax, FILE_ATTRIBUTE_DIRECTORY
    jz .Lop_mkfd
    mov edi, FK_DIR
.Lop_mkfd:
    mov rsi, rbx
    mov rdx, r13
    and rdx, O_NONBLOCK | O_APPEND
    call win_fd_new
    test rax, rax
    jns .Lop_out
    mov r12, rax
    mov rcx, rbx
    call CloseHandle
    mov rax, r12
.Lop_out:
    EPILOGUE
.Lop_err:
    call win_last_error
    EPILOGUE

# mkdirat(dirfd, path, mode) -> 0 | -errno
FN winh_mkdirat
    PROLOGUE 32
    mov rdi, rsi
    lea rsi, [rip + win_scratch16]
    call win_utf8_to_utf16
    test rax, rax
    js .Lmk_out
    lea rcx, [rip + win_scratch16]
    xor edx, edx
    call CreateDirectoryW
    test eax, eax
    jz .Lmk_err
    xor eax, eax
.Lmk_out:
    EPILOGUE
.Lmk_err:
    call win_last_error
    EPILOGUE

# unlinkat(dirfd, path, flags) -> 0 | -errno
FN winh_unlinkat
    PROLOGUE 32
    mov rdi, rsi
    lea rsi, [rip + win_scratch16]
    call win_utf8_to_utf16
    test rax, rax
    js .Lun_out
    lea rcx, [rip + win_scratch16]
    call DeleteFileW
    test eax, eax
    jnz .Lun_ok
    call GetLastError
    cmp eax, ERROR_ACCESS_DENIED
    jne .Lun_err2
    lea rcx, [rip + win_scratch16]
    call RemoveDirectoryW
    test eax, eax
    jnz .Lun_ok
.Lun_err2:
    call win_last_error
    EPILOGUE
.Lun_ok:
    xor eax, eax
.Lun_out:
    EPILOGUE

# rename(old, new) -> 0 | -errno
FN winh_rename
    PROLOGUE 32
    mov r12, rsi                    # new
    mov rdi, rdi                    # old
    lea rsi, [rip + win_scratch16]
    call win_utf8_to_utf16
    test rax, rax
    js .Lrn_out
    mov rdi, r12
    lea rsi, [rip + win_scratch8]
    call win_utf8_to_utf16
    test rax, rax
    js .Lrn_out
    lea rcx, [rip + win_scratch16]
    lea rdx, [rip + win_scratch8]
    mov r8d, 1                      # MOVEFILE_REPLACE_EXISTING
    call MoveFileExW
    test eax, eax
    jz .Lrn_err
    xor eax, eax
.Lrn_out:
    EPILOGUE
.Lrn_err:
    call win_last_error
    EPILOGUE

# getcwd(buf, len) -> bytes incl NUL | -errno
FN winh_getcwd
    PROLOGUE 32
    mov r12, rdi                    # buf
    mov r13, rsi                    # len
    mov ecx, UTF16_MAX
    lea rdx, [rip + win_scratch16]
    call GetCurrentDirectoryW
    test eax, eax
    jz .Lgc_err
    lea rdi, [rip + win_scratch16]
    mov rsi, r12
    mov rdx, r13
    call win_utf16_to_utf8
    test rax, rax
    jns 1f
    cmp rax, -EINVAL
    jne .Lgc_out
    mov rax, -ERANGE               # conversion failed: buffer too small
    jmp .Lgc_out
1:  cmp rax, r13
    jbe .Lgc_out
    mov rax, -ERANGE
.Lgc_out:
    EPILOGUE
.Lgc_err:
    call win_last_error
    EPILOGUE

# chdir(path) -> 0 | -errno (used by a few unit tests through raw syscall)
FN winh_chdir
    PROLOGUE 32
    mov rdi, rdi
    lea rsi, [rip + win_scratch16]
    call win_utf8_to_utf16
    test rax, rax
    js .Lcd_out
    lea rcx, [rip + win_scratch16]
    call SetCurrentDirectoryW
    test eax, eax
    jz .Lcd_err
    xor eax, eax
.Lcd_out:
    EPILOGUE
.Lcd_err:
    call win_last_error
    EPILOGUE

# dup(fd) -> new fd | -errno: DuplicateHandle, so the two descriptors are
# independent (closing one does not close the other's handle).
FN winh_dup
    PROLOGUE 64
    mov r12d, edi
    call win_fd_entry
    test rax, rax
    jz .Ldp_bad
    mov rbx, rax
    call GetCurrentProcess
    mov rcx, rax
    mov rdx, [rbx + FD_HANDLE]
    mov r8, rax
    lea r9, [rsp + 56]
    mov dword ptr [rsp + 32], 0     # dwDesiredAccess (ignored)
    mov dword ptr [rsp + 40], 1     # bInheritHandle
    mov dword ptr [rsp + 48], 2     # DUPLICATE_SAME_ACCESS
    call DuplicateHandle
    test eax, eax
    jz .Ldp_err
    mov edi, [rbx + FD_KIND]
    mov rsi, [rsp + 56]
    mov rdx, [rbx + FD_FLAGS]
    call win_fd_new
    test rax, rax
    jns .Ldp_out
    mov r12, rax
    mov rcx, [rsp + 56]
    call CloseHandle
    mov rax, r12
.Ldp_out:
    EPILOGUE
.Ldp_bad:
    mov rax, -EBADF
    EPILOGUE
.Ldp_err:
    call win_last_error
    EPILOGUE

# dup2(old, new) -> new | -errno
FN winh_dup2
    PROLOGUE 64
    mov r12d, edi                   # old
    mov r13d, esi                   # new
    cmp r12d, r13d
    je .Ld2_same
    call win_fd_entry
    test rax, rax
    jz .Ld2_bad
    mov rbx, rax
    # release the target slot (fd 0/1/2 slots are just table entries)
    mov edi, r13d
    call win_fd_close
    call GetCurrentProcess
    mov rcx, rax
    mov rdx, [rbx + FD_HANDLE]
    mov r8, rax
    lea r9, [rsp + 56]
    mov dword ptr [rsp + 32], 0
    mov dword ptr [rsp + 40], 1
    mov dword ptr [rsp + 48], 2
    call DuplicateHandle
    test eax, eax
    jz .Ld2_err
    # install into the exact slot
    lea rax, [rip + win_fd_table]
    imul rcx, r13, FD_SIZE
    add rax, rcx
    mov rcx, [rsp + 56]
    mov [rax + FD_HANDLE], rcx
    mov ecx, [rbx + FD_KIND]
    mov [rax + FD_KIND], ecx
    mov rcx, [rbx + FD_FLAGS]
    mov [rax + FD_FLAGS], rcx
    mov qword ptr [rax + FD_AUX], 0
    mov eax, r13d
    EPILOGUE
.Ld2_same:
    mov eax, r13d
    EPILOGUE
.Ld2_bad:
    mov rax, -EBADF
    EPILOGUE
.Ld2_err:
    call win_last_error
    EPILOGUE

# fstat(fd, buf) -> 0 | -errno; fills the 144-byte Linux x86-64 struct stat.
# The portable consumers read st_nlink(+16), st_mode(+24) and st_size(+48).
FN winh_fstat
    PROLOGUE 64
    mov r12, rdi
    mov r13, rsi
    call win_fd_entry
    test rax, rax
    jz .Lfs_bad
    mov rbx, rax
    mov rdi, r13
    xor eax, eax
    mov ecx, 18
    rep stosq                       # 144 bytes
    mov qword ptr [r13 + STAT_NLINK], 1
    mov qword ptr [r13 + STAT_BLKSIZE], 4096
    mov eax, [rbx + FD_KIND]
    mov ecx, S_IFREG | 0644
    cmp eax, FK_FILE
    je .Lfs_mode
    mov ecx, S_IFDIR | 0755
    cmp eax, FK_DIR
    je .Lfs_mode
    mov ecx, S_IFCHR | 0620
    cmp eax, FK_CONSOLE
    je .Lfs_mode
    mov ecx, S_IFIFO | 0600
    cmp eax, FK_PIPE_R
    je .Lfs_mode
    cmp eax, FK_PIPE_W
    je .Lfs_mode
    mov ecx, S_IFSOCK | 0600
.Lfs_mode:
    mov [r13 + STAT_MODE], ecx
    mov eax, [rbx + FD_KIND]
    cmp eax, FK_FILE
    jne .Lfs_ok
    mov rcx, [rbx + FD_HANDLE]
    lea rdx, [rsp + 32]
    call GetFileSizeEx
    test eax, eax
    jz .Lfs_ok
    mov rax, [rsp + 32]
    mov [r13 + STAT_SIZE], rax
    add rax, 511
    shr rax, 9
    mov [r13 + STAT_BLOCKS], rax
.Lfs_ok:
    xor eax, eax
    EPILOGUE
.Lfs_bad:
    mov rax, -EBADF
    EPILOGUE

# lseek(fd, off, whence) -> off | -errno
FN winh_lseek
    PROLOGUE 48
    mov r12, rsi
    mov r13, rdx
    call win_fd_entry
    test rax, rax
    jz .Lls_bad
    mov rcx, [rax + FD_HANDLE]
    mov rdx, r12
    lea r8, [rsp + 32]
    mov r9, r13
    call SetFilePointerEx
    test eax, eax
    jz .Lls_err
    mov rax, [rsp + 32]
    EPILOGUE
.Lls_bad:
    mov rax, -EBADF
    EPILOGUE
.Lls_err:
    call win_last_error
    EPILOGUE

# fsync(fd) -> 0 | -errno
FN winh_fsync
    PROLOGUE 32
    call win_fd_entry
    test rax, rax
    jz .Lfy_bad
    mov rcx, [rax + FD_HANDLE]
    call FlushFileBuffers
    test eax, eax
    jz .Lfy_err
    xor eax, eax
    EPILOGUE
.Lfy_bad:
    mov rax, -EBADF
    EPILOGUE
.Lfy_err:
    call win_last_error
    EPILOGUE

# fcntl(fd, cmd, arg) -> value | -errno; only F_GETFL/F_SETFL are used.
FN winh_fcntl
    PROLOGUE 32
    mov r12d, esi
    call win_fd_entry
    test rax, rax
    jz .Lfc_bad
    cmp r12d, F_GETFL
    je .Lfc_get
    cmp r12d, F_SETFL
    je .Lfc_set
    mov rax, -ENOSYS
    EPILOGUE
.Lfc_get:
    mov rax, [rax + FD_FLAGS]
    EPILOGUE
.Lfc_set:
    mov [rax + FD_FLAGS], rdx
    xor eax, eax
    EPILOGUE
.Lfc_bad:
    mov rax, -EBADF
    EPILOGUE

# fchmod(fd, mode) -> -ENOSYS: Win32 has no POSIX mode bits (best-effort miss
# for every caller; the readonly attribute is not the same permission model).
FN winh_fchmod
    mov rax, -ENOSYS
    ret

# ---------------------------------------------------------------- memory
# mmap(addr, len, prot, flags, fd, off): os_map only requests anonymous RW.
FN winh_mmap
    test r10d, MAP_ANONYMOUS
    jz .Lmm_bad
    cmp r8, -1
    jne .Lmm_bad
    sub rsp, 40
    mov rdx, rsi                    # dwSize
    mov rcx, rdi                    # lpAddress
    mov r8d, MEM_COMMIT | MEM_RESERVE
    mov r9d, PAGE_READWRITE
    call VirtualAlloc
    add rsp, 40
    test rax, rax
    jnz .Lmm_ret
    mov rax, -ENOMEM
.Lmm_ret:
    ret
.Lmm_bad:
    mov rax, -EINVAL
    ret

# munmap(ptr, size) -> 0 | -errno
FN winh_munmap
    sub rsp, 40
    mov rcx, rdi
    xor edx, edx
    mov r8d, MEM_RELEASE
    call VirtualFree
    add rsp, 40
    test eax, eax
    jz .Lmu_bad
    xor eax, eax
    ret
.Lmu_bad:
    mov rax, -EINVAL
    ret

# ---------------------------------------------------------------- time
# clock_gettime(clock, ts): 0 realtime (Unix epoch), 1 monotonic (QPC).
FN winh_clock_gettime
    PROLOGUE 48
    mov r12, rsi
    test edi, edi
    jnz .Lcg_mono
    lea rcx, [rsp + 32]
    call GetSystemTimePreciseAsFileTime
    mov rax, [rsp + 32]
    mov r13, EPOCH_100NS
    sub rax, r13
    xor edx, edx
    mov rcx, 10000000
    div rcx
    mov [r12], rax
    imul rdx, rdx, 100
    mov [r12 + 8], rdx
    xor eax, eax
    EPILOGUE
.Lcg_mono:
    call winqpc_init
    mov r13, rax
    lea rcx, [rsp + 40]
    call QueryPerformanceCounter
    mov rax, [rsp + 40]
    xor edx, edx
    div r13
    mov [r12], rax
    mov rax, rdx
    mov rcx, 1000000000
    mul rcx
    div r13
    mov [r12 + 8], rax
    xor eax, eax
    EPILOGUE

# nanosleep(ts) -> 0 | -errno
FN winh_nanosleep
    sub rsp, 40
    mov rax, [rdi]
    imul rax, rax, 1000
    mov rcx, [rdi + 8]
    xor edx, edx
    mov r8, 1000000
    mov r9, rax
    mov rax, rcx
    div r8
    add rax, r9
    test rax, rax
    jnz .Lns_go
    mov eax, 1
.Lns_go:
    mov ecx, eax
    call Sleep
    add rsp, 40
    xor eax, eax
    ret

# getrandom(buf, len, flags) -> 0 | -errno
FN winh_getrandom
    PROLOGUE 48
    mov r12, rdi
    mov r13, rsi
    xor ecx, ecx
    mov rdx, r12
    mov r8, r13
    mov r9d, BCRYPT_USE_SYSTEM_PREFERRED_RNG
    call BCryptGenRandom
    test eax, eax
    jnz .Lgr_err
    mov rax, r13                    # getrandom returns the byte count
    EPILOGUE
.Lgr_err:
    mov rax, -EIO
    EPILOGUE

# getpid() -> pid
FN winh_getpid
    sub rsp, 40
    call GetCurrentProcessId
    add rsp, 40
    mov eax, eax
    ret

# exit_group(code): never returns.  os_exit already ran g_exit_hook.
FN winh_exit_group
    sub rsp, 40
    mov ecx, edi
    call ExitProcess
    ud2

# ---------------------------------------------------------------- poll
# poll(fds, nfds, timeout_ms) -> ready count | -errno
# Sockets go through WSAPoll with a zero timeout, pipes through
# PeekNamedPipe, consoles through GetNumberOfConsoleInputEvents; when nothing
# is ready the loop sleeps 1 ms.  This is the price of one poll interface for
# handles Windows does not poll together; opcode polls few descriptors.
FN winh_poll
    PROLOGUE 96
    mov rbx, rdi                    # pollfd array
    mov r12, rsi                    # nfds
    mov r13, rdx                    # timeout_ms
    call GetTickCount64
    mov [rsp + 80], rax
.Lpl_again:
    xor r14d, r14d
    xor r15d, r15d
.Lpl_loop:
    cmp r15, r12
    jae .Lpl_scanned
    imul rcx, r15, POLLFD_SIZE
    add rcx, rbx
    mov [rsp + 72], rcx
    mov edi, [rcx + POLLFD_FD]
    mov word ptr [rcx + POLLFD_REVENT], 0
    call win_fd_entry
    test rax, rax
    jz .Lpl_next
    mov [rsp + 64], rax
    mov rdx, [rsp + 72]
    movzx esi, word ptr [rdx + POLLFD_EVENT]
    mov [rsp + 68], esi
    mov ecx, [rax + FD_KIND]
    cmp ecx, FK_SOCKET
    je .Lpl_sock
    cmp ecx, FK_PIPE_R
    je .Lpl_pipe
    cmp ecx, FK_CONSOLE
    je .Lpl_console
    cmp ecx, FK_DIR
    je .Lpl_next
    mov eax, esi
    and eax, POLLIN | POLLOUT
    jmp .Lpl_store
.Lpl_sock:
    mov rcx, [rax + FD_HANDLE]
    mov [rsp + 32], rcx
    xor edx, edx
    test esi, POLLIN
    jz 1f
    or edx, WSAPOLLIN
1:  test esi, POLLOUT
    jz 2f
    or edx, WSAPOLLOUT
2:  mov [rsp + 40], edx
    mov word ptr [rsp + 42], 0
    lea rcx, [rsp + 32]
    mov edx, 1
    xor r8d, r8d
    call WSAPoll
    cmp eax, 1
    jne .Lpl_next
    movzx edx, word ptr [rsp + 42]
    xor esi, esi
    test edx, WSAPOLLIN
    jz 3f
    or esi, POLLIN
3:  test edx, WSAPOLLOUT
    jz 4f
    or esi, POLLOUT
4:  test edx, WSAPOLLERR
    jz 5f
    or esi, POLLERR
5:  test edx, WSAPOLLHUP
    jz 6f
    or esi, POLLHUP | POLLIN
6:  test edx, WSAPOLLNVAL
    jz 7f
    or esi, POLLERR
7:  mov eax, esi
    jmp .Lpl_store
.Lpl_pipe:
    mov rcx, [rax + FD_HANDLE]
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    lea rax, [rsp + 56]
    mov [rsp + 32], rax
    mov qword ptr [rsp + 40], 0
    call PeekNamedPipe
    test eax, eax
    jz .Lpl_pipe_err
    cmp dword ptr [rsp + 56], 0
    je .Lpl_next
    mov esi, [rsp + 68]
    and esi, POLLIN
    jmp .Lpl_ready
.Lpl_pipe_err:
    call GetLastError
    cmp eax, ERROR_BROKEN_PIPE
    je .Lpl_pipe_hup
    cmp eax, ERROR_HANDLE_EOF
    je .Lpl_pipe_hup
    cmp eax, ERROR_NOT_SUPPORTED
    je .Lpl_pipe_unknown
    cmp eax, ERROR_INVALID_FUNCTION
    je .Lpl_pipe_unknown
    jmp .Lpl_next
.Lpl_pipe_unknown:
    # Wine cannot probe the anonymous Unix pipe behind a std handle; a
    # blocking fd is reported readable (its ReadFile will wait), a
    # non-blocking one is reported not ready.
    mov rax, [rsp + 64]
    test qword ptr [rax + FD_FLAGS], O_NONBLOCK
    jnz .Lpl_next
    mov esi, [rsp + 68]
    and esi, POLLIN
    test esi, esi
    jnz .Lpl_ready
    jmp .Lpl_next
.Lpl_pipe_hup:
    mov esi, POLLHUP | POLLIN
    jmp .Lpl_ready
.Lpl_console:
    mov rcx, [rax + FD_HANDLE]
    lea rdx, [rsp + 60]
    mov dword ptr [rsp + 60], 0
    call GetNumberOfConsoleInputEvents
    test eax, eax
    jz .Lpl_next
    cmp dword ptr [rsp + 60], 0
    je .Lpl_next
    mov esi, [rsp + 68]
    and esi, POLLIN
    test esi, esi
    jnz .Lpl_ready
    jmp .Lpl_next
.Lpl_ready:
    test esi, esi
    jz .Lpl_next
    mov eax, esi
.Lpl_store:
    test ax, ax                     # revents 0 is not a ready descriptor
    jz .Lpl_next
    mov rdx, [rsp + 72]
    mov word ptr [rdx + POLLFD_REVENT], ax
    inc r14d
.Lpl_next:
    inc r15
    jmp .Lpl_loop
.Lpl_scanned:
    test r14d, r14d
    jnz .Lpl_done
    test r13d, r13d
    jz .Lpl_done
    js .Lpl_sleep
    call GetTickCount64
    sub rax, [rsp + 80]
    cmp rax, r13
    jae .Lpl_done
.Lpl_sleep:
    mov ecx, 1
    call Sleep
    jmp .Lpl_again
.Lpl_done:
    mov eax, r14d
    EPILOGUE

# ---------------------------------------------------------------- dispatch
# win_syscall: Linux syscall convention in, Linux result out; only rcx/r11
# may change.  Unknown or unimplemented numbers return -ENOSYS.
FN win_syscall
    push rbp
    mov rbp, rsp
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    # The portable corpus calls this from both aligned and 8-mod-16 frames
    # (leaf `os_*` wrappers vs PROLOGUE users); Win32 requires a 16-byte
    # aligned stack, so normalize unconditionally.
    and rsp, -16
    cmp eax, 0
    je .Lws_read
    cmp eax, 1
    je .Lws_write
    cmp eax, 3
    je .Lws_close
    cmp eax, 5
    je .Lws_fstat
    cmp eax, 7
    je .Lws_poll
    cmp eax, 8
    je .Lws_lseek
    cmp eax, 9
    je .Lws_mmap
    cmp eax, 11
    je .Lws_munmap
    cmp eax, 32
    je .Lws_dup
    cmp eax, 33
    je .Lws_dup2
    cmp eax, 35
    je .Lws_nanosleep
    cmp eax, 39
    je .Lws_getpid
    cmp eax, 41
    je .Lws_socket
    cmp eax, 42
    je .Lws_connect
    cmp eax, 44
    je .Lws_send
    cmp eax, 45
    je .Lws_recv
    cmp eax, 48
    je .Lws_shutdown
    cmp eax, 49
    je .Lws_bind
    cmp eax, 50
    je .Lws_listen
    cmp eax, 51
    je .Lws_getsockname
    cmp eax, 54
    je .Lws_setsockopt
    cmp eax, 55
    je .Lws_getsockopt
    cmp eax, 72
    je .Lws_fcntl
    cmp eax, 74
    je .Lws_fsync
    cmp eax, 79
    je .Lws_getcwd
    cmp eax, 80
    je .Lws_chdir
    cmp eax, 82
    je .Lws_rename
    cmp eax, 91
    je .Lws_fchmod
    cmp eax, 228
    je .Lws_clock
    cmp eax, 231
    je .Lws_exit
    cmp eax, 257
    je .Lws_openat
    cmp eax, 258
    je .Lws_mkdirat
    cmp eax, 263
    je .Lws_unlinkat
    cmp eax, 288
    je .Lws_accept4
    cmp eax, 318
    je .Lws_getrandom
    mov rax, -ENOSYS
    jmp .Lws_done
.Lws_read:
    call winh_read
    jmp .Lws_done
.Lws_write:
    call winh_write
    jmp .Lws_done
.Lws_close:
    call win_fd_close
    jmp .Lws_done
.Lws_fstat:
    call winh_fstat
    jmp .Lws_done
.Lws_poll:
    call winh_poll
    jmp .Lws_done
.Lws_lseek:
    call winh_lseek
    jmp .Lws_done
.Lws_mmap:
    call winh_mmap
    jmp .Lws_done
.Lws_munmap:
    call winh_munmap
    jmp .Lws_done
.Lws_dup:
    call winh_dup
    jmp .Lws_done
.Lws_dup2:
    call winh_dup2
    jmp .Lws_done
.Lws_nanosleep:
    call winh_nanosleep
    jmp .Lws_done
.Lws_getpid:
    call winh_getpid
    jmp .Lws_done
.Lws_socket:
    call winh_socket
    jmp .Lws_done
.Lws_connect:
    call winh_connect
    jmp .Lws_done
.Lws_send:
    call winh_send
    jmp .Lws_done
.Lws_recv:
    call winh_recv
    jmp .Lws_done
.Lws_shutdown:
    call winh_shutdown
    jmp .Lws_done
.Lws_bind:
    call winh_bind
    jmp .Lws_done
.Lws_listen:
    call winh_listen
    jmp .Lws_done
.Lws_getsockname:
    call winh_getsockname
    jmp .Lws_done
.Lws_setsockopt:
    call winh_setsockopt
    jmp .Lws_done
.Lws_getsockopt:
    call winh_getsockopt
    jmp .Lws_done
.Lws_fcntl:
    call winh_fcntl
    jmp .Lws_done
.Lws_fsync:
    call winh_fsync
    jmp .Lws_done
.Lws_getcwd:
    call winh_getcwd
    jmp .Lws_done
.Lws_chdir:
    call winh_chdir
    jmp .Lws_done
.Lws_rename:
    call winh_rename
    jmp .Lws_done
.Lws_fchmod:
    call winh_fchmod
    jmp .Lws_done
.Lws_clock:
    call winh_clock_gettime
    jmp .Lws_done
.Lws_exit:
    call winh_exit_group
    jmp .Lws_done
.Lws_openat:
    call winh_openat
    jmp .Lws_done
.Lws_mkdirat:
    call winh_mkdirat
    jmp .Lws_done
.Lws_unlinkat:
    call winh_unlinkat
    jmp .Lws_done
.Lws_accept4:
    call winh_accept4
    jmp .Lws_done
.Lws_getrandom:
    call winh_getrandom
.Lws_done:
    mov rsp, rbp
    sub rsp, 64
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbp
    ret
