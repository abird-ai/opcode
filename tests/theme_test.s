.include "opcode.inc"
.include "tui/theme.inc"
# theme_test: built-in bases, system detection, named/config precedence,
# trust-gated project themes, invalid stems and 24-bit -> 256/16 SGR output.
#
# The user config dir is build/theme_test_cfg (absolute), exposed through the
# g_config_home override; project themes live under build/theme_test_proj.
# g_envp is pointed at a static table so $COLORFGBG detection is deterministic.

.bss
.p2align 3
t_root:     .zero 512
t_cfg:      .zero 512
t_empty:    .zero 512
t_proj:     .zero 512
t_themes:   .zero 512
t_cfgdoc:   .zero 512
t_nameddoc: .zero 512
t_projopcode:.zero 512
t_projdoc:  .zero 512
th:         .zero 256
sb:         .zero SB_SIZE

.section .rodata
s_cfgsub:    .asciz "/build/theme_test_cfg"
s_emptysub:  .asciz "/build/theme_test_empty"
s_projsub:   .asciz "/build/theme_test_proj"
s_themes:    .asciz "/themes"
s_dotopcode:  .asciz "/.opcode"
s_themejson: .asciz "/theme.jsonc"
s_named:     .asciz "/named.jsonc"
s_projjson:  .asciz "/proj.jsonc"

cfg_doc:
    .ascii "{ \"base\": \"light\", \"accent\": \"#112233\" }\n"
cfg_doc_len = . - cfg_doc
named_doc:
    .ascii "{ \"base\": \"dark\", \"fg\": \"#445566\" }\n"
named_doc_len = . - named_doc
proj_doc:
    .ascii "{ \"base\": \"dark\", \"ok\": \"#778899\" }\n"
proj_doc_len = . - proj_doc

s_ok:   .asciz " ok\n"
s_fail: .asciz " FAIL\n"

v_dark:  .asciz "dark"
v_light: .asciz "light"
v_sys:   .asciz "system"
v_named: .asciz "named"
v_proj:  .asciz "proj"
v_bad1:  .asciz "bad/name"
v_bad2:  .asciz ".."
v_bad3:  .asciz ""
v_slash: .asciz "/"
v_bslash:.asciz "\\"
v_dollar:.asciz "$"
v_dot:   .asciz "."
v_dot2:  .asciz ".."

# expected SGR sequences
x_fg_true:  .asciz "\033[38;2;255;0;0m"
x_bg_true:  .asciz "\033[48;2;255;0;0m"
x_fg_256:   .asciz "\033[38;5;196m"
x_bg_256:   .asciz "\033[48;5;196m"
x_fg_16:    .asciz "\033[91m"
x_bg_16:    .asciz "\033[101m"
x_no_bg:    .asciz "\033[49m"
x_ramp_256: .asciz "\033[38;5;236m"
x_muted_16: .asciz "\033[90m"

m_dark_fg:   .asciz "dark fg"
m_dark_bg:   .asciz "dark bg"
m_light_fg:  .asciz "light fg"
m_light_bg:  .asciz "light bg"
m_sys7:      .asciz "system COLORFGBG=0;7"
m_sys0:      .asciz "system COLORFGBG=0;0"
m_sys15:     .asciz "system COLORFGBG=15;15"
m_sys8:      .asciz "system COLORFGBG=15;8"
m_sysbad:    .asciz "system COLORFGBG=x"
m_sysnone:   .asciz "system no COLORFGBG"
m_named_base:.asciz "named base dark"
m_named_fg:  .asciz "named fg"
m_cfg_accent:.asciz "config accent"
m_named_bg:  .asciz "named bg"
m_bad1:      .asciz "invalid bad/name"
m_bad2:      .asciz "invalid .."
m_bad3:      .asciz "invalid empty"
m_tn_slash:  .asciz "name reject /"
m_tn_bslash: .asciz "name reject backslash"
m_tn_dollar: .asciz "name reject $"
m_tn_dot:    .asciz "name reject ."
m_tn_dot2:   .asciz "name reject .."
m_proj_ok:   .asciz "project ok"
m_proj_deny: .asciz "project untrusted"
m_true_fg:   .asciz "true fg"
m_true_bg:   .asciz "true bg"
m_256_fg:    .asciz "256 fg"
m_256_bg:    .asciz "256 bg"
m_16_fg:     .asciz "16 fg"
m_16_bg:     .asciz "16 bg"
m_no_bg:     .asciz "no bg 49"
m_ramp:      .asciz "256 ramp"
m_mutedpin:  .asciz "16 muted pin"

# COLORFGBG env fixtures
e_cf7:   .asciz "COLORFGBG=0;7"
e_cf0:   .asciz "COLORFGBG=0;0"
e_cf15:  .asciz "COLORFGBG=15;15"
e_cf8:   .asciz "COLORFGBG=15;8"
e_cfbad: .asciz "COLORFGBG=x"
e_other: .asciz "PATH=/nonexistent"
envp_cf7:   .quad e_cf7, 0
envp_cf0:   .quad e_cf0, 0
envp_cf15:  .quad e_cf15, 0
envp_cf8:   .quad e_cf8, 0
envp_cfbad: .quad e_cfbad, 0
envp_other: .quad e_other, 0

.text

tprint:
    push rdi
    call strlen
    pop rdi
    mov rdx, rax
    mov rsi, rdi
    mov edi, 1
    jmp write_all

teq:
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

tscat:
    mov rax, rdi
1:  mov cl, [rsi]
    mov [rax], cl
    inc rax
    inc rsi
    test cl, cl
    jnz 1b
    dec rax
    ret

tmkdir:
    mov esi, 0x1ED
    jmp os_mkdir

twrite:
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov esi, O_WRONLY | O_CREAT | O_TRUNC
    mov edx, 0x1A4
    call os_open
    test rax, rax
    js .Ltw_out
    mov r14d, eax
    mov edi, r14d
    mov rsi, r12
    mov rdx, r13
    call write_all
    mov r15, rax
    mov edi, r14d
    call os_close
    mov rax, r15
.Ltw_out:
    EPILOGUE

# tcheck(actual edi, expected esi, msg rdx)
tcheck:
    PROLOGUE 0
    mov r12, rdx
    cmp edi, esi
    jne .Ltc_bad
    mov rdi, r12
    call tprint
    lea rdi, [rip + s_ok]
    call tprint
    EPILOGUE
.Ltc_bad:
    mov rdi, r12
    call tprint
    lea rdi, [rip + s_fail]
    call tprint
    EPILOGUE

# tcheck_str(actual rdi, expected rsi, msg rdx)
tcheck_str:
    PROLOGUE 0
    mov r12, rdx
    call teq
    test eax, eax
    jz .Ltcs_bad
    mov rdi, r12
    call tprint
    lea rdi, [rip + s_ok]
    call tprint
    EPILOGUE
.Ltcs_bad:
    mov rdi, r12
    call tprint
    lea rdi, [rip + s_fail]
    call tprint
    EPILOGUE

# rgb_at(slot edi) -> eax = th.rgb[slot]
rgb_at:
    lea rax, [rip + th]
    mov eax, [rax + TH_rgb + rdi*4]
    ret

# set_env(envp rdi)
set_env:
    mov [rip + g_envp], rdi
    ret

FN opcode_main
    PROLOGUE
    lea rdi, [rip + t_root]
    mov esi, 512
    call os_getcwd
    test rax, rax
    js .Lfail

    # t_cfg = root + "/build/theme_test_cfg"
    lea rdi, [rip + t_cfg]
    lea rsi, [rip + t_root]
    call tscat
    mov rdi, rax
    lea rsi, [rip + s_cfgsub]
    call tscat
    # t_empty = root + "/build/theme_test_empty"
    lea rdi, [rip + t_empty]
    lea rsi, [rip + t_root]
    call tscat
    mov rdi, rax
    lea rsi, [rip + s_emptysub]
    call tscat
    # t_proj = root + "/build/theme_test_proj"
    lea rdi, [rip + t_proj]
    lea rsi, [rip + t_root]
    call tscat
    mov rdi, rax
    lea rsi, [rip + s_projsub]
    call tscat
    # t_themes = t_cfg + "/themes"
    lea rdi, [rip + t_themes]
    lea rsi, [rip + t_cfg]
    call tscat
    mov rdi, rax
    lea rsi, [rip + s_themes]
    call tscat
    # t_cfgdoc = t_cfg + "/theme.jsonc"
    lea rdi, [rip + t_cfgdoc]
    lea rsi, [rip + t_cfg]
    call tscat
    mov rdi, rax
    lea rsi, [rip + s_themejson]
    call tscat
    # t_nameddoc = t_themes + "/named.jsonc"
    lea rdi, [rip + t_nameddoc]
    lea rsi, [rip + t_themes]
    call tscat
    mov rdi, rax
    lea rsi, [rip + s_named]
    call tscat
    # t_projopcode = t_proj + "/.opcode"
    lea rdi, [rip + t_projopcode]
    lea rsi, [rip + t_proj]
    call tscat
    mov rdi, rax
    lea rsi, [rip + s_dotopcode]
    call tscat
    # t_projdoc = t_projopcode + "/themes/proj.jsonc" (reuse t_projopcode then append)
    lea rdi, [rip + rsp_tmp]
    lea rsi, [rip + t_projopcode]
    call tscat
    mov rdi, rax
    lea rsi, [rip + s_themes]
    call tscat
    lea rdi, [rip + t_projdoc]
    lea rsi, [rip + rsp_tmp]
    call tscat
    mov rdi, rax
    lea rsi, [rip + s_projjson]
    call tscat

    # create dirs and files (ignore EEXIST)
    lea rdi, [rip + t_cfg]
    call tmkdir
    lea rdi, [rip + t_empty]
    call tmkdir
    lea rdi, [rip + t_themes]
    call tmkdir
    lea rdi, [rip + t_proj]
    call tmkdir
    lea rdi, [rip + t_projopcode]
    call tmkdir
    lea rdi, [rip + rsp_tmp]
    call tmkdir
    lea rdi, [rip + t_cfgdoc]
    lea rsi, [rip + cfg_doc]
    mov edx, cfg_doc_len
    call twrite
    lea rdi, [rip + t_nameddoc]
    lea rsi, [rip + named_doc]
    mov edx, named_doc_len
    call twrite
    lea rdi, [rip + t_projdoc]
    lea rsi, [rip + proj_doc]
    mov edx, proj_doc_len
    call twrite

    # built-in dark/light palettes (theme_init reads no config)
    lea rdi, [rip + th]
    mov esi, 1
    call theme_init
    mov edi, TH_FG
    call rgb_at
    mov edi, eax
    mov esi, 0xFFCDD6F4
    lea rdx, [rip + m_dark_fg]
    call tcheck
    mov edi, TH_BG
    call rgb_at
    mov edi, eax
    mov esi, 0xFF1E1E2E
    lea rdx, [rip + m_dark_bg]
    call tcheck
    lea rdi, [rip + th]
    xor esi, esi
    call theme_init
    mov edi, TH_FG
    call rgb_at
    mov edi, eax
    mov esi, 0xFF1E1E2E
    lea rdx, [rip + m_light_fg]
    call tcheck
    mov edi, TH_BG
    call rgb_at
    mov edi, eax
    mov esi, 0xFFEFF1F5
    lea rdx, [rip + m_light_bg]
    call tcheck

    # system detection from $COLORFGBG
    lea rdi, [rip + envp_cf7]
    call set_env
    call theme_system_dark
    mov edi, eax
    xor esi, esi
    lea rdx, [rip + m_sys7]
    call tcheck
    lea rdi, [rip + envp_cf0]
    call set_env
    call theme_system_dark
    mov edi, eax
    mov esi, 1
    lea rdx, [rip + m_sys0]
    call tcheck
    lea rdi, [rip + envp_cf15]
    call set_env
    call theme_system_dark
    mov edi, eax
    xor esi, esi
    lea rdx, [rip + m_sys15]
    call tcheck
    lea rdi, [rip + envp_cf8]
    call set_env
    call theme_system_dark
    mov edi, eax
    mov esi, 1
    lea rdx, [rip + m_sys8]
    call tcheck
    lea rdi, [rip + envp_cfbad]
    call set_env
    call theme_system_dark
    mov edi, eax
    mov esi, 1
    lea rdx, [rip + m_sysbad]
    call tcheck
    lea rdi, [rip + envp_other]
    call set_env
    call theme_system_dark
    mov edi, eax
    mov esi, 1
    lea rdx, [rip + m_sysnone]
    call tcheck

    # named file + config precedence, with the populated config dir
    lea rax, [rip + t_cfg]
    mov [rip + g_config_home], rax
    lea rdi, [rip + th]
    lea rsi, [rip + v_named]
    call theme_apply_named
    mov eax, [rip + th + TH_dark]
    mov edi, eax
    mov esi, 1
    lea rdx, [rip + m_named_base]
    call tcheck
    mov edi, TH_FG
    call rgb_at
    mov edi, eax
    mov esi, 0xFF445566
    lea rdx, [rip + m_named_fg]
    call tcheck
    mov edi, TH_ACCENT
    call rgb_at
    mov edi, eax
    mov esi, 0xFF112233
    lea rdx, [rip + m_cfg_accent]
    call tcheck
    mov edi, TH_BG
    call rgb_at
    mov edi, eax
    mov esi, 0xFF1E1E2E
    lea rdx, [rip + m_named_bg]
    call tcheck

    # invalid stems are rejected
    lea rdi, [rip + th]
    lea rsi, [rip + v_bad1]
    call theme_apply_named
    mov edi, eax
    xor esi, esi
    lea rdx, [rip + m_bad1]
    call tcheck
    lea rdi, [rip + th]
    lea rsi, [rip + v_bad2]
    call theme_apply_named
    mov edi, eax
    xor esi, esi
    lea rdx, [rip + m_bad2]
    call tcheck
    lea rdi, [rip + th]
    lea rsi, [rip + v_bad3]
    call theme_apply_named
    mov edi, eax
    xor esi, esi
    lea rdx, [rip + m_bad3]
    call tcheck

    # theme_name_ok must run the charset check for length-1 names too
    lea rdi, [rip + v_slash]
    call theme_name_ok
    mov edi, eax
    xor esi, esi
    lea rdx, [rip + m_tn_slash]
    call tcheck
    lea rdi, [rip + v_bslash]
    call theme_name_ok
    mov edi, eax
    xor esi, esi
    lea rdx, [rip + m_tn_bslash]
    call tcheck
    lea rdi, [rip + v_dollar]
    call theme_name_ok
    mov edi, eax
    xor esi, esi
    lea rdx, [rip + m_tn_dollar]
    call tcheck
    lea rdi, [rip + v_dot]
    call theme_name_ok
    mov edi, eax
    xor esi, esi
    lea rdx, [rip + m_tn_dot]
    call tcheck
    lea rdi, [rip + v_dot2]
    call theme_name_ok
    mov edi, eax
    xor esi, esi
    lea rdx, [rip + m_tn_dot2]
    call tcheck

    # trusted project theme resolves; untrusted does not
    lea rdi, [rip + t_proj]
    mov esi, 1
    call theme_set_project_root
    lea rdi, [rip + th]
    lea rsi, [rip + v_proj]
    call theme_apply_named
    test eax, eax
    jz .Lproj_deny
    mov edi, TH_OK
    call rgb_at
    mov edi, eax
    mov esi, 0xFF778899
    lea rdx, [rip + m_proj_ok]
    call tcheck
    jmp .Lproj_after
.Lproj_deny:
    mov edi, 1
    xor esi, esi
    lea rdx, [rip + m_proj_ok]
    call tcheck
.Lproj_after:
    lea rdi, [rip + t_proj]
    xor esi, esi
    call theme_set_project_root
    lea rdi, [rip + th]
    lea rsi, [rip + v_proj]
    call theme_apply_named
    mov edi, eax
    xor esi, esi
    lea rdx, [rip + m_proj_deny]
    call tcheck

    # ---- SGR downgrade: 0xFFFF0000 through every mode ----
    lea rdi, [rip + th]
    mov esi, 1
    call theme_init
    lea rdi, [rip + th]
    call theme_set_current

    lea rdi, [rip + th]
    mov esi, THEME_TRUE
    call theme_set_mode
    lea rdi, [rip + sb]
    call sb_clear
    lea rdi, [rip + sb]
    mov esi, 0xFFFF0000
    call theme_emit_fg
    mov rdi, [rip + sb + SB_ptr]
    lea rsi, [rip + x_fg_true]
    lea rdx, [rip + m_true_fg]
    call tcheck_str
    lea rdi, [rip + sb]
    call sb_clear
    lea rdi, [rip + sb]
    mov esi, 0xFFFF0000
    call theme_emit_bg
    mov rdi, [rip + sb + SB_ptr]
    lea rsi, [rip + x_bg_true]
    lea rdx, [rip + m_true_bg]
    call tcheck_str

    lea rdi, [rip + th]
    mov esi, THEME_256
    call theme_set_mode
    lea rdi, [rip + sb]
    call sb_clear
    lea rdi, [rip + sb]
    mov esi, 0xFFFF0000
    call theme_emit_fg
    mov rdi, [rip + sb + SB_ptr]
    lea rsi, [rip + x_fg_256]
    lea rdx, [rip + m_256_fg]
    call tcheck_str
    lea rdi, [rip + sb]
    call sb_clear
    lea rdi, [rip + sb]
    mov esi, 0xFFFF0000
    call theme_emit_bg
    mov rdi, [rip + sb + SB_ptr]
    lea rsi, [rip + x_bg_256]
    lea rdx, [rip + m_256_bg]
    call tcheck_str
    # near-neutral dark tint takes the greyscale ramp
    lea rdi, [rip + sb]
    call sb_clear
    lea rdi, [rip + sb]
    mov esi, 0xFF282832
    call theme_emit_fg
    mov rdi, [rip + sb + SB_ptr]
    lea rsi, [rip + x_ramp_256]
    lea rdx, [rip + m_ramp]
    call tcheck_str

    lea rdi, [rip + th]
    mov esi, THEME_16
    call theme_set_mode
    lea rdi, [rip + sb]
    call sb_clear
    lea rdi, [rip + sb]
    mov esi, 0xFFFF0000
    call theme_emit_fg
    mov rdi, [rip + sb + SB_ptr]
    lea rsi, [rip + x_fg_16]
    lea rdx, [rip + m_16_fg]
    call tcheck_str
    lea rdi, [rip + sb]
    call sb_clear
    lea rdi, [rip + sb]
    mov esi, 0xFFFF0000
    call theme_emit_bg
    mov rdi, [rip + sb + SB_ptr]
    lea rsi, [rip + x_bg_16]
    lea rdx, [rip + m_16_bg]
    call tcheck_str
    # muted (dark #7F849C) is pinned to ANSI bright black (index 8)
    lea rdi, [rip + sb]
    call sb_clear
    lea rdi, [rip + sb]
    mov esi, 0xFF7F849C
    call theme_emit_fg
    mov rdi, [rip + sb + SB_ptr]
    lea rsi, [rip + x_muted_16]
    lea rdx, [rip + m_mutedpin]
    call tcheck_str
    # TH_NO_BG is 49 regardless of mode
    lea rdi, [rip + sb]
    call sb_clear
    lea rdi, [rip + sb]
    xor esi, esi
    call theme_emit_bg
    mov rdi, [rip + sb + SB_ptr]
    lea rsi, [rip + x_no_bg]
    lea rdx, [rip + m_no_bg]
    call tcheck_str

    xor eax, eax
    EPILOGUE
.Lfail:
    mov eax, 1
    EPILOGUE

.section .bss
.p2align 3
rsp_tmp: .zero 512
