# forbidden-patterns.md

Each row is a mistake that actually shipped, paired with what it caused. This
turns "be careful" into something greppable.

⭐ **Grep yourself against this table before calling a gate green.**

⛔ **Grow it.** Every review that finds a new class of defect adds a row. A row
with no incident behind it is a preference, and preferences stated as rules are
what make an agent stop believing the rules that matter.

⚠ Rows marked **[here]** happened in this repository. The rest are carried from
[`Azathothas/TEMPLATE`](https://github.com/Azathothas/TEMPLATE) because they
recur everywhere.

---

## Guards and gates

| forbidden | what it caused |
|---|---|
| **[here]** A gate whose pattern matches its own source | the gate refuses **every** build. Two did, and it was invisible until a review ran them against a clean tree as well as a planted defect. Write the pattern with character classes: `dlope[n]` matches "dlopen" and is not itself "dlopen" |
| **[here]** Testing for a CR with `grep` | the check reads GREEN over a file that has one. Measured: a pattern built from `$(printf '\r')` matches nothing. Use `tr -d '\r' \| cmp -s - "$f"` |
| **[here]** Carrying a check across a rewrite without re-proving it | the behaviour survives in form and not in fact. The CR refusal was ported out of PowerShell into `sh` as a no-op that looked identical to the original |
| A guard whose test has never been seen to fail | theatre. Plant the defect and read the exit code |
| Reading an exit code through a pipe | the pipeline's status, not the check's. A guard that failed reads as green |
| A control gated on one of several paths into the same action | every other door reaches the same operation ungated |
| A test whose name claims more than it checks | a green suite over the defect it was written to catch |

## Measurement and claims

| forbidden | what it caused |
|---|---|
| **[here]** A doc claim written from reading rather than from checking | a stated fact about another project that its own files contradict. Verify against the code, then cite the file |
| **[here]** Asserting a build property the toolchain does not deliver | a security mitigation documented as present and absent in every artefact. The flag was passed; the note was never emitted |
| **[here]** A SKIP that carries a verdict | "this host has no X, therefore nothing can be done" welded a claim about the design space onto a measured fact, and kept OpenGL broken on every musl distribution for a session |
| **[here]** A test whose success condition is "a string appeared" | passes a broken shim. `GL_RENDERER` printing does not mean anything was drawn |
| **[here]** A single-sided result | cannot tell a fix from a fallback that was already happening |
| A number on a report that was not measured | worse than a blank, because a blank gets checked |
| A value in two places with no check that they agree | drift. The copy a reader trusts is the wrong one |

## Shell

| forbidden | what it caused |
|---|---|
| **[here]** A function that prints its report and echoes its result down stdout | the caller captures both, compares a paragraph to a number, and reports the opposite of what was measured |
| **[here]** A build error discarded with `2>/dev/null` | ten cases failed naming a missing file, and the cause was a compiler error nobody could see |
| **[here]** `ld.so --preload A --preload B` | silently keeps only B. The command line reads as if both are loaded |
| **[here]** `timeout` on a program that never exits, inside `$( )` | hangs on the case that WORKED, while the failing case exits cleanly and looks fine |
| **[here]** A CR in a `.sh` | every command reports "not found" while naming something else |
| A prose payload passed inline to a shell | backticks executed inside the text, even in a quoted heredoc |

## Structure

| forbidden | what it caused |
|---|---|
| **[here]** Editing a generated file | the next `make` reverts it, and the two disagree in between |
| **[here]** Renaming a name that belongs to another project | three controls became silent passes. `$APPDIR/lib/foreign-dlopen.so` and `.foreign-dlopen-enabled` are upstream's |
| **[here]** A source file left in the repository root because a list said "no need to touch" | "correct and self-contained" was about the content, not the location. `elfsym.py` and `gap.py` sat in the root until a human noticed |
| Rebuilding something the tree already does | the most expensive mistake available, and usually invisible in review |
| Dead code kept for later | noise. Delete it; the history remembers |
| A page nothing links to | not read, so not corrected. The state every stale document passes through |

## Tooling

| forbidden | what it caused |
|---|---|
| **[here]** A heredoc carrying backslashes | the shell eats them and the written file differs from the intent, silently |
| **[here]** `grep -q 'properties'` against `readelf` output | the header is `Properties:`, capitalised, so a case-sensitive grep reported an absence that was not there. Grep locates; it does not confirm |
| A literal control byte in a tracked text file | invisible to review. Grep calls the file binary and skips it, and a diff says only that the files differ |
| `podman run --platform linux/arm64` to get another architecture | pulling a tag for another platform REPLACES the cached image, and the next native job dies with `Exec format error` |

---

## How to add a row

Three things, and a row without all three does not go in:

1. **What is forbidden**, in a form someone can grep for or recognise.
2. **What it caused.** Not "it is untidy". The concrete consequence.
3. **Where it happened**, if it happened here.

⚠ If a defect is mechanical enough to be checked, ⭐ **write the check instead
of the row**, and let the row point at it.
