# Base library API contract (frozen for M0)

Every function: args in `rdi, rsi, rdx, rcx, r8, r9`, return in `rax` (second value
in `rdx`), callee-saved `rbx,rbp,r12-r15`. All sources include `opcode.inc` first
(Intel syntax). Non-leaf functions use `PROLOGUE`/`EPILOGUE`; leaf functions must
keep `rsp` 16-byte aligned before any `call`.

## src/base/str.s

```
memcpy(dst, src, n) -> dst
memmove(dst, src, n) -> dst
memset(dst, byte, n) -> dst
memset32(dst, u32, count) -> dst
memeq(a, b, n) -> 1 | 0
strlen(s) -> n
str_eq(a, alen, b, blen) -> 1 | 0
str_eq_cstr(a, alen, cstr) -> 1 | 0            (exported: other seats may drop local cstr_eq copies)
str_starts(a, alen, prefix, plen) -> 1 | 0
str_find(hay, hlen, needle, nlen) -> index | -1        (empty needle -> 0)
parse_u64(ptr, len) -> rax value, rdx digits consumed  (rdx=0 if none)
                                                       (overflow -> rax=0, rdx=0)
parse_hex(ptr, len) -> rax value, rdx digits consumed
fmt_u64(buf, value) -> rax length                       (no NUL terminator)
utf8_encode(codepoint, buf) -> rax length
```

## src/base/uni.s

The single Unicode width table shared by the composer, transcript and grid
(`view_wcwidth` is a tail call into it); strict UTF-8 decoding lives here too.

```
utf8_decode(ptr, len) -> rax cp, rdx bytes consumed      (strict; invalid -> U+FFFD, 1 byte)
utf8_wcwidth(cp) -> 0 combining/zero-width/format, 2 wide/fullwidth/emoji, else 1
utf8_is_combining(cp) -> 1 | 0                           (genuine combining mark only)
```

Zero width: the combining blocks, the Cf format set (including soft hyphen
U+00AD and Mongolian vowel separator U+180E), and C0/DEL/C1 controls.  Width 2:
East-Asian Wide/Fullwidth plus the emoji ranges 1F000-1F2FF,
1F300-1F64F, 1F680-1F6FF, 1F7E0-1F7EB, 1F7F0, 1F900-1F9FF and 1FA70-1FAFF.
`utf8_is_combining` excludes the Cf format characters, so the grid attaches
only genuine marks; callers store a control as a space and drop the rest.

## src/base/log.s

```
LOG_ERROR 0, LOG_INFO 1, LOG_DEBUG 2        # level scale
write_all(fd, ptr, len) -> 0 | -errno   (retries EINTR/EAGAIN)
log_write(ptr, len) -> 0 | -errno       (fd 2)
log_cstr(cstr)
log_u64(value)
log_nl()
log_set_level(level)                   # set the log_debug_* threshold
g_log_level: .long                     # current threshold (LOG_ERROR by default)
log_debug_write(ptr, len) -> 0 | -errno # log_write only when g_log_level >= LOG_DEBUG
log_debug_cstr(cstr)
log_debug_u64(value)
log_debug_nl()
die(cstr)                               (stderr + os_exit(1); never returns)
```

The `log_debug_*` functions are no-ops below `LOG_DEBUG`, so the hot paths pay
one compare; `agent_init` raises the gate to `LOG_DEBUG` when `--verbose` set
`g_agent_verbose` (`src/core/API.md`).

## src/base/mem.s

```
mem_alloc(size) -> ptr          zeroed; dies on OOM
mem_alloc_try(size) -> ptr | 0
mem_free(ptr)                   NULL-safe
mem_capacity(ptr) -> usable bytes
mem_realloc(ptr, size) -> ptr   contents preserved up to min(old,new)
mem_dup(ptr, len) -> cstr       NUL-terminated copy (len == SIZE_MAX rejected)
sb_reserve(sb, extra) -> ptr    room for extra bytes; len NOT bumped
sb_push(sb, ptr, len)
sb_push_cstr(sb, cstr)
sb_push_byte(sb, byte)
sb_push_u64(sb, value)
sb_push_utf8(sb, codepoint)
sb_clear(sb)
sb_free(sb)
vec_push(vec, item_size) -> ptr to new zeroed slot
vec_free(vec)
```

Global: `g_mem_live` (quad, live block count).

`sb_push` is alias-safe: `ptr` may point into the SB's own buffer (including the
byte just past `len`). The source offset is captured before `sb_reserve` may
reallocate the buffer and the copy is then done with `memmove` semantics, so a
self-append grows correctly. `sb_push_cstr` inherits this rule.

## src/base/json.s

Parser accepts JSONC: `//` and `/* */` comments, trailing commas in arrays and
objects; rejects missing commas. Strings are decoded and NUL-terminated in the
arena. Numbers keep their raw text (`JV_n` = byte length).

```
json_parse(ptr, len) -> JV* | 0     (resets the arena first)
json_reset()                        frees all arena blocks but the newest
json_get(obj, key cstr) -> JV* | 0
json_get_cstr(obj, key cstr) -> cstr | 0
json_get_u64(obj, key cstr, dflt) -> u64  (dflt if missing, non-number or overflow)
json_str(jv) -> rax ptr, rdx len    (0,0 unless JT_STR)
json_str_cstr(jv) -> cstr | 0
json_is(jv, cstr) -> 1 | 0
json_at(arr, i) -> JV* | 0
json_len(jv) -> count               (0 unless JT_ARR; JT_OBJ -> pairs)
json_type(jv) -> JT_*               (-1 for NULL pointer)
```

JV layout and JT_* constants: `opcode.inc`.

## src/base/start.s

```
_start:
    mov rdi, rsp
    and rsp, -16
    call os_init
    call opcode_main
    mov edi, eax
    jmp os_exit
```

## Platform (src/plat/linux/sys.s) — see src/plat/plat.inc

Globals: `g_argc`, `g_argv`, `g_envp` (populated by `os_init`).
