.include "opcode.inc"
.include "core/core.inc"
# ext/mcp.s: minimal MCP (Model Context Protocol) stdio client.
#
# mcp_start() reads the user-level <config dir>/mcp.jsonc always, and the
# project-level <cwd>/.opcode/mcp.jsonc only when config_trusted(cwd) is set
# (g_config_approve wins; same gate as config_load), so an untrusted clone
# cannot spawn attacker commands at startup
# ({"servers":{"<name>":{"command":"...","args":[...],"env":{...}}}}), spawns
# each stdio server, performs the JSON-RPC 2.0 initialize/initialized/tools/list
# handshake (blocking, 10 s deadline; this runs before the UI starts) and
# registers every tool as `mcp__<server>__<tool>` (<=64 chars, lowercased,
# non [a-z0-9_] mapped to '_'). HTTP {"url":...} entries are ignored.
#
# Registered tools execute synchronously inside TL_exec: send tools/call, block
# (10 s deadline) until the matching id, join result.content[].text with "\n"
# and complete the job. A dead server or a timeout becomes an error result.
# mcp_start() is a no-op returning 0 when no config file exists.
#
# Contract: src/core/API.md. Call after tools_init() (agent_init).

.equ MCP_MAX_SERVERS, 8
.equ MCP_MAX_TOOLS,   32
.equ MCP_TIMEOUT_MS,  10000
.equ MCP_BUF_MAX,     1048576
.equ MCP_READ_CHUNK,  8192
.equ F_SETFL,         4
.equ SIGKILL,         9
.equ MCP_WRITE_NS,    10000000000   # per-request write deadline (10 s)

# per-server state: pid, request fd (child stdin), response fd (child stdout),
# next JSON-RPC id, partial-line buffer, sanitized name, live flag.
STRUCT
F SP_pid, 8
F SP_in, 8
F SP_out, 8
F SP_next, 8
F SP_buf, SB_SIZE
F SP_name, 8
F SP_ok, 4
F SP_pad, 4
ENDSTRUCT SP_SIZE

# TL* -> (server index, original tool name) for tools/call dispatch.
STRUCT
F TM_tl, 8
F TM_srv, 4
F TM_pad, 4
F TM_name, 8
ENDSTRUCT TM_SIZE

.section .rodata
.Lservers:     .asciz "servers"
.Lcommand:     .asciz "command"
.Largs:        .asciz "args"
.Lenv:         .asciz "env"
.Lname:        .asciz "name"
.Ldescription: .asciz "description"
.LinputSchema: .asciz "inputSchema"
.Ltools:       .asciz "tools"
.Lresult:      .asciz "result"
.Lerror:       .asciz "error"
.Lmessage:     .asciz "message"
.Lcontent:     .asciz "content"
.Ltext:        .asciz "text"
.Ltype:        .asciz "type"
.Lid:          .asciz "id"
.LisError:     .asciz "isError"
.Ljsonrpc:     .asciz "jsonrpc"
.Lv2:          .asciz "2.0"
.Lmethod:      .asciz "method"
.Lparams:      .asciz "params"
.Ltools_call:  .asciz "tools/call"
.Larguments:   .asciz "arguments"
.Ldevnull:     .asciz "/dev/null"
.Lpath_env:    .asciz "PATH"
.Lmcp_name:    .asciz "/mcp.jsonc"
.Lproj_name:   .asciz "/.opcode/mcp.jsonc"
.Lempty_obj:   .asciz "{}"
.Lempty:       .asciz ""
.Linit_msg:
    .ascii "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":"
    .ascii "{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},"
    .asciz "\"clientInfo\":{\"name\":\"opcode\",\"version\":\"0.1\"}}}"
.Linitialized_msg:
    .asciz "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"
.Llist_msg:
    .asciz "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}"
.Lerr_prefix:   .asciz "error: "
.Lerr_timeout:  .asciz "mcp: server timed out"
.Lerr_closed:   .asciz "mcp: server closed the connection"
.Lerr_io:       .asciz "mcp: server I/O error"
.Lerr_big:      .asciz "mcp: response line too long"
.Lerr_unknown:  .asciz "unknown mcp tool"
.Lerr_dead:     .asciz "mcp: server is not running"
.Lerr_write:    .asciz "mcp: cannot write to server"
.Lerr_rpc:      .asciz "mcp: rpc error"

.section .bss
.p2align 3
mcp_servers: .zero SP_SIZE * MCP_MAX_SERVERS
mcp_nsrv:    .quad 0
mcp_tmap:    .zero TM_SIZE * MCP_MAX_TOOLS
mcp_nmap:    .quad 0
mcp_msgbuf:  .zero SB_SIZE
mcp_schema_sb: .zero SB_SIZE
mcp_readbuf: .zero MCP_READ_CHUNK
mcp_parsebuf: .zero MCP_BUF_MAX + 1
mcp_last_err: .quad 0

.text

# cstr_eq(a, b) -> 1 | 0 (leaf)
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

# mcp_san(dst, src cstr, max) -> rax = dst + copied. Copies src lowercased,
# mapping every byte outside [a-z0-9_] to '_'; stops at max bytes or NUL.
mcp_san:
    xor ecx, ecx
.Lsn_loop:
    cmp rcx, rdx
    jae .Lsn_done
    movzx eax, byte ptr [rsi + rcx]
    test al, al
    jz .Lsn_done
    mov r8d, eax
    cmp al, 'A'
    jb .Lsn_low
    cmp al, 'Z'
    ja .Lsn_low
    add r8d, 32
    jmp .Lsn_put
.Lsn_low:
    cmp al, 'a'
    jb .Lsn_dig
    cmp al, 'z'
    jbe .Lsn_put
.Lsn_dig:
    cmp al, '0'
    jb .Lsn_us
    cmp al, '9'
    jbe .Lsn_put
.Lsn_us:
    cmp al, '_'
    je .Lsn_put
    mov r8d, '_'
.Lsn_put:
    mov [rdi + rcx], r8b
    inc rcx
    jmp .Lsn_loop
.Lsn_done:
    lea rax, [rdi + rcx]
    ret

# mcp_build_name(dst, server cstr, tool cstr) -> len. Emits
# "mcp__<server>__<tool>", sanitized and capped at 64 bytes; dst needs 65.
mcp_build_name:
    PROLOGUE 0
    mov rbx, rdi
    mov r11, rsi
    mov r12, rdx
    mov dword ptr [rbx], 0x5f70636d      # "mcp_"
    mov byte ptr [rbx + 4], '_'
    lea rdi, [rbx + 5]
    mov rsi, r11
    mov edx, 57                          # leaves room for "__"
    call mcp_san
    mov word ptr [rax], 0x5f5f           # "__"
    add rax, 2
    mov rdi, rax
    mov rsi, r12
    lea rdx, [rbx + 64]
    sub rdx, rax
    call mcp_san
    mov byte ptr [rax], 0
    sub rax, rbx
    EPILOGUE

# mcp_ser(sb, jv): serialize a parsed JV tree back to JSON (for inputSchema).
mcp_ser:
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    test r12, r12
    jz .Lse_null
    mov eax, [r12 + JV_type]
    cmp eax, JT_NULL
    je .Lse_null
    cmp eax, JT_TRUE
    je .Lse_true
    cmp eax, JT_FALSE
    je .Lse_false
    cmp eax, JT_NUM
    je .Lse_num
    cmp eax, JT_STR
    je .Lse_str
    cmp eax, JT_ARR
    je .Lse_arr
    cmp eax, JT_OBJ
    je .Lse_obj
.Lse_null:
    mov rdi, rbx
    call jsonw_null
    EPILOGUE
.Lse_true:
    mov rdi, rbx
    mov esi, 1
    call jsonw_bool
    EPILOGUE
.Lse_false:
    mov rdi, rbx
    xor esi, esi
    call jsonw_bool
    EPILOGUE
.Lse_num:
    mov rdi, rbx
    mov rsi, [r12 + JV_ptr]
    mov edx, [r12 + JV_n]
    call jsonw_raw
    EPILOGUE
.Lse_str:
    mov rdi, rbx
    mov rsi, [r12 + JV_ptr]
    mov edx, [r12 + JV_n]
    call jsonw_str
    EPILOGUE
.Lse_arr:
    mov rdi, rbx
    call jsonw_arr
    xor r13d, r13d
1:  cmp r13d, [r12 + JV_n]
    jae 2f
    mov rdi, r12
    mov esi, r13d
    call json_at
    mov rdi, rbx
    mov rsi, rax
    call mcp_ser
    inc r13d
    jmp 1b
2:  mov rdi, rbx
    call jsonw_arr_end
    EPILOGUE
.Lse_obj:
    mov rdi, rbx
    call jsonw_obj
    xor r13d, r13d
1:  cmp r13d, [r12 + JV_n]
    jae 2f
    mov rax, [r12 + JV_ptr]          # object pairs: key,value at i*16
    mov rcx, r13
    shl rcx, 4
    mov rdi, [rax + rcx]
    call json_str
    mov rdi, rbx
    mov rsi, rax
    call jsonw_key_n
    mov rax, [r12 + JV_ptr]
    mov rcx, r13
    shl rcx, 4
    mov rdi, [rax + rcx + 8]
    mov rsi, rdi
    mov rdi, rbx
    call mcp_ser
    inc r13d
    jmp 1b
2:  mov rdi, rbx
    call jsonw_obj_end
    EPILOGUE

# mcp_job_err(job, msg): "error: <msg>" into J_out, flag error, complete.
mcp_job_err:
    PROLOGUE 0
    mov rbx, rdi
    mov r12, rsi
    mov rdi, [rbx + J_out]
    call sb_clear
    mov rdi, [rbx + J_out]
    lea rsi, [rip + .Lerr_prefix]
    call sb_push_cstr
    mov rdi, [rbx + J_out]
    mov rsi, r12
    call sb_push_cstr
    mov dword ptr [rbx + J_flags], JF_ERROR
    mov rdi, rbx
    call tool_done
    xor eax, eax
    EPILOGUE

# mcp_env_build(spec JV*) -> envp. Parent env plus the server's "env" object
# ("KEY":"value", values copied verbatim); returns g_envp when there is none.
mcp_env_build:
    PROLOGUE 96
    mov qword ptr [rsp], 0
    lea rsi, [rip + .Lenv]
    call json_get
    test rax, rax
    jz .Leb_parent
    cmp dword ptr [rax + JV_type], JT_OBJ
    jne .Leb_parent
    mov r13, rax
    mov rdi, r13
    call json_len
    test rax, rax
    jz .Leb_parent
    mov r14, rax                        # pair count
    mov rax, [rip + g_envp]
    xor r12d, r12d
1:  test rax, rax
    jz 2f
    cmp qword ptr [rax + r12*8], 0
    je 2f
    inc r12
    jmp 1b
2:  lea rdi, [r12 + r14 + 1]
    shl rdi, 3
    call mem_alloc
    mov rbx, rax
    mov [rsp + 8], rax
    mov qword ptr [rsp], 1
    mov rdi, rax
    mov rsi, [rip + g_envp]
    mov rdx, r12
    shl rdx, 3
    call memcpy
    mov r15, r12                        # out index
    mov qword ptr [rsp + 16], 0
3:  mov rcx, [rsp + 16]
    cmp rcx, r14
    jae 6f
    mov rax, [r13 + JV_ptr]          # object pairs: key at i*16, value at +8
    mov rdx, rcx
    shl rdx, 4
    mov rdi, [rax + rdx]
    call json_str
    test rax, rax
    jz .Leb_next
    mov [rsp + 24], rax
    mov [rsp + 32], rdx
    mov rcx, [rsp + 16]
    mov rax, [r13 + JV_ptr]
    mov rdx, rcx
    shl rdx, 4
    mov rdi, [rax + rdx + 8]
    call json_str
    test rax, rax
    jz .Leb_next
    mov [rsp + 40], rax
    mov [rsp + 48], rdx
    mov rdi, [rsp + 32]
    add rdi, [rsp + 48]
    add rdi, 2
    call mem_alloc
    mov [rsp + 56], rax
    mov rdi, rax
    mov rsi, [rsp + 24]
    mov rdx, [rsp + 32]
    call memcpy
    mov rcx, [rsp + 32]
    mov byte ptr [rax + rcx], '='
    lea rdi, [rax + rcx + 1]
    mov rsi, [rsp + 40]
    mov rdx, [rsp + 48]
    call memcpy
    mov rax, [rsp + 56]
    mov rcx, [rsp + 32]
    add rcx, [rsp + 48]
    mov byte ptr [rax + rcx + 1], 0
    mov rcx, [rsp + 8]
    mov [rcx + r15*8], rax
    inc r15
.Leb_next:
    inc qword ptr [rsp + 16]
    jmp 3b
6:  mov rax, [rsp + 8]
    mov qword ptr [rax + r15*8], 0
    EPILOGUE
.Leb_parent:
    mov rax, [rip + g_envp]
    EPILOGUE

# mcp_env_free(envp): release a table built by mcp_env_build (no-op for g_envp).
mcp_env_free:
    PROLOGUE 0
    test rdi, rdi
    jz .Lef_done
    cmp rdi, [rip + g_envp]
    je .Lef_done
    mov rbx, rdi
    mov rax, [rip + g_envp]
    xor r12d, r12d
1:  test rax, rax
    jz 2f
    cmp qword ptr [rax + r12*8], 0
    je 2f
    inc r12
    jmp 1b
2:  mov r13, r12
3:  mov rdi, [rbx + r13*8]
    test rdi, rdi
    jz 4f
    call mem_free
    inc r13
    jmp 3b
4:  mov rdi, rbx
    call mem_free
.Lef_done:
    xor eax, eax
    EPILOGUE

# mcp_env_get(name cstr) -> value cstr | 0 (leaf)
mcp_env_get:
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

# mcp_find_exe(cmd cstr) -> mem_alloc'd path | 0. execve(2) does not search
# PATH, so a bare command name is resolved against $PATH (first existing file).
# Returns 0 when the command already contains '/' or is not found.
mcp_find_exe:
    PROLOGUE 96
    mov r12, rdi
    mov rsi, r12
1:  mov al, [rsi]
    test al, al
    jz 2f
    cmp al, '/'
    je .Lfe_none
    inc rsi
    jmp 1b
2:  lea rdi, [rip + .Lpath_env]
    call mcp_env_get
    test rax, rax
    jz .Lfe_none
    mov r13, rax
    mov rdi, r12
    call strlen
    mov r14, rax                        # command length
.Lfe_seg:
    mov r15, r13
3:  mov al, [r15]
    test al, al
    jz 4f
    cmp al, ':'
    je 4f
    inc r15
    jmp 3b
4:  mov rbx, r15
    sub rbx, r13                        # segment length
    lea rdi, [rbx + r14 + 2]
    call mem_alloc
    mov [rsp], rax
    test rbx, rbx
    jz 5f
    mov rdi, rax
    mov rsi, r13
    mov rdx, rbx
    call memcpy
    mov rax, [rsp]
    add rax, rbx
    mov byte ptr [rax], '/'
    inc rax
    jmp 6f
5:  mov rax, [rsp]
    mov byte ptr [rax], '.'
    mov byte ptr [rax + 1], '/'
    add rax, 2
6:  mov [rsp + 8], rax
    mov rdi, rax
    mov rsi, r12
    mov rdx, r14
    call memcpy
    mov rax, [rsp + 8]
    add rax, r14
    mov byte ptr [rax], 0
    mov rdi, [rsp]
    mov esi, O_RDONLY | O_CLOEXEC
    xor edx, edx
    call os_open
    test rax, rax
    js .Lfe_miss
    mov edi, eax
    call os_close
    mov rdi, [rsp]
    call strlen
    mov rsi, rax
    mov rdi, [rsp]
    call mem_dup
    mov [rsp + 16], rax
    mov rdi, [rsp]
    call mem_free
    mov rax, [rsp + 16]
    EPILOGUE
.Lfe_miss:
    mov rdi, [rsp]
    call mem_free
    mov r13, r15
    cmp byte ptr [r13], 0
    je .Lfe_none
    inc r13
    jmp .Lfe_seg
.Lfe_none:
    xor eax, eax
    EPILOGUE

# mcp_write_all(fd, ptr, len) -> 0 | -errno
# Non-blocking write with a deadline, so a server that stops reading cannot
# wedge the agent (the plain write_all would block on a full pipe).
mcp_write_all:
    PROLOGUE 32
    mov r12d, edi
    mov r13, rsi
    mov r14, rdx
    mov edi, CLOCK_MONOTONIC
    call os_now_ns
    mov rcx, MCP_WRITE_NS
    add rax, rcx
    mov [rsp], rax                     # deadline ns
    mov dword ptr [rsp + 8], r12d      # pollfd.fd
    mov word ptr [rsp + 12], POLLOUT
    mov word ptr [rsp + 14], 0
.Lmwa_loop:
    test r14, r14
    jz .Lmwa_ok
    mov edi, r12d
    mov rsi, r13
    mov rdx, r14
    call os_write
    test rax, rax
    js .Lmwa_neg
    add r13, rax
    sub r14, rax
    jmp .Lmwa_loop
.Lmwa_neg:
    cmp rax, -EINTR
    je .Lmwa_loop
    cmp rax, -EAGAIN
    jne .Lmwa_ret
    mov edi, CLOCK_MONOTONIC
    call os_now_ns
    mov rcx, [rsp]
    sub rcx, rax
    jbe .Lmwa_timeout
    mov rax, rcx
    xor edx, edx
    mov ecx, 1000000
    div rcx
    lea rdi, [rsp + 8]
    mov esi, 1
    mov rdx, rax
    call os_poll
    test rax, rax
    js .Lmwa_perr
    jmp .Lmwa_loop
.Lmwa_perr:
    cmp rax, -EINTR
    je .Lmwa_loop
    EPILOGUE
.Lmwa_timeout:
    mov rax, -ETIMEDOUT
.Lmwa_ret:
    EPILOGUE
.Lmwa_ok:
    xor eax, eax
    EPILOGUE

# mcp_spawn(idx, spec JV*) -> 0 | -errno. Two pipes (stdin/stdout), stderr to
# /dev/null; the child's stdin read end is switched back to blocking because
# os_pipe marks the read end O_NONBLOCK.
mcp_spawn:
    PROLOGUE 128
    mov r12, rdi
    mov r13, rsi
    mov qword ptr [rsp + 64], 0
    lea rdi, [rsp]
    call os_pipe
    test rax, rax
    js .Lsp_ret
    lea rdi, [rsp + 8]
    call os_pipe
    test rax, rax
    js .Lsp_close_in
    lea rdi, [rip + .Ldevnull]
    mov esi, O_WRONLY
    xor edx, edx
    call os_open
    test rax, rax
    js .Lsp_close_pipes
    mov [rsp + 16], rax
    mov edi, [rsp]
    mov esi, F_SETFL
    xor edx, edx
    call os_fcntl
    # command
    mov rdi, r13
    lea rsi, [rip + .Lcommand]
    call json_get_cstr
    test rax, rax
    jz .Lsp_bad_args
    mov [rsp + 24], rax
    mov rdi, rax
    call mcp_find_exe
    mov [rsp + 64], rax
    test rax, rax
    jz .Lsp_have_cmd
    mov [rsp + 24], rax
.Lsp_have_cmd:
    # argv = { command, args..., 0 }
    mov rdi, r13
    lea rsi, [rip + .Largs]
    call json_get
    mov r14, rax
    xor r15d, r15d
    test r14, r14
    jz 1f
    cmp dword ptr [r14 + JV_type], JT_ARR
    jne 1f
    mov rdi, r14
    call json_len
    mov r15, rax
1:  lea rdi, [r15 + 2]
    shl rdi, 3
    call mem_alloc
    mov [rsp + 32], rax
    mov rcx, [rsp + 24]
    mov [rax], rcx
    mov qword ptr [rsp + 40], 0
    xor ebx, ebx
2:  cmp rbx, r15
    jae 3f
    mov rdi, r14
    mov esi, ebx
    call json_at
    test rax, rax
    jz 21f
    mov rdi, rax
    call json_str_cstr
    test rax, rax
    jz 21f
    mov rcx, [rsp + 32]
    mov rdx, [rsp + 40]
    mov [rcx + rdx*8 + 8], rax
    inc qword ptr [rsp + 40]
21: inc rbx
    jmp 2b
3:  mov rcx, [rsp + 32]
    mov rdx, [rsp + 40]
    mov qword ptr [rcx + rdx*8 + 8], 0
    # environment
    mov rdi, r13
    call mcp_env_build
    mov [rsp + 48], rax
    # spawn
    mov r14, [rsp + 32]
    mov r15, [rsp + 48]
    mov r10d, [rsp]
    mov r11d, [rsp + 12]
    mov eax, [rsp + 16]
    sub rsp, 16
    mov qword ptr [rsp], 0
    mov rdi, r14
    mov rsi, r15
    xor edx, edx
    mov ecx, r10d
    mov r8d, r11d
    mov r9d, eax
    call os_spawn
    add rsp, 16
    mov [rsp + 56], rax
    mov edi, [rsp + 4]                # make the request pipe non-blocking so
    mov esi, F_SETFL                  # mcp_write_all can enforce a deadline
    mov edx, O_NONBLOCK
    call os_fcntl
    mov edi, [rsp]
    call os_close
    mov edi, [rsp + 12]
    call os_close
    mov edi, [rsp + 16]
    call os_close
    mov rdi, [rsp + 32]
    call mem_free
    mov rdi, [rsp + 48]
    call mcp_env_free
    mov rdi, [rsp + 64]
    call mem_free
    mov rax, [rsp + 56]
    test rax, rax
    js .Lsp_ret
    mov rcx, r12
    imul rcx, rcx, SP_SIZE
    lea rdx, [rip + mcp_servers]
    add rdx, rcx
    mov [rdx + SP_pid], rax
    mov eax, [rsp + 4]
    mov [rdx + SP_in], rax
    mov eax, [rsp + 8]
    mov [rdx + SP_out], rax
    mov qword ptr [rdx + SP_next], 3
    mov dword ptr [rdx + SP_ok], 1
    xor eax, eax
    EPILOGUE
.Lsp_close_in:
    mov r14, rax
    mov edi, [rsp]
    call os_close
    mov edi, [rsp + 4]
    call os_close
    mov rax, r14
    EPILOGUE
.Lsp_close_pipes:
    mov r14, rax
    mov edi, [rsp]
    call os_close
    mov edi, [rsp + 4]
    call os_close
    mov edi, [rsp + 8]
    call os_close
    mov edi, [rsp + 12]
    call os_close
    mov rax, r14
    EPILOGUE
.Lsp_bad_args:
    mov edi, [rsp]
    call os_close
    mov edi, [rsp + 4]
    call os_close
    mov edi, [rsp + 8]
    call os_close
    mov edi, [rsp + 12]
    call os_close
    mov edi, [rsp + 16]
    call os_close
    mov rdi, [rsp + 64]
    call mem_free
    mov rax, -EINVAL
.Lsp_ret:
    EPILOGUE

# mcp_read_msg(srv*, want_id) -> JV* | 0. Blocks until a complete JSON line
# whose "id" equals want_id, skipping notifications/other responses. The line
# is copied to mcp_parsebuf before parsing so raw number pointers survive the
# buffer compaction (callers must consume the tree before the next call).
mcp_read_msg:
    PROLOGUE 96
    mov rbx, rdi
    mov r12, rsi
    mov edi, CLOCK_MONOTONIC
    call os_now_ns
    mov r13, MCP_TIMEOUT_MS
    imul r13, r13, 1000000
    add r13, rax
.Lrm_loop:
    mov rsi, [rbx + SP_buf + SB_ptr]
    mov rcx, [rbx + SP_buf + SB_len]
    test rsi, rsi
    jz .Lrm_read
    test rcx, rcx
    jz .Lrm_read
    xor edx, edx
.Lrm_scan:
    cmp rdx, rcx
    jae .Lrm_read
    cmp byte ptr [rsi + rdx], 10
    je .Lrm_line
    inc rdx
    jmp .Lrm_scan
.Lrm_line:
    mov [rsp], rdx
    mov r14, rdx
    test r14, r14
    jz 1f
    cmp byte ptr [rsi + r14 - 1], 13
    jne 1f
    dec r14
1:  cmp r14, MCP_BUF_MAX
    jae .Lrm_big
    lea rdi, [rip + mcp_parsebuf]
    mov rdx, r14
    call memcpy
    lea rcx, [rip + mcp_parsebuf]
    mov byte ptr [rcx + r14], 0
    # consume newline index + 1 bytes from the server buffer
    mov rcx, [rsp]
    inc rcx
    mov rax, [rbx + SP_buf + SB_len]
    sub rax, rcx
    mov [rsp + 8], rax
    mov rdi, [rbx + SP_buf + SB_ptr]
    mov rsi, rdi
    add rsi, rcx
    mov rdx, rax
    call memmove
    mov rax, [rsp + 8]
    mov [rbx + SP_buf + SB_len], rax
    mov rdx, [rbx + SP_buf + SB_ptr]
    mov byte ptr [rdx + rax], 0
    lea rdi, [rip + mcp_parsebuf]
    mov rsi, r14
    call json_parse
    mov r15, rax
    test r15, r15
    jz .Lrm_loop
    mov rdi, r15
    lea rsi, [rip + .Lid]
    call json_get
    test rax, rax
    jz .Lrm_loop
    cmp dword ptr [rax + JV_type], JT_NUM
    jne .Lrm_loop
    mov rdi, [rax + JV_ptr]
    mov esi, [rax + JV_n]
    call parse_u64
    test rdx, rdx
    jz .Lrm_loop
    cmp rax, r12
    jne .Lrm_loop
    mov rax, r15
    EPILOGUE
.Lrm_read:
    mov edi, CLOCK_MONOTONIC
    call os_now_ns
    cmp rax, r13
    jb .Lrm_poll
    lea rax, [rip + .Lerr_timeout]
    mov [rip + mcp_last_err], rax
    xor eax, eax
    EPILOGUE
.Lrm_poll:
    mov rcx, r13
    sub rcx, rax
    mov rax, rcx
    xor edx, edx
    mov ecx, 1000000
    div rcx
    test rax, rax
    jnz 2f
    mov eax, 1
2:  mov [rsp + 16], rax
    mov eax, [rbx + SP_out]
    mov [rsp + 24], eax
    mov word ptr [rsp + 28], POLLIN
    mov word ptr [rsp + 30], 0
    lea rdi, [rsp + 24]
    mov esi, 1
    mov edx, [rsp + 16]
    call os_poll
    test rax, rax
    js .Lrm_poll_err
    jz .Lrm_loop
    mov edi, [rbx + SP_out]
    lea rsi, [rip + mcp_readbuf]
    mov edx, MCP_READ_CHUNK
    call os_read
    test rax, rax
    js .Lrm_read_err
    jz .Lrm_eof
    mov rcx, [rbx + SP_buf + SB_len]
    add rcx, rax
    cmp rcx, MCP_BUF_MAX
    ja .Lrm_big
    lea rdi, [rbx + SP_buf]
    lea rsi, [rip + mcp_readbuf]
    mov rdx, rax
    call sb_push
    jmp .Lrm_loop
.Lrm_eof:
    lea rax, [rip + .Lerr_closed]
    mov [rip + mcp_last_err], rax
    xor eax, eax
    EPILOGUE
.Lrm_big:
    lea rax, [rip + .Lerr_big]
    mov [rip + mcp_last_err], rax
    xor eax, eax
    EPILOGUE
.Lrm_poll_err:
    cmp rax, -EINTR
    je .Lrm_loop
    lea rax, [rip + .Lerr_io]
    mov [rip + mcp_last_err], rax
    xor eax, eax
    EPILOGUE
.Lrm_read_err:
    cmp rax, -EAGAIN
    je .Lrm_loop
    cmp rax, -EINTR
    je .Lrm_loop
    lea rax, [rip + .Lerr_io]
    mov [rip + mcp_last_err], rax
    xor eax, eax
    EPILOGUE

# mcp_register_tools(srv_idx, root): register root.result.tools[] as TLs.
mcp_register_tools:
    PROLOGUE 160
    mov r12, rdi
    mov r13, rsi
    mov rcx, r12
    imul rcx, rcx, SP_SIZE
    lea rbx, [rip + mcp_servers]
    add rbx, rcx
    mov rdi, r13
    lea rsi, [rip + .Lresult]
    call json_get
    test rax, rax
    jz .Lrt_done
    mov rdi, rax
    lea rsi, [rip + .Ltools]
    call json_get
    test rax, rax
    jz .Lrt_done
    cmp dword ptr [rax + JV_type], JT_ARR
    jne .Lrt_done
    mov r14, rax
    mov qword ptr [rsp + 96], 0
.Lrt_loop:
    mov rax, [rsp + 96]
    cmp eax, [r14 + JV_n]
    jae .Lrt_done
    mov rdi, r14
    mov esi, eax
    call json_at
    test rax, rax
    jz .Lrt_next
    mov r13, rax
    mov rdi, r13
    lea rsi, [rip + .Lname]
    call json_get_cstr
    test rax, rax
    jz .Lrt_next
    mov [rsp + 104], rax
    mov rdi, r13
    lea rsi, [rip + .Ldescription]
    call json_get_cstr
    mov [rsp + 112], rax
    mov rdi, r13
    lea rsi, [rip + .LinputSchema]
    call json_get
    mov [rsp + 120], rax
    lea rdi, [rsp]
    mov rsi, [rbx + SP_name]
    mov rdx, [rsp + 104]
    call mcp_build_name
    lea rdi, [rip + mcp_schema_sb]
    call sb_clear
    mov rsi, [rsp + 120]
    test rsi, rsi
    jz 1f
    lea rdi, [rip + mcp_schema_sb]
    call mcp_ser
    jmp 2f
1:  lea rdi, [rip + mcp_schema_sb]
    lea rsi, [rip + .Lempty_obj]
    call sb_push_cstr
2:  mov rdi, [rip + mcp_schema_sb + SB_ptr]
    mov rsi, [rip + mcp_schema_sb + SB_len]
    call mem_dup
    mov [rsp + 136], rax
    mov rdi, [rsp + 112]
    test rdi, rdi
    jnz 3f
    lea rdi, [rip + .Lempty]
3:  call strlen
    mov rsi, rax
    mov rdi, [rsp + 112]
    test rdi, rdi
    jnz 4f
    lea rdi, [rip + .Lempty]
4:  call mem_dup
    mov [rsp + 144], rax
    lea rdi, [rsp]
    call strlen
    mov rdi, rsp
    mov rsi, rax
    call mem_dup
    mov [rsp + 152], rax
    mov edi, TL_SIZE
    call mem_alloc
    mov [rsp + 128], rax
    mov rcx, [rsp + 152]
    mov [rax + TL_name], rcx
    mov [rax + TL_label], rcx
    mov rcx, [rsp + 144]
    mov [rax + TL_desc], rcx
    mov rcx, [rsp + 136]
    mov [rax + TL_params], rcx
    mov dword ptr [rax + TL_flags], 0
    mov dword ptr [rax + TL_pad], 0
    lea rcx, [rip + mcp_exec]
    mov [rax + TL_exec], rcx
    mov qword ptr [rax + TL_finish], 0
    mov rcx, [rip + mcp_nmap]
    cmp rcx, MCP_MAX_TOOLS
    jae .Lrt_cleanup
    mov rdi, [rsp + 128]
    call tools_add
    test eax, eax
    js .Lrt_cleanup
    mov rcx, [rip + mcp_nmap]
    imul rdx, rcx, TM_SIZE
    lea rsi, [rip + mcp_tmap]
    add rsi, rdx
    mov rax, [rsp + 128]
    mov [rsi + TM_tl], rax
    mov [rsi + TM_srv], r12d
    mov rdi, [rsp + 104]
    call strlen
    mov rdi, [rsp + 104]
    mov rsi, rax
    call mem_dup
    mov rsi, [rip + mcp_nmap]
    imul rdx, rsi, TM_SIZE
    lea rsi, [rip + mcp_tmap]
    add rsi, rdx
    mov [rsi + TM_name], rax
    inc qword ptr [rip + mcp_nmap]
.Lrt_next:
    inc qword ptr [rsp + 96]
    jmp .Lrt_loop
.Lrt_cleanup:
    mov rdi, [rsp + 152]
    call mem_free
    mov rdi, [rsp + 144]
    call mem_free
    mov rdi, [rsp + 136]
    call mem_free
    mov rdi, [rsp + 128]
    call mem_free
    jmp .Lrt_next
.Lrt_done:
    xor eax, eax
    EPILOGUE

# mcp_exec(job): tools/call round trip, join content[].text with "\n".
mcp_exec:
    PROLOGUE 96
    mov rbx, rdi
    xor r12d, r12d
1:  cmp r12, [rip + mcp_nmap]
    jae .Lme_unknown
    mov rcx, r12
    imul rcx, rcx, TM_SIZE
    lea rdx, [rip + mcp_tmap]
    add rdx, rcx
    mov rax, [rdx + TM_tl]
    cmp rax, [rbx + J_tool]
    je 2f
    inc r12
    jmp 1b
2:  mov r13, rdx
    mov eax, [r13 + TM_srv]
    imul rax, rax, SP_SIZE
    lea r14, [rip + mcp_servers]
    add r14, rax
    cmp dword ptr [r14 + SP_ok], 0
    je .Lme_dead
    mov r15, [r14 + SP_next]
    lea rax, [r15 + 1]
    mov [r14 + SP_next], rax
    lea rdi, [rip + mcp_msgbuf]
    call sb_clear
    lea rdi, [rip + mcp_msgbuf]
    call jsonw_obj
    lea rdi, [rip + mcp_msgbuf]
    lea rsi, [rip + .Ljsonrpc]
    call jsonw_key
    lea rdi, [rip + mcp_msgbuf]
    lea rsi, [rip + .Lv2]
    call jsonw_str_cstr
    lea rdi, [rip + mcp_msgbuf]
    lea rsi, [rip + .Lid]
    call jsonw_key
    lea rdi, [rip + mcp_msgbuf]
    mov rsi, r15
    call jsonw_u64
    lea rdi, [rip + mcp_msgbuf]
    lea rsi, [rip + .Lmethod]
    call jsonw_key
    lea rdi, [rip + mcp_msgbuf]
    lea rsi, [rip + .Ltools_call]
    call jsonw_str_cstr
    lea rdi, [rip + mcp_msgbuf]
    lea rsi, [rip + .Lparams]
    call jsonw_key
    lea rdi, [rip + mcp_msgbuf]
    call jsonw_obj
    lea rdi, [rip + mcp_msgbuf]
    lea rsi, [rip + .Lname]
    call jsonw_key
    lea rdi, [rip + mcp_msgbuf]
    mov rsi, [r13 + TM_name]
    call jsonw_str_cstr
    lea rdi, [rip + mcp_msgbuf]
    lea rsi, [rip + .Larguments]
    call jsonw_key
    mov rdi, [rbx + J_args]
    test rdi, rdi
    jz 3f
    call strlen
    test rax, rax
    jz 3f
    lea rdi, [rip + mcp_msgbuf]
    mov rsi, [rbx + J_args]
    mov rdx, rax
    call jsonw_raw
    jmp 4f
3:  lea rdi, [rip + mcp_msgbuf]
    lea rsi, [rip + .Lempty_obj]
    mov edx, 2
    call jsonw_raw
4:  lea rdi, [rip + mcp_msgbuf]
    call jsonw_obj_end
    lea rdi, [rip + mcp_msgbuf]
    call jsonw_obj_end
    lea rdi, [rip + mcp_msgbuf]
    mov esi, 10
    call sb_push_byte
    mov rdi, [r14 + SP_in]
    mov rsi, [rip + mcp_msgbuf + SB_ptr]
    mov rdx, [rip + mcp_msgbuf + SB_len]
    call mcp_write_all
    test rax, rax
    jnz .Lme_write
    mov rdi, r14
    mov rsi, r15
    call mcp_read_msg
    test rax, rax
    jz .Lme_rw
    mov r13, rax
    mov rdi, r13
    lea rsi, [rip + .Lresult]
    call json_get
    test rax, rax
    jz .Lme_rpc
    mov r14, rax
    mov rdi, r14
    lea rsi, [rip + .LisError]
    call json_get
    test rax, rax
    jz 5f
    cmp dword ptr [rax + JV_type], JT_TRUE
    jne 5f
    or dword ptr [rbx + J_flags], JF_ERROR
5:  mov rdi, r14
    lea rsi, [rip + .Lcontent]
    call json_get
    test rax, rax
    jz .Lme_done
    cmp dword ptr [rax + JV_type], JT_ARR
    jne .Lme_done
    mov r14, rax
    mov qword ptr [rsp], 0
    mov qword ptr [rsp + 8], 0
6:  mov rax, [rsp]
    cmp eax, [r14 + JV_n]
    jae .Lme_done
    mov rdi, r14
    mov esi, eax
    call json_at
    test rax, rax
    jz 8f
    mov r13, rax
    mov rdi, r13
    lea rsi, [rip + .Ltype]
    call json_get_cstr
    test rax, rax
    jz 8f
    mov rdi, rax
    lea rsi, [rip + .Ltext]
    call cstr_eq
    test eax, eax
    jz 8f
    mov rdi, r13
    lea rsi, [rip + .Ltext]
    call json_get
    test rax, rax
    jz 8f
    mov rdi, rax
    call json_str
    test rax, rax
    jz 8f
    mov [rsp + 16], rax
    mov [rsp + 24], rdx
    cmp qword ptr [rsp + 8], 0
    je 7f
    mov rdi, [rbx + J_out]
    mov esi, 10
    call sb_push_byte
7:  mov rdi, [rbx + J_out]
    mov rsi, [rsp + 16]
    mov rdx, [rsp + 24]
    call sb_push
    mov qword ptr [rsp + 8], 1
8:  inc qword ptr [rsp]
    jmp 6b
.Lme_done:
    mov rdi, rbx
    call tool_done
    xor eax, eax
    EPILOGUE
.Lme_rpc:
    mov rdi, r13
    lea rsi, [rip + .Lerror]
    call json_get
    test rax, rax
    jz .Lme_rpc_generic
    mov rdi, rax
    lea rsi, [rip + .Lmessage]
    call json_get_cstr
    test rax, rax
    jz .Lme_rpc_generic
    mov rsi, rax
    mov rdi, rbx
    call mcp_job_err
    xor eax, eax
    EPILOGUE
.Lme_rpc_generic:
    mov rdi, rbx
    lea rsi, [rip + .Lerr_rpc]
    call mcp_job_err
    xor eax, eax
    EPILOGUE
.Lme_unknown:
    mov rdi, rbx
    lea rsi, [rip + .Lerr_unknown]
    call mcp_job_err
    xor eax, eax
    EPILOGUE
.Lme_dead:
    mov rdi, rbx
    lea rsi, [rip + .Lerr_dead]
    call mcp_job_err
    xor eax, eax
    EPILOGUE
.Lme_write:
    mov rdi, rbx
    lea rsi, [rip + .Lerr_write]
    call mcp_job_err
    xor eax, eax
    EPILOGUE
.Lme_rw:
    mov rsi, [rip + mcp_last_err]
    test rsi, rsi
    jnz 9f
    lea rsi, [rip + .Lerr_io]
9:  mov rdi, rbx
    call mcp_job_err
    xor eax, eax
    EPILOGUE

# mcp_handshake(idx): initialize -> initialized -> tools/list -> register.
mcp_handshake:
    PROLOGUE 0
    mov r12, rdi
    mov rcx, r12
    imul rcx, rcx, SP_SIZE
    lea rbx, [rip + mcp_servers]
    add rbx, rcx
    lea rdi, [rip + mcp_msgbuf]
    call sb_clear
    lea rdi, [rip + mcp_msgbuf]
    lea rsi, [rip + .Linit_msg]
    call sb_push_cstr
    lea rdi, [rip + mcp_msgbuf]
    mov esi, 10
    call sb_push_byte
    mov rdi, [rbx + SP_in]
    mov rsi, [rip + mcp_msgbuf + SB_ptr]
    mov rdx, [rip + mcp_msgbuf + SB_len]
    call mcp_write_all
    test rax, rax
    jnz .Lhs_dead
    mov rdi, rbx
    mov esi, 1
    call mcp_read_msg
    test rax, rax
    jz .Lhs_dead
    lea rdi, [rip + mcp_msgbuf]
    call sb_clear
    lea rdi, [rip + mcp_msgbuf]
    lea rsi, [rip + .Linitialized_msg]
    call sb_push_cstr
    lea rdi, [rip + mcp_msgbuf]
    mov esi, 10
    call sb_push_byte
    mov rdi, [rbx + SP_in]
    mov rsi, [rip + mcp_msgbuf + SB_ptr]
    mov rdx, [rip + mcp_msgbuf + SB_len]
    call mcp_write_all
    test rax, rax
    jnz .Lhs_dead
    lea rdi, [rip + mcp_msgbuf]
    call sb_clear
    lea rdi, [rip + mcp_msgbuf]
    lea rsi, [rip + .Llist_msg]
    call sb_push_cstr
    lea rdi, [rip + mcp_msgbuf]
    mov esi, 10
    call sb_push_byte
    mov rdi, [rbx + SP_in]
    mov rsi, [rip + mcp_msgbuf + SB_ptr]
    mov rdx, [rip + mcp_msgbuf + SB_len]
    call mcp_write_all
    test rax, rax
    jnz .Lhs_dead
    mov rdi, rbx
    mov esi, 2
    call mcp_read_msg
    test rax, rax
    jz .Lhs_dead
    mov rdi, r12
    mov rsi, rax
    call mcp_register_tools
    xor eax, eax
    EPILOGUE
.Lhs_dead:
    mov dword ptr [rbx + SP_ok], 0
    mov rdi, [rbx + SP_in]
    call os_close
    mov rdi, [rbx + SP_out]
    call os_close
    mov rdi, [rbx + SP_pid]
    mov esi, SIGKILL
    call os_kill_group
    mov rdi, [rbx + SP_pid]
    xor esi, esi                    # blocking: reap the child
    call os_wait
    mov qword ptr [rbx + SP_pid], 0
    mov qword ptr [rbx + SP_in], 0
    mov qword ptr [rbx + SP_out], 0
    xor eax, eax
    EPILOGUE

# mcp_load_file(path): parse one mcp.jsonc and spawn its stdio servers.
mcp_load_file:
    PROLOGUE 176
    mov r12, rdi
    xor eax, eax
    mov [rsp + SB_ptr], rax
    mov [rsp + SB_len], rax
    mov [rsp + SB_cap], rax
    mov rdi, r12
    lea rsi, [rsp]
    call config_read_file
    test eax, eax
    jz .Llf_done
    mov rdi, [rsp + SB_ptr]
    mov rsi, [rsp + SB_len]
    call json_parse
    test rax, rax
    jz .Llf_free
    mov rdi, rax
    lea rsi, [rip + .Lservers]
    call json_get
    test rax, rax
    jz .Llf_free
    cmp dword ptr [rax + JV_type], JT_OBJ
    jne .Llf_free
    mov [rsp + 152], rax
    mov qword ptr [rsp + 160], 0
.Llf_loop:
    mov rax, [rip + mcp_nsrv]
    cmp rax, MCP_MAX_SERVERS
    jae .Llf_free
    mov rcx, [rsp + 160]
    mov rdx, [rsp + 152]
    cmp ecx, [rdx + JV_n]
    jae .Llf_free
    mov rax, [rdx + JV_ptr]          # servers pairs: key at i*16
    shl rcx, 4
    mov rdi, [rax + rcx]
    call json_str
    test rax, rax
    jz .Llf_next
    test rdx, rdx
    jz .Llf_next
    cmp rdx, 64
    ja .Llf_next
    mov r8, rax
    mov r9, rdx
    xor ecx, ecx
.Llf_chars:
    cmp rcx, r9
    jae .Llf_name_ok
    movzx eax, byte ptr [r8 + rcx]
    cmp al, 'A'
    jb 1f
    cmp al, 'Z'
    jbe 2f
1:  cmp al, 'a'
    jb 3f
    cmp al, 'z'
    jbe 2f
3:  cmp al, '0'
    jb 4f
    cmp al, '9'
    jbe 2f
4:  cmp al, '_'
    je 2f
    cmp al, '-'
    jne .Llf_next
2:  inc rcx
    jmp .Llf_chars
.Llf_name_ok:
    mov [rsp + 136], r8
    mov rcx, [rsp + 160]
    mov rdx, [rsp + 152]
    mov rax, [rdx + JV_ptr]          # spec is the pair value at i*16+8
    shl rcx, 4
    mov rdi, [rax + rcx + 8]
    test rdi, rdi
    jz .Llf_next
    cmp dword ptr [rdi + JV_type], JT_OBJ
    jne .Llf_next
    mov [rsp + 128], rdi
    mov rdi, [rsp + 128]
    lea rsi, [rip + .Lcommand]
    call json_get
    test rax, rax
    jz .Llf_next
    cmp dword ptr [rax + JV_type], JT_STR
    jne .Llf_next
    mov rdi, [rip + mcp_nsrv]
    mov rsi, [rsp + 128]
    call mcp_spawn
    test rax, rax
    js .Llf_next
    lea rdi, [rsp + 32]
    mov rsi, [rsp + 136]
    mov edx, 64
    call mcp_san
    mov byte ptr [rax], 0
    lea rdi, [rsp + 32]
    call strlen
    mov rdi, rsp
    add rdi, 32
    mov rsi, rax
    call mem_dup
    mov rcx, [rip + mcp_nsrv]
    imul rcx, rcx, SP_SIZE
    lea rdx, [rip + mcp_servers]
    add rdx, rcx
    mov [rdx + SP_name], rax
    inc qword ptr [rip + mcp_nsrv]
.Llf_next:
    inc qword ptr [rsp + 160]
    jmp .Llf_loop
.Llf_free:
    lea rdi, [rsp]
    call sb_free
.Llf_done:
    xor eax, eax
    EPILOGUE

# mcp_handshake_range(start): handshake every server index >= start.
mcp_handshake_range:
    PROLOGUE 0
    mov r12, rdi
1:  cmp r12, [rip + mcp_nsrv]
    jae 2f
    mov rdi, r12
    call mcp_handshake
    inc r12
    jmp 1b
2:  xor eax, eax
    EPILOGUE

# mcp_start() -> 0. Loads the user mcp.jsonc, then the project mcp.jsonc when
# cwd is trusted (config_trusted), and connects.
FN mcp_start
    PROLOGUE 560
    call mcp_shutdown
    call config_user_dir
    test rax, rax
    jz .Lms_project
    mov rdi, rax
    lea rsi, [rip + .Lmcp_name]
    call config_path_join
    test rax, rax
    jz .Lms_project
    mov r12, rax
    mov r13, [rip + mcp_nsrv]
    mov rdi, r12
    call mcp_load_file
    mov rdi, r12
    call mem_free
    mov rdi, r13
    call mcp_handshake_range
    cmp qword ptr [rip + mcp_nsrv], MCP_MAX_SERVERS
    jae .Lms_done
.Lms_project:
    lea rdi, [rsp]
    mov esi, 512
    call os_getcwd
    test rax, rax
    js .Lms_done
    lea rdi, [rsp]                  # project file only when cwd is trusted
    call config_trusted
    test eax, eax
    jz .Lms_done
    lea rdi, [rsp]
    lea rsi, [rip + .Lproj_name]
    call config_path_join
    test rax, rax
    jz .Lms_done
    mov r12, rax
    mov r13, [rip + mcp_nsrv]
    mov rdi, r12
    call mcp_load_file
    mov rdi, r12
    call mem_free
    mov rdi, r13
    call mcp_handshake_range
.Lms_done:
    xor eax, eax
    EPILOGUE

# mcp_shutdown(): kill/reap every live server and release its state (idempotent).
FN mcp_shutdown
    PROLOGUE
    xor r12d, r12d
.Lmsd_loop:
    cmp r12, [rip + mcp_nsrv]
    jae .Lmsd_done
    mov rax, r12
    imul rax, rax, SP_SIZE
    lea rbx, [rip + mcp_servers]
    add rbx, rax
    cmp qword ptr [rbx + SP_pid], 0
    je .Lmsd_next
    mov rdi, [rbx + SP_in]
    call os_close
    mov rdi, [rbx + SP_out]
    call os_close
    mov rdi, [rbx + SP_pid]
    mov esi, SIGKILL
    call os_kill_group
    mov rdi, [rbx + SP_pid]
    xor esi, esi
    call os_wait
    mov qword ptr [rbx + SP_pid], 0
.Lmsd_next:
    mov rdi, [rbx + SP_name]
    call mem_free
    mov qword ptr [rbx + SP_name], 0
    lea rdi, [rbx + SP_buf]
    call sb_free
    inc r12d
    jmp .Lmsd_loop
.Lmsd_done:
    mov qword ptr [rip + mcp_nsrv], 0
    mov qword ptr [rip + mcp_nmap], 0
    EPILOGUE
