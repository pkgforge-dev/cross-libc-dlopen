# docs.md

Which documents exist and what each one owns.
[`prose.md`](prose.md) is how they are written.

---

## The set

| file | owns |
|---|---|
| [`../../README.md`](../../README.md) | what this is, for a competent stranger: what, why, how to start, and where every other document is. ⛔ Concise and technical. No paragraph whose subject is a past mistake. ⛔ **It carries the documentation map**, so `docs/` has no index page of its own for the two to disagree |
| [`../alternatives.md`](../alternatives.md) | the other answers to the same problem, and which one fits the reader's position. ⛔ Comparison belongs here and not in `README.md`, which was two thirds comparison before this row existed |
| [`../AGENTS.md`](../AGENTS.md) | ⭐ the router. One per repository, in `docs/`. Restates nothing, links everything |
| [`../HUMANS.md`](../HUMANS.md) | the operator's side: what to paste to get useful work out of a session |
| [`../todo/PROGRESS.md`](../todo/PROGRESS.md) | ⭐ the record. The baseline, what the last session did, and **the work order**. Nothing else carries a work order |
| [`../todo/INDEX.md`](../todo/INDEX.md) | every entry, one line each, with the counts. A list, not an order |
| [`../todo/RULES.md`](../todo/RULES.md) | how this repository is worked on, with what each rule cost to learn |
| [`../report/README.md`](../report/README.md) | ⭐ the measured record. **Every count and every suite total lives here.** When any document conflicts with it, this one wins and the other is the defect |
| [`../overview.md`](../overview.md), [`../building.md`](../building.md), [`../integrating.md`](../integrating.md), [`../diagnostics.md`](../diagnostics.md), [`../limits.md`](../limits.md), [`../traps.md`](../traps.md) | what the thing does and how to use it |
| [`../history/`](../history/README.md) | why things are the way they are. Every past mistake, in its original wording |

⭐ Create what the project has a use for and nothing else. A file nobody
selected is a file a future session reads, believes, and follows into a rule
that was never meant to apply.

---

## The invariants

### One fact, one home

See [`prose.md`](prose.md). [`../report/README.md`](../report/README.md) is the home for every
measured number, and CI checks it.

### The measured record wins

When any document conflicts with [`../report/README.md`](../report/README.md), the report is
right and the other document is the defect. Fix it in the same change.

### Documentation ships with the code it describes

⛔ The moment code changes a documented behaviour, the document changes with it,
in the same commit. Doc and code drifting apart is a forbidden pattern.

### Every claim is verified before it is written

Writing the documentation is the audit. ⚠ **The most confident sentence in a
file is regularly the only false one.** Two examples from this repository, both
found by a review pass rather than by a user:

- `../report/README.md` said the shims carry an IBT property note because they are built
  `-fcf-protection=full`. Measured on three Debian images: no note is emitted,
  with or without the flag.
- The prior-art paragraph described another project's CI from reading rather
  than from checking, and one of its numbers was not what that project's own
  manifest says.

### Prefer a shape a check can assert

Where a document names a file, a target or an identifier, prefer a form a check
can verify against the tree, so a rename fails a gate instead of rotting.

### Say what is not true

⛔ A limit hidden is a defect filed against the user later.
[`../limits.md`](../limits.md) is that place, and an entry there without a
measurement behind it is labelled UNVERIFIED rather than argued.
