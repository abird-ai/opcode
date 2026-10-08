.include "opcode.inc"
# win: Microsoft-x64-ABI entry points for compiler-generated libcalls.
#
# The mbedTLS/glue C objects are compiled for Windows (Microsoft x64 ABI) but
# the assembly corpus uses opcode's internal SysV-shaped convention.  The glue
# declares these `opcode_*_int` functions with __attribute__((sysv_abi)); each
# thunk hands off to the real internal-ABI body in src/base/str.s.

.text

FN opcode_memcpy_int
    jmp memcpy

FN opcode_memmove_int
    jmp memmove

FN opcode_memset_int
    jmp memset

FN opcode_strlen_int
    jmp strlen
