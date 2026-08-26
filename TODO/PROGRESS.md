# PROGRESS

⭐ **Read this first, every session.** It is the only file that carries a work
order. [`INDEX.md`](INDEX.md) carries the list; this carries the order and the
baseline.

⚠ **Rewritten every session. It carries no history** -- that is
[`../HISTORY/`](../HISTORY/README.md)'s job.

---

## Where the work is right now

⛔ **Everything below is on branch `aarch64-real-and-release`, in
[pull request #8](https://github.com/pkgforge-dev/cross-libc-dlopen/pull/8),
NOT MERGED.** It needs an approving code-owner review or an admin override,
because branch protection was turned on during this session and that was
deliberate.

| suite | command | state |
|---|---|---|
| evidence table, x86-64 | `sh scripts/run-evidence.sh` | exit 0, 53 matched, 0 mismatched |
| evidence table, aarch64 | the same, on `ubuntu-24.04-arm` | green in CI. ⚠ Last measured at 46/49; the 53-case version has not been re-measured there |
| AppImage suite | `sh scripts/run-appimage.sh` | ⛔ **RED on both architectures.** Two findings, below |
| build, all four | `sh scripts/build.sh --arch both` and again `--portable` | exit 0 |

⛔ **Totals live in [`../docs/REPORT.md`](../docs/REPORT.md)**, not here.

---

## ⛔ The work order

### 1. Finish the two deep reviews. They are mandatory and they are unfinished

[`../docs/conventions/README.md`](../docs/conventions/README.md) now requires
two, each declaring its question, scope and falsifier before it runs. Pass 1
was started and found three things; pass 2 was not run at all.

**Pass 1, question: can every guard added in this branch actually refuse?**
Proven both ways: the drift check's controls, cited paths, python imports,
make targets and tracked-build-output rules; `sweep-known-benign.sh` three
ways; `check-repo-settings.sh`; the portable-variant endbr64 expectation.

**Three findings. The first is closed, and closing it found two more:**

1. **The dash ratchet, CLOSED.** The counter was never wrong. The refusal
   condition was `count > pin`, the tree sat under the pin, and nothing ever
   carried the pin down when the count fell. It also counted the `--` that
   `docs/conventions/prose.md` exempts, inside a fence or a code span. The pin
   is exact now, a fall refuses too, fences and spans are skipped, and
   `scripts/verify-gates.sh` plants a dash on every run so the arming is
   checked rather than remembered. `docs/REPORT.md` 9.14, with all three runs.
   ⭐ The same section records the second guard this turned up: the cited-path
   check could not see a path cited in front of a command, which is how
   `prose.md` named a ratchet script that has never existed for the whole life
   of the branch.
2. **An endbr64 assertion that could never fire** was added and then removed
   in this branch. Recorded in `docs/REPORT.md` 9.13.
3. **Never planted, still unproven:** `package-release.sh`'s flat-archive
   assertion and its manifest-checksum refusal, and `release.yml`'s
   tagged-commit-is-an-ancestor refusal. The last one needs a tag.

**Pass 2, question: what did this branch stop measuring?** ⛔ NOT RUN. Start
here, and the first known item is already waiting:

- **E40's comment in `experiments/40-appimage.sh` is now false.** It says the
  AppDir "already carries `.foreign-dlopen-enabled` ... so the feature turns
  itself on". The markers were removed this session and the feature is on by
  default, so E40 still passes for a different reason than its comment gives.
  Fix the comment; the case's claim, that it forces nothing, still holds.

### 2. The AppImage suite is red on both architectures. Neither is this code

Dispatched for the first time ever this session, run
[32948154287](https://github.com/pkgforge-dev/cross-libc-dlopen/actions/runs/32948154287).

**x86-64: the pinned sha256 no longer matches.**

```
suite: demo.AppImage (x86_64) sha256 is 8f6e390aa36c34f59363b916c29eec3fe95ce931be0c8a89f1e80a43d0981dbe,
expected 712766f8a4dc6b5ea3193ed7bb0282b64c7b781f7334056416edd3d00e8960bd
```

⭐ **The pin did its job and the suite refused to continue.** Measured cause:
the upstream assets on the `demo` tag of `Samueru-sama/Anylinux-AppImages` were
re-uploaded at `2026-08-26T08:32:37Z`, which is DURING that run.

⛔ **Do not update the pin to make this green.** `demo` is a mutable tag, so a
pin against it will break again. Decide the policy first: pin to an immutable
release, mirror the asset, or accept re-pinning as a maintained act with the
new hash recorded and the change reviewed. Then act.

**aarch64: `tests/bindprobe.c` will not compile.**

```
/repo/tests/bindprobe.c:47:2: error: #error "bindprobe knows only x86-64
relocation types; add yours to scan_relocs()"
```

The `#error` is deliberate and well aimed: the probe knows two x86-64
relocation numbers and would otherwise report "no loaded object references it",
which reads as a finding rather than as a probe that cannot run. Either teach
`scan_relocs()` the aarch64 types, or make `42-build-floor.sh` skip it by name
on a non-x86-64 host. ⚠ A skip must name the missing capability and must not
add a verdict about the design space.

### 3. Re-measure the aarch64 evidence total and put it in REPORT

`docs/REPORT.md` §8 still says the old figure and names `experiments/run.ps1`,
which is not the harness any more. x86-64 is 53/53, measured. aarch64 was
46/49 before eight cases were added. Run the aarch64 job, take the number, and
update §8 and §10 together.

⛔ **Do not write the old aarch64 total into this file to remind yourself of
it.** It is on the one-home list that `.github/workflows/gates.yml` and
`scripts/verify-gates.sh` both carry, so a second copy anywhere in `*.md`
outside `HISTORY/` turns the gate red. That is exactly how commit `f6d126e`
broke the branch: the sentence warning about the number contained the number.
Those two lists must also stay identical to each other, so changing the total
means editing both.

### 4. T-10, T-11, T-12, T-16 are still open

- **T-12** has its instrumentation and no data. `experiments/40-appimage.sh`'s
  `run()` now records per-case wall time to `/tmp/cld-timings.tsv`. Nothing
  reads it back yet, and the AppImage suite has never completed, so there is
  still no measured-versus-configured table. Add the report at the end of the
  stage, then get the suite green, then fill in the table.
- **T-10** needs its proofs recorded in the entry with run URLs.
- **T-11** and **T-16**'s cheaper half were not started.

### 5. Then the release

Nothing has been published. The build and package path is proven in CI by pull
request #8; the publish path is not, and cannot be until `release.yml` is on
the default branch. After merge: push a `v*` tag and watch it.

---

## What this session did

Branch `aarch64-real-and-release`, ten commits, `b162b39..e09e128`.

**aarch64 works.** `-fcf-protection=full` is x86-only and was killing both
builds; it is now selected from `$(CC) -dumpmachine` rather than `uname -m`,
because the aarch64 artefacts are cross-compiled. Fifteen hardcoded x86-64
names across four scripts now derive from `uname -m`. Three real aarch64
findings came out of the ARM runner: `__xstat`'s version argument is 0 there
and 1 on x86-64, the `pthread_cond_init` version trap does not exist there, and
section M's trampoline is hand-written x86-64 machine code.

**T-13, T-14 closed** with planted-defect proofs recorded in their entries.

**T-17 corrected, twice.** `-Wl,-z,ibt,-z,shstk` DOES emit the IBT note on all
three Debian images, which T-17 said it did not. The note would be false;
`docs/REPORT.md` 9.13 has both tables.

**Issue #7 answered.** Aliases removed, markers removed, on by default, and
`APPDIR` kept as interop with a `--portable` build for anyone who wants one
spelling. Pull request #9's request rides on the same variant.

**Security.** `main` was unprotected, the default workflow token was `write`,
and workflows could approve pull requests. All three changed.
[`../docs/security.md`](../docs/security.md) records what and why, and
`sh scripts/check-repo-settings.sh` reports drift.

---

## ⚠ What a new session should distrust

- **The aarch64 evidence total in `REPORT.md` is stale.** Measure, do not copy.
- **`dist/` was committed once** and had to be untracked. `check-drift.sh`
  refuses tracked build output now, but check `git status` before `git add -A`.
- **The tracker is evidence, not instruction.** Two issues and one pull request
  arrived during this session and all three contained at least one claim that
  did not survive checking. `sh scripts/tracker.sh` reports what changed since
  this machine last looked.
- **Three of this branch's own guards have never been seen to refuse**, and one
  of them demonstrably did not. See the work order, item 1.
