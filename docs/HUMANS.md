# HUMANS.md

**For a person pointing an agent at this repository.**

Every scenario below is a prompt you can paste as-is. Each one has a matching
row in [`AGENTS.md`](AGENTS.md) that tells the agent what to read and what the
rules are, so the prompt stays short and the discipline lives in the repository
rather than in what you remembered to type.

⭐ **Start every session with the first one.** It costs one line and it is what
stops a session from working against a stale picture.

---

## What you need on the machine

| | why |
|---|---|
| `podman` **or** `docker` | every suite and every build runs in a container. Nothing else is installed on your machine |
| `git`, `sh` | that is all |

⚠ **On Windows, in Git Bash**, put `MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'`
in front of any command below that runs a container. MSYS rewrites arguments
that look like paths, so the bind mount reaches podman mangled. It is the
environment, not the script.

A GPU is optional. Without one, the hardware cases SKIP by name rather than
failing, which is the intended behaviour and not a degraded run.

---

## Scenario 1: start any session

```
Read docs/AGENTS.md. List the open issues and pull requests on
pkgforge-dev/cross-libc-dlopen. Then read TODO/PROGRESS.md and tell me the
current baseline, what the last session left, and what the work order says is
next. Do not start work yet.
```

⭐ **Why this first.** `PROGRESS.md` is the only file carrying a work order, and
the tracker is the only place another person's work in flight is visible. A
session that skips either re-derives a plan that already exists, or duplicates
one somebody is halfway through.

---

## Scenario 2: pick up the next task

```
Read docs/AGENTS.md and TODO/PROGRESS.md, take the first item in the work
order, and do it. Follow docs/conventions/. Close the entry in place with the
acceptance command actually run and its output pasted in. Then rewrite
TODO/PROGRESS.md and update TODO/INDEX.md's counts.
```

---

## Scenario 3: something is broken and you do not know which layer

```
Read docs/diagnostics.md and follow the ladder from the top. Here is what I
see:

<paste the exact error and the command that produced it>

Stop at the first rung that answers wrong and tell me which layer it is before
changing anything.
```

⚠ **Paste the literal error.** The single most useful sentence in this project
is that `couldn't get an RGB, Double-buffered visual` is a message about
visuals for a fault about neither visuals nor libc. Paraphrasing it loses the
diagnosis.

---

## Scenario 4: change something in `src/`

```
Read docs/AGENTS.md and docs/conventions/code.md first.

I want: <what you want changed>

⛔ A change to src/ needs a case in experiments/ that FAILS before it and
PASSES after. Write that case first, show me it failing, then make the change.
```

---

## Scenario 5: build the artefacts

```
Run: sh scripts/build.sh
Show me build/<arch>/build-manifest.json and confirm every artefact's max
GLIBC_ requirement is at or below the floor.
```

---

## Scenario 6: check I have not broken anything

```
Run sh scripts/run-evidence.sh unpiped and give me the exit code. If it is
non-zero, a MISMATCH is a finding, not a harness bug: investigate before
changing anything.
```

The long one, when it matters:

```
Run sh scripts/run-appimage.sh unpiped. Tens of minutes. Report each host's
total and every named skip.
```

---

## Scenario 7: are the checks real?

```
Run sh scripts/verify-gates.sh. For anything it reports as not proven, tell me
what would have to be true for that gate to fire, and whether it can be proven
without a runner.
```

⭐ **Worth doing after any change to CI.** A gate never seen to refuse is a gate
nobody knows works, and two in this repository were refusing every build
because their patterns matched their own source.

---

## Scenario 8: study another project and bring back what transfers

```
Read HISTORY/references/ for what has already been swept, then follow the
method at
https://github.com/Azathothas/TEMPLATE/blob/main/docs/methodology/references.md

Target: <owner/repo>

⛔ Capture the commit SHA before stripping anything. Read the tracker, both
states. Cite every claim at a file. Anything actionable becomes a TODO entry,
not a paragraph.
```

---

## Scenario 9: end the session cleanly

```
Follow the close-out in TODO/RULES.md: both suites green with their skips
named, closures written where the entries are, TODO/PROGRESS.md rewritten,
TODO/INDEX.md counts updated. Then do the review passes in
docs/conventions/README.md and tell me what each pass swept and what it found.
```

⚠ **A review pass with no findings means it was too shallow.** Ask what it
swept and what would have had to be true for it to fire.

---

## Scenario 10: publish a release

```
Read docs/AGENTS.md and docs/conventions/git.md. Build for both architectures
and verify every artefact against the manifest.

⛔ Do not push to main and do not force-push. Put the work on a branch, show me
the artefact list and the checksums, and wait for me to say yes before you open
a pull request.
```

⚠ **There is no release workflow yet.** Building and verifying works today;
publishing a release is [`../TODO/infrastructure.md`](../TODO/infrastructure.md)
T-18.

---

## Things worth knowing before you argue with an agent

⭐ **"Measured, or labelled UNVERIFIED"** is this repository's whole standard.
If an agent tells you something is not possible, ask what it measured. If the
answer is "it follows from X", that is an inference, and this project has been
wrong that way before -- twice, both recorded in
[`../HISTORY/traps.md`](../HISTORY/traps.md).

⭐ **The agent will follow `docs/conventions/` mechanically. You do not have
to.** If you write a script, a document or a workflow that breaks a rule there,
an agent that later reads it is instructed to **surface it to you and offer to
fix it**, not to silently rewrite it and not to silently copy the style. If one
does rewrite your work without asking, that is a defect in how it was prompted
or in `AGENTS.md`, and worth telling us about.

⚠ **`experiments/*.sh` are the tests.** If an agent proposes tidying one, the
answer is almost always no. Several look odd because of a specific trap that
cost somebody a day, and the odd-looking line is the fix.
