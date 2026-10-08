# Third-party notices

Opcode is MIT licensed (see `LICENSE`). It includes or adapts the following
third-party components.

## mbedTLS 3.6.2 — https://github.com/Mbed-TLS/mbedtls

Copyright (c) The Mbed TLS Contributors.
Licensed under the Apache License, Version 2.0 (or GPL-2.0-or-later).

Vendored as an unmodified upstream subset under `third_party/mbedtls/`
(`include/`, `library/` and `LICENSE` from the `v3.6.2` tag). Opcode builds it
from source as the Linux TLS backend (`third_party/mbedtls_glue.c`,
`third_party/mbedtls_opcode_config.h`, `src/net/linux/tls_shim.c`), so there is
no runtime dependency and no `dlopen`. Opcode's own configuration and glue files
are original work under this repository's MIT license.

## Mozilla CA bundle — https://curl.se/ca/cacert.pem

`third_party/cacert.pem` is the Mozilla CA certificate bundle from
<https://curl.se/ca/cacert.pem>, distributed under the Mozilla Public License,
v. 2.0 (MPL-2.0): <https://mozilla.org/MPL/2.0/>. It is embedded byte-for-byte
into the Opcode binary by `tools/gen-assets.sh` and parsed at run time by the
vendored mbedTLS X.509 code.

## rhun — https://github.com/vshvedov/rhun

Copyright (c) 2026 Vlad Shvedov, MIT License.

`src/base/mem.s`, `src/base/str.s`, `src/base/json.s` and
`src/plat/linux/sys.s` were originally adapted from rhun's `mem.s`, `lib.s`,
`json.s` and platform code; the allocator design, the `SB`/`VEC` containers, the
JSON arena and parser structure, and the negative-errno syscall convention
follow that project. These files keep a minimal "adapted from rhun (MIT)"
header.

## rhun arm64 translator — https://github.com/vshvedov/rhun

Copyright (c) 2026 Vlad Shvedov, MIT License.

`tools/arm64.py` is vendored verbatim from rhun's `tools/arm64.py` (its MIT
license is embedded in the file header, along with the list of Opcode's local
modifications). It is a host-side build tool that translates the x86-64
sources into AArch64 for Apple silicon; it is never compiled into the binary
and is not used by the Linux build. Opcode's modifications: `.extern` dropped and
`.weak` lowered to Mach-O `.weak_definition`/`.weak_reference`; bare `NAME = value`
lowered to `.set`; parse-time values for `.equ`/`.set` and data directives;
label differences folded to numbers with a guard against arm64-only `.quad`
alignment padding; `.align`/`.balign` through one layout/emit helper;
`.rept`/`.endr` expanded at parse time; `leave` lowered to `mov rsp, rbp` +
`pop rbp`.

## rhun macOS/aarch64 platform layer — https://github.com/vshvedov/rhun

Copyright (c) 2026 Vlad Shvedov, MIT License.

The native AArch64 Darwin layer is adapted from rhun's macOS port:

| Opcode file | rhun source |
|---|---|
| `src/plat/mac/mac.inc` | `src/mac/mac.inc` (macros and the native↔translated register/stack contract) |
| `src/plat/mac/rt.s` | `src/mac/rt.s` (entry and translator runtime helpers) |
| `src/plat/mac/sys.s` | `src/mac/linux.s` (`x_syscall`, the Linux-syscall-number table over libSystem, struct/flag/errno/termios conversions) |
| `src/net/mac/net.s` | `src/mac/linux.s`, socket stubs split out into the network layer |

Macro names, structure and the syscall-table design follow rhun so a future
re-vendor stays a clean diff. Opcode's local modifications, listed in each file's
header:

- socket stubs moved to `src/net/mac/net.s` (network-layer concerns);
- added `sys_mkdirat` (258), `sys_unlinkat` (263), `sys_dup` (32),
  `sys_socketpair` (53) and `sys_getrandom` (318);
- `sys_rt_sigaction` installs a native trampoline so a *translated* handler runs
  (instead of rhun's `SIG_DFL`/`SIG_IGN`-only subset);
- pty-path and pty-ioctl translation dropped (opcode opens no pseudo-terminals);
- rhun's AppKit hooks `g_xsp`/`g_poll_hook` dropped (opcode has no AppKit);
- `MSG_NOSIGNAL`, `SOL_SOCKET` and `SO_ERROR` translations added to the net
  layer.

`src/plat/mac/smoke.s` is original work under this repository's MIT license.
These files are compiled into the macOS binary, which is built natively by the
`macos-14` CI job (defined, not yet run on Apple hardware; see
`.agents/docs/ports.md` §2).

## pi — https://github.com/earendil-works/pi

MIT License.

`runtime/catalog.json` carries MIT-licensed model catalog data from the pi
project: factual model metadata only (ids, providers, base URLs, context
windows, limits and capability flags). Opcode maintains the file as its own data
and ships it in this repository; no pi code is vendored.

Opcode's UX and extensibility designs (context files, skills, prompt templates,
MCP, machine modes and the session model) are inspired by pi. That is design
inspiration only — it is not a code adaptation and no pi source is vendored or
linked into the binary.
