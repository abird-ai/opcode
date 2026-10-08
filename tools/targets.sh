#!/bin/sh
# Opcode cross-build target table. Probes the source tree for the paths each
# target needs; the same table lives in lib.opcodeTargets in flake.nix and is
# what release.yml consumes. Keep the three in sync.
#
# usage:
#   tools/targets.sh                  print the table and exit 0
#   tools/targets.sh --enabled NAME   exit 0 when NAME is enabled, 1 otherwise
#   tools/targets.sh --artifact NAME  print the artifact name of NAME
#
# A target is enabled when every path of its gate exists and, for ports that
# need a runner, the CI job that builds and executes it is defined. The native
# linux-x86_64 target has no gate; darwin-arm64 requires the macOS CI job,
# linux-aarch64 the QEMU job and windows-x86_64 the Wine lane. `--enabled` is
# the CI gate: a closed target is skipped with an ::notice::, never built.
#
# darwin-x86_64 is NOT part of this port: the Darwin work is AArch64-only and
# the Makefile fails fast on every darwin-* TARGET except darwin-arm64. Its
# gate names the x86_64 Darwin platform/net sources that would be needed, and
# those do not exist, so the target stays closed on every host.
set -u
cd "$(dirname "$0")/.." || exit 1

TARGETS='linux-x86_64 linux-aarch64 linux-riscv64 windows-x86_64 darwin-arm64 darwin-x86_64'

# The darwin-arm64 target is a port plus a runner: a macOS job in release.yml
# must build and test it and publish the opcode-darwin-arm64 artifact. Without
# that job the target is not shipped, so the gate stays closed.
macos_ci_job() {
    [ -f .github/workflows/release.yml ] &&
        grep -q 'macos-14' .github/workflows/release.yml &&
        grep -q 'opcode-darwin-arm64' .github/workflows/release.yml
}

# The linux-aarch64 port requires an x86_64-linux CI job that cross-builds
# the static ELF and runs the full suite under qemu-aarch64 before the
# target is shipped.  The release step must also verify the same target.
linux_aarch64_qemu_ci_job() {
    [ -f .github/workflows/ci.yml ] &&
        grep -q 'build and test linux-aarch64 with QEMU' .github/workflows/ci.yml &&
        grep -q 'EMULATOR=qemu-aarch64' .github/workflows/ci.yml &&
    [ -f .github/workflows/release.yml ] &&
        grep -q 'Build and verify linux-aarch64 under QEMU' .github/workflows/release.yml &&
        grep -q 'EMULATOR=qemu-aarch64' .github/workflows/release.yml
}

# The windows-x86_64 port is cross-built on x86_64-linux and must pass its
# Wine lane (unit binaries, CLI checks, integration subset) in CI and in
# the release job before the PE can ship.  A source-only port stays closed.
windows_wine_ci_job() {
    [ -f .github/workflows/ci.yml ] &&
        grep -q 'build and verify windows-x86_64 under Wine' .github/workflows/ci.yml &&
        grep -q 'test-wine' .github/workflows/ci.yml &&
    [ -f .github/workflows/release.yml ] &&
        grep -q 'windows-x86_64 under Wine' .github/workflows/release.yml &&
        grep -q 'test-wine' .github/workflows/release.yml
}

enabled() {
    case "$1" in
        linux-x86_64) return 0 ;;
        linux-aarch64) [ -f tools/arm64.py ] && [ -d src/plat/linux/aarch64 ] && linux_aarch64_qemu_ci_job ;;
        linux-riscv64) [ -d src/plat/riscv64 ] && [ -d src/net/riscv64 ] ;;
        windows-x86_64) [ -d src/plat/win ] && [ -d src/net/win ] && [ -f tests/run-wine.sh ] && windows_wine_ci_job ;;
        darwin-arm64) [ -d src/plat/mac ] && [ -d src/net/mac ] && [ -f tools/arm64.py ] && macos_ci_job ;;
        darwin-x86_64) [ -d src/plat/mac/x86_64 ] && [ -d src/net/mac/x86_64 ] ;;
        *) return 1 ;;
    esac
}

gate() {
    case "$1" in
        linux-x86_64) echo 'native' ;;
        linux-aarch64)
            # The translator emits `bl x_syscall`, but the Linux/AArch64 port
            # has no x_syscall: src/plat/linux/*.s wrap the raw x86 syscall
            # model. Until a native shim exists under src/plat/linux/aarch64/,
            # flipping this target feeds Intel-syntax sources to aarch64-as.
            if [ ! -f tools/arm64.py ]; then
                echo 'tools/arm64.py (translator missing)'
            elif [ ! -d src/plat/linux/aarch64 ]; then
                echo 'needs an AArch64 Linux syscall shim (translator emits bl x_syscall)'
            elif ! linux_aarch64_qemu_ci_job; then
                echo 'needs linux-aarch64 QEMU CI job (cross-build + qemu-aarch64 full suite)'
            else
                echo 'tools/arm64.py + src/plat/linux/aarch64 + QEMU CI (cross-build + full suite; Darwin arm64 unverified on its own runner)'
            fi ;;
        linux-riscv64) echo 'src/plat/riscv64 + src/net/riscv64' ;;
        windows-x86_64)
            if [ ! -d src/plat/win ] || [ ! -d src/net/win ]; then
                echo 'src/plat/win + src/net/win'
            elif [ ! -f tests/run-wine.sh ]; then
                echo 'tests/run-wine.sh (Wine execution harness missing)'
            elif ! windows_wine_ci_job; then
                echo 'needs windows-x86_64 Wine CI job (build + unit/CLI/integration subset)'
            else
                echo 'src/plat/win + src/net/win + Wine CI (win_syscall PE, unit/CLI/integration subset)'
            fi ;;
        darwin-arm64) echo 'src/plat/mac + src/net/mac + tools/arm64.py + macos-14 CI job' ;;
        darwin-x86_64) echo 'src/plat/mac/x86_64 + src/net/mac/x86_64' ;;
        *) echo 'unknown target' ;;
    esac
}

artifact() {
    case "$1" in
        linux-x86_64) echo 'opcode-linux-x86_64' ;;
        linux-aarch64) echo 'opcode-linux-aarch64' ;;
        linux-riscv64) echo 'opcode-linux-riscv64' ;;
        windows-x86_64) echo 'opcode-windows-x86_64.exe' ;;
        darwin-arm64) echo 'opcode-darwin-arm64' ;;
        darwin-x86_64) echo 'opcode-darwin-x86_64' ;;
        *) return 1 ;;
    esac
}

case "${1:-}" in
    --enabled)
        [ $# -eq 2 ] || { echo "usage: $0 --enabled TARGET" >&2; exit 2; }
        enabled "$2"
        exit $?
        ;;
    --artifact)
        [ $# -eq 2 ] || { echo "usage: $0 --artifact TARGET" >&2; exit 2; }
        artifact "$2" || { echo "unknown target: $2" >&2; exit 2; }
        exit 0
        ;;
    --help|-h)
        sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    "")
        # Size the GATE column to the longest entry: the linux-aarch64 gate
        # text is much longer than the rest, and a fixed width would push the
        # ENABLED/ARTIFACT columns out of alignment.
        gate_w=4
        for t in $TARGETS; do
            g=$(gate "$t")
            [ ${#g} -gt $gate_w ] && gate_w=${#g}
        done
        printf '%-18s %-*s %-8s %s\n' 'TARGET' "$gate_w" 'GATE' 'ENABLED' 'ARTIFACT'
        for t in $TARGETS; do
            if enabled "$t"; then e=yes; else e=no; fi
            printf '%-18s %-*s %-8s %s\n' "$t" "$gate_w" "$(gate "$t")" "$e" "$(artifact "$t")"
        done
        ;;
    *)
        echo "usage: $0 [--enabled TARGET | --artifact TARGET]" >&2
        exit 2
        ;;
esac
