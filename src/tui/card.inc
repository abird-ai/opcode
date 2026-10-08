# card.inc — tool-card data model, style ids and the fixed dark card palette.
#
# Included by src/tui/view.s (to extend the style palette) and src/tui/card.s
# (the model).  S5 (themes) swaps the palette for theme slots; keeping every
# card colour in this one block is the seam.  The tints are pi's dark
# toolSuccessBg/toolErrorBg/toolPendingBg (`#283228`/`#3C2828`/`#282832`),
# matching the built-in dark palette.

# ---- styles: ids after view.s's base VS_TEXT..VS_CODE range ---------------
.equ VS_CARD_TOOL,   12   # card header name/args
.equ VS_CARD_WARN,   13   # running status
.equ VS_CARD_OK,     14   # ok status
.equ VS_CARD_ERR,    15   # err status
.equ VS_CARD_BODY,   16   # plain body text
.equ VS_CARD_DIM,    17   # "... (+N lines)" marker
.equ VS_CARD_ADD,    18   # edit diff '+'
.equ VS_CARD_DEL,    19   # edit diff '-'
.equ VS_CARD_HUNK,   20   # edit diff '@'
.equ VS_MAX,         22

# ---- fixed dark palette ---------------------------------------------------
.equ CARD_FG,       0xFFCDD6F4
.equ CARD_MUTED,    0xFF7F849C
.equ CARD_ACCENT,   0xFF89B4FA
.equ CARD_OK,       0xFFA6E3A1
.equ CARD_WARN,     0xFFF9E2AF
.equ CARD_ERR,      0xFFF38BA8
.equ CARD_TOOL,     0xFFCBA6F7
.equ CARD_DIFF_ADD, 0xFFA6E3A1
.equ CARD_DIFF_DEL, 0xFFF38BA8
.equ CARD_BG_RUN,   0xFF282832
.equ CARD_BG_OK,    0xFF283228
.equ CARD_BG_ERR,   0xFF3C2828

# ---- model -----------------------------------------------------------------
# One tool card.  args/out are owned SBs; id/name owned cstrings.  started_ms
# is the app clock at SE_TOOL_START, duration_ms the value reported by
# SE_TOOL_EXEC.  CD_rendered is a per-rebuild bookkeeping flag.
STRUCT
F CD_id,          8
F CD_name,        8
F CD_args,        8
F CD_out,         8
F CD_started_ms,  8
F CD_duration_ms, 8
F CD_running,     4
F CD_error,       4
F CD_expanded,    4
F CD_rendered,    4
ENDSTRUCT CD_SIZE           # 56

STRUCT
F CH_cards, 8               # VEC* of CD
ENDSTRUCT CH_SIZE           # 8
