#!/usr/bin/env python3
"""PTY tests for the TUI presentation modes and the owned inline region.

  python3 tests/tui_pty.py

Runs the real build/opcode behind a PTY and feeds the byte stream through a
small VT parser, so both the raw escape protocol and the resulting scrollback
can be asserted:

  * the three modes plus `auto` (scrollback=0, inline=1 default, fullscreen=2);
  * inline owns the bottom region: hidden cursor parked at the region top-left,
    autowrap off/on around every frame, never the alternate screen;
  * finished transcript lines are committed once, in order, and the region
    chrome (rules, composer, status footer) never reaches scrollback;
  * a resize storm (idle and mid-turn) keeps that invariant.
"""
import fcntl
import os
import pty
import select
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BIN = os.path.join(ROOT, "build", "opcode")
COMMON = ["--provider", "anthropic", "--api-key", "test", "--no-session",
          "--replay", os.path.join(ROOT, "tests", "data", "agent_replay.wire")]

ALT_ON = b"\x1b[?1049h"
ALT_OFF = b"\x1b[?1049l"
PARK = b"\x1b[1G\x1b[?25l\x1b[?7h"


class Vt:
    """Minimal VT100/ANSI screen + scrollback used to assert committed lines."""

    def __init__(self, cols=80, rows=24):
        self.W = cols
        self.H = rows
        self.rows = [[" "] * cols for _ in range(rows)]
        self.sb = []
        self.r = 0
        self.c = 0
        self.saved = (0, 0)

    def _scroll(self):
        self.sb.append("".join(self.rows[0]).rstrip())
        self.rows.pop(0)
        self.rows.append([" "] * self.W)

    def _put(self, ch):
        if self.c >= self.W:
            self.c = self.W - 1
        self.rows[self.r][self.c] = ch
        self.c += 1

    def _csi(self, body, fin):
        body = body.lstrip("?")
        parts = body.split(";") if body else []

        def num(k, d=1):
            try:
                return int(parts[k]) if k < len(parts) and parts[k] != "" else d
            except ValueError:
                return d

        if fin == "A":
            self.r = max(0, self.r - num(0))
        elif fin == "B":
            self.r = min(self.H - 1, self.r + num(0))
        elif fin == "C":
            self.c = min(self.W - 1, self.c + num(0))
        elif fin == "D":
            self.c = max(0, self.c - num(0))
        elif fin == "G":
            self.c = max(0, min(self.W - 1, num(0) - 1))
        elif fin == "H":
            self.r = max(0, min(self.H - 1, num(0) - 1))
            self.c = max(0, min(self.W - 1, num(1) - 1))
        elif fin == "K":
            for x in range(self.c, self.W):
                self.rows[self.r][x] = " "
        elif fin == "J":
            for y in range(self.r, self.H):
                for x in range(self.W):
                    self.rows[y][x] = " "

    def feed(self, data):
        i, n = 0, len(data)
        while i < n:
            b = data[i]
            if b == 0x1B:
                if i + 1 < n and data[i + 1:i + 2] == b"[":
                    j = i + 2
                    while j < n and not (0x40 <= data[j] <= 0x7E):
                        j += 1
                    if j >= n:
                        break
                    self._csi(data[i + 2:j].decode("latin1"), chr(data[j]))
                    i = j + 1
                    continue
                if i + 1 < n and data[i + 1:i + 2] == b"]":
                    j = i + 2
                    while j < n and data[j] != 7:
                        if data[j] == 0x1B and j + 1 < n and data[j + 1] == 0x5C:
                            j += 1
                            break
                        j += 1
                    i = j + 1
                    continue
                if i + 1 < n and data[i + 1:i + 2] == b"7":
                    self.saved = (self.r, self.c)
                elif i + 1 < n and data[i + 1:i + 2] == b"8":
                    self.r, self.c = self.saved
                i += 2
                continue
            if b == 0x0A:
                self.r += 1
                if self.r >= self.H:
                    self._scroll()
                    self.r = self.H - 1
                i += 1
                continue
            if b == 0x0D:
                self.c = 0
                i += 1
                continue
            ln = 1
            if b >= 0xF0:
                ln = 4
            elif b >= 0xE0:
                ln = 3
            elif b >= 0xC0:
                ln = 2
            try:
                ch = data[i:i + ln].decode("utf-8")
            except UnicodeDecodeError:
                ch, ln = "?", 1
            self._put(ch)
            i += ln

    def screen(self):
        return "\n".join("".join(r).rstrip() for r in self.rows)

    def scrollback(self):
        return "\n".join(self.sb)


def run(extra, steps, sigs=(), cols=80, rows=8, timeout=25):
    """Run opcode in a PTY.  steps = [(predicate(bytes)->bool, bytes)]."""
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    proc = subprocess.Popen([BIN] + extra + COMMON, stdin=slave, stdout=slave,
                            stderr=slave, close_fds=True)
    os.close(slave)
    out = b""
    step = 0
    sent = set()
    t0 = time.time()
    while time.time() - t0 < timeout:
        if proc.poll() is not None:
            break
        for k, (delay, sig) in enumerate(sigs):
            if k not in sent and time.time() - t0 >= delay:
                try:
                    os.kill(proc.pid, sig)
                except ProcessLookupError:
                    pass
                sent.add(k)
        r, _, _ = select.select([master], [], [], 0.05)
        if r:
            try:
                chunk = os.read(master, 65536)
            except OSError:
                chunk = b""
            if not chunk:
                break
            out += chunk
        if step < len(steps) and time.time() - t0 > 0.3 and steps[step][0](out):
            os.write(master, steps[step][1])
            step += 1
    if proc.poll() is None:
        proc.kill()
    rc = proc.wait()
    os.close(master)
    return out, rc


def submit_and_quit(delay=0.7):
    """Submit a turn, then quit a moment after the final answer lands so the
    idle frame can commit the finished turn to scrollback first."""
    state = {"t": None}

    def final(o):
        if b"All done." not in o:
            return False
        if state["t"] is None:
            state["t"] = time.time()
        return time.time() - state["t"] > delay

    return [
        (lambda o: b"ready" in o, b"run the checks\r"),
        (final, b"/quit\r"),
    ]


def chrome_free(text):
    """No rule/footer chrome ever enters scrollback."""
    if "\u2500" in text:
        return False
    for line in text.splitlines():
        if "ready" in line or "working" in line or "think:" in line:
            return False
    return True


def committed_once(text):
    return (text.count("> run the checks") == 1 and
            text.count("Let me check.") == 1 and
            text.count("All done.") == 1 and
            text.find("> run the checks") < text.find("Let me check.") <
            text.find("All done."))


def main():
    tmp = tempfile.mkdtemp(prefix="opcode-tui-pty-")
    os.environ["XDG_CONFIG_HOME"] = os.path.join(tmp, "config")
    os.environ["XDG_STATE_HOME"] = os.path.join(tmp, "state")
    os.makedirs(os.environ["XDG_CONFIG_HOME"], exist_ok=True)
    os.makedirs(os.environ["XDG_STATE_HOME"], exist_ok=True)
    results = []

    def check(name, ok):
        results.append(ok)
        print(("ok   " if ok else "FAIL ") + name)

    # ---- mode names -------------------------------------------------------
    for name, extra, want_alt in [("scrollback", ["--tui-mode", "scrollback"], False),
                                  ("inline", ["--tui-mode", "inline"], False),
                                  ("auto", ["--tui-mode", "auto"], False),
                                  ("default", [], False),
                                  ("fullscreen", ["--tui-mode", "fullscreen"], True)]:
        out, rc = run(extra, [(lambda o: b"ready" in o, b"/quit\r")], rows=24)
        check("mode-%s-exit-0" % name, rc == 0)
        check("mode-%s-alt" % name, (ALT_ON in out) == want_alt and
              (ALT_OFF in out) == want_alt)

    # ---- inline region protocol ------------------------------------------
    out, rc = run(["--tui-mode", "inline"], submit_and_quit())
    check("inline-exit-0", rc == 0)
    check("inline-no-altscreen", ALT_ON not in out and ALT_OFF not in out)
    check("inline-autowrap-bracket", b"\x1b[?7l" in out and b"\x1b[?7h" in out)
    check("inline-parked-cursor", PARK in out)
    vt = Vt(cols=80, rows=8)
    vt.feed(out)
    sb = vt.scrollback()
    # A committed line may still sit on the visible screen if it has not
    # scrolled off yet, so the commit assertion looks at scrollback + screen.
    visible = vt.screen()
    check("inline-scrollback-no-chrome", chrome_free(sb))
    check("inline-committed-once-in-order", committed_once(sb + "\n" + visible))
    check("inline-streamed-text", "Let me check." in vt.screen() or "Let me check." in sb)
    check("inline-tool-call", "[bash]" in sb)

    # Scrollback (legacy) mode must also keep chrome out of scrollback.
    out, rc = run(["--tui-mode", "scrollback"], submit_and_quit())
    vt = Vt(cols=80, rows=8)
    vt.feed(out)
    sb = vt.scrollback()
    check("scrollback-exit-0", rc == 0)
    check("scrollback-no-chrome", chrome_free(sb))
    # The legacy scrollback path streams the live tail once and never redraws a
    # finished line; the final assistant line may still be on screen at quit.
    check("scrollback-streamed-once",
          sb.count("> run the checks") == 1 and sb.count("Let me check.") == 1 and
          sb.count("All done.") <= 1)

    # ---- resize storm, idle ----------------------------------------------
    sigs = tuple((0.6 + 0.25 * i, signal.SIGWINCH) for i in range(4))
    out, rc = run(["--tui-mode", "inline"],
                  [(lambda o: b"ready" in o, b"/quit\r")], sigs=sigs)
    vt = Vt(cols=80, rows=8)
    vt.feed(out)
    check("resize-idle-exit-0", rc == 0)
    check("resize-idle-no-chrome", chrome_free(vt.scrollback()))

    # ---- resize storm, mid-turn ------------------------------------------
    sigs = tuple((0.6 + 0.2 * i, signal.SIGWINCH) for i in range(5))
    out, rc = run(["--tui-mode", "inline"], submit_and_quit(), sigs=sigs)
    vt = Vt(cols=80, rows=8)
    vt.feed(out)
    sb = vt.scrollback()
    check("resize-live-exit-0", rc == 0)
    check("resize-live-no-chrome", chrome_free(sb))
    check("resize-live-committed-once",
          committed_once(sb + "\n" + vt.screen()))

    shutil.rmtree(tmp, ignore_errors=True)
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
