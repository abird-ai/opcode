#!/bin/sh
# Onboarding + `opcode models` tests.
#
# Non-interactive checks: the builtin catalogue, the no-TTY onboarding block
# (exit 2), and that an env key / config provider suppresses onboarding.
# When python3 is available, a PTY test drives the interactive menu (choice 1)
# and Ctrl-C, and checks config_save's merge/atomicity/0600 preservation.
set -e
cd "$(dirname "$0")/.."
[ -x build/opcode ] || make -s all

fail=0
check() {
    if [ "$2" = "$3" ]; then
        echo "ok   $1"
    else
        echo "FAIL $1"
        printf '  expected: %s\n  actual:   %s\n' "$2" "$3"
        fail=1
    fi
}
contains() {
    if printf '%s' "$3" | grep -q -e "$2"; then
        echo "ok   $1"
    else
        echo "FAIL $1"
        printf '  missing: %s\n  in: %s\n' "$2" "$3"
        fail=1
    fi
}
not_contains() {
    if printf '%s' "$3" | grep -q -e "$2"; then
        echo "FAIL $1"
        printf '  unexpected: %s\n  in: %s\n' "$2" "$3"
        fail=1
    else
        echo "ok   $1"
    fi
}

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# 1. opcode models: builtin catalogue grouped by provider, exit 0.
rc=0
out=$(env -i HOME="$TMP/nohome" PATH="$PATH" ./build/opcode models 2>&1) || rc=$?
check models-rc 0 "$rc"
contains models-anthropic "anthropic/claude-sonnet-4-5 (builtin)" "$out"
contains models-google "google/gemini-2.5-pro (builtin)" "$out"
contains models-ollama "ollama/llama3.2 (builtin)" "$out"
contains models-cloud "ollama-cloud/gpt-oss:120b (builtin)" "$out"

# 2. discovered cache from models.jsonc is listed as (discovered), builtins kept.
mkdir -p "$TMP/xdg/opcode"
cat > "$TMP/xdg/opcode/models.jsonc" <<'EOF'
{"models":[{"id":"qwen3:8b","name":"Qwen3 8B","api":"openai-chat","provider":"ollama",
  "base":"http://127.0.0.1:11434/v1","context_window":0,"max_tokens":0,
  "reasoning":false,"image":false,"no_key":true}]}
EOF
out=$(env -i HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/xdg" PATH="$PATH" \
        ./build/opcode models 2>&1) || rc=$?
check models-disc-rc 0 "$rc"
contains models-disc "ollama/qwen3:8b (discovered)" "$out"
contains models-disc-builtin "ollama/llama3.2 (builtin)" "$out"

# 3. no TTY and no provider/key: onboarding block, exit 2.
rc=0
out=$(env -i HOME="$TMP/nohome" PATH="$PATH" ./build/opcode -p "hi" 2>&1) || rc=$?
check onboard-notty-rc 2 "$rc"
contains onboard-notty-login "opcode login anthropic" "$out"
contains onboard-notty-apikey "--api-key" "$out"
contains onboard-notty-local "no API key" "$out"

# 4. OPENAI_API_KEY resolves a provider: no onboarding (replay may still fail).
[ -f tests/data/agent_replay.wire ] || python3 tests/gen_agent_replay.py
rc=0
out=$(env -i HOME="$TMP/nohome" PATH="$PATH" OPENAI_API_KEY=test \
        ./build/opcode -p "hi" --replay tests/data/agent_replay.wire --no-session 2>&1) || rc=$?
not_contains onboard-envkey "no provider is configured" "$out"

# 5. config default_provider/default_model resolves a provider: no onboarding.
mkdir -p "$TMP/cfg/opcode"
printf '{"default_provider":"anthropic","default_model":"claude-haiku-4-5"}\n' \
    > "$TMP/cfg/opcode/config.jsonc"
rc=0
out=$(env -i HOME="$TMP/nohome" XDG_CONFIG_HOME="$TMP/cfg" PATH="$PATH" \
        ./build/opcode -p "hi" --replay tests/data/agent_replay.wire --no-session 2>&1) || rc=$?
not_contains onboard-config "no provider is configured" "$out"

# 6. interactive PTY: menu, config merge, atomic write, Ctrl-C restore.
if command -v python3 > /dev/null 2>&1; then
    rc=0
    python3 - "$PWD/build/opcode" "$TMP" <<'PY' || rc=$?
import fcntl, os, pty, select, signal, subprocess, sys, termios, time

BIN, TMP = sys.argv[1], sys.argv[2]
LFLAGS = termios.ICANON | termios.ECHO | termios.ISIG
fail = 0

def say(name, ok, detail=""):
    global fail
    if ok:
        print("ok   " + name)
    else:
        print("FAIL " + name)
        if detail:
            print("  " + str(detail)[:400])
        fail = 1

def env_for(home):
    env = {"HOME": home, "PATH": os.environ.get("PATH", ""), "TERM": "xterm"}
    return env

def controlling_tty(fd):
    # Popen's child inherits the parent's session, so the freshly opened pty
    # slave is not its controlling terminal and there is no foreground process
    # group for the line discipline to signal.  setsid() in the child starts a
    # new session, then TIOCSCTTY claims the slave as its controlling terminal;
    # both must run in the child (TIOCSCTTY requires the caller to be the
    # session leader, which the parent is not).  This is the canonical way to
    # spawn a program on a real controlling pty.
    def _child():
        os.setsid()
        fcntl.ioctl(fd, termios.TIOCSCTTY, 0)
    return _child

def wait_raw(fd, timeout):
    # The guest calls os_tty_raw() only *after* it prints the menu prompt, so
    # a byte written the instant the prompt appears can still land in the
    # canonical line discipline.  Wait for ISIG to be cleared (raw mode) before
    # driving input; otherwise an INTR byte is consumed by the kernel instead
    # of reaching the guest's own byte-3 handling (onboard.s .Lom_ctrlc).
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            if not (termios.tcgetattr(fd)[3] & termios.ISIG):
                return True
        except termios.error:
            return False
        time.sleep(0.01)
    return False

def spawn(args, home):
    master, slave = pty.openpty()
    proc = subprocess.Popen([BIN] + args, stdin=slave, stdout=slave,
                            stderr=slave, env=env_for(home), close_fds=True)
    os.close(slave)
    return master, proc

def read_until(master, needle, timeout):
    buf = b""
    deadline = time.time() + timeout
    while time.time() < deadline:
        r, _, _ = select.select([master], [], [], 0.2)
        if not r:
            continue
        try:
            data = os.read(master, 4096)
        except OSError:
            break
        if not data:
            break
        buf += data
        if needle in buf:
            return buf
    return buf

def kill(proc):
    try:
        proc.kill()
    except OSError:
        pass
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass

def drain(master, timeout):
    buf = b""
    deadline = time.time() + timeout
    while time.time() < deadline:
        r, _, _ = select.select([master], [], [], 0.2)
        if not r:
            continue
        try:
            data = os.read(master, 4096)
        except OSError:
            break
        if not data:
            break
        buf += data
    return buf

# --- menu choice 1: config_save merges into an existing config.jsonc ---------
home = os.path.join(TMP, "pty-home")
cfgdir = os.path.join(home, ".config", "opcode")
os.makedirs(cfgdir)
cfg = os.path.join(cfgdir, "config.jsonc")
sess = os.path.join(TMP, "pty-sessions")
with open(cfg, "w") as fh:
    fh.write('{"session_dir":"%s","providers":{"openai":{"api_key":"k"}}}\n' % sess)
os.chmod(cfg, 0o600)
os.umask(0o022)
master, proc = spawn(["-p", "hi"], home)
out = read_until(master, b"choice [1-6]:", 15)
say("pty-menu-shown", b"1) Ollama (local)" in out and b"5) Google" in out and b"6) Skip" in out)
os.write(master, b"1")
out += read_until(master, b"configured ollama/", 30)
say("pty-menu-choice", b"configured ollama/" in out)
kill(proc)
os.close(master)
try:
    with open(cfg, "r") as fh:
        text = fh.read()
except OSError:
    text = ""
say("pty-config-provider", '"default_provider":"ollama"' in text, text)
say("pty-config-model", '"default_model":"' in text, text)
say("pty-config-keep", ('"session_dir":"%s"' % sess) in text and '"api_key":"k"' in text, text)
say("pty-config-mode", oct(os.stat(cfg).st_mode & 0o777) == "0o600",
    oct(os.stat(cfg).st_mode & 0o777))
say("pty-config-atomic", not os.path.exists(cfg + ".tmp"))
say("pty-menu-auth", b"needs no API key" in out)

# --- menu choice 3 for a cloud provider prints the login command -------------
home3 = os.path.join(TMP, "pty-home3")
os.makedirs(home3)
master, proc = spawn(["-p", "hi"], home3)
out = read_until(master, b"choice [1-6]:", 15)
os.write(master, b"3")
out += read_until(master, b"opcode login anthropic", 30)
say("pty-cloud-login", b"opcode login anthropic" in out)
kill(proc)
os.close(master)

# --- menu choice 5 (Google) prints the API-key hint --------------------------
home4 = os.path.join(TMP, "pty-home4")
os.makedirs(home4)
master, proc = spawn(["-p", "hi"], home4)
out = read_until(master, b"choice [1-6]:", 15)
os.write(master, b"5")
out += read_until(master, b"GEMINI_API_KEY", 30)
say("pty-google-hint", b"GEMINI_API_KEY" in out)
kill(proc)
os.close(master)

# --- Ctrl-C in the menu: exit 130, terminal settings restored ----------------
home2 = os.path.join(TMP, "pty-home2")
os.makedirs(home2)
master, slave = pty.openpty()
before = termios.tcgetattr(slave)
proc = subprocess.Popen([BIN], stdin=slave, stdout=slave, stderr=slave,
                        env=env_for(home2), close_fds=True,
                        preexec_fn=controlling_tty(slave))
out = read_until(master, b"choice [1-6]:", 15)
wait_raw(slave, 5)
os.write(master, b"\x03")
try:
    rc = proc.wait(timeout=10)
except subprocess.TimeoutExpired:
    rc = None
    kill(proc)
out += drain(master, 2)
after = termios.tcgetattr(slave)
os.close(slave)
os.close(master)
say("pty-ctrl-c-rc", rc == 130, "rc=%r" % rc)
say("pty-ctrl-c-restore", (before[3] & LFLAGS) == (after[3] & LFLAGS),
    "before=%x after=%x" % (before[3] & LFLAGS, after[3] & LFLAGS))
say("pty-ctrl-c-msg", b"onboarding cancelled" in out, out[-200:])

sys.exit(1 if fail else 0)
PY
    if [ "$rc" -ne 0 ]; then
        fail=1
    fi
else
    echo "SKIP onboarding-pty (python3 not found)"
fi

exit $fail
