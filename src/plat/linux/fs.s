.include "opcode.inc"
# linux x86-64 layer 0: file-name and durability syscalls. Direct syscalls,
# negative-errno returns, leaf functions. Contract: src/plat/plat.inc / API.md.

.equ SYS_rename, 82
.equ SYS_fsync,  74
.equ SYS_fcntl,  72
.equ SYS_fchmod, 91

.text

# os_rename(old, new) -> 0 | -errno
FN os_rename
    SYS SYS_rename
    ret

# os_fsync(fd) -> 0 | -errno
FN os_fsync
    SYS SYS_fsync
    ret

# os_fcntl(fd, cmd, arg) -> 0 | value | -errno
FN os_fcntl
    SYS SYS_fcntl
    ret

# os_fchmod(fd, mode) -> 0 | -errno.  Backends that do not implement the
# syscall (the Darwin and aarch64 shims) return -ENOSYS; callers must treat
# that as a best-effort miss rather than a hard failure.
FN os_fchmod
    SYS SYS_fchmod
    ret
