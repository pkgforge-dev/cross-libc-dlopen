# INDEX

Every entry, one line each, sorted by id.

⛔ **The work order is not here.** It is in [`PROGRESS.md`](PROGRESS.md) and
nowhere else. This file is a list, not an order and not a log.

---

## Counts

| | open | partially done | done | total |
|---|---|---|---|---|
| measurement | 5 | 1 | 0 | 6 |
| infrastructure | 7 | 0 | 2 | 9 |
| blocked | 7 | 0 | 2 reclassified | 9 |
| **total** | **19** | **1** | **2 done, 2 reclassified** | **24** |

By priority, across the open and partially-done rows:

| priority | count |
|---|---|
| high | 6 |
| medium | 7 |
| low | 0 |
| blocked (no priority -- a machine unblocks these, not a decision) | 7 |

---

## Entries

| id | title | category | priority | status |
|---|---|---|---|---|
| T-01 | [Static and mostly-static binaries: which of the three actually work](measurement.md) | measurement | high | open |
| T-02 | [`libepoxy.so.0`, and the eight loaders behind it](measurement.md) | measurement | high | open |
| T-03 | [A second consumer, measured end to end](measurement.md) | measurement | high | partially done |
| T-04 | [Two struct sizes where this project and solo disagree](measurement.md) | measurement | medium | open |
| T-05 | [NixOS as a host class](measurement.md) | measurement | medium | open |
| T-06 | [Translate the two live struct hazards at the call](measurement.md) | measurement | high | open |
| T-10 | [Prove every CI gate can fail](infrastructure.md) | infrastructure | high | open |
| T-11 | [A machine-readable suite result](infrastructure.md) | infrastructure | medium | open |
| T-12 | [Measure the stage timeouts on a runner before trusting them](infrastructure.md) | infrastructure | medium | open |
| T-13 | [A build error hidden by `2>/dev/null` cost a debugging cycle](infrastructure.md) | infrastructure | medium | done |
| T-14 | [Four files that no runner runs](infrastructure.md) | infrastructure | low | done |
| T-15 | [A corpus test with a fresh process per library](infrastructure.md) | infrastructure | medium | open |
| T-16 | [Delete the path that would mask the failure](infrastructure.md) | infrastructure | medium | open |
| T-17 | [The IBT property note is documented and is not there](infrastructure.md) | infrastructure | medium | open |
| T-18 | [There is no release](infrastructure.md) | infrastructure | high | open |
| B-01…B-09 | [the blocked list](blocked.md) -- nine rows. ⚠ **Two of them are not blocked**; the correction is at the foot of that file and the work is T-02 and T-06 | blocked | -- | 7 open, 2 reclassified |

---

## What a category means

| category | the deliverable |
|---|---|
| **measurement** | a number that does not exist yet, and the command that produced it |
| **infrastructure** | build, CI or orchestration. Never a change to `experiments/*.sh`'s assertions |
| **blocked** | ⛔ blocked by hardware, by what a distribution ships, or by a rule in [`RULES.md`](RULES.md). **Nothing on that list is merely unwritten.** If you have a machine that unblocks a row, that row is the work |

⚠ **Closing an entry moves several numbers**: the counts table above, the
priority table, the entry's own status line, and the record in `PROGRESS.md`.
They are checked by hand today; making that mechanical is worth more than the
edit that fixes them once.
