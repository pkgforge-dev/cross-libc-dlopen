# HISTORY

Why things are the way they are.

⭐ **This is not filler and it is not deleted.** Several of these paragraphs are
the only record of why a design has the shape it does, and one of them is the
reason a whole class of bug was found. What they are not is front-page material:
a reader who wants to *use* this project should not have to read about a
mistake somebody made to get to the instructions.

⛔ **Moved, not summarised.** Every file here carries its original wording. A
trap recorded in one sentence is a trap the next person does not walk into, and
several `experiments/*.sh` lines look odd for reasons written down only here.

| file | what it holds |
|---|---|
| [`traps.md`](traps.md) | things that cost somebody real time, each paid for once already -- including how a whole gap hid for a session |
| [`closures.md`](closures.md) | eight named limits; seven closed, each with the command that proves it and the output it produced |
| [`the-blocker.md`](the-blocker.md) | the defect that held everything up, and why the first two guesses about it were wrong |
| [`handover.md`](handover.md) | the narrative from the end of the measurement phase |
| [`references/`](references/) | sweeps of other projects: what was read, at which commit, what transfers and what does not |

Not here:

- [`../docs/`](../docs/AGENTS.md) -- what the project does and how to use it.
  The map of every page is in [`../README.md`](../README.md).
- [`../TODO/`](../TODO/INDEX.md) -- what is still open. The work order is in
  `TODO/PROGRESS.md` and nowhere else.

---

⚠ **A document here reflects what was true when it was written.** Where a
premise later turned out to be wrong, the correction is written underneath and
the original keeps its wording -- because the original is how the item has always
been referred to, and a silently edited premise is a record of nothing.
