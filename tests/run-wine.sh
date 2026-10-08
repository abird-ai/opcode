#!/bin/sh
# Windows x86-64 (PE) verification lane: builds build/opcode-windows-x86_64.exe,
# runs the unit-test binaries and the CLI checks under Wine, then runs the
# integration suites through a temporary build/opcode wrapper that execs Wine.
#
# Every check the suite reports is counted.  A FAIL that is a documented Wine
# or Windows divergence is counted as a skip with its reason (see the case
# statement below); any other FAIL fails the lane.  Nothing is silently
# dropped: the skip list is printed with a reason at the end.
#
# usage: tests/run-wine.sh
#   WINE=/path/to/wine        override the emulator
#   WINECC=/path/to/gcc       override the mingw C compiler (make WIN_CC=...)
set -e
cd "$(dirname "$0")/.."

WINE=${WINE:-}
if [ -z "$WINE" ]; then
    if command -v wine > /dev/null 2>&1; then
        WINE=$(command -v wine)
    else
        echo "opcode: test-wine: wine not found; enter the flake devShell or install wine"
        exit 1
    fi
fi
case "$WINE" in
    /*) ;;
    *) WINE="$PWD/$WINE" ;;
esac

# Build the PE and its unit-test binaries (skipped when make is told not to).
if [ "${OPCODE_WINE_SKIP_BUILD:-0}" != "1" ]; then
    make -s TARGET=windows-x86_64 all test
fi
OPCODE_EXE="$PWD/build/opcode-windows-x86_64.exe"
[ -f "$OPCODE_EXE" ] || { echo "opcode: test-wine: $OPCODE_EXE missing"; exit 1; }

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"
export WINEDEBUG="${WINEDEBUG:--all}"
export WINEPREFIX="${WINEPREFIX:-$PWD/build/wineprefix}"

# First run creates the prefix and prints setup noise ("created the
# configuration directory", a failed rundll32 probe).  Do it once, quietly,
# before any output-comparing test starts.
if [ ! -d "$WINEPREFIX/drive_c" ]; then
    mkdir -p "$WINEPREFIX"
    timeout 300 "$WINE" cmd /c exit > /dev/null 2>&1 || true
fi

# Temporary build/opcode wrapper for the suites (~50 ./build/opcode call sites).
saved_opcode=
if [ -e build/opcode ] || [ -L build/opcode ]; then
    mv build/opcode build/.opcode-wine-saved
    saved_opcode=build/.opcode-wine-saved
fi
cat > build/opcode <<SH
#!/bin/sh
export XDG_RUNTIME_DIR="\${XDG_RUNTIME_DIR:-/tmp}"
export WINEDEBUG="\${WINEDEBUG:--all}"
export WINEPREFIX="\${WINEPREFIX:-$PWD/build/wineprefix}"
exec "$WINE" "$OPCODE_EXE" "\$@"
SH
chmod +x build/opcode

cleanup() {
    rm -f build/opcode
    if [ -n "$saved_opcode" ]; then
        mv "$saved_opcode" build/opcode
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

pass=0
fail=0
skip=0
skip_log=

note_skip() { # check reason
    skip=$((skip + 1))
    skip_log="${skip_log}SKIP $1 ($2)
"
}

# A FAIL line is a Wine divergence only when it names one of these checks.
divergence_reason() {
    case "$1" in
        modes-json-expected|modes-rpc-expected)
            echo "cmd.exe echoes CRLF; the golden files are byte-exact Linux output" ;;
        tui-screens|tui-queue|tui-cards|tui-scroll-ctrl-o|tui-sticky)
            echo "the tui golden embeds host-shell (cmd.exe) output; the replay's bash tool is Unix" ;;
        tui-inline-capture)
            echo "the inline golden embeds cmd.exe output and a host-speed-dependent repaint count" ;;
        mcp-initialize|mcp-tools-list|mcp-tools-call|mcp-call-args)
            echo "MCP servers are Unix processes; Wine cannot CreateProcess an ELF" ;;
        term-state/*)
            echo "Unix PTY is not a Win32 console; raw-mode/signal assertions do not apply" ;;
        pty-*)
            echo "Unix PTY is not a Win32 console; interactive onboarding does not apply" ;;
        *)
            echo "" ;;
    esac
}

echo "Binary: $OPCODE_EXE"
echo "Wine:   $WINE"
echo

# ---------------------------------------------------------------- unit tests
echo "Unit binaries (build/win/tests/*.exe):"
for t in tests/*.s; do
    n=$(basename "$t" .s)
    rc=0
    timeout 120 "$WINE" "build/win/tests/$n.exe" > "build/$n.out" 2>&1 || rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "FAIL $n (exit $rc)"
        sed -n '1,10p' "build/$n.out" || true
        fail=$((fail + 1))
    elif cmp -s "build/$n.out" "tests/data/$n.expected"; then
        echo "ok   $n"
        pass=$((pass + 1))
    else
        echo "FAIL $n (output)"
        diff -u "tests/data/$n.expected" "build/$n.out" | head -20 || true
        fail=$((fail + 1))
    fi
done

# ---------------------------------------------------------------- CLI checks
echo
echo "CLI checks:"
v=$(cat VERSION)
if [ "$(timeout 60 "$WINE" "$OPCODE_EXE" --version)" = "opcode $v" ]; then
    echo "ok   cli-version"
    pass=$((pass + 1))
else
    echo "FAIL cli-version"
    fail=$((fail + 1))
fi
if timeout 60 "$WINE" "$OPCODE_EXE" --help 2>&1 | head -1 | grep -q '^opcode - a minimal extensible coding agent$'; then
    echo "ok   cli-help"
    pass=$((pass + 1))
else
    echo "FAIL cli-help"
    fail=$((fail + 1))
fi
rc=0
timeout 60 "$WINE" "$OPCODE_EXE" --nope > /dev/null 2>&1 && rc=0 || rc=$?
if [ "$rc" = 2 ]; then
    echo "ok   cli-unknown"
    pass=$((pass + 1))
else
    echo "FAIL cli-unknown (exit $rc)"
    fail=$((fail + 1))
fi

# ---------------------------------------------------------------- suites
run_suite() { # name script...
    _name=$1
    shift
    _rc=0
    _out=$(timeout 900 "$@" 2>&1) || _rc=$?
    printf '%s\n' "$_out"
    _n=$(printf '%s\n' "$_out" | grep -c '^ok ' || true)
    _f=$(printf '%s\n' "$_out" | grep -c '^FAIL ' || true)
    pass=$((pass + _n))
    # every FAIL line is either a documented divergence or a real failure
    printf '%s\n' "$_out" | sed -n 's/^FAIL \([^ ]*\).*/\1/p' | while read -r _check; do
        _why=$(divergence_reason "$_check")
        if [ -n "$_why" ]; then
            printf '  (wine divergence: %s)\n' "$_why"
        fi
    done
    _real=0
    for _check in $(printf '%s\n' "$_out" | sed -n 's/^FAIL \([^ ]*\).*/\1/p'); do
        _why=$(divergence_reason "$_check")
        if [ -n "$_why" ]; then
            note_skip "$_check" "$_why"
        else
            _real=$((_real + 1))
        fi
    done
    fail=$((fail + _real))
    if [ "$_n" -eq 0 ] && [ "$_f" -eq 0 ]; then
        echo "FAIL $_name (no result lines, exit $_rc)"
        fail=$((fail + 1))
    elif [ "$_rc" -ne 0 ] && [ "$_real" -ne 0 ]; then
        echo "FAIL $_name (exit $_rc)"
        fail=$((fail + 1))
    elif [ "$_rc" -ne 0 ] && [ "$_f" -eq 0 ]; then
        # No failed check line explains the exit: only the known oauth file
        # mode assertion is accepted, everything else is a real failure.
        if [ "$_name" = "oauth" ] && printf '%s' "$_out" | grep -q 'AssertionError: 0o100644'; then
            note_skip "$_name (file modes)" "POSIX 0600 is not a Win32 concept; the auth file keeps the host mode"
        else
            echo "FAIL $_name (exit $_rc)"
            fail=$((fail + 1))
        fi
    fi
}

if command -v python3 > /dev/null 2>&1; then
    echo
    echo "Integration suites:"
    # Same order as tests/run.sh so suite-to-suite state matches the native lane.
    run_suite net tests/net.sh
    run_suite update tests/update.sh
    run_suite agent tests/agent.sh
    run_suite compact_cli tests/compact_cli.sh
    run_suite session_cli tests/session_cli.sh
    run_suite tui tests/tui.sh
    run_suite term_state python3 tests/term_state.py
    run_suite modes tests/modes.sh
    run_suite onboarding tests/onboarding.sh
    run_suite mcp tests/mcp.sh
    run_suite oauth tests/oauth.sh
else
    echo "python3 not found: integration suites not run"
fi

echo
if [ -n "$skip_log" ]; then
    printf '%s' "$skip_log"
fi
echo "TESTS $pass passed, $fail failed ($skip skipped: documented Wine divergences)"
[ "$fail" -eq 0 ]
