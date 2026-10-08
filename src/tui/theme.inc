# theme.inc — colour slots, base palettes and colour-mode constants.
#
# The grid Cell carries a resolved 0xAARRGGBB colour; every draw site asks
# theme_rgb(slot) for the current theme's value each frame.  TH_NO_BG is the
# pseudo-slot for "leave the terminal background", emitted as SGR 49 and
# represented as the colour 0 in a cell.
.equ TH_FG,          0
.equ TH_BG,          1
.equ TH_MUTED,       2
.equ TH_ACCENT,      3
.equ TH_OK,          4
.equ TH_WARN,        5
.equ TH_ERR,         6
.equ TH_USER,        7
.equ TH_ASSISTANT,   8
.equ TH_THINKING,    9
.equ TH_TOOL,       10
.equ TH_DIFF_ADD,   11
.equ TH_DIFF_DEL,   12
.equ TH_CODE,       13
.equ TH_TOOL_OK_BG, 14
.equ TH_TOOL_ERR_BG,15
.equ TH_TOOL_BG,    16
.equ TH_COUNT,      17
.equ TH_NO_BG,  0xFFFF

.equ THEME_16,   0
.equ THEME_256,  1
.equ THEME_TRUE, 2

# Theme struct (src/tui/theme.s): palette + detected mode + variant + force_bg.
STRUCT
F TH_rgb,      68          # u32 rgb[TH_COUNT]
F TH_mode,      4          # THEME_*
F TH_dark,      4          # 1 dark, 0 light
F TH_force_bg,  4          # push TH_BG via OSC 11
ENDSTRUCT TH_SIZE          # 80
