.include "opcode.inc"
.include "core/core.inc"
# ext/host.s — static OpcodeHostV1 host table for build-time plugins (M6).
#
# Contract: include/opcode_plugin.h (frozen v1 ABI).  The binary is static and
# nostdlib, so there is no dlopen: src/ext/plugin.s walks the generated table
# and hands this vtable to every plugin.  Layout: 2 x u32 header + 26 function
# pointers + reserved[8] = 280 bytes, field order exactly as in the header.
#
# Documented M6 limitations (see .agents/docs/extensibility.md §3.2):
#   - session_id/session_file/system_prompt return 0 (no session plumbing yet);
#     append_entry does write `custom` entries when g_agent_session is set.
#   - defer runs the callback immediately (single-threaded; no event loop here).
#   - is_cancelled always returns 0; http_request/http_cancel return 0 (M7).
#   - register_tool wraps the plugin tool in an internal TL and completes
#     synchronously; OPCODE_TOOL_THREADSAFE is not honoured by the M6 loader.
#   - events/commands are recorded in static tables (opcode_host_events /
#     opcode_host_commands + counts) for the later wiring milestone.

.equ OPCODE_HOST_ABI,  1
.equ OPCODE_HOST_SIZE, 280

# OpcodeToolV1 field offsets (C header)
.equ FT_flags,   4
.equ FT_name,    8
.equ FT_label,   16
.equ FT_desc,    24
.equ FT_params,  32
.equ FT_execute, 56
.equ FT_SIZE,    72

# OpcodePluginV1 field offsets
.equ FP_abi,     0
.equ FP_size,    4
.equ FP_name,    8
.equ FP_version, 16
.equ FP_init,    24

.section .rodata
.Lopcode_prefix: .asciz "opcode: "
.Llevel_debug:   .asciz "debug: "
.Llevel_info:    .asciz "info: "
.Llevel_warn:    .asciz "warn: "
.Llevel_error:   .asciz "error: "
.Lcontent:       .asciz "content"
.Ltext:          .asciz "text"
.Lerr_incomplete: .asciz "error: plugin tool did not complete"
.Lhex:           .ascii "0123456789abcdef"
.p2align 3
.Llevels: .quad .Llevel_debug, .Llevel_info, .Llevel_warn, .Llevel_error

.section .bss
.p2align 3
.Lcwd_buf: .zero 4096
.Lkeybuf:  .zero 256

# event registrations: {name, handler, userdata} (24 bytes each), for later wiring
.globl opcode_host_events
opcode_host_events: .zero 24 * 32
.globl opcode_host_event_count
opcode_host_event_count: .zero 8

# slash-command registrations: {name, description, handler} (24 bytes each)
.globl opcode_host_commands
opcode_host_commands: .zero 24 * 32
.globl opcode_host_command_count
opcode_host_command_count: .zero 8

.text

# ------------------------------------------------------------------ helpers
# json_path(json cstr, path cstr) -> JV* | 0.  Dotted key path ("a.b.c"), each
# segment looked up in the current object.  Single-threaded host: one scratch
# key buffer is enough.
json_path:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    test rbx, rbx
    jz .Ljp_null
    test r12, r12
    jz .Ljp_null
    cmp byte ptr [r12], 0
    je .Ljp_null
    mov rdi, rbx
    call strlen
    mov rdi, rbx
    mov rsi, rax
    call json_parse
    test rax, rax
    jz .Ljp_null
    mov r13, rax
.Ljp_loop:
    lea rdi, [rip + .Lkeybuf]
    mov rcx, r12
    xor edx, edx
1:  movzx eax, byte ptr [rcx]
    test al, al
    jz 2f
    cmp al, '.'
    je 2f
    cmp edx, 255
    jae 2f
    mov [rdi + rdx], al
    inc rdx
    inc rcx
    jmp 1b
2:  mov byte ptr [rdi + rdx], 0
    mov r12, rcx
    cmp byte ptr [r12], '.'
    jne 3f
    inc r12
3:  mov rdi, r13
    lea rsi, [rip + .Lkeybuf]
    call json_get
    test rax, rax
    jz .Ljp_null
    mov r13, rax
    cmp byte ptr [r12], 0
    jne .Ljp_loop
    mov rax, r13
    EPILOGUE
.Ljp_null:
    xor eax, eax
    EPILOGUE

# esc_push(sb, byte): append one JSON-escaped input byte to the SB
esc_push:
    PROLOGUE
    mov rbx, rdi
    mov r12d, esi
    cmp r12b, '"'
    je .Lep_quote
    cmp r12b, '\\'
    je .Lep_bslash
    cmp r12b, 0x20
    jb .Lep_ctrl
    mov rdi, rbx
    mov esi, r12d
    call sb_push_byte
    EPILOGUE
.Lep_quote:
    mov r13d, '"'
    jmp .Lep_pair
.Lep_bslash:
    mov r13d, '\\'
.Lep_pair:
    mov rdi, rbx
    mov esi, '\\'
    call sb_push_byte
    mov rdi, rbx
    mov esi, r13d
    call sb_push_byte
    EPILOGUE
.Lep_ctrl:
    mov r13d, r12d
    cmp r13b, 10
    je .Lep_n
    cmp r13b, 13
    je .Lep_r
    cmp r13b, 9
    je .Lep_t
    cmp r13b, 8
    je .Lep_b
    cmp r13b, 12
    je .Lep_f
    mov rdi, rbx
    mov esi, '\\'
    call sb_push_byte
    mov rdi, rbx
    mov esi, 'u'
    call sb_push_byte
    mov rdi, rbx
    mov esi, '0'
    call sb_push_byte
    mov rdi, rbx
    mov esi, '0'
    call sb_push_byte
    mov eax, r13d
    shr eax, 4
    lea rcx, [rip + .Lhex]
    movzx esi, byte ptr [rcx + rax]
    mov rdi, rbx
    call sb_push_byte
    mov eax, r13d
    and eax, 15
    lea rcx, [rip + .Lhex]
    movzx esi, byte ptr [rcx + rax]
    mov rdi, rbx
    call sb_push_byte
    EPILOGUE
.Lep_n:
    mov r13d, 'n'
    jmp .Lep_named
.Lep_r:
    mov r13d, 'r'
    jmp .Lep_named
.Lep_t:
    mov r13d, 't'
    jmp .Lep_named
.Lep_b:
    mov r13d, 'b'
    jmp .Lep_named
.Lep_f:
    mov r13d, 'f'
.Lep_named:
    mov rdi, rbx
    mov esi, '\\'
    call sb_push_byte
    mov rdi, rbx
    mov esi, r13d
    call sb_push_byte
    EPILOGUE

# ------------------------------------------------------------------ memory
# strdup_(s) -> cstr (host allocator)
host_strdup:
    PROLOGUE
    mov r12, rdi
    call strlen
    mov rdi, r12
    mov rsi, rax
    call mem_dup
    EPILOGUE

# ------------------------------------------------------------------ logging
# log(level, msg) -> void; 0=debug 1=info 2=warn 3=error, prefix + newline
host_log:
    PROLOGUE
    mov r12d, edi
    mov r13, rsi
    test r13, r13
    jz .Lhl_ret
    mov eax, r12d
    cmp eax, 3
    jbe 1f
    xor eax, eax
1:  lea rcx, [rip + .Llevels]
    mov rdi, [rcx + rax*8]
    call log_cstr
    mov rdi, r13
    call log_cstr
    call log_nl
.Lhl_ret:
    EPILOGUE

# ------------------------------------------------------------------ tools
# register_tool(tool): wrap the plugin's OpcodeToolV1 so it becomes a core TL.
# The wrapper is TL_SIZE + sizeof(OpcodeToolV1): the internal TL first, then a
# copy of the plugin struct; host_ptool_exec reaches it through J_tool.
host_register_tool:
    PROLOGUE
    mov r12, rdi
    test r12, r12
    jz .Lhrt_ret
    mov edi, TL_SIZE + FT_SIZE
    call mem_alloc
    mov rbx, rax
    mov rax, [r12 + FT_name]
    mov [rbx + TL_name], rax
    mov rax, [r12 + FT_label]
    mov [rbx + TL_label], rax
    mov rax, [r12 + FT_desc]
    mov [rbx + TL_desc], rax
    mov rax, [r12 + FT_params]
    mov [rbx + TL_params], rax
    mov eax, [r12 + FT_flags]
    and eax, TL_READONLY | TL_SEQUENTIAL | TL_DESTRUCTIVE
    mov [rbx + TL_flags], eax
    lea rax, [rip + host_ptool_exec]
    mov [rbx + TL_exec], rax
    lea rdi, [rbx + TL_SIZE]
    mov rsi, r12
    mov edx, FT_SIZE
    call memcpy
    mov rdi, rbx
    call tools_add
.Lhrt_ret:
    EPILOGUE

# host_ptool_exec(job): call the plugin's execute synchronously.  The opaque
# call handle is the Job* itself, so tool_done can find the result buffer.
host_ptool_exec:
    PROLOGUE
    mov rbx, rdi
    mov r12, [rbx + J_tool]
    lea r13, [r12 + TL_SIZE]
    # J_pid/J_fd is a union in the zeroed Job; mark it "not started" so a
    # plugin that neither completes nor publishes a child/pipe cannot make
    # the loop watch_add(0, POLLIN) on stdin.
    mov qword ptr [rbx + J_fd], -1
    mov rax, [r13 + FT_execute]
    test rax, rax
    jz .Lhpe_check
    lea rdi, [rip + opcode_host_v1]
    mov rsi, rbx
    mov rdx, [rbx + J_call_id]
    mov rcx, [rbx + J_args]
    xor r8d, r8d                    # signal_token: v1 helper is a no-op
    call rax
.Lhpe_check:
    # A synchronous plugin is expected to have called tool_done.  If it did
    # not and left no fd/pid, finish with an explicit error instead of
    # watching an unset descriptor.
    cmp dword ptr [rbx + J_state], JS_DONE
    je .Lhpe_ret
    cmp qword ptr [rbx + J_fd], -1
    jne .Lhpe_ret
    mov rdi, rbx
    lea rsi, [rip + .Lerr_incomplete]
    call tool_err
.Lhpe_ret:
    xor eax, eax
    EPILOGUE

# tool_done(call, result_json, is_error): copy content[0].text into the job's
# result SB, free the plugin-allocated envelope (host owns it after the call)
# and mark the job done.  A non-JSON/empty envelope yields an empty result.
host_tool_done:
    PROLOGUE
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    test rbx, rbx
    jz .Lhtd_ret
    test r13d, r13d
    jz 1f
    or dword ptr [rbx + J_flags], JF_ERROR
1:  test r12, r12
    jz .Lhtd_done
    mov rdi, r12
    call strlen
    mov rdi, r12
    mov rsi, rax
    call json_parse
    test rax, rax
    jz .Lhtd_free
    mov rdi, rax
    lea rsi, [rip + .Lcontent]
    call json_get
    test rax, rax
    jz .Lhtd_free
    mov rdi, rax
    xor esi, esi
    call json_at
    test rax, rax
    jz .Lhtd_free
    mov rdi, rax
    lea rsi, [rip + .Ltext]
    call json_get_cstr
    test rax, rax
    jz .Lhtd_free
    mov rdi, [rbx + J_out]
    mov rsi, rax
    call sb_push_cstr
.Lhtd_free:
    mov rdi, r12
    call mem_free
.Lhtd_done:
    mov rdi, rbx
    call tool_done
.Lhtd_ret:
    EPILOGUE

# ------------------------------------------------------------------ scheduling
# defer(host, fn, ud): run fn(ud) immediately (single-threaded M6)
host_defer:
    push rbp
    mov rbp, rsp
    test rsi, rsi
    jz 1f
    mov rdi, rdx
    call rsi
1:  pop rbp
    xor eax, eax
    ret

# is_cancelled(host, signal_token) -> 0 (no cancellation yet)
host_is_cancelled:
    xor eax, eax
    ret

# ------------------------------------------------------------------ events
# on_event(name, handler, userdata): append to the static table, max 32
host_on_event:
    mov rax, [rip + opcode_host_event_count]
    cmp rax, 32
    jae 1f
    lea r8, [rip + opcode_host_events]
    lea r9, [rax + rax*2]
    lea r8, [r8 + r9*8]
    mov [r8], rdi
    mov [r8 + 8], rsi
    mov [r8 + 16], rdx
    inc rax
    mov [rip + opcode_host_event_count], rax
1:  ret

# ------------------------------------------------------------------ json
# json_get_str(json, path, dflt) -> cstr | dflt
host_json_get_str:
    PROLOGUE
    mov r12, rdx
    call json_path
    test rax, rax
    jz 1f
    mov rdi, rax
    call json_str_cstr
    test rax, rax
    jnz 2f
1:  mov rax, r12
2:  EPILOGUE

# json_get_int(json, path, dflt) -> i64 | dflt (signed; whole token must parse)
host_json_get_int:
    PROLOGUE
    mov r12, rdx
    call json_path
    test rax, rax
    jz .Lgi_dflt
    cmp dword ptr [rax + JV_type], JT_NUM
    jne .Lgi_dflt
    mov r13, [rax + JV_ptr]
    mov r14d, [rax + JV_n]
    xor r15d, r15d
    mov rdi, r13
    mov esi, r14d
    cmp byte ptr [r13], '-'
    jne 1f
    mov r15d, 1
    inc rdi
    dec esi
1:  call parse_u64
    test rdx, rdx
    jz .Lgi_dflt
    mov rcx, r14
    test r15d, r15d
    jz 2f
    dec rcx
2:  cmp rdx, rcx
    jne .Lgi_dflt
    test r15d, r15d
    jz 3f
    neg rax
3:  EPILOGUE
.Lgi_dflt:
    mov rax, r12
    EPILOGUE

# json_get_bool(json, path, dflt) -> 1 | 0 | dflt
host_json_get_bool:
    PROLOGUE
    mov r12, rdx
    call json_path
    test rax, rax
    jz 1f
    mov ecx, [rax + JV_type]
    cmp ecx, JT_TRUE
    je 2f
    cmp ecx, JT_FALSE
    je 3f
1:  mov rax, r12
    EPILOGUE
2:  mov eax, 1
    EPILOGUE
3:  xor eax, eax
    EPILOGUE

# json_escape(s) -> new cstr with JSON string escapes (host allocator)
host_json_escape:
    PROLOGUE 32
    mov r12, rdi
    test r12, r12
    jz .Lje_null
    lea rdi, [rsp]
    xor eax, eax
    mov [rdi + SB_ptr], rax
    mov [rdi + SB_len], rax
    mov [rdi + SB_cap], rax
    xor r13d, r13d
1:  movzx esi, byte ptr [r12 + r13]
    test sil, sil
    jz 2f
    lea rdi, [rsp]
    call esc_push
    inc r13
    jmp 1b
2:  mov r14, [rsp + SB_len]
    lea rdi, [r14 + 1]
    call mem_alloc
    mov rbx, rax
    mov rdi, rbx
    mov rsi, [rsp + SB_ptr]
    mov rdx, r14
    call memcpy
    mov byte ptr [rbx + r14], 0
    lea rdi, [rsp]
    call sb_free
    mov rax, rbx
    EPILOGUE
.Lje_null:
    xor eax, eax
    EPILOGUE

# ------------------------------------------------------------------ session
# cwd(host) -> cstr into a static buffer (valid until the next call)
host_cwd:
    PROLOGUE
    lea rdi, [rip + .Lcwd_buf]
    mov esi, 4096
    call os_getcwd
    test rax, rax
    jle 1f
    lea rax, [rip + .Lcwd_buf]
    EPILOGUE
1:  xor eax, eax
    EPILOGUE

# session_id/session_file/system_prompt: not wired in M6
host_session_id:
    xor eax, eax
    ret
host_session_file:
    xor eax, eax
    ret
host_system_prompt:
    xor eax, eax
    ret

# append_entry(custom_type, data_json): write through the live session when set
host_append_entry:
    mov rax, [rip + g_agent_session]
    test rax, rax
    jz 1f
    mov rdx, rsi
    mov rsi, rdi
    mov rdi, rax
    jmp session_append_custom
1:  xor eax, eax
    ret

# ------------------------------------------------------------------ ui
# notify(message, level): "opcode: <msg>\n" on stderr
host_notify:
    PROLOGUE
    mov r12, rdi
    test r12, r12
    jz 1f
    lea rdi, [rip + .Lopcode_prefix]
    call log_cstr
    mov rdi, r12
    call log_cstr
    call log_nl
1:  EPILOGUE

# set_status/set_title: no-ops without a TUI
host_set_status:
    xor eax, eax
    ret
host_set_title:
    xor eax, eax
    ret

# register_command(name, description, handler): static table, max 32
host_register_command:
    mov rax, [rip + opcode_host_command_count]
    cmp rax, 32
    jae 1f
    lea r8, [rip + opcode_host_commands]
    lea r9, [rax + rax*2]
    lea r8, [r8 + r9*8]
    mov [r8], rdi
    mov [r8 + 8], rsi
    mov [r8 + 16], rdx
    inc rax
    mov [rip + opcode_host_command_count], rax
1:  ret

# ------------------------------------------------------------------ model / http
host_set_model:
    xor eax, eax
    ret
host_set_thinking_level:
    xor eax, eax
    ret
# outbound HTTP is M7 (no async transport in the static build yet)
host_http_request:
    xor eax, eax
    ret
host_http_cancel:
    xor eax, eax
    ret

# ------------------------------------------------------------------ vtable
.section .data
.p2align 3
.globl opcode_host_v1
opcode_host_v1:
    .long OPCODE_HOST_ABI
    .long OPCODE_HOST_SIZE
    .quad mem_alloc             # alloc
    .quad mem_free              # free
    .quad host_strdup           # strdup_
    .quad host_log              # log
    .quad host_register_tool    # register_tool
    .quad host_tool_done        # tool_done
    .quad host_defer            # defer
    .quad host_is_cancelled     # is_cancelled
    .quad host_on_event         # on_event
    .quad host_json_get_str     # json_get_str
    .quad host_json_get_int     # json_get_int
    .quad host_json_get_bool    # json_get_bool
    .quad host_json_escape      # json_escape
    .quad host_cwd              # cwd
    .quad host_session_id       # session_id
    .quad host_session_file     # session_file
    .quad host_append_entry     # append_entry
    .quad host_system_prompt    # system_prompt
    .quad host_notify           # notify
    .quad host_set_status       # set_status
    .quad host_set_title        # set_title
    .quad host_register_command # register_command
    .quad host_set_model        # set_model
    .quad host_set_thinking_level # set_thinking_level
    .quad host_http_request     # http_request
    .quad host_http_cancel      # http_cancel
    .zero 64                    # reserved[8]

.text
# opcode_host() -> OpcodeHostV1*
FN opcode_host
    lea rax, [rip + opcode_host_v1]
    ret
