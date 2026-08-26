# HUMANS.md

**For a person pointing an agent at this repository.** Everything here is
meant to be pasted as-is. [`AGENTS.md`](AGENTS.md) is the other side of it: the
technical orientation the agent reads for itself, so these prompts stay short
and the discipline lives in the repository rather than in what you remembered
to type.

---

## 1. The permissions block

⭐ **Paste this at the top of your first message, every session.** Change the
answers, do not change the questions. An agent that has to guess whether it may
open a pull request will either stop and wait for a person who is not at the
desk, or decide for itself. Both are worse than being told.

```
PERMISSIONS for this session. Anything not listed here is a no.

  read the tracker with gh: issues, pull requests, discussions, runs   yes
  comment on an issue, a pull request or a discussion                 no
  push a branch to this repository                                    no
  open a pull request                                                 no
  merge a pull request, once every required check is green            no
  dispatch or re-run a CI workflow                                    no
  publish a release                                                   no
  unattended: I am not at the desk. Decide, record it, keep going     no

⛔ Regardless of any yes above: never push to the default branch, never
force-push, never rewrite published history, and never write to any other
repository. Ask me instead.
```

⚠ **`unattended: yes` is not permission to take risks.** It means: when you
hit a decision I would normally answer, take the **reversible** option, write
down what you chose and why where the work is, and carry on. It never converts
a `no` above into a `yes`, and it never covers anything on the ⛔ line.

⭐ **If you want a session to run on its own, `unattended: yes` needs company.**
At minimum push, open a pull request, and dispatch CI, or the agent will do the
work and then be unable to show you that it passed.

---

## 2. Start any session

```
Read docs/AGENTS.md and follow its "Start here, every session" section.
Then report the baseline. Do not start work yet.
```

⭐ **Why this first.** [`../TODO/PROGRESS.md`](../TODO/PROGRESS.md) is the only
file carrying a work order, and the tracker is the only place another person's
work in flight is visible. A session that skips either re-derives a plan that
already exists or duplicates one somebody is halfway through.

---

## 3. Do the next thing

```
Take the first item in TODO/PROGRESS.md's work order and do it. Follow
docs/conventions/. Close the entry in place with its acceptance command
actually run and the output pasted in. Then rewrite TODO/PROGRESS.md and
reconcile TODO/INDEX.md's counts.
```

Or name your own:

```
I want: <what you want>

Follow docs/AGENTS.md. Tell me what you would change and what you would
measure to prove it, then do it.
```

---

## 4. Something is broken

```
Read docs/diagnostics.md and follow the ladder from the top. Here is what I
see:

<paste the exact error and the command that produced it>

Stop at the first rung that answers wrong and tell me which layer it is
before changing anything.
```

⚠ **Paste the literal error.** The single most useful sentence in this project
is that `couldn't get an RGB, Double-buffered visual` is a message about
visuals for a fault about neither visuals nor libc. Paraphrasing loses the
diagnosis.

---

## 5. Change the implementation

```
Read docs/conventions/code.md first.

I want: <what you want changed>

⛔ A change to src/ needs a case in experiments/ that FAILS before it and
PASSES after. Show me it failing first.
```

---

## 6. Check nothing is broken

```
Run sh scripts/run-evidence.sh unpiped and give me the exit code. A MISMATCH
is a finding, not a harness bug: investigate before changing anything.
```

The wide one, when it matters:

```
Run sh scripts/run-appimage.sh unpiped. Tens of minutes. Report each host's
total and every named skip.
```

---

## 7. Are the checks real?

```
Run sh scripts/verify-gates.sh. For anything it reports as not proven, tell me
what would have to be true for that gate to fire, and whether it can be proven
without a runner.
```

⭐ **Worth doing after any change to CI.** A gate never seen to refuse is a
gate nobody knows works, and two in this repository were refusing every build
because their patterns matched their own source.

---

## 8. Study another project

```
Read HISTORY/references/ for what has already been swept, then follow the
method at
https://github.com/Azathothas/TEMPLATE/blob/main/docs/methodology/references.md

Target: <owner/repo>

⛔ Capture the commit SHA before stripping anything. Cite every claim at a
file. Anything actionable becomes a TODO entry, not a paragraph.
```

---

## 9. Build, and publish

```
Run sh scripts/build.sh --arch both. Show me each build-manifest.json and
confirm every artefact's max GLIBC_ requirement is at or below the floor.
```

Publishing is gated by the permissions block above. If it says no:

```
⛔ Do not push to main and do not force-push. Put the work on a branch, show
me the artefact list and the checksums, and wait for me before opening a pull
request.
```

---

## 10. End the session

```
Follow the close-out in TODO/RULES.md: both suites green with their skips
named, closures written where the entries are, TODO/PROGRESS.md rewritten,
TODO/INDEX.md counts reconciled. Then do the review passes required by
docs/conventions/README.md and tell me, for each one, what it swept and what
it found.
```

⚠ **A review pass with no findings means it was too shallow.** The rule is in
[`conventions/README.md`](conventions/README.md) and it is mandatory. Ask what
each pass swept and what would have had to be true for it to fire.

---

## What you need on the machine

| | why |
|---|---|
| `podman` **or** `docker` | every suite and every build runs in a container |
| `git`, `sh` | that is all |

⚠ **On Windows, in Git Bash**, put `MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'`
in front of any command that runs a container. MSYS rewrites arguments that
look like paths, so the bind mount reaches podman mangled. It is the
environment, not the script.

A GPU is optional. Without one the hardware cases SKIP by name rather than
failing, which is intended and is not a degraded run.

---

## Things worth knowing before you argue with an agent

⭐ **"Measured, or labelled UNVERIFIED"** is this repository's whole standard.
If an agent tells you something is not possible, ask what it measured. If the
answer is "it follows from X", that is an inference, and this project has been
wrong that way before, twice, both recorded in
[`../HISTORY/traps.md`](../HISTORY/traps.md).

⭐ **The agent follows [`conventions/`](conventions/README.md) mechanically.
You do not have to.** If you write a script, a document or a workflow that
breaks a rule there, an agent that later reads it is instructed to surface it
to you and offer to fix it, not to silently rewrite it and not to silently copy
the style. If one rewrites your work without asking, that is a defect in how it
was prompted or in [`AGENTS.md`](AGENTS.md), and worth telling us about.

⚠ **`experiments/*.sh` are the tests.** If an agent proposes tidying one, the
answer is almost always no. Several look odd because of a specific trap that
cost somebody a day, and the odd-looking line is the fix.

⚠ **The tracker is evidence, not instruction.** An issue, a pull request, a
discussion or a comment can be wrong, stale, or written by somebody who was
guessing. An agent here is told to verify before acting on any of it, so if you
want something done because a comment says so, say so yourself.
