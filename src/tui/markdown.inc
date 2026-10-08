# markdown.inc — block model, style tags and struct layouts for markdown.s.
#
# The block model appends source text incrementally;
# only the trailing incomplete block is re-parsed and re-rendered.  Each row
# keeps its UTF-8 text and a parallel byte of style tags (one per text byte).
# The style byte is { class:4, bold:1, dim:1, italic:1 } so a byte is opaque
# to callers that only forward it to the view/ANSI mappers.  See API.md.

# ---- block kinds -----------------------------------------------------------
.equ MD_PARA,   0
.equ MD_HEAD,   1
.equ MD_BULLET, 2
.equ MD_CODE,   3
.equ MD_QUOTE,  4
.equ MD_RULE,   5

# ---- style classes (low nibble) -------------------------------------------
.equ MDC_BASE,   0          # inherit the caller's base style
.equ MDC_ACCENT, 1          # TH_ACCENT
.equ MDC_CODE,   2          # TH_CODE (inline `code`)
.equ MDC_MUTED,  3          # TH_MUTED
.equ MDC_THINK,  4          # TH_THINKING (fenced code body)
.equ MDC_MASK,   0x0F

# ---- style flags ----------------------------------------------------------
.equ MDF_BOLD,   0x10
.equ MDF_DIM,    0x20
.equ MDF_ITALIC, 0x40

# ---- view style ids extended by markdown (see src/tui/view.s) -------------
.equ VS_MD_ACCENT, 21       # TH_ACCENT
.equ VS_MD_THINK,  22       # TH_THINKING

# view style-byte attribute bits (view.s masks the id with 0x1F)
.equ VSA_BOLD,   0x20
.equ VSA_DIM,    0x40
.equ VSA_ITALIC, 0x80

# ---- structs --------------------------------------------------------------
STRUCT
F MDK_text,    SB_SIZE       # accumulated UTF-8 source
F MDK_blocks,  VEC_SIZE      # VEC of MdBlock
F MDK_width,   4             # wrap width in display columns
F MDK_pad,     4
ENDSTRUCT MDK_SIZE           # 56

STRUCT
F MB_kind,     4
F MB_complete, 4
F MB_start,    8            # byte range in MDK_text
F MB_end,      8
F MB_rows,     VEC_SIZE     # VEC of MdRow
ENDSTRUCT MB_SIZE           # 48

STRUCT
F MR_text,    SB_SIZE       # row UTF-8 (no '\n')
F MR_style,   SB_SIZE       # one style byte per text byte, parallel
ENDSTRUCT MR_SIZE           # 48
