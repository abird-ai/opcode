.include "opcode.inc"
.include "core/core.inc"
# session.s: JSONL session persistence (M3). Contract: src/core/API.md.
#
# Session struct (private; layout is not part of the frozen API):
#   +0   fd          i64   -1 when closed
#   +8   path        cstr  owned, full path of the .jsonl file
#   +16  id          cstr  owned, 8-hex session id
#   +24  last_id     cstr  owned, id of the last message entry (parent chain)
#   +32  cwd         cstr  owned, may be an empty string
#   +40  provider    cstr  owned, last model_change seen/loaded
#   +48  model       cstr  owned, last model_change seen/loaded
#   +56  enabled     u32
#   =64 bytes.
#
# One JSON object per line; all keys snake_case, tagged by "type". The header
# is {"type":"session","schema_version":1,...}; message lines are
# {"type":"message","id":...,"parent_id":...,"message":{...}}. model_change
# and custom entries do not participate in the parent chain. On load a
# missing schema_version is the legacy 1; a value greater than SESSION_SCHEMA
# refuses the load with the version pair (no migration hook exists yet).
#
# Platform notes: durability and directory reads go through the Layer 0
# wrappers os_fsync (plat/linux/fs.s) and os_getdents (plat/linux/dir.s).
# config_session_dir is referenced weakly so session.s links before config.s
# lands (the weak address is 0 when undefined).

.weak config_session_dir

.equ S_fd, 0
.equ S_path, 8
.equ S_id, 16
.equ S_last_id, 24
.equ S_cwd, 32
.equ S_provider, 40
.equ S_model, 48
.equ S_enabled, 56
.equ S_SIZE, 64

# The session header schema this build writes and accepts. A newer value
# refuses the load; a missing value is the legacy 1 (see .Lschema_check).
.equ SESSION_SCHEMA, 1

.section .rodata
.Lempty:        .asciz ""
.Lempty_obj:    .asciz "{}"
.Lerr_schema_new:  .asciz "opcode: session schema "
.Lerr_schema_mid:  .asciz " is newer than supported schema "
.Lerr_schema_tail: .asciz "; the file was written by a newer opcode"
.Lerr_schema_num:  .asciz "opcode: session schema_version must be a number"
.Ljsonl:        .asciz ".jsonl"
.Lhex:          .asciz "0123456789abcdef"

.Lenv_session_dir: .asciz "OPCODE_SESSION_DIR"
.Lenv_xdg:         .asciz "XDG_DATA_HOME"
.Lenv_home:        .asciz "HOME"
.Lsub_local:       .asciz "/.local/share"
.Lsub_opcode:      .asciz "/opcode/sessions/--"
.Lsub_dashes:      .asciz "--"

# keys
.Lk_type:        .asciz "type"
.Lk_schema:      .asciz "schema_version"
.Lk_id:          .asciz "id"
.Lk_parent_id:   .asciz "parent_id"
.Lk_message:     .asciz "message"
.Lk_role:        .asciz "role"
.Lk_timestamp:   .asciz "timestamp"
.Lk_cwd:         .asciz "cwd"
.Lk_content:     .asciz "content"
.Lk_stop:        .asciz "stop_reason"
.Lk_usage:       .asciz "usage"
.Lk_tool_call_id:.asciz "tool_call_id"
.Lk_is_error:    .asciz "is_error"
.Lk_input_tokens:.asciz "input_tokens"
.Lk_output_tokens:.asciz "output_tokens"
.Lk_cache_read:  .asciz "cache_read"
.Lk_cache_write: .asciz "cache_write"
.Lk_total_tokens:.asciz "total_tokens"
.Lk_provider:    .asciz "provider"
.Lk_model:       .asciz "model"
.Lk_custom_type: .asciz "custom_type"
.Lk_data:        .asciz "data"
.Lk_first_kept:  .asciz "first_kept"
.Lk_text:        .asciz "text"
.Lk_thinking:    .asciz "thinking"
.Lk_tool_use:    .asciz "tool_use"
.Lk_name:        .asciz "name"
.Lk_input:       .asciz "input"

# values
.Lv_session:      .asciz "session"
.Lv_message:      .asciz "message"
.Lv_model_change: .asciz "model_change"
.Lv_custom:       .asciz "custom"
.Lv_compaction:   .asciz "compaction"
.Lv_user:         .asciz "user"
.Lv_assistant:    .asciz "assistant"
.Lv_system:       .asciz "system"
.Lv_tool_result:  .asciz "tool_result"
.Lv_text:         .asciz "text"
.Lv_thinking:     .asciz "thinking"
.Lv_tool_use:     .asciz "tool_use"
.Lv_stop:         .asciz "stop"
.Lv_length:       .asciz "length"
.Lv_error:        .asciz "error"
.Lv_aborted:      .asciz "aborted"
.Lv_pending:      .asciz "pending"

.text

# ---------------------------------------------------------------- small helpers
# .Lenv_get(name cstr) -> value cstr | 0
.Lenv_get:
    PROLOGUE
    mov rbx, rdi
    call strlen
    mov r12, rax
    mov r13, [rip + g_envp]
    test r13, r13
    jz .Leg_none
.Leg_loop:
    mov r14, [r13]
    test r14, r14
    jz .Leg_none
    mov rdi, r14
    mov rsi, rbx
    mov rdx, r12
    call memeq
    test eax, eax
    jz .Leg_next
    cmp byte ptr [r14 + r12], '='
    jne .Leg_next
    lea rax, [r14 + r12 + 1]
    EPILOGUE
.Leg_next:
    add r13, 8
    jmp .Leg_loop
.Leg_none:
    xor eax, eax
    EPILOGUE

# .Ldup_cstr(cstr|0) -> mem_dup copy | 0
.Ldup_cstr:
    PROLOGUE
    test rdi, rdi
    jz .Ldc_zero
    mov rbx, rdi
    call strlen
    mov rsi, rax
    mov rdi, rbx
    call mem_dup
    EPILOGUE
.Ldc_zero:
    xor eax, eax
    EPILOGUE

# .Lreplace_str(field_addr, cstr|0): free *field_addr, store a fresh copy
.Lreplace_str:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, [rbx]
    call mem_free
    mov rdi, r12
    call .Ldup_cstr
    mov [rbx], rax
    EPILOGUE

# .Lcstr_eq(a cstr, b cstr) -> 1|0
.Lcstr_eq:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rsi
    call strlen
    mov rdi, rbx
    mov rsi, rax
    mov rdx, r12
    call str_eq_cstr
    EPILOGUE

# .Lrand_id8(out): 8 lowercase hex digits + NUL from os_random
.Lrand_id8:
    PROLOGUE 16
    mov rbx, rdi
    mov rdi, rsp
    mov esi, 4
    call os_random
    test rax, rax
    jns .Lri_go
    mov dword ptr [rsp], 0
.Lri_go:
    lea rsi, [rip + .Lhex]
    xor ecx, ecx
.Lri_loop:
    movzx eax, byte ptr [rsp + rcx]
    mov edx, eax
    shr edx, 4
    and eax, 15
    movzx edx, byte ptr [rsi + rdx]
    mov [rbx + rcx*2], dl
    movzx eax, byte ptr [rsi + rax]
    mov [rbx + rcx*2 + 1], al
    inc ecx
    cmp ecx, 4
    jb .Lri_loop
    mov byte ptr [rbx + 8], 0
    EPILOGUE

# .Lunix_ms() -> unix milliseconds (CLOCK_REALTIME)
.Lunix_ms:
    PROLOGUE
    xor edi, edi
    call os_now_ns
    xor edx, edx
    mov ecx, 1000000
    div rcx
    EPILOGUE

# .Lpath_join(dir cstr, name cstr) -> mem_alloc'd "dir/name"
.Lpath_join:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rbx
    call strlen
    mov r13, rax
    mov rdi, r12
    call strlen
    mov r14, rax
    lea rdi, [r13 + r14 + 2]
    call mem_alloc
    mov r15, rax
    mov rdi, rax
    mov rsi, rbx
    mov rdx, r13
    call memcpy
    mov byte ptr [r15 + r13], '/'
    lea rdi, [r15 + r13 + 1]
    mov rsi, r12
    mov rdx, r14
    call memcpy
    lea rax, [r13 + r14 + 1]
    mov byte ptr [r15 + rax], 0
    mov rax, r15
    EPILOGUE

# .Lsb_push_san(sb, cstr|0): append with '/' and '\' replaced by '-'
.Lsb_push_san:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    test r12, r12
    jz .Lsp_done
    xor r13d, r13d
.Lsp_loop:
    movzx eax, byte ptr [r12 + r13]
    test al, al
    jz .Lsp_done
    cmp al, '/'
    je .Lsp_dash
    cmp al, 92
    jne .Lsp_put
.Lsp_dash:
    mov al, '-'
.Lsp_put:
    mov rdi, rbx
    mov esi, eax
    call sb_push_byte
    inc r13
    jmp .Lsp_loop
.Lsp_done:
    EPILOGUE

# .Lgetcwd() -> mem_alloc'd cwd | 0
.Lgetcwd:
    PROLOGUE 4096
    mov rdi, rsp
    mov esi, 4096
    call os_getcwd
    test rax, rax
    js .Lgc_none
    mov rdi, rsp
    call .Ldup_cstr
    EPILOGUE
.Lgc_none:
    xor eax, eax
    EPILOGUE

# .Lbuild_xdg(cwd cstr|0) -> mem_alloc'd session dir per XDG | 0
.Lbuild_xdg:
    PROLOGUE 32
    mov r12, rdi
    mov qword ptr [rsp + SB_ptr], 0
    mov qword ptr [rsp + SB_len], 0
    mov qword ptr [rsp + SB_cap], 0
    lea rdi, [rip + .Lenv_xdg]
    call .Lenv_get
    test rax, rax
    jz .Lbx_home
    cmp byte ptr [rax], 0
    je .Lbx_home
    lea rdi, [rsp]
    mov rsi, rax
    call sb_push_cstr
    jmp .Lbx_suffix
.Lbx_home:
    lea rdi, [rip + .Lenv_home]
    call .Lenv_get
    test rax, rax
    jz .Lbx_none
    cmp byte ptr [rax], 0
    je .Lbx_none
    lea rdi, [rsp]
    mov rsi, rax
    call sb_push_cstr
    lea rdi, [rsp]
    lea rsi, [rip + .Lsub_local]
    call sb_push_cstr
.Lbx_suffix:
    lea rdi, [rsp]
    lea rsi, [rip + .Lsub_opcode]
    call sb_push_cstr
    lea rdi, [rsp]
    mov rsi, r12
    call .Lsb_push_san
    lea rdi, [rsp]
    lea rsi, [rip + .Lsub_dashes]
    call sb_push_cstr
    mov rdi, [rsp + SB_ptr]
    mov rsi, [rsp + SB_len]
    call mem_dup
    mov rbx, rax
    lea rdi, [rsp]
    call sb_free
    mov rax, rbx
    EPILOGUE
.Lbx_none:
    lea rdi, [rsp]
    call sb_free
    xor eax, eax
    EPILOGUE

# .Lresolve_dir(dir cstr|0, cwd cstr|0) -> mem_alloc'd dir | 0 (does not create)
.Lresolve_dir:
    PROLOGUE 16
    mov r12, rsi
    xor r15d, r15d
    test rdi, rdi
    jnz .Lrd_dup
    lea rdi, [rip + .Lenv_session_dir]
    call .Lenv_get
    test rax, rax
    jz .Lrd_cfg
    cmp byte ptr [rax], 0
    je .Lrd_cfg
    mov rdi, rax
    call .Ldup_cstr
    EPILOGUE
.Lrd_dup:
    call .Ldup_cstr
    EPILOGUE
.Lrd_cfg:
    lea rax, [rip + config_session_dir]
    test rax, rax
    jz .Lrd_xdg
    call rax
    test rax, rax
    jz .Lrd_xdg
    EPILOGUE
.Lrd_xdg:
    test r12, r12
    jnz .Lrd_build
    call .Lgetcwd
    test rax, rax
    jz .Lrd_build
    mov r12, rax
    mov r15, rax
.Lrd_build:
    mov rdi, r12
    call .Lbuild_xdg
    mov rbx, rax
    mov rdi, r15
    call mem_free
    mov rax, rbx
    EPILOGUE

# .Lmkdirs(path): recursively mkdir each component; existing dirs are fine
.Lmkdirs:
    PROLOGUE
    test rdi, rdi
    jz .Lmd_ret
    call .Ldup_cstr
    test rax, rax
    jz .Lmd_ret
    mov rbx, rax
    mov rdi, rbx
    call strlen
    mov r13, rax
    xor r12d, r12d
.Lmd_loop:
    cmp r12, r13
    jae .Lmd_final
    cmp byte ptr [rbx + r12], '/'
    jne .Lmd_next
    test r12, r12
    jz .Lmd_next
    cmp r12, 1
    jne .Lmd_do
    cmp byte ptr [rbx], '/'
    je .Lmd_next
.Lmd_do:
    mov byte ptr [rbx + r12], 0
    mov rdi, rbx
    mov esi, 0x1ED
    call os_mkdir
    mov byte ptr [rbx + r12], '/'
.Lmd_next:
    inc r12
    jmp .Lmd_loop
.Lmd_final:
    mov rdi, rbx
    mov esi, 0x1ED
    call os_mkdir
    mov rdi, rbx
    call mem_free
.Lmd_ret:
    xor eax, eax
    EPILOGUE

# .Lwrite_line(s, sb, fsync): newline-terminate, write, optionally fsync
.Lwrite_line:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    mov rdi, r12
    mov esi, 10
    call sb_push_byte
    mov edi, dword ptr [rbx + S_fd]
    mov rsi, [r12 + SB_ptr]
    mov rdx, [r12 + SB_len]
    call write_all
    test rax, rax
    js .Lwl_out
    test r13d, r13d
    jz .Lwl_out
    mov edi, dword ptr [rbx + S_fd]
    call os_fsync
.Lwl_out:
    EPILOGUE

# .Lkv_str(sb, key cstr, val cstr|0)
.Lkv_str:
    PROLOGUE
    mov rbx, rdi
    mov r12, rdx
    call jsonw_key
    test r12, r12
    jnz .Lkv_emit
    lea r12, [rip + .Lempty]
.Lkv_emit:
    mov rdi, rbx
    mov rsi, r12
    call jsonw_str_cstr
    EPILOGUE

# .Lstop_to_cstr(stop code) -> cstr
.Lstop_to_cstr:
    lea rax, [rip + .Lv_stop]
    cmp edi, SR_STOP
    je .Lstc_ret
    lea rax, [rip + .Lv_length]
    cmp edi, SR_LENGTH
    je .Lstc_ret
    lea rax, [rip + .Lv_tool_use]
    cmp edi, SR_TOOL_USE
    je .Lstc_ret
    lea rax, [rip + .Lv_error]
    cmp edi, SR_ERROR
    je .Lstc_ret
    lea rax, [rip + .Lv_aborted]
    cmp edi, SR_ABORTED
    je .Lstc_ret
    lea rax, [rip + .Lv_pending]
.Lstc_ret:
    ret

# .Lstop_from_cstr(cstr|0) -> stop code
.Lstop_from_cstr:
    PROLOGUE
    test rdi, rdi
    jz .Lsfc_pending
    mov rbx, rdi
    lea rsi, [rip + .Lv_stop]
    call .Lcstr_eq
    test eax, eax
    jnz .Lsfc_stop
    mov rdi, rbx
    lea rsi, [rip + .Lv_length]
    call .Lcstr_eq
    test eax, eax
    jnz .Lsfc_length
    mov rdi, rbx
    lea rsi, [rip + .Lv_tool_use]
    call .Lcstr_eq
    test eax, eax
    jnz .Lsfc_tool
    mov rdi, rbx
    lea rsi, [rip + .Lv_error]
    call .Lcstr_eq
    test eax, eax
    jnz .Lsfc_error
    mov rdi, rbx
    lea rsi, [rip + .Lv_aborted]
    call .Lcstr_eq
    test eax, eax
    jnz .Lsfc_aborted
.Lsfc_pending:
    mov eax, SR_PENDING
    EPILOGUE
.Lsfc_stop:
    mov eax, SR_STOP
    EPILOGUE
.Lsfc_length:
    mov eax, SR_LENGTH
    EPILOGUE
.Lsfc_tool:
    mov eax, SR_TOOL_USE
    EPILOGUE
.Lsfc_error:
    mov eax, SR_ERROR
    EPILOGUE
.Lsfc_aborted:
    mov eax, SR_ABORTED
    EPILOGUE

# .Ljv_to_sb(sb, JV*): serialize a parsed value back to compact JSON.
# Numbers are emitted raw; every other node goes through the jsonw writer.
.Ljv_to_sb:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    test r12, r12
    jz .Lje_null
    mov eax, [r12 + JV_type]
    cmp eax, JT_NULL
    je .Lje_null
    cmp eax, JT_TRUE
    je .Lje_true
    cmp eax, JT_FALSE
    je .Lje_false
    cmp eax, JT_NUM
    je .Lje_num
    cmp eax, JT_STR
    je .Lje_str
    cmp eax, JT_ARR
    je .Lje_arr
    cmp eax, JT_OBJ
    je .Lje_obj
.Lje_null:
    mov rdi, rbx
    call jsonw_null
    EPILOGUE
.Lje_true:
    mov rdi, rbx
    mov esi, 1
    call jsonw_bool
    EPILOGUE
.Lje_false:
    mov rdi, rbx
    xor esi, esi
    call jsonw_bool
    EPILOGUE
.Lje_num:
    mov rdi, rbx
    mov rsi, [r12 + JV_ptr]
    mov edx, dword ptr [r12 + JV_n]
    call jsonw_raw
    EPILOGUE
.Lje_str:
    mov rdi, rbx
    mov rsi, [r12 + JV_ptr]
    mov edx, dword ptr [r12 + JV_n]
    call jsonw_str
    EPILOGUE
.Lje_arr:
    mov rdi, rbx
    call jsonw_arr
    mov r13d, dword ptr [r12 + JV_n]
    xor r14d, r14d
.Lje_arr_loop:
    cmp r14, r13
    jae .Lje_arr_end
    mov rdi, r12
    mov esi, r14d
    call json_at
    mov r15, rax
    test r14, r14
    jz .Lje_arr_val
    test r15, r15
    jz .Lje_arr_val
    cmp dword ptr [r15 + JV_type], JT_NUM
    jne .Lje_arr_val
    mov rdi, rbx
    mov esi, 44
    call sb_push_byte
.Lje_arr_val:
    mov rdi, rbx
    mov rsi, r15
    call .Ljv_to_sb
    inc r14
    jmp .Lje_arr_loop
.Lje_arr_end:
    mov rdi, rbx
    call jsonw_arr_end
    EPILOGUE
.Lje_obj:
    mov rdi, rbx
    call jsonw_obj
    mov r13d, dword ptr [r12 + JV_n]
    xor r14d, r14d
.Lje_obj_loop:
    cmp r14, r13
    jae .Lje_obj_end
    mov rax, [r12 + JV_ptr]
    mov rcx, r14
    shl rcx, 4
    mov r15, [rax + rcx]
    mov rdi, rbx
    mov rsi, [r15 + JV_ptr]
    mov edx, dword ptr [r15 + JV_n]
    call jsonw_key_n
    mov rax, [r12 + JV_ptr]
    mov rcx, r14
    shl rcx, 4
    mov rsi, [rax + rcx + 8]
    mov rdi, rbx
    call .Ljv_to_sb
    inc r14
    jmp .Lje_obj_loop
.Lje_obj_end:
    mov rdi, rbx
    call jsonw_obj_end
    EPILOGUE

# .Lwrite_content(sb, Msg*): "content":[...] with text/thinking/tool_use blocks
.Lwrite_content:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rbx
    call jsonw_arr
    mov r13, [r12 + M_blocks]
    test r13, r13
    jz .Lwc_end
    mov r14, [r13 + VEC_ptr]
    mov rax, [r13 + VEC_len]
    imul rax, rax, B_SIZE
    lea r15, [r14 + rax]
.Lwc_loop:
    cmp r14, r15
    jae .Lwc_end
    mov eax, [r14 + B_type]
    cmp eax, BT_TEXT
    je .Lwc_text
    cmp eax, BT_THINK
    je .Lwc_think
    cmp eax, BT_TOOLCALL
    je .Lwc_tool
    jmp .Lwc_next
.Lwc_text:
    mov rdi, rbx
    call jsonw_obj
    mov rdi, rbx
    lea rsi, [rip + .Lk_type]
    call jsonw_key
    mov rdi, rbx
    lea rsi, [rip + .Lv_text]
    call jsonw_str_cstr
    mov rdi, rbx
    lea rsi, [rip + .Lk_text]
    call jsonw_key
    mov rdi, rbx
    mov rsi, [r14 + B_ptr]
    mov rdx, [r14 + B_len]
    call jsonw_str
    jmp .Lwc_endblk
.Lwc_think:
    mov rdi, rbx
    call jsonw_obj
    mov rdi, rbx
    lea rsi, [rip + .Lk_type]
    call jsonw_key
    mov rdi, rbx
    lea rsi, [rip + .Lv_thinking]
    call jsonw_str_cstr
    mov rdi, rbx
    lea rsi, [rip + .Lk_thinking]
    call jsonw_key
    mov rdi, rbx
    mov rsi, [r14 + B_ptr]
    mov rdx, [r14 + B_len]
    call jsonw_str
    jmp .Lwc_endblk
.Lwc_tool:
    mov rdi, rbx
    call jsonw_obj
    mov rdi, rbx
    lea rsi, [rip + .Lk_type]
    call jsonw_key
    mov rdi, rbx
    lea rsi, [rip + .Lv_tool_use]
    call jsonw_str_cstr
    mov rax, [r14 + B_ptr]
    mov [rsp], rax
    mov rdi, rbx
    lea rsi, [rip + .Lk_id]
    call jsonw_key
    mov rax, [rsp]
    mov rdi, rbx
    mov rsi, [rax + TC_id]
    call jsonw_str_cstr
    mov rdi, rbx
    lea rsi, [rip + .Lk_name]
    call jsonw_key
    mov rax, [rsp]
    mov rdi, rbx
    mov rsi, [rax + TC_name]
    call jsonw_str_cstr
    mov rdi, rbx
    lea rsi, [rip + .Lk_input]
    call jsonw_key
    mov rax, [rsp]
    mov rdi, [rax + TC_args]
    test rdi, rdi
    jz .Lwc_raw_empty
    call strlen
    test rax, rax
    jz .Lwc_raw_empty
    mov rdx, rax
    mov rax, [rsp]
    mov rsi, [rax + TC_args]
    mov rdi, rbx
    call jsonw_raw
    jmp .Lwc_endblk
.Lwc_raw_empty:
    mov rdi, rbx
    lea rsi, [rip + .Lempty_obj]
    mov edx, 2
    call jsonw_raw
.Lwc_endblk:
    mov rdi, rbx
    call jsonw_obj_end
.Lwc_next:
    add r14, B_SIZE
    jmp .Lwc_loop
.Lwc_end:
    mov rdi, rbx
    call jsonw_arr_end
    EPILOGUE

# .Lwrite_message(sb, Msg*): the "message" object of a message line
.Lwrite_message:
    PROLOGUE 16
    mov rbx, rdi
    mov r12, rsi
    mov rdi, rbx
    call jsonw_obj
    mov rdi, rbx
    lea rsi, [rip + .Lk_role]
    call jsonw_key
    mov eax, [r12 + M_role]
    lea rsi, [rip + .Lv_user]
    cmp eax, MR_USER
    je .Lwm_role
    lea rsi, [rip + .Lv_system]
    cmp eax, MR_SYSTEM
    je .Lwm_role
    lea rsi, [rip + .Lv_assistant]
    cmp eax, MR_ASSISTANT
    je .Lwm_role
    lea rsi, [rip + .Lv_tool_result]
.Lwm_role:
    mov rdi, rbx
    call jsonw_str_cstr
    cmp dword ptr [r12 + M_role], MR_TOOL_RESULT
    je .Lwm_toolresult
    mov rdi, rbx
    lea rsi, [rip + .Lk_timestamp]
    call jsonw_key
    call .Lunix_ms
    mov rdi, rbx
    mov rsi, rax
    call jsonw_u64
    cmp dword ptr [r12 + M_role], MR_ASSISTANT
    jne .Lwm_content
    mov rdi, rbx
    lea rsi, [rip + .Lk_stop]
    call jsonw_key
    mov edi, [r12 + M_stop]
    call .Lstop_to_cstr
    mov rdi, rbx
    mov rsi, rax
    call jsonw_str_cstr
    mov r13, [r12 + M_usage]
    test r13, r13
    jz .Lwm_content
    mov rdi, rbx
    lea rsi, [rip + .Lk_usage]
    call jsonw_key
    mov rdi, rbx
    call jsonw_obj
    mov rdi, rbx
    lea rsi, [rip + .Lk_input_tokens]
    call jsonw_key
    mov rdi, rbx
    mov esi, dword ptr [r13 + USG_input]
    call jsonw_u64
    mov rdi, rbx
    lea rsi, [rip + .Lk_output_tokens]
    call jsonw_key
    mov rdi, rbx
    mov esi, dword ptr [r13 + USG_output]
    call jsonw_u64
    mov rdi, rbx
    lea rsi, [rip + .Lk_cache_read]
    call jsonw_key
    mov rdi, rbx
    mov esi, dword ptr [r13 + USG_cache_read]
    call jsonw_u64
    mov rdi, rbx
    lea rsi, [rip + .Lk_cache_write]
    call jsonw_key
    mov rdi, rbx
    mov esi, dword ptr [r13 + USG_cache_write]
    call jsonw_u64
    mov rdi, rbx
    lea rsi, [rip + .Lk_total_tokens]
    call jsonw_key
    mov rdi, rbx
    mov esi, dword ptr [r13 + USG_total]
    call jsonw_u64
    mov rdi, rbx
    call jsonw_obj_end
.Lwm_content:
    mov rdi, rbx
    lea rsi, [rip + .Lk_content]
    call jsonw_key
    mov rdi, rbx
    mov rsi, r12
    call .Lwrite_content
    mov rdi, rbx
    call jsonw_obj_end
    EPILOGUE
.Lwm_toolresult:
    mov rdi, rbx
    lea rsi, [rip + .Lk_tool_call_id]
    call jsonw_key
    mov rdi, r12
    call msg_call_id
    test rax, rax
    jnz .Lwm_cid_ok
    lea rax, [rip + .Lempty]
.Lwm_cid_ok:
    mov rsi, rax
    mov rdi, rbx
    call jsonw_str_cstr
    mov rdi, rbx
    lea rsi, [rip + .Lk_is_error]
    call jsonw_key
    xor esi, esi
    test dword ptr [r12 + M_flags], MF_ERROR
    setnz sil
    mov rdi, rbx
    call jsonw_bool
    mov rdi, rbx
    lea rsi, [rip + .Lk_timestamp]
    call jsonw_key
    call .Lunix_ms
    mov rdi, rbx
    mov rsi, rax
    call jsonw_u64
    jmp .Lwm_content

# .Lload_msg_content(msg, content JV*, text_only): replay blocks
.Lload_msg_content:
    PROLOGUE 64
    mov r12, rdi
    mov r13, rsi
    mov r14d, edx
    mov qword ptr [rsp + SB_ptr], 0
    mov qword ptr [rsp + SB_len], 0
    mov qword ptr [rsp + SB_cap], 0
    mov qword ptr [rsp + 24], 0
    test r13, r13
    jz .Llmc_done
    mov eax, [r13 + JV_type]
    cmp eax, JT_STR
    jne .Llmc_arr
    mov rdi, r13
    call json_str
    mov rcx, rdx
    mov rdx, rax
    mov esi, BT_TEXT
    mov rdi, r12
    call msg_add_block
    jmp .Llmc_done
.Llmc_arr:
    cmp eax, JT_ARR
    jne .Llmc_done
    mov r15d, dword ptr [r13 + JV_n]
.Llmc_loop:
    mov rax, [rsp + 24]
    cmp rax, r15
    jae .Llmc_done
    mov rdi, r13
    mov esi, dword ptr [rsp + 24]
    call json_at
    test rax, rax
    jz .Llmc_next
    mov [rsp + 32], rax
    mov rdi, rax
    lea rsi, [rip + .Lk_type]
    call json_get
    test rax, rax
    jz .Llmc_next
    mov [rsp + 56], rax
    mov rdi, rax
    lea rsi, [rip + .Lv_text]
    call json_is
    test eax, eax
    jnz .Llmc_text
    test r14d, r14d
    jnz .Llmc_next
    mov rdi, [rsp + 56]
    lea rsi, [rip + .Lv_thinking]
    call json_is
    test eax, eax
    jnz .Llmc_next
    mov rdi, [rsp + 56]
    lea rsi, [rip + .Lv_tool_use]
    call json_is
    test eax, eax
    jnz .Llmc_tool
    jmp .Llmc_next
.Llmc_text:
    mov rdi, [rsp + 32]
    lea rsi, [rip + .Lk_text]
    call json_get
    mov rdi, rax
    call json_str
    mov rcx, rdx
    mov rdx, rax
    mov esi, BT_TEXT
    mov rdi, r12
    call msg_add_block
    jmp .Llmc_next
.Llmc_tool:
    mov rdi, [rsp + 32]
    lea rsi, [rip + .Lk_id]
    call json_get
    mov rdi, rax
    call json_str_cstr
    mov [rsp + 40], rax
    mov rdi, [rsp + 32]
    lea rsi, [rip + .Lk_name]
    call json_get
    mov rdi, rax
    call json_str_cstr
    mov [rsp + 48], rax
    mov rdi, [rsp + 32]
    lea rsi, [rip + .Lk_input]
    call json_get
    mov [rsp + 56], rax
    lea rdi, [rsp]
    call sb_clear
    mov rsi, [rsp + 56]
    test rsi, rsi
    jz .Llmc_tool_empty
    lea rdi, [rsp]
    call .Ljv_to_sb
    jmp .Llmc_tool_args
.Llmc_tool_empty:
    lea rdi, [rsp]
    lea rsi, [rip + .Lempty_obj]
    call sb_push_cstr
.Llmc_tool_args:
    mov rdi, r12
    mov rsi, [rsp + 40]
    mov rdx, [rsp + 48]
    mov rcx, [rsp + SB_ptr]
    call msg_add_toolcall
.Llmc_next:
    inc qword ptr [rsp + 24]
    jmp .Llmc_loop
.Llmc_done:
    lea rdi, [rsp]
    call sb_free
    EPILOGUE

# .Lload_message(s, tr, message JV*): rebuild one Msg and push it
.Lload_message:
    PROLOGUE 48
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov rdi, r14
    lea rsi, [rip + .Lk_role]
    call json_get
    mov rdi, rax
    call json_str
    test rax, rax
    jz .Llm_ret
    mov rbx, rax
    mov rdi, rbx
    lea rsi, [rip + .Lv_user]
    call .Lcstr_eq
    test eax, eax
    jnz .Llm_user
    mov rdi, rbx
    lea rsi, [rip + .Lv_assistant]
    call .Lcstr_eq
    test eax, eax
    jnz .Llm_assistant
    mov rdi, rbx
    lea rsi, [rip + .Lv_system]
    call .Lcstr_eq
    test eax, eax
    jnz .Llm_system
    mov rdi, rbx
    lea rsi, [rip + .Lv_tool_result]
    call .Lcstr_eq
    test eax, eax
    jnz .Llm_toolresult
    jmp .Llm_ret
.Llm_user:
    mov dword ptr [rsp + 24], MR_USER
    jmp .Llm_new
.Llm_assistant:
    mov dword ptr [rsp + 24], MR_ASSISTANT
    jmp .Llm_new
.Llm_system:
    mov dword ptr [rsp + 24], MR_SYSTEM
    jmp .Llm_new
.Llm_toolresult:
    mov dword ptr [rsp + 24], MR_TOOL_RESULT
.Llm_new:
    mov edi, dword ptr [rsp + 24]
    call msg_new
    mov r15, rax
    test r15, r15
    jz .Llm_ret
    cmp dword ptr [rsp + 24], MR_TOOL_RESULT
    je .Llm_tr
    mov rdi, r14
    lea rsi, [rip + .Lk_content]
    call json_get
    mov rdi, r15
    mov rsi, rax
    xor edx, edx
    call .Lload_msg_content
    cmp dword ptr [rsp + 24], MR_ASSISTANT
    jne .Llm_push
    mov rdi, r14
    lea rsi, [rip + .Lk_stop]
    call json_get
    mov rdi, rax
    call json_str_cstr
    mov rdi, rax
    call .Lstop_from_cstr
    mov [r15 + M_stop], eax
    mov rdi, r14
    lea rsi, [rip + .Lk_usage]
    call json_get
    test rax, rax
    jz .Llm_push
    cmp dword ptr [rax + JV_type], JT_OBJ
    jne .Llm_push
    mov r14, rax
    mov qword ptr [rsp], 0
    mov qword ptr [rsp + 8], 0
    mov qword ptr [rsp + 16], 0
    mov rdi, r14
    lea rsi, [rip + .Lk_input_tokens]
    xor edx, edx
    call json_get_u64
    mov dword ptr [rsp + USG_input], eax
    mov rdi, r14
    lea rsi, [rip + .Lk_output_tokens]
    xor edx, edx
    call json_get_u64
    mov dword ptr [rsp + USG_output], eax
    mov rdi, r14
    lea rsi, [rip + .Lk_cache_read]
    xor edx, edx
    call json_get_u64
    mov dword ptr [rsp + USG_cache_read], eax
    mov rdi, r14
    lea rsi, [rip + .Lk_cache_write]
    xor edx, edx
    call json_get_u64
    mov dword ptr [rsp + USG_cache_write], eax
    mov rdi, r14
    lea rsi, [rip + .Lk_total_tokens]
    xor edx, edx
    call json_get_u64
    mov dword ptr [rsp + USG_total], eax
    mov rdi, r15
    lea rsi, [rsp]
    call msg_set_usage
    jmp .Llm_push
.Llm_tr:
    mov rdi, r14
    lea rsi, [rip + .Lk_tool_call_id]
    call json_get
    mov rdi, rax
    call json_str_cstr
    mov rdi, r15
    mov rsi, rax
    call msg_set_call_id
    mov rdi, r14
    lea rsi, [rip + .Lk_is_error]
    call json_get
    test rax, rax
    jz .Llm_tr_content
    cmp dword ptr [rax + JV_type], JT_TRUE
    jne .Llm_tr_content
    or dword ptr [r15 + M_flags], MF_ERROR
.Llm_tr_content:
    mov rdi, r14
    lea rsi, [rip + .Lk_content]
    call json_get
    mov rdi, r15
    mov rsi, rax
    mov edx, 1
    call .Lload_msg_content
.Llm_push:
    mov rdi, r13
    mov rsi, r15
    call tr_push
.Llm_ret:
    EPILOGUE

# .Lschema_check(ptr, len) -> 0 | -EPERM
# The first JSONL line is the session header. A missing or unparsable header
# is the legacy schema 1; schema_version greater than SESSION_SCHEMA refuses
# the load with the version pair and the reason.
.Lschema_check:
    PROLOGUE
    mov r12, rdi
    mov r13, rsi
    call json_parse
    test rax, rax
    jz .Lsc_ok
    mov rbx, rax
    mov rdi, rbx
    lea rsi, [rip + .Lk_type]
    call json_get
    test rax, rax
    jz .Lsc_ok
    mov rdi, rax
    lea rsi, [rip + .Lv_session]
    call json_is
    test eax, eax
    jz .Lsc_ok
    mov rdi, rbx
    lea rsi, [rip + .Lk_schema]
    call json_get
    test rax, rax
    jz .Lsc_ok                 # missing -> legacy schema 1
    cmp dword ptr [rax + JV_type], JT_NUM
    jne .Lsc_nonnum            # a quoted/other present value is refused
    mov rdi, rbx
    lea rsi, [rip + .Lk_schema]
    mov edx, 1
    call json_get_u64
    cmp rax, SESSION_SCHEMA
    jbe .Lsc_ok
    mov r12, rax
    lea rdi, [rip + .Lerr_schema_new]
    call log_cstr
    mov rdi, r12
    call log_u64
    lea rdi, [rip + .Lerr_schema_mid]
    call log_cstr
    mov edi, SESSION_SCHEMA
    call log_u64
    lea rdi, [rip + .Lerr_schema_tail]
    call log_cstr
    call log_nl
    mov rax, -EPERM
    EPILOGUE
.Lsc_nonnum:
    lea rdi, [rip + .Lerr_schema_num]
    call log_cstr
    call log_nl
    mov rax, -EPERM
    EPILOGUE
.Lsc_ok:
    xor eax, eax
    EPILOGUE

# .Lapply_compaction(tr rdi, cut rsi): replay a "compaction" custom entry.
# compact_apply persisted the summary as the last loaded message, immediately
# before this entry, so drop the first `cut` messages, move that summary to the
# front and keep it plus everything after.  Dropped messages have their M_blocks
# VEC freed here; their leaves remain in TR_owned for tr_free (no double free).
.Lapply_compaction:
    PROLOGUE 16
    mov r12, rdi
    mov r13, rsi
    test r12, r12
    jz .Lac_ret
    test r13, r13
    jle .Lac_ret
    call tr_len
    mov r14, rax                    # n (includes the summary)
    cmp r14, 1
    jb .Lac_ret
    lea r15, [r14 - 1]              # N = index of the summary
    cmp r13, r15
    jbe .Lac_clamped
    mov r13, r15
.Lac_clamped:
    xor ebx, ebx
.Lac_free_loop:
    cmp rbx, r13
    jae .Lac_shift
    mov rdi, r12
    mov rsi, rbx
    call tr_msg
    test rax, rax
    jz .Lac_free_next
    mov rdi, [rax + M_blocks]
    test rdi, rdi
    jz .Lac_free_next
    mov [rsp], rax
    mov [rsp + 8], rdi
    call vec_free
    mov rdi, [rsp + 8]
    call mem_free
    mov rax, [rsp]
    mov qword ptr [rax + M_blocks], 0
.Lac_free_next:
    inc rbx
    jmp .Lac_free_loop
.Lac_shift:
    mov r8, [r12 + TR_msgs]
    test r8, r8
    jz .Lac_ret
    mov r9, [r8 + VEC_ptr]
    mov r10, r15
    sub r10, r13
    inc r10                         # new length = 1 + (N - cut)
    mov rax, [r9 + r15*8]           # the summary message
    mov [r9], rax
    mov rcx, 1
.Lac_shift_loop:
    cmp rcx, r10
    jae .Lac_shift_done
    lea rax, [r13 - 1]
    add rax, rcx
    mov rdx, [r9 + rax*8]
    mov [r9 + rcx*8], rdx
    inc rcx
    jmp .Lac_shift_loop
.Lac_shift_done:
    mov [r8 + VEC_len], r10
.Lac_ret:
    EPILOGUE

# .Lprocess_line(s, tr, ptr, len): parse one JSONL line and replay it
.Lprocess_line:
    PROLOGUE
    test rcx, rcx
    jz .Lpl_ret
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    mov rdi, r14
    mov rsi, r15
    call json_parse
    test rax, rax
    jz .Lpl_ret
    mov rbx, rax
    mov rdi, rbx
    lea rsi, [rip + .Lk_type]
    call json_get
    test rax, rax
    jz .Lpl_ret
    mov rdi, rax
    lea rsi, [rip + .Lv_message]
    call json_is
    test eax, eax
    jnz .Lpl_msg
    mov rdi, rbx
    lea rsi, [rip + .Lk_type]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lv_model_change]
    call json_is
    test eax, eax
    jnz .Lpl_model
    mov rdi, rbx
    lea rsi, [rip + .Lk_type]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lv_custom]
    call json_is
    test eax, eax
    jnz .Lpl_custom
    jmp .Lpl_ret
.Lpl_custom:
    mov rdi, rbx
    lea rsi, [rip + .Lk_custom_type]
    call json_get_cstr
    test rax, rax
    jz .Lpl_ret
    mov rdi, rax
    lea rsi, [rip + .Lv_compaction]
    call .Lcstr_eq
    test eax, eax
    jz .Lpl_ret
    mov rdi, rbx
    lea rsi, [rip + .Lk_data]
    call json_get
    test rax, rax
    jz .Lpl_ret
    mov rdi, rax
    lea rsi, [rip + .Lk_first_kept]
    xor edx, edx
    call json_get_u64
    test rax, rax
    jz .Lpl_ret
    mov rdi, r13
    mov rsi, rax
    call .Lapply_compaction
    jmp .Lpl_ret
.Lpl_msg:
    mov rdi, rbx
    lea rsi, [rip + .Lk_message]
    call json_get
    mov rdi, r12
    mov rsi, r13
    mov rdx, rax
    call .Lload_message
    jmp .Lpl_ret
.Lpl_model:
    mov rdi, rbx
    lea rsi, [rip + .Lk_provider]
    call json_get
    mov rdi, rax
    call json_str_cstr
    mov r14, rax
    mov rdi, rbx
    lea rsi, [rip + .Lk_model]
    call json_get
    mov rdi, rax
    call json_str_cstr
    mov r15, rax
    lea rdi, [r12 + S_provider]
    mov rsi, r14
    call .Lreplace_str
    lea rdi, [r12 + S_model]
    mov rsi, r15
    call .Lreplace_str
.Lpl_ret:
    EPILOGUE

# .Lscan_id(ptr, len, &first_id, &last_id): header id fallback + last message id
.Lscan_id:
    PROLOGUE 32
    test rsi, rsi
    jz .Lsi_ret
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    mov rdi, r12
    mov rsi, r13
    call json_parse
    test rax, rax
    jz .Lsi_ret
    mov rbx, rax
    mov rdi, rbx
    lea rsi, [rip + .Lk_type]
    call json_get
    test rax, rax
    jz .Lsi_ret
    mov rdi, rax
    lea rsi, [rip + .Lv_session]
    call json_is
    test eax, eax
    jnz .Lsi_header
    mov rdi, rbx
    lea rsi, [rip + .Lk_type]
    call json_get
    mov rdi, rax
    lea rsi, [rip + .Lv_message]
    call json_is
    test eax, eax
    jnz .Lsi_msgentry
    jmp .Lsi_ret
.Lsi_header:
    cmp qword ptr [r14], 0
    jne .Lsi_ret
    mov rdi, rbx
    lea rsi, [rip + .Lk_id]
    call json_get
    mov rdi, rax
    call json_str_cstr
    mov rdi, r14
    mov rsi, rax
    call .Lreplace_str
    jmp .Lsi_ret
.Lsi_msgentry:
    mov rdi, rbx
    lea rsi, [rip + .Lk_id]
    call json_get
    mov rdi, rax
    call json_str_cstr
    mov rdi, r15
    mov rsi, rax
    call .Lreplace_str
.Lsi_ret:
    EPILOGUE

# .Lid_from_name(path) -> 8 (or whatever) char id after the last '_' | 0
.Lid_from_name:
    PROLOGUE
    mov rbx, rdi
    test rbx, rbx
    jz .Lif_none
    call strlen
    mov r13, rax
    cmp r13, 7
    jb .Lif_none
    lea rdi, [rbx + r13 - 6]
    lea rsi, [rip + .Ljsonl]
    mov edx, 6
    call memeq
    cmp eax, 1
    jne .Lif_none
    lea r12, [rbx + r13 - 7]
.Lif_loop:
    cmp byte ptr [r12], '_'
    je .Lif_found
    cmp r12, rbx
    jbe .Lif_none
    dec r12
    jmp .Lif_loop
.Lif_found:
    lea rdi, [r12 + 1]
    mov rax, r12
    sub rax, rbx
    mov rsi, r13
    sub rsi, rax
    sub rsi, 7
    test rsi, rsi
    jz .Lif_none
    call mem_dup
    EPILOGUE
.Lif_none:
    xor eax, eax
    EPILOGUE

# ================================================================ public API
# session_new(dir|0, cwd) -> Session* | 0
FN session_new
    PROLOGUE 64
    mov r12, rdi
    mov r13, rsi
    mov rdi, r12
    mov rsi, r13
    call .Lresolve_dir
    test rax, rax
    jz .Lsn_zero
    mov r14, rax
    mov rdi, r14
    call .Lmkdirs
    mov edi, S_SIZE
    call mem_alloc
    mov rbx, rax
    mov qword ptr [rbx + S_fd], -1
    mov dword ptr [rbx + S_enabled], 1
    mov qword ptr [rbx + S_path], 0
    mov qword ptr [rbx + S_id], 0
    mov qword ptr [rbx + S_last_id], 0
    mov qword ptr [rbx + S_provider], 0
    mov qword ptr [rbx + S_model], 0
    mov rdi, r13
    test rdi, rdi
    jnz .Lsn_cwdcopy
    lea rdi, [rip + .Lempty]
.Lsn_cwdcopy:
    call .Ldup_cstr
    mov [rbx + S_cwd], rax
    lea rdi, [rsp]
    call .Lrand_id8
    lea rdi, [rsp]
    call .Ldup_cstr
    mov [rbx + S_id], rax
    lea rdi, [rsp + 16]
    mov qword ptr [rdi + SB_ptr], 0
    mov qword ptr [rdi + SB_len], 0
    mov qword ptr [rdi + SB_cap], 0
    call .Lunix_ms
    mov r15, rax
    lea rdi, [rsp + 16]
    mov rsi, r15
    call sb_push_u64
    lea rdi, [rsp + 16]
    mov esi, 95
    call sb_push_byte
    lea rdi, [rsp + 16]
    lea rsi, [rsp]
    mov edx, 8
    call sb_push
    lea rdi, [rsp + 16]
    lea rsi, [rip + .Ljsonl]
    call sb_push_cstr
    mov rdi, r14
    mov rsi, [rsp + 16 + SB_ptr]
    call .Lpath_join
    mov [rbx + S_path], rax
    lea rdi, [rsp + 16]
    call sb_free
    mov rdi, r14
    call mem_free
    mov rdi, [rbx + S_path]
    mov esi, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC
    mov edx, 0x1A4
    call os_open
    test rax, rax
    js .Lsn_fail
    mov [rbx + S_fd], rax
    lea rdi, [rsp + 16]
    mov qword ptr [rdi + SB_ptr], 0
    mov qword ptr [rdi + SB_len], 0
    mov qword ptr [rdi + SB_cap], 0
    lea rdi, [rsp + 16]
    call jsonw_obj
    lea rdi, [rsp + 16]
    lea rsi, [rip + .Lk_type]
    call jsonw_key
    lea rdi, [rsp + 16]
    lea rsi, [rip + .Lv_session]
    call jsonw_str_cstr
    lea rdi, [rsp + 16]
    lea rsi, [rip + .Lk_schema]
    call jsonw_key
    lea rdi, [rsp + 16]
    mov esi, SESSION_SCHEMA
    call jsonw_u64
    lea rdi, [rsp + 16]
    lea rsi, [rip + .Lk_id]
    call jsonw_key
    lea rdi, [rsp + 16]
    lea rsi, [rsp]
    mov edx, 8
    call jsonw_str
    lea rdi, [rsp + 16]
    lea rsi, [rip + .Lk_timestamp]
    call jsonw_key
    lea rdi, [rsp + 16]
    mov rsi, r15
    call jsonw_u64
    lea rdi, [rsp + 16]
    lea rsi, [rip + .Lk_cwd]
    call jsonw_key
    test r13, r13
    jz .Lsn_cwdempty
    mov rdi, r13
    call strlen
    mov rdx, rax
    mov rsi, r13
    jmp .Lsn_cwdemit
.Lsn_cwdempty:
    lea rsi, [rip + .Lempty]
    xor edx, edx
.Lsn_cwdemit:
    lea rdi, [rsp + 16]
    call jsonw_str
    lea rdi, [rsp + 16]
    call jsonw_obj_end
    mov rdi, rbx
    lea rsi, [rsp + 16]
    mov edx, 1
    call .Lwrite_line
    mov r12, rax
    lea rdi, [rsp + 16]
    call sb_free
    test r12, r12
    js .Lsn_fail
    mov rax, rbx
    EPILOGUE
.Lsn_fail:
    mov edi, dword ptr [rbx + S_fd]
    cmp edi, 0
    js .Lsn_free
    call os_close
.Lsn_free:
    mov rdi, [rbx + S_path]
    call mem_free
    mov rdi, [rbx + S_id]
    call mem_free
    mov rdi, [rbx + S_cwd]
    call mem_free
    mov rdi, rbx
    call mem_free
.Lsn_zero:
    xor eax, eax
    EPILOGUE

# session_open(path) -> Session* | 0 (existing file, append mode)
FN session_open
    PROLOGUE 64
    test rdi, rdi
    jz .Lso_zero
    mov r12, rdi
    mov esi, O_RDONLY | O_CLOEXEC
    xor edx, edx
    call os_open
    test rax, rax
    js .Lso_zero
    mov r13, rax
    mov qword ptr [rsp + SB_ptr], 0
    mov qword ptr [rsp + SB_len], 0
    mov qword ptr [rsp + SB_cap], 0
    mov qword ptr [rsp + 48], 0
    mov qword ptr [rsp + 56], 0
    mov edi, 65536
    call mem_alloc
    mov rbx, rax
.Lso_read:
    mov edi, r13d
    mov rsi, rbx
    mov edx, 65536
    call os_read
    cmp rax, -EINTR
    je .Lso_read
    test rax, rax
    js .Lso_eof
    jz .Lso_eof
    lea rcx, [rbx + rax]
    mov [rsp + 32], rcx
    mov [rsp + 24], rbx
.Lso_scan:
    mov rcx, [rsp + 24]
    cmp rcx, [rsp + 32]
    jae .Lso_read
    mov rdx, rcx
.Lso_findnl:
    cmp rdx, [rsp + 32]
    jae .Lso_partial
    cmp byte ptr [rdx], 10
    je .Lso_line
    inc rdx
    jmp .Lso_findnl
.Lso_partial:
    lea rdi, [rsp]
    mov rsi, rcx
    sub rdx, rcx
    call sb_push
    mov rdx, [rsp + 32]
    mov [rsp + 24], rdx
    jmp .Lso_read
.Lso_line:
    mov [rsp + 40], rdx
    lea rdi, [rsp]
    mov rsi, rcx
    sub rdx, rcx
    call sb_push
    mov rdx, [rsp + 40]
    inc rdx
    mov [rsp + 24], rdx
    mov rdi, [rsp + SB_ptr]
    mov rsi, [rsp + SB_len]
    lea rdx, [rsp + 48]
    lea rcx, [rsp + 56]
    call .Lscan_id
    lea rdi, [rsp]
    call sb_clear
    jmp .Lso_scan
.Lso_eof:
    cmp qword ptr [rsp + SB_len], 0
    je .Lso_close
    mov rdi, [rsp + SB_ptr]
    mov rsi, [rsp + SB_len]
    lea rdx, [rsp + 48]
    lea rcx, [rsp + 56]
    call .Lscan_id
.Lso_close:
    mov edi, r13d
    call os_close
    mov rdi, rbx
    call mem_free
    lea rdi, [rsp]
    call sb_free
    mov rdi, r12
    call .Lid_from_name
    test rax, rax
    jnz .Lso_haveid
    mov rax, [rsp + 48]
    mov qword ptr [rsp + 48], 0
.Lso_haveid:
    mov r14, rax
    # the header id is a separate allocation when the file name supplied one;
    # in the fallback path the slot is already 0, so this is a no-op
    mov rdi, [rsp + 48]
    call mem_free
    mov qword ptr [rsp + 48], 0
    mov r15, [rsp + 56]
    mov rdi, r12
    mov esi, O_WRONLY | O_APPEND | O_CLOEXEC
    xor edx, edx
    call os_open
    test rax, rax
    js .Lso_openfail
    mov r13, rax
    mov edi, S_SIZE
    call mem_alloc
    mov rbx, rax
    mov [rbx + S_fd], r13
    mov dword ptr [rbx + S_enabled], 1
    mov [rbx + S_id], r14
    mov [rbx + S_last_id], r15
    mov qword ptr [rbx + S_cwd], 0
    mov qword ptr [rbx + S_provider], 0
    mov qword ptr [rbx + S_model], 0
    mov rdi, r12
    call .Ldup_cstr
    mov [rbx + S_path], rax
    mov rax, rbx
    EPILOGUE
.Lso_openfail:
    mov rdi, r14
    call mem_free
    mov rdi, r15
    call mem_free
.Lso_zero:
    xor eax, eax
    EPILOGUE

# session_load(s, tr) -> 0 | -errno
FN session_load
    PROLOGUE 48
    test rdi, rdi
    jz .Lsl_einval
    test rsi, rsi
    jz .Lsl_einval
    mov r12, rdi
    mov r13, rsi
    mov qword ptr [rsp + SB_ptr], 0
    mov qword ptr [rsp + SB_len], 0
    mov qword ptr [rsp + SB_cap], 0
    mov qword ptr [rsp + 40], 0
    mov rdi, [r12 + S_path]
    test rdi, rdi
    jz .Lsl_einval
    mov esi, O_RDONLY | O_CLOEXEC
    xor edx, edx
    call os_open
    test rax, rax
    js .Lsl_err
    mov r14, rax
    mov edi, 65536
    call mem_alloc
    mov r15, rax
.Lsl_read:
    mov edi, r14d
    mov rsi, r15
    mov edx, 65536
    call os_read
    cmp rax, -EINTR
    je .Lsl_read
    test rax, rax
    js .Lsl_readerr
    jz .Lsl_eof
    lea rcx, [r15 + rax]
    mov [rsp + 24], rcx
    mov rbx, r15
.Lsl_scan:
    cmp rbx, [rsp + 24]
    jae .Lsl_read
    mov rcx, rbx
.Lsl_findnl:
    cmp rcx, [rsp + 24]
    jae .Lsl_partial
    cmp byte ptr [rcx], 10
    je .Lsl_line
    inc rcx
    jmp .Lsl_findnl
.Lsl_partial:
    lea rdi, [rsp]
    mov rsi, rbx
    mov rdx, [rsp + 24]
    sub rdx, rbx
    call sb_push
    mov rbx, [rsp + 24]
    jmp .Lsl_scan
.Lsl_line:
    mov [rsp + 32], rcx
    lea rdi, [rsp]
    mov rsi, rbx
    mov rdx, rcx
    sub rdx, rbx
    call sb_push
    mov rcx, [rsp + 32]
    inc rcx
    mov rbx, rcx
    cmp qword ptr [rsp + 40], 0
    jne .Lsl_proc
    mov qword ptr [rsp + 40], 1
    mov rdi, [rsp + SB_ptr]
    mov rsi, [rsp + SB_len]
    call .Lschema_check
    test rax, rax
    js .Lsl_readerr
.Lsl_proc:
    mov rdi, r12
    mov rsi, r13
    mov rdx, [rsp + SB_ptr]
    mov rcx, [rsp + SB_len]
    call .Lprocess_line
    lea rdi, [rsp]
    call sb_clear
    jmp .Lsl_scan
.Lsl_eof:
    cmp qword ptr [rsp + SB_len], 0
    je .Lsl_done
    cmp qword ptr [rsp + 40], 0
    jne .Lsl_proc_eof
    mov qword ptr [rsp + 40], 1
    mov rdi, [rsp + SB_ptr]
    mov rsi, [rsp + SB_len]
    call .Lschema_check
    test rax, rax
    js .Lsl_readerr
.Lsl_proc_eof:
    mov rdi, r12
    mov rsi, r13
    mov rdx, [rsp + SB_ptr]
    mov rcx, [rsp + SB_len]
    call .Lprocess_line
.Lsl_done:
    mov edi, r14d
    call os_close
    mov rdi, r15
    call mem_free
    lea rdi, [rsp]
    call sb_free
    xor eax, eax
    EPILOGUE
.Lsl_readerr:
    mov rbx, rax
    mov edi, r14d
    call os_close
    mov rdi, r15
    call mem_free
    lea rdi, [rsp]
    call sb_free
    mov rax, rbx
    EPILOGUE
.Lsl_err:
    EPILOGUE
.Lsl_einval:
    mov rax, -EINVAL
    EPILOGUE

# session_provider(s) -> cstr | 0
FN session_provider
    xor eax, eax
    test rdi, rdi
    jz .Lspv_ret
    mov rax, [rdi + S_provider]
.Lspv_ret:
    ret

# session_model(s) -> cstr | 0
FN session_model
    xor eax, eax
    test rdi, rdi
    jz .Lsmd_ret
    mov rax, [rdi + S_model]
.Lsmd_ret:
    ret

# session_id(s) -> cstr | 0.  The 8-hex id of the active session (filename
# suffix, else the header `id`), borrowed and owned by the Session.
FN session_id
    xor eax, eax
    test rdi, rdi
    jz .Lsid_ret
    mov rax, [rdi + S_id]
.Lsid_ret:
    ret

# session_path(s) -> cstr | 0.  The full .jsonl path, borrowed and owned by
# the Session.
FN session_path
    xor eax, eax
    test rdi, rdi
    jz .Lspth_ret
    mov rax, [rdi + S_path]
.Lspth_ret:
    ret

# session_append_model(s, provider cstr, model cstr) -> 0 | -EINVAL
FN session_append_model
    PROLOGUE 32
    test rdi, rdi
    jz .Lam_einval
    cmp qword ptr [rdi + S_fd], 0
    js .Lam_einval
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    lea rdi, [rsp]
    mov qword ptr [rdi + SB_ptr], 0
    mov qword ptr [rdi + SB_len], 0
    mov qword ptr [rdi + SB_cap], 0
    lea rdi, [rsp]
    call jsonw_obj
    lea rdi, [rsp]
    lea rsi, [rip + .Lk_type]
    lea rdx, [rip + .Lv_model_change]
    call .Lkv_str
    lea rdi, [rsp]
    lea rsi, [rip + .Lk_provider]
    mov rdx, r13
    call .Lkv_str
    lea rdi, [rsp]
    lea rsi, [rip + .Lk_model]
    mov rdx, r14
    call .Lkv_str
    lea rdi, [rsp]
    call jsonw_obj_end
    lea rdi, [r12 + S_provider]
    mov rsi, r13
    call .Lreplace_str
    lea rdi, [r12 + S_model]
    mov rsi, r14
    call .Lreplace_str
    mov rdi, r12
    lea rsi, [rsp]
    xor edx, edx
    call .Lwrite_line
    mov r13, rax
    lea rdi, [rsp]
    call sb_free
    mov rax, r13
    EPILOGUE
.Lam_einval:
    mov rax, -EINVAL
    EPILOGUE

# session_append_msg(s, Msg*) -> 0 | -EINVAL
FN session_append_msg
    PROLOGUE 48
    test rdi, rdi
    jz .Lsm_einval
    test rsi, rsi
    jz .Lsm_einval
    cmp qword ptr [rdi + S_fd], 0
    js .Lsm_einval
    mov r12, rdi
    mov r13, rsi
    lea rdi, [rsp]
    mov qword ptr [rdi + SB_ptr], 0
    mov qword ptr [rdi + SB_len], 0
    mov qword ptr [rdi + SB_cap], 0
    lea rdi, [rsp + 24]
    call .Lrand_id8
    lea rdi, [rsp]
    call jsonw_obj
    lea rdi, [rsp]
    lea rsi, [rip + .Lk_type]
    call jsonw_key
    lea rdi, [rsp]
    lea rsi, [rip + .Lv_message]
    call jsonw_str_cstr
    lea rdi, [rsp]
    lea rsi, [rip + .Lk_id]
    call jsonw_key
    lea rdi, [rsp]
    lea rsi, [rsp + 24]
    mov edx, 8
    call jsonw_str
    lea rdi, [rsp]
    lea rsi, [rip + .Lk_parent_id]
    call jsonw_key
    mov rax, [r12 + S_last_id]
    test rax, rax
    jz .Lsm_nullparent
    lea rdi, [rsp]
    mov rsi, rax
    call jsonw_str_cstr
    jmp .Lsm_parentdone
.Lsm_nullparent:
    lea rdi, [rsp]
    call jsonw_null
.Lsm_parentdone:
    lea rdi, [rsp]
    lea rsi, [rip + .Lk_message]
    call jsonw_key
    lea rdi, [rsp]
    mov rsi, r13
    call .Lwrite_message
    lea rdi, [rsp]
    call jsonw_obj_end
    lea rdi, [r12 + S_last_id]
    lea rsi, [rsp + 24]
    call .Lreplace_str
    mov rdi, r12
    lea rsi, [rsp]
    mov edx, 1
    call .Lwrite_line
    mov r13, rax
    lea rdi, [rsp]
    call sb_free
    mov rax, r13
    EPILOGUE
.Lsm_einval:
    mov rax, -EINVAL
    EPILOGUE

# session_append_custom(s, custom_type cstr, data_json cstr|0) -> 0 | -EINVAL
FN session_append_custom
    PROLOGUE 32
    test rdi, rdi
    jz .Lac_einval
    cmp qword ptr [rdi + S_fd], 0
    js .Lac_einval
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    lea rdi, [rsp]
    mov qword ptr [rdi + SB_ptr], 0
    mov qword ptr [rdi + SB_len], 0
    mov qword ptr [rdi + SB_cap], 0
    lea rdi, [rsp]
    call jsonw_obj
    lea rdi, [rsp]
    lea rsi, [rip + .Lk_type]
    lea rdx, [rip + .Lv_custom]
    call .Lkv_str
    lea rdi, [rsp]
    lea rsi, [rip + .Lk_custom_type]
    mov rdx, r13
    call .Lkv_str
    lea rdi, [rsp]
    lea rsi, [rip + .Lk_data]
    call jsonw_key
    test r14, r14
    jz .Lac_nulldata
    cmp byte ptr [r14], 0
    je .Lac_nulldata
    mov rdi, r14
    call strlen
    mov rdx, rax
    mov rsi, r14
    lea rdi, [rsp]
    call jsonw_raw
    jmp .Lac_datadone
.Lac_nulldata:
    lea rdi, [rsp]
    call jsonw_null
.Lac_datadone:
    lea rdi, [rsp]
    call jsonw_obj_end
    mov rdi, r12
    lea rsi, [rsp]
    xor edx, edx
    call .Lwrite_line
    mov r13, rax
    lea rdi, [rsp]
    call sb_free
    mov rax, r13
    EPILOGUE
.Lac_einval:
    mov rax, -EINVAL
    EPILOGUE

# session_close(s)
FN session_close
    PROLOGUE
    test rdi, rdi
    jz .Lcl_ret
    mov r12, rdi
    mov edi, dword ptr [r12 + S_fd]
    cmp edi, 0
    js .Lcl_strings
    call os_close
.Lcl_strings:
    mov rdi, [r12 + S_path]
    call mem_free
    mov rdi, [r12 + S_id]
    call mem_free
    mov rdi, [r12 + S_last_id]
    call mem_free
    mov rdi, [r12 + S_cwd]
    call mem_free
    mov rdi, [r12 + S_provider]
    call mem_free
    mov rdi, [r12 + S_model]
    call mem_free
    mov rdi, r12
    call mem_free
.Lcl_ret:
    EPILOGUE

# session_find_latest(dir|0, cwd) -> mem_alloc'd path | 0
FN session_find_latest
    PROLOGUE 48
    call .Lresolve_dir
    test rax, rax
    jz .Lfl_zero
    mov r12, rax
    mov rdi, r12
    mov esi, O_RDONLY | O_DIRECTORY | O_CLOEXEC
    xor edx, edx
    call os_open
    test rax, rax
    js .Lfl_nodir
    mov r13, rax
    mov edi, 32768
    call mem_alloc
    mov r14, rax
    xor r15d, r15d
    mov qword ptr [rsp], 0
    mov qword ptr [rsp + 8], 0
.Lfl_read:
    mov edi, r13d
    mov rsi, r14
    mov edx, 32768
    call os_getdents
    test rax, rax
    js .Lfl_end
    jz .Lfl_end
    mov [rsp + 16], rax
    xor ebx, ebx
.Lfl_rec:
    cmp rbx, [rsp + 16]
    jae .Lfl_read
    lea rcx, [r14 + rbx]
    movzx eax, word ptr [rcx + 16]
    test eax, eax
    jz .Lfl_end
    mov [rsp + 24], rax
    lea rax, [rcx + 19]
    mov [rsp + 32], rax
    mov rdi, rax
    call strlen
    mov rdi, [rsp + 32]
    mov [rsp + 40], rax
    cmp rax, 6
    jb .Lfl_next
    lea rdi, [rdi + rax - 6]
    lea rsi, [rip + .Ljsonl]
    mov edx, 6
    call memeq
    cmp eax, 1
    jne .Lfl_next
    mov rdi, [rsp + 32]
    mov rsi, [rsp + 40]
    call parse_u64
    test rdx, rdx
    jz .Lfl_next
    mov rcx, [rsp + 32]
    cmp byte ptr [rcx + rdx], '_'
    jne .Lfl_next
    cmp qword ptr [rsp + 8], 0
    jne .Lfl_cmp
    mov qword ptr [rsp + 8], 1
    jmp .Lfl_take
.Lfl_cmp:
    cmp rax, [rsp]
    jbe .Lfl_next
.Lfl_take:
    mov [rsp], rax
    mov rdi, r15
    call mem_free
    mov rdi, r12
    mov rsi, [rsp + 32]
    call .Lpath_join
    mov r15, rax
.Lfl_next:
    add rbx, [rsp + 24]
    jmp .Lfl_rec
.Lfl_end:
    mov edi, r13d
    call os_close
    mov rdi, r14
    call mem_free
    mov rdi, r12
    call mem_free
    mov rax, r15
    EPILOGUE
.Lfl_nodir:
    mov rdi, r12
    call mem_free
.Lfl_zero:
    xor eax, eax
    EPILOGUE

# session_find_id(dir|0, id) -> mem_alloc'd path | 0
FN session_find_id
    PROLOGUE 48
    mov r15, rsi
    xor esi, esi
    call .Lresolve_dir
    test rax, rax
    jz .Lfi_zero
    mov r12, rax
    mov rdi, r12
    mov esi, O_RDONLY | O_DIRECTORY | O_CLOEXEC
    xor edx, edx
    call os_open
    test rax, rax
    js .Lfi_nodir
    mov r13, rax
    mov edi, 32768
    call mem_alloc
    mov r14, rax
.Lfi_read:
    mov edi, r13d
    mov rsi, r14
    mov edx, 32768
    call os_getdents
    test rax, rax
    js .Lfi_none
    jz .Lfi_none
    mov [rsp], rax
    xor ebx, ebx
.Lfi_rec:
    cmp rbx, [rsp]
    jae .Lfi_read
    lea rcx, [r14 + rbx]
    movzx eax, word ptr [rcx + 16]
    test eax, eax
    jz .Lfi_none
    mov [rsp + 32], rax
    lea rax, [rcx + 19]
    mov [rsp + 8], rax
    mov rdi, rax
    call strlen
    mov [rsp + 16], rax
    mov rdi, r15
    call strlen
    mov [rsp + 24], rax
    mov rax, [rsp + 16]
    sub rax, [rsp + 24]
    cmp rax, 7
    jb .Lfi_next
    mov rdi, [rsp + 8]
    mov rax, [rsp + 16]
    lea rdi, [rdi + rax - 6]
    lea rsi, [rip + .Ljsonl]
    mov edx, 6
    call memeq
    cmp eax, 1
    jne .Lfi_next
    mov rcx, [rsp + 8]
    mov rax, [rsp + 16]
    sub rax, 7
    sub rax, [rsp + 24]
    cmp byte ptr [rcx + rax], '_'
    jne .Lfi_next
    lea rdi, [rcx + rax + 1]
    mov rsi, r15
    mov rdx, [rsp + 24]
    call memeq
    cmp eax, 1
    jne .Lfi_next
    mov rdi, r12
    mov rsi, [rsp + 8]
    call .Lpath_join
    mov r15, rax
    jmp .Lfi_end
.Lfi_next:
    add rbx, [rsp + 32]
    jmp .Lfi_rec
.Lfi_none:
    xor r15d, r15d
.Lfi_end:
    mov edi, r13d
    call os_close
    mov rdi, r14
    call mem_free
    mov rdi, r12
    call mem_free
    mov rax, r15
    EPILOGUE
.Lfi_nodir:
    mov rdi, r12
    call mem_free
.Lfi_zero:
    xor eax, eax
    EPILOGUE

# ================================================================ session_list
# session_list(dir|0, cwd|0) -> count | 0.  Lists the cwd's known sessions,
# newest first, as "<id> <timestamp_ms> <path>" on stdout.  The dir/cwd
# resolution mirrors session_find_latest: an explicit --session-dir is used
# verbatim, otherwise the default per-cwd directory is resolved.
.equ SL_MAX, 512

.section .bss
.p2align 3
sl_ts:   .zero 8 * SL_MAX       # unix-ms timestamp per entry
sl_path: .zero 8 * SL_MAX       # mem_alloc'd full path per entry
sl_id:   .zero 16 * SL_MAX      # 8-char id + NUL per entry

.section .rodata
.Lsl_space: .asciz " "
.Lsl_nl:    .byte 10

.text

# .Lsl_write(ptr rdi, len rsi): write to stdout (fd 1)
.Lsl_write:
    mov rdx, rsi
    mov rsi, rdi
    mov edi, 1
    jmp write_all

FN session_list
    PROLOGUE 96
    mov qword ptr [rsp], 0          # count
    call .Lresolve_dir
    test rax, rax
    jz .Lslist_zero
    mov r12, rax                    # dir (owned)
    mov rdi, r12
    mov esi, O_RDONLY | O_DIRECTORY | O_CLOEXEC
    xor edx, edx
    call os_open
    test rax, rax
    js .Lslist_freedir
    mov r13, rax                    # dirfd
    mov edi, 32768
    call mem_alloc
    mov r14, rax                    # getdents buffer
.Lslist_read:
    mov edi, r13d
    mov rsi, r14
    mov edx, 32768
    call os_getdents
    test rax, rax
    js .Lslist_scan_done
    jz .Lslist_scan_done
    mov [rsp + 8], rax              # bytes
    xor r15d, r15d                  # offset
.Lslist_rec:
    cmp r15, [rsp + 8]
    jae .Lslist_read
    lea rcx, [r14 + r15]
    movzx eax, word ptr [rcx + 16]  # d_reclen
    test eax, eax
    jz .Lslist_scan_done
    mov [rsp + 16], rax
    lea rbx, [rcx + 19]             # d_name
    mov rdi, rbx
    call strlen
    mov r8, rax                     # name length
    cmp r8, 16
    jb .Lslist_next
    lea rdi, [rbx + r8 - 6]
    lea rsi, [rip + .Ljsonl]
    mov edx, 6
    call memeq
    cmp eax, 1
    jne .Lslist_next
    # "<ms>_<id8>.jsonl": parse the ms prefix and require the exact suffix
    mov rdi, rbx
    mov rsi, r8
    call parse_u64
    test rdx, rdx
    jz .Lslist_next
    cmp byte ptr [rbx + rdx], '_'
    jne .Lslist_next
    lea rcx, [rdx + 15]
    cmp rcx, r8
    jne .Lslist_next
    mov [rsp + 32], rax             # timestamp
    mov [rsp + 40], rdx             # digits consumed
    mov rcx, [rsp]
    cmp rcx, SL_MAX
    jae .Lslist_next
    mov rdi, r12
    mov rsi, rbx
    call .Lpath_join
    test rax, rax
    jz .Lslist_next
    mov rcx, [rsp]
    lea rsi, [rip + sl_path]
    mov [rsi + rcx*8], rax
    lea rsi, [rip + sl_ts]
    mov rdx, [rsp + 32]
    mov [rsi + rcx*8], rdx
    mov rdx, [rsp + 40]
    lea rsi, [rbx + rdx + 1]
    mov rdi, rcx
    shl rdi, 4
    lea rdx, [rip + sl_id]
    add rdi, rdx
    mov edx, 8
    call memcpy
    mov byte ptr [rax + 8], 0
    inc qword ptr [rsp]
.Lslist_next:
    add r15, [rsp + 16]
    jmp .Lslist_rec
.Lslist_scan_done:
    mov edi, r13d
    call os_close
    mov rdi, r14
    call mem_free
    # insertion sort, descending timestamp (equal keys keep directory order)
    mov r15, [rsp]
    mov r14, 1
.Lslist_sort_i:
    cmp r14, r15
    jae .Lslist_print
    lea rax, [rip + sl_ts]
    mov r8, [rax + r14*8]
    lea rax, [rip + sl_path]
    mov r9, [rax + r14*8]
    mov r10, r14
    shl r10, 4
    lea rax, [rip + sl_id]
    add r10, rax
    mov rbx, [r10]                  # save the key id value (not its address)
    mov r11, [r10 + 8]              # before the shift overwrites sl_id[i]
    mov rcx, r14
.Lslist_sort_shift:
    test rcx, rcx
    jz .Lslist_sort_place
    lea rax, [rip + sl_ts]
    mov rdx, [rax + rcx*8 - 8]
    cmp rdx, r8
    jae .Lslist_sort_place
    mov [rax + rcx*8], rdx
    lea rax, [rip + sl_path]
    mov rdx, [rax + rcx*8 - 8]
    mov [rax + rcx*8], rdx
    mov rdx, rcx
    shl rdx, 4
    lea rax, [rip + sl_id]
    add rax, rdx
    mov rsi, rax
    sub rsi, 16
    mov rdi, [rsi]
    mov [rax], rdi
    mov rdi, [rsi + 8]
    mov [rax + 8], rdi
    dec rcx
    jmp .Lslist_sort_shift
.Lslist_sort_place:
    lea rax, [rip + sl_ts]
    mov [rax + rcx*8], r8
    lea rax, [rip + sl_path]
    mov [rax + rcx*8], r9
    mov rdx, rcx
    shl rdx, 4
    lea rax, [rip + sl_id]
    add rax, rdx
    mov [rax], rbx
    mov [rax + 8], r11
    inc r14
    jmp .Lslist_sort_i
.Lslist_print:
    mov r15, [rsp]
    xor r14d, r14d
.Lslist_print_loop:
    cmp r14, r15
    jae .Lslist_done
    mov rax, r14
    shl rax, 4
    lea rbx, [rip + sl_id]
    add rbx, rax
    mov rdi, rbx
    call strlen
    mov rdi, rbx
    mov rsi, rax
    call .Lsl_write
    lea rdi, [rip + .Lsl_space]
    mov esi, 1
    call .Lsl_write
    lea rax, [rip + sl_ts]
    mov rsi, [rax + r14*8]
    lea rdi, [rsp + 48]             # number scratch (keeps [rsp] count intact)
    call fmt_u64
    lea rdi, [rsp + 48]
    mov rsi, rax
    call .Lsl_write
    lea rdi, [rip + .Lsl_space]
    mov esi, 1
    call .Lsl_write
    lea rax, [rip + sl_path]
    mov rbx, [rax + r14*8]
    mov rdi, rbx
    call strlen
    mov rdi, rbx
    mov rsi, rax
    call .Lsl_write
    lea rdi, [rip + .Lsl_nl]
    mov esi, 1
    call .Lsl_write
    inc r14
    jmp .Lslist_print_loop
.Lslist_done:
    xor r14d, r14d
    mov r15, [rsp]
.Lslist_free_loop:
    cmp r14, r15
    jae .Lslist_freedir
    lea rax, [rip + sl_path]
    mov rdi, [rax + r14*8]
    call mem_free
    inc r14
    jmp .Lslist_free_loop
.Lslist_freedir:
    mov rdi, r12
    call mem_free
.Lslist_zero:
    mov rax, [rsp]
    EPILOGUE
