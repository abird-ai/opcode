# TODO — parity2

Status: done (one lineage-comment nit carried forward)
Provenance: `df8c7fa` → `77216fa`
Proof of record: `eb4602e` (v0.3.0, user-approved)

Goal: match agentc's login/logout workflow, add interactive pickers, and align
model discovery.

## Done

- [x] login/logout parity: `--manual`/`--paste`, sets `default_provider`,
      logout clears OAuth + api_key — `7e87ea2`
- [x] modal model/thinking pickers and a standalone `opcode_pick_tty` session
      picker — `e173696`
- [x] `--list-models`/`--refresh-models`, 24 h discovery cache, `--resume`
      picker — `4785b6f`
- [x] docs for login/pickers/discovery; README leads with agentc — `4ed4deb`
- [x] accept full redirect URLs (state in the fragment) in `login --manual` —
      `afcfb91`
- [x] interactive provider/model pickers during onboarding — `922203e`
- [x] a lone Esc cancels the standalone picker — `d33a800`
- [x] onboarding picker docs — `fe4a200`
- [x] core: reasoning defaults to `medium`; `agent_load_session`;
      `openai_client_version` — `66e4958`
- [x] tui: in-TUI `/resume` and `/continue`, wrap-around menus, inline
      scrollbar — `4c30c5b`
- [x] discovery: Codex/Responses `/models` with `client_version` — `4747c59`
- [x] regenerate TUI goldens for the medium default and picker chrome —
      `77216fa`
- [x] listing flags (`--list-models`/`--list-sessions`) recognised regardless of
      position — folded

## Uncommitted

- (none)

## Carried forward

- [ ] remove the remaining `agentc` comments in `src/core/discover.s` and
      `src/core/config.s` — tracked in the top-level `plans/TODO.md`.

## Decisions

- Provider defaults to `openai`; on success set `default_provider`.
- `--continue` stays newest; a non-TTY `--resume` falls back to newest.
- Discovery failures are non-fatal per provider; `--offline` never probes.
