#!/usr/bin/env python3
"""Terminal-state tests: opcode must restore the tty on every exit path.

Each scenario runs build/opcode in a PTY and checks that the slave termios
ICANON/ECHO/ISIG bits return to their pre-run values and that the output ends
with the restore sequences (cursor shown, alt screen left, clean line) -- even
when the process leaves through an external fatal signal.

Prints one "ok <scenario>" line per scenario and exits nonzero on any failure.
"""
import atexit
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
REPLAY = os.path.join(ROOT, "tests", "data", "agent_replay.wire")
COMMON = ["--provider", "anthropic", "--api-key", "test", "--no-session",
          "--replay", REPLAY]

LFLAG_MASK = termios.ICANON | termios.ECHO | termios.ISIG
CURSOR_ON = b"\x1b[?25h"
ALT_ON = b"\x1b[?1049h"
ALT_OFF = b"\x1b[?1049l"
INLINE_TAIL = CURSOR_ON + b"\r\n"

READY_TIMEOUT = 15.0
EXIT_TIMEOUT = 10.0


def ensure_replay():
    if not os.path.exists(REPLAY):
        subprocess.check_call(
            [sys.executable, os.path.join(ROOT, "tests", "gen_agent_replay.py")],
            cwd=ROOT)


class Session:
    def __init__(self, extra):
        self.master, self.slave = pty.openpty()
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ,
                    struct.pack("HHHH", 24, 80, 0, 0))
        self.initial = termios.tcgetattr(self.slave)
        self.proc = subprocess.Popen([BIN] + extra + COMMON, stdin=self.slave,
                                     stdout=self.slave, stderr=self.slave,
                                     close_fds=True)
        self.out = b""
        self.raw = False

    def _pump(self, timeout):
        r, _, _ = select.select([self.master], [], [], timeout)
        if not r:
            return
        try:
            chunk = os.read(self.master, 65536)
        except OSError:
            return
        if chunk:
            self.out += chunk

    def drain(self):
        while True:
            r, _, _ = select.select([self.master], [], [], 0)
            if not r:
                return
            try:
                chunk = os.read(self.master, 65536)
            except OSError:
                return
            if not chunk:
                return
            self.out += chunk

    def poll(self):
        if self.proc.poll() is not None:
            self.drain()
            return True
        self._pump(0.05)
        if not self.raw:
            try:
                cur = termios.tcgetattr(self.slave)
                if not (cur[3] & termios.ICANON):
                    self.raw = True
            except termios.error:
                pass
        return False

    def wait_ready(self, timeout=READY_TIMEOUT):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.poll():
                break
            if self.raw and b"ready" in self.out:
                return True
        return self.raw and b"ready" in self.out

    def wait_exit(self, timeout=EXIT_TIMEOUT):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.poll():
                return True
        self.proc.kill()
        self.proc.wait()
        self.drain()
        return False

    def close(self):
        self.drain()
        try:
            final = termios.tcgetattr(self.slave)
        except termios.error:
            final = None
        os.close(self.master)
        os.close(self.slave)
        return final


def termios_ok(initial, final):
    return final is not None and \
        (final[3] & LFLAG_MASK) == (initial[3] & LFLAG_MASK)


def scenario(name, extra, act, expect_rc, expect_tail, extra_check=None):
    s = Session(extra)
    reason = None
    if not s.wait_ready():
        reason = "did not enter raw mode / print ready"
    else:
        act(s)
        if not s.wait_exit():
            reason = "process did not exit"
    final = s.close()
    rc = s.proc.returncode
    ok = reason is None
    if s.raw is False:
        ok = False
        reason = (reason or "") + " [raw mode never observed]"
    # expect_rc=None means the caller declared the exit status unreliable on
    # this host (see the SIGFPE emulator note in main).
    if expect_rc is not None and rc != expect_rc:
        ok = False
        reason = (reason or "") + " [rc=%r want %r]" % (rc, expect_rc)
    if not termios_ok(s.initial, final):
        ok = False
        reason = (reason or "") + " [termios flags not restored]"
    if not expect_tail(s.out):
        ok = False
        reason = (reason or "") + " [tail=%r]" % s.out[-24:]
    if extra_check is not None and not extra_check(s.out):
        ok = False
        reason = (reason or "") + " [missing screen sequences]"
    if ok:
        print("ok   term-state/%s" % name)
    else:
        print("FAIL term-state/%s: %s" % (name, reason.strip()))
    return ok


def main():
    # A user config can pin default_provider/default_model and silently override
    # --provider; isolate config and state so the suite is deterministic here
    # and in CI, exactly as tests/tui.sh does.
    tmp = tempfile.mkdtemp(prefix="opcode-term-state-")
    atexit.register(shutil.rmtree, tmp, ignore_errors=True)
    os.environ["XDG_CONFIG_HOME"] = os.path.join(tmp, "config")
    os.environ["XDG_STATE_HOME"] = os.path.join(tmp, "state")
    os.makedirs(os.environ["XDG_CONFIG_HOME"], exist_ok=True)
    os.makedirs(os.environ["XDG_STATE_HOME"], exist_ok=True)
    # run.sh/the Makefile set EMULATOR to the user-mode emulator (qemu-*) for a
    # cross target; Wine never reaches this suite (its PTY checks are skipped).
    emulator = os.environ.get("EMULATOR", "")
    ensure_replay()
    results = []

    results.append(scenario(
        "inline-quit", [],
        lambda s: os.write(s.master, b"/quit\r"),
        0, lambda out: out.endswith(INLINE_TAIL)))

    # S7 mode names: scrollback and auto both keep the normal screen and end on
    # a clean line exactly like the default owned inline region.
    for mode in ("scrollback", "auto"):
        results.append(scenario(
            "%s-quit" % mode, ["--tui-mode", mode],
            lambda s: os.write(s.master, b"/quit\r"),
            0, lambda out: out.endswith(INLINE_TAIL)))

    # Ctrl+C is clear-then-quit: the first press on an empty composer arms a
    # 1 s window and the second quits.
    results.append(scenario(
        "inline-ctrl-c", [],
        lambda s: os.write(s.master, b"\x03\x03"),
        0, lambda out: out.endswith(INLINE_TAIL)))

    results.append(scenario(
        "sigterm", [],
        lambda s: os.kill(s.proc.pid, signal.SIGTERM),
        -signal.SIGTERM, lambda out: out.endswith(INLINE_TAIL)))

    results.append(scenario(
        "sigsegv", [],
        lambda s: os.kill(s.proc.pid, signal.SIGSEGV),
        -signal.SIGSEGV, lambda out: out.endswith(INLINE_TAIL)))

    # The fatal-signal set must also cover SIGBUS and SIGFPE,
    # or a crash from either leaves the tty in raw mode with a hidden cursor.
    results.append(scenario(
        "sigbus", [],
        lambda s: os.kill(s.proc.pid, signal.SIGBUS),
        -signal.SIGBUS, lambda out: out.endswith(INLINE_TAIL)))

    # qemu-user cannot re-raise SIGFPE from inside a SIGFPE handler: the
    # emulator dies with SIGSEGV before the guest's rt_sigreturn, so the
    # re-raised signal never reaches the guest.  A native freestanding AArch64
    # program reproduces this, so it is a qemu-user limitation, not a
    # opcode/translator bug, and the identical restore path is already checked by
    # the SIGBUS/SIGSEGV scenarios above.  Keep the terminal-restore assertion
    # but do not pin the emulated exit status.
    sigfpe_rc = None if emulator else -signal.SIGFPE
    results.append(scenario(
        "sigfpe", [],
        lambda s: os.kill(s.proc.pid, signal.SIGFPE),
        sigfpe_rc, lambda out: out.endswith(INLINE_TAIL)))

    results.append(scenario(
        "fullscreen", ["--tui-mode", "fullscreen"],
        lambda s: os.write(s.master, b"/quit\r"),
        0, lambda out: out.endswith(ALT_OFF),
        extra_check=lambda out: ALT_ON in out and CURSOR_ON in out))

    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
