# opcode -p/--print: one-shot print front end.  Flag parsing, template
# expansion and session resolution are shared in src/app/cli.s; argv[0] is the
# -p/--print marker, so the parse starts at argv[1].
.include "opcode.inc"
.include "core/core.inc"

.text

# opcode_print_main(argc, argv) -> exit code
FN opcode_print_main
    PROLOGUE
    lea rdi, [rdi - 1]
    lea rsi, [rsi + 8]
    mov edx, CK_PRINT
    call cli_parse
    test eax, eax
    jnz .Lpm_ret
    call config_load
    call cli_expand_prompt
    test eax, eax
    jnz .Lpm_fail
    call cli_require_prompt
    test eax, eax
    jnz .Lpm_ret
    # first-run onboarding: no provider resolvable anywhere -> explain or menu
    call onboard_maybe
    test eax, eax
    jnz .Lpm_ret
    call cli_open_session
    test eax, eax
    jnz .Lpm_fail
    mov rdi, [rip + cl_prompt + SB_ptr]
    call agent_run
    EPILOGUE
.Lpm_fail:
    mov eax, 1
.Lpm_ret:
    EPILOGUE
