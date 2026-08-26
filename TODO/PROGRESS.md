# PROGRESS

⭐ **Read this first, every session.** It is the only file that carries a work
order. [`INDEX.md`](INDEX.md) carries the list; this carries the order and the
baseline.

⚠ **Rewritten every session. It carries no history** -- that is
[`../HISTORY/`](../HISTORY/README.md)'s job.

---

## The measured baseline

Everything below was green at the time this file was written. ⛔ **If a number
here disagrees with [`../docs/REPORT.md`](../docs/REPORT.md), REPORT is right
and this file is stale** -- one fact, one home.

| suite | command | state |
|---|---|---|
| evidence table | `sh scripts/run-evidence.sh` | exit 0, every prediction held |
| AppImage, all five stages | `sh scripts/run-appimage.sh` | exit 0, every prediction held, skips all named |
| standalone, no AppDir | `sh examples/plain-preload/run.sh` | before FAILS, after succeeds, feature-off control FAILS |

⛔ **The totals are deliberately not repeated here.** They live in
[`../docs/REPORT.md`](../docs/REPORT.md) §8, with the host each one came from.
A count in two files agrees on the day it is written and disagrees within a
month, and a reader has no way to tell which is stale.

Measured on the machine described in
[`../docs/environment.md`](../docs/environment.md). ⚠ **Every one of those
numbers came from that one machine.** CI has never run.

---

## What the last session did

Ported the repository from a measured experiment to a project: new owner, new
name, one identifier prefix, portable build scripts, CI on two architectures, a
docs tree, a standalone example, and this work record. Both suites were re-run
before and after and their totals are unchanged.

Two regressions were introduced during the port and both were caught by the
suites and fixed before the commit: a new header missing from three copy lists,
and a handshake fallback referencing the wrong variable.

One claim in this repository was **corrected** rather than carried over: the
prior-art description of `pg83/solo`'s CI, which had been written from reading
rather than from checking. See [`../docs/REPORT.md`](../docs/REPORT.md) §11 and
[`../HISTORY/references/solo-findings.md`](../HISTORY/references/solo-findings.md).

---

## ⛔ The work order

Do these in this order. The reason for the order is under each one, because an
order with no argument behind it is somebody's preference.

### 1. T-18 -- a release, built on the floor, for both architectures

**First, because everything this repository produces is currently unreachable
to anyone who will not build it themselves.** It is also the item that forces
the two things after it: a release cannot publish without CI running the
suites, and CI cannot be trusted to gate a release until its gates have been
seen to refuse.

⚠ **The aarch64 half has never been built anywhere.** The cross-build path is a
property of `scripts/build.sh`'s code and not of any artefact that exists.

### 2. T-10 -- prove every CI gate can fail

**Second, and it is what makes the first one mean anything.** A release gated
on a green suite is worth exactly as much as the gate. `sh scripts/verify-gates.sh`
already proves seven of them locally and names what it cannot reach; the rest
need a runner.

⭐ Three gates written during the port were defective and two of them refused
every build. All three were found by running them against a clean tree as well
as a planted defect. Do both halves.

### 3. T-12 -- measure the stage timeouts on a runner

**Third, because a timeout is scored as a FAILURE, not a skip.** Until this is
measured, the first genuinely red CI run cannot be told apart from a slow
runner. ⛔ Raise rather than shorten.

### 4. The easy wins, in any order

T-13 (a build error hidden by `2>/dev/null`), T-14 (the two Python tools that
nothing runs), T-16's cheaper half (assert the frame by hash, not one pixel),
T-11 (a machine-readable suite result). None is blocked and none needs
hardware this project does not have.

### 5. T-06 -- translate the two live struct hazards at the call

**Then this, because it closes a documented limit and the mechanism is already
written down** at file and line in
[`../HISTORY/references/solo-usable.md`](../HISTORY/references/solo-usable.md)
§1. Sharp acceptance: E50 goes from `2 live hazard(s)` to 0 while E47 and E49
still pass.

### 6. T-02 -- `libepoxy.so.0`

**The cheapest lead in the tree**, and it is a *dispatcher* -- the class of
failure that took a whole session to see the first time. ⛔ Do not assume it is
benign because GTK4 rendered.

### 7. T-03 -- a second consumer, with a real driver on the far end

**This is what allows the README's opening sentence to widen.** Today it is
about AppImages, which is what every measured result is about.
[`../examples/plain-preload/`](../examples/plain-preload/) is the shape and it
works; what it lacks is a host GPU driver rather than a stand-in.
⚠ Build it, measure it, *then* rewrite the sentence. In that order.

Then T-01, T-04, T-05, T-15, T-17 as they come. T-17 in particular is bounded
and its approach is written: emit the note from `src/gl-fwd.c` rather than
raising the glibc floor to get one.

---

## In progress

Nothing. The port session ended cleanly.

---

## ⚠ What a new session should distrust

- **CI has never run.** The workflows are written and reasoned about; no run
  exists. T-10 is first for that reason.
- **Every number in the baseline is from one machine.** An aarch64 result, a
  NixOS result and a real-DRM result do not exist anywhere in this repository.
- **`scripts/run-appimage.sh`'s aarch64 path is untested.** The per-architecture
  sha256 pins were computed from the real assets, and the loader name and musl
  soname now derive from `uname -m`, but no aarch64 run of that suite has
  happened.
