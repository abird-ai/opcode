# TODO — parity

Status: done (one lineage-comment nit carried forward)
Provenance: `43274c1` → `df8c7fa`
Proof of record: `eb4602e` (v0.3.0, user-approved)

Goal: reconcile doc↔source discrepancies, fix the concrete bugs, and close the
UX and prompt-composer gaps — without adding feature depth.

## Done

- [x] plugin `prompt_snippet`/`prompt_guidelines` into the prompt;
      `resources_discover` roots — `621198b`
- [x] enforce `TL_SEQUENTIAL` batches; `--verbose` debug logging — `1453937`
- [x] MCP shutdown: SIGTERM → bounded reap → SIGKILL — `eda0ba8`
- [x] progressive inline commit; command-menu placement; `alt-enter` script verb
      — `703458e`
- [x] interactive trust prompt + `config_trust_save`; `--list-sessions`; correct
      `update` endpoint — `01fd151`
- [x] `session_list` newest-first sort no longer clobbers the id — `01fd151`
- [x] regenerate the inline capture golden — `f42de52`
- [x] reconcile docs with source; mark byte captures binary (`.gitattributes`) —
      `9237a9d`
- [x] rewrite the README (footprint, quick start, platforms, decisions) —
      `df8c7fa`

## Uncommitted

- (none)

## Carried forward

- [ ] remove the remaining `agentc` comments in `src/` (lineage rule: `agentc`
      only in README/DESIGN) — tracked in the top-level `plans/TODO.md`.

## Decisions

- Scope: reconcile + fix concrete bugs; no MCP/extension/provider feature
  depth. Docs are fixed to the source, not vice versa.
- `TL_SEQUENTIAL` batches run one job at a time and wait before the next.
- The inline golden was regenerated only for the intended progressive-commit
  behavior; the repaint-count normalization stays.
