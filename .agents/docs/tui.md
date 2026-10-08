# Terminal UI

The TUI is a small, allocation-light shell over the same async agent API used by
`-p` and `--mode json`: `agent_init` / `agent_submit` / `agent_step` plus a UI
hook that receives typed `SE_*` events. It does not reimplement the agent and it
does not parse JSON.

---

## 1. Modes and terminal lifecycle (`src/app/tui.s`, `src/tui/term.s`)

Three renderers over the same state. The mode values are `scrollback=0`,
`inline=1` (default), `fullscreen=2`, and `auto` parses to inline.

- **inline (default, `--tui-mode inline`)** — the app owns a rectangular bottom
  region (`transcript tail + queue strip + composer + menu + footer`) recomputed
  every frame. The hidden cursor is parked at the region's top-left and the
  editor's reverse-video cell is the visible caret. Every owned row is repainted
  under a full-line clear inside one `ESC[?7l`/`ESC[?7h` write. Finished whole
  transcript messages are committed at the region's top edge with newline mode
  and flow up into real scrollback; the commit is progressive — the finished
  prefix (whole messages with no running tool card) is printed on each frame
  while a run streams, not only when the agent goes idle, and `t_in_offset`
  tracks the rows already printed so no row is written twice. A live block
  taller than the region shows its tail. A resize clears the region with
  cursor-relative movement only, then re-anchors and repaints; the SIGWINCH pipe
  and a size poll share one resize path. Both dimensions are clamped to 4096
  (the renderer's `GRID_MAX`) so an oversized terminal or a script `resize`
  cannot overrun the region state.
- **scrollback (`--tui-mode scrollback`)** — the append-only path: the
  terminal's normal scrollback is the transcript, finalized text is streamed to
  stdout once, and a live footer is redrawn by moving up over the previous frame.
  Existing sessions are replayed once into scrollback (`inline_history`) so
  `--continue` shows the conversation.
- **fullscreen (`--tui-mode fullscreen`)** — alternate screen, full cell-grid
  renderer, differential row updates, no scrollback interference. The status
  footer is the last row, the composer sits directly above it, and the menu sits
  above the composer (between the transcript and the composer).

`term_init()` saves termios, enables raw mode, hides the cursor, installs
SIGWINCH (delivered as one byte on a pipe watched by the loop) and, in
fullscreen mode, enters the alternate screen and clears it. `term_restore()` is
idempotent, resets autowrap (`ESC[?7h`), bracketed paste, SGR, cursor, the
alternate screen and the OSC 11 background, is installed as `g_exit_hook`, and
is also called from `os_sig_cleanup` before fatal signals are re-raised
(HUP, INT, QUIT, ABRT, BUS, FPE, SEGV, TERM). Headless test runs set
`g_tui_headless` first; `term_init` then touches no terminal state and
`term_set_size` supplies the dimensions. `--headless-capture FILE` keeps the
requested mode and routes fd-1 writer bytes to FILE, so a golden can assert the
inline/fullscreen byte stream (banner, autowrap bracket, parked cursor, bands)
instead of only the grid dump. Before `term_init`, `tui_banner()` prints one dim
line above the live region into real scrollback: `opcode <version>`, then
`tools: <name, name, ...>` when the core registry is non-empty, then
`session: <id>` when a session is active. The whole body is run through
`grid_sanitize_bytes`, so the version, tool names and session id cannot inject
controls; the banner is suppressed for a plain `--headless` grid dump and
emitted when a capture sink is active.

## 2. Renderer (`src/tui/render.s`)

- Cell = 24 bytes: `{ u32 cp; u32 comb; u32 fg; u32 bg; u16 attrs; u16 pad }`;
  attrs are `A_BOLD`, `A_UNDERLINE`, `A_DIM`, `A_REVERSE`, `A_ITALIC`, and
  `comb` carries one combining mark attached to the base glyph. Grids are
  caller-allocated and their size is exported as `grid_size`.
- A width-2 codepoint occupies two cells and marks the second `CELL_CONT`; the
  emitter skips that cell because the base glyph covers both terminal columns.
  A wide glyph that would cross the right edge is blanked, never split, so no
  stray continuation cell survives. A genuine combining mark attaches to the
  preceding base cell (skipping a `CELL_CONT`) and spends no column. C0/DEL
  controls are stored as a space and the Cf format characters (soft hyphen,
  ZWSP/ZWNJ/ZWJ, BOM, bidi controls) are dropped; the output-side emitter also
  refuses to write a raw control or a non-printable attached mark.
- UTF-8 is decoded per codepoint with the single strict decoder
  `utf8_decode` (`src/base/uni.s`), and `grid_sanitize` (`src/tui/render.s`) is
  the single per-codepoint filter (`view.s:utf8dec` and `card.s:card_sanitize_cp`
  are aliases). Overlong/surrogate/>U+10FFFF/bad continuation all become
  U+FFFD. The transcript/view layer and the composer share the `src/base/uni.s`
  width table (`utf8_wcwidth`, with `view_wcwidth` a tail call into it), so
  measured and drawn rows cannot disagree; wide = 2, combining/zero-width = 0.
- `render_flush` diffs the grid against the previous frame, emits minimal SGR
  runs and one `writev`, then positions the cursor once. `render_dump` writes
  the grid as plain text for headless tests (trailing blanks trimmed).
  `render_build` resolves each cell's ARGB through the active theme's emitter
  (`src/tui/theme.s`), so 256/16-colour terminals get the downgraded SGR and a
  `TH_NO_BG` cell emits `SGR 49`; there is no fixed palette.

## 3. View buffer (`src/tui/view.s`)

A fixed-row styled transcript buffer: 20 000 rows max, each row 256 text bytes +
256 style bytes (stride 512). Styles are ids `VS_TEXT`, `VS_DIM`, `VS_ASSIST`,
`VS_USER`, `VS_TOOL`, `VS_TOOL_OUT`, `VS_DIFF_ADD`, `VS_DIFF_DEL`,
`VS_DIFF_HUNK`, `VS_ERR`, `VS_CODE`; colors are resolved in `view_draw` from the
active theme's slots (`view_style_color`), so a `/theme` change repaints on the
next frame. The view wraps text at the current display width, tracks a
mark for truncation (used while re-rendering the tail of a stream), scrolls over
the visible viewport, and draws only visible rows. Each row records its byte
length (a `'\n'` commits the row, including empty rows), so multiline text and
markdown code blocks keep their blank lines and never render blank.

## 4. Composer (`src/tui/editor.s`)

The composer is a multiline input area:

- Geometry: two full-width dim rules (`─` U+2500, or `-` when
  `editor_set_ascii(1)`, which the shell selects for `TERM=dumb`/`OPCODE_ASCII`)
  bracketing up to four visible input rows. Text starts at column 0; the last
  column is reserved for the caret. Wrapping is by display width (`utf8_wcwidth`
  from `src/base/uni.s`): a codepoint wraps when `col + wcwidth > width-1`
  (strict `>`); a newline always breaks. `editor_visual_rows` is `text_rows + 2`.
  `editor_render` degrades for short allocations (top rule at h>=3, bottom at
  h>=2, at least one input row) and scrolls internally so the caret row is
  visible.
- Caret: the cell under the caret is reverse-video and the hardware cursor is
  parked on it; `editor_render` returns `(-1,-1)` when the caret is not visible.
- Empty state: the shell passes the placeholder cstr; it is drawn dim+muted only
  when the buffer is empty, the transcript is empty and no run is in flight, and
  is clipped rather than wrapped.
- Keymap: readline. `Ctrl+A`/`Home` line start, `Ctrl+E`/`End` line end,
  `Ctrl+Home`/`Ctrl+End` buffer bounds, `Ctrl+B`/`Left` and `Ctrl+F`/`Right` char
  motion, `Alt+B`/`Ctrl+Left` and `Alt+F`/`Ctrl+Right` word motion,
  `Ctrl+W`/`Alt+Backspace` and `Alt+D`/`Ctrl+Delete` word kills, `Ctrl+K` kill to
  end of line (eating one newline), `Ctrl+U` kill to start of line, `Ctrl+Y`
  yank, `Ctrl+T` transpose, `Backspace`/`Delete`, `Up`/`Down` history when the
  buffer has no newline (otherwise vertical motion), `Enter` submit (returns 1,
  inserts nothing), `Alt+Enter` insert `\n`, `Tab` `@file` completion. The opcode
  shift-selection extension is present but not rendered.
- Kill ring: one slot (the last kill). `editor_take(e)` expands any
  `[Pasted text #N +M lines]` markers and returns an owned string (free with
  `mem_free`), then clears the buffer.
- Paste: `input.s` emits one `K_PASTE` carrying the raw bytes; `editor_paste`
  normalises CRLF/CR to LF, expands tabs, inserts directly for <= 10 lines and
  otherwise stores the body and inserts `[Pasted text #N +M lines]`.
- History: disk-backed, oldest-first, up to 1000 entries. `editor_history_append`
  skips empty and multi-line submissions and appends `text + "\n"` (duplicates
  are written but collapsed again on load); `editor_history_load` reads the whole
  file (16 MiB cap), strips one `\r`, skips empty lines and dedupes consecutive
  entries. Up/Down browse with a live-buffer save/restore; the caret goes to the
  end.
- Completion: `editor_complete(e, dir)` handles a caret token starting with `@`
  after whitespace, scores directory entries (case-insensitive prefix beats
  subsequence, shorter names break ties, directories get `/`) and replaces the
  token; on macOS it no-ops. The shell passes `dir = 0` to use the cwd.

## 5. Input (`src/tui/input.s`)

Incremental byte parser with a 64-event ring. States: ground, ESC, CSI, SS3,
bracketed paste, and a string state that swallows OSC/DCS/APC payloads until BEL
or ST. CSI parameters and modifiers are decoded for arrows, home/end/page keys,
delete and function keys; UTF-8 sequences may be split across arbitrary feed
boundaries and a stale partial sequence is cancelled by an intervening ASCII
byte. A lone ESC is deferred and reported as `K_ESC` once the queue drains, so
`Esc` aborts the current run promptly without breaking escape sequences.

`InputEvent` is 32 bytes (`input_ev_size`): `{ u32 key; u32 cp; u32 mods; u32 pad;
u64 paste; u64 paste_len; }`. Bracketed paste (`ESC[200~ ... ESC[201~`) now
accumulates the raw bytes verbatim and emits exactly one `K_PASTE` event whose
`paste`/`paste_len` point at that buffer (valid until the next paste starts); the
shell calls `editor_paste` with it instead of feeding `editor_key`.

## 6. Markdown (`src/tui/markdown.s`)

A streaming block model (`markdown.inc` holds the layouts and style tags).
`md_append` scans the source into `MD_PARA`/`MD_HEAD`/`MD_BULLET`/`MD_CODE`/
`MD_QUOTE`/`MD_RULE` blocks and re-parses only the trailing incomplete block,
so completed blocks keep their wrapped rows; `md_set_width` re-renders all of
them once (resize/theme). A blank line ends a paragraph, `#`..`######` starts a
heading, `- `/`* `/`+ ` a bullet, `> ` a quote, a line of >=3 `-`/`*`/`_` a rule,
and a ```` ``` ````/`~~~` fence buffers verbatim until a closing fence of the
same char. Paragraphs join source lines with a space and wrap word-granularly
(longer words split per codepoint); bullets emit `"- "` in the accent style and
indent continuations by two columns; fenced code is clipped, not wrapped.

Inline `**bold**`, `` `code` ``, `*italic*`/`_italic_` are parsed into styled
runs (an unterminated marker stays literal); each row stores UTF-8 plus one
style byte per byte. `md_emit_view` maps tags to view styles (`VS_MD_ACCENT`,
`VS_CODE`, `VS_DIM`, `VS_MD_THINK`, plus bold/dim/italic attribute bits) and
`md_emit_ansi` emits SGR runs for inline mode. Headings <= H1 use the accent
slot, H3-6 add dim; inline code is `TH_CODE`, fenced code `TH_THINKING`.

## 7. Agent integration

The TUI installs `g_agent_ui_fn` and translates events:

- `SE_TEXT` deltas append to the live assistant row; completed blocks are
  committed to the view buffer.
- Thinking and errors get their own styled rows/notes. Tool results render as
  diff-coloured cards (`src/tui/card.s`), not plain text: the header is
  `[<name>] <48-column arg preview>` with a right-aligned spinner/elapsed while
  running or `ok`/`err <duration>ms` when finished, the body shows the tail of
  the output (3 collapsed / 10 expanded lines) with a dim `... (+N lines)`
  marker, and `edit` lines starting `+`/`-`/`@` take the diff add/del/hunk
  styles. `Ctrl+O` toggles the last card collapsed/expanded.
- The status line is a provider-segment footer (`src/tui/status.s`), not a fixed
  string: LEFT renders `model` (`<provider>/<id>`), `think:<level>`, and
  `tok:<input>/<output>`; RIGHT renders `ready`, or `<spinner> <elapsed>ms` while
  busy. A `$cost` segment is supported by the provider but omitted because the
  TUI has no pricing table, and there is no context-window footer in this build.
- Key precedence per event: refresh the menu from the editor text; if the menu is
  open consume exactly Up/Down/Tab/Enter/Esc; then `Ctrl+C` (non-empty clears,
  empty quits within 1 s), `Ctrl+D` (empty quits), `Esc` (busy aborts, else
  clears), PageUp/PageDown scroll the transcript, and finally `editor_key`;
  `editor_key == 1` accepts/submits.
- Submit: `editor_take` then dispatch the built-ins (`/quit`, `/new`, `/clear`,
  `/help`, `/model [id]`, `/theme [dark|light|<name>]`,
  `/thinking [off|low|medium|high]`, `/compact`) then `/skill:<name> [args]`,
  prompt-template names and plugin/extension commands; otherwise append the user
  block, `editor_history_append` and `agent_submit`.
- The slash-command menu (`src/tui/menu.s`) opens on a leading `/` word, filters
  by prefix, and lists the built-ins `clear help model new quit theme thinking
  compact`, then prompt-template names, skill names as `skill:<name>` and
  extension commands when `opcode_host_command_count` is non-zero. The selected
  row is reverse-video; the menu sits above the composer in fullscreen and below
  it inline (between the composer and the footer).
- `Esc` aborts the current run and returns queued input to the editor; `Ctrl+C`
  clears the input and a second `Ctrl+C` quits. `/quit` exits and `/new` starts
  a fresh session.

## 8. Headless script runner

`--headless WxH --script FILE` runs the real TUI against the in-memory grid and
prints it as text, which is how the golden TUI tests work. Script verbs (one per
line, `#` comments): `type TEXT`, `key NAME` (`up`, `down`, `enter`, `alt-enter`
(inserts a newline), `esc`, `tab`, `backspace`, `ctrl-c`, `ctrl-o`, …),
`prompt TEXT` (submit a message), `wait MS`, `resize W H`, `print-screen`,
`quit`.
`tests/scripts/tui.rsc` and `tests/data/tui.expected` are the reference example.

## 9. Performance rules

1. Deltas are appended to buffers; rendering is tick-driven and never per token.
2. Layout state is a single shell struct; only the footer or changed rows are
   redrawn.
3. The fullscreen flush is one `writev` per frame; the inline renderer writes
   only the footer and streamed text.
4. Resize is handled once per SIGWINCH drain and re-renders from the view buffer.

## 10. Themes (`src/tui/theme.s`)

Built-ins are `dark` and `light`; `system` picks a base from `$COLORFGBG`'s last
field (0-6 and 8 dark, 7 and 9-15 light, anything else dark). Named themes are
`themes/<name>.jsonc` under the config dir and, when the project is trusted,
`<cwd>/.opcode/themes`; the stem is `[A-Za-z0-9._-]{1,64}`, no `.` or `..`. The
schema is `base` (`dark`/`light`) plus the slot keys `fg, bg, muted, accent, ok,
warn, err, user, assistant, thinking, tool, diff_add, diff_del, code,
tool_ok_bg, tool_err_bg, tool_bg`. Precedence is slot by slot, most specific
last: built-in base, the `<config>/theme.jsonc` base, then the named file's
base; then the config file's slots, then the named file's slots. Project themes
resolve only under the trust verdict the app passes in; the TUI never derives
trust itself.

The startup name is `--theme` (CLI) > config `theme` > `system`. `/theme` with
no argument toggles dark<->light; `/theme <name>` applies a name and prints
`theme: <name>` (or `theme: unknown '<name>'`). A successful apply invalidates
the fullscreen frame so every resolved cell colour is repainted; inline leaves
its already-committed scrollback untouched. A fixed dark/light palette owns its
background, so the TUI pushes `TH_BG` with `OSC 11` at startup and after every
apply, and resets it with `OSC 111` on exit; `system`/named themes keep the
terminal's own background. Colours are 24-bit by default; `COLORTERM`
`truecolor`/`24bit` selects true colour, else `TERM`/`COLORTERM` `256` selects
the 6x6x6 cube with the near-neutral dark greyscale-ramp special case, else the
16 ANSI colours (muted pinned to index 8). All SGR fg/bg emission in the
fullscreen and inline paths goes through `theme_emit_fg`/`theme_emit_bg`;
`TH_NO_BG` is emitted as `SGR 49`.
