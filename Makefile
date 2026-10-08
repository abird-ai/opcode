# Opcode — Linux x86-64, static, no libc.
#
#   make               build/opcode (Linux x86-64, static)
#   make release       stripped build/opcode
#   make test          build the unit-test binaries
#   make check         build + run the full suite (tests/run.sh)
#   make darwin-arm64  build/opcode-darwin-arm64 (Mach-O arm64; see the darwin section)
#   make linux-aarch64 build/opcode-linux-aarch64 (static ELF aarch64; see its section)
#   make clean
#
# Everything portable is assembled from src/**; platform sources come from
# src/plat/linux and src/net/linux; the tests link the mock net backend instead.

AS     ?= as
LD     ?= ld
# The project toolchain is clang (freestanding); command-line `make CC=...`
# still overrides this.
CC     := clang
PYTHON ?= python3

# Cross builds select the GNU cross toolchain and rename the output:
#   make CROSS=aarch64-unknown-linux-gnu TARGET=linux-aarch64
# Both default to empty, so the native build is unchanged. CROSS only fills
# AS/LD when set; a command-line AS=/LD= still wins. TARGET is the matrix
# target name and only changes the binary name.
CROSS  ?=
TARGET ?=
ifneq ($(CROSS),)
AS := $(CROSS)-as
LD := $(CROSS)-ld
endif
ifeq ($(TARGET),windows-x86_64)
BIN := build/opcode-windows-x86_64.exe
else ifeq ($(TARGET),)
BIN := build/opcode
else
BIN := build/opcode-$(TARGET)
endif

# ---------------------------------------------------------------- flags
# GNU as only understands --64 on the x86 targets; a CROSS toolchain
# (aarch64/riscv64) assembles natively-sized sources without it.
ifneq ($(CROSS),)
ARCHFLAG :=
else
ARCHFLAG := --64
endif

ifeq ($(RELEASE),1)
ASFLAGS  := $(ARCHFLAG) -I src -I build
LDFLAGS  := -static -nostdlib --no-dynamic-linker -z noexecstack -s
else
ASFLAGS  := $(ARCHFLAG) -I src -I build -g
LDFLAGS  := -static -nostdlib --no-dynamic-linker -z noexecstack
endif

# Every assembler source depends on all headers: a coarse but correct rule.
HDRS := $(shell find src -name '*.inc') \
        third_party/mbedtls_opcode_config.h third_party/mbedtls_glue.c \
        src/net/linux/tls_shim.h $(shell find third_party/mbedtls -name '*.h')

# glibc's fortify headers reject MB_LEN_MAX != 16 when the macro is defined;
# clang's freestanding <limits.h> otherwise defines it to 1.
MBEDTLS_CFLAGS := -O2 -ffreestanding -fno-stack-protector -fno-builtin -fno-pic \
    -mno-red-zone -nostdlib -DMB_LEN_MAX=16 \
    '-DMBEDTLS_CONFIG_FILE="mbedtls_opcode_config.h"' \
    -I third_party -I third_party/mbedtls/include -I third_party/mbedtls/library

# ---------------------------------------------------------------- sources
SSRC    := $(shell find src -name '*.s' ! -path 'src/mac/*' ! -path 'src/win/*' \
                 ! -path 'src/plat/mac/*' ! -path 'src/net/mac/*' \
                 ! -path 'src/plat/win/*' ! -path 'src/net/win/*' \
                 ! -path 'src/plat/linux/aarch64/*')
APPSRC  := $(filter src/app/%,$(SSRC))
NETSRC  := $(filter src/net/linux/%,$(SSRC))
CORESRC := $(filter-out $(APPSRC) $(NETSRC) src/net/mock.s,$(SSRC))

GENS    := build/assets.s build/catalog.s build/plugins.s
APP_OBJS  := $(addprefix build/obj/,$(APPSRC:.s=.o))
NET_OBJS  := $(addprefix build/obj/,$(NETSRC:.s=.o))
CORE_OBJS := $(addprefix build/obj/,$(CORESRC:.s=.o))
GEN_OBJS  := $(addprefix build/obj/,$(GENS:.s=.o))
MOCK_OBJS := build/obj/src/net/mock.o

MBED_OBJS := $(addprefix build/obj/,$(addsuffix .o,$(basename $(shell cat third_party/mbedtls_sources.txt))))

# One object (+ init symbol rename) per plugin source from the manifest.
PLUGIN_OBJS :=
# These rules are emitted before `all`; keep `all` the default goal.
.DEFAULT_GOAL := all
define PLUGIN_RULE
build/obj/plugins/$(1)_$(notdir $(basename $(2))).o: $(2) $$(HDRS) plugins/manifest.json
	@mkdir -p $$(@D)
	$$(CC) $$(MBEDTLS_CFLAGS) -Dopcode_plugin_init=opcode_plugin_init_$(1) -c $$< -o $$@
PLUGIN_OBJS += build/obj/plugins/$(1)_$(notdir $(basename $(2))).o
endef
$(foreach l,$(shell $(PYTHON) tools/gen-plugins.py --list 2>/dev/null),\
    $(eval $(call PLUGIN_RULE,$(firstword $(subst :, ,$(l))),$(lastword $(subst :, ,$(l))))))

OBJS := $(CORE_OBJS) $(NET_OBJS) $(APP_OBJS) $(GEN_OBJS) $(MBED_OBJS) $(PLUGIN_OBJS)

TESTS    := $(notdir $(basename $(wildcard tests/*.s)))
TESTBINS := $(addprefix build/,$(TESTS))

# ---------------------------------------------------------------- darwin-arm64
# `make darwin-arm64` (equivalent to `make TARGET=darwin-arm64`) builds
# build/opcode-darwin-arm64 as a dynamic Mach-O arm64 executable.  A macOS arm64
# object set mixes three kinds, all under build/mac/ so they never collide with
# the Linux build/obj tree:
#   * translated  — every portable source plus the src/plat/linux and
#     src/net/linux Layer-0/1 wrappers, lowered by tools/arm64.py and assembled.
#     Those wrappers are pure `SYS n` shims over the native Darwin syscall table
#     (ADR-5);
#   * native      — src/plat/mac and src/net/mac are AArch64 already and are
#     assembled as authored, never translated;
#   * C           — the vendored mbedTLS sources (third_party/mbedtls_sources.txt
#     already lists the glue and the TLS shim) and the plugin sources, compiled
#     for arm64-apple-macos11.
# One file drives a real macOS runner (native Apple clang; -target is redundant
# but harmless) and a Linux host (clang is the LLVM cross-assembler).  Nothing
# here is used by the default Linux build.
ARM64_CC      ?= clang
# The Mach-O link driver; on macOS clang wraps the linker.  Naming a cross
# linker here (or MAC_LINK=1) enables the link on a non-Darwin host.
ARM64_LD      ?= $(ARM64_CC)
ARM64_INC     := -I src -I build
# The native Darwin sources .include "mac.inc" from src/plat/mac, so the
# assembler needs that directory on its include path; it is harmless for the
# translated sources, whose includes tools/arm64.py has already resolved.
ARM64_ASFLAGS := -target arm64-apple-macos11 -c -I src/plat/mac -I src/net/mac
ARM64_CFLAGS  := $(ARM64_ASFLAGS) -O2 -ffreestanding -fno-stack-protector \
    -fno-builtin -fno-pic -nostdlib -DMB_LEN_MAX=16 -ffixed-x28 \
    '-DMBEDTLS_CONFIG_FILE="mbedtls_opcode_config.h"' \
    -I third_party -I third_party/mbedtls/include -I third_party/mbedtls/library
ARM64_LDFLAGS ?= -target arm64-apple-macos11

# On a macOS host the native SDK headers are correct.  Any other host has no
# Apple SDK, so the freestanding C sources are preprocessed against the host's
# libc headers with the two collisions between those headers and an Apple target
# neutralised: __nonnull is a clang builtin on Apple targets (glibc wants to
# define it as __attribute__((__nonnull__))), and glibc's bits/floatn.h enables
# __float128 which arm64 clang rejects — faking the Intel SYCL guard makes its
# __HAVE_FLOAT128 test false.  build/mac/include/gnu/stubs-32.h is an empty
# shadow of the x86-64 stubs header glibc includes for a non-x86_64 target; it
# only lets the target-clean declarations parse.  None of this reaches the Linux
# build or a real macOS runner.
HOST_DARWIN := $(filter Darwin,$(shell uname -s 2>/dev/null))
ifeq ($(HOST_DARWIN),)
MAC_C_SHIM   := -I build/mac/include -U__nonnull \
    -D__INTEL_LLVM_COMPILER=1 -DSYCL_LANGUAGE_VERSION=1
MAC_SHIM_HDR := build/mac/include/gnu/stubs-32.h
endif

# The generated sources a macOS build needs.  The plugin table has its own
# Mach-O variant because it references the plugin init symbols by bare name:
# the Darwin table must carry the leading underscore the C compiler gives the
# definition.  Linux keeps build/plugins.s, byte for byte.
MAC_GENS := build/assets.s build/catalog.s build/plugins-mac.s

# smoke.s is the one x86-64 source in src/plat/mac: it is translated, so it is
# kept out of the native list and pulled in only by the smoke target.
MAC_X86SRC := $(shell find src -name '*.s' \
        ! -path 'src/plat/mac/*' ! -path 'src/net/mac/*' \
        ! -path 'src/plat/win/*' ! -path 'src/net/win/*' \
        ! -path 'src/plat/linux/aarch64/*' \
        ! -path 'src/mac/*' ! -path 'src/win/*' ! -path 'src/net/mock.s') \
    $(MAC_GENS)
MAC_NATSRC := $(filter-out src/plat/mac/smoke.s, \
    $(shell find src/plat/mac src/net/mac -name '*.s' 2>/dev/null))
MAC_CSRC   := $(shell cat third_party/mbedtls_sources.txt)

# The syntax gate's translated list is the portable set plus the generated
# sources and the tests; the mock backend is assembled there too, as on Linux.
# It keeps the src/plat/linux and src/net/linux wrappers out so the gate's
# assembly count stays a portable-coverage measure; the mac app build adds them
# through MAC_X86SRC.
ARM64_X86SRC := $(shell find src -name '*.s' \
        ! -path 'src/plat/linux/*' ! -path 'src/net/linux/*' ! -path 'src/net/mock.s' \
        ! -path 'src/plat/mac/*' ! -path 'src/net/mac/*' \
        ! -path 'src/plat/win/*' ! -path 'src/net/win/*' ! -path 'src/mac/*' ! -path 'src/win/*') \
    $(GENS) $(wildcard tests/*.s)
ARM64_MOCKSRC := src/net/mock.s
ARM64_ASM  := $(addprefix build/arm64/,$(ARM64_X86SRC:.s=.s)) \
              $(addprefix build/arm64/,$(ARM64_MOCKSRC:.s=.s))
ARM64_OBJS := $(addprefix build/arm64/,$(ARM64_X86SRC:.s=.o)) \
              $(addprefix build/arm64/,$(ARM64_MOCKSRC:.s=.o)) \
              $(addprefix build/arm64/,$(MAC_NATSRC:.s=.o))

MAC_BIN         := build/opcode-darwin-arm64
MAC_TR_ASM      := $(addprefix build/mac/,$(MAC_X86SRC:.s=.s))
MAC_TR_OBJS     := $(addprefix build/mac/,$(MAC_X86SRC:.s=.o))
MAC_NAT_OBJS    := $(addprefix build/mac/native/,$(notdir $(MAC_NATSRC:.s=.o)))
MAC_C_OBJS      := $(addprefix build/mac/c/,$(MAC_CSRC:.c=.o))
MAC_PLUGIN_OBJS :=
# One arm64 C object (+ init symbol rename) per plugin source, as on Linux.
define MAC_PLUGIN_RULE
build/mac/c/plugins/$(1)_$(notdir $(basename $(2))).o: $(2) $$(HDRS) plugins/manifest.json $$(MAC_SHIM_HDR)
	@mkdir -p $$(@D)
	$$(ARM64_CC) $$(ARM64_CFLAGS) $$(MAC_C_SHIM) -Dopcode_plugin_init=opcode_plugin_init_$(1) -c $$< -o $$@
MAC_PLUGIN_OBJS += build/mac/c/plugins/$(1)_$(notdir $(basename $(2))).o
endef
$(foreach l,$(shell $(PYTHON) tools/gen-plugins.py --list 2>/dev/null),\
    $(eval $(call MAC_PLUGIN_RULE,$(firstword $(subst :, ,$(l))),$(lastword $(subst :, ,$(l))))))
MAC_OBJS := $(MAC_TR_OBJS) $(MAC_NAT_OBJS) $(MAC_C_OBJS) $(MAC_PLUGIN_OBJS)

# Smoke program: translated like the app sources, linked with the full native
# and C object set minus the normal entry point, since the smoke program brings
# its own _start.
SMOKE_BIN  := build/smoke-darwin-arm64
SMOKE_ASM  := build/mac/src/plat/mac/smoke.s
SMOKE_OBJ  := build/mac/src/plat/mac/smoke.o
SMOKE_OBJS := $(SMOKE_OBJ) $(filter-out build/mac/src/base/start.o,$(MAC_OBJS))

# Unit-test binaries for arm64: the mac mirror of the Linux `$(TESTBINS)` rule
# below.  The portable core is translated, the Darwin shim (src/plat/mac and the
# low-level src/net/mac sys_* wrappers its syscall table names) supplies the
# entry point and syscalls, and the translated mock backend stands in for the
# translated src/net/linux protocol layer.  mbedTLS is omitted because the mock
# supplies net_*/tls_*, exactly as on Linux; the generated and plugin objects
# are included as there too.
MAC_TEST_X86SRC   := $(filter-out src/app/% src/net/linux/%,$(MAC_X86SRC)) \
                     src/net/mock.s
MAC_TEST_TR_OBJS  := $(addprefix build/mac/,$(MAC_TEST_X86SRC:.s=.o))
MAC_TEST_OBJS     := $(MAC_TEST_TR_OBJS) $(MAC_NAT_OBJS) $(MAC_PLUGIN_OBJS)
MAC_TESTBINS      := $(addprefix build/mac/tests/,$(TESTS))

# Live-network variant of tests/discover_test.s for tests/ollama.sh: the same
# source translated with OPCODE_LIVE defined (the `.ifdef` picks the real net
# stack instead of the mock replay) and linked against the app object set minus
# src/app, which defines the normal opcode_main the test file replaces.  This is
# the Mach-O counterpart of the `as --defsym OPCODE_LIVE=1` helper tests/ollama.sh
# builds on Linux, and it is deliberately separate from MAC_TEST_OBJS above,
# whose mock backend cannot reach a live server.
MAC_LIVE_BIN  := build/mac/tests/discover_live
MAC_LIVE_ASM  := build/mac/tests/discover_live.s
MAC_LIVE_OBJ  := build/mac/tests/discover_live.o
MAC_LIVE_OBJS := $(filter-out \
    $(addprefix build/mac/,$(filter src/app/%,$(MAC_X86SRC:.s=.o))),$(MAC_OBJS))

# A Mach-O link needs a Mach-O linker.  On Darwin clang is one; on any other
# host the default toolchain cannot link Mach-O, so the link is skipped with a
# message instead of being allowed to emit a foreign binary.  Naming
# ARM64_LD/ARM64_CC on the command line (or setting MAC_LINK=1) declares that
# the caller supplies one.
MAC_LINK_OK :=
ifeq ($(HOST_DARWIN),Darwin)
MAC_LINK_OK := 1
endif
ifneq ($(filter command line environment override,$(origin ARM64_LD) $(origin ARM64_CC)),)
MAC_LINK_OK := 1
endif
ifneq ($(MAC_LINK),)
MAC_LINK_OK := 1
endif

# ---------------------------------------------------------------- linux-aarch64
# `make linux-aarch64` (equivalent to `make TARGET=linux-aarch64`) builds
# build/opcode-linux-aarch64 as a static, no-libc ELF aarch64 executable.  The
# object set mixes three kinds, all under build/a64/ so they never collide
# with the Linux build/obj tree or the darwin build/mac tree:
#   * translated  — every portable source plus the src/plat/linux and
#     src/net/linux Layer-0/1 wrappers, lowered by tools/arm64.py --os linux
#     and assembled by the GNU cross assembler;
#   * native      — src/plat/linux/aarch64 is AArch64 already (the x_syscall
#     shim, the translator runtime helpers, the ELF entry point) and is
#     assembled as authored, never translated;
#   * C           — the vendored mbedTLS sources, the glue, the TLS shim and
#     the plugin sources, compiled by a real aarch64-unknown-linux-gnu-gcc
#     (its own aarch64 glibc sysroot supplies the freestanding headers).
# The toolchain is overridable with A64_CC=/A64_AS=/A64_LD=.  Nothing here is
# used by the default Linux build.
A64_CC      ?= aarch64-unknown-linux-gnu-gcc
A64_AS      ?= aarch64-unknown-linux-gnu-as
A64_LD      ?= aarch64-unknown-linux-gnu-ld
A64_INC     := -I src -I build
# The native sources .include "plat/linux/aarch64/linux.inc" (so the frozen
# acceptance command `as -c -I src ...` resolves it), which is why the
# assembler gets -I src; the platform directory is harmless for the
# translated sources, whose includes tools/arm64.py has already resolved.
# The translated sources are pure baseline Armv8.0: tools/arm64.py lowers the
# x86 carry-inversion through NZCV, never cfinv (FEAT_FlagM, Armv8.4), so pin
# the assembler to the baseline ISA the runtime contract promises.  This is
# the flag the old `cfinv` rejection exposed; the flake check and the CI lanes
# all assemble through this variable.
A64_ASFLAGS := -march=armv8-a -I src -I src/plat/linux/aarch64
# The nix cc-wrapper compiles with _FORTIFY_SOURCE=3 by default and appends
# it after user flags, so the C recipes set NIX_HARDENING_ENABLE= to drop the
# wrapper's hardening set (the freestanding build has no __memcpy_chk/
# __memset_chk; the nix derivation sets hardeningDisable=["fortify"] for the
# same reason).
# x28 is the translator's x86 rsp.  AAPCS makes x19-x28 callee-saved, so a C
# function preserves its incoming x28 across every call it makes — but it is
# free to *use* x28 inside its own body.  A C body that reuses x28 and then
# calls a translated function would hand that function a garbage xsp, so the
# whole C corpus is compiled with x28 reserved: GCC/clang never allocate it and
# x28 then holds the translated rsp at every C -> asm boundary (the entry stub
# relies on it).  Only the aarch64 C objects need this.
A64_CFLAGS  := -O2 -ffreestanding -fno-stack-protector -fno-builtin -fno-pic \
    -nostdlib -DMB_LEN_MAX=16 -ffixed-x28 \
    '-DMBEDTLS_CONFIG_FILE="mbedtls_opcode_config.h"' \
    -I third_party -I third_party/mbedtls/include -I third_party/mbedtls/library
A64_LDFLAGS := -static -nostdlib --no-dynamic-linker -z noexecstack -e opcode_entry

# The generated sources are shared with the Linux build: build/plugins.s is
# already ELF (the Mach-O table is a separate file).
A64_X86SRC := $(shell find src -name '*.s' \
        ! -path 'src/plat/linux/aarch64/*' \
        ! -path 'src/plat/mac/*' ! -path 'src/net/mac/*' \
        ! -path 'src/plat/win/*' ! -path 'src/net/win/*' \
        ! -path 'src/mac/*' ! -path 'src/win/*' ! -path 'src/net/mock.s') \
    $(GENS)
A64_NATSRC := $(shell find src/plat/linux/aarch64 -name '*.s' 2>/dev/null)
A64_CSRC   := $(shell cat third_party/mbedtls_sources.txt)

A64_TR_ASM     := $(addprefix build/a64/,$(A64_X86SRC:.s=.s))
A64_TR_OBJS    := $(addprefix build/a64/,$(A64_X86SRC:.s=.o))
A64_NAT_OBJS   := $(addprefix build/a64/native/,$(notdir $(A64_NATSRC:.s=.o)))
A64_C_OBJS     := $(addprefix build/a64/c/,$(A64_CSRC:.c=.o))
A64_PLUGIN_OBJS :=
# One aarch64 C object (+ init symbol rename) per plugin source, as on Linux.
define A64_PLUGIN_RULE
build/a64/c/plugins/$(1)_$(notdir $(basename $(2))).o: $(2) $$(HDRS) plugins/manifest.json
	@mkdir -p $$(@D)
	NIX_HARDENING_ENABLE= $$(A64_CC) $$(A64_CFLAGS) -Dopcode_plugin_init=opcode_plugin_init_$(1) -c $$< -o $$@
A64_PLUGIN_OBJS += build/a64/c/plugins/$(1)_$(notdir $(basename $(2))).o
endef
$(foreach l,$(shell $(PYTHON) tools/gen-plugins.py --list 2>/dev/null),\
    $(eval $(call A64_PLUGIN_RULE,$(firstword $(subst :, ,$(l))),$(lastword $(subst :, ,$(l))))))
A64_OBJS := $(A64_TR_OBJS) $(A64_NAT_OBJS) $(A64_C_OBJS) $(A64_PLUGIN_OBJS)
A64_BIN  := build/opcode-linux-aarch64

# Unit-test binaries for linux-aarch64: the mirror of the Linux `$(TESTBINS)`
# rule.  The portable core is translated, the aarch64 shim
# (src/plat/linux/aarch64) supplies the ELF entry point (opcode_entry) and the
# syscalls, and the translated mock backend stands in for the translated
# src/net/linux protocol layer.  mbedTLS is omitted because the mock supplies
# net_*/tls_*, exactly as on Linux; the generated and plugin objects are
# included as there too.
A64_MOCKSRC     := src/net/mock.s
A64_TEST_X86SRC := $(filter-out src/app/% src/net/linux/%,$(A64_X86SRC)) \
                   $(A64_MOCKSRC)
A64_TEST_TR_OBJS := $(addprefix build/a64/,$(A64_TEST_X86SRC:.s=.o))
A64_TEST_OBJS    := $(A64_TEST_TR_OBJS) $(A64_NAT_OBJS) $(A64_PLUGIN_OBJS)
A64_TESTBINS     := $(addprefix build/a64/tests/,$(TESTS))

# Live-network variant of tests/discover_test.s for tests/ollama.sh: the same
# source translated with OPCODE_LIVE defined (the `.ifdef` picks the real net
# stack instead of the mock replay) and linked against the app object set minus
# src/app, which defines the normal opcode_main the test file replaces.  This is
# the aarch64 counterpart of the `as --defsym OPCODE_LIVE=1` helper
# tests/ollama.sh builds on Linux.
A64_LIVE_BIN  := build/a64/tests/discover_live
A64_LIVE_ASM  := build/a64/tests/discover_live.s
A64_LIVE_OBJ  := build/a64/tests/discover_live.o
A64_LIVE_OBJS := $(filter-out \
    $(addprefix build/a64/,$(filter src/app/%,$(A64_X86SRC:.s=.o))),$(A64_OBJS))

# ------------------------------------------- derived C <-> asm ABI boundary
# ADR-112: the boundary is derived from the *linked objects*, not guessed from
# the assembly syntax.  Two sets reach tools/arm64.py:
#
#   C_CALLEES = every symbol the C objects define.  A direct `call SYM` gets
#               the call-side bridge (`mov x8, x0`) iff SYM is in this set:
#               asm -> C only.  An indirect call always gets it (the target is
#               unknown; a C function pointer is the realistic case).
#   C_UNDEF   = every symbol some C object references but does not define.
#               `--aapcs-entry` carries the whole set; the translator emits the
#               ret-side bridge (`mov x0, x8`) only when the symbol is defined
#               by the unit it is translating, so its per-file filter is
#               exactly (C_UNDEF and defined by translated objects) plus the
#               in-unit address-escape set — CALLBACKS in ADR-112.
#
# The C objects are built first: their recipes name only the .c, the header set
# and mbedtls_sources.txt, so they have no dependency on translated output and
# the lists are complete before any translation starts.  The two list files are
# real prerequisites of every translation rule (not order-only: a changed
# boundary set must re-translate, and order-only would leave the old bridge set
# in place), and the recipe shell joins them at build time — a $(shell ...)
# expansion at parse time would see a clean tree's lists empty and translate
# with no boundary at all.
#
# The names are OS-independent (the same C and asm sources; Mach-O's leading
# underscore is stripped), so one pair of files feeds both trees.  The canonical
# Linux cross build derives it from the aarch64 C objects with the cross nm; the
# Linux-hosted darwin cross derivation (llvm-binutils) and a macOS host, which
# lack the aarch64-linux toolchain, derive the same names from the Mach-O
# objects with the host nm.
A64_NM ?= aarch64-unknown-linux-gnu-nm
MAC_NM ?= nm
ABI_SYMOBJS := $(A64_C_OBJS) $(A64_PLUGIN_OBJS)
ABI_NM      := $(A64_NM)
ABI_DIR     := build/a64
ABI_DEFS_AWK  := awk 'NF >= 3 { print $$3 }'
ABI_UNDEF_AWK := awk 'NF >= 2 { print $$2 }'
ifeq ($(shell command -v $(firstword $(A64_NM)) >/dev/null 2>&1 && echo yes),)
ABI_SYMOBJS := $(MAC_C_OBJS) $(MAC_PLUGIN_OBJS)
ABI_NM      := $(MAC_NM)
ABI_DIR     := build/mac
# Mach-O prefixes external names with '_'; strip one so the sets are the same
# on both object formats.  (The ELF branch must not: __udivti3 is a real name.)
ABI_DEFS_AWK  := awk 'NF >= 3 { sub(/^_/, "", $$3); print $$3 }'
ABI_UNDEF_AWK := awk 'NF >= 2 { sub(/^_/, "", $$2); print $$2 }'
endif
ABI_C_DEFS  := $(ABI_DIR)/c-defs.txt
ABI_C_UNDEF := $(ABI_DIR)/c-undef.txt

$(ABI_C_DEFS): $(ABI_SYMOBJS)
	@mkdir -p $(@D)
	$(ABI_NM) --defined-only --extern-only $(ABI_SYMOBJS) | $(ABI_DEFS_AWK) | sort -u > $@

$(ABI_C_UNDEF): $(ABI_SYMOBJS)
	@mkdir -p $(@D)
	$(ABI_NM) -u $(ABI_SYMOBJS) | $(ABI_UNDEF_AWK) | sort -u > $@

# $$(...) stays a shell command so the lists are read when the recipe runs,
# after the prerequisites have produced them.
ABI_FLAGS = --aapcs-callee "$$(paste -sd, $(ABI_C_DEFS))" \
            --aapcs-entry  "$$(paste -sd, $(ABI_C_UNDEF))"

# ---------------------------------------------------------------- windows-x86_64
# `make windows-x86_64` (equivalent to `make TARGET=windows-x86_64`) builds
# build/opcode-windows-x86_64.exe: PE32+, -nostdlib, no MSVCRT.  The portable
# corpus and the src/plat/linux wrappers are assembled with --defsym WINDOWS=1
# (opcode.inc's SYS macro then calls win_syscall); src/plat/win supplies the
# shim, the PE entry and the native process/console/directory layers; the
# vendored mbedTLS is compiled by the mingw cross compiler and the link pulls
# in kernel32, ws2_32, bcrypt and shell32 only.  The toolchain is overridable
# with WIN_CC=/WIN_AS=/WIN_LD=.  Nothing here is used by the Linux build.
WIN_CC      ?= x86_64-w64-mingw32-gcc
WIN_AS      ?= x86_64-w64-mingw32-as
WIN_LD      ?= $(WIN_CC)
WIN_ASFLAGS := --64 -I src -I build -I src/plat/win --defsym WINDOWS=1
WIN_CFLAGS  := $(MBEDTLS_CFLAGS) -mno-stack-arg-probe -I src/plat/win/include
WIN_LDFLAGS := -nostdlib -Wl,-e,win_start -Wl,--subsystem,console -Wl,--stack,16777216
WIN_LIBS    := -lkernel32 -lws2_32 -lbcrypt -lshell32

# Translated = every portable source plus the src/plat/linux and src/net/linux
# wrappers, minus the three Linux files whose contract is not a thin syscall
# wrapper (proc.s, dir.s, tty.s - native Windows versions live in
# src/plat/win).  src/plat/win is added natively; src/net/mock.s is test-only.
WIN_X86SRC := $(shell find src -name '*.s' \
        ! -path 'src/plat/linux/aarch64/*' \
        ! -path 'src/plat/linux/proc.s' ! -path 'src/plat/linux/dir.s' \
        ! -path 'src/plat/linux/tty.s' \
        ! -path 'src/plat/mac/*' ! -path 'src/net/mac/*' \
        ! -path 'src/plat/win/*' ! -path 'src/net/win/*' \
        ! -path 'src/mac/*' ! -path 'src/win/*' ! -path 'src/net/mock.s') \
    $(GENS)
WIN_NATSRC  := $(shell find src/plat/win -name '*.s')
WIN_TR_OBJS := $(addprefix build/win/,$(WIN_X86SRC:.s=.o))
WIN_NAT_OBJS := $(addprefix build/win/native/,$(notdir $(WIN_NATSRC:.s=.o)))
WIN_CSRC    := $(patsubst src/net/linux/tls_shim.c,src/net/win/tls_shim.c,$(shell cat third_party/mbedtls_sources.txt))
WIN_C_OBJS  := $(addprefix build/win/c/,$(WIN_CSRC:.c=.o))
WIN_PLUGIN_OBJS :=
define WIN_PLUGIN_RULE
build/win/c/plugins/$(1)_$(notdir $(basename $(2))).o: $(2) $$(HDRS) plugins/manifest.json
	@mkdir -p $$(@D)
	$$(WIN_CC) $$(WIN_CFLAGS) -Dopcode_plugin_init=opcode_plugin_init_$(1) -c $$< -o $$@
WIN_PLUGIN_OBJS += build/win/c/plugins/$(1)_$(notdir $(basename $(2))).o
endef
$(foreach l,$(shell $(PYTHON) tools/gen-plugins.py --list 2>/dev/null),\
    $(eval $(call WIN_PLUGIN_RULE,$(firstword $(subst :, ,$(l))),$(lastword $(subst :, ,$(l))))))
WIN_OBJS := $(WIN_TR_OBJS) $(WIN_NAT_OBJS) $(WIN_C_OBJS) $(WIN_PLUGIN_OBJS)
WIN_BIN  := build/opcode-windows-x86_64.exe

# Unit-test binaries: the portable core plus the mock net backend, the native
# Windows layer and the plugin objects; mbedTLS is omitted because the mock
# supplies net_*/tls_*, exactly as on Linux.
WIN_MOCKSRC     := src/net/mock.s
WIN_TEST_X86SRC := $(filter-out src/app/% src/net/linux/%,$(WIN_X86SRC)) \
                   $(WIN_MOCKSRC)
WIN_TEST_OBJS   := $(addprefix build/win/,$(WIN_TEST_X86SRC:.s=.o)) \
                   $(WIN_NAT_OBJS) $(WIN_PLUGIN_OBJS)
WIN_TESTBINS    := $(addprefix build/win/tests/,$(TESTS))

# ---------------------------------------------------------------- rules
.PHONY: all release test check clean arm64-translate darwin-arm64 darwin-arm64-smoke darwin-arm64-test darwin-arm64-discover-live darwin-arm64-cross linux-aarch64 test-aarch64 linux-aarch64-discover-live test-qemu windows-x86_64 test-wine

all: $(BIN)

release:
	rm -f $(BIN)
	$(MAKE) RELEASE=1 all

# A Mach-O target must never be produced by the GNU toolchain: `make
# TARGET=darwin-arm64` builds through the mac recipe below (finding F1), and any
# other darwin-* target fails fast instead of emitting a mislabeled Linux ELF.
ifneq ($(filter darwin-%,$(TARGET)),)
ifneq ($(TARGET),darwin-arm64)
$(error TARGET=$(TARGET) is a Mach-O target with no recipe here; only \
        darwin-arm64 is implemented — build it on a macOS host or with \
        ARM64_CC/ARM64_LD naming a cross toolchain)
endif
else ifeq ($(TARGET),linux-aarch64)
# `all` resolves through the explicit $(A64_BIN) rule in the linux-aarch64
# section: TARGET=linux-aarch64 must never fall into the native GNU recipe
# below and silently emit a mislabeled x86-64 ELF.
else ifeq ($(TARGET),windows-x86_64)
# `all` resolves through $(WIN_BIN) in the windows-x86_64 section; the PE
# link recipe (mingw gcc driver, import libraries) replaces the ELF recipe.
else
$(BIN): $(OBJS)
	$(LD) $(LDFLAGS) -o $@ $^
endif

build/obj/%.o: %.s $(HDRS)
	@mkdir -p $(@D)
	$(AS) $(ASFLAGS) -o $@ $<

build/obj/%.o: %.c third_party/mbedtls_sources.txt $(HDRS)
	@mkdir -p $(@D)
	$(CC) $(MBEDTLS_CFLAGS) -c $< -o $@

# Syntax gate: translate + assemble every portable source and the mock backend,
# assemble the native Darwin sources, and compile the arm64 C objects (mbedTLS,
# the glue, the TLS shim and the plugins) — the C half was previously untested.
# The mac app build reuses those C objects; only the assembly lists differ.
arm64-translate: $(ARM64_OBJS) $(MAC_C_OBJS) $(MAC_PLUGIN_OBJS)

$(ARM64_ASM): build/arm64/%.s: %.s $(HDRS) $(ABI_C_DEFS) $(ABI_C_UNDEF)
	@mkdir -p $(@D)
	$(PYTHON) tools/arm64.py $(ABI_FLAGS) $(ARM64_INC) $< $@

$(addprefix build/arm64/,$(ARM64_X86SRC:.s=.o) $(ARM64_MOCKSRC:.s=.o)): build/arm64/%.o: build/arm64/%.s
	@mkdir -p $(@D)
	$(ARM64_CC) $(ARM64_ASFLAGS) $< -o $@

$(addprefix build/arm64/,$(MAC_NATSRC:.s=.o)): build/arm64/%.o: %.s $(HDRS)
	@mkdir -p $(@D)
	$(ARM64_CC) $(ARM64_ASFLAGS) $< -o $@

# --- Mach-O objects under build/mac/ -----------------------------------------
$(MAC_TR_ASM) $(SMOKE_ASM): build/mac/%.s: %.s $(HDRS) $(ABI_C_DEFS) $(ABI_C_UNDEF)
	@mkdir -p $(@D)
	$(PYTHON) tools/arm64.py $(ABI_FLAGS) $(ARM64_INC) $< $@

$(MAC_TR_OBJS) $(SMOKE_OBJ): build/mac/%.o: build/mac/%.s
	@mkdir -p $(@D)
	$(ARM64_CC) $(ARM64_ASFLAGS) $< -o $@

# The mock backend is translated for the unit tests only; the app links the real
# net instead.
$(addprefix build/mac/,$(ARM64_MOCKSRC:.s=.s)): build/mac/%.s: %.s $(HDRS) $(ABI_C_DEFS) $(ABI_C_UNDEF)
	@mkdir -p $(@D)
	$(PYTHON) tools/arm64.py $(ABI_FLAGS) $(ARM64_INC) $< $@

$(addprefix build/mac/,$(ARM64_MOCKSRC:.s=.o)): build/mac/%.o: build/mac/%.s
	@mkdir -p $(@D)
	$(ARM64_CC) $(ARM64_ASFLAGS) $< -o $@

# Native AArch64 sources keep their basename under build/mac/native/.
define MAC_NATIVE_RULE
build/mac/native/$(notdir $(basename $(1))).o: $(1) $$(HDRS)
	@mkdir -p $$(@D)
	$$(ARM64_CC) $$(ARM64_ASFLAGS) $$< -o $$@
endef
$(foreach s,$(MAC_NATSRC),$(eval $(call MAC_NATIVE_RULE,$(s))))

$(MAC_C_OBJS): build/mac/c/%.o: %.c third_party/mbedtls_sources.txt $(HDRS) $(MAC_SHIM_HDR)
	@mkdir -p $(@D)
	$(ARM64_CC) $(ARM64_CFLAGS) $(MAC_C_SHIM) -c $< -o $@

ifeq ($(HOST_DARWIN),)
# Empty shadow of glibc's x86-64 stubs header; see the shim comment above.
$(MAC_SHIM_HDR):
	@mkdir -p $(@D)
	: > $@
endif

# The mac app binary and the smoke binary share one guarded link step, as
# described next to MAC_LINK_OK.  `darwin-arm64` is the explicit alias for
# TARGET=darwin-arm64; the default `all` resolves to the same target.
darwin-arm64: $(MAC_BIN)

$(MAC_BIN): $(MAC_OBJS)
	@if [ -n "$(MAC_LINK_OK)" ]; then \
		echo "  MAC-LINK $@"; \
		$(ARM64_LD) $(ARM64_LDFLAGS) -o $@ $(MAC_OBJS); \
	else \
		echo "opcode: not linking $@: no Mach-O linker on $$(uname -s)"; \
		echo "opcode:   $(words $(MAC_OBJS)) arm64 objects are ready; run on macOS or set ARM64_LD=... MAC_LINK=1"; \
	fi

darwin-arm64-smoke: $(SMOKE_BIN)

$(SMOKE_BIN): $(SMOKE_OBJS)
	@if [ -n "$(MAC_LINK_OK)" ]; then \
		echo "  MAC-LINK $@"; \
		$(ARM64_LD) $(ARM64_LDFLAGS) -o $@ $(SMOKE_OBJS); \
	else \
		echo "opcode: not linking $@: no Mach-O linker on $$(uname -s)"; \
		echo "opcode:   $(words $(SMOKE_OBJS)) arm64 objects are ready; run on macOS or set ARM64_LD=... MAC_LINK=1"; \
	fi

# Cross/smoke entry point for a non-Darwin host with a Mach-O driver named in
# ARM64_LD: both the app and the smoke binary.  Static validation lives in
# tools/check-macho.sh; the flake's darwin-arm64-cross output runs it as a check.
darwin-arm64-cross: $(MAC_BIN) $(SMOKE_BIN)

# --- Mach-O unit-test binaries under build/mac/tests/ ------------------------
# Each tests/<name>.s is translated to AArch64, assembled, and linked against
# the mac test object set above.  On a macOS host clang links them; a non-Darwin
# host needs a Mach-O driver in ARM64_LD (the flake's zig cross build does this).
build/mac/tests/%.s: tests/%.s $(HDRS) $(ABI_C_DEFS) $(ABI_C_UNDEF)
	@mkdir -p $(@D)
	$(PYTHON) tools/arm64.py $(ABI_FLAGS) $(ARM64_INC) $< $@

build/mac/tests/%.o: build/mac/tests/%.s
	@mkdir -p $(@D)
	$(ARM64_CC) $(ARM64_ASFLAGS) $< -o $@

$(MAC_TESTBINS): build/mac/tests/%: build/mac/tests/%.o $(MAC_TEST_OBJS)
	@if [ -n "$(MAC_LINK_OK)" ]; then \
		echo "  MAC-LINK $@"; \
		$(ARM64_LD) $(ARM64_LDFLAGS) -o $@ $< $(MAC_TEST_OBJS); \
	else \
		echo "opcode: not linking $@: no Mach-O linker on $$(uname -s)"; \
		echo "opcode:   $(words $(MAC_TEST_OBJS)) arm64 objects are ready; run on macOS or set ARM64_LD=... MAC_LINK=1"; \
	fi

darwin-arm64-test: $(MAC_TESTBINS)

# tests/ollama.sh's live discover helper.  The explicit .s rule overrides the
# `build/mac/tests/%.s: tests/%.s` pattern so this one source gets -D OPCODE_LIVE.
darwin-arm64-discover-live: $(MAC_LIVE_BIN)

$(MAC_LIVE_ASM): tests/discover_test.s $(HDRS) $(ABI_C_DEFS) $(ABI_C_UNDEF)
	@mkdir -p $(@D)
	$(PYTHON) tools/arm64.py $(ABI_FLAGS) $(ARM64_INC) -D OPCODE_LIVE $< $@

$(MAC_LIVE_BIN): $(MAC_LIVE_OBJ) $(MAC_LIVE_OBJS)
	@if [ -n "$(MAC_LINK_OK)" ]; then \
		echo "  MAC-LINK $@"; \
		$(ARM64_LD) $(ARM64_LDFLAGS) -o $@ $(MAC_LIVE_OBJ) $(MAC_LIVE_OBJS); \
	else \
		echo "opcode: not linking $@: no Mach-O linker on $$(uname -s)"; \
		echo "opcode:   $(words $(MAC_LIVE_OBJS)) arm64 objects are ready; run on macOS or set ARM64_LD=... MAC_LINK=1"; \
	fi

# --- linux-aarch64 objects under build/a64/ -----------------------------------
# The translated outputs depend on the translator itself: a translator fix
# must force a re-translation, not leave stale build/a64 sources behind.
$(A64_TR_ASM): build/a64/%.s: %.s $(HDRS) tools/arm64.py $(ABI_C_DEFS) $(ABI_C_UNDEF)
	@mkdir -p $(@D)
	$(PYTHON) tools/arm64.py --os linux $(ABI_FLAGS) $(A64_INC) $< $@

$(A64_TR_OBJS): build/a64/%.o: build/a64/%.s
	@mkdir -p $(@D)
	$(A64_AS) $(A64_ASFLAGS) -c $< -o $@

# Native AArch64 sources keep their basename under build/a64/native/.
define A64_NATIVE_RULE
build/a64/native/$(notdir $(basename $(1))).o: $(1) $$(HDRS)
	@mkdir -p $$(@D)
	$$(A64_AS) $$(A64_ASFLAGS) -c $$< -o $$@
endef
$(foreach s,$(A64_NATSRC),$(eval $(call A64_NATIVE_RULE,$(s))))

$(A64_C_OBJS): build/a64/c/%.o: %.c third_party/mbedtls_sources.txt $(HDRS)
	@mkdir -p $(@D)
	NIX_HARDENING_ENABLE= $(A64_CC) $(A64_CFLAGS) -c $< -o $@

# The app binary.  `linux-aarch64` is the explicit alias for
# TARGET=linux-aarch64; the default `all` resolves to the same target.
linux-aarch64: $(A64_BIN)

$(A64_BIN): $(A64_OBJS)
	@echo "  A64-LINK $@"
	$(A64_LD) $(A64_LDFLAGS) -o $@ $(A64_OBJS)

# The mock backend is translated for the unit tests only; the app links the real
# net instead (same shape as the Darwin section's mock rules).
$(addprefix build/a64/,$(A64_MOCKSRC:.s=.s)): build/a64/%.s: %.s $(HDRS) tools/arm64.py $(ABI_C_DEFS) $(ABI_C_UNDEF)
	@mkdir -p $(@D)
	$(PYTHON) tools/arm64.py --os linux $(ABI_FLAGS) $(A64_INC) $< $@

$(addprefix build/a64/,$(A64_MOCKSRC:.s=.o)): build/a64/%.o: build/a64/%.s
	@mkdir -p $(@D)
	$(A64_AS) $(A64_ASFLAGS) -c $< -o $@

# --- linux-aarch64 unit-test binaries under build/a64/tests/ -----------------
# Each tests/<name>.s is translated to AArch64, assembled, and linked against
# the aarch64 test object set above.
build/a64/tests/%.s: tests/%.s $(HDRS) tools/arm64.py $(ABI_C_DEFS) $(ABI_C_UNDEF)
	@mkdir -p $(@D)
	$(PYTHON) tools/arm64.py --os linux $(ABI_FLAGS) $(A64_INC) $< $@

build/a64/tests/%.o: build/a64/tests/%.s
	@mkdir -p $(@D)
	$(A64_AS) $(A64_ASFLAGS) -c $< -o $@

$(A64_TESTBINS): build/a64/tests/%: build/a64/tests/%.o $(A64_TEST_OBJS)
	@echo "  A64-TEST-LINK $@"
	$(A64_LD) $(A64_LDFLAGS) -o $@ $< $(A64_TEST_OBJS)

test-aarch64: $(A64_TESTBINS)

# tests/ollama.sh's live discover helper.  The explicit .s rule overrides the
# `build/a64/tests/%.s: tests/%.s` pattern so this one source gets -D OPCODE_LIVE.
linux-aarch64-discover-live: $(A64_LIVE_BIN)

$(A64_LIVE_ASM): tests/discover_test.s $(HDRS) tools/arm64.py $(ABI_C_DEFS) $(ABI_C_UNDEF)
	@mkdir -p $(@D)
	$(PYTHON) tools/arm64.py --os linux $(ABI_FLAGS) $(A64_INC) -D OPCODE_LIVE $< $@

$(A64_LIVE_BIN): $(A64_LIVE_OBJ) $(A64_LIVE_OBJS)
	@echo "  A64-LIVE-LINK $@"
	$(A64_LD) $(A64_LDFLAGS) -o $@ $(A64_LIVE_OBJ) $(A64_LIVE_OBJS)

# --- windows-x86_64 objects under build/win/ ---------------------------------
windows-x86_64: $(WIN_BIN)

test-wine:
	@if command -v x86_64-w64-mingw32-as > /dev/null 2>&1 \
	    && command -v x86_64-w64-mingw32-gcc > /dev/null 2>&1 \
	    && command -v wine > /dev/null 2>&1; then \
		tests/run-wine.sh; \
	elif command -v nix > /dev/null 2>&1 && [ -f flake.nix ]; then \
		echo "opcode: test-wine: entering the flake devShell (wine + mingw toolchain)"; \
		nix develop --command $(MAKE) test-wine; \
	else \
		echo "opcode: test-wine needs wine and the x86_64-w64-mingw32 toolchain"; \
		echo "opcode:   (run inside \`nix develop\`, or install wine + pkgsCross.mingwW64)"; \
		exit 1; \
	fi

$(WIN_BIN): $(WIN_OBJS)
	@echo "  PE-LINK $@"
	$(WIN_CC) $(WIN_LDFLAGS) -o $@ $(WIN_OBJS) $(WIN_LIBS)

build/win/%.o: %.s $(HDRS)
	@mkdir -p $(@D)
	$(WIN_AS) $(WIN_ASFLAGS) -o $@ $<

build/win/native/%.o: src/plat/win/%.s $(HDRS)
	@mkdir -p $(@D)
	$(WIN_AS) $(WIN_ASFLAGS) -o $@ $<

build/win/c/%.o: %.c third_party/mbedtls_sources.txt $(HDRS)
	@mkdir -p $(@D)
	$(WIN_CC) $(WIN_CFLAGS) -c $< -o $@

$(WIN_TESTBINS): build/win/tests/%: tests/%.s $(WIN_TEST_OBJS) $(HDRS)
	@mkdir -p $(@D)
	$(WIN_AS) $(WIN_ASFLAGS) -o build/win/tests/$*.o $<
	$(WIN_CC) $(WIN_LDFLAGS) -o $@ build/win/tests/$*.o $(WIN_TEST_OBJS) $(WIN_LIBS)

build/assets.s: tools/gen-assets.sh VERSION third_party/cacert.pem
	@mkdir -p $(@D)
	tools/gen-assets.sh > $@

build/catalog.s: tools/gen-catalog.py runtime/catalog.json
	@mkdir -p $(@D)
	$(PYTHON) tools/gen-catalog.py > $@

build/plugins.s: tools/gen-plugins.py plugins/manifest.json
	@mkdir -p $(@D)
	$(PYTHON) tools/gen-plugins.py > $@

# The macOS plugin table: same plugins, Mach-O symbol references (leading
# underscore on the init names).  Kept separate so the Linux table is untouched.
build/plugins-mac.s: tools/gen-plugins.py plugins/manifest.json
	@mkdir -p $(@D)
	$(PYTHON) tools/gen-plugins.py --macho > $@

# Tests link the mock net backend, never src/net/linux or the TLS objects.
$(TESTBINS): build/%: tests/%.s $(CORE_OBJS) $(MOCK_OBJS) $(PLUGIN_OBJS) $(GEN_OBJS) $(HDRS)
	@mkdir -p build/obj/tests
	$(AS) $(ASFLAGS) -o build/obj/tests/$*.o $<
	$(LD) $(LDFLAGS) -o $@ build/obj/tests/$*.o \
	    $(CORE_OBJS) $(MOCK_OBJS) $(PLUGIN_OBJS) $(GEN_OBJS)

ifeq ($(TARGET),darwin-arm64)
test: $(MAC_TESTBINS)
else ifeq ($(TARGET),linux-aarch64)
test: $(A64_TESTBINS)
else ifeq ($(TARGET),windows-x86_64)
test: $(WIN_TESTBINS)
else
test: $(TESTBINS)
endif

check: test
	tests/run.sh

# Full suite against the static aarch64 ELF under qemu-user (tests/run.sh
# with OPCODE_TARGET=linux-aarch64).  Needs qemu-aarch64 plus the
# aarch64-unknown-linux-gnu toolchain; when only nix is present (this flake's
# devShell provides both), re-exec through it once.
test-qemu:
	@if command -v qemu-aarch64 > /dev/null 2>&1 \
	    && command -v aarch64-unknown-linux-gnu-as > /dev/null 2>&1; then \
		OPCODE_TARGET=linux-aarch64 tests/run.sh; \
	elif command -v nix > /dev/null 2>&1 && [ -f flake.nix ]; then \
		echo "opcode: test-qemu: entering the flake devShell (qemu-aarch64 + cross toolchain)"; \
		nix develop --command $(MAKE) test-qemu; \
	else \
		echo "opcode: test-qemu needs qemu-aarch64 and aarch64-unknown-linux-gnu-{as,ld,cc}"; \
		echo "opcode:   (run inside \`nix develop\`, or install the cross toolchain + qemu-user)"; \
		exit 1; \
	fi

clean:
	rm -rf build
