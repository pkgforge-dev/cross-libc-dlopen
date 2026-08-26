# docs

| file | what it answers |
|---|---|
| [`overview.md`](overview.md) | **the two gaps**, and the failure message each one actually gives you. Start here |
| [`building.md`](building.md) | how to build, and the floor rule that everything else follows from |
| [`integrating.md`](integrating.md) | how to wire it into an AppImage, a plain binary, or a packer |
| [`diagnostics.md`](diagnostics.md) | it did not work -- which layer? A rung-by-rung procedure |
| [`traps.md`](traps.md) | things that cost somebody a day, for a *user* of this |
| [`limits.md`](limits.md) | what it cannot do, with the measurement behind each |
| [`reproducing.md`](reproducing.md) | how to re-run every number here yourself |
| [`environment.md`](environment.md) | the machine the numbers were measured on |
| [`REPORT.md`](REPORT.md) | ⭐ **the measured record.** Every count and every suite total lives here and nowhere else |
| [`ground-truth.md`](ground-truth.md) | a measured survey of where distributions actually keep their libraries |
| [`rejected-designs.md`](rejected-designs.md) | three designs evaluated and refused, with evidence -- including one refused *after* it arrived as a pull request |
| [`AGENTS.md`](AGENTS.md) | the single entry point for an agent working on this repository |
| [`HUMANS.md`](HUMANS.md) | ⭐ the other side of it: what a **person** pastes to get useful work out of a session, scenario by scenario |
| [`conventions/`](conventions/README.md) | ⛔ how this repository is written, rule by rule. Binding, and half of it is checked by CI |

Not here:

- [`../HISTORY/`](../HISTORY/README.md) -- why things are the way they are, and
  every past mistake in its original wording. Not on the front page, not
  deleted.
- [`../TODO/`](../TODO/INDEX.md) -- what is open. The work order is in
  `TODO/PROGRESS.md` and nowhere else.

---

⭐ **One fact, one home.** No measured number appears in two of these files. The
counts and the totals are in [`REPORT.md`](REPORT.md); everything else points at
it. Two copies agree on the day they are written and disagree within a month,
and a reader has no way to tell which one is stale.
