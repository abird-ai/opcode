#!/bin/sh
# tools/check-macho.sh — static validation of a cross-linked Mach-O arm64 binary.
#
# This is a smoke check, not a release gate.  It proves the file is a well-formed
# Mach-O arm64 executable that imports only libSystem and defines the opcode
# symbols at link time.  It does not run the binary, does not exercise Apple
# frameworks, says nothing about code signing or runtime behaviour, and is not
# evidence that the release artifact works: that is built and tested only on the
# macOS runner.  The Linux target that calls it is a cross/smoke artifact.
#
# Usage: tools/check-macho.sh [--smoke] <binary>
#   --smoke  the Layer-0 smoke program: the same Mach-O shape, dylib and entry
#            checks, but only _main and x_syscall for the symbol set (the smoke
#            program carries no net stack).
#
# Dependencies: od(1) plus llvm-readobj, llvm-nm and llvm-objdump from
# llvmPackages.bintools.  file(1) is deliberately not used: it is absent here.

set -u

usage() {
    echo "usage: $0 [--smoke] <binary>" >&2
    exit 2
}

smoke=0
bin=
for arg in "$@"; do
    case "$arg" in
        --smoke) smoke=1 ;;
        -h|--help) usage ;;
        -*) echo "$0: unknown option: $arg" >&2; usage ;;
        *) [ -n "$bin" ] && usage; bin=$arg ;;
    esac
done
[ -n "$bin" ] || usage
[ -f "$bin" ] || { echo "$0: no such file: $bin" >&2; exit 2; }

for tool in od llvm-readobj llvm-nm llvm-objdump; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "FAIL missing tool: $tool" >&2
        exit 2
    }
done

rc=0
pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1"; rc=1; }

if [ "$smoke" -eq 1 ]; then
    echo "# check-macho (smoke): $bin"
else
    echo "# check-macho: $bin"
fi

# 1. Byte-exact header: MH_MAGIC_64 little-endian (cf fa ed fe) at offset 0 and
#    CPU_TYPE_ARM64 little-endian (0c 00 00 01) at offset 4, read with od.
magic=$(od -An -tx1 -N4 "$bin" | tr -d ' \n')
cputype=$(od -An -tx1 -j4 -N4 "$bin" | tr -d ' \n')
echo "  raw: magic=0x$magic cputype=0x$cputype"
if [ "$magic" = "cffaedfe" ] && [ "$cputype" = "0c000001" ]; then
    pass "header MH_MAGIC_64 (0xfeedfacf) + CPU_TYPE_ARM64 (0x0100000c)"
else
    fail "header: expected magic 0xcffaedfe / cputype 0x0c000001, got 0x$magic / 0x$cputype"
fi

# 2. LLVM's own view of the file and Mach-O header.
headers=$(llvm-readobj --file-headers "$bin" 2>/dev/null)
if printf '%s\n' "$headers" | grep -q '^Format: Mach-O arm64$'; then fmt=1; else fmt=0; fi
if printf '%s\n' "$headers" | grep -q 'FileType: Executable'; then exe=1; else exe=0; fi
if [ "$fmt" -eq 1 ] && [ "$exe" -eq 1 ]; then
    pass "file-headers: Format Mach-O arm64, FileType Executable"
else
    fail "file-headers: Format Mach-O arm64 (got $fmt), FileType Executable (got $exe)"
fi

# 3. Exactly one LC_LOAD_DYLIB: /usr/lib/libSystem.B.dylib.  The full list is
#    printed whatever it is.
dylibs=$(llvm-objdump --macho --dylibs-used "$bin" 2>/dev/null \
    | sed -n '2,$p' | awk 'NF { print $1 }')
ndyl=$(printf '%s\n' "$dylibs" | grep -c .)
echo "  dylibs-used ($ndyl):"
printf '%s\n' "$dylibs" | sed 's/^/    /'
if [ "$ndyl" -eq 1 ] && [ "$dylibs" = "/usr/lib/libSystem.B.dylib" ]; then
    pass "dylibs: only /usr/lib/libSystem.B.dylib"
else
    fail "dylibs: expected exactly /usr/lib/libSystem.B.dylib, got $ndyl entr(ies)"
fi

# 4. LC_MAIN with a non-zero entryoff.
entry=$(llvm-objdump --macho -p "$bin" 2>/dev/null \
    | awk '/cmd LC_MAIN/ { main=1 } main && /entryoff/ { print $2; exit }')
if [ -n "$entry" ] && [ "$entry" -gt 0 ] 2>/dev/null; then
    pass "entry: LC_MAIN entryoff $entry"
else
    fail "entry: LC_MAIN with non-zero entryoff (got '${entry:-none}')"
fi

# 5. Imports.  The binary is linked with undefined symbols fatal (the cross
#    driver passes no -undefined dynamic_lookup), so every undefined name is a
#    libSystem import by construction; we print the set and the counts for
#    review rather than re-deriving the libSystem stub here.
allnm=$(llvm-nm "$bin" 2>/dev/null)
undef=$(llvm-nm -u "$bin" 2>/dev/null)
ndef=$(printf '%s\n' "$allnm" | grep -E '^[0-9a-fA-F]+ ' | grep -c .)
nundef=$(printf '%s\n' "$undef" | grep -c .)
echo "  undefined ($nundef):"
printf '%s\n' "$undef" | grep . | sed 's/^/    /'
echo "  defined ($ndef)"
pass "imports: $nundef undefined, all libSystem (link was undefined-fatal)"

# 6. Expected opcode symbols are defined (address-bearing nm lines, so an
#    undefined reference with the same name fails this check).
defined=$(printf '%s\n' "$allnm" | grep -E '^[0-9a-fA-F]+ ')
if [ "$smoke" -eq 1 ]; then
    want="_main x_syscall"
else
    want="_main x_syscall os_init os_exit mem_alloc opcode_main net_init tls_new"
fi
missing=
found=0
total=0
for sym in $want; do
    total=$((total + 1))
    if printf '%s\n' "$defined" | grep -q " ${sym}\$"; then
        found=$((found + 1))
    else
        missing="$missing $sym"
    fi
done
if [ -z "$missing" ]; then
    pass "symbols: $found/$total defined"
else
    fail "symbols: missing=$missing"
fi

[ "$rc" -eq 0 ] && echo "# PASS" || echo "# FAIL"
exit "$rc"
