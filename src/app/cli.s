# cli.s: the shared front-end CLI.  The -p/--print, --mode json|rpc and TUI
# front ends all parse their flags here: one table-driven parser, one usage
# renderer and one session resolver, so the three accept the same agent flags.
#
# Contract:
#   cli_parse(argc rdi, argv rsi, kind edx) -> 0 ok | 2 usage (printed)
#     argv is the front end's own argv with argv[0] already a flag (run.s
#     strips -p/--print, modes.s leaves the leading --mode for the parser to
#     skip).  kind is CK_* below.
#   cli_expand_prompt() -> 0 ok | 1 template missing (printed)
#   cli_require_prompt() -> 0 present | 2 missing (printed)
#   cli_open_session() -> 0 ok | 1 not found (printed)
#   cli_usage() -> prints the unified usage to stderr
# Parse state lives in the cl_* globals below.
.include "opcode.inc"
.include "core/core.inc"

# CF record (24 bytes): name ptr, kind mask, takes value, action id, pad.
.equ CF_NAME,  0
.equ CF_KINDS, 8
.equ CF_ARG,  12
.equ CF_ACT,  16
.equ CF_SIZE, 24

.equ CL_PROVIDER, 1
.equ CL_MODEL,    2
.equ CL_APIKEY,   3
.equ CL_BASE,     4
.equ CL_SYSTEM,   5
.equ CL_OFFLINE,  6
.equ CL_REPLAY,   7
.equ CL_MAXTOK,   8
.equ CL_VERBOSE,  9
.equ CL_CONT,     10
.equ CL_SESSION,  11
.equ CL_SDIR,     12
.equ CL_NOSESS,   13
.equ CL_APPROVE,  14
.equ CL_TEMPLATE, 15
.equ CL_HEADLESS, 16
.equ CL_SCRIPT,   17
.equ CL_TUIMODE,  18
.equ CL_MODE,     19
.equ CL_PRINT,    20
.equ CL_THINKING, 21
.equ CL_THEME,    22
.equ CL_CAPTURE,  23
.equ CL_RESUME,   24
.equ CL_REFRESHM, 25
.equ CL_MAXACT,   25

# The pre-TUI session picker is owned by the PICKERS seat (src/tui/pick.s).  A
# weak reference keeps this build linkable before that file exists; absent, the
# resume path falls back to the newest session.
.weak opcode_pick_tty

.section .rodata
.Lspace:        .asciz " "
.Lnl:           .asciz "\n"
.Lempty:        .asciz ""
.Lerr_unknown:  .asciz "opcode: unknown option: "
.Lerr_noval:    .asciz "opcode: option requires a value: "
.Lerr_badval:   .asciz "opcode: invalid value for option: "
.Lerr_prompt:   .asciz "opcode: missing prompt\n"
.Lerr_tmpl:     .asciz "opcode: template not found: "
.Lerr_session:  .asciz "opcode: session not found\n"
.Lusage:
    .ascii "usage: opcode [options] [PROMPT]\n"
    .ascii "  --provider P --model M --api-key K --base-url U [--system S]\n"
    .ascii "  [--offline] [--replay FILE] [--max-tokens N] [--verbose]\n"
    .ascii "  [--continue] [--resume] [--session PATH|ID] [--session-dir DIR]\n"
    .ascii "  [--no-session] [--template NAME [args...]] [--approve]\n"
    .ascii "  [--tui-mode scrollback|inline|fullscreen|auto] [--theme NAME]\n"
    .ascii "  [--headless WxH] [--headless-capture FILE] [--script FILE]\n"
    .ascii "  [--thinking off|low|medium|high]\n"
    .asciz "one-shot: opcode -p PROMPT | JSONL: opcode --mode json|rpc | help: opcode --help\n"

.Lf_provider:   .asciz "--provider"
.Lf_model:      .asciz "--model"
.Lf_apikey:     .asciz "--api-key"
.Lf_base:       .asciz "--base-url"
.Lf_system:     .asciz "--system"
.Lf_offline:    .asciz "--offline"
.Lf_refreshm:   .asciz "--refresh-models"
.Lf_replay:     .asciz "--replay"
.Lf_maxtok:     .asciz "--max-tokens"
.Lf_verbose:    .asciz "--verbose"
.Lf_continue:   .asciz "--continue"
.Lf_resume:     .asciz "--resume"
.Lf_session:    .asciz "--session"
.Lf_sdir:       .asciz "--session-dir"
.Lf_nosess:     .asciz "--no-session"
.Lf_approve:    .asciz "--approve"
.Lf_template:   .asciz "--template"
.Lf_headless:   .asciz "--headless"
.Lf_script:     .asciz "--script"
.Lf_tuimode:    .asciz "--tui-mode"
.Lf_mode:       .asciz "--mode"
.Lf_thinking:   .asciz "--thinking"
.Lf_theme:      .asciz "--theme"
.Lf_capture:    .asciz "--headless-capture"
.Lpick_title:   .asciz "Resume a session"
.Lkey_dp:       .asciz "default_provider"
.Lprov_openai:  .asciz "openai"
.Lf_p:          .asciz "-p"
.Lf_print:      .asciz "--print"
.Lv_scrollback: .asciz "scrollback"
.Lv_inline:     .asciz "inline"
.Lv_fullscreen: .asciz "fullscreen"
.Lv_auto:       .asciz "auto"

.p2align 3
cli_flags:
    .quad .Lf_provider;  .long CK_AGENT; .long 1; .long CL_PROVIDER; .long 0
    .quad .Lf_model;     .long CK_AGENT; .long 1; .long CL_MODEL;    .long 0
    .quad .Lf_apikey;    .long CK_AGENT; .long 1; .long CL_APIKEY;   .long 0
    .quad .Lf_base;      .long CK_AGENT; .long 1; .long CL_BASE;     .long 0
    .quad .Lf_system;    .long CK_AGENT; .long 1; .long CL_SYSTEM;   .long 0
    .quad .Lf_offline;   .long CK_AGENT; .long 0; .long CL_OFFLINE;  .long 0
    .quad .Lf_refreshm;  .long CK_AGENT; .long 0; .long CL_REFRESHM; .long 0
    .quad .Lf_replay;    .long CK_AGENT; .long 1; .long CL_REPLAY;   .long 0
    .quad .Lf_maxtok;    .long CK_AGENT; .long 1; .long CL_MAXTOK;   .long 0
    .quad .Lf_verbose;   .long CK_AGENT; .long 0; .long CL_VERBOSE;  .long 0
    .quad .Lf_continue;  .long CK_AGENT; .long 0; .long CL_CONT;     .long 0
    .quad .Lf_resume;    .long CK_AGENT; .long 0; .long CL_RESUME;   .long 0
    .quad .Lf_session;   .long CK_AGENT; .long 1; .long CL_SESSION;  .long 0
    .quad .Lf_sdir;      .long CK_AGENT; .long 1; .long CL_SDIR;     .long 0
    .quad .Lf_nosess;    .long CK_AGENT; .long 0; .long CL_NOSESS;   .long 0
    .quad .Lf_approve;   .long CK_AGENT; .long 0; .long CL_APPROVE;  .long 0
    .quad .Lf_template;  .long CK_AGENT; .long 1; .long CL_TEMPLATE; .long 0
    .quad .Lf_headless;  .long CK_TUI;   .long 1; .long CL_HEADLESS; .long 0
    .quad .Lf_script;    .long CK_TUI;   .long 1; .long CL_SCRIPT;   .long 0
    .quad .Lf_tuimode;   .long CK_TUI;   .long 1; .long CL_TUIMODE;  .long 0
    .quad .Lf_mode;      .long CK_MODES; .long 1; .long CL_MODE;     .long 0
    .quad .Lf_thinking;  .long CK_AGENT; .long 1; .long CL_THINKING; .long 0
    .quad .Lf_theme;     .long CK_TUI;   .long 1; .long CL_THEME;    .long 0
    .quad .Lf_capture;   .long CK_TUI;   .long 1; .long CL_CAPTURE;  .long 0
    .quad .Lf_p;         .long CK_MODES; .long 0; .long CL_PRINT;    .long 0
    .quad .Lf_print;     .long CK_MODES; .long 0; .long CL_PRINT;    .long 0
    .quad 0;             .long 0;        .long 0; .long 0;           .long 0

.p2align 3
.Lacts:
    .quad .Lca_bad
    .quad .Lca_provider
    .quad .Lca_model
    .quad .Lca_apikey
    .quad .Lca_base
    .quad .Lca_system
    .quad .Lca_offline
    .quad .Lca_replay
    .quad .Lca_maxtok
    .quad .Lca_verbose
    .quad .Lca_cont
    .quad .Lca_session
    .quad .Lca_sdir
    .quad .Lca_nosess
    .quad .Lca_approve
    .quad .Lca_template
    .quad .Lca_headless
    .quad .Lca_script
    .quad .Lca_tuimode
    .quad .Lca_noop
    .quad .Lca_noop
    .quad .Lca_thinking
    .quad .Lca_theme
    .quad .Lca_capture
    .quad .Lca_resume
    .quad .Lca_refreshm

.bss
.p2align 3
.globl cl_prompt
cl_prompt:  .zero SB_SIZE
.globl cl_targs
cl_targs:   .zero SB_SIZE
.globl cl_cwd
cl_cwd:     .zero 512
.globl cl_session
cl_session: .zero 8
.globl cl_sdir
cl_sdir:    .zero 8
.globl cl_template
cl_template:.zero 8
.globl cl_headless
cl_headless:.zero 8
.globl cl_mode
cl_mode:    .zero 4
.globl cl_kind
cl_kind:    .zero 4
.globl cl_tui_mode
cl_tui_mode:.zero 4
.globl cl_theme
cl_theme:   .zero 8

.text

# cl_streq(a cstr, b cstr) -> 1|0 (leaf)
cl_streq:
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

# cl_has_slash(s cstr) -> 1|0 (leaf)
cl_has_slash:
1:  mov al, [rdi]
    test al, al
    jz 2f
    cmp al, '/'
    je 3f
    inc rdi
    jmp 1b
2:  xor eax, eax
    ret
3:  mov eax, 1
    ret

# cl_out(fd, cstr)
cl_out:
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

# cl_line(prefix rdi, token rsi): "opcode: ...TOKEN\n" on stderr
cl_line:
    PROLOGUE
    mov r13, rdi
    mov r12, rsi
    mov edi, 2
    mov rsi, r13
    call cl_out
    mov edi, 2
    mov rsi, r12
    call cl_out
    mov edi, 2
    lea rsi, [rip + .Lnl]
    call cl_out
    EPILOGUE

# cli_usage(): the one usage renderer (stderr)
FN cli_usage
    lea rsi, [rip + .Lusage]
    mov edi, 2
    jmp cl_out

# cl_push_word(sb, word): append " word" (a plain space when non-empty)
cl_push_word:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    cmp qword ptr [rbx + SB_len], 0
    je 1f
    mov rdi, rbx
    lea rsi, [rip + .Lspace]
    mov edx, 1
    call sb_push
1:  mov rdi, r12
    call strlen
    mov rdx, rax
    mov rsi, r12
    mov rdi, rbx
    call sb_push
    EPILOGUE

# cli_apply(action edi, value rsi) -> 0 ok | 1 bad value
cli_apply:
    cmp edi, CL_MAXACT
    ja .Lca_bad
    lea rax, [rip + .Lacts]
    mov ecx, edi
    jmp qword ptr [rax + rcx*8]
.Lca_bad:
    mov eax, 1
    ret
.Lca_provider:
    mov [rip + g_agent_provider], rsi
    xor eax, eax
    ret
.Lca_model:
    mov [rip + g_agent_model], rsi
    xor eax, eax
    ret
.Lca_base:
    mov [rip + g_agent_base], rsi
    xor eax, eax
    ret
.Lca_system:
    mov [rip + g_agent_system], rsi
    xor eax, eax
    ret
.Lca_apikey:
    mov rdi, rsi
    call auth_set_flag
    xor eax, eax
    ret
.Lca_offline:
    mov qword ptr [rip + g_offline], 1
    xor eax, eax
    ret
.Lca_replay:
    mov [rip + g_agent_replay], rsi
    xor eax, eax
    ret
.Lca_maxtok:
    push rsi
    mov rdi, rsi
    call strlen
    pop rdi
    mov rsi, rax
    call parse_u64
    mov [rip + g_agent_max_tokens], rax
    xor eax, eax
    ret
.Lca_verbose:
    mov qword ptr [rip + g_agent_verbose], 1
    xor eax, eax
    ret
.Lca_cont:
    mov dword ptr [rip + cl_mode], 1
    xor eax, eax
    ret
.Lca_session:
    mov [rip + cl_session], rsi
    mov dword ptr [rip + cl_mode], 2
    xor eax, eax
    ret
.Lca_sdir:
    mov [rip + cl_sdir], rsi
    xor eax, eax
    ret
.Lca_nosess:
    mov dword ptr [rip + cl_mode], 3
    xor eax, eax
    ret
.Lca_approve:
    mov qword ptr [rip + g_config_approve], 1
    xor eax, eax
    ret
.Lca_template:
    mov [rip + cl_template], rsi
    xor eax, eax
    ret
.Lca_headless:
    mov qword ptr [rip + g_tui_headless], 1
    mov [rip + cl_headless], rsi
    xor eax, eax
    ret
.Lca_script:
    mov [rip + g_tui_script], rsi
    mov qword ptr [rip + g_tui_headless], 1
    xor eax, eax
    ret
.Lca_tuimode:
    push rsi
    mov rdi, rsi
    lea rsi, [rip + .Lv_scrollback]
    call cl_streq
    pop rsi
    test eax, eax
    jnz .Lca_tui_scroll
    push rsi
    mov rdi, rsi
    lea rsi, [rip + .Lv_inline]
    call cl_streq
    pop rsi
    test eax, eax
    jnz .Lca_tui_inline
    push rsi
    mov rdi, rsi
    lea rsi, [rip + .Lv_fullscreen]
    call cl_streq
    pop rsi
    test eax, eax
    jnz .Lca_tui_full
    push rsi
    mov rdi, rsi
    lea rsi, [rip + .Lv_auto]
    call cl_streq
    pop rsi
    test eax, eax
    jnz .Lca_tui_inline
    mov eax, 1
    ret
.Lca_tui_scroll:
    mov dword ptr [rip + cl_tui_mode], 0
    xor eax, eax
    ret
.Lca_tui_inline:
    mov dword ptr [rip + cl_tui_mode], 1
    xor eax, eax
    ret
.Lca_tui_full:
    mov dword ptr [rip + cl_tui_mode], 2
    xor eax, eax
    ret
.Lca_noop:
    xor eax, eax
    ret
.Lca_thinking:
    mov rdi, rsi
    call agent_thinking_parse
    test eax, eax
    js 1f
    mov esi, eax
    call agent_set_thinking
    xor eax, eax
    ret
1:  mov eax, 1
    ret
.Lca_theme:
    mov [rip + cl_theme], rsi
    xor eax, eax
    ret
.Lca_capture:
    mov [rip + g_tui_capture], rsi
    mov qword ptr [rip + g_tui_headless], 1
    xor eax, eax
    ret
.Lca_refreshm:
    mov dword ptr [rip + g_discover_force], 1
    xor eax, eax
    ret
.Lca_resume:
    mov dword ptr [rip + cl_mode], 4
    xor eax, eax
    ret

# cli_parse(argc rdi, argv rsi, kind edx) -> 0 ok | 2 usage error (printed)
FN cli_parse
    PROLOGUE
    mov r15, rdi
    mov r14, rsi
    mov [rip + cl_kind], edx
    mov qword ptr [rip + cl_session], 0
    mov qword ptr [rip + cl_sdir], 0
    mov qword ptr [rip + cl_template], 0
    mov qword ptr [rip + cl_headless], 0
    mov dword ptr [rip + cl_mode], 0
    mov dword ptr [rip + cl_tui_mode], 1
    mov qword ptr [rip + cl_theme], 0
    lea rdi, [rip + cl_prompt]
    call sb_clear
    lea rdi, [rip + cl_targs]
    call sb_clear
    xor r12d, r12d
    # a leading "--mode json|rpc" belongs to dispatch, not the state
    mov eax, [rip + cl_kind]
    test eax, CK_MODES
    jz .Lcp_loop
    cmp r15, 1
    jbe .Lcp_loop
    mov r13, [r14]
    test r13, r13
    jz .Lcp_loop
    mov rdi, r13
    lea rsi, [rip + .Lf_mode]
    call cl_streq
    test eax, eax
    jz .Lcp_loop
    mov r12d, 2
.Lcp_loop:
    cmp r12, r15
    jae .Lcp_ok
    mov r13, [r14 + r12*8]
    cmp byte ptr [r13], '-'
    jne .Lcp_word
    lea rbx, [rip + cli_flags]
.Lcp_scan:
    mov rax, [rbx + CF_NAME]
    test rax, rax
    jz .Lcp_unknown
    mov rdi, r13
    mov rsi, rax
    call cl_streq
    test eax, eax
    jnz .Lcp_match
    add rbx, CF_SIZE
    jmp .Lcp_scan
.Lcp_match:
    mov eax, [rip + cl_kind]
    test dword ptr [rbx + CF_KINDS], eax
    jz .Lcp_unknown
    cmp dword ptr [rbx + CF_ARG], 0
    je .Lcp_apply
    inc r12
    cmp r12, r15
    jae .Lcp_noval
    mov r13, [r14 + r12*8]
.Lcp_apply:
    mov rsi, r13
    mov edi, [rbx + CF_ACT]
    call cli_apply
    test eax, eax
    jnz .Lcp_badval
    inc r12
    jmp .Lcp_loop
.Lcp_word:
    mov eax, [rip + cl_kind]
    test eax, CK_TUI
    jnz .Lcp_usage
    mov rsi, r13
    cmp qword ptr [rip + cl_template], 0
    jne .Lcp_targ
    lea rdi, [rip + cl_prompt]
    jmp .Lcp_word_go
.Lcp_targ:
    lea rdi, [rip + cl_targs]
.Lcp_word_go:
    call cl_push_word
    inc r12
    jmp .Lcp_loop
.Lcp_unknown:
    lea rdi, [rip + .Lerr_unknown]
    mov rsi, r13
    call .Lcp_badline
    jmp .Lcp_usage
.Lcp_noval:
    lea rdi, [rip + .Lerr_noval]
    mov rsi, r13
    call .Lcp_badline
    jmp .Lcp_usage
.Lcp_badval:
    lea rdi, [rip + .Lerr_badval]
    mov rsi, r13
    call .Lcp_badline
.Lcp_usage:
    call cli_usage
    mov eax, 2
    EPILOGUE
.Lcp_ok:
    # The interactive project-trust prompt is only for the TUI, and never for
    # the headless/scripted/capture variants; the core checks the TTY itself.
    xor eax, eax
    cmp dword ptr [rip + cl_kind], CK_TUI
    jne 1f
    cmp qword ptr [rip + g_tui_headless], 0
    jne 1f
    mov eax, 1
1:  mov [rip + g_config_interactive], rax
    xor eax, eax
    EPILOGUE
# .Lcp_badline(prefix rdi, token rsi): "opcode: ...TOKEN\n"
.Lcp_badline:
    mov r13, rdi
    mov r12, rsi
    mov edi, 2
    mov rsi, r13
    call cl_out
    mov edi, 2
    mov rsi, r12
    call cl_out
    mov edi, 2
    lea rsi, [rip + .Lnl]
    jmp cl_out

# cli_expand_prompt() -> 0 ok | 1 template missing (printed)
FN cli_expand_prompt
    PROLOGUE
    cmp qword ptr [rip + cl_template], 0
    je .Lce_ok
    call prompt_templates_init
    lea rdi, [rip + cl_prompt]
    call sb_clear
    mov rdi, [rip + cl_template]
    mov rsi, [rip + cl_targs + SB_ptr]
    test rsi, rsi
    jnz 1f
    lea rsi, [rip + .Lempty]
1:  lea rdx, [rip + cl_prompt]
    call prompt_template_expand
    test rax, rax
    js .Lce_err
.Lce_ok:
    xor eax, eax
    EPILOGUE
.Lce_err:
    lea rdi, [rip + .Lerr_tmpl]
    mov rsi, [rip + cl_template]
    call cl_line
    mov eax, 1
    EPILOGUE

# cli_require_prompt() -> 0 present | 2 missing (printed)
FN cli_require_prompt
    cmp qword ptr [rip + cl_prompt + SB_len], 0
    je .Lrp_missing
    xor eax, eax
    ret
.Lrp_missing:
    lea rsi, [rip + .Lerr_prompt]
    mov edi, 2
    call cl_out
    call cli_usage
    mov eax, 2
    ret

# cli_open_session() -> 0 ok | 1 session not found (printed)
FN cli_open_session
    PROLOGUE 256
    # --refresh-models: force discovery for the resolved provider before the
    # session/agent setup, so a newly added model becomes selectable.  --offline
    # still suppresses the probe (discover_models_cached honours it).
    cmp dword ptr [rip + g_discover_force], 0
    je .Lcs_mode
    mov rdi, [rip + g_agent_provider]
    test rdi, rdi
    jnz .Lcs_rd_flag
    lea rdi, [rip + .Lkey_dp]
    call config_str
    test rax, rax
    jz .Lcs_rd_default
    mov r12, rax
    mov r13, 1                  # owned by config_str
    jmp .Lcs_rd_disc
.Lcs_rd_default:
    lea r12, [rip + .Lprov_openai]
    xor r13d, r13d
    jmp .Lcs_rd_disc
.Lcs_rd_flag:
    mov r12, rdi
    xor r13d, r13d
.Lcs_rd_disc:
    mov rax, [rip + g_agent_base]
    test rax, rax
    jz 1f
    mov [rip + g_discover_base], rax
1:  mov rdi, r12
    xor esi, esi
    mov edx, 1
    call discover_models_cached
    test r13, r13
    jz .Lcs_mode
    mov rdi, r12
    call mem_free
.Lcs_mode:
    mov eax, [rip + cl_mode]
    cmp eax, 3
    je .Lcs_ok
    lea rdi, [rip + cl_cwd]
    mov esi, 512
    call os_getcwd
    mov eax, [rip + cl_mode]
    cmp eax, 2
    je .Lcs_id
    cmp eax, 1
    je .Lcs_cont
    cmp eax, 4
    je .Lcs_resume
    jmp .Lcs_new
.Lcs_id:
    mov rdi, [rip + cl_session]
    test rdi, rdi
    jz .Lcs_missing
    call cl_has_slash
    test eax, eax
    jz 1f
    mov rdi, [rip + cl_session]
    call session_open
    jmp 2f
1:  mov rdi, [rip + cl_sdir]
    mov rsi, [rip + cl_session]
    call session_find_id
    test rax, rax
    jz .Lcs_missing
    mov rdi, rax
    call session_open
2:  test rax, rax
    jz .Lcs_missing
    mov [rip + g_agent_session], rax
    jmp .Lcs_ok
.Lcs_cont:
    mov rdi, [rip + cl_sdir]
    lea rsi, [rip + cl_cwd]
    call session_find_latest
    test rax, rax
    jz .Lcs_new
    mov rdi, rax
    call session_open
    test rax, rax
    jz .Lcs_missing
    mov [rip + g_agent_session], rax
    jmp .Lcs_ok
.Lcs_resume:
    # --resume with no explicit --session: a terminal gets the pre-TUI picker
    # over the cwd's sessions, newest first; a non-tty run keeps the newest.
    cmp qword ptr [rip + cl_session], 0
    jne .Lcs_id
    lea rdi, [rsp]
    call os_tty_raw
    test rax, rax
    js .Lcs_cont
    lea rdi, [rsp]
    call os_tty_restore
    mov rdi, [rip + cl_sdir]
    lea rsi, [rip + cl_cwd]
    call session_recent
    test rax, rax
    jz .Lcs_new
    mov [rsp + 64], rax
    mov rdi, rax
    call session_recent_count
    mov [rsp + 72], rax
    test rax, rax
    jz .Lcsr_new
    shl rax, 3
    mov rdi, rax
    call mem_alloc
    mov [rsp + 80], rax
    mov rdi, [rsp + 72]
    shl rdi, 3
    call mem_alloc
    mov [rsp + 88], rax
    xor r12d, r12d
.Lcsr_fill:
    cmp r12, [rsp + 72]
    jae .Lcsr_call
    mov rdi, [rsp + 64]
    mov rsi, r12
    call session_recent_id
    mov rcx, [rsp + 80]
    mov [rcx + r12*8], rax
    mov rdi, [rsp + 64]
    mov rsi, r12
    call session_recent_desc
    mov rcx, [rsp + 88]
    mov [rcx + r12*8], rax
    inc r12
    jmp .Lcsr_fill
.Lcsr_call:
    lea rax, [rip + opcode_pick_tty]
    test rax, rax
    jz .Lcsr_nopick
    lea rdi, [rip + .Lpick_title]
    mov rsi, [rsp + 80]
    mov rdx, [rsp + 88]
    mov rcx, [rsp + 72]
    xor r8d, r8d
    call rax
    jmp .Lcsr_got
.Lcsr_nopick:
    xor eax, eax
.Lcsr_got:
    mov [rsp + 96], rax
    mov rdi, [rsp + 80]
    call mem_free
    mov rdi, [rsp + 88]
    call mem_free
    mov rax, [rsp + 96]
    test rax, rax
    js .Lcsr_new
    cmp rax, [rsp + 72]
    jae .Lcsr_new
    mov rdi, [rsp + 64]
    mov rsi, rax
    call session_recent_path
    mov rdi, rax
    call session_open
    test rax, rax
    jz .Lcsr_fail
    mov [rip + g_agent_session], rax
    mov rdi, [rsp + 64]
    call session_recent_free
    jmp .Lcs_ok
.Lcsr_new:
    mov rdi, [rsp + 64]
    call session_recent_free
    jmp .Lcs_new
.Lcsr_fail:
    mov rdi, [rsp + 64]
    call session_recent_free
    jmp .Lcs_missing
.Lcs_new:
    mov rdi, [rip + cl_sdir]
    lea rsi, [rip + cl_cwd]
    call session_new
    mov [rip + g_agent_session], rax
.Lcs_ok:
    xor eax, eax
    EPILOGUE
.Lcs_missing:
    lea rsi, [rip + .Lerr_session]
    mov edi, 2
    call cl_out
    mov eax, 1
    EPILOGUE
