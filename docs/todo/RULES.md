# How an entry here is worked and closed

⛔ **This file owns one thing: the life of an entry in this directory.** How the
code is written, how a document is written, and what may be pushed are owned by
[`../conventions/`](../conventions/README.md), and this page does not
restate them.

⚠ It used to restate them, at length. Three of its sections were near-verbatim
copies of [`../conventions/git.md`](../conventions/git.md), and a
reader had no way to tell which copy was authoritative when the two drifted.
The implementation invariants it carried now live in
[`../conventions/code.md`](../conventions/code.md), beside the rest of
what governs `src/`.

| what you need | where it lives |
|---|---|
| the invariants a change to `src/` must not break | [`code.md`](../conventions/code.md) |
| attribution, branches, pushing, the tracker | [`git.md`](../conventions/git.md) |
| how a document is written | [`prose.md`](../conventions/prose.md) |
| which documents exist and what each owns | [`docs.md`](../conventions/docs.md) |
| mistakes that shipped, each with what it caused | [`forbidden-patterns.md`](../conventions/forbidden-patterns.md) |

---

## What an entry is

An entry states a problem, what is already measured about it, what would close
it, and the command that proves it closed. It is not a task list and it is not
a plan.

⭐ **The work order is [`PROGRESS.md`](PROGRESS.md) and nowhere else.**
[`INDEX.md`](INDEX.md) is a list, not an order.

---

## An entry closes in place

⛔ **The closure is written where the entry is written**, with the command that
proves it and the output that command produced. Not in a summary, not in
`PROGRESS.md`, and not in a commit message alone.

⛔ **A premise a measurement disproves keeps its title and gets the correction
written underneath it.** Never a silent edit: the title is how the entry has
been referred to everywhere else.

---

## Before a session ends

1. **Both suites green, with their skips named.**
   `sh scripts/run-evidence.sh` and `sh scripts/run-appimage.sh`. The expected
   totals are in [`../report/08-test-results.md`](../report/08-test-results.md) section 8.
2. **Write the closure where the entry is**, per the rule above.
3. **Rewrite [`PROGRESS.md`](PROGRESS.md)** so the next reader does not redo
   what you did. ⭐ It is the only file written FOR the next session rather than
   about this one. What is worth spending words on is not what you built: it is
   which of your assumptions turned out to be wrong, and what you would look at
   first if you had the session again.
4. **Update [`INDEX.md`](INDEX.md)'s counts.** Closing one entry moves several
   numbers, and `sh scripts/check-drift.sh` reconciles the two.
5. **Check nothing now says something wrongly.** ⚠ If you changed a headline
   count, it lives in one file by design: `git grep` for it and confirm it
   still does.
6. **Two deep reviews**, asking different questions.
   [`../conventions/README.md`](../conventions/README.md) has what
   each pass must state before it runs and report after.
