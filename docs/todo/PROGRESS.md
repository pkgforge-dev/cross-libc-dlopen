# PROGRESS

⭐ **Read this first, every session.** [`INDEX.md`](INDEX.md) carries the list; this carries the order and the baseline.

⚠ **Rewritten every session. It carries no history.** That is [`../history/`](../history/README.md)'s job.

---

## Where the work is right now

[v0.2.9](https://github.com/pkgforge-dev/cross-libc-dlopen/releases/tag/v0.2.9) is
published.

| workflow | latest on `main` |
|---|---|
| `gates` | ✅ |
| `secret-sweep` | ✅ |
| `release` | ✅ on `v0.2.9` |

`v0.2.9` adds the three NixOS host directories: `/run/opengl-driver/lib` and
`/run/current-system/sw/lib` join the shim's fixed host list, the assembled
`--library-path`, and the libva `<dir>/dri` list. NixOS is neither FHS nor a
host that writes `/etc/ld.so.conf`, so before this each of the three failed
differently and silently.

⚠ **The three cases ran in the container; no NixOS host was behind them.** E104,
E105 and E106 create `/run/opengl-driver/lib`, which needs root, so the container
suite runs all three and reports MATCH, which is why the local total is higher
than the previous release's. Where `/run` is not writable each SKIPS by name
instead. ⛔ **Nothing in this tree has run the shims on a NixOS host.** The cases
prove the lists carry the directories and that a library placed there is found;
they do not prove the directories are where a real NixOS system puts its GPU
userspace, and
[`../report/10-measured-versus-assumed.md`](../report/10-measured-versus-assumed.md)
does not yet carry that distinction. Writing it there is open work, not a
citation.

The mechanism was also confirmed here as an A/B independent of the suite: the
fake-libva contract run against the `v0.2.8` source prints `NO-DRIVER`, and
against the shipped source prints `DRIVER=NIX`. The published binaries carry
the directory strings.

`v0.2.8` remains the first release carrying the ppc64le resolver frame repair
(PR #60). `v0.2.7` and earlier ship a `gl-fwd.so` whose `glfwd_resolve_asm`
saved r5 and r6 where the C callee writes its caller's LR and TOC slots, so the
first call of any GL entry point taking a third or fourth integer argument was
handed garbage. Issue #59 is the report.

---

## ⛔ The work order

### 1. `glfwd_try_vendor` accepts a matching filename without checking its class

`glfwd_try_soname` skips a candidate of the other ELF class, and
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

### 3. The stale totals in `docs/ground-truth.md`

It still states the evidence table as 22/22 (issue #45). The home for the
totals is [`../report/08-test-results.md`](../report/08-test-results.md), which
carries the current pair. This is the last document of the release-shaped
staleness class that issue #46 opened, and T-18 is closed.

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
  not run `run-appimage.sh`, so a green `v0.2.9` does not mean the AppImage
  suite is green.
- **The NixOS directories are a host class nobody has run.** The three cases
  prove the lists carry the directories and that a library placed there is
  found. No NixOS host has been behind the shims, and
  [`../report/10-measured-versus-assumed.md`](../report/10-measured-versus-assumed.md)
  is where that distinction belongs if it is not already written there.
- **A tag's tree, not its commit, is what CI tested.** `v0.2.8` and `v0.2.9`
  are both squashed commits, so their hashes appear in no run. Check
  `git rev-parse <tag>^{tree}` against the PR head's tree before concluding a
  tag went untested.
- **`docs/todo/INDEX.md`'s counts are checked by hand.** `sh scripts/check-drift.sh`
  reconciles the rows against the entries and does not check the totals, so a
  future closure moves numbers no gate reads.
