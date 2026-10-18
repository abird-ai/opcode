# TODO-SPEC — how plans and TODOs are tracked

Opcode tracks work as plain, hand-edited markdown checklists. This replaces
handoff prose, per-run `STATE.md`/`REPORT.md`/`decisions.md`, evidence bundles
and generated tracking files. The git history is the evidence, and a
user-approved snapshot commit at the tip is the accepted proof of record. This
file is the rulebook; `AGENTS.md` is the repository guide.

## Files

| file | role |
| --- | --- |
| `.agents/plans/TODO.md` | plan ledger — one line per plan |
| `.agents/plans/<plan>/README.md` | plan details (optional) |
| `.agents/plans/<plan>/DESIGN.md` | detailed architecture (optional) |
| `.agents/plans/<plan>/DECISIONS.md` | user decisions (optional) |
| `.agents/plans/<plan>/REFERENCES.md` | research and source references (optional) |
| `.agents/plans/<plan>/TODO.md` | a plan's living checklist (required) |
| `.agents/runs/<plan>-<session>/TODO.md` | one working agent's private checklist (gitignored) |
| `.agents/plans/TODO-SPEC.md` | this file — the rules |

There is no other tracking artifact: no tracking JSON, no per-run report, no
evidence directory.

## Plan layout

A plan is a directory under `.agents/plans/<plan>/`. `TODO.md` is required; the
optional `README.md` is the single home for everything else:

- `README.md` — the plan details: what it is and why it exists, plus goals,
  scope, and links, and sections as needed:
  - **Design** — interfaces, invariants, alternatives considered, migration and
    rollback.
  - **Decisions** — user decisions that bind the plan, with their rationale, so
    agents follow them instead of re-litigating settled questions.
  - **References** — research and source references: papers, specs, prior art,
    source files, benchmarks, with enough provenance to reproduce the reasoning.

  Open it with the plan's authorship: when human-led, `Author: <user>` plus
  `Co-authors: <comma-separated AI models used>`; when AI-led,
  `Author: <the AI models only>`. Keep it one file while it stays readable. When
  a section grows large, split it into `DESIGN.md`, `DECISIONS.md`, or
  `REFERENCES.md` beside `README.md` and link back from `README.md`.
- `TODO.md` — the detailed todo: implementation, tests, verification, gates, and
  evidence. Required, and it needs to be extensive — every step, test, and gate
  gets its own item. Completed work is grouped under the commit that landed it;
  work without a commit yet goes under `## Uncommitted`.

Keep plans flat: a plan is a top-level directory under `.agents/plans/`, not
nested inside another, and one flat plan per effort is preferred while its
`TODO.md` stays tractable. Only an extremely complex or large design splits into
smaller plans that stand on their own — added as sibling plan directories, with
the larger plan's `TODO.md` referring to them by link instead of carrying every
item.

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

- `## Committed` — landed work, grouped under a `### <sha>` heading per
  commit that landed each set; the heading is the provenance for every item
  beneath it. Append new groups, newest last; never reorder or rewrite one.
- `## Uncommitted` — work not yet committed (owner + note); the only place new
  work appears.
- `## Tests and verification` — every test and gate the plan must pass, each
  with the command or evidence that proves it; a plan is not done while any of
  these is open. All must be `[x]` on the closing commit.
- optional `## Deferred` — accepted, fail-closed items with their reason.

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
- On every commit, add a `### <sha>` group under `## Committed` and move the
  items it landed into it; leave the rest in `## Uncommitted`. Mark `[x]` only
  once the item is committed.
- When a plan has no open items and every `## Tests and verification` item is
  `[x]`, mark its line in `plans/TODO.md` `[x]` and record its tip as the proof
  of record.

## Invariants

- Checklists are hand-edited. A generated checklist that rejects editing is a
  report, not a TODO.
- Invariant and contract gates stay executable scripts. A checklist line may
  *name and require* a gate; the gate must remain a script, or nothing enforces
  it.
- Never enable later phases and never record a pass that was not run.
