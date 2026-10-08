# dir: Layer 0 directory reads. Linux getdents64 records:
#   u64 ino; s64 off; u16 reclen; u8 type; char name[]  (name at +19)
# type: 4 = directory, 8 = regular, 0 = unknown
.include "opcode.inc"

# os_getdents(fd, buf, len) -> bytes | -errno
FN os_getdents
    mov eax, 217
    syscall
    ret
