# wire: HTTP/SSE/JSON API contract (frozen for M1)

## src/wire/url.s

The `Url` layout below is single-sourced in `src/wire/url.inc` (included after
`opcode.inc`); `url.s`, `http_client.s`, `app/fetch.s`, `app/update.s` and the
core URL consumers all include it, so there is one `U_*` layout in the tree.

```
STRUCT
F U_scheme, 8      # ptr into the url string
F U_host, 8
F U_path, 8        # includes the leading '/', default "/"
F U_query, 8       # after '?' (may be 0)
F U_scheme_len, 4
F U_host_len, 4
F U_path_len, 4
F U_query_len, 4
F U_port, 2
F U_flags, 2       # UF_TLS = 1
ENDSTRUCT U_SIZE

url_parse(url cstr, out *Url) -> 0 | -EINVAL
url_copy_host(url, buf, cap) -> len | -ERANGE    (NUL-terminated; for TLS SNI)
url_authority(url, buf, cap) -> len | -ERANGE    ("host[:port]"; Host header)
```

- Accepts `http://host[:port][/path][?query]` and `https://…`. Default ports 80/443.
- Rejects C0 controls and DEL (`< 0x20` or `0x7f`) in the scheme, host, path and
  query, so a CR/LF cannot be smuggled through a URL into a request line or header.
- Pointers reference the input string (caller keeps it alive; input is not modified).
- Missing path -> `"/"` length 1 pointing at a static slash or at a NUL in the input.

## src/wire/http.s — request builder

All builders append to an SB (first arg). They never reset the SB.

```
http_req_begin(sb, method cstr, host ptr, host_len, path ptr, path_len) -> 0
http_req_header(sb, name cstr, value ptr, value_len) -> 0
http_req_header_cstr(sb, name cstr, value cstr) -> 0
http_req_body(sb, ptr, len) -> 0     # emits "Content-Length: n\r\n\r\n" then the body
```
`http_req_begin` emits `METHOD path HTTP/1.1\r\nHost: host\r\n`. The caller adds
headers and either ends with `http_req_end(sb)` (no body) or calls `http_req_body`.
`http_req_header` rejects a value containing CR or LF (`-EINVAL`, nothing
appended), because either would terminate the line and reparse the remainder as
a new header.

```
http_req_end(sb) -> 0                # emits the blank line, no body
```

## src/wire/http.s — response parser

```
STRUCT (fields are implementation-private; do not index from outside)
http_resp_init(r, on_body, ctx)      # on_body(ctx, ptr, len) called for each body chunk
http_resp_feed(r, ptr, len) -> consumed bytes   # 0 when more input is needed
http_resp_status(r) -> int          # 0 until the status line is parsed
http_resp_header(r, name cstr) -> rax ptr, rdx len | 0,0 if absent (case-insensitive)
http_resp_header_count(r) -> n
http_resp_header_at(r, i) -> rax name ptr, rdx name len, rcx value ptr, r8 value len
http_resp_done(r) -> 1|0            # body finished (content-length, last chunk, or eof)
http_resp_eof(r)                    # peer closed: completes an EOF-delimited body
http_resp_close(r) -> 1|0           # Connection: close, or HTTP/1.0 without keep-alive
http_resp_chunked(r) -> 1|0
http_resp_error(r) -> 0 | cstr message
```

- Supports `Content-Length` and `Transfer-Encoding: chunked`; 1xx/204/304 are
  completed with no body automatically, and a caller that knows the method
  (e.g. HEAD) calls `http_resp_no_body(r)`.
- Hardening: a duplicate `Content-Length` is rejected (`http_resp_error`), not
  last-wins; `Transfer-Encoding` and `Connection` are matched as
  comma-separated tokens (after optional SP/HTAB), so `xchunked` and `close-me`
  do not match; `Content-Length` is parsed with a bounded decimal parser
  (overflow is an error rather than a silent wrap).
- Header limits: 8 KB per line, 64 headers. `http_resp_header*` returns
  pointers into the parser's internal growable buffer (recomputed from the
  current buffer each call), valid until `http_resp_close`/`http_resp_free`.
- `http_resp_feed` must handle a header block split across arbitrary byte
  boundaries. Excess bytes after the body are not consumed (returns only what
  the parser used).

## src/wire/http_client.s — shared HTTP(S) transport

One small client for the request paths that used to repeat connect/DNS/TLS/
send/recv. Request building stays in `http.s`, response parsing in the
`http_resp_*` parser, so SSE and recorded bodies stream through callbacks and
are never copied into the client. The OAuth loopback accept server and the
provider SSE adapters are not part of it.

An `HC` (layout in `http_client.inc`) is caller-owned storage holding the
parsed Url, the host/authority copies, the socket/TLS handles and the receive
buffer. Errors are negative errno; `hc_connect` never closes on failure and
leaves `HC_stage` at the furthest step so the caller can classify the error.

```
hc_init(hc)
hc_setup(hc, url cstr, flags) -> 0 | -EINVAL     # HC_F_INSECURE = 1
hc_set_recbuf(hc, ptr, cap)
hc_connect(hc, url, flags, dns_ms, wait_ns, absolute) -> 0 | -errno
hc_connect_started(hc, dns_ms, wait_ns, absolute) -> 0 | -errno
hc_close(hc)                                     # idempotent
hc_send_all(fd, conn, ptr, len, deadline_ns) -> 0 | -errno
hc_recv_loop(hc, resp, flags, on_data, ctx, deadline_ns) -> 0 | -errno
```

`absolute` selects the timeout model: 0 = `now + wait_ns` for each poll
(fetch/update/discover/agent-blocking), 1 = one absolute deadline stored in
`HC_deadline` (OAuth exchange). `hc_recv_loop` flags are the historical error
policies (`HCR_CHECK_FEED`, `HCR_CHECK_DONE`, `HCR_CHECK_EOF`, `HCR_PROGRESS`);
`on_data(ctx, ptr, len)` sees each raw chunk before the parser does
(record/dump hooks). Returns `-EINVAL` for parser/body errors; call
`http_resp_error` for the message.

Non-blocking steps for the agent state machine: `hc_resolve_host(host,
out_ip4, dns_ms)`, `hc_resolve(hc, dns_ms)`, `hc_socket_start(hc, connect_ms)`,
`hc_socket_finish(hc)`, `hc_tls_start(hc)`, `hc_handshake(hc, wait_ns)`,
`hc_wait_io(fd, events, deadline_ns)`, `hc_tls_events(conn)`, `hc_send_some`,
`hc_recv_some`, `hc_ip4_parse`.

## src/wire/sse.s

```
sse_init(s, on_event, ctx)     # on_event(ctx, event ptr,len, data ptr,len)
sse_feed(s, ptr, len)
sse_reset(s)
sse_last_id(s) -> rax ptr, rdx len    # most recent "id:" field (0,0 if none)
sse_error(s) -> 0 | cstr              # e.g. "event too large"
```

- Line-based: `event:`, `data:` (multiple lines joined with `\n`), `id:`, `:`
  comments, blank line dispatches. Default event name `"message"`.
- Limits: 1 MB event data, 512 KB line; on overflow set error and skip to the
  next blank line. Handles LF, CRLF, and CR line endings.

## src/wire/jsonw.s — streaming JSON writer

Writes into an SB (first arg everywhere). Escapes strings per RFC 8259
(control chars, `"`, `\`; no HTML escaping). Never emits whitespace.

```
jsonw_obj(sb) jsonw_obj_end(sb) jsonw_arr(sb) jsonw_arr_end(sb)
jsonw_key(sb, cstr) jsonw_key_n(sb, ptr, len)
jsonw_str(sb, ptr, len) jsonw_str_cstr(sb, cstr)
jsonw_i64(sb, value) jsonw_u64(sb, value)
jsonw_bool(sb, b) jsonw_null(sb)
jsonw_raw(sb, ptr, len)        # pre-encoded value (number/literal)
```

## Replay file format (mock backend, `src/net/mock.s`)

```
magic:  "FWIR1\n" (6 bytes)
records, repeated until EOF:
    u8  dir          0 = client -> server (captured), 1 = server -> client (replayed)
    u32 len          little-endian
    bytes payload
```
`net_recv` returns dir=1 payloads in order, then EOF (0). `net_send` appends to
a capture buffer; `mock_sent() -> ptr, len` exposes it. DNS returns 127.0.0.1 for
any name unless the file contains an `ip` record (reserved for later). TLS is a
plaintext passthrough: replay files store the decrypted HTTP bytes.
