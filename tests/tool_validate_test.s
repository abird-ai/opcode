.include "opcode.inc"
.include "core/core.inc"
# tool_validate_test: the schema-driven required/type validator for the
# built-ins.  Each line is "<name> ok" or "<name> FAIL"; any FAIL sets the
# exit code.  Golden: tests/data/tool_validate_test.expected
#
# The validator must reject a missing required field, an explicit null, and a
# field of the wrong JSON type, while accepting a correct object and an
# optional field of the declared type.

.bss
.p2align 3
fail: .zero 4

.section .rodata
.Lok:    .asciz " ok\n"
.Lbad:   .asciz " FAIL\n"
.Lread:  .asciz "read"
.Lwrite: .asciz "write"
.Ledit:  .asciz "edit"

# ---- read: required path, optional integer offset/limit
.Lc_read_ok:      .asciz "read.required"
.La_read_ok:      .asciz "{\"path\":\"x\"}"
.Lc_read_missing: .asciz "read.missing"
.La_read_missing: .asciz "{}"
.Lc_read_null:    .asciz "read.null"
.La_read_null:    .asciz "{\"path\":null}"
.Lc_read_wrong:   .asciz "read.wrongtype"
.La_read_wrong:   .asciz "{\"path\":123}"
.Lc_read_opt_ok:  .asciz "read.optional-ok"
.La_read_opt_ok:  .asciz "{\"path\":\"x\",\"offset\":3,\"limit\":1}"

# ---- write: required path + content, both strings
.Lc_write_ok:      .asciz "write.required"
.La_write_ok:      .asciz "{\"path\":\"x\",\"content\":\"y\"}"
.Lc_write_no_path: .asciz "write.missing-path"
.La_write_no_path: .asciz "{\"content\":\"y\"}"
.Lc_write_no_cont: .asciz "write.missing-content"
.La_write_no_cont: .asciz "{\"path\":\"x\"}"
.Lc_write_wrong:   .asciz "write.wrongtype"
.La_write_wrong:   .asciz "{\"path\":\"x\",\"content\":7}"

# ---- edit: required path + edits array
.Lc_edit_ok:      .asciz "edit.required"
.La_edit_ok:      .asciz "{\"path\":\"x\",\"edits\":[]}"
.Lc_edit_no_path: .asciz "edit.missing-path"
.La_edit_no_path: .asciz "{\"edits\":[]}"
.Lc_edit_no_ed:   .asciz "edit.missing-edits"
.La_edit_no_ed:   .asciz "{\"path\":\"x\"}"
.Lc_edit_wrong:   .asciz "edit.wrongtype"
.La_edit_wrong:   .asciz "{\"path\":\"x\",\"edits\":\"no\"}"

.text

# print(cstr)
print:
    push rdi
    call strlen
    pop rdi
    mov rdx, rax
    mov rsi, rdi
    mov edi, 1
    jmp write_all

# case4(casename cstr, tool cstr, args cstr, want_zero ecx): call
# tool_validate and print "<casename> ok" when (result == 0) == want_zero,
# else "<casename> FAIL".
case4:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15d, ecx
    mov rdi, r13
    mov rsi, r14
    call tool_validate
    test eax, eax
    setz al
    movzx eax, al
    cmp eax, r15d
    je .Lc4_ok
    mov rdi, r12
    call print
    lea rdi, [rip + .Lbad]
    call print
    mov dword ptr [rip + fail], 1
    EPILOGUE
.Lc4_ok:
    mov rdi, r12
    call print
    lea rdi, [rip + .Lok]
    call print
    EPILOGUE

FN opcode_main
    PROLOGUE
    call tools_init

    # ---- read
    lea rdi, [rip + .Lc_read_ok]
    lea rsi, [rip + .Lread]
    lea rdx, [rip + .La_read_ok]
    mov ecx, 1
    call case4
    lea rdi, [rip + .Lc_read_missing]
    lea rsi, [rip + .Lread]
    lea rdx, [rip + .La_read_missing]
    xor ecx, ecx
    call case4
    lea rdi, [rip + .Lc_read_null]
    lea rsi, [rip + .Lread]
    lea rdx, [rip + .La_read_null]
    xor ecx, ecx
    call case4
    lea rdi, [rip + .Lc_read_wrong]
    lea rsi, [rip + .Lread]
    lea rdx, [rip + .La_read_wrong]
    xor ecx, ecx
    call case4
    lea rdi, [rip + .Lc_read_opt_ok]
    lea rsi, [rip + .Lread]
    lea rdx, [rip + .La_read_opt_ok]
    mov ecx, 1
    call case4

    # ---- write
    lea rdi, [rip + .Lc_write_ok]
    lea rsi, [rip + .Lwrite]
    lea rdx, [rip + .La_write_ok]
    mov ecx, 1
    call case4
    lea rdi, [rip + .Lc_write_no_path]
    lea rsi, [rip + .Lwrite]
    lea rdx, [rip + .La_write_no_path]
    xor ecx, ecx
    call case4
    lea rdi, [rip + .Lc_write_no_cont]
    lea rsi, [rip + .Lwrite]
    lea rdx, [rip + .La_write_no_cont]
    xor ecx, ecx
    call case4
    lea rdi, [rip + .Lc_write_wrong]
    lea rsi, [rip + .Lwrite]
    lea rdx, [rip + .La_write_wrong]
    xor ecx, ecx
    call case4

    # ---- edit
    lea rdi, [rip + .Lc_edit_ok]
    lea rsi, [rip + .Ledit]
    lea rdx, [rip + .La_edit_ok]
    mov ecx, 1
    call case4
    lea rdi, [rip + .Lc_edit_no_path]
    lea rsi, [rip + .Ledit]
    lea rdx, [rip + .La_edit_no_path]
    xor ecx, ecx
    call case4
    lea rdi, [rip + .Lc_edit_no_ed]
    lea rsi, [rip + .Ledit]
    lea rdx, [rip + .La_edit_no_ed]
    xor ecx, ecx
    call case4
    lea rdi, [rip + .Lc_edit_wrong]
    lea rsi, [rip + .Ledit]
    lea rdx, [rip + .La_edit_wrong]
    xor ecx, ecx
    call case4

    mov eax, [rip + fail]
    EPILOGUE
