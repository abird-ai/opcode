.include "opcode.inc"
.include "core/core.inc"
# ext/plugin.s — static plugin loader (M6).
#
# The build is static/nostdlib, so plugins cannot be dlopen'd.  Instead
# tools/gen-plugins.py emits build/plugins.s:
#
#   opcode_plugin_count: .quad N
#   opcode_plugin_table: {init, name cstr, manifest index} * N
#
# plugins_init walks it, calls opcode_plugin_init(host, &out) per entry,
# validates the frozen ABI (abi_version == 1, struct_size >= 40), logs
# "opcode: plugin <name> v<version> loaded" and returns the number loaded.
# An empty table is skipped silently.  Call after tools_init() so plugin tools
# join the core registry.

.equ FP_abi,     0
.equ FP_size,    4
.equ FP_name,    8
.equ FP_version, 16
.equ FP_init,    24
.equ FP_SIZE,    72
.equ FP_MIN_SIZE, 40              # through shutdown; append-only ABI

.section .rodata
.Lplug_prefix:   .asciz "opcode: plugin "
.Lplug_v:        .asciz " v"
.Lplug_loaded:   .asciz " loaded\n"
.Lplug_initfail: .asciz " init failed\n"
.Lplug_badabi:   .asciz " has incompatible ABI\n"

.section .bss
.p2align 3
p_plugin: .zero FP_SIZE

.text

# plugins_init() -> n loaded
FN plugins_init
    PROLOGUE
    mov r12, [rip + opcode_plugin_count]
    test r12, r12
    jz .Lpi_ret
    xor r13d, r13d                # manifest index
    xor r14d, r14d                # loaded count
.Lpi_loop:
    cmp r13, r12
    jae .Lpi_done
    lea rax, [rip + opcode_plugin_table]
    lea rcx, [r13 + r13*2]
    lea r15, [rax + rcx*8]
    mov rax, [r15]
    test rax, rax
    jz .Lpi_next
    lea rdi, [rip + p_plugin]
    xor esi, esi
    mov edx, FP_SIZE
    call memset
    call opcode_host
    mov rdi, rax
    lea rsi, [rip + p_plugin]
    call qword ptr [r15]
    test eax, eax
    jnz .Lpi_fail
    lea rax, [rip + p_plugin]
    cmp dword ptr [rax + FP_abi], 1
    jne .Lpi_bad
    cmp dword ptr [rax + FP_size], FP_MIN_SIZE
    jb .Lpi_bad
    # the ABI's registration point: call the plugin's init(host) hook once
    cmp qword ptr [rax + FP_init], 0
    je .Lpi_loaded
    call opcode_host
    mov rdi, rax
    mov rax, [rip + p_plugin + FP_init]
    call rax
    test eax, eax
    jnz .Lpi_fail
.Lpi_loaded:
    lea rdi, [rip + .Lplug_prefix]
    call log_cstr
    mov rdi, [rip + p_plugin + FP_name]
    test rdi, rdi
    jz 1f
    call log_cstr
1:  lea rdi, [rip + .Lplug_v]
    call log_cstr
    mov rdi, [rip + p_plugin + FP_version]
    test rdi, rdi
    jz 2f
    call log_cstr
2:  lea rdi, [rip + .Lplug_loaded]
    call log_cstr
    inc r14
.Lpi_next:
    inc r13
    jmp .Lpi_loop
.Lpi_fail:
    lea rdi, [rip + .Lplug_prefix]
    call log_cstr
    mov rdi, [rip + p_plugin + FP_name]
    test rdi, rdi
    jz 3f
    call log_cstr
3:  lea rdi, [rip + .Lplug_initfail]
    call log_cstr
    jmp .Lpi_next
.Lpi_bad:
    lea rdi, [rip + .Lplug_prefix]
    call log_cstr
    mov rdi, [rip + p_plugin + FP_name]
    test rdi, rdi
    jz 4f
    call log_cstr
4:  lea rdi, [rip + .Lplug_badabi]
    call log_cstr
    jmp .Lpi_next
.Lpi_done:
    mov rax, r14
    EPILOGUE
.Lpi_ret:
    xor eax, eax
    EPILOGUE
