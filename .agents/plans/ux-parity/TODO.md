# TODO — ux-parity

Status: done
Provenance: `77216fa` → `443162d`
Proof of record: `eb4602e` (v0.3.0, user-approved)

Goal: match agentc's picker/UI closely; make the inline erase/restore robust
and the inline capture target-independent.

## Done

- [x] mac: do not redefine `snprintf`/`vsnprintf` under the Apple SDK —
      `3df8b16`
- [x] inline erase = `\r` + `ESC[J` to end-of-screen on the resize and
      picker-close paths; restore termios/alt-screen/cursor/autowrap on every
      path, hook registered before raw mode — `8e7cee7`
- [x] `tui-inline-capture` asserts the settled final frame + protocol markers
      (`?7l`/`?7h`, hidden cursor, no alt screen, composer/status rows,
      erase-to-end) and is identical on x86-64 and qemu-aarch64 — `443162d`
- [x] release v0.1.0 — `fef702d`
- [x] CI: macOS suite informational pending hardware verification; `gh --repo` —
      `d322d9d`, `d076ced`

## Note

- The plan's UX-CORE / UX-TUI / UX-DISC deltas (reasoning default `medium`,
  in-TUI `/resume`, wrap-around menus, Codex discovery) had already been
  delivered by the parity2 commits `66e4958`, `4c30c5b`, `4747c59`; they were
  not re-implemented.

## Uncommitted

- (none)
