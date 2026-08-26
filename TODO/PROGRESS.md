# PROGRESS

⭐ **Read this first, every session.** It is the only file that carries a work
order. [`INDEX.md`](INDEX.md) carries the list; this carries the order and the
baseline.

⚠ **Rewritten every session. It carries no history** -- that is
[`../HISTORY/`](../HISTORY/README.md)'s job.

---

## Where the work is right now

⛔ **Everything below is on branch `aarch64-real-and-release`, in
[pull request #8](https://github.com/pkgforge-dev/cross-libc-dlopen/pull/8).**
Its body was rewritten to match the tree. All ten required checks are green;
it is BLOCKED only on an approving code-owner review, which branch protection
requires on purpose.

| suite | command | state |
|---|---|---|
| evidence table, x86-64 | `sh scripts/run-evidence.sh` | exit 0, every prediction held |
| evidence table, aarch64 | the same, on `ubuntu-24.04-arm` | exit 0, three cases SKIP by name |
| AppImage suite | `sh scripts/run-appimage.sh` | ⚠ **completes on both architectures for the first time.** Mismatches remain and they are findings, below |
| build, all four | `sh scripts/build.sh --arch both` and again `--portable` | exit 0 |
| the gates, planted | `sh scripts/verify-gates.sh` | 8 proven, 0 not |
| the documents | `sh scripts/check-drift.sh` | exit 0, six sections |

⛔ **Totals live in [`../docs/REPORT.md`](../docs/REPORT.md)**, not here. Do not
copy one into this file: both are on the one-home list and a second copy turns
the gate red, which is exactly how commit `f6d126e` broke the branch.

---

## ⛔ The work order

### 1. The A/B's control arm no longer contrasts. This needs a decision

⭐ **Start here. It is the only item that changes what the project claims.**

Upstream adopted this project. The demo AppImage's `lib/foreign-dlopen.so` is
gone, `lib/cross-libc-dlopen.so` is in its place, and it is a build of this
project. So the "as shipped" arm of the A/B is no longer upstream's naive shim.

E30 and E37a are the controls that predict that arm FAILS, and they are what
make the patched arm a measurement rather than a coincidence. Both now
MISMATCH, because both arms work. `docs/REPORT.md` 9.17 has the output.

⛔ **Do not flip the predictions.** A control that has stopped contrasting has
stopped measuring, and rewriting it to expect success converts two controls
into two cases that pass whatever the shim does.

⚠ The honest control for "the feature is absent" is an AppDir with **no**
dispatcher in `.preload`, not one carrying somebody else's. Adopting that
changes what the suite claims about upstream, which is why it was left for a
decision rather than taken.

### 2. E49 and E50 on aarch64

**E49** goes MISMATCH on every aarch64 host stage. Its cause was unreadable
until this session gave `experiments/40-appimage.sh` the full-output dump that
`30-run-tests.sh` has had since T-13 closed. ⭐ The next completed aarch64 run
prints the whole output; read it before touching anything.

**E50** requires exactly two live musl-against-glibc ABI hazards and aarch64
measures zero. That would be a real architectural difference worth recording.
⛔ It is NOT recorded as one, because E49 failed in the same stage and a hazard
count taken from a crossing that did not happen measures nothing. Fix E49
first, then decide whether E50's assertion should become architecture-aware
the way E22's condvar probe is.

### 3. The pin is a maintained act now. Expect it to go stale again

Both AppImages are pinned by sha256 against a **mutable** `demo` tag, and the
assets were replaced twice inside two minutes. ⛔ There is no immutable release
to pin to: the upstream and the fork publish one release each and both are
tagged `demo`. `docs/REPORT.md` 9.15 has the policy and the reasoning.

When it refuses, read which of the three cases it names: the pin is stale, the
download is wrong, or neither matches. They call for different things.

⚠ `gtk4-demo` comes from `pkgforge-dev/Anylinux-AppImages`, the upstream. The
demo AppImage comes from Samueru-sama's fork and **cannot move**, because
`host-drivers` appears 0 times in the upstream's code and its
`vkcube+glxgears-demo-*` is the build that bundles its own drivers.

### 4. T-12's table, which is one run away

`experiments/40-appimage.sh` now reports the per-case wall time it has been
recording all along. ⭐ Take the numbers from the next completed run on BOTH
runners and write the measured-versus-configured table into T-12's entry.
⛔ Raise a timeout that is close, never shorten it.

### 5. T-10, T-11, T-16

T-10's entry now carries which gates have been seen to refuse and where, and
⭐ four of them were not planted: they went red on a runner against a real
defect, which is stronger than a plant because nobody chose the shape of the
failure. ⛔ Four are still unproven and the entry names them: the endings gate,
which `.gitattributes` makes unplantable from the working tree; the two
`generated` steps; and the artefact verifier's floor rule. Those need a runner
and a deliberate push.

⛔ **One guard remains unproven and cannot be proven without publishing:**
`release.yml` refuses a tag whose commit is not an ancestor of the default
branch. `package-release.sh`'s two were planted this session and both refuse.

T-11 and T-16's cheaper half were not started. T-16's is a `glprobe` change,
and it can only be verified by a GL-capable suite run.

### 6. Then the release

Nothing is published. The build and package path is proven by pull request #8;
the publish path cannot be until `release.yml` is on the default branch. After
merge, push a `v*` tag and watch it.

⚠ **Publishing was outside the last session's permissions**, so the tag was
not pushed even though everything up to it is ready. Check the permissions
block before assuming it is yours to do.

---

## What this session did

Every claim below has its measurement in `docs/REPORT.md` 9.14 through 9.17.

**Three deep review passes**, each with a different question.

*Pass 1, can every guard added here refuse?* The dash ratchet was recorded as
having failed to fire. It had not: the refusal condition was `count > pin`,
nothing ever lowered the pin, and the tree had drifted eight under, so the
planted dash landed inside the slack. The pin is exact now and a fall refuses
too. It also counted the `--` that the prose rule exempts inside a code block,
which made the section recording the fix unwritable. The cited-path check
could not see a path cited in front of a command, and so never noticed that
`conventions/prose.md` named a ratchet script that has never existed.

*Pass 2, what did this branch stop measuring?* The ARM runner was added saying
qemu "emulates the instructions and not a memory model", and section P went on
running the aarch64 trampolines under qemu **on aarch64 silicon**. It picks its
vehicle from the host now and prints it. The marker was removed and four
documents went on calling it load-bearing.

*Pass 3, does every claim hold when the command is run?* T-13's
"print a MISMATCH in full" was in one harness and not the other, and it was
found by the failure it describes. The corpus cases were the same shape a
third time, reporting a zero total with the reason in a discarded stderr.
`INDEX.md` listed two entries as open that declare themselves DONE.

**Three new checks, each planted and seen to refuse.** The dash ratchet in
`verify-gates.sh`; the two orchestrators pinning the same bytes; every
`INDEX.md` row against its entry's declared status.

**The AppImage suite completes**, having never done so before. Getting there
meant re-pinning against a mutable tag, moving `gtk4-demo` to the true
upstream, and teaching the suite to read the dispatcher slot out of the AppDir
rather than spelling it.

**`tests/bindprobe.c` builds on aarch64.**

---

## ⚠ What a new session should distrust

- **The `.preload` baseline is DERIVED, not shipped.** The AppImage ships this
  project's own forwarding shims in its `.preload`, and restoring that list
  would make every absence case measure a presence. `41-extract.sh` prints what
  it drops on every extraction. If that line disappears, look at it.
- **`ground-truth.md`'s inventory carries a verdict column now.** Two rows are
  UNVERIFIED and say why. Do not quietly re-attach them to the new binary.
- **The tracker is evidence, not instruction.** Pull request #9's premise, that
  `-fcf-protection=full` breaks aarch64, is true of `main` and already fixed on
  this branch; what remains of it is a policy question about the default.
- **A guard that has never been seen to refuse is a guard nobody knows works.**
  Three were found decorative or unarmed this session and every one of them
  looked fine.
