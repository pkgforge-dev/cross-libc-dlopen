# prose.md

How documents are written here. The mechanical half is checked by CI; the rest
is a reading.

---

## The rule

Short sentences, each with a subject and a verb. No dashes as punctuation, in
any spelling. ASCII only, apart from the five markers below. No marketing
adjectives. Present tense. Every claim backed by a command a reader can run or
a path a reader can open.

⛔ **A rule is a complete sentence.** Not a fragment, not a slogan, not a noun
phrase standing in for an instruction. `Generated files: never edited` is a
label; `Generated files are regenerated and never edited by hand` is a rule,
and only the second one tells a reader what to do. Where a rule exists because
something went wrong, it says what went wrong in a sentence that can be
checked.

---

## Dashes, and why `--` is not the fix

⛔ **No dash as punctuation, in any spelling.** Not an em dash, not ` -- `, not
` - ` between two words. ⛔ **And `--` is not what replaces an em dash.**
Substituting one dash for another keeps the sentence that wanted a dash and
makes it read worse:
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

⚠ **The check is section 4 of `scripts/check-drift.sh`**, which CI runs on
every push. It refuses. It carries no budget, no pin and no tolerance, and it
does not pass because a count fell: it was a ratchet once, and
[`../REPORT.md`](../REPORT.md) 9.14 records the ratchet drifting eight under
the tree and then admitting a planted dash.

It covers Markdown prose, C comments, and shell, YAML, Python and Makefile
comments, and it counts a dash that wraps at the end of a line. Four shapes are
not punctuation and are permitted: a fenced block or a code span, an
end-of-options separator such as `cd --`, a command synopsis such as
`NAME -- CMD [ARGS...]`, and a banner line such as `# ----- name --`.

⚠ **Prose a program prints is out of scope**, and the check says so in its own
comments rather than reporting a coverage it does not have. Two reasons, both
local: five occurrences sit on `verdict` lines that
[`code.md`](code.md) forbids tidying, and `src/gl-fwd.c` emits a string whose
spelling [`../diagnostics.md`](../diagnostics.md) documents as the debug line a
reader greps for.

`HISTORY/` is excluded because it records original wording.

⛔ **A specimen is not a violation.** A dash inside a code span is being named
rather than used, which is what makes this page writable: a rule that banned
its own subject could not show what it bans, and
[`../../scripts/verify-gates.sh`](../../scripts/verify-gates.sh) could not
record the planted case that proves the check fires. That exemption is itself
proven on every run, because an exemption nobody checks is one that can stop
applying in silence.

Write for an agent with no memory of the session that wrote the file, and for a
person looking for one fact.

---

## ASCII, and the five markers

⛔ **Every file this repository authors is ASCII**, with exactly five
exceptions: ⛔ ⭐ ⚠ ✅ ❌ and no others.

A glyph outside that set is one a reader cannot type, cannot grep for, and may
not see rendered the way its author saw it. Once one carries meaning in a rule
or a table, the rule is unreadable to somebody. Each has an ASCII spelling:

| removed | what replaces it |
|---|---|
| a middle dot separating items | a comma, or a line break where the list is a sequence of steps |
| a section sign | the word `section` |
| a greater-or-equal sign | `>=` |
| an ellipsis spanning a range | the word `to`, as in `B-01 to B-09` |
| an ellipsis trailing a sentence | three full stops, or a rewrite that does not trail off |
| an em dash | one of the four rewrites above |
| a box-drawing character | `+`, `-` and `|`, inside a fenced block |
| an arrow glyph | `->` |
| a tick or cross other than the two below | ✅ and ❌, which are the state-table markers |

⛔ **A character being NAMED rather than used belongs in a code span**, which is
how the table above is written at all.

⚠ **The check is [`../../scripts/check-charset.sh`](../../scripts/check-charset.sh)**,
and it takes its file list from version control. A file this repository does
not track is a file it does not author, so it is not scanned and does not need
naming in the check. A hardcoded list of directories to skip drifts from what
is tracked, and each stale entry then reads as a rule about a path that may
not exist.

---

## What each marker means

| marker | meaning |
|---|---|
| ⛔ | a rule that has already been broken, or one whose violation is unrecoverable. A hard stop |
| ⭐ | reach for this first. The highest-value item on the page |
| ⚠ | a trap. It works until it does not, and the failure is quiet |
| ✅ | a state that IS so, in a table of states |
| ❌ | a state that is NOT so, in the same table |

⛔ **The tick and the cross are for a STATE TABLE and nothing else.** They say
what a row is, not what a reader should do, which is the whole difference
between them and the three above. ⚠ A tick in running prose is a decoration
and the first three are not: it reads as approval of a sentence, which is not
a state anybody can check.

⛔ **They do not stack.** No `⛔⛔`. Once a page has three levels of stop, a
reader has to weigh them, and weighing is what a marker exists to prevent.

⭐ **Use them sparingly enough that they are still visible.** A page where every
paragraph carries one has no markers at all.

⚠ The check enforces this, and enforcing the tick and cross needed a local
divergence. The template's `check-docs.sh` hardcodes three markers, and it is
in a repository this one does not write to, so
[`../../.github/workflows/gates.yml`](../../.github/workflows/gates.yml)
widens the allowlist in the copy it fetches and asserts that the patch
applied. An arrow glyph written instead of `->` still fails, which is what
that check was catching here before.

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
underneath. The title is how the item has been referred to everywhere else.
That is a different operation from a stacked banner: the
correction states what was measured, when, and with what command.

---

## Say what is not true

⛔ **Never a fabricated number.** When the real value is unknown, write a dash
or the word UNVERIFIED. A wrong number is worse than no number, because a blank
gets checked and a number gets used.

⚠ **A measurement carries its conditions or it is not a measurement.** A rate
with no host, no date and no sample size cannot be compared to anything.

⭐ **A SKIP names a missing capability and stops there.** It may say "this host
has no X". It may **not** say "and therefore nothing can be done". That is a
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
2. No angle-bracket placeholders inside a shell block: bash reads
   `<appdir>` as a redirect. Use `"$APPDIR"`.
3. No literal control bytes.
4. Every relative link resolves and every cited path exists.
5. No em dash, no emoji outside the three, none of the banned vocabulary.
6. No page under `docs/` that nothing links to.

⛔ **What no check can do is decide whether a claim is true.** That is a
reading, and it belongs to the review pass.
