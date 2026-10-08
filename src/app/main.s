# opcode entry: argument parsing and mode dispatch.
# M0: --version and --help only; the agent core is added in later milestones.
.include "opcode.inc"

.section .rodata
.Lprefix:       .asciz "opcode "
.Lnl:           .asciz "\n"
.Lopt_version:  .asciz "--version"
.Lopt_help:     .asciz "--help"
.Lopt_h:        .asciz "-h"
.Lopt_list:     .asciz "--list-sessions"
.Lopt_listm:    .asciz "--list-models"
.Lcmd_fetch:    .asciz "fetch"
.Lcmd_login:    .asciz "login"
.Lcmd_logout:   .asciz "logout"
.Lcmd_models:   .asciz "models"
.Lcmd_update:   .asciz "update"
.Lopt_mode:     .asciz "--mode"
.Lmode_json:    .asciz "json"
.Lmode_rpc:     .asciz "rpc"
.Lopt_p:        .asciz "-p"
.Lopt_print:    .asciz "--print"
.Lerr_unknown:  .asciz "opcode: unknown option: "
.Lusage:
    .ascii "opcode - a minimal extensible coding agent\n\n"
    .ascii "usage: opcode [options]\n\n"
    .ascii "options:\n"
    .ascii "  --version   print version and exit\n"
    .ascii "  --help      print this help and exit\n"
    .ascii "  --list-sessions   list this directory's sessions (newest first) and exit\n"
    .ascii "  --list-models [F]  list known models (built-in + discovered), optionally\n"
    .ascii "                     filtered by a substring of provider/id/name, then exit\n"
    .ascii "  -p PROMPT   run the agent on PROMPT and print the answer\n"
    .ascii "  login [provider]    OAuth login (openai, anthropic)\n"
    .ascii "  logout [provider]   remove stored credentials\n"
    .ascii "  models [--refresh] [--provider P]   list available models\n"
    .ascii "  fetch URL   minimal HTTP(S) client\n"
    .ascii "  update      check the latest release on GitHub\n"
    .ascii "  --mode json|rpc -p PROMPT   machine-readable runs\n"
    .ascii "  --tui-mode scrollback|inline|fullscreen|auto   TUI rendering (default: inline)\n"
    .ascii "  --headless WxH --headless-capture FILE   scripted frame capture\n"
    .ascii "  --theme system|dark|light|NAME   TUI palette (default: system)\n"
    .ascii "  (no args)   interactive TUI (owned inline region by default)\n"
    .asciz ""
.text

# out_cstr(fd, cstr) -> 0|-errno
FN out_cstr
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rsi
    call strlen
    mov edi, ebx
    mov rsi, r12
    mov rdx, rax
    call write_all
    EPILOGUE

# sig_setup(): install the fatal-signal cleanup for the non-TUI modes.
# Points the platform exit hook at the agent's reaper and arms
# os_sig_cleanup, so SIGINT/SIGTERM runs agent_sig_cleanup (kill + reap the tool
# children, close their pipes) and then re-raises: the process exits with
# 128+signum (130 for SIGINT).  TUI mode keeps its own terminal-restore hook.
sig_setup:
    lea rax, [rip + agent_sig_cleanup]
    mov [rip + g_exit_hook], rax
    jmp os_sig_cleanup

# cstr_eq(a, b) -> 1|0 (leaf)
cstr_eq:
1:  mov al, [rdi]
    cmp al, [rsi]
    jne 2f
    test al, al
    jz 3f
    inc rdi
    inc rsi
    jmp 1b
2:  xor eax, eax
    ret
3:  mov eax, 1
    ret

# opcode_main() -> exit code
FN opcode_main
    PROLOGUE
    mov r12, [rip + g_argc]
    mov r13, [rip + g_argv]
    cmp r12, 2
    jb .Ltui
    mov rdi, [r13 + 8]
    lea rsi, [rip + .Lopt_p]
    call cstr_eq
    test eax, eax
    jnz .Lprint
    mov rdi, [r13 + 8]
    lea rsi, [rip + .Lopt_print]
    call cstr_eq
    test eax, eax
    jnz .Lprint
    mov rdi, [r13 + 8]
    lea rsi, [rip + .Lcmd_login]
    call cstr_eq
    test eax, eax
    jnz .Llogin
    mov rdi, [r13 + 8]
    lea rsi, [rip + .Lcmd_logout]
    call cstr_eq
    test eax, eax
    jnz .Llogin
    mov rdi, [r13 + 8]
    lea rsi, [rip + .Lcmd_models]
    call cstr_eq
    test eax, eax
    jnz .Lmodels
    mov rdi, [r13 + 8]
    lea rsi, [rip + .Lopt_mode]
    call cstr_eq
    test eax, eax
    jnz .Lmode
    mov rdi, [r13 + 8]
    lea rsi, [rip + .Lcmd_fetch]
    call cstr_eq
    test eax, eax
    jnz .Lfetch
    mov rdi, [r13 + 8]
    lea rsi, [rip + .Lcmd_update]
    call cstr_eq
    test eax, eax
    jnz .Lupdate
    mov rdi, [r13 + 8]
    lea rsi, [rip + .Lopt_version]
    call cstr_eq
    test eax, eax
    jnz .Lversion
    mov rdi, [r13 + 8]
    lea rsi, [rip + .Lopt_help]
    call cstr_eq
    test eax, eax
    jnz .Lusage_out
    mov rdi, [r13 + 8]
    lea rsi, [rip + .Lopt_h]
    call cstr_eq
    test eax, eax
    jnz .Lusage_out
    mov rdi, [r13 + 8]
    lea rsi, [rip + .Lopt_list]
    call cstr_eq
    test eax, eax
    jnz .Llist_sessions
    mov rdi, [r13 + 8]
    lea rsi, [rip + .Lopt_listm]
    call cstr_eq
    test eax, eax
    jnz .Llist_models
    # --list-sessions/--list-models are top-level modes and may appear after
    # agent flags (e.g. `opcode --offline --list-models`); scan the rest of
    # argv so position among those flags does not matter.  A recognised
    # argv[1] subcommand above still wins.
    mov r14, 1
.Lscan_sessions:
    cmp r14, r12
    jae .Lscan_models_start
    mov rdi, [r13 + r14*8]
    lea rsi, [rip + .Lopt_list]
    call cstr_eq
    test eax, eax
    jnz .Llist_sessions
    inc r14
    jmp .Lscan_sessions
.Lscan_models_start:
    mov r14, 1
.Lscan_models:
    cmp r14, r12
    jae .Ltui
    mov rdi, [r13 + r14*8]
    lea rsi, [rip + .Lopt_listm]
    call cstr_eq
    test eax, eax
    jnz .Llist_models_any
    inc r14
    jmp .Lscan_models
.Llist_models_any:
    # Build a filtered argv for opcode_list_models_main: index 0 is a skipped
    # placeholder (the flag itself), then every original argument except the
    # flag.  This keeps options and their values adjacent while dropping the
    # top-level mode flag the handler does not parse.
    mov rax, r12
    add rax, 2
    and rax, -2
    shl rax, 3
    sub rsp, rax
    mov rbx, rsp
    mov rax, [r13 + r14*8]
    mov [rbx], rax
    mov rdx, 1
    mov rcx, 1
.Llist_build:
    cmp rcx, r12
    jae .Llist_build_done
    cmp rcx, r14
    je .Llist_build_skip
    mov rax, [r13 + rcx*8]
    mov [rbx + rdx*8], rax
    inc rdx
.Llist_build_skip:
    inc rcx
    jmp .Llist_build
.Llist_build_done:
    mov rdi, rdx
    mov rsi, rbx
    call opcode_list_models_main
    EPILOGUE
    # no other subcommand: interactive TUI (flags are parsed there)
.Ltui:
    lea rdi, [r12 - 1]
    lea rsi, [r13 + 8]
    call tui_run
    EPILOGUE
.Lversion:
    mov edi, 1
    lea rsi, [rip + .Lprefix]
    call out_cstr
    mov edi, 1
    lea rsi, [rip + opcode_version]
    call out_cstr
    mov edi, 1
    lea rsi, [rip + .Lnl]
    call out_cstr
    xor eax, eax
    EPILOGUE
.Llist_sessions:
    # --list-sessions: print the cwd's sessions (newest first) and exit 0
    # without starting the agent.  config_load first so a configured
    # session_dir is honoured, matching --continue/--session resolution.
    call config_load
    xor edi, edi
    xor esi, esi
    call session_list
    xor eax, eax
    EPILOGUE
.Llist_models:
    # --list-models [FILTER]: built-in catalog + discovered entries (cache
    # first unless --refresh-models/--offline say otherwise); exit 0 without
    # starting the agent.
    lea rdi, [r12 - 1]
    lea rsi, [r13 + 8]
    call opcode_list_models_main
    EPILOGUE
.Llogin:
    lea rdi, [r12 - 1]
    lea rsi, [r13 + 8]
    call opcode_login_main
    EPILOGUE
.Lmodels:
    lea rdi, [r12 - 1]
    lea rsi, [r13 + 8]
    call opcode_models_main
    EPILOGUE
.Lmode:
    cmp r12, 3
    jb .Lusage_err
    mov rdi, [r13 + 16]
    lea rsi, [rip + .Lmode_json]
    call cstr_eq
    test eax, eax
    jnz .Lfmode_json
    mov rdi, [r13 + 16]
    lea rsi, [rip + .Lmode_rpc]
    call cstr_eq
    test eax, eax
    jnz .Lfmode_rpc
    jmp .Lusage_err
.Lfmode_json:
    call sig_setup
    lea rdi, [r12 - 1]
    lea rsi, [r13 + 8]
    call opcode_json_main
    EPILOGUE
.Lfmode_rpc:
    call sig_setup
    lea rdi, [r12 - 1]
    lea rsi, [r13 + 8]
    call opcode_rpc_main
    EPILOGUE
.Lprint:
    call sig_setup
    lea rdi, [r12 - 1]
    lea rsi, [r13 + 8]
    call opcode_print_main
    EPILOGUE
.Lfetch:
    lea rdi, [r12 - 1]
    lea rsi, [r13 + 8]
    call fetch_main
    EPILOGUE
.Lupdate:
    lea rdi, [r12 - 1]
    lea rsi, [r13 + 8]
    call opcode_update_main
    EPILOGUE
.Lusage_out:
    mov edi, 1
    lea rsi, [rip + .Lusage]
    call out_cstr
    xor eax, eax
    EPILOGUE
.Lusage_err:
    mov edi, 2
    lea rsi, [rip + .Lusage]
    call out_cstr
    mov eax, 2
    EPILOGUE
