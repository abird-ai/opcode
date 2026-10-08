#!/bin/sh
# M4 TUI tests: scripted headless run over a deterministic replay.
set -e
cd "$(dirname "$0")/.."
[ -x build/opcode ] || make -s all
[ -f tests/data/agent_replay.wire ] || python3 tests/gen_agent_replay.py
[ -f tests/data/agent_replay_queue.wire ] || python3 tests/gen_agent_replay.py
[ -f tests/data/agent_replay_cards.wire ] || python3 tests/gen_agent_replay.py
[ -f tests/data/agent_replay_markdown.wire ] || python3 tests/gen_agent_replay.py
[ -f tests/data/agent_replay_hostile.wire ] || python3 tests/gen_agent_replay.py
[ -f tests/data/agent_replay_scroll.wire ] || python3 tests/gen_agent_replay.py

# A developer/user config (e.g. ~/.config/opcode/config.jsonc) can pin
# default_provider/default_model and silently override --provider, and a
# state dir can seed the editor history.  Isolate both in fresh temp dirs so
# the golden is the same here and in CI.
tui_tmp=$(mktemp -d "${TMPDIR:-/tmp}/opcode-tui.XXXXXX")
trap 'rm -rf "$tui_tmp"' EXIT INT TERM HUP
export XDG_CONFIG_HOME="$tui_tmp/config"
export XDG_STATE_HOME="$tui_tmp/state"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_STATE_HOME"

fail=0
if timeout 30 ./build/opcode --headless 60x14 --script tests/scripts/tui.rsc \
        --provider anthropic --api-key test --no-session \
        --replay tests/data/agent_replay.wire > build/tui.out 2> build/tui.err; then
    :
else
    echo "FAIL tui-run"
    sed -n '1,5p' build/tui.err || true
    fail=1
fi
if cmp -s build/tui.out tests/data/tui.expected; then
    echo "ok   tui-screens"
else
    echo "FAIL tui-screens"
    diff -u tests/data/tui.expected build/tui.out | head -60 || true
    fail=1
fi

# Busy submits queue instead of replacing the composer; the idle tick drains
# them in order, one per tick.  A dedicated replay keeps turn 1 on a tool call.
if timeout 30 ./build/opcode --headless 60x14 --script tests/scripts/tui_queue.rsc \
        --provider anthropic --api-key test --no-session \
        --replay tests/data/agent_replay_queue.wire > build/tui-queue.out 2> build/tui-queue.err; then
    :
else
    echo "FAIL tui-queue-run"
    sed -n '1,5p' build/tui-queue.err || true
    fail=1
fi
if cmp -s build/tui-queue.out tests/data/tui_queue.expected; then
    echo "ok   tui-queue"
else
    echo "FAIL tui-queue"
    diff -u tests/data/tui_queue.expected build/tui-queue.out | head -60 || true
    fail=1
fi

# Esc while busy aborts and returns the queued messages to the editor; the
# slash menu's Esc only dismisses the menu.
if timeout 30 ./build/opcode --headless 60x14 --script tests/scripts/tui_queue_esc.rsc \
        --provider anthropic --api-key test --no-session \
        --replay tests/data/agent_replay_queue.wire > build/tui-queue-esc.out 2> build/tui-queue-esc.err; then
    :
else
    echo "FAIL tui-queue-esc-run"
    sed -n '1,5p' build/tui-queue-esc.err || true
    fail=1
fi
if cmp -s build/tui-queue-esc.out tests/data/tui_queue_esc.expected; then
    echo "ok   tui-queue-esc"
else
    echo "FAIL tui-queue-esc"
    diff -u tests/data/tui_queue_esc.expected build/tui-queue-esc.out | head -60 || true
    fail=1
fi

# Tool cards: a running card (frozen spinner/elapsed under --headless), a
# finished err card and a finished ok card, the collapsed "... (+N lines)"
# marker, and Ctrl+O expanding the last card.
if timeout 30 ./build/opcode --headless 60x20 --script tests/scripts/tui_cards.rsc \
        --provider anthropic --api-key test --no-session \
        --replay tests/data/agent_replay_cards.wire > build/tui-cards.out 2> build/tui-cards.err; then
    :
else
    echo "FAIL tui-cards-run"
    sed -n '1,5p' build/tui-cards.err || true
    fail=1
fi
if cmp -s build/tui-cards.out tests/data/tui_cards.expected; then
    echo "ok   tui-cards"
else
    echo "FAIL tui-cards"
    diff -u tests/data/tui_cards.expected build/tui-cards.out | head -60 || true
    fail=1
fi

# Markdown: one streamed assistant turn with headings, inline bold/code,
# bullets, a quote and a fenced block, rendered by the live block model.
if timeout 30 ./build/opcode --headless 60x20 --script tests/scripts/tui_markdown.rsc \
        --provider anthropic --api-key test --no-session \
        --replay tests/data/agent_replay_markdown.wire > build/tui-md.out 2> build/tui-md.err; then
    :
else
    echo "FAIL tui-markdown-run"
    sed -n '1,5p' build/tui-md.err || true
    fail=1
fi
if cmp -s build/tui-md.out tests/data/tui_markdown.expected; then
    echo "ok   tui-markdown"
else
    echo "FAIL tui-markdown"
    diff -u tests/data/tui_markdown.expected build/tui-md.out | head -60 || true
    fail=1
fi

# Wide/combining composer: CJK glyphs occupy two columns, an enclosed
# ideograph and emoji are width 2, and a combining acute attaches to its base
# glyph rather than taking a column of its own.
if timeout 30 ./build/opcode --headless 40x8 --script tests/scripts/tui_wcwidth.rsc \
        --provider anthropic --api-key test --no-session > build/tui-wc.out 2> build/tui-wc.err; then
    :
else
    echo "FAIL tui-wcwidth-run"
    sed -n '1,5p' build/tui-wc.err || true
    fail=1
fi
if cmp -s build/tui-wc.out tests/data/tui_wcwidth.expected; then
    echo "ok   tui-wcwidth"
else
    echo "FAIL tui-wcwidth"
    diff -u tests/data/tui_wcwidth.expected build/tui-wc.out | head -60 || true
    fail=1
fi

# Banner + scrollback frame capture: --headless-capture redirects fd-1 writer
# bytes (banner, live footer, autowrap bracket, parked cursor) to a file, so the
# legacy scrollback UX can be asserted byte-for-byte.  The banner must appear
# exactly once even though the footer is redrawn.
if timeout 30 ./build/opcode --headless 40x8 --tui-mode scrollback \
        --headless-capture build/tui-banner.bin \
        --script tests/scripts/tui_banner.rsc \
        --provider anthropic --api-key test --no-session > build/tui-banner.out 2> build/tui-banner.err; then
    :
else
    echo "FAIL tui-banner-run"
    sed -n '1,5p' build/tui-banner.err || true
    fail=1
fi
if cmp -s build/tui-banner.bin tests/data/tui_banner_capture.expected; then
    echo "ok   tui-banner-capture"
else
    echo "FAIL tui-banner-capture"
    cat -v tests/data/tui_banner_capture.expected > build/tui-banner-exp.txt
    cat -v build/tui-banner.bin > build/tui-banner-got.txt
    diff -u build/tui-banner-exp.txt build/tui-banner-got.txt | head -40 || true
    fail=1
fi
nban=$(grep -a -c "opcode $(cat VERSION)" build/tui-banner.bin || true)
if [ "$nban" -eq 1 ] && grep -aq '?7l' build/tui-banner.bin && grep -aq '?7h' build/tui-banner.bin; then
    echo "ok   tui-banner-once"
else
    echo "FAIL tui-banner-once (count=$nban)"
    fail=1
fi

# Hostile scrollback capture: a tool name and argument preview carrying terminal
# escapes must be sanitized before the inline card writer reaches stdout.  The
# capture must show U+FFFD replacements and no raw ESC/OSC/C1/BEL.
if timeout 30 ./build/opcode --headless 60x14 --tui-mode scrollback \
        --headless-capture build/tui-hostile.bin \
        --script tests/scripts/tui_hostile.rsc \
        --provider anthropic --api-key test --no-session \
        --replay tests/data/agent_replay_hostile.wire > build/tui-hostile.out 2> build/tui-hostile.err; then
    :
else
    echo "FAIL tui-hostile-run"
    sed -n '1,5p' build/tui-hostile.err || true
    fail=1
fi
if python3 - <<'PY'
data = open("build/tui-hostile.bin", "rb").read()
fffd = b"\xef\xbf\xbd"
ok = True
ok &= b"missing" + fffd + b"tool" in data
ok &= fffd + b"[2K" in data
ok &= fffd + b"]0;PWNED" in data
ok &= b"\x1b]" not in data
ok &= b"\x07" not in data
ok &= b"\xc2\x9b" not in data
ok &= b"missing\x1btool" not in data
raise SystemExit(0 if ok else 1)
PY
then
    echo "ok   tui-hostile-sanitized"
else
    echo "FAIL tui-hostile-sanitized"
    cat -v build/tui-hostile.bin | head -40
    fail=1
fi

# Scrollback Ctrl+O: the finished card is the tail output, so the key must
# erase its printed rows and reprint it expanded.
if timeout 30 ./build/opcode --headless 60x20 --tui-mode scrollback \
        --headless-capture build/tui-scroll.bin \
        --script tests/scripts/tui_scroll_cards.rsc \
        --provider anthropic --api-key test --no-session \
        --replay tests/data/agent_replay_scroll.wire > build/tui-scroll.out 2> build/tui-scroll.err; then
    :
else
    echo "FAIL tui-scroll-cards-run"
    sed -n '1,5p' build/tui-scroll.err || true
    fail=1
fi
if python3 - <<'PY'
import re
data = open("build/tui-scroll.bin", "rb").read()
ok = False
for m in re.finditer(rb"\x1b\[(\d+)A\x1b\[J", data):
    if int(m.group(1)) < 2:
        continue
    tail = data[m.end():]
    if b" line1" in tail and b"(+3 lines)" not in tail:
        ok = True
ok &= data.count(b"line1") == 1
ok &= data.count(b"(+3 lines)") == 1
raise SystemExit(0 if ok else 1)
PY
then
    echo "ok   tui-scroll-ctrl-o"
else
    echo "FAIL tui-scroll-ctrl-o"
    cat -v build/tui-scroll.bin | tail -30
    fail=1
fi

# Owned inline region capture (S7): a finished turn is committed to scrollback
# with newline mode, the live region is repainted in place with a hidden cursor
# parked at its top-left, and a mid-turn resize clears the region with relative
# moves only.  Byte-for-byte golden plus structural assertions.
if timeout 40 ./build/opcode --headless 60x10 --tui-mode inline \
        --headless-capture build/tui-inline.bin \
        --script tests/scripts/tui_inline.rsc \
        --provider anthropic --api-key test --no-session \
        --replay tests/data/agent_replay.wire > build/tui-inline.out 2> build/tui-inline.err; then
    :
else
    echo "FAIL tui-inline-run"
    sed -n '1,5p' build/tui-inline.err || true
    fail=1
fi
if cmp -s build/tui-inline.bin tests/data/tui_inline_capture.expected; then
    echo "ok   tui-inline-capture"
elif command -v python3 > /dev/null 2>&1 && \
        python3 - tests/data/tui_inline_capture.expected build/tui-inline.bin <<'PY'
import re, sys

exp = open(sys.argv[1], "rb").read()
got = open(sys.argv[2], "rb").read()

# The capture is a sequence of owned-region frames.  A frame is bracketed by
# autowrap-off (`ESC[?7l`); the banner precedes the first one.  Erase-to-end of
# the parked region top is the current `\r ESC[J`, or the older counted
# `ESC7 (ESC[2K ESC[1B)* ESC[2K ESC8` run.
SEP = b"\x1b[?7l"
CLEAR = re.compile(
    rb"(?:\r\x1b\[J)|(?:\x1b7(?:\x1b\[2K\x1b\[1B)*\x1b\[2K\x1b8)")


def final_frame(data):
    """The settled region frame: the last frame that paints a row.  Erase-only
    frames (the resize/shutdown clears) carry no row paint and are part of the
    repaint schedule, not the terminal state.  A leading clear is stripped so a
    target that folds it into the paint compares equal to one that emits it as
    a separate frame."""
    last = None
    for i, chunk in enumerate(data.split(SEP)):
        if i == 0:
            continue
        body = CLEAR.sub(b"", chunk, count=1)
        if b"\x1b[2K" in body:
            last = body
    return last


ef, gf = final_frame(exp), final_frame(got)
reasons = []
if ef is None or gf is None:
    reasons.append("no painted region frame")
elif ef != gf:
    reasons.append("settled frame differs (expected %d bytes, got %d)"
                   % (len(ef), len(gf)))

# Inline protocol: autowrap is bracketed off/on around the paint, the cursor is
# hidden and parked in column 1, and the alternate screen is never entered.
for marker, name in ((SEP, "autowrap off"), (b"\x1b[?7h", "autowrap on"),
                     (b"\x1b[?25l", "hidden cursor"), (b"\x1b[1G", "column 1")):
    if marker not in got:
        reasons.append("missing %s" % name)
if b"\x1b[?1049h" in got:
    reasons.append("entered alternate screen")

# The shrink path must clear the old region to the end of the screen, or the
# rows the shorter region no longer paints would survive as stale/stacked rows.
if CLEAR.search(got) is None:
    reasons.append("no erase-to-end on the shrink path")

# The settled frame is exactly the composer (top rule, prompt, bottom rule) and
# its status line, so a dropped/stale/duplicated region row fails here too.
if gf is not None:
    if b"\xe2\x94\x80" not in gf:
        reasons.append("missing composer rules")
    if b"Press Ctrl-C once to clear" not in gf:
        reasons.append("missing composer prompt")
    if b"anthropic/claude-sonnet-4-5" not in gf or b"ready" not in gf:
        reasons.append("missing status line")
    if gf.count(b"\x1b[2K") != (ef or b"").count(b"\x1b[2K"):
        reasons.append("unexpected region row count")

for r in reasons:
    sys.stderr.write("  %s\n" % r)
raise SystemExit(0 if not reasons else 1)
PY
then
    # The repaint schedule (how many frames, and whether a shrink clear is
    # emitted inside a paint or as its own frame) depends on how many replay
    # events the poll loop coalesces per iteration, which varies by host speed
    # and emulator -- it even varies run-to-run on native x86 under load.  The
    # settled frame and the protocol markers above are invariant; native x86
    # still matches byte-for-byte first, so only a repaint-schedule difference
    # reaches this branch.
    echo "ok   tui-inline-capture (settled frame + protocol)"
else
    echo "FAIL tui-inline-capture"
    cat -v tests/data/tui_inline_capture.expected > build/tui-inline-exp.txt
    cat -v build/tui-inline.bin > build/tui-inline-got.txt
    diff -u build/tui-inline-exp.txt build/tui-inline-got.txt | head -40 || true
    fail=1
fi
# The region must hide the cursor, bracket every frame with autowrap off/on,
# park the cursor in column 1, and never enter the alternate screen.
if grep -aq '?7l' build/tui-inline.bin && grep -aq '?7h' build/tui-inline.bin && \
        grep -aq '?25l' build/tui-inline.bin && grep -aq '1G' build/tui-inline.bin && \
        ! grep -aq '?1049h' build/tui-inline.bin; then
    echo "ok   tui-inline-region"
else
    echo "FAIL tui-inline-region"
    fail=1
fi

# Resize beyond the grid cap: tui_script_resize clamps each dimension to
# TUI_MAX_DIM (4096) before term_set_size/tui_resize, so a >cap "resize" cannot
# ask grid_resize for a size it rejects (which would silently keep the old
# geometry).  The dump must therefore carry the full clamped 4096 rows.
cat > build/tui-resize.rsc <<'EOF'
resize 20 9000
print-screen
quit
EOF
if timeout 60 ./build/opcode --headless 60x10 --script build/tui-resize.rsc \
        --provider anthropic --api-key test --no-session \
        > build/tui-resize.out 2> build/tui-resize.err; then
    :
else
    echo "FAIL tui-resize-clamp-run"
    sed -n '1,5p' build/tui-resize.err || true
    fail=1
fi
nrows=$(wc -l < build/tui-resize.out || echo 0)
if [ "$nrows" -ge 4096 ] && [ "$nrows" -le 4097 ]; then
    echo "ok   tui-resize-clamp"
else
    echo "FAIL tui-resize-clamp (rows=$nrows)"
    fail=1
fi

# Sticky bottom vs anchored scroll: the first dump is pinned to the running
# tool card (bottom), PgUp anchors the reading position, and the finished card
# must not snap the viewport back to the bottom.
if timeout 40 ./build/opcode --headless 40x8 --tui-mode fullscreen \
        --headless-capture build/tui-sticky.bin \
        --script tests/scripts/tui_sticky.rsc \
        --provider anthropic --api-key test --no-session \
        --replay tests/data/agent_replay_cards.wire > build/tui-sticky.out 2> build/tui-sticky.err; then
    :
else
    echo "FAIL tui-sticky-run"
    sed -n '1,5p' build/tui-sticky.err || true
    fail=1
fi
if cmp -s build/tui-sticky.out tests/data/tui_sticky.expected; then
    echo "ok   tui-sticky"
else
    echo "FAIL tui-sticky"
    diff -u tests/data/tui_sticky.expected build/tui-sticky.out | head -60 || true
    fail=1
fi

# /theme dark, /theme light and an unknown name each print their notice and
# repaint the frame (headless dumps the resolved colours as text).
for tname in dark light unknown; do
    if timeout 30 ./build/opcode --headless 50x8 --script "tests/scripts/tui_theme_$tname.rsc" \
            --provider anthropic --api-key test --no-session \
            --replay tests/data/agent_replay.wire > "build/tui-theme-$tname.out" 2> "build/tui-theme-$tname.err"; then
        :
    else
        echo "FAIL tui-theme-$tname-run"
        sed -n '1,5p' "build/tui-theme-$tname.err" || true
        fail=1
    fi
    if cmp -s "build/tui-theme-$tname.out" "tests/data/tui_theme_$tname.expected"; then
        echo "ok   tui-theme-$tname"
    else
        echo "FAIL tui-theme-$tname"
        diff -u "tests/data/tui_theme_$tname.expected" "build/tui-theme-$tname.out" | head -60 || true
        fail=1
    fi
done

# /new opens a fresh persisted session; that session must carry a
# model_change record or resuming it loses the provider/model.
sdir=build/tui-new-sessions
rm -rf "$sdir"
mkdir -p "$sdir"
cat > build/tui-new.rsc <<'EOF'
prompt /new
quit
EOF
rc=0
timeout 30 ./build/opcode --headless 60x14 --script build/tui-new.rsc \
    --provider anthropic --api-key test --session-dir "$sdir" \
    > build/tui-new.out 2> build/tui-new.err || rc=$?
n=0
bad=0
for f in "$sdir"/*.jsonl; do
    [ -e "$f" ] || continue
    n=$((n + 1))
    grep -q '"type":"model_change"' "$f" || bad=1
done
if [ "$n" -ge 2 ] && [ "$bad" -eq 0 ]; then
    echo "ok   tui-new-model-change"
else
    echo "FAIL tui-new-model-change (files=$n missing-model-change=$bad rc=$rc)"
    sed -n '1,20p' build/tui-new.err || true
    fail=1
fi

# the TUI parser is shared with -p/--mode: offline, max-tokens and template
# are accepted here too (--template errors clearly when it does not exist)
rc=0
timeout 30 ./build/opcode --headless 60x14 --script build/tui-new.rsc \
    --provider anthropic --api-key test --no-session --offline \
    --replay tests/data/agent_replay.wire --max-tokens 123 \
    > /dev/null 2>&1 || rc=$?
if [ "$rc" -eq 0 ]; then
    echo "ok   tui-shared-agent-flags"
else
    echo "FAIL tui-shared-agent-flags (rc=$rc)"
    fail=1
fi
rc=0
out=$(timeout 30 ./build/opcode --headless 60x14 --script build/tui-new.rsc \
    --template no-such-template 2>&1) || rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'template not found: no-such-template'; then
    echo "ok   tui-template-flag"
else
    echo "FAIL tui-template-flag (rc=$rc out=$out)"
    fail=1
fi
exit $fail
