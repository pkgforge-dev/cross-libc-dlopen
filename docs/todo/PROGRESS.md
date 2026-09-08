
# PROGRESS

⭐ **Read this first, every session.** It is the only file that carries a work
order. [`INDEX.md`](INDEX.md) carries the list; this carries the order and the
baseline.

⚠ **Rewritten every session. It carries no history.** That is
[`../history/`](../history/README.md)'s job.

---

## Where the work is right now

⭐ **[`v0.2.3` is published.](https://github.com/pkgforge-dev/cross-libc-dlopen/releases/tag/v0.2.3)**
66 assets: all six architectures (x86_64, aarch64, riscv64, ppc64, ppc64le,
loongarch64), loose objects plus `.tar`, `.zip` and `.sha256` for each, both
variants. Tagged on `34482c7`, built on the glibc 2.31 floor, body generated
from the manifests by `scripts/release-notes.sh`. The `release` workflow went
green end to end on the tag: run
[34025633281](https://github.com/pkgforge-dev/cross-libc-dlopen/actions/runs/34025633281).

| workflow | latest on `main` |
|---|---|
| `gates` | ✅ run [34025411777](https://github.com/pkgforge-dev/cross-libc-dlopen/actions/runs/34025411777) |
| `secret-sweep` | ✅ on `34482c7` |
| `release` | ✅ on `v0.2.3`, published |

**This branch changes what a release ships.** One variant, and no CET request
from any build. See the work below.

---

## ⛔ The work order

### 1. Ship one variant, and stop asking for CET

⭐ **This is the session's work, on branch `drop-portable-variant`.** Two
decisions, both the operator's:

- **The release ships the default build only.** The strict build (reads only
  `CROSS_LIBC_DLOPEN_ROOT`, never `APPDIR`) stays a build-time choice:
  `cd src && make portable`, measured by E87 and E88. quick-sharun sets
  `CROSS_LIBC_DLOPEN_ROOT` itself, so the strict assets had no consumer; the
  `APPDIR` fallback stays, because upstream's own AppImage relies on it and
  [`src/cld-env.h`](../../src/cld-env.h) has that argument in full.
- **No build asks for `-fcf-protection=full`.** Measured in
  [`../report/09-the-second-boundary.md`](../report/09-the-second-boundary.md)
  9.13: the flag adds six `endbr64` and cannot produce the IBT property note,
  so it does no protective work here. It stays askable with
  `make CET_CFLAGS=-fcf-protection=full`.

**The case that proves it.** E101 in `experiments/30-run-tests.sh` builds the
shim by the default recipe and again with the flag asked for, and requires the
default to come out strictly lighter:

- FAILS before, against the Makefile that still asked for the flag:
  `predictions matched: 63, mismatched: 1` with
  `E101 MISMATCH predicted=OK (exit 1, wanted OK)`; both arms tied.
- PASSES after: `E101 MATCH predicted=OK  fewer endbr64 than the flag arm:
  default 3472, asked for: 3478`, and the table is green end to end on
  x86-64. The suite total moves 63 to 64 and every one-home record moved with
  it: [`../report/`](../report/README.md) 01, 08, 09 and 10, the list in
  [`gates.yml`](../../.github/workflows/gates.yml), and the same list in
  `scripts/verify-gates.sh`. The aarch64 total and the four-skip list are in
  report 08, which is that number's home.

Measured locally besides the suite: `build.sh --arch x86_64` and
`--arch x86_64 --portable` both exit 0 with the right manifest variant, the
default build's `gl-fwd.so` carries 3472 `endbr64`, and both directories
package and generate a body.

### 2. What is still open

Nothing from this session. The open list is [`INDEX.md`](INDEX.md) and the
work order lives nowhere else.

---

## ⚠ What a new session should distrust

- **The aarch64 total on this branch is expected, not yet measured here.**
  This machine has no ARM silicon: it is the x86-64 total minus four named
  skips (E22, E23, E58 and now E101). The PR's CI run is the measurement.
- **`verify-gates.sh`'s one-home list claimed to be identical to
  `gates.yml`'s and was not** (53/53 50/50 against 63/63 60/60) until this
  branch aligned them. A comment that asserts sameness is a claim; diff it.
- **`skip E76` and `skip E76b` at the foot of `experiments/30-run-tests.sh`
  name a function that does not exist in that file.** On an x86-64 machine
  with neither qemu nor an aarch64 cross compiler those lines would fail with
  `skip: command not found` and leave E76 and E76b unscored rather than
  SKIPPED by name. CI never reaches that path (it installs both), so it has
  never been seen to fire. Named, not fixed: a change there belongs to its
  own decision.
- **A guard that has never been seen to refuse is a guard nobody knows
  works.** Three were found decorative or unarmed in earlier sessions and
  every one of them looked fine.
