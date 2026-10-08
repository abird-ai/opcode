# plat: Layer 0 contract. The core includes this file for documentation only;
# symbols resolve at link time to exactly one implementation directory:
#
#   src/plat/linux/*.s    raw linux syscalls
#   src/plat/mac/*.s      libSystem (later)
#   src/plat/win/*.s      Win32 (implemented; see .agents/docs/ports.md §3)
#   src/plat/headless.s   deterministic backend for tests (later)
#
# Rules:
#   - All functions return in rax; failures are negative linux errno values.
#   - Two-value returns use rax/rdx.
#   - Buffers are caller-owned; nothing here allocates except os_map.
#   - No core file may include an OS header or call an OS API directly.
#
# Contract (see .agents/docs/platform.md for full semantics):
#
#   os_init(rsp)                      record argc/argv/envp
#   os_exit(code)                    never returns
#   os_open(path, flags, mode)       -> fd
#   os_read(fd, buf, len)            -> n | -errno
#   os_write(fd, buf, len)           -> n | -errno
#   os_close(fd)                     -> 0 | -errno
#   os_lseek(fd, off, whence)        -> off | -errno
#   os_fstat(fd, statbuf)            -> 0 | -errno
#   os_mkdir(path, mode)             -> 0 | -errno
#   os_unlink(path)                  -> 0 | -errno
#   os_getcwd(buf, len)              -> n | -errno
#   os_platform()                    -> "linux" | "macos" (system-prompt text)
#   os_map(size)                     -> ptr          (dies on failure)
#   os_map_try(size)                 -> ptr | 0
#   os_unmap(ptr, size)              -> 0 | -errno
#   os_now_ns(clock)                 -> nanoseconds  (0=realtime 1=monotonic)
#   os_sleep_ns(ns)
#   os_random(buf, len)              -> 0 | -errno
#   os_poll(pollfds, nfds, timeout_ms) -> n | -errno
#   os_fcntl(fd, cmd, arg)           -> 0 | value | -errno
#   os_setsockopt(fd, level, optname, val_ptr, val_len) -> 0 | -errno
#
# pollfd: { i32 fd; i16 events; i16 revents } (8 bytes)

# Socket option constants, in the Linux numbering the portable layers use; the
# Darwin and Win32 shims translate them at the syscall boundary.  Keep in sync
# with src/net/net.inc (SOL_SOCKET / SO_ERROR) and src/core/oauth.s.
.equ SOL_SOCKET,    1
.equ SO_REUSEADDR,  2
.equ IPPROTO_IPV6,  41
.equ IPV6_V6ONLY,   26
