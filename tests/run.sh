#!/bin/sh
# runs every tests/*.s against tests/data/<name>.expected, then the CLI checks
# and, when python3 is available, the integration suites. Prints a final
# "TESTS n passed" line; missing python3 reduces the count and is reported.
#
# On Linux the host builds the static x86-64 unit binaries from the default
# recipe. On Darwin the mac recipe builds native Mach-O arm64 unit binaries
# (build/mac/tests/<name>) plus the app, and the portable CLI and integration
# checks run against them. Skips are always reported by name.
# usage: tests/run.sh
set -e
cd "$(dirname "$0")/.."

# Hermeticity: every suite runs with isolated config/state/data roots and a
# private HOME, so a developer's ~/.config/opcode, ~/.local/state or a stray
# XDG_* setting can never change an outcome.  The dirs are removed on exit.
HERMETIC=$(mktemp -d "${TMPDIR:-/tmp}/opcode-hermetic.XXXXXX")
XDG_CONFIG_HOME="$HERMETIC/config"
XDG_STATE_HOME="$HERMETIC/state"
XDG_DATA_HOME="$HERMETIC/data"
HOME="$HERMETIC/home"
export XDG_CONFIG_HOME XDG_STATE_HOME XDG_DATA_HOME HOME
mkdir -p "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$XDG_DATA_HOME" "$HOME"

HOST=$(uname -s 2>/dev/null || echo unknown)
# linux-aarch64 mode is selected by the environment, never by uname: the
# emulation host IS Linux and would otherwise take the native branch.
OPCODE_TARGET=${OPCODE_TARGET:-}
# EMULATOR fronts every guest binary in linux-aarch64 mode (qemu-aarch64 by
# default, overridable); empty means "run directly", which is what the native
# and Darwin modes do.
EMULATOR=${EMULATOR:-}

# The integration suites call `timeout N cmd` directly. Stock macOS ships only
# coreutils' `gtimeout`, so a host without `timeout` gets a small CPython
# wrapper first on PATH. It uses Popen.wait()'s own deadline (no orphaned
# sleep process) and keeps the exit-124 timeout convention. On Linux the real
# timeout is found and this block is a no-op.
if ! command -v timeout > /dev/null 2>&1; then
    mkdir -p build/testbin
    cat > build/testbin/timeout <<'PY'
#!/usr/bin/env python3
"""Minimal `timeout SECONDS COMMAND...` for hosts without GNU coreutils."""
import subprocess
import sys

try:
    seconds = float(sys.argv[1])
    proc = subprocess.Popen(sys.argv[2:])
except (IndexError, ValueError):
    sys.stderr.write("usage: timeout SECONDS COMMAND [ARG...]\n")
    sys.exit(125)
except OSError as exc:
    sys.stderr.write("timeout: %s\n" % exc)
    sys.exit(126)

try:
    sys.exit(proc.wait(timeout=seconds))
except subprocess.TimeoutExpired:
    proc.terminate()
    try:
        proc.wait(timeout=1)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    sys.exit(124)
PY
    chmod +x build/testbin/timeout
    PATH="$PWD/build/testbin:$PATH"
    export PATH
fi

# BSD `wc` pads its numeric columns, so `wc -l < f` yields "       6" where the
# CLI tests compare against "6". On such a host a thin wrapper trims the
# padding; Linux keeps the real wc untouched.
if [ "$(printf 'x\n' | wc -l | tr -d '0-9')" != "" ]; then
    real_wc=$(command -v wc)
    cat > build/testbin/wc <<SH
#!/bin/sh
# Strip BSD wc's leading column padding; the suite compares counts as strings.
"$real_wc" "\$@" | sed 's/^[[:space:]]*//'
SH
    chmod +x build/testbin/wc
    PATH="$PWD/build/testbin:$PATH"
    export PATH
fi

# Darwin builds the Mach-O app and its arm64 unit-test binaries, and exposes
# the app at the ./build/opcode path the suites and the CLI checks use; Linux
# keeps the default static ELF build.  linux-aarch64 builds the static aarch64
# ELF app and its translated unit-test binaries (build/a64/tests/), then
# installs a temporary exec wrapper at build/opcode so the ~50 ./build/opcode
# call sites in the suites reach the emulator; the wrapper is removed on exit
# (trap below) so the next native `make` relinks the real x86-64 binary.
EMU_TIMEOUT_SCALE=${EMU_TIMEOUT_SCALE:-10}
wrapper_installed=0
saved_opcode=
if [ "$OPCODE_TARGET" = "linux-aarch64" ]; then
    [ -n "$EMULATOR" ] || EMULATOR=qemu-aarch64
    unitdir="build/a64/tests"
    make -s linux-aarch64 test-aarch64
    if [ -e build/opcode ] || [ -L build/opcode ]; then
        mv build/opcode build/.opcode-saved
        saved_opcode=build/.opcode-saved
    fi
    cat > build/opcode <<SH
#!/bin/sh
# Temporary emulator exec wrapper installed by tests/run.sh
# (OPCODE_TARGET=linux-aarch64); removed on exit so the next native \`make\`
# relinks the real x86-64 binary.
#
# /bin/sh, not /usr/bin/env bash: the pure Nix build sandbox provides /bin/sh
# and PATH but has no /usr/bin/env, so a \`#!/usr/bin/env bash\` shebang makes
# every ./build/opcode call fail with "No such file or directory".  The
# ADR-110 stderr filter needs process substitution, a bash extension, so it
# is handed to bash as a single-quoted -c program (keeping this file itself
# POSIX-parseable) whenever bash is on PATH; without bash the wrapper still
# execs the emulator and the harness-level filter in run_suite below removes
# the noise from each suite's captured output.  Every branch execs, so the
# wrapper's PID becomes the emulator (the signal-based tests kill the process
# they spawned) and the guest's exit code is preserved.
#
# qemu-user 11.1.1 writes its own "qemu: uncaught target signal N (...) -
# core dumped" line to stderr when a guest dies of a signal — emulator noise,
# not program output (the guest's exit status and real output are untouched).
# Filter exactly that line from stderr only; the exec preserves the exit code.
if command -v bash > /dev/null 2>&1; then
    exec bash -c 'exec "\$0" "\$@" 2> >(grep --line-buffered -v "^qemu: uncaught target signal .* - core dumped\\\$" >&2)' \\
        "$EMULATOR" "$PWD/build/opcode-linux-aarch64" "\$@"
fi
exec $EMULATOR "$PWD/build/opcode-linux-aarch64" "\$@"
SH
    chmod +x build/opcode
    wrapper_installed=1
elif [ "$HOST" = "Darwin" ]; then
    unitdir="build/mac/tests"
    make -s darwin-arm64 darwin-arm64-test
    ln -sf opcode-darwin-arm64 build/opcode
else
    unitdir="build"
    make -s all test
fi

cleanup() {
    if [ "$wrapper_installed" = 1 ]; then
        rm -f build/opcode
        if [ -n "$saved_opcode" ]; then
            mv "$saved_opcode" build/opcode
        fi
    fi
    rm -rf "$HERMETIC"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# The suites (ollama.sh's live-discover helper in particular) branch on these.
export OPCODE_TARGET EMULATOR EMU_TIMEOUT_SCALE

if command -v timeout > /dev/null 2>&1; then
    if [ "$OPCODE_TARGET" = "linux-aarch64" ]; then
        # qemu-user runs the guest 5-50x slower; scale the harness timeouts
        # (never a test assertion) by an env-overridable factor.
        case "$EMU_TIMEOUT_SCALE" in
            ''|*[!0-9]*) EMU_TIMEOUT_SCALE=10 ;;
        esac
        TIMEOUT="timeout $((30 * EMU_TIMEOUT_SCALE))"
        SUITE_TIMEOUT="timeout $((300 * EMU_TIMEOUT_SCALE))"
    else
        TIMEOUT="timeout 30"
        SUITE_TIMEOUT="timeout 300"
    fi
else
    TIMEOUT=""
    SUITE_TIMEOUT=""
fi

pass=0
fail=0
skip=0
skip_why=""

# Every unit binary is the same portable test; only its directory differs
# (build/ on Linux, build/mac/tests/ for the arm64 Mach-O, build/a64/tests/
# for the linux-aarch64 ELF, which also runs under $EMULATOR).
for t in tests/*.s; do
    n=$(basename "$t" .s)
    out="build/$n.out"
    rc=0
    # shellcheck disable=SC2086
    $TIMEOUT $EMULATOR "./$unitdir/$n" > "$out" 2>&1 || rc=$?
    if [ "$rc" -eq 124 ]; then
        echo "FAIL $n (timeout)"
        sed -n '1,20p' "$out" || true
        fail=$((fail + 1))
    elif [ "$rc" -ne 0 ]; then
        echo "FAIL $n (exit $rc)"
        sed -n '1,20p' "$out" || true
        fail=$((fail + 1))
    elif cmp -s "$out" "tests/data/$n.expected"; then
        echo "ok   $n"
        pass=$((pass + 1))
    else
        echo "FAIL $n"
        diff -u "tests/data/$n.expected" "$out" | head -40 || true
        fail=$((fail + 1))
    fi
done

# CLI: --version, --help, unknown option.  The linux-aarch64 mode runs them
# against the aarch64 binary through the emulator; every other mode uses the
# build/opcode path directly (native ELF or the Darwin symlink).
opcode_bin=./build/opcode
if [ "$OPCODE_TARGET" = "linux-aarch64" ]; then
    opcode_bin="$EMULATOR build/opcode-linux-aarch64"
fi
v=$(cat VERSION)
# shellcheck disable=SC2086
if [ "$($opcode_bin --version)" = "opcode $v" ]; then
    echo "ok   cli-version"
    pass=$((pass + 1))
else
    echo "FAIL cli-version"
    fail=$((fail + 1))
fi
# shellcheck disable=SC2086
$opcode_bin --help > build/cli-help.out 2>&1 || true
if head -1 build/cli-help.out | grep -q '^opcode - a minimal extensible coding agent$'; then
    echo "ok   cli-help"
    pass=$((pass + 1))
else
    echo "FAIL cli-help"
    fail=$((fail + 1))
fi
# shellcheck disable=SC2086
$opcode_bin --nope > /dev/null 2>&1 && rc=0 || rc=$?
if [ "$rc" = 2 ]; then
    echo "ok   cli-unknown"
    pass=$((pass + 1))
else
    echo "FAIL cli-unknown (exit $rc)"
    fail=$((fail + 1))
fi

# Integration suites (need loopback + python3). Count their ok/FAIL lines so
# the final total is the real number of checks, not the number of scripts.
run_suite() { # name script
    _name=$1
    shift
    _rc=0
    # shellcheck disable=SC2086
    _out=$($SUITE_TIMEOUT "$@" 2>&1) || _rc=$?
    if [ -n "$EMULATOR" ]; then
        # qemu-user 11.1.1 injects its own stderr line when a guest dies of a
        # signal; it is emulator noise, not program output (the guest's exit
        # status and its real output are untouched, and the checks below still
        # see every other byte).
        _out=$(printf '%s\n' "$_out" | grep -v '^qemu: uncaught target signal .* - core dumped$')
    fi
    printf '%s\n' "$_out"
    _n=$(printf '%s\n' "$_out" | grep -c '^ok ' || true)
    _f=$(printf '%s\n' "$_out" | grep -c '^FAIL ' || true)
    pass=$((pass + _n))
    fail=$((fail + _f))
    if [ "$_n" -eq 0 ] && [ "$_f" -eq 0 ]; then
        # A suite that reports nothing is broken even when it exits 0: the
        # harness cannot treat an empty result set as success.
        echo "FAIL $_name (no result lines, exit $_rc)"
        fail=$((fail + 1))
    elif [ "$_rc" -ne 0 ] && [ "$_f" -eq 0 ]; then
        echo "FAIL $_name (exit $_rc)"
        fail=$((fail + 1))
    fi
}

if command -v python3 > /dev/null 2>&1; then
    run_suite net tests/net.sh
    run_suite update tests/update.sh
    run_suite agent tests/agent.sh
    run_suite compact_cli tests/compact_cli.sh
    run_suite session_cli tests/session_cli.sh
    run_suite tui tests/tui.sh
    run_suite term_state python3 tests/term_state.py
    run_suite modes tests/modes.sh
    run_suite onboarding tests/onboarding.sh
    run_suite ollama tests/ollama.sh
    run_suite mcp tests/mcp.sh
    run_suite oauth tests/oauth.sh
else
    for s in net update agent compact_cli session_cli tui modes onboarding ollama mcp oauth; do
        echo "SKIP $s (python3 not found)"
        skip=$((skip + 1))
    done
    skip_why="python3 not found"
fi

if [ "$skip" -gt 0 ]; then
    if [ "$skip_why" = "python3 not found" ]; then
        echo "TESTS $pass passed, $fail failed ($skip integration suites skipped: python3 not found)"
    else
        echo "TESTS $pass passed, $fail failed ($skip skipped: $skip_why)"
    fi
else
    echo "TESTS $pass passed, $fail failed"
fi
[ "$fail" -eq 0 ]
