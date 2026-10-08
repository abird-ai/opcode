# status.inc — status-line segment registry data model shared by status.s, the
# TUI footer renderer and (from S5) the theme swapper.  Defines the segment
# registry ABI used by built-in and extension status providers.
#
# Provider callback (opcode ABI):
#   size_t provider(rdi=ud, rsi=out SEG*, rdx=max, rcx=arena, r8=arena_cap)
# A provider fills up to `max` SEG records and returns how many it wrote.  The
# arena is registry-owned scratch; text must be plain UTF-8 and is copied
# immediately, so a pointer into the arena or the provider's own state is fine.
# A provider is an ordinary function: it must preserve the callee-saved
# registers (rbx/rbp/r12-r15); the built-in provider does.
# `status_register(fn, ud)` is idempotent for the same (fn, ud); a NULL fn is
# ignored.  Providers live in a fixed 16-slot table.

# ------------------------------------------------------------------ slots
.equ SLOT_LEFT,  0
.equ SLOT_RIGHT, 1

# ------------------------------------------------------------------ styles
.equ STYLE_DIM,    0x0001
.equ STYLE_BOLD,   0x0002
.equ STYLE_ACCENT, 0x0004
.equ STYLE_WARN,   0x0008
.equ STYLE_ERROR,  0x0010
.equ STYLE_OK,     0x0020
.equ STYLE_ALL,    0x003F

# ------------------------------------------------------------------ bounds
.equ STATUS_MAX_PROVIDERS,          16
.equ STATUS_MAX_SEGMENTS,           24
.equ STATUS_MAX_PROVIDER_SEGMENTS,   8
.equ STATUS_ARENA_CAP,            1024
.equ STATUS_TEXT_MAX,              192   # NUL included
.equ STATUS_BUDGET_NS,         2000000   # 2 ms per provider

# Raw provider segment: { u32 struct_size; u32 slot; i32 priority; u32 style;
# char *text } — the fixed 24-byte status-segment layout.
STRUCT
F SEG_struct_size, 4
F SEG_slot,        4
F SEG_priority,    4
F SEG_style,       4
F SEG_text,        8
ENDSTRUCT SEG_SIZE                        # 24

# Validated, copied segment handed back by status_snapshot(), with the text
# inlined; seq is the stable (provider, output
# order) tiebreak used by the (slot, priority, seq) sort.
STRUCT
F SV_slot,     4
F SV_priority, 4
F SV_style,    4
F SV_pad,      4
F SV_text,   192
F SV_seq,      8
ENDSTRUCT SV_SIZE                        # 216

# Built-in provider state, copied in by status_builtin_set().  The TUI fills it
# from the agent accessors each frame; the provider formats the model, thinking,
# token and cost segments plus the right-slot run state.
STRUCT
F ST_model,      192
F ST_thinking,    24
F ST_tok_in,       8
F ST_tok_out,      8
F ST_cost_micro,   8
F ST_spinner,      4
F ST_pad0,         4
F ST_elapsed_ms,   8
F ST_running,      4
F ST_pad1,         4
ENDSTRUCT ST_SIZE                       # 264

# One registry slot.
STRUCT
F SP_fn,       8
F SP_ud,       8
F SP_id,       8
F SP_disabled, 4
F SP_pad,      4
ENDSTRUCT SP_SIZE                       # 32

# Fixed palette for the footer band.  Theme slots arrive in S5; until then the
# footer paints these values, so there is exactly one place to swap them.
.equ ST_FG,     0xFFE6E6E6
.equ ST_MUTED,  0xFF8A8A8A
.equ ST_BG,     0xFF262633
.equ ST_ACCENT, 0xFF7FB8FF
.equ ST_WARN,   0xFFE8C07D
.equ ST_ERR,    0xFFE06C6C
.equ ST_OK,     0xFF7FD07F
