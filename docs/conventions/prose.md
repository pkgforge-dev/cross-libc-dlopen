# prose.md

How documents are written here. The mechanical half is checked by CI; the rest
is a reading.

---

## The rule

Short sentences. No dashes as punctuation, in either spelling. No marketing
adjectives. No emoji beyond the three below. Present tense. Every claim backed
by a command a reader can run or a path a reader can open.

---

## Dashes, and why `--` is not the fix

⛔ **No em dash.** ⛔ **And `--` is not what replaces it.** Substituting one
dash for another keeps the sentence that wanted a dash and makes it read worse:
a reader meets what looks like a subtraction in the middle of a clause, and
`--` is also how every command-line flag in this repository begins, so the page
now has two meanings for one token.

⭐ **Rewrite the sentence.** A dash is doing one of four jobs, and each has a
mark that is not a dash:

| what the dash was doing | what to use instead |
|---|---|
| joining two independent clauses | a full stop. Two sentences are almost always better |
| introducing an explanation, a list or a consequence | a colon |
| wrapping an aside | a pair of commas, or parentheses |
| trailing an afterthought | delete it, or promote it to its own sentence |

⚠ **`--` as itself is fine and is not what this is about.** A flag
(`--library-path`), a literal inside a code block, a shell comment, and a
horizontal rule are all `--` or `---` doing their own job. The rule is about
prose.

⚠ The ratchet is `sh scripts/check-prose-dashes.sh`, and it is a ratchet rather
than a gate: the count may fall and may not rise. The tree it was written
against still carries several hundred, `HISTORY/` is excluded because it
records original wording, and a single change that rewrote them all would be a
change nobody could review.

Write for an agent with no memory of the session that wrote the file, and for a
person looking for one fact.

---

## The three markers, and nothing else

⛔ ⭐ ⚠ and no others.

| marker | meaning |
|---|---|
| ⛔ | a rule that has already been broken, or one whose violation is unrecoverable. A hard stop |
| ⭐ | reach for this first. The highest-value item on the page |
| ⚠ | a trap. It works until it does not, and the failure is quiet |

⛔ **They do not stack.** No `⛔⛔`. Once a page has three levels of stop, a
reader has to weigh them, and weighing is what a marker exists to prevent.

⭐ **Use them sparingly enough that they are still visible.** A page where every
paragraph carries one has no markers at all.

⚠ The check enforces this. A `✅` in a table, or a `->` written as an arrow
glyph, fails it -- both were found in this repository and both were removed.

---

## Amend in place. Do not stack banners

⛔ **When a rule changes, rewrite the rule.** Do not append a dated box under
the old text saying the text above is retired. An agent reads the first
paragraph, stops, and acts on the retired rule.

1. Rewrite the rule to what it is now. The current text is the only text.
2. Move the superseded wording to [`../../HISTORY/`](../../HISTORY/README.md).
3. Link to it once, from the rule, in a sentence.

⚠ This is not licence to delete. A superseded rule is moved, never dropped.

⭐ **The one exception is a measured correction inside the record.**
[`../REPORT.md`](../REPORT.md) is a measured record, and a premise a later
measurement disproves keeps its title and gets the correction written
underneath -- because the title is how the item has been referred to
everywhere else. That is a different operation from a stacked banner: the
correction states what was measured, when, and with what command.

---

## Say what is not true

⛔ **Never a fabricated number.** When the real value is unknown, write a dash
or the word UNVERIFIED. A wrong number is worse than no number, because a blank
gets checked and a number gets used.

⚠ **A measurement carries its conditions or it is not a measurement.** A rate
with no host, no date and no sample size cannot be compared to anything.

⭐ **A SKIP names a missing capability and stops there.** It may say "this host
has no X". It may **not** say "and therefore nothing can be done" -- that is a
claim about the design space, it needs its own evidence, and welded to a
measured fact it inherits the measured fact's authority. One such sentence kept
OpenGL broken on every musl distribution for an entire session
([`../../HISTORY/traps.md`](../../HISTORY/traps.md)).

---

## One fact, one home

Every measured number lives in exactly one document.
[`../REPORT.md`](../REPORT.md) is that home for every count and every suite
total; everything else points at it.

⛔ **A value in two documents with no check between them drifts**, and the copy
a reader trusts is the wrong one. The gate is the `every headline number has
exactly one home` step in
[`../../.github/workflows/gates.yml`](../../.github/workflows/gates.yml).

⚠ `HISTORY/` is excluded from that gate on purpose. It records what was true
when it was written and says so at the top of every file.

---

## What a document is not

**A document says what the thing does. It does not say what the project did.**

⛔ Correction logs, audit trails and "this used to say" notes do not go on a
reference page or in `README.md`. They go in `HISTORY/`, or in the commit
message, or in a measured correction inside `REPORT.md` where the record is the
point.

⚠ An unlinked page is not read, so it is not corrected. A page nothing links to
is a finding.

---

## Banned vocabulary

> seamless, blazing, effortless, robust, powerful, cutting-edge,
> state-of-the-art, world-class, elegant, simply, just, obviously, of course,
> revolutionary, game-changing, rock-solid, bulletproof, lightning-fast

⚠ "Simply" and "just" do the real damage: they tell a reader who is stuck that
the thing they cannot do is easy. Replace the adjective with the measurement,
or delete it.

---

## Defensive framing is not neutral

⛔ **Describe what the code does in plain technical terms.** No up-front
disclaimers arguing that something is legitimate, and no telling a future
reader not to re-open a question. A defensive paragraph primes a sceptical
reader to look for the thing it denies.

---

## The mechanical half

Checked by `check-docs` in CI:

1. Every fenced shell block parses.
2. No angle-bracket placeholders inside a shell block -- bash reads
   `<appdir>` as a redirect. Use `"$APPDIR"`.
3. No literal control bytes.
4. Every relative link resolves and every cited path exists.
5. No em dash, no emoji outside the three, none of the banned vocabulary.
6. No page under `docs/` that nothing links to.

⛔ **What no check can do is decide whether a claim is true.** That is a
reading, and it belongs to the review pass.
