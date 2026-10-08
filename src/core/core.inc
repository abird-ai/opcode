# core: shared structs and constants for messages, providers, tools, catalog.
# Included after opcode.inc (which sets Intel syntax). Contract: src/core/API.md.
.intel_syntax noprefix

# ---------------------------------------------------------------- front ends
# src/app/cli.s kind mask: every front end that shares the flag parser.
.equ CK_PRINT, 1
.equ CK_JSON,  2
.equ CK_RPC,   4
.equ CK_TUI,   8
.equ CK_MODES, CK_JSON | CK_RPC
.equ CK_AGENT, CK_PRINT | CK_JSON | CK_RPC | CK_TUI

# ---------------------------------------------------------------- messages
.equ MR_SYSTEM,      0
.equ MR_USER,        1
.equ MR_ASSISTANT,   2
.equ MR_TOOL_RESULT, 3

# ---------------------------------------------------------------- thinking
# Thinking level for reasoning-capable models. opcode uses a monotonic
# 0..3 scale; the CLI/config names are
# "off"/"low"/"medium"/"high". Default off.
.equ TH_OFF,         0
.equ TH_LOW,         1
.equ TH_MEDIUM,      2
.equ TH_HIGH,        3

.equ BT_TEXT,     1
.equ BT_THINK,    2
.equ BT_TOOLCALL, 3

.equ SR_PENDING,  0
.equ SR_STOP,     1
.equ SR_LENGTH,   2
.equ SR_TOOL_USE, 3
.equ SR_ERROR,    4
.equ SR_ABORTED,  5

# Msg: fixed header; M_blocks points to a VEC of Block
STRUCT
F M_role, 4
F M_flags, 4
F M_blocks, 8
F M_stop, 4
F M_pad, 4
F M_usage, 8
F M_call_id, 8              # tool_call id for MR_TOOL_RESULT (cstr, owned)
ENDSTRUCT M_SIZE            # 40

# Block: 24 bytes
STRUCT
F B_type, 4
F B_flags, 4
F B_ptr, 8                  # text bytes | TC*
F B_len, 8
ENDSTRUCT B_SIZE

# ToolCall: 24 bytes; strings owned by the message
STRUCT
F TC_id, 8
F TC_name, 8
F TC_args, 8
ENDSTRUCT TC_SIZE

# Usage: 24 bytes
STRUCT
F USG_input, 4
F USG_output, 4
F USG_cache_read, 4
F USG_cache_write, 4
F USG_total, 4
F USG_pad, 4
ENDSTRUCT USAGE_SIZE

# Transcript: VEC of Msg + a string owner list for tr_free
STRUCT
F TR_msgs, 8                # VEC*
F TR_owned, 8               # VEC* of allocated pointers
ENDSTRUCT TR_SIZE

# ---------------------------------------------------------------- stream sink
# sink fn(rdi=&SS, esi=SE_*, rdx=a, rcx=b)
.equ SE_TEXT,       1       # a=ptr b=len
.equ SE_TEXT_END,   2
.equ SE_THINK,      3       # a=ptr b=len
.equ SE_THINK_END,  4
.equ SE_TOOL_START, 5       # a=id cstr b=name cstr
.equ SE_TOOL_DELTA, 6       # a=ptr b=len
.equ SE_TOOL_END,   7
.equ SE_USAGE,      8       # a=Usage*
.equ SE_DONE,       9       # a=SR_*
.equ SE_ERROR,      10      # a=err cstr
.equ SE_TOOL_RESULT, 11      # a=ptr b=len (UI hook only, legacy)
.equ SE_COMPACT,     12      # a=tokens_before u32, b=kept_messages u32
.equ SE_TOOL_EXEC,   13      # rdx=&TE (full tool-execution record)

# Full tool-execution record handed to the UI hook with SE_TOOL_EXEC.  The
# pointer is valid for the duration of the call only; the UI copies what it
# needs.  `result`/`result_len` are the raw tool output bytes (not NUL
# terminated), `error` is 1 when the job reported MF_ERROR/JF_ERROR, and
# `duration_ms` is measured from tool start with CLOCK_MONOTONIC.
STRUCT
F TE_id, 8                  # cstr call id
F TE_name, 8                # cstr tool name ("?" for an unknown tool)
F TE_args, 8                # cstr raw JSON arguments
F TE_result, 8              # ptr tool output bytes
F TE_result_len, 8          # u64 output byte count
F TE_error, 4               # u32 1 on error
F TE_duration_ms, 4         # u32 elapsed ms
ENDSTRUCT TE_SIZE            # 40

STRUCT
F SS_fn, 8
F SS_ctx, 8
ENDSTRUCT SS_SIZE

# ---------------------------------------------------------------- model catalog
.equ MDF_REASONING, 1
.equ MDF_IMAGE,     2
.equ MDF_NO_KEY,    4       # no API key required (local providers)
.equ MDF_DEFAULT,  8       # preferred model when a provider has no default_model

STRUCT
F MD_id, 8                  # cstr
F MD_name, 8                # cstr
F MD_api, 8                 # cstr: "anthropic-messages" | "openai-chat"
F MD_provider, 8            # cstr
F MD_base, 8                # base url cstr
F MD_ctx_window, 4
F MD_max_tokens, 4
F MD_flags, 4
F MD_pad, 4
ENDSTRUCT MD_SIZE           # 56

# ---------------------------------------------------------------- provider vtable
STRUCT
F PV_new, 8                 # (MD*) -> ctx
F PV_build, 8               # (ctx, SB*, sys cstr, Transcript*) -> 0|-errno
F PV_path, 8                # (ctx) -> cstr endpoint path ("/v1/messages")
F PV_sse, 8                 # (ctx, SS*, event ptr, event len, data ptr, data len) -> 0
F PV_finish, 8              # (ctx, SS*) -> 0 ; emits SE_DONE/SE_ERROR if missing
F PV_free, 8                # (ctx)
ENDSTRUCT PV_SIZE

# ---------------------------------------------------------------- tools
.equ TL_READONLY,    1
.equ TL_SEQUENTIAL,  2
.equ TL_DESTRUCTIVE, 4

.equ MF_ERROR, 1
.equ JF_ERROR, 1
.equ JF_TIMEOUT, 2        # the loop's watchdog killed the child

.equ JS_NEW,     0
.equ JS_RUNNING, 1
.equ JS_DONE,    2

STRUCT
F TL_name, 8                # cstr
F TL_label, 8
F TL_desc, 8
F TL_params, 8              # embedded JSON schema cstr
F TL_flags, 4
F TL_pad, 4
F TL_exec, 8                # (Job*) -> 0|-errno
F TL_finish, 8              # (Job*) -> 0; called at child EOF (may be 0)
ENDSTRUCT TL_SIZE           # 48

STRUCT
F J_tool, 8                 # TL*
F J_call_id, 8              # cstr (owned by the message)
F J_args, 8                 # cstr raw JSON
F J_pid, 8
F J_fd, 8
F J_out, 8                  # SB* result text
F J_state, 4
F J_flags, 4
F J_deadline_ms, 8
F J_started_ms, 8
ENDSTRUCT J_SIZE            # 64
