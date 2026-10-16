# TODO — clean-lineage

Status: done
Provenance: `46706ad` (pre-rewrite, 61 commits) → base history `7fc7363`..`43274c1`
Proof of record: `eb4602e` (v0.3.0, user-approved)

Goal: `.agents/` describes the system as it is now (not how it evolved); the
README leads with "research project; production → agentc"; the git history is a
clean set of signed logical commits with no falcon/aagent/agentc-parity lineage.

## Done

- [x] Recon + freeze: 38 modified + 59 untracked files, `make check` 209/0,
      HEAD `46706ad`, SSH signing config — recon
- [x] Rewrite `.agents/` to current state (`plans/DESIGN.md`, `docs/*`,
      `AGENTS.md`); delete `COMPOSER-PARITY.md`, `UX-PARITY.md` and the old
      council runs — `43274c1`
- [x] Scrub source/API/tests of lineage; `tests/prompt_parity_test.*` →
      `prompt_compose_test.*` — base history
- [x] README research/production note + pi/rhun thanks; `Falcon` → `Opcode`
      headers; `THIRD_PARTY.md` pi section — base history
- [x] Rebuild history as 16 signed logical commits from the frozen tree; drop
      and `gc` the 61-commit falcon/aagent lineage — `7fc7363`..`43274c1`
- [x] Branch `master` → `main`; SSH-sign every commit (ED25519) — base history
- [x] Final verify: tree `9a9de5e`, `make clean && make check` 209/0, 16/16
      signatures GOOD, lineage greps clean, links resolve, critic objections
      resolved — verify gate

## Uncommitted

- (none)

## Decisions

- Fresh orphan linear history from the frozen tree (not a rebase).
- Layered/logical granularity; only the tip must build (user option 1a).
- Keep license attribution (mbedTLS/CA bundle/rhun) + pi thanks; drop
  parity/evolution framing; `agentc` only as the production pointer.
- `DESIGN.md` stays at `.agents/plans/DESIGN.md`; branch `main`; runs untracked
  and gitignored.
- Stage explicit path groups; never `git add -A`.

## Carried forward

- Intermediate commits are not independently green (synthetic partition; all
  share a timestamp; docs land last). Accepted.
- Pre-rewrite history is intentionally unrecoverable. Accepted.
- SSH signing, not OpenPGP (GitHub "Verified" needs the key registered).
- Performance figures are approximate; aarch64/macOS/Windows unverified on
  silicon.
