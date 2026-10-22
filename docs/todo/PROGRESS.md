# PROGRESS

⭐ **Read this first, every session.** [`INDEX.md`](INDEX.md) carries the list; this carries the order and the baseline.

⚠ **Rewritten every session. It carries no history.** That is [`../history/`](../history/README.md)'s job.

---

## Where the work is right now

[v0.2.8](https://github.com/pkgforge-dev/cross-libc-dlopen/releases/tag/v0.2.8) is
published.

| workflow | latest on `main` |
|---|---|
| `gates` | ✅ |
| `secret-sweep` | ✅ |
| `release` | ✅ on `v0.2.8` |

`v0.2.8` is the first release that carries the ppc64le resolver frame repair
(PR #60). Every earlier release, `v0.2.7` included, ships a `gl-fwd.so` whose
`glfwd_resolve_asm` saved r5 and r6 where the C callee writes its caller's LR
and TOC slots, so the first call of any GL entry point taking a third or fourth
integer argument was handed garbage. Issue #59 is the report; the gtk3-demo
ppc64le AppImage exits 139 under `v0.2.7` and stays alive under a build from
this commit.

---

## ⛔ The work order

### 1. `glfwd_try_vendor` accepts a matching filename without checking its class

`glfwd_try_soname` now skips a candidate of the other ELF class, and
`glfwd_try_vendor` does not. A host whose only vendor library is the wrong
class is therefore reported as having one. It is a different path, reached only
when the bundle carries a dispatcher, so it needs a bundled-dispatcher case to
measure. Nothing in this session's change touches it.

### 2. Wire `make gl-fwd-qemu-check` into a runner

The case that caught the ppc64le frame exists and fails on the old source, but
nothing runs it: `gates.yml` builds ppc64le and runs
`scripts/verify-artifacts.sh`, which never executes a trampoline. The target is
run by hand today. ⚠ This is issue #59's first loose end and it is the reason
that class of bug reached a release at all.

### 3. Close the release-shaped staleness the tracker already reported

Issue #46 named this file and T-18. Both are corrected here. ⚠ The same class
remains in [`../ground-truth.md`](../ground-truth.md), which still states the
evidence table as 22/22 (issue #45); that is the next document to check against
[`../report/08-test-results.md`](../report/08-test-results.md), which owns the
totals.

---

## ⚠ What a new session should distrust

- **The scheduled `appimage-suite` on `main` is red, and the failure is
  upstream's, not this tree's.** Both architectures fail at
  `experiments/41-extract.sh` with `no dispatcher slot in AppDir/lib.`: the
  `demo` release of `Anylinux-AppImages` no longer carries
  `cross-libc-dlopen.so` or `foreign-dlopen.so` in `lib/`. The extraction
  refuses rather than guessing, which is what it was built to do. Verify against
  the upstream asset before treating it as a defect here.
- **The release gate is not the wide suite.** `release.yml` runs the evidence
  table on x86_64 and aarch64 and then builds all five architectures. It does
  not run `run-appimage.sh`, so a green `v0.2.8` does not mean the AppImage
  suite is green.
- **`v0.2.8` was tagged on `main` at `900a393`, which is the PR #60 merge
  commit.** CI for that PR ran on the PR head commits, whose tree is
  `62985da`. The trees are identical; the commits are not. Do not read the
  merge commit's absence from the run list as "the tag was never tested".
- **`docs/todo/INDEX.md`'s counts were reconciled in this session** with T-18
  closed. `sh scripts/check-drift.sh` checks the rows against the entries and
  does not check the totals, so a future closure moves numbers no gate reads.
