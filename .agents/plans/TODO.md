# TODO — plans

Plan ledger: one line per plan, `[x]` = done. A plan is done only when its
`plans/<plan>/TODO.md` has no open items. See
[`TODO-SPEC.md`](TODO-SPEC.md) for the rules.

- [x] [clean-lineage](clean-lineage/TODO.md) — current-state `.agents/`, lineage-free signed history — `7fc7363`..`43274c1`
- [x] [hardening](hardening/TODO.md) — correctness/robustness/memory-safety sweep — folded into `7fc7363`..`43274c1`
- [x] [parity](parity/TODO.md) — doc↔source reconcile, prompt/composer and inline-commit gaps — `43274c1`..`df8c7fa`
- [x] [parity2](parity2/TODO.md) — login/logout, pickers, model discovery — `df8c7fa`..`77216fa`
- [x] [ux-parity](ux-parity/TODO.md) — picker/UX parity, inline erase + capture robustness — `77216fa`..`443162d`

Snapshot checkpoint: **`eb4602e` (v0.3.0)** is the user-approved proof of record
for all of the above (user authority). The former evidence bundles, contracts,
`STATE.md` and `REPORT.md` files were retired with this snapshot.

## Open

- [ ] Scrub the remaining `agentc` comments from `src/` (`app/tui.s`,
      `core/agent.s`, `core/config.s`, `core/discover.s`, `core/API.md`) per the
      clean-lineage lineage rule: `agentc` survives only in README/DESIGN.
