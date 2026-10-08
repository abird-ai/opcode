.include "opcode.inc"
.include "tui/theme.inc"
# theme: built-in dark/light palettes, JSONC overrides, named themes,
# 24-bit -> 256/16 downgrade.  See src/tui/API.md.
#
# Resolution order for `/theme <name>`:
#   * built-in "dark"/"light"/"system" (system reads $COLORFGBG),
#   * <name>.jsonc under the trusted project's .opcode/themes,
#   * <name>.jsonc under <config dir>/themes.
# The effective base is built-in -> <config>/theme.jsonc "base" -> named file
# "base"; config slots are applied next, then the named file's slots, so the
# most specific file wins slot by slot.

.set TF_base,  0            # -1 absent, 0 light, 1 dark
.set TF_has,   4            # 17 presence bytes
.set TF_rgb,  24            # 17 u32
.set TF_SIZE, 96

.section .rodata
.p2align 3
.globl theme_dark_colors
theme_dark_colors:
    .long 0xFFCDD6F4       # fg
    .long 0xFF1E1E2E       # bg
    .long 0xFF7F849C       # muted
    .long 0xFF89B4FA       # accent
    .long 0xFFA6E3A1       # ok
    .long 0xFFF9E2AF       # warn
    .long 0xFFF38BA8       # err
    .long 0xFF89DCEB       # user
    .long 0xFFCDD6F4       # assistant
    .long 0xFF6C7086       # thinking
    .long 0xFFCBA6F7       # tool
    .long 0xFFA6E3A1       # diff_add
    .long 0xFFF38BA8       # diff_del
    .long 0xFFF5C2E7       # code
    .long 0xFF283228       # tool_ok_bg
    .long 0xFF3C2828       # tool_err_bg
    .long 0xFF282832       # tool_bg

.p2align 3
.globl theme_light_colors
theme_light_colors:
    .long 0xFF1E1E2E       # fg
    .long 0xFFEFF1F5       # bg
    .long 0xFF6C6F85       # muted
    .long 0xFF1E66F5       # accent
    .long 0xFF40A02B       # ok
    .long 0xFFDF8E1D       # warn
    .long 0xFFD20F39       # err
    .long 0xFF04A5E5       # user
    .long 0xFF1E1E2E       # assistant
    .long 0xFF8C8FA1       # thinking
    .long 0xFF8839EF       # tool
    .long 0xFF40A02B       # diff_add
    .long 0xFFD20F39       # diff_del
    .long 0xFFEA76CB       # code
    .long 0xFFE8F0E8       # tool_ok_bg
    .long 0xFFF0E8E8       # tool_err_bg
    .long 0xFFE8E8F0       # tool_bg

.p2align 3
theme_slot_names:
    .quad .Ls_n_fg, .Ls_n_bg, .Ls_n_muted, .Ls_n_accent, .Ls_n_ok
    .quad .Ls_n_warn, .Ls_n_err, .Ls_n_user, .Ls_n_assistant
    .quad .Ls_n_thinking, .Ls_n_tool, .Ls_n_diff_add, .Ls_n_diff_del
    .quad .Ls_n_code, .Ls_n_tool_ok_bg, .Ls_n_tool_err_bg, .Ls_n_tool_bg

.Ls_n_fg:         .asciz "fg"
.Ls_n_bg:         .asciz "bg"
.Ls_n_muted:      .asciz "muted"
.Ls_n_accent:     .asciz "accent"
.Ls_n_ok:         .asciz "ok"
.Ls_n_warn:       .asciz "warn"
.Ls_n_err:        .asciz "err"
.Ls_n_user:       .asciz "user"
.Ls_n_assistant:  .asciz "assistant"
.Ls_n_thinking:   .asciz "thinking"
.Ls_n_tool:       .asciz "tool"
.Ls_n_diff_add:   .asciz "diff_add"
.Ls_n_diff_del:   .asciz "diff_del"
.Ls_n_code:       .asciz "code"
.Ls_n_tool_ok_bg: .asciz "tool_ok_bg"
.Ls_n_tool_err_bg:.asciz "tool_err_bg"
.Ls_n_tool_bg:    .asciz "tool_bg"

.Ls_base:      .asciz "base"
.Ls_light:     .asciz "light"
.Ls_dark:      .asciz "dark"
.Ls_system:    .asciz "system"
.Ls_jsonc:     .asciz ".jsonc"
.Ls_theme_jsonc: .asciz "/theme.jsonc"
.Ls_themes_slash: .asciz "/themes/"
.Ls_opcode_themes: .asciz "/.opcode/themes/"
.Ls_colorterm: .asciz "COLORTERM"
.Ls_term:      .asciz "TERM"
.Ls_colorfgbg: .asciz "COLORFGBG"
.Ls_truecolor: .asciz "truecolor"
.Ls_24bit:     .asciz "24bit"
.Ls_256:       .asciz "256"
.Ls_color:     .asciz "color"

.Ls_fg_true:   .ascii "\033[38;2;"
.Ls_bg_true:   .ascii "\033[48;2;"
.Ls_fg_256:    .ascii "\033[38;5;"
.Ls_bg_256:    .ascii "\033[48;5;"
.Ls_csi:       .ascii "\033["
.Ls_semi:      .ascii ";"
.Ls_m:         .ascii "m"
.Ls_49:        .ascii "\033[49m"

.p2align 3
theme_pal16:
    .long 0x000000, 0x800000, 0x008000, 0x808000, 0x000080, 0x800080, 0x008080, 0xC0C0C0
    .long 0x808080, 0xFF0000, 0x00FF00, 0xFFFF00, 0x0000FF, 0xFF00FF, 0x00FFFF, 0xFFFFFF

.data
.p2align 3
.globl theme_size
theme_size: .quad TH_SIZE

.bss
.p2align 3
g_theme_cur:     .quad 0
g_theme_proj:    .quad 0
g_theme_trusted: .zero 4
.p2align 3
theme_sb:        .zero SB_SIZE

.text

# ---------------------------------------------------------------- helpers
# theme_env(name cstr) -> cstr | 0.  Case-sensitive walk of g_envp.
theme_env:
    mov r8, [rip + g_envp]
    test r8, r8
    jz .Lte_none
    mov r9, rdi
.Lte_next:
    mov rsi, [r8]
    test rsi, rsi
    jz .Lte_none
    mov rdi, r9
    mov rdx, rsi
.Lte_cmp:
    mov al, [rdi]
    test al, al
    jz .Lte_name_end
    cmp al, [rdx]
    jne .Lte_skip
    inc rdi
    inc rdx
    jmp .Lte_cmp
.Lte_name_end:
    cmp byte ptr [rdx], '='
    jne .Lte_skip
    lea rax, [rdx + 1]
    ret
.Lte_skip:
    add r8, 8
    jmp .Lte_next
.Lte_none:
    xor eax, eax
    ret

# theme_contains(hay cstr, needle cstr) -> eax 1|0
theme_contains:
    mov al, [rsi]
    test al, al
    jz .Ltc_yes
.Ltc_next:
    mov al, [rdi]
    test al, al
    jz .Ltc_no
    mov rdx, rdi
    mov rcx, rsi
.Ltc_cmp:
    mov al, [rcx]
    test al, al
    jz .Ltc_yes
    cmp al, [rdx]
    jne .Ltc_adv
    inc rcx
    inc rdx
    jmp .Ltc_cmp
.Ltc_adv:
    inc rdi
    jmp .Ltc_next
.Ltc_yes:
    mov eax, 1
    ret
.Ltc_no:
    xor eax, eax
    ret

# theme_streq(a cstr, b cstr) -> eax 1|0
FN theme_streq
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

# theme_set_base(t rdi, dark esi): copy the dark/light built-in palette.
FN theme_set_base
    PROLOGUE 0
    mov rbx, rdi
    mov r12d, esi
    test r12d, r12d
    jz .Lsb_light
    lea r13, [rip + theme_dark_colors]
    jmp .Lsb_go
.Lsb_light:
    lea r13, [rip + theme_light_colors]
.Lsb_go:
    xor ecx, ecx
1:  cmp ecx, TH_COUNT
    jae 2f
    mov eax, [r13 + rcx*4]
    mov [rbx + TH_rgb + rcx*4], eax
    inc ecx
    jmp 1b
2:  mov [rbx + TH_dark], r12d
    EPILOGUE

# theme_system_dark() -> eax 1 dark | 0 light.  $COLORFGBG's last field: 0-6
# and 8 are dark, 7 and 9-15 light, anything unparseable falls back to dark.
FN theme_system_dark
    PROLOGUE 16
    lea rdi, [rip + .Ls_colorfgbg]
    call theme_env
    test rax, rax
    jz .Lsd_dark
    cmp byte ptr [rax], 0
    je .Lsd_dark
    mov rbx, rax
    mov r12d, -1               # last parsed index
.Lsd_loop:
    movzx eax, byte ptr [rbx]
    test al, al
    jz .Lsd_done
    cmp al, '0'
    jb .Lsd_next
    cmp al, '9'
    ja .Lsd_next
    xor r13d, r13d             # value
    xor r14d, r14d             # digits
    xor r15d, r15d             # overflow flag
.Lsd_dig:
    movzx eax, byte ptr [rbx]
    test al, al
    jz .Lsd_store
    cmp al, '0'
    jb .Lsd_store
    cmp al, '9'
    ja .Lsd_store
    cmp r14d, 3
    jae .Lsd_over
    imul r13d, r13d, 10
    sub eax, '0'
    add r13d, eax
    inc r14d
    inc rbx
    jmp .Lsd_dig
.Lsd_over:
    mov r15d, 1
    inc rbx
    jmp .Lsd_dig
.Lsd_store:
    test r15d, r15d
    jz 1f
    mov r12d, 16
    jmp .Lsd_loop
1:  mov r12d, r13d
    jmp .Lsd_loop
.Lsd_next:
    inc rbx
    jmp .Lsd_loop
.Lsd_done:
    cmp r12d, 0
    jl .Lsd_dark
    cmp r12d, 15
    ja .Lsd_dark
    cmp r12d, 7
    je .Lsd_light
    cmp r12d, 9
    jae .Lsd_light
.Lsd_dark:
    mov eax, 1
    EPILOGUE
.Lsd_light:
    xor eax, eax
    EPILOGUE

# theme_detect_mode() -> eax THEME_*.  24-bit default; COLORTERM truecolor/24bit
# selects true; TERM/COLORTERM 256 selects the cube; else the 16 ANSI colours.
FN theme_detect_mode
    PROLOGUE 0
    lea rdi, [rip + .Ls_colorterm]
    call theme_env
    mov rbx, rax
    test rbx, rbx
    jz .Ldm_term
    mov rdi, rbx
    lea rsi, [rip + .Ls_truecolor]
    call theme_contains
    test eax, eax
    jnz .Ldm_true
    mov rdi, rbx
    lea rsi, [rip + .Ls_24bit]
    call theme_contains
    test eax, eax
    jnz .Ldm_true
.Ldm_term:
    lea rdi, [rip + .Ls_term]
    call theme_env
    test rax, rax
    jz .Ldm_ct
    mov rdi, rax
    lea rsi, [rip + .Ls_256]
    call theme_contains
    test eax, eax
    jnz .Ldm_256
.Ldm_ct:
    test rbx, rbx
    jz .Ldm_16
    mov rdi, rbx
    lea rsi, [rip + .Ls_color]
    call theme_contains
    test eax, eax
    jnz .Ldm_256
.Ldm_16:
    xor eax, eax
    EPILOGUE
.Ldm_256:
    mov eax, THEME_256
    EPILOGUE
.Ldm_true:
    mov eax, THEME_TRUE
    EPILOGUE

# theme_parse_color(s rdi, out rsi) -> eax 1|0.  "#rrggbb"/"rrggbb" or the
# 3-digit short form; stored as 0xFFRRGGBB.
FN theme_parse_color
    test rdi, rdi
    jz .Lpc_no
    cmp byte ptr [rdi], '#'
    jne 1f
    inc rdi
1:  xor ecx, ecx
    xor edx, edx
.Lpc_loop:
    movzx eax, byte ptr [rdi + rcx]
    test al, al
    jz .Lpc_end
    cmp ecx, 8
    jae .Lpc_no
    cmp al, '0'
    jb .Lpc_alpha
    cmp al, '9'
    ja .Lpc_alpha
    sub eax, '0'
    jmp .Lpc_add
.Lpc_alpha:
    cmp al, 'a'
    jb .Lpc_upper
    cmp al, 'f'
    ja .Lpc_upper
    sub eax, 'a'
    add eax, 10
    jmp .Lpc_add
.Lpc_upper:
    cmp al, 'A'
    jb .Lpc_no
    cmp al, 'F'
    ja .Lpc_no
    sub eax, 'A'
    add eax, 10
.Lpc_add:
    shl edx, 4
    or edx, eax
    inc ecx
    jmp .Lpc_loop
.Lpc_end:
    cmp ecx, 3
    je .Lpc_short
    cmp ecx, 6
    jne .Lpc_no
    jmp .Lpc_store
.Lpc_short:
    mov r8d, edx
    and r8d, 0xF               # b
    mov r9d, edx
    shr r9d, 4
    and r9d, 0xF               # g
    mov r10d, edx
    shr r10d, 8
    and r10d, 0xF              # r
    mov edx, r10d
    shl edx, 4
    or edx, r10d
    shl edx, 16
    mov eax, r9d
    shl eax, 4
    or eax, r9d
    shl eax, 8
    or edx, eax
    mov eax, r8d
    shl eax, 4
    or eax, r8d
    or edx, eax
.Lpc_store:
    and edx, 0xFFFFFF
    or edx, 0xFF000000
    mov [rsi], edx
    mov eax, 1
    ret
.Lpc_no:
    xor eax, eax
    ret

# theme_load_file(path rdi, tf rsi) -> eax 1 valid JSON object | 0.
FN theme_load_file
    PROLOGUE 64
    mov rbx, rdi
    mov r12, rsi
    mov rdi, r12
    xor esi, esi
    mov edx, TF_SIZE
    call memset
    mov dword ptr [r12 + TF_base], -1
    test rbx, rbx
    jz .Ltlf_no
    xor eax, eax
    mov [rsp], rax
    mov [rsp + 8], rax
    mov [rsp + 16], rax
    mov rdi, rbx
    lea rsi, [rsp]
    call config_read_file
    test eax, eax
    jz .Ltlf_no
    mov rdi, [rsp + SB_ptr]
    mov rsi, [rsp + SB_len]
    call json_parse
    mov r13, rax
    lea rdi, [rsp]
    call sb_free
    test r13, r13
    jz .Ltlf_no
    mov rdi, r13
    call json_type
    cmp eax, JT_OBJ
    jne .Ltlf_no
    mov rdi, r13
    lea rsi, [rip + .Ls_base]
    call json_get_cstr
    test rax, rax
    jz .Ltlf_slots
    mov r14, rax
    mov rdi, r14
    lea rsi, [rip + .Ls_light]
    call theme_streq
    test eax, eax
    jz 1f
    mov dword ptr [r12 + TF_base], 0
    jmp .Ltlf_slots
1:  mov rdi, r14
    lea rsi, [rip + .Ls_dark]
    call theme_streq
    test eax, eax
    jz .Ltlf_slots
    mov dword ptr [r12 + TF_base], 1
.Ltlf_slots:
    xor r14d, r14d
.Ltlf_slot:
    cmp r14d, TH_COUNT
    jae .Ltlf_ok
    mov rdi, r13
    lea rax, [rip + theme_slot_names]
    mov rsi, [rax + r14*8]
    call json_get_cstr
    test rax, rax
    jz .Ltlf_next
    mov rdi, rax
    lea rsi, [r12 + TF_rgb + r14*4]
    call theme_parse_color
    test eax, eax
    jz .Ltlf_next
    mov byte ptr [r12 + TF_has + r14], 1
.Ltlf_next:
    inc r14d
    jmp .Ltlf_slot
.Ltlf_ok:
    mov eax, 1
    EPILOGUE
.Ltlf_no:
    xor eax, eax
    EPILOGUE

# theme_apply_slots(t rdi, tf rsi)
FN theme_apply_slots
    xor ecx, ecx
1:  cmp ecx, TH_COUNT
    jae 3f
    cmp byte ptr [rsi + TF_has + rcx], 0
    je 2f
    mov eax, [rsi + TF_rgb + rcx*4]
    mov [rdi + TH_rgb + rcx*4], eax
2:  inc ecx
    jmp 1b
3:  xor eax, eax
    ret

# theme_name_ok(name rdi) -> eax 1|0.  [A-Za-z0-9._-]{1,64}, no "." / "..".
FN theme_name_ok
    test rdi, rdi
    jz .Lnk_no
    xor ecx, ecx
1:  cmp ecx, 64
    jae .Lnk_no
    movzx eax, byte ptr [rdi + rcx]
    test al, al
    jz 2f
    inc ecx
    jmp 1b
2:  test ecx, ecx
    jz .Lnk_no
    cmp ecx, 1
    jne 3f
    cmp byte ptr [rdi], '.'
    je .Lnk_no
    jmp 4f
3:  cmp ecx, 2
    jne 4f
    cmp byte ptr [rdi], '.'
    jne 4f
    cmp byte ptr [rdi + 1], '.'
    je .Lnk_no
4:  xor edx, edx
5:  movzx eax, byte ptr [rdi + rdx]
    test al, al
    jz .Lnk_ok
    cmp al, 'A'
    jb 6f
    cmp al, 'Z'
    jbe 7f
6:  cmp al, 'a'
    jb 8f
    cmp al, 'z'
    jbe 7f
8:  cmp al, '0'
    jb 9f
    cmp al, '9'
    jbe 7f
9:  cmp al, '.'
    je 7f
    cmp al, '_'
    je 7f
    cmp al, '-'
    je 7f
    jmp .Lnk_no
7:  inc edx
    jmp 5b
.Lnk_ok:
    mov eax, 1
    ret
.Lnk_no:
    xor eax, eax
    ret

# theme_is_file(path rdi) -> eax 1|0
FN theme_is_file
    PROLOGUE 0
    mov r12, rdi
    mov rdi, r12
    mov esi, O_RDONLY
    xor edx, edx
    call os_open
    test rax, rax
    js .Lif_no
    mov edi, eax
    call os_close
    mov eax, 1
    EPILOGUE
.Lif_no:
    xor eax, eax
    EPILOGUE

# theme_join_copy(base rdi, suffix rsi, out rdx, cap ecx) -> eax 1
FN theme_join_copy
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14d, ecx
    dec r14d
    xor r15d, r15d
    test r14d, r14d
    jle .Ljc_fin
1:  mov al, [rbx]
    test al, al
    jz 2f
    cmp r15d, r14d
    jae .Ljc_fin
    mov [r13 + r15], al
    inc r15d
    inc rbx
    jmp 1b
2:  mov al, [r12]
    test al, al
    jz .Ljc_fin
    cmp r15d, r14d
    jae .Ljc_fin
    mov [r13 + r15], al
    inc r15d
    inc r12
    jmp 2b
.Ljc_fin:
    mov byte ptr [r13 + r15], 0
    mov eax, 1
    EPILOGUE

# theme_resolve_named(name rdi, out rsi, cap edx) -> eax 1 path found | 0.
FN theme_resolve_named
    PROLOGUE 32
    mov r12, rdi
    mov r13, rsi
    mov r14d, edx
    mov rdi, r12
    call theme_name_ok
    test eax, eax
    jz .Lrn_no
    # trusted project: <cwd>/.opcode/themes/<name>.jsonc
    cmp dword ptr [rip + g_theme_trusted], 0
    je .Lrn_cfg
    mov rax, [rip + g_theme_proj]
    test rax, rax
    jz .Lrn_cfg
    lea rdi, [rip + theme_sb]
    call sb_clear
    lea rdi, [rip + theme_sb]
    mov rsi, [rip + g_theme_proj]
    call sb_push_cstr
    lea rdi, [rip + theme_sb]
    lea rsi, [rip + .Ls_opcode_themes]
    call sb_push_cstr
    lea rdi, [rip + theme_sb]
    mov rsi, r12
    call sb_push_cstr
    lea rdi, [rip + theme_sb]
    lea rsi, [rip + .Ls_jsonc]
    call sb_push_cstr
    mov rdi, [rip + theme_sb + SB_ptr]
    call theme_is_file
    test eax, eax
    jnz .Lrn_copy
.Lrn_cfg:
    call config_user_dir
    test rax, rax
    jz .Lrn_no
    mov r15, rax
    lea rdi, [rip + theme_sb]
    call sb_clear
    lea rdi, [rip + theme_sb]
    mov rsi, r15
    call sb_push_cstr
    lea rdi, [rip + theme_sb]
    lea rsi, [rip + .Ls_themes_slash]
    call sb_push_cstr
    lea rdi, [rip + theme_sb]
    mov rsi, r12
    call sb_push_cstr
    lea rdi, [rip + theme_sb]
    lea rsi, [rip + .Ls_jsonc]
    call sb_push_cstr
    mov rdi, [rip + theme_sb + SB_ptr]
    call theme_is_file
    test eax, eax
    jz .Lrn_no
.Lrn_copy:
    mov rsi, [rip + theme_sb + SB_ptr]
    mov rdi, r13
    mov ecx, r14d
    dec ecx
    xor edx, edx
1:  cmp edx, ecx
    jae 2f
    mov al, [rsi + rdx]
    test al, al
    jz 2f
    mov [rdi + rdx], al
    inc edx
    jmp 1b
2:  mov byte ptr [rdi + rdx], 0
    mov eax, 1
    EPILOGUE
.Lrn_no:
    xor eax, eax
    EPILOGUE

# ------------------------------------------------------------------ lifecycle
# theme_init(t rdi, dark esi)
FN theme_init
    PROLOGUE 0
    mov rbx, rdi
    mov r12d, esi
    mov rdi, rbx
    mov esi, r12d
    call theme_set_base
    mov dword ptr [rbx + TH_force_bg], 0
    call theme_detect_mode
    mov [rbx + TH_mode], eax
    EPILOGUE

# theme_set_project_root(cwd rdi, trusted esi)
FN theme_set_project_root
    PROLOGUE 0
    mov rbx, rdi
    mov r12d, esi
    mov rdi, [rip + g_theme_proj]
    call mem_free
    mov qword ptr [rip + g_theme_proj], 0
    mov dword ptr [rip + g_theme_trusted], 0
    test r12d, r12d
    jz .Lpr_done
    test rbx, rbx
    jz .Lpr_done
    cmp byte ptr [rbx], 0
    je .Lpr_done
    mov rdi, rbx
    call strlen
    mov rdi, rbx
    mov rsi, rax
    call mem_dup
    mov [rip + g_theme_proj], rax
    mov dword ptr [rip + g_theme_trusted], 1
.Lpr_done:
    EPILOGUE

# theme_apply_named(t rdi, name rsi) -> eax 1 applied | 0 unknown
FN theme_apply_named
    PROLOGUE 4608
    mov rbx, rdi
    mov r12, rsi
    test r12, r12
    jz .Lan_fail
    cmp byte ptr [r12], 0
    je .Lan_fail
    mov dword ptr [rbp - 512], 0       # AN_have_cfg
    mov dword ptr [rbp - 508], 0       # AN_have_named
    mov dword ptr [rbp - 504], 1       # AN_dark default
    mov dword ptr [rbp - 500], 0       # AN_force
    # ---- config theme.jsonc (base + slot overrides) ----
    call config_user_dir
    test rax, rax
    jz .Lan_classify
    mov rdi, rax
    lea rsi, [rip + .Ls_theme_jsonc]
    lea rdx, [rbp - 4608]
    mov ecx, 4096
    call theme_join_copy
    lea rdi, [rbp - 4608]
    lea rsi, [rbp - 416]               # AN_cfg
    call theme_load_file
    test eax, eax
    jz .Lan_classify
    mov dword ptr [rbp - 512], 1
.Lan_classify:
    mov rdi, r12
    lea rsi, [rip + .Ls_system]
    call theme_streq
    test eax, eax
    jnz .Lan_system
    mov rdi, r12
    lea rsi, [rip + .Ls_dark]
    call theme_streq
    test eax, eax
    jnz .Lan_dark
    mov rdi, r12
    lea rsi, [rip + .Ls_light]
    call theme_streq
    test eax, eax
    jnz .Lan_light
    # named file
    mov rdi, r12
    lea rsi, [rbp - 4608]
    mov edx, 4096
    call theme_resolve_named
    test eax, eax
    jz .Lan_fail
    mov dword ptr [rbp - 508], 1
    lea rdi, [rbp - 4608]
    lea rsi, [rbp - 320]               # AN_named
    call theme_load_file
    jmp .Lan_resolve
.Lan_system:
    call theme_system_dark
    mov [rbp - 504], eax
    jmp .Lan_resolve
.Lan_dark:
    mov dword ptr [rbp - 504], 1
    mov dword ptr [rbp - 500], 1
    jmp .Lan_resolve
.Lan_light:
    mov dword ptr [rbp - 504], 0
    mov dword ptr [rbp - 500], 1
.Lan_resolve:
    mov eax, [rbp - 504]
    cmp dword ptr [rbp - 512], 0
    je 1f
    cmp dword ptr [rbp - 416 + TF_base], 0
    jl 1f
    mov eax, [rbp - 416 + TF_base]
1:  cmp dword ptr [rbp - 508], 0
    je 2f
    cmp dword ptr [rbp - 320 + TF_base], 0
    jl 2f
    mov eax, [rbp - 320 + TF_base]
2:  mov rdi, rbx
    mov esi, eax
    call theme_set_base
    cmp dword ptr [rbp - 512], 0
    je 3f
    mov rdi, rbx
    lea rsi, [rbp - 416]
    call theme_apply_slots
3:  cmp dword ptr [rbp - 508], 0
    je 4f
    mov rdi, rbx
    lea rsi, [rbp - 320]
    call theme_apply_slots
4:  mov eax, [rbp - 500]
    mov [rbx + TH_force_bg], eax
    mov eax, 1
    EPILOGUE
.Lan_fail:
    xor eax, eax
    EPILOGUE

# theme_set_current(t rdi)
FN theme_set_current
    mov [rip + g_theme_cur], rdi
    xor eax, eax
    ret

# theme_set_mode(t rdi, mode esi)
FN theme_set_mode
    cmp esi, THEME_16
    jge 1f
    xor esi, esi
1:  cmp esi, THEME_TRUE
    jle 2f
    mov esi, THEME_TRUE
2:  mov [rdi + TH_mode], esi
    xor eax, eax
    ret

# theme_rgb(slot esi) -> rax 0xAARRGGBB; TH_NO_BG -> 0
FN theme_rgb
    cmp esi, TH_NO_BG
    je .Lrgb_zero
    mov rax, [rip + g_theme_cur]
    test rax, rax
    jz .Lrgb_default
    cmp esi, TH_COUNT
    jae .Lrgb_zero
    mov eax, [rax + TH_rgb + rsi*4]
    ret
.Lrgb_default:
    cmp esi, TH_COUNT
    jae .Lrgb_zero
    lea rax, [rip + theme_dark_colors]
    mov eax, [rax + rsi*4]
    ret
.Lrgb_zero:
    xor eax, eax
    ret

# ---------------------------------------------------------------- downgrade
# theme_rgb_to_256(color edi) -> eax 0..255
FN theme_rgb_to_256
    PROLOGUE 32
    mov eax, edi
    shr eax, 16
    and eax, 0xFF
    mov [rsp], eax                 # r
    mov eax, edi
    shr eax, 8
    and eax, 0xFF
    mov [rsp + 4], eax             # g
    mov eax, edi
    and eax, 0xFF
    mov [rsp + 8], eax             # b
    mov eax, [rsp]
    mov ecx, [rsp + 4]
    cmp eax, ecx
    jae 1f
    mov eax, ecx
1:  mov ecx, [rsp + 8]
    cmp eax, ecx
    jae 2f
    mov eax, ecx
2:  mov [rsp + 12], eax            # mx
    mov eax, [rsp]
    mov ecx, [rsp + 4]
    cmp eax, ecx
    jbe 3f
    mov eax, ecx
3:  mov ecx, [rsp + 8]
    cmp eax, ecx
    jbe 4f
    mov eax, ecx
4:  mov edx, [rsp + 12]
    sub edx, eax
    cmp edx, 24
    jg .Lc_cube
    cmp dword ptr [rsp + 12], 96
    jge .Lc_cube
    # near-neutral dark: nearest greyscale-ramp entry
    mov dword ptr [rsp + 16], 0
    mov dword ptr [rsp + 20], -1
    xor ecx, ecx
.Lc_ramp:
    cmp ecx, 24
    jae .Lc_ramp_done
    lea esi, [rcx + rcx*4]
    lea esi, [rsi + rsi]
    add esi, 8
    mov edi, [rsp]
    sub edi, esi
    imul edi, edi
    mov edx, [rsp + 4]
    sub edx, esi
    imul edx, edx
    add edi, edx
    mov edx, [rsp + 8]
    sub edx, esi
    imul edx, edx
    add edi, edx
    mov edx, [rsp + 20]
    cmp edx, 0
    jl .Lc_ramp_set
    cmp edi, edx
    jae .Lc_ramp_next
.Lc_ramp_set:
    mov [rsp + 20], edi
    mov [rsp + 16], ecx
.Lc_ramp_next:
    inc ecx
    jmp .Lc_ramp
.Lc_ramp_done:
    mov eax, [rsp + 16]
    add eax, 232
    EPILOGUE
.Lc_cube:
    mov eax, [rsp]
    cmp eax, [rsp + 4]
    jne .Lc_color
    cmp eax, [rsp + 8]
    jne .Lc_color
    cmp eax, 8
    jb .Lc_16
    cmp eax, 248
    ja .Lc_231
    mov edx, eax
    sub edx, 8
    mov eax, edx
    xor edx, edx
    mov ecx, 10
    div ecx
    add eax, 232
    cmp eax, 255
    jbe .Lc_done
    mov eax, 255
    EPILOGUE
.Lc_16:
    mov eax, 16
    EPILOGUE
.Lc_231:
    mov eax, 231
    EPILOGUE
.Lc_done:
    EPILOGUE
.Lc_color:
    mov eax, [rsp]
    imul eax, eax, 5
    add eax, 127
    xor edx, edx
    mov ecx, 255
    div ecx
    mov edi, eax
    mov eax, [rsp + 4]
    imul eax, eax, 5
    add eax, 127
    xor edx, edx
    mov ecx, 255
    div ecx
    mov esi, eax
    mov eax, [rsp + 8]
    imul eax, eax, 5
    add eax, 127
    xor edx, edx
    mov ecx, 255
    div ecx
    imul edi, edi, 36
    imul esi, esi, 6
    add edi, esi
    add edi, eax
    lea eax, [rdi + 16]
    EPILOGUE

# theme_rgb_to_16(color edi) -> eax 0..15 nearest ANSI colour
FN theme_rgb_to_16
    PROLOGUE 0
    mov r8d, edi
    shr r8d, 16
    and r8d, 0xFF                  # r
    mov r9d, edi
    shr r9d, 8
    and r9d, 0xFF                  # g
    mov r10d, edi
    and r10d, 0xFF                 # b
    lea r11, [rip + theme_pal16]
    mov ecx, -1
    xor edx, edx
    xor esi, esi
.Lp_loop:
    cmp esi, 16
    jae .Lp_done
    mov eax, [r11 + rsi*4]
    mov r12d, eax
    shr r12d, 16
    and r12d, 0xFF
    sub r12d, r8d
    imul r12d, r12d
    mov r13d, eax
    shr r13d, 8
    and r13d, 0xFF
    sub r13d, r9d
    imul r13d, r13d
    add r12d, r13d
    mov r13d, eax
    and r13d, 0xFF
    sub r13d, r10d
    imul r13d, r13d
    add r12d, r13d
    cmp ecx, 0
    jl .Lp_set
    cmp r12d, ecx
    jae .Lp_next
.Lp_set:
    mov ecx, r12d
    mov edx, esi
.Lp_next:
    inc esi
    jmp .Lp_loop
.Lp_done:
    mov eax, edx
    EPILOGUE

# ---------------------------------------------------------------- emitter
# theme_emit_color(sb rdi, color esi, fg edx)
FN theme_emit_color
    PROLOGUE 16
    mov rbx, rdi
    mov r12d, esi
    test r12d, r12d
    jz .Lec_done
    mov r13d, edx
    mov rax, [rip + g_theme_cur]
    mov r14d, THEME_TRUE
    test rax, rax
    jz 1f
    mov r14d, [rax + TH_mode]
1:  cmp r14d, THEME_TRUE
    je .Lec_true
    cmp r14d, THEME_256
    je .Lec_256
    jmp .Lec_16
.Lec_true:
    mov rdi, rbx
    test r13d, r13d
    jz 2f
    lea rsi, [rip + .Ls_fg_true]
    mov edx, 7
    jmp 3f
2:  lea rsi, [rip + .Ls_bg_true]
    mov edx, 7
3:  call sb_push
    mov esi, r12d
    shr esi, 16
    and esi, 0xFF
    mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ls_semi]
    mov edx, 1
    call sb_push
    mov esi, r12d
    shr esi, 8
    and esi, 0xFF
    mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ls_semi]
    mov edx, 1
    call sb_push
    mov esi, r12d
    and esi, 0xFF
    mov rdi, rbx
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ls_m]
    mov edx, 1
    call sb_push
    EPILOGUE
.Lec_256:
    mov edi, r12d
    call theme_rgb_to_256
    mov r15d, eax
    mov rdi, rbx
    test r13d, r13d
    jz 4f
    lea rsi, [rip + .Ls_fg_256]
    mov edx, 7
    jmp 5f
4:  lea rsi, [rip + .Ls_bg_256]
    mov edx, 7
5:  call sb_push
    mov rdi, rbx
    mov esi, r15d
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ls_m]
    mov edx, 1
    call sb_push
    EPILOGUE
.Lec_16:
    mov esi, TH_MUTED
    call theme_rgb
    cmp eax, r12d
    je .Lec_pin
    mov edi, r12d
    call theme_rgb_to_16
    mov r15d, eax
    jmp .Lec_code
.Lec_pin:
    mov r15d, 8
.Lec_code:
    test r13d, r13d
    jz 6f
    cmp r15d, 8
    jb 7f
    sub r15d, 8
    add r15d, 90
    jmp 8f
7:  add r15d, 30
    jmp 8f
6:  cmp r15d, 8
    jb 9f
    sub r15d, 8
    add r15d, 100
    jmp 8f
9:  add r15d, 40
8:  mov rdi, rbx
    lea rsi, [rip + .Ls_csi]
    mov edx, 2
    call sb_push
    mov rdi, rbx
    mov esi, r15d
    call sb_push_u64
    mov rdi, rbx
    lea rsi, [rip + .Ls_m]
    mov edx, 1
    call sb_push
    EPILOGUE
.Lec_done:
    EPILOGUE

# theme_emit_fg(sb rdi, color esi)
FN theme_emit_fg
    mov edx, 1
    jmp theme_emit_color

# theme_emit_bg(sb rdi, color esi): 0 -> SGR 49 (terminal default)
FN theme_emit_bg
    test esi, esi
    jz .Leb_49
    xor edx, edx
    jmp theme_emit_color
.Leb_49:
    lea rsi, [rip + .Ls_49]
    mov edx, 5
    jmp sb_push
