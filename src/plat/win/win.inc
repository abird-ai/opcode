# win.inc: Windows x86-64 Layer 0 constants and ABI notes.
#
# Opcode's x86-64 corpus is written against the Linux ABI.  On Windows the
# portable and src/plat/linux wrappers are assembled unchanged with
# `as --defsym WINDOWS=1`: opcode.inc's SYS macro then lowers `SYS n` to
# `mov eax, n; call win_syscall` instead of the syscall instruction.  This
# header holds the Win32 constants and the fd-table layout that win_syscall,
# proc.s, tty.s and dir.s share.
#
# win_syscall ABI: exactly the Linux syscall convention.
#   in : eax = Linux syscall number, rdi rsi rdx r10 r8 r9 = arguments
#   out: rax = result or -errno (Linux numbering)
#   clobbers: rcx, r11 only (all other registers are preserved by the
#             dispatcher, so portable `syscall` call sites keep working)
# No call here may return 0 for work it did not do.

# ---------------------------------------------------------------- errno
.equ ESRCH,  3
.equ EBADF,  9
.equ EFAULT, 14
.equ EBUSY,  16
.equ EEXIST, 17
.equ EXDEV,  18
.equ EMFILE, 24
.equ EFBIG,  27
.equ ESPIPE, 29
.equ ETXTBSY, 26
.equ ENAMETOOLONG, 36
.equ ENOTEMPTY, 39
.equ ELOOP,  40
.equ EOVERFLOW, 75
.equ EMSGSIZE, 90
.equ EPROTONOSUPPORT, 93
.equ EAFNOSUPPORT, 97
.equ EADDRINUSE, 98
.equ EADDRNOTAVAIL, 99
.equ ENETDOWN, 100
.equ ENETUNREACH, 101
.equ ECONNABORTED, 103
.equ ECONNRESET, 104
.equ ENOBUFS, 105
.equ ECONNREFUSED, 111
.equ EHOSTUNREACH, 113
.equ EALREADY, 114

.equ INVALID_HANDLE, -1

# ---------------------------------------------------------------- fd table
# Small integer descriptors are the contract (pollfd.fd is i32); the table
# maps them to Win32 handles.  fd 0/1/2 are the process standard handles.
.equ FD_MAX,  256
.equ FD_SIZE, 32
.equ FD_HANDLE, 0               # HANDLE / SOCKET
.equ FD_KIND,   8
.equ FD_FLAGS,  16              # O_* bits (O_NONBLOCK, O_APPEND, ...)
.equ FD_AUX,    24              # win_dir state for FD_KIND_DIR

.equ FK_NONE,   0
.equ FK_FILE,   1
.equ FK_DIR,    2
.equ FK_PIPE_R, 3
.equ FK_PIPE_W, 4
.equ FK_CONSOLE, 5
.equ FK_SOCKET, 6

.equ SEEK_SET, 0
.equ SEEK_CUR, 1
.equ SEEK_END, 2

# ---------------------------------------------------------------- files
.equ GENERIC_READ,  0x80000000
.equ GENERIC_WRITE, 0x40000000
.equ FILE_APPEND_DATA, 4
.equ FILE_SHARE_READ, 1
.equ FILE_SHARE_WRITE, 2
.equ FILE_SHARE_DELETE, 4
.equ CREATE_NEW, 1
.equ CREATE_ALWAYS, 2
.equ OPEN_EXISTING, 3
.equ OPEN_ALWAYS, 4
.equ TRUNCATE_EXISTING, 5
.equ FILE_ATTRIBUTE_READONLY, 1
.equ FILE_ATTRIBUTE_NORMAL, 0x80
.equ FILE_ATTRIBUTE_DIRECTORY, 0x10
.equ FILE_FLAG_BACKUP_SEMANTICS, 0x02000000
.equ INVALID_FILE_ATTRIBUTES, -1
.equ FILE_BEGIN, 0
.equ FILE_CURRENT, 1
.equ FILE_END, 2

# GetFileType
.equ FILE_TYPE_UNKNOWN, 0
.equ FILE_TYPE_DISK, 1
.equ FILE_TYPE_CHAR, 2
.equ FILE_TYPE_PIPE, 3

# GetLastError values
.equ ERROR_INVALID_FUNCTION, 1
.equ ERROR_FILE_NOT_FOUND, 2
.equ ERROR_PATH_NOT_FOUND, 3
.equ ERROR_ACCESS_DENIED, 5
.equ ERROR_INVALID_HANDLE, 6
.equ ERROR_NOT_ENOUGH_MEMORY, 8
.equ ERROR_WRITE_PROTECT, 19
.equ ERROR_SHARING_VIOLATION, 32
.equ ERROR_LOCK_VIOLATION, 33
.equ ERROR_HANDLE_EOF, 38
.equ ERROR_NOT_SUPPORTED, 50
.equ ERROR_NOT_SAME_DEVICE, 17
.equ ERROR_FILE_EXISTS, 80
.equ ERROR_INVALID_PARAMETER, 87
.equ ERROR_BROKEN_PIPE, 109
.equ ERROR_DISK_FULL, 112
.equ ERROR_NEGATIVE_SEEK, 131
.equ ERROR_ALREADY_EXISTS, 183
.equ ERROR_FILENAME_EXCED_RANGE, 206
.equ ERROR_DIRECTORY_NOT_EMPTY, 145
.equ ERROR_NO_DATA, 232
.equ ERROR_OPERATION_ABORTED, 995

# ---------------------------------------------------------------- memory
.equ MEM_COMMIT,  0x1000
.equ MEM_RESERVE, 0x2000
.equ MEM_RELEASE, 0x8000
.equ PAGE_READWRITE, 4
.equ PAGE_NOACCESS, 1

# ---------------------------------------------------------------- time
# FILETIME epoch (1601-01-01) to Unix epoch (1970-01-01) in 100 ns units.
.equ EPOCH_100NS, 116444736000000000
.equ TICKS_PER_SEC, 1000000000

# ---------------------------------------------------------------- processes
.equ STD_INPUT_HANDLE,  -10
.equ STD_OUTPUT_HANDLE, -11
.equ STD_ERROR_HANDLE,  -12
.equ STARTF_USESTDHANDLES, 0x100
.equ CREATE_UNICODE_ENVIRONMENT, 0x400
.equ CREATE_SUSPENDED, 0x4
.equ INFINITE, 0xFFFFFFFF
.equ WAIT_OBJECT_0, 0
.equ WAIT_TIMEOUT, 0x102
.equ WAIT_FAILED, 0xFFFFFFFF
.equ HANDLE_FLAG_INHERIT, 1
.equ JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE, 0x2000
.equ JobObjectExtendedLimitInformation, 9

# ---------------------------------------------------------------- console
.equ ENABLE_PROCESSED_INPUT, 1
.equ ENABLE_LINE_INPUT, 2
.equ ENABLE_ECHO_INPUT, 4
.equ ENABLE_WINDOW_INPUT, 8
.equ ENABLE_MOUSE_INPUT, 0x10
.equ ENABLE_VIRTUAL_TERMINAL_INPUT, 0x200
.equ ENABLE_PROCESSED_OUTPUT, 1
.equ ENABLE_WRAP_AT_EOL_OUTPUT, 2
.equ ENABLE_VIRTUAL_TERMINAL_PROCESSING, 4
.equ DISABLE_NEWLINE_AUTO_RETURN, 8
.equ KEY_EVENT, 1
.equ WINDOW_BUFFER_SIZE_EVENT, 4
.equ CTRL_C_EVENT, 0
.equ CTRL_BREAK_EVENT, 1

# ---------------------------------------------------------------- sockets
.equ AF_INET, 2
.equ SOCK_DGRAM, 2
.equ SOCK_STREAM, 1
.equ SOCK_NONBLOCK, 0x800
.equ SOCK_CLOEXEC, 0x80000
.equ SOL_SOCKET, 0xFFFF
.equ SO_ERROR, 0x1007
.equ SO_REUSEADDR, 4
.equ TCP_NODELAY, 1
.equ IPPROTO_TCP, 6
.equ FIONBIO, 0x8004667E
.equ FIONREAD, 0x4004667F
.equ MSG_NOSIGNAL, 0x4000
.equ WSAEWOULDBLOCK, 10035
.equ WSAEINPROGRESS, 10036
.equ WSAEALREADY, 10037
.equ WSAENOTSOCK, 10038
.equ WSAEMSGSIZE, 10040
.equ WSAEPROTONOSUPPORT, 10043
.equ WSAEAFNOSUPPORT, 10047
.equ WSAEADDRINUSE, 10048
.equ WSAEADDRNOTAVAIL, 10049
.equ WSAENETUNREACH, 10051
.equ WSAECONNABORTED, 10053
.equ WSAECONNRESET, 10054
.equ WSAENOBUFS, 10055
.equ WSAETIMEDOUT, 10060
.equ WSAECONNREFUSED, 10061
.equ WSAEHOSTUNREACH, 10065
.equ WSAEACCES, 10013
.equ WSAEMFILE, 10024
.equ WSAEINVAL, 10022
.equ WSABASEERR, 10000
.equ WSAPOLLIN, 0x0100
.equ WSAPOLLOUT, 0x0010
.equ WSAPOLLERR, 0x0001
.equ WSAPOLLHUP, 0x0002
.equ WSAPOLLNVAL, 0x0004
.equ SD_RECEIVE, 0
.equ SD_SEND, 1
.equ SD_BOTH, 2
.equ WSA_FLAG_OVERLAPPED, 1
.equ WSADATA_SIZE, 408
.equ BCRYPT_USE_SYSTEM_PREFERRED_RNG, 2

# ---------------------------------------------------------------- misc
.equ CP_UTF8, 65001
.equ MB_ERR_INVALID_CHARS, 8
.equ UTF16_MAX, 32768           # path/argv scratch in UTF-16 code units
.equ STACK_SIZE, 16 << 20       # the x86 model gets its own stack, like mac
.equ POLLFD_SIZE, 8
.equ POLLFD_FD, 0
.equ POLLFD_EVENT, 4
.equ POLLFD_REVENT, 6

# WSAPOLLFD is not the Linux pollfd: SOCKET is 64-bit.
.equ WPOLLFD_SIZE, 16
.equ WPOLLFD_FD, 0
.equ WPOLLFD_EVENT, 8
.equ WPOLLFD_REVENT, 10

# ---------------------------------------------------------------- stat/mode
.equ S_IFIFO,  0x1000
.equ S_IFCHR,  0x2000
.equ S_IFDIR,  0x4000
.equ S_IFREG,  0x8000
.equ S_IFSOCK, 0xC000

# fcntl commands used by the corpus
.equ F_GETFL, 3
.equ F_SETFL, 4

# statbuf is the Linux x86-64 144-byte struct stat
.equ STAT_NLINK, 16
.equ STAT_MODE,  24
.equ STAT_SIZE,  48
.equ STAT_BLKSIZE, 56
.equ STAT_BLOCKS, 64

.equ ENOTTY, 25
