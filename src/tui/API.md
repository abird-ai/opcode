# tui API contract (frozen for M4)

All files include `opcode.inc` (and `core/core.inc` when needed). ABI as usual.

## Layer 0 additions

```
# src/plat/linux/tty.s
os_tty_raw(saved /* 64+ bytes */) -> 0|-errno   # tcgetattr save + raw mode
os_tty_restore(saved)             -> 0|-errno
os_tty_size(fd)                   -> rax=cols, rdx=rows
os_sig_winch()                    -> 0          # SIGWINCH -> 1 byte on a pipe
os_winch_fd()                     -> fd         # non-blocking read end for the watch table
os_sig_cleanup()                  -> 0|-errno   # fatal signals (HUP INT QUIT ABRT BUS FPE SEGV TERM):
                                                 # restore the tty, then re-raise (async-safe)
```

`src/plat/linux/sys.s` exports `g_exit_hook: .quad`; when non-zero, `os_exit`
calls it (indirect, guarded) before `exit_group`. The hook must be
async-signal-safe. `term_init` sets it to `term_restore`.

## src/tui/render.s — cell grid

Cell = 24 bytes: `{ u32 cp; u32 comb; u32 fg; u32 bg; u16 attrs; u16 pad }`.
Attrs: `A_BOLD 1, A_UNDERLINE 2, A_DIM 4, A_REVERSE 8, A_ITALIC 16`.  `comb`
holds one combining mark attached to the base glyph (0 = none).  `cp` sentinel
`CELL_CONT 0xFFFFFFFF` marks the second column of a width-2 glyph.

```
grid_init(g, w, h) -> 0|-errno
grid_free(g)
grid_resize(g, w, h) -> 0|-errno
grid_clear(g, fg, bg)
grid_fill(g, x, y, w, h, cp, fg, bg)
grid_put(g, x, y, cp, fg, bg, attrs)
grid_text(g, x, y, fg, bg, attrs, ptr, len) -> new_x      # UTF-8, controls sanitised
grid_sanitize_bytes(src, len, out_sb) -> 0   # strict UTF-8; C0/DEL/C1 -> U+FFFD, newline/tab kept
render_flush(g, fd) -> 0|-errno      # ANSI diff vs the previous frame, one writev
render_dump(g, sb) -> 0              # plain text for headless tests (trim right, lines joined)
grid_invalidate(g)                  # zero `prev` so the next flush repaints every row
```
`g` is caller-allocated; its size is exported as the data symbol `grid_size: .quad` in render.s
(reset the struct with that many zero bytes before `grid_init`).

Wide/combining model, shared by every draw site through `grid_put`/`grid_text`:
a width-2 codepoint occupies two cells and marks the second `CELL_CONT` (the
emitter emits nothing for it; the base glyph covers both terminal columns).  A
wide glyph that would cross the right edge is blanked, never split, so no stray
continuation cell can survive at a row boundary.  A genuine combining mark
(`utf8_is_combining`) attaches to the preceding base cell, skipping a
`CELL_CONT`, and spends no column; at most one mark per cell.  Any other
zero-width codepoint that is a C0 control or DEL is stored as a space, and the
remaining Cf format characters are dropped and never drawn.  `grid_put` and
`grid_text` are the output-side defence: `render_build`, `render_dump` and the
inline `inline_emit_row` each also skip `CELL_CONT`, emit a space for any
control that slipped into a cell and emit an attached mark only when it is
itself printable (`>= 0x20`, `!= 0x7F`).

`grid_sanitize_bytes` remains the input-side choke point (S1): C0/DEL/C1 ->
U+FFFD, newline/tab kept.  `render_build`'s trailing-blank trim keeps a
reverse-video caret cell and any cell with a non-zero theme background so a
status/tool-card band reaches the right edge.

The decoder and the per-codepoint filter are single-sourced: `utf8_decode`
(`src/base/uni.s`) is the only strict UTF-8 decoder and `grid_sanitize` the only
codepoint filter.  `src/tui/view.s:utf8dec` is a one-instruction alias (`jmp
utf8_decode`) and `src/tui/card.s:card_sanitize_cp` aliases `grid_sanitize`, so
there is exactly one implementation of each.

## src/tui/term.s

```
term_init() -> 0|-errno        # skip entirely when g_tui_headless != 0 (exported u64 global)
term_restore()                 # idempotent; write(2)/ioctl(2) only, signal-safe
term_size() -> rax=cols, rdx=rows
term_flush(g, cursor_x, cursor_y, cursor_visible) -> 0
term_resized() -> 1|0          # drains the winch pipe and refreshes the size
term_poll_resize() -> 1|0      # queries the size directly; refreshes the cache
                              # on change (headless no-op); the SIGWINCH pipe
                              # and this poll share the one tui_resize path
term_set_bg(color ARGB)        # OSC 11 set-background (skip when headless)
term_reset_bg()                # OSC 111 reset-background (skip when headless)
tui_write_all(fd, ptr, len)    # write_all, but fd 1 -> capture sink when active
g_tui_headless: .quad          # set by the app before term_init
g_tui_capture: .quad           # cstr path for --headless-capture (0 = none)
g_tui_capture_fd: .quad        # open sink fd (-1 = none); term_flush honours it
```

### Presentation modes (S7)

The app selects one renderer from `t_ui_mode`, with these names/values:
`scrollback=0`, `inline=1` (the default), `fullscreen=2`; `auto` parses to
`inline`. `--tui-mode` accepts exactly those four spellings
(`cli.s:.Lca_tuimode`). `--headless` without a capture sink forces fullscreen
(`t_ui_mode=2`) so the grid-dump goldens stay stable; `--headless-capture` keeps
the requested mode so the raw byte stream can be asserted.

`scrollback` is the legacy append-only path: finalized text streams to stdout
once, a live footer is redrawn by moving up over the previous frame, and
finished rows are never redrawn.

`inline` owns a rectangular bottom region `h = transcript tail + queue strip +
composer + menu + footer`, recomputed every frame. The hidden hardware cursor is
parked at the region's top-left between frames (`ESC[1G` + `ESC[?25l`), and the
editor's reverse-video cell is the visible caret.  `inline_emit_row` reads the
cell's `attrs` (offset 16) as well as fg/bg and emits the matching `A_BOLD`,
`A_DIM`, `A_UNDERLINE`, `A_REVERSE` and `A_ITALIC` SGRs, and its trailing-blank
trim keeps a reverse-video or themed-band cell, so the caret and markdown
emphasis are visible in inline mode too. Every owned row is repainted
under a full-line clear (`ESC[2K`); a frame is one write bracketed by
`ESC[?7l`/`ESC[?7h` so a repaint cannot leave the terminal in a pending-wrap
state. Finished whole transcript messages are committed at the region top with
newline mode, so they flow up into real scrollback; a live block taller than the
region shows its tail. Commit happens only while the agent is idle, so a running
card or streaming message is never printed twice; `t_in_commit` (message index)
and `t_in_live_base` (its view-row count at the current width) bound the
committed prefix.

On resize the terminal has already reflowed, so `inline_region_erase` clears the
region with cursor-relative movement only (`ESC7` `ESC[2K` `ESC[1B` …, `ESC8`) —
never a row recomputed from the old width — over the rows each owned row
re-wraps to at the new width (`t_in_cw` holds each row's last content column),
and the next frame re-anchors at the new bottom and repaints. Detection is the
SIGWINCH pipe plus `term_poll_resize`, both funnelled through `tui_resize`.

`fullscreen` is unchanged: the alternate screen, a full cell grid and the
differential `term_flush`, with the cursor parked on the caret cell.

## src/tui/theme.s (new in S5)

The grid stores a resolved `0xAARRGGBB` per cell; every draw site resolves its
slot through the active theme each frame. `TH_NO_BG` is the pseudo-slot for
the terminal background, represented by the colour `0` and emitted as SGR 49.

```
theme_init(t, dark)                       # built-in palette, detected mode
theme_apply_named(t, name) -> 1|0         # system/dark/light/named; re-reads files
theme_set_project_root(cwd, trusted)      # trust verdict comes from the app
theme_set_current(t)
theme_set_mode(t, mode)                   # THEME_16/256/TRUE
theme_rgb(slot) -> rax ARGB               # TH_NO_BG -> 0
theme_parse_color(s, out) -> 1|0          # #rgb/#rrggbb
theme_emit_fg(sb, color)  theme_emit_bg(sb, color)   # 24-bit/256/16 emitter
theme_emit_bg(sb, 0) -> SGR 49
theme_system_dark() -> 1|0                # $COLORFGBG last field
theme_detect_mode() -> THEME_*            # COLORTERM/TERM heuristic
theme_size: .quad TH_SIZE                 # sizeof(Theme)
```

Slots: `TH_FG, TH_BG, TH_MUTED, TH_ACCENT, TH_OK, TH_WARN, TH_ERR, TH_USER,
TH_ASSISTANT, TH_THINKING, TH_TOOL, TH_DIFF_ADD, TH_DIFF_DEL, TH_CODE,
TH_TOOL_OK_BG, TH_TOOL_ERR_BG, TH_TOOL_BG` plus `TH_NO_BG`. Named themes
resolve from `themes/<name>.jsonc` under the config dir and (when trusted)
`<cwd>/.opcode/themes`; the stem is `[A-Za-z0-9._-]{1,64}`, no `.`/`..`.
Precedence slot by slot is built-in base -> `<config>/theme.jsonc` base ->
named file base, then config slots, then named slots. The emitter uses the
detected mode (truecolor by default, 256 cube with the near-neutral dark
greyscale-ramp special case, else 16 ANSI with muted pinned to index 8).

## src/tui/input.s

```
# InputEvent (32 bytes): { u32 key; u32 cp; u32 mods; u32 pad;
#                         u64 paste; u64 paste_len; }
#   mods: bit0 alt, bit1 shift, bit2 ctrl
#   paste/paste_len are only meaningful for K_PASTE; other keys leave them 0.
input_init(in)
input_free(in)
input_feed(in, ptr, len)
input_next(in, InputEvent*) -> 1 | 0 (empty)
input_idle(in, now_ms)         # arm/fire the 50 ms lone-ESC / partial-CSI timeout
input_in_size: .quad           # exported buffer size for the caller's zeroed struct
input_ev_size: .quad           # sizeof(InputEvent) = 32
```
Special keys (>= 0x110000): `K_UP 0x110001, K_DOWN, K_LEFT, K_RIGHT, K_HOME, K_END,
K_PGUP, K_PGDN, K_DEL, K_INSERT 0x11000a, K_F1 0x11000b, K_F2, K_F3, K_F4,
K_BACKSPACE 0x7f, K_ENTER 0x0a, K_TAB 0x09, K_ESC 0x1b`, `K_PASTE 0x110010`.
Printable input arrives as `cp` with `key == cp`. Modifier bits are alt=1,
shift=2, ctrl=4; `CSI`/`SS3` special keys report `cp = 0`.

The parser accepts this escape grammar: `CSI A/B/C/D/H/F` movement
(standard `1;mod` and the legacy single-parameter `CSI 5D`/`CSI 3A` forms),
`CSI Z` shift-Tab, `CSI ~` keys (Home/Insert/Delete/End/PgUp/PgDn/F1-F4),
kitty `CSI cp;mods u`, SS3 movement and F1-F4, and CRLF collapse (CR+LF and a
bare LF are one Enter). UTF-8 is validated strictly: a malformed lead or
continuation reports U+FFFD, and an overlong/surrogate/>U+10FFFF sequence
reports one U+FFFD per byte it consumed (the `src/base/uni.s` one-byte rule).

Bracketed paste (`\x1b[200~ ... \x1b[201~`) accumulates the raw bytes verbatim
in an internal SB and emits exactly one `K_PASTE` event whose `paste`/`paste_len`
point at it (valid until the next paste starts). The editor's `editor_paste`
consumes that event; do not feed it to `editor_key`. OSC/DCS/APC payloads are
swallowed. The `K_PASTE` payloads are owned by the parser: `input_free`
releases every queued or in-flight paste buffer, and `input_init` calls it
before zeroing, so re-initialising a parser cannot leak a previous paste. A lone ESC (or an incomplete CSI/SS3 sequence) is held, not flushed
by `input_next`: the caller's poll tick calls `input_idle(in, now_ms)` and the
50 ms window then emits `K_ESC` (or drops the incomplete sequence). This keeps a
real escape sequence that arrives in a later read from being split, and is the
Alt disambiguation rule.

## src/tui/editor.s

Struct layout (160 bytes, `ED_SIZE`/`editor_ed_size`): text/kill/live SBs, a VEC of
history entries (oldest first), a VEC of collapsed paste bodies, the retained
prompt, cursor/anchor, `hist_pos`, goal column, width, flags, paste counter and
scroll.

```
editor_init(e)  editor_free(e)
editor_set(e, ptr, len)          # replace text, expanding tabs to 4-col stops; cursor at end
editor_text(e) -> rax ptr, rdx len
editor_empty(e) -> eax 0|1
editor_clear(e)                  # text + pastes (history/ascii kept)
editor_take(e) -> rax owned cstr # expand [Pasted text #N +M lines] markers, then clear;
                                 # mem_free the result.  Out-of-range markers stay literal.
editor_set_prompt(e, cstr); editor_prompt(e) -> cstr
editor_set_ascii(e, esi flag)    # '-' rules instead of U+2500
editor_key(e, key, cp, mods) -> eax 1 submit | 0
editor_paste(e, ptr, len) -> eax 0   # K_PASTE: normalise CRLF/CR, expand tabs,
                                     # collapse >10 lines into a marker
editor_history_add(e, ptr, len) -> eax 1|0        # in-memory, dedupes against newest
editor_history_append(e, path|0, ptr, len) -> eax 1|0  # in-memory + append to file;
                                 # empty/multi-line are not persisted
editor_history_load(e, path)                     # whole file, CR-tolerant, dedupes
editor_complete(e, dir|0) -> eax 0               # @file Tab completion (macOS no-op)
editor_lines(e, width) -> rax rows, rdx cur row, rcx cur col   # input area only
editor_visual_rows(e, width) -> rax text rows + 2
editor_render(e, grid, x, y, w, h,
              [rbp+16] bg, [rbp+24] muted, [rbp+32] cursor_visible,
              [rbp+40] placeholder) -> rax cursor_x, rdx cursor_y   # (-1,-1) hidden
editor_ed_size: .quad            # exported buffer size
```

`editor_key` returns 1 on plain Enter (submit; inserts nothing) and 0 otherwise;
Alt+Enter inserts `\n`. A K_PASTE event never goes through `editor_key`. The
keymap is the readline set: Ctrl+A/E and Home/End are line
bounds, Ctrl+Home/End are buffer bounds, Alt+B/F and Ctrl+arrows are word motion,
Ctrl+W/Alt+Backspace and Alt+D/Ctrl+Delete kill words, Ctrl+K/U kill, Ctrl+Y yanks
the single-slot kill buffer, Ctrl+T transposes, Up/Down browse history when the
buffer has no newline (otherwise vertical motion).

`editor_complete` needs a caret token beginning with `@` after whitespace and
replaces it with the best `@file` candidate (case-insensitive prefix beats
subsequence, shorter name breaks ties, directories get a trailing `/`).

## src/tui/menu.s

The slash-command menu is module-local state (`menu_size` is the caller's zeroed
buffer size). It opens while the composer text begins with `/` and has no
space/tab/newline and the filter is <= 63 bytes; the filter is case-sensitive.

```
menu_init()                              # zero state + menu_sources_refresh()
menu_sources_refresh()                   # capture built-ins, prompts, skills, ext cmds
menu_update(ptr, len)                    # recompute open/filter/entries
menu_open() -> eax 1|0
menu_count() -> eax
menu_sel() -> eax
menu_top() -> eax                        # clamped so the selection is visible
menu_height(esi avail) -> eax            # min(count, 8, avail); 0 when closed
menu_key(esi key, edx cp, ecx mods) -> eax 1 consumed
menu_render(rdi grid, esi x, edx y, ecx w, r8d maxrows)
menu_name(edi index) -> rax ptr, rdx len
menu_desc(edi index) -> rax ptr, rdx len
```

Sources, in precedence order: the built-ins `clear help model new quit thinking
compact` (name + description), then prompt-template names, then skill names as
`skill:<name>`, then extension commands when `opcode_host_command_count` is non-zero.
The `skill:` prefix is reserved and a name already taken by an earlier source is
skipped, so the menu never advertises an entry `tui_submit_editor` would not
reach. `menu_sources_refresh()` calls `prompt_templates_init()` and `skills_list()`
once at startup (it copies the names into module storage), so `menu_update` stays
filesystem-free and `skill_body` later finds the same table. At most 32 entries
are stored, 8 rendered.

Only Up/Down/Tab/Enter(no Alt)/Esc are consumed; the shell reads
`menu_name(menu_sel())` itself to complete or dispatch on Tab/Enter. Entries
render as `/name` plus a dim description, selected row reverse-video, at most 8
visible rows. A missing description (`menu_desc` returns 0,0) is simply not drawn.

## src/tui/status.s

The footer is a provider segment registry, not a fixed string. Layout lives in
`src/tui/status.inc` (`SEG_*` raw provider segments, `SV_*` validated copies,
`ST_*` built-in state, `SLOT_*`/`STYLE_*`/`STATUS_*` constants). Segment styles
resolve to theme slots (`STYLE_ACCENT/WARN/ERROR/OK` -> `TH_ACCENT`/`TH_WARN`/
`TH_ERR`/`TH_OK`, plain -> `TH_MUTED`) on the `TH_BG` footer band; the legacy
`ST_*` RGB constants are unused.

```
status_register(rdi=provider, rsi=ud)     # idempotent; NULL ignored; 16 slots
status_remove(rdi=provider, rsi=ud)
status_reset()
status_version() -> rax u64
status_invalidate()
status_snapshot(rdi out SV*, rsi max) -> rax count
status_register_builtin()
status_builtin_set(rdi ST*)
status_render(rdi grid, esi row, edx width) -> eax 0
```

Provider callback: `size_t fn(rdi=ud, rsi=out SEG*, rdx=max, rcx=arena, r8=cap)`
returning the number of segments written (<= 8). The registry validates and
copies each segment, dropping short structs, unknown slots/styles, empty text,
embedded control bytes, and clamps text to 191 bytes. A provider over the 2 ms
budget is disabled for the rest of the process. The snapshot is sorted by
`(slot, priority, registration order)` and `status_render` rebuilds its cached
snapshot only when `status_version()` changes. The built-in provider emits LEFT
`model`, `think:<name>`, `tok:<in>/<out>`, `$cost` (omitted when the state cost is
negative) and RIGHT `ready`/`<spin> <elapsed>`; `status_render` fills the footer
band, joins LEFT with `" | "`, right-aligns RIGHT (the right slot wins a full row,
LEFT is clipped first). `status_builtin_set` invalidates only when a rendered field
actually changed.

## src/tui/markdown.s

The streaming markdown block model. `markdown.inc` holds the struct layouts
(`Markdown` = text SB + `MdBlock` VEC + width), the block kinds, the style tags
and the per-row `MD_*`/`MDF_*`/`MDC_*` constants.

```
md_init(m, width)                 # zero the struct; width < 1 -> 80
md_free(m)                        # free text, blocks and rows
md_reset(m)                       # md_free but keep the width
md_set_width(m, width)            # re-render every block once (resize/theme)
md_append(m, ptr, len)            # incremental: re-parse only the trailing
                                  # incomplete block; completed blocks keep rows
md_height(m) -> rax rows
md_nblocks(m) -> rax
md_blocks(m, &n) -> MdBlock*
md_rows_before(m, first) -> rax   # rows in blocks [0, first)
parse_inline(ptr, len, segs, max) -> rax count   # Seg = {ptr,len,tag}, 24 bytes
md_emit_view(m, view, base_style)
md_emit_view_from(m, view, base_style, first_block)
md_emit_ansi(m, sb, base_slot)    # SGR runs + '\n' per row (inline)
```

Block kinds: `MD_PARA 0`, `MD_HEAD 1`, `MD_BULLET 2`, `MD_CODE 3`, `MD_QUOTE 4`,
`MD_RULE 5`. A blank line ends a paragraph; `#`..`######` starts a heading;
`- `/`* `/`+ ` starts a bullet; `> ` a quote; a line of >=3 `-`/`*`/`_` a rule;
a ```` ``` ````/`~~~` fence buffers verbatim until a closing fence of the same
char (>=3). Paragraphs join source lines with a space and wrap word-granularly
(words longer than the width split per codepoint; leading blanks dropped);
bullets indent continuation rows by 2 and emit `"- "` in the accent style;
fenced code is clipped, not wrapped.

Each row stores UTF-8 text plus one style byte per text byte. A style byte is
`{ class:4; bold:1; dim:1; italic:1 }`: classes `MDC_BASE` (inherit the caller's
base style), `MDC_ACCENT`, `MDC_CODE`, `MDC_MUTED`, `MDC_THINK` (fenced code),
flags `MDF_BOLD/DIM/ITALIC`. `md_emit_view` maps the tag to a view style byte
(class -> base / `VS_MD_ACCENT` 21 / `VS_CODE` 11 / `VS_DIM` 2 / `VS_MD_THINK`
22, flags -> the high bits) and calls `view_append_span` per run, then
`view_break` per row. `md_emit_ansi` emits `SGR 0` + `theme_emit_fg(slot)` +
bold/dim/italic + text for each run. `parse_inline` parses `**bold**`, `` `code`
``, `*italic*`/`_italic_`; an unterminated marker stays literal and one `Seg`
slot is reserved for the unstyled tail.

The theme is resolved per frame: headings <= H1 use the accent slot, H3-6 add
dim; inline code uses `TH_CODE`; fenced code uses `TH_THINKING`.

## src/tui/view.s (integrator-owned)

A fixed-row styled transcript buffer. Row = 256 bytes of text + 256 bytes of style
(one byte per cell: style ids from a small palette), fixed stride 512, max 20000 rows.

```
view_init(v, width)
view_clear(v)
view_resize(v, width)
view_rows(v) -> n
view_row_text(v, i) -> ptr
view_row_style(v, i) -> ptr
view_row_len(v, i) -> n
view_row_bg(v, i) -> band colour (0 = terminal bg)
view_set_bg(v, bg)                         # band for rows finished from now on
view_text_width(ptr, len) -> display columns
view_append_span(v, style, ptr, len)       # wraps at width, appends rows
view_break(v)                              # force a new row
view_mark(v) -> row                        # remember a position
view_truncate(v, row)                      # drop rows after row
view_scroll(v, delta)  view_scroll_bottom(v)  view_top(v) -> row
view_set_vp(v, x, y, w, h)                 # viewport for draw
view_draw(v, grid, fg, bg)                 # draw visible rows with palette styles
```
Each committed row carries a background band (`view_set_bg` before the row is
finished, read back with `view_row_bg`). `view_draw` fills the whole row with
that band first and draws the text over it, so the card's SGR survives the
tail erase and reaches the terminal's right edge. It places each codepoint
through `grid_put`, so a wide glyph is written as a base + `CELL_CONT` and a
combining mark attaches to its base exactly as in the composer; the transcript
wrap uses the same display width as the draw pass. `utf8dec` (a thin alias for
`utf8_decode`), `view_wcwidth` (a tail call into the shared `utf8_wcwidth` table),
`view_style_color` and `view_text_width` are exported for `card.s`.

Base styles: `VS_TEXT, VS_DIM, VS_ASSIST, VS_USER, VS_TOOL, VS_TOOL_OUT,
VS_DIFF_ADD, VS_DIFF_DEL, VS_DIFF_HUNK, VS_ERR, VS_CODE` (ids 1..11).
Markdown adds `VS_MD_ACCENT 21` (TH_ACCENT) and `VS_MD_THINK 22` (TH_THINKING).
A style byte's high bits carry attributes: `VSA_BOLD 0x20`, `VSA_DIM 0x40`,
`VSA_ITALIC 0x80`; `view_style_color` masks the id with `0x1F` and
`view_style_attrs` returns the grid `A_BOLD`/`A_DIM` bits that `view_draw` passes
to `grid_put`.
Tool-card styles `VS_CARD_TOOL/WARN/OK/ERR/BODY/DIM/ADD/DEL/HUNK` (12..20) map
to theme slots in `view_style_color`, which resolves the active theme every
frame.

## src/tui/card.s (new in S4)

Tool-card state machine and renderer (`card.inc` holds the model, style ids and
palette). A card starts on `SE_TOOL_START`, accumulates its argument preview
from `SE_TOOL_DELTA`, and finishes on `SE_TOOL_EXEC`.

```
chat_init(chat)  chat_free(chat)  chat_clear(chat)
chat_tool_start(chat, id cstr, name cstr, now_ms) -> card*
chat_tool_delta(chat, ptr, len)
chat_tool_exec(chat, TE*)                 # find running by name/id, else create
chat_find(chat, id cstr) -> card*|0
chat_toggle_last(chat)                    # Ctrl+O
chat_has_running(chat) -> 1|0
chat_reset_marks(chat)
chat_render_by_id(view, chat, id cstr, width, now_ms) -> 1 found / 0
chat_render_unmatched(view, chat, width, now_ms)
chat_emit_last_inline(chat, width, now_ms)
```

`card_render` paints one card: `[<name>] <48-column arg preview>` (clipped on
a codepoint boundary so a multibyte sequence is never split) with `\n\r\t`
folded to spaces, then a right-aligned status (`<spinner> <elapsed>ms` while
running, `ok <duration>ms` / `err <duration>ms` when finished). The body shows
the tail of the output (last 3 collapsed, last 10 expanded) indented one
column, with a dim `... (+N lines)` marker when collapsed and truncated; `edit`
lines starting `+`/`-`/`@` take the diff styles. Rows are padded with the
outcome band (`TH_TOOL_BG`/`TH_TOOL_OK_BG`/`TH_TOOL_ERR_BG`) and a blank gap row keeps two
cards from merging. Under `g_tui_headless` the spinner/elapsed and the finished
duration are frozen so goldens are deterministic.

## src/app/tui.s (integrator-owned)

```
g_tui_script: .quad   # --script FILE : headless script runner
g_tui_headless: .quad # --headless WxH
tui_run(argc, argv) -> exit code
```
Script verbs (one per line, `#` comments): `type TEXT`, `key NAME` (up, down, enter,
esc, tab, backspace, ctrl-c, ctrl-o ...), `wait MS`, `prompt TEXT` (submit a
message), `print-screen`, `resize W H`, `quit`.

Slash grammar: a submitted line is split at the first space/tab/newline into a
command `word` and the remaining `args` (leading spaces/tabs skipped). Dispatch
order is built-in -> `skill:<name>` (reserved) -> prompt template -> extension
command -> plain model message. Built-ins: `/clear` (view clear), `/help`,
`/model [id]` (report or switch), `/new`, `/theme [dark|light|<name>]`,
`/thinking [off|low|medium|high]`, `/compact`, `/quit`. `/skill:<name> [args]` submits the stripped skill body with
`\n\n` + args appended; a missing/unknown/oversized skill is a notice. The footer
state is filled from `agent_model_provider`/`agent_model_id`, `agent_thinking`,
`agent_usage_totals`, `agent_busy` and a tracked run-start ms; while busy the loop
repaints at least every 100 ms. Thinking blocks (`SE_THINK`/`SE_THINK_END`) are
recorded but rendered only when `agent_thinking() != TH_OFF` (fullscreen `VS_DIM`,
inline a dim `~ ...`). `SE_COMPACT` appends `[compacted <n> tokens]`.

Tool cards are rendered from `t_chat` (`card.s`). `SE_TOOL_START`/`SE_TOOL_DELTA`
create/extend the running card; `SE_TOOL_EXEC` finishes it; `SE_TOOL_RESULT` is
kept only for compatibility. The fullscreen transcript is rebuilt from the
transcript plus the cards (`chat_reset_marks` + `chat_render_by_id` on each
`BT_TOOLCALL` + `chat_render_unmatched` for a running card with no block yet);
the rebuild runs while `chat_has_running()` or after any card change, and must
happen *after* `view_set_vp` so `view_scroll_bottom` sees the viewport height.
`Ctrl+O` (`chat_toggle_last`) re-renders the last card collapsed/expanded.
Under the S7 owned inline region a running card is drawn live in the region tail
(its rows come from the same `chat_render_*` path used by fullscreen) and the
finished card is committed to scrollback once with the rest of the turn.

Assistant `BT_TEXT` blocks go through `markdown.s`: the fullscreen rebuild
(`tui_render_msg`) renders each block with `md_emit_view` into `t_view`, and the
inline history replay (`.Lihm_assist`) emits it as ANSI rows with `md_emit_ansi`
after sanitizing the bytes (`tui_inline_md`), so both presentations share the
same block styling. While a run streams, `SE_TEXT` deltas accumulate in
`t_md_live`; each delta re-renders only from the previously-last block
(`md_rows_before` + `view_truncate` + `md_emit_view_from`), so completed blocks
keep their rows. `SE_TEXT_END` clears the live flag and the next `SE_TEXT`
starts a fresh model; `tui_render_all` also clears it because it rebuilds the
whole view from the transcript.

The theme is selected at startup by `--theme` (CLI) > config `theme` > `system`,
initialised into `t_theme` and installed with `theme_set_current`. The TUI fills
`theme_set_project_root` from the app's trust verdict (`config_trusted(cwd)`) and
pushes the fixed dark/light background with `term_set_bg` at startup and after
every `/theme` (`term_restore` resets it). `/theme` with no argument toggles
dark<->light; a name applies or reports `theme: unknown '<name>'`; a success
reports `theme: <name>` and invalidates the fullscreen frame.

## src/core/agent.s additions

```
agent_init() -> 0 | 1          # session load, model resolution, provider ctx, buffers;
                              # 1 after printing the reason (offline, no key/model, bad replay)
agent_submit(prompt cstr) -> 0 accepted | 1 busy
agent_reset_session(sdir cstr|0, cwd cstr|0) -> 0 | -EIO  # /new: fresh session + model_change
agent_busy() -> 1|0
agent_exit_code() -> code
agent_abort()
g_agent_ui_fn: .quad          # fn(rdi=ctx, esi=SE_*, rdx=a, rcx=b); when set, print mode
g_agent_ui_ctx: .quad         # does not write to stdout
```
New sink event emitted to the UI hook only: `SE_TOOL_RESULT 11` (a=ptr, b=len) after each
tool result message is appended, and `SE_TOOL_EXEC 13` (rdx = `TE*`) with the full
tool-execution record (`id/name/args/result/result_len/error/duration_ms`); see
`src/core/API.md`.

An aborted run still reaches the shell: `agent_abort()` followed by the next
`agent_step` makes `agent_handle_abort` emit `SE_DONE` with `a=SR_ABORTED` (5)
to the UI hook exactly once. The turn's done flag guards against a provider
`PV_finish` already having delivered `SE_DONE`, so a shell that waits for run end
settles without a second event.

## Shell queue (steering)

While `agent_busy()`, a composer submit is not refused: the expanded text is
pushed onto a bounded FIFO of owned strings (grows from 4) and the composer is
cleared. The main loop (and the `wait` script verb) drains exactly one queued
message per idle tick through the normal submit path. A one-row strip above the
composer shows `queued <n>: "<first line, <=60 chars>" (esc aborts)`, or
`queued <n> (esc aborts)` when the first message is empty, in the warn colour
on the terminal background, clipped to width-1 and never committed to
scrollback. `Esc` while busy aborts the run and joins the queued messages with
`\n` into the composer, replacing its contents (`/skill:` and prompt-template
expansions queue the same way).

## S10/S11 polish (banner, sticky bottom, capture, signals)

`tui_banner()` prints one dim+muted line block above the live region exactly
once, before `term_init`, so it lands in the terminal scrollback and is never
part of a redraw: `opcode <version>`, then `tools: <name, name, ...>` when the
core registry is non-empty, then `session: <id>` when `g_agent_session` is set.
The whole text body is run through `grid_sanitize_bytes`, so the version, tool
names and session id cannot inject controls. opcode has no external tool-engine
selector, so the summary lists the registered tool names from `tools_count`/`tools_at`.
The banner is suppressed for a plain `--headless` run (grid-dump goldens) and
emitted when a capture sink is active.

Fullscreen keeps the viewport pinned to the bottom while content streams, and
preserves the reading position once the user pages up: `tui_stick_bottom()` is
called after every row append (`SE_TEXT`, `SE_TEXT_END`, `SE_ERROR`,
`SE_THINK`) and `tui_restore_anchor()` finishes every `tui_render_all`, both
implementing the bottom-pinning rule (`max = total - vh`; `top ==
last_max` means "at the bottom"). `t_last_max` tracks the previous frame's
max scroll; PgUp/PgDn (`key pgup`/`key pgdn` in scripts) call `view_scroll`, and
an explicit submit snaps to the bottom. A resize resets the view and re-pins.

`--headless-capture FILE` (CK_TUI) sets `g_tui_headless` and opens FILE; fd-1
bytes from the inline writer (`tui_write_all`) and fullscreen `term_flush` are
written there instead, so goldens can assert the exact emitted byte stream
(autowrap `ESC[?7l`/`ESC[?7h`, parked cursor, bands). A headless capture run
keeps the requested `--tui-mode` (default inline) instead of forcing the
fullscreen grid dump.

Fatal-signal coverage: `os_sig_cleanup` installs the restore
handler for HUP, INT, QUIT, ABRT, **BUS, FPE**, SEGV and TERM; `term_restore` is
idempotent and resets autowrap (`ESC[?7h`), bracketed paste, SGR, cursor,
alternate screen and the OSC 11 background.
