# docs.md

Which documents exist and what each one owns.
[`prose.md`](prose.md) is how they are written.

---

## The set

| file | owns |
|---|---|
| [`../../CONTRIBUTING.md`](../../CONTRIBUTING.md) | how to contribute, as a table of links. ⛔ It states no rule of its own: this directory is the authority and a rule written twice disagrees with itself |
| [`../../SECURITY.md`](../../SECURITY.md) | how to report a vulnerability privately, and what is worth reporting. ⚠ A different question from [`../security.md`](../security.md), which is about what a pull request can reach in CI |
| [`../../README.md`](../../README.md) | what this is, for a competent stranger: what, why, how to start, and where every other document is. ⛔ Concise and technical. No paragraph whose subject is a past mistake. ⛔ **It carries the documentation map**, so `docs/` has no index page of its own for the two to disagree |
| [`../alternatives.md`](../alternatives.md) | the other answers to the same problem, and which one fits the reader's position. ⛔ Comparison belongs here and not in `README.md`, which was two thirds comparison before this row existed |
| [`../AGENTS.md`](../AGENTS.md) | ⭐ the router. One per repository, in `docs/`. Restates nothing, links everything |
| [`../HUMANS.md`](../HUMANS.md) | the operator's side: what to paste to get useful work out of a session |
| [`../todo/PROGRESS.md`](../todo/PROGRESS.md) | ⭐ the record. The baseline, what the last session did, and **the work order**. Nothing else carries a work order |
| [`../todo/INDEX.md`](../todo/INDEX.md) | every entry, one line each, with the counts. A list, not an order |
| [`../todo/RULES.md`](../todo/RULES.md) | the life of an entry in `docs/todo/`: what one is, that it closes in place, and the close-out sequence. ⛔ It routes to the conventions for everything else, because it used to restate three of `git.md`'s sections and a reader could not tell which copy was authoritative |
| [`../report/README.md`](../report/README.md) | ⭐ the measured record. **Every count and every suite total lives here.** When any document conflicts with it, this one wins and the other is the defect |
| [`../overview.md`](../overview.md), [`../building.md`](../building.md), [`../integrating.md`](../integrating.md), [`../diagnostics.md`](../diagnostics.md), [`../limits.md`](../limits.md), [`../traps.md`](../traps.md) | what the thing does and how to use it |
| [`../history/`](../history/README.md) | why things are the way they are. Every past mistake, in its original wording |

⭐ Create what the project has a use for and nothing else. A file nobody
selected is a file a future session reads, believes, and follows into a rule
that was never meant to apply.

---

## Where a file lives

⛔ **The root names what the project builds. Prose lives under `docs/`.**

| root entry | holds |
|---|---|
| `src/` | the implementation |
| `tests/` | the probes |
| `tools/` | generators and analysis |
| `scripts/` | build and orchestration |
| `experiments/` | the staged cases, which are the tests |
| `examples/` | scripts that run and print a before and an after |
| `inventories/` | measured symbol inventories the generators consume |
| `docs/` | every document |

⭐ **Three markdown files are the exception, and each is opened by convention
rather than by following a link:** `README.md`, `CONTRIBUTING.md` and
`SECURITY.md`. GitHub renders the first, offers the second when a pull request
is opened, and surfaces the third on the security tab. A fourth has no such
excuse and belongs under `docs/`.

⚠ **The check is section 4b of
[`../../scripts/check-drift.sh`](../../scripts/check-drift.sh).** It exists
because nothing said this before: `HISTORY/` and `TODO/` sat at the root, in
capitals, beside `src/` and `tests/` for the life of the project, and the rule
they broke had never been written down.

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
