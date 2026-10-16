# TODO — hardening

Status: done (folded into the base history)
Provenance: `1c88f09` (clean-lineage draft) → landed in `7fc7363`..`43274c1`
Proof of record: `eb4602e` (v0.3.0, user-approved)

Goal: resolve every confirmed defect and the invariant drift from the fresh
review; `make check` green; all cross-targets still assemble.

## Done

Correctness / security

- [x] inline TUI cell attrs → visible caret; resize clamp; history path NUL;
      strict size parser — `7786d39`, `af7cffd`
- [x] project `.opcode/mcp.jsonc` trust-gated — `af7cffd`
- [x] `diff_unified` frees buffers on truncation — `af7cffd`
- [x] markdown trailing-block rows VEC freed per delta — `af7cffd`
- [x] `edit`/`write` atomic temp name; shared `tool_write_atomic` — `45f8c08`,
      `af7cffd`
- [x] failed `watch_add` kills/reaps the tool child — `af7cffd`
- [x] Anthropic validates streamed tool args before re-emitting — `af7cffd`
- [x] `os_setsockopt`; no raw `SYS 54` in portable code — `c888564`, `af7cffd`
- [x] OAuth token body capped + parser errors; owned `auth_key` contract —
      `af7cffd`
- [x] reject duplicate `Content-Length`; token-match TE/Connection; reject CR/LF
      in URL/headers — `af7cffd`
- [x] compaction durable/persisted, frees removed leaves; session
      `schema_version` numeric — `af7cffd`
- [x] SIGINT/SIGTERM cleanup aborts and reaps children — `7786d39`, `af7cffd`
- [x] Windows socket/pipe/getrandom/poll/frame; macOS `stat`; aarch64 `sa_flags`;
      Linux `os_pipe` — `e76c088`, `00cb6a8`, `e8924dc`, `c888564`
- [x] base: `mem_dup` overflow guard, `sb_push` alias safety, `parse_u64`
      overflow — `e06d270`

Design / maintenance

- [x] one UTF-8 decoder / sanitizer — `e06d270`
- [x] one `Url` layout (`wire/url.inc`); `U_SIZE` → `USAGE_SIZE`; `MD_*` →
      `MDK_*` — `85dcbc4`, `7786d39`, `af7cffd`
- [x] schema-driven `tool_validate` — `af7cffd`
- [x] static provider dispatch table — `af7cffd`
- [x] document the process-global singleton + abort/exit semantics — `43274c1`
- [x] hermetic `tests/run.sh`; +6 regression tests — `5ab2c41`

## Uncommitted

- (none)

## Decisions

- Fix correctness/security first, then refactors, then docs/tests; keep
  `make check` green and cross-targets assembling after every wave.
- Regression test for every defect the headless harness can observe.
- Accepted debt (deferred): physical split of `app/tui.s`; full `Agent*`
  encapsulation; registries beyond the provider table; Makefile per-target
  dedup; plugin-host event dispatch; ABI-bridge verification (needs Apple/qemu
  hardware).
