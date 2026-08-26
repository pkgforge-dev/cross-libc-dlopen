# AGENTS.md

`cross-libc-dlopen` lets a process carrying its own bundled glibc load the
**host's** GPU drivers -- drivers built against a newer glibc, or against musl,
or shipped in a shape the bundled dispatcher does not recognise -- without
patching host files, bundling a second libc, or causing symbol collisions. It
is a C implementation plus the measurements that establish what it does and
does not do.

**This file is a router.** It is the only agent entry point in this
repository -- not one per directory, not a second one in the root. It restates
nothing written elsewhere, so the two cannot fork. Everything binding is
linked, and the link is the authority: reading a row in a table here is not
reading the rule.

[`HUMANS.md`](HUMANS.md) is the other side of it: the prompts a person pastes
to reach each scenario below.

---

## Start here, every session

⛔ **Read the tracker before anything else.** This is an organisation
repository with more than one person and more than one agent in it.

```bash
gh issue list --repo pkgforge-dev/cross-libc-dlopen --state open
```

```bash
gh pr list --repo pkgforge-dev/cross-libc-dlopen --state open
```

⭐ **Then read [`../TODO/PROGRESS.md`](../TODO/PROGRESS.md).** It is the only
file that carries a work order. Nothing else does -- not this file, not
`README.md`, not `TODO/INDEX.md`.

⛔ **And nothing you do lands on `main` directly.** Branch, then a pull request,
and ask before opening it. [`conventions/git.md`](conventions/git.md).

Then read what **this task** routes you to. Not everything, and not less.

---

## The scenarios

Each row matches a numbered scenario in [`HUMANS.md`](HUMANS.md). Find the one
in front of you and read what it names, in full.

| # | the task | read, in this order | ⛔ the rule that governs it |
|---|---|---|---|
| 1 | **Start a session** | [`../TODO/PROGRESS.md`](../TODO/PROGRESS.md) · [`../TODO/RULES.md`](../TODO/RULES.md) · **the open tracker** | ⛔ list open issues AND pull requests first. Somebody else may already be doing this. Then report the baseline before proposing anything |
| 2 | **Take the next task** | [`../TODO/PROGRESS.md`](../TODO/PROGRESS.md) work order · the entry in [`../TODO/INDEX.md`](../TODO/INDEX.md) · [`conventions/README.md`](conventions/README.md) | an entry closes **in place**, with its acceptance command actually run and the output recorded |
| 3 | **Diagnose a failure** | [`diagnostics.md`](diagnostics.md) · [`traps.md`](traps.md) · [`overview.md`](overview.md) | stop at the first rung that answers wrong. The rungs below it are noise until it is fixed |
| 4 | **Change `src/`** | [`conventions/code.md`](conventions/code.md) · [`overview.md`](overview.md) · the case in [`REPORT.md`](REPORT.md) that covers it | ⛔ a change here needs a case that FAILS before and PASSES after |
| 5 | **Build** | [`building.md`](building.md) · [`../src/Makefile`](../src/Makefile) header | ⛔ the floor rule first. Oldest glibc, never the newest |
| 6 | **Run the suites** | [`reproducing.md`](reproducing.md) | a MISMATCH is a finding, not a harness bug. Investigate before coding |
| 7 | **Touch CI or a check** | [`../.github/workflows/gates.yml`](../.github/workflows/gates.yml) · [`conventions/shell.md`](conventions/shell.md) | ⭐ plant the defect and read the exit code, **and** run it against a clean tree. `sh scripts/verify-gates.sh` |
| 8 | **Study another project** | [`../HISTORY/references/`](../HISTORY/references/) · the method at [`TEMPLATE docs/methodology/references.md`](https://github.com/Azathothas/TEMPLATE/blob/main/docs/methodology/references.md) -- ⚠ in the template, not in this tree | ⛔ capture the commit SHA before stripping. Cite every claim at a file |
| 9 | **End the session** | [`../TODO/RULES.md`](../TODO/RULES.md) close-out · [`conventions/README.md`](conventions/README.md) | rewrite `PROGRESS.md`; update `INDEX.md`'s counts |
| 10 | **Publish anything** | [`conventions/git.md`](conventions/git.md) · [`building.md`](building.md) | ⛔ **never push to the default branch.** Branch, then a pull request with `gh`, and ⛔ **ask first** unless the prompt authorises publishing in so many words |
| -- | **Write or edit a document** | [`conventions/prose.md`](conventions/prose.md) · [`conventions/docs.md`](conventions/docs.md) | one fact, one home |
| -- | **Commit** | [`conventions/git.md`](conventions/git.md) | ⛔ no tool is credited |
| -- | **Wonder why something is the way it is** | [`../HISTORY/`](../HISTORY/README.md) | every past mistake is there, in its original wording |

⛔ **Read what the row names in full.** Not grepped, not skimmed, not recalled
from a previous session. The routing exists so the reading is small enough to
actually do. When two rows apply, read both -- the union, not the shorter one.

---

## ⭐ When a human wrote it, say so rather than fixing it silently

You will follow [`conventions/`](conventions/README.md) mechanically. **A human
contributor may never have read them**, and that is normal.

⛔ **So when you find a script, document, test, workflow or tool in this
repository that breaks a convention, do three things and stop:**

1. **Name it.** The file, the line, and the rule it breaks.
2. **Say what you would change**, concretely.
3. **Offer.** Then wait.

⛔ **Do not silently rewrite it.** The person who wrote it may have had a reason
that is not written down, and a rule applied over an unstated reason is how a
working thing gets broken tidily. This repository has an example: several
`experiments/*.sh` lines look wrong and are the fix for a specific trap.

⛔ **And do not silently copy it either.** Finding one convention-breaking file
is not permission to write a second. If the existing style and the written rule
disagree, the written rule wins and the disagreement is the finding.

⚠ Politely. The point is to give the operator a decision, not a verdict.

---

## The three things this repository will not bend on

Each links to where the real rule lives.

### 1. State a prediction, report MATCH or MISMATCH, and a MISMATCH is a finding

Every case in `experiments/*.sh` declares what it expects before it runs.
⛔ **A test whose success condition is "a string appeared" passes a broken
implementation** -- the probes clear to a known colour and read the pixel back
for exactly that reason. [`conventions/code.md`](conventions/code.md).

### 2. Measured, or labelled UNVERIFIED. Never estimated

⭐ **A SKIP names a missing capability and stops there.** It may not add "and
therefore nothing can be done" -- that is a claim about the design space, and
welded to a measured fact it inherits that fact's authority.
[`conventions/prose.md`](conventions/prose.md).

### 3. One fact, one home

⛔ **No measured number appears in two documents.** Every count and every suite
total lives in [`REPORT.md`](REPORT.md); everywhere else points at it. The gate
is in [`gates.yml`](../.github/workflows/gates.yml).

---

## What must not be touched, and why

| path | why |
|---|---|
| `experiments/*.sh` | ⛔ **these are the tests.** Rewriting one in another language, "cleaning up" a grep, or making an assertion tidier silently changes what is asserted. Port the ORCHESTRATION around them -- [`../scripts/run-evidence.sh`](../scripts/run-evidence.sh) is that layer |
| `src/forward-shim.c`, `src/gl-fwd-*.h` | ⛔ **generated.** [`conventions/code.md`](conventions/code.md) has the regeneration commands |
| `inventories/*.json` | measured symbol inventories the generator consumes |
| `.gitattributes` | enforces LF on `.sh`. A CR makes every command in a script report "not found" while naming something else |
| `$APPDIR/lib/foreign-dlopen.so`, `.foreign-dlopen-enabled` | ⚠ **these two names are upstream's.** Renaming either turns E30, E37a and E43a into silent passes. `sh scripts/verify-upstream-controls.sh` proves the difference |

---

## The suites

```bash
sh scripts/run-evidence.sh
```

The ~4 minute pre-commit gate. Exit 0 means every prediction held.

```bash
sh scripts/run-appimage.sh
```

Tens of minutes: two downloads and four distributions, two of them from 2014
and 2016. Not a pre-commit gate. ⚠ Neither is deprecated by CI -- CI is the
wider matrix and the architectures a developer does not have.

Totals and per-host results: [`REPORT.md`](REPORT.md).
