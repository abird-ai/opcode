# TODO-SPEC — how plans and TODOs are tracked

Opcode tracks work as plain, hand-edited markdown checklists. This replaces
handoff prose, per-run `STATE.md`/`REPORT.md`/`decisions.md`, evidence bundles
and generated tracking files. The git history is the evidence, and a
user-approved snapshot commit at the tip is the accepted proof of record. This
file is the rulebook; `.agents/AGENTS.md` is the repository guide.

## Files

| file | role |
| --- | --- |
| `.agents/plans/TODO.md` | plan ledger — one line per plan |
| `.agents/plans/<plan>/TODO.md` | a plan's living checklist |
| `.agents/runs/<plan>-<session>/TODO.md` | one working agent's private checklist (gitignored) |
| `.agents/plans/TODO-SPEC.md` | this file — the rules |

There is no other tracking artifact: no tracking JSON, no per-run report, no
evidence directory.

## The one rule

Tick an item only after its checks pass, in the same session, on the commit you
are marking. The check *is* the evidence — no separate artifact is required for
the agent to have "checked" it. Never record a pass that was not run, and never
mark an external gate done from authority alone (signed artifacts, real device
runs, real participant data): preserve those as `[!]`.

## Glyphs

| glyph | meaning |
| --- | --- |
| `[x]` | done |
| `[~]` | in progress |
| `[ ]` | not started |
| `[!]` | blocked outside this repository |

## Ledger lines (`.agents/plans/TODO.md`)

One line per plan, with a one-line summary and its commit range:

```text
- [x] [clean-lineage](clean-lineage/TODO.md) — current-state `.agents/`, lineage-free history — `7fc7363`..`43274c1`
- [~] [<plan>](<plan>/TODO.md) — <one-line summary> — since `<base-sha>`
```

A plan is `done` only when its `plans/<plan>/TODO.md` has no open items; flip
the ledger line to `[x]` with the tip commit in the same change.

## Checklist items (`plans/<plan>/TODO.md`)

Header:

```text
# TODO — <plan>

Status: <done | in progress | blocked>
Provenance: <base-sha>            # the commit the plan started from
Proof of record: <snapshot-sha>   # the user-approved tip, when closed
```

Sections, in order:

- `## Done` — landed items; each ends in the commit that landed it.
- `## Uncommitted` — work not yet committed (owner + note).
- optional `## Decisions`.
- optional `## Carried forward`.

An item is a checkbox plus a short action. An optional bold id may prefix it for
plans that carry one:

```text
- [x] enforce `TL_SEQUENTIAL` batches — `1453937`
- [~] **AH-046** signed native packages and store readiness — 0/7 receipts — since `285abc0`
- [!] verify on real Apple silicon — needs a macOS host
```

## Flow

- An agent works in `.agents/runs/<plan>-<session>/TODO.md` (gitignored). When
  its workstream is committed it appends the finished lines to
  `plans/<plan>/TODO.md` in one atomic write and deletes its run file. Streams
  never edit each other's run files.
- On every commit, move the items it landed from `## Uncommitted` to `## Done`
  with the new commit id; leave the rest. Mark `[x]` only once the item is
  committed.
- When a plan has no open items, mark its line in `plans/TODO.md` `[x]` and
  record its tip as the proof of record.

## Invariants

- Checklists are hand-edited. A generated checklist that rejects editing is a
  report, not a TODO.
- Invariant and contract gates stay executable scripts. A checklist line may
  *name and require* a gate; the gate must remain a script, or nothing enforces
  it.
- Never enable later phases and never record a pass that was not run.
