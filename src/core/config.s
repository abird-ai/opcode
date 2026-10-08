.include "opcode.inc"
.include "core/core.inc"
# config.s: JSONC configuration, trust file and config-dir resolution (M3).
# Contract: src/core/API.md.
#
#   user config    <config dir>/config.jsonc
#   project config <cwd>/.opcode/config.jsonc   (loaded only when trusted)
#   trust file     <config dir>/trust.jsonc
#   auth file      <config dir>/auth.jsonc      (read by auth.s)
#
# <config dir> is g_config_home when the app set it before calling config_load
# (debug/test override; the same global is read by prompt.s), else
# $XDG_CONFIG_HOME/opcode, else $HOME/.config/opcode.
#
# The JSON parser owns a single-document arena, so config_load keeps the raw
# bytes of each accepted file and every lookup re-parses them on demand.
# Every string returned by config_* is a mem_alloc'd copy owned by the caller.
#
# Internal helpers shared with auth.s: config_user_dir, config_path_join,
# config_read_file (not part of the frozen API, but needed to avoid duplicating
# the path/read logic).

.bss
.p2align 3
.globl g_config_approve
g_config_approve: .quad 0       # set by --approve before config_load
.globl g_config_home
g_config_home:    .quad 0       # app/test override: the opcode config dir; 0 = XDG/HOME
cfg_dir:      .quad 0           # cached <config dir>, process lifetime
cfg_user:     .quad 0           # raw user config.jsonc bytes (owned)
cfg_user_len: .quad 0
cfg_proj:     .quad 0           # raw project config.jsonc bytes (owned)
cfg_proj_len: .quad 0

.section .rodata
.Lenv_xdg:       .asciz "XDG_CONFIG_HOME"
.Lenv_home:      .asciz "HOME"
.Lsub_opcode:    .asciz "/opcode"
.Lsub_dotconfig: .asciz "/.config/opcode"
.Lconfig_name:   .asciz "/config.jsonc"
.Ltrust_name:    .asciz "/trust.jsonc"
.Ltmp_suffix:    .asciz ".tmp"
.Lproj_name:     .asciz "/.opcode/config.jsonc"
.Lsession_key:   .asciz "session_dir"
.Lthinking_key:  .asciz "default_thinking"
.Ltheme_key:     .asciz "theme"
.Ltrusted_key:   .asciz "trusted"
.Lproviders_dot: .asciz "providers."
.Lapi_keys_dot:  .asciz "api_keys."
.Lbase_url_dot:  .asciz ".base_url"
.Lprefix_trust:  .asciz "{\"trusted\":["
.Lsuffix_trust:  .asciz "]}\n"
.Lwarn_prefix:   .asciz "opcode: warning: invalid config "
# config_save/merge keys
.Lkey_dp:        .asciz "default_provider"
.Lkey_dm:        .asciz "default_model"
.Lkey_pv:        .asciz "providers"
.Lkey_base:      .asciz "base_url"
.Lslash:         .asciz "/"
.text

# env_get(name cstr) -> cstr | 0.  Case-sensitive walk of the NULL-terminated
# g_envp array looking for "name=" and returning the value pointer.
env_get:
    mov r8, [rip + g_envp]
    test r8, r8
    jz .Leg_none
    mov r9, rdi
.Leg_next:
    mov rsi, [r8]
    test rsi, rsi
    jz .Leg_none
    mov rdi, r9
    mov rdx, rsi
.Leg_cmp:
    mov al, [rdi]
    test al, al
    jz .Leg_name_end
    cmp al, [rdx]
    jne .Leg_skip
    inc rdi
    inc rdx
    jmp .Leg_cmp
.Leg_name_end:
    cmp byte ptr [rdx], '='
    jne .Leg_skip
    lea rax, [rdx + 1]
    ret
.Leg_skip:
    add r8, 8
    jmp .Leg_next
.Leg_none:
    xor eax, eax
    ret

# stpcpy(dst, src) -> end pointer (points at the written NUL)
.Lstpcpy:
    mov rax, rdi
1:  mov cl, [rsi]
    mov [rax], cl
    inc rax
    inc rsi
    test cl, cl
    jnz 1b
    dec rax
    ret

# ---------------------------------------------------------------------------
# config_path_join(base cstr, suffix cstr) -> mem_alloc'd cstr | 0
# Internal helper (auth.s); caller owns the result.
FN config_path_join
    PROLOGUE 32
    mov rbx, rdi
    mov r12, rsi
    xor eax, eax
    mov [rsp + SB_ptr], rax
    mov [rsp + SB_len], rax
    mov [rsp + SB_cap], rax
    lea rdi, [rsp]
    mov rsi, rbx
    call sb_push_cstr
    lea rdi, [rsp]
    mov rsi, r12
    call sb_push_cstr
    mov rdi, [rsp + SB_ptr]
    mov rsi, [rsp + SB_len]
    call mem_dup
    mov rbx, rax
    lea rdi, [rsp]
    call sb_free
    mov rax, rbx
    EPILOGUE

# config_user_dir() -> cstr | 0.  The opcode config directory, cached for the
# process lifetime (borrowed; do not free).  Internal helper (auth.s).
FN config_user_dir
    PROLOGUE 16
    mov rax, [rip + cfg_dir]
    test rax, rax
    jnz .Lcud_ret
    mov rbx, [rip + g_config_home]
    test rbx, rbx
    jz .Lcud_xdg
    mov [rip + cfg_dir], rbx    # the override is already the config dir
    mov rax, rbx
    jmp .Lcud_ret
.Lcud_xdg:
    lea rdi, [rip + .Lenv_xdg]
    call env_get
    test rax, rax
    jz .Lcud_home
    cmp byte ptr [rax], 0
    je .Lcud_home
    mov rbx, rax
    lea rsi, [rip + .Lsub_opcode]
    jmp .Lcud_build
.Lcud_home:
    lea rdi, [rip + .Lenv_home]
    call env_get
    test rax, rax
    jz .Lcud_none
    cmp byte ptr [rax], 0
    je .Lcud_none
    mov rbx, rax
    lea rsi, [rip + .Lsub_dotconfig]
.Lcud_build:
    mov rdi, rbx
    call config_path_join
    mov [rip + cfg_dir], rax
.Lcud_ret:
    EPILOGUE
.Lcud_none:
    xor eax, eax
    EPILOGUE

# config_read_file(path cstr, out SB*) -> 1|0.  Reads the whole file into out
# (which the caller initialized); 0 when missing or unreadable.  Internal
# helper (auth.s).
FN config_read_file
    PROLOGUE 4112
    mov rbx, rdi
    mov r12, rsi
    xor esi, esi                # O_RDONLY
    xor edx, edx
    call os_open
    test rax, rax
    js .Lcrf_no
    mov r13d, eax
.Lcrf_loop:
    mov edi, r13d
    mov rsi, rsp
    mov edx, 4096
    call os_read
    cmp rax, -EINTR
    je .Lcrf_loop
    test rax, rax
    js .Lcrf_fail
    jz .Lcrf_eof
    mov rdi, r12
    mov rsi, rsp
    mov rdx, rax
    call sb_push
    jmp .Lcrf_loop
.Lcrf_eof:
    mov edi, r13d
    call os_close
    mov eax, 1
    EPILOGUE
.Lcrf_fail:
    mov edi, r13d
    call os_close
.Lcrf_no:
    xor eax, eax
    EPILOGUE

# ---------------------------------------------------------------------------
# json_get_dotted(jv, key cstr) -> JV* | 0; '.' splits nested keys.
.Ljson_get_dotted:
    PROLOGUE 256
    mov rbx, rdi
    mov r12, rsi
.Lgd_loop:
    test rbx, rbx
    jz .Lgd_none
    xor r13d, r13d
.Lgd_copy:
    mov al, [r12]
    test al, al
    jz .Lgd_last
    cmp al, '.'
    je .Lgd_seg_dot
    cmp r13d, 255
    jae .Lgd_none
    mov [rsp + r13], al
    inc r13
    inc r12
    jmp .Lgd_copy
.Lgd_seg_dot:
    inc r12                     # skip the separator
.Lgd_nested:
    mov byte ptr [rsp + r13], 0
    mov rdi, rbx
    mov rsi, rsp
    call json_get
    mov rbx, rax
    test rbx, rbx
    jz .Lgd_none
    jmp .Lgd_loop
.Lgd_last:
    mov byte ptr [rsp + r13], 0
    mov rdi, rbx
    mov rsi, rsp
    call json_get
    EPILOGUE
.Lgd_none:
    xor eax, eax
    EPILOGUE

# config_lookup(key cstr) -> rax ptr, rdx len into the arena (valid until the
# next json_parse) or 0,0.  Project first, then user.
.Lconfig_lookup:
    PROLOGUE 0
    mov rbx, rdi
    mov rdi, [rip + cfg_proj]
    test rdi, rdi
    jz .Lcl_user
    mov rsi, [rip + cfg_proj_len]
    call json_parse
    test rax, rax
    jz .Lcl_user
    mov rdi, rax
    mov rsi, rbx
    call .Ljson_get_dotted
    test rax, rax
    jz .Lcl_user
    cmp dword ptr [rax + JV_type], JT_STR
    jne .Lcl_user
    mov rdi, rax
    call json_str
    test rax, rax
    jz .Lcl_user
    EPILOGUE
.Lcl_user:
    mov rdi, [rip + cfg_user]
    test rdi, rdi
    jz .Lcl_none
    mov rsi, [rip + cfg_user_len]
    call json_parse
    test rax, rax
    jz .Lcl_none
    mov rdi, rax
    mov rsi, rbx
    call .Ljson_get_dotted
    test rax, rax
    jz .Lcl_none
    cmp dword ptr [rax + JV_type], JT_STR
    jne .Lcl_none
    mov rdi, rax
    call json_str
    test rax, rax
    jz .Lcl_none
    EPILOGUE
.Lcl_none:
    xor eax, eax
    xor edx, edx
    EPILOGUE

# ---------------------------------------------------------------------------
# config_str(key cstr) -> mem_alloc'd cstr | 0.  Dotted keys walk nested
# objects, e.g. "providers.openai.base_url".
FN config_str
    PROLOGUE 0
    call .Lconfig_lookup
    test rax, rax
    jz .Lcs_none
    mov rdi, rax
    mov rsi, rdx
    call mem_dup
    EPILOGUE
.Lcs_none:
    xor eax, eax
    EPILOGUE

# config_provider_base(provider cstr) -> mem_alloc'd cstr | 0
FN config_provider_base
    PROLOGUE 288
    mov rbx, rdi
    call strlen
    cmp rax, 230
    ja .Lcpb_none
    mov rdi, rsp
    lea rsi, [rip + .Lproviders_dot]
    call .Lstpcpy
    mov rdi, rax
    mov rsi, rbx
    call .Lstpcpy
    mov rdi, rax
    lea rsi, [rip + .Lbase_url_dot]
    call .Lstpcpy
    mov rdi, rsp
    call config_str
    EPILOGUE
.Lcpb_none:
    xor eax, eax
    EPILOGUE

# config_api_key(provider cstr) -> mem_alloc'd cstr | 0
FN config_api_key
    PROLOGUE 288
    mov rbx, rdi
    call strlen
    cmp rax, 260
    ja .Lcak_none
    mov rdi, rsp
    lea rsi, [rip + .Lapi_keys_dot]
    call .Lstpcpy
    mov rdi, rax
    mov rsi, rbx
    call .Lstpcpy
    mov rdi, rsp
    call config_str
    EPILOGUE
.Lcak_none:
    xor eax, eax
    EPILOGUE

# config_session_dir() -> mem_alloc'd cstr | 0
FN config_session_dir
    lea rdi, [rip + .Lsession_key]
    jmp config_str

# config_default_thinking() -> mem_alloc'd cstr | 0.  The configured
# `default_thinking` name ("off"/"low"/"medium"/"high"), else 0.  Parsed by
# agent_thinking_parse; the CLI --thinking flag wins over this value.
FN config_default_thinking
    lea rdi, [rip + .Lthinking_key]
    jmp config_str

# config_default_theme() -> mem_alloc'd cstr | 0.  The configured `theme` name
# ("system"/"dark"/"light"/named); the CLI --theme flag wins.
FN config_default_theme
    lea rdi, [rip + .Ltheme_key]
    jmp config_str

# ---------------------------------------------------------------------------
# config_trusted(cwd cstr) -> 1|0.  g_config_approve wins; otherwise cwd must
# appear in "trusted" in <config dir>/trust.jsonc.
FN config_trusted
    PROLOGUE 48
    mov rbx, rdi
    xor r15d, r15d
    mov rax, [rip + g_config_approve]
    test rax, rax
    jz .Lct_file
    mov eax, 1
    EPILOGUE
.Lct_file:
    call config_user_dir
    test rax, rax
    jz .Lct_done
    mov rdi, rax
    lea rsi, [rip + .Ltrust_name]
    call config_path_join
    test rax, rax
    jz .Lct_done
    mov r12, rax
    xor eax, eax
    mov [rsp], rax
    mov [rsp + 8], rax
    mov [rsp + 16], rax
    mov rdi, r12
    lea rsi, [rsp]
    call config_read_file
    test eax, eax
    jz .Lct_cleanup
    mov rdi, [rsp + SB_ptr]
    mov rsi, [rsp + SB_len]
    call json_parse
    test rax, rax
    jz .Lct_cleanup
    mov rdi, rax
    lea rsi, [rip + .Ltrusted_key]
    call json_get
    test rax, rax
    jz .Lct_cleanup
    cmp dword ptr [rax + JV_type], JT_ARR
    jne .Lct_cleanup
    mov r13, rax                # trusted array
    xor r14d, r14d
.Lct_loop:
    mov rdi, r13
    mov esi, r14d
    call json_at
    test rax, rax
    jz .Lct_cleanup
    mov rdi, rax
    call json_str
    test rax, rax
    jz .Lct_next
    mov rdi, rax
    mov rsi, rdx
    mov rdx, rbx
    call str_eq_cstr
    test eax, eax
    jnz .Lct_yes
.Lct_next:
    inc r14d
    jmp .Lct_loop
.Lct_yes:
    mov r15d, 1
.Lct_cleanup:
    lea rdi, [rsp]
    call sb_free
    mov rdi, r12
    call mem_free
.Lct_done:
    mov eax, r15d
    EPILOGUE

# config_trust_save(cwd cstr) -> 0 | -errno.  Rewrites trust.jsonc with cwd
# appended (a simple read + re-emit through jsonw), atomically: <file>.tmp
# then os_rename.
FN config_trust_save
    PROLOGUE 128
    mov qword ptr [rsp + 96], 0     # result
    mov qword ptr [rsp + 104], 0    # temp path | 0
    mov rbx, rdi                    # cwd
    call config_user_dir
    test rax, rax
    jz .Lcts_err_noent
    mov r12, rax
    mov rdi, r12
    mov esi, 0700                  # config dir: only the user (holds api_keys)
    call os_mkdir
    mov rdi, r12
    lea rsi, [rip + .Ltrust_name]
    call config_path_join
    test rax, rax
    jz .Lcts_err_noent
    mov r13, rax                    # trust path
    xor eax, eax
    mov [rsp], rax
    mov [rsp + 8], rax
    mov [rsp + 16], rax
    mov [rsp + 32], rax
    mov [rsp + 40], rax
    mov [rsp + 48], rax
    # re-emit the existing entries
    mov rdi, r13
    lea rsi, [rsp]
    call config_read_file
    lea rdi, [rsp + 32]
    lea rsi, [rip + .Lprefix_trust]
    call sb_push_cstr
    xor r14d, r14d
    cmp qword ptr [rsp + SB_ptr], 0
    je .Lcts_append
    mov rdi, [rsp + SB_ptr]
    mov rsi, [rsp + SB_len]
    call json_parse
    test rax, rax
    jz .Lcts_append
    mov rdi, rax
    lea rsi, [rip + .Ltrusted_key]
    call json_get
    test rax, rax
    jz .Lcts_append
    cmp dword ptr [rax + JV_type], JT_ARR
    jne .Lcts_append
    mov [rsp + 64], rax             # trusted array
.Lcts_loop:
    mov rdi, [rsp + 64]
    mov esi, r14d
    call json_at
    test rax, rax
    jz .Lcts_append
    mov rdi, rax
    call json_str
    test rax, rax
    jz .Lcts_next
    mov [rsp + 72], rax
    mov [rsp + 80], rdx
    mov rdi, rax
    mov rsi, rdx
    mov rdx, rbx
    call str_eq_cstr
    test eax, eax
    jnz .Lcts_exists
    lea rdi, [rsp + 32]
    mov rsi, [rsp + 72]
    mov rdx, [rsp + 80]
    call jsonw_str
.Lcts_next:
    inc r14d
    jmp .Lcts_loop
.Lcts_exists:
    # already trusted: keep the file as it is
    jmp .Lcts_cleanup
.Lcts_append:
    lea rdi, [rsp + 32]
    mov rsi, rbx
    call jsonw_str_cstr
    lea rdi, [rsp + 32]
    lea rsi, [rip + .Lsuffix_trust]
    call sb_push_cstr
    # write <trust>.tmp
    mov rdi, r13
    lea rsi, [rip + .Ltmp_suffix]
    call config_path_join
    test rax, rax
    jz .Lcts_err_nomem
    mov r14, rax
    mov [rsp + 104], rax
    mov rdi, r14
    mov esi, O_WRONLY | O_CREAT | O_TRUNC
    mov edx, 0x180                  # 0600
    call os_open
    test rax, rax
    js .Lcts_open_fail
    mov r15d, eax
    mov edi, r15d
    mov rsi, [rsp + 32 + SB_ptr]
    mov rdx, [rsp + 32 + SB_len]
    call write_all
    mov [rsp + 96], rax
    mov edi, r15d
    call os_close
    cmp qword ptr [rsp + 96], 0
    jne .Lcts_write_fail
    mov rdi, r14
    mov rsi, r13
    call os_rename
    test rax, rax
    jz .Lcts_cleanup
    mov [rsp + 96], rax
    jmp .Lcts_write_fail
.Lcts_open_fail:
    mov [rsp + 96], rax
.Lcts_write_fail:
    mov rdi, [rsp + 104]
    call os_unlink
    jmp .Lcts_cleanup
.Lcts_err_nomem:
    mov qword ptr [rsp + 96], -ENOMEM
.Lcts_cleanup:
    lea rdi, [rsp]
    call sb_free
    lea rdi, [rsp + 32]
    call sb_free
    mov rdi, r13
    call mem_free
    mov rdi, [rsp + 104]
    call mem_free
    mov rax, [rsp + 96]
    EPILOGUE
.Lcts_err_noent:
    mov rax, -ENOENT
    EPILOGUE

# ---------------------------------------------------------------------------
# cfg_mkdirs(path cstr) -> 0.  Best-effort mkdir -p: every '/'-terminated
# prefix is created 0755 and the full path 0700 (the opcode config dir can hold
# api_keys). EEXIST is ignored. A relative path works too.
cfg_mkdirs:
    PROLOGUE 512
    mov rbx, rdi
    xor ecx, ecx
.Lmk_copy:
    mov al, [rbx + rcx]
    mov [rsp + rcx], al
    test al, al
    jz .Lmk_copied
    inc ecx
    jmp .Lmk_copy
.Lmk_copied:
    mov r13d, 1
.Lmk_loop:
    movzx eax, byte ptr [rsp + r13]
    test al, al
    jz .Lmk_final
    cmp al, '/'
    jne .Lmk_next
    mov byte ptr [rsp + r13], 0
    mov rdi, rsp
    mov esi, 0755
    call os_mkdir
    mov byte ptr [rsp + r13], '/'
.Lmk_next:
    inc r13
    jmp .Lmk_loop
.Lmk_final:
    mov rdi, rsp
    mov esi, 0700
    call os_mkdir
    xor eax, eax
    EPILOGUE

# cfg_jv_streq(jv, cstr) -> 1|0.  Leaf; 0 for a non-string jv.
cfg_jv_streq:
    xor eax, eax
    test rdi, rdi
    jz .Ljvs_out
    cmp dword ptr [rdi + JV_type], JT_STR
    jne .Ljvs_out
    mov r8, [rdi + JV_ptr]
    mov r9d, [rdi + JV_n]
    xor ecx, ecx
.Ljvs_loop:
    cmp ecx, r9d
    jae .Ljvs_end
    mov dl, [r8 + rcx]
    cmp dl, [rsi + rcx]
    jne .Ljvs_no
    inc ecx
    jmp .Ljvs_loop
.Ljvs_end:
    cmp byte ptr [rsi + rcx], 0
    jne .Ljvs_no
    mov eax, 1
.Ljvs_out:
    ret
.Ljvs_no:
    xor eax, eax
    ret

# cfg_emit_jv(sb, jv): re-serialize one parsed JSON value verbatim (numbers keep
# their raw text; object keys are emitted from the parsed key strings).
FN cfg_emit_jv
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    test r12, r12
    jz .Lej_null
    mov eax, [r12 + JV_type]
    cmp eax, JT_OBJ
    je .Lej_obj
    cmp eax, JT_ARR
    je .Lej_arr
    cmp eax, JT_STR
    je .Lej_str
    cmp eax, JT_NUM
    je .Lej_num
    cmp eax, JT_TRUE
    je .Lej_true
    cmp eax, JT_FALSE
    je .Lej_false
.Lej_null:
    mov rdi, rbx
    call jsonw_null
    EPILOGUE
.Lej_true:
    mov rdi, rbx
    mov esi, 1
    call jsonw_bool
    EPILOGUE
.Lej_false:
    mov rdi, rbx
    xor esi, esi
    call jsonw_bool
    EPILOGUE
.Lej_str:
    mov rdi, rbx
    mov rsi, [r12 + JV_ptr]
    mov edx, [r12 + JV_n]
    call jsonw_str
    EPILOGUE
.Lej_num:
    mov rdi, rbx
    mov rsi, [r12 + JV_ptr]
    mov edx, [r12 + JV_n]
    call jsonw_raw
    EPILOGUE
.Lej_arr:
    mov rdi, rbx
    call jsonw_arr
    mov r15d, [r12 + JV_n]
    mov r14, [r12 + JV_ptr]
    xor r13d, r13d
.Lej_arr_loop:
    cmp r13d, r15d
    jae .Lej_arr_end
    mov rdi, rbx
    mov rsi, [r14 + r13*8]
    call cfg_emit_jv
    inc r13
    jmp .Lej_arr_loop
.Lej_arr_end:
    mov rdi, rbx
    call jsonw_arr_end
    EPILOGUE
.Lej_obj:
    mov rdi, rbx
    call jsonw_obj
    mov r15d, [r12 + JV_n]
    mov r14, [r12 + JV_ptr]
    xor r13d, r13d
.Lej_obj_loop:
    cmp r13d, r15d
    jae .Lej_obj_end
    mov rax, r13
    shl rax, 4
    mov rdi, [r14 + rax]
    mov rsi, [rdi + JV_ptr]
    mov edx, [rdi + JV_n]
    mov rdi, rbx
    call jsonw_key_n
    mov rax, r13
    shl rax, 4
    mov rsi, [r14 + rax + 8]
    mov rdi, rbx
    call cfg_emit_jv
    inc r13
    jmp .Lej_obj_loop
.Lej_obj_end:
    mov rdi, rbx
    call jsonw_obj_end
    EPILOGUE

# cfg_emit_provider_entry(sb, jv|0, base_url|0): emit a providers.<p> object,
# overriding base_url in place (dropping duplicates) and keeping every other key.
FN cfg_emit_provider_entry
    PROLOGUE 32
    mov [rsp], rdx
    mov dword ptr [rsp + 8], 0
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rbx
    call jsonw_obj
    test r12, r12
    jz .Lepe_tail
    cmp dword ptr [r12 + JV_type], JT_OBJ
    jne .Lepe_tail
    mov r15d, [r12 + JV_n]
    mov r14, [r12 + JV_ptr]
    xor r13d, r13d
.Lepe_loop:
    cmp r13d, r15d
    jae .Lepe_tail
    mov rax, r13
    shl rax, 4
    mov rdi, [r14 + rax]
    cmp qword ptr [rsp], 0
    je .Lepe_copy
    lea rsi, [rip + .Lkey_base]
    call cfg_jv_streq
    test eax, eax
    jz .Lepe_copy
    cmp dword ptr [rsp + 8], 0
    jne .Lepe_next
    mov dword ptr [rsp + 8], 1
    mov rdi, rbx
    lea rsi, [rip + .Lkey_base]
    call jsonw_key
    mov rdi, rbx
    mov rsi, [rsp]
    call jsonw_str_cstr
    jmp .Lepe_next
.Lepe_copy:
    mov rax, r13
    shl rax, 4
    mov rdi, [r14 + rax]
    mov rsi, [rdi + JV_ptr]
    mov edx, [rdi + JV_n]
    mov rdi, rbx
    call jsonw_key_n
    mov rax, r13
    shl rax, 4
    mov rsi, [r14 + rax + 8]
    mov rdi, rbx
    call cfg_emit_jv
.Lepe_next:
    inc r13
    jmp .Lepe_loop
.Lepe_tail:
    cmp qword ptr [rsp], 0
    je .Lepe_end
    cmp dword ptr [rsp + 8], 0
    jne .Lepe_end
    mov rdi, rbx
    lea rsi, [rip + .Lkey_base]
    call jsonw_key
    mov rdi, rbx
    mov rsi, [rsp]
    call jsonw_str_cstr
.Lepe_end:
    mov rdi, rbx
    call jsonw_obj_end
    EPILOGUE

# cfg_emit_providers(sb, jv|0, provider, base_url|0): merge the providers object,
# keeping all other providers and replacing/adding ours.
FN cfg_emit_providers
    PROLOGUE 32
    mov [rsp], rdx
    mov [rsp + 8], rcx
    mov dword ptr [rsp + 16], 0
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rbx
    call jsonw_obj
    test r12, r12
    jz .Lepv_tail
    cmp dword ptr [r12 + JV_type], JT_OBJ
    jne .Lepv_tail
    mov r15d, [r12 + JV_n]
    mov r14, [r12 + JV_ptr]
    xor r13d, r13d
.Lepv_loop:
    cmp r13d, r15d
    jae .Lepv_tail
    mov rax, r13
    shl rax, 4
    mov rdi, [r14 + rax]
    mov rsi, [rsp]
    call cfg_jv_streq
    test eax, eax
    jz .Lepv_other
    cmp dword ptr [rsp + 16], 0
    jne .Lepv_next
    mov dword ptr [rsp + 16], 1
    mov rax, r13
    shl rax, 4
    mov rdi, [r14 + rax]
    mov rsi, [rdi + JV_ptr]
    mov edx, [rdi + JV_n]
    mov rdi, rbx
    call jsonw_key_n
    mov rax, r13
    shl rax, 4
    mov rsi, [r14 + rax + 8]
    mov rdi, rbx
    mov rdx, [rsp + 8]
    call cfg_emit_provider_entry
    jmp .Lepv_next
.Lepv_other:
    mov rax, r13
    shl rax, 4
    mov rdi, [r14 + rax]
    mov rsi, [rdi + JV_ptr]
    mov edx, [rdi + JV_n]
    mov rdi, rbx
    call jsonw_key_n
    mov rax, r13
    shl rax, 4
    mov rsi, [r14 + rax + 8]
    mov rdi, rbx
    call cfg_emit_jv
.Lepv_next:
    inc r13
    jmp .Lepv_loop
.Lepv_tail:
    cmp dword ptr [rsp + 16], 0
    jne .Lepv_end
    mov rdi, rbx
    mov rsi, [rsp]
    call jsonw_key
    mov rdi, rbx
    xor esi, esi
    mov rdx, [rsp + 8]
    call cfg_emit_provider_entry
.Lepv_end:
    mov rdi, rbx
    call jsonw_obj_end
    EPILOGUE

# cfg_emit_root(sb, root|0, provider, model, base_url|0): re-emit the config
# object with default_provider/default_model/providers.<p> overridden; every
# other key (and every other provider key) is preserved verbatim.
FN cfg_emit_root
    PROLOGUE 48
    mov [rsp], rdx
    mov [rsp + 8], rcx
    mov [rsp + 16], r8
    mov dword ptr [rsp + 24], 0
    mov dword ptr [rsp + 28], 0
    mov dword ptr [rsp + 32], 0
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rbx
    call jsonw_obj
    test r12, r12
    jz .Ler_tail
    cmp dword ptr [r12 + JV_type], JT_OBJ
    jne .Ler_tail
    mov r15d, [r12 + JV_n]
    mov r14, [r12 + JV_ptr]
    xor r13d, r13d
.Ler_loop:
    cmp r13d, r15d
    jae .Ler_tail
    mov rax, r13
    shl rax, 4
    mov rdi, [r14 + rax]
    lea rsi, [rip + .Lkey_dp]
    call cfg_jv_streq
    test eax, eax
    jnz .Ler_dp
    mov rax, r13
    shl rax, 4
    mov rdi, [r14 + rax]
    lea rsi, [rip + .Lkey_dm]
    call cfg_jv_streq
    test eax, eax
    jnz .Ler_dm
    mov rax, r13
    shl rax, 4
    mov rdi, [r14 + rax]
    lea rsi, [rip + .Lkey_pv]
    call cfg_jv_streq
    test eax, eax
    jnz .Ler_pv
    mov rax, r13
    shl rax, 4
    mov rdi, [r14 + rax]
    mov rsi, [rdi + JV_ptr]
    mov edx, [rdi + JV_n]
    mov rdi, rbx
    call jsonw_key_n
    mov rax, r13
    shl rax, 4
    mov rsi, [r14 + rax + 8]
    mov rdi, rbx
    call cfg_emit_jv
    jmp .Ler_next
.Ler_dp:
    cmp dword ptr [rsp + 24], 0
    jne .Ler_next
    mov dword ptr [rsp + 24], 1
    mov rdi, rbx
    lea rsi, [rip + .Lkey_dp]
    call jsonw_key
    mov rdi, rbx
    mov rsi, [rsp]
    call jsonw_str_cstr
    jmp .Ler_next
.Ler_dm:
    cmp dword ptr [rsp + 28], 0
    jne .Ler_next
    mov dword ptr [rsp + 28], 1
    mov rdi, rbx
    lea rsi, [rip + .Lkey_dm]
    call jsonw_key
    mov rdi, rbx
    mov rsi, [rsp + 8]
    call jsonw_str_cstr
    jmp .Ler_next
.Ler_pv:
    cmp dword ptr [rsp + 32], 0
    jne .Ler_next
    mov dword ptr [rsp + 32], 1
    mov rdi, rbx
    lea rsi, [rip + .Lkey_pv]
    call jsonw_key
    mov rax, r13
    shl rax, 4
    mov rsi, [r14 + rax + 8]
    mov rdi, rbx
    mov rdx, [rsp]
    mov rcx, [rsp + 16]
    call cfg_emit_providers
.Ler_next:
    inc r13
    jmp .Ler_loop
.Ler_tail:
    cmp dword ptr [rsp + 24], 0
    jne .Ler_saw_dp
    mov rdi, rbx
    lea rsi, [rip + .Lkey_dp]
    call jsonw_key
    mov rdi, rbx
    mov rsi, [rsp]
    call jsonw_str_cstr
.Ler_saw_dp:
    cmp dword ptr [rsp + 28], 0
    jne .Ler_saw_dm
    mov rdi, rbx
    lea rsi, [rip + .Lkey_dm]
    call jsonw_key
    mov rdi, rbx
    mov rsi, [rsp + 8]
    call jsonw_str_cstr
.Ler_saw_dm:
    cmp dword ptr [rsp + 32], 0
    jne .Ler_end
    mov rdi, rbx
    lea rsi, [rip + .Lkey_pv]
    call jsonw_key
    mov rdi, rbx
    call jsonw_obj
    mov rdi, rbx
    mov rsi, [rsp]
    call jsonw_key
    mov rdi, rbx
    xor esi, esi
    mov rdx, [rsp + 16]
    call cfg_emit_provider_entry
    mov rdi, rbx
    call jsonw_obj_end
.Ler_end:
    mov rdi, rbx
    call jsonw_obj_end
    EPILOGUE

# ---------------------------------------------------------------------------
# config_save(provider cstr, model cstr, base_url cstr|0) -> 0 | -errno.
# Merges default_provider/default_model and providers.<provider>.base_url into
# <config dir>/config.jsonc, keeping every existing key.  Atomic: writes
# <config.jsonc>.tmp (0600) and renames it over the original.
FN config_save
    PROLOGUE 176
    mov qword ptr [rsp + 72], 0      # result
    mov qword ptr [rsp + 64], 0      # tmp path
    mov qword ptr [rsp + 80], 0      # config path
    mov qword ptr [rsp + 88], 0      # parsed root
    mov dword ptr [rsp + 112], -1    # tmp fd
    mov qword ptr [rsp + 120], 0     # (unused pad)
    mov qword ptr [rsp + 0], 0       # out SB
    mov qword ptr [rsp + 8], 0
    mov qword ptr [rsp + 16], 0
    mov qword ptr [rsp + 32], 0      # in SB
    mov qword ptr [rsp + 40], 0
    mov qword ptr [rsp + 48], 0
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    test rbx, rbx
    jz .Lcsave_einval
    test r12, r12
    jz .Lcsave_einval
    call config_user_dir
    test rax, rax
    jz .Lcsave_noent
    mov r14, rax
    mov rdi, r14
    call cfg_mkdirs
    mov rdi, r14
    lea rsi, [rip + .Lconfig_name]
    call config_path_join
    test rax, rax
    jz .Lcsave_nomem
    mov [rsp + 80], rax
    mov rdi, rax
    lea rsi, [rsp + 32]
    call config_read_file
    test eax, eax
    jz .Lcsave_emit
    mov rdi, [rsp + 32 + SB_ptr]
    mov rsi, [rsp + 32 + SB_len]
    call json_parse
    mov [rsp + 88], rax
.Lcsave_emit:
    lea rdi, [rsp]
    mov rsi, [rsp + 88]
    mov rdx, rbx
    mov rcx, r12
    mov r8, r13
    call cfg_emit_root
    mov rdi, [rsp + 80]
    lea rsi, [rip + .Ltmp_suffix]
    call config_path_join
    test rax, rax
    jz .Lcsave_nomem
    mov [rsp + 64], rax
    mov rdi, rax
    mov esi, O_WRONLY | O_CREAT | O_TRUNC
    mov edx, 0600
    call os_open
    test rax, rax
    js .Lcsave_openfail
    mov [rsp + 112], eax
    mov edi, eax
    mov esi, 0600
    call os_fchmod                 # force 0600 on a pre-existing .tmp too
    mov edi, [rsp + 112]
    mov rsi, [rsp + SB_ptr]
    mov rdx, [rsp + SB_len]
    call write_all
    mov [rsp + 72], rax
    test rax, rax
    jnz .Lcsave_writefail
    mov edi, [rsp + 112]
    call os_fsync
    mov edi, [rsp + 112]
    call os_close
    mov dword ptr [rsp + 112], -1
    mov rdi, [rsp + 64]
    mov rsi, [rsp + 80]
    call os_rename
    test rax, rax
    jz .Lcsave_cleanup
    mov [rsp + 72], rax
    jmp .Lcsave_unlink
.Lcsave_openfail:
    mov [rsp + 72], rax
    jmp .Lcsave_cleanup
.Lcsave_writefail:
    mov edi, [rsp + 112]
    call os_close
    mov dword ptr [rsp + 112], -1
.Lcsave_unlink:
    mov rdi, [rsp + 64]
    call os_unlink
.Lcsave_cleanup:
    lea rdi, [rsp]
    call sb_free
    lea rdi, [rsp + 32]
    call sb_free
    mov rdi, [rsp + 80]
    call mem_free
    mov rdi, [rsp + 64]
    call mem_free
    mov rax, [rsp + 72]
    EPILOGUE
.Lcsave_einval:
    mov rax, -EINVAL
    EPILOGUE
.Lcsave_noent:
    mov rax, -ENOENT
    EPILOGUE
.Lcsave_nomem:
    mov qword ptr [rsp + 72], -ENOMEM
    jmp .Lcsave_cleanup

# config_provider_at(i) -> mem_alloc'd cstr | 0.  i-th key of the effective
# "providers" object (project first, then user), for `opcode models --refresh`.
FN config_provider_at
    PROLOGUE 64
    mov r12d, edi
    mov rdi, [rip + cfg_proj]
    test rdi, rdi
    jz .Lcpa_user
    mov rsi, [rip + cfg_proj_len]
    call json_parse
    test rax, rax
    jz .Lcpa_user
    mov rdi, rax
    lea rsi, [rip + .Lkey_pv]
    call json_get
    test rax, rax
    jz .Lcpa_user
    cmp dword ptr [rax + JV_type], JT_OBJ
    jne .Lcpa_user
    mov r13, rax
    cmp r12d, [r13 + JV_n]
    jae .Lcpa_user
    mov rax, [r13 + JV_ptr]
    mov rcx, r12
    shl rcx, 4
    mov rdi, [rax + rcx]
    mov rsi, [rdi + JV_ptr]
    mov edx, [rdi + JV_n]
    mov rdi, rsi
    mov rsi, rdx
    call mem_dup
    EPILOGUE
.Lcpa_user:
    mov rdi, [rip + cfg_user]
    test rdi, rdi
    jz .Lcpa_none
    mov rsi, [rip + cfg_user_len]
    call json_parse
    test rax, rax
    jz .Lcpa_none
    mov rdi, rax
    lea rsi, [rip + .Lkey_pv]
    call json_get
    test rax, rax
    jz .Lcpa_none
    cmp dword ptr [rax + JV_type], JT_OBJ
    jne .Lcpa_none
    mov r13, rax
    cmp r12d, [r13 + JV_n]
    jae .Lcpa_none
    mov rax, [r13 + JV_ptr]
    mov rcx, r12
    shl rcx, 4
    mov rdi, [rax + rcx]
    mov rsi, [rdi + JV_ptr]
    mov edx, [rdi + JV_n]
    mov rdi, rsi
    mov rsi, rdx
    call mem_dup
    EPILOGUE
.Lcpa_none:
    xor eax, eax
    EPILOGUE

# ---------------------------------------------------------------------------
# warn_invalid(path cstr): "opcode: warning: invalid config <path>\n" (stderr)
warn_invalid:
    PROLOGUE 0
    mov rbx, rdi
    lea rdi, [rip + .Lwarn_prefix]
    call log_cstr
    mov rdi, rbx
    call log_cstr
    call log_nl
    EPILOGUE

# config_load() -> 0.  Reads the user config, then the project config when
# config_trusted(cwd) is set.  Missing files are not errors; malformed JSONC
# warns and is ignored.
FN config_load
    PROLOGUE 560
    # ---- user config ----
    mov rdi, [rip + cfg_user]
    call mem_free
    mov qword ptr [rip + cfg_user], 0
    mov qword ptr [rip + cfg_user_len], 0
    call config_user_dir
    test rax, rax
    jz .Lcl_proj
    mov rdi, rax
    lea rsi, [rip + .Lconfig_name]
    call config_path_join
    test rax, rax
    jz .Lcl_proj
    mov rbx, rax
    xor eax, eax
    mov [rsp], rax
    mov [rsp + 8], rax
    mov [rsp + 16], rax
    mov rdi, rbx
    lea rsi, [rsp]
    call config_read_file
    test eax, eax
    jz .Lcl_user_free
    mov rdi, [rsp + SB_ptr]
    mov rsi, [rsp + SB_len]
    call json_parse
    test rax, rax
    jz .Lcl_user_warn
    mov rdi, [rsp + SB_ptr]
    mov rsi, [rsp + SB_len]
    call mem_dup
    mov [rip + cfg_user], rax
    mov rax, [rsp + SB_len]
    mov [rip + cfg_user_len], rax
    jmp .Lcl_user_free
.Lcl_user_warn:
    mov rdi, rbx
    call warn_invalid
.Lcl_user_free:
    lea rdi, [rsp]
    call sb_free
    mov rdi, rbx
    call mem_free
.Lcl_proj:
    # ---- project config (only when trusted) ----
    mov rdi, [rip + cfg_proj]
    call mem_free
    mov qword ptr [rip + cfg_proj], 0
    mov qword ptr [rip + cfg_proj_len], 0
    lea rdi, [rsp + 32]
    mov esi, 512
    call os_getcwd
    test rax, rax
    js .Lcl_done
    lea rdi, [rsp + 32]
    call config_trusted
    test eax, eax
    jz .Lcl_done
    lea rdi, [rsp + 32]
    lea rsi, [rip + .Lproj_name]
    call config_path_join
    test rax, rax
    jz .Lcl_done
    mov rbx, rax
    xor eax, eax
    mov [rsp], rax
    mov [rsp + 8], rax
    mov [rsp + 16], rax
    mov rdi, rbx
    lea rsi, [rsp]
    call config_read_file
    test eax, eax
    jz .Lcl_proj_free
    mov rdi, [rsp + SB_ptr]
    mov rsi, [rsp + SB_len]
    call json_parse
    test rax, rax
    jz .Lcl_proj_warn
    mov rdi, [rsp + SB_ptr]
    mov rsi, [rsp + SB_len]
    call mem_dup
    mov [rip + cfg_proj], rax
    mov rax, [rsp + SB_len]
    mov [rip + cfg_proj_len], rax
    jmp .Lcl_proj_free
.Lcl_proj_warn:
    mov rdi, rbx
    call warn_invalid
.Lcl_proj_free:
    lea rdi, [rsp]
    call sb_free
    mov rdi, rbx
    call mem_free
.Lcl_done:
    xor eax, eax
    EPILOGUE
