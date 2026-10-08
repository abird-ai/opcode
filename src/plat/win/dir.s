.include "opcode.inc"
.include "plat/win/win.inc"
# win: Layer 0 directory reads (replaces src/plat/linux/dir.s).
#
# os_getdents(fd, buf, len) emits the same Linux getdents64 records the
# portable consumers parse:
#   u64 ino; s64 off; u16 reclen; u8 type; char name[]   (name at +19)
# type: 4 = directory, 8 = regular.  The directory is enumerated with
# FindFirstFileW/FindNextFileW; the path is recovered from the handle with
# GetFinalPathNameByHandleW on first use, so os_open does not have to keep
# the path alive.  Win32 find handles cannot be polled, so no revents are
# produced for a directory fd.

.equ DIR_AUX_SIZE, 4096
.equ DIR_FIND, 0                    # HANDLE find
.equ DIR_DATA, 8                    # WIN32_FIND_DATAW (592 bytes)
.equ DIR_DONE, 600                  # dword: enumeration finished
.equ DIR_PATH, 1024                 # UTF-16 search pattern

.text

# dir_start(entry) -> aux | 0
FN dir_start
    PROLOGUE 48
    mov rbx, rdi
    mov rcx, 0
    mov edx, DIR_AUX_SIZE
    mov r8d, MEM_COMMIT | MEM_RESERVE
    mov r9d, PAGE_READWRITE
    call VirtualAlloc
    test rax, rax
    jz .Lds_out
    mov r12, rax
    mov rcx, [rbx + FD_HANDLE]
    lea rdx, [r12 + DIR_PATH]
    mov r8d, 1000
    xor r9d, r9d
    call GetFinalPathNameByHandleW
    test eax, eax
    jz .Lds_free
    # append "\*"
    lea rdx, [r12 + DIR_PATH]
    mov ecx, eax
    lea rdx, [rdx + rcx * 2]
    mov word ptr [rdx], 0x5C
    mov word ptr [rdx + 2], '*'
    mov word ptr [rdx + 4], 0
    lea rcx, [r12 + DIR_PATH]
    lea rdx, [r12 + DIR_DATA]
    call FindFirstFileW
    cmp rax, INVALID_HANDLE
    je .Lds_free
    mov [r12 + DIR_FIND], rax
    mov dword ptr [r12 + DIR_DONE], 0
    mov [rbx + FD_AUX], r12
    mov rax, r12
    EPILOGUE
.Lds_free:
    mov rcx, r12
    xor edx, edx
    mov r8d, MEM_RELEASE
    call VirtualFree
    xor eax, eax
    EPILOGUE
.Lds_out:
    xor eax, eax
    EPILOGUE

# os_getdents(fd, buf, len) -> bytes | -errno
FN os_getdents
    PROLOGUE 96
    mov r12d, edi                   # fd
    mov r13, rsi                    # buf
    mov r14, rdx                    # len
    call win_fd_entry
    test rax, rax
    jz .Lgd_bad
    mov rbx, rax
    cmp dword ptr [rbx + FD_KIND], FK_DIR
    jne .Lgd_notdir
    mov rdi, rbx
    mov rax, [rbx + FD_AUX]
    test rax, rax
    jnz .Lgd_have
    call dir_start
    test rax, rax
    jz .Lgd_err
.Lgd_have:
    mov [rsp + 88], rax             # aux
    xor r15, r15                    # bytes written
.Lgd_loop:
    mov rax, [rsp + 88]
    cmp dword ptr [rax + DIR_DONE], 0
    jne .Lgd_done
    # name = data.cFileName (data + 44)
    lea rdi, [rax + DIR_DATA + 44]
    lea rsi, [rip + win_scratch8]
    mov edx, 4096
    call win_utf16_to_utf8
    test rax, rax
    js .Lgd_err
    dec rax                         # name length without NUL
    mov [rsp + 80], rax             # namelen
    # reclen = align8(20 + namelen)
    lea rcx, [rax + 20]
    add rcx, 7
    and rcx, ~7
    mov [rsp + 72], rcx             # reclen
    # does it fit?
    mov rax, r15
    add rax, rcx
    cmp rax, r14
    ja .Lgd_full
    # write the record
    lea rdx, [r13 + r15]
    mov qword ptr [rdx], 0          # ino
    mov qword ptr [rdx + 8], 0      # off
    mov rcx, [rsp + 72]
    mov word ptr [rdx + 16], cx     # d_reclen
    mov rax, [rsp + 88]
    mov eax, [rax + DIR_DATA]       # dwFileAttributes
    mov byte ptr [rdx + 18], 8
    test eax, FILE_ATTRIBUTE_DIRECTORY
    jz 1f
    mov byte ptr [rdx + 18], 4
1:  # copy the name (including NUL)
    lea rsi, [rip + win_scratch8]
    lea rdi, [rdx + 19]
    mov rcx, [rsp + 80]
    inc rcx
    rep movsb
    add r15, [rsp + 72]
    # advance
    mov rax, [rsp + 88]
    mov rcx, [rax + DIR_FIND]
    mov rdx, [rsp + 88]
    lea rdx, [rdx + DIR_DATA]
    call FindNextFileW
    test eax, eax
    jnz .Lgd_loop
    call GetLastError
    cmp eax, 18                     # ERROR_NO_MORE_FILES
    jne .Lgd_err
    mov rax, [rsp + 88]
    mov dword ptr [rax + DIR_DONE], 1
    jmp .Lgd_loop
.Lgd_full:
    test r15, r15
    jnz .Lgd_done
    mov rax, -EINVAL
    EPILOGUE
.Lgd_done:
    mov rax, r15
    EPILOGUE
.Lgd_bad:
    mov rax, -EBADF
    EPILOGUE
.Lgd_notdir:
    mov rax, -ENOTDIR
    EPILOGUE
.Lgd_err:
    call win_last_error
    EPILOGUE
